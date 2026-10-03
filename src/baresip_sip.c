/*
 * baresip 을 Dart 에서 부르기 위한 얇은 층.
 *
 * baresip 은 자기 스레드에서 이벤트 루프(re_main)를 돈다. 이 파일은
 *   - 그 스레드를 띄우고 멈추며,
 *   - Dart 스레드에서 온 호출을 re_thread_enter/leave 로 감싸 루프 안에서
 *     돌리고,
 *   - baresip 의 사건(bevent)을 JSON 한 줄로 만들어 Dart 콜백으로 넘긴다.
 *
 * 통화는 baresip 의 struct call * 대신 작은 정수 번호로 주고받는다. Dart 는
 * 포인터를 들고 있지 않는다.
 *
 * JSON 의 모양은 kamailio_sip 플러그인(MethodChannel)이 올려 보내는 맵과
 * 같게 맞췄다. Dart 쪽이 같은 변환을 쓴다.
 */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <re.h>
#include <baresip.h>

#include "baresip_sip.h"
#include "log_file.h"
#include "video_out.h"
#ifdef __APPLE__
#include "vt_h264.h"
#endif

#define MAX_CALLS 8
#define REG_INTERVAL 300

struct slot {
	int id;
	struct call *call;
};

static struct {
	/* libre 의 C11 스레드(thrd·mtx·cnd)를 쓴다 — Windows 에서도 돈다. */
	thrd_t thread;
	mtx_t lock;
	cnd_t cond;
	int start_err;        /* 스레드가 기동을 마치면 채운다 */
	bool start_done;
	RE_ATOMIC bool running;  /* re_main 이 돌고 있는지 */

	uint16_t sip_port;
	bs_event_cb cb;

	struct mqueue *mq;    /* 다른 스레드에서 루프를 멈추게 할 때 */
	struct ua *ua;
	struct slot slots[MAX_CALLS];
	int next_call_id;

	/* 영상 크기 알림이 어느 통화의 것인지. 영상 스레드에서 읽는다. */
	RE_ATOMIC int media_call_id;
	RE_ATOMIC unsigned video_w[2];
	RE_ATOMIC unsigned video_h[2];
} g = {
	.next_call_id = 1,
};

static once_flag g_once = ONCE_FLAG_INIT;

static void g_init(void)
{
	mtx_init(&g.lock, mtx_plain);
	cnd_init(&g.cond);
}


/* ───────────────────────────────────────────────────── 사건 보내기 */

/* JSON 문자열 값 하나를 따옴표까지 붙여 쓴다. %H 로 부른다. */
static int json_str(struct re_printf *pf, const char *s)
{
	int err = re_hprintf(pf, "\"");

	for (; s && *s && !err; s++) {
		unsigned char c = (unsigned char)*s;
		if (c == '"' || c == '\\')
			err = re_hprintf(pf, "\\%c", c);
		else if (c < 0x20)
			err = re_hprintf(pf, "\\u%04x", c);
		else
			err = re_hprintf(pf, "%c", c);
	}

	return err ? err : re_hprintf(pf, "\"");
}

/* fmt 은 "{" 와 "}" 사이의 본문이다. 문자열은 malloc 으로 넘기고 Dart 가
 * bs_free 로 푼다. */
static void emit(const char *fmt, ...)
{
	char *body = NULL, *out;
	size_t n;
	va_list ap;

	if (!g.cb)
		return;

	va_start(ap, fmt);
	(void)re_vsdprintf(&body, fmt, ap);
	va_end(ap);
	if (!body)
		return;

	n = strlen(body);
	out = malloc(n + 3);
	if (out) {
		out[0] = '{';
		memcpy(out + 1, body, n);
		out[n + 1] = '}';
		out[n + 2] = '\0';
		g.cb(out);
	}
	mem_deref(body);
}


/* ───────────────────────────────────────────────────── 통화 번호 */

static int slot_add(struct call *call)
{
	for (int i = 0; i < MAX_CALLS; i++) {
		if (g.slots[i].call == call)
			return g.slots[i].id;
	}
	for (int i = 0; i < MAX_CALLS; i++) {
		if (!g.slots[i].call) {
			g.slots[i].call = call;
			g.slots[i].id = g.next_call_id++;
			return g.slots[i].id;
		}
	}
	return -1;
}

