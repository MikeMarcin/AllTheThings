@testable import AllTheThings
import Testing

@Suite("Process memory formatter")
struct ProcessMemoryFormatterTests {
    @Test("formats memory byte thresholds")
    func formatsMemoryByteThresholds() {
        #expect(ProcessMemoryFormatter.label(forBytes: 120_000_000) == "Memory 120 MB")
        #expect(ProcessMemoryFormatter.label(forBytes: 1_420_000_000) == "Memory 1.42 GB")
        #expect(ProcessMemoryFormatter.label(forBytes: 54_000_000_000) == "Memory 54 GB")
    }

    @Test("uses physical footprint before resident memory")
    func usesPhysicalFootprintBeforeResidentMemory() {
        let usage = ProcessMemoryUsage(
            physicalFootprintBytes: 1_420_000_000,
            residentBytes: 120_000_000
        )

        #expect(ProcessMemoryFormatter.label(for: usage) == "Memory 1.42 GB")
    }

    @Test("falls back to resident memory when physical footprint is unavailable")
    func fallsBackToResidentMemoryWhenPhysicalFootprintIsUnavailable() {
        let usage = ProcessMemoryUsage(
            physicalFootprintBytes: 0,
            residentBytes: 120_000_000
        )

        #expect(ProcessMemoryFormatter.label(for: usage) == "Memory 120 MB")
    }
}
