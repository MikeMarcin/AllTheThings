import AppKit
import ATTCore
import Carbon.HIToolbox

@MainActor
final class MatchColorPaletteControl: NSView {
    var onChange: ((MatchClass, NSColor) -> Void)?

    private let stack = NSStackView()
    private var colorWells: [MatchClass: NSColorWell] = [:]
    private var isDark = false

    private static let matchClasses: [MatchClass] = [.alias, .exact, .prefix, .substring, .near, .weakPath, .metadata]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(defaults: UserDefaults, isDark: Bool) {
        self.isDark = isDark

        for matchClass in Self.matchClasses {
            colorWells[matchClass]?.color = AppSettings.matchColor(for: matchClass, isDark: isDark, defaults: defaults)
        }
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        for matchClass in Self.matchClasses {
            let colorWell = NSColorWell()
            colorWell.translatesAutoresizingMaskIntoConstraints = false
            colorWell.isBordered = true
            colorWell.tag = matchClass.rawValue
            colorWell.target = self
            colorWell.action = #selector(colorWellDidChange(_:))
            colorWell.toolTip = "\(Self.label(for: matchClass)) match color"

            stack.addArrangedSubview(colorWell)
            colorWells[matchClass] = colorWell

            NSLayoutConstraint.activate([
                colorWell.widthAnchor.constraint(equalToConstant: 28),
                colorWell.heightAnchor.constraint(equalToConstant: 22)
            ])
        }
    }

    @objc private func colorWellDidChange(_ sender: NSColorWell) {
        guard let matchClass = MatchClass(rawValue: sender.tag) else { return }

        onChange?(matchClass, sender.color)
    }

    private static func label(for matchClass: MatchClass) -> String {
        switch matchClass {
        case .alias: "Alias"
        case .exact: "Exact"
        case .prefix: "Prefix"
        case .substring: "Text"
        case .near: "Near"
        case .weakPath: "Path"
        case .metadata: "Meta"
        }
    }
}

@MainActor
final class ThemePreviewSelectorControl: NSControl {
    private var optionViews: [AppThemePreference: ThemePreviewOptionView] = [:]
    private(set) var selectedPreference: AppThemePreference = .system

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(defaults: UserDefaults, selectedPreference: AppThemePreference) {
        self.selectedPreference = selectedPreference

        for preference in AppThemePreference.allCases {
            guard let optionView = optionViews[preference] else { continue }
            optionView.configure(defaults: defaults)
            optionView.isSelected = preference == selectedPreference
        }
    }

    func selectPreference(_ preference: AppThemePreference, sendsAction: Bool = false) {
        let didChange = selectedPreference != preference
        selectedPreference = preference
        updateSelectionStates()

        if sendsAction, didChange {
            sendAction(action, to: target)
        }
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        identifier = NSUserInterfaceItemIdentifier("themePreviewSelector")
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var previousOptionView: ThemePreviewOptionView?
        for preference in AppThemePreference.allCases {
            let optionView = ThemePreviewOptionView(preference: preference)
            optionView.target = self
            optionView.action = #selector(optionWasSelected(_:))
            optionViews[preference] = optionView
            addSubview(optionView)

            var constraints = [
                optionView.topAnchor.constraint(equalTo: topAnchor),
                optionView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ]

            if let previousOptionView {
                constraints.append(optionView.leadingAnchor.constraint(equalTo: previousOptionView.trailingAnchor, constant: 14))
                constraints.append(optionView.widthAnchor.constraint(equalTo: previousOptionView.widthAnchor))
            } else {
                constraints.append(optionView.leadingAnchor.constraint(equalTo: leadingAnchor))
            }

            NSLayoutConstraint.activate(constraints)
            previousOptionView = optionView
        }

        previousOptionView?.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        updateSelectionStates()
    }

    private func updateSelectionStates() {
        for (preference, optionView) in optionViews {
            optionView.isSelected = preference == selectedPreference
        }
    }

    @objc private func optionWasSelected(_ sender: ThemePreviewOptionView) {
        selectPreference(sender.preference, sendsAction: true)
    }
}

@MainActor
private final class ThemePreviewOptionView: NSControl {
    let preference: AppThemePreference

    private let canvasView: ThemePreviewCanvasView
    private let titleLabel = NSTextField(labelWithString: "")
    private var defaults: UserDefaults = .standard

