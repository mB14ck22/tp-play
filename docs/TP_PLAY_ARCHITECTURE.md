# TP Play mobile architecture

## Product boundary

TP Play is a separately named product derived from chiaki-ng. It is developed
in its own repository and has its own application identifiers, UI, release
process, and mobile platform code. Its technical lineage and applicable
licenses remain explicit.

Pylux code and commits are not part of this baseline.

## Source layout

The initial source layout keeps upstream-owned code recognizable so upstream
changes remain reviewable:

- `lib/`: shared Chiaki protocol, discovery, session, encryption, and streaming
  code
- `android/`: Android application and its native platform integration
- `ios/`: native TP Play iOS application and Xcode project
- `mobile/bridge/`: proposed stable C-facing mobile API, to be introduced
  without exposing internal C++ types to Swift or Kotlin

New product-specific behavior should normally be added in new files or narrow
adapters. Changes to upstream-owned files must be deliberate and documented.

## Android

- Language: Kotlin
- UI: Jetpack Compose for navigation, discovery, registration, and settings
- Stream surface: `SurfaceView` backed by `ANativeWindow`
- Video: hardware `MediaCodec` decoding directly to the surface
- Audio: Oboe/AAudio low-latency output
- Native bridge: JNI into the stable mobile C API
- Input: Android controller and motion APIs, with a dedicated native touch
  overlay above the stream surface

Compose state must not be updated once per decoded video frame. Encoded video
packets and decoded frames stay outside the Kotlin object graph.

## iOS

- Language: Swift
- UI: SwiftUI for navigation, discovery, registration, and settings
- Stream and touch surface: UIKit hosted from SwiftUI where direct event
  ownership is required
- Video: VideoToolbox hardware decoding to `CVPixelBuffer`, rendered by Metal
- Audio: AudioUnit or AVAudioEngine, selected after measured latency tests
- Native bridge: C API, with Objective-C++ only where a C++ adapter is necessary
- Input: GameController and CoreMotion

Decoded pixel buffers must remain on the hardware/GPU path. Swift does not copy
frame payloads into arrays or images.

## Repository remotes

- `upstream`: `https://github.com/streetpea/chiaki-ng.git`
- `origin`: reserved for the future TP Play repository

The local `main` branch intentionally has no upstream tracking branch until the
TP Play origin repository is selected.

## Initial implementation order

1. Establish the iOS Swift shell. (Implemented; core integration pending.)
2. Introduce the stable mobile C API and contract tests.
3. Add discovery and registration through the bridge.
4. Implement the iOS VideoToolbox/Metal path.
5. Establish the Android Kotlin shell and retain a zero-copy MediaCodec path.
6. Add session lifecycle, audio, controller, and touch
   controls in that order.
7. Measure glass-to-glass latency, audio stability, frame pacing, thermals, and
   reconnect behavior on physical devices before release claims are made.
