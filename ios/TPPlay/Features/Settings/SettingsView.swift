import AuthenticationServices
import SwiftUI
import UIKit

struct HomeView: View {
    @StateObject private var psnLibrary = PSNLibraryStore.shared
    @StateObject private var psnAuthenticator = PSNWebAuthenticator()
    @ObservedObject private var touchLayouts = TouchLayoutStore.shared
    @AppStorage("streamResolution") private var resolution = 1080
    @AppStorage("streamFPS") private var fps = 60
    @AppStorage("streamBitrate") private var bitrate = 15_000
    @State private var showingTouchLayouts = false
    @State private var showingLinkDiagnostic = false

    var body: some View {
        VStack(spacing: 0) {
            TPPageHeader("HOME // CONFIG")
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 10)
                .background(TPPlayTheme.canvas)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                psnAccountPanel
                touchControlsPanel
                Button("LINK DIAGNOSTIC // 串流链路测试 >") { showingLinkDiagnostic = true }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .buttonStyle(AcidButtonStyle())
                VStack(alignment: .leading, spacing: 18) {
                    configHeader("STREAM PROFILE", value: "\(resolution)P / \(fps)FPS")
                    choiceRow("RESOLUTION", choices: [("720P", 720), ("1080P", 1080)], selection: $resolution)
                    choiceRow("FRAME RATE", choices: [("30 FPS", 30), ("60 FPS", 60)], selection: $fps)
                    VStack(alignment: .leading, spacing: 8) {
                        configHeader("BITRATE", value: "\(bitrate / 1_000) MBPS // NEXT SESSION")
                        HStack(spacing: 8) {
                            Button("−") { bitrate = max(2_000, bitrate - 1_000) }
                                .frame(width: 48, height: 44)
                                .buttonStyle(AcidButtonStyle())
                            Text("\(bitrate / 1_000)")
                                .font(.system(size: 18, weight: .black, design: .monospaced))
                                .foregroundStyle(TPPlayTheme.accent)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(TPPlayTheme.canvas)
                                .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
                            Button("+") { bitrate = min(100_000, bitrate + 1_000) }
                                .frame(width: 48, height: 44)
                                .buttonStyle(AcidButtonStyle())
                        }
                        Text("2–100 MBPS // HIGHER VALUES PRESERVE FAST MOTION BUT REQUIRE A STABLE DIRECT PATH")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .tracking(0.35)
                            .foregroundStyle(TPPlayTheme.tertiaryText)
                    }
                    Button("RESET RECOMMENDED") {
                        resolution = 1080
                        fps = 60
                        bitrate = 15_000
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(AcidButtonStyle(active: true))
                }
                .padding(16)
                .background(TPPlayTheme.surface)
                .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }

                VStack(alignment: .leading, spacing: 8) {
                    Text("TP PLAY")
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.primaryText)
                    Text("OPEN SOURCE REMOTE PLAY CLIENT")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(TPPlayTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 20)
            }
        }
        .background(TPPlayTheme.canvas)
        .fullScreenCover(isPresented: $showingTouchLayouts) {
            TouchLayoutSettingsView()
        }
        .fullScreenCover(isPresented: $showingLinkDiagnostic) {
            LinkDiagnosticView()
        }
    }

    private var touchControlsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            configHeader("TOUCH CONTROLS", value: "\(touchLayouts.presets.count) PRESET\(touchLayouts.presets.count == 1 ? "" : "S")")
            HStack(spacing: 12) {
                Rectangle()
                    .fill(TPPlayTheme.violet)
                    .frame(width: 8, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("CONTROL PRESET LIBRARY")
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.primaryText)
                        .lineLimit(1)
                    Text("SELECT A PRESET WHILE STREAMING")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(TPPlayTheme.secondaryText)
                }
                Spacer()
            }
            Button("MANAGE + EDIT PRESETS >") { showingTouchLayouts = true }
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(AcidButtonStyle(active: true))
        }
        .padding(16)
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
    }

    private var psnAccountPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            configHeader("PLAYSTATION NETWORK", value: psnLibrary.signedInOnlineID?.uppercased() ?? "NOT CONNECTED")

            if psnLibrary.isSignedIn {
                Text("PSN LINKED // TROPHY ARCHIVE ENABLED")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.accent)
                Button(psnLibrary.isLoading ? "SYNCING..." : "SYNC TROPHY ARCHIVE") {
                    Task { await psnLibrary.sync() }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(AcidButtonStyle(active: true))
                .disabled(psnLibrary.isLoading)
                Button("SIGN OUT PSN") { psnLibrary.signOut() }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(AcidButtonStyle())
            } else {
                Button(psnLibrary.isLoading || psnAuthenticator.isAuthenticating ? "CONNECTING..." : "CONNECT PSN + LOAD LIBRARY") {
                    Task { await psnAuthenticator.connect(library: psnLibrary) }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(AcidButtonStyle(active: true))
                .disabled(psnLibrary.isLoading || psnAuthenticator.isAuthenticating)
                Text("SIGN-IN RUNS IN SONY'S SECURE WEB SESSION AND RETURNS TO TP PLAY AUTOMATICALLY. ONLY THE RETURNED SESSION IS STORED IN IOS KEYCHAIN.")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.secondaryText)
            }

            if let error = psnLibrary.errorMessage ?? psnAuthenticator.errorMessage {
                Text("ERROR // \(error.uppercased())")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.danger)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay { Rectangle().stroke(TPPlayTheme.danger, lineWidth: 1) }
            }
        }
        .padding(16)
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
    }

    private func configHeader(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(TPPlayTheme.secondaryText)
            Spacer()
            Text(value).foregroundStyle(TPPlayTheme.accent)
        }
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .tracking(0.6)
    }

    private func choiceRow(_ title: String, choices: [(String, Int)], selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(TPPlayTheme.secondaryText)
            HStack(spacing: 8) {
                ForEach(choices, id: \.1) { choice in
                    Button(choice.0) { selection.wrappedValue = choice.1 }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(AcidButtonStyle(active: selection.wrappedValue == choice.1))
                }
            }
        }
    }
}

