import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'src/bindings.dart' as c;

/// baresip 스택이 돌려준 오류. [code] 는 errno 값이다.
class BaresipException implements Exception {
  const BaresipException(this.operation, this.code);

  final String operation;
  final int code;

  @override
  String toString() => 'BaresipException($operation, errno $code)';
}

/// baresip 을 부르는 얇은 껍데기.
///
/// 사건의 모양(`type` 으로 갈래를 나눈 맵)은 kamailio_sip 플러그인과 같다.
/// 상태를 들고 있지 않으므로 상태 머신은 앱 쪽(`SipService`)이 맡는다.
///
/// 스택은 프로세스에 하나뿐이다.
class BaresipSip {
  final StreamController<Map<String, Object?>> _events = StreamController.broadcast();
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

  /// 발신. 통화 번호를 돌려준다.
  int makeCall(String requestUri, {required bool video}) {
    final result = using(
      (arena) => c.bs_call(requestUri.toNativeUtf8(allocator: arena), video ? 1 : 0),
    );
    _check('makeCall', result);
    return result;
  }

  void answer(int callId, {required bool video}) =>
      _check('answer', c.bs_answer(callId, video ? 1 : 0));

  void decline(int callId, {int code = 603}) => _check('decline', c.bs_hangup(callId, code));

  void hangup(int callId) => _check('hangup', c.bs_hangup(callId, 0));

  void setMute(int callId, bool mute) => _check('setMute', c.bs_mute(callId, mute ? 1 : 0));

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
      final event = (jsonDecode(json.toDartString()) as Map).cast<String, Object?>();
      if (!_events.isClosed) _events.add(event);
    } finally {
      c.bs_free(json.cast());
    }
  }

  static void _check(String operation, int result) {
    if (result < 0) throw BaresipException(operation, -result);
  }
}
