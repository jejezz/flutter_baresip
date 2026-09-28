# flutter_baresip

[baresip](https://github.com/baresip/baresip)(BSD-3)을 `dart:ffi` 와 Dart native
assets 로 감싼 Flutter 데스크톱 SIP 스택. GotDoor SIP 에서 쓴다.

| 플랫폼 | 음성 | 영상 |
| --- | --- | --- |
| macOS (arm64, 12.0+) | Opus·G.711, WebRTC AEC3 | H.264 (VideoToolbox), Flutter 텍스처 |
| Windows (x64) | Opus·G.711, WebRTC AEC3 (wasapi) | 아직 없음 |

## 쓰기

```yaml
dependencies:
  flutter_baresip:
    git:
      url: https://github.com/jejezz/flutter_baresip
      ref: v0.1.1
```

```dart
import 'package:flutter_baresip/flutter_baresip.dart';

if (BaresipSip.isAvailable) {
  final sip = BaresipSip()..start(localPort: 5160);
  sip.events.listen(print); // stack · registration · call · media
  sip.register(serverIp: '192.168.0.10', serverPort: 5060, username: '1001',
      password: '…', domain: 'example.org');
}
```

## 미리 빌드한 라이브러리

baresip·libre·OpenSSL·Opus·webrtc-audio-processing 은 정적 라이브러리로 미리 빌드해
이 저장소의 GitHub Release 에 올려 둔다(`libs-*` 태그). 앱을 빌드할 때 빌드 훅
(`hook/build.dart`)이 `native/prebuilt.json` 에 적힌 zip 을 받아 SHA-256 을 확인하고 쓴다.

공개 저장소의 릴리스라 인증 없이 받는다. 한 번 받은 것은 훅의 공유 폴더에 두고 다시
받지 않는다.

## 라이브러리 다시 빌드

`native/build-macos.sh`(macOS)·`native/build-windows.sh`(Windows, Git Bash + MSVC)가
`native/macos`·`native/windows` 를 만든다. 그 폴더가 있으면 훅이 받지 않고 그걸 쓴다.
baresip 원본에 얹는 고침은 `native/patches/` 에 있다.

올릴 때는 태그를 민다. `.github/workflows/libs.yml` 이 두 플랫폼을 빌드해 릴리스를
만들고, 릴리스의 `SHA256SUMS` 로 `native/prebuilt.json` 을 고친다.

```bash
git tag libs-4.11.0-2 && git push origin libs-4.11.0-2
```

## 라이선스

이 패키지의 코드는 [MIT](LICENSE). 앱에 함께 들어가는 라이브러리: baresip·libre (BSD-3), webrtc-audio-processing (BSD-3),
abseil-cpp (Apache-2.0), OpenSSL (Apache-2.0), Opus (BSD). 원문은 각 zip 의
`LICENSE.*` 에 있다.
