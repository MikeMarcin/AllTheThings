import Foundation

final class FileExclusionQuery {
    private let roots: [String]
    private let rules: [Rule]
    private let ancestorPropagatingRules: [(index: Int, rule: Rule)]
    private let literalComponentRuleIndexes: [String: [Int]]
    private var literalRuleCandidateGenerations: [UInt64]
    private var literalRuleCandidateGeneration: UInt64 = 0
    private var ancestorRuleIndexCache: [String: Set<Int>] = [:]

    struct Instrumentation: Sendable, Equatable {
        var compiledExclusionDecisionCount = 0
        var componentSplitCount = 0
        var ancestorMatchCheckCount = 0
        var regexMatchCount = 0
        var fastPathDecisionCount = 0
        var fastPruneDirectoryCount = 0
        var ruleMatchAttemptCount = 0
        var literalRuleFastRejectCount = 0

        init() {}

        mutating func add(_ other: Instrumentation) {
            compiledExclusionDecisionCount += other.compiledExclusionDecisionCount
            componentSplitCount += other.componentSplitCount
            ancestorMatchCheckCount += other.ancestorMatchCheckCount
            regexMatchCount += other.regexMatchCount
            fastPathDecisionCount += other.fastPathDecisionCount
            fastPruneDirectoryCount += other.fastPruneDirectoryCount
            ruleMatchAttemptCount += other.ruleMatchAttemptCount
            literalRuleFastRejectCount += other.literalRuleFastRejectCount
        }
    }

    init(patterns: [String] = FileExclusionRules.defaultPatterns, roots: [String]) {
        self.roots = roots
            .map(Self.normalizedRootPath)
            .sorted { $0.count > $1.count }
        let rules = patterns.compactMap(Rule.init(rawPattern:))
        self.rules = rules
        self.ancestorPropagatingRules = rules.enumerated().compactMap { index, rule in
            rule.propagatesThroughIgnoredAncestors ? (index, rule) : nil
        }
        var literalComponentRuleIndexes: [String: [Int]] = [:]
        for (index, rule) in rules.enumerated() {
            guard let component = rule.indexedLiteralComponent else { continue }
            literalComponentRuleIndexes[component, default: []].append(index)
        }
        self.literalComponentRuleIndexes = literalComponentRuleIndexes
        self.literalRuleCandidateGenerations = Array(repeating: 0, count: rules.count)
    }

    func decision(path: String, isDirectory: Bool) -> FileExclusionRules.Decision {
        var instrumentation = Instrumentation()
        return decision(path: path, isDirectory: isDirectory, instrumentation: &instrumentation)
    }

    func decision(
        path: String,
        isDirectory: Bool,
        instrumentation: inout Instrumentation
    ) -> FileExclusionRules.Decision {
        instrumentation.compiledExclusionDecisionCount += 1

        let relativePaths = relativePathContexts(for: path, instrumentation: &instrumentation)
        let literalCandidateGeneration = markLiteralRuleCandidates(in: relativePaths)
        var excluded = false
        var finalMatchingRuleIndex: Int?
        var finalMatchingRule: Rule?

        let ignoredAncestorRuleIndexes = inheritedAncestorRuleIndexes(
            for: relativePaths,
            instrumentation: &instrumentation
        )

        for (index, rule) in rules.enumerated() {
            if rule.indexedLiteralComponent != nil,
               literalRuleCandidateGenerations[index] != literalCandidateGeneration {
                instrumentation.literalRuleFastRejectCount += 1
                continue
            }
            instrumentation.ruleMatchAttemptCount += 1
            let matchesTarget = rule.matches(
                relativePaths: relativePaths,
                isDirectory: isDirectory,
                instrumentation: &instrumentation
            )
            let matchesIgnoredAncestor = !matchesTarget
                && !rule.isNegated
                && ignoredAncestorRuleIndexes.contains(index)
            guard matchesTarget || matchesIgnoredAncestor else { continue }

            excluded = !rule.isNegated
            finalMatchingRuleIndex = index
            finalMatchingRule = rule
        }

        guard isDirectory else {
            return excluded ? .prune : .index
        }

        if finalMatchingRule?.isTraversalOnlyDirectoryReinclude == true {
            return .skipButDescend
        }

        guard excluded else { return .index }
        guard let finalMatchingRuleIndex else { return .prune }

        for rule in rules.dropFirst(finalMatchingRuleIndex + 1)
            where rule.mayReincludeDescendant(of: relativePaths) {
            return .skipButDescend
        }

        return .prune
    }

