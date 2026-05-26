import AppKit

enum AppTheme {
    @MainActor
    static func apply(_ preference: AppThemePreference) {
        switch preference {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    static func applyCurrent(defaults: UserDefaults = .standard) {
        apply(AppSettings.themePreference(defaults: defaults))
    }

    @MainActor
    static func resolvedCGColor(_ color: NSColor, for view: NSView) -> CGColor {
        var resolvedColor = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolvedColor = color.cgColor
        }
        return resolvedColor
    }

    @MainActor
    static func isDarkAppearance(for view: NSView) -> Bool {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

final class ThemedBackgroundView: NSView {
    var appearanceDidChange: (() -> Void)?

    var backgroundColor: NSColor {
        didSet {
            updateThemeColors()
        }
    }

    init(backgroundColor: NSColor = .windowBackgroundColor) {
        self.backgroundColor = backgroundColor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        updateThemeColors()
    }

    override init(frame frameRect: NSRect) {
        self.backgroundColor = .windowBackgroundColor
        super.init(frame: frameRect)
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
        appearanceDidChange?()
    }

    func updateThemeColors() {
        layer?.backgroundColor = AppTheme.resolvedCGColor(backgroundColor, for: self)
    }
}

final class ThemedCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
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

    func updateThemeColors() {
        layer?.backgroundColor = AppTheme.resolvedCGColor(.controlBackgroundColor, for: self)
        layer?.borderColor = AppTheme.resolvedCGColor(.separatorColor, for: self)
    }
}
