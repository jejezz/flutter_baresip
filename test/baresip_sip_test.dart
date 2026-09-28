@TestOn('mac-os')
library;

import 'dart:io';

import 'package:baresip_sip/baresip_sip.dart';
import 'package:flutter_test/flutter_test.dart';

/// 실제 스택을 띄워 C 경계가 도는지만 본다. 서버는 없다 — 아무도 듣지 않는
/// 포트로 REGISTER 를 보내 실패 사건이 올라오는지 확인한다.
void main() {
  test('기동 → 등록 실패 → 정지', () async {
    // 빈 UDP 포트 하나를 빌려 서버 자리로 쓴다(아무 응답도 하지 않는다).
    final silent = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sip = BaresipSip();
    final events = <Map<String, Object?>>[];
    final sub = sip.events.listen(events.add);

    sip.start(localPort: 0);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(events.first, containsPair('state', 'started'));

    // TCP 로 보내면 연결 거부로 바로 실패한다.
    sip.register(
      serverIp: '127.0.0.1',
      serverPort: silent.port,
      username: '1001',
      password: 'secret',
      domain: 'example.test',
      transport: 'tcp',
    );
    final failed = await sip.events
        .firstWhere((e) => e['type'] == 'registration')
        .timeout(const Duration(seconds: 10));
    expect(failed['code'], isNot(200));
    expect(failed['expiration'], 0);

    expect(() => sip.hangup(99), throwsA(isA<BaresipException>()));
    expect(sip.getStats(99), isEmpty);

    sip.stop();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(events.last, containsPair('state', 'stopped'));

    await sub.cancel();
    silent.close();
  });
}
