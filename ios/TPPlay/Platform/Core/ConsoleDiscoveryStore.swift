import Foundation

struct DiscoveredConsole: Identifiable, Equatable, Sendable {
    enum State: Sendable {
        case unknown
        case ready
        case standby
    }

    let id: String
    let name: String
    let address: String
    let systemVersion: String
    let runningAppName: String?
    let isPS5: Bool
    let target: Int32
    let state: State
}

@MainActor
final class ConsoleDiscoveryStore: ObservableObject {
    @Published private(set) var consoles: [DiscoveredConsole] = []
    @Published private(set) var errorMessage: String?

    nonisolated(unsafe) private var discovery: OpaquePointer?
    private var registeredConsoles: [RegisteredConsole] = []

    var coreVersion: String {
        String(cString: tp_play_core_version())
    }

    init() {
    }

    private func restart() {
        tp_play_discovery_destroy(discovery)
        discovery = nil
        errorMessage = nil
        consoles = []
        if !registeredConsoles.isEmpty { start() }
    }

    func updateRegisteredConsoles(_ registeredConsoles: [RegisteredConsole]) {
        self.registeredConsoles = registeredConsoles
        if registeredConsoles.isEmpty {
            tp_play_discovery_destroy(discovery)
            discovery = nil
            consoles = []
            errorMessage = nil
        } else {
            consoles = consoles.filter(matchesRegisteredConsole)
        }
    }

    /// Runs a bounded, on-demand LAN discovery pass. The discovery service is
    /// stopped before this method returns so opening the Play page does not keep
    /// a background broadcast scan alive.
    func discoverConsole(matching registered: RegisteredConsole, timeoutMilliseconds: UInt64 = 3_000) async -> DiscoveredConsole? {
        restart()
        defer { stopDiscovery() }

        let interval: UInt64 = 100
        let attempts = max(1, Int(timeoutMilliseconds / interval))
        for _ in 0..<attempts {
            if let console = console(matching: registered) { return console }
            guard !Task.isCancelled else { return nil }
            try? await Task.sleep(for: .milliseconds(interval))
        }
        return console(matching: registered)
    }

    func console(matching registered: RegisteredConsole) -> DiscoveredConsole? {
        consoles.first { console in
            console.name == registered.nickname || console.address == registered.address
        }
    }

    func wake(_ console: RegisteredConsole) -> String? {
        let bytes = console.registrationKey.prefix { $0 != 0 }
        guard let text = String(data: Data(bytes), encoding: .utf8),
              let credential = UInt64(text, radix: 16) else {
            return "The saved wake credential is invalid. Link this console again."
        }
        let result = console.address.withCString {
            tp_play_console_wake($0, credential, console.target >= 1_000_000)
        }
        return result == 0 ? nil : "Wake request failed (core error \(result))."
    }

    private func start() {
        var errorCode: Int32 = 0
        discovery = tp_play_discovery_create(
            tpPlayDiscoveryCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            &errorCode
        )
        if discovery == nil {
            errorMessage = "Discovery could not start (core error \(errorCode))."
        }
    }

    private func stopDiscovery() {
        tp_play_discovery_destroy(discovery)
        discovery = nil
    }

    deinit {
        tp_play_discovery_destroy(discovery)
    }

    fileprivate func receive(_ consoles: [DiscoveredConsole]) {
        self.consoles = consoles.filter(matchesRegisteredConsole)
        errorMessage = nil
    }

    private func matchesRegisteredConsole(_ discovered: DiscoveredConsole) -> Bool {
        registeredConsoles.contains { registered in
            registered.nickname == discovered.name || registered.address == discovered.address
        }
    }
}

private let tpPlayDiscoveryCallback: @convention(c) (
    UnsafePointer<TPPlayHost>?,
    Int,
    UnsafeMutableRawPointer?
) -> Void = { hosts, count, context in
    guard let context else { return }

    var discovered: [DiscoveredConsole] = []
    if let hosts {
        discovered.reserveCapacity(count)
        for index in 0..<count {
            let host = hosts[index]
            let identifier = string(host.identifier)
            let address = string(host.address)
            let name = string(host.name)
            let runningApp = optionalString(host.running_app_name)
            let state: DiscoveredConsole.State
            switch host.state.rawValue {
            case 1: state = .ready
            case 2: state = .standby
            default: state = .unknown
            }

            discovered.append(
                DiscoveredConsole(
                    id: identifier.isEmpty ? address : identifier,
                    name: name.isEmpty ? (host.is_ps5 ? "PlayStation 5" : "PlayStation 4") : name,
                    address: address,
                    systemVersion: string(host.system_version),
                    runningAppName: runningApp,
                    isPS5: host.is_ps5,
                    target: Int32(host.target),
                    state: state
                )
            )
        }
    }

    let store = Unmanaged<ConsoleDiscoveryStore>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in
        store.receive(discovered)
    }
}

private func string(_ value: UnsafePointer<CChar>?) -> String {
    value.map(String.init(cString:)) ?? ""
}

private func optionalString(_ value: UnsafePointer<CChar>?) -> String? {
    let result = string(value)
    return result.isEmpty ? nil : result
}
