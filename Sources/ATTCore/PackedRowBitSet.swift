/// A compact set for stable row identifiers from a fixed-size snapshot.
///
/// The set deliberately has a fixed capacity: row identifiers only remain
/// meaningful for the snapshot that supplied them. Keeping one bit per row
/// makes whole-snapshot difference passes cheap without retaining every path.
struct PackedRowBitSet: Sendable {
    let bitCount: Int
    private var words: [UInt64]
    private(set) var setBitCount = 0

    init(bitCount: Int) {
        precondition(bitCount >= 0, "Bit count cannot be negative")
        self.bitCount = bitCount
        words = Array(repeating: 0, count: (bitCount + 63) / 64)
    }

    @discardableResult
    mutating func insert(_ index: Int) -> Bool {
        validate(index)
        let wordIndex = index >> 6
        let mask = UInt64(1) << UInt64(index & 63)
        guard words[wordIndex] & mask == 0 else { return false }

        words[wordIndex] |= mask
        setBitCount += 1
        return true
    }

    @discardableResult
    mutating func remove(_ index: Int) -> Bool {
        validate(index)
        let wordIndex = index >> 6
        let mask = UInt64(1) << UInt64(index & 63)
        guard words[wordIndex] & mask != 0 else { return false }

        words[wordIndex] &= ~mask
        setBitCount -= 1
        return true
    }

    func contains(_ index: Int) -> Bool {
        validate(index)
        let wordIndex = index >> 6
        let mask = UInt64(1) << UInt64(index & 63)
        return words[wordIndex] & mask != 0
    }

    /// Visits unset indices in ascending order. Returns `false` when the visitor stops the pass.
    ///
    /// Interior 256-bit spans are inverted and checked four words at a time. Sparse unset words
    /// then use trailing-zero extraction, avoiding a branch for every row in mostly-seen ranges.
    @discardableResult
    func visitUnsetIndices(
        in range: Range<Int>,
        _ visitor: (Int) -> Bool
    ) -> Bool {
        validate(range)
        guard !range.isEmpty else { return true }

        var current = range.lowerBound

        if current & 63 != 0 {
            let wordEnd = min(range.upperBound, (current | 63) + 1)
            let wordIndex = current >> 6
            let mask = Self.mask(
                fromBit: current & 63,
                toBit: ((wordEnd - 1) & 63) + 1
            )
            guard visitSetBits(
                ~words[wordIndex] & mask,
                baseIndex: wordIndex << 6,
                visitor
            ) else {
                return false
            }
            current = wordEnd
        }

        while current + 256 <= range.upperBound {
            let wordIndex = current >> 6
            let unset = ~SIMD4<UInt64>(
                words[wordIndex],
                words[wordIndex + 1],
                words[wordIndex + 2],
                words[wordIndex + 3]
            )

            if unset[0] | unset[1] | unset[2] | unset[3] != 0 {
                for lane in 0..<4 where unset[lane] != 0 {
                    guard visitSetBits(
                        unset[lane],
                        baseIndex: current + lane * 64,
                        visitor
                    ) else {
                        return false
                    }
                }
            }
            current += 256
        }

        while current + 64 <= range.upperBound {
            let wordIndex = current >> 6
            guard visitSetBits(~words[wordIndex], baseIndex: current, visitor) else {
                return false
            }
            current += 64
        }

        if current < range.upperBound {
            let wordIndex = current >> 6
            let mask = Self.mask(
                fromBit: current & 63,
                toBit: ((range.upperBound - 1) & 63) + 1
            )
            guard visitSetBits(
                ~words[wordIndex] & mask,
                baseIndex: wordIndex << 6,
                visitor
            ) else {
                return false
            }
        }

        return true
    }

    func forEachUnset(in range: Range<Int>, _ body: (Int) -> Void) {
        visitUnsetIndices(in: range) { index in
            body(index)
            return true
        }
    }

    private func validate(_ index: Int) {
        precondition(index >= 0 && index < bitCount, "Bit index is out of bounds")
    }

    private func validate(_ range: Range<Int>) {
        precondition(
            range.lowerBound >= 0 && range.upperBound <= bitCount,
            "Bit range is out of bounds"
        )
    }

    private func visitSetBits(
        _ bits: UInt64,
        baseIndex: Int,
        _ visitor: (Int) -> Bool
    ) -> Bool {
        var remaining = bits
        while remaining != 0 {
            let offset = remaining.trailingZeroBitCount
            guard visitor(baseIndex + offset) else { return false }
            remaining &= remaining - 1
        }
        return true
    }

    private static func mask(fromBit lowerBound: Int, toBit upperBound: Int) -> UInt64 {
        precondition(lowerBound >= 0 && lowerBound < upperBound && upperBound <= 64)
        let lowerMask = UInt64.max << UInt64(lowerBound)
        let upperMask = upperBound == 64
            ? UInt64.max
            : (UInt64(1) << UInt64(upperBound)) - 1
        return lowerMask & upperMask
    }
}
