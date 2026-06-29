import Foundation

public struct FileExclusionRules: @unchecked Sendable {
    public static let defaultPatterns = [
        ".git/*",
        "!.git/config",
        "!.git/HEAD",
        "!.git/description",
        "!.git/hooks/**",
        "!.git/info/**",
        ".hg/store/",
        ".svn/pristine/",
        "node_modules/",
        "DerivedData/",
        ".gradle/caches/",
        ".dart_tool/",
        ".next/cache/",
        ".parcel-cache/",
        ".turbo/",
        "*.app/Contents/_CodeSignature/",
        "Xcode.app/Contents/Developer/Platforms/",
        "Xcode.app/Contents/Developer/Toolchains/",
        "Engine/Binaries/ThirdParty/DotNet/",
        "Engine/Binaries/ThirdParty/Python3/",
        "Engine/DerivedDataCache/",
        "Engine/Intermediate/",
        "Engine/Saved/",
        "CMakeFiles/",
        "Testing/Temporary/",
        ".build/**/index/store/",
        ".build/debug/",
        ".build/release/",
        ".build/*/debug/",
        ".build/*/release/",
        ".build/*/index/",
        ".build/*/ModuleCache/",
        ".build/plugins/",
        ".build/artifacts/",
        "build/.cmake/api/",
        "build/_deps/",
        "build/**/_deps/",
        "build/**/*.tmp*",
        "*.o",
        "*.pyc",
        "*.pyo",
        "*.dSYM/",
        "*.gcda",
        "*.gcno",
        "*.profraw",
        "*.profdata",
        ".venv/",
        "venv/",
        ".tox/",
        "__pycache__/",
        ".pytest_cache/",
        ".mypy_cache/",
        ".ruff_cache/",
        ".cache/",
        "Library/Caches/",
        ".Trash/"
    ]

    public let patterns: [String]
    private let rules: [Rule]
    // FileIndex copies this value into concurrent scan workers; the reference lock keeps
    // those copies coordinated while they share Rule instances and regex matchers.
    private let decisionLock = NSLock()

    public enum Decision: Sendable, Equatable {
        case index
        case skipButDescend
        case prune

        public var shouldIndex: Bool {
            self == .index
        }

        public var shouldDescend: Bool {
            self != .prune
        }
    }

    public init(patterns: [String] = Self.defaultPatterns) {
        self.patterns = patterns
        self.rules = patterns.compactMap(Rule.init(rawPattern:))
    }

    public func excludes(url: URL, roots: [String], isDirectory: Bool? = nil) -> Bool {
        decision(url: url, roots: roots, isDirectory: isDirectory) != .index
    }

    public func decision(url: URL, roots: [String], isDirectory: Bool? = nil) -> Decision {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        let relativePaths = Self.relativePaths(for: path, roots: roots)
        let effectiveIsDirectory = isDirectory ?? standardized.hasDirectoryPath

        decisionLock.lock()
        defer { decisionLock.unlock() }

        var excluded = false
        var finalMatchingRuleIndex: Int?
        var finalMatchingRule: Rule?

        for (index, rule) in rules.enumerated() {
            let matchesTarget = rule.matches(
                relativePaths: relativePaths,
                isDirectory: effectiveIsDirectory
            )
            let matchesIgnoredAncestor = !matchesTarget && rule.matchesIgnoredAncestor(of: relativePaths)
            guard matchesTarget || matchesIgnoredAncestor else { continue }

            excluded = !rule.isNegated
            finalMatchingRuleIndex = index
            finalMatchingRule = rule
        }

        guard effectiveIsDirectory else {
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

    private static func relativePaths(for path: String, roots: [String]) -> [String] {
        var relativePaths: [String] = []

        for root in roots.sorted(by: { $0.count > $1.count }) {
            if path == root {
                relativePaths.append("")
            } else if path.hasPrefix(root + "/") {
                relativePaths.append(String(path.dropFirst(root.count + 1)))
            }
        }

        return relativePaths.isEmpty ? [path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))] : relativePaths
    }

