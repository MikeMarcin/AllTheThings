import AppKit

enum OperationMascotAnimation: String, CaseIterable {
    case idle
    case indexing
    case searching
    case optimizing
    case fileChanged
    case success
    case error

    var row: Int {
        switch self {
        case .idle: 0
        case .indexing: 1
        case .searching: 2
        case .optimizing: 3
        case .fileChanged: 4
        case .success: 5
        case .error: 6
        }
    }

    var frameCount: Int {
        switch self {
        case .idle: 8
        case .indexing: 10
        case .searching: 10
        case .optimizing: 10
        case .fileChanged: 6
        case .success: 8
        case .error: 6
        }
    }

    var framesPerSecond: Double {
        switch self {
        case .idle: 4
        case .indexing: 5
        case .searching: 5
        case .optimizing: 5
        case .fileChanged: 6
        case .success: 6
        case .error: 5
        }
    }

    var loops: Bool {
        switch self {
        case .idle, .indexing, .searching, .optimizing:
            true
        case .fileChanged, .success, .error:
            false
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: "Idle"
        case .indexing: "Indexing files"
        case .searching: "Searching files"
        case .optimizing: "Optimizing files"
        case .fileChanged: "File changed"
        case .success: "Operation completed"
        case .error: "Operation needs attention"
        }
    }
}

@MainActor
final class MascotSpriteSheet {
    static let shared = MascotSpriteSheet()

    private static let columnCount = 10
    private static let rowCount = 7

    private let frames: [OperationMascotAnimation: [NSImage]]

    convenience init() {
        self.init(imageURL: Self.bundledSpriteSheetURL())
    }

    init(imageURL: URL?) {
        if let imageURL, let image = NSImage(contentsOf: imageURL), let frames = Self.sliceFrames(from: image) {
            self.frames = frames
        } else {
            self.frames = [:]
        }
    }

    func frame(for animation: OperationMascotAnimation, index: Int) -> NSImage? {
        guard let animationFrames = frames[animation], !animationFrames.isEmpty else {
            return nil
        }

        let wrappedIndex = ((index % animationFrames.count) + animationFrames.count) % animationFrames.count
        return animationFrames[wrappedIndex]
    }

    private static func bundledSpriteSheetURL() -> URL? {
        Bundle.main.url(forResource: "NibGeneratedMasterSheet", withExtension: "png")
    }

    private static func sliceFrames(from image: NSImage) -> [OperationMascotAnimation: [NSImage]]? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }

        var result: [OperationMascotAnimation: [NSImage]] = [:]
        for animation in OperationMascotAnimation.allCases {
            var animationFrames: [NSImage] = []
            animationFrames.reserveCapacity(animation.frameCount)

            for column in 0..<animation.frameCount {
                let rect = cropRect(
                    imageWidth: cgImage.width,
                    imageHeight: cgImage.height,
                    column: column,
                    row: animation.row
                )

                guard let frameImage = cgImage.cropping(to: rect) else {
                    continue
                }

                let image = NSImage(cgImage: frameImage, size: NSSize(width: rect.width, height: rect.height))
                image.isTemplate = false
                animationFrames.append(image)
            }

            result[animation] = animationFrames
        }

        return result
    }

    private static func cropRect(imageWidth: Int, imageHeight: Int, column: Int, row: Int) -> CGRect {
        let x0 = floor(Double(column) * Double(imageWidth) / Double(columnCount))
        let x1 = column == columnCount - 1
            ? Double(imageWidth)
            : floor(Double(column + 1) * Double(imageWidth) / Double(columnCount))
        let y0 = floor(Double(row) * Double(imageHeight) / Double(rowCount))
        let y1 = row == rowCount - 1
            ? Double(imageHeight)
            : floor(Double(row + 1) * Double(imageHeight) / Double(rowCount))

        return CGRect(
            x: x0,
            y: y0,
            width: max(1, x1 - x0),
            height: max(1, y1 - y0)
        )
    }
}

@MainActor
final class OperationMascotCoordinator {
    static let layoutSize: CGFloat = 24

    private static let displaySize: CGFloat = 30

    private let imageView: NSImageView
    private let spriteSheet: MascotSpriteSheet
    private var persistentAnimation: OperationMascotAnimation = .idle
    private var activeAnimation: OperationMascotAnimation = .idle
    private var frameIndex = 0
    private nonisolated(unsafe) var timer: Timer?
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    init(imageView: NSImageView, spriteSheet: MascotSpriteSheet = .shared) {
        self.imageView = imageView
        self.spriteSheet = spriteSheet
        configureImageView()
        setPersistentAnimation(.idle)
    }

    deinit {
        timer?.invalidate()
    }

    func setPersistentAnimation(_ animation: OperationMascotAnimation) {
        persistentAnimation = animation
        guard activeAnimation.loops else { return }
        start(animation)
    }

    func playTransient(_ animation: OperationMascotAnimation) {
        start(animation)
    }

    private func configureImageView() {
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.wantsLayer = true
        imageView.layer?.masksToBounds = false
        imageView.setAccessibilityRole(.image)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: Self.displaySize),
            imageView.heightAnchor.constraint(equalToConstant: Self.displaySize)
        ])
    }

    private func start(_ animation: OperationMascotAnimation) {
        activeAnimation = animation
        frameIndex = 0
        imageView.setAccessibilityLabel(animation.accessibilityLabel)
        renderCurrentFrame()
        configureTimer()
    }

    private func configureTimer() {
        timer?.invalidate()
        timer = nil

        guard !reduceMotion, activeAnimation.frameCount > 1 else {
            return
        }

        timer = Timer.scheduledTimer(
            withTimeInterval: 1 / activeAnimation.framesPerSecond,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.advanceFrame()
            }
        }
    }

    private func advanceFrame() {
        frameIndex += 1
        if frameIndex >= activeAnimation.frameCount {
            if activeAnimation.loops {
                frameIndex = 0
            } else {
                start(persistentAnimation)
                return
            }
        }

        renderCurrentFrame()
    }

    private func renderCurrentFrame() {
        imageView.image = spriteSheet.frame(for: activeAnimation, index: frameIndex)
    }
}
