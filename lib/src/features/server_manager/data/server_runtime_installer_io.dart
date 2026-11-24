// Copyright (c) 2026 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:archive/archive.dart' as archive;
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import 'server_compatibility_manifest.dart';
import 'server_runtime_installer_base.dart';

ServerRuntimeInstaller createServerRuntimeInstaller() =>
    IoServerRuntimeInstaller();

class IoServerRuntimeInstaller implements ServerRuntimeInstaller {
  IoServerRuntimeInstaller({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  @override
  Future<String> install({
    required ServerReleaseAsset asset,
    required String versionsDirectory,
    void Function(ServerInstallProgress progress)? onProgress,
  }) async {
    final versionsRoot = Directory(versionsDirectory);
    await versionsRoot.create(recursive: true);
    final installedDirectory = Directory(
      path.join(versionsRoot.path, asset.version),
    );
    if (await installedDirectory.exists()) {
      if (await _isValidInstallation(installedDirectory, asset.platform)) {
        return installedDirectory.path;
      }
      throw FileSystemException(
        'An incomplete installation already exists and will not be overwritten.',
        installedDirectory.path,
      );
    }

    final temporaryDirectory = Directory(
      path.join(
        versionsRoot.path,
        '.install-${asset.version}-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await temporaryDirectory.create();
    try {
      final archiveFile = File(
        path.join(temporaryDirectory.path, path.basename(asset.uri.path)),
      );
      final totalBytes = await _downloadAndVerify(
        asset,
        archiveFile,
        onProgress,
      );
      onProgress?.call(
        ServerInstallProgress(
          phase: ServerInstallPhase.extracting,
          receivedBytes: totalBytes ?? 0,
          totalBytes: totalBytes,
        ),
      );

      final extractedDirectory = Directory(
        path.join(temporaryDirectory.path, 'extracted'),
      );
      await _extractArchive(archiveFile, extractedDirectory);
      final bundleDirectory = await _findBundleRoot(extractedDirectory);
      await _downloadLicense(asset.version, bundleDirectory);
      if (!await _isValidInstallation(bundleDirectory, asset.platform)) {
        throw const FormatException(
          'The downloaded server release is missing its Java runtime or server JAR.',
        );
      }

      onProgress?.call(
        ServerInstallProgress(
          phase: ServerInstallPhase.installing,
          receivedBytes: totalBytes ?? 0,
          totalBytes: totalBytes,
        ),
      );
      return (await bundleDirectory.rename(installedDirectory.path)).path;
    } finally {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    }
  }

  Future<void> _extractArchive(File archiveFile, Directory destination) async {
    await destination.create(recursive: true);
    final extension = getInputExtension(archiveFile.path);
    var decodedArchiveFile = archiveFile;
    if (extension == '.tar.gz' || extension == '.tgz') {
      decodedArchiveFile = File(
        path.join(destination.parent.path, 'decoded.tar'),
      );
      final input = InputFileStream(archiveFile.path);
      final output = OutputFileStream(decodedArchiveFile.path);
      try {
        if (!archive.GZipDecoder().decodeStream(input, output)) {
          throw const FormatException(
            'The downloaded server archive is invalid.',
          );
        }
      } finally {
        input.closeSync();
        output.closeSync();
      }
    } else if (extension != '.zip') {
      throw FormatException('Unsupported server archive format "$extension".');
    }

    final archiveInput = InputFileStream(decodedArchiveFile.path);
    final extractedPaths = <String>{};
    try {
      void extractEntry(archive.ArchiveFile entry) {
        final relativePath = path.normalize(entry.name);
        final rootPath = path.canonicalize(destination.path);
        final outputPath = path.canonicalize(path.join(rootPath, relativePath));
        if (entry.name.isEmpty ||
            path.isAbsolute(entry.name) ||
            relativePath == '.' ||
            !path.isWithin(rootPath, outputPath)) {
          throw FormatException(
            'The server archive contains an unsafe path "${entry.name}".',
          );
        }
        if (!extractedPaths.add(outputPath) && !entry.isDirectory) {
          throw FormatException(
            'The server archive contains duplicate path "${entry.name}".',
          );
        }
        _ensureNoSymbolicLinkAncestors(rootPath, outputPath);

        if (entry.isSymbolicLink) {
          final linkTarget = entry.symbolicLink;
          if (linkTarget == null || path.isAbsolute(linkTarget)) {
            throw FormatException(
              'The server archive contains an unsafe symbolic link "${entry.name}".',
            );
          }
          final resolvedTarget = path.canonicalize(
            path.join(path.dirname(outputPath), linkTarget),
          );
          if (!path.isWithin(rootPath, resolvedTarget)) {
            throw FormatException(
              'The server archive contains an unsafe symbolic link "${entry.name}".',
            );
          }
          _ensureNoSymbolicLinkAncestors(rootPath, resolvedTarget);
          if (FileSystemEntity.typeSync(resolvedTarget, followLinks: false) ==
              FileSystemEntityType.link) {
            throw FormatException(
              'The server archive contains an unsafe symbolic link "${entry.name}".',
            );
          }
          Link(outputPath).createSync(linkTarget, recursive: true);
        } else if (entry.isDirectory) {
          Directory(outputPath).createSync(recursive: true);
        } else if (entry.isFile) {
          Directory(path.dirname(outputPath)).createSync(recursive: true);
          final output = OutputFileStream(outputPath);
          try {
            entry.writeContent(output);
          } finally {
            output.closeSync();
          }
          if (!Platform.isWindows && (entry.mode & 0x49) != 0) {
            final permissions = (entry.mode & 0x1ff).toRadixString(8);
            final result = Process.runSync('chmod', [permissions, outputPath]);
            if (result.exitCode != 0) {
              throw ProcessException(
                'chmod',
                [permissions, outputPath],
                result.stderr.toString(),
                result.exitCode,
              );
            }
          }
        }
      }

      if (extension == '.zip') {
        archive.ZipDecoder().decodeStream(archiveInput, callback: extractEntry);
      } else {
        archive.TarDecoder().decodeStream(archiveInput, callback: extractEntry);
      }
    } finally {
      archiveInput.closeSync();
    }
  }

  void _ensureNoSymbolicLinkAncestors(String rootPath, String outputPath) {
    var ancestorPath = path.dirname(outputPath);
    while (path.isWithin(rootPath, ancestorPath)) {
      if (FileSystemEntity.typeSync(ancestorPath, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FormatException(
          'The server archive contains a path through a symbolic link.',
        );
      }
      if (ancestorPath == rootPath) return;
      ancestorPath = path.dirname(ancestorPath);
    }
  }

  Future<int?> _downloadAndVerify(
    ServerReleaseAsset asset,
    File destination,
    void Function(ServerInstallProgress progress)? onProgress,
  ) async {
    final request = http.Request('GET', asset.uri);
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw HttpException(
        'Could not download Suwayomi-Server ${asset.version} '
        '(HTTP ${response.statusCode}).',
        uri: asset.uri,
      );
    }

    final totalBytes = response.contentLength;
    final digestSink = _DigestAccumulator();
    final hashSink = sha256.startChunkedConversion(digestSink);
    final fileSink = destination.openWrite();
    var receivedBytes = 0;
    try {
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 60),
      )) {
        hashSink.add(chunk);
        fileSink.add(chunk);
        receivedBytes += chunk.length;
        onProgress?.call(
          ServerInstallProgress(
            phase: ServerInstallPhase.downloading,
            receivedBytes: receivedBytes,
            totalBytes: totalBytes,
          ),
        );
      }
      hashSink.close();
      await fileSink.flush();
    } finally {
      await fileSink.close();
    }

    onProgress?.call(
      ServerInstallProgress(
        phase: ServerInstallPhase.verifying,
        receivedBytes: receivedBytes,
        totalBytes: totalBytes,
      ),
    );
    final actualDigest = digestSink.value.toString();
    if (actualDigest != asset.sha256) {
      throw const FormatException(
        'The downloaded Suwayomi-Server checksum does not match the manifest.',
      );
    }
    return totalBytes ?? receivedBytes;
  }

  Future<void> _downloadLicense(
    String version,
    Directory bundleDirectory,
  ) async {
    final uri = Uri.https(
      'raw.githubusercontent.com',
      '/Suwayomi/Suwayomi-Server/$version/LICENSE',
    );
    final response = await _client
        .get(uri)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw HttpException(
        'Could not download the Suwayomi-Server license file '
        '(HTTP ${response.statusCode}).',
        uri: uri,
      );
    }
    if (response.bodyBytes.length > 1024 * 1024) {
      throw const FormatException(
        'The Suwayomi-Server license file is unexpectedly large.',
      );
    }
    final license = response.body;
    if (!license.toLowerCase().contains('mozilla public license')) {
      throw const FormatException(
        'The Suwayomi-Server license file could not be verified.',
      );
    }
    await File(
      path.join(bundleDirectory.path, 'Suwayomi-Server-LICENSE.txt'),
    ).writeAsString(license);
  }

