import SwiftUI

@MainActor
final class TPTerminalTitleAnimator: ObservableObject {
    static let shared = TPTerminalTitleAnimator()

    @Published private(set) var renderedTitle = ""
    @Published private(set) var cursorVisible = false

    private var targetTitle = ""
    private var animationTask: Task<Void, Never>?

    func transition(to title: String, reduceMotion: Bool) {
        guard targetTitle != title else { return }
        targetTitle = title
        animationTask?.cancel()

        if reduceMotion {
            renderedTitle = title
            cursorVisible = false
            return
        }

        animationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            cursorVisible = true

            while !renderedTitle.isEmpty {
                guard !Task.isCancelled else { return }
                renderedTitle.removeLast()
                try? await Task.sleep(for: .milliseconds(5))
            }

            for character in title {
                guard !Task.isCancelled else { return }
                renderedTitle.append(character)
                try? await Task.sleep(for: .milliseconds(8))
            }

            for _ in 0..<2 {
                guard !Task.isCancelled else { return }
                cursorVisible = false
                try? await Task.sleep(for: .milliseconds(55))
                guard !Task.isCancelled else { return }
                cursorVisible = true
                try? await Task.sleep(for: .milliseconds(55))
            }
            cursorVisible = false
        }
    }
}

enum TPPlayTheme {
    static let canvas = Color.black
    static let surface = Color(red: 0.035, green: 0.035, blue: 0.045)
    static let surfaceRaised = Color(red: 0.07, green: 0.07, blue: 0.085)
    static let border = Color(red: 0.54, green: 0.17, blue: 0.89)
    static let accent = Color(red: 0.714, green: 1.0, blue: 0.0)
    static let violet = Color(red: 0.54, green: 0.17, blue: 0.89)
    static let onAccent = Color.black
    static let primaryText = Color(red: 0.94, green: 0.94, blue: 0.90)
    static let secondaryText = Color(red: 0.62, green: 0.62, blue: 0.60)
    static let tertiaryText = Color(red: 0.42, green: 0.42, blue: 0.44)
    static let danger = Color(red: 1.0, green: 0.19, blue: 0.37)
}

struct TPPageHeader<Actions: View>: View {
    let title: String
    private let actions: Actions
    @ObservedObject private var titleAnimator = TPTerminalTitleAnimator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(titleAnimator.renderedTitle + (titleAnimator.cursorVisible ? "|" : ""))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(TPPlayTheme.accent)
            Spacer()
            actions
        }
        .frame(height: 42)
        .onAppear {
            titleAnimator.transition(to: title, reduceMotion: reduceMotion)
        }
        .onChange(of: title) { _, newTitle in
            titleAnimator.transition(to: newTitle, reduceMotion: reduceMotion)
        }
    }
}

extension TPPageHeader where Actions == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

struct TPErrorDialog: View {
    let title: String
    let message: String
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(TPPlayTheme.onAccent)
                    .frame(width: 8, height: 8)
                Text("// \(title)")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(1)
                Spacer()
                Text("ERR")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(1)
            }
            .foregroundStyle(TPPlayTheme.onAccent)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(TPPlayTheme.danger)

            VStack(alignment: .leading, spacing: 18) {
                Text(message.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(TPPlayTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Button("ACKNOWLEDGE >", action: dismiss)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(TPPlayTheme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(TPPlayTheme.danger)
                    .overlay { Rectangle().stroke(TPPlayTheme.danger, lineWidth: 1) }
            }
            .padding(16)
            .background(TPPlayTheme.surfaceRaised)
        }
        .overlay { Rectangle().stroke(TPPlayTheme.danger, lineWidth: 2) }
        .accessibilityElement(children: .contain)
    }
}

struct AcidButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(active ? TPPlayTheme.onAccent : TPPlayTheme.primaryText)
            .background(active ? TPPlayTheme.accent : TPPlayTheme.surface)
            .overlay { Rectangle().stroke(active ? TPPlayTheme.accent : TPPlayTheme.border, lineWidth: 1) }
            .opacity(configuration.isPressed ? 0.62 : 1)
    }
}

struct AcidFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(TPPlayTheme.primaryText)
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(TPPlayTheme.surface)
            .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
    }
}

struct TPTerminalActivityGlyph: View {
    var color = TPPlayTheme.accent
    @State private var frameIndex = 0

    private let frames = ["|", "\\", "-", "/"]

    var body: some View {
        Text(frames[frameIndex])
            .font(.system(size: 14, weight: .black, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(70))
                    guard !Task.isCancelled else { return }
                    frameIndex = (frameIndex + 1) % frames.count
                }
            }
    }
}
