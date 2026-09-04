import Foundation
import GameController

struct StreamConfiguration: Sendable {
    let width: UInt32
    let height: UInt32
    let fps: UInt32
    let bitrate: UInt32

    static let highQuality = StreamConfiguration(width: 1920, height: 1080, fps: 60, bitrate: 15_000)
}

@MainActor
final class RemotePlaySession: ObservableObject {
    enum ConnectionStage: Int32, Equatable {
        case contacting = 1
        case authenticating = 2
        case establishingStream = 3
        case waitingForVideo = 4

        var label: String {
            switch self {
            case .contacting: "CONNECTING TO CONSOLE"
            case .authenticating: "VERIFYING CREDENTIALS"
            case .establishingStream: "ESTABLISHING STREAM"
            case .waitingForVideo: "WAITING FOR VIDEO"
            }
        }
    }

    enum State: Equatable {
        case connecting(ConnectionStage)
        case connected
        case loginPINRequired(incorrect: Bool)
        case ended(String)
    }

    @Published private(set) var state: State = .connecting(.contacting)
    let renderer: MetalVideoRenderer

    nonisolated(unsafe) private var session: OpaquePointer?
    private var preparationTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var streamHealthTask: Task<Void, Never>?
    private var isStopped = false
    private var didReportConnection = false
    private var lastVideoRecoveryNanoseconds: UInt64 = 0
    private let onConnected: (() -> Void)?
    nonisolated let videoDecoder: VideoDecoder
    nonisolated let audioPlayer: AudioPlayer
    private var controller = TPPlayControllerState()
    private var touchpadGestureTask: Task<Void, Never>?

    init(
        console: RegisteredConsole,
        configuration: StreamConfiguration = .highQuality,
        remote: RemoteConsoleConnection? = nil,
        startupBufferMilliseconds: Int = 0,
        onConnected: (() -> Void)? = nil
    ) {
        let isPS5 = console.target >= 1_000_000
        let audioPlayer = AudioPlayer(startupBufferMilliseconds: startupBufferMilliseconds)
        self.audioPlayer = audioPlayer
        renderer = MetalVideoRenderer(
            framesPerSecond: Int(configuration.fps),
            startupBufferMilliseconds: startupBufferMilliseconds,
            onStartupBufferReady: { [audioPlayer] in
                audioPlayer.releasePlaybackGate()
            }
        )
        self.onConnected = onConnected
        videoDecoder = VideoDecoder(hevc: isPS5)
        videoDecoder.onFrame = { [renderer] frame in
            renderer.display(frame)
        }
        videoDecoder.onRecoveryNeeded = { [weak self] reason in
            Task { @MainActor in
                self?.recoverVideo(reason: reason)
            }
        }

        if let remote {
            preparationTask = Task { [weak self] in
                let prepared = await Task.detached(priority: .userInitiated) {
                    var errorCode: Int32 = 0
                    let handle = remote.accessToken.withCString { token in
                        remote.consoleDUID.withUnsafeBytes { duid in
                            tp_play_holepunch_prepare(
                                token,
                                duid.bindMemory(to: UInt8.self).baseAddress,
                                remote.consoleDUID.count,
                                remote.isPS5,
                                &errorCode
                            )
                        }
                    }
                    return PreparedHolepunch(pointer: handle, errorCode: errorCode)
                }.value
                guard let self else {
                    tp_play_holepunch_destroy(prepared.pointer)
                    return
                }
                guard !Task.isCancelled, !isStopped else {
                    tp_play_holepunch_destroy(prepared.pointer)
                    return
                }
                guard let handle = prepared.pointer else {
                    state = .ended("Internet connection setup failed (core error \(prepared.errorCode)).")
                    return
                }
                createRemoteSession(handle: handle, remote: remote, configuration: configuration)
            }
        } else {
            createLocalSession(console: console, configuration: configuration)
        }
    }

