import Foundation

public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let size: Int64
        public let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }
    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: URL
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", htmlURL = "html_url"
        case name, body, draft, prerelease, assets
    }
}

public enum UpdateChannel: String, Sendable {
    case stable, beta, alpha
    public func allows(_ version: AppVersion) -> Bool {
        if version.prerelease.isEmpty { return true }
        switch (self, version.prerelease.first) {
        case (.alpha, "alpha"), (.alpha, "beta"), (.alpha, "rc"), (.beta, "beta"), (.beta, "rc"): return true
        default: return false
        }
    }
}

public struct UpdateOffer: Sendable, Equatable {
    public let version: AppVersion
    public let title: String
    public let notes: String
    public let pageURL: URL
    public let archiveURL: URL
    public let archiveSize: Int64
    public let signatureURL: URL?

    public init(version: AppVersion, title: String, notes: String, pageURL: URL, archiveURL: URL, archiveSize: Int64, signatureURL: URL?) {
        self.version = version; self.title = title; self.notes = notes; self.pageURL = pageURL
        self.archiveURL = archiveURL; self.archiveSize = archiveSize; self.signatureURL = signatureURL
    }
}

public enum ReleaseFeed {
    public static let archivePrefix = "Auralink-EQ-"
    public static let maximumArchiveSize: Int64 = 512 * 1024 * 1024

    public static func releasesURL(repository: String) -> URL? {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }) else { return nil }
        // /latest excludes prereleases; list releases so alpha users can update too.
        return URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100")
    }

    public static func offer(from release: GitHubRelease, channel: UpdateChannel = .stable) -> UpdateOffer? {
        guard !release.draft, let version = AppVersion(release.tagName), channel.allows(version),
              !release.prerelease || !version.prerelease.isEmpty,
              isAllowed(release.htmlURL),
              let archive = release.assets.first(where: { $0.name == "\(archivePrefix)\(version).zip" }),
              archive.size > 0, archive.size <= maximumArchiveSize, isAllowed(archive.browserDownloadURL) else { return nil }
        let signature = release.assets.first { $0.name == archive.name + ".sig" && (1...256).contains($0.size) && isAllowed($0.browserDownloadURL) }
        let title = release.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return UpdateOffer(version: version, title: title.isEmpty ? release.tagName : title,
                           notes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                           pageURL: release.htmlURL, archiveURL: archive.browserDownloadURL,
                           archiveSize: archive.size, signatureURL: signature?.browserDownloadURL)
    }

    public static func newestOffer(in releases: [GitHubRelease], channel: UpdateChannel) -> UpdateOffer? {
        releases.compactMap { offer(from: $0, channel: channel) }.max { $0.version < $1.version }
    }

    public static func fetchReleases(from url: URL, userAgent: String, session: URLSession = .shared) async throws -> [GitHubRelease] {
        guard isAllowed(url) else { throw UpdateError.insecureURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .timedOut, .dnsLookupFailed].contains(error.code) { throw UpdateError.offline }
        guard let http = response as? HTTPURLResponse, let finalURL = http.url, isAllowed(finalURL) else { throw UpdateError.badResponse }
        if http.statusCode == 403 || http.statusCode == 429 { throw UpdateError.rateLimited }
        // A missing repository is an error; an existing repository without releases returns [].
        guard (200..<300).contains(http.statusCode) else { throw UpdateError.server(http.statusCode) }
        guard let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) else { throw UpdateError.badResponse }
        return releases
    }

    public static func isAllowed(_ url: URL, allowingLocalFiles: Bool = false) -> Bool {
        if url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty, url.user == nil, url.password == nil { return true }
        return allowingLocalFiles && url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
    }
}
