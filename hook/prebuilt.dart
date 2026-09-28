import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';

/// 미리 빌드한 baresip 정적 라이브러리가 있는 폴더를 돌려준다.
///
/// 1. 패키지 안의 native/[platform]/lib — 라이브러리를 직접 빌드하며 고칠 때.
/// 2. native/prebuilt.json 이 가리키는 GitHub Release 의 zip — 받아서
///    SHA-256 을 확인하고 훅의 공유 폴더에 풀어 둔다. 한 번 받으면 다시 받지
///    않는다.
///
Future<Uri> resolveNativeDir(
  BuildInput input,
  String platform,
  Logger logger,
) async {
  final local = input.packageRoot.resolve('native/$platform/');
  if (Directory.fromUri(local.resolve('lib/')).existsSync()) {
    logger.info('flutter_baresip: 로컬 라이브러리를 쓴다 (${local.toFilePath()})');
    return local;
  }

  final manifestFile = File.fromUri(
    input.packageRoot.resolve('native/prebuilt.json'),
  );
  final manifest = jsonDecode(manifestFile.readAsStringSync()) as Map;
  final repository = manifest['repository'] as String;
  final tag = manifest['tag'] as String;
  final asset = (manifest['assets'] as Map)[platform] as Map?;
  if (asset == null) {
    throw StateError('flutter_baresip: $platform 용 미리 빌드한 라이브러리가 없다');
  }
  final name = asset['name'] as String;
  final sha256Hex = (asset['sha256'] as String).toLowerCase();

  final dest = input.outputDirectoryShared.resolve('prebuilt/$tag/$platform/');
  final done = File.fromUri(dest.resolve('.sha256'));
  if (done.existsSync() && done.readAsStringSync().trim() == sha256Hex) {
    return dest;
  }

  logger.info('flutter_baresip: $repository@$tag 에서 $name 을 받는다');
  final bytes = await _download(repository, tag, name);
  final actual = sha256.convert(bytes).toString();
  if (actual != sha256Hex) {
    throw StateError(
      'flutter_baresip: $name 의 SHA-256 이 맞지 않는다 '
      '(기대 $sha256Hex, 받은 것 $actual)',
    );
  }

  final dir = Directory.fromUri(dest);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  final zip = File.fromUri(dest.resolve('../$name'));
  zip.writeAsBytesSync(bytes);
  // macOS 와 Windows 10+ 의 tar(bsdtar)는 zip 을 푼다.
  final result = await Process.run('tar', [
    '-xf',
    zip.path,
    '-C',
    dir.path,
  ]);
  if (result.exitCode != 0) {
    throw StateError('flutter_baresip: $name 을 풀지 못했다: ${result.stderr}');
  }
  zip.deleteSync();
  done.writeAsStringSync(sha256Hex);
  return dest;
}

/// 공개 저장소의 릴리스 파일은 인증 없이, API 호출 한도 없이 받는다.
Future<List<int>> _download(String repository, String tag, String name) async {
  final uri = Uri.parse(
    'https://github.com/$repository/releases/download/$tag/$name',
  );
  final client = HttpClient();
  try {
    // 저장소 서버로 넘겨 주는 것은 HttpClient 가 따라간다.
    final response = await (await client.getUrl(uri)).close();
    if (response.statusCode != 200) {
      throw StateError(
        'flutter_baresip: $uri 을 받지 못했다 (HTTP ${response.statusCode})',
      );
    }
    final builder = BytesBuilder(copy: false);
    await response.forEach(builder.add);
    return builder.takeBytes();
  } finally {
    client.close();
  }
}
