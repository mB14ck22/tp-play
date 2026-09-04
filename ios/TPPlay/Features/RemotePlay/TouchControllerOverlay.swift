import SwiftUI
import UIKit

struct StoredControlPoint: Codable, Equatable {
    let x: Double
    let y: Double
}

enum TouchpadPresentationMode: String, Codable, CaseIterable {
    case surface
    case actions
}

enum TouchpadQuickAction: String, Codable, CaseIterable, Identifiable {
    case click
    case lowerLeftClick
    case lowerRightClick
    case swipeLeft
    case swipeRight
    case swipeUp
    case swipeDown
    case touchHold

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .click: "CLICK"
        case .lowerLeftClick: "LOWER L"
        case .lowerRightClick: "LOWER R"
        case .swipeLeft: "SWIPE L"
        case .swipeRight: "SWIPE R"
        case .swipeUp: "SWIPE U"
        case .swipeDown: "SWIPE D"
        case .touchHold: "HOLD"
        }
    }

    var layoutKey: String { "touchpadAction.\(rawValue)" }
}

struct StoredTouchLayout: Codable, Equatable {
    var centers: [String: StoredControlPoint] = [:]
    var scales: [String: Double] = [:]
    // Optional fields keep v1/v2 archives decodable without a migration pass.
    var leftStickSensitivity: Double?
    var rightStickSensitivity: Double?
    var touchpadMode: TouchpadPresentationMode?
    var touchpadActions: [TouchpadQuickAction]?

    var resolvedLeftStickSensitivity: Double {
        max(0.5, min(3, leftStickSensitivity ?? 1))
    }

    var resolvedRightStickSensitivity: Double {
        max(0.5, min(3, rightStickSensitivity ?? 1))
    }

    var resolvedTouchpadMode: TouchpadPresentationMode {
        touchpadMode ?? .surface
    }

    var resolvedTouchpadActions: [TouchpadQuickAction] {
        Array((touchpadActions ?? [.click, .swipeLeft, .swipeRight]).prefix(4))
    }
}

struct TouchLayoutPreset: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var layout: StoredTouchLayout
}

private struct StoredTouchLayoutArchive: Codable {
    var presets: [TouchLayoutPreset]
    var activePresetID: UUID
}

@MainActor
final class TouchLayoutStore: ObservableObject {
    static let shared = TouchLayoutStore()

    @Published private(set) var presets: [TouchLayoutPreset]
    @Published private(set) var activePresetID: UUID
    @Published private(set) var revision = 0

    private static let storageKey = "tpplay.touchLayouts.v2"
    private static let legacyStorageKey = "tpplay.touchLayout.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let archive = try? JSONDecoder().decode(StoredTouchLayoutArchive.self, from: data),
           !archive.presets.isEmpty {
            presets = archive.presets
            activePresetID = archive.presets.contains(where: { $0.id == archive.activePresetID })
                ? archive.activePresetID
                : archive.presets[0].id
            return
        }

