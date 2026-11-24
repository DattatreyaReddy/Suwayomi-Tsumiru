// Copyright (c) 2026 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'server_compatibility_manifest.dart';
import 'server_runtime_base.dart';

ServerRuntime createServerRuntime() => const _UnsupportedServerRuntime();

class _UnsupportedServerRuntime implements ServerRuntime {
  const _UnsupportedServerRuntime();

  @override
  ServerPlatform? get serverPlatform => null;

  @override
  Future<String> defaultDataDirectory() => Future.error(
    const ServerRuntimeException(
      ServerRuntimeError.unsupportedPlatform,
    ),
  );

  @override
  Future<String> versionsDirectory() => Future.error(
    const ServerRuntimeException(ServerRuntimeError.unsupportedPlatform),
  );

  @override
  Future<List<String>> installedVersions() => Future.error(
    const ServerRuntimeException(ServerRuntimeError.unsupportedPlatform),
  );

  @override
  Future<ServerProcess> start(ServerLaunchOptions options) =>
      Future.error(
        const ServerRuntimeException(
          ServerRuntimeError.unsupportedPlatform,
        ),
      );
}
