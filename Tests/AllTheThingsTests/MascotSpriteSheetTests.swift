@testable import AllTheThings
import AppKit
import Foundation
import Testing

@Suite("Mascot sprite sheet")
struct MascotSpriteSheetTests {
    @Test("animation metadata matches runtime strips")
    @MainActor
    func animationMetadataMatchesRuntimeStrips() {
        #expect(OperationMascotAnimation.idle.resourceName == "NibOperationIdleStrip")
        #expect(OperationMascotAnimation.indexing.resourceName == "NibOperationIndexingStrip")
        #expect(OperationMascotAnimation.searching.resourceName == "NibOperationSearchingStrip")
        #expect(OperationMascotAnimation.optimizing.resourceName == "NibOperationOptimizingStrip")
        #expect(OperationMascotAnimation.fileChanged.resourceName == "NibOperationFileChangedStrip")
        #expect(OperationMascotAnimation.success.resourceName == "NibOperationSuccessStrip")
        #expect(OperationMascotAnimation.error.resourceName == "NibOperationErrorStrip")
        #expect(OperationMascotAnimation.idle.frameCount == 8)
        #expect(OperationMascotAnimation.indexing.frameCount == 16)
        #expect(OperationMascotAnimation.searching.frameCount == 16)
        #expect(OperationMascotAnimation.optimizing.frameCount == 16)
        #expect(OperationMascotAnimation.fileChanged.frameCount == 6)
        #expect(OperationMascotAnimation.success.frameCount == 8)
        #expect(OperationMascotAnimation.error.frameCount == 6)

        #expect(OperationMascotAnimation.idle.framesPerSecond == 4)
        #expect(OperationMascotAnimation.indexing.framesPerSecond == 5)
        #expect(OperationMascotAnimation.searching.framesPerSecond == 8)
        #expect(OperationMascotAnimation.optimizing.framesPerSecond == 5)
        #expect(OperationMascotAnimation.fileChanged.framesPerSecond == 6)
        #expect(OperationMascotAnimation.success.framesPerSecond == 6)
        #expect(OperationMascotAnimation.error.framesPerSecond == 5)

        for animation in OperationMascotAnimation.allCases {
            #expect(!animation.accessibilityLabel.isEmpty)
            #expect(animation.framesPerSecond > 0)
            #expect(animation.framesPerSecond <= 8)
        }

        #expect(OperationMascotAnimation.indexing.playbackPriority > OperationMascotAnimation.fileChanged.playbackPriority)
        #expect(OperationMascotAnimation.optimizing.playbackPriority > OperationMascotAnimation.fileChanged.playbackPriority)
        #expect(OperationMascotAnimation.indexing.playbackPriority > OperationMascotAnimation.success.playbackPriority)
        #expect(OperationMascotAnimation.optimizing.playbackPriority > OperationMascotAnimation.error.playbackPriority)

        #expect(OperationMascotCoordinator.statusDisplaySize == 40)
        #expect(OperationMascotCoordinator.footerSlotHeight == 28)
        #expect(OperationMascotCoordinator.footerSlotHeight < OperationMascotCoordinator.statusDisplaySize)
        #expect(OperationMascotCoordinator.heroDisplaySize == 86)
        #expect(OperationMascotCoordinator.heroDisplaySize > OperationMascotCoordinator.statusDisplaySize * 2)
        #expect(OperationMascotCoordinator.expandedDisplaySize == OperationMascotCoordinator.statusDisplaySize * 4)
        #expect(OperationMascotCoordinator.expandedDisplaySize > OperationMascotCoordinator.heroDisplaySize)

        #expect(OperationMascotAnimation.idle.loops)
        #expect(OperationMascotAnimation.indexing.loops)
        #expect(OperationMascotAnimation.searching.loops)
        #expect(OperationMascotAnimation.optimizing.loops)
        #expect(!OperationMascotAnimation.fileChanged.loops)
        #expect(!OperationMascotAnimation.success.loops)
        #expect(!OperationMascotAnimation.error.loops)
    }

