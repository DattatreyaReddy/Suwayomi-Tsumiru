import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tsumiru/src/constants/db_keys.dart';
import 'package:tsumiru/src/features/server_manager/data/local_server_manager.dart';
import 'package:tsumiru/src/features/server_manager/data/server_compatibility_manifest.dart';
import 'package:tsumiru/src/features/server_manager/data/server_runtime.dart';
import 'package:tsumiru/src/features/server_manager/data/server_runtime_installer.dart';

class _FakeProcess implements ServerProcess {
  final _exitCode = Completer<int>();

  @override
  Stream<String> get output => const Stream.empty();

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  bool kill({bool force = false}) {
    if (!_exitCode.isCompleted) _exitCode.complete(0);
    return true;
  }
}

class _FakeRuntime implements ServerRuntime {
  _FakeRuntime(this.process);

  final _FakeProcess process;
  Completer<String>? dataDirectoryCompleter;
  ServerLaunchOptions? options;
  final List<String> versions = ['v2.4.2373'];

  @override
  ServerPlatform? get serverPlatform => ServerPlatform.linuxX64;

  @override
  Future<String> defaultDataDirectory() =>
      dataDirectoryCompleter?.future ?? Future.value('/data/suwayomi');

  @override
  Future<String> versionsDirectory() async => '/install/versions';

  @override
  Future<List<String>> installedVersions() async => versions;

  @override
  Future<ServerProcess> start(ServerLaunchOptions value) async {
    options = value;
    return process;
  }
}

class _FakeInstaller implements ServerRuntimeInstaller {
  _FakeInstaller(this.runtime);

  final _FakeRuntime runtime;
  ServerReleaseAsset? installedAsset;

  @override
  Future<String> install({
    required ServerReleaseAsset asset,
    required String versionsDirectory,
    void Function(ServerInstallProgress progress)? onProgress,
  }) async {
    installedAsset = asset;
    runtime.versions.add(asset.version);
    onProgress?.call(
      const ServerInstallProgress(
        phase: ServerInstallPhase.installing,
        receivedBytes: 4,
        totalBytes: 4,
      ),
    );
    return '$versionsDirectory/${asset.version}';
  }

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('saves and reloads local server settings', () async {
    final preferences = await SharedPreferences.getInstance();
    const configuration = LocalServerConfiguration(
      port: 4321,
      bindToLan: true,
      dataDirectory: '  /data/books  ',
    );

    await configuration.save(preferences);

    final loaded = LocalServerConfiguration.load(preferences);
    expect(loaded.port, 4321);
    expect(loaded.bindToLan, isTrue);
    expect(loaded.dataDirectory, '/data/books');
  });

  test('loads legacy bundled-server settings for migration', () async {
    SharedPreferences.setMockInitialValues({
      'bundledServerPort': 4322,
      'bundledServerBindToLan': true,
      'bundledServerDataDirectory': '/legacy/server-data',
    });
    final preferences = await SharedPreferences.getInstance();

    final loaded = LocalServerConfiguration.load(preferences);

    expect(loaded.port, 4322);
    expect(loaded.bindToLan, isTrue);
    expect(loaded.dataDirectory, '/legacy/server-data');
  });

  test('rejects invalid ports without changing saved settings', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(DBKeys.localServerPort.name, 4567);

    await expectLater(
      const LocalServerConfiguration(
        port: 65536,
        bindToLan: false,
        dataDirectory: '',
      ).save(preferences),
      throwsA(isA<RangeError>()),
    );
    expect(preferences.getInt(DBKeys.localServerPort.name), 4567);
  });

  test('starts with the configured options and stops the process', () async {
    final preferences = await SharedPreferences.getInstance();
    final process = _FakeProcess();
    final runtime = _FakeRuntime(process);
    final manager = LocalServerManager(
      preferences: preferences,
      runtime: runtime,
      httpClient: MockClient((http.Request _) async => http.Response('', 200)),
    );
    addTearDown(manager.dispose);
    await manager.saveConfiguration(
      const LocalServerConfiguration(
        port: 4568,
        bindToLan: true,
        dataDirectory: '',
      ),
    );
    await preferences.setString(DBKeys.localServerVersion.name, 'v2.4.2373');

    await manager.start();

    expect(manager.state, LocalServerState.running);
    expect(manager.isHealthy, isTrue);
    expect(runtime.options?.port, 4568);
    expect(runtime.options?.bindAddress, '0.0.0.0');
    expect(runtime.options?.dataDirectory, '/data/suwayomi');
    expect(runtime.options?.serverDirectory, '/install/versions/v2.4.2373');

    await manager.stop();

    expect(manager.state, LocalServerState.stopped);
    expect(manager.isHealthy, isFalse);
  });

  test('does not launch if shutdown is requested during startup', () async {
    final preferences = await SharedPreferences.getInstance();
    final runtime = _FakeRuntime(_FakeProcess())
      ..dataDirectoryCompleter = Completer<String>();
    final manager = LocalServerManager(
      preferences: preferences,
      runtime: runtime,
      httpClient: MockClient((http.Request _) async => http.Response('', 200)),
    );
    addTearDown(manager.dispose);
    await manager.saveConfiguration(
      const LocalServerConfiguration(
        port: 4568,
        bindToLan: false,
        dataDirectory: '',
      ),
    );
    await preferences.setString(DBKeys.localServerVersion.name, 'v2.4.2373');

    final startup = manager.start();
    await manager.shutdownForAppExit();
    runtime.dataDirectoryCompleter!.complete('/data/suwayomi');
    await startup;

    expect(runtime.options, isNull);
    expect(manager.state, LocalServerState.stopped);
  });

  test(
    'refreshes supported versions and installs the selected version',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final runtime = _FakeRuntime(_FakeProcess())..versions.clear();
      final installer = _FakeInstaller(runtime);
      final manifestClient = MockClient((_) async {
        return http.Response(
          jsonEncode({
            'schemaVersion': 1,
            'latestTestedVersion': 'v2.4.2373',
            'maxSupportedVersion': 'v2.4.2373',
            'releases': [
              {
                'version': 'v2.4.2373',
                'assets': {
                  'linux-x64': {
                    'url':
                        'https://github.com/Suwayomi/Suwayomi-Server/releases/'
                        'download/v2.4.2373/'
                        'Suwayomi-Server-v2.4.2373-linux-x64.tar.gz',
                    'sha256': List.filled(64, 'a').join(),
                  },
                },
              },
            ],
          }),
          200,
        );
      });
      final manager = LocalServerManager(
        preferences: preferences,
        runtime: runtime,
        installer: installer,
        compatibilityRepository: ServerCompatibilityRepository(
          client: manifestClient,
        ),
        httpClient: MockClient(
          (http.Request _) async => http.Response('', 200),
        ),
      );
      addTearDown(manager.dispose);
      addTearDown(manifestClient.close);

      await manager.refreshVersions();
      await manager.installSelectedVersion();

      expect(manager.availableVersions, ['v2.4.2373']);
      expect(manager.installedVersions, ['v2.4.2373']);
      expect(installer.installedAsset?.version, 'v2.4.2373');
      expect(manager.installProgress?.phase, ServerInstallPhase.installing);
      expect(
        preferences.getString(DBKeys.localServerVersion.name),
        'v2.4.2373',
      );
    },
  );
}
