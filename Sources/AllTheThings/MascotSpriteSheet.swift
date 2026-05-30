import AppKit
import QuartzCore

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

enum OperationMascotIdleClip: String, CaseIterable {
    case mainLoop
    case blink
    case antennaWiggle
    case fileFinderSpark
    case victoryBounce

    var resourceName: String {
        switch self {
        case .mainLoop: "NibIdleMainLoopStrip"
        case .blink: "NibIdleBlinkFidgetStrip"
        case .antennaWiggle: "NibIdleAntennaFidgetStrip"
        case .fileFinderSpark: "NibIdleFileFinderSparkStrip"
        case .victoryBounce: "NibIdleVictoryBounceStrip"
        }
    }

    var frameCount: Int {
        switch self {
        case .mainLoop, .blink, .antennaWiggle: 8
        case .fileFinderSpark, .victoryBounce: 10
        }
    }

    var framesPerSecond: Double {
        switch self {
        case .mainLoop: 1.5
        case .blink: 4
        case .antennaWiggle: 3
        case .fileFinderSpark: 5
        case .victoryBounce: 5
        }
    }

    var loops: Bool {
        self == .mainLoop
    }

    var isFidget: Bool {
        switch self {
        case .blink, .antennaWiggle: true
        case .mainLoop, .fileFinderSpark, .victoryBounce: false
        }
    }

    var isFlourish: Bool {
        switch self {
        case .fileFinderSpark, .victoryBounce: true
        case .mainLoop, .blink, .antennaWiggle: false
        }
    }

    var idleSelectionWeight: Int {
        switch self {
        case .mainLoop: 84
        case .blink, .antennaWiggle: 6
        case .fileFinderSpark, .victoryBounce: 2
        }
    }

    var fallbackFrameIndices: [Int] {
        switch self {
        case .mainLoop:
            [0, 0, 0, 0, 0, 0, 0, 0]
        case .blink:
            [0, 0, 2, 2, 0, 0, 0, 0]
        case .antennaWiggle:
            [0, 1, 3, 4, 3, 1, 0, 0]
        case .fileFinderSpark:
            [0, 1, 1, 0, 2, 0, 1, 0, 0, 0]
        case .victoryBounce:
            [0, 1, 1, 0, 1, 0, 2, 0, 1, 0]
        }
    }
}

struct OperationMascotAnimationController {
    enum Frame: Equatable {
        case animation(OperationMascotAnimation, index: Int)
        case idleClip(OperationMascotIdleClip, index: Int)
    }

    enum AdvanceResult: Equatable {
        case advanced
        case changedIdleClip
        case completedOneShot
    }

    static let idleSelectionTable: [(clip: OperationMascotIdleClip, weight: Int)] = OperationMascotIdleClip.allCases
        .map { clip in (clip, clip.idleSelectionWeight) }

    private let idleClipSelector: () -> OperationMascotIdleClip

    private(set) var persistentAnimation: OperationMascotAnimation = .idle
    private(set) var activeAnimation: OperationMascotAnimation = .idle
    private(set) var activeIdleClip: OperationMascotIdleClip = .mainLoop
    private(set) var lastIdleFidget: OperationMascotIdleClip?
    private(set) var lastIdleFlourish: OperationMascotIdleClip?
    private var frameIndex = 0

    init(idleClipSelector: @escaping () -> OperationMascotIdleClip = OperationMascotAnimationController.weightedIdleClip) {
        self.idleClipSelector = idleClipSelector
    }

    var currentFrame: Frame {
        if activeAnimation == .idle {
            return .idleClip(activeIdleClip, index: frameIndex)
        }

        return .animation(activeAnimation, index: frameIndex)
    }

    var currentFramesPerSecond: Double {
        activeAnimation == .idle ? activeIdleClip.framesPerSecond : activeAnimation.framesPerSecond
    }

    var currentPlaybackFrameCount: Int {
        activeAnimation == .idle ? activeIdleClip.frameCount : activeAnimation.frameCount
    }

