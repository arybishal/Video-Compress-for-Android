import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/compression_preset.dart';

/// Manages persistence and retrieval of built-in and user-defined compression presets.
class PresetRepository {
  PresetRepository({SharedPreferences? prefs}) {
    _prefs = prefs;
  }

  static const String prefsKey = 'purecompress_custom_presets_v1';

  SharedPreferences? _prefs;

  Future<SharedPreferences> _getPrefs() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  /// Returns all available presets (built-in presets plus user-created custom presets).
  Future<List<CompressionPreset>> loadPresets() async {
    final prefs = await _getPrefs();
    final customJsonList = prefs.getStringList(prefsKey) ?? [];

    final customPresets = <CompressionPreset>[];
    for (final jsonStr in customJsonList) {
      try {
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        customPresets.add(CompressionPreset.fromJson(map));
      } catch (_) {
        // Skip corrupted entries
      }
    }

    return [...CompressionPreset.builtInPresets, ...customPresets];
  }

  /// Saves a custom preset. If a preset with the same id already exists, it is updated.
  Future<void> saveCustomPreset(CompressionPreset preset) async {
    if (preset.isBuiltIn) {
      throw ArgumentError('Cannot overwrite a built-in preset directly.');
    }
    final prefs = await _getPrefs();
    final customJsonList = prefs.getStringList(prefsKey) ?? [];

    final customPresets = <CompressionPreset>[];
    for (final jsonStr in customJsonList) {
      try {
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        final p = CompressionPreset.fromJson(map);
        if (p.id != preset.id) {
          customPresets.add(p);
        }
      } catch (_) {}
    }

    customPresets.add(preset);

    final updatedJsonList =
        customPresets.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(prefsKey, updatedJsonList);
  }

  /// Deletes a custom preset by [id].
  Future<bool> deleteCustomPreset(String id) async {
    final prefs = await _getPrefs();
    final customJsonList = prefs.getStringList(prefsKey) ?? [];

    final remaining = <String>[];
    var removed = false;
    for (final jsonStr in customJsonList) {
      try {
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        if (map['id'] == id) {
          removed = true;
          continue;
        }
        remaining.add(jsonStr);
      } catch (_) {}
    }

    if (removed) {
      await prefs.setStringList(prefsKey, remaining);
    }
    return removed;
  }

  /// Clears all custom presets, reverting to built-in presets only.
  Future<void> resetToDefaults() async {
    final prefs = await _getPrefs();
    await prefs.remove(prefsKey);
  }

  /// Restores any missing default presets while preserving user custom presets.
  Future<List<CompressionPreset>> restoreMissingDefaults() async {
    return loadPresets();
  }
}