static int slot_id(const struct call *call)
{
	for (int i = 0; i < MAX_CALLS; i++) {
		if (g.slots[i].call && g.slots[i].call == call)
			return g.slots[i].id;
	}
	return -1;
}

static struct call *slot_call(int id)
{
	for (int i = 0; i < MAX_CALLS; i++) {
		if (g.slots[i].call && g.slots[i].id == id)
			return g.slots[i].call;
	}
	return NULL;
}

static void slot_remove(const struct call *call)
{
	for (int i = 0; i < MAX_CALLS; i++) {
		if (g.slots[i].call == call)
			g.slots[i].call = NULL;
	}
}


/* ───────────────────────────────────────────────────── bevent */

/* "401 Unauthorized" 같은 글에서 코드와 사유를 떼어 낸다. */
static void split_status(const char *text, int *code, const char **reason)
{
	char *end = NULL;
	long v = text ? strtol(text, &end, 10) : 0;

	if (text && end != text && v >= 100 && v < 1000) {
		*code = (int)v;
		*reason = (*end == ' ') ? end + 1 : end;
	}
	else {
		*code = 0;
		*reason = text ? text : "";
	}
}

static void emit_call(struct call *call, int id, const char *state,
		      int scode, const char *reason)
{
	emit("\"type\":\"call\",\"callId\":%d,\"state\":\"%s\","
	     "\"remoteUri\":%H,\"incoming\":%s,\"remoteHasVideo\":%s,"
	     "\"statusCode\":%d,\"reason\":%H",
	     id, state, json_str, call_peeruri(call),
	     call_is_outgoing(call) ? "false" : "true",
	     call_has_video(call) ? "true" : "false",
	     scode, json_str, reason ? reason : "");
}

/* 영상이 실제로 오가는지 — SDP 에 영상이 있고 방향이 inactive 가 아니다. */
static bool video_active(const struct call *call)
{
	const struct sdp_media *m;

	if (!call_has_video(call))
		return false;

	m = stream_sdpmedia(video_strm(call_video(call)));
	return m && sdp_media_dir(m) != SDP_INACTIVE;
}

/* 미디어 상태. 영상 크기는 아는 쪽만 싣는다(0 이면 아직 그림이 없다). */
static void emit_media(int id, bool video)
{
	unsigned lw = re_atomic_rlx(&g.video_w[0]), lh = re_atomic_rlx(&g.video_h[0]);
	unsigned rw = re_atomic_rlx(&g.video_w[1]), rh = re_atomic_rlx(&g.video_h[1]);

	emit("\"type\":\"media\",\"callId\":%d,"
	     "\"audioActive\":true,\"videoActive\":%s,"
	     "\"localVideoWidth\":%u,\"localVideoHeight\":%u,"
	     "\"remoteVideoWidth\":%u,\"remoteVideoHeight\":%u",
	     id, video ? "true" : "false", lw, lh, rw, rh);
}

/* video_out 이 영상 스레드에서 부른다. */
static void on_video_size(int which, unsigned w, unsigned h)
{
	int id = re_atomic_rlx(&g.media_call_id);

	re_atomic_rlx_set(&g.video_w[which], w);
	re_atomic_rlx_set(&g.video_h[which], h);
	if (id > 0)
		emit_media(id, true);
}

static void reset_video_state(void)
{
	for (int i = 0; i < 2; i++) {
		re_atomic_rlx_set(&g.video_w[i], 0);
		re_atomic_rlx_set(&g.video_h[i], 0);
	}
	video_out_reset();
}

