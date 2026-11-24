// Copyright (c) 2026 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'server_compatibility_manifest.dart';

class ServerLaunchOptions {
  const ServerLaunchOptions({
    required this.port,
    required this.bindAddress,
    required this.dataDirectory,
    required this.serverDirectory,
  });

  final int port;
  final String bindAddress;
  final String dataDirectory;
  final String serverDirectory;
}

enum ServerRuntimeError {
  unsupportedPlatform,
  missingInstallation,
}

class ServerRuntimeException implements Exception {
  const ServerRuntimeException(this.code, [this.details]);

  final ServerRuntimeError code;
  final String? details;

  @override
  String toString() =>
      details == null ? 'Local server error: $code' : details!;
}

abstract interface class ServerProcess {
  Stream<String> get output;
  Future<int> get exitCode;
  bool kill({bool force = false});
}

abstract interface class ServerRuntime {
  ServerPlatform? get serverPlatform;
  Future<String> defaultDataDirectory();
  Future<String> versionsDirectory();
  Future<List<String>> installedVersions();
  Future<ServerProcess> start(ServerLaunchOptions options);
}
