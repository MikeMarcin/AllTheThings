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
