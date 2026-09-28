// src/baresip_sip.h 를 그대로 옮긴 것. 헤더를 고치면 여기도 고친다.
// ignore_for_file: non_constant_identifier_names
import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef EventCallback = Void Function(Pointer<Utf8> json);

@Native<Int32 Function(Uint16, Pointer<NativeFunction<EventCallback>>)>()
external int bs_start(int sipPort, Pointer<NativeFunction<EventCallback>> cb);

@Native<Void Function()>()
external void bs_stop();

@Native<
  Int32 Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Uint16,
    Pointer<Utf8>,
  )
>()
external int bs_register(
  Pointer<Utf8> user,
  Pointer<Utf8> password,
  Pointer<Utf8> domain,
  Pointer<Utf8> server,
  int port,
  Pointer<Utf8> transport,
);

@Native<Int32 Function()>()
external int bs_unregister();

@Native<Int32 Function(Pointer<Utf8>, Int32)>()
external int bs_call(Pointer<Utf8> uri, int video);

@Native<Int32 Function(Int32, Int32)>()
external int bs_answer(int callId, int video);

@Native<Int32 Function(Int32, Int32)>()
external int bs_hangup(int callId, int code);

@Native<Int32 Function(Int32, Int32)>()
external int bs_mute(int callId, int mute);

@Native<Int32 Function(Int32, Pointer<Utf8>)>()
external int bs_dtmf(int callId, Pointer<Utf8> digits);

@Native<Pointer<Utf8> Function(Int32)>()
external Pointer<Utf8> bs_stats(int callId);

@Native<Void Function(Pointer<Void>)>()
external void bs_free(Pointer<Void> p);

@Native<Int32 Function(Int32, Int32)>()
external int bs_set_video(int callId, int enabled);

@Native<Int32 Function(Pointer<Utf8>)>()
external int bs_set_log_file(Pointer<Utf8> path);

@Native<Void Function(Pointer<Utf8>)>()
external void bs_log(Pointer<Utf8> msg);

@Native<Void Function(Pointer<Void>, Pointer<Void>)>()
external void bs_set_video_sink(Pointer<Void> sink, Pointer<Void> ctx);
