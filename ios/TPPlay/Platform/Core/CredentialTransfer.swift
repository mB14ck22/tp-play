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

    func canAttemptRemoteConnection(for console: RegisteredConsole) -> Bool {
        guard let credentials,
              !credentials.accessToken.isEmpty || !credentials.refreshToken.isEmpty,
              let accountID = Data(base64Encoded: credentials.accountID), accountID.count == 8 else { return false }
        return remoteDevice(for: console) != nil
    }

    func connection(for console: RegisteredConsole) async throws -> RemoteConsoleConnection? {
        guard var credentials else { throw RemoteCredentialError.unavailable }
        guard let device = remoteDevice(for: console) else { return nil }

        if credentials.accessToken.isEmpty || Date().timeIntervalSince1970 * 1000 >= credentials.tokenExpiry {
            credentials = try await refresh(credentials)
            let payload = RemoteCredentialPayload(credentials: credentials, remoteDevices: remoteDevices)
            try keychain.save(payload)
            self.credentials = credentials
            storageError = nil
        }

        guard let accountID = Data(base64Encoded: credentials.accountID), accountID.count == 8 else {
            throw RemoteCredentialError.invalidAccount
        }
        guard let consoleDUID = Data(hexString: device.duid), consoleDUID.count == 32 else {
            throw RemoteCredentialError.invalidConsole
        }

        return RemoteConsoleConnection(
            accessToken: credentials.accessToken,
            accountID: accountID,
            consoleDUID: consoleDUID,
            isPS5: device.isPS5
        )
    }

    private func remoteDevice(for console: RegisteredConsole) -> StoredRemoteDevice? {
        let isPS5 = console.target >= 1_000_000
        let devices = remoteDevices.filter { $0.isPS5 == isPS5 }
        return devices.first {
            $0.name.caseInsensitiveCompare(console.nickname) == .orderedSame
        } ?? (devices.count == 1 ? devices[0] : nil)
    }

    private func refresh(_ credentials: StoredPSNCredentials) async throws -> StoredPSNCredentials {
        guard !credentials.refreshToken.isEmpty else { throw RemoteCredentialError.signInRequired }

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: credentials.refreshToken),
            URLQueryItem(name: "scope", value: PSNRemoteAuth.scopes),
            URLQueryItem(name: "redirect_uri", value: PSNRemoteAuth.redirectURI),
            URLQueryItem(name: "client_id", value: PSNRemoteAuth.clientID),
            URLQueryItem(name: "client_secret", value: PSNRemoteAuth.clientSecret),
        ]

        var request = URLRequest(url: PSNRemoteAuth.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(PSNRemoteAuth.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RemoteCredentialError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw RemoteCredentialError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if [400, 401, 403].contains(http.statusCode) {
                throw RemoteCredentialError.signInRequired
            }
            throw RemoteCredentialError.service(http.statusCode)
        }

        let refreshed: PSNTokenRefreshResponse
        do {
            refreshed = try JSONDecoder().decode(PSNTokenRefreshResponse.self, from: data)
        } catch {
            throw RemoteCredentialError.invalidResponse
        }
        guard !refreshed.accessToken.isEmpty, refreshed.expiresIn > 0 else {
            throw RemoteCredentialError.invalidResponse
        }

        let refreshToken = refreshed.refreshToken.flatMap { $0.isEmpty ? nil : $0 } ?? credentials.refreshToken
        return StoredPSNCredentials(
            npsso: credentials.npsso,
            accessToken: refreshed.accessToken,
            refreshToken: refreshToken,
            tokenExpiry: Date().timeIntervalSince1970 * 1000 + refreshed.expiresIn * 1000,
            accountID: credentials.accountID,
            onlineID: credentials.onlineID,
            clientDUID: credentials.clientDUID
        )
    }
}

private enum PSNRemoteAuth {
    static let tokenURL = URL(string: "https://ca.account.sony.com/api/authz/v3/oauth/token")!
    static let clientID = "ba495a24-818c-472b-b12d-ff231c1b5745"
    static let clientSecret = "mvaiZkRsAsI1IBkY"
    static let redirectURI = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
    static let scopes = "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
}

private struct PSNTokenRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
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

    func save(_ payload: RemoteCredentialPayload) throws {
        let data = try JSONEncoder().encode(payload)
        let key: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw RemoteCredentialError.keychain(updateStatus)
        }
        var insert = key
        insert[kSecValueData] = data
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw RemoteCredentialError.keychain(addStatus)
        }
    }
}

private enum RemoteCredentialError: LocalizedError {
    case keychain(OSStatus)
    case unavailable
    case invalidAccount
    case invalidConsole
    case network
    case service(Int)
    case invalidResponse
    case signInRequired

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
        case .unavailable:
            return "No saved PSN credential is available."
        case .invalidAccount:
            return "The saved PSN account identifier is invalid."
        case .invalidConsole:
            return "The saved remote console identifier is invalid."
        case .network:
            return "Could not refresh the PSN credential. Check your network connection and try again."
        case .service(let status):
            return "PSN credential refresh failed (HTTP \(status)). Try again later."
        case .invalidResponse:
            return "PSN returned an invalid credential response. Try again later."
        case .signInRequired:
            return "The PSN session has expired and must be authorized again."
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
