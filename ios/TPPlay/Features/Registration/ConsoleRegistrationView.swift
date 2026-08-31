import SwiftUI

struct ConsoleRegistrationView: View {
    let console: DiscoveredConsole
    @ObservedObject var store: RegisteredConsoleStore

    @Environment(\.dismiss) private var dismiss
    @StateObject private var registration = ConsoleRegistration()
    @State private var accountID = ""
    @State private var pin = ""

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
                    registrationStatus
                    Button("Register console") {
                        guard let accountID = decodedAccountID, let pin = validPIN else { return }
                        registration.start(console: console, accountID: accountID, pin: pin, store: store)
                    }
                    .disabled(decodedAccountID == nil || validPIN == nil || registration.state == .registering)

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
