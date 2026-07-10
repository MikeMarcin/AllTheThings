import AppKit
import ATTCore

private enum InsightsEnergyHoverTarget: Equatable {
    case sample(Int)
    case rollup(Int)
    case day(Int)
}

final class InsightsEnergyChartView: NSView {
    var usage = IndexUsageMetrics() {
        didSet {
            refreshHoverAfterContentUpdate()
            needsDisplay = true
        }
    }

    var range: InsightsEnergyRange = .hour {
        didSet {
            hoveredTarget = nil
            hoverPoint = nil
            InsightsHoverCard.hide(from: self)
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    private var trackingArea: NSTrackingArea?
    private var hoveredTarget: InsightsEnergyHoverTarget?
    private var hoverPoint: NSPoint?

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point)
        updateHoverCard()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredTarget = nil
        hoverPoint = nil
        InsightsHoverCard.hide(from: self)
        needsDisplay = true
    }

    private func refreshHoverAfterContentUpdate() {
        guard
            let hoverPoint,
            bounds.contains(hoverPoint),
            window?.isKeyWindow != false
        else {
            hoveredTarget = nil
            self.hoverPoint = nil
            InsightsHoverCard.hide(from: self)
            return
        }

        updateHover(at: hoverPoint)
        updateHoverCard()
    }

    private func updateHover(at point: NSPoint) {
        hoverPoint = point
        switch range {
        case .hour:
            let samples = recentSamples()
            hoveredTarget = InsightsEnergyTimelineLayout.sampleIndex(at: point, samples: samples, in: bounds)
                .map(InsightsEnergyHoverTarget.sample)
        case .day:
            let rollups = recentRollups()
            hoveredTarget = InsightsEnergyTimelineLayout.rollupIndex(at: point, rollups: rollups, in: bounds)
                .map(InsightsEnergyHoverTarget.rollup)
        case .calendar:
            let buckets = usage.dailyBuckets
            let grid = InsightsEnergyCalendarLayout.layout(buckets: buckets, in: bounds)
            hoveredTarget = InsightsEnergyCalendarLayout.itemIndex(at: point, in: grid.items)
                .map(InsightsEnergyHoverTarget.day)
        }
    }

