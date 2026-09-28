/*
 * 영상을 Flutter 텍스처로 내보낸다.
 *
 * - 상대 영상: baresip 의 영상 출력(vidisp) "flutter" 로 받는다.
 * - 내 카메라: 인코더 앞에 선 영상 필터(vidfilt) "selfview" 로 엿본다.
 *
 * 두 쪽 모두 BGRA(= libre 의 RGB32, 리틀 엔디언) 로 바꿔 싱크 함수로
 * 넘긴다. 싱크는 앱 쪽 플랫폼 코드(macOS 는 Swift 플러그인)가 bs_set_video_sink
 * 로 걸어 둔다. 싱크는 baresip 의 영상 스레드에서 불리므로 스스로 스레드
 * 안전해야 한다.
 */
#include <string.h>
#include <re.h>
#include <rem.h>
#include <baresip.h>

#include "baresip_sip.h"
#include "video_out.h"

static struct {
	mtx_t lock;
	bs_video_sink sink;
	void *ctx;
	video_out_size_h *sizeh;
	struct vidsz last[2];
} vo;

static once_flag vo_once = ONCE_FLAG_INIT;

static void vo_init(void)
{
	mtx_init(&vo.lock, mtx_plain);
}

static struct vidisp *vidisp;


/* 한 쪽(0 = 내 카메라, 1 = 상대)의 프레임을 BGRA 로 바꿔 넘긴다. 변환 버퍼는
 * 쪽마다 따로 두고 크기가 바뀔 때만 다시 잡는다. */
struct conv {
	struct vidframe *bgra;
};

static void deliver(struct conv *cv, int which, const struct vidframe *f)
{
	bs_video_sink sink;
	void *ctx;
	bool resized;

	if (!f || !vidframe_isvalid(f))
		return;

	mtx_lock(&vo.lock);
	sink = vo.sink;
	ctx = vo.ctx;
	resized = !vidsz_cmp(&vo.last[which], &f->size);
	vo.last[which] = f->size;
	mtx_unlock(&vo.lock);

	if (resized) {
		info("video_out: %s %ux%u (%s)\n", which ? "remote" : "local",
		     f->size.w, f->size.h, vidfmt_name(f->fmt));
		if (vo.sizeh)
			vo.sizeh(which, f->size.w, f->size.h);
	}

	if (!sink)
		return;

	if (!cv->bgra || !vidsz_cmp(&cv->bgra->size, &f->size)) {
		cv->bgra = mem_deref(cv->bgra);
		if (vidframe_alloc(&cv->bgra, VID_FMT_RGB32, &f->size))
			return;
	}

	if (f->fmt == VID_FMT_RGB32) {
		sink(ctx, which, f->data[0], (int)f->size.w, (int)f->size.h,
		     f->linesize[0]);
		return;
	}

	vidconv(cv->bgra, f, NULL);
	sink(ctx, which, cv->bgra->data[0], (int)f->size.w, (int)f->size.h,
	     cv->bgra->linesize[0]);
}


/* ───────────────────────────────────────────────────── 상대 영상 */

struct vidisp_st {
	struct conv cv;
};

static void disp_destructor(void *arg)
{
	struct vidisp_st *st = arg;

	mem_deref(st->cv.bgra);
}

static int disp_alloc(struct vidisp_st **stp, const struct vidisp *vd,
		      struct vidisp_prm *prm, const char *dev,
		      vidisp_resize_h *resizeh, void *arg)
{
	struct vidisp_st *st;
	(void)vd;
	(void)prm;
	(void)dev;
	(void)resizeh;
	(void)arg;

	st = mem_zalloc(sizeof(*st), disp_destructor);
	if (!st)
		return ENOMEM;

	*stp = st;
	return 0;
}

static int disp_frame(struct vidisp_st *st, const char *title,
		      const struct vidframe *frame, uint64_t timestamp)
{
	(void)title;
	(void)timestamp;

	deliver(&st->cv, 1, frame);
	return 0;
}


/* ───────────────────────────────────────────────────── 내 카메라 */

struct selfview_enc {
	struct vidfilt_enc_st vf;   /* 반드시 맨 앞 */
	struct conv cv;
};

static void selfview_destructor(void *arg)
{
	struct selfview_enc *st = arg;

	list_unlink(&st->vf.le);
	mem_deref(st->cv.bgra);
}

static int selfview_update(struct vidfilt_enc_st **stp, void **ctx,
			   const struct vidfilt *vf, struct vidfilt_prm *prm,
			   const struct video *vid)
{
	struct selfview_enc *st;
	(void)ctx;
	(void)vf;
	(void)prm;
	(void)vid;

	if (!stp)
		return EINVAL;

	if (*stp)
		return 0;

	st = mem_zalloc(sizeof(*st), selfview_destructor);
	if (!st)
		return ENOMEM;

	*stp = (struct vidfilt_enc_st *)st;
	return 0;
}

static int selfview_encode(struct vidfilt_enc_st *vst, struct vidframe *frame,
			   uint64_t *timestamp)
{
	struct selfview_enc *st = (struct selfview_enc *)vst;
	(void)timestamp;

	deliver(&st->cv, 0, frame);
	return 0;
}

static struct vidfilt selfview = {
	.name    = "selfview_flutter",
	.encupdh = selfview_update,
	.ench    = selfview_encode,
};


/* ───────────────────────────────────────────────────── 공개 */

int video_out_register(video_out_size_h *sizeh)
{
	call_once(&vo_once, vo_init);
	vo.sizeh = sizeh;
	memset(vo.last, 0, sizeof(vo.last));
	vidfilt_register(baresip_vidfiltl(), &selfview);
	return vidisp_register(&vidisp, baresip_vidispl(), "flutter",
			       disp_alloc, NULL, disp_frame, NULL);
}

void video_out_unregister(void)
{
	vidfilt_unregister(&selfview);
	vidisp = mem_deref(vidisp);
	vo.sizeh = NULL;
}

/* 통화가 끝나면 다음 통화에서 크기를 다시 알리도록 잊는다. */
void video_out_reset(void)
{
	mtx_lock(&vo.lock);
	memset(vo.last, 0, sizeof(vo.last));
	mtx_unlock(&vo.lock);
}

void bs_set_video_sink(bs_video_sink sink, void *ctx)
{
	call_once(&vo_once, vo_init);
	mtx_lock(&vo.lock);
	vo.sink = sink;
	vo.ctx = ctx;
	mtx_unlock(&vo.lock);
}
