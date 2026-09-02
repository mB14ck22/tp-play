import SwiftUI

struct ConsoleLibraryView: View {
    @StateObject private var discovery = ConsoleDiscoveryStore()
    @StateObject private var registeredConsoles = RegisteredConsoleStore()
    @StateObject private var remoteCredentials = RemoteCredentialStore()
    @State private var consoleToRegister: DiscoveredConsole?
    @State private var pendingConsoleRegistration: DiscoveredConsole?
    @State private var playRequest: ConsolePlayRequest?
    @State private var consoleToRemove: RegisteredConsole?
    @State private var wakeError: String?
    @State private var connectingConsoleID: String?
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
                .refreshable { discovery.restart() }
            }
            .allowsHitTesting(wakeError == nil)

            if let wakeError {
                Color.black.opacity(0.76)
                    .ignoresSafeArea()
                TPErrorDialog(title: "CONNECTION ERROR", message: wakeError) {
                    self.wakeError = nil
                }
                .frame(maxWidth: 420)
                .padding(20)
                .transition(.opacity)
                .zIndex(2)
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
        .fullScreenCover(item: $playRequest) { request in
            RemotePlayView(
                console: request.console,
                configuration: streamConfiguration,
                remote: request.remote
            )
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
                    onPlay: { startSession(for: registered, nearby: nearby, remoteAvailable: remoteAvailable) },
                    onRemove: { consoleToRemove = registered }
                )
            }
        }
    }

    private func startSession(for registered: RegisteredConsole, nearby: DiscoveredConsole?, remoteAvailable: Bool) {
        let current = registered.updatedAddress(nearby?.address)
        registeredConsoles.updateAddressIfNeeded(current)

        if nearby == nil, remoteAvailable {
            connectingConsoleID = registered.id
            Task { @MainActor in
                defer { connectingConsoleID = nil }
                do {
                    guard let remote = try await remoteCredentials.connection(for: current) else {
                        wakeError = "No matching remote console credential was found."
                        return
                    }
                    playRequest = ConsolePlayRequest(console: current, remote: remote)
                } catch {
                    wakeError = error.localizedDescription
                }
            }
        } else if nearby?.state == .standby || nearby == nil {
            guard !current.address.isEmpty else {
                wakeError = "No saved remote connection is available for this console."
                return
            }
            wakeError = discovery.wake(current)
        } else {
            playRequest = ConsolePlayRequest(console: current, remote: nil)
        }
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
                    Text(isConnecting ? "REFRESHING PSN" : (canStartSession ? "START SESSION" : "WAKE CONSOLE"))
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
    let console: RegisteredConsole
    let remote: RemoteConsoleConnection?
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