    private func createLocalSession(
        console: RegisteredConsole,
        configuration: StreamConfiguration
    ) {
        let isPS5 = console.target >= 1_000_000
        print("[TPPLAY-DIAG] requested bitrate=\(configuration.bitrate) kbps")
        var errorCode: Int32 = 0
        session = console.address.withCString { host in
            console.registrationKey.withUnsafeBytes { registrationKey in
                console.key.withUnsafeBytes { key in
                    tp_play_session_create(
                        isPS5,
                        host,
                        registrationKey.bindMemory(to: UInt8.self).baseAddress,
                        console.registrationKey.count,
                        key.bindMemory(to: UInt8.self).baseAddress,
                        console.key.count,
                        configuration.width,
                        configuration.height,
                        configuration.fps,
                        configuration.bitrate,
                        isPS5 ? 1 : 0,
                        tpPlaySessionEventCallback,
                        tpPlayVideoCallback,
                        tpPlayAudioSettingsCallback,
                        tpPlayAudioFrameCallback,
                        Unmanaged.passUnretained(self).toOpaque(),
                        &errorCode
                    )
                }
            }
        }
        guard let session else {
            state = .ended("Session setup failed (core error \(errorCode)).")
            return
        }
        let startError = tp_play_session_start(session)
        if startError != 0 {
            state = .ended("Session start failed (core error \(startError)).")
        }
    }

    private func createRemoteSession(
        handle: OpaquePointer,
        remote: RemoteConsoleConnection,
        configuration: StreamConfiguration
    ) {
        var errorCode: Int32 = 0
        session = remote.accountID.withUnsafeBytes { accountID in
            tp_play_session_create_remote(
                remote.isPS5,
                handle,
                accountID.bindMemory(to: UInt8.self).baseAddress,
                remote.accountID.count,
                configuration.width,
                configuration.height,
                configuration.fps,
                configuration.bitrate,
                remote.isPS5 ? 1 : 0,
                tpPlaySessionEventCallback,
                tpPlayVideoCallback,
                tpPlayAudioSettingsCallback,
                tpPlayAudioFrameCallback,
                Unmanaged.passUnretained(self).toOpaque(),
                &errorCode
            )
        }
        guard let session else {
            state = .ended("Internet session setup failed (core error \(errorCode)).")
            return
        }
        let startError = tp_play_session_start(session)
        if startError != 0 {
            state = .ended("Internet session start failed (core error \(startError)).")
        }
    }

    private func markConnected() {
        state = .connected
        startStreamHealthMonitor()
        if !didReportConnection {
            didReportConnection = true
            onConnected?()
        }
    }

    deinit {
        preparationTask?.cancel()
        touchpadGestureTask?.cancel()
        streamHealthTask?.cancel()
        // Normal UI exits clear and destroy the handle in stop(). This fallback
        // only covers a session that is released without going through that path.
        if let session {
            tp_play_session_stop(session)
            tp_play_session_destroy(session)
        }
        audioPlayer.stop()
        renderer.stopBufferedPlayback()
    }

    func stop(completion: (() -> Void)? = nil) {
        if isStopped {
            completion?()
            return
        }

        isStopped = true
        preparationTask?.cancel()
        touchpadGestureTask?.cancel()
        streamHealthTask?.cancel()
        streamHealthTask = nil
        touchpadGestureTask = nil
        renderer.stopBufferedPlayback()
        guard let session else {
            audioPlayer.stop()
            completion?()
            return
        }

        // Signal Chiaki immediately while the control connection is still live.
        // Waiting for the detached destroy task to begin can leave the console
        // thinking Remote Play is still occupied even though our UI is gone.
        tp_play_session_stop(session)
        self.session = nil
        let handle = SessionHandle(pointer: session)
        // chiaki_session_stop() is only a request. destroy() performs stop + join
        // + fini, so keep this object alive and do the blocking join off-main.
        teardownTask = Task { [self] in
            await Task.detached(priority: .userInitiated) {
                tp_play_session_destroy(handle.pointer)
            }.value
            audioPlayer.stop()
        }
        // Stopping the session is immediate; join/fini may take an unbounded
        // amount of time on a broken UDP path and must never hold the UI hostage.
        completion?()
    }

