// Copyright (c) 2026 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:pub_semver/pub_semver.dart';

import 'server_compatibility_manifest.dart';
import 'server_runtime_base.dart';

ServerRuntime createServerRuntime() => const _IoServerRuntime();

class _IoServerRuntime implements ServerRuntime {
  const _IoServerRuntime();

  @override
  ServerPlatform? get serverPlatform {
    if (Platform.isLinux && Abi.current() == Abi.linuxX64) {
      return ServerPlatform.linuxX64;
    }
    if (Platform.isWindows && Abi.current() == Abi.windowsX64) {
      return ServerPlatform.windowsX64;
    }
    if (Platform.isMacOS) {
      return switch (Abi.current()) {
        Abi.macosX64 => ServerPlatform.macosX64,
        Abi.macosArm64 => ServerPlatform.macosArm64,
        _ => null,
      };
    }
    return null;
  }

  @override
  Future<String> defaultDataDirectory() async {
    final environment = Platform.environment;
    final home = environment['HOME'];
    if (Platform.isWindows) {
      final localAppData = environment['LOCALAPPDATA'];
      if (localAppData == null || localAppData.isEmpty) {
        throw StateError('Windows did not provide LOCALAPPDATA.');
      }
      return path.join(localAppData, 'Tsumiru', 'Suwayomi');
    }
    if (home == null || home.isEmpty) {
      throw StateError('The operating system did not provide a home path.');
    }
    if (Platform.isMacOS) {
      return path.join(
        home,
        'Library',
        'Application Support',
        'Tsumiru',
        'Suwayomi',
      );
    }
    final dataHome = environment['XDG_DATA_HOME'];
    return path.join(
      dataHome == null || dataHome.isEmpty
          ? path.join(home, '.local', 'share')
          : dataHome,
      'tsumiru',
      'Suwayomi',
    );
  }

  @override
  Future<String> versionsDirectory() async {
    final environment = Platform.environment;
    final home = environment['HOME'];
    late final String applicationDataDirectory;
    if (Platform.isWindows) {
      final localAppData = environment['LOCALAPPDATA'];
      if (localAppData == null || localAppData.isEmpty) {
        throw StateError('Windows did not provide LOCALAPPDATA.');
      }
      applicationDataDirectory = path.join(
        localAppData,
        'Tsumiru',
        'SuwayomiServer',
      );
    } else {
      if (home == null || home.isEmpty) {
        throw StateError('The operating system did not provide a home path.');
      }
      if (Platform.isMacOS) {
        applicationDataDirectory = path.join(
          home,
          'Library',
          'Application Support',
          'Tsumiru',
          'SuwayomiServer',
        );
      } else {
        final dataHome = environment['XDG_DATA_HOME'];
        applicationDataDirectory = path.join(
          dataHome == null || dataHome.isEmpty
              ? path.join(home, '.local', 'share')
              : dataHome,
          'tsumiru',
          'suwayomi-server',
        );
      }
    }
    return path.join(applicationDataDirectory, 'versions');
  }

  @override
  Future<List<String>> installedVersions() async {
    final root = Directory(await versionsDirectory());
    if (!await root.exists()) return const [];
    final javaName = Platform.isWindows ? 'java.exe' : 'java';
    final versions = <String>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final version = path.basename(entity.path);
      if (!RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(version)) continue;
      if (await File(
            path.join(entity.path, 'bin', 'Suwayomi-Server.jar'),
          ).exists() &&
          await File(path.join(entity.path, 'jre', 'bin', javaName)).exists() &&
          await Directory(path.join(entity.path, 'jre', 'legal')).exists()) {
        versions.add(version);
      }
    }
    versions.sort(
      (left, right) => Version.parse(right.substring(1)).compareTo(
        Version.parse(left.substring(1)),
      ),
    );
    return List.unmodifiable(versions);
  }

  @override
  Future<ServerProcess> start(ServerLaunchOptions options) async {
    if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
      throw const ServerRuntimeException(
        ServerRuntimeError.unsupportedPlatform,
      );
    }

    final bundleDirectory = Directory(options.serverDirectory);
    final javaName = Platform.isWindows ? 'java.exe' : 'java';
    final javaPath = path.join(
      bundleDirectory.path,
      'jre',
      'bin',
      javaName,
    );
    final serverJar = path.join(
      bundleDirectory.path,
      'bin',
      'Suwayomi-Server.jar',
    );
    if (!await File(javaPath).exists() ||
        !await File(serverJar).exists() ||
        !await Directory(path.join(bundleDirectory.path, 'jre', 'legal'))
            .exists()) {
      throw ServerRuntimeException(
        ServerRuntimeError.missingInstallation,
        'The installed Suwayomi-Server version is incomplete at '
        '${bundleDirectory.path}. Select or install another version.',
      );
    }

    ServerSocket socket;
    try {
      socket = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        options.port,
        shared: false,
      );
    } on SocketException catch (exception) {
      throw StateError(
        'Could not bind to port ${options.port}; it may already be in use. '
        '$exception',
      );
    }
    await socket.close();
    await Directory(options.dataDirectory).create(recursive: true);
    final arguments = [
      '--add-exports=java.desktop/sun.awt=ALL-UNNAMED',
      '-Dsuwayomi.tachidesk.config.server.rootDir=${options.dataDirectory}',
      '-Dsuwayomi.tachidesk.config.server.ip=${options.bindAddress}',
      '-Dsuwayomi.tachidesk.config.server.port=${options.port}',
      '-Dsuwayomi.tachidesk.config.server.initialOpenInBrowserEnabled=false',
      '-Dsuwayomi.tachidesk.config.server.systemTrayEnabled=false',
      '-jar',
      serverJar,
    ];
    final environment = Map<String, String>.of(Platform.environment);
    final abortHandler = path.join(
      bundleDirectory.path,
      'bin',
      'catch_abort.so',
    );
    if (Platform.isLinux && await File(abortHandler).exists()) {
      final currentPreload = environment['LD_PRELOAD'];
      environment['LD_PRELOAD'] =
          currentPreload == null || currentPreload.isEmpty
          ? abortHandler
          : '$abortHandler:$currentPreload';
    }
    final process = await Process.start(
      javaPath,
      arguments,
      workingDirectory: bundleDirectory.path,
      environment: environment,
    );
    return _IoServerProcess(process);
  }
}

class _IoServerProcess implements ServerProcess {
  _IoServerProcess(this._process) {
    _listen(_process.stdout);
    _listen(_process.stderr);
    unawaited(_process.exitCode.then((_) => _finish()));
  }

  final Process _process;
  final StreamController<String> _output = StreamController.broadcast();
  final List<StreamSubscription<String>> _subscriptions = [];

  @override
  Stream<String> get output => _output.stream;

  @override
  Future<int> get exitCode => _process.exitCode;

  void _listen(Stream<List<int>> stream) {
    _subscriptions.add(
      stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_output.add, onError: _output.addError),
    );
  }

  Future<void> _finish() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _output.close();
  }

  @override
  bool kill({bool force = false}) {
    if (Platform.isWindows || force) return _process.kill();
    return _process.kill(ProcessSignal.sigterm);
  }
}
