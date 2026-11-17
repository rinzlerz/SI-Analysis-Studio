# SI Studio - one-time Android project setup (Windows PowerShell).
# Generates the android/ platform folder around the existing lib/ and test/
# sources (existing files are not overwritten), installs packages and runs tests.
$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  Write-Error 'Flutter is not on PATH. Install Flutter (https://docs.flutter.dev/get-started/install) and reopen the terminal.'
}

flutter --version

if (-not (Test-Path 'android')) {
  flutter create --platforms=android --org com.sistudio --project-name si_studio .
}

$manifest = 'android/app/src/main/AndroidManifest.xml'
if (Test-Path $manifest) {
  (Get-Content $manifest -Raw) -replace 'android:label="si_studio"', 'android:label="SI Studio"' |
    Set-Content $manifest -NoNewline
}

flutter pub get
flutter test

Write-Host ''
Write-Host 'Setup complete. Next:' -ForegroundColor Green
Write-Host '  flutter run                   # run on a connected device / emulator'
Write-Host '  flutter build apk --release   # build\app\outputs\flutter-apk\app-release.apk'
