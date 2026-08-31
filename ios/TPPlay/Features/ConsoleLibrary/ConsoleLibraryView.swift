import SwiftUI

struct ConsoleLibraryView: View {
    @StateObject private var discovery = ConsoleDiscoveryStore()

    var body: some View {
        NavigationStack {
            ZStack {
                TPPlayTheme.canvas.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        introduction
                        consoleLibrary
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
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remote Play, natively built")
                .font(.title2.weight(.semibold))

            Text("Keep your iPhone on the same network as your PlayStation. TP Play scans the local network automatically.")
                .font(.body)
                .foregroundStyle(TPPlayTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var consoleLibrary: some View {
        if let errorMessage = discovery.errorMessage {
            ContentUnavailableView(
                "Discovery unavailable",
                systemImage: "wifi.exclamationmark",
                description: Text(errorMessage)
            )
        } else if discovery.consoles.isEmpty {
            emptyLibrary
        } else {
            VStack(spacing: 12) {
                ForEach(discovery.consoles) { console in
                    ConsoleCard(console: console)
                }
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 18) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(TPPlayTheme.accent)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Searching for consoles")
                    .font(.headline)

                Text("Turn on your PS4 or PS5 and allow Local Network access when iOS asks.")
                    .font(.subheadline)
                    .foregroundStyle(TPPlayTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            ProgressView()
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
            StatusRow(title: "Chiaki core \(discovery.coreVersion) and LAN discovery", isReady: true)
            StatusRow(title: "VideoToolbox and Metal", isReady: false)
            StatusRow(title: "Audio and controller input", isReady: false)
        }
    }
}

private struct ConsoleCard: View {
    let console: DiscoveredConsole

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: console.isPS5 ? "playstation.logo" : "gamecontroller.fill")
                .font(.title2)
                .foregroundStyle(TPPlayTheme.accent)
                .frame(width: 44, height: 44)
                .background(TPPlayTheme.canvas, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(console.name)
                    .font(.headline)
                Text([console.isPS5 ? "PS5" : "PS4", console.address].joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(TPPlayTheme.secondaryText)
                if let runningAppName = console.runningAppName {
                    Text(runningAppName)
                        .font(.caption)
                        .lineLimit(1)
                }
            }

            Spacer()

            Circle()
                .fill(console.state == .ready ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
                .accessibilityLabel(console.state == .ready ? "Ready" : "Standby")
        }
        .padding(16)
        .background(TPPlayTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(TPPlayTheme.border, lineWidth: 1)
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

#Preview {
    ConsoleLibraryView()
}
