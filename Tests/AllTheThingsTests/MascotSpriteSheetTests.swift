@testable import AllTheThings
import AppKit
import Foundation
import Testing

@Suite("Mascot sprite sheet")
struct MascotSpriteSheetTests {
    @Test("animation metadata matches sprite sheet rows")
    @MainActor
    func animationMetadataMatchesSpriteSheetRows() {
        #expect(OperationMascotAnimation.idle.row == 0)
        #expect(OperationMascotAnimation.indexing.row == 1)
        #expect(OperationMascotAnimation.searching.row == 2)
        #expect(OperationMascotAnimation.optimizing.row == 3)
        #expect(OperationMascotAnimation.fileChanged.row == 4)
        #expect(OperationMascotAnimation.success.row == 5)
        #expect(OperationMascotAnimation.error.row == 6)

        #expect(OperationMascotAnimation.idle.frameCount == 8)
        #expect(OperationMascotAnimation.indexing.frameCount == 16)
        #expect(OperationMascotAnimation.searching.frameCount == 10)
        #expect(OperationMascotAnimation.optimizing.frameCount == 16)
        #expect(OperationMascotAnimation.fileChanged.frameCount == 6)
        #expect(OperationMascotAnimation.success.frameCount == 8)
        #expect(OperationMascotAnimation.error.frameCount == 6)

        #expect(OperationMascotAnimation.idle.framesPerSecond == 4)
        #expect(OperationMascotAnimation.indexing.framesPerSecond == 5)
        #expect(OperationMascotAnimation.searching.framesPerSecond == 5)
        #expect(OperationMascotAnimation.optimizing.framesPerSecond == 5)
        #expect(OperationMascotAnimation.fileChanged.framesPerSecond == 6)
        #expect(OperationMascotAnimation.success.framesPerSecond == 6)
        #expect(OperationMascotAnimation.error.framesPerSecond == 5)

        for animation in OperationMascotAnimation.allCases {
            #expect(!animation.accessibilityLabel.isEmpty)
            #expect(animation.framesPerSecond > 0)
            #expect(animation.framesPerSecond <= 6)
        }

        #expect(OperationMascotCoordinator.layoutSize == 40)
        #expect(OperationMascotCoordinator.statusDisplaySize == OperationMascotCoordinator.layoutSize)
        #expect(OperationMascotCoordinator.heroDisplaySize == 86)
        #expect(OperationMascotCoordinator.heroDisplaySize > OperationMascotCoordinator.layoutSize * 2)
        #expect(OperationMascotCoordinator.expandedDisplaySize == OperationMascotCoordinator.layoutSize * 4)
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
            #expect(clip.frameCount == clip.fallbackFrameIndices.count)
            #expect(clip.framesPerSecond > 0)
            #expect(clip.framesPerSecond <= 5)
            #expect(!(clip.isFidget && clip.isFlourish))
            #expect(clip.idleSelectionWeight > 0)

            for index in clip.fallbackFrameIndices {
                #expect(index >= 0)
                #expect(index < OperationMascotAnimation.idle.frameCount)
            }
        }

        #expect(OperationMascotIdleClip.mainLoop.idleSelectionWeight > fidgets.map(\.idleSelectionWeight).reduce(0, +))
        #expect(flourishes.allSatisfy { $0.idleSelectionWeight < OperationMascotIdleClip.blink.idleSelectionWeight })
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

    @Test("coordinator renders first idle frame on initialization")
    @MainActor
    func coordinatorRendersFirstIdleFrameOnInitialization() throws {
        let spriteSheet = MascotSpriteSheet(
            imageURL: try #require(spriteSheetURL()),
            idleClipDirectoryURL: resourcesDirectoryURL()
        )
        let imageView = NSImageView()

        _ = OperationMascotCoordinator(imageView: imageView, spriteSheet: spriteSheet)

        #expect(imageView.image != nil)
        #expect(imageView.accessibilityLabel() == OperationMascotAnimation.idle.accessibilityLabel)
    }