        let migratedLayout: StoredTouchLayout
        if let data = UserDefaults.standard.data(forKey: Self.legacyStorageKey),
           let legacy = try? JSONDecoder().decode(StoredTouchLayout.self, from: data) {
            migratedLayout = legacy
        } else {
            migratedLayout = StoredTouchLayout()
        }
        let initial = TouchLayoutPreset(id: UUID(), name: "DEFAULT", layout: migratedLayout)
        presets = [initial]
        activePresetID = initial.id
        persist()
        UserDefaults.standard.removeObject(forKey: Self.legacyStorageKey)
    }

    var activePreset: TouchLayoutPreset {
        presets.first(where: { $0.id == activePresetID }) ?? presets[0]
    }

    func preset(id: UUID) -> TouchLayoutPreset? {
        presets.first(where: { $0.id == id })
    }

    func setActive(_ id: UUID) {
        guard presets.contains(where: { $0.id == id }), activePresetID != id else { return }
        activePresetID = id
        revision += 1
        persist()
    }

    @discardableResult
    func addPreset(named rawName: String, copying sourceID: UUID? = nil) -> UUID {
        let name = normalizedName(rawName, fallback: "PRESET \(presets.count + 1)")
        let sourceLayout = sourceID.flatMap { preset(id: $0)?.layout } ?? StoredTouchLayout()
        let item = TouchLayoutPreset(id: UUID(), name: name, layout: sourceLayout)
        presets.append(item)
        revision += 1
        persist()
        return item.id
    }

    func rename(_ id: UUID, to rawName: String) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].name = normalizedName(rawName, fallback: presets[index].name)
        revision += 1
        persist()
    }

    func delete(_ id: UUID) {
        guard presets.count > 1, let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets.remove(at: index)
        if activePresetID == id { activePresetID = presets[min(index, presets.count - 1)].id }
        revision += 1
        persist()
    }

    func updateLayout(_ layout: StoredTouchLayout, for id: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == id }), presets[index].layout != layout else { return }
        presets[index].layout = layout
        revision += 1
        persist()
    }

    func resetLayout(for id: UUID) {
        updateLayout(StoredTouchLayout(), for: id)
    }

    private func normalizedName(_ rawName: String, fallback: String) -> String {
        let clean = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((clean.isEmpty ? fallback : clean).uppercased().prefix(28))
    }

    private func persist() {
        let archive = StoredTouchLayoutArchive(presets: presets, activePresetID: activePresetID)
        guard let data = try? JSONEncoder().encode(archive) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

struct TouchControllerOverlay: UIViewRepresentable {
    let session: RemotePlaySession?
    let editing: Bool
    let resetToken: Int
    let presetID: UUID
    let revision: Int

    init(
        session: RemotePlaySession?,
        editing: Bool,
        resetToken: Int,
        presetID: UUID = TouchLayoutStore.shared.activePresetID,
        revision: Int = TouchLayoutStore.shared.revision
    ) {
        self.session = session
        self.editing = editing
        self.resetToken = resetToken
        self.presetID = presetID
        self.revision = revision
    }

    func makeUIView(context: Context) -> TPVirtualControllerView {
        TPVirtualControllerView(session: session, presetID: presetID)
    }

    func updateUIView(_ view: TPVirtualControllerView, context: Context) {
        view.selectPreset(presetID, revision: revision)
        view.setEditing(editing)
        view.applyResetToken(resetToken)
    }
}

private final class TPFloatingStickView: UIView {
    var onChange: ((Int16, Int16) -> Void)?
    var sensitivity: CGFloat = 1

    private weak var trackedTouch: UITouch?
    private var origin: CGPoint?
    private var knobOffset = CGPoint.zero
    private let inputRadius: CGFloat = 24

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackedTouch == nil, let touch = touches.first else { return }
        trackedTouch = touch
        origin = touch.location(in: self)
        knobOffset = .zero
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.55)
        onChange?(0, 0)
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { $0 === trackedTouch }), let origin else { return }
        let point = touch.location(in: self)
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let length = hypot(dx, dy)
        let scale = length > inputRadius ? inputRadius / length : 1
        knobOffset = CGPoint(x: dx * scale, y: dy * scale)
        let maxValue = CGFloat(Int16.max)
        let normalizedX = max(-1, min(1, knobOffset.x / inputRadius * sensitivity))
        let normalizedY = max(-1, min(1, knobOffset.y / inputRadius * sensitivity))
        onChange?(Int16(clamping: Int(normalizedX * maxValue)), Int16(clamping: Int(normalizedY * maxValue)))
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        guard touches.contains(where: { $0 === trackedTouch }) else { return }
        trackedTouch = nil
        origin = nil
        knobOffset = .zero
        onChange?(0, 0)
        setNeedsDisplay()
    }

    func resetInteraction() {
        trackedTouch = nil
        origin = nil
        knobOffset = .zero
        onChange?(0, 0)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let origin, let context = UIGraphicsGetCurrentContext() else { return }
        let outer = CGRect(x: origin.x - 58, y: origin.y - 58, width: 116, height: 116)
        context.setFillColor(UIColor.white.withAlphaComponent(0.10).cgColor)
        context.fillEllipse(in: outer)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.22).cgColor)
        context.setLineWidth(1)
        context.strokeEllipse(in: outer.insetBy(dx: 1, dy: 1))

        let knobCenter = CGPoint(x: origin.x + knobOffset.x, y: origin.y + knobOffset.y)
        let knob = CGRect(x: knobCenter.x - 25, y: knobCenter.y - 25, width: 50, height: 50)
        context.setFillColor(UIColor.white.withAlphaComponent(0.30).cgColor)
        context.fillEllipse(in: knob)
        context.setStrokeColor(UIColor(red: 0.714, green: 1, blue: 0, alpha: 0.68).cgColor)
        context.strokeEllipse(in: knob.insetBy(dx: 0.75, dy: 0.75))
    }
}

/// Invisible mobile-shooter look surface. Unlike a floating analog stick, its
/// output follows finger velocity and decays to neutral as soon as motion
/// stops, so resting a finger never keeps the camera turning.
private final class TPRelativeLookView: UIView {
    var sensitivityX: CGFloat = 2.5
    var sensitivityY: CGFloat = 2.5
    var onChange: ((Int16, Int16) -> Void)?

    private weak var trackedTouch: UITouch?
    private var lastPoint = CGPoint.zero
    private var filtered = CGPoint.zero
    private var lastMoveTimestamp: TimeInterval = 0
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: TPRelativeLookDisplayLinkProxy?
    private var lastPublishedX: Int16 = 0
    private var lastPublishedY: Int16 = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        isOpaque = false
        accessibilityLabel = "Camera look area"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackedTouch == nil, let touch = touches.first else { return }
        trackedTouch = touch
        lastPoint = touch.location(in: self)
        lastMoveTimestamp = touch.timestamp
        filtered = .zero
        startDisplayLink()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { $0 === trackedTouch }) else { return }
        let point = touch.location(in: self)
        let dt = max(1.0 / 240.0, min(1.0 / 30.0, touch.timestamp - lastMoveTimestamp))
        let frameScale = CGFloat((1.0 / 60.0) / dt)
        let targetX = max(-1, min(1, (point.x - lastPoint.x) * frameScale / 12 * sensitivityX))
        let targetY = max(-1, min(1, (point.y - lastPoint.y) * frameScale / 12 * sensitivityY))
        filtered.x = filtered.x * 0.32 + targetX * 0.68
        filtered.y = filtered.y * 0.32 + targetY * 0.68
        lastPoint = point
        lastMoveTimestamp = touch.timestamp
        publish()
        if displayLink == nil { startDisplayLink() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        guard touches.contains(where: { $0 === trackedTouch }) else { return }
        resetInteraction()
    }

    func resetInteraction() {
        trackedTouch = nil
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
        filtered = .zero
        publish()
    }

    private func startDisplayLink() {
        displayLink?.invalidate()
        let proxy = TPRelativeLookDisplayLinkProxy(owner: self)
        let link = CADisplayLink(target: proxy, selector: #selector(TPRelativeLookDisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLinkProxy = proxy
        displayLink = link
    }

    fileprivate func displayLinkDidTick() {
        guard trackedTouch != nil else { return }
        if ProcessInfo.processInfo.systemUptime - lastMoveTimestamp > 0.025 {
            filtered.x *= 0.48
            filtered.y *= 0.48
            if abs(filtered.x) < 0.01 { filtered.x = 0 }
            if abs(filtered.y) < 0.01 { filtered.y = 0 }
            publish()
            if filtered == .zero {
                displayLink?.invalidate()
                displayLink = nil
                displayLinkProxy = nil
            }
        }
    }

    private func publish() {
        let maxValue = CGFloat(Int16.max)
        let x = Int16(clamping: Int(filtered.x * maxValue))
        let y = Int16(clamping: Int(filtered.y * maxValue))
        guard x != lastPublishedX || y != lastPublishedY else { return }
        lastPublishedX = x
        lastPublishedY = y
        onChange?(x, y)
    }
}

private final class TPRelativeLookDisplayLinkProxy: NSObject {
    weak var owner: TPRelativeLookView?

    init(owner: TPRelativeLookView) {
        self.owner = owner
    }

    @MainActor @objc func tick(_ link: CADisplayLink) {
        guard let owner else {
            link.invalidate()
            return
        }
        owner.displayLinkDidTick()
    }
}

private final class TPControllerButtonView: UIView {
    private enum VisualStyle {
        case round
        case shoulder
        case utility
    }

    let layoutKey: String
    var onPressed: ((Bool) -> Void)?
    private let label = UILabel()
    private let visiblePlate = UIView()
    private var symbolView: UIImageView?
    private let visualStyle: VisualStyle
    private var isDown = false

    init(key: String, text: String, symbol: String? = nil) {
        layoutKey = key
        if ["dpadUp", "dpadLeft", "dpadRight", "dpadDown", "triangle", "square", "circle", "cross", "l3", "r3", "ps"].contains(key) {
            visualStyle = .round
        } else if ["l1", "l2", "r1", "r2"].contains(key) {
            visualStyle = .shoulder
        } else {
            visualStyle = .utility
        }
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = false

        visiblePlate.isUserInteractionEnabled = false
        visiblePlate.backgroundColor = UIColor.white.withAlphaComponent(0.13)
        addSubview(visiblePlate)

        label.isUserInteractionEnabled = false
        label.text = symbol.flatMap { UIImage(systemName: $0) } == nil ? text : nil
        label.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        label.textColor = UIColor.white.withAlphaComponent(0.76)
        label.textAlignment = .center
        if let symbol, let image = UIImage(systemName: symbol) {
            let imageView = UIImageView(image: image)
            imageView.tintColor = UIColor.white.withAlphaComponent(0.76)
            imageView.contentMode = .scaleAspectFit
            imageView.isUserInteractionEnabled = false
            imageView.tag = 99
            symbolView = imageView
            addSubview(imageView)
        } else {
            addSubview(label)
        }
        accessibilityLabel = text
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let visualWidth: CGFloat
        let visualHeight: CGFloat
        switch visualStyle {
        case .round:
            let diameter = min(bounds.width, bounds.height) * 0.68
            visualWidth = diameter
            visualHeight = diameter
        case .shoulder:
            visualWidth = bounds.width * 0.78
            visualHeight = bounds.height * 0.58
        case .utility:
            visualWidth = bounds.width * 0.76
            visualHeight = bounds.height * 0.56
        }
        visiblePlate.frame = CGRect(
            x: (bounds.width - visualWidth) / 2,
            y: (bounds.height - visualHeight) / 2,
            width: visualWidth,
            height: visualHeight
        )
        visiblePlate.layer.cornerRadius = visualStyle == .round ? visualHeight / 2 : min(9, visualHeight * 0.28)
        label.frame = visiblePlate.frame
        symbolView?.frame = visiblePlate.frame.insetBy(dx: visualWidth * 0.27, dy: visualHeight * 0.27)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isDown else { return }
        isDown = true
        visiblePlate.backgroundColor = UIColor(red: 0.714, green: 1, blue: 0, alpha: 0.58)
        visiblePlate.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
        label.textColor = UIColor.black.withAlphaComponent(0.78)
        symbolView?.tintColor = UIColor.black.withAlphaComponent(0.72)
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.65)
        onPressed?(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { releaseButton() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { releaseButton() }

    private func releaseButton() {
        guard isDown else { return }
        isDown = false
        visiblePlate.backgroundColor = UIColor.white.withAlphaComponent(0.13)
        visiblePlate.transform = .identity
        label.textColor = UIColor.white.withAlphaComponent(0.76)
        symbolView?.tintColor = UIColor.white.withAlphaComponent(0.76)
        onPressed?(false)
    }
}

private final class TPTouchpadView: UIView {
    let layoutKey = "touchpad"
    var onTouch: ((Bool, UInt16, UInt16) -> Void)?
    var onClick: ((UInt16, UInt16) -> Void)?

    private weak var trackedTouch: UITouch?
    private var startPoint = CGPoint.zero
    private var startTime: TimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.white.withAlphaComponent(0.07)
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        layer.cornerRadius = 7
        isMultipleTouchEnabled = false
        accessibilityLabel = "Touchpad"
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        let text = "TOUCHPAD" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 8, weight: .bold),
            .foregroundColor: UIColor(white: 0.94, alpha: 0.45)
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackedTouch == nil, let touch = touches.first else { return }
        trackedTouch = touch
        startPoint = touch.location(in: self)
        startTime = touch.timestamp
        backgroundColor = UIColor.white.withAlphaComponent(0.18)
        layer.borderColor = UIColor(red: 0.714, green: 1, blue: 0, alpha: 0.62).cgColor
        publish(touch, active: true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { $0 === trackedTouch }) else { return }
        publish(touch, active: true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { $0 === trackedTouch }) else { return }
        let end = touch.location(in: self)
        let isTap = touch.timestamp - startTime < 0.28 && hypot(end.x - startPoint.x, end.y - startPoint.y) < 14
        let coordinates = mappedCoordinates(for: end)
        trackedTouch = nil
        backgroundColor = UIColor.white.withAlphaComponent(0.07)
        layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        if isTap {
            onClick?(coordinates.0, coordinates.1)
        } else {
            onTouch?(false, 0, 0)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        trackedTouch = nil
        backgroundColor = UIColor.white.withAlphaComponent(0.07)
        layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        onTouch?(false, 0, 0)
    }

    private func publish(_ touch: UITouch, active: Bool) {
        let coordinates = mappedCoordinates(for: touch.location(in: self))
        onTouch?(active, coordinates.0, coordinates.1)
    }

    private func mappedCoordinates(for point: CGPoint) -> (UInt16, UInt16) {
        let x = max(0, min(1, point.x / max(bounds.width, 1)))
        let y = max(0, min(1, point.y / max(bounds.height, 1)))
        return (UInt16(x * 1919), UInt16(y * 941))
    }
}

final class TPVirtualControllerView: UIView, UIGestureRecognizerDelegate {
    private weak var session: RemotePlaySession?
    private let layoutStore = TouchLayoutStore.shared
    private let leftStick = TPFloatingStickView()
    private let rightLook = TPRelativeLookView()
    private let touchpad = TPTouchpadView()
    private var buttons: [TPControllerButtonView] = []
    private var touchpadActionButtons: [(TouchpadQuickAction, TPControllerButtonView)] = []
    private var presetID: UUID
    private var loadedRevision = -1
    private var layout: StoredTouchLayout
    private var editing = false
    private var lastResetToken = 0
    private weak var editTarget: UIView?
    private var editKey: String?
    private var selectedKey: String?

