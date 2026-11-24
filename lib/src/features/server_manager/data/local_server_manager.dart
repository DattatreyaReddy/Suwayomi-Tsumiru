// Copyright (c) 2026 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/legacy.dart' show ChangeNotifierProvider;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../constants/db_keys.dart';
import '../../../global_providers/global_providers.dart';
import 'server_compatibility_manifest.dart';
import 'server_runtime.dart';
import 'server_runtime_installer.dart';

enum LocalServerState { stopped, starting, running, stopping, failed }

@immutable
class LocalServerConfiguration {
  const LocalServerConfiguration({
    required this.port,
    required this.bindToLan,
    required this.dataDirectory,
  });

  factory LocalServerConfiguration.load(SharedPreferences preferences) =>
      LocalServerConfiguration(
        port:
            preferences.getInt(DBKeys.localServerPort.name) ??
            preferences.getInt('bundledServerPort') ??
            DBKeys.localServerPort.initial as int,
        bindToLan:
            preferences.getBool(DBKeys.localServerBindToLan.name) ??
            preferences.getBool('bundledServerBindToLan') ??
            DBKeys.localServerBindToLan.initial as bool,
        dataDirectory:
            preferences.getString(DBKeys.localServerDataDirectory.name) ??
            preferences.getString('bundledServerDataDirectory') ??
            DBKeys.localServerDataDirectory.initial as String,
      );

  final int port;
  final bool bindToLan;
  final String dataDirectory;

  LocalServerConfiguration copyWith({
    int? port,
    bool? bindToLan,
    String? dataDirectory,
  }) => LocalServerConfiguration(
    port: port ?? this.port,
    bindToLan: bindToLan ?? this.bindToLan,
    dataDirectory: dataDirectory ?? this.dataDirectory,
  );

  Future<void> save(SharedPreferences preferences) async {
    if (port < 1 || port > 65535) {
      throw RangeError.range(port, 1, 65535, 'port');
    }
    final trimmedDirectory = dataDirectory.trim();
    if (!await preferences.setInt(DBKeys.localServerPort.name, port) ||
        !await preferences.setBool(
          DBKeys.localServerBindToLan.name,
          bindToLan,
        ) ||
        !await preferences.setString(
          DBKeys.localServerDataDirectory.name,
          trimmedDirectory,
        )) {
      throw StateError('Could not save the local server configuration.');
    }
  }
}

final localServerManagerProvider =
    ChangeNotifierProvider<LocalServerManager>((ref) {
      final manager = LocalServerManager(
        preferences: ref.watch(sharedPreferencesProvider),
      );
      ref.onDispose(manager.dispose);
      return manager;
    });

class LocalServerManager extends ChangeNotifier {
  LocalServerManager({
    required SharedPreferences preferences,
    ServerRuntime? runtime,
    http.Client? httpClient,
    ServerCompatibilityRepository? compatibilityRepository,
    ServerRuntimeInstaller? installer,
  }) : _preferences = preferences,
       _runtime = runtime ?? createServerRuntime(),
       _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null,
       _compatibilityRepository =
           compatibilityRepository ?? ServerCompatibilityRepository(),
       _ownsCompatibilityRepository = compatibilityRepository == null,
       _installer = installer ?? createServerRuntimeInstaller(),
       _ownsInstaller = installer == null,
       configuration = LocalServerConfiguration.load(preferences);

  final SharedPreferences _preferences;
  final ServerRuntime _runtime;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final ServerCompatibilityRepository _compatibilityRepository;
  final bool _ownsCompatibilityRepository;
  final ServerRuntimeInstaller _installer;
  final bool _ownsInstaller;
  final List<String> _logs = [];
  ServerProcess? _process;
  StreamSubscription<String>? _outputSubscription;
  Timer? _healthTimer;
  LocalServerState state = LocalServerState.stopped;
  LocalServerConfiguration configuration;
  ServerCompatibilityManifest? compatibilityManifest;
  List<String> installedVersions = const [];
  String? selectedVersion;
  String? activeVersion;
  ServerInstallProgress? installProgress;
  String? compatibilityError;
  String? installError;
  bool isLoadingVersions = false;
  bool isInstalling = false;
  int? activePort;
  bool isHealthy = false;
  bool _checkingHealth = false;
  bool _stopping = false;
  bool _shutdownRequested = false;
  bool _disposed = false;
  String? error;

  List<String> get logs => List.unmodifiable(_logs);
  List<String> get availableVersions {
    final platform = _runtime.serverPlatform;
    if (platform == null) return const [];
    return compatibilityManifest?.releases
            .where((release) => release.assets.containsKey(platform))
            .map((release) => release.version)
            .toList(growable: false) ??
        const [];
  }
  Future<String> getDefaultDataDirectory() => _runtime.defaultDataDirectory();