    @Test("idle clip metadata supports a subtle loop and unique fidgets")
    func idleClipMetadataSupportsSubtleLoopAndUniqueFidgets() {
        #expect(OperationMascotIdleClip.mainLoop.frameCount == 8)
        #expect(OperationMascotIdleClip.mainLoop.framesPerSecond <= 2)
        #expect(OperationMascotIdleClip.mainLoop.loops)
        #expect(!OperationMascotIdleClip.mainLoop.isFidget)
        #expect(!OperationMascotIdleClip.mainLoop.isFlourish)

        let fidgets = OperationMascotIdleClip.allCases.filter(\.isFidget)
        #expect(fidgets.count >= 2)
        let flourishes = OperationMascotIdleClip.allCases.filter(\.isFlourish)
        #expect(flourishes.count >= 2)
        #expect(OperationMascotAnimationController.idleSelectionTable.count == OperationMascotIdleClip.allCases.count)

        for clip in OperationMascotIdleClip.allCases {
            #expect(!clip.resourceName.isEmpty)
            #expect(clip.framesPerSecond > 0)
            #expect(clip.framesPerSecond <= 5)
            #expect(!(clip.isFidget && clip.isFlourish))
            #expect(clip.idleSelectionWeight > 0)
        }

        #expect(OperationMascotIdleClip.mainLoop.idleSelectionWeight > fidgets.map(\.idleSelectionWeight).reduce(0, +))
        #expect(flourishes.allSatisfy { $0.idleSelectionWeight < OperationMascotIdleClip.blink.idleSelectionWeight })
    }

    @Test("standalone clip metadata stays out of idle selection")
    func standaloneClipMetadataStaysOutOfIdleSelection() {
        #expect(OperationMascotStandaloneClip.introWelcome.resourceName == "NibIntroWelcomeStrip")
        #expect(OperationMascotStandaloneClip.introWelcome.frameCount == 32)
        #expect(OperationMascotStandaloneClip.introWelcome.framesPerSecond == 4)
        #expect(OperationMascotStandaloneClip.introWelcome.loops)
        #expect(!OperationMascotStandaloneClip.introWelcome.accessibilityLabel.isEmpty)

        #expect(OperationMascotStandaloneClip.flydown.resourceName == "NibFlydownStrip")
        #expect(OperationMascotStandaloneClip.flydown.frameCount == 10)
        #expect(OperationMascotStandaloneClip.flydown.framesPerSecond == 14)
        #expect(!OperationMascotStandaloneClip.flydown.loops)
        #expect(!OperationMascotStandaloneClip.flydown.accessibilityLabel.isEmpty)

        for clip in OperationMascotStandaloneClip.allCases {
            #expect(!OperationMascotIdleClip.allCases.map(\.resourceName).contains(clip.resourceName))
            #expect(!OperationMascotAnimationController.idleSelectionTable.map(\.clip.resourceName).contains(clip.resourceName))
        }
    }

    @Test("animation controller rolls weighted idle table after main loop")
    func animationControllerRollsWeightedIdleTableAfterMainLoop() {
        var controller = OperationMascotAnimationController(idleClipSelector: { .victoryBounce })
        #expect(controller.currentFrame == .idleClip(.mainLoop, index: 0))

        for index in 1..<OperationMascotIdleClip.mainLoop.frameCount {
            #expect(controller.advanceFrame() == .advanced)
            #expect(controller.currentFrame == .idleClip(.mainLoop, index: index))
        }

        #expect(controller.advanceFrame() == .changedIdleClip)
        #expect(controller.currentFrame == .idleClip(.victoryBounce, index: 0))
    }

