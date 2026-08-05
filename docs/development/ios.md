<!-- SPDX-FileCopyrightText: 2026 Bora Yarkın -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# iOS Developer Target

The Flutter client includes an iOS host project for simulator or device
testing. This is a developer convenience target only. It is not part of the
portable release bundle and is not a supported deployment artifact.

When the app is built without a compile-time `API_BASE_URL`, the iOS/mobile
client now behaves like a generalized self-hosted app: on first launch it asks
for the company domain, verifies that an OpsAtlas backend is reachable there,
and only then proceeds to sign-in.

## Requirements

- macOS with Xcode installed
- CocoaPods
- an iOS simulator or connected iPhone/iPad
- Flutter stable with iOS support enabled

## Initial Setup

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
brew install cocoapods
cd client
flutter pub get
cd ios
pod install
```

Open `client/ios/Runner.xcworkspace` in Xcode for simulator or device builds.
Do not open `Runner.xcodeproj` directly after CocoaPods integration.

## Native Dependency Integration

Flutter 3.44+ can wire iOS plugins through both Swift Package Manager and
CocoaPods in the same project.

In this repo:

- `file_picker`, `pointer_interceptor_ios`, and
  `shared_preferences_foundation` are linked through Flutter's generated local
  Swift package.
- `flutter_inappwebview_ios` and `flutter_keyboard_visibility` still use
  CocoaPods because those plugins do not support Swift Package Manager yet.
- `client/ios/Runner.xcworkspace` is the correct Xcode entry point because it
  knows about the Pods project and the app project.

The Swift Package Manager lockfiles under `client/ios/**/swiftpm/Package.resolved`
are expected. The generated package under
`client/ios/Flutter/ephemeral/Packages/` is not committed and is recreated by
Flutter.

When plugin wiring looks stale, regenerate the native integration:

```bash
cd client
flutter build ios --config-only --no-codesign
cd ios
pod install
```

Then reopen `Runner.xcworkspace`.

## Running Against A Remote API

From the repository root:

```bash
cd client
flutter run --dart-define=API_BASE_URL=https://api-dev.example.com/
```

The repository also includes VS Code launch configurations for iOS runs against
an explicit API base URL.

## Notes

- Use Profile or Release builds for standalone-capable device installs.
- The release bundle created by `make release` excludes `client/ios` and other
  development-only mobile artifacts on purpose.
- A Flutter warning about `flutter_inappwebview_ios` or
  `flutter_keyboard_visibility` not supporting Swift Package Manager is
  expected today. CocoaPods still handles those plugins.

## Common Errors

### `Module 'file_picker' not found`

This means Xcode is compiling `GeneratedPluginRegistrant.m` without the
generated Swift package linked.

Fix it with:

```bash
cd client
flutter build ios --config-only --no-codesign
open ios/Runner.xcworkspace
```

If the workspace was already open, close and reopen it after regeneration.

### CocoaPods sandbox is not in sync

Run:

```bash
cd client/ios
pod install
```

Then build from `Runner.xcworkspace`.
