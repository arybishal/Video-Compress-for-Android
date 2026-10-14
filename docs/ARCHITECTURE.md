# PureCompress — Architecture

## Principles

1. **Pure Dart core, thin engine wrapper.** Everything that decides *what* to
   run (probe parsing, validation, ffmpeg argument construction, verification
   comparison, size math, naming, history) is pure Dart → unit-tested on the
   host without a device.
2. **UI never touches ffmpeg directly.** Screens call services; services call
   the engine.
3. **No fabricated progress.** Percent comes from ffmpeg's `-progress`
   statistics only; otherwise the UI shows stage + indeterminate bar.
4. **Originals are immutable.** Work happens in `cacheDir/purecompress_jobs/<jobId>/`.

## Module map

```
lib/
├── config/app_config.dart        # branding, caps, privacy text (single place)
├── models/models.dart            # MediaInfo, StreamInfo, Settings, Plan,
│                                 # JobRecord, JobProgress, VerificationResult
├── services/
│   ├── media_probe.dart          # ffprobe JSON → MediaInfo (pure Dart)
│   ├── ffmpeg_service.dart       # engine wrapper: probe, run(args, stats),
│   │                             # cancel, capability detection, error mapping
│   ├── settings_validator.dart   # pre-flight validation (pure Dart)
│   ├── job_planner.dart          # mode → ffmpeg arg-list plan (pure Dart)
│   ├── verification_service.dart # framemd5 fingerprints + comparison
│   ├── compression_controller.dart # one-job orchestrator (ChangeNotifier)
│   ├── temp_manager.dart         # unique job dirs + orphan cleanup
│   ├── native_exporter.dart      # MethodChannel → MediaStore / ACTION_VIEW
│   └── job_repository.dart       # local history (SharedPreferences JSON)
└── ui/
    ├── theme/app_theme.dart      # M3 light/dark seeded from brand color
    ├── format.dart               # bytes/duration/percent formatting
    └── screens/
        ├── home_screen.dart      # select video, modes, privacy, history
        ├── analysis_screen.dart  # probe results + supported modes + storage
        ├── configure_screen.dart # per-mode controls + validation + estimate
        ├── processing_screen.dart# real progress, ETA, cancel
        ├── results_screen.dart   # honest savings, verification, save/share/play
        └── settings_screen.dart  # theme, history toggle/clear, about
```

Native (Kotlin) `MainActivity.kt` exposes channel `purecompress/native`:
`exportToMovies` (MediaStore IS_PENDING copy into Movies/PureCompress),
`openWith` (FileProvider + ACTION_VIEW), `freeBytes` (StatFs).

## Processing pipeline

```
pick (SAF) → probe (ffprobe JSON) → validate (mode × media × capabilities)
   → plan (arg lists) → free-space check → ffmpeg stage(s) [stats → progress]
   → (lossless modes) verify: framemd5(src) vs framemd5(out) → compare
   → finalize: sizes, JobRecord, history → user saves/shares/plays
```

### Mode strategies

- **Exact Lossless (stream copy / remux)** — `-map` all video/audio (+subs in
  MKV), `-c copy`, MP4 gets `-movflags +faststart` and `mov_text` subtitle
  conversion. Verification: decoded fingerprints must match (pts columns
  ignored; small audio priming shifts tolerated and reported). No
  re-encoding, so this never shrinks the video data itself.
- **Exact Lossless (re-encode, per codec)** — verified mathematically
  lossless configurations, 8-bit sources only, source pix_fmt pinned so no
  color conversion can alter samples:
  - H.264: `libx264 -crf 0 -preset <p>`
  - HEVC: `libx265 -preset <p> -x265-params lossless=1`
  - AV1: `libaom-av1 -lossless 1 -b:v 0 -cpu-used <n>`
  Audio copy or FLAC (MKV). Blocked for 10/12-bit sources and pixel formats
  the encoder cannot preserve. All are verified with decoded-frame
  comparison after encoding; losslessness is never assumed from args or
  exit codes.
- **High Efficiency (CRF)** — software CRF rate control (modes A/C/G/E):
  `libx264 -crf 23`, `libx265 -crf 26` / `-crf 18` (low-CRF high quality),
  `libaom-av1 -crf 30 -b:v 0 -cpu-used <n>`. CRF is a software-encoder
  feature (MediaCodec has no CRF), so CRF requests always select software.
  Resolution/frame rate preserved unless the user opts into downscaling.
  Explicitly labeled lossy; low CRF is never described as lossless.
- **Custom** — bitrate-based rate control (hardware
  `h264_mediacodec`/`hevc_mediacodec` preferred in auto mode; software
  `libx264`/`libx265`/`libaom-av1` fallback), plus validated stream copy.
  Illegal combinations (copy + downscale, fps above source, missing codec,
  CRF outside codec range) are blocking errors shown before start.
- **Lossy integrity check** — after every lossy encode the output is
  re-probed: decodable, duration within tolerance, expected resolution,
  audio presence. Reported as an integrity result, never as losslessness.

## Failure & lifecycle handling

- Every ffmpeg failure is mapped (storage / encoder / corrupt / permission /
  container / broken pipe / out of memory) to user-facing text. The mapper
  reads **both** ffmpeg-kit console channels (`getOutput()` +
  `getAllLogsAsString()`), so the real engine error always reaches it;
  unmapped failures keep the full console in `raw`.
- Each job writes a best-effort `DiagnosticLog`
  (`<temp>/diagnostics/<jobId>.log`): settings, source facts, capability
  detection, exact stage arguments, engine console tail + return code,
  storage state, verification/integrity results, output finalisation, and
  on failure the exception with its full stack. Kept only for failures,
  rotated to the newest 5, `content://` URIs redacted. The failure screen
  shows a Diagnostic ID (== job id) and can share the log; stacks are never
  shown to users.
- Cancel → session cancel → temp dir (incl. partial output) deleted and the
  job's diagnostic log discarded; original untouched; job recorded as
  cancelled.
- Process death → next launch `cleanupOrphans()` removes temp dirs older than
  24 h (also reclaims finished-but-never-saved outputs; the results screen
  explains this if it happens).
- One job at a time (single controller); PopScope blocks leaving mid-job
  without cancelling.

## Deliberate v1 cuts (documented, not hidden)

- No foreground service: jobs are foreground-UI-bound; Android process death
  mid-job is recovered by orphan cleanup + honest "interrupted" state.
  (Upgrade path: `flutter_foreground_task` + `FOREGROUND_SERVICE` permission.)
- No in-app video preview player (Play opens the file in the user's player via
  ACTION_VIEW; avoids adding a heavyweight player dependency).
- Multi-stage pipelines are planned (the model supports N stages) but all v1
  strategies are single-stage.