    @Test("sprite sheet slices all animation frames")
    @MainActor
    func spriteSheetSlicesAllAnimationFrames() throws {
        let url = try #require(spriteSheetURL())
        let sheet = MascotSpriteSheet(imageURL: url)
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

    @Test("sprite frames keep transparent gutters")
    func spriteFramesKeepTransparentGutters() throws {
        let url = try #require(spriteSheetURL())
        let imageData = try Data(contentsOf: url)
        let bitmap = try #require(NSBitmapImageRep(data: imageData))

        let cellWidth = 160
        let cellHeight = 96
        #expect(bitmap.pixelsWide == cellWidth * 16)
        #expect(bitmap.pixelsHigh == cellHeight * 7)

        for animation in OperationMascotAnimation.allCases {
            for frame in 0..<animation.frameCount {
                let originX = frame * cellWidth
                let originY = animation.row * cellHeight
                let bbox = visibleBounds(
                    in: bitmap,
                    xRange: originX..<(originX + cellWidth),
                    yRange: originY..<(originY + cellHeight)
                )

                let bounds = try #require(bbox)
                #expect(bounds.minX > originX)
                #expect(bounds.minY > originY)
                #expect(bounds.maxX < originX + cellWidth - 1)
                #expect(bounds.maxY < originY + cellHeight - 1)
            }
        }
    }

    @Test("animation rows keep consistent mascot scale")
    func animationRowsKeepConsistentMascotScale() throws {
        let url = try #require(spriteSheetURL())
        let imageData = try Data(contentsOf: url)
        let bitmap = try #require(NSBitmapImageRep(data: imageData))

        let cellWidth = 160
        let cellHeight = 96

        for animation in OperationMascotAnimation.allCases {
            var frameHeights: [Int] = []
            for frame in 0..<animation.frameCount {
                let originX = frame * cellWidth
                let originY = animation.row * cellHeight
                guard let bounds = visibleBounds(
                    in: bitmap,
                    xRange: originX..<(originX + cellWidth),
                    yRange: originY..<(originY + cellHeight)
                ) else {
                    continue
                }

                frameHeights.append(bounds.maxY - bounds.minY + 1)
            }

            let medianHeight = try #require(median(frameHeights))
            #expect(medianHeight >= 78)
        }
    }

    @Test("animation rows keep consistent mascot body width")
    func animationRowsKeepConsistentMascotBodyWidth() throws {
        let url = try #require(spriteSheetURL())
        let imageData = try Data(contentsOf: url)
        let bitmap = try #require(NSBitmapImageRep(data: imageData))

        let cellWidth = 160
        let cellHeight = 96

        for animation in OperationMascotAnimation.allCases {
            var bodyWidths: [Int] = []
            for frame in 0..<animation.frameCount {
                let originX = frame * cellWidth
                let originY = animation.row * cellHeight
                guard let bounds = largestMascotBlueBounds(
                    in: bitmap,
                    xRange: originX..<(originX + cellWidth),
                    yRange: originY..<(originY + cellHeight)
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

    @Test("animation frames keep mascot body horizontally registered")
    func animationFramesKeepMascotBodyHorizontallyRegistered() throws {
        let url = try #require(spriteSheetURL())
        let imageData = try Data(contentsOf: url)
        let bitmap = try #require(NSBitmapImageRep(data: imageData))

        let cellWidth = 160
        let cellHeight = 96

        for animation in OperationMascotAnimation.allCases {
            var bodyCenters: [Double] = []
            for frame in 0..<animation.frameCount {
                let originX = frame * cellWidth
                let originY = animation.row * cellHeight
                guard let bounds = largestMascotBlueBounds(
                    in: bitmap,
                    xRange: originX..<(originX + cellWidth),
                    yRange: originY..<(originY + cellHeight)
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

    private func spriteSheetURL() -> URL? {
        resourcesDirectoryURL()?
            .appendingPathComponent("NibGeneratedMasterSheet.png", isDirectory: false)
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