    func submitLoginPIN(_ pin: String) {
        pin.withCString { _ = tp_play_session_set_login_pin(session, $0) }
    }

    func requestVideoRefresh() {
        recoverVideo(reason: "app returned to foreground", force: true)
    }

    private func recoverVideo(reason: String, force: Bool = false) {
        guard !isStopped, let session else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        // The core requests the first IDR on FEC failure. Repeating reliable
        // requests too quickly on a congested route delays the recovery packet.
        let cooldown: UInt64 = 8_000_000_000
        guard force || now &- lastVideoRecoveryNanoseconds >= cooldown else { return }
        lastVideoRecoveryNanoseconds = now
        videoDecoder.prepareForRecovery()
        let result = tp_play_session_request_idr(session)
        print("[TPPLAY-DIAG] IDR request (\(reason)): \(result)")
    }

    private func startStreamHealthMonitor() {
        guard streamHealthTask == nil else { return }
        streamHealthTask = Task { @MainActor [weak self] in
            var previousInput: UInt64 = 0
            var previousOutput: UInt64 = 0
            var previousRenderedInput: UInt64 = 0
            var previousDrawn: UInt64 = 0
            var decoderStallStarted: UInt64?
            var rendererStallStarted: UInt64?
            var lastDecodedOutputAt = DispatchTime.now().uptimeNanoseconds
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, !self.isStopped else { return }
                guard case .connected = self.state else { continue }

                let snapshot = self.videoDecoder.healthSnapshot()
                let renderSnapshot = self.renderer.healthSnapshot()
                let now = DispatchTime.now().uptimeNanoseconds
                let inputAdvanced = snapshot.inputFrames > previousInput
                let outputAdvanced = snapshot.outputFrames > previousOutput
                if inputAdvanced && !outputAdvanced {
                    if decoderStallStarted == nil { decoderStallStarted = now }
                    if let started = decoderStallStarted, now &- started >= 500_000_000 {
                        self.recoverVideo(reason: "decoder output stalled while input continued")
                        decoderStallStarted = now
                    }
                } else if outputAdvanced {
                    decoderStallStarted = nil
                    lastDecodedOutputAt = now
                }

                // Once the core enters its "wait for IDR" state it intentionally
                // stops forwarding P-frames, so decoder input no longer advances.
                // Retry one IDR request at a controlled cadence instead of
                // mistaking that silence for a healthy decoder.
                if !outputAdvanced && now &- lastDecodedOutputAt >= 3_000_000_000 {
                    self.recoverVideo(reason: "no decoded video output")
                    lastDecodedOutputAt = now
                }

                let renderedInputAdvanced = renderSnapshot.receivedFrames > previousRenderedInput
                let drawAdvanced = renderSnapshot.drawnFrames > previousDrawn
                if renderedInputAdvanced && !drawAdvanced {
                    if rendererStallStarted == nil { rendererStallStarted = now }
                    if let started = rendererStallStarted, now &- started >= 500_000_000 {
                        print("[TPPLAY-DIAG] renderer stalled while decoded frames continued; requesting redraw")
                        self.renderer.requestRedraw()
                        rendererStallStarted = now
                    }
                } else if drawAdvanced {
                    rendererStallStarted = nil
                }

                previousInput = snapshot.inputFrames
                previousOutput = snapshot.outputFrames
                previousRenderedInput = renderSnapshot.receivedFrames
                previousDrawn = renderSnapshot.drawnFrames
                ticks += 1
                if ticks % 4 == 0 {
                    print("[TPPLAY-DIAG] video health: input=\(snapshot.inputFrames) output=\(snapshot.outputFrames) decodeQueue=\(snapshot.queuedFrames) renderer=\(renderSnapshot.receivedFrames)/\(renderSnapshot.drawnFrames)")
                }
            }
        }
    }

    func setButton(_ mask: UInt32, pressed: Bool) {
        if pressed { controller.buttons |= mask } else { controller.buttons &= ~mask }
        sendController()
    }

    func setSticks(leftX: Int16, leftY: Int16, rightX: Int16, rightY: Int16) {
        controller.left_x = leftX
        controller.left_y = leftY
        controller.right_x = rightX
        controller.right_y = rightY
        sendController()
    }

    func setLeftStick(x: Int16, y: Int16) {
        controller.left_x = x
        controller.left_y = y
        sendController()
    }

    func setRightStick(x: Int16, y: Int16) {
        controller.right_x = x
        controller.right_y = y
        sendController()
    }

    func setTrigger(left: Bool, value: Float) {
        let scaled = UInt8(clamping: Int(value * 255))
        if left { controller.l2 = scaled } else { controller.r2 = scaled }
        sendController()
    }

    func setTouch(active: Bool, x: UInt16 = 0, y: UInt16 = 0) {
        controller.touch_active = active
        controller.touch_x = x
        controller.touch_y = y
        sendController()
    }

    func clickTouchpad() {
        setButton(1 << 14, pressed: true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            self?.setButton(1 << 14, pressed: false)
        }
    }

    func clickTouchpad(at x: UInt16, y: UInt16) {
        cancelTouchpadGesture()
        controller.touch_active = true
        controller.touch_x = x
        controller.touch_y = y
        controller.buttons |= 1 << 14
        sendController()
        touchpadGestureTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled, let self else { return }
            self.controller.buttons &= ~(1 << 14)
            self.controller.touch_active = false
            self.controller.touch_x = 0
            self.controller.touch_y = 0
            self.sendController()
        }
    }

    func performTouchpadSwipe(from: (UInt16, UInt16), to: (UInt16, UInt16)) {
        cancelTouchpadGesture()
        touchpadGestureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = 8
            for step in 0...steps {
                guard !Task.isCancelled else { return }
                let progress = Double(step) / Double(steps)
                let x = UInt16(Double(from.0) + (Double(to.0) - Double(from.0)) * progress)
                let y = UInt16(Double(from.1) + (Double(to.1) - Double(from.1)) * progress)
                self.controller.touch_active = true
                self.controller.touch_x = x
                self.controller.touch_y = y
                self.sendController()
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled else { return }
            self.controller.touch_active = false
            self.controller.touch_x = 0
            self.controller.touch_y = 0
            self.sendController()
        }
    }

    private func cancelTouchpadGesture() {
        touchpadGestureTask?.cancel()
        touchpadGestureTask = nil
        controller.buttons &= ~(1 << 14)
        controller.touch_active = false
        controller.touch_x = 0
        controller.touch_y = 0
    }

    func clickPSButton() {
        setButton(1 << 15, pressed: true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            self?.setButton(1 << 15, pressed: false)
        }
    }

    func attach(_ gameController: GCController) {
        guard let gamepad = gameController.extendedGamepad else { return }
        bind(gamepad.buttonA, mask: 1 << 0)
        bind(gamepad.buttonB, mask: 1 << 1)
        bind(gamepad.buttonX, mask: 1 << 2)
        bind(gamepad.buttonY, mask: 1 << 3)
        bind(gamepad.leftShoulder, mask: 1 << 8)
        bind(gamepad.rightShoulder, mask: 1 << 9)
        bind(gamepad.leftThumbstickButton, mask: 1 << 10)
        bind(gamepad.rightThumbstickButton, mask: 1 << 11)
        bind(gamepad.buttonMenu, mask: 1 << 12)
        bind(gamepad.buttonOptions, mask: 1 << 13)
        bind(gamepad.buttonHome, mask: 1 << 15)

        // Native PlayStation controllers expose the physical touchpad click.
        // On Xbox, View (the secondary/menu-left button) matches the in-game
        // function of the PlayStation touchpad; Share remains PS Create/Share.
        if let dualSense = gamepad as? GCDualSenseGamepad {
            bind(dualSense.touchpadButton, mask: 1 << 14)
        } else if let dualShock = gamepad as? GCDualShockGamepad {
            bind(dualShock.touchpadButton, mask: 1 << 14)
        } else if let xbox = gamepad as? GCXboxGamepad {
            bind(xbox.buttonOptions, mask: 1 << 14)
            bind(xbox.buttonShare, mask: 1 << 13)
        }

        gamepad.dpad.valueChangedHandler = { [weak self] _, x, y in
            Task { @MainActor in
                self?.setButton(1 << 4, pressed: x < -0.5)
                self?.setButton(1 << 5, pressed: x > 0.5)
                self?.setButton(1 << 6, pressed: y > 0.5)
                self?.setButton(1 << 7, pressed: y < -0.5)
            }
        }
        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            let sx = Self.axis(x)
            let sy = Self.axis(-y)
            Task { @MainActor in
                guard let self else { return }
                self.controller.left_x = sx
                self.controller.left_y = sy
                self.sendController()
            }
        }
        gamepad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
            let sx = Self.axis(x)
            let sy = Self.axis(-y)
            Task { @MainActor in
                guard let self else { return }
                self.controller.right_x = sx
                self.controller.right_y = sy
                self.sendController()
            }
        }
        gamepad.leftTrigger.valueChangedHandler = { [weak self] _, value, _ in
            Task { @MainActor in self?.setTrigger(left: true, value: value) }
        }
        gamepad.rightTrigger.valueChangedHandler = { [weak self] _, value, _ in
            Task { @MainActor in self?.setTrigger(left: false, value: value) }
        }
    }

    func detach(_ gameController: GCController) {
        guard gameController.extendedGamepad != nil else { return }
        controller = TPPlayControllerState()
        sendController()
    }

    private func bind(_ input: GCControllerButtonInput?, mask: UInt32) {
        input?.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in self?.setButton(mask, pressed: pressed) }
        }
    }

    nonisolated private static func axis(_ value: Float) -> Int16 {
        Int16(clamping: Int(value * Float(Int16.max)))
    }

    private func sendController() {
        var state = controller
        _ = tp_play_session_set_controller(session, &state)
    }

    fileprivate func receiveEvent(type: Int32, value: Int32, message: String?) {
        switch type {
        case 1000:
            if let stage = ConnectionStage(rawValue: value), case .connecting = state {
                state = .connecting(stage)
            }
        case 0:
            markConnected()
        case 1: state = .loginPINRequired(incorrect: value != 0)
        case 9:
            streamHealthTask?.cancel()
            streamHealthTask = nil
            renderer.stopBufferedPlayback()
            audioPlayer.stop()
            state = .ended(message ?? "Remote Play ended (reason \(value)).")
        default: break
        }
    }
}

