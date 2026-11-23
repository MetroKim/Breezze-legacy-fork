import 'dart:convert';
import 'dart:io';

import 'bz_track.dart';
import 'lyrics_provider.dart';

class DownloadCancellation {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class DownloadCancelledException implements Exception {}

/// Downloads library — offline tracks with lyrics and cover art stored
/// alongside each track (§54.3).
///
/// Layout per track:
///   <downloadsDir>/<trackId>/audio.m4a
///   <downloadsDir>/<trackId>/cover.jpg
///   <downloadsDir>/<trackId>/lyrics.lrc
///   <downloadsDir>/<trackId>/meta.json
class DownloadsLibrary {
  final Directory root;
  final LyricsProvider lyrics;

  DownloadsLibrary({
    required this.root,
    required this.lyrics,
  });

  // R2 returns strong quoted ETags for each stored media version.
  String? _strongEtagVersion(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^"([A-Za-z0-9._:-]{1,120})"$').firstMatch(value.trim());
    return match == null ? null : 'etag:${match.group(1)}';
  }

  Directory _dirFor(String trackId) {
    final safeTrackId = trackId.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    if (safeTrackId.isEmpty || safeTrackId == '.' || safeTrackId == '..') {
      throw ArgumentError.value(trackId, 'trackId', 'invalid storage key');
    }
    return Directory('${root.path}/$safeTrackId');
  }