    var isIdleMainLoop: Bool {
        activeAnimation == .idle && activeIdleClip == .mainLoop
    }

    var canBeginIdleFidget: Bool {
        isIdleMainLoop
    }

    var canBeginIdleFlourish: Bool {
        isIdleMainLoop
    }

    mutating func setPersistentAnimation(_ animation: OperationMascotAnimation) -> Bool {
        persistentAnimation = animation

        guard activeAnimation.loops, activeAnimation != animation else {
            return false
        }

        start(animation)
        return true
    }

    mutating func start(_ animation: OperationMascotAnimation) {
        activeAnimation = animation
        activeIdleClip = .mainLoop
        frameIndex = 0
    }

    mutating func beginIdleFidget(_ clip: OperationMascotIdleClip? = nil) {
        guard canBeginIdleFidget else { return }

        let selectedClip: OperationMascotIdleClip
        if let clip, clip.isFidget {
            selectedClip = clip
        } else {
            selectedClip = nextIdleFidget()
        }

        activeIdleClip = selectedClip
        lastIdleFidget = selectedClip
        frameIndex = 0
    }

    mutating func beginIdleFlourish(_ clip: OperationMascotIdleClip? = nil) {
        guard canBeginIdleFlourish else { return }

        let selectedClip: OperationMascotIdleClip
        if let clip, clip.isFlourish {
            selectedClip = clip
        } else {
            selectedClip = nextIdleFlourish()
        }

        activeIdleClip = selectedClip
        lastIdleFlourish = selectedClip
        frameIndex = 0
    }

    mutating func advanceFrame() -> AdvanceResult {
        frameIndex += 1

        if frameIndex < currentPlaybackFrameCount {
            return .advanced
        }

        if activeAnimation == .idle {
            if activeIdleClip.loops {
                frameIndex = 0
                selectNextIdleClip()
                return .changedIdleClip
            }

            activeIdleClip = .mainLoop
            frameIndex = 0
            return .changedIdleClip
        }

        if activeAnimation.loops {
            frameIndex = 0
            return .advanced
        }

        return .completedOneShot
    }

    static func weightedIdleClip() -> OperationMascotIdleClip {
        let totalWeight = idleSelectionTable.reduce(0) { $0 + max(0, $1.weight) }
        guard totalWeight > 0 else { return .mainLoop }

        var roll = Int.random(in: 1...totalWeight)
        for entry in idleSelectionTable {
            roll -= max(0, entry.weight)
            if roll <= 0 {
                return entry.clip
            }
        }

        return .mainLoop
    }

    private mutating func selectNextIdleClip() {
        let selectedClip = idleClipSelector()
        activeIdleClip = selectedClip

        if selectedClip.isFidget {
            lastIdleFidget = selectedClip
        }
        if selectedClip.isFlourish {
            lastIdleFlourish = selectedClip
        }
    }

    private func nextIdleFidget() -> OperationMascotIdleClip {
        let fidgets = OperationMascotIdleClip.allCases.filter(\.isFidget)
        let eligibleFidgets = fidgets.filter { $0 != lastIdleFidget }
        return (eligibleFidgets.isEmpty ? fidgets : eligibleFidgets).randomElement() ?? .blink
    }

    private func nextIdleFlourish() -> OperationMascotIdleClip {
        let flourishes = OperationMascotIdleClip.allCases.filter(\.isFlourish)
        let eligibleFlourishes = flourishes.filter { $0 != lastIdleFlourish }
        return (eligibleFlourishes.isEmpty ? flourishes : eligibleFlourishes).randomElement() ?? .fileFinderSpark
    }
}

@MainActor
final class MascotSpriteSheet {
    static let shared = MascotSpriteSheet()

    private static let columnCount = 10
    private static let rowCount = 7

    private let frames: [OperationMascotAnimation: [NSImage]]
    private let idleClipFrames: [OperationMascotIdleClip: [NSImage]]

    convenience init() {
        self.init(
            imageURL: Self.bundledSpriteSheetURL(),
            idleClipDirectoryURL: Bundle.main.resourceURL
        )
    }

