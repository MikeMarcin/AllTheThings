@testable import ATTCore
import Testing

@Suite("Packed row bit set")
struct PackedRowBitSetTests {
    @Test("set and clear track membership and count across word boundaries")
    func mutations() {
        var bitSet = PackedRowBitSet(bitCount: 130)

        let insertedZero = bitSet.insert(0)
        let inserted63 = bitSet.insert(63)
        let inserted64 = bitSet.insert(64)
        let inserted129 = bitSet.insert(129)
        let reinserted64 = bitSet.insert(64)

        #expect(insertedZero)
        #expect(inserted63)
        #expect(inserted64)
        #expect(inserted129)
        #expect(!reinserted64)
        #expect(bitSet.setBitCount == 4)
        #expect(bitSet.contains(0))
        #expect(bitSet.contains(63))
        #expect(bitSet.contains(64))
        #expect(bitSet.contains(129))

        let cleared64 = bitSet.remove(64)
        let recleared64 = bitSet.remove(64)

        #expect(cleared64)
        #expect(!recleared64)
        #expect(!bitSet.contains(64))
        #expect(bitSet.setBitCount == 3)
    }

    @Test("unset iteration handles partial edges and excludes padding bits")
    func partialRangeIteration() {
        var bitSet = PackedRowBitSet(bitCount: 275)
        let unset = Set([5, 63, 64, 127, 128, 255, 256, 274])
        for index in 0..<bitSet.bitCount where !unset.contains(index) {
            bitSet.insert(index)
        }

        var visited: [Int] = []
        bitSet.forEachUnset(in: 5..<275) { visited.append($0) }

        #expect(visited == unset.sorted())
    }

    @Test("unset iteration crosses multiple SIMD chunks in ascending order")
    func simdChunkIteration() {
        var bitSet = PackedRowBitSet(bitCount: 1_024)
        let unset = Set([0, 65, 191, 255, 256, 511, 512, 700, 767, 768, 1_023])
        for index in 0..<bitSet.bitCount where !unset.contains(index) {
            bitSet.insert(index)
        }

        var visited: [Int] = []
        let completed = bitSet.visitUnsetIndices(in: 0..<bitSet.bitCount) { index in
            visited.append(index)
            return true
        }

        #expect(completed)
        #expect(visited == unset.sorted())
    }

    @Test("visitor can stop without examining the remainder of the range")
    func earlyStop() {
        let bitSet = PackedRowBitSet(bitCount: 600)
        var visited: [Int] = []

        let completed = bitSet.visitUnsetIndices(in: 250..<550) { index in
            visited.append(index)
            return visited.count < 4
        }

        #expect(!completed)
        #expect(visited == [250, 251, 252, 253])
    }

    @Test("empty ranges complete without invoking the visitor")
    func emptyRange() {
        let bitSet = PackedRowBitSet(bitCount: 0)
        var visitCount = 0

        let completed = bitSet.visitUnsetIndices(in: 0..<0) { _ in
            visitCount += 1
            return true
        }

        #expect(completed)
        #expect(visitCount == 0)
    }
}