  /// Downloads audio + cover art + lyrics for one track.
  ///
  /// [onProgress] receives 0.0–1.0 across the audio transfer (the
  /// dominant cost); lyrics and art are near-instant.
  Future<bool> download(
    BzTrack track, {
    required String downloadUrl,
    required String ownerId,
    required String catalogTrackId,
    DateTime? rightsExpiresAtUtc,
    String? assetVersion,
    void Function(double progress)? onProgress,
    DownloadCancellation? cancellation,
  }) async {
    final dir = _dirFor(track.id);
    var observedAssetVersion = assetVersion;
    try {
      await dir.create(recursive: true);

      // 1. Fetch only the short-lived URL issued by the backend after its
      // download-rights decision. Never extract media directly from a
      // metadata/search provider in the client.
      final audioFile = File('${dir.path}/audio.m4a');
      if (await audioFile.exists()) {
        // A completed cache is no more trustworthy than a partial one.
        // An updated master, codec or revoked asset invalidates old bytes.
        final metaFile = File('${dir.path}/meta.json');
        String? cachedVersion;
        try {
          if (await metaFile.exists()) {
            final data = jsonDecode(await metaFile.readAsString());
            if (data is Map) cachedVersion = data['assetVersion'] as String?;
          }
        } catch (_) {
          // Corrupt metadata is never proof of a matching audio master.
        }
        var reusable = assetVersion != null &&
            RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(assetVersion) &&
            cachedVersion == assetVersion;
        // When the API supplies no master revision, compare the current
        // object ETag through the already-authorized signed media URL.
        if (!reusable && assetVersion == null &&
            cachedVersion != null && cachedVersion.startsWith('etag:')) {
          final client = HttpClient();
          try {
            final request = await client.openUrl('HEAD', Uri.parse(downloadUrl));
            final response = await request.close();
            final version = _strongEtagVersion(response.headers.value('etag'));
            reusable = response.statusCode == HttpStatus.ok &&
                version != null && version == cachedVersion;
            await response.drain<void>();
          } catch (_) {
            reusable = false;
          } finally {
            client.close(force: true);
          }
        }
        if (!reusable) {
          await audioFile.delete();
        } else {
          observedAssetVersion = cachedVersion;
        }
      }
      if (!await audioFile.exists()) {
        final partialFile = File('${dir.path}/audio.part');
        final versionFile = File(partialFile.path + '.version');
        // Partial bytes are only valid for the same encoded asset version.
        // If no stable version exists, restart instead of splicing masters.
        final validVersion = assetVersion != null &&
            RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(assetVersion);
        final storedVersion = await versionFile.exists()
            ? await versionFile.readAsString() : null;
        final sameVersion = storedVersion != null &&
            (validVersion ? storedVersion == assetVersion :
                assetVersion == null && storedVersion.startsWith('etag:'));
        if (!sameVersion && await partialFile.exists()) {
          await partialFile.delete();
        }
        if (validVersion) {
          await versionFile.writeAsString(assetVersion!);
        } else if (!sameVersion && await versionFile.exists()) {
          await versionFile.delete();
        }
        final client = HttpClient();
        try {
          final existingBytes =
              await partialFile.exists() ? await partialFile.length() : 0;
          final request = await client.getUrl(Uri.parse(downloadUrl));
          if (existingBytes > 0) {
            request.headers.set('range', 'bytes=$existingBytes-');
            if (assetVersion == null && storedVersion != null &&
                storedVersion.startsWith('etag:')) {
              request.headers.set(
                'if-range', '"${storedVersion.substring(5)}"',
              );
            }
          }
          final response = await request.close();
          final responseVersion = _strongEtagVersion(
            response.headers.value('etag'),
          );
          if (existingBytes > 0 && assetVersion == null &&
              response.statusCode == HttpStatus.partialContent &&
              responseVersion != storedVersion) {
            await response.drain<void>();
            if (await partialFile.exists()) await partialFile.delete();
            if (await versionFile.exists()) await versionFile.delete();
            throw const HttpException('resumed_asset_etag_mismatch');
          }
          if (assetVersion == null && responseVersion != null) {
            observedAssetVersion = responseVersion;
            await versionFile.writeAsString(responseVersion);
          }
          final resumes = existingBytes > 0 &&
              response.statusCode == HttpStatus.partialContent;
          if (response.statusCode != HttpStatus.ok && !resumes) {
            throw HttpException(
              'authorized_download_${response.statusCode}',
              uri: Uri.parse(downloadUrl),
            );
          }
          if (resumes) {
            final contentRange = response.headers.value('content-range');
            if (contentRange == null ||
                !contentRange.startsWith('bytes $existingBytes-')) {
              throw const HttpException('invalid_resume_content_range');
            }
          }

          // A server that ignores Range returns 200. Start over rather than
          // appending a second copy of the complete asset.
          final sink = partialFile.openWrite(
            mode: resumes ? FileMode.append : FileMode.write,
          );
          var received = resumes ? existingBytes : 0;
          final totalBytes = resumes
              ? _totalBytesFromContentRange(
                  response.headers.value('content-range'),
                )
              : response.contentLength;
          try {
            await for (final chunk in response) {
              if (cancellation?.isCancelled == true) throw DownloadCancelledException();
              sink.add(chunk);
              received += chunk.length;
              if (totalBytes > 0) {
                onProgress?.call((received / totalBytes).clamp(0.0, 1.0));
              }
            }
            await sink.flush();
          } finally {
            await sink.close();
          }
          if (totalBytes > 0 && received != totalBytes) {
            throw const HttpException('authorized_download_incomplete');
          }
          await partialFile.rename(audioFile.path);
          if (await versionFile.exists()) await versionFile.delete();
        } catch (_) {
          // Keep the partial asset. The next authorized attempt can request
          // the remaining byte range instead of downloading from zero.
          rethrow;
        } finally {
          client.close(force: true);
        }
      }
      onProgress?.call(1.0);

      // 2. Cover art is optional. A CDN/network failure must not turn a
      // completed, rights-authorized audio download into a failed job.
      if (track.artworkUrl != null) {
        final coverFile = File('${dir.path}/cover.jpg');
        if (!await coverFile.exists()) {
          final client = HttpClient();
          try {
            final request = await client.getUrl(Uri.parse(track.artworkUrl!));
            final response = await request.close();
            if (response.statusCode == HttpStatus.ok) {
              await response.pipe(coverFile.openWrite());
            } else {
              await response.drain<void>();
            }
          } catch (_) {
            if (await coverFile.exists()) await coverFile.delete();
          } finally {
            client.close(force: true);
          }
        }
      }

      // 3. Lyrics are also best-effort. LRCLIB being unavailable must not
      // invalidate an otherwise complete offline audio asset.
      try {
        final lyricsFile = File('${dir.path}/lyrics.lrc');
        final result = await lyrics.bestFor(track);
        if (result != null) {
          await lyricsFile.writeAsString(result.bestLrc);
        }
      } catch (_) {
        // Lyrics can be fetched again independently when the app is online.
      }

      // 4. Ownership and licence metadata are stored beside the app-private asset. Downloads are listed only for their owner and
      // are blocked locally after an explicit rights end time.
      final metaFile = File('${dir.path}/meta.json');
      await metaFile.writeAsString(jsonEncode({
        'title': track.title,
        'artist': track.artist,
        'ownerId': ownerId,
        'catalogTrackId': catalogTrackId,
        'assetVersion': observedAssetVersion,
        'rightsExpiresAtUtc': rightsExpiresAtUtc?.toUtc().toIso8601String(),
      }));

      return true;
    } catch (_) {
      return false;
    }
  }