  Future<Directory> _findBundleRoot(Directory extractionDirectory) async {
    await for (final entity in extractionDirectory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File ||
          path.basename(entity.path) != 'Suwayomi-Server.jar' ||
          path.basename(path.dirname(entity.path)) != 'bin') {
        continue;
      }
      return Directory(path.dirname(path.dirname(entity.path)));
    }
    throw const FormatException(
      'The downloaded archive does not contain bin/Suwayomi-Server.jar.',
    );
  }

  Future<bool> _isValidInstallation(
    Directory directory,
    ServerPlatform platform,
  ) async {
    final javaName = platform == ServerPlatform.windowsX64
        ? 'java.exe'
        : 'java';
    return await File(
          path.join(directory.path, 'bin', 'Suwayomi-Server.jar'),
        ).exists() &&
        await File(
          path.join(directory.path, 'jre', 'bin', javaName),
        ).exists() &&
        await Directory(path.join(directory.path, 'jre', 'legal')).exists();
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}

class _DigestAccumulator implements Sink<Digest> {
  Digest? _digest;

  Digest get value =>
      _digest ?? (throw StateError('The archive digest was not produced.'));

  @override
  void add(Digest value) {
    if (_digest != null) {
      throw StateError('The archive digest was produced more than once.');
    }
    _digest = value;
  }

  @override
  void close() {}
}
