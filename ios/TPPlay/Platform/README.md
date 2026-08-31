# iOS platform adapters

This directory is reserved for concrete integrations that sit outside SwiftUI:

- `Bridge/`: stable C API and Objective-C++ adaptation where required
- `Video/`: VideoToolbox decode and Metal presentation
- `Audio/`: AudioUnit or AVAudioEngine output selected by measured latency
- `Input/`: GameController, CoreMotion, and touch ownership
- `Network/`: local-network permission and platform reachability adaptation

These directories will be introduced with their first implementation. No media
or session capability is represented as complete by this placeholder.