    private func markLiteralRuleCandidates(in relativePaths: [RelativePathContext]) -> UInt64 {
        literalRuleCandidateGeneration &+= 1
        if literalRuleCandidateGeneration == 0 {
            literalRuleCandidateGenerations = Array(repeating: 0, count: rules.count)
            literalRuleCandidateGeneration = 1
        }

        let generation = literalRuleCandidateGeneration
        for relativePath in relativePaths {
            for component in relativePath.lowercasedComponents {
                guard let ruleIndexes = literalComponentRuleIndexes[component] else { continue }
                for ruleIndex in ruleIndexes {
                    literalRuleCandidateGenerations[ruleIndex] = generation
                }
            }
        }
        return generation
    }

    private func inheritedAncestorRuleIndexes(
        for relativePaths: [RelativePathContext],
        instrumentation: inout Instrumentation
    ) -> Set<Int> {
        var indexes = Set<Int>()

        for relativePath in relativePaths where relativePath.componentCount > 1 {
            indexes.formUnion(nonNegatedRuleIndexesMatchingDirectoryOrAncestor(
                relativePath: relativePath,
                componentCount: relativePath.componentCount - 1,
                instrumentation: &instrumentation
            ))
        }

        return indexes
    }

    private func nonNegatedRuleIndexesMatchingDirectoryOrAncestor(
        relativePath: RelativePathContext,
        componentCount: Int,
        instrumentation: inout Instrumentation
    ) -> Set<Int> {
        guard componentCount > 0 else { return [] }

        let cacheKey = relativePath.prefixString(componentCount: componentCount)
        if let cached = ancestorRuleIndexCache[cacheKey] {
            return cached
        }

        var indexes = componentCount > 1
            ? nonNegatedRuleIndexesMatchingDirectoryOrAncestor(
                relativePath: relativePath,
                componentCount: componentCount - 1,
                instrumentation: &instrumentation
            )
            : []

        for (index, rule) in ancestorPropagatingRules {
            instrumentation.ancestorMatchCheckCount += 1
            if rule.matches(
                relativePath: relativePath,
                componentCount: componentCount,
                isDirectory: true,
                instrumentation: &instrumentation
            ) {
                indexes.insert(index)
            }
        }

        ancestorRuleIndexCache[cacheKey] = indexes
        return indexes
    }

