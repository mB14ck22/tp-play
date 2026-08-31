
# TP Play

TP Play is an independent, open-source PlayStation Remote Play client for iOS
and Android. The project starts from the
[chiaki-ng](https://github.com/streetpea/chiaki-ng) codebase and preserves its
shared protocol and streaming core while building native mobile applications.

## Project status

TP Play currently contains a clean chiaki-ng baseline plus the first native iOS
application shell. The shell builds independently but is not connected to the
Chiaki core yet. The new Android application architecture has not been
implemented.

## Repository map

- `ios/`: native TP Play iOS application (Swift and SwiftUI)
- `android/`: current chiaki-ng Android frontend; TP Play migration pending
- `lib/`: shared Chiaki protocol and streaming core
- `gui/`: upstream desktop frontend
- `switch/`: upstream Nintendo Switch frontend

## Technical direction

- Shared protocol and streaming core: C/C++ with CMake
- Android application: Kotlin and Jetpack Compose
- Android media path: MediaCodec, SurfaceView/ANativeWindow, and Oboe/AAudio
- iOS application: Swift with SwiftUI and UIKit where direct touch handling is
  required
- iOS media path: VideoToolbox, Metal, and AudioUnit/AVAudioEngine
- Platform bridge: a narrow, stable C API; JNI on Android and C/Objective-C++
  bridging on iOS

The video, audio, controller, and touch hot paths stay in native platform APIs.
UI frameworks do not own or copy decoded video frames.

See [docs/TP_PLAY_ARCHITECTURE.md](docs/TP_PLAY_ARCHITECTURE.md) for repository
boundaries and the initial implementation plan.

## Upstream

The canonical upstream is
[streetpea/chiaki-ng](https://github.com/streetpea/chiaki-ng). TP Play keeps the
upstream Git history so fixes can be reviewed and integrated without treating
TP Play as a source-code rewrite.

## License and attribution

TP Play is derived from chiaki-ng and Chiaki. Existing copyright, attribution,
and license notices must be retained. The current upstream baseline is licensed
under the GNU Affero General Public License v3 with the additional permission
recorded in [LICENSES/AGPL-3.0-only-OpenSSL.txt](LICENSES/AGPL-3.0-only-OpenSSL.txt).

TP Play is not endorsed or certified by Sony Interactive Entertainment LLC.
PlayStation and related marks belong to their respective owners.