    @Test("animation controller returns to main idle after fidgets")
    func animationControllerReturnsToMainIdleAfterFidgets() {
        var controller = OperationMascotAnimationController()
        #expect(controller.currentFrame == .idleClip(.mainLoop, index: 0))
        #expect(controller.isIdleMainLoop)

        controller.beginIdleFidget(.blink)
        #expect(controller.currentFrame == .idleClip(.blink, index: 0))
        #expect(!controller.isIdleMainLoop)

        for index in 1..<OperationMascotIdleClip.blink.frameCount {
            #expect(controller.advanceFrame() == .advanced)
            #expect(controller.currentFrame == .idleClip(.blink, index: index))
        }

        #expect(controller.advanceFrame() == .changedIdleClip)
        #expect(controller.currentFrame == .idleClip(.mainLoop, index: 0))
        #expect(controller.isIdleMainLoop)
    }

    @Test("animation controller returns to main idle after rare flourishes")
    func animationControllerReturnsToMainIdleAfterRareFlourishes() {
        var controller = OperationMascotAnimationController()
        #expect(controller.currentFrame == .idleClip(.mainLoop, index: 0))
        #expect(controller.isIdleMainLoop)

        controller.beginIdleFlourish(.fileFinderSpark)
        #expect(controller.currentFrame == .idleClip(.fileFinderSpark, index: 0))
        #expect(!controller.isIdleMainLoop)

        for index in 1..<OperationMascotIdleClip.fileFinderSpark.frameCount {
            #expect(controller.advanceFrame() == .advanced)
            #expect(controller.currentFrame == .idleClip(.fileFinderSpark, index: index))
        }

        #expect(controller.advanceFrame() == .changedIdleClip)
        #expect(controller.currentFrame == .idleClip(.mainLoop, index: 0))
        #expect(controller.isIdleMainLoop)
    }

    @Test("animation controller reports one shot completion")
    func animationControllerReportsOneShotCompletion() {
        var controller = OperationMascotAnimationController()
        controller.start(.success)
        #expect(controller.currentFrame == .animation(.success, index: 0))

        for index in 1..<OperationMascotAnimation.success.frameCount {
            #expect(controller.advanceFrame() == .advanced)
            #expect(controller.currentFrame == .animation(.success, index: index))
        }

        #expect(controller.advanceFrame() == .completedOneShot)
    }

    @Test("animation controller keeps indexing and optimizing ahead of lower priority transients")
    func animationControllerKeepsIndexingAndOptimizingAheadOfLowerPriorityTransients() {
        var controller = OperationMascotAnimationController()

        let didStartIndexing = controller.setPersistentAnimation(.indexing)
        #expect(didStartIndexing)
        #expect(controller.currentFrame == .animation(.indexing, index: 0))
        let didStartFileChangedWhileIndexing = controller.playTransient(.fileChanged)
        #expect(!didStartFileChangedWhileIndexing)
        #expect(controller.currentFrame == .animation(.indexing, index: 0))
        let didStartSuccessWhileIndexing = controller.playTransient(.success)
        #expect(!didStartSuccessWhileIndexing)
        #expect(controller.currentFrame == .animation(.indexing, index: 0))

        let didStartOptimizing = controller.setPersistentAnimation(.optimizing)
        #expect(didStartOptimizing)
        #expect(controller.currentFrame == .animation(.optimizing, index: 0))
        let didStartFileChangedWhileOptimizing = controller.playTransient(.fileChanged)
        #expect(!didStartFileChangedWhileOptimizing)
        #expect(controller.currentFrame == .animation(.optimizing, index: 0))
        let didStartErrorWhileOptimizing = controller.playTransient(.error)
        #expect(!didStartErrorWhileOptimizing)
        #expect(controller.currentFrame == .animation(.optimizing, index: 0))
    }

