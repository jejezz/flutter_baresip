/*
 * 로그를 파일에 남긴다.
 *
 * 데스크톱 앱은 콘솔이 없어(Windows) baresip 로그를 볼 곳이 없다. baresip 의
 * 로그(log_register_handler)와 libre 의 저수준 경고(dbg_handler_set), 앱이
 * bs_log 로 넘기는 줄을 한 파일에 시각을 붙여 쓴다.
 *
 * 여러 스레드(baresip 루프, 오디오·영상, Dart)가 부르므로 잠근다.
 */
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <re.h>
#define DEBUG_MODULE "log_file"
#define DEBUG_LEVEL 5
#include <re_dbg.h>   /* re.h 는 이걸 싣지 않는다 */
#include <baresip.h>

#ifdef _WIN32
#include <windows.h>
#endif

#include "baresip_sip.h"
#include "log_file.h"

static struct {
	mtx_t lock;
	FILE *f;
} lg;

static once_flag lg_once = ONCE_FLAG_INIT;

static void lg_init(void)
{
	mtx_init(&lg.lock, mtx_plain);
}

/* UTF-8 경로를 연다. Windows 의 fopen 은 ANSI 코드 페이지라 한글 사용자
 * 이름이 든 경로를 열지 못한다. */
static FILE *open_utf8(const char *path)
{
#ifdef _WIN32
	wchar_t wpath[1024];

	if (!MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath,
				 (int)RE_ARRAY_SIZE(wpath)))
		return NULL;
	return _wfopen(wpath, L"a");
#else
	return fopen(path, "a");
#endif
}

static void write_line(const char *tag, const char *msg, size_t len)
{
	struct timespec ts;
	struct tm tm;
	char stamp[32];

	if (!lg.f || !msg)
		return;

	timespec_get(&ts, TIME_UTC);
#ifdef _WIN32
	localtime_s(&tm, &ts.tv_sec);
#else
	localtime_r(&ts.tv_sec, &tm);
#endif
	strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &tm);

	/* 끝의 줄바꿈은 떼고 우리가 하나 붙인다. */
	while (len > 0 && (msg[len - 1] == '\n' || msg[len - 1] == '\r'))
		--len;

	fprintf(lg.f, "%s.%03ld %-5s %.*s\n", stamp, ts.tv_nsec / 1000000,
		tag, (int)len, msg);
	fflush(lg.f);
}

static void on_log(uint32_t level, const char *msg)
{
	mtx_lock(&lg.lock);
	write_line(log_level_name((enum log_level)level), msg,
		   msg ? strlen(msg) : 0);
	mtx_unlock(&lg.lock);
}

static void on_dbg(int level, const char *p, size_t len, void *arg)
{
	(void)arg;
	mtx_lock(&lg.lock);
	write_line(level <= DBG_WARNING ? "WARN" : "DEBUG", p, len);
	mtx_unlock(&lg.lock);
}

static struct log loghandler = {
	.h = on_log,
};

int bs_set_log_file(const char *path)
{
	FILE *f = NULL;

	call_once(&lg_once, lg_init);

	if (path && *path) {
		f = open_utf8(path);
		if (!f)
			return -EIO;
	}

	mtx_lock(&lg.lock);
	if (lg.f)
		fclose(lg.f);
	lg.f = f;
	mtx_unlock(&lg.lock);

	return 0;
}

void bs_log(const char *msg)
{
	call_once(&lg_once, lg_init);

	mtx_lock(&lg.lock);
	write_line("APP", msg, msg ? strlen(msg) : 0);
	mtx_unlock(&lg.lock);
}

/* 스택 스레드가 libre_init 뒤에 부른다. */
void log_file_attach(void)
{
	call_once(&lg_once, lg_init);

	/* 파일에 색 코드(ESC[31m …)가 섞이지 않게 한다. */
	log_enable_color(false);
	log_register_handler(&loghandler);
	dbg_handler_set(on_dbg, NULL);
}

void log_file_detach(void)
{
	dbg_handler_set(NULL, NULL);
	log_unregister_handler(&loghandler);
}
