import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'src/bindings.dart' as c;

/// baresip 스택이 돌려준 오류. [code] 는 errno 값이다.
class BaresipException implements Exception {
  const BaresipException(this.operation, this.code);

  final String operation;
  final int code;

  @override
  String toString() => 'BaresipException($operation, errno $code)';
}

/// 영상 프레임이 올라가는 Flutter 텍스처 두 개.
class BaresipVideoTextures {
  const BaresipVideoTextures({required this.local, required this.remote});

  /// 내 카메라.
  final int local;

  /// 상대 영상.
  final int remote;
}

/// baresip 을 부르는 얇은 껍데기.
///
/// 사건의 모양(`type` 으로 갈래를 나눈 맵)은 kamailio_sip 플러그인과 같다.
/// 상태를 들고 있지 않으므로 상태 머신은 앱 쪽(`SipService`)이 맡는다.
///
/// 스택은 프로세스에 하나뿐이다.
class BaresipSip {
  static const MethodChannel _video = MethodChannel('flutter_baresip/video');

  /// 이 빌드에 스택 라이브러리가 들어 있는지.
  ///
  /// 미리 빌드한 라이브러리가 없는 플랫폼·체크아웃에서는 빌드 훅이 아무것도
  /// 내지 않고, 네이티브 함수를 처음 부를 때 ArgumentError 가 난다.
  static bool get isAvailable {
    try {
      c.bs_free(nullptr);
      return true;
    } on ArgumentError {
      return false;
    }
  }

  final StreamController<Map<String, Object?>> _events =
      StreamController.broadcast();
  NativeCallable<c.EventCallback>? _callback;

  /// `stack` · `registration` · `call` · `media`.
  Stream<Map<String, Object?>> get events => _events.stream;

  /// 스택을 띄우고 [localPort] 에서 SIP 를 듣는다.
  ///
  /// 이벤트 루프가 돌기 시작할 때까지 기다린다(보통 수 ms).
  void start({required int localPort}) {
    if (_callback != null) return;
    final callback = NativeCallable<c.EventCallback>.listener(_onEvent);
    final err = c.bs_start(localPort, callback.nativeFunction);
    if (err != 0) {
      callback.close();
      throw BaresipException('start', -err);
    }
    _callback = callback;
  }

  /// 로그를 이 파일에 덧붙인다(baresip·libre 로그와 [log] 로 넘긴 줄).
  /// [start] 앞에 불러야 기동 로그까지 남는다.
  static void setLogFile(String path) {
    final err = using(
      (arena) => c.bs_set_log_file(path.toNativeUtf8(allocator: arena)),
    );
    if (err != 0) throw BaresipException('setLogFile', -err);
  }

  /// 앱 쪽 한 줄을 로그 파일에 쓴다.
  static void log(String message) {
    using((arena) => c.bs_log(message.toNativeUtf8(allocator: arena)));
  }

  /// 영상 텍스처를 만들고 스택의 영상 출력을 거기로 잇는다.
  ///
  /// 텍스처를 등록하는 플랫폼 플러그인이 없으면(macOS 밖, 테스트) null.
  Future<BaresipVideoTextures?> attachVideo() async {
    final Map<Object?, Object?>? reply;
    try {
      reply = await _video.invokeMapMethod<Object?, Object?>('attach');
    } on MissingPluginException {
      return null;
    }
    if (reply == null) return null;
    c.bs_set_video_sink(
      Pointer.fromAddress(reply['sink']! as int),
      Pointer.fromAddress(reply['context']! as int),
    );
    return BaresipVideoTextures(
      local: reply['localTextureId']! as int,
      remote: reply['remoteTextureId']! as int,
    );
  }

  /// 카메라 권한. 아직 묻지 않았으면 이때 묻는다.
  ///
  /// `authorized` · `denied` · `restricted` · `unknown`. 플러그인이 없으면 null.
  Future<String?> requestCameraAccess() async {
    try {
      return await _video.invokeMethod<String>('cameraAccess');
    } on MissingPluginException {
      return null;
    }
  }

  /// 지난 통화의 마지막 그림을 텍스처에서 지운다.
  Future<void> clearVideo() async {
    try {
      await _video.invokeMethod<void>('clear');
    } on MissingPluginException {
      // 텍스처가 없으면 지울 것도 없다.
    }
  }

  void stop() {
    c.bs_stop();
    // 루프가 멈추며 보낸 마지막 사건까지 받은 뒤에 닫는다.
    final callback = _callback;
    _callback = null;
    if (callback != null) Timer.run(callback.close);
  }

  void register({
    required String serverIp,
    required int serverPort,
    required String username,
    required String password,
    required String domain,
    String transport = 'udp',
  }) {
    _check(
      'register',
      using((arena) {
        return c.bs_register(
          username.toNativeUtf8(allocator: arena),
          password.toNativeUtf8(allocator: arena),
          domain.toNativeUtf8(allocator: arena),
          serverIp.toNativeUtf8(allocator: arena),
          serverPort,
          transport.toNativeUtf8(allocator: arena),
        );
      }),
    );
  }

  void unregister() => _check('unregister', c.bs_unregister());

  /// 서버에 등록하지 않는 계정(Direct)을 올린다. `sip:<username>@<localIp>` 로
  /// 오는 INVITE 를 받고, 발신도 이 계정으로 나간다. 이전 계정은 걷어 낸다.
  void directStart({required String username, required String localIp}) {
    _check(
      'directStart',
      using(
        (arena) => c.bs_direct_start(
          username.toNativeUtf8(allocator: arena),
          localIp.toNativeUtf8(allocator: arena),
        ),
      ),
    );
  }

  /// Direct 계정을 없앤다.
  void directStop() => _check('directStop', c.bs_direct_stop());

  /// 발신. 통화 번호를 돌려준다.
  int makeCall(String requestUri, {required bool video}) {
    final result = using(
      (arena) =>
          c.bs_call(requestUri.toNativeUtf8(allocator: arena), video ? 1 : 0),
    );
    _check('makeCall', result);
    return result;
  }

  void answer(int callId, {required bool video}) =>
      _check('answer', c.bs_answer(callId, video ? 1 : 0));

  void decline(int callId, {int code = 603}) =>
      _check('decline', c.bs_hangup(callId, code));

  void hangup(int callId) => _check('hangup', c.bs_hangup(callId, 0));

  /// 통화 중 영상을 켜고 끈다(re-INVITE).
  void setVideoEnabled(int callId, bool enabled) =>
      _check('setVideoEnabled', c.bs_set_video(callId, enabled ? 1 : 0));

  void setMute(int callId, bool mute) =>
      _check('setMute', c.bs_mute(callId, mute ? 1 : 0));

  void sendDtmf(int callId, String digits) => _check(
    'sendDtmf',
    using((arena) => c.bs_dtmf(callId, digits.toNativeUtf8(allocator: arena))),
  );

  /// 통화 진단 값. 통화가 없으면 빈 맵.
  Map<String, Object?> getStats(int callId) {
    final raw = c.bs_stats(callId);
    if (raw == nullptr) return const {};
    try {
      return (jsonDecode(raw.toDartString()) as Map).cast<String, Object?>();
    } finally {
      c.bs_free(raw.cast());
    }
  }

  void _onEvent(Pointer<Utf8> json) {
    try {
      final event = (jsonDecode(json.toDartString()) as Map)
          .cast<String, Object?>();
      if (!_events.isClosed) _events.add(event);
    } finally {
      c.bs_free(json.cast());
    }
  }

  static void _check(String operation, int result) {
    if (result < 0) throw BaresipException(operation, -result);
  }
}