    init(session: RemotePlaySession?, presetID: UUID) {
        self.session = session
        self.presetID = presetID
        self.layout = TouchLayoutStore.shared.preset(id: presetID)?.layout ?? StoredTouchLayout()
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        leftStick.onChange = { [weak session] x, y in session?.setLeftStick(x: x, y: y) }
        rightLook.onChange = { [weak session] x, y in session?.setRightStick(x: x, y: y) }
        addSubview(leftStick)
        addSubview(rightLook)

        touchpad.onTouch = { [weak session] active, x, y in session?.setTouch(active: active, x: x, y: y) }
        touchpad.onClick = { [weak session] x, y in session?.clickTouchpad(at: x, y: y) }
        addSubview(touchpad)

        addButton("dpadUp", "UP", "chevron.up", 1 << 6)
        addButton("dpadLeft", "LEFT", "chevron.left", 1 << 4)
        addButton("dpadRight", "RIGHT", "chevron.right", 1 << 5)
        addButton("dpadDown", "DOWN", "chevron.down", 1 << 7)
        addButton("triangle", "TRIANGLE", "triangle", 1 << 3)
        addButton("square", "SQUARE", "square", 1 << 2)
        addButton("circle", "CIRCLE", "circle", 1 << 1)
        addButton("cross", "CROSS", "xmark", 1 << 0)
        addButton("l1", "L1", nil, 1 << 8)
        addButton("l2", "L2", nil, nil, triggerLeft: true)
        addButton("l3", "L3", nil, 1 << 10)
        addButton("r1", "R1", nil, 1 << 9)
        addButton("r2", "R2", nil, nil, triggerLeft: false)
        addButton("r3", "R3", nil, 1 << 11)
        addButton("share", "SHARE", nil, 1 << 13)
        addButton("options", "OPTIONS", nil, 1 << 12)

        applyBehaviorSettings()
        rebuildTouchpadActionButtons()

        let pan = UIPanGestureRecognizer(target: self, action: #selector(editPan(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = true
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(editPinch(_:)))
        pinch.delegate = self
        pinch.cancelsTouchesInView = true
        addGestureRecognizer(pinch)
    }

    required init?(coder: NSCoder) { fatalError() }

    func selectPreset(_ id: UUID, revision: Int) {
        guard id != presetID || revision != loadedRevision else { return }
        presetID = id
        loadedRevision = revision
        layout = layoutStore.preset(id: id)?.layout ?? StoredTouchLayout()
        selectedKey = nil
        applyBehaviorSettings()
        rebuildTouchpadActionButtons()
        setNeedsLayout()
    }

    private func addButton(_ key: String, _ text: String, _ symbol: String?, _ mask: UInt32?, triggerLeft: Bool? = nil) {
        let button = TPControllerButtonView(key: key, text: text, symbol: symbol)
        if let triggerLeft {
            button.onPressed = { [weak session] pressed in
                session?.setTrigger(left: triggerLeft, value: pressed ? 1 : 0)
            }
        } else if let mask {
            button.onPressed = { [weak session] pressed in session?.setButton(mask, pressed: pressed) }
        }
        buttons.append(button)
        addSubview(button)
    }

    func setEditing(_ editing: Bool) {
        guard self.editing != editing else { return }
        self.editing = editing
        leftStick.isUserInteractionEnabled = !editing
        rightLook.isUserInteractionEnabled = !editing
        touchpad.isUserInteractionEnabled = !editing
        (buttons + touchpadActionButtons.map { $0.1 }).forEach { $0.isUserInteractionEnabled = !editing }
        if editing {
            leftStick.resetInteraction()
            rightLook.resetInteraction()
        } else {
            editTarget = nil
            editKey = nil
            selectedKey = nil
        }
        updateEditingAppearance()
    }

