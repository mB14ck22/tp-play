import SwiftUI
import UIKit

struct TouchLayoutSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = TouchLayoutStore.shared
    @State private var namingAction: TouchPresetNamingAction?
    @State private var deleteCandidate: TouchLayoutPreset?
    @State private var editorRequest: TouchLayoutEditorRequest?

    var body: some View {
        ZStack {
            TPPlayTheme.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                TPPageHeader("SETTINGS // TOUCH LAYOUTS") {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .black))
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(AcidButtonStyle())
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        summaryPanel

                        HStack {
                            sectionLabel("CONTROL PRESETS", detail: "\(store.presets.count)")
                            Spacer()
                        }

                        ForEach(store.presets) { preset in
                            presetCard(preset)
                        }

                        Button("NEW PRESET") {
                            namingAction = TouchPresetNamingAction(kind: .new, initialName: "")
                        }
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .buttonStyle(AcidButtonStyle(active: true))
                    }
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 30)
                }
            }
            .allowsHitTesting(namingAction == nil && deleteCandidate == nil)

            if let action = namingAction {
                Color.black.opacity(0.78).ignoresSafeArea()
                TouchPresetNameDialog(
                    title: action.title,
                    initialName: action.initialName,
                    confirmLabel: action.confirmLabel,
                    onConfirm: { name in
                        handleNaming(action, name: name)
                        namingAction = nil
                    },
                    onCancel: { namingAction = nil }
                )
                .frame(maxWidth: 420)
                .padding(20)
            }

            if let preset = deleteCandidate {
                Color.black.opacity(0.78).ignoresSafeArea()
                TouchPresetDeleteDialog(
                    name: preset.name,
                    onDelete: {
                        store.delete(preset.id)
                        deleteCandidate = nil
                    },
                    onCancel: { deleteCandidate = nil }
                )
                .frame(maxWidth: 420)
                .padding(20)
            }
        }
        .fullScreenCover(item: $editorRequest) { request in
            TouchLayoutEditorView(presetID: request.presetID)
        }
    }

    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("PRESET STORAGE", detail: "LOCAL")
            HStack(spacing: 12) {
                Rectangle()
                    .fill(TPPlayTheme.violet)
                    .frame(width: 9, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("BUILD LAYOUTS HERE")
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.primaryText)
                    Text("SELECT THE PRESET FROM LAYOUT WHILE STREAMING")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.45)
                        .foregroundStyle(TPPlayTheme.secondaryText)
                }
                Spacer()
            }
        }
        .padding(16)
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
    }

    private func presetCard(_ preset: TouchLayoutPreset) -> some View {
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(TPPlayTheme.violet)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.name)
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.primaryText)
                        .lineLimit(1)
                    Text("STORED CONTROL MAP")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(TPPlayTheme.tertiaryText)
                }
                Spacer()
            }
            .padding(14)

            HStack(spacing: 0) {
                presetAction("EDIT", symbol: "slider.horizontal.3") {
                    editorRequest = TouchLayoutEditorRequest(presetID: preset.id)
                }
                presetAction("COPY", symbol: "square.on.square") {
                    namingAction = TouchPresetNamingAction(
                        kind: .copy(preset.id),
                        initialName: "\(preset.name) COPY"
                    )
                }
                presetAction("RENAME", symbol: "pencil") {
                    namingAction = TouchPresetNamingAction(kind: .rename(preset.id), initialName: preset.name)
                }
                presetAction("DELETE", symbol: "trash", danger: true, disabled: store.presets.count == 1) {
                    deleteCandidate = preset
                }
            }
            .frame(height: 44)
            .overlay(alignment: .top) { Rectangle().fill(TPPlayTheme.border).frame(height: 1) }
        }
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
    }

    private func presetAction(
        _ title: String,
        symbol: String,
        danger: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .foregroundStyle(danger ? TPPlayTheme.danger : TPPlayTheme.primaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) { Rectangle().fill(TPPlayTheme.border).frame(width: 1) }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
    }

    private func sectionLabel(_ title: String, detail: String) -> some View {
        HStack {
            Text("// \(title)")
            Spacer()
            Text(detail)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .tracking(1)
        .foregroundStyle(TPPlayTheme.accent)
    }

    private func handleNaming(_ action: TouchPresetNamingAction, name: String) {
        switch action.kind {
        case .new:
            let id = store.addPreset(named: name)
            editorRequest = TouchLayoutEditorRequest(presetID: id)
        case .copy(let sourceID):
            let id = store.addPreset(named: name, copying: sourceID)
            editorRequest = TouchLayoutEditorRequest(presetID: id)
        case .rename(let id):
            store.rename(id, to: name)
        }
    }
}

private struct TouchLayoutEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = TouchLayoutStore.shared
    let presetID: UUID
    @State private var resetToken = 0
    @State private var toolExpanded = false
    @State private var toolOffset = CGSize.zero

    private var presetName: String {
        store.preset(id: presetID)?.name ?? "CONTROL MAP"
    }

    var body: some View {
        ZStack {
            TPPlayTheme.canvas.ignoresSafeArea()

            Rectangle()
                .fill(TPPlayTheme.surface)
                .overlay {
                    Text("CONTROL MAP // PREVIEW FIELD")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(TPPlayTheme.tertiaryText.opacity(0.32))
                }
                .ignoresSafeArea()

            TouchControllerOverlay(
                session: nil,
                editing: true,
                resetToken: resetToken,
                presetID: presetID,
                revision: store.revision
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { dismiss() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "chevron.left")
                            Text("DONE")
                        }
                        .frame(width: 88, height: 44)
                    }
                    .buttonStyle(AcidButtonStyle(active: true))

                    Text(presetName)
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(TPPlayTheme.primaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(TPPlayTheme.surface.opacity(0.9))
                        .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }

                    Spacer()

                    Button("RESET") { resetToken += 1 }
                        .frame(width: 86, height: 44)
                        .buttonStyle(AcidButtonStyle())
                }
                .padding(12)

                Spacer()
            }

            LayoutEditorToolDock(
                expanded: $toolExpanded,
                offset: $toolOffset,
                leftSensitivity: sensitivityBinding(\.leftStickSensitivity),
                rightSensitivity: sensitivityBinding(\.rightStickSensitivity),
                touchpadMode: touchpadModeBinding,
                selectedActions: currentLayout.resolvedTouchpadActions,
                toggleAction: toggleTouchpadAction
            )
            .padding(.bottom, 10)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { TPInterfaceOrientation.request(.landscape) }
        .onDisappear { TPInterfaceOrientation.request(.portrait) }
    }

    private var currentLayout: StoredTouchLayout {
        store.preset(id: presetID)?.layout ?? StoredTouchLayout()
    }

    private func sensitivityBinding(_ keyPath: WritableKeyPath<StoredTouchLayout, Double?>) -> Binding<Double> {
        Binding(
            get: { currentLayout[keyPath: keyPath] ?? 1 },
            set: { value in
                var layout = currentLayout
                layout[keyPath: keyPath] = max(0.5, min(3, value))
                store.updateLayout(layout, for: presetID)
            }
        )
    }

    private var touchpadModeBinding: Binding<TouchpadPresentationMode> {
        Binding(
            get: { currentLayout.resolvedTouchpadMode },
            set: { mode in
                var layout = currentLayout
                layout.touchpadMode = mode
                store.updateLayout(layout, for: presetID)
            }
        )
    }

    private func toggleTouchpadAction(_ action: TouchpadQuickAction) {
        var layout = currentLayout
        var actions = layout.resolvedTouchpadActions
        if let index = actions.firstIndex(of: action) {
            actions.remove(at: index)
        } else if actions.count < 4 {
            actions.append(action)
        }
        layout.touchpadActions = actions
        store.updateLayout(layout, for: presetID)
    }
}

private struct LayoutEditorToolDock: View {
    @Binding var expanded: Bool
    @Binding var offset: CGSize
    @Binding var leftSensitivity: Double
    @Binding var rightSensitivity: Double
    @Binding var touchpadMode: TouchpadPresentationMode
    let selectedActions: [TouchpadQuickAction]
    let toggleAction: (TouchpadQuickAction) -> Void
    @State private var dragOrigin = CGSize.zero

    var body: some View {
        VStack(spacing: 0) {
            if expanded {
                VStack(spacing: 10) {
                    HStack(spacing: 16) {
                        sensitivityControl("LEFT STICK", value: $leftSensitivity)
                        Rectangle().fill(TPPlayTheme.border).frame(width: 1, height: 38)
                        sensitivityControl("RIGHT STICK", value: $rightSensitivity)
                    }

                    HStack(spacing: 8) {
                        Text("TOUCHPAD")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .tracking(0.7)
                            .foregroundStyle(TPPlayTheme.secondaryText)
                        modeButton("SURFACE", mode: .surface)
                        modeButton("ACTIONS", mode: .actions)
                        Rectangle().fill(TPPlayTheme.border).frame(width: 1, height: 28)
                        Text("MAX 4")
                            .font(.system(size: 7, weight: .black, design: .monospaced))
                            .foregroundStyle(TPPlayTheme.tertiaryText)
                        ForEach(TouchpadQuickAction.allCases) { action in
                            actionButton(action)
                        }
                    }
                }
                .padding(12)
                .background(TPPlayTheme.surface.opacity(0.96))
                .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }

                Text("DRAG TO MOVE  //  PINCH TO SCALE  //  LEFT + RIGHT HALVES REMAIN STICK ZONES")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(TPPlayTheme.onAccent)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(TPPlayTheme.accent)
            }

            handle
        }
        .frame(maxWidth: expanded ? 820 : 150)
        .offset(offset)
        .animation(.snappy(duration: 0.2), value: expanded)
    }

    private var handle: some View {
        HStack(spacing: 8) {
            Image(systemName: expanded ? "chevron.down" : "slider.horizontal.3")
            Text(expanded ? "COLLAPSE" : "LAYOUT TOOLS")
        }
        .font(.system(size: 9, weight: .black, design: .monospaced))
        .tracking(0.55)
        .foregroundStyle(TPPlayTheme.primaryText)
        .frame(width: 150, height: 36)
        .background(TPPlayTheme.surfaceRaised.opacity(0.97))
        .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
        .gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { value in
                    offset = CGSize(width: dragOrigin.width + value.translation.width, height: dragOrigin.height + value.translation.height)
                }
                .onEnded { _ in dragOrigin = offset }
        )
    }

    private func sensitivityControl(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(0.55)
                .foregroundStyle(TPPlayTheme.secondaryText)
                .frame(width: 76, alignment: .leading)
            Slider(value: value, in: 0.5...3, step: 0.1)
                .tint(TPPlayTheme.accent)
                .frame(width: 150)
            Text(String(format: "%.1f×", value.wrappedValue))
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(TPPlayTheme.accent)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func modeButton(_ title: String, mode: TouchpadPresentationMode) -> some View {
        Button(title) { touchpadMode = mode }
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .foregroundStyle(touchpadMode == mode ? TPPlayTheme.onAccent : TPPlayTheme.primaryText)
            .frame(width: 66, height: 28)
            .background(touchpadMode == mode ? TPPlayTheme.accent : TPPlayTheme.canvas)
            .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
            .buttonStyle(.plain)
    }

    private func actionButton(_ action: TouchpadQuickAction) -> some View {
        let selected = selectedActions.contains(action)
        let unavailable = !selected && selectedActions.count >= 4
        return Button(action.shortLabel) { toggleAction(action) }
            .font(.system(size: 7, weight: .black, design: .monospaced))
            .foregroundStyle(selected ? TPPlayTheme.onAccent : TPPlayTheme.primaryText)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(selected ? TPPlayTheme.accent : TPPlayTheme.canvas)
            .overlay { Rectangle().stroke(selected ? TPPlayTheme.accent : TPPlayTheme.border, lineWidth: 1) }
            .buttonStyle(.plain)
            .disabled(unavailable)
            .opacity(unavailable ? 0.28 : 1)
    }
}

