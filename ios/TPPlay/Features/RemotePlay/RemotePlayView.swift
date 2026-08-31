import SwiftUI
import GameController

struct RemotePlayView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: RemotePlaySession
    @State private var loginPIN = ""

    init(console: RegisteredConsole, configuration: StreamConfiguration = .highQuality) {
        _session = StateObject(wrappedValue: RemotePlaySession(console: console, configuration: configuration))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MetalVideoView(renderer: session.renderer)
                .ignoresSafeArea()

            controls

            if case .connecting = session.state {
                ProgressView("Connecting…")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.primaryText)
                    .tint(TPPlayTheme.accent)
                    .padding(18)
                    .background(TPPlayTheme.surface.opacity(0.92))
                    .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
            }

            if case .ended(let reason) = session.state {
                ContentUnavailableView("Remote Play ended", systemImage: "rectangle.slash", description: Text(reason))
                    .foregroundStyle(.white)
            }
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
        .alert("Console login PIN", isPresented: loginPINBinding) {
            SecureField("PIN", text: $loginPIN)
                .keyboardType(.numberPad)
            Button("Submit") {
                session.submitLoginPIN(loginPIN)
                loginPIN = ""
            }
            Button("Stop", role: .cancel) { session.stop() }
        } message: {
            if case .loginPINRequired(let incorrect) = session.state {
                Text(incorrect ? "That PIN was incorrect. Try again." : "Enter the user login PIN configured on the console.")
            }
        }
        .onAppear {
            GCController.controllers().forEach(session.attach)
            GCController.startWirelessControllerDiscovery()
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { notification in
            if let controller = notification.object as? GCController {
                session.attach(controller)
            }
        }
        .onDisappear { session.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                session.stop()
                dismiss()
            }
        }
    }

    private var loginPINBinding: Binding<Bool> {
        Binding(
            get: {
                if case .loginPINRequired = session.state { return true }
                return false
            },
            set: { _ in }
        )
    }

    private var controls: some View {
        VStack {
            HStack {
                Button {
                    session.stop()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .background(TPPlayTheme.surface.opacity(0.82))
                        .overlay { Rectangle().stroke(TPPlayTheme.accent, lineWidth: 1) }
                }
                Spacer()
            }
            .padding()

            Spacer()

            HStack {
                HStack(spacing: 10) {
                    ControllerTextButton(label: "L2", session: session, triggerLeft: true)
                    ControllerTextButton(label: "L1", mask: 1 << 8, session: session)
                    ControllerTextButton(label: "L3", mask: 1 << 10, session: session)
                }
                Spacer()
                HStack(spacing: 10) {
                    ControllerTextButton(label: "R3", mask: 1 << 11, session: session)
                    ControllerTextButton(label: "R1", mask: 1 << 9, session: session)
                    ControllerTextButton(label: "R2", session: session, triggerLeft: false)
                }
            }
            .padding(.horizontal, 24)

            HStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(spacing: 4) {
                        ControllerButton(symbol: "chevron.up", mask: 1 << 6, session: session)
                        HStack(spacing: 28) {
                            ControllerButton(symbol: "chevron.left", mask: 1 << 4, session: session)
                            ControllerButton(symbol: "chevron.right", mask: 1 << 5, session: session)
                        }
                        ControllerButton(symbol: "chevron.down", mask: 1 << 7, session: session)
                    }
                    VirtualStick { x, y in session.setLeftStick(x: x, y: y) }
                }

                Spacer()

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ControllerTextButton(label: "SHARE", mask: 1 << 13, session: session)
                        ControllerTextButton(label: "PS", mask: 1 << 15, session: session)
                        ControllerTextButton(label: "OPTIONS", mask: 1 << 12, session: session)
                    }
                    TouchpadControl(session: session)
                    HStack(alignment: .bottom, spacing: 14) {
                        VirtualStick { x, y in session.setRightStick(x: x, y: y) }
                        VStack(spacing: 4) {
                            ControllerButton(symbol: "triangle", mask: 1 << 3, session: session)
                            HStack(spacing: 28) {
                                ControllerButton(symbol: "square", mask: 1 << 2, session: session)
                                ControllerButton(symbol: "circle", mask: 1 << 1, session: session)
                            }
                            ControllerButton(symbol: "xmark", mask: 1 << 0, session: session)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .foregroundStyle(.white.opacity(0.8))
        }
    }
}

private struct TouchpadControl: View {
    @ObservedObject var session: RemotePlaySession

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(TPPlayTheme.surface.opacity(0.72))
                .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
                .overlay {
                    Text("TOUCHPAD")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.45))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .local)
                        .onChanged { value in
                            let x = max(0, min(1, value.location.x / geometry.size.width))
                            let y = max(0, min(1, value.location.y / geometry.size.height))
                            session.setTouch(
                                active: true,
                                x: UInt16(x * 1919),
                                y: UInt16(y * 941)
                            )
                        }
                        .onEnded { _ in session.setTouch(active: false) }
                )
                .onTapGesture { session.clickTouchpad() }
        }
        .frame(width: 132, height: 38)
        .accessibilityLabel("Touchpad")
        .accessibilityHint("Drag to move a touch or tap to click")
    }
}

private struct ControllerTextButton: View {
    let label: String
    var mask: UInt32 = 0
    @ObservedObject var session: RemotePlaySession
    var triggerLeft: Bool?
    @State private var pressed = false

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .frame(minWidth: 42, minHeight: 34)
            .padding(.horizontal, 4)
            .background(TPPlayTheme.surface.opacity(0.72))
            .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
            .scaleEffect(pressed ? 0.92 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        if let triggerLeft { session.setTrigger(left: triggerLeft, value: 1) }
                        else { session.setButton(mask, pressed: true) }
                    }
                    .onEnded { _ in
                        pressed = false
                        if let triggerLeft { session.setTrigger(left: triggerLeft, value: 0) }
                        else { session.setButton(mask, pressed: false) }
                    }
            )
    }
}

private struct VirtualStick: View {
    let onChange: (Int16, Int16) -> Void
    @State private var offset: CGSize = .zero

    var body: some View {
        Rectangle()
            .fill(TPPlayTheme.surface.opacity(0.66))
            .frame(width: 104, height: 104)
            .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
            .overlay {
                Rectangle()
                    .fill(TPPlayTheme.accent.opacity(0.38))
                    .frame(width: 48, height: 48)
                    .offset(offset)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let radius: CGFloat = 28
                        let length = hypot(gesture.translation.width, gesture.translation.height)
                        let scale = length > radius ? radius / length : 1
                        offset = CGSize(width: gesture.translation.width * scale, height: gesture.translation.height * scale)
                        onChange(
                            Int16(clamping: Int(offset.width / radius * CGFloat(Int16.max))),
                            Int16(clamping: Int(offset.height / radius * CGFloat(Int16.max)))
                        )
                    }
                    .onEnded { _ in
                        offset = .zero
                        onChange(0, 0)
                    }
            )
    }
}

private struct ControllerButton: View {
    let symbol: String
    let mask: UInt32
    @ObservedObject var session: RemotePlaySession
    @State private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.title3.weight(.bold))
            .frame(width: 54, height: 54)
            .background(TPPlayTheme.surface.opacity(0.72))
            .overlay { Rectangle().stroke(TPPlayTheme.accent, lineWidth: 1) }
            .scaleEffect(pressed ? 0.9 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            session.setButton(mask, pressed: true)
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        session.setButton(mask, pressed: false)
                    }
            )
    }
}