  Future<void> refreshVersions() async {
    if (isLoadingVersions) return;
    isLoadingVersions = true;
    compatibilityError = null;
    notifyListeners();
    try {
      installedVersions = await _runtime.installedVersions();
      final savedVersion = _preferences.getString(
        DBKeys.localServerVersion.name,
      );
      if (savedVersion != null && installedVersions.contains(savedVersion)) {
        selectedVersion = savedVersion;
      }
      compatibilityManifest = await _compatibilityRepository.fetch();
      if (savedVersion != null &&
          (availableVersions.contains(savedVersion) ||
              installedVersions.contains(savedVersion))) {
        selectedVersion = savedVersion;
      } else {
        selectedVersion =
            availableVersions.contains(
              compatibilityManifest!.latestTestedVersion,
            )
            ? compatibilityManifest!.latestTestedVersion
            : availableVersions.firstOrNull;
      }
    } catch (exception) {
      compatibilityError = exception.toString();
    } finally {
      isLoadingVersions = false;
      notifyListeners();
    }
  }

  Future<void> selectVersion(String version) async {
    if (!availableVersions.contains(version) &&
        !installedVersions.contains(version)) {
      throw StateError('Suwayomi-Server $version is not supported.');
    }
    selectedVersion = version;
    if (!await _preferences.setString(DBKeys.localServerVersion.name, version)) {
      throw StateError('Could not save the selected server version.');
    }
    notifyListeners();
  }

  Future<void> installSelectedVersion() async {
    if (isInstalling ||
        state == LocalServerState.starting ||
        state == LocalServerState.running ||
        state == LocalServerState.stopping) {
      throw StateError('Stop the local server before installing a version.');
    }
    final version = selectedVersion;
    final manifest = compatibilityManifest;
    if (version == null || manifest == null) {
      throw StateError('Load the supported server versions before installing.');
    }
    final platform = _runtime.serverPlatform;
    if (platform == null) {
      throw UnsupportedError(
        'This desktop architecture is not supported by the local server.',
      );
    }
    final asset = manifest.assetFor(version, platform);
    if (asset == null) {
      throw StateError(
        'Suwayomi-Server $version is not available for ${platform.manifestKey}.',
      );
    }

    isInstalling = true;
    installError = null;
    installProgress = null;
    notifyListeners();
    try {
      final versionsDirectory = await _runtime.versionsDirectory();
      await _installer.install(
        asset: asset,
        versionsDirectory: versionsDirectory,
        onProgress: (progress) {
          installProgress = progress;
          notifyListeners();
        },
      );
      installedVersions = await _runtime.installedVersions();
      if (!installedVersions.contains(version)) {
        throw StateError(
          'Suwayomi-Server $version was installed but could not be verified.',
        );
      }
      if (!await _preferences.setString(DBKeys.localServerVersion.name, version)) {
        throw StateError('Could not save the installed server version.');
      }
      selectedVersion = version;
      _appendLog('Installed Suwayomi-Server $version.');
    } catch (exception) {
      installError = exception.toString();
      rethrow;
    } finally {
      isInstalling = false;
      notifyListeners();
    }
  }

  Future<void> saveConfiguration(LocalServerConfiguration next) async {
    await next.save(_preferences);
    configuration = next.copyWith(dataDirectory: next.dataDirectory.trim());
    notifyListeners();
  }

