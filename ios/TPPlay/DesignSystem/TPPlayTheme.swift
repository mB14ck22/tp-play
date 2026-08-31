import SwiftUI

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
