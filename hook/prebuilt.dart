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
/// 저장소가 비공개라 받을 때 토큰이 필요하다. FLUTTER_BARESIP_TOKEN,
/// GITHUB_TOKEN 을 차례로 보고 없으면 `gh auth token` 을 쓴다.
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

Future<List<int>> _download(String repository, String tag, String name) async {
  final token = await _token();
  final client = HttpClient();
  try {
    // 릴리스에서 자산 번호를 찾는다.
    final release = await _getJson(
      client,
      Uri.parse('https://api.github.com/repos/$repository/releases/tags/$tag'),
      token,
    );
    final assets = (release['assets'] as List).cast<Map>();
    final asset = assets.firstWhere(
      (a) => a['name'] == name,
      orElse: () => throw StateError(
        'flutter_baresip: 릴리스 $tag 에 $name 이 없다',
      ),
    );

    // 자산 API 는 서명된 저장소 주소로 넘겨 준다. 그쪽에 Authorization 을
    // 같이 보내면 거절하므로 넘겨 주는 걸 직접 따라간다.
    final request = await client.getUrl(Uri.parse(asset['url'] as String));
    request.followRedirects = false;
    request.headers.set('Accept', 'application/octet-stream');
    if (token != null) request.headers.set('Authorization', 'Bearer $token');
    var response = await request.close();
    if (response.isRedirect) {
      final location = response.headers.value('location')!;
      await response.drain<void>();
      response = await (await client.getUrl(Uri.parse(location))).close();
    }
    if (response.statusCode != 200) {
      throw StateError(
        'flutter_baresip: $name 을 받지 못했다 (HTTP ${response.statusCode})',
      );
    }
    final builder = BytesBuilder(copy: false);
    await response.forEach(builder.add);
    return builder.takeBytes();
  } finally {
    client.close();
  }
}

Future<Map> _getJson(HttpClient client, Uri uri, String? token) async {
  final request = await client.getUrl(uri);
  request.headers.set('Accept', 'application/vnd.github+json');
  if (token != null) request.headers.set('Authorization', 'Bearer $token');
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode != 200) {
    throw StateError(
      'flutter_baresip: $uri → HTTP ${response.statusCode}. 비공개 저장소라면 '
      'FLUTTER_BARESIP_TOKEN 을 두거나 `gh auth login` 을 한다.',
    );
  }
  return jsonDecode(body) as Map;
}

Future<String?> _token() async {
  for (final name in ['FLUTTER_BARESIP_TOKEN', 'GITHUB_TOKEN']) {
    final value = Platform.environment[name];
    if (value != null && value.isNotEmpty) return value;
  }
  try {
    final result = await Process.run('gh', ['auth', 'token']);
    final value = (result.stdout as String).trim();
    if (result.exitCode == 0 && value.isNotEmpty) return value;
  } on ProcessException {
    // gh 가 없다.
  }
  return null;
}