    var isSelected = false {
        didSet {
            canvasView.isSelected = isSelected
            updateLabelStyle()
            updateAccessibilityValue()
        }
    }

    override var acceptsFirstResponder: Bool { true }

    init(preference: AppThemePreference) {
        self.preference = preference
        self.canvasView = ThemePreviewCanvasView(preference: preference)
        super.init(frame: .zero)
        configureView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(defaults: UserDefaults) {
        self.defaults = defaults
        canvasView.configure(defaults: defaults)
        updateLabelStyle()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_Space) {
            sendAction(action, to: target)
            return
        }

        super.keyDown(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLabelStyle()
        canvasView.needsDisplay = true
    }

    private func configureView() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        identifier = NSUserInterfaceItemIdentifier("themePreview.\(preference.rawValue)")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(preference.title) theme")
        updateAccessibilityValue()

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = preference.title
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail

        addSubview(canvasView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: topAnchor),
            canvasView.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvasView.heightAnchor.constraint(equalTo: canvasView.widthAnchor, multiplier: 0.58),

            titleLabel.topAnchor.constraint(equalTo: canvasView.bottomAnchor, constant: 7),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func updateLabelStyle() {
        titleLabel.font = AppSettings.appFont(
            defaults: defaults,
            sizeDelta: 0,
            weight: isSelected ? .semibold : .medium
        )
        titleLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor
    }

    private func updateAccessibilityValue() {
        setAccessibilityValue(isSelected ? "Selected" : nil)
    }
}

@MainActor
private final class ThemePreviewCanvasView: NSView {
    private let preference: AppThemePreference
    private var defaults: UserDefaults = .standard

