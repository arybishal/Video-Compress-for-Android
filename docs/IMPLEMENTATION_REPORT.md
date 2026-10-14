# PureCompress — Implementation Report

Stage-by-stage record of the build of PureCompress, an offline-only Android
video-compression app (Flutter + FFmpeg), in this repository.

## Environment

- Flutter 3.47.7 at `C:\flutter` (official archive, SHA-256 verified).
- Android SDK at `D:\SDK` (cmdline-tools `latest`, platform android-36,
  build-tools 36.0.0, NDK 28.2). Debug and release APKs built with the
  Android Studio JBR (JDK 21).
- Gradle 9.3.1 wrapper / AGP 9.1.0 (Flutter 3.47 template defaults).

## Stage 1 — Inspection

The repo contained a minimal native-Android template. The user approved
replacing it with a Flutter project at the repo root, keeping the original
application id `com.pvideocompress.smedia`, minSdk 24 and the app label
"PureCompress".

## Stage 2 — Scaffold

Flutter project created at the repo root; branding centralized in
`lib/theme` + `lib/config/app_config.dart`; manifest declares no
`INTERNET` permission and no exported components beyond the launcher
activity. `MainActivity.kt` registers a `purecompress/native` method
channel (pick video via SAF, export via MediaStore, open-with via
FileProvider, free-space query).

## Stage 3 — Probe

`MediaProbeService` runs FFmpeg (`-hide_banner -i <file>`) and parses
container, duration, per-stream codec/bitrate/resolution/rate into
`MediaProbe`. Parsing is pure Dart and unit-tested against captured
`ffprobe`-style outputs (H.264/HEVC/AV1, audio-only, no-video).

## Stage 4 — Exact Lossless

Default path is a **remux** (`-c copy -map 0:v? -map 0:a?`), i.e. no
re-encoding, so video is bit-identical by construction. Optional true
lossless re-encode (`-crf 0` libx264) is offered explicitly. Losslessness
is never claimed from exit codes: `VerificationService` fingerprints both
original and output with framemd5 and compares decoded-frame hashes in
Dart (PTS columns ignored, ≤8 audio priming frames tolerated,
head/tail alignment).

## Stage 5 — High Efficiency

Bitrate presets capped at 85 % of the measured source video bitrate.
Encoder selection: hardware `h264_mediacodec` / `hevc_mediacodec` only
after a runtime probe confirms availability; otherwise software
`libx264` / `libx265` / `libsvtav1`. `JobPlanner` builds the full FFmpeg
argument list; every argument is covered by unit tests.

## Stage 6 — Custom

CRF / target-size / custom-bitrate inputs are validated by
`SettingsValidator` (bounds, impossible combinations, free-disk space)
before a job is created. Untouched streams (subs/data) are not silently
dropped: the plan either maps them losslessly or records why they are
excluded.

## Stage 7 — Progress / Export / Results

Progress is parsed from FFmpeg's `-progress pipe:1` output — real frame
and time values only, never a fabricated percentage. Finished files are
exported to `Movies/PureCompress` via MediaStore (`IS_PENDING` flow, no
storage permission), shareable via `share_plus`, and openable in external
players via the FileProvider. Originals are never modified or deleted;
temp copies live in the app cache and are cleaned by `TempManager`.
History is persisted with `shared_preferences` (`JobRepository`).

## Stage 8 — Tests

`flutter analyze`: **No issues found.**
`flutter test`: **67/67 passing** — probe parsing, settings validation,
job-planner arguments, size/format math, temp management, job
repository, verification comparison and error mapping, widget smoke.

**Not run / could not be run:** no Android device or emulator was attached
to the build machine, so on-device integration (real encodes, hardware
codec probing, MediaStore export, SAF picking) could not be executed in
this environment. These paths are covered by unit tests only and must be
smoke-tested on a physical device before release.

## Stage 9 — APK

- Debug APK: `build/app/outputs/flutter-apk/app-debug.apk` — **322.1 MB**
  (debug build: all ABIs, debug symbols, engine validation layer).
- Release APK: `build/app/outputs/flutter-apk/app-release.apk` — **218.5 MB**
  (still all ABIs + full GPL FFmpeg feature set; use `--split-per-abi`
  to reduce size).
- Package name verified as `com.pvideocompress.smedia`.
- Release signing is driven by `android/key.properties` (git-ignored);
  without that file release builds fall back to the debug key.

