import SwiftUI

private enum AppSection: String, CaseIterable {
    case play = "PLAY"
    case news = "NEWS"
    case library = "LIBRARY"
    case home = "HOME"

    var symbol: String {
        switch self {
        case .play: return "play.fill"
        case .news: return "bolt.horizontal.fill"
        case .library: return "square.grid.2x2.fill"
        case .home: return "house.fill"
        }
    }
}

struct RootView: View {
    @State private var selection = AppSection.play

    var body: some View {
        ZStack(alignment: .bottom) {
            TPPlayTheme.canvas.ignoresSafeArea()
            Group {
                switch selection {
                case .play: ConsoleLibraryView()
                case .news: PlaceholderSectionView(section: "NEWS // FEED", title: "NO FEED CONNECTED", message: "NEWS SOURCES WILL APPEAR HERE.", symbol: "bolt.horizontal.fill")
                case .library: PlaceholderSectionView(section: "LIBRARY // TROPHIES", title: "TROPHY DATA OFFLINE", message: "CONNECT A DATA SOURCE TO BUILD YOUR LIBRARY.", symbol: "square.grid.2x2.fill")
                case .home: HomeView()
                }
            }
            .padding(.bottom, 72)

            AcidDock(selection: $selection)
                .frame(height: 72)
        }
        .ignoresSafeArea(edges: .bottom)
        .preferredColorScheme(.dark)
        .tint(TPPlayTheme.accent)
    }
}

private struct AcidDock: View {
    @Binding var selection: AppSection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, item in
                Button { selection = item } label: {
                    VStack(spacing: 2) {
                        Image(systemName: item.symbol).font(.system(size: 13, weight: .black))
                        Text(item.rawValue)
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .tracking(0.5)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(selection == item ? TPPlayTheme.onAccent : TPPlayTheme.primaryText)
                    .background(selection == item ? TPPlayTheme.accent : TPPlayTheme.surface)
                    .overlay(alignment: .leading) {
                        if index > 0 {
                            Rectangle().fill(TPPlayTheme.violet).frame(width: 1)
                        }
                    }
                }
                .buttonStyle(DockPressStyle())
                .accessibilityAddTraits(selection == item ? .isSelected : [])
            }
        }
        .background(TPPlayTheme.canvas)
        .overlay(alignment: .top) { Rectangle().fill(TPPlayTheme.violet).frame(height: 1) }
    }
}

private struct DockPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.62 : 1)
    }
}

private struct PlaceholderSectionView: View {
    let section: String
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(section)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(TPPlayTheme.accent)
                Spacer(minLength: 40)
                VStack(spacing: 18) {
                    Image(systemName: symbol)
                        .font(.system(size: 34, weight: .black))
                        .foregroundStyle(TPPlayTheme.violet)
                    Text(title)
                        .font(.system(size: 20, weight: .black, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.primaryText)
                    Text(message)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(TPPlayTheme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 44)
                .background(TPPlayTheme.surface)
                .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
                Spacer(minLength: 80)
            }
            .padding(20)
        }
        .background(TPPlayTheme.canvas)
    }
}

#Preview { RootView() }
