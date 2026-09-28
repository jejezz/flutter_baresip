import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// baresip 과 C 경계(src/baresip_sip.c)를 동적 라이브러리 하나로 묶는다.
///
/// baresip·libre 는 native/build-macos.sh 로 미리 빌드해 둔 정적 라이브러리를
/// 쓴다. 아직 macOS 만 있다 — 다른 플랫폼에서는 아무것도 내지 않고, Dart 쪽은
/// 그 플랫폼에서 이 패키지를 부르지 않는다.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    if (code.targetOS != OS.macOS || code.targetArchitecture != Architecture.arm64) {
      return;
    }

    await CBuilder.library(
      name: 'baresip_sip',
      assetName: 'src/bindings.dart',
      sources: ['src/baresip_sip.c'],
      includes: ['native/macos/include', 'native/macos/include/re'],
      // 상대 경로는 훅의 출력 폴더 기준이 되므로 패키지 경로로 푼다.
      libraryDirectories: [input.packageRoot.resolve('native/macos/lib/').toFilePath()],
      libraries: [
        'baresip',
        're',
        'webrtc-audio-processing',
        'opus',
        'ssl',
        'crypto',
        'z',
        'resolv',
        // webrtc-audio-processing 은 C++ 이다.
        'c++',
      ],
      frameworks: ['AudioToolbox', 'CoreAudio', 'CoreFoundation', 'SystemConfiguration'],
      // libre 를 빌드할 때 쓴 값과 같아야 헤더의 구조체 배치가 맞는다.
      defines: {
        'HAVE_ATOMIC': null,
        'HAVE_PTHREAD': null,
        'HAVE_UNIXSOCK': '1',
        'USE_TLS': null,
        'USE_DTLS': null,
        'USE_OPENSSL': null,
        'RELEASE': null,
        'DARWIN': null,
      },
    ).run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = Level.INFO
        ..onRecord.listen((record) => print(record.message)),
    );
  });
}
