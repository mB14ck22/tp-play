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
        ZStack {
            TPPlayTheme.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("LINK // \(console.isPS5 ? "PS5" : "PS4")")
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                            .foregroundStyle(TPPlayTheme.accent)
                        Spacer()
                        Button("X") { dismiss() }
                            .frame(width: 42, height: 42)
                            .buttonStyle(AcidButtonStyle())
                    }

                    infoPanel
                    fieldBlock("ACCOUNT ID // BASE64") {
                        TextField("BASE64 ACCOUNT ID", text: $accountID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(AcidFieldStyle())
                    }
                    fieldBlock("REMOTE PLAY // 8-DIGIT PIN") {
                        SecureField("00000000", text: $pin)
                            .keyboardType(.numberPad)
                            .textFieldStyle(AcidFieldStyle())
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("PSN ACCOUNT LOOKUP").registrationLabel()
                        Button("OPEN PLAYSTATION SIGN-IN >") {
                            UIApplication.shared.open(PSNAccountIDResolver.loginURL)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(AcidButtonStyle())
                        TextField("PASTE FINAL REDIRECT URL", text: $redirectURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(AcidFieldStyle())
                        Button("GET ACCOUNT ID") {
                            Task {
                                if let value = await psnAccount.resolve(from: redirectURL) { accountID = value }
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(AcidButtonStyle(active: true))
                        .disabled(redirectURL.isEmpty || psnAccount.isLoading)
                        if psnAccount.isLoading {
                            HStack { ProgressView().tint(TPPlayTheme.accent); Text("RETRIEVING ACCOUNT ID...") }
                                .registrationLabel()
                        }
                        if let error = psnAccount.errorMessage {
                            Text("ERROR // \(error)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(TPPlayTheme.danger)
                        }
                        Text("YOUR PASSWORD IS ENTERED ONLY ON SONY'S WEBSITE.")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(TPPlayTheme.secondaryText)
                    }
                    .padding(14)
                    .background(TPPlayTheme.surface)
                    .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }

                    registrationStatus
                    if registration.state == .succeeded {
                        Button("DONE >") { dismiss() }
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .buttonStyle(AcidButtonStyle(active: true))
                    } else {
                        Button("LINK CONSOLE >") {
                            guard let accountID = decodedAccountID, let pin = validPIN else { return }
                            registration.start(console: console, accountID: accountID, pin: pin, store: store)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .buttonStyle(AcidButtonStyle(active: true))
                        .disabled(decodedAccountID == nil || validPIN == nil || registration.state == .registering)
                    }
                    if registration.state == .registering {
                        Button("CANCEL") { registration.cancel() }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .buttonStyle(AcidButtonStyle())
                    }
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("CONSOLE"); Spacer(); Text(console.name.uppercased()) }
            HStack { Text("ADDRESS"); Spacer(); Text(console.address) }
        }
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundStyle(TPPlayTheme.primaryText)
        .padding(14)
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
    }

    private func fieldBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).registrationLabel()
            content()
        }
    }

    @ViewBuilder
    private var registrationStatus: some View {
        switch registration.state {
        case .idle:
            EmptyView()
        case .registering:
            HStack {
                ProgressView().tint(TPPlayTheme.accent)
                Text("LINKING WITH CONSOLE...")
            }
        case .succeeded:
            Text("LINKED // KEYS SAVED SECURELY")
                .foregroundStyle(TPPlayTheme.accent)
        case .canceled:
            Text("REGISTRATION CANCELED")
        case .failed(let message):
            Text("ERROR // \(message)").foregroundStyle(TPPlayTheme.danger)
        }
    }
}

private extension View {
    func registrationLabel() -> some View {
        font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(0.7)
            .foregroundStyle(TPPlayTheme.secondaryText)
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
