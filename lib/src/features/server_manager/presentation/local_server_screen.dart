// Copyright (c) 2026 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../features/settings/presentation/server/widget/client/server_port_tile/server_port_tile.dart'
    show serverPortProvider, serverPortToggleProvider;
import '../../../features/settings/presentation/server/widget/client/server_url_tile/server_url_tile.dart'
    show serverExternalUrlProvider, serverLanUrlProvider;
import '../../../utils/extensions/custom_extensions.dart';
import '../../../widgets/popup_widgets/confirm_action.dart';
import '../data/local_server_manager.dart';
import '../data/server_runtime.dart';
import '../data/server_runtime_installer.dart';

class LocalServerScreen extends ConsumerStatefulWidget {
  const LocalServerScreen({super.key});

  @override
  ConsumerState<LocalServerScreen> createState() =>
      _LocalServerScreenState();
}

class _LocalServerScreenState extends ConsumerState<LocalServerScreen> {
  late final TextEditingController _portController;
  late final TextEditingController _dataDirectoryController;
  late final Future<String> _defaultDataDirectory;
  bool _bindToLan = false;
  String? _actionError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final manager = ref.read(localServerManagerProvider);
    _portController = TextEditingController(
      text: manager.configuration.port.toString(),
    );
    _dataDirectoryController = TextEditingController(
      text: manager.configuration.dataDirectory,
    );
    _bindToLan = manager.configuration.bindToLan;
    _defaultDataDirectory = manager.getDefaultDataDirectory();
    unawaited(manager.refreshVersions());
  }

  @override
  void dispose() {
    _portController.dispose();
    _dataDirectoryController.dispose();
    super.dispose();
  }

  LocalServerConfiguration _formConfiguration(
    LocalServerConfiguration current,
  ) {
    final port = int.tryParse(_portController.text.trim());
    if (port == null || port < 1 || port > 65535) {
      throw const FormatException('Enter a port from 1 through 65535.');
    }
    return current.copyWith(
      port: port,
      bindToLan: _bindToLan,
      dataDirectory: _dataDirectoryController.text,
    );
  }

  Future<void> _save(LocalServerManager manager) async {
    setState(() {
      _saving = true;
      _actionError = null;
    });
    try {
      await manager.saveConfiguration(
        _formConfiguration(manager.configuration),
      );
    } catch (exception) {
      if (mounted) setState(() => _actionError = exception.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _start(LocalServerManager manager) async {
    setState(() => _actionError = null);
    try {
      await manager.saveConfiguration(
        _formConfiguration(manager.configuration),
      );
      await manager.start();
    } catch (exception) {
      if (mounted) setState(() => _actionError = _localizeError(exception));
    }
  }

  Future<void> _stop(LocalServerManager manager) async {
    setState(() => _actionError = null);
    try {
      await manager.stop();
    } catch (exception) {
      if (mounted) setState(() => _actionError = exception.toString());
    }
  }

  Future<void> _install(LocalServerManager manager) async {
    setState(() => _actionError = null);
    try {
      await manager.installSelectedVersion();
    } catch (exception) {
      if (mounted) setState(() => _actionError = exception.toString());
    }
  }

  Future<void> _selectVersion(
    LocalServerManager manager,
    String version,
  ) async {
    setState(() => _actionError = null);
    try {
      await manager.selectVersion(version);
    } catch (exception) {
      if (mounted) setState(() => _actionError = exception.toString());
    }
  }

  String _localizeError(Object exception) {
    if (exception is ServerRuntimeException) {
      return switch (exception.code) {
        ServerRuntimeError.missingInstallation =>
          context.l10n.localServerInstallMissing,
        ServerRuntimeError.unsupportedPlatform =>
          context.l10n.localServerUnsupportedArchitecture,
      };
    }
    return exception.toString();
  }

  Future<void> _chooseDataDirectory() async {
    try {
      final directory = await FilePicker.getDirectoryPath();
      if (directory != null && mounted) {
        _dataDirectoryController.text = directory;
      }
    } catch (exception) {
      if (mounted) setState(() => _actionError = exception.toString());
    }
  }

  Future<void> _connectTsumiru(LocalServerManager manager) async {
    setState(() => _actionError = null);
    try {
      final confirmed = await confirmAction(
        context,
        title: context.l10n.confirmServerOriginTitle,
        message: context.l10n.localServerConnectConfirm,
        action: context.l10n.localServerConnectTsumiru,
      );
      if (!confirmed || !mounted) return;
      ref.read(serverLanUrlProvider.notifier).update(null);
      await ref
          .read(serverPortProvider.notifier)
          .update(manager.activePort ?? manager.configuration.port);
      await ref.read(serverPortToggleProvider.notifier).update(true);
      await ref
          .read(serverExternalUrlProvider.notifier)
          .update('http://127.0.0.1');
    } catch (exception) {
      if (mounted) setState(() => _actionError = exception.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = ref.watch(localServerManagerProvider);
    final busy =
        manager.state == LocalServerState.starting ||
        manager.state == LocalServerState.stopping ||
        manager.isInstalling ||
        manager.isLoadingVersions ||
        _saving;
    final running = manager.state == LocalServerState.running;
    final versionControlsBusy = busy || running;
    final versions = [
      ...manager.availableVersions,
      ...manager.installedVersions.where(
        (version) => !manager.availableVersions.contains(version),
      ),
    ];
    final selectedVersion = versions.contains(manager.selectedVersion)
        ? manager.selectedVersion
        : null;
    final selectedVersionInstalled =
        selectedVersion != null &&
        manager.installedVersions.contains(selectedVersion);
    final compatibilityManifest = manager.compatibilityManifest;
    final installProgress = manager.installProgress;
    final l10n = context.l10n;
    final status = switch (manager.state) {
      LocalServerState.stopped => l10n.localServerStatusStopped,
      LocalServerState.starting => l10n.localServerStatusStarting,
      LocalServerState.running => l10n.localServerStatusRunning,
      LocalServerState.stopping => l10n.localServerStatusStopping,
      LocalServerState.failed => l10n.localServerStatusFailed,
    };

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(FluentIcons.arrow_left_24_regular),
          onPressed: () => Navigator.of(context).maybePop(),
          tooltip: l10n.back,
        ),
        title: Text(l10n.localServerManager),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.localServerStatus,
                    style: context.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(status),
                  if (manager.state == LocalServerState.running) ...[
                    const SizedBox(height: 4),
                    Text(
                      manager.isHealthy
                          ? l10n.localServerHealthReady
                          : l10n.localServerHealthWaiting,
                    ),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: busy || running || !selectedVersionInstalled
                            ? null
                            : () => _start(manager),
                        icon: const Icon(FluentIcons.play_24_filled),
                        label: Text(l10n.localServerStart),
                      ),
                      OutlinedButton.icon(
                        onPressed:
                            busy || manager.state == LocalServerState.stopped
                            ? null
                            : () => _stop(manager),
                        icon: const Icon(FluentIcons.stop_24_filled),
                        label: Text(l10n.localServerStop),
                      ),
                      if (manager.isHealthy)
                        OutlinedButton.icon(
                          onPressed: () => _connectTsumiru(manager),
                          icon: const Icon(FluentIcons.link_24_regular),
                          label: Text(l10n.localServerConnectTsumiru),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.localServerVersion,
                    style: context.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(l10n.localServerDownloadNotice),
                  if (compatibilityManifest != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      l10n.localServerLatestTested(
                        compatibilityManifest.latestTestedVersion,
                      ),
                    ),
                    Text(
                      l10n.localServerMaxSupported(
                        compatibilityManifest.maxSupportedVersion,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (versions.isNotEmpty)
                    DropdownButtonFormField<String>(
                      initialValue: selectedVersion,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: l10n.localServerVersion,
                        border: const OutlineInputBorder(),
                      ),
                      items: [
                        for (final version in versions)
                          DropdownMenuItem(
                            value: version,
                            child: Text(
                              manager.installedVersions.contains(version)
                                  ? '$version · ${l10n.localServerInstalled}'
                                  : version,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: versionControlsBusy
                          ? null
                          : (version) {
                              if (version != null) {
                                unawaited(_selectVersion(manager, version));
                              }
                            },
                    )
                  else
                    Text(l10n.localServerNoAvailableVersions),
                  if (!selectedVersionInstalled &&
                      compatibilityManifest != null) ...[
                    const SizedBox(height: 8),
                    Text(l10n.localServerVersionNotInstalled),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed:
                            versionControlsBusy ||
                                selectedVersion == null ||
                                selectedVersionInstalled
                            ? null
                            : () => _install(manager),
                        icon: const Icon(FluentIcons.arrow_down_24_regular),
                        label: Text(l10n.localServerDownloadVersion),
                      ),
                      OutlinedButton.icon(
                        onPressed: busy
                            ? null
                            : () => unawaited(manager.refreshVersions()),
                        icon: const Icon(FluentIcons.arrow_sync_24_regular),
                        label: Text(l10n.localServerRefreshVersions),
                      ),
                    ],
                  ),
                  if (manager.isInstalling && installProgress != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      switch (installProgress.phase) {
                        ServerInstallPhase.downloading => l10n.localServerDownloading,
                        ServerInstallPhase.verifying => l10n.localServerVerifying,
                        ServerInstallPhase.extracting => l10n.localServerExtracting,
                        ServerInstallPhase.installing => l10n.localServerInstalling,
                      },
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(value: installProgress.fraction),
                  ],
                  if (manager.compatibilityError != null) ...[
                    const SizedBox(height: 8),
                    SelectableText(
                      manager.compatibilityError!,
                      style: TextStyle(color: context.theme.colorScheme.error),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(l10n.localServerManager, style: context.textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _portController,
            decoration: InputDecoration(
              labelText: l10n.localServerPort,
              border: const OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.localServerAllowLan),
            value: _bindToLan,
            onChanged: busy
                ? null
                : (value) => setState(() => _bindToLan = value),
          ),
          if (_bindToLan)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                l10n.localServerLanWarning,
                style: TextStyle(color: context.theme.colorScheme.error),
              ),
            ),
          TextField(
            controller: _dataDirectoryController,
            readOnly: true,
            decoration: InputDecoration(
              labelText: l10n.localServerDataDirectory,
              border: const OutlineInputBorder(),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: busy
                        ? null
                        : () => _dataDirectoryController.clear(),
                    icon: const Icon(FluentIcons.arrow_reset_24_regular),
                    tooltip: l10n.localServerUseDefaultDirectory,
                  ),
                  IconButton(
                    onPressed: busy ? null : _chooseDataDirectory,
                    icon: const Icon(FluentIcons.folder_open_24_regular),
                    tooltip: l10n.localServerChooseDirectory,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          FutureBuilder<String>(
            future: _defaultDataDirectory,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Text(
                  snapshot.error.toString(),
                  style: TextStyle(color: context.theme.colorScheme.error),
                );
              }
              return Text(
                '${l10n.localServerDefaultDirectory}: '
                '${snapshot.data ?? ''}',
              );
            },
          ),
          if (running) ...[
            const SizedBox(height: 8),
            Text(
              l10n.localServerRestartToApply,
              style: context.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: busy ? null : () => _save(manager),
              child: Text(l10n.localServerSaveConfiguration),
            ),
          ),
          if (_actionError != null || manager.error != null) ...[
            const SizedBox(height: 12),
            SelectableText(
              _actionError ?? manager.error!,
              style: TextStyle(color: context.theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 24),
          Text(l10n.localServerLogs, style: context.textTheme.titleMedium),
          const SizedBox(height: 8),
          Container(
            height: 280,
            decoration: BoxDecoration(
              color: context.theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
            ),
            child: manager.logs.isEmpty
                ? Center(child: Text(l10n.localServerNoLogs))
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: manager.logs.length,
                    itemBuilder: (context, index) => SelectableText(
                      manager.logs[index],
                      style: context.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
