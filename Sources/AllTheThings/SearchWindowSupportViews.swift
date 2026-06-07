import AppKit

struct MatchPlacard {
    let title: String
    let scoreText: String
    let detail: String?
    let reason: String
    let color: NSColor
}

final class MatchIconCellView: NSTableCellView {
    let iconView = NSImageView()
    private var placard: MatchPlacard?
    private var trackingArea: NSTrackingArea?
    private weak var placardView: MatchPlacardView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        showPlacard()
    }

    override func mouseExited(with event: NSEvent) {
        hidePlacard()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hidePlacard()
        }
    }

    func configure(icon: NSImage?, color: NSColor, placard: MatchPlacard?) {
        hidePlacard()
        self.placard = placard
        removeAllToolTips()
        iconView.removeAllToolTips()
        toolTip = nil
        iconView.toolTip = nil
        iconView.image = Self.tintedImage(icon, color: color)
        iconView.isHidden = icon == nil
        setAccessibilityLabel(placard?.title)
        iconView.setAccessibilityLabel(placard?.title)
    }

    func hidePlacard() {
        placardView?.removeFromSuperview()
        placardView = nil
    }

    private func configure() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        iconView.setAccessibilityRole(.image)

        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    private func showPlacard() {
        guard let placard, let contentView = window?.contentView else { return }

        let placardView = placardView ?? MatchPlacardView()
        placardView.configure(placard)
        for visiblePlacardView in contentView.subviews.compactMap({ $0 as? MatchPlacardView }) where visiblePlacardView !== placardView {
            visiblePlacardView.removeFromSuperview()
        }
        if placardView.superview == nil {
            contentView.addSubview(placardView)
        }
        self.placardView = placardView

        let size = NSSize(width: 316, height: 136)
        let anchor = convert(bounds, to: contentView)
        let maxX = contentView.bounds.maxX - size.width - 10
        let preferredX = anchor.maxX + 8
        let x = max(10, min(preferredX, maxX))
        let y = max(10, min(anchor.midY - size.height / 2, contentView.bounds.maxY - size.height - 10))
        placardView.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private static func tintedImage(_ image: NSImage?, color: NSColor) -> NSImage? {
        guard let image else { return nil }

        let size = NSSize(width: 18, height: 18)
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let rect = NSRect(origin: .zero, size: size)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }
}

final class MatchPlacardView: NSView {
    private let swatchView = MatchSwatchView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let scoreLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let reasonLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    func configure(_ placard: MatchPlacard) {
        swatchView.color = placard.color
        titleLabel.stringValue = placard.title
        scoreLabel.stringValue = placard.scoreText
        detailLabel.stringValue = placard.detail ?? ""
        detailLabel.isHidden = placard.detail == nil
        reasonLabel.stringValue = placard.reason
        updateLayerColors()
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 14
        layer?.shadowOffset = NSSize(width: 0, height: -4)

        swatchView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        scoreLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        reasonLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = AppSettings.appFont(sizeDelta: 0, weight: .semibold)
        scoreLabel.font = AppSettings.appFont(sizeDelta: -1, weight: .medium)
        scoreLabel.textColor = .secondaryLabelColor
        detailLabel.font = AppSettings.appFont(sizeDelta: -1, weight: .medium)
        detailLabel.textColor = .labelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingTail
        reasonLabel.font = AppSettings.appFont(sizeDelta: -1)
        reasonLabel.textColor = .secondaryLabelColor
        reasonLabel.maximumNumberOfLines = 3
        reasonLabel.lineBreakMode = .byTruncatingTail

        addSubview(swatchView)
        addSubview(titleLabel)
        addSubview(scoreLabel)
        addSubview(detailLabel)
        addSubview(reasonLabel)

        NSLayoutConstraint.activate([
            swatchView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            swatchView.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            swatchView.widthAnchor.constraint(equalToConstant: 10),
            swatchView.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.leadingAnchor.constraint(equalTo: swatchView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            scoreLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            scoreLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            scoreLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: scoreLabel.bottomAnchor, constant: 7),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            reasonLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            reasonLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 6),
            reasonLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            reasonLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12)
        ])

        updateLayerColors()
    }

    private func updateLayerColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (isDark
            ? NSColor(calibratedWhite: 0.12, alpha: 0.98)
            : NSColor(calibratedWhite: 0.97, alpha: 0.98)
        ).cgColor
        layer?.borderColor = (isDark
            ? NSColor(calibratedWhite: 1.0, alpha: 0.16)
            : NSColor(calibratedWhite: 0.0, alpha: 0.12)
        ).cgColor
    }
}

final class MatchSwatchView: NSView {
    var color: NSColor = .clear {
        didSet {
            needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: min(3, rect.width / 2), yRadius: min(3, rect.width / 2))
        color.setFill()
        path.fill()
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (isDark
            ? NSColor.white.withAlphaComponent(0.55)
            : NSColor.black.withAlphaComponent(0.18)
        ).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

final class ClickableMascotView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

final class IndexingSetupOverlayView: NSView {
    let mascotImageView = NSImageView()
    let startIndexingButton = NSButton()
    let chooseIndexedFoldersButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        isHidden = true

        mascotImageView.translatesAutoresizingMaskIntoConstraints = false
        mascotImageView.imageAlignment = .alignCenter
        mascotImageView.imageScaling = .scaleProportionallyUpOrDown
        mascotImageView.setAccessibilityRole(.image)
        mascotImageView.setAccessibilityLabel(OperationMascotStandaloneClip.introWelcome.accessibilityLabel)

        let titleLabel = NSTextField(labelWithString: "Get Started")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = AppSettings.appFont(sizeDelta: 5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center

        let detailLabel = NSTextField(labelWithString: """
        Indexing lets AllTheThings discover files in selected folders,
        so filename and path searches can show results.
        Start with the default folders, or choose your own.
        """)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = AppSettings.appFont(sizeDelta: 1)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 3

        let buttonStack = NSStackView(views: [
            Self.configureActionButton(startIndexingButton, title: "Start Indexing", symbolName: "play.circle"),
            Self.configureActionButton(chooseIndexedFoldersButton, title: "Choose Folders...", symbolName: "folder")
        ])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8

        let stack = NSStackView(views: [mascotImageView, titleLabel, detailLabel, buttonStack])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 9

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),

            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 620)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setMascotVisible(_ visible: Bool) {
        mascotImageView.isHidden = !visible
    }

    @discardableResult
    private static func configureActionButton(_ button: NSButton, title: String, symbolName: String) -> NSButton {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = title
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = AppSettings.appFont(sizeDelta: 1)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
}

final class SetupSuggestionPanelView: NSView {
    let enableGlobalHotKeyButton = NSButton()
    let chooseGlobalHotKeyButton = NSButton()
    let enableGlobalAppSearchHotKeyButton = NSButton()
    let chooseGlobalAppSearchHotKeyButton = NSButton()
    let openFullDiskAccessButton = NSButton()
    let dismissGlobalHotKeyButton = NSButton()
    let dismissGlobalAppSearchHotKeyButton = NSButton()
    let dismissFullDiskAccessButton = NSButton()

    private let globalHotKeyRow = NSView()
    private let globalAppSearchHotKeyRow = NSView()
    private let fullDiskAccessRow = NSView()
    private let globalHotKeySeparator = SetupSuggestionSeparatorView()
    private let globalAppSearchHotKeySeparator = SetupSuggestionSeparatorView()
    private let globalHotKeyDetailLabel = NSTextField(labelWithString: "")
    private let globalAppSearchHotKeyDetailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let globalHotKeyTitleLabel = Self.makeTitleLabel("Global search hotkey")
        let globalAppSearchHotKeyTitleLabel = Self.makeTitleLabel("Global app search hotkey")
        let fullDiskAccessTitleLabel = Self.makeTitleLabel("Full Disk Access")
        let fullDiskAccessDetailLabel = Self.makeDetailLabel(
            "Grant access before indexing protected folders to avoid macOS prompts."
        )
        Self.configureSuggestionRow(
            globalHotKeyRow,
            symbolName: "keyboard",
            titleLabel: globalHotKeyTitleLabel,
            detailLabel: globalHotKeyDetailLabel,
            buttons: [
                Self.configureActionButton(enableGlobalHotKeyButton, title: "Enable", symbolName: "checkmark.circle"),
                Self.configureActionButton(chooseGlobalHotKeyButton, title: "Customize", symbolName: "slider.horizontal.3"),
                Self.configureActionButton(dismissGlobalHotKeyButton, title: "Not Now", symbolName: "xmark")
            ]
        )
        Self.configureSuggestionRow(
            globalAppSearchHotKeyRow,
            symbolName: "macwindow.badge.plus",
            titleLabel: globalAppSearchHotKeyTitleLabel,
            detailLabel: globalAppSearchHotKeyDetailLabel,
            buttons: [
                Self.configureActionButton(enableGlobalAppSearchHotKeyButton, title: "Enable", symbolName: "checkmark.circle"),
                Self.configureActionButton(chooseGlobalAppSearchHotKeyButton, title: "Customize", symbolName: "slider.horizontal.3"),
                Self.configureActionButton(dismissGlobalAppSearchHotKeyButton, title: "Not Now", symbolName: "xmark")
            ]
        )
        Self.configureSuggestionRow(
            fullDiskAccessRow,
            symbolName: "externaldrive.badge.checkmark",
            titleLabel: fullDiskAccessTitleLabel,
            detailLabel: fullDiskAccessDetailLabel,
            buttons: [
                Self.configureActionButton(openFullDiskAccessButton, title: "Open Settings", symbolName: "gearshape"),
                Self.configureActionButton(dismissFullDiskAccessButton, title: "Not Now", symbolName: "xmark")
            ]
        )

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        updateThemeColors()

        let rowsStack = NSStackView(views: [
            globalHotKeyRow,
            globalHotKeySeparator,
            globalAppSearchHotKeyRow,
            globalAppSearchHotKeySeparator,
            fullDiskAccessRow
        ])
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 5
        rowsStack.detachesHiddenViews = true

        addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            globalHotKeySeparator.heightAnchor.constraint(equalToConstant: 2),
            globalAppSearchHotKeySeparator.heightAnchor.constraint(equalToConstant: 2)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateThemeColors()
    }

    func update(
        hotKey: GlobalHotKey,
        appHotKey: GlobalHotKey,
        needsGlobalHotKey: Bool,
        needsGlobalAppSearchHotKey: Bool,
        needsFullDiskAccess: Bool
    ) {
        globalHotKeyDetailLabel.stringValue = "Use \(hotKey.displayString) to open search from anywhere."
        globalAppSearchHotKeyDetailLabel.stringValue = "Use \(appHotKey.displayString) to open app search from anywhere."
        globalHotKeyRow.isHidden = !needsGlobalHotKey
        globalAppSearchHotKeyRow.isHidden = !needsGlobalAppSearchHotKey
        fullDiskAccessRow.isHidden = !needsFullDiskAccess
        globalHotKeySeparator.isHidden = !needsGlobalHotKey || (!needsGlobalAppSearchHotKey && !needsFullDiskAccess)
        globalAppSearchHotKeySeparator.isHidden = !needsGlobalAppSearchHotKey || !needsFullDiskAccess
        isHidden = !needsGlobalHotKey && !needsGlobalAppSearchHotKey && !needsFullDiskAccess
    }

    private func updateThemeColors() {
        layer?.backgroundColor = AppTheme.resolvedCGColor(NSColor.controlBackgroundColor, for: self)
        layer?.borderColor = AppTheme.resolvedCGColor(NSColor.separatorColor, for: self)
    }

    private static func configureSuggestionRow(
        _ row: NSView,
        symbolName: String,
        titleLabel: NSTextField,
        detailLabel: NSTextField,
        buttons: [NSButton]
    ) {
        row.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: titleLabel.stringValue)
        iconView.contentTintColor = .secondaryLabelColor

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3

        let buttonStack = NSStackView(views: buttons)
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8

        row.addSubview(iconView)
        row.addSubview(textStack)
        row.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),

            iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -16),

            buttonStack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            buttonStack.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
    }

    private static func makeTitleLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = AppSettings.appFont(weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private static func makeDetailLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = AppSettings.appFont()
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    @discardableResult
    private static func configureActionButton(_ button: NSButton, title: String, symbolName: String) -> NSButton {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = title
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = AppSettings.appFont()
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
}

final class SetupSuggestionSeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
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
        layer?.backgroundColor = AppTheme.resolvedCGColor(NSColor.labelColor.withAlphaComponent(0.28), for: self)
    }
}

final class SearchCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock {
            cancelled
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
        }
    }
}

final class FileTableView: NSTableView {
    var openAction: (() -> Void)?
    var copyAction: (() -> Void)?
    var copyPathAction: (() -> Void)?

    @objc func copy(_ sender: Any?) {
        copyAction?()
    }

    override func rightMouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: location)
        if clickedRow >= 0, !selectedRowIndexes.contains(clickedRow) {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        super.rightMouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if Self.isPlainReturn(event) {
            openAction?()
            return
        }

        guard
            event.modifierFlags.contains(.command),
            event.charactersIgnoringModifiers?.lowercased() == "c"
        else {
            super.keyDown(with: event)
            return
        }

        if event.modifierFlags.contains(.option) {
            copyPathAction?()
        } else {
            copyAction?()
        }
    }

    private static func isPlainReturn(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isEmpty || modifiers == .numericPad else { return false }

        return event.charactersIgnoringModifiers == "\r"
            || event.charactersIgnoringModifiers == "\u{3}"
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