    private func updateHoverCard() {
        guard let hoveredTarget, let hoverPoint else {
            InsightsHoverCard.hide(from: self)
            return
        }

        let lines: [String]
        switch hoveredTarget {
        case let .sample(index):
            let samples = recentSamples()
            guard index < samples.count else {
                InsightsHoverCard.hide(from: self)
                return
            }
            lines = placardLines(for: samples[index])
        case let .rollup(index):
            let rollups = recentRollups()
            guard index < rollups.count else {
                InsightsHoverCard.hide(from: self)
                return
            }
            lines = placardLines(for: rollups[index])
        case let .day(index):
            let buckets = usage.dailyBuckets
            guard index < buckets.count else {
                InsightsHoverCard.hide(from: self)
                return
            }
            lines = placardLines(for: buckets[index])
        }

        InsightsHoverCard.show(lines: lines, near: hoverPoint, from: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isDark = InsightsPanelPalette.isDarkAppearance(effectiveAppearance)
        InsightsPanelPalette.chartBackgroundColor(isDark: isDark).setFill()
        bounds.fill()

        switch range {
        case .hour:
            drawHour()
        case .day:
            drawDay()
        case .calendar:
            drawCalendar()
        }
    }

    private func drawHour() {
        let samples = recentSamples()
        guard samples.contains(where: { $0.cpuTime > 0 || $0.wakeups > 0 }) else {
            drawEmpty("No energy samples yet")
            return
        }

        let cpuPlot = InsightsEnergyTimelineLayout.cpuPlotRect(in: bounds)
        let wakeupsPlot = InsightsEnergyTimelineLayout.wakeupsPlotRect(in: bounds)
        let maxLoad = Self.cpuLoadScaleMaximum(samples.map(\.cpuLoad))
        let maxWakeups = maxWakeupsPerMinute(samples: samples)
        let rects = InsightsEnergyTimelineLayout.sampleRects(samples: samples, in: bounds)
        drawTimelineBackground(plot: cpuPlot, intermediateLineCount: 3)
        drawTimelineBackground(plot: wakeupsPlot, intermediateLineCount: 1)

        drawCategorizedCPULoad(samples: samples, slots: rects, maxLoad: maxLoad, plot: cpuPlot)
        drawWakeupBars(
            values: samples.map(\.wakeupsPerMinute),
            maxValue: maxWakeups,
            slots: rects,
            plot: wakeupsPlot
        )

        drawLegend(in: InsightsEnergyTimelineLayout.legendRect(in: bounds))
        drawHoverHighlight(rects: rects)
    }

    private func drawDay() {
        let rollups = recentRollups()
        guard rollups.contains(where: { $0.energy.total.cpuTime > 0 || $0.energy.total.wakeups > 0 }) else {
            drawEmpty("No day-scale energy samples yet")
            return
        }

        let cpuPlot = InsightsEnergyTimelineLayout.cpuPlotRect(in: bounds)
        let wakeupsPlot = InsightsEnergyTimelineLayout.wakeupsPlotRect(in: bounds)
        let maxLoad = Self.cpuLoadScaleMaximum(rollups.map { $0.energy.total.averageCPULoad })
        let maxWakeups = maxWakeupsPerMinute(rollups: rollups)
        let rects = InsightsEnergyTimelineLayout.rollupRects(rollups: rollups, in: bounds)
        drawTimelineBackground(plot: cpuPlot, intermediateLineCount: 3)
        drawTimelineBackground(plot: wakeupsPlot, intermediateLineCount: 1)

        let totalPoints = rollups.enumerated().compactMap { index, rollup -> NSPoint? in
            guard index < rects.count else { return nil }
            return timelinePoint(
                x: rects[index].midX,
                value: rollup.energy.total.averageCPULoad,
                maxValue: maxLoad,
                plot: cpuPlot
            )
        }
        let backgroundPoints = rollups.enumerated().compactMap { index, rollup -> NSPoint? in
            guard index < rects.count else { return nil }
            return timelinePoint(
                x: rects[index].midX,
                value: Self.backgroundCPULoadContribution(rollup.energy),
                maxValue: maxLoad,
                plot: cpuPlot
            )
        }

        drawStackedCPULoad(totalPoints: totalPoints, backgroundPoints: backgroundPoints, plot: cpuPlot)
        drawWakeupBars(
            values: rollups.map { $0.energy.total.wakeupsPerMinute },
            maxValue: maxWakeups,
            slots: rects,
            plot: wakeupsPlot
        )

        drawLegend(in: InsightsEnergyTimelineLayout.legendRect(in: bounds))
        drawHoverHighlight(rects: rects)
    }

    private func drawCalendar() {
        let buckets = usage.dailyBuckets
        let grid = InsightsEnergyCalendarLayout.layout(buckets: buckets, in: bounds)
        drawCalendarGrid(grid)
        let visibleBuckets = grid.items.compactMap { item -> DailyUsageBucket? in
            guard let bucketIndex = item.bucketIndex, bucketIndex < buckets.count else { return nil }
            return buckets[bucketIndex]
        }

        guard visibleBuckets.contains(where: { Self.calendarActivityScore($0) > 0 }) else {
            drawEmpty("No calendar activity yet")
            return
        }

        let activityScores = visibleBuckets.map(Self.calendarActivityScore).filter { $0 > 0 }
        let activityBaseline = Self.calendarActivityBaseline(scores: activityScores)
        let impactBuckets = visibleBuckets.filter { Self.backgroundEnergyImpactScore($0) > 0 }
        let maxBackgroundImpact = max(impactBuckets.map(Self.backgroundEnergyImpactScore).max() ?? 0, 0.001)
        let comparisonCount = impactBuckets.count

        for item in grid.items {
            guard let bucketIndex = item.bucketIndex, bucketIndex < buckets.count else { continue }
            let bucket = buckets[bucketIndex]
            let activity = Self.calendarActivityScore(bucket)
            guard activity > 0 else { continue }
            let radiusScale = Self.calendarRadiusScale(activity: activity, baseline: activityBaseline)
            let side = max(4, item.maximumRadius * 2 * radiusScale)
            Self.calendarColor(
                backgroundImpact: Self.backgroundEnergyImpactScore(bucket),
                maxBackgroundImpact: maxBackgroundImpact,
                comparisonCount: comparisonCount
            ).setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: item.center.x - side / 2,
                    y: item.center.y - side / 2,
                    width: side,
                    height: side
                )
            ).fill()
        }

        if
            case let .day(index) = hoveredTarget,
            let item = grid.items.first(where: { $0.bucketIndex == index })
        {
            NSColor.labelColor.withAlphaComponent(0.24).setStroke()
            let path = NSBezierPath(roundedRect: item.cellRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawCalendarGrid(_ grid: InsightsEnergyCalendarGrid) {
        let isDark = InsightsPanelPalette.isDarkAppearance(effectiveAppearance)
        let cellFill = isDark
            ? NSColor.white.withAlphaComponent(0.045)
            : NSColor.black.withAlphaComponent(0.045)
        let separatorColor = isDark
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.12)
        let labelColor = NSColor.secondaryLabelColor
        let monthAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: labelColor
        ]
        let weekdayAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: labelColor
        ]

        for label in grid.monthLabels {
            label.title.draw(in: label.rect, withAttributes: monthAttributes)
        }

        for label in grid.weekdayLabels {
            label.title.draw(in: label.rect, withAttributes: weekdayAttributes)
        }

        cellFill.setFill()
        for item in grid.items {
            NSBezierPath(roundedRect: item.cellRect, xRadius: 3, yRadius: 3).fill()
        }

