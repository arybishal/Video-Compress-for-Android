import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../models/models.dart';

/// Local-only job history (no source paths retained, capped at
/// [AppConfig.maxHistoryEntries]). Stored via SharedPreferences.
class JobRepository {
  static const _key = 'job_history_v1';

  Future<List<JobRecord>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => _fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
    } catch (_) {
      return const []; // corrupted history is not worth crashing over
    }
  }

  Future<void> add(JobRecord record) async {
    final prefs = await SharedPreferences.getInstance();
    final current = (await load()).toList();
    current.insert(0, record);
    final trimmed = current.take(AppConfig.maxHistoryEntries).toList();
    await prefs.setString(_key, jsonEncode(trimmed.map(_toJson).toList()));
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static Map<String, dynamic> _toJson(JobRecord r) => {
        'id': r.id,
        'createdAt': r.createdAt.toIso8601String(),
        'sourceName': r.sourceName,
        'originalBytes': r.originalBytes,
        'outputBytes': r.outputBytes,
        'durationMs': r.durationMs,
        'mode': r.mode.name,
        'videoCodec': r.videoCodec,
        'outputPath': r.outputPath,
        'status': r.status.name,
        'errorCode': r.errorCode,
        'verification': r.verification == null
            ? null
            : {
                'completed': r.verification!.completed,
                'video': r.verification!.videoIdentical,
                'audio': r.verification!.audioIdentical,
                'detail': r.verification!.detail,
              },
        'integrity': r.integrity == null
            ? null
            : {
                'decodable': r.integrity!.decodable,
                'duration': r.integrity!.durationMatches,
                'resolution': r.integrity!.resolutionMatches,
                'audio': r.integrity!.audioMatches,
                'detail': r.integrity!.detail,
              },
      };

  static JobRecord _fromJson(Map<String, dynamic> m) {
    final v = m['verification'] as Map<String, dynamic>?;
    final i = m['integrity'] as Map<String, dynamic>?;
    return JobRecord(
      id: m['id'] as String,
      createdAt: DateTime.parse(m['createdAt'] as String),
      sourceName: m['sourceName'] as String,
      originalBytes: (m['originalBytes'] as num?)?.toInt() ?? 0,
      outputBytes: (m['outputBytes'] as num?)?.toInt() ?? 0,
      durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
      mode: CompressionMode.values.firstWhere(
        (e) => e.name == m['mode'],
        orElse: () => CompressionMode.highEfficiency,
      ),
      videoCodec: m['videoCodec'] as String? ?? 'unknown',
      outputPath: m['outputPath'] as String?,
      status: JobStatus.values.firstWhere(
        (e) => e.name == m['status'],
        orElse: () => JobStatus.completed,
      ),
      errorCode: m['errorCode'] as String?,
      verification: v == null
          ? null
          : VerificationResult(
              completed: v['completed'] == true,
              videoIdentical: v['video'] == true,
              audioIdentical: v['audio'] == true,
              detail: v['detail'] as String?,
            ),
      integrity: i == null
          ? null
          : IntegrityResult(
              decodable: i['decodable'] == true,
              durationMatches: i['duration'] == true,
              resolutionMatches: i['resolution'] == true,
              audioMatches: i['audio'] == true,
              detail: i['detail'] as String?,
            ),
    );
  }
}
