# iOS platform adapters

This directory contains concrete integrations that sit outside SwiftUI:

- `Core/`: stable C API, discovery, registration, session, and secure host storage
- `Streaming/`: VideoToolbox decode, Metal presentation, and AVAudioEngine output
- `Features/RemotePlay/`: GameController and touch input ownership

Platform capabilities are exposed to Swift through the narrow C bridge in
`Core/TPPlayCore.h`; media payloads remain outside SwiftUI observable state.
