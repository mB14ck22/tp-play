import SwiftUI

struct ConsoleLibraryView: View {
    @State private var isShowingRegistrationMilestone = false

    var body: some View {
        NavigationStack {
            ZStack {
                TPPlayTheme.canvas.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        introduction
                        emptyLibrary
                        implementationStatus
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 28)
                }
            }
            .navigationTitle("TP Play")
            .navigationBarTitleDisplayMode(.large)
            .preferredColorScheme(.dark)
            .sheet(isPresented: $isShowingRegistrationMilestone) {
                RegistrationMilestoneView()
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remote Play, natively built")
                .font(.title2.weight(.semibold))

            Text("Your registered consoles will appear here. The iOS client shell is ready; discovery and registration are the next implementation milestone.")
                .font(.body)
                .foregroundStyle(TPPlayTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 18) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(TPPlayTheme.accent)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("No consoles registered")
                    .font(.headline)

                Text("Registration is not connected to the Chiaki core yet.")
                    .font(.subheadline)
                    .foregroundStyle(TPPlayTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            Button {
                isShowingRegistrationMilestone = true
            } label: {
                Label("View next milestone", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(TPPlayTheme.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(TPPlayTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(TPPlayTheme.border, lineWidth: 1)
        }
    }

    private var implementationStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FOUNDATION")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(TPPlayTheme.secondaryText)

            StatusRow(title: "Native SwiftUI application", isReady: true)
            StatusRow(title: "Chiaki C bridge", isReady: false)
            StatusRow(title: "VideoToolbox and Metal", isReady: false)
            StatusRow(title: "Audio and controller input", isReady: false)
        }
    }
}

private struct StatusRow: View {
    let title: String
    let isReady: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isReady ? Color.green : TPPlayTheme.secondaryText)

            Text(title)
                .font(.subheadline)

            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isReady ? "Ready" : "Not implemented")
    }
}

private struct RegistrationMilestoneView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "network")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(TPPlayTheme.accent)

                Text("Discovery and registration")
                    .font(.title2.weight(.semibold))

                Text("The next milestone will expose console discovery and registration through a stable C bridge into libchiaki. This screen does not claim those capabilities are available yet.")
                    .foregroundStyle(TPPlayTheme.secondaryText)

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TPPlayTheme.canvas.ignoresSafeArea())
            .navigationTitle("Next milestone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}

#Preview {
    ConsoleLibraryView()
}
