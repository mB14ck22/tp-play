import SwiftUI
import UIKit

struct ConsoleRegistrationView: View {
    let console: DiscoveredConsole
    @ObservedObject var store: RegisteredConsoleStore

    @Environment(\.dismiss) private var dismiss
    @StateObject private var registration = ConsoleRegistration()
    @StateObject private var psnAccount = PSNAccountIDResolver()
    @State private var accountID = ""
    @State private var pin = ""
    @State private var redirectURL = ""

    private var decodedAccountID: Data? {
        guard let data = Data(base64Encoded: accountID.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 8 else {
            return nil
        }
        return data
    }

    private var validPIN: UInt32? {
        guard pin.count == 8, pin.allSatisfy(\.isNumber) else { return nil }
        return UInt32(pin)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Console") {
                    LabeledContent("Name", value: console.name)
                    LabeledContent("Address", value: console.address)
                }

                Section {
                    TextField("Base64 account ID", text: $accountID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("8-digit PIN", text: $pin)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Remote Play registration")
                } footer: {
                    Text("On the console, open Settings → System → Remote Play → Link Device. Enter the displayed PIN and your PSN account ID encoded as Base64.")
                }

                Section {
                    Button("Sign in to PlayStation", systemImage: "safari") {
                        UIApplication.shared.open(PSNAccountIDResolver.loginURL)
                    }
                    TextField("Paste the redirect URL", text: $redirectURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Get account ID") {
                        Task {
                            if let value = await psnAccount.resolve(from: redirectURL) {
                                accountID = value
                            }
                        }
                    }
                    .disabled(redirectURL.isEmpty || psnAccount.isLoading)

                    if psnAccount.isLoading {
                        HStack { ProgressView(); Text("Retrieving account ID…") }
                    }
                    if let error = psnAccount.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Need your account ID?")
                } footer: {
                    Text("Sign in, copy the final redirect page URL from Safari, return here, and paste it above. Your password is entered only on Sony's website.")
                }

                Section {
                    registrationStatus
                    if registration.state == .succeeded {
                        Button("Done") { dismiss() }
                    } else {
                        Button("Link console") {
                            guard let accountID = decodedAccountID, let pin = validPIN else { return }
                            registration.start(console: console, accountID: accountID, pin: pin, store: store)
                        }
                        .disabled(decodedAccountID == nil || validPIN == nil || registration.state == .registering)
                    }

                    if registration.state == .registering {
                        Button("Cancel", role: .cancel) {
                            registration.cancel()
                        }
                    }
                }
            }
            .navigationTitle("Register \(console.isPS5 ? "PS5" : "PS4")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var registrationStatus: some View {
        switch registration.state {
        case .idle:
            EmptyView()
        case .registering:
            HStack {
                ProgressView()
                Text("Registering with the console…")
            }
        case .succeeded:
            Label("Console registered and keys saved securely.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .canceled:
            Label("Registration canceled.", systemImage: "xmark.circle")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

@MainActor
private final class PSNAccountIDResolver: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private static let clientID = "ba495a24-818c-472b-b12d-ff231c1b5745"
    private static let clientSecret = "mvaiZkRsAsI1IBkY"
    private static let redirect = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
    private static let tokenURL = URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token")!

    static let loginURL: URL = {
        var components = URLComponents(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "service_entity", value: "urn:service-entity:psn"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: "psn:clientapp"),
            URLQueryItem(name: "request_locale", value: "en_US"),
            URLQueryItem(name: "ui", value: "pr"),
            URLQueryItem(name: "service_logo", value: "ps"),
            URLQueryItem(name: "layout_type", value: "popup"),
            URLQueryItem(name: "smcid", value: "remoteplay"),
            URLQueryItem(name: "prompt", value: "always"),
            URLQueryItem(name: "PlatformPrivacyWs1", value: "minimal"),
        ]
        return components.url!
    }()

    func resolve(from redirectText: String) async -> String? {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard let components = URLComponents(string: redirectText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                  !code.isEmpty else {
                throw ResolverError.message("The pasted URL does not contain a sign-in code.")
            }

            var tokenRequest = URLRequest(url: Self.tokenURL)
            tokenRequest.httpMethod = "POST"
            tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            tokenRequest.setValue(Self.authorizationHeader, forHTTPHeaderField: "Authorization")
            var body = URLComponents()
            body.queryItems = [
                URLQueryItem(name: "grant_type", value: "authorization_code"),
                URLQueryItem(name: "code", value: code),
                URLQueryItem(name: "redirect_uri", value: Self.redirect),
            ]
            tokenRequest.httpBody = body.percentEncodedQuery?.data(using: .utf8)

            let (tokenData, tokenResponse) = try await URLSession.shared.data(for: tokenRequest)
            try Self.requireSuccess(tokenResponse)
            let tokenObject = try JSONSerialization.jsonObject(with: tokenData) as? [String: Any]
            guard let token = tokenObject?["access_token"] as? String, !token.isEmpty else {
                throw ResolverError.message("Sony did not return an access token. Sign in again.")
            }

            guard let encodedToken = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let accountURL = URL(string: Self.tokenURL.absoluteString + "/" + encodedToken) else {
                throw ResolverError.message("The returned access token is invalid.")
            }
            var accountRequest = URLRequest(url: accountURL)
            accountRequest.setValue(Self.authorizationHeader, forHTTPHeaderField: "Authorization")
            let (accountData, accountResponse) = try await URLSession.shared.data(for: accountRequest)
            try Self.requireSuccess(accountResponse)
            let accountObject = try JSONSerialization.jsonObject(with: accountData) as? [String: Any]
            let userIDText = accountObject?["user_id"] as? String ?? (accountObject?["user_id"] as? NSNumber)?.stringValue
            guard let userIDText, let userID = UInt64(userIDText) else {
                throw ResolverError.message("Sony did not return a valid account ID.")
            }
            var littleEndian = userID.littleEndian
            return withUnsafeBytes(of: &littleEndian) { Data($0).base64EncodedString() }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    private static var authorizationHeader: String {
        let value = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        return "Basic \(value)"
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ResolverError.message("Sony sign-in request failed (HTTP \(status)).")
        }
    }

    private enum ResolverError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let value) = self { return value }
            return nil
        }
    }
}
