import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

import 'prebuilt.dart';

/// baresip 과 C 경계(src/)를 동적 라이브러리 하나로 묶는다.
///
/// baresip·libre 와 의존 라이브러리는 미리 빌드한 정적 라이브러리를 쓴다.
///   macOS(arm64)   — native/build-macos.sh
///   Windows(x64)   — native/build-windows.sh
/// 두 스크립트의 결과는 이 저장소의 GitHub Release 에 올려 두고, 이 훅이
/// native/prebuilt.json 에 적힌 것을 받아 쓴다. 패키지 안에 native/<플랫폼>/lib
/// 가 있으면(라이브러리를 직접 빌드하며 고칠 때) 그걸 먼저 쓴다.
///
/// 그 밖의 플랫폼에서는 아무것도 내지 않는다. Dart 쪽은 `BaresipSip.isAvailable`
/// 로 알아본다.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final platform = switch ((code.targetOS, code.targetArchitecture)) {
      (OS.macOS, Architecture.arm64) => 'macos',
      (OS.windows, Architecture.x64) => 'windows',
      _ => null,
    };
    if (platform == null) return;

    final logger = Logger('')
      ..level = Level.INFO
      ..onRecord.listen((record) => print(record.message));

    final native = await resolveNativeDir(input, platform, logger);
    final builder = switch (platform) {
      'macos' => _macOS(native),
      _ => _windows(native),
    };

    await builder.run(input: input, output: output, logger: logger);
  });
}

/// macos/Runner.xcodeproj 의 MACOSX_DEPLOYMENT_TARGET 과 같아야 한다.
const _minMacOS = '12.0';

CBuilder _macOS(Uri native) => CBuilder.library(
  name: 'flutter_baresip',
  assetName: 'src/bindings.dart',
  sources: [
    'src/baresip_sip.c',
    'src/vt_h264.c',
    'src/video_out.c',
    'src/log_file.c',
  ],
  includes: [
    native.resolve('include/').toFilePath(),
    native.resolve('include/re/').toFilePath(),
  ],
  libraryDirectories: [native.resolve('lib/').toFilePath()],
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
  frameworks: [
    'AudioToolbox',
    'CoreAudio',
    'CoreFoundation',
    'SystemConfiguration',
    // 영상: 카메라(avcapture)와 H.264(vt_h264.c).
    'AVFoundation',
    'CoreMedia',
    'CoreVideo',
    'Foundation',
    'VideoToolbox',
  ],
  // Flutter 는 훅에 macOS 13 을 넘기지만 앱(Runner)의 최소 버전은 12.0 이다.
  // 그대로 두면 macOS 12 에서 앱은 떠도 이 라이브러리를 싣지 못한다.
  // 뒤에 오는 값이 이기므로 앱과 같은 값으로 덮는다. 정적 라이브러리들도
  // native/build-macos.sh 의 MIN_MACOS(12.0)로 빌드되어 있다.
  flags: ['-mmacos-version-min=$_minMacOS'],
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
);

CBuilder _windows(Uri native) {
  // build-windows.sh 가 baresip 을 빌드한 매크로를 남겨 둔다. 헤더의 구조체
  // 배치가 여기에 달려 있으므로 그대로 따른다.
  final definesFile = File.fromUri(native.resolve('defines.txt'));
  final defines = <String, String?>{
    for (final line in definesFile.readAsLinesSync())
      if (line.trim().isNotEmpty)
        line.split('=').first.trim(): line.contains('=')
            ? line.substring(line.indexOf('=') + 1).trim()
            : null,
  };

  return CBuilder.library(
    name: 'flutter_baresip',
    assetName: 'src/bindings.dart',
    // 영상(H.264)은 아직 없다. video_out.c 는 싱크가 없으면 아무 일도 하지 않는다.
    sources: ['src/baresip_sip.c', 'src/video_out.c', 'src/log_file.c'],
    includes: [
      native.resolve('include/').toFilePath(),
      native.resolve('include/re/').toFilePath(),
    ],
    libraryDirectories: [native.resolve('lib/').toFilePath()],
    libraries: [
      'baresip',
      're-static',
      'webrtc-audio-processing',
      'opus',
      'libssl',
      'libcrypto',
      // libre·baresip·OpenSSL·wasapi 가 쓰는 시스템 라이브러리.
      'ws2_32',
      'wsock32',
      'iphlpapi',
      'qwave',
      'dbghelp',
      'winmm',
      'gdi32',
      'crypt32',
      'strmiids',
      'ole32',
      'oleaut32',
      'advapi32',
      'user32',
      'shell32', // libre fs_gethome → SHGetFolderPathA
      'bcrypt',
      'avrt',
      'ksuser',
    ],
    // 정적 라이브러리를 모두 동적 CRT 로 빌드했다. cl 은 따로 말하지 않으면 /MT 다.
    flags: ['/MD'],
    std: 'c11',
    defines: defines,
  );
}
