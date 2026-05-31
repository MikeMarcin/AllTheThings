import ATTCore
import Foundation

enum DiagnosticsReportBuilder {
    static func build(
        snapshot: IndexInsightsSnapshot,
        defaults: UserDefaults = .standard,
        includeRootPaths: Bool = false
    ) -> String {
        AppSettings.registerDefaults(defaults)

        var lines: [String] = []
        lines.append("# AllTheThings Diagnostics Report")
        lines.append("")
        lines.append("Privacy: this report contains aggregate counters and configuration shape. It does not include query text, result names, clicked files, or per-event history. Indexed root paths are \(includeRootPaths ? "included because the option was enabled" : "redacted by default").")
        lines.append("")

        lines.append("## App")
        lines.append("- Version: \(appVersionString())")
        lines.append("- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("- Architecture: \(architectureString())")
        lines.append("- First Launch: \(dateString(snapshot.lifetime.firstLaunchDate))")
        lines.append("- Launch Count: \(snapshot.lifetime.launchCount)")
        lines.append("- Current Version First Seen: \(dateString(snapshot.lifetime.currentAppVersionFirstSeenDate))")
        lines.append("")

        lines.append("## Settings Shape")
        lines.append("- Indexed Roots Configured: \(AppSettings.indexedRootsConfigured(defaults: defaults))")
        lines.append("- Indexed Root Count: \(AppSettings.indexedRoots(defaults: defaults).count)")
        lines.append("- Exclusion Pattern Count: \(AppSettings.exclusionPatterns(defaults: defaults).count)")
        lines.append("- Show Hidden Files: \(defaults.bool(forKey: AppSettings.showHiddenFilesKey))")
        lines.append("- Global Hotkey Enabled: \(AppSettings.globalSearchHotKeyEnabled(defaults: defaults))")
        lines.append("- Menu Bar Icon Enabled: \(AppSettings.menuBarIconEnabled(defaults: defaults))")
        lines.append("- Theme: \(AppSettings.themePreference(defaults: defaults).rawValue)")
        lines.append("")

        lines.append("## Index Status")
        lines.append("- Phase: \(snapshot.health.phase.rawValue)")
        lines.append("- Status: \(snapshot.health.status)")
        lines.append("- Schema Version: \(snapshot.health.schemaVersion)")
        lines.append("- Snapshot Revision: \(snapshot.health.snapshotRevision)")
        lines.append("- Result Rows: \(snapshot.health.resultCount)")
        lines.append("- Virtual Rows: \(snapshot.health.virtualRowCount)")
        lines.append("- Visible Rows: \(snapshot.health.visibleCount.map(String.init) ?? "unknown")")
        lines.append("- Store Kind: \(snapshot.health.recordStoreKind)")
        lines.append("- Active Jobs: \(snapshot.health.activeIndexJobs)")
        lines.append("- Active Job High Water Mark: \(snapshot.health.activeIndexJobHighWaterMark)")
        lines.append("")

        lines.append("## Storage")
        lines.append("- ATT Data: \(byteString(snapshot.storage.totalATTDataBytes))")
        lines.append("- Index Package: \(byteString(snapshot.storage.indexPackageBytes))")
        lines.append("- Caches: \(byteString(snapshot.storage.cacheBytes))")
        lines.append("- Measurement: \(storageMeasurementString(snapshot.storage))")
        for location in snapshot.storage.locations {
            lines.append("- \(location.label): \(byteString(location.allocatedBytes))")
        }
        lines.append("")

        lines.append("## Indexed Roots")
        if snapshot.roots.isEmpty {
            lines.append("- none")
        } else {
            for (index, root) in snapshot.roots.enumerated() {
                let label = includeRootPaths ? root.path : "Root \(index + 1)"
                lines.append("- \(label): source=\(root.attributionSource.rawValue), files=\(root.trackedFileCount), directories=\(root.directoryCount), hidden=\(root.hiddenCount), content=\(byteString(root.indexedContentBytes)), estimatedIndex=\(byteString(root.estimatedIndexBytes))")
            }
        }
        lines.append("")

        lines.append("## Search Performance")
        appendSearchCounters(snapshot.usage.allTimeSearches, to: &lines)
        lines.append("")

        lines.append("## Health Counters")
        let health = snapshot.usage.health
        lines.append("- Full Rebuilds: \(health.fullRebuilds)")
        lines.append("- Initial Build Duration: \(durationString(health.initialBuildDuration))")
        lines.append("- Last Rebuild Duration: \(durationString(health.lastRebuildDuration))")
        lines.append("- Incremental Refresh Batches: \(health.incrementalRefreshBatches)")
        lines.append("- Last Refresh Duration: \(durationString(health.lastRefreshDuration))")
        lines.append("- Recursive Rescans: \(health.recursiveRescans)")
        lines.append("- Indexing Failures: \(health.indexingFailures)")
        lines.append("- Snapshot Load Failures: \(health.snapshotLoadFailures)")
        lines.append("- Corrupt Snapshot Removals: \(health.corruptSnapshotRemovals)")
        lines.append("- Persist Failures: \(health.persistFailures)")
        lines.append("- Temp Cleanup Count: \(health.tempCleanupCount)")
        lines.append("")

        lines.append("## File Actions")
        if snapshot.usage.allTimeFileActions.isEmpty {
            lines.append("- none")
        } else {
            for action in FileActionMetric.allCases {
                if let count = snapshot.usage.allTimeFileActions[action], count > 0 {
                    lines.append("- \(action.rawValue): \(count)")
                }
            }
        }
        lines.append("")

        lines.append("## Sidecars")
        if snapshot.storage.sidecars.isEmpty {
            lines.append("- none")
        } else {
            for sidecar in snapshot.storage.sidecars {
                lines.append("- \(sidecar.name): \(byteString(sidecar.allocatedBytes))")
            }
        }
        lines.append("")

        lines.append("## Recent Daily Aggregates")
        let recentBuckets = snapshot.usage.dailyBuckets.suffix(14)
        if recentBuckets.isEmpty {
            lines.append("- none")
        } else {
            for bucket in recentBuckets {
                lines.append("- \(bucket.day): searches=\(bucket.searches.completed), fallbacks=\(bucket.searches.fallbackScans), refreshes=\(bucket.health.incrementalRefreshBatches), rebuilds=\(bucket.health.fullRebuilds), launches=\(bucket.launches), memoryLatest=\(byteString(bucket.memory.latestBytes))")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func appendSearchCounters(_ counters: SearchUsageCounters, to lines: inout [String]) {
        lines.append("- Started: \(counters.started)")
        lines.append("- Completed: \(counters.completed)")
        lines.append("- Cancelled: \(counters.cancelled)")
        lines.append("- Stale Retries: \(counters.staleRetries)")
        lines.append("- Indexed Candidate Searches: \(counters.indexedCandidateSearches)")
        lines.append("- Fallback Scans: \(counters.fallbackScans)")
        lines.append("- Average Latency: \(durationString(counters.averageLatency))")
        lines.append("- Max Latency: \(durationString(counters.maxLatency))")
        lines.append("- Candidate Rows Examined: \(counters.candidateRowsExamined)")
        lines.append("- Scanned Rows Examined: \(counters.scannedRowsExamined)")

        if !counters.executionPathCounts.isEmpty {
            lines.append("- Execution Paths:")
            for path in SearchExecutionPath.allCases {
                if let count = counters.executionPathCounts[path], count > 0 {
                    lines.append("  - \(path.rawValue): \(count)")
                }
            }
        }

        if !counters.indexUseCounts.isEmpty {
            lines.append("- Index Structures:")
            for indexUse in SearchIndexUse.allCases {
                if let count = counters.indexUseCounts[indexUse], count > 0 {
                    lines.append("  - \(indexUse.rawValue): \(count)")
                }
            }
        }

        if !counters.latencyBuckets.isEmpty {
            lines.append("- Latency Buckets:")
            for key in ["<10ms", "10-50ms", "50-100ms", "100-250ms", "250ms-1s", ">1s"] {
                if let count = counters.latencyBuckets[key], count > 0 {
                    lines.append("  - \(key): \(count)")
                }
            }
        }
    }

    private static func appVersionString() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (version?, build?) where !version.isEmpty && !build.isEmpty:
            return "\(version) (\(build))"
        case let (version?, _) where !version.isEmpty:
            return version
        case let (_, build?) where !build.isEmpty:
            return build
        default:
            return "unknown"
        }
    }

    private static func architectureString() -> String {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            return "unknown"
        #endif
    }

    private static func dateString(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        return ISO8601DateFormatter().string(from: date)
    }

    private static func durationString(_ duration: TimeInterval?) -> String {
        guard let duration else { return "unknown" }
        return durationString(duration)
    }

    private static func durationString(_ duration: TimeInterval) -> String {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = duration < 1 ? 1 : 2
        return formatter.string(from: Measurement(value: max(duration, 0), unit: UnitDuration.seconds))
    }

    private static func byteString(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    private static func storageMeasurementString(_ storage: IndexStorageInsights) -> String {
        if storage.isMeasuring {
            return storage.measuredAt.map { "refreshing; last measured \(dateString($0))" } ?? "measuring"
        }
        return storage.measuredAt.map { "measured \(dateString($0))" } ?? "not measured"
    }
}
