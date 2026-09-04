import SwiftUI

struct ConsoleLibraryView: View {
    @StateObject private var discovery = ConsoleDiscoveryStore()
    @StateObject private var registeredConsoles = RegisteredConsoleStore()
    @StateObject private var remoteCredentials = RemoteCredentialStore()
    @StateObject private var manualConnections = ManualConnectionHistoryStore()
    @State private var consoleToRegister: DiscoveredConsole?
    @State private var pendingConsoleRegistration: DiscoveredConsole?
    @State private var playRequest: ConsolePlayRequest?
    @State private var consoleToRemove: RegisteredConsole?
    @State private var wakeError: String?
    @State private var connectingConsoleID: String?
    @State private var connectionActivityText: String?
    @State private var connectionPrompt: ConsoleConnectionPrompt?
    @State private var showingManualConsole = false
    @AppStorage("streamResolution") private var streamResolution = 1080
    @AppStorage("streamFPS") private var streamFPS = 60
    @AppStorage("streamBitrate") private var streamBitrate = 15_000

    var body: some View {
        ZStack {
            TPPlayTheme.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 10)
                    .background(TPPlayTheme.canvas)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if !registeredConsoles.consoles.isEmpty { consoleSection }
                        else { emptyConsoleState }
                        if let storageError = registeredConsoles.storageError {
                            Text("KEYCHAIN ERROR // \(storageError)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(TPPlayTheme.danger)
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
            }
            .allowsHitTesting(wakeError == nil && connectionPrompt == nil)

            if let connectionPrompt {
                Color.black.opacity(0.78)
                    .ignoresSafeArea()
                ConnectionRouteDialog(
                    consoleName: connectionPrompt.console.nickname,
                    automaticDetail: connectionPrompt.automaticDetail,
                    initialManualAddress: manualConnections.address(for: connectionPrompt.console) ?? connectionPrompt.console.address,
                    onAutomatic: {
                        self.connectionPrompt = nil
                        startAutomaticSession(
                            for: connectionPrompt.console,
                            remoteAvailable: connectionPrompt.remoteAvailable
                        )
                    },
                    onManual: { address in
                        self.connectionPrompt = nil
                        startManualSession(for: connectionPrompt.console, address: address)
                    },
                    onCancel: { self.connectionPrompt = nil }
                )
                .frame(maxWidth: 430)
                .padding(20)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(2)
            }

            if let wakeError {
                Color.black.opacity(0.76)
                    .ignoresSafeArea()
                TPErrorDialog(title: "CONNECTION ERROR", message: wakeError) {
                    self.wakeError = nil
                }
                .frame(maxWidth: 420)
                .padding(20)
                .transition(.opacity)
                .zIndex(3)
            }
        }
        .fullScreenCover(item: $consoleToRegister) { console in
            ConsoleRegistrationView(console: console, store: registeredConsoles)
        }
        .fullScreenCover(isPresented: $showingManualConsole, onDismiss: {
            if let pendingConsoleRegistration {
                consoleToRegister = pendingConsoleRegistration
                self.pendingConsoleRegistration = nil
            }
        }) {
            ManualConsoleView { address, isPS5 in
                let cleanAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
                pendingConsoleRegistration = DiscoveredConsole(
                    id: "manual:\(cleanAddress)",
                    name: isPS5 ? "PlayStation 5" : "PlayStation 4",
                    address: cleanAddress,
                    systemVersion: "",
                    runningAppName: nil,
                    isPS5: isPS5,
                    target: isPS5 ? 1_000_100 : 1_000,
                    state: .unknown
                )
                showingManualConsole = false
            }
        }
        .fullScreenCover(item: $playRequest, onDismiss: {
            playRequest = nil
        }) { request in
            RemotePlayView(session: request.session)
        }
        .confirmationDialog("REMOVE CONSOLE?", isPresented: Binding(
            get: { consoleToRemove != nil },
            set: { if !$0 { consoleToRemove = nil } }
        ), titleVisibility: .visible) {
            Button("Remove console", role: .destructive) {
                guard let consoleToRemove else { return }
                registeredConsoles.remove(consoleToRemove)
                self.consoleToRemove = nil
            }
            Button("Cancel", role: .cancel) { consoleToRemove = nil }
        } message: {
            Text("The console must be linked again before Remote Play can start.")
        }
        .onChange(of: registeredConsoles.consoles, initial: true) { _, consoles in
            discovery.updateRegisteredConsoles(consoles)
        }
    }

