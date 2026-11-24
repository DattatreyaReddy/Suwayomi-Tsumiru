import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;
import 'package:tsumiru/src/features/server_manager/data/server_compatibility_manifest.dart';
import 'package:tsumiru/src/features/server_manager/data/server_runtime_installer_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'verifies and installs a server archive without touching user data',
    () async {
      final archiveBytes = _serverArchive();
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'server-installer-test',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final versionsDirectory = Directory(
        path.join(temporaryDirectory.path, 'versions'),
      );
      final userDataDirectory = Directory(
        path.join(temporaryDirectory.path, 'user-data'),
      );
      await userDataDirectory.create();
      await File(
        path.join(userDataDirectory.path, 'library.db'),
      ).writeAsString('preserve');

      final client = MockClient((request) async {
        if (request.url.host == 'raw.githubusercontent.com') {
          return http.Response('Mozilla Public License, v. 2.0.', 200);
        }
        return http.Response.bytes(archiveBytes, 200);
      });
      final installer = IoServerRuntimeInstaller(client: client);
      addTearDown(client.close);
      addTearDown(installer.close);
      final installation = await installer.install(
        asset: _asset(sha256.convert(archiveBytes).toString()),
        versionsDirectory: versionsDirectory.path,
      );

      expect(
        File(
          path.join(installation, 'bin', 'Suwayomi-Server.jar'),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(path.join(installation, 'jre', 'bin', 'java.exe')).existsSync(),
        isTrue,
      );
      expect(
        File(
          path.join(installation, 'Suwayomi-Server-LICENSE.txt'),
        ).existsSync(),
        isTrue,
      );
      expect(
        await File(
          path.join(userDataDirectory.path, 'library.db'),
        ).readAsString(),
        'preserve',
      );
    },
  );

  test(
    'extracts Linux tar.gz releases and preserves Java executable mode',
    () async {
      final serverArchive = Archive()
        ..addFile(ArchiveFile('server/bin/Suwayomi-Server.jar', 3, [1, 2, 3]))
        ..addFile(
          ArchiveFile('server/jre/bin/java', 4, [4, 5, 6, 7])..mode = 0x1ed,
        )
        ..addFile(ArchiveFile.directory('server/jre/legal'));
      final archiveBytes = GZipEncoder().encode(
        TarEncoder().encode(serverArchive),
      );
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'server-installer-tar-test',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final client = MockClient((request) async {
        if (request.url.host == 'raw.githubusercontent.com') {
          return http.Response('Mozilla Public License, v. 2.0.', 200);
        }
        return http.Response.bytes(archiveBytes, 200);
      });
      final installer = IoServerRuntimeInstaller(client: client);
      addTearDown(client.close);
      addTearDown(installer.close);

      final installation = await installer.install(
        asset: ServerReleaseAsset(
          version: 'v2.4.2373',
          platform: ServerPlatform.linuxX64,
          uri: Uri.parse(
            'https://github.com/Suwayomi/Suwayomi-Server/releases/download/'
            'v2.4.2373/Suwayomi-Server-v2.4.2373-linux-x64.tar.gz',
          ),
          sha256: sha256.convert(archiveBytes).toString(),
        ),
        versionsDirectory: path.join(temporaryDirectory.path, 'versions'),
      );

      final javaFile = File(path.join(installation, 'jre', 'bin', 'java'));
      expect(javaFile.existsSync(), isTrue);
      if (!Platform.isWindows) {
        expect(javaFile.statSync().mode & 0x49, 0x49);
      }
    },
  );

  test('rejects a checksum mismatch and removes staging files', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'server-installer-mismatch-test',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final versionsDirectory = Directory(
      path.join(temporaryDirectory.path, 'versions'),
    );
    final client = MockClient(
      (_) async => http.Response.bytes(_serverArchive(), 200),
    );
    final installer = IoServerRuntimeInstaller(client: client);
    addTearDown(client.close);
    addTearDown(installer.close);

    await expectLater(
      installer.install(
        asset: _asset('0' * 64),
        versionsDirectory: versionsDirectory.path,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(await versionsDirectory.list().toList(), isEmpty);
  });

  test(
    'rejects archive paths that escape the installation directory',
    () async {
      final maliciousArchive = ZipEncoder().encode(
        Archive()
          ..addFile(ArchiveFile('../outside.txt', 7, 'outside'.codeUnits)),
      );
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'server-installer-path-test',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final versionsDirectory = Directory(
        path.join(temporaryDirectory.path, 'versions'),
      );
      final client = MockClient(
        (_) async => http.Response.bytes(maliciousArchive, 200),
      );
      final installer = IoServerRuntimeInstaller(client: client);
      addTearDown(client.close);
      addTearDown(installer.close);

      await expectLater(
        installer.install(
          asset: _asset(sha256.convert(maliciousArchive).toString()),
          versionsDirectory: versionsDirectory.path,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        File(path.join(temporaryDirectory.path, 'outside.txt')).existsSync(),
        isFalse,
      );
      expect(await versionsDirectory.list().toList(), isEmpty);
    },
  );
}

ServerReleaseAsset _asset(String checksum) => ServerReleaseAsset(
  version: 'v2.4.2373',
  platform: ServerPlatform.windowsX64,
  uri: Uri.parse(
    'https://github.com/Suwayomi/Suwayomi-Server/releases/download/v2.4.2373/'
    'Suwayomi-Server-v2.4.2373-windows-x64.zip',
  ),
  sha256: checksum,
);

List<int> _serverArchive() {
  final archive = Archive()
    ..addFile(ArchiveFile('server/bin/Suwayomi-Server.jar', 3, [1, 2, 3]))
    ..addFile(ArchiveFile('server/jre/bin/java.exe', 3, [4, 5, 6]))
    ..addFile(ArchiveFile.directory('server/jre/legal'));
  return ZipEncoder().encode(archive);
}
