// Copyright (c) 2026 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'server_compatibility_manifest.dart';
import 'server_runtime_installer_base.dart';

ServerRuntimeInstaller createServerRuntimeInstaller() =>
    const _UnsupportedServerRuntimeInstaller();

class _UnsupportedServerRuntimeInstaller implements ServerRuntimeInstaller {
  const _UnsupportedServerRuntimeInstaller();

  @override
  Future<String> install({
    required ServerReleaseAsset asset,
    required String versionsDirectory,
    void Function(ServerInstallProgress progress)? onProgress,
  }) => Future.error(
    UnsupportedError(
      'Runtime server installation requires a supported desktop platform.',
    ),
  );

  @override
  void close() {}
}
