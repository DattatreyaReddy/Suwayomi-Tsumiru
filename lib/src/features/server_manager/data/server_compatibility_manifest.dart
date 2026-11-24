// Copyright (c) 2026 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

enum ServerPlatform {
  linuxX64('linux-x64', 'Suwayomi-Server-{version}-linux-x64.tar.gz'),
  windowsX64('windows-x64', 'Suwayomi-Server-{version}-windows-x64.zip'),
  macosX64('macos-x64', 'Suwayomi-Server-{version}-macOS-x64.tar.gz'),
  macosArm64('macos-arm64', 'Suwayomi-Server-{version}-macOS-arm64.tar.gz');

  const ServerPlatform(this.manifestKey, this.assetNameTemplate);

  final String manifestKey;
  final String assetNameTemplate;

  String assetName(String version) => assetNameTemplate.replaceAll(
    '{version}',
    version,
  );

}

class ServerReleaseAsset {
  const ServerReleaseAsset({
    required this.version,
    required this.platform,
    required this.uri,
    required this.sha256,
  });

  final String version;
  final ServerPlatform platform;
  final Uri uri;
  final String sha256;
}

class ServerRelease {
  const ServerRelease({required this.version, required this.assets});

  final String version;
  final Map<ServerPlatform, ServerReleaseAsset> assets;

  Version get parsedVersion => _parseVersion(version);
}

class ServerCompatibilityManifest {
  const ServerCompatibilityManifest({
    required this.latestTestedVersion,
    required this.maxSupportedVersion,
    required this.releases,
  });

  final String latestTestedVersion;
  final String maxSupportedVersion;
  final List<ServerRelease> releases;

  List<String> get versions =>
      releases.map((release) => release.version).toList(growable: false);

  ServerReleaseAsset? assetFor(String version, ServerPlatform platform) {
    for (final release in releases) {
      if (release.version == version) return release.assets[platform];
    }
    return null;
  }

  factory ServerCompatibilityManifest.parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('The compatibility manifest must be an object.');
    }
    if (decoded['schemaVersion'] != 1) {
      throw const FormatException('Unsupported compatibility manifest schema.');
    }

    final latestTestedVersion = _requiredString(
      decoded,
      'latestTestedVersion',
    );
    final maxSupportedVersion = _requiredString(
      decoded,
      'maxSupportedVersion',
    );
    final latestTested = _parseVersion(latestTestedVersion);
    final maxSupported = _parseVersion(maxSupportedVersion);
    if (latestTested > maxSupported) {
      throw const FormatException(
        'The latest tested server version exceeds the supported version limit.',
      );
    }

    final rawReleases = decoded['releases'];
    if (rawReleases is! List || rawReleases.isEmpty) {
      throw const FormatException(
        'The compatibility manifest must list at least one release.',
      );
    }

    final releases = <ServerRelease>[];
    final seenVersions = <String>{};
    for (final rawRelease in rawReleases) {
      if (rawRelease is! Map<String, dynamic>) {
        throw const FormatException('A server release entry is invalid.');
      }
      final version = _requiredString(rawRelease, 'version');
      final parsedVersion = _parseVersion(version);
      if (parsedVersion > maxSupported) {
        throw FormatException(
          'Server release $version exceeds the supported version limit.',
        );
      }
      if (!seenVersions.add(version)) {
        throw FormatException('Server release $version is listed more than once.');
      }

      final rawAssets = rawRelease['assets'];
      if (rawAssets is! Map<String, dynamic> || rawAssets.isEmpty) {
        throw FormatException('Server release $version has no platform assets.');
      }
      final assets = <ServerPlatform, ServerReleaseAsset>{};
      for (final entry in rawAssets.entries) {
        final platform = ServerPlatform.values
            .where((candidate) => candidate.manifestKey == entry.key)
            .firstOrNull;
        if (platform == null || entry.value is! Map<String, dynamic>) {
          throw FormatException(
            'Server release $version has an unknown platform asset.',
          );
        }
        final rawAsset = entry.value as Map<String, dynamic>;
        final url = Uri.tryParse(_requiredString(rawAsset, 'url'));
        final digest = _requiredString(rawAsset, 'sha256');
        final expectedName = platform.assetName(version);
        final expectedPath =
            '/Suwayomi/Suwayomi-Server/releases/download/$version/'
            '$expectedName';
        if (url == null ||
            url.scheme != 'https' ||
            url.host != 'github.com' ||
            url.userInfo.isNotEmpty ||
            url.path != expectedPath ||
            !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(digest)) {
          throw FormatException(
            'The ${platform.manifestKey} asset for $version is invalid.',
          );
        }
        assets[platform] = ServerReleaseAsset(
          version: version,
          platform: platform,
          uri: url,
          sha256: digest.toLowerCase(),
        );
      }
      releases.add(ServerRelease(version: version, assets: assets));
    }

    if (!seenVersions.contains(latestTestedVersion)) {
      throw const FormatException(
        'The latest tested server version is not listed as a release.',
      );
    }
    releases.sort(
      (left, right) => right.parsedVersion.compareTo(left.parsedVersion),
    );
    return ServerCompatibilityManifest(
      latestTestedVersion: latestTestedVersion,
      maxSupportedVersion: maxSupportedVersion,
      releases: List.unmodifiable(releases),
    );
  }
}

class ServerCompatibilityRepository {
  ServerCompatibilityRepository({
    http.Client? client,
    Uri? manifestUri,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _manifestUri =
           manifestUri ??
           Uri.parse(
             'https://raw.githubusercontent.com/Suwayomi/'
             'Suwayomi-Tsumiru/main/server-manager/compatibility.json',
           );

  final http.Client _client;
  final bool _ownsClient;
  final Uri _manifestUri;

  Future<ServerCompatibilityManifest> fetch() async {
    final response = await _client
        .get(_manifestUri)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError(
        'Could not load supported Suwayomi-Server versions from '
        '$_manifestUri (HTTP ${response.statusCode}).',
      );
    }
    if (response.bodyBytes.length > 128 * 1024) {
      throw const FormatException('The compatibility manifest is too large.');
    }
    return ServerCompatibilityManifest.parse(
      utf8.decode(response.bodyBytes),
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

String _requiredString(Map<String, dynamic> object, String key) {
  final value = object[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('The compatibility manifest field "$key" is invalid.');
  }
  return value;
}

Version _parseVersion(String version) {
  if (!RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(version)) {
    throw FormatException('Invalid Suwayomi-Server version "$version".');
  }
  return Version.parse(version.substring(1));
}