    @Test("animation controller promotes indexing and optimizing over active lower priority one shots")
    func animationControllerPromotesIndexingAndOptimizingOverActiveLowerPriorityOneShots() {
        var controller = OperationMascotAnimationController()

        let didStartFileChanged = controller.playTransient(.fileChanged)
        #expect(didStartFileChanged)
        #expect(controller.currentFrame == .animation(.fileChanged, index: 0))
        let didStartIndexing = controller.setPersistentAnimation(.indexing)
        #expect(didStartIndexing)
        #expect(controller.currentFrame == .animation(.indexing, index: 0))

        var optimizingController = OperationMascotAnimationController()
        let didStartSuccess = optimizingController.playTransient(.success)
        #expect(didStartSuccess)
        #expect(optimizingController.currentFrame == .animation(.success, index: 0))
        let didStartOptimizing = optimizingController.setPersistentAnimation(.optimizing)
        #expect(didStartOptimizing)
        #expect(optimizingController.currentFrame == .animation(.optimizing, index: 0))
    }

    @Test("coordinator renders first idle frame on initialization")
    @MainActor
    func coordinatorRendersFirstIdleFrameOnInitialization() throws {
        let spriteSheet = MascotSpriteSheet(resourceDirectoryURL: resourcesDirectoryURL())
        let imageView = NSImageView()

        _ = OperationMascotCoordinator(imageView: imageView, spriteSheet: spriteSheet)

        #expect(imageView.image != nil)
        #expect(imageView.accessibilityLabel() == OperationMascotAnimation.idle.accessibilityLabel)
    }

    @Test("runtime strips load all animation frames")
    @MainActor
    func runtimeStripsLoadAllAnimationFrames() throws {
        let sheet = MascotSpriteSheet(resourceDirectoryURL: resourcesDirectoryURL())
        let expectedFrameSize = NSSize(width: 160, height: 96)

        for animation in OperationMascotAnimation.allCases {
            #expect(sheet.loadedFrameCount(for: animation) == animation.frameCount)

            let first = try #require(sheet.frame(for: animation, index: 0))
            let wrapped = try #require(sheet.frame(for: animation, index: animation.frameCount))
            let negative = try #require(sheet.frame(for: animation, index: -1))

            #expect(first.isValid)
            #expect(wrapped.isValid)
            #expect(negative.isValid)
            #expect(first.size == expectedFrameSize)
            #expect(wrapped.size == expectedFrameSize)
            #expect(negative.size == expectedFrameSize)
        }

        for clip in OperationMascotIdleClip.allCases {
            #expect(sheet.loadedFrameCount(for: clip) == clip.frameCount)

            let first = try #require(sheet.frame(for: clip, index: 0))
            let wrapped = try #require(sheet.frame(for: clip, index: clip.frameCount))
            let negative = try #require(sheet.frame(for: clip, index: -1))

            #expect(first.isValid)
            #expect(wrapped.isValid)
            #expect(negative.isValid)
            #expect(first.size == expectedFrameSize)
            #expect(wrapped.size == expectedFrameSize)
            #expect(negative.size == expectedFrameSize)
        }

        for clip in OperationMascotStandaloneClip.allCases {
            #expect(sheet.loadedFrameCount(for: clip) == clip.frameCount)

            let first = try #require(sheet.frame(for: clip, index: 0))
            let wrapped = try #require(sheet.frame(for: clip, index: clip.frameCount))
            let negative = try #require(sheet.frame(for: clip, index: -1))

            #expect(first.isValid)
            #expect(wrapped.isValid)
            #expect(negative.isValid)
            #expect(first.size == expectedFrameSize)
            #expect(wrapped.size == expectedFrameSize)
            #expect(negative.size == expectedFrameSize)
        }
    }

    @Test("idle clip strips match fixed cell metadata")
    func idleClipStripsMatchFixedCellMetadata() throws {
        let cellWidth = 160
        let cellHeight = 96

        for clip in OperationMascotIdleClip.allCases {
            let url = try #require(idleClipURL(for: clip))
            let imageData = try Data(contentsOf: url)
            let bitmap = try #require(NSBitmapImageRep(data: imageData))

            #expect(bitmap.pixelsWide == cellWidth * clip.frameCount)
            #expect(bitmap.pixelsHigh == cellHeight)

            var bodyCenters: [Double] = []
            var bodyBottoms: [Int] = []
            for frame in 0..<clip.frameCount {
                let originX = frame * cellWidth
                let xRange = originX..<(originX + cellWidth)
                let yRange = 0..<cellHeight

                let bounds = try #require(visibleBounds(in: bitmap, xRange: xRange, yRange: yRange))
                #expect(bounds.minX > originX)
                #expect(bounds.minY > 0)
                #expect(bounds.maxX < originX + cellWidth - 1)
                #expect(bounds.maxY < cellHeight - 1)

                let bodyBounds = try #require(largestMascotBlueBounds(in: bitmap, xRange: xRange, yRange: yRange))
                let bodyWidth = bodyBounds.maxX - bodyBounds.minX + 1
                #expect(bodyWidth >= 69)
                #expect(bodyWidth <= 78)
                bodyCenters.append(Double(bodyBounds.minX + bodyBounds.maxX) / 2 - Double(originX))
                bodyBottoms.append(bodyBounds.maxY)
            }

            let minimumCenter = try #require(bodyCenters.min())
            let maximumCenter = try #require(bodyCenters.max())
            #expect(minimumCenter >= 79)
            #expect(maximumCenter <= 84)
            #expect(maximumCenter - minimumCenter <= 3)
            if clip == .antennaWiggle {
                #expect(maximumCenter == minimumCenter)
            }

            let minimumBottom = try #require(bodyBottoms.min())
            let maximumBottom = try #require(bodyBottoms.max())
            if [OperationMascotIdleClip.blink, .antennaWiggle].contains(clip) {
                #expect(maximumBottom == minimumBottom)
            } else if ![OperationMascotIdleClip.mainLoop, .victoryBounce].contains(clip) {
                #expect(maximumBottom - minimumBottom <= 1)
            }
        }
    }