static void event_handler(enum bevent_ev ev, struct bevent *event, void *arg)
{
	struct call *call = bevent_get_call(event);
	struct ua *ua = bevent_get_ua(event);
	const char *text = bevent_get_text(event);
	const char *reason;
	int code, id;
	(void)arg;

	if (ua && ua != g.ua)
		return;

	switch (ev) {

	case BEVENT_REGISTER_OK:
		split_status(text, &code, &reason);
		emit("\"type\":\"registration\",\"code\":%d,\"reason\":%H,"
		     "\"expiration\":%u",
		     code ? code : 200, json_str, reason,
		     account_regint(ua_account(ua)));
		break;

	case BEVENT_REGISTER_FAIL:
		split_status(text, &code, &reason);
		/* 코드가 없으면 전송 오류다(연결 거부, DNS 등). */
		emit("\"type\":\"registration\",\"code\":%d,\"reason\":%H,"
		     "\"expiration\":0",
		     code ? code : 503, json_str, reason);
		break;

	case BEVENT_UNREGISTERING:
		emit("\"type\":\"registration\",\"code\":200,"
		     "\"reason\":\"OK\",\"expiration\":0");
		break;

	case BEVENT_CALL_INCOMING:
		id = slot_add(call);
		if (id < 0) {
			call_hangup(call, 486, "Busy Here");
			break;
		}
		emit_call(call, id, "early", 0, NULL);
		break;

	case BEVENT_CALL_OUTGOING:
		emit_call(call, slot_add(call), "calling", 0, NULL);
		break;

	case BEVENT_CALL_RINGING:
	case BEVENT_CALL_PROGRESS:
		emit_call(call, slot_add(call), "early", 0, NULL);
		break;

	case BEVENT_CALL_ANSWERED:
		emit_call(call, slot_add(call), "connecting", 0, NULL);
		break;

	case BEVENT_CALL_ESTABLISHED:
		id = slot_add(call);
		reset_video_state();
		re_atomic_rlx_set(&g.media_call_id, id);
		emit_call(call, id, "confirmed", 0, NULL);
		emit_media(id, video_active(call));
		break;

	/* 통화 중 영상을 켜고 끈 re-INVITE 가 오가면 미디어 상태를 다시 알린다. */
	case BEVENT_CALL_REMOTE_SDP:
	case BEVENT_CALL_LOCAL_SDP:
		id = slot_id(call);
		if (id > 0 && call_state(call) == CALL_STATE_ESTABLISHED)
			emit_media(id, video_active(call));
		break;

	case BEVENT_CALL_CLOSED:
		id = slot_id(call);
		if (id < 0)
			break;
		split_status(text, &code, &reason);
		if (!code)
			code = call_scode(call);
		emit_call(call, id, "disconnected", code, reason);
		slot_remove(call);
		if (re_atomic_rlx(&g.media_call_id) == id)
			re_atomic_rlx_set(&g.media_call_id, 0);
		break;

	default:
		break;
	}
}


/* ───────────────────────────────────────────────────── 스택 스레드 */

/* 플랫폼마다 다른 설정.
 *   macOS   — 오디오 audiounit, 영상 avcapture + vt_h264(VideoToolbox) + flutter 출력
 *   Windows — 오디오 wasapi. 영상은 아직 없다(H.264 를 무엇으로 할지 정하기 전). */
#ifdef __APPLE__
#define AUDIO_DRIVER "audiounit"
#define VIDEO_CONFIG \
	"video_source\t\tavcapture,\n" \
	"video_display\t\tflutter,\n" \
	"video_size\t\t640x480\n" \
	"video_bitrate\t\t1000000\n" \
	"video_fps\t\t25\n"
#define VIDEO_MODULES "module\t\t\tavcapture.so\n"
#define VIDEO_CODECS ";video_codecs=H264"
#else
#define AUDIO_DRIVER "wasapi"
#define VIDEO_CONFIG ""
#define VIDEO_MODULES ""
#define VIDEO_CODECS ""
#endif

static const char *config_template =
	"sip_listen\t\t0.0.0.0:%u\n"
	"sip_verify_server\tno\n"
	"call_max_calls\t\t4\n"
	/* 기본값(no)이면 들어온 INVITE 를 앱이 ua_accept 해 주길 기다린다
	 * (baresip 의 menu 모듈이 하는 일). 받아서 CALL_INCOMING 으로 올린다. */
	"call_accept\t\tyes\n"
	"audio_player\t\t" AUDIO_DRIVER ",default\n"
	"audio_source\t\t" AUDIO_DRIVER ",default\n"
	"audio_alert\t\t" AUDIO_DRIVER ",default\n"
	"rtp_ports\t\t10000-20000\n"
	VIDEO_CONFIG
	/* 음성에는 스테레오가 필요 없고, webrtc_aec 는 모노만 처리한다. */
	"opus_stereo\t\tno\n"
	"opus_sprop_stereo\tno\n"
	"module_path\t\t.\n"
	"module\t\t\tg711.so\n"
	"module\t\t\topus.so\n"
	"module\t\t\t" AUDIO_DRIVER ".so\n"
	"module\t\t\tauconv.so\n"
	"module\t\t\tauresamp.so\n"
	/* 에코 제거(WebRTC AEC3). 필터는 불러온 순서대로 서므로 auconv·
	 * auresamp 뒤에 둬야 코덱 표본율에서 돈다. 모노만 받는다. */
	"module\t\t\twebrtc_aec.so\n"
	VIDEO_MODULES
	"module\t\t\tstun.so\n"
	"module\t\t\tturn.so\n"
	"module\t\t\tice.so\n"
	"module\t\t\tsrtp.so\n"
	"module\t\t\tdtls_srtp.so\n";

