import SwiftUI

struct ConsoleLibraryView: View {
    @StateObject private var discovery = ConsoleDiscoveryStore()
    @StateObject private var registeredConsoles = RegisteredConsoleStore()
    @State private var consoleToRegister: DiscoveredConsole?
    @State private var consoleToPlay: RegisteredConsole?
    @State private var consoleToRemove: RegisteredConsole?
    @State private var wakeError: String?
    @State private var showingManualConsole = false
    @State private var showingSettings = false
    @AppStorage("streamResolution") private var streamResolution = 1080
    @AppStorage("streamFPS") private var streamFPS = 60
    @AppStorage("streamBitrate") private var streamBitrate = 15_000

    private var unregisteredConsoles: [DiscoveredConsole] {
        discovery.consoles.filter { registeredConsoles.registration(for: $0) == nil }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TPPlayTheme.canvas.ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 32) {
                        hero
                        if !registeredConsoles.consoles.isEmpty { consoleSection }
                        nearbySection
                        if let storageError = registeredConsoles.storageError {
                            Label(storageError, systemImage: "key.slash")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 44)
                }
                .refreshable { discovery.restart() }
            }
            .navigationTitle("TP Play")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Streaming settings", systemImage: "slider.horizontal.3") { showingSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add console", systemImage: "plus") { showingManualConsole = true }
                }
            }
            .sheet(item: $consoleToRegister) { console in
                ConsoleRegistrationView(console: console, store: registeredConsoles)
            }
            .sheet(isPresented: $showingManualConsole) {
                ManualConsoleView { address, isPS5 in
                    discovery.addManual(address: address, isPS5: isPS5)
                    showingManualConsole = false
                }
            }
            .sheet(isPresented: $showingSettings) {
                StreamingSettingsView()
            }
            .fullScreenCover(item: $consoleToPlay) { console in
                RemotePlayView(console: console, configuration: streamConfiguration)
            }
            .confirmationDialog(
                "Remove this console?",
                isPresented: Binding(
                    get: { consoleToRemove != nil },
                    set: { if !$0 { consoleToRemove = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove console", role: .destructive) {
                    guard let consoleToRemove else { return }
                    registeredConsoles.remove(consoleToRemove)
                    self.consoleToRemove = nil
                }
                Button("Cancel", role: .cancel) { consoleToRemove = nil }
            } message: {
                Text("You will need to link this PlayStation again before using Remote Play.")
            }
            .alert("Could not wake console", isPresented: Binding(
                get: { wakeError != nil },
                set: { if !$0 { wakeError = nil } }
            )) {
                Button("OK", role: .cancel) { wakeError = nil }
            } message: {
                Text(wakeError ?? "Unknown error")
            }
        }
    }

    private var streamConfiguration: StreamConfiguration {
        let height = UInt32(streamResolution)
        return StreamConfiguration(
            width: height == 1080 ? 1920 : 1280,
            height: height,
            fps: UInt32(streamFPS),
            bitrate: UInt32(streamBitrate)
        )
    }

    private var hero: some View {
        HStack(spacing: 14) {
            Image(systemName: "playstation.logo")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(TPPlayTheme.accent)
                .frame(width: 52, height: 52)
                .background(TPPlayTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("Remote Play").font(.title2.weight(.bold))
                Text("Your PlayStation, on this screen.")
                    .font(.subheadline)
                    .foregroundStyle(TPPlayTheme.secondaryText)
            }
        }
    }

    private var consoleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("MY CONSOLES", detail: "\(registeredConsoles.consoles.count)")
            ForEach(registeredConsoles.consoles) { registered in
                let nearby = discovery.console(matching: registered)
                RegisteredConsoleCard(
                    console: registered,
                    nearby: nearby,
                    onPlay: {
                        let current = registered.updatedAddress(nearby?.address)
                        registeredConsoles.updateAddressIfNeeded(current)
                        if nearby?.state == .standby || nearby == nil {
                            wakeError = discovery.wake(current)
                        } else {
                            consoleToPlay = current
                        }
                    },
                    onRemove: { consoleToRemove = registered }
                )
            }
        }
    }

    @ViewBuilder
    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("NEARBY", detail: discovery.isSearching ? "SEARCHING" : nil)
            if let errorMessage = discovery.errorMessage {
                StatePanel(symbol: "wifi.exclamationmark", title: "Local network unavailable", message: errorMessage, actionTitle: "Try again", action: discovery.restart)
            } else if unregisteredConsoles.isEmpty {
                StatePanel(
                    symbol: registeredConsoles.consoles.isEmpty ? "gamecontroller" : "dot.radiowaves.left.and.right",
                    title: registeredConsoles.consoles.isEmpty ? "Looking for your PlayStation" : "No new consoles found",
                    message: "Turn on Remote Play on your PS4 or PS5 and keep it on the same Wi-Fi network as this iPhone.",
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

    private func sectionHeader(_ title: String, detail: String?) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.bold))
                .tracking(1.3)
                .foregroundStyle(TPPlayTheme.tertiaryText)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(TPPlayTheme.tertiaryText)
            }
        }
    }
}

