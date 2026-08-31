import Foundation
import GameController

@MainActor
final class RemotePlaySession: ObservableObject {
    enum State: Equatable {
        case connecting
        case connected
        case loginPINRequired(incorrect: Bool)
        case ended(String)
    }

    @Published private(set) var state: State = .connecting
    let renderer = MetalVideoRenderer()

    nonisolated(unsafe) private var session: OpaquePointer?
    nonisolated let videoDecoder: VideoDecoder
    nonisolated let audioPlayer = AudioPlayer()
    private var controller = TPPlayControllerState()

    init(console: RegisteredConsole) {
        let isPS5 = console.target >= 1_000_000
        videoDecoder = VideoDecoder(hevc: isPS5)
        videoDecoder.onFrame = { [renderer] frame in
            renderer.display(frame)
        }

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
                        1920,
                        1080,
                        60,
                        15_000,
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

    deinit {
        tp_play_session_stop(session)
        tp_play_session_destroy(session)
        audioPlayer.stop()
    }

    func stop() {
        tp_play_session_stop(session)
    }

    func submitLoginPIN(_ pin: String) {
        pin.withCString { _ = tp_play_session_set_login_pin(session, $0) }
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
        case 0: state = .connected
        case 1: state = .loginPINRequired(incorrect: value != 0)
        case 9: state = .ended(message ?? "Remote Play ended (reason \(value)).")
        default: break
        }
    }
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
