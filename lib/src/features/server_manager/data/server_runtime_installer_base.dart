// Copyright (c) 2026 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'server_compatibility_manifest.dart';

enum ServerInstallPhase { downloading, verifying, extracting, installing }

class ServerInstallProgress {
  const ServerInstallProgress({
    required this.phase,
    required this.receivedBytes,
    required this.totalBytes,
  });

  final ServerInstallPhase phase;
  final int receivedBytes;
  final int? totalBytes;

  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0, 1);
  }
}

abstract interface class ServerRuntimeInstaller {
  Future<String> install({
    required ServerReleaseAsset asset,
    required String versionsDirectory,
    void Function(ServerInstallProgress progress)? onProgress,
  });

  void close();
}
