import Foundation

public struct FileExclusionRules: @unchecked Sendable {
    public static let defaultPatterns = [
        "node_modules/",
        "DerivedData/",
        ".git/objects/",
        "Library/Caches/",
        ".Trash/"
    ]

    public let patterns: [String]
    private let rules: [Rule]

    public init(patterns: [String] = Self.defaultPatterns) {
        self.patterns = patterns
        self.rules = patterns.compactMap(Rule.init(rawPattern:))
    }

    public func excludes(url: URL, roots: [String], isDirectory: Bool? = nil) -> Bool {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        let relativePaths = Self.relativePaths(for: path, roots: roots)
        let pathComponents = path.split(separator: "/").map(String.init)
        let effectiveIsDirectory = isDirectory ?? standardized.hasDirectoryPath
        var excluded = false

        for rule in rules where rule.matches(
            name: standardized.lastPathComponent,
            pathComponents: pathComponents,
            relativePaths: relativePaths,
            isDirectory: effectiveIsDirectory
        ) {
            excluded = !rule.isNegated
        }

        return excluded
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
        private let isDirectoryPattern: Bool
        private let isAnchored: Bool
        private let containsSlash: Bool
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

            do {
                regex = try NSRegularExpression(pattern: Self.regexPattern(for: pattern), options: [.caseInsensitive])
            } catch {
                return nil
            }
        }

        func matches(
            name: String,
            pathComponents: [String],
            relativePaths: [String],
            isDirectory: Bool
        ) -> Bool {
            if !containsSlash {
                if isDirectoryPattern {
                    return pathComponents.contains { matchesWholeString($0) }
                }

                return matchesWholeString(name) || pathComponents.contains { matchesWholeString($0) }
            }

            for relativePath in relativePaths where matchesPath(relativePath, isDirectory: isDirectory) {
                return true
            }

            return false
        }

        private func matchesPath(_ relativePath: String, isDirectory: Bool) -> Bool {
            guard !relativePath.isEmpty else { return false }

            if isDirectoryPattern {
                let prefixes = directoryPrefixes(for: relativePath, isDirectory: isDirectory)
                return prefixes.contains { matchesPathCandidate($0) }
            }

            return matchesPathCandidate(relativePath)
        }

        private func directoryPrefixes(for relativePath: String, isDirectory: Bool) -> [String] {
            let components = relativePath.split(separator: "/").map(String.init)
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

            let components = candidate.split(separator: "/").map(String.init)
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
                } else {
                    output += NSRegularExpression.escapedPattern(for: String(character))
                    index = nextIndex
                }
            }

            output += "$"
            return output
        }
    }
}