  Future<void> start() async {
    if (state == LocalServerState.starting ||
        state == LocalServerState.running ||
        state == LocalServerState.stopping ||
        isInstalling) {
      return;
    }
    if (configuration.port < 1 || configuration.port > 65535) {
      throw RangeError.range(configuration.port, 1, 65535, 'port');
    }

    _shutdownRequested = false;
    error = null;
    isHealthy = false;
    state = LocalServerState.starting;
    _appendLog('Starting Suwayomi-Server...');
    notifyListeners();
    try {
      final version =
          selectedVersion ??
          _preferences.getString(DBKeys.localServerVersion.name);
      if (version == null || version.isEmpty) {
        throw StateError('Select and install a Suwayomi-Server version first.');
      }
      installedVersions = await _runtime.installedVersions();
      if (_shutdownRequested || _disposed) {
        state = LocalServerState.stopped;
        notifyListeners();
        return;
      }
      if (!installedVersions.contains(version)) {
        throw StateError(
          'Suwayomi-Server $version is not installed. Download it before starting.',
        );
      }
      activeVersion = version;
      final dataDirectory = configuration.dataDirectory.isEmpty
          ? await _runtime.defaultDataDirectory()
          : configuration.dataDirectory;
      final versionsDirectory = await _runtime.versionsDirectory();
      if (_shutdownRequested || _disposed) {
        activeVersion = null;
        state = LocalServerState.stopped;
        notifyListeners();
        return;
      }
      final process = await _runtime.start(
        ServerLaunchOptions(
          port: configuration.port,
          bindAddress: configuration.bindToLan ? '0.0.0.0' : '127.0.0.1',
          dataDirectory: dataDirectory,
          serverDirectory: path.join(versionsDirectory, version),
        ),
      );
      _process = process;
      activePort = configuration.port;
      _outputSubscription = process.output.listen(_appendLog);
      unawaited(_watchProcess(process));

      if (_shutdownRequested || _disposed) {
        _stopping = true;
        state = LocalServerState.stopping;
        process.kill(force: true);
        await process.exitCode.timeout(const Duration(seconds: 5));
        if (identical(_process, process)) {
          _process = null;
          activePort = null;
          activeVersion = null;
        }
        _stopping = false;
        state = LocalServerState.stopped;
        notifyListeners();
        return;
      }

      const startupTimeout = Duration(seconds: 60);
      final startupTimer = Stopwatch()..start();
      while (startupTimer.elapsed < startupTimeout) {
        if (!identical(_process, process) ||
            state != LocalServerState.starting) {
          return;
        }
        final healthy = await _probeServer(configuration.port);
        if (!identical(_process, process) ||
            state != LocalServerState.starting) {
          return;
        }
        if (healthy) {
          state = LocalServerState.running;
          isHealthy = true;
          _healthTimer = Timer.periodic(
            const Duration(seconds: 5),
            (_) => unawaited(_refreshHealth()),
          );
          _appendLog('Suwayomi-Server API is ready.');
          notifyListeners();
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      throw TimeoutException(
        'The server process started, but its API did not become ready within '
        '${startupTimeout.inSeconds} seconds.',
      );
    } catch (exception) {
      error = exception.toString();
      state = LocalServerState.failed;
      _appendLog('Server startup failed: $exception');
      notifyListeners();
      final process = _process;
      if (process != null) {
        _process = null;
        activePort = null;
        activeVersion = null;
        await _outputSubscription?.cancel();
        _outputSubscription = null;
        process.kill(force: true);
        try {
          await process.exitCode.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          final terminationError =
              '$exception; the server process could not be terminated.';
          error = terminationError;
          _appendLog(terminationError);
          throw StateError(terminationError);
        }
      }
      rethrow;
    }
  }

  Future<void> stop() async {
    _shutdownRequested = true;
    final process = _process;
    if (process == null) {
      state = LocalServerState.stopped;
      isHealthy = false;
      error = null;
      notifyListeners();
      return;
    }
    _stopping = true;
    state = LocalServerState.stopping;
    isHealthy = false;
    _healthTimer?.cancel();
    _appendLog('Stopping Suwayomi-Server...');
    notifyListeners();
    try {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        process.kill(force: true);
        await process.exitCode.timeout(const Duration(seconds: 5));
      }
      if (identical(_process, process)) {
        _process = null;
        activePort = null;
        activeVersion = null;
        state = LocalServerState.stopped;
        _appendLog('Suwayomi-Server stopped.');
        notifyListeners();
      }
    } catch (exception) {
      error = 'Could not stop Suwayomi-Server: $exception';
      state = LocalServerState.failed;
      notifyListeners();
      rethrow;
    } finally {
      _stopping = false;
    }
  }

  Future<void> _watchProcess(ServerProcess process) async {
    final exitCode = await process.exitCode;
    if (_disposed) return;
    if (!identical(_process, process)) return;
    _healthTimer?.cancel();
    _healthTimer = null;
    _process = null;
    activePort = null;
    activeVersion = null;
    isHealthy = false;
    if (_stopping) {
      state = LocalServerState.stopped;
      _appendLog('Suwayomi-Server stopped.');
    } else {
      state = exitCode == 0
          ? LocalServerState.stopped
          : LocalServerState.failed;
      if (exitCode != 0) {
        error = 'Suwayomi-Server exited with code $exitCode.';
        _appendLog(error!);
      }
    }
    notifyListeners();
  }

  Future<void> _refreshHealth() async {
    if (_checkingHealth || state != LocalServerState.running) return;
    _checkingHealth = true;
    try {
      final port = activePort;
      if (port == null) return;
      final healthy = await _probeServer(port);
      if (state == LocalServerState.running && healthy != isHealthy) {
        isHealthy = healthy;
        notifyListeners();
      }
    } finally {
      _checkingHealth = false;
    }
  }

  Future<bool> _probeServer(int port) async {
    try {
      final response = await _httpClient
          .post(
            Uri(
              scheme: 'http',
              host: '127.0.0.1',
              port: port,
              path: '/api/graphql',
            ),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode(const {'query': '{ __typename }'}),
          )
          .timeout(const Duration(seconds: 2));
      return response.statusCode == 200 ||
          response.statusCode == 401 ||
          response.statusCode == 403;
    } on Exception {
      return false;
    }
  }

  void _appendLog(String line) {
    if (_disposed) return;
    _logs.add(line);
    if (_logs.length > 500) _logs.removeRange(0, _logs.length - 500);
    notifyListeners();
  }

  Future<void> shutdownForAppExit() => stop();

  @override
  void dispose() {
    _disposed = true;
    _healthTimer?.cancel();
    unawaited(_outputSubscription?.cancel());
    if (_ownsHttpClient) _httpClient.close();
    if (_ownsCompatibilityRepository) _compatibilityRepository.close();
    if (_ownsInstaller) _installer.close();
    _process?.kill(force: true);
    super.dispose();
  }
}
