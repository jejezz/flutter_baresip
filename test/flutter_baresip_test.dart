@TestOn('mac-os')
library;

import 'dart:io';

import 'package:flutter_baresip/flutter_baresip.dart';
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

  test('Direct 계정은 REGISTER 없이 발신할 수 있고 정지하면 없어진다', () async {
    // baresip 은 루프백을 로컬 주소로 받아 주지 않는다. 실제 LAN 주소가 필요하다.
    final lan = [
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4))
        for (final a in i.addresses)
          if (!a.isLoopback && !a.address.startsWith('169.254.')) a.address,
    ];
    if (lan.isEmpty) {
      markTestSkipped('LAN 주소가 없다');
      return;
    }
    final ip = lan.first;
    final sip = BaresipSip();
    final events = <Map<String, Object?>>[];
    final sub = sip.events.listen(events.add);

    sip.start(localPort: 0);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // 계정이 없으면 발신이 ENOENT 로 막힌다.
    expect(
      () => sip.makeCall('sip:1002@$ip:9', video: false),
      throwsA(isA<BaresipException>()),
    );

    sip.directStart(username: '1001', localIp: ip);
    final id = sip.makeCall('sip:1002@$ip:9', video: false);
    expect(id, greaterThan(0));
    sip.hangup(id);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(events.where((e) => e['type'] == 'registration'), isEmpty);

    sip.directStop();
    expect(
      () => sip.makeCall('sip:1002@$ip:9', video: false),
      throwsA(isA<BaresipException>()),
    );

    sip.stop();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await sub.cancel();
  });
}