        separatorColor.setStroke()
        for separator in grid.monthSeparators {
            let path = NSBezierPath()
            path.lineWidth = 1
            path.lineCapStyle = .round
            path.move(to: separator.start)
            path.line(to: separator.end)
            path.stroke()
        }
    }

    private func drawTimelineBackground(plot: NSRect, intermediateLineCount: Int) {
        NSColor.separatorColor.withAlphaComponent(0.25).setStroke()
        NSBezierPath(rect: plot).stroke()
        NSColor.separatorColor.withAlphaComponent(0.14).setStroke()
        guard intermediateLineCount > 0 else { return }
        for index in 1...intermediateLineCount {
            let fraction = CGFloat(index) / CGFloat(intermediateLineCount + 1)
            let y = plot.minY + plot.height * fraction
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: NSPoint(x: plot.minX, y: y))
            path.line(to: NSPoint(x: plot.maxX, y: y))
            path.stroke()
        }
    }

    private func timelinePoint(x: CGFloat, value: Double, maxValue: Double, plot: NSRect) -> NSPoint? {
        guard value.isFinite, maxValue > 0, plot.width > 0, plot.height > 0 else { return nil }
        let fraction = min(max(value / maxValue, 0), 1)
        return NSPoint(x: x, y: plot.maxY - CGFloat(fraction) * plot.height)
    }

    private func drawCategorizedCPULoad(
        samples: [EnergyUsageIntervalSample],
        slots: [NSRect],
        maxLoad: Double,
        plot: NSRect
    ) {
        guard samples.count == slots.count else { return }
        let points = InsightsEnergyTimelineLayout.cpuLoadPoints(
            loads: samples.map(\.cpuLoad),
            maxLoad: maxLoad,
            slots: slots,
            plot: plot
        )
        guard !points.isEmpty else { return }
        let baseline = points.map { NSPoint(x: $0.x, y: plot.maxY) }

        for (sample, slot) in zip(samples, slots) {
            let clipRect = slot.intersection(plot)
            guard !clipRect.isEmpty else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: clipRect).addClip()
            drawArea(
                upperPoints: points,
                lowerPoints: baseline,
                color: Self.fillColor(for: sample.mode)
            )
            drawLine(points: points, color: Self.color(for: sample.mode), lineWidth: 1.5)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawStackedCPULoad(totalPoints: [NSPoint], backgroundPoints: [NSPoint], plot: NSRect) {
        guard totalPoints.count == backgroundPoints.count else { return }
        let totalPoints = expandedSinglePointSeries(totalPoints, in: plot)
        let backgroundPoints = expandedSinglePointSeries(backgroundPoints, in: plot)
        let baseline = totalPoints.map { NSPoint(x: $0.x, y: plot.maxY) }
        drawArea(
            upperPoints: backgroundPoints,
            lowerPoints: baseline,
            color: Self.fillColor(for: .background)
        )
        drawArea(
            upperPoints: totalPoints,
            lowerPoints: backgroundPoints,
            color: Self.fillColor(for: .foreground)
        )
        drawBackgroundOutline(points: backgroundPoints, baselineY: plot.maxY)
        drawCPUOutline(totalPoints: totalPoints, backgroundPoints: backgroundPoints)
    }

    private func expandedSinglePointSeries(_ points: [NSPoint], in plot: NSRect) -> [NSPoint] {
        guard let point = points.first, points.count == 1 else { return points }
        return [
            NSPoint(x: max(plot.minX, point.x - 1.5), y: point.y),
            NSPoint(x: min(plot.maxX, point.x + 1.5), y: point.y)
        ]
    }

    private func drawCPUOutline(totalPoints: [NSPoint], backgroundPoints: [NSPoint]) {
        guard totalPoints.count == backgroundPoints.count else { return }
        drawLineRuns(points: totalPoints) { index in
            let previousHasForegroundLoad = totalPoints[index - 1].y < backgroundPoints[index - 1].y - 0.5
            let currentHasForegroundLoad = totalPoints[index].y < backgroundPoints[index].y - 0.5
            return previousHasForegroundLoad || currentHasForegroundLoad ? .foreground : .background
        }
    }

    private func drawBackgroundOutline(points: [NSPoint], baselineY: CGFloat) {
        drawLineRuns(points: points) { index in
            let previousHasBackgroundLoad = points[index - 1].y < baselineY - 0.5
            let currentHasBackgroundLoad = points[index].y < baselineY - 0.5
            return previousHasBackgroundLoad && currentHasBackgroundLoad ? .background : nil
        }
    }

    private func drawLineRuns(
        points: [NSPoint],
        modeForSegment: (Int) -> EnergyUsageMode?
    ) {
        guard points.count > 1 else { return }
        var runStart: Int?
        var runMode: EnergyUsageMode?

        for index in 1..<points.count {
            let mode = modeForSegment(index)
            guard mode != runMode else { continue }
            if let runStart, let runMode {
                drawLine(
                    points: Array(points[runStart..<index]),
                    color: Self.color(for: runMode),
                    lineWidth: 1.5
                )
            }
            runStart = mode == nil ? nil : index - 1
            runMode = mode
        }

        if let runStart, let runMode {
            drawLine(
                points: Array(points[runStart...]),
                color: Self.color(for: runMode),
                lineWidth: 1.5
            )
        }
    }

    private func drawArea(upperPoints: [NSPoint], lowerPoints: [NSPoint], color: NSColor) {
        guard !upperPoints.isEmpty, upperPoints.count == lowerPoints.count else { return }
        let path = NSBezierPath()
        path.move(to: upperPoints[0])
        for point in upperPoints.dropFirst() {
            path.line(to: point)
        }
        for point in lowerPoints.reversed() {
            path.line(to: point)
        }
        path.close()
        color.setFill()
        path.fill()
    }

    private func drawWakeupBars(values: [Double], maxValue: Double, slots: [NSRect], plot: NSRect) {
        guard values.count == slots.count, maxValue > 0, plot.height > 0 else { return }
        NSColor.systemRed.withAlphaComponent(0.72).setFill()
        for (value, slot) in zip(values, slots) where value.isFinite && value > 0 {
            let fraction = min(max(value / maxValue, 0), 1)
            let height = max(1, CGFloat(fraction) * plot.height)
            let horizontalInset = min(1, max(0, slot.width * 0.12))
            let bar = NSRect(
                x: slot.minX + horizontalInset,
                y: plot.maxY - height,
                width: max(1, slot.width - horizontalInset * 2),
                height: height
            ).intersection(plot)
            NSBezierPath(roundedRect: bar, xRadius: min(1.5, bar.width / 2), yRadius: 1.5).fill()
        }
    }

    private func drawLine(points: [NSPoint], color: NSColor, lineWidth: CGFloat) {
        guard !points.isEmpty else { return }
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.stroke()
    }

    private func drawHoverHighlight(rects: [NSRect]) {
        let index: Int?
        switch hoveredTarget {
        case let .sample(value):
            index = value
        case let .rollup(value):
            index = value
        case .day, nil:
            index = nil
        }
        guard let index, index < rects.count else { return }
        let rect = rects[index]
        NSColor.labelColor.withAlphaComponent(0.18).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: rect.midX, y: rect.minY))
        path.line(to: NSPoint(x: rect.midX, y: rect.maxY))
        path.stroke()
    }

    private func drawLegend(in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let items: [(String, NSColor)] = [
            ("Foreground CPU", Self.color(for: .foreground)),
            ("Background CPU", Self.color(for: .background)),
            ("Wakeups / Min", .systemRed.withAlphaComponent(0.72))
        ]
        var x = rect.minX
        for item in items {
            item.1.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: x, y: rect.minY + 7))
            path.line(to: NSPoint(x: x + 10, y: rect.minY + 7))
            path.stroke()
            x += 14
            item.0.draw(at: NSPoint(x: x, y: rect.minY), withAttributes: attributes)
            x += item.0.size(withAttributes: attributes).width + 14
        }
    }

    private func drawEmpty(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func recentSamples() -> [EnergyUsageIntervalSample] {
        let referenceDate = usage.recentEnergySamples.last?.completedAt ?? Date()
        let cutoff = referenceDate.addingTimeInterval(-60 * 60)
        return usage.recentEnergySamples.filter { $0.completedAt >= cutoff }
    }

    private func recentRollups() -> [EnergyUsageRollup] {
        let referenceDate = usage.energyRollups.last?.bucketStart.addingTimeInterval(IndexUsageMetrics.energyRollupInterval) ?? Date()
        let cutoff = referenceDate.addingTimeInterval(-24 * 60 * 60)
        return usage.energyRollups.filter { $0.bucketStart >= cutoff }
    }

    private func maxWakeupsPerMinute(samples: [EnergyUsageIntervalSample]) -> Double {
        max(samples.map(\.wakeupsPerMinute).max() ?? 0, 0.001)
    }

    private func maxWakeupsPerMinute(rollups: [EnergyUsageRollup]) -> Double {
        max(rollups.map { $0.energy.total.wakeupsPerMinute }.max() ?? 0, 0.001)
    }

    private func placardLines(for sample: EnergyUsageIntervalSample) -> [String] {
        [
            dateTimeString(sample.completedAt),
            "\(modeTitle(sample.mode)) · \(cpuLoadString(sample.cpuLoad)) load",
            "\(durationString(sample.cpuTime)) CPU over \(durationString(sample.duration))",
            "\(wakeupsPerMinuteString(sample.wakeupsPerMinute)) · \(sample.wakeups.formatted()) wakeups"
        ]
    }

    private func placardLines(for rollup: EnergyUsageRollup) -> [String] {
        let total = rollup.energy.total
        return [
            dateTimeString(rollup.bucketStart),
            "\(cpuLoadString(total.averageCPULoad)) average CPU load",
            "\(durationString(rollup.energy.foreground.cpuTime)) foreground CPU",
            "\(durationString(rollup.energy.background.cpuTime)) background CPU",
            "\(wakeupsPerMinuteString(total.wakeupsPerMinute)) · \(total.wakeups.formatted()) wakeups"
        ]
    }

    private func placardLines(for bucket: DailyUsageBucket) -> [String] {
        let total = bucket.energy.total
        let background = bucket.energy.background
        let components = bucket.calendarActivityScoreComponents
        return [
            bucket.day,
            "Activity\t\(scoreString(components.total))",
            "Background Impact\t\(scoreString(bucket.backgroundEnergyImpactScore))",
            "",
            "Search\t\(scoreString(components.search))",
            "Index\t\(scoreString(components.index))",
            "Refresh\t\(scoreString(components.refresh))",
            "",
            "Background CPU\t\(durationString(background.cpuTime))",
            "Background Wakeups\t\(wakeupsPerMinuteString(background.wakeupsPerMinute))",
            "Total CPU\t\(durationString(total.cpuTime))",
            "Average Load\t\(cpuLoadString(total.averageCPULoad))",
            "Foreground CPU\t\(durationString(bucket.energy.foreground.cpuTime))",
            "Background Share\t\(backgroundShareString(bucket.energy))"
        ]
    }

    private static func color(for mode: EnergyUsageMode) -> NSColor {
        switch mode {
        case .foreground:
            return .systemBlue.withAlphaComponent(0.78)
        case .background:
            return .systemOrange.withAlphaComponent(0.82)
        }
    }

    private static func fillColor(for mode: EnergyUsageMode) -> NSColor {
        color(for: mode).withAlphaComponent(0.28)
    }

    nonisolated static func calendarColor(
        backgroundImpact: Double,
        maxBackgroundImpact: Double,
        comparisonCount: Int
    ) -> NSColor {
        guard
            backgroundImpact.isFinite,
            backgroundImpact > 0,
            maxBackgroundImpact.isFinite,
            maxBackgroundImpact > 0
        else {
            return NSColor.systemGreen.withAlphaComponent(0.78)
        }

        let relativeImpact = min(max(backgroundImpact / maxBackgroundImpact, 0), 1)
        if comparisonCount < 3 {
            let blend = CGFloat(relativeImpact * 0.65)
            return blendedColor(from: .systemGreen, to: .systemYellow, fraction: blend).withAlphaComponent(0.84)
        }

        if relativeImpact < 0.55 {
            let blend = CGFloat(relativeImpact / 0.55)
            return blendedColor(from: .systemGreen, to: .systemYellow, fraction: blend).withAlphaComponent(0.84)
        }

        let blend = CGFloat((relativeImpact - 0.55) / 0.45)
        return blendedColor(from: .systemYellow, to: .systemRed, fraction: blend).withAlphaComponent(0.84)
    }

    nonisolated static func calendarActivityScore(_ bucket: DailyUsageBucket) -> Double {
        bucket.calendarActivityScore
    }

    nonisolated static func backgroundEnergyImpactScore(_ bucket: DailyUsageBucket) -> Double {
        bucket.backgroundEnergyImpactScore
    }

    nonisolated static func cpuLoadScaleMaximum(_ values: [Double]) -> Double {
        max(values.filter { $0.isFinite && $0 > 0 }.max() ?? 0, 1)
    }

    nonisolated static func backgroundCPULoadContribution(_ energy: EnergyUsageBreakdown) -> Double {
        let totalWallTime = energy.total.wallTime
        guard totalWallTime > 0 else { return 0 }
        return energy.background.cpuTime / totalWallTime
    }

    nonisolated static func calendarActivityBaseline(scores: [Double]) -> Double {
        let sortedScores = scores.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !sortedScores.isEmpty else { return 0 }
        let percentileIndex = max(0, Int(ceil(Double(sortedScores.count) * 0.9)) - 1)
        return sortedScores[min(percentileIndex, sortedScores.count - 1)]
    }

    nonisolated static func calendarRadiusScale(activity: Double, baseline: Double) -> CGFloat {
        guard activity.isFinite, activity > 0, baseline.isFinite, baseline > 0 else { return 0 }
        return max(0.16, sqrt(CGFloat(min(max(activity / baseline, 0), 1))))
    }

    private nonisolated static func blendedColor(from start: NSColor, to end: NSColor, fraction: CGFloat) -> NSColor {
        let clamped = min(max(fraction, 0), 1)
        return start.blended(withFraction: clamped, of: end) ?? start
    }

    private func modeTitle(_ mode: EnergyUsageMode) -> String {
        switch mode {
        case .foreground:
            return "Foreground"
        case .background:
            return "Background"
        }
    }

    private func durationString(_ duration: TimeInterval) -> String {
        if duration <= 0 {
            return "0 ms"
        }
        if duration < 1 {
            return "\(Int((duration * 1_000).rounded())) ms"
        }
        return String(format: "%.2f s", duration)
    }

    private func cpuLoadString(_ load: Double) -> String {
        guard load.isFinite, load > 0 else { return "0%" }
        let percent = load * 100
        if percent < 10 {
            return String(format: "%.1f%%", percent)
        }
        return "\(Int(percent.rounded()))%"
    }

    private func wakeupsPerMinuteString(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0/min" }
        if value < 10 {
            return String(format: "%.1f/min", value)
        }
        return "\(Int(value.rounded()).formatted())/min"
    }

    private func scoreString(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0.0" }
        return String(format: "%.1f", value)
    }

    private func backgroundShareString(_ energy: EnergyUsageBreakdown) -> String {
        let totalCPU = energy.total.cpuTime
        guard totalCPU > 0 else { return "0%" }
        return cpuLoadString(energy.background.cpuTime / totalCPU)
    }

    private func dateTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct InsightsEnergyCalendarItem: Equatable {
    let index: Int
    let day: String
    let bucketIndex: Int?
    let cellRect: NSRect
    let center: NSPoint
    let maximumRadius: CGFloat
}

struct InsightsEnergyCalendarLabel: Equatable {
    let title: String
    let rect: NSRect
}

struct InsightsEnergyCalendarSeparator: Equatable {
    let start: NSPoint
    let end: NSPoint
}

struct InsightsEnergyCalendarGrid: Equatable {
    let items: [InsightsEnergyCalendarItem]
    let weekdayLabels: [InsightsEnergyCalendarLabel]
    let monthLabels: [InsightsEnergyCalendarLabel]
    let monthSeparators: [InsightsEnergyCalendarSeparator]
}

enum InsightsEnergyTimelineLayout {
    static let inset = NSEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
    static let legendHeight: CGFloat = 14
    static let legendGap: CGFloat = 8
    static let plotGap: CGFloat = 8
    static let wakeupsPlotFraction: CGFloat = 0.25
    static let minimumSlotWidth: CGFloat = 2

    static func plotRect(in bounds: NSRect) -> NSRect {
        let content = bounds.insetBy(dx: inset.left, dy: 0)
        let bottomReserved = inset.bottom + legendHeight + legendGap
        return NSRect(
            x: content.minX,
            y: bounds.minY + inset.top,
            width: max(0, content.width),
            height: max(0, bounds.height - inset.top - bottomReserved)
        )
    }

    static func legendRect(in bounds: NSRect) -> NSRect {
        let plot = plotRect(in: bounds)
        return NSRect(
            x: plot.minX,
            y: plot.maxY + legendGap,
            width: plot.width,
            height: legendHeight
        )
    }

    static func cpuPlotRect(in bounds: NSRect) -> NSRect {
        let plot = plotRect(in: bounds)
        let availableHeight = max(0, plot.height - plotGap)
        let wakeupsHeight = floor(availableHeight * wakeupsPlotFraction)
        return NSRect(
            x: plot.minX,
            y: plot.minY,
            width: plot.width,
            height: max(0, availableHeight - wakeupsHeight)
        )
    }

    static func wakeupsPlotRect(in bounds: NSRect) -> NSRect {
        let plot = plotRect(in: bounds)
        let cpuPlot = cpuPlotRect(in: bounds)
        return NSRect(
            x: plot.minX,
            y: cpuPlot.maxY + plotGap,
            width: plot.width,
            height: max(0, plot.maxY - cpuPlot.maxY - plotGap)
        )
    }

    static func cpuLoadPoints(loads: [Double], maxLoad: Double, slots: [NSRect], plot: NSRect) -> [NSPoint] {
        guard
            loads.count == slots.count,
            !loads.isEmpty,
            maxLoad > 0,
            plot.width > 0,
            plot.height > 0
        else {
            return []
        }

        let samplePoints = zip(loads, slots).map { load, slot in
            let finiteLoad = load.isFinite ? load : 0
            let fraction = min(max(finiteLoad / maxLoad, 0), 1)
            return NSPoint(
                x: slot.midX,
                y: plot.maxY - CGFloat(fraction) * plot.height
            )
        }
        guard let first = samplePoints.first, let last = samplePoints.last else { return [] }
        return [NSPoint(x: slots[0].minX, y: first.y)]
            + samplePoints
            + [NSPoint(x: slots[slots.count - 1].maxX, y: last.y)]
    }

    static func sampleRects(samples: [EnergyUsageIntervalSample], in bounds: NSRect) -> [NSRect] {
        guard !samples.isEmpty else { return [] }
        let end = samples.last?.completedAt ?? Date()
        let start = end.addingTimeInterval(-60 * 60)
        return rects(
            count: samples.count,
            start: start,
            duration: 60 * 60,
            bounds: bounds
        ) { index in
            (samples[index].completedAt, max(samples[index].duration, 1))
        }
    }

    static func rollupRects(rollups: [EnergyUsageRollup], in bounds: NSRect) -> [NSRect] {
        guard !rollups.isEmpty else { return [] }
        let end = (rollups.last?.bucketStart ?? Date()).addingTimeInterval(IndexUsageMetrics.energyRollupInterval)
        let start = end.addingTimeInterval(-24 * 60 * 60)
        return rects(
            count: rollups.count,
            start: start,
            duration: 24 * 60 * 60,
            bounds: bounds
        ) { index in
            (rollups[index].bucketStart.addingTimeInterval(IndexUsageMetrics.energyRollupInterval), IndexUsageMetrics.energyRollupInterval)
        }
    }

    static func sampleIndex(at point: NSPoint, samples: [EnergyUsageIntervalSample], in bounds: NSRect) -> Int? {
        sampleRects(samples: samples, in: bounds)
            .lastIndex { $0.insetBy(dx: -2, dy: 0).contains(point) }
    }

    static func rollupIndex(at point: NSPoint, rollups: [EnergyUsageRollup], in bounds: NSRect) -> Int? {
        rollupRects(rollups: rollups, in: bounds)
            .lastIndex { $0.insetBy(dx: -2, dy: 0).contains(point) }
    }

    private static func rects(
        count: Int,
        start: Date,
        duration: TimeInterval,
        bounds: NSRect,
        values: (Int) -> (completedAt: Date, duration: TimeInterval)
    ) -> [NSRect] {
        let plot = plotRect(in: bounds)
        guard count > 0, duration > 0, plot.width > 0, plot.height > 0 else { return [] }
        return (0..<count).map { index in
            let value = values(index)
            let endOffset = value.completedAt.timeIntervalSince(start)
            let width = max(minimumSlotWidth, CGFloat(value.duration / duration) * plot.width)
            let x = plot.minX + CGFloat(endOffset / duration) * plot.width - width
            return NSRect(
                x: min(max(x, plot.minX), plot.maxX - minimumSlotWidth),
                y: plot.minY,
                width: min(max(width, minimumSlotWidth), plot.width),
                height: plot.height
            )
        }
    }
}

enum InsightsEnergyCalendarLayout {
    static let inset = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    static let monthLabelHeight: CGFloat = 22
    static let weekdayLabelWidth: CGFloat = 38
    static let weekdayGap: CGFloat = 8
    static let rows = 7
    static let displayedMonthCount = 3
    static let weekdayTitles = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    static func layout(
        buckets: [DailyUsageBucket],
        in bounds: NSRect,
        referenceDate: Date = Date()
    ) -> InsightsEnergyCalendarGrid {
        let calendar = gregorianCalendar()
        let datedBuckets = buckets.enumerated().compactMap { index, bucket -> (index: Int, bucket: DailyUsageBucket, date: Date)? in
            guard let date = date(from: bucket.day, calendar: calendar) else { return nil }
            return (index, bucket, date)
        }
        guard
            let monthStart = startOfMonth(containing: referenceDate, calendar: calendar),
            let firstMonthStart = calendar.date(
                byAdding: .month,
                value: -(displayedMonthCount - 1),
                to: monthStart
            ),
            let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart),
            let lastDay = calendar.date(byAdding: .day, value: -1, to: nextMonthStart)
        else {
            return InsightsEnergyCalendarGrid(items: [], weekdayLabels: [], monthLabels: [], monthSeparators: [])
        }

        let firstWeekStart = startOfWeek(containing: firstMonthStart, calendar: calendar)
        let columns = max(1, weekIndex(for: lastDay, from: firstWeekStart, calendar: calendar) + 1)

        let content = bounds.insetBy(dx: inset.left, dy: 0)
        let plot = NSRect(
            x: content.minX + weekdayLabelWidth + weekdayGap,
            y: bounds.minY + inset.top + monthLabelHeight,
            width: max(0, content.width - weekdayLabelWidth - weekdayGap),
            height: max(0, bounds.height - inset.top - inset.bottom - monthLabelHeight)
        )
        guard plot.width > 0, plot.height > 0 else {
            return InsightsEnergyCalendarGrid(items: [], weekdayLabels: [], monthLabels: [], monthSeparators: [])
        }

        let cellWidth = plot.width / CGFloat(columns)
        let cellHeight = plot.height / CGFloat(rows)
        let gap = max(1, min(4, min(cellWidth, cellHeight) * 0.14))
        let radius = max(1.5, min(cellWidth - gap, cellHeight - gap) * 0.34)
        let bucketIndexesByDay = Dictionary(uniqueKeysWithValues: datedBuckets.map { ($0.bucket.day, $0.index) })

        let weekdayLabels = weekdayTitles.enumerated().map { row, title in
            InsightsEnergyCalendarLabel(
                title: title,
                rect: NSRect(
                    x: content.minX,
                    y: plot.minY + CGFloat(row) * cellHeight + (cellHeight - 14) / 2,
                    width: weekdayLabelWidth,
                    height: 14
                )
            )
        }

        let days = days(from: firstMonthStart, through: lastDay, calendar: calendar)
        let items = days.enumerated().map { itemIndex, date in
            let day = dayString(for: date, calendar: calendar)
            let column = weekIndex(for: date, from: firstWeekStart, calendar: calendar)
            let row = weekdayRow(for: date, calendar: calendar)
            let cellRect = NSRect(
                x: plot.minX + CGFloat(column) * cellWidth + gap / 2,
                y: plot.minY + CGFloat(row) * cellHeight + gap / 2,
                width: max(1, cellWidth - gap),
                height: max(1, cellHeight - gap)
            )
            return InsightsEnergyCalendarItem(
                index: itemIndex,
                day: day,
                bucketIndex: bucketIndexesByDay[day],
                cellRect: cellRect,
                center: NSPoint(x: cellRect.midX, y: cellRect.midY),
                maximumRadius: radius
            )
        }

        let monthLabels = monthLabels(
            firstMonthStart: firstMonthStart,
            firstWeekStart: firstWeekStart,
            plot: plot,
            cellWidth: cellWidth,
            calendar: calendar
        )
        let monthSeparators = monthSeparators(
            firstMonthStart: firstMonthStart,
            firstWeekStart: firstWeekStart,
            plot: plot,
            cellWidth: cellWidth,
            gap: gap,
            calendar: calendar
        )

        return InsightsEnergyCalendarGrid(
            items: items,
            weekdayLabels: weekdayLabels,
            monthLabels: monthLabels,
            monthSeparators: monthSeparators
        )
    }

    static func items(buckets: [DailyUsageBucket], in bounds: NSRect) -> [InsightsEnergyCalendarItem] {
        layout(buckets: buckets, in: bounds).items
    }

    static func itemIndex(at point: NSPoint, in items: [InsightsEnergyCalendarItem]) -> Int? {
        items.first { item in
            item.cellRect.insetBy(dx: -1, dy: -1).contains(point)
        }?.bucketIndex
    }

    private static func monthLabels(
        firstMonthStart: Date,
        firstWeekStart: Date,
        plot: NSRect,
        cellWidth: CGFloat,
        calendar: Calendar
    ) -> [InsightsEnergyCalendarLabel] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"

        return (0..<displayedMonthCount).compactMap { offset in
            guard let date = calendar.date(byAdding: .month, value: offset, to: firstMonthStart) else { return nil }
            let column = weekIndex(for: date, from: firstWeekStart, calendar: calendar)
            return InsightsEnergyCalendarLabel(
                title: formatter.string(from: date),
                rect: NSRect(
                    x: plot.minX + CGFloat(column) * cellWidth,
                    y: plot.minY - monthLabelHeight + 2,
                    width: max(24, cellWidth * 4),
                    height: monthLabelHeight - 4
                )
            )
        }
    }

    private static func monthSeparators(
        firstMonthStart: Date,
        firstWeekStart: Date,
        plot: NSRect,
        cellWidth: CGFloat,
        gap: CGFloat,
        calendar: Calendar
    ) -> [InsightsEnergyCalendarSeparator] {
        (1..<displayedMonthCount).compactMap { offset in
            guard let date = calendar.date(byAdding: .month, value: offset, to: firstMonthStart) else {
                return nil
            }
            let column = weekIndex(for: date, from: firstWeekStart, calendar: calendar)
            let x = min(max(plot.minX + CGFloat(column) * cellWidth - gap / 2, plot.minX), plot.maxX)
            return InsightsEnergyCalendarSeparator(
                start: NSPoint(x: x, y: plot.minY),
                end: NSPoint(x: x, y: plot.maxY)
            )
        }
    }

    private static func gregorianCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar
    }

    private static func date(from day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return components.date.map { calendar.startOfDay(for: $0) }
    }

    private static func dayString(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func startOfMonth(containing date: Date, calendar: Calendar) -> Date? {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) }
    }

    private static func days(from start: Date, through end: Date, calendar: Calendar) -> [Date] {
        var days: [Date] = []
        var date = calendar.startOfDay(for: start)
        let end = calendar.startOfDay(for: end)
        while date <= end {
            days.append(date)
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        return days
    }

    private static func startOfWeek(containing date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let daysFromMonday = (weekday + 5) % rows
        return calendar.date(byAdding: .day, value: -daysFromMonday, to: calendar.startOfDay(for: date))
            ?? calendar.startOfDay(for: date)
    }

    private static func weekIndex(for date: Date, from firstWeekStart: Date, calendar: Calendar) -> Int {
        let days = calendar.dateComponents([.day], from: firstWeekStart, to: calendar.startOfDay(for: date)).day ?? 0
        return max(0, days / rows)
    }

    private static func weekdayRow(for date: Date, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return (weekday + 5) % rows
    }
}