    var isSelected = false {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    init(preference: AppThemePreference) {
        self.preference = preference
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(defaults: UserDefaults) {
        self.defaults = defaults
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let borderWidth: CGFloat = isSelected ? 3 : 1
        let previewRect = bounds.insetBy(dx: borderWidth + 0.5, dy: borderWidth + 0.5)

        if preference == .system {
            drawSystemPreview(in: previewRect)
        } else {
            drawWindowPreview(in: previewRect, isDark: preference == .dark)
        }

        drawBorder(in: previewRect, borderWidth: borderWidth)
    }

    private func drawSystemPreview(in rect: NSRect) {
        let lightClipPath = NSBezierPath()
        lightClipPath.move(to: NSPoint(x: rect.minX, y: rect.minY))
        lightClipPath.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        lightClipPath.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        lightClipPath.close()

        NSGraphicsContext.saveGraphicsState()
        lightClipPath.addClip()
        drawWindowPreview(in: rect, isDark: false)
        NSGraphicsContext.restoreGraphicsState()

        let darkClipPath = NSBezierPath()
        darkClipPath.move(to: NSPoint(x: rect.maxX, y: rect.minY))
        darkClipPath.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        darkClipPath.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        darkClipPath.close()

        NSGraphicsContext.saveGraphicsState()
        darkClipPath.addClip()
        drawWindowPreview(in: rect, isDark: true)
        NSGraphicsContext.restoreGraphicsState()

        let dividerPath = NSBezierPath()
        dividerPath.move(to: NSPoint(x: rect.maxX - 1, y: rect.minY + 1))
        dividerPath.line(to: NSPoint(x: rect.minX + 1, y: rect.maxY - 1))
        dividerPath.lineWidth = 1.5
        NSColor.separatorColor.withAlphaComponent(0.70).setStroke()
        dividerPath.stroke()
    }

    private func drawWindowPreview(in rect: NSRect, isDark: Bool) {
        let palette = ThemePreviewPalette(defaults: defaults, isDark: isDark)
        let radius: CGFloat = 6
        let titleHeight = max(8, rect.height * 0.12)
        let sidebarWidth = rect.width * 0.34
        let bodyY = rect.minY + titleHeight
        let bodyHeight = rect.height - titleHeight
        let contentX = rect.minX + sidebarWidth
        let lineX = contentX + 13
        let lineY = bodyY + 7

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()

        palette.window.setFill()
        NSBezierPath(rect: rect).fill()

        palette.titlebar.setFill()
        NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: titleHeight)).fill()

        palette.sidebar.setFill()
        NSBezierPath(rect: NSRect(x: rect.minX, y: bodyY, width: sidebarWidth, height: bodyHeight)).fill()

        palette.separator.setFill()
        NSBezierPath(rect: NSRect(x: contentX, y: bodyY, width: 1, height: bodyHeight)).fill()

        fillRoundedRect(
            NSRect(x: rect.minX + 8, y: bodyY + 7, width: max(18, sidebarWidth - 16), height: 7),
            radius: 2,
            color: palette.sidebarField
        )
        fillRoundedRect(
            NSRect(x: rect.minX + 10, y: bodyY + 25, width: max(12, sidebarWidth * 0.32), height: 8),
            radius: 2,
            color: palette.sidebarButton
        )
        fillRoundedRect(
            NSRect(x: rect.minX + 14 + sidebarWidth * 0.32, y: bodyY + 25, width: max(14, sidebarWidth * 0.30), height: 8),
            radius: 2,
            color: palette.accentButton
        )

        let lineWidth = rect.maxX - lineX - 12
        for (index, color) in palette.matchLineColors.enumerated() {
            let y = lineY + CGFloat(index) * 8
            let ratio = ThemePreviewCanvasView.lineRatios[index % ThemePreviewCanvasView.lineRatios.count]
            fillRoundedRect(
                NSRect(x: lineX, y: y, width: max(10, lineWidth * ratio), height: 3),
                radius: 1.5,
                color: color
            )
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBorder(in rect: NSRect, borderWidth: CGFloat) {
        let borderRect = rect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        let borderColor = isSelected ? NSColor.controlAccentColor : NSColor.separatorColor.withAlphaComponent(0.85)
        let border = NSBezierPath(roundedRect: borderRect, xRadius: 7, yRadius: 7)
        border.lineWidth = borderWidth
        borderColor.setStroke()
        border.stroke()
    }

    private func fillRoundedRect(_ rect: NSRect, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    private static let lineRatios: [CGFloat] = [0.58, 0.84, 0.72, 0.49, 0.93, 0.66, 0.22]
}

private struct ThemePreviewPalette {
    let window: NSColor
    let titlebar: NSColor
    let sidebar: NSColor
    let separator: NSColor
    let sidebarField: NSColor
    let sidebarButton: NSColor
    let accentButton: NSColor
    let matchLineColors: [NSColor]

    init(defaults: UserDefaults, isDark: Bool) {
        if isDark {
            window = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.13, alpha: 1)
            titlebar = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.10, alpha: 1)
            sidebar = NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.18, alpha: 1)
            separator = NSColor(calibratedWhite: 0.26, alpha: 1)
            sidebarField = NSColor(calibratedWhite: 0.34, alpha: 1)
            sidebarButton = NSColor(calibratedWhite: 0.26, alpha: 1)
            accentButton = NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.14, alpha: 1)
        } else {
            window = NSColor(calibratedWhite: 0.98, alpha: 1)
            titlebar = NSColor(calibratedWhite: 0.94, alpha: 1)
            sidebar = NSColor(calibratedWhite: 0.92, alpha: 1)
            separator = NSColor(calibratedWhite: 0.82, alpha: 1)
            sidebarField = NSColor(calibratedWhite: 0.84, alpha: 1)
            sidebarButton = NSColor(calibratedWhite: 0.78, alpha: 1)
            accentButton = NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.14, alpha: 1)
        }

        matchLineColors = [
            .prefix,
            .metadata,
            .alias,
            .substring,
            .near,
            .weakPath,
            .exact
        ].map { AppSettings.matchColor(for: $0, isDark: isDark, defaults: defaults) }
    }
}

@MainActor
final class HotKeyRecorderView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Press shortcut")
    private let detailLabel = NSTextField(labelWithString: "Escape cancels")
    private(set) var recordedHotKey: GlobalHotKey?
    var onChange: ((GlobalHotKey?) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 74))

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.textColor = .labelColor

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.alignment = .center
        detailLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 5

        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 320),
            heightAnchor.constraint(equalToConstant: 74),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
            return
        }

        guard let hotKey = GlobalHotKey(event: event) else {
            recordedHotKey = nil
            titleLabel.stringValue = "Invalid shortcut"
            titleLabel.textColor = .systemRed
            detailLabel.stringValue = "Use a non-modifier key with a modifier"
            onChange?(nil)
            return
        }

        recordedHotKey = hotKey
        titleLabel.stringValue = hotKey.displayString
        titleLabel.textColor = .labelColor
        detailLabel.stringValue = "Ready to save"
        onChange?(hotKey)
    }
}