### Build issues found and fixed along the way

1. `D:\SDK\platforms\android-36` existed but was **incomplete (no
   `android.jar`)**, which surfaced as AGP's
   "Cannot query the value of this provider because it has no value
   available" on `:app:compileDebugJavaWithJavac`. Reinstalled the
   platform with sdkmanager.
2. `file_picker` was dropped: its `android_file_picker` 2.1.0 pins
   AGP 8.5.2 inside this AGP 9.1 build (flutter/flutter#180137). Picking
   is now native SAF in `MainActivity.kt`.
3. `registerForActivityResult` is unavailable on `FlutterActivity` (not a
   `ComponentActivity` here); switched the picker to
   `startActivityForResult` / `onActivityResult`.

## Known limitations (honest list)

- No foreground service: leaving the app mid-encode may have the OS kill
  the process (the temp file is cleaned, the original is untouched, but
  the job is lost).
- No in-app preview player; playback uses external players via ACTION_VIEW.
- Lossless verification compares decoded fingerprints, not container
  bytes — that is the correct test for "visually/decodably lossless"
  and for remux identity of the video stream.
- Only tested here by unit tests and builds; on-device behavior requires
  a manual QA pass.

---

# Round 2 — Full mode set (A–G), verified encoder usage, lossy integrity

## Packaged-FFmpeg verification (offline, from the actual AAR)

The `ffmpeg-kit-full-gpl:2.2.3` AAR from the Gradle cache was unpacked and
the arm64 `libavcodec.so` / `libavformat.so` strings inspected. This is the
**actual binary shipped in the APK**, not a desktop assumption:

| Encoder / feature | In build |
|---|---|
| `libx264` | ✅ |
| `libx265` (param table contains `lossless`) | ✅ |
| `libaom-av1` (libaom 3.6.1, AVOption "Lossless mode") | ✅ |
| `libsvtav1`, `librav1e` | ❌ not included |
| `h264_mediacodec`, `hevc_mediacodec`, `av1_mediacodec` | ✅ (device support varies) |
| `framemd5` muxer (libavformat) | ✅ |
| FFmpeg version | **n8.1.2** |

**Bug found and fixed:** the planner previously emitted `-c:v libsvtav1`,
which is *not in this build* — every AV1 encode would have failed with
"Unknown encoder". AV1 now uses `libaom-av1` (with `-b:v 0` for CRF mode
and `-cpu-used` instead of `-preset`); libsvtav1 remains supported only for
hypothetical builds that contain it instead. A second latent bug was fixed
in `-encoders` parsing (it read the last word of the description column, so
every encoder lookup missed; it now parses the name column with a tested
regex).

## Exact commands per mode

Arguments are always passed as an explicit list via
`FFmpegKit.executeWithArguments` (no shell, no user command strings).
Common suffix: `-y -i <in> -map 0:v? -map 0:a? … [audio args]
[-movflags +faststart for MP4] -map_metadata 0|-1 <out>`.

| Mode | Video arguments |
|---|---|
| Stream copy (remux) | `-c copy` (+ `-c:s mov_text` for MP4 subtitles, `-map 0:s?` for MKV) |
| B — H.264 lossless | `-c:v libx264 -preset medium -crf 0 -pix_fmt <src>` |
| D — HEVC lossless | `-c:v libx265 -preset medium -x265-params lossless=1 -pix_fmt yuv420p` |
| F — AV1 lossless | `-c:v libaom-av1 -lossless 1 -b:v 0 -cpu-used 5 -pix_fmt <src>` |
| A — H.264 CRF | `-c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p` |
| C — HEVC CRF | `-c:v libx265 -preset medium -crf 26 -pix_fmt yuv420p` |
| G — HEVC low CRF | `-c:v libx265 -preset medium -crf 18 -pix_fmt yuv420p` |
| E — AV1 CRF | `-c:v libaom-av1 -crf 30 -b:v 0 -cpu-used 5 -pix_fmt yuv420p` |
| Custom bitrate | `h264_mediacodec`/`hevc_mediacodec` `-b:v Nk -maxrate -bufsize`, or software `libx264/libx265/libaom-av1 -b:v Nk` |

Verification stages (lossless): `-i <file> -map 0:v? -map 0:a? -f framemd5
<file>` for source and output, hashes compared in Dart.

## Honest-lossless rules implemented

- Lossless re-encode offered only for 8-bit sources; 10/12-bit sources are
  remux-only with an explanation.
- Pixel format pinned (`-pix_fmt` = source format); encoders/pixel formats
  that cannot preserve it are **disabled in the UI with the exact reason**
  (e.g. packaged libx265 handles yuv420p only) — never silently converted.
- No downscale/fps filter can be combined with any lossless mode (validator
  blocking error).
- The claim "lossless" is only ever shown after framemd5 decoded-frame
  equality succeeds; failed or incomplete verification is displayed as
  such.
- AV1 lossless uses libaom's dedicated `-lossless 1` mode (verified present
  in this build's binary); CRF 0 alone is never assumed lossless.
- Negative savings (lossless output larger than source) are displayed as a
  size increase, as before.

## Lossy verification (new)

After every lossy job the output is re-probed and checked: decodable,
duration within max(1 s, 3%) of source, resolution as requested, audio
presence as configured. The result is stored on the job record and shown
on the Results screen as "Output verified playable" — explicitly not a
losslessness claim.

## Round-2 test results

`flutter analyze`: **No issues found.** `flutter test`: **93/93 passing**
(67 previous + mode A–G planner args, lossless-per-codec configs, encoder
absence errors, CRF bounds, `-encoders` parsing, capability mirror,
lossy integrity checks, cancellation + temp cleanup).

## Round-2 known limitations / not run

- **No real device encode was executed**: the build machine has no attached
  device, and its emulator cannot boot — the Android Emulator hypervisor
  driver (WHPX/KVM) is not installed and enabling it needs admin rights and
  a reboot; software-mode boot of the x86_64 image was attempted but does
  not reach a usable state in reasonable time. All encoder behavior is
  therefore verified by: binary inspection of the shipped libraries,
  unit-tested command generation, and runtime capability detection — the
  framemd5/integrity checks then confirm every real job on-device.
- AV1 (libaom) encoding is slow on phones; the UI warns and the encoder
  speed preset maps to `-cpu-used`.
- To enable libsvtav1 instead, the FFmpeg build would have to change
  (ffmpeg-kit script + svtAV1 dependency); nothing in the app assumes it.


# Round 3 — Compression-failure diagnosis, real error surfacing & diagnostics

## Reported symptom

Pressing **Start Compression** ended every job with:

> Processing failed unexpectedly. The original file was not modified.

The same string existed in **two** code paths, which is exactly why the message
was useless: every unrecognised failure collapsed into it while the real cause
was thrown away.

## Root causes found (in order discovered)

1. **The APK could not even be built.** The interrupted Round-2 MediaCodec
   groundwork left an unwired `android/.../MediaCodecEncoder.kt` calling
   `MediaCodec.createByType(mime, MediaCodec.Encoder)` — neither symbol
   exists in the Android SDK (the real API is `createEncoderByType`).
   One unresolved call cascaded into 14 Kotlin errors, so
   `flutter build apk` failed outright.
   *Fix:* use `MediaCodec.createEncoderByType(mime)`; build green.

2. **The failure mapper often never saw the engine's error text.**
   `FfmpegService.run()` fed `mapFfmpegFailure` only
   `session.getOutput()`, while `raw` came from `getFailStackTrace()`
   — which is **null for normal non-zero exits**. ffmpeg prints its errors
   through *av_log → stderr*, which ffmpeg-kit captures into the **session
   log channel** (`getAllLogsAsString`), not reliably into `getOutput()`.
   With an empty `err` string no pattern matches, so the default branch
   returned exactly the reported generic message for *any* engine failure
   (missing encoder, broken pipe, corrupt input, …).
   *Evidence:* binary inspection of the shipped `libffmpegkit.so` shows
   `av_log_set_callback` imported and **no** `dup2`/`pipe` fd-redirect
   symbols — the two channels are genuinely separate.
   *Fix:* `FfmpegService.mergeSessionText(getOutput, getAllLogsAsString)`
   now feeds `run()`, `detectCapabilities()` and `probe()` failure text;
   `mapFfmpegFailure` stores the full console in `raw`.
   Unit test reproduces the exact reported string from an empty-channel
   result and shows the same failure maps to the real cause once merged.

3. **The generic `catch` swallowed Dart exceptions.**
   `catch (e)` discarded the exception identity and stack. Planner
   `ArgumentError` guard-rails (which carry precise messages) surfaced as
   the same generic text.
   *Fix:* `catch (e, st)` records the exception + full stack in the
   diagnostic log and shows `Compression failed unexpectedly. Diagnostic ID: …`;
   `on ArgumentError` now surfaces the planner's own message.

4. **Validation could start a job the build cannot run.**
   The encoder-availability condition was
   `(needHw && !hw) && (needSw && !sw)` — in CRF mode `needHw` is
   `false`, so the branch could **never fire**: a device/build with no
   usable encoder still passed Start and guaranteed a failing encode (which
   then hit cause 2). Forcing Hardware with no hardware encoder had the same
   hole.
   *Fix:* block unless `((needHw && hwAvailable) || (needSw && swAvailable))`,
   with a specific message for forced-hardware-without-hardware.

5. **New engine-error patterns** (previously all generic): broken pipe /
   `av_interleaved_write_frame` / error-muxing → storage-write advice;
   allocation failure → out-of-memory advice; `error opening input` →
   corrupt/unsupported input advice. The unknown fallback now keeps the real
   console tail in `raw` and the controller appends the diagnostic id.

## Diagnostic logging added (`lib/services/diagnostic_log.dart`)

One file per job under `<temp>/diagnostics/<jobId>.log`, written
best-effort (logging can never break a job), kept only for failures,
rotated to the newest 5, capped at 256 KB, `content://` URIs redacted.
It records, per the task checklist: full settings; source path/exists/size
(probe-reported + filesystem), format, duration, codec/resolution/fps;
capability detection; job dir, output path, free bytes; the **exact ffmpeg
argument list per stage**; engine console tail + return code per stage;
auto-hardware-fallback flag; lossless-verification / integrity results;
output file creation + finalisation status; and on failure the error kind,
message and **full stack trace**. Nothing is shown to users as a stack
trace — they see a one-line message plus a **Diagnostic ID** (== job id)
and a *Share diagnostic log* button on the failure screen.

## Changed files

- `android/.../MediaCodecEncoder.kt` — compile fix (`createEncoderByType`)
- `lib/services/ffmpeg_service.dart` — `mergeSessionText`, richer
  `mapFfmpegFailure`, full console in `raw`, new `outOfMemory` kind
- `lib/services/diagnostic_log.dart` — new
- `lib/services/compression_controller.dart` — diagnostics capture,
  three-way catch (Ffmpeg / ArgumentError / unexpected), `_fail` helper,
  `lastDiagnosticId`/`lastDiagnosticPath`, log discard on success+cancel
- `lib/services/settings_validator.dart` — encoder-availability gating fix
- `lib/ui/screens/processing_screen.dart` — diagnostic id + share button
- `test/diagnostics_test.dart` — 14 new tests
- `docs/` (this file, ARCHITECTURE, README)

## Commands executed

`
flutter analyze          -> No issues found!
flutter test             -> 107/107 passing (93 previous + 14 new)
flutter build apk --debug -> √ build\app\outputs\flutter-apk\app-debug.apk
`

## Verification honesty (device testing)

- **No device or emulator run was possible on this machine.** No USB device
  is attached; the AVD cannot boot because the hypervisor driver
  (WHPX) is missing (installing it needs admin + reboot); a software-mode
  boot was retried for >1 h and never reached `adb` online, so it was
  terminated. Therefore the *per-mode on-device encode matrix* (sizes,
  durations, playback, cancellation, storage pressure) was **not executed**
  and is not claimed.
- What was verified instead:
  - the **exact reported message** is reproduced from the pre-fix code path
    by test (empty console channel → default branch);
  - the fixed path maps real FFmpeg error strings to specific messages
    (unknown encoder, no space, moov, permission, broken pipe, OOM,
    invalid input) by test;
  - the validator now blocks CRF/hardware jobs with no available encoder by
    test;
  - a full controller run (fake engine) writes the complete diagnostic
    trail, records the right `errorCode`, shows the specific message with
    a Diagnostic ID, and discards the log on success — all by test;
  - the packaged FFmpeg really contains libx264/libx265/libaom-av1/framemd5
    (Round-2 AAR inspection), and the app still builds an installable APK.

## Round-3 remaining issues / not done

- The MediaCodec native encoder file is now compiling but still **unwired**
  (no platform-channel handler); the FFmpeg pipeline is the only active
  engine, exactly as before this round.
- On-device test matrix for all modes still pending a real device.