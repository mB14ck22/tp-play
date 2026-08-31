import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct SettingsView: View {
    @AppStorage("appAppearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("streamResolution") private var resolution = 1080
    @AppStorage("streamFPS") private var fps = 60
    @AppStorage("streamBitrate") private var bitrate = 15_000

    var body: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    Picker("主题", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("串流画面") {
                    Picker("分辨率", selection: $resolution) {
                        Text("720p").tag(720)
                        Text("1080p").tag(1080)
                    }
                    Picker("帧率", selection: $fps) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("码率", value: "\(bitrate / 1_000) Mbps")
                        Slider(
                            value: Binding(get: { Double(bitrate) }, set: { bitrate = Int($0) }),
                            in: 4_000...30_000,
                            step: 1_000
                        )
                        .tint(TPPlayTheme.accent)
                    }
                }

                Section {
                    Button("恢复推荐设置") {
                        resolution = 1080
                        fps = 60
                        bitrate = 15_000
                    }
                } footer: {
                    Text("局域网条件良好时建议使用 1080p、60 fps 和 15 Mbps；画面卡顿时可降低分辨率或码率。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(TPPlayTheme.canvas)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

#Preview { SettingsView() }