static void finish_start(int err)
{
	mtx_lock(&g.lock);
	g.start_err = err;
	g.start_done = true;
	cnd_signal(&g.cond);
	mtx_unlock(&g.lock);
}

/* re_main 이 돌기 시작한 뒤에 한 번 불린다. 이때부터 re_thread_enter 가
 * 제대로 잠근다. */
static void on_loop_started(void *arg)
{
	(void)arg;
	re_atomic_rlx_set(&g.running, true);
	emit("\"type\":\"stack\",\"state\":\"started\"");
	finish_start(0);
}

/* bs_stop 이 보낸 요청. 루프 스레드에서 불린다. re_cancel 을 다른 스레드에서
 * 부르면 루프가 잠에서 깨지 않으므로 mqueue(파이프)로 깨운다. */
static void mq_handler(int id, void *data, void *arg)
{
	(void)id;
	(void)data;
	(void)arg;
	ua_stop_all(true);
	re_cancel();
}

static int stack_thread(void *arg)
{
	struct tmr tmr;
	char *conf = NULL;
	int err;
	(void)arg;

	tmr_init(&tmr);

	err = libre_init();
	if (err)
		goto fail;

	log_file_attach();

	err = mqueue_alloc(&g.mq, mq_handler, NULL);
	if (err)
		goto out;

	re_thread_async_init(4);

	err = re_sdprintf(&conf, config_template, g.sip_port);
	if (err)
		goto out;

	err = conf_configure_buf((const uint8_t *)conf, strlen(conf));
	if (err)
		goto out;

	err = baresip_init(conf_config());
	if (err)
		goto out;

#ifdef __APPLE__
	vt_h264_register();
#endif
	err = video_out_register(on_video_size);
	if (err)
		goto out;

	err = ua_init("GotDoor SIP (baresip " BARESIP_VERSION ")",
		      true, true, true);
	if (err)
		goto out;

	err = bevent_register(event_handler, NULL);
	if (err)
		goto out;

	err = conf_modules();
	if (err)
		goto out;

	tmr_start(&tmr, 0, on_loop_started, NULL);

	(void)re_main(NULL);

	re_atomic_rlx_set(&g.running, false);
	emit("\"type\":\"stack\",\"state\":\"stopped\"");

 out:
	tmr_cancel(&tmr);
	bevent_unregister(event_handler);
	g.ua = NULL;
	memset(g.slots, 0, sizeof(g.slots));
	ua_close();
	video_out_unregister();
#ifdef __APPLE__
	vt_h264_unregister();
#endif
	module_app_unload();
	conf_close();
	baresip_close();
	mod_close();
	re_thread_async_close();
	log_file_detach();
	g.mq = mem_deref(g.mq);
	mem_deref(conf);
	libre_close();

 fail:
	if (err) {
		emit("\"type\":\"stack\",\"state\":\"failed\",\"reason\":%H",
		     json_str, strerror(err));
		finish_start(err);
	}

	return 0;
}


/* ───────────────────────────────────────────────────── 공개 함수 */

int bs_start(uint16_t sip_port, bs_event_cb cb)
{
	int err;

	if (re_atomic_rlx(&g.running))
		return 0;

	call_once(&g_once, g_init);

#ifndef _WIN32
	/* baresip 은 로그를 stdout 으로 낸다. 파일·파이프로 받을 때도 줄마다
	 * 나오게 한다. (MSVC 는 _IOLBF 를 받지 않는다.) */
	setvbuf(stdout, NULL, _IOLBF, 0);
#endif

	g.sip_port = sip_port;
	g.cb = cb;
	g.start_done = false;
	g.start_err = 0;

	if (thrd_create(&g.thread, stack_thread, NULL) != thrd_success)
		return -EAGAIN;

	mtx_lock(&g.lock);
	while (!g.start_done)
		cnd_wait(&g.cond, &g.lock);
	err = g.start_err;
	mtx_unlock(&g.lock);

	if (err)
		thrd_join(g.thread, NULL);

	return -err;
}