private struct TouchPresetNameDialog: View {
    let title: String
    let initialName: String
    let confirmLabel: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String
    @FocusState private var focused: Bool

    init(title: String, initialName: String, confirmLabel: String, onConfirm: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.initialName = initialName
        self.confirmLabel = confirmLabel
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(spacing: 0) {
            dialogHeader(title, code: "MAP")
            VStack(alignment: .leading, spacing: 14) {
                Text("PRESET NAME").acidLabel()
                TextField("GAME / LAYOUT NAME", text: $name)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textFieldStyle(AcidFieldStyle())
                    .focused($focused)
                HStack(spacing: 8) {
                    Button("CANCEL", action: onCancel)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(AcidButtonStyle())
                    Button(confirmLabel) { onConfirm(name) }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(AcidButtonStyle(active: true))
                }
            }
            .padding(16)
            .background(TPPlayTheme.surface)
        }
        .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
        .onAppear { focused = true }
    }
}

private struct TouchPresetDeleteDialog: View {
    let name: String
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            dialogHeader("DELETE CONTROL PRESET", code: "DEL", danger: true)
            VStack(alignment: .leading, spacing: 16) {
                Text("DELETE \(name)? THIS LAYOUT CANNOT BE RECOVERED.")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.45)
                    .foregroundStyle(TPPlayTheme.primaryText)
                HStack(spacing: 8) {
                    Button("CANCEL", action: onCancel)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(AcidButtonStyle())
                    Button("DELETE", action: onDelete)
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(TPPlayTheme.danger)
                }
            }
            .padding(16)
            .background(TPPlayTheme.surface)
        }
        .overlay { Rectangle().stroke(TPPlayTheme.danger, lineWidth: 1) }
    }
}

@ViewBuilder
private func dialogHeader(_ title: String, code: String, danger: Bool = false) -> some View {
    HStack(spacing: 10) {
        Rectangle()
            .fill(danger ? TPPlayTheme.onAccent : TPPlayTheme.accent)
            .frame(width: 8, height: 8)
        Text("// \(title)")
            .font(.system(size: 11, weight: .black, design: .monospaced))
            .tracking(0.8)
        Spacer()
        Text(code)
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .tracking(1)
    }
    .foregroundStyle(danger ? TPPlayTheme.onAccent : TPPlayTheme.primaryText)
    .padding(.horizontal, 16)
    .frame(height: 44)
    .background(danger ? TPPlayTheme.danger : TPPlayTheme.surfaceRaised)
    .overlay(alignment: .bottom) { Rectangle().fill(danger ? TPPlayTheme.danger : TPPlayTheme.violet).frame(height: 1) }
}

private struct TouchLayoutEditorRequest: Identifiable {
    let id = UUID()
    let presetID: UUID
}

private struct TouchPresetNamingAction: Identifiable {
    enum Kind {
        case new
        case copy(UUID)
        case rename(UUID)
    }

    let id = UUID()
    let kind: Kind
    let initialName: String

    var title: String {
        switch kind {
        case .new: "NEW CONTROL PRESET"
        case .copy: "COPY CONTROL PRESET"
        case .rename: "RENAME CONTROL PRESET"
        }
    }

    var confirmLabel: String {
        if case .rename = kind { return "SAVE" }
        return "CREATE"
    }
}

@MainActor
private enum TPInterfaceOrientation {
    static func request(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            NSLog("TPPlay orientation request failed: %@", error.localizedDescription)
        }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

private extension View {
    func acidLabel() -> some View {
        font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(TPPlayTheme.secondaryText)
    }
}
