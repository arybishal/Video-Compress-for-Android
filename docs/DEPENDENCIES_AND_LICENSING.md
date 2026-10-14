# Dependencies & Licensing

## Flutter / Dart

- Flutter 3.47.7 stable (Dart 3.13.5) — BSD-3-Clause.
- minSdk 24 (engine requirement), app effectively targets Android 10+ (API 29)
  because MediaStore export uses the IS_PENDING flow. compileSdk/targetSdk:
  Flutter default (36+).

## Runtime dependencies (pubspec.yaml)

| Package | Version | License | Maintenance | Role | Notes |
|---|---|---|---|---|---|
| `ffmpeg_kit_flutter_new` | 4.6.7 (2026-10-05) | LGPL-3.0 (wrapper) + **GPL-3.0** (FFmpeg full-gpl binaries) | Active — community continuation of the retired ffmpeg-kit (official repo archived July 2026); repo: github.com/sk3llo/ffmpeg_kit_flutter | ffprobe probing, stream copy, lossless libx264 encode, lossy software encode, MediaCodec hardware encode, framemd5 verification | Ships maven artifact `com.antonkarpenko:ffmpeg-kit-full-gpl:2.2.3`. **Risk:** third-party fork, single maintainer — mitigated by pinned version and by keeping all engine calls behind `FfmpegService` (swap point). |
| `share_plus` | 13.3.1 | MIT | Very active (fluttercommunity plus_plugins) | Share finished files | |
| `path_provider` | 2.1.6 | BSD-3-Clause | Very active (fluttercommunity) | Temp/cache directories | |
| `shared_preferences` | 2.5.6 | BSD-3-Clause | Google/Flutter team | Settings + job history | |

**Removed after build failure:** `file_picker` (→ its Android module
`android_file_picker` 2.1.0 pins its own AGP 8.5.2 classpath inside an AGP 9.1
build, breaking `compileDebugJavaWithJavac`; upstream issue referenced in its
own source: flutter/flutter#180137). Replaced by ~60 lines of SAF picking in
`MainActivity.kt` (`ACTION_GET_CONTENT video/*` + cache copy) — same system
picker UX, one less dependency chain.

## FFmpeg build contents (full GPL)

Included encoders used by the app: `libx264`, `libx265`, `libaom-av1`
(AV1 — **libsvtav1 is not included** in this build), `h264_mediacodec`,
`hevc_mediacodec`, `av1_mediacodec`, `aac`, `flac`, `libopus`; muxers `mp4`,
`matroska`; analysis `ffprobe`, `framemd5`.

### Obligations (full GPL binaries)

1. **GPL-3.0 applies to the distributed APK** — source of the app covering the
   combined work must be offered (this repository fulfills that), and the
   license text must be included (`ffmpeg_kit_flutter_new` ships
   LICENSE.GPLv3; keep NOTICE text in release notes).
2. **No proprietary app-store restriction** — GPL is fine for Play Store
   distribution of open-source apps; it does not allow adding extra
   restrictions beyond GPL.
3. Alternative if a smaller/LGPL-only APK is ever required: use the
   `ffmpeg_kit_flutter_new_min` variant (loses libx264/libx265 → lossless
   re-encode and software HEVC would be dropped; remux + MediaCodec HE remain).

## Native binary size

The full-gpl native libraries are ~70–90 MB unpacked across ABIs. The debug
APK built here is a fat APK (all ABIs). For release, ABI splits are enabled by
Flutter automatically per-ABI APKs (`flutter build apk --split-per-abi`) or an
AAB (Play serves per-device splits). Typical per-device download: ~20–30 MB.

## Hardware acceleration claims

The app never assumes hardware encoding. At startup the engine's `-encoders`
output is parsed; `h264_mediacodec` / `hevc_mediacodec` are offered only when
the FFmpeg build lists them. Whether the *device* encoder actually engages is
confirmed only by a successful encode session; on failure the app reports the
hardware-encoder error and auto mode retries software.

## What the app does NOT contain

- No INTERNET permission (verify in the merged manifest).
- No analytics, ads, auth, crash reporters, or subscription code.
- No network calls of any kind in Dart or Kotlin sources.
