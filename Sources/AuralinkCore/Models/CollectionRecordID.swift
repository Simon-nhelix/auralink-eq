import Foundation

/// Safe ID validation for collection records (presets, headphone profiles).
///
/// Collection directories are user-owned (often git checkouts) and can contain
/// records from various sources. This validation ensures IDs cannot escape the
/// intended directory via path traversal (e.g., `../manifest`, `../../etc`).
///
/// Contract:
/// - Alphanumeric start, then alphanumeric + `._-`
/// - Max 128 characters
/// - No `..` sequences
/// - No leading/trailing dots or dashes
///
/// Used by `PresetStore`, `KnowledgeBase`, and the migration script.
public enum CollectionRecordID {
    public static let maxLength = 128

    /// Validates that `id` is safe for filesystem use.
    /// - Returns: `true` if the ID matches the safe pattern
    public static func isValid(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return false }
        guard trimmed != ".", trimmed != ".." else { return false }
        guard !trimmed.contains("..") else { return false }
        guard !trimmed.hasPrefix("-"), !trimmed.hasPrefix(".") else { return false }
        guard !trimmed.hasSuffix("."), !trimmed.hasSuffix("-") else { return false }

        // Must start with alphanumeric, then allow alphanumeric + ._-
        guard let first = trimmed.first, first.isLetter || first.isNumber else { return false }
        for char in trimmed.dropFirst() {
            guard char.isLetter || char.isNumber || char == "." || char == "_" || char == "-" else {
                return false
            }
        }
        return true
    }

    /// Returns the ID if valid, nil otherwise.
    public static func parse(_ id: String) -> String? {
        isValid(id) ? id.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    /// Returns the ID if valid, throws otherwise.
    public static func require(_ id: String) throws -> String {
        guard let valid = parse(id) else {
            throw CollectionRecordIDError.invalid(id)
        }
        return valid
    }

    /// Creates a file URL within `directory` for the given ID.
    /// - Throws: `CollectionRecordIDError` if the ID is invalid or the resolved path escapes the directory
    public static func fileURL(in directory: URL, id: String, ext: String = "json") throws -> URL {
        let safeID = try require(id)
        let url = directory.appendingPathComponent("\(safeID).\(ext)", isDirectory: false)
        try assertContained(url, in: directory)
        return url
    }

    /// Creates a subdirectory URL within `directory` for the given ID.
    /// - Throws: `CollectionRecordIDError` if the ID is invalid or the resolved path escapes the directory
    public static func subdirectory(in directory: URL, id: String) throws -> URL {
        let safeID = try require(id)
        let url = directory.appendingPathComponent(safeID, isDirectory: true)
        try assertContained(url, in: directory)
        return url
    }

    /// Asserts that `url` is contained within `base` (defense-in-depth).
    private static func assertContained(_ url: URL, in base: URL) throws {
        let urlPath = url.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        guard urlPath.hasPrefix(basePath + "/") else {
            throw CollectionRecordIDError.containment(url: url, base: base)
        }
    }
}

public enum CollectionRecordIDError: Error, LocalizedError {
    case invalid(String)
    case containment(url: URL, base: URL)

    public var errorDescription: String? {
        switch self {
        case .invalid(let id):
            return "Invalid collection record ID: '\(id)'. IDs must start with a letter or number, contain only letters, numbers, dots, underscores, and dashes, and be at most \(CollectionRecordID.maxLength) characters."
        case .containment(let url, let base):
            return "Path traversal detected: '\(url.path)' escapes the collection directory '\(base.path)'."
        }
    }
}
