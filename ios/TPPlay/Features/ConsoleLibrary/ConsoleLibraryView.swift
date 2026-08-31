import SwiftUI

struct ConsoleLibraryView: View {
    @StateObject private var discovery = ConsoleDiscoveryStore()
    @StateObject private var registeredConsoles = RegisteredConsoleStore()
    @State private var consoleToRegister: DiscoveredConsole?
    @State private var consoleToPlay: RegisteredConsole?
    @State private var consoleToRemove: RegisteredConsole?
    @State private var wakeError: String?
    @State private var showingManualConsole = false
    @AppStorage("streamResolution") private var streamResolution = 1080
    @AppStorage("streamFPS") private var streamFPS = 60
    @AppStorage("streamBitrate") private var streamBitrate = 15_000

    private var unregisteredConsoles: [DiscoveredConsole] {
        discovery.consoles.filter { registeredConsoles.registration(for: $0) == nil }
    }

    var body: some View {
        ZStack {
            TPPlayTheme.canvas.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    topBar
                    hero
                    if !registeredConsoles.consoles.isEmpty { consoleSection }
                    nearbySection
                    if let storageError = registeredConsoles.storageError {
                        Text("KEYCHAIN ERROR // \(storageError)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(TPPlayTheme.danger)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .refreshable { discovery.restart() }
        }
        .fullScreenCover(item: $consoleToRegister) { console in
            ConsoleRegistrationView(console: console, store: registeredConsoles)
        }
        .fullScreenCover(isPresented: $showingManualConsole) {
            ManualConsoleView { address, isPS5 in
                discovery.addManual(address: address, isPS5: isPS5)
                showingManualConsole = false
            }
        }
        .fullScreenCover(item: $consoleToPlay) { console in
            RemotePlayView(console: console, configuration: streamConfiguration)
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
        .alert("WAKE FAILED", isPresented: Binding(
            get: { wakeError != nil },
            set: { if !$0 { wakeError = nil } }
        )) {
            Button("OK", role: .cancel) { wakeError = nil }
        } message: { Text(wakeError ?? "Unknown error") }
    }

    private var streamConfiguration: StreamConfiguration {
        let height = UInt32(streamResolution)
        return StreamConfiguration(width: height == 1080 ? 1920 : 1280, height: height, fps: UInt32(streamFPS), bitrate: UInt32(streamBitrate))
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Spacer()
            HStack(spacing: 7) {
                Rectangle()
                    .fill(discovery.errorMessage == nil ? TPPlayTheme.accent : TPPlayTheme.danger)
                    .frame(width: 6, height: 6)
                Text("LOCAL")
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(TPPlayTheme.primaryText)
            .frame(width: 82, height: 38)
            .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }

            Button { showingManualConsole = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .black))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(AcidButtonStyle(active: true))
            .accessibilityLabel("Add console")
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("READY TO PLAY")
                .font(.system(size: 30, weight: .black, design: .monospaced))
                .tracking(-1)
                .foregroundStyle(TPPlayTheme.primaryText)
            Text("SELECT A CONSOLE. START A LOCAL SESSION.")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(TPPlayTheme.secondaryText)
        }
    }

    private var consoleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("MY CONSOLES", detail: "\(registeredConsoles.consoles.count)")
            ForEach(registeredConsoles.consoles) { registered in
                let nearby = discovery.console(matching: registered)
                RegisteredConsoleCard(console: registered, nearby: nearby, onPlay: {
                    let current = registered.updatedAddress(nearby?.address)
                    registeredConsoles.updateAddressIfNeeded(current)
                    if nearby?.state == .standby || nearby == nil {
                        wakeError = discovery.wake(current)
                    } else {
                        consoleToPlay = current
                    }
                }, onRemove: { consoleToRemove = registered })
            }
        }
    }

    @ViewBuilder private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("LOCAL NETWORK", detail: discovery.isSearching ? "SCANNING" : "IDLE")
            if let errorMessage = discovery.errorMessage {
                StatePanel(title: "NETWORK UNAVAILABLE", message: errorMessage, actionTitle: "RETRY", action: discovery.restart)
            } else if unregisteredConsoles.isEmpty {
                StatePanel(
                    title: registeredConsoles.consoles.isEmpty ? "SEARCHING FOR CONSOLE" : "NO NEW CONSOLES",
                    message: "ENABLE REMOTE PLAY AND KEEP THE CONSOLE ON THIS LOCAL NETWORK.",
                    actionTitle: nil,
                    action: nil
                )
            } else {
                ForEach(unregisteredConsoles) { console in
                    NearbyConsoleCard(console: console) { consoleToRegister = console }
                }
            }
        }
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
                        .foregroundStyle(nearby == nil ? TPPlayTheme.secondaryText : TPPlayTheme.accent)
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
                    Text(canStartSession ? "START SESSION" : "WAKE CONSOLE")
                    Spacer()
                    Text(">")
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(AcidButtonStyle(active: true))
        }
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
    }

    private var canStartSession: Bool { nearby?.state == .ready || nearby?.state == .unknown }
    private var statusText: String {
        guard let nearby else { return "SAVED // OFFLINE" }
        switch nearby.state {
        case .ready: return nearby.runningAppName ?? "READY"
        case .standby: return "REST MODE"
        case .unknown: return "AVAILABLE"
        }
    }
}

private struct NearbyConsoleCard: View {
    let console: DiscoveredConsole
    let onRegister: () -> Void

    var body: some View {
        Button(action: onRegister) {
            HStack(spacing: 14) {
                ConsoleGlyph(isPS5: console.isPS5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(console.name.uppercased()).font(.system(size: 14, weight: .black, design: .monospaced))
                    Text("\(console.isPS5 ? "PS5" : "PS4") // \(console.address)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.secondaryText)
                }
                Spacer()
                Text("LINK >")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.accent)
            }
            .foregroundStyle(TPPlayTheme.primaryText)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 76)
        }
        .buttonStyle(AcidButtonStyle())
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

private struct StatePanel: View {
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .foregroundStyle(TPPlayTheme.primaryText)
            Text(message)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(TPPlayTheme.secondaryText)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .frame(width: 120, height: 42)
                    .buttonStyle(AcidButtonStyle(active: true))
            } else {
                ProgressView().tint(TPPlayTheme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 26)
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
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
                Text("USE MANUAL ENTRY WHEN LOCAL DISCOVERY CANNOT SEE THE CONSOLE.")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.secondaryText)
                Spacer()
                Button("ADD CONSOLE >") { onAdd(address, isPS5) }
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
