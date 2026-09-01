import SwiftUI

private enum AppSection: String, CaseIterable {
    case play = "PLAY"
    case news = "NEWS"
    case library = "LIBRARY"
    case home = "HOME"
}

struct RootView: View {
    @State private var selection = AppSection.play

    var body: some View {
        ZStack(alignment: .bottom) {
            TPPlayTheme.canvas.ignoresSafeArea()
            Group {
                switch selection {
                case .play: ConsoleLibraryView()
                case .news: NewsView()
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
                        AngularDockIcon(section: item)
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

private struct AngularDockIcon: View {
    let section: AppSection

    @ViewBuilder var body: some View {
        switch section {
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

        case .home:
            ZStack {
                AngularHomeOutline()
                    .stroke(.foreground, style: StrokeStyle(lineWidth: 2, lineCap: .butt, lineJoin: .miter))
                Rectangle()
                    .fill(.foreground)
                    .frame(width: 5, height: 7)
                    .offset(y: 6.5)
            }
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

private struct AngularHomeOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 1, y: rect.minY + 10))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY + 1))
        path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.minY + 10))
        path.move(to: CGPoint(x: rect.minX + 4, y: rect.minY + 7))
        path.addLine(to: CGPoint(x: rect.minX + 4, y: rect.maxY - 1))
        path.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.maxY - 1))
        path.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.minY + 7))
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
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                TPPageHeader(section)
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
