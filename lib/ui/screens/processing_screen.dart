import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../main.dart';
import '../../models/models.dart';
import '../../services/compression_controller.dart';
import '../../services/ffmpeg_service.dart';
import '../format.dart';
import 'results_screen.dart';

/// Runs the job and reports real progress. Percent is shown only when the
/// engine reports an exact position; otherwise an indeterminate bar plus the
/// current stage is shown. Cancel stops the encode and cleans up.
class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({
    super.key,
    required this.sourcePath,
    required this.sourceName,
    required this.media,
    required this.settings,
  });

  final String sourcePath;
  final String sourceName;
  final MediaInfo media;
  final CompressionSettings settings;

  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  final _elapsed = Stopwatch();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _elapsed.start();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _start();
  }

  Future<void> _start() async {
    final controller = AppServices.compressionController;
    final record = await controller.run(
      sourcePath: widget.sourcePath,
      sourceName: widget.sourceName,
      media: widget.media,
      settings: widget.settings,
    );
    _ticker?.cancel();
    _elapsed.stop();
    if (!mounted) return;
    if (record.status == JobStatus.completed) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => ResultsScreen(record: record),
      ));
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppServices.compressionController;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final p = controller.progress;
        final failed = controller.status == JobStatus.failed;
        final cancelled = controller.status == JobStatus.cancelled;

        if (failed || cancelled) {
          return _FailureView(
            cancelled: cancelled,
            error: controller.error,
            diagnosticId: controller.lastDiagnosticId,
            diagnosticPath: controller.lastDiagnosticPath,
          );
        }

        final percent = p?.percent;
        final eta = _eta(controller, percent);
        return PopScope(
          canPop: false, // one active job; leaving requires explicit cancel
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Compressing'),
              automaticallyImplyLeading: false,
            ),
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Spacer(),
                  Text(widget.sourceName,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 32),
                  if (percent != null)
                    SizedBox(
                      height: 10,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(value: percent),
                      ),
                    )
                  else
                    const SizedBox(
                        height: 10, child: LinearProgressIndicator()),
                  const SizedBox(height: 16),
                  Text(
                    p?.stageLabel ?? 'Preparing',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  if (percent != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${(percent * 100).toStringAsFixed(1)}%',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ],
                  const SizedBox(height: 24),
                  _StatsRow(
                    elapsed: _elapsed.elapsed,
                    speed: p?.speed,
                    eta: eta,
                  ),
                  const Spacer(),
                  Text(
                    'Keep the app open while compressing. '
                    'The original file is never modified.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Theme.of(context).colorScheme.outline),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () => _confirmCancel(context, controller),
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Duration? _eta(CompressionController controller, double? percent) {
    final speed = controller.progress?.speed;
    if (percent == null || speed == null || speed <= 0) return null;
    final elapsed = _elapsed.elapsed;
    if (elapsed.inSeconds < 3) return null;
    final totalSeconds = elapsed.inSeconds / percent.clamp(0.01, 1.0);
    final remaining = totalSeconds - elapsed.inSeconds;
    if (remaining <= 0) return null;
    return Duration(seconds: remaining.round());
  }

  Future<void> _confirmCancel(
      BuildContext context, CompressionController controller) async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel compression?'),
        content: const Text(
            'The incomplete output will be deleted. Your original video is untouched.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep going')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cancel job')),
        ],
      ),
    );
    if (proceed == true) await controller.cancel();
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.elapsed, this.speed, this.eta});
  final Duration elapsed;
  final double? speed;
  final Duration? eta;

  @override
  Widget build(BuildContext context) {
    Widget stat(String label, String value) => Expanded(
          child: Column(
            children: [
              Text(value,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        );
    return Row(
      children: [
        stat('Elapsed', formatDuration(elapsed.inMilliseconds / 1000)),
        stat('Speed', speed != null && speed! > 0 ? '${speed!.toStringAsFixed(1)}×' : '—'),
        stat('Remaining', eta != null ? formatEta(eta!) : '—'),
      ],
    );
  }
}

class _FailureView extends StatelessWidget {
  const _FailureView({
    required this.cancelled,
    this.error,
    this.diagnosticId,
    this.diagnosticPath,
  });
  final bool cancelled;
  final FfmpegException? error;
  final String? diagnosticId;
  final String? diagnosticPath;

  Future<void> _shareLog(BuildContext context) async {
    final path = diagnosticPath;
    if (path == null) return;
    try {
      await SharePlus.instance.share(ShareParams(
        files: [XFile(path, mimeType: 'text/plain')],
        title: 'PureCompress diagnostic log',
      ));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not share the diagnostic log: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(cancelled ? 'Cancelled' : 'Compression failed')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                cancelled ? Icons.block : Icons.error_outline,
                size: 52,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                cancelled
                    ? 'Compression was cancelled and the temporary output was deleted. '
                        'Your original video is untouched.'
                    : (error?.userMessage ??
                        'Processing failed. Your original video is untouched.'),
                textAlign: TextAlign.center,
              ),
              if (!cancelled && diagnosticId != null) ...[
                const SizedBox(height: 16),
                Text(
                  'Diagnostic ID: $diagnosticId',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontFamily: 'monospace'),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Back'),
              ),
              if (!cancelled && diagnosticPath != null) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => _shareLog(context),
                  icon: const Icon(Icons.bug_report_outlined),
                  label: const Text('Share diagnostic log'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
