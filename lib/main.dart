import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config/app_config.dart';
import 'services/compression_controller.dart';
import 'services/diagnostic_export_service.dart';
import 'services/ffmpeg_service.dart';
import 'services/job_repository.dart';
import 'services/native_exporter.dart';
import 'services/preset_repository.dart';
import 'services/temp_manager.dart';
import 'ui/screens/home_screen.dart';
import 'ui/screens/onboarding_screen.dart';
import 'ui/theme/app_theme.dart';

/// App-wide service wiring (all on-device; nothing leaves the phone).
class AppServices {
  AppServices._();

  static final ffmpeg = FfmpegService();
  static final tempManager = TempManager();
  static final jobRepository = JobRepository();
  static final exporter = NativeExporter();
  static final diagnosticExportService = DiagnosticExportService(
    tempManager: tempManager,
    jobRepository: jobRepository,
    ffmpeg: ffmpeg,
    exporter: exporter,
  );
  static final presetRepository = PresetRepository();
  static final compressionController = CompressionController(
    ffmpeg: ffmpeg,
    tempManager: tempManager,
    jobRepository: jobRepository,
    exporter: exporter,
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Reclaim temp working dirs and stale picked inputs from interrupted or
  // never-exported jobs.
  await AppServices.tempManager.cleanupOrphans().catchError((_) => 0);
  await AppServices.tempManager.cleanupPickedInputs().catchError((_) => 0);
  runApp(const PureCompressApp());
}

class PureCompressApp extends StatefulWidget {
  const PureCompressApp({super.key});

  @override
  State<PureCompressApp> createState() => _PureCompressAppState();
}

class _PureCompressAppState extends State<PureCompressApp> {
  ThemeMode _themeMode = ThemeMode.system;
  bool _historyEnabled = true;
  bool _onboardingCompleted = true; // default true until checked
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final completed = await OnboardingScreen.isCompleted();
    if (!mounted) return;
    setState(() {
      _themeMode = switch (prefs.getString('theme_mode')) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      _historyEnabled = prefs.getBool('history_enabled') ?? true;
      _onboardingCompleted = completed;
      _ready = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: _themeMode,
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _themeMode,
      home: _onboardingCompleted
          ? HomeScreen(
              historyEnabled: _historyEnabled,
              onThemeChanged: (mode) async {
                setState(() => _themeMode = mode);
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString('theme_mode', mode.name);
              },
              onHistoryToggled: (v) async {
                setState(() => _historyEnabled = v);
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool('history_enabled', v);
              },
            )
          : OnboardingScreen(
              onFinished: () => setState(() => _onboardingCompleted = true),
            ),
    );
  }
}