void bs_stop(void)
{
	if (!re_atomic_rlx(&g.running))
		return;

	mqueue_push(g.mq, 0, NULL);
	thrd_join(g.thread, NULL);
	g.cb = NULL;
}

/* Dart 에서 온 호출을 re 스레드 잠금 안에서 돌린다. */
#define ENTER()                              \
	do {                                 \
		if (!re_atomic_rlx(&g.running)) \
			return -EAGAIN;      \
		re_thread_enter();           \
	} while (0)
#define LEAVE() re_thread_leave()

int bs_register(const char *user, const char *password, const char *domain,
		const char *server, uint16_t port, const char *transport)
{
	char *aor = NULL;
	int err;

	ENTER();

	/* 계정을 바꾸면 이전 등록과 통화를 걷어 낸다. */
	if (g.ua) {
		ua_destroy(g.ua);
		g.ua = NULL;
		memset(g.slots, 0, sizeof(g.slots));
	}

	/* 도메인과 서버가 다를 수 있으므로 요청은 늘 서버로 보낸다(outbound).
	 * 비밀번호는 문자열 파싱을 거치지 않게 따로 넣는다.
	 * opus 는 모노로 설정해 두었으므로 채널 수를 1 로 찾는다(SDP 에는
	 * RFC 7587 대로 opus/48000/2 가 나간다). */
	err = re_sdprintf(&aor,
			  "<sip:%s@%s;transport=%s>"
			  ";outbound=\"sip:%s:%u;transport=%s\""
			  ";regint=%u;auth_user=%s"
			  ";audio_codecs=PCMU/8000/1,PCMA/8000/1,opus/48000/1"
			  VIDEO_CODECS,
			  user, domain, transport,
			  server, port, transport,
			  REG_INTERVAL, user);
	if (err)
		goto out;

	err = ua_alloc(&g.ua, aor);
	if (err)
		goto out;

	err = account_set_auth_pass(ua_account(g.ua), password);
	if (err)
		goto out;

	err = ua_register(g.ua);

 out:
	mem_deref(aor);
	LEAVE();
	return -err;
}

int bs_unregister(void)
{
	ENTER();
	if (g.ua)
		ua_unregister(g.ua);
	LEAVE();
	return 0;
}

/* Direct 모드. REGISTER 없이 sip:<user>@<local_ip> 계정만 올린다. 상대가 이
 * 주소로 곧바로 보내는 INVITE 를 이 계정이 받고, 발신도 이 계정으로 나간다.
 * regint=0 이고 ua_register 를 부르지 않는다. */
int bs_direct_start(const char *user, const char *local_ip)
{
	char *aor = NULL;
	int err;

	ENTER();

	if (g.ua) {
		ua_destroy(g.ua);
		g.ua = NULL;
		memset(g.slots, 0, sizeof(g.slots));
	}

	err = re_sdprintf(&aor,
			  "<sip:%s@%s>;regint=0"
			  ";audio_codecs=PCMU/8000/1,PCMA/8000/1,opus/48000/1"
			  VIDEO_CODECS,
			  user, local_ip);
	if (err)
		goto out;

	err = ua_alloc(&g.ua, aor);

 out:
	mem_deref(aor);
	LEAVE();
	return -err;
}

int bs_direct_stop(void)
{
	ENTER();
	if (g.ua) {
		ua_destroy(g.ua);
		g.ua = NULL;
		memset(g.slots, 0, sizeof(g.slots));
	}
	LEAVE();
	return 0;
}

int bs_call(const char *uri, int video)
{
	struct call *call = NULL;
	int err, id = -1;

	ENTER();

	if (!g.ua) {
		err = ENOENT;
		goto out;
	}

	err = ua_connect(g.ua, &call, NULL, uri,
			 video ? VIDMODE_ON : VIDMODE_OFF);
	if (err)
		goto out;

	id = slot_add(call);
	if (id < 0) {
		ua_hangup(g.ua, call, 486, "Busy Here");
		err = EBUSY;
	}

 out:
	LEAVE();
	return err ? -err : id;
}