    private func relativePathContexts(
        for path: String,
        instrumentation: inout Instrumentation
    ) -> [RelativePathContext] {
        var relativePaths: [String] = []

        for root in roots {
            if path == root {
                relativePaths.append("")
            } else if path.hasPrefix(root + "/") {
                relativePaths.append(String(path.dropFirst(root.count + 1)))
            }
        }

        if relativePaths.isEmpty {
            relativePaths.append(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }

        return relativePaths.map {
            RelativePathContext(value: $0, instrumentation: &instrumentation)
        }
    }

    private static func normalizedRootPath(_ root: String) -> String {
        guard root.count > 1 else { return root }
        var normalized = root
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

extension FileExclusionRules {
    func makeQuery(roots: [String]) -> FileExclusionQuery {
        FileExclusionQuery(patterns: patterns, roots: roots)
    }

    @_spi(ATTInternal)
    /// Creates a serial, batch-owned evaluator that reuses compiled rules and ancestor matches.
    /// Callers must not invoke the returned closure concurrently.
    public func makeDecisionEvaluator(
        roots: [String]
    ) -> (_ path: String, _ isDirectory: Bool) -> Decision {
        let query = makeQuery(roots: roots)
        return { path, isDirectory in
            query.decision(path: path, isDirectory: isDirectory)
        }
    }
}

private final class RelativePathContext {
    struct RangeKey: Hashable {
        let start: Int
        let end: Int
    }

    let value: String
    let components: [String]
    let lowercasedComponents: [String]
    let componentASCII: [Bool]
    let prefixes: [String]

    private var rangeStrings: [RangeKey: String] = [:]

    var componentCount: Int {
        components.count
    }

    init(value: String, instrumentation: inout FileExclusionQuery.Instrumentation) {
        self.value = value
        instrumentation.componentSplitCount += 1
        components = value.split(separator: "/").map(String.init)
        lowercasedComponents = components.map { $0.lowercased() }
        componentASCII = components.map { $0.unicodeScalars.allSatisfy(\.isASCII) }

        var prefixes: [String] = []
        var prefix = ""
        for component in components {
            if prefix.isEmpty {
                prefix = component
            } else {
                prefix += "/" + component
            }
            prefixes.append(prefix)
        }
        self.prefixes = prefixes
    }

    func componentMatches(_ lowercasedLiteral: String, in range: Range<Int>) -> Bool {
        for index in range where lowercasedComponents[index] == lowercasedLiteral {
            return true
        }
        return false
    }

    func componentIsASCII(at index: Int) -> Bool {
        componentASCII[index]
    }

    func componentsAreASCII(in range: Range<Int>) -> Bool {
        range.allSatisfy { componentIsASCII(at: $0) }
    }

    func suffixMatches(_ lowercasedLiteralComponents: [String], endingAt end: Int) -> Bool {
        guard !lowercasedLiteralComponents.isEmpty else { return false }
        guard lowercasedLiteralComponents.count <= end else { return false }

        let start = end - lowercasedLiteralComponents.count
        for offset in 0..<lowercasedLiteralComponents.count {
            if lowercasedComponents[start + offset] != lowercasedLiteralComponents[offset] {
                return false
            }
        }
        return true
    }

    func prefixString(componentCount: Int) -> String {
        guard componentCount > 0 else { return "" }
        guard componentCount < prefixes.count else { return value }
        return prefixes[componentCount - 1]
    }

    func rangeString(start: Int, end: Int) -> String {
        guard start < end else { return "" }
        if start == 0 {
            return prefixString(componentCount: end)
        }
        if end == components.count {
            return components[start..<end].joined(separator: "/")
        }

        let key = RangeKey(start: start, end: end)
        if let cached = rangeStrings[key] {
            return cached
        }

        let value = components[start..<end].joined(separator: "/")
        rangeStrings[key] = value
        return value
    }
}

private final class Rule {
    let isNegated: Bool
    let isTraversalOnlyDirectoryReinclude: Bool
    private let isDirectoryPattern: Bool
    private let isAnchored: Bool
    private let containsSlash: Bool
    private let literalPrefix: String
    private let matcher: Matcher
    let indexedLiteralComponent: String?

    var propagatesThroughIgnoredAncestors: Bool {
        !isNegated && !isDirectoryPattern && (containsSlash || isAnchored)
    }

    init?(rawPattern: String) {
        var pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty, !pattern.hasPrefix("#") else { return nil }

        if pattern.hasSuffix("\r") {
            pattern.removeLast()
        }

        if pattern.hasPrefix("\\#") {
            pattern.removeFirst()
        }

        if pattern.hasPrefix("\\!") {
            isNegated = false
            pattern.removeFirst()
        } else if pattern.hasPrefix("!") {
            isNegated = true
            pattern.removeFirst()
        } else {
            isNegated = false
        }

        pattern = pattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return nil }

        isDirectoryPattern = pattern.hasSuffix("/")
        while pattern.hasSuffix("/") {
            pattern.removeLast()
        }

        var anchored = false
        if pattern.hasPrefix("/") {
            anchored = true
            pattern.removeFirst()
        }

        while pattern.hasPrefix("./") {
            pattern.removeFirst(2)
        }

        guard !pattern.isEmpty else { return nil }

        isAnchored = anchored
        containsSlash = pattern.contains("/")
        isTraversalOnlyDirectoryReinclude = isNegated
            && ((isDirectoryPattern && !containsSlash && pattern == "*") || pattern.hasSuffix("/**"))
        literalPrefix = Self.literalPrefix(for: pattern)

        let compiledMatcher: Matcher
        if Self.isLiteral(pattern) {
            compiledMatcher = .literal(
                lowercasedValue: pattern.lowercased(),
                lowercasedComponents: pattern.split(separator: "/").map { String($0).lowercased() }
            )
        } else if let glob = NativeGlobMatcher(pattern: pattern) {
            guard let fallbackRegex = try? NSRegularExpression(
                pattern: Self.regexPattern(for: pattern),
                options: [.caseInsensitive]
            ) else {
                return nil
            }
            compiledMatcher = .glob(glob, nonASCIIFallback: fallbackRegex)
        } else {
            do {
                compiledMatcher = .regex(try NSRegularExpression(
                    pattern: Self.regexPattern(for: pattern),
                    options: [.caseInsensitive]
                ))
            } catch {
                return nil
            }
        }
        matcher = compiledMatcher
        if case .literal(let lowercasedValue, let lowercasedComponents) = compiledMatcher {
            indexedLiteralComponent = lowercasedComponents.max {
                $0.count < $1.count
            } ?? lowercasedValue
        } else {
            indexedLiteralComponent = nil
        }
    }

    func matches(
        relativePaths: [RelativePathContext],
        isDirectory: Bool,
        instrumentation: inout FileExclusionQuery.Instrumentation
    ) -> Bool {
        for relativePath in relativePaths
            where matches(
                relativePath: relativePath,
                componentCount: relativePath.componentCount,
                isDirectory: isDirectory,
                instrumentation: &instrumentation
            ) {
            return true
        }

        return false
    }

    func mayReincludeDescendant(of relativePaths: [RelativePathContext]) -> Bool {
        guard isNegated, !isTraversalOnlyDirectoryReinclude, containsSlash, !literalPrefix.isEmpty else {
            return false
        }

        let prefix = literalPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !prefix.isEmpty else { return false }

        return relativePaths.contains { relativePath in
            Self.pathsMayOverlapForDescendant(
                rulePrefix: prefix,
                directoryPath: relativePath.value,
                isAnchored: isAnchored
            )
        }
    }

    func matchesIgnoredAncestor(
        of relativePaths: [RelativePathContext],
        instrumentation: inout FileExclusionQuery.Instrumentation
    ) -> Bool {
        guard !isNegated else { return false }

        for relativePath in relativePaths {
            guard relativePath.componentCount > 1 else { continue }
            for ancestorComponentCount in 1..<relativePath.componentCount {
                instrumentation.ancestorMatchCheckCount += 1
                if matches(
                    relativePath: relativePath,
                    componentCount: ancestorComponentCount,
                    isDirectory: true,
                    instrumentation: &instrumentation
                ) {
                    return true
                }
            }
        }

        return false
    }

    func matches(
        relativePath: RelativePathContext,
        componentCount: Int,
        isDirectory: Bool,
        instrumentation: inout FileExclusionQuery.Instrumentation
    ) -> Bool {
        if !containsSlash {
            if isAnchored {
                return matchesPath(
                    relativePath,
                    componentCount: componentCount,
                    isDirectory: isDirectory,
                    instrumentation: &instrumentation
                )
            }

            return matchesComponentPattern(
                relativePath: relativePath,
                componentCount: componentCount,
                isDirectory: isDirectory,
                instrumentation: &instrumentation
            )
        }

        return matchesPath(
            relativePath,
            componentCount: componentCount,
            isDirectory: isDirectory,
            instrumentation: &instrumentation
        )
    }

    private func matchesComponentPattern(
        relativePath: RelativePathContext,
        componentCount: Int,
        isDirectory: Bool,
        instrumentation: inout FileExclusionQuery.Instrumentation
    ) -> Bool {
        guard componentCount > 0 else { return false }

        let matchableComponentCount: Int
        if isDirectoryPattern {
            if isNegated, !isDirectory {
                return false
            }
            matchableComponentCount = isDirectory ? componentCount : max(componentCount - 1, 0)
        } else {
            matchableComponentCount = componentCount
        }
        guard matchableComponentCount > 0 else { return false }

        switch matcher {
        case .literal(let lowercasedValue, _):
            instrumentation.fastPathDecisionCount += 1
            return relativePath.componentMatches(lowercasedValue, in: 0..<matchableComponentCount)
        case .glob(let glob, let nonASCIIFallback):
            for index in 0..<matchableComponentCount {
                if relativePath.componentIsASCII(at: index) {
                    instrumentation.fastPathDecisionCount += 1
                    if glob.matchesComponent(relativePath.lowercasedComponents[index]) {
                        return true
                    }
                } else if matchesWholeString(
                    relativePath.components[index],
                    regex: nonASCIIFallback,
                    instrumentation: &instrumentation
                ) {
                    return true
                }
            }
            return false
        case .regex:
            for index in 0..<matchableComponentCount {
                if matchesWholeString(
                    relativePath.components[index],
                    instrumentation: &instrumentation
                ) {
                    return true
                }
            }
            return false
        }
    }

    private func matchesPath(
        _ relativePath: RelativePathContext,
        componentCount: Int,
        isDirectory: Bool,
        instrumentation: inout FileExclusionQuery.Instrumentation
    ) -> Bool {
        guard componentCount > 0 else { return false }

        if isNegated, isDirectoryPattern, !isDirectory {
            return false
        }

        if isDirectoryPattern {
            let prefixCount = isDirectory ? componentCount : max(componentCount - 1, 0)
            guard prefixCount > 0 else { return false }

            for prefixComponentCount in 1...prefixCount
                where matchesPathCandidate(
                    relativePath,
                    componentCount: prefixComponentCount,
                    instrumentation: &instrumentation
                ) {
                return true
            }
            return false
        }

        return matchesPathCandidate(
            relativePath,
            componentCount: componentCount,
            instrumentation: &instrumentation
        )
    }

    private func matchesPathCandidate(
        _ relativePath: RelativePathContext,
        componentCount: Int,
        instrumentation: inout FileExclusionQuery.Instrumentation
    ) -> Bool {
        switch matcher {
        case .literal(_, let lowercasedComponents):
            instrumentation.fastPathDecisionCount += 1
            guard relativePath.suffixMatches(lowercasedComponents, endingAt: componentCount) else {
                return false
            }
            return !isAnchored || lowercasedComponents.count == componentCount
        case .glob(let glob, let nonASCIIFallback):
            if matchesGlobPathCandidate(
                glob,
                nonASCIIFallback: nonASCIIFallback,
                relativePath: relativePath,
                range: 0..<componentCount,
                instrumentation: &instrumentation
            ) {
                return true
            }

            guard !isAnchored, componentCount > 1 else { return false }
            for index in 1..<componentCount {
                if matchesGlobPathCandidate(
                    glob,
                    nonASCIIFallback: nonASCIIFallback,
                    relativePath: relativePath,
                    range: index..<componentCount,
                    instrumentation: &instrumentation
                ) {
                    return true
                }
            }
            return false
        case .regex:
            if matchesWholeString(
                relativePath.prefixString(componentCount: componentCount),
                instrumentation: &instrumentation
            ) {
                return true
            }

            guard !isAnchored else { return false }
            guard componentCount > 1 else { return false }

            for index in 1..<componentCount
                where matchesWholeString(
                    relativePath.rangeString(start: index, end: componentCount),
                    instrumentation: &instrumentation
                ) {
                return true
            }
            return false
        }
    }

    private func matchesWholeString(
        _ value: String,
        instrumentation: inout FileExclusionQuery.Instrumentation
    ) -> Bool {
        guard case .regex(let regex) = matcher else { return false }
        return matchesWholeString(value, regex: regex, instrumentation: &instrumentation)
    }

    private func matchesWholeString(
        _ value: String,
        regex: NSRegularExpression,
        instrumentation: inout FileExclusionQuery.Instrumentation
    ) -> Bool {
        instrumentation.regexMatchCount += 1
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }

    private func matchesGlobPathCandidate(
        _ glob: NativeGlobMatcher,
        nonASCIIFallback: NSRegularExpression,
        relativePath: RelativePathContext,
        range: Range<Int>,
        instrumentation: inout FileExclusionQuery.Instrumentation
    ) -> Bool {
        if relativePath.componentsAreASCII(in: range) {
            instrumentation.fastPathDecisionCount += 1
            return glob.matches(components: relativePath.lowercasedComponents, range: range)
        }

        return matchesWholeString(
            relativePath.rangeString(start: range.lowerBound, end: range.upperBound),
            regex: nonASCIIFallback,
            instrumentation: &instrumentation
        )
    }

    private static func isLiteral(_ pattern: String) -> Bool {
        !pattern.contains("*") && !pattern.contains("?") && !pattern.contains("[")
    }

    private static func regexPattern(for pattern: String) -> String {
        var output = "^"
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            let nextIndex = pattern.index(after: index)

            if character == "/",
               nextIndex < pattern.endIndex,
               pattern[nextIndex] == "*" {
                let secondStar = pattern.index(after: nextIndex)
                if secondStar < pattern.endIndex, pattern[secondStar] == "*",
                   pattern.index(after: secondStar) == pattern.endIndex {
                    output += "(?:/.*)?"
                    index = pattern.endIndex
                } else {
                    output += "/"
                    index = nextIndex
                }
            } else if character == "*" {
                if nextIndex < pattern.endIndex, pattern[nextIndex] == "*" {
                    let afterDoubleStar = pattern.index(after: nextIndex)
                    if afterDoubleStar < pattern.endIndex, pattern[afterDoubleStar] == "/" {
                        output += "(?:.*/)?"
                        index = pattern.index(after: afterDoubleStar)
                    } else {
                        output += ".*"
                        index = afterDoubleStar
                    }
                } else {
                    output += "[^/]*"
                    index = nextIndex
                }
            } else if character == "?" {
                output += "[^/]"
                index = nextIndex
            } else if character == "[", let characterClass = regexCharacterClass(in: pattern, from: index) {
                output += characterClass.pattern
                index = characterClass.endIndex
            } else {
                output += NSRegularExpression.escapedPattern(for: String(character))
                index = nextIndex
            }
        }

        output += "$"
        return output
    }

    private static func literalPrefix(for pattern: String) -> String {
        var output = ""
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" || character == "?" || character == "[" {
                break
            }
            output.append(character)
            index = pattern.index(after: index)
        }

        return output
    }