    func applyResetToken(_ token: Int) {
        guard token != lastResetToken else { return }
        lastResetToken = token
        layout = StoredTouchLayout()
        layoutStore.resetLayout(for: presetID)
        selectedKey = nil
        applyBehaviorSettings()
        rebuildTouchpadActionButtons()
        setNeedsLayout()
        updateEditingAppearance()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let w = bounds.width
        let h = bounds.height
        let safe = safeAreaInsets
        let top = safe.top + 8
        let bottom = h - safe.bottom

        leftStick.frame = CGRect(x: 0, y: 0, width: w / 2, height: h)
        rightLook.frame = CGRect(x: w / 2, y: 0, width: w / 2, height: h)

        touchpad.bounds = CGRect(x: 0, y: 0, width: 168, height: 54)
        touchpad.center = CGPoint(x: w / 2, y: top + 34)

        let defaults: [String: (CGPoint, CGSize)] = [
            "l2": (CGPoint(x: safe.left + 42, y: top + 78), CGSize(width: 76, height: 52)),
            "l1": (CGPoint(x: safe.left + 105, y: top + 106), CGSize(width: 76, height: 54)),
            "share": (CGPoint(x: w / 2 - 112, y: top + 32), CGSize(width: 72, height: 48)),
            "options": (CGPoint(x: w / 2 + 112, y: top + 32), CGSize(width: 80, height: 48)),
            "r1": (CGPoint(x: w - safe.right - 105, y: top + 106), CGSize(width: 76, height: 54)),
            "r2": (CGPoint(x: w - safe.right - 42, y: top + 78), CGSize(width: 76, height: 52)),
            "l3": (CGPoint(x: safe.left + 42, y: bottom - 34), CGSize(width: 68, height: 58)),
            "r3": (CGPoint(x: w - safe.right - 42, y: bottom - 34), CGSize(width: 68, height: 58)),
            "dpadUp": (CGPoint(x: safe.left + 126, y: bottom - 188), CGSize(width: 76, height: 76)),
            "dpadLeft": (CGPoint(x: safe.left + 72, y: bottom - 134), CGSize(width: 76, height: 76)),
            "dpadRight": (CGPoint(x: safe.left + 180, y: bottom - 134), CGSize(width: 76, height: 76)),
            "dpadDown": (CGPoint(x: safe.left + 126, y: bottom - 80), CGSize(width: 76, height: 76)),
            "triangle": (CGPoint(x: w - safe.right - 126, y: bottom - 188), CGSize(width: 76, height: 76)),
            "square": (CGPoint(x: w - safe.right - 180, y: bottom - 134), CGSize(width: 76, height: 76)),
            "circle": (CGPoint(x: w - safe.right - 72, y: bottom - 134), CGSize(width: 76, height: 76)),
            "cross": (CGPoint(x: w - safe.right - 126, y: bottom - 80), CGSize(width: 76, height: 76))
        ]

        applyLayout(to: touchpad, key: touchpad.layoutKey, defaultCenter: touchpad.center)
        for button in buttons {
            guard let item = defaults[button.layoutKey] else { continue }
            button.bounds = CGRect(origin: .zero, size: item.1)
            button.center = item.0
            applyLayout(to: button, key: button.layoutKey, defaultCenter: item.0)
        }

        let actionSpacing: CGFloat = 86
        let actionStart = w / 2 - CGFloat(max(0, touchpadActionButtons.count - 1)) * actionSpacing / 2
        for (index, pair) in touchpadActionButtons.enumerated() {
            let button = pair.1
            let defaultCenter = CGPoint(x: actionStart + CGFloat(index) * actionSpacing, y: top + 42)
            button.bounds = CGRect(x: 0, y: 0, width: 82, height: 54)
            button.center = defaultCenter
            applyLayout(to: button, key: pair.0.layoutKey, defaultCenter: defaultCenter)
        }
    }