@MainActor
private final class PSNWebAuthenticator: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var isAuthenticating = false
    @Published private(set) var errorMessage: String?

    private var session: ASWebAuthenticationSession?
    private weak var presentationWindow: UIWindow?

    func connect(library: PSNLibraryStore) async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        do {
            let callback = try await authenticate()
            await library.signIn(from: callback.absoluteString)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func authenticate() async throws -> URL {
        guard session == nil else { throw PSNWebAuthenticationError.alreadyRunning }
        guard let window = Self.activeWindow else { throw PSNWebAuthenticationError.noPresentationWindow }
        presentationWindow = window

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: PSNLibraryStore.loginURL,
                callbackURLScheme: PSNLibraryStore.loginCallbackScheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor in
                    self?.session = nil
                    self?.presentationWindow = nil
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else {
                        continuation.resume(throwing: PSNWebAuthenticationError.missingCallback)
                    }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session

            if !session.start() {
                self.session = nil
                self.presentationWindow = nil
                continuation.resume(throwing: PSNWebAuthenticationError.couldNotStart)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationWindow ?? Self.activeWindow ?? UIWindow()
    }

    private static var activeWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

private enum PSNWebAuthenticationError: LocalizedError {
    case alreadyRunning
    case noPresentationWindow
    case missingCallback
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "A PSN sign-in is already running."
        case .noPresentationWindow: "TP Play could not present the PSN sign-in window."
        case .missingCallback: "Sony completed sign-in without returning an authorization code."
        case .couldNotStart: "TP Play could not start the PSN sign-in session."
        }
    }
}

#Preview { HomeView() }
