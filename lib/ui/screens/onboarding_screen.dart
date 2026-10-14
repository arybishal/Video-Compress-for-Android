import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lightweight, swipeable first-launch onboarding walkthrough.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.onFinished,
    this.isReplay = false,
  });

  final VoidCallback onFinished;
  final bool isReplay;

  /// SharedPreferences key recording whether onboarding was seen.
  static const String prefKey = 'onboarding_completed_v1';

  /// Marks onboarding completed in persistent storage.
  static Future<void> markCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, true);
  }

  /// Checks whether onboarding has been completed.
  static Future<bool> isCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefKey) ?? false;
  }

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  static const int _numPages = 4;

  void _finish() async {
    if (!widget.isReplay) {
      await OnboardingScreen.markCompleted();
    }
    widget.onFinished();
  }

  void _next() {
    if (_currentPage < _numPages - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _finish();
    }
  }

  void _back() {
    if (_currentPage > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLastPage = _currentPage == _numPages - 1;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        actions: [
          if (!isLastPage)
            TextButton(
              onPressed: _finish,
              child: const Text('Skip'),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (idx) => setState(() => _currentPage = idx),
                children: const [
                  _SlideWelcome(),
                  _SlidePicker(),
                  _SlideModes(),
                  _SlideProcess(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Row(
                children: [
                  // Back button
                  if (_currentPage > 0)
                    OutlinedButton(
                      onPressed: _back,
                      child: const Text('Back'),
                    )
                  else
                    const SizedBox(width: 80),
                  const Spacer(),
                  // Dots indicator
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(_numPages, (i) {
                      final active = i == _currentPage;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        height: 8,
                        width: active ? 24 : 8,
                        decoration: BoxDecoration(
                          color: active
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      );
                    }),
                  ),
                  const Spacer(),
                  // Next / Get Started button
                  FilledButton(
                    onPressed: _next,
                    child: Text(isLastPage ? 'Get Started' : 'Next'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SlideWelcome extends StatelessWidget {
  const _SlideWelcome();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Image.asset(
                  'assets/images/logo.png',
                  width: 140,
                  height: 140,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => Container(
                    width: 140,
                    height: 140,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Icon(Icons.video_collection,
                        size: 64, color: theme.colorScheme.primary),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Text(
                'Welcome to PureCompress',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                '100% on-device video compression and remuxing. Your videos never leave your phone — zero cloud, zero accounts, and zero tracking.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withAlpha(128),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.shield_outlined,
                        size: 20, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Powered by local native FFmpeg',
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SlidePicker extends StatelessWidget {
  const _SlidePicker();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withAlpha(150),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.folder_open_rounded,
                  size: 60,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 32),
              Text(
                'Select Your Video',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                "Use Android's system file picker or photo picker to choose which video to process. PureCompress only accesses the specific file you pick and never scans your whole storage.",
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.lock_outline,
                          size: 24, color: theme.colorScheme.secondary),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          'Your original video is strictly read-only and will never be modified or overwritten.',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SlideModes extends StatelessWidget {
  const _SlideModes();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Choose Your Mode',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Tailor output size and quality to your needs:',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              _ModeExplainer(
                icon: Icons.all_inclusive_rounded,
                title: 'Exact Lossless',
                description:
                    'Stream copy preserves existing audio/video packets without re-encoding (no quality loss, minor size change). FrameMD5 fingerprinting verifies exact stream equality.',
                badge: 'Verified',
              ),
              const SizedBox(height: 12),
              _ModeExplainer(
                icon: Icons.bolt_rounded,
                title: 'High Efficiency',
                description:
                    'Lossy CRF rate control using H.264, HEVC / H.265, or AV1. Balances noticeable size reduction with high visual fidelity.',
                badge: 'Recommended',
              ),
              const SizedBox(height: 12),
              _ModeExplainer(
                icon: Icons.tune_rounded,
                title: 'Custom',
                description:
                    'Take full control: configure target bitrates, custom resolutions, frame rates, audio actions, and containers (MP4 / MKV).',
                badge: 'Advanced',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeExplainer extends StatelessWidget {
  const _ModeExplainer({
    required this.icon,
    required this.title,
    required this.description,
    required this.badge,
  });

  final IconData icon;
  final String title;
  final String description;
  final String badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: theme.colorScheme.primary, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(title,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          badge,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SlideProcess extends StatelessWidget {
  const _SlideProcess();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withAlpha(150),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.save_alt_rounded,
                  size: 60,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 32),
              Text(
                'Process, Verify & Save',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                'Watch real engine progress and cancel safely anytime. Once finished, verify the output and export it directly to your Movies library or share it via your favorite apps.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_outline,
                          size: 24, color: theme.colorScheme.primary),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          'Detailed diagnostics and honest byte metrics are always available in Settings if you ever need them.',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