    private var streamConfiguration: StreamConfiguration {
        let height = UInt32(streamResolution)
        return StreamConfiguration(width: height == 1080 ? 1920 : 1280, height: height, fps: UInt32(streamFPS), bitrate: UInt32(streamBitrate))
    }

    private var header: some View {
        TPPageHeader("PLAY // CONSOLES") {
            HStack(spacing: 7) {
                Rectangle()
                    .fill(discovery.errorMessage == nil ? TPPlayTheme.accent : TPPlayTheme.danger)
                    .frame(width: 6, height: 6)
                Text("LOCAL")
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(TPPlayTheme.primaryText)
            .frame(width: 82, height: 42)
            .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }

            Button { showingManualConsole = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .black))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(AcidButtonStyle(active: true))
            .accessibilityLabel("Add console")
        }
    }

    private var consoleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("MY CONSOLES", detail: "\(registeredConsoles.consoles.count)")
            ForEach(registeredConsoles.consoles) { registered in
                let nearby = discovery.console(matching: registered)
                let remoteAvailable = remoteCredentials.canAttemptRemoteConnection(for: registered)
                RegisteredConsoleCard(
                    console: registered,
                    nearby: nearby,
                    remoteAvailable: remoteAvailable,
                    isConnecting: connectingConsoleID == registered.id,
                    connectionActivityText: connectingConsoleID == registered.id ? connectionActivityText : nil,
                    onPlay: {
                        connectionPrompt = ConsoleConnectionPrompt(
                            console: registered,
                            remoteAvailable: remoteAvailable
                        )
                    },
                    onRemove: { consoleToRemove = registered }
                )
            }
        }
    }

    private func startAutomaticSession(for registered: RegisteredConsole, remoteAvailable: Bool) {
        connectingConsoleID = registered.id
        connectionActivityText = "SCANNING LOCAL NETWORK"

        Task { @MainActor in
            defer {
                connectingConsoleID = nil
                connectionActivityText = nil
            }

            // Do not route from the Play page's cached discovery snapshot. AUTO
            // starts a fresh broadcast scan and directly probes the paired LAN
            // address; only a negative result from both permits PSN fallback.
            async let discoveredConsole = discovery.discoverConsole(matching: registered)
            async let savedAddressState = probeState(of: registered, timeout: 1_000)
            let (nearby, directState) = await (discoveredConsole, savedAddressState)
            guard !Task.isCancelled else { return }

            let localConsole: RegisteredConsole?
            let localState: DiscoveredConsole.State
            if let nearby {
                localConsole = registered.updatedAddress(nearby.address)
                localState = nearby.state
            } else if directState != .unknown {
                localConsole = registered
                localState = directState
            } else {
                localConsole = nil
                localState = .unknown
            }

            var localFailure: String?
            if let localConsole {
                registeredConsoles.updateAddressIfNeeded(localConsole)
                if localState == .standby {
                    connectionActivityText = "WAKING LOCAL CONSOLE"
                    if let error = discovery.wake(localConsole) {
                        localFailure = error
                    } else {
                        connectionActivityText = "WAITING FOR LOCAL CONSOLE"
                        for _ in 0..<15 {
                            try? await Task.sleep(for: .milliseconds(800))
                            guard !Task.isCancelled else { return }
                            if await probeState(of: localConsole, timeout: 650) == .ready {
                                presentSession(console: localConsole)
                                return
                            }
                        }
                        localFailure = "The local console did not become ready after the wake request."
                    }
                } else {
                    presentSession(console: localConsole)
                    return
                }
            }

            guard remoteAvailable else {
                wakeError = localFailure ?? "The console was not found on the local network and no internet connection credential is available."
                return
            }

            connectionActivityText = "CONNECTING THROUGH PSN"
            do {
                guard let remote = try await remoteCredentials.connection(for: registered) else {
                    wakeError = localFailure ?? "No matching remote console credential was found."
                    return
                }
                presentSession(console: registered, remote: remote)
            } catch {
                wakeError = error.localizedDescription
            }
        }
    }

    private func startManualSession(for registered: RegisteredConsole, address: String) {
        let cleanAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAddress.isEmpty else { return }
        let directConsole = registered.updatedAddress(cleanAddress)
        connectingConsoleID = registered.id
        connectionActivityText = "CHECKING CONSOLE"
        Task { @MainActor in
            defer {
                connectingConsoleID = nil
                connectionActivityText = nil
            }

            let initialState = await probeState(of: directConsole, timeout: 900)
            if initialState == .standby {
                connectionActivityText = "WAKING CONSOLE"
                if let error = discovery.wake(directConsole) {
                    wakeError = error
                    return
                }

                for _ in 0..<15 {
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled else { return }
                    let state = await probeState(of: directConsole, timeout: 650)
                    if state == .ready {
                        presentSession(console: directConsole, manualAddress: cleanAddress)
                        return
                    }
                }
                wakeError = "The console did not become ready after the wake request."
                return
            }

            // READY connects immediately. UNKNOWN also gets one direct attempt because
            // routed/VPN networks may carry Remote Play while dropping discovery replies.
            presentSession(console: directConsole, manualAddress: cleanAddress)
        }
    }

    private func probeState(of console: RegisteredConsole, timeout: UInt32) async -> DiscoveredConsole.State {
        let state = await Task.detached(priority: .userInitiated) {
            console.address.withCString {
                tp_play_console_probe_state($0, console.target >= 1_000_000, timeout)
            }
        }.value
        switch state.rawValue {
        case 1: return .ready
        case 2: return .standby
        default: return .unknown
        }
    }

    private func presentSession(
        console: RegisteredConsole,
        remote: RemoteConsoleConnection? = nil,
        manualAddress: String? = nil
    ) {
        let session = RemotePlaySession(
            console: console,
            configuration: streamConfiguration,
            remote: remote,
            // Manual addresses are commonly routed over a WAN/VPN path. Give
            // those sessions a short A/V startup cushion, while preserving the
            // configured bitrate and LAN/AUTO's immediate low-latency playback.
            startupBufferMilliseconds: manualAddress == nil ? 0 : 250,
            onConnected: {
                guard let manualAddress else { return }
                manualConnections.recordSuccessfulAddress(manualAddress, for: console)
            }
        )
        playRequest = ConsolePlayRequest(session: session)
    }

    private var emptyConsoleState: some View {
        VStack(spacing: 10) {
            Text("NO LINKED CONSOLES")
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .foregroundStyle(TPPlayTheme.primaryText)
            Text("TAP + TO LINK A PLAYSTATION.")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(TPPlayTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 26)
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        HStack {
            Text("// \(title)")
            Spacer()
            Text(detail)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .tracking(1)
        .foregroundStyle(TPPlayTheme.accent)
    }
}

private struct RegisteredConsoleCard: View {
    let console: RegisteredConsole
    let nearby: DiscoveredConsole?
    let remoteAvailable: Bool
    let isConnecting: Bool
    let connectionActivityText: String?
    let onPlay: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ConsoleGlyph(isPS5: console.isPS5)
                VStack(alignment: .leading, spacing: 5) {
                    Text(console.nickname.uppercased())
                        .font(.system(size: 16, weight: .black, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.primaryText)
                        .lineLimit(1)
                    Text(statusText.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(remoteAvailable || nearby != nil ? TPPlayTheme.accent : TPPlayTheme.secondaryText)
                        .lineLimit(1)
                    Text(console.address)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.tertiaryText)
                }
                Spacer(minLength: 4)
                Menu {
                    Button("Remove console", systemImage: "trash", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(TPPlayTheme.primaryText)
                        .frame(width: 36, height: 36)
                        .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
                }
            }
            .padding(14)

            Button(action: onPlay) {
                HStack {
                    if isConnecting {
                        TPTerminalActivityGlyph(color: TPPlayTheme.onAccent)
                    }
                    Text(isConnecting ? (connectionActivityText ?? "PREPARING CONSOLE") : (canStartSession ? "START SESSION" : "WAKE CONSOLE"))
                    Spacer()
                    Text(">")
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(AcidButtonStyle(active: true))
            .disabled(isConnecting)
        }
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
    }

    private var canStartSession: Bool {
        remoteAvailable || nearby?.state == .ready || nearby?.state == .unknown
    }
    private var statusText: String {
        guard let nearby else { return remoteAvailable ? "PSN REMOTE // READY" : "SAVED // OFFLINE" }
        switch nearby.state {
        case .ready: return nearby.runningAppName ?? "READY"
        case .standby: return "REST MODE"
        case .unknown: return "AVAILABLE"
        }
    }
}

private struct ConsolePlayRequest: Identifiable {
    let id = UUID()
    let session: RemotePlaySession
}

private struct ConsoleConnectionPrompt: Identifiable {
    let id = UUID()
    let console: RegisteredConsole
    let remoteAvailable: Bool

    var automaticDetail: String {
        remoteAvailable ? "LOCAL FIRST / INTERNET FALLBACK" : "LOCAL NETWORK"
    }
}

@MainActor
private final class ManualConnectionHistoryStore: ObservableObject {
    private static let storageKey = "manualConnectionAddresses"
    @Published private var addresses: [String: String]

    init() {
        addresses = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
    }

    func address(for console: RegisteredConsole) -> String? {
        addresses[console.id]
    }

    func recordSuccessfulAddress(_ address: String, for console: RegisteredConsole) {
        guard addresses[console.id] != address else { return }
        addresses[console.id] = address
        UserDefaults.standard.set(addresses, forKey: Self.storageKey)
    }
}

private struct ConnectionRouteDialog: View {
    private enum Route {
        case automatic
        case manual
    }

    let consoleName: String
    let automaticDetail: String
    let onAutomatic: () -> Void
    let onManual: (String) -> Void
    let onCancel: () -> Void

    @State private var route: Route = .automatic
    @State private var manualAddress: String

    init(
        consoleName: String,
        automaticDetail: String,
        initialManualAddress: String,
        onAutomatic: @escaping () -> Void,
        onManual: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.consoleName = consoleName
        self.automaticDetail = automaticDetail
        self.onAutomatic = onAutomatic
        self.onManual = onManual
        self.onCancel = onCancel
        _manualAddress = State(initialValue: initialManualAddress)
    }

    private var cleanAddress: String {
        manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(TPPlayTheme.accent)
                    .frame(width: 8, height: 8)
                Text("// CONNECTION ROUTE")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(1)
                Spacer()
                Text("NET")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(1)
            }
            .foregroundStyle(TPPlayTheme.primaryText)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(TPPlayTheme.surfaceRaised)
            .overlay(alignment: .bottom) {
                Rectangle().fill(TPPlayTheme.violet).frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(consoleName.uppercased())
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.primaryText)
                        .lineLimit(1)
                    Text("SELECT HOW TP PLAY REACHES THIS CONSOLE")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(TPPlayTheme.secondaryText)
                }

                HStack(spacing: 8) {
                    routeButton("AUTO", detail: automaticDetail, value: .automatic)
                    routeButton("MANUAL", detail: "DIRECT IP / TAILSCALE", value: .manual)
                }

                if route == .manual {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("DIRECT ENDPOINT").acidLabel()
                        TextField("IP ADDRESS OR HOSTNAME", text: $manualAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                            .textFieldStyle(AcidFieldStyle())
                        Text("THE ADDRESS IS SAVED ONLY AFTER A SUCCESSFUL CONNECTION.")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .tracking(0.35)
                            .foregroundStyle(TPPlayTheme.tertiaryText)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                HStack(spacing: 8) {
                    Button("CANCEL", action: onCancel)
                        .frame(width: 96)
                        .frame(minHeight: 46)
                        .buttonStyle(AcidButtonStyle())
                    Button(route == .automatic ? "START AUTO >" : "CONNECT DIRECT >") {
                        if route == .automatic { onAutomatic() }
                        else { onManual(cleanAddress) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .buttonStyle(AcidButtonStyle(active: true))
                    .disabled(route == .manual && cleanAddress.isEmpty)
                }
            }
            .padding(16)
            .background(TPPlayTheme.surface)
        }
        .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 2) }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
    }

    private func routeButton(_ title: String, detail: String, value: Route) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { route = value }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Rectangle()
                        .fill(route == value ? TPPlayTheme.onAccent : TPPlayTheme.violet)
                        .frame(width: 6, height: 6)
                    Text(title)
                    Spacer(minLength: 0)
                    Text(value == .automatic ? "A" : "M")
                        .foregroundStyle(route == value ? TPPlayTheme.onAccent.opacity(0.62) : TPPlayTheme.tertiaryText)
                }
                Text(detail)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.3)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        }
        .buttonStyle(AcidButtonStyle(active: route == value))
    }
}

