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

/* 성공하면 통화 번호(양수)를 돌려준다. */
int  bs_call(const char *uri, int video);
int  bs_answer(int call_id, int video);
int  bs_hangup(int call_id, int code);
int  bs_mute(int call_id, int mute);
int  bs_dtmf(int call_id, const char *digits);

/* 통화 진단 값(JSON). 통화가 없으면 NULL. */
char *bs_stats(int call_id);

void bs_free(void *p);

#ifdef __cplusplus
}
#endif

#endif
