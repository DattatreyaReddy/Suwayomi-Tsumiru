// Copyright (c) 2026 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'window_geometry.dart';
import 'window_geometry_store.dart';

Future<void> Function()? _beforeDesktopWindowClose;

void setBeforeDesktopWindowClose(Future<void> Function() callback) {
  _beforeDesktopWindowClose = callback;
}

/// Debounce resize saves: Linux emits continuous onWindowResize, never onWindowResized.
class WindowGeometryListener with WindowListener {
  WindowGeometryListener(this._prefs);
  final SharedPreferences _prefs;
  Timer? _debounce;
  bool _persisting = false;
  Future<void>? _inFlight;
  bool _closing = false;

  void _scheduleSave() {
    if (_closing) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _persist);
  }

  Future<void> _persist() {
    // Serialize: interleaved isMaximized/getSize reads corrupt the saved bounds.
    if (_persisting) {
      _scheduleSave();
      return _inFlight ?? Future.value();
    }
    _persisting = true;
    _inFlight = _persistNow().whenComplete(() => _persisting = false);
    return _inFlight!;
  }

  Future<void> _persistNow() async {
    final maximized = await windowManager.isMaximized();
    if (shouldPersistSize(isMaximized: maximized)) {
      final size = await windowManager.getSize();
      await saveWindowGeometry(
        _prefs,
        WindowGeometry(size: size, maximized: false),
      );
    } else {
      final existing = loadWindowGeometry(_prefs);
      await saveWindowGeometry(
        _prefs,
        WindowGeometry(size: existing.size, maximized: true),
      );
    }
  }

  @override
  void onWindowResize() => _scheduleSave();
  @override
  void onWindowResized() => _scheduleSave(); // macOS/Windows end-of-resize
  @override
  void onWindowMaximize() => _scheduleSave();
  @override
  void onWindowUnmaximize() => _scheduleSave();

  @override
  Future<void> onWindowClose() async {
    if (_closing) return;
    _closing = true;
    _debounce?.cancel();
    try {
      await _beforeDesktopWindowClose?.call();
    } catch (exception, stackTrace) {
      debugPrint('Failed to stop local server before closing: $exception');
      debugPrintStack(stackTrace: stackTrace);
    }
    try {
      await _flush().timeout(const Duration(seconds: 2));
    } catch (exception, stackTrace) {
      debugPrint('Failed to persist window geometry on close: $exception');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      await windowManager.destroy();
    }
  }

  Future<void> _flush() async {
    final running = _inFlight;
    if (running != null) {
      try {
        await running;
      } catch (_) {}
    }
    await _persistNow();
  }
}

void attachWindowGeometryListener(SharedPreferences prefs) {
  windowManager.addListener(WindowGeometryListener(prefs));
}