    private final class Rule: @unchecked Sendable {
        let isNegated: Bool
        let isTraversalOnlyDirectoryReinclude: Bool
        private let isDirectoryPattern: Bool
        private let isAnchored: Bool
        private let containsSlash: Bool
        private let literalPrefix: String
        private let regex: NSRegularExpression

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

            do {
                regex = try NSRegularExpression(pattern: Self.regexPattern(for: pattern), options: [.caseInsensitive])
            } catch {
                return nil
            }
        }

        func matches(
            relativePaths: [String],
            isDirectory: Bool
        ) -> Bool {
            for relativePath in relativePaths where matches(relativePath: relativePath, isDirectory: isDirectory) {
                return true
            }

            return false
        }

        func mayReincludeDescendant(of relativePaths: [String]) -> Bool {
            guard isNegated, !isTraversalOnlyDirectoryReinclude, containsSlash, !literalPrefix.isEmpty else {
                return false
            }

            let prefix = literalPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !prefix.isEmpty else { return false }

            return relativePaths.contains { relativePath in
                Self.pathsMayOverlapForDescendant(rulePrefix: prefix, directoryPath: relativePath)
            }
        }

        func matchesIgnoredAncestor(of relativePaths: [String]) -> Bool {
            guard !isNegated else { return false }

            return relativePaths.contains { relativePath in
                let components = Self.components(for: relativePath)
                guard components.count > 1 else { return false }

                if !containsSlash {
                    let ancestorComponents = components.dropLast()
                    if isAnchored {
                        guard let firstAncestor = ancestorComponents.first else { return false }
                        return matchesWholeString(String(firstAncestor))
                    }

                    return ancestorComponents.contains { matchesWholeString(String($0)) }
                }

                var ancestor = ""
                for component in components.dropLast() {
                    if ancestor.isEmpty {
                        ancestor = String(component)
                    } else {
                        ancestor += "/"
                        ancestor += String(component)
                    }
                    if matchesPathCandidate(ancestor) {
                        return true
                    }
                }

                return false
            }
        }

        private func matches(relativePath: String, isDirectory: Bool) -> Bool {
            if !containsSlash {
                if isAnchored {
                    return matchesPath(relativePath, isDirectory: isDirectory)
                }

                return matchesComponentPattern(relativePath: relativePath, isDirectory: isDirectory)
            }

            return matchesPath(relativePath, isDirectory: isDirectory)
        }

        private func matchesComponentPattern(relativePath: String, isDirectory: Bool) -> Bool {
            let components = Self.components(for: relativePath)
            guard !components.isEmpty else { return false }

            if isDirectoryPattern {
                if isNegated, !isDirectory {
                    return false
                }

                let directoryComponents = isDirectory ? components : components.dropLast()
                return directoryComponents.contains { matchesWholeString($0) }
            }

            return components.contains { matchesWholeString($0) }
        }

        private func matchesPath(_ relativePath: String, isDirectory: Bool) -> Bool {
            guard !relativePath.isEmpty else { return false }

            if isNegated, isDirectoryPattern, !isDirectory {
                return false
            }

            if isDirectoryPattern {
                let prefixes = directoryPrefixes(for: relativePath, isDirectory: isDirectory)
                return prefixes.contains { matchesPathCandidate($0) }
            }

            return matchesPathCandidate(relativePath)
        }

        private func directoryPrefixes(for relativePath: String, isDirectory: Bool) -> [String] {
            let components = Self.components(for: relativePath)
            guard !components.isEmpty else { return [] }

            let prefixCount = isDirectory ? components.count : max(components.count - 1, 0)
            guard prefixCount > 0 else { return [] }

            return (1...prefixCount).map { components.prefix($0).joined(separator: "/") }
        }

        private func matchesPathCandidate(_ candidate: String) -> Bool {
            if matchesWholeString(candidate) {
                return true
            }

            guard !isAnchored else { return false }

            let components = Self.components(for: candidate)
            guard components.count > 1 else { return false }

            for index in 1..<components.count where matchesWholeString(components[index...].joined(separator: "/")) {
                return true
            }

            return false
        }

        private func matchesWholeString(_ value: String) -> Bool {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return regex.firstMatch(in: value, options: [], range: range) != nil
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

        private static func components(for path: String) -> [String] {
            path.split(separator: "/").map(String.init)
        }
    }
}
