import Foundation

/// Release ordering includes prereleases: alpha.2 < alpha.10 < beta < stable.
/// Build metadata does not affect precedence. Dotted numbers may have 1–4 parts.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    private let numbers: [Int]
    public let prerelease: [String]
    public let description: String

    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let build = text.split(separator: "+", omittingEmptySubsequences: false)
        guard build.count <= 2, build.count == 1 || Self.identifiers(String(build[1])) != nil else { return nil }
        let components = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let parts = components[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        let prerelease: [String]
        if components.count == 2 {
            guard let identifiers = Self.identifiers(String(components[1])),
                  identifiers.allSatisfy({ !$0.allSatisfy(\.isNumber) || ($0.count == 1 || $0.first != "0") }) else { return nil }
            prerelease = identifiers
        } else { prerelease = [] }
        self.prerelease = prerelease
        description = numbers.map(String.init).joined(separator: ".")
            + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
        while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
        self.numbers = numbers
    }

    private static func identifiers(_ text: String) -> [String]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else { return nil }
        return parts
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumeric = left.allSatisfy(\.isNumber), rightNumeric = right.allSatisfy(\.isNumber)
            if leftNumeric != rightNumeric { return leftNumeric }
            if leftNumeric, left.count != right.count { return left.count < right.count }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.numbers == rhs.numbers && lhs.prerelease == rhs.prerelease
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(numbers); hasher.combine(prerelease) }
}