int bs_answer(int call_id, int video)
{
	struct call *call;
	int err = ENOENT;

	ENTER();
	call = slot_call(call_id);
	if (call && g.ua)
		err = ua_answer(g.ua, call, video ? VIDMODE_ON : VIDMODE_OFF);
	LEAVE();
	return -err;
}

int bs_hangup(int call_id, int code)
{
	struct call *call;
	int err = ENOENT;

	ENTER();
	call = slot_call(call_id);
	if (call && g.ua) {
		/* 우리가 끊은 통화는 CALL_CLOSED 가 오지 않는다. 화면이
		 * 기다리므로 여기서 직접 알린다. */
		emit_call(call, call_id, "disconnected", code ? code : 200, "");
		slot_remove(call);
		if (re_atomic_rlx(&g.media_call_id) == call_id)
			re_atomic_rlx_set(&g.media_call_id, 0);
		ua_hangup(g.ua, call, (uint16_t)code, NULL);
		err = 0;
	}
	LEAVE();
	return -err;
}

int bs_set_video(int call_id, int enabled)
{
	struct call *call;
	int err = ENOENT;

	ENTER();
	call = slot_call(call_id);
	if (call)
		err = call_set_video_dir(call, enabled ? SDP_SENDRECV
					 : SDP_INACTIVE);
	LEAVE();
	return -err;
}

int bs_mute(int call_id, int mute)
{
	struct call *call;
	int err = ENOENT;

	ENTER();
	call = slot_call(call_id);
	if (call) {
		audio_mute(call_audio(call), mute != 0);
		err = 0;
	}
	LEAVE();
	return -err;
}

int bs_dtmf(int call_id, const char *digits)
{
	struct call *call;
	int err = ENOENT;

	ENTER();
	call = slot_call(call_id);
	if (call) {
		err = 0;
		for (const char *d = digits; d && *d && !err; d++)
			err = call_send_digit(call, *d);
		if (!err)
			err = call_send_digit(call, KEYCODE_REL);
	}
	LEAVE();
	return -err;
}

char *bs_stats(int call_id)
{
	struct call *call;
	struct audio *au;
	struct stream *strm;
	const struct aucodec *ac;
	const struct rtcp_stats *rtcp;
	const struct sdp_media *m, *vm = NULL;
	const struct vidcodec *vc = NULL;
	char *body = NULL, *out = NULL;
	double loss = 0;

	if (!re_atomic_rlx(&g.running))
		return NULL;

	re_thread_enter();

	call = slot_call(call_id);
	au = call ? call_audio(call) : NULL;
	strm = au ? audio_strm(au) : NULL;
	if (!strm)
		goto out;

	ac = audio_codec(au, true);
	if (video_active(call)) {
		vc = video_codec(call_video(call), true);
		vm = stream_sdpmedia(video_strm(call_video(call)));
	}
	rtcp = stream_rtcp_stats(strm);
	m = stream_sdpmedia(strm);

	if (rtcp && rtcp->rx.sent + rtcp->rx.lost > 0)
		loss = 100.0 * rtcp->rx.lost /
			(rtcp->rx.sent + rtcp->rx.lost);

	(void)re_sdprintf(&body,
		"{\"audioCodec\":%H,"
		"\"bytesSent\":%u,\"packetsSent\":%u,"
		"\"bytesReceived\":%u,\"packetsReceived\":%u,"
		"\"lossPercent\":%.1f,\"rttMs\":%u,"
		"\"remoteRtpAddress\":\"%J\",\"audioDirection\":\"%s\","
		"\"videoCodec\":%H,\"videoDirection\":\"%s\"}",
		json_str, ac ? ac->name : "",
		stream_metric_get_tx_n_bytes(strm),
		stream_metric_get_tx_n_packets(strm),
		stream_metric_get_rx_n_bytes(strm),
		stream_metric_get_rx_n_packets(strm),
		loss,
		rtcp ? rtcp->rtt / 1000 : 0,
		sdp_media_raddr(m),
		sdp_dir_name(sdp_media_dir(m)),
		json_str, vc ? vc->name : "",
		vm ? sdp_dir_name(sdp_media_dir(vm)) : "");

 out:
	re_thread_leave();

	if (body) {
		out = strdup(body);
		mem_deref(body);
	}
	return out;
}

void bs_free(void *p)
{
	free(p);
}