@MainActor
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class EmptyListCellView: NSTableCellView {
    let messageLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .systemFont(ofSize: 12, weight: .regular)
        messageLabel.textColor = .secondaryLabelColor

        addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class SettingsWarningView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        updateThemeColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateThemeColors()
    }

    private func updateThemeColors() {
        layer?.backgroundColor = AppTheme.resolvedCGColor(NSColor.systemYellow.withAlphaComponent(0.08), for: self)
        layer?.borderColor = AppTheme.resolvedCGColor(NSColor.systemYellow.withAlphaComponent(0.26), for: self)
    }
}

@MainActor
final class IndexedRootCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("IndexedRootCell")

    private let dragHandleView = NSImageView()
    private let iconView = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        identifier = Self.identifier

        dragHandleView.translatesAutoresizingMaskIntoConstraints = false
        dragHandleView.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag indexed folder")
        dragHandleView.contentTintColor = .tertiaryLabelColor

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Indexed folder")
        iconView.contentTintColor = .secondaryLabelColor

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .systemFont(ofSize: 12, weight: .regular)
        pathLabel.textColor = .labelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle

        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove indexed folder")
        removeButton.title = ""
        removeButton.isBordered = false
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.toolTip = "Remove indexed folder"

        for subview in [dragHandleView, iconView, pathLabel, removeButton] {
            addSubview(subview)
        }

        NSLayoutConstraint.activate([
            dragHandleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dragHandleView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dragHandleView.widthAnchor.constraint(equalToConstant: 14),
            dragHandleView.heightAnchor.constraint(equalToConstant: 14),

            iconView.leadingAnchor.constraint(equalTo: dragHandleView.trailingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            pathLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            pathLabel.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -14),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 22),
            removeButton.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(root: URL, index: Int, target: AnyObject, removeAction: Selector) {
        pathLabel.stringValue = AppSettings.displayPath(root)
        removeButton.tag = index
        removeButton.target = target
        removeButton.action = removeAction
    }
}

@MainActor
final class ExclusionPatternCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ExclusionPatternCell")

    let patternField = NSTextField(string: "")
    private let dragHandleView = NSImageView()
    private let removeButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        identifier = Self.identifier

        dragHandleView.translatesAutoresizingMaskIntoConstraints = false
        dragHandleView.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag excluded path")
        dragHandleView.contentTintColor = .tertiaryLabelColor

        patternField.translatesAutoresizingMaskIntoConstraints = false
        patternField.identifier = NSUserInterfaceItemIdentifier("exclusionPatternField")
        patternField.placeholderString = "**/.cache/"
        patternField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        patternField.textColor = .labelColor
        patternField.bezelStyle = .roundedBezel
        patternField.isBordered = true
        patternField.drawsBackground = true

        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove excluded path")
        removeButton.title = ""
        removeButton.isBordered = false
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.toolTip = "Remove excluded path"

        for subview in [dragHandleView, patternField, removeButton] {
            addSubview(subview)
        }

        NSLayoutConstraint.activate([
            dragHandleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dragHandleView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dragHandleView.widthAnchor.constraint(equalToConstant: 14),
            dragHandleView.heightAnchor.constraint(equalToConstant: 14),

            patternField.leadingAnchor.constraint(equalTo: dragHandleView.trailingAnchor, constant: 12),
            patternField.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -14),
            patternField.centerYAnchor.constraint(equalTo: centerYAnchor),

            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 22),
            removeButton.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        pattern: String,
        index: Int,
        target: AnyObject,
        removeAction: Selector,
        fieldAction: Selector
    ) {
        patternField.stringValue = pattern
        patternField.tag = index
        patternField.target = target
        patternField.action = fieldAction

        removeButton.tag = index
        removeButton.target = target
        removeButton.action = removeAction
    }
}

@MainActor
final class SidebarRow: NSControl {
    let section: SettingsSection
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    var isSelected = false {
        didSet {
            updateSelectionBackground()
        }
    }

    init(section: SettingsSection) {
        self.section = section
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        updateSelectionBackground()

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: section.symbolName, accessibilityDescription: section.title)
        iconView.contentTintColor = .labelColor

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = section.title
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .labelColor

        addSubview(iconView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelectionBackground()
    }

    private func updateSelectionBackground() {
        layer?.backgroundColor = isSelected
            ? AppTheme.resolvedCGColor(NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28), for: self)
            : AppTheme.resolvedCGColor(.clear, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }
}