  int _totalBytesFromContentRange(String? value) {
    if (value == null) return -1;
    final match = RegExp(r'^bytes \d+-\d+/(\d+)$').firstMatch(value);
    return match == null ? -1 : int.tryParse(match.group(1)!) ?? -1;
  }

  Future<void> updateOfflineLease(String trackId, DateTime? expiresAtUtc) async {
    final metaFile = File('${_dirFor(trackId).path}/meta.json');
    if (!await metaFile.exists()) return;
    final raw = jsonDecode(await metaFile.readAsString());
    if (raw is! Map<String, dynamic>) return;
    raw['rightsExpiresAtUtc'] = expiresAtUtc?.toUtc().toIso8601String();
    await metaFile.writeAsString(jsonEncode(raw));
  }

  /// Lists only assets owned by [ownerId]. A legacy file without owner
  /// metadata is deliberately hidden rather than exposed across sessions.
  Future<List<DownloadedTrack>> list({required String ownerId}) async {
    final tracks = <DownloadedTrack>[];
    if (!await root.exists()) return tracks;
    await for (final entry in root.list()) {
      if (entry is! Directory) continue;
      final metaFile = File('${entry.path}/meta.json');
      if (!await metaFile.exists()) continue;
      try {
        final raw = jsonDecode(await metaFile.readAsString());
        if (raw is! Map<String, dynamic> || raw['ownerId'] != ownerId) {
          continue;
        }
        final title = raw['title'] as String? ?? 'Unknown';
        final artist = raw['artist'] as String? ?? 'Unknown';
        final catalogTrackId = raw['catalogTrackId'] as String?;
        final audioPath = '${entry.path}/audio.m4a';
        if (catalogTrackId == null || catalogTrackId.isEmpty ||
            !await File(audioPath).exists()) continue;
        final expiryRaw = raw['rightsExpiresAtUtc'] as String?;
        final expiry = expiryRaw == null ? null : DateTime.tryParse(expiryRaw);
        tracks.add(DownloadedTrack(
          trackId: entry.uri.pathSegments.lastWhere((part) => part.isNotEmpty),
          catalogTrackId: catalogTrackId,
          ownerId: ownerId,
          rightsExpiresAtUtc: expiry?.toUtc(),
          title: title.isNotEmpty ? title : 'Unknown',
          artist: artist,
          audioPath: audioPath,
          coverPath: await File('${entry.path}/cover.jpg').exists()
              ? '${entry.path}/cover.jpg'
              : null,
          lyricsPath: await File('${entry.path}/lyrics.lrc').exists()
              ? '${entry.path}/lyrics.lrc'
              : null,
        ));
      } catch (_) {
        continue;
      }
    }
    return tracks;
  }

  Future<void> removePartial(String trackId) async {
    final partial = File('${_dirFor(trackId).path}/audio.part');
    if (await partial.exists()) await partial.delete();
    final version = File(partial.path + '.version');
    if (await version.exists()) await version.delete();
  }

  Future<void> remove(String trackId) async {
    final dir = _dirFor(trackId);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}

/// A downloaded track with its local file paths.
class DownloadedTrack {
  /// Storage key used to remove this local asset.
  final String trackId;
  final String catalogTrackId;
  final String ownerId;
  final DateTime? rightsExpiresAtUtc;
  final String title;
  final String artist;
  final String audioPath;
  final String? coverPath;
  final String? lyricsPath;

  const DownloadedTrack({
    required this.trackId,
    required this.catalogTrackId,
    required this.ownerId,
    required this.rightsExpiresAtUtc,
    required this.title,
    required this.artist,
    required this.audioPath,
    this.coverPath,
    this.lyricsPath,
  });
}