    init(imageURL: URL?, idleClipDirectoryURL: URL? = nil) {
        let slicedFrames: [OperationMascotAnimation: [NSImage]]
        if let imageURL, let image = NSImage(contentsOf: imageURL), let frames = Self.sliceFrames(from: image) {
            slicedFrames = frames
        } else {
            slicedFrames = [:]
        }

        self.frames = slicedFrames
        self.idleClipFrames = Self.loadIdleClipFrames(
            from: idleClipDirectoryURL,
            fallbackFrames: slicedFrames[.idle] ?? []
        )
    }

    func frame(for animation: OperationMascotAnimation, index: Int) -> NSImage? {
        guard let animationFrames = frames[animation], !animationFrames.isEmpty else {
            return nil
        }

        let wrappedIndex = ((index % animationFrames.count) + animationFrames.count) % animationFrames.count
        return animationFrames[wrappedIndex]
    }

    func frame(for idleClip: OperationMascotIdleClip, index: Int) -> NSImage? {
        guard let frames = idleClipFrames[idleClip], !frames.isEmpty else {
            return frame(for: .idle, index: index)
        }

        let wrappedIndex = ((index % frames.count) + frames.count) % frames.count
        return frames[wrappedIndex]
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

    private static func loadIdleClipFrames(
        from directoryURL: URL?,
        fallbackFrames: [NSImage]
    ) -> [OperationMascotIdleClip: [NSImage]] {
        var result: [OperationMascotIdleClip: [NSImage]] = [:]

        for clip in OperationMascotIdleClip.allCases {
            if
                let directoryURL,
                let stripFrames = sliceStripFrames(
                    from: directoryURL
                        .appendingPathComponent(clip.resourceName, isDirectory: false)
                        .appendingPathExtension("png"),
                    frameCount: clip.frameCount
                )
            {
                result[clip] = stripFrames
                continue
            }

            let frames = clip.fallbackFrameIndices.compactMap { index -> NSImage? in
                guard fallbackFrames.indices.contains(index) else { return nil }
                return fallbackFrames[index]
            }
            if frames.count == clip.frameCount {
                result[clip] = frames
            }
        }

        return result
    }

    private static func sliceStripFrames(from url: URL, frameCount: Int) -> [NSImage]? {
        guard let image = NSImage(contentsOf: url) else {
            return nil
        }

        return sliceStripFrames(from: image, frameCount: frameCount)
    }

    private static func sliceStripFrames(from image: NSImage, frameCount: Int) -> [NSImage]? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }

        var frames: [NSImage] = []
        frames.reserveCapacity(frameCount)

        for column in 0..<frameCount {
            let x0 = floor(Double(column) * Double(cgImage.width) / Double(frameCount))
            let x1 = column == frameCount - 1
                ? Double(cgImage.width)
                : floor(Double(column + 1) * Double(cgImage.width) / Double(frameCount))
            let rect = CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: Double(cgImage.height))

            guard let frameImage = cgImage.cropping(to: rect) else {
                continue
            }

            let image = NSImage(cgImage: frameImage, size: NSSize(width: rect.width, height: rect.height))
            image.isTemplate = false
            frames.append(image)
        }

        return frames.count == frameCount ? frames : nil
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
    static let layoutSize: CGFloat = 40
    static let statusDisplaySize: CGFloat = layoutSize
    static let heroDisplaySize: CGFloat = 86
    static let expandedDisplaySize: CGFloat = layoutSize * 4

    private let imageView: NSImageView
    private let spriteSheet: MascotSpriteSheet
    private let displaySize: CGFloat
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var animationController = OperationMascotAnimationController()
    private nonisolated(unsafe) var frameTimer: Timer?
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    init(
        imageView: NSImageView,
        spriteSheet: MascotSpriteSheet = .shared,
        displaySize: CGFloat = 40
    ) {
        self.imageView = imageView
        self.spriteSheet = spriteSheet
        self.displaySize = displaySize
        configureImageView()
        start(.idle)
    }

    deinit {
        frameTimer?.invalidate()
    }

    func setPersistentAnimation(_ animation: OperationMascotAnimation) {
        if animationController.setPersistentAnimation(animation) {
            didStartPlayback()
        }
    }

    func playTransient(_ animation: OperationMascotAnimation) {
        start(animation)
    }

    func setDisplaySize(_ size: CGFloat, animated: Bool = false) {
        if animated {
            widthConstraint?.animator().constant = size
            heightConstraint?.animator().constant = size
        } else {
            widthConstraint?.constant = size
            heightConstraint?.constant = size
        }
    }

    private func configureImageView() {
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.wantsLayer = true
        imageView.layer?.masksToBounds = false
        imageView.setAccessibilityRole(.image)

        let widthConstraint = imageView.widthAnchor.constraint(equalToConstant: displaySize)
        let heightConstraint = imageView.heightAnchor.constraint(equalToConstant: displaySize)
        self.widthConstraint = widthConstraint
        self.heightConstraint = heightConstraint
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])
    }

    private func start(_ animation: OperationMascotAnimation) {
        animationController.start(animation)
        didStartPlayback()
    }

    private func didStartPlayback() {
        imageView.setAccessibilityLabel(animationController.activeAnimation.accessibilityLabel)
        configureMotionAccent()
        renderCurrentFrame()
        configureTimers()
    }

    private func configureTimers() {
        frameTimer?.invalidate()
        frameTimer = nil

        guard !reduceMotion else { return }

        configureFrameTimer()
    }

    private func configureFrameTimer() {
        frameTimer?.invalidate()
        frameTimer = nil

        guard !reduceMotion, animationController.currentPlaybackFrameCount > 1 else { return }

        let frameInterval = 1 / animationController.currentFramesPerSecond
        let timer = Timer(
            timeInterval: frameInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.advanceFrame()
            }
        }
        timer.tolerance = min(0.03, frameInterval * 0.2)
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func advanceFrame() {
        let result = animationController.advanceFrame()
        if result == .completedOneShot {
            start(animationController.persistentAnimation)
            return
        }

        renderCurrentFrame()

        if result == .changedIdleClip {
            configureFrameTimer()
        }
    }

    private func renderCurrentFrame() {
        if !reduceMotion, imageView.image != nil {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = min(0.08, 0.4 / animationController.currentFramesPerSecond)
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            imageView.layer?.add(transition, forKey: "mascotFrameBlend")
        }

        switch animationController.currentFrame {
        case let .animation(animation, index):
            imageView.image = spriteSheet.frame(for: animation, index: index)
        case let .idleClip(clip, index):
            imageView.image = spriteSheet.frame(for: clip, index: index)
        }
    }

    private func configureMotionAccent() {
        guard let layer = imageView.layer else { return }
        layer.removeAnimation(forKey: "mascotFloat")
        layer.removeAnimation(forKey: "mascotTilt")

        guard !reduceMotion else { return }

        let amplitude: CGFloat
        let duration: CFTimeInterval
        let tilt: CGFloat
        switch animationController.activeAnimation {
        case .idle:
            amplitude = 0.6
            duration = 2.8
            tilt = 0.004
        case .indexing, .searching, .optimizing:
            amplitude = 2.4
            duration = 1.15
            tilt = 0.025
        case .fileChanged, .success:
            amplitude = 2.0
            duration = 0.75
            tilt = 0.02
        case .error:
            amplitude = 1.2
            duration = 0.55
            tilt = 0.018
        }

        let float = CABasicAnimation(keyPath: "transform.translation.y")
        float.fromValue = amplitude
        float.toValue = -amplitude
        float.duration = duration
        float.autoreverses = true
        float.repeatCount = .infinity
        float.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(float, forKey: "mascotFloat")

        let rotate = CABasicAnimation(keyPath: "transform.rotation.z")
        rotate.fromValue = -tilt
        rotate.toValue = tilt
        rotate.duration = duration * 1.4
        rotate.autoreverses = true
        rotate.repeatCount = .infinity
        rotate.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(rotate, forKey: "mascotTilt")
    }
}
