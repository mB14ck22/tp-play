import SwiftUI
import UIKit

enum TPPlayTheme {
    static let canvas = Color(uiColor: .systemBackground)
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let surfaceRaised = Color(uiColor: .tertiarySystemBackground)
    static let border = Color(uiColor: .separator).opacity(0.55)
    static let accent = Color.primary
    static let onAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : .white
    })
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let tertiaryText = Color(uiColor: .tertiaryLabel)
}
