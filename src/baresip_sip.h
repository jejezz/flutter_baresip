/*
 * baresip 을 Dart(dart:ffi) 에서 부르기 위한 C 경계.
 *
 * 정수를 돌려주는 함수는 0(또는 양수) 이면 성공, 음수면 -errno 다.
 * 사건과 bs_stats 가 돌려주는 문자열은 JSON 이고, 받은 쪽이 bs_free 로 푼다.
 */
#ifndef BARESIP_SIP_H
#define BARESIP_SIP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* baresip 스레드에서 불린다. Dart 는 NativeCallable.listener 로 받는다. */
typedef void (*bs_event_cb)(char *json);

/* 스택을 띄우고 이벤트 루프가 돌 때까지 기다린다. */
int  bs_start(uint16_t sip_port, bs_event_cb cb);
void bs_stop(void);

int  bs_register(const char *user, const char *password, const char *domain,
		 const char *server, uint16_t port, const char *transport);
int  bs_unregister(void);

/* REGISTER 없는 계정(Direct). bs_direct_stop 은 계정을 없앤다. */
int  bs_direct_start(const char *user, const char *local_ip);
int  bs_direct_stop(void);

/* 성공하면 통화 번호(양수)를 돌려준다. */
int  bs_call(const char *uri, int video);
int  bs_answer(int call_id, int video);
int  bs_hangup(int call_id, int code);
int  bs_mute(int call_id, int mute);
int  bs_dtmf(int call_id, const char *digits);

/* 통화 중 영상을 켜고 끈다(re-INVITE). */
int  bs_set_video(int call_id, int enabled);

/* 영상 프레임을 받을 곳. which: 0 = 내 카메라, 1 = 상대. bgra 는 한 줄에
 * stride 바이트인 BGRA 그림이고 이 호출 안에서만 유효하다. baresip 의 영상
 * 스레드에서 불린다. */
typedef void (*bs_video_sink)(void *ctx, int which, const uint8_t *bgra,
			      int width, int height, int stride);
void bs_set_video_sink(bs_video_sink sink, void *ctx);

/* 통화 진단 값(JSON). 통화가 없으면 NULL. */
char *bs_stats(int call_id);

void bs_free(void *p);

/* 로그를 이 파일(UTF-8 경로)에 덧붙인다. baresip·libre 로그와 bs_log 로 넘긴
 * 줄이 시각과 함께 쌓인다. NULL 이나 빈 문자열이면 멈춘다. bs_start 앞에
 * 불러야 기동 로그까지 남는다. */
int  bs_set_log_file(const char *path);
void bs_log(const char *msg);

#ifdef __cplusplus
}
#endif

#endif