private struct PreparedHolepunch: @unchecked Sendable {
    let pointer: OpaquePointer?
    let errorCode: Int32
}

private struct SessionHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}

private let tpPlaySessionEventCallback: @convention(c) (Int32, Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { type, value, message, context in
    guard let context else { return }
    let text = message.map(String.init(cString:))
    let session = Unmanaged<RemotePlaySession>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in session.receiveEvent(type: type, value: value, message: text) }
}

private let tpPlayVideoCallback: @convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Bool = { bytes, count, context in
    guard let bytes, count > 0, let context else { return false }
    let session = Unmanaged<RemotePlaySession>.fromOpaque(context).takeUnretainedValue()
    return session.videoDecoder.decode(Data(bytes: bytes, count: count))
}

private let tpPlayAudioSettingsCallback: @convention(c) (UInt32, UInt32, UnsafeMutableRawPointer?) -> Void = { channels, rate, context in
    guard let context else { return }
    let session = Unmanaged<RemotePlaySession>.fromOpaque(context).takeUnretainedValue()
    session.audioPlayer.configure(channels: channels, sampleRate: rate)
}

private let tpPlayAudioFrameCallback: @convention(c) (UnsafePointer<Int16>?, Int, UnsafeMutableRawPointer?) -> Void = { samples, count, context in
    guard let samples, count > 0, let context else { return }
    let session = Unmanaged<RemotePlaySession>.fromOpaque(context).takeUnretainedValue()
    session.audioPlayer.enqueue(samples: samples, count: count)
}