    private func applyLayout(to view: UIView, key: String, defaultCenter: CGPoint) {
        view.transform = .identity
        if let stored = layout.centers[key] {
            view.center = CGPoint(x: stored.x * bounds.width, y: stored.y * bounds.height)
        } else {
            view.center = defaultCenter
        }
        let scale = max(0.55, min(1.7, layout.scales[key] ?? 1))
        view.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    private var editableViews: [(String, UIView)] {
        let surface = touchpad.isHidden ? [] : [(touchpad.layoutKey, touchpad)]
        return surface + buttons.map { ($0.layoutKey, $0) }
            + touchpadActionButtons.map { ($0.0.layoutKey, $0.1) }
    }

    private func applyBehaviorSettings() {
        leftStick.sensitivity = CGFloat(layout.resolvedLeftStickSensitivity)
        let lookSensitivity = CGFloat(layout.resolvedRightStickSensitivity) * 2.5
        rightLook.sensitivityX = lookSensitivity
        rightLook.sensitivityY = lookSensitivity
        touchpad.isHidden = layout.resolvedTouchpadMode == .actions
    }

    private func rebuildTouchpadActionButtons() {
        touchpadActionButtons.forEach { $0.1.removeFromSuperview() }
        touchpadActionButtons.removeAll()
        guard layout.resolvedTouchpadMode == .actions else { return }

        for action in layout.resolvedTouchpadActions {
            let button = TPControllerButtonView(key: action.layoutKey, text: action.shortLabel)
            button.onPressed = { [weak session] pressed in
                guard let session else { return }
                switch action {
                case .click:
                    if pressed { session.clickTouchpad() }
                case .lowerLeftClick:
                    if pressed { session.clickTouchpad(at: 360, y: 790) }
                case .lowerRightClick:
                    if pressed { session.clickTouchpad(at: 1_560, y: 790) }
                case .swipeLeft:
                    if pressed { session.performTouchpadSwipe(from: (1_520, 470), to: (400, 470)) }
                case .swipeRight:
                    if pressed { session.performTouchpadSwipe(from: (400, 470), to: (1_520, 470)) }
                case .swipeUp:
                    if pressed { session.performTouchpadSwipe(from: (960, 780), to: (960, 170)) }
                case .swipeDown:
                    if pressed { session.performTouchpadSwipe(from: (960, 170), to: (960, 780)) }
                case .touchHold:
                    session.setTouch(active: pressed, x: pressed ? 960 : 0, y: pressed ? 470 : 0)
                }
            }
            touchpadActionButtons.append((action, button))
            addSubview(button)
        }
        updateEditingAppearance()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled, bounds.contains(point) else { return nil }
        guard !editing else { return self }

        let candidates = editableViews.filter { _, view in
            !view.isHidden && view.alpha > 0.01
                && view.point(inside: convert(point, to: view), with: event)
        }
        if let nearest = candidates.min(by: {
            hypot(point.x - $0.1.center.x, point.y - $0.1.center.y)
                < hypot(point.x - $1.1.center.x, point.y - $1.1.center.y)
        }) {
            return nearest.1
        }
        return point.x < bounds.midX ? leftStick : rightLook
    }

    private func editableControl(at point: CGPoint) -> (String, UIView)? {
        editableViews
            .filter { _, view in view.point(inside: convert(point, to: view), with: nil) }
            .min { abs($0.1.frame.width * $0.1.frame.height) < abs($1.1.frame.width * $1.1.frame.height) }
    }

    @objc private func editPan(_ gesture: UIPanGestureRecognizer) {
        guard editing else { return }
        if gesture.state == .began {
            let item = editableControl(at: gesture.location(in: self))
            editKey = item?.0
            editTarget = item?.1
            selectedKey = item?.0
            updateEditingAppearance()
        }
        guard let key = editKey, let view = editTarget else { return }
        let delta = gesture.translation(in: self)
        let halfW = abs(view.frame.width) / 2
        let halfH = abs(view.frame.height) / 2
        view.center = CGPoint(
            x: max(halfW, min(bounds.width - halfW, view.center.x + delta.x)),
            y: max(halfH, min(bounds.height - halfH, view.center.y + delta.y))
        )
        gesture.setTranslation(.zero, in: self)
        if gesture.state == .ended || gesture.state == .cancelled {
            layout.centers[key] = StoredControlPoint(
                x: view.center.x / max(bounds.width, 1),
                y: view.center.y / max(bounds.height, 1)
            )
            layoutStore.updateLayout(layout, for: presetID)
            editKey = nil
            editTarget = nil
        }
    }

    @objc private func editPinch(_ gesture: UIPinchGestureRecognizer) {
        guard editing else { return }
        if gesture.state == .began {
            let item = editableControl(at: gesture.location(in: self))
            editKey = item?.0
            editTarget = item?.1
            selectedKey = item?.0
            updateEditingAppearance()
        }
        guard let key = editKey, let view = editTarget else { return }
        let current = CGFloat(layout.scales[key] ?? 1)
        let next = max(0.55, min(1.7, current * gesture.scale))
        layout.scales[key] = Double(next)
        view.transform = CGAffineTransform(scaleX: next, y: next)
        gesture.scale = 1
        if gesture.state == .ended || gesture.state == .cancelled {
            layoutStore.updateLayout(layout, for: presetID)
            editKey = nil
            editTarget = nil
        }
    }

    private func updateEditingAppearance() {
        for (key, view) in editableViews {
            view.layer.borderWidth = editing ? (key == selectedKey ? 2 : 1) : (view === touchpad ? 1 : 0)
            view.layer.borderColor = editing
                ? UIColor(red: 0.714, green: 1, blue: 0, alpha: key == selectedKey ? 1 : 0.55).cgColor
                : (view === touchpad ? UIColor.white.withAlphaComponent(0.18).cgColor : UIColor.clear.cgColor)
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        editing
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        editing
    }
}
