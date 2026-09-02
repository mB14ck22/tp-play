import SwiftUI
import UIKit

struct HomeView: View {
    @StateObject private var psnLibrary = PSNLibraryStore.shared
    @AppStorage("streamResolution") private var resolution = 1080
    @AppStorage("streamFPS") private var fps = 60
    @AppStorage("streamBitrate") private var bitrate = 15_000
    @State private var psnRedirectURL = ""

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
                VStack(alignment: .leading, spacing: 18) {
                    configHeader("STREAM PROFILE", value: "\(resolution)P / \(fps)FPS")
                    choiceRow("RESOLUTION", choices: [("720P", 720), ("1080P", 1080)], selection: $resolution)
                    choiceRow("FRAME RATE", choices: [("30 FPS", 30), ("60 FPS", 60)], selection: $fps)
                    VStack(alignment: .leading, spacing: 8) {
                        configHeader("BITRATE", value: "\(bitrate / 1_000) MBPS")
                        HStack(spacing: 8) {
                            Button("−") { bitrate = max(4_000, bitrate - 1_000) }
                                .frame(width: 48, height: 44)
                                .buttonStyle(AcidButtonStyle())
                            Text("\(bitrate / 1_000)")
                                .font(.system(size: 18, weight: .black, design: .monospaced))
                                .foregroundStyle(TPPlayTheme.accent)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(TPPlayTheme.canvas)
                                .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
                            Button("+") { bitrate = min(30_000, bitrate + 1_000) }
                                .frame(width: 48, height: 44)
                                .buttonStyle(AcidButtonStyle())
                        }
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
                Button("OPEN PLAYSTATION SIGN-IN >") {
                    UIApplication.shared.open(PSNLibraryStore.loginURL)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(AcidButtonStyle())
                TextField("PASTE FINAL REDIRECT URL", text: $psnRedirectURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(AcidFieldStyle())
                Button(psnLibrary.isLoading ? "CONNECTING..." : "CONNECT PSN + LOAD LIBRARY") {
                    Task { await psnLibrary.signIn(from: psnRedirectURL) }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(AcidButtonStyle(active: true))
                .disabled(psnRedirectURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || psnLibrary.isLoading)
                Text("SIGN-IN RUNS ON SONY'S WEBSITE. TP PLAY STORES ONLY THE RETURNED SESSION IN IOS KEYCHAIN.")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.secondaryText)
            }

            if let error = psnLibrary.errorMessage {
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

#Preview { HomeView() }
