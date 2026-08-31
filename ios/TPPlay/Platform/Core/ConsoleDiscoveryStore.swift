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

    var coreVersion: String {
        String(cString: tp_play_core_version())
    }

    init() {
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

    deinit {
        tp_play_discovery_destroy(discovery)
    }

    fileprivate func receive(_ consoles: [DiscoveredConsole]) {
        self.consoles = consoles
        errorMessage = nil
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
