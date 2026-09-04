import SwiftUI

private enum AppSection: String, CaseIterable {
    case community = "COMMUNITY"
    case news = "NEWS"
    case play = "PLAY"
    case library = "LIBRARY"
    case settings = "SETTINGS"
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var psnLibrary = PSNLibraryStore.shared
    @State private var selection = AppSection.community
    @State private var didRunLaunchProfileRefresh = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TPPlayTheme.canvas.ignoresSafeArea()
            Group {
                switch selection {
                case .community: CommunityView()
                case .play: ConsoleLibraryView()
                case .news: NewsView()
                case .library: LibraryView()
                case .settings: HomeView()
                }
            }
            .padding(.bottom, 72)

            AcidDock(selection: $selection)
                .frame(maxWidth: .infinity)
                .frame(height: 72)
                .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        }
        .ignoresSafeArea(edges: .bottom)
        .preferredColorScheme(.dark)
        .tint(TPPlayTheme.accent)
        .task {
            guard !didRunLaunchProfileRefresh else { return }
            didRunLaunchProfileRefresh = true
            await psnLibrary.refreshProfile(force: true)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, didRunLaunchProfileRefresh else { return }
            Task { await psnLibrary.refreshProfile() }
        }
    }
}

private struct AcidDock: View {
    @Binding var selection: AppSection

    var body: some View {
        GeometryReader { geometry in
            let itemWidth = geometry.size.width / CGFloat(AppSection.allCases.count)

            HStack(spacing: 0) {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, item in
                    Button { selection = item } label: {
                        AngularDockIcon(section: item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(selection == item ? TPPlayTheme.onAccent : TPPlayTheme.primaryText)
                        .background(selection == item ? TPPlayTheme.accent : TPPlayTheme.surface)
                        .overlay(alignment: .leading) {
                            if index > 0 {
                                Rectangle().fill(TPPlayTheme.violet).frame(width: 1)
                            }
                        }
                    }
                    .frame(width: itemWidth, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .buttonStyle(DockPressStyle())
                    .accessibilityLabel(item.rawValue.capitalized)
                    .accessibilityAddTraits(selection == item ? .isSelected : [])
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(TPPlayTheme.canvas)
            .overlay(alignment: .top) { Rectangle().fill(TPPlayTheme.violet).frame(height: 1) }
        }
    }
}

private struct AngularDockIcon: View {
    let section: AppSection

    @ViewBuilder var body: some View {
        switch section {
        case .community:
            ZStack {
                Rectangle()
                    .stroke(.foreground, style: StrokeStyle(lineWidth: 2, lineCap: .butt, lineJoin: .miter))
                    .frame(width: 18, height: 14)
                    .offset(y: -2)
                SharpChatTail()
                    .fill(.foreground)
                    .frame(width: 6, height: 6)
                    .offset(x: -5, y: 7)
                HStack(spacing: 3) {
                    Rectangle().fill(.foreground).frame(width: 3, height: 3)
                    Rectangle().fill(.foreground).frame(width: 3, height: 3)
                    Rectangle().fill(.foreground).frame(width: 3, height: 3)
                }
                .offset(y: -2)
            }
            .frame(width: 22, height: 22)

        case .play:
            ZStack {
                Rectangle()
                    .fill(.foreground)
                    .frame(width: 2, height: 18)
                    .offset(x: -9)
                SharpPlayhead()
                    .fill(.foreground)
                    .frame(width: 17, height: 18)
                    .offset(x: 3)
            }
            .frame(width: 22, height: 22)

        case .news:
            ZStack {
                Rectangle()
                    .stroke(.foreground, style: StrokeStyle(lineWidth: 2, lineCap: .butt, lineJoin: .miter))
                Rectangle().fill(.foreground).frame(width: 5, height: 5).offset(x: -5, y: -5)
                Rectangle().fill(.foreground).frame(width: 6, height: 2).offset(x: 5, y: -6.5)
                Rectangle().fill(.foreground).frame(width: 6, height: 2).offset(x: 5, y: -2.5)
                Rectangle().fill(.foreground).frame(width: 14, height: 2).offset(y: 3)
                Rectangle().fill(.foreground).frame(width: 10, height: 2).offset(x: -2, y: 7)
            }
            .frame(width: 20, height: 20)

        case .library:
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Rectangle().fill(.foreground)
                    Rectangle().fill(.foreground)
                }
                HStack(spacing: 4) {
                    Rectangle().fill(.foreground)
                    Rectangle().fill(.foreground)
                }
            }
            .frame(width: 20, height: 20)

        case .settings:
            Image(systemName: "gearshape.fill")
                .font(.system(size: 20, weight: .black))
            .frame(width: 22, height: 22)
        }
    }
}

private struct SharpPlayhead: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct SharpChatTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
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
        VStack(spacing: 0) {
            TPPageHeader(section)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 10)
                .background(TPPlayTheme.canvas)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
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
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background(TPPlayTheme.canvas)
    }
}

#Preview { RootView() }