    private static func regexCharacterClass(
        in pattern: String,
        from startIndex: String.Index
    ) -> (pattern: String, endIndex: String.Index)? {
        var index = pattern.index(after: startIndex)
        guard index < pattern.endIndex else { return nil }

        var output = "["
        var hasContent = false
        if pattern[index] == "!" || pattern[index] == "^" {
            output += "^"
            index = pattern.index(after: index)
        }

        while index < pattern.endIndex {
            let character = pattern[index]
            let nextIndex = pattern.index(after: index)

            if character == "]", hasContent {
                output += "]"
                return (output, nextIndex)
            }

            guard character != "/" else { return nil }
            output += escapedCharacterClassLiteral(character)
            hasContent = true
            index = nextIndex
        }

        return nil
    }

    private static func escapedCharacterClassLiteral(_ character: Character) -> String {
        switch character {
        case "\\":
            return "\\\\"
        case "]":
            return "\\]"
        default:
            return String(character)
        }
    }

    private static func pathsMayOverlapForDescendant(
        rulePrefix: String,
        directoryPath: String,
        isAnchored: Bool
    ) -> Bool {
        guard !directoryPath.isEmpty else { return true }
        if rulePrefix == directoryPath
            || rulePrefix.hasPrefix(directoryPath + "/")
            || directoryPath.hasPrefix(rulePrefix + "/") {
            return true
        }
        guard !isAnchored else { return false }

        let components = directoryPath.split(separator: "/")
        return components.indices.contains { start in
            let suffix = components[start...].joined(separator: "/")
            return rulePrefix == suffix
                || rulePrefix.hasPrefix(suffix + "/")
                || suffix.hasPrefix(rulePrefix + "/")
        }
    }
}

