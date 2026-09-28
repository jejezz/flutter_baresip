/* 로그를 파일에 남긴다(bs_set_log_file). 스택 스레드가 붙이고 뗀다. */
#ifndef LOG_FILE_H
#define LOG_FILE_H

void log_file_attach(void);
void log_file_detach(void);

#endif
