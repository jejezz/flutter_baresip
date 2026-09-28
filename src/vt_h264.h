/* VideoToolbox 로 하는 H.264 코덱. baresip_init 뒤, conf_modules 앞에 등록한다. */
#ifndef VT_H264_H
#define VT_H264_H

void vt_h264_register(void);
void vt_h264_unregister(void);

#endif
