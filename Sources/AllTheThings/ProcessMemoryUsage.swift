@preconcurrency import Darwin
import Foundation

struct ProcessMemoryUsage: Equatable, Sendable {
    let physicalFootprintBytes: UInt64
    let residentBytes: UInt64

    var displayBytes: UInt64 {
        physicalFootprintBytes > 0 ? physicalFootprintBytes : residentBytes
    }
}

struct ProcessResourceUsage: Equatable, Sendable {
    let sampledAt: Date
    let cpuTime: TimeInterval
    let wakeups: UInt64?
}

struct ProcessResourceDelta: Equatable, Sendable {
    let completedAt: Date
    let duration: TimeInterval
    let cpuTime: TimeInterval
    let wakeups: UInt64

    var cpuLoad: Double {
        duration > 0 ? cpuTime / duration : 0
    }

    var wakeupsPerMinute: Double {
        duration > 0 ? Double(wakeups) / duration * 60 : 0
    }
}

enum ProcessMemorySampler {
    static func currentUsage() -> ProcessMemoryUsage? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        return ProcessMemoryUsage(
            physicalFootprintBytes: UInt64(info.phys_footprint),
            residentBytes: UInt64(info.resident_size)
        )
    }
}

enum ProcessResourceSampler {
    static func currentUsage(sampledAt: Date = Date()) -> ProcessResourceUsage? {
        if let usage = currentRusageInfo(sampledAt: sampledAt) {
            return usage
        }
        return currentBasicRusage(sampledAt: sampledAt)
    }

    static func delta(from previous: ProcessResourceUsage, to current: ProcessResourceUsage) -> ProcessResourceDelta? {
        let duration = current.sampledAt.timeIntervalSince(previous.sampledAt)
        let cpuTime = current.cpuTime - previous.cpuTime
        guard duration > 0, cpuTime >= 0 else { return nil }

        let wakeups: UInt64
        if let previousWakeups = previous.wakeups, let currentWakeups = current.wakeups {
            guard currentWakeups >= previousWakeups else { return nil }
            wakeups = currentWakeups - previousWakeups
        } else {
            wakeups = 0
        }

        return ProcessResourceDelta(
            completedAt: current.sampledAt,
            duration: duration,
            cpuTime: cpuTime,
            wakeups: wakeups
        )
    }

    private static func currentRusageInfo(sampledAt: Date) -> ProcessResourceUsage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pid_rusage(
                getpid(),
                RUSAGE_INFO_V4,
                UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self)
            )
        }

        guard result == 0 else { return nil }
        return ProcessResourceUsage(
            sampledAt: sampledAt,
            cpuTime: nanosecondsToSeconds(info.ri_user_time + info.ri_system_time),
            wakeups: info.ri_pkg_idle_wkups + info.ri_interrupt_wkups
        )
    }

    private static func currentBasicRusage(sampledAt: Date) -> ProcessResourceUsage? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return ProcessResourceUsage(
            sampledAt: sampledAt,
            cpuTime: timeInterval(usage.ru_utime) + timeInterval(usage.ru_stime),
            wakeups: nil
        )
    }

    private static func nanosecondsToSeconds(_ value: UInt64) -> TimeInterval {
        TimeInterval(value) / 1_000_000_000
    }

    private static func timeInterval(_ value: timeval) -> TimeInterval {
        TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000
    }
}

enum ProcessMemoryFormatter {
    static func label(for usage: ProcessMemoryUsage?) -> String {
        guard let usage else {
            return "Memory unavailable"
        }

        return label(forBytes: usage.displayBytes)
    }

    static func label(forBytes bytes: UInt64) -> String {
        "Memory \(byteString(forBytes: bytes))"
    }

    private static func byteString(forBytes bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }
}