    @Test("standalone strips match fixed cell metadata")
    func standaloneStripsMatchFixedCellMetadata() throws {
        let cellWidth = 160
        let cellHeight = 96

        for clip in OperationMascotStandaloneClip.allCases {
            let url = try #require(standaloneClipURL(for: clip))
            let imageData = try Data(contentsOf: url)
            let bitmap = try #require(NSBitmapImageRep(data: imageData))

            #expect(bitmap.pixelsWide == cellWidth * clip.frameCount)
            #expect(bitmap.pixelsHigh == cellHeight)

            var bodyCenters: [Double] = []
            var bodyWidths: [Int] = []
            for frame in 0..<clip.frameCount {
                let originX = frame * cellWidth
                let xRange = originX..<(originX + cellWidth)
                let yRange = 0..<cellHeight

                let bounds = try #require(visibleBounds(in: bitmap, xRange: xRange, yRange: yRange))
                #expect(bounds.minX > originX)
                #expect(bounds.minY > 0)
                #expect(bounds.maxX < originX + cellWidth - 1)
                #expect(bounds.maxY < cellHeight - 1)

                let bodyBounds = try #require(largestMascotBlueBounds(in: bitmap, xRange: xRange, yRange: yRange))
                let bodyWidth = bodyBounds.maxX - bodyBounds.minX + 1
                bodyWidths.append(bodyWidth)
                bodyCenters.append(Double(bodyBounds.minX + bodyBounds.maxX) / 2 - Double(originX))
            }

            let medianWidth = try #require(median(bodyWidths))
            #expect(medianWidth >= 69)
            #expect(medianWidth <= 78)

            let minimumCenter = try #require(bodyCenters.min())
            let maximumCenter = try #require(bodyCenters.max())
            #expect(minimumCenter >= 79)
            #expect(maximumCenter <= 84)
            #expect(maximumCenter - minimumCenter <= 3)

            if clip.loops {
                let firstBody = try #require(largestMascotBlueBounds(in: bitmap, xRange: 0..<cellWidth, yRange: 0..<cellHeight))
                let lastOriginX = (clip.frameCount - 1) * cellWidth
                let lastBody = try #require(largestMascotBlueBounds(
                    in: bitmap,
                    xRange: lastOriginX..<(lastOriginX + cellWidth),
                    yRange: 0..<cellHeight
                ))
                let firstCenter = Double(firstBody.minX + firstBody.maxX) / 2
                let lastCenter = Double(lastBody.minX + lastBody.maxX) / 2 - Double(lastOriginX)
                #expect(abs(firstCenter - lastCenter) <= 1)
                #expect(abs((firstBody.maxY - firstBody.minY) - (lastBody.maxY - lastBody.minY)) <= 1)
            }
        }
    }

    @Test("operation strips keep transparent gutters")
    func operationStripsKeepTransparentGutters() throws {
        let cellWidth = 160
        let cellHeight = 96

        for animation in OperationMascotAnimation.allCases {
            let bitmap = try operationBitmap(for: animation)
            #expect(bitmap.pixelsWide == cellWidth * animation.frameCount)
            #expect(bitmap.pixelsHigh == cellHeight)

            for frame in 0..<animation.frameCount {
                let originX = frame * cellWidth
                let bounds = try #require(visibleBounds(
                    in: bitmap,
                    xRange: originX..<(originX + cellWidth),
                    yRange: 0..<cellHeight
                ))

                #expect(bounds.minX > originX)
                #expect(bounds.minY > 0)
                #expect(bounds.maxX < originX + cellWidth - 1)
                #expect(bounds.maxY < cellHeight - 1)
            }
        }
    }

    @Test("operation strips keep consistent mascot scale")
    func operationStripsKeepConsistentMascotScale() throws {
        let cellWidth = 160
        let cellHeight = 96

        for animation in OperationMascotAnimation.allCases {
            let bitmap = try operationBitmap(for: animation)
            var frameHeights: [Int] = []
            for frame in 0..<animation.frameCount {
                let originX = frame * cellWidth
                guard let bounds = visibleBounds(
                    in: bitmap,
                    xRange: originX..<(originX + cellWidth),
                    yRange: 0..<cellHeight
                ) else {
                    continue
                }

                frameHeights.append(bounds.maxY - bounds.minY + 1)
            }

            let medianHeight = try #require(median(frameHeights))
            #expect(medianHeight >= 78)
        }
    }

    @Test("operation strips keep consistent mascot body width")
    func operationStripsKeepConsistentMascotBodyWidth() throws {
        let cellWidth = 160
        let cellHeight = 96

        for animation in OperationMascotAnimation.allCases {
            let bitmap = try operationBitmap(for: animation)
            var bodyWidths: [Int] = []
            for frame in 0..<animation.frameCount {
                let originX = frame * cellWidth
                guard let bounds = largestMascotBlueBounds(
                    in: bitmap,
                    xRange: originX..<(originX + cellWidth),
                    yRange: 0..<cellHeight
                ) else {
                    continue
                }

                bodyWidths.append(bounds.maxX - bounds.minX + 1)
            }

            let medianWidth = try #require(median(bodyWidths))
            #expect(medianWidth >= 69)
            #expect(medianWidth <= 78)
        }
    }

    @Test("operation strips keep mascot body horizontally registered")
    func operationStripsKeepMascotBodyHorizontallyRegistered() throws {
        let cellWidth = 160
        let cellHeight = 96

        for animation in OperationMascotAnimation.allCases {
            let bitmap = try operationBitmap(for: animation)
            var bodyCenters: [Double] = []
            for frame in 0..<animation.frameCount {
                let originX = frame * cellWidth
                guard let bounds = largestMascotBlueBounds(
                    in: bitmap,
                    xRange: originX..<(originX + cellWidth),
                    yRange: 0..<cellHeight
                ) else {
                    continue
                }

                bodyCenters.append(Double(bounds.minX + bounds.maxX) / 2 - Double(originX))
            }

            let minimumCenter = try #require(bodyCenters.min())
            let maximumCenter = try #require(bodyCenters.max())
            #expect(minimumCenter >= 79)
            #expect(maximumCenter <= 84)
            #expect(maximumCenter - minimumCenter <= 3)
        }
    }

    private func resourcesDirectoryURL() -> URL? {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
    }

    private func idleClipURL(for clip: OperationMascotIdleClip) -> URL? {
        resourcesDirectoryURL()?
            .appendingPathComponent("\(clip.resourceName).png", isDirectory: false)
    }

    private func operationStripURL(for animation: OperationMascotAnimation) -> URL? {
        resourcesDirectoryURL()?
            .appendingPathComponent("\(animation.resourceName).png", isDirectory: false)
    }

    private func standaloneClipURL(for clip: OperationMascotStandaloneClip) -> URL? {
        resourcesDirectoryURL()?
            .appendingPathComponent("\(clip.resourceName).png", isDirectory: false)
    }

    private func operationBitmap(for animation: OperationMascotAnimation) throws -> NSBitmapImageRep {
        let url = try #require(operationStripURL(for: animation))
        let imageData = try Data(contentsOf: url)
        return try #require(NSBitmapImageRep(data: imageData))
    }

    private func visibleBounds(
        in bitmap: NSBitmapImageRep,
        xRange: Range<Int>,
        yRange: Range<Int>
    ) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = Int.max
        var minY = Int.max
        var maxX = Int.min
        var maxY = Int.min

        for y in yRange {
            for x in xRange {
                guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.03 else {
                    continue
                }

                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard minX <= maxX, minY <= maxY else {
            return nil
        }

        return (minX, minY, maxX, maxY)
    }

    private func largestMascotBlueBounds(
        in bitmap: NSBitmapImageRep,
        xRange: Range<Int>,
        yRange: Range<Int>
    ) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        let width = xRange.count
        let height = yRange.count
        var bluePixels = Array(repeating: false, count: width * height)

        for y in yRange {
            for x in xRange {
                guard
                    let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                    isMascotBlue(color)
                else {
                    continue
                }

                bluePixels[(y - yRange.lowerBound) * width + (x - xRange.lowerBound)] = true
            }
        }

        var visited = Array(repeating: false, count: bluePixels.count)
        var largestBounds: (area: Int, minX: Int, minY: Int, maxX: Int, maxY: Int)?

        for start in bluePixels.indices {
            guard bluePixels[start], !visited[start] else {
                visited[start] = true
                continue
            }

            var stack = [start]
            visited[start] = true
            var area = 0
            var minX = start % width
            var maxX = minX
            var minY = start / width
            var maxY = minY

            while let index = stack.popLast() {
                area += 1
                let x = index % width
                let y = index / width
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)

                for nextY in max(0, y - 1)...min(height - 1, y + 1) {
                    for nextX in max(0, x - 1)...min(width - 1, x + 1) {
                        guard nextX != x || nextY != y else { continue }

                        let nextIndex = nextY * width + nextX
                        guard !visited[nextIndex] else { continue }

                        visited[nextIndex] = true
                        if bluePixels[nextIndex] {
                            stack.append(nextIndex)
                        }
                    }
                }
            }

            if largestBounds == nil || area > largestBounds!.area {
                largestBounds = (area, minX, minY, maxX, maxY)
            }
        }

        guard let largestBounds else {
            return nil
        }

        return (
            xRange.lowerBound + largestBounds.minX,
            yRange.lowerBound + largestBounds.minY,
            xRange.lowerBound + largestBounds.maxX,
            yRange.lowerBound + largestBounds.maxY
        )
    }

    private func isMascotBlue(_ color: NSColor) -> Bool {
        let red = color.redComponent
        let green = color.greenComponent
        let blue = color.blueComponent
        let alpha = color.alphaComponent

        guard alpha > 0.03 else { return false }

        return (blue >= 0.47 && green >= 0.31 && red <= 0.57 && blue >= red + 0.10 && green >= red + 0.04)
            || (green >= 0.57 && blue >= 0.57 && red <= 0.47)
    }

    private func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sortedValues = values.sorted()
        return sortedValues[sortedValues.count / 2]
    }
}
