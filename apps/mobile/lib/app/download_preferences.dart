import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persisted offline-download preferences. Rights and available quality are
/// still decided by the backend; these values are user preferences only.
class DownloadPreferences {
  final bool wifiOnly;
  final bool allowCellular;
  final bool autoCleanup;
  final int minimumFreeSpaceGb;
  final String quality;
  final String streamingQuality;

  const DownloadPreferences({
    this.wifiOnly = true,
    this.allowCellular = false,
    this.autoCleanup = true,
    this.minimumFreeSpaceGb = 2,
    this.quality = 'standard',
    this.streamingQuality = 'AAC_256',
  });

  DownloadPreferences copyWith({
    bool? wifiOnly,
    bool? allowCellular,
    bool? autoCleanup,
    int? minimumFreeSpaceGb,
    String? quality,
    String? streamingQuality,
  }) =>
      DownloadPreferences(
        wifiOnly: wifiOnly ?? this.wifiOnly,
        allowCellular: allowCellular ?? this.allowCellular,
        autoCleanup: autoCleanup ?? this.autoCleanup,
        minimumFreeSpaceGb: minimumFreeSpaceGb ?? this.minimumFreeSpaceGb,
        quality: quality ?? this.quality,
        streamingQuality: streamingQuality ?? this.streamingQuality,
      );

  Map<String, Object> toJson() => {
        'wifiOnly': wifiOnly,
        'allowCellular': allowCellular,
        'autoCleanup': autoCleanup,
        'minimumFreeSpaceGb': minimumFreeSpaceGb,
        'quality': quality,
        'streamingQuality': streamingQuality,
      };

  factory DownloadPreferences.fromJson(Map<String, dynamic> json) {
    final requestedMinimum = (json['minimumFreeSpaceGb'] as num?)?.toInt();
    final requestedQuality = json['quality'];
    final allowCellular = json['allowCellular'] == true;
    final wifiOnly = json['wifiOnly'] is bool
        ? json['wifiOnly'] as bool
        : !allowCellular;
    return DownloadPreferences(
      // Keep the two network flags mutually exclusive even when loading an
      // older or hand-edited preferences file.
      wifiOnly: wifiOnly && !allowCellular,
      allowCellular: allowCellular,
      autoCleanup: json['autoCleanup'] as bool? ?? true,
      minimumFreeSpaceGb: const [1, 2, 5, 10].contains(requestedMinimum)
          ? requestedMinimum!
          : 2,
      quality: requestedQuality == 'lossless' ? 'lossless' : 'standard',
      streamingQuality: const ['AAC_128', 'AAC_256', 'LOSSLESS'].contains(json['streamingQuality'])
          ? json['streamingQuality'] as String
          : 'AAC_256',
    );
  }
}

class DownloadPreferencesStore {
  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    final folder = Directory(p.join(dir.path, 'Breezze', 'Preferences'));
    await folder.create(recursive: true);
    return File(p.join(folder.path, 'downloads.json'));
  }

  Future<DownloadPreferences> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const DownloadPreferences();
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) return const DownloadPreferences();
      return DownloadPreferences.fromJson(json);
    } catch (_) {
      return const DownloadPreferences();
    }
  }

  Future<void> save(DownloadPreferences preferences) async {
    final file = await _file();
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(preferences.toJson()), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}
