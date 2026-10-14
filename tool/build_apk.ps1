# Build script for PureCompress (Windows).
# Usage:
#   powershell -File tool\build_apk.ps1            # debug APK
#   powershell -File tool\build_apk.ps1 -Release   # release APK (debug-signed
#                                                  # unless android/key.properties exists)
param([switch]$Release)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

# Toolchain locations for this machine (adjust if yours differ).
if (-not $env:FLUTTER_HOME) { $env:FLUTTER_HOME = 'C:\flutter' }
if (-not $env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT = 'D:\SDK' }
$env:ANDROID_HOME = $env:ANDROID_SDK_ROOT
$studioJbr = 'C:\Program Files\Android\Android Studio\jbr'
if (Test-Path $studioJbr) { $env:JAVA_HOME = $studioJbr }
$env:Path = "$env:Path;$env:FLUTTER_HOME\bin"

Push-Location $repo
try {
    flutter pub get
    flutter analyze
    if ($LASTEXITCODE -ne 0) { throw 'flutter analyze reported issues' }
    flutter test
    if ($LASTEXITCODE -ne 0) { throw 'tests failed' }
    if ($Release) {
        flutter build apk --release
    } else {
        flutter build apk --debug
    }
    if ($LASTEXITCODE -ne 0) { throw 'build failed' }
    Get-ChildItem 'build\app\outputs\flutter-apk\*.apk' |
        Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
} finally {
    Pop-Location
}
