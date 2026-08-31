# TP Play for iOS

This directory contains the native TP Play iOS application. It is intentionally
parallel to the repository's top-level `android/` directory; shared Remote Play
protocol and session code remains in `lib/`.

## Layout

- `TPPlay.xcodeproj/`: native Xcode project
- `TPPlay/App/`: application entry point and root composition
- `TPPlay/Features/`: user-facing features grouped by domain
- `TPPlay/Platform/`: iOS media, controller, networking, and C bridge adapters
- `TPPlay/DesignSystem/`: shared visual tokens and reusable presentation

Platform code must depend on a narrow C-facing mobile bridge rather than expose
internal Chiaki structs to Swift. Video and audio payloads must remain outside
SwiftUI state.

## Build

The complete Xcode installation currently used for command-line builds is on
the XcodeSSD volume:

```sh
DEVELOPER_DIR=/Volumes/XcodeSSD/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project ios/TPPlay.xcodeproj \
  -scheme TPPlay \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The iOS target now links the Chiaki core and provides local-network discovery,
manual host entry, console registration with Keychain storage, wake-on-LAN,
hardware video decoding, Metal presentation, audio playback, external controller
input, and an on-screen controller. Device runtime behavior still needs to be
validated against real PS4 and PS5 hardware as those paths cannot be exercised by
the command-line build alone.