private enum Matcher {
    case literal(lowercasedValue: String, lowercasedComponents: [String])
    case glob(NativeGlobMatcher, nonASCIIFallback: NSRegularExpression)
    case regex(NSRegularExpression)
}

private struct NativeGlobMatcher {
    private enum PathComponent {
        case recursiveWildcard
        case component(ComponentGlobMatcher)
    }

    private let pathComponents: [PathComponent]

    init?(pattern: String) {
        guard
            pattern.unicodeScalars.allSatisfy(\.isASCII),
            !pattern.contains("?"),
            !pattern.contains("[")
        else {
            return nil
        }

        var pathComponents: [PathComponent] = []
        var recursiveWildcardCount = 0
        for component in pattern.split(separator: "/", omittingEmptySubsequences: false) {
            let component = String(component).lowercased()
            if component == "**" {
                recursiveWildcardCount += 1
                guard recursiveWildcardCount == 1 else { return nil }
                pathComponents.append(.recursiveWildcard)
            } else {
                guard !component.contains("**") else { return nil }
                let wildcardCount = component.reduce(into: 0) { count, character in
                    if character == "*" {
                        count += 1
                    }
                }
                let hasSupportedWildcards = wildcardCount == 0
                    || component == "*"
                    || (wildcardCount == 1 && (component.hasPrefix("*") || component.hasSuffix("*")))
                    || (wildcardCount == 2 && component.hasPrefix("*") && component.hasSuffix("*"))
                guard hasSupportedWildcards else { return nil }
                pathComponents.append(.component(ComponentGlobMatcher(pattern: component)))
            }
        }
        guard !pathComponents.isEmpty else { return nil }
        self.pathComponents = pathComponents
    }

