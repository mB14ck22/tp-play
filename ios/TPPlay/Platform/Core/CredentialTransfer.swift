import Foundation
import Security

private struct StoredRemoteDevice: Codable {
    let name: String
    let duid: String
    let isPS5: Bool
}

private struct StoredPSNCredentials: Codable {
    let npsso: String
    let accessToken: String
    let refreshToken: String
    let tokenExpiry: TimeInterval
    let accountID: String
    let onlineID: String
    let clientDUID: String
}

struct RemoteConsoleConnection: Sendable {
    let accessToken: String
    let accountID: Data
    let consoleDUID: Data
    let isPS5: Bool
}

@MainActor
final class RemoteCredentialStore: ObservableObject {
    @Published private var credentials: StoredPSNCredentials?
    @Published private var remoteDevices: [StoredRemoteDevice] = []
    @Published private(set) var storageError: String?

    private let keychain = RemoteCredentialKeychain()

    init() {
        do {
            let payload = try keychain.load()
            credentials = payload?.credentials
            remoteDevices = payload?.remoteDevices ?? []
        } catch {
            storageError = error.localizedDescription
        }
    }

    func connection(for console: RegisteredConsole) -> RemoteConsoleConnection? {
        guard let credentials,
              !credentials.accessToken.isEmpty,
              Date().timeIntervalSince1970 * 1000 < credentials.tokenExpiry,
              let accountID = Data(base64Encoded: credentials.accountID), accountID.count == 8 else { return nil }

        let isPS5 = console.target >= 1_000_000
        let devices = remoteDevices.filter { $0.isPS5 == isPS5 }
        let device = devices.first {
            $0.name.caseInsensitiveCompare(console.nickname) == .orderedSame
        } ?? (devices.count == 1 ? devices[0] : nil)
        guard let device, let consoleDUID = Data(hexString: device.duid), consoleDUID.count == 32 else { return nil }
        return RemoteConsoleConnection(
            accessToken: credentials.accessToken,
            accountID: accountID,
            consoleDUID: consoleDUID,
            isPS5: device.isPS5
        )
    }
}

private struct RemoteCredentialPayload: Codable {
    let credentials: StoredPSNCredentials
    let remoteDevices: [StoredRemoteDevice]
}

private struct RemoteCredentialKeychain {
    private let service = "com.mb14ck22.tpplay.remote-credentials"
    private let account = "pylux-import"

    func load() throws -> RemoteCredentialPayload? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RemoteCredentialError.keychain(status)
        }
        return try JSONDecoder().decode(RemoteCredentialPayload.self, from: data)
    }
}

private enum RemoteCredentialError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        }
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }
}
