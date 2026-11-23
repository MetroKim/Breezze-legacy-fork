import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:path_provider/path_provider.dart';

/// Local, device-scoped search history. Search terms are personal UI state,
/// not catalog data, so they stay on this device and are never synced.
class SearchHistoryStore {
  SearchHistoryStore({
    String ownerId = 'guest',
    Future<File> Function()? fileProvider,
    Future<String?> Function(String key)? readBrowserValue,
    Future<void> Function(String key, String value)? writeBrowserValue,
  })  : _ownerId = ownerId,
        _useBrowserStorage = fileProvider == null &&
            (kIsWeb || (readBrowserValue != null && writeBrowserValue != null)),
        _readBrowserValue = readBrowserValue ??
            ((key) => _secureStorage.read(key: key)),
        _writeBrowserValue = writeBrowserValue ??
            ((key, value) => _secureStorage.write(key: key, value: value)),
        _fileProvider = fileProvider ?? (() => _defaultFile(ownerId));

  static const int maxEntries = 10;
  static const String _fileName = 'breezze_search_history.json';

  static const _secureStorage = FlutterSecureStorage();
  final String _ownerId;
  final bool _useBrowserStorage;
  final Future<String?> Function(String key) _readBrowserValue;
  final Future<void> Function(String key, String value) _writeBrowserValue;
  final Future<File> Function() _fileProvider;
  Future<void> _mutationQueue = Future<void>.value();

  String get _browserKey =>
      'breezze:search_history:v1:${Uri.encodeComponent(_ownerId)}';

  static Future<File> _defaultFile(String ownerId) async {
    final directory = await getApplicationDocumentsDirectory();
    if (ownerId == 'guest') {
      return File('${directory.path}/$_fileName');
    }
    final safeOwnerId = ownerId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return File('${directory.path}/breezze_search_history_$safeOwnerId.json');
  }

  Future<List<String>> load() async {
    // Wait for queued mutations so callers never observe a partially written
    // or stale snapshot while an add/remove/clear operation is in progress.
    await _mutationQueue;
    return _load();
  }

  Future<List<String>> _load() async {
    try {
      String? source;
      if (_useBrowserStorage) {
        // dart:io files are unsupported by the browser. Flutter secure storage
        // uses the browser's secure persisted storage on a trusted origin.
        source = await _readBrowserValue(_browserKey);
      } else {
        final file = await _fileProvider();
        if (!await file.exists()) return const [];
        source = await file.readAsString();
      }
      if (source == null) return const [];
      final decoded = jsonDecode(source);
      if (decoded is! List) return const [];

      final seen = <String>{};
      final entries = <String>[];
      for (final value in decoded) {
        if (value is! String) continue;
        final query = value.trim();
        if (query.isEmpty || !seen.add(query.toLowerCase())) continue;
        entries.add(query);
        if (entries.length == maxEntries) break;
      }
      return entries;
    } on FormatException {
      return const [];
    } on FileSystemException {
      return const [];
    } catch (_) {
      // A browser that blocks storage must never block the actual search.
      return const [];
    }
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _mutationQueue.then((_) => operation());
    // Keep the queue alive after a failed write while still returning the
    // original error to the caller.
    _mutationQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<List<String>> add(String query) {
    final normalized = query.trim();
    if (normalized.isEmpty) return load();

    return _serialize(() async {
      final current = await _load();
      final next = [
        normalized,
        ...current.where(
          (entry) => entry.toLowerCase() != normalized.toLowerCase(),
        ),
      ].take(maxEntries).toList(growable: false);
      await _write(next);
      return next;
    });
  }

  Future<List<String>> remove(String query) => _serialize(() async {
        final current = await _load();
        final next = current
            .where((entry) => entry.toLowerCase() != query.toLowerCase())
            .toList(growable: false);
        await _write(next);
        return next;
      });

  Future<void> clear() => _serialize(() => _write(const []));

  Future<void> _write(List<String> entries) async {
    final encoded = jsonEncode(entries);
    if (_useBrowserStorage) {
      await _writeBrowserValue(_browserKey, encoded);
      return;
    }
    final file = await _fileProvider();
    await file.parent.create(recursive: true);
    await file.writeAsString(encoded, flush: true);
  }
}
