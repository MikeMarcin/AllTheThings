import Foundation

final class FileExclusionQuery {
    private let roots: [String]
    private let rules: [Rule]
    private var ancestorRuleIndexCache: [String: Set<Int>] = [:]

    struct Instrumentation: Sendable, Equatable {
        var compiledExclusionDecisionCount = 0
        var componentSplitCount = 0
        var ancestorMatchCheckCount = 0
        var regexMatchCount = 0
        var fastPathDecisionCount = 0

        init() {}

        mutating func add(_ other: Instrumentation) {
            compiledExclusionDecisionCount += other.compiledExclusionDecisionCount
            componentSplitCount += other.componentSplitCount
            ancestorMatchCheckCount += other.ancestorMatchCheckCount
            regexMatchCount += other.regexMatchCount
            fastPathDecisionCount += other.fastPathDecisionCount
        }
    }

    init(patterns: [String] = FileExclusionRules.defaultPatterns, roots: [String]) {
        self.roots = roots
            .map(Self.normalizedRootPath)
            .sorted { $0.count > $1.count }
        self.rules = patterns.compactMap(Rule.init(rawPattern:))
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
        var excluded = false
        var finalMatchingRuleIndex: Int?
        var finalMatchingRule: Rule?

        let ignoredAncestorRuleIndexes = inheritedAncestorRuleIndexes(
            for: relativePaths,
            instrumentation: &instrumentation
        )

        for (index, rule) in rules.enumerated() {
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

        for (index, rule) in rules.enumerated() where !rule.isNegated {
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
}

private final class RelativePathContext {
    struct RangeKey: Hashable {
        let start: Int
        let end: Int
    }

    let value: String
    let components: [String]
    let lowercasedComponents: [String]
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
        isTraversalOnlyDirectoryReinclude = isNegated && isDirectoryPattern && !containsSlash && pattern == "*"
        literalPrefix = Self.literalPrefix(for: pattern)

        if Self.isLiteral(pattern) {
            matcher = .literal(
                lowercasedValue: pattern.lowercased(),
                lowercasedComponents: pattern.split(separator: "/").map { String($0).lowercased() }
            )
        } else {
            do {
                matcher = .regex(try NSRegularExpression(
                    pattern: Self.regexPattern(for: pattern),
                    options: [.caseInsensitive]
                ))
            } catch {
                return nil
            }
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
            Self.pathsMayOverlapForDescendant(rulePrefix: prefix, directoryPath: relativePath.value)
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
        instrumentation.regexMatchCount += 1
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
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

            if character == "*" {
                if nextIndex < pattern.endIndex, pattern[nextIndex] == "*" {
                    output += ".*"
                    index = pattern.index(after: nextIndex)
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

    private static func pathsMayOverlapForDescendant(rulePrefix: String, directoryPath: String) -> Bool {
        guard !directoryPath.isEmpty else { return true }
        return rulePrefix == directoryPath
            || rulePrefix.hasPrefix(directoryPath + "/")
            || directoryPath.hasPrefix(rulePrefix + "/")
    }
}

private enum Matcher {
    case literal(lowercasedValue: String, lowercasedComponents: [String])
    case regex(NSRegularExpression)
}
