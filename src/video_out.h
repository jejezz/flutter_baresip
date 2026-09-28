/* 영상을 Flutter 텍스처로 내보내는 출력(vidisp)과 내 카메라 필터(vidfilt). */
#ifndef VIDEO_OUT_H
#define VIDEO_OUT_H

/* which: 0 = 내 카메라, 1 = 상대. 크기가 처음 정해지거나 바뀔 때 불린다
 * (baresip 영상 스레드). */
typedef void (video_out_size_h)(int which, unsigned width, unsigned height);

int  video_out_register(video_out_size_h *sizeh);
void video_out_unregister(void);
void video_out_reset(void);

#endif
