import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
    init(defaults: UserDefaults = .standard) {
        let contentSize = NSSize(width: 780, height: 640)
        let viewController = SettingsViewController(defaults: defaults)
        viewController.preferredContentSize = contentSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 700, height: 560)
        window.contentViewController = viewController
        window.setContentSize(contentSize)
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private enum SettingsSection {
    case general
    case indexedFolders

    var title: String {
        switch self {
        case .general: "General"
        case .indexedFolders: "Indexed Folders"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .indexedFolders: "folder"
        }
    }
}

@MainActor
private final class SettingsViewController: NSViewController {
    private let defaults: UserDefaults
    private let contentContainer = NSView()
    private let generalSidebarRow = SidebarRow(section: .general)
    private let indexedFoldersSidebarRow = SidebarRow(section: .indexedFolders)
    private let highlightSearchTextSwitch = NSSwitch()
    private let allowMultipleInstancesSwitch = NSSwitch()
    private let automaticallyCheckForUpdatesSwitch = NSSwitch()
    private let rootsStack = NSStackView()
    private let addRootButton = NSButton()
    private let exclusionPatternsTextView = NSTextView()
    private let applyExclusionsButton = NSButton()
    private var pageViews: [SettingsSection: NSView] = [:]
    private var selectedSection = SettingsSection.general

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
        view = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 640))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        buildInterface()
        updateSwitches()
        selectSection(.general)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(indexedRootsDidChange(_:)),
            name: AppSettings.indexedRootsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(exclusionPatternsDidChange(_:)),
            name: AppSettings.exclusionPatternsDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func buildInterface() {
        let sidebar = makeSidebar()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(sidebar)
        view.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 190),

            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func makeSidebar() -> NSView {
        let sidebar = NSVisualEffectView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active

        let stack = NSStackView(views: [generalSidebarRow, indexedFoldersSidebarRow])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6

        for row in [generalSidebarRow, indexedFoldersSidebarRow] {
            row.target = self
            row.action = #selector(selectSidebarRow(_:))
        }

        sidebar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sidebar.safeAreaLayoutGuide.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12)
        ])

        return sidebar
    }

    @objc private func selectSidebarRow(_ sender: SidebarRow) {
        selectSection(sender.section)
    }

    private func selectSection(_ section: SettingsSection) {
        selectedSection = section
        generalSidebarRow.isSelected = section == .general
        indexedFoldersSidebarRow.isSelected = section == .indexedFolders
        renderSelectedSection()
    }

    private func renderSelectedSection() {
        let page = pageView(for: selectedSection)
        if page.superview == nil {
            contentContainer.addSubview(page)
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                page.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                page.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
            ])
        }

        for (section, view) in pageViews {
            view.isHidden = section != selectedSection
        }

        if selectedSection == .indexedFolders {
            renderIndexedRoots()
            renderExclusionPatterns()
        }
    }

    private func pageView(for section: SettingsSection) -> NSView {
        if let page = pageViews[section] {
            return page
        }

        let page: NSView
        switch section {
        case .general:
            page = makeGeneralPage()
        case .indexedFolders:
            page = makeIndexedFoldersPage()
        }

        pageViews[section] = page
        return page
    }

    private func makePageScrollView() -> (NSScrollView, NSView) {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        return (scrollView, contentView)
    }

    private func makeGeneralPage() -> NSView {
        let (scrollView, contentView) = makePageScrollView()

        let titleLabel = makeTitleLabel("General")
        let sectionLabel = makeSectionLabel("Application")

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
            settingsCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -52),
            settingsCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -32)
        ])

        return scrollView
    }

    private func makeIndexedFoldersPage() -> NSView {
        let (scrollView, contentView) = makePageScrollView()

        let titleLabel = makeTitleLabel("Indexed Folders")
        let rootsHeader = NSStackView()
        rootsHeader.translatesAutoresizingMaskIntoConstraints = false
        rootsHeader.orientation = .horizontal
        rootsHeader.alignment = .centerY
        rootsHeader.spacing = 8

        let rootsLabel = makeSectionLabel("Folders")

        addRootButton.translatesAutoresizingMaskIntoConstraints = false
        addRootButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add indexed folder")
        addRootButton.title = ""
        addRootButton.bezelStyle = .texturedRounded
        addRootButton.toolTip = "Add indexed folder"
        addRootButton.target = self
        addRootButton.action = #selector(addIndexedRoot(_:))

        let rootsHeaderSpacer = NSView()
        rootsHeaderSpacer.translatesAutoresizingMaskIntoConstraints = false
        rootsHeader.addArrangedSubview(rootsLabel)
        rootsHeader.addArrangedSubview(rootsHeaderSpacer)
        rootsHeader.addArrangedSubview(addRootButton)

        let rootsCard = makeIndexedRootsCard()

        let exclusionsHeader = NSStackView()
        exclusionsHeader.translatesAutoresizingMaskIntoConstraints = false
        exclusionsHeader.orientation = .horizontal
        exclusionsHeader.alignment = .centerY
        exclusionsHeader.spacing = 8

        let exclusionsLabel = makeSectionLabel("Excluded paths")

        applyExclusionsButton.translatesAutoresizingMaskIntoConstraints = false
        applyExclusionsButton.title = "Apply"
        applyExclusionsButton.bezelStyle = .rounded
        applyExclusionsButton.controlSize = .small
        applyExclusionsButton.target = self
        applyExclusionsButton.action = #selector(applyExclusionPatterns(_:))

        let exclusionsHeaderSpacer = NSView()
        exclusionsHeaderSpacer.translatesAutoresizingMaskIntoConstraints = false
        exclusionsHeader.addArrangedSubview(exclusionsLabel)
        exclusionsHeader.addArrangedSubview(exclusionsHeaderSpacer)
        exclusionsHeader.addArrangedSubview(applyExclusionsButton)

        let exclusionsCard = makeExclusionPatternsCard()

        contentView.addSubview(titleLabel)
        contentView.addSubview(rootsHeader)
        contentView.addSubview(rootsCard)
        contentView.addSubview(exclusionsHeader)
        contentView.addSubview(exclusionsCard)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.topAnchor, constant: 58),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 52),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -52),

            rootsHeader.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 42),
            rootsHeader.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            rootsHeader.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -52),
            addRootButton.widthAnchor.constraint(equalToConstant: 28),
            addRootButton.heightAnchor.constraint(equalToConstant: 24),

            rootsCard.topAnchor.constraint(equalTo: rootsHeader.bottomAnchor, constant: 10),
            rootsCard.leadingAnchor.constraint(equalTo: rootsHeader.leadingAnchor),
            rootsCard.trailingAnchor.constraint(equalTo: rootsHeader.trailingAnchor),

            exclusionsHeader.topAnchor.constraint(equalTo: rootsCard.bottomAnchor, constant: 28),
            exclusionsHeader.leadingAnchor.constraint(equalTo: rootsCard.leadingAnchor),
            exclusionsHeader.trailingAnchor.constraint(equalTo: rootsCard.trailingAnchor),

            exclusionsCard.topAnchor.constraint(equalTo: exclusionsHeader.bottomAnchor, constant: 10),
            exclusionsCard.leadingAnchor.constraint(equalTo: rootsCard.leadingAnchor),
            exclusionsCard.trailingAnchor.constraint(equalTo: rootsCard.trailingAnchor),
            exclusionsCard.heightAnchor.constraint(equalToConstant: 156),
            exclusionsCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -32)
        ])

        return scrollView
    }

    private func makeTitleLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 26, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    private func makeSectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func configureSwitch(_ control: NSSwitch, action: Selector) {
        control.translatesAutoresizingMaskIntoConstraints = false
        control.target = self
        control.action = action
    }

    private func makeSettingsCard(rows: [NSView]) -> NSView {
        let card = makeCard()

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

    private func makeIndexedRootsCard() -> NSView {
        let card = makeCard()

        rootsStack.translatesAutoresizingMaskIntoConstraints = false
        rootsStack.orientation = .vertical
        rootsStack.alignment = .leading
        rootsStack.spacing = 0

        card.addSubview(rootsStack)
        NSLayoutConstraint.activate([
            rootsStack.topAnchor.constraint(equalTo: card.topAnchor),
            rootsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rootsStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rootsStack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])

        return card
    }

    private func makeExclusionPatternsCard() -> NSView {
        let card = makeCard()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        exclusionPatternsTextView.drawsBackground = false
        exclusionPatternsTextView.isRichText = false
        exclusionPatternsTextView.isAutomaticQuoteSubstitutionEnabled = false
        exclusionPatternsTextView.isAutomaticDashSubstitutionEnabled = false
        exclusionPatternsTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        exclusionPatternsTextView.textColor = .labelColor
        exclusionPatternsTextView.textContainerInset = NSSize(width: 10, height: 10)
        exclusionPatternsTextView.isVerticallyResizable = true
        exclusionPatternsTextView.isHorizontallyResizable = false
        exclusionPatternsTextView.autoresizingMask = [.width]
        exclusionPatternsTextView.textContainer?.widthTracksTextView = true
        scrollView.documentView = exclusionPatternsTextView

        card.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: card.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])

        return card
    }

    private func makeCard() -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.borderWidth = 1
        card.layer?.cornerRadius = 8
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

    private func makeIndexedRootRow(_ root: URL) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Indexed folder")
        icon.contentTintColor = .secondaryLabelColor

        let pathLabel = NSTextField(labelWithString: AppSettings.displayPath(root))
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .systemFont(ofSize: 12, weight: .regular)
        pathLabel.textColor = .labelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle

        let removeButton = NSButton()
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove indexed folder")
        removeButton.title = ""
        removeButton.isBordered = false
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.toolTip = "Remove indexed folder"
        removeButton.identifier = NSUserInterfaceItemIdentifier(root.standardizedFileURL.path)
        removeButton.target = self
        removeButton.action = #selector(removeIndexedRoot(_:))

        row.addSubview(icon)
        row.addSubview(pathLabel)
        row.addSubview(removeButton)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 38),

            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            pathLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            pathLabel.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -14),
            pathLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            removeButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            removeButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 22),
            removeButton.heightAnchor.constraint(equalToConstant: 22)
        ])

        return row
    }

    private func makeEmptyRootsRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "No indexed folders")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor

        row.addSubview(label)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 44),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])

        return row
    }

    private func addFullWidthRootSubview(_ subview: NSView) {
        rootsStack.addArrangedSubview(subview)
        subview.widthAnchor.constraint(equalTo: rootsStack.widthAnchor).isActive = true
    }

    private func renderIndexedRoots() {
        for view in rootsStack.arrangedSubviews {
            rootsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let roots = AppSettings.indexedRoots(defaults: defaults)
        guard !roots.isEmpty else {
            addFullWidthRootSubview(makeEmptyRootsRow())
            return
        }

        for (index, root) in roots.enumerated() {
            addFullWidthRootSubview(makeIndexedRootRow(root))
            if index < roots.count - 1 {
                addFullWidthRootSubview(makeSeparator())
            }
        }
    }

    private func renderExclusionPatterns() {
        let patterns = AppSettings.exclusionPatterns(defaults: defaults)
        let text = patterns.joined(separator: "\n")
        guard exclusionPatternsTextView.string != text else { return }
        exclusionPatternsTextView.string = text
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

    @objc private func addIndexedRoot(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self else { return }

            var roots = AppSettings.indexedRoots(defaults: self.defaults)
            var existing = Set(roots.map { $0.standardizedFileURL.path })

            for url in panel.urls.map(\.standardizedFileURL) where existing.insert(url.path).inserted {
                roots.append(url)
            }

            AppSettings.saveIndexedRoots(roots, defaults: self.defaults)
            self.renderIndexedRoots()
        }

        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    @objc private func removeIndexedRoot(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }

        let roots = AppSettings.indexedRoots(defaults: defaults).filter {
            $0.standardizedFileURL.path != path
        }
        AppSettings.saveIndexedRoots(roots, defaults: defaults)
        renderIndexedRoots()
    }

    @objc private func indexedRootsDidChange(_ notification: Notification) {
        renderIndexedRoots()
    }

    @objc private func applyExclusionPatterns(_ sender: NSButton) {
        let patterns = exclusionPatternsTextView.string
            .components(separatedBy: .newlines)
        AppSettings.saveExclusionPatterns(patterns, defaults: defaults)
    }

    @objc private func exclusionPatternsDidChange(_ notification: Notification) {
        renderExclusionPatterns()
    }
}

@MainActor
private final class SidebarRow: NSControl {
    let section: SettingsSection
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    var isSelected = false {
        didSet {
            layer?.backgroundColor = isSelected
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28).cgColor
                : NSColor.clear.cgColor
        }
    }

    init(section: SettingsSection) {
        self.section = section
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

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

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }
}