private struct RegisteredConsoleCard: View {
    let console: RegisteredConsole
    let nearby: DiscoveredConsole?
    let onPlay: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 16) {
                ConsoleGlyph(isPS5: console.isPS5)
                VStack(alignment: .leading, spacing: 5) {
                    Text(console.nickname)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(nearby == nil ? TPPlayTheme.tertiaryText : Color.green)
                            .frame(width: 7, height: 7)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(TPPlayTheme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: canStartSession ? "play.fill" : "power")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(width: 44, height: 44)
                    .background(TPPlayTheme.accent, in: Circle())
            }
            .padding(16)
            .background(TPPlayTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Menu {
                    Button("Remove console", systemImage: "trash", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(TPPlayTheme.secondaryText)
                        .frame(width: 44, height: 44)
                }
                .offset(x: -58, y: 16)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(TPPlayTheme.border, lineWidth: 1)
            }
        }
        .buttonStyle(ConsolePressStyle())
        .accessibilityHint(canStartSession ? "Starts Remote Play" : "Sends a wake request")
    }

    private var canStartSession: Bool { nearby?.state == .ready || nearby?.state == .unknown }

    private var statusText: String {
        guard let nearby else { return "Saved" }
        switch nearby.state {
        case .ready: return nearby.runningAppName ?? "Ready to play"
        case .standby: return "Rest mode"
        case .unknown: return "Available"
        }
    }
}

private struct NearbyConsoleCard: View {
    let console: DiscoveredConsole
    let onRegister: () -> Void

    var body: some View {
        Button(action: onRegister) {
            HStack(spacing: 16) {
                ConsoleGlyph(isPS5: console.isPS5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(console.name).font(.headline).foregroundStyle(.white)
                    Text("\(console.isPS5 ? "PS5" : "PS4")  ·  \(console.address)")
                        .font(.caption)
                        .foregroundStyle(TPPlayTheme.secondaryText)
                }
                Spacer()
                Text("LINK")
                    .font(.caption.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(TPPlayTheme.accent)
                    .frame(minWidth: 52, minHeight: 44)
            }
            .padding(16)
            .background(TPPlayTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(TPPlayTheme.border, lineWidth: 1)
            }
        }
        .buttonStyle(ConsolePressStyle())
    }
}

private struct ConsoleGlyph: View {
    let isPS5: Bool
    var body: some View {
        Image(systemName: isPS5 ? "playstation.logo" : "gamecontroller.fill")
            .font(.title2.weight(.medium))
            .foregroundStyle(TPPlayTheme.accent)
            .frame(width: 48, height: 48)
            .background(TPPlayTheme.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct StatePanel: View {
    let symbol: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(TPPlayTheme.accent)
            VStack(spacing: 6) {
                Text(title).font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(TPPlayTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .tint(TPPlayTheme.accent)
            } else {
                ProgressView().tint(TPPlayTheme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .background(TPPlayTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(TPPlayTheme.border, lineWidth: 1)
        }
    }
}

private struct ConsolePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ManualConsoleView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var isPS5 = true
    let onAdd: (String, Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Console type") {
                    Picker("Console", selection: $isPS5) {
                        Text("PlayStation 5").tag(true)
                        Text("PlayStation 4").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    TextField("IP address or hostname", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Network address")
                } footer: {
                    Text("Use this when automatic discovery cannot see a console on your local network.")
                }
            }
            .navigationTitle("Add console")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { onAdd(address, isPS5) }
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct StreamingSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("streamResolution") private var resolution = 1080
    @AppStorage("streamFPS") private var fps = 60
    @AppStorage("streamBitrate") private var bitrate = 15_000

    var body: some View {
        NavigationStack {
            Form {
                Section("Video") {
                    Picker("Resolution", selection: $resolution) {
                        Text("720p").tag(720)
                        Text("1080p").tag(1080)
                    }
                    Picker("Frame rate", selection: $fps) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Bitrate", value: "\(bitrate / 1_000) Mbps")
                        Slider(
                            value: Binding(get: { Double(bitrate) }, set: { bitrate = Int($0) }),
                            in: 4_000...30_000,
                            step: 1_000
                        )
                    }
                }

                Section {
                    Button("Reset to recommended") {
                        resolution = 1080
                        fps = 60
                        bitrate = 15_000
                    }
                } footer: {
                    Text("1080p at 60 fps and 15 Mbps is recommended for a strong 5 GHz or 6 GHz local network. Use 720p or a lower bitrate if video stutters.")
                }
            }
            .navigationTitle("Streaming")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
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
