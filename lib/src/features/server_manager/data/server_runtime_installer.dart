// Copyright (c) 2026 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'server_runtime_installer_base.dart';
import 'server_runtime_installer_stub.dart'
    if (dart.library.io) 'server_runtime_installer_io.dart'
    as implementation;

export 'server_runtime_installer_base.dart';

ServerRuntimeInstaller createServerRuntimeInstaller() =>
    implementation.createServerRuntimeInstaller();