    func matchesComponent(_ component: String) -> Bool {
        guard pathComponents.count == 1 else { return false }
        switch pathComponents[0] {
        case .recursiveWildcard:
            return true
        case .component(let matcher):
            return matcher.matches(component)
        }
    }

    func matches(components: [String], range: Range<Int>) -> Bool {
        matches(
            components: components,
            componentIndex: range.lowerBound,
            componentEnd: range.upperBound,
            patternIndex: 0
        )
    }

    private func matches(
        components: [String],
        componentIndex: Int,
        componentEnd: Int,
        patternIndex: Int
    ) -> Bool {
        guard patternIndex < pathComponents.count else {
            return componentIndex == componentEnd
        }

        switch pathComponents[patternIndex] {
        case .component(let matcher):
            guard componentIndex < componentEnd, matcher.matches(components[componentIndex]) else {
                return false
            }
            return matches(
                components: components,
                componentIndex: componentIndex + 1,
                componentEnd: componentEnd,
                patternIndex: patternIndex + 1
            )

        case .recursiveWildcard:
            if patternIndex == pathComponents.count - 1 {
                return true
            }
            for nextComponentIndex in componentIndex...componentEnd where matches(
                components: components,
                componentIndex: nextComponentIndex,
                componentEnd: componentEnd,
                patternIndex: patternIndex + 1
            ) {
                return true
            }
            return false
        }
    }
}

private struct ComponentGlobMatcher {
    private enum Kind {
        case any
        case exact(String)
        case prefix(String)
        case suffix(String)
        case contains(String)
    }

    private let kind: Kind

    init(pattern: String) {
        if pattern == "*" {
            kind = .any
        } else if pattern.hasPrefix("*"), pattern.hasSuffix("*") {
            kind = .contains(String(pattern.dropFirst().dropLast()))
        } else if pattern.hasPrefix("*") {
            kind = .suffix(String(pattern.dropFirst()))
        } else if pattern.hasSuffix("*") {
            kind = .prefix(String(pattern.dropLast()))
        } else {
            kind = .exact(pattern)
        }
    }

    func matches(_ value: String) -> Bool {
        switch kind {
        case .any:
            return true
        case .exact(let literal):
            return value == literal
        case .prefix(let prefix):
            return value.hasPrefix(prefix)
        case .suffix(let suffix):
            return value.hasSuffix(suffix)
        case .contains(let fragment):
            return value.contains(fragment)
        }
    }
}