private struct ConsoleGlyph: View {
    let isPS5: Bool
    var body: some View {
        Image(systemName: isPS5 ? "playstation.logo" : "gamecontroller.fill")
            .font(.system(size: 22, weight: .black))
            .foregroundStyle(TPPlayTheme.accent)
            .frame(width: 48, height: 48)
            .background(TPPlayTheme.canvas)
            .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
    }
}

private struct ManualConsoleView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var isPS5 = true
    let onAdd: (String, Bool) -> Void

    var body: some View {
        ZStack {
            TPPlayTheme.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("ADD // CONSOLE")
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.accent)
                    Spacer()
                    Button("X") { dismiss() }
                        .frame(width: 42, height: 42)
                        .buttonStyle(AcidButtonStyle())
                }
                Text("CONSOLE TYPE").acidLabel()
                HStack(spacing: 8) {
                    typeButton("PLAYSTATION 5", value: true)
                    typeButton("PLAYSTATION 4", value: false)
                }
                Text("NETWORK ADDRESS").acidLabel()
                TextField("IP ADDRESS OR HOSTNAME", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(AcidFieldStyle())
                Text("ENTER THE CONSOLE ADDRESS, THEN COMPLETE REMOTE PLAY PAIRING.")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.secondaryText)
                Spacer()
                Button("CONTINUE TO LINK >") { onAdd(address, isPS5) }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .buttonStyle(AcidButtonStyle(active: true))
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
        }
        .preferredColorScheme(.dark)
    }

    private func typeButton(_ label: String, value: Bool) -> some View {
        Button(label) { isPS5 = value }
            .frame(maxWidth: .infinity, minHeight: 44)
            .buttonStyle(AcidButtonStyle(active: isPS5 == value))
    }
}

private extension View {
    func acidLabel() -> some View {
        font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(TPPlayTheme.secondaryText)
    }
}

private extension RegisteredConsole {
    var isPS5: Bool { target >= 1_000_000 }
    func updatedAddress(_ address: String?) -> RegisteredConsole {
        guard let address, address != self.address else { return self }
        return RegisteredConsole(target: target, nickname: nickname, address: address, serverMAC: serverMAC, registrationKey: registrationKey, keyType: keyType, key: key, consolePIN: consolePIN)
    }
}

#Preview { ConsoleLibraryView() }
