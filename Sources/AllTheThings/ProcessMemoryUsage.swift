@preconcurrency import Darwin
import Foundation

struct ProcessMemoryUsage: Equatable, Sendable {
    let physicalFootprintBytes: UInt64
    let residentBytes: UInt64

    var displayBytes: UInt64 {
        physicalFootprintBytes > 0 ? physicalFootprintBytes : residentBytes
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
