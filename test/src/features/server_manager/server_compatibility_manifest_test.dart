import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsumiru/src/features/server_manager/data/server_compatibility_manifest.dart';

void main() {
  test('parses the checked-in manifest and resolves platform assets', () async {
    final source = await File(
      'server-manager/compatibility.json',
    ).readAsString();
    final manifest = ServerCompatibilityManifest.parse(source);

    expect(manifest.latestTestedVersion, 'v2.4.2373');
    expect(manifest.maxSupportedVersion, 'v2.4.2373');
    expect(
      manifest.assetFor('v2.4.2373', ServerPlatform.linuxX64)?.uri.host,
      'github.com',
    );
    expect(
      manifest
          .assetFor('v2.4.2373', ServerPlatform.macosArm64)
          ?.sha256
          .length,
      64,
    );
  });

  test('rejects server releases above the manifest support ceiling', () {
    final source = _manifest(
      latestTestedVersion: 'v2.4.2',
      maxSupportedVersion: 'v2.4.1',
      version: 'v2.4.2',
    );

    expect(
      () => ServerCompatibilityManifest.parse(source),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects assets outside the official release host and path', () {
    final source = _manifest(
      latestTestedVersion: 'v2.4.1',
      maxSupportedVersion: 'v2.4.1',
      version: 'v2.4.1',
      url:
          'https://example.com/Suwayomi-Server-v2.4.1-linux-x64.tar.gz',
    );

    expect(
      () => ServerCompatibilityManifest.parse(source),
      throwsA(isA<FormatException>()),
    );
  });
}

String _manifest({
  required String latestTestedVersion,
  required String maxSupportedVersion,
  required String version,
  String? url,
}) =>
    '''
{
  "schemaVersion": 1,
  "latestTestedVersion": "$latestTestedVersion",
  "maxSupportedVersion": "$maxSupportedVersion",
  "releases": [
    {
      "version": "$version",
      "assets": {
        "linux-x64": {
          "url": "${url ?? 'https://github.com/Suwayomi/Suwayomi-Server/releases/download/$version/Suwayomi-Server-$version-linux-x64.tar.gz'}",
          "sha256": "${'a' * 64}"
        }
      }
    }
  ]
}
''';
