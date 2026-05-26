import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
    init(defaults: UserDefaults = .standard) {
        let viewController = SettingsViewController(defaults: defaults)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 620, height: 380)
        window.contentViewController = viewController
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class SettingsViewController: NSViewController {
    private let defaults: UserDefaults
    private let highlightSearchTextSwitch = NSSwitch()
    private let allowMultipleInstancesSwitch = NSSwitch()
    private let automaticallyCheckForUpdatesSwitch = NSSwitch()

    init(defaults: UserDefaults) {
        self.defaults = defaults
        AppSettings.registerDefaults(defaults)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        buildInterface()
        updateSwitches()
    }

    private func buildInterface() {
        let sidebar = makeSidebar()
        let contentView = makeContentView()

        view.addSubview(sidebar)
        view.addSubview(contentView)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 190),

            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func makeSidebar() -> NSView {
        let sidebar = NSVisualEffectView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active

        let selectedRow = NSView()
        selectedRow.translatesAutoresizingMaskIntoConstraints = false
        selectedRow.wantsLayer = true
        selectedRow.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28).cgColor
        selectedRow.layer?.cornerRadius = 8

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        icon.contentTintColor = .labelColor

        let label = NSTextField(labelWithString: "General")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor

        selectedRow.addSubview(icon)
        selectedRow.addSubview(label)
        sidebar.addSubview(selectedRow)

        NSLayoutConstraint.activate([
            selectedRow.topAnchor.constraint(equalTo: sidebar.safeAreaLayoutGuide.topAnchor, constant: 18),
            selectedRow.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            selectedRow.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            selectedRow.heightAnchor.constraint(equalToConstant: 36),

            icon.leadingAnchor.constraint(equalTo: selectedRow.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: selectedRow.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: selectedRow.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: selectedRow.centerYAnchor)
        ])

        return sidebar
    }

    private func makeContentView() -> NSView {
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "General")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        titleLabel.textColor = .labelColor

        let sectionLabel = NSTextField(labelWithString: "Application")
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        sectionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        sectionLabel.textColor = .secondaryLabelColor

        configureSwitch(highlightSearchTextSwitch, action: #selector(toggleHighlightSearchText(_:)))
        configureSwitch(allowMultipleInstancesSwitch, action: #selector(toggleAllowMultipleInstances(_:)))
        configureSwitch(automaticallyCheckForUpdatesSwitch, action: #selector(toggleAutomaticallyCheckForUpdates(_:)))

        let settingsCard = makeSettingsCard(rows: [
            makeSwitchRow(
                title: "Highlight search text",
                detail: "Highlight matching text in file names while searching.",
                control: highlightSearchTextSwitch
            ),
            makeSwitchRow(
                title: "Allow multiple instances",
                detail: "Open a new app instance instead of activating the existing one.",
                control: allowMultipleInstancesSwitch
            ),
            makeSwitchRow(
                title: "Automatically check for updates",
                detail: "Look for new GitHub releases in the background.",
                control: automaticallyCheckForUpdatesSwitch
            )
        ])

        contentView.addSubview(titleLabel)
        contentView.addSubview(sectionLabel)
        contentView.addSubview(settingsCard)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 58),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 52),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -52),

            sectionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 42),
            sectionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            sectionLabel.trailingAnchor.constraint(lessThanOrEqualTo: titleLabel.trailingAnchor),

            settingsCard.topAnchor.constraint(equalTo: sectionLabel.bottomAnchor, constant: 12),
            settingsCard.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            settingsCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -52)
        ])

        return contentView
    }

    private func configureSwitch(_ control: NSSwitch, action: Selector) {
        control.translatesAutoresizingMaskIntoConstraints = false
        control.target = self
        control.action = action
    }

    private func makeSettingsCard(rows: [NSView]) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.borderWidth = 1
        card.layer?.cornerRadius = 8

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0

        for (index, row) in rows.enumerated() {
            stack.addArrangedSubview(row)
            if index < rows.count - 1 {
                stack.addArrangedSubview(makeSeparator())
            }
        }

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])

        return card
    }

    private func makeSwitchRow(title: String, detail: String, control: NSSwitch) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .labelColor

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        row.addSubview(textStack)
        row.addSubview(control)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 74),

            textStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -24),
            textStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])

        return row
    }

    private func makeSeparator() -> NSView {
        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        NSLayoutConstraint.activate([
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])
        return separator
    }

    private func updateSwitches() {
        highlightSearchTextSwitch.state = defaults.bool(forKey: AppSettings.highlightSearchTextKey) ? .on : .off
        allowMultipleInstancesSwitch.state = defaults.bool(forKey: AppSettings.allowMultipleInstancesKey) ? .on : .off
        automaticallyCheckForUpdatesSwitch.state = ReleaseUpdater.shared.automaticallyChecksForUpdates ? .on : .off
    }

    @objc private func toggleHighlightSearchText(_ sender: NSSwitch) {
        defaults.set(sender.state == .on, forKey: AppSettings.highlightSearchTextKey)
        defaults.synchronize()
    }

    @objc private func toggleAllowMultipleInstances(_ sender: NSSwitch) {
        defaults.set(sender.state == .on, forKey: AppSettings.allowMultipleInstancesKey)
        defaults.synchronize()
    }

    @objc private func toggleAutomaticallyCheckForUpdates(_ sender: NSSwitch) {
        ReleaseUpdater.shared.automaticallyChecksForUpdates = sender.state == .on
        defaults.synchronize()
    }
}
