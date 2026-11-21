import AppKit
import CryptoKit
import Darwin
import Foundation

// MARK: - SemVer Model

/// Strict semantic version supporting optional leading `v`/`V`, pre-release identifiers
/// (where a final release sorts strictly greater than the same core pre-release), and `+build` metadata.
public struct PulsarSemVer: Comparable, Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = max(0, major)
        self.minor = max(0, minor)
        self.patch = max(0, patch)
        self.prerelease = prerelease.filter { !$0.isEmpty }
    }

    public init?(_ raw: String) {
        guard let parsed = Self.parse(raw) else { return nil }
        self = parsed
    }

    public static func parse(_ raw: String) -> PulsarSemVer? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }
        guard !s.isEmpty else { return nil }

        // Strip SemVer build metadata (`+...`) which does not affect precedence.
        if let plusIdx = s.firstIndex(of: "+") {
            s = String(s[..<plusIdx])
        }
        guard !s.isEmpty else { return nil }

        let corePart: String
        let prereleasePart: String?
        if let dashIdx = s.firstIndex(of: "-") {
            corePart = String(s[..<dashIdx])
            let tail = String(s[s.index(after: dashIdx)...])
            guard !tail.isEmpty else { return nil }
            prereleasePart = tail
        } else {
            corePart = s
            prereleasePart = nil
        }

        let coreSegments = corePart.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(coreSegments.count) else { return nil }

        var nums: [Int] = []
        nums.reserveCapacity(3)
        for seg in coreSegments {
            guard !seg.isEmpty, seg.allSatisfy(\.isNumber), let val = Int(seg), val >= 0 else {
                return nil
            }
            nums.append(val)
        }
        while nums.count < 3 {
            nums.append(0)
        }

        var prereleaseIds: [String] = []
        if let prereleasePart {
            let parts = prereleasePart.split(separator: ".", omittingEmptySubsequences: false)
            for part in parts {
                guard !part.isEmpty else { return nil }
                let allowed = part.allSatisfy { ch in
                    ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-")
                }
                guard allowed else { return nil }
                prereleaseIds.append(String(part))
            }
        }

        return PulsarSemVer(
            major: nums[0],
            minor: nums[1],
            patch: nums[2],
            prerelease: prereleaseIds
        )
    }

    public var isPrerelease: Bool {
        !prerelease.isEmpty
    }

    public var normalizedString: String {
        let base = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? base : "\(base)-\(prerelease.joined(separator: "."))"
    }

    public var description: String {
        normalizedString
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = Self.parse(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid semantic version: \(raw)"
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(normalizedString)
    }

    public static func < (lhs: PulsarSemVer, rhs: PulsarSemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // Release version strictly outranks any pre-release of the same core tuple.
        if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        let count = min(lhs.prerelease.count, rhs.prerelease.count)
        for i in 0..<count {
            let a = lhs.prerelease[i]
            let b = rhs.prerelease[i]
            if a == b { continue }

            let aNum = a.allSatisfy(\.isNumber) ? Int(a) : nil
            let bNum = b.allSatisfy(\.isNumber) ? Int(b) : nil
            switch (aNum, bNum) {
            case (let na?, let nb?):
                return na < nb
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

// MARK: - Release Info & State Machine Models

public struct ReleaseUpdateInfo: Codable, Equatable, Hashable, Sendable {
    public let version: String
    public let tagName: String
    public let title: String
    public let releaseNotes: String
    public let htmlURL: URL
    public let dmgDownloadURL: URL?
    public let dmgFileName: String?
    public let sha256DownloadURL: URL?
    public let publishedAt: Date?
    public let assetSizeBytes: Int64?

    public init(
        version: String,
        tagName: String,
        title: String,
        releaseNotes: String,
        htmlURL: URL,
        dmgDownloadURL: URL? = nil,
        dmgFileName: String? = nil,
        sha256DownloadURL: URL? = nil,
        publishedAt: Date? = nil,
        assetSizeBytes: Int64? = nil
    ) {
        self.version = version
        self.tagName = tagName
        self.title = title
        self.releaseNotes = releaseNotes
        self.htmlURL = htmlURL
        self.dmgDownloadURL = dmgDownloadURL
        self.dmgFileName = dmgFileName
        self.sha256DownloadURL = sha256DownloadURL
        self.publishedAt = publishedAt
        self.assetSizeBytes = assetSizeBytes
    }
}

public enum ReleaseUpdateCheckResult: Equatable, Sendable {
    case updateAvailable(ReleaseUpdateInfo)
    case upToDate(latestVersion: String?, checkedAt: Date)
    case notModified(checkedAt: Date)
}

public enum ReleaseUpdatePhase: Equatable, Sendable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case available(ReleaseUpdateInfo)
    case downloading(ReleaseUpdateInfo, progress: Double)
    case verifying(ReleaseUpdateInfo)
    case installing(ReleaseUpdateInfo)
    case readyToRelaunch(ReleaseUpdateInfo)
    case manualInstallOpened(ReleaseUpdateInfo, dmgPath: String)
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .checking, .downloading, .verifying, .installing, .readyToRelaunch:
            return true
        case .idle, .upToDate, .available, .manualInstallOpened, .failed:
            return false
        }
    }

    public var updateInfo: ReleaseUpdateInfo? {
        switch self {
        case .available(let info),
             .downloading(let info, _),
             .verifying(let info),
             .installing(let info),
             .readyToRelaunch(let info),
             .manualInstallOpened(let info, _):
            return info
        case .idle, .checking, .upToDate, .failed:
            return nil
        }
    }
}

public enum ReleaseUpdaterError: Error, LocalizedError, Equatable, Sendable {
    case disallowedHost(String)
    case networkFailure(String)
    case invalidReleasePayload(String)
    case missingAsset(String)
    case missingChecksum(String)
    case checksumMismatch(String)
    case mountFailed(String)
    case appBundleMissing(String)
    case bundleIdentifierMismatch(String)
    case codeSignatureInvalid(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .disallowedHost(let msg),
             .networkFailure(let msg),
             .invalidReleasePayload(let msg),
             .missingAsset(let msg),
             .missingChecksum(let msg),
             .checksumMismatch(let msg),
             .mountFailed(let msg),
             .appBundleMissing(let msg),
             .bundleIdentifierMismatch(let msg),
             .codeSignatureInvalid(let msg),
             .installFailed(let msg):
            return msg
        }
    }
}

// MARK: - Strict Redirect-Guarded URLSession Delegates

private final class AllowlistedRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, ReleaseUpdater.isAllowedHost(url) else {
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }
}

private final class AllowlistedDownloadDelegate: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let fallbackExpectedBytes: Int64?
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, HTTPURLResponse?), Error>?
    private var moveError: Error?
    private var rejectedRedirectHost: String?
    private var lastReportedProgress: Double = -1.0
    private var lastReportedTime: TimeInterval = 0

    init(
        destinationURL: URL,
        fallbackExpectedBytes: Int64?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) {
        self.destinationURL = destinationURL
        self.fallbackExpectedBytes = fallbackExpectedBytes
        self.onProgress = onProgress
        super.init()
    }

    func setContinuation(_ continuation: CheckedContinuation<(URL, HTTPURLResponse?), Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, ReleaseUpdater.isAllowedHost(url) else {
            lock.lock()
            rejectedRedirectHost = request.url?.absoluteString ?? "unknown"
            lock.unlock()
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : (fallbackExpectedBytes ?? 0)
        guard expected > 0 else { return }

        let progress = min(max(Double(totalBytesWritten) / Double(expected), 0.0), 1.0)
        let now = Date().timeIntervalSinceReferenceDate

        lock.lock()
        let shouldEmit = (progress >= 1.0 && lastReportedProgress < 1.0)
            || (progress - lastReportedProgress >= 0.01)
            || (now - lastReportedTime >= 0.08)
        if shouldEmit {
            lastReportedProgress = progress
            lastReportedTime = now
        }
        lock.unlock()

        if shouldEmit {
            onProgress(progress)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.moveItem(at: location, to: destinationURL)
        } catch {
            lock.lock()
            moveError = error
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let moveErr = moveError
        let badRedirect = rejectedRedirectHost
        lock.unlock()

        guard let cont else { return }

        if let badRedirect {
            cont.resume(throwing: ReleaseUpdaterError.disallowedHost("拒绝跳转至非白名单下载地址：\(badRedirect)"))
            return
        }
        if let error {
            cont.resume(throwing: ReleaseUpdaterError.networkFailure("下载安装包失败：\(error.localizedDescription)"))
            return
        }
        if let moveErr {
            cont.resume(throwing: ReleaseUpdaterError.installFailed("写入临时安装包失败：\(moveErr.localizedDescription)"))
            return
        }

        let httpResp = task.response as? HTTPURLResponse
        cont.resume(returning: (destinationURL, httpResp))
    }
}

// MARK: - Native GitHub Releases Auto-Updater

public final class ReleaseUpdater: @unchecked Sendable {
    public static let allowedHosts: Set<String> = [
        "api.github.com",
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    public static let defaultLatestReleaseURL = URL(
        string: "https://api.github.com/repos/rorywang98-netizen/Pulsar/releases/latest"
    )!

    public static let releasesPageURL = URL(
        string: "https://github.com/rorywang98-netizen/Pulsar/releases"
    )!

    private let latestReleaseURL: URL
    private let injectedSession: URLSession?
    private let runningAppBundleURL: URL
    private let downloadsDirectoryURL: URL
    private let expectedBundleIdentifier: String
    private let relaunchTerminator: @Sendable () async -> Void
    private let openManualInstaller: @Sendable (URL) async -> Void

    private let cacheLock = NSLock()
    private var cachedETag: String?
    private var cachedReleaseData: Data?

    public init(
        latestReleaseURL: URL = ReleaseUpdater.defaultLatestReleaseURL,
        session: URLSession? = nil,
        runningAppBundleURL: URL = Bundle.main.bundleURL,
        downloadsDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true),
        expectedBundleIdentifier: String = AppStore.bundleIdentifier,
        relaunchTerminator: (@Sendable () async -> Void)? = nil,
        openManualInstaller: (@Sendable (URL) async -> Void)? = nil
    ) {
        self.latestReleaseURL = latestReleaseURL
        self.injectedSession = session
        self.runningAppBundleURL = runningAppBundleURL
        self.downloadsDirectoryURL = downloadsDirectoryURL
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.relaunchTerminator = relaunchTerminator ?? {
            await MainActor.run {
                NSApp.terminate(nil)
            }
        }
        self.openManualInstaller = openManualInstaller ?? { url in
            await MainActor.run {
                _ = NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Strict Host Allowlist & Pure Testable Helpers

    /// Returns `true` only for HTTPS URLs targeting the exact GitHub Releases host allowlist without embedded credentials.
    public static func isAllowedHost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return false
        }
        return allowedHosts.contains(host)
    }

    /// Pure parser for the GitHub Releases `/releases/latest` JSON payload.
    /// Ignores `draft` and `prerelease` releases, selects the best `arm64` `.dmg` asset and its matching `.sha256` file,
    /// and strictly validates every URL against `isAllowedHost(_:)`.
    public static func parseLatestReleaseJSON(
        _ data: Data,
        currentVersion: String,
        checkedAt: Date = Date()
    ) throws -> ReleaseUpdateCheckResult {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            throw ReleaseUpdaterError.invalidReleasePayload("GitHub Release 返回了无效的 JSON 数据")
        }

        if let isDraft = root["draft"] as? Bool, isDraft {
            return .upToDate(latestVersion: nil, checkedAt: checkedAt)
        }
        if let isPrerelease = root["prerelease"] as? Bool, isPrerelease {
            return .upToDate(latestVersion: nil, checkedAt: checkedAt)
        }

        guard let rawTag = (root["tag_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTag.isEmpty,
              let remoteVer = PulsarSemVer.parse(rawTag) else {
            throw ReleaseUpdaterError.invalidReleasePayload("无法解析最新版本标签（tag_name）")
        }

        let currentVer = PulsarSemVer.parse(currentVersion) ?? PulsarSemVer(major: 0, minor: 0, patch: 0)

        let htmlURL: URL
        if let rawHTML = (root["html_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawHTML.isEmpty {
            guard let parsedHTML = URL(string: rawHTML), isAllowedHost(parsedHTML) else {
                throw ReleaseUpdaterError.disallowedHost("Release 页面地址不在白名单中")
            }
            htmlURL = parsedHTML
        } else {
            htmlURL = releasesPageURL
        }

        guard remoteVer > currentVer else {
            return .upToDate(latestVersion: remoteVer.normalizedString, checkedAt: checkedAt)
        }

        let rawTitle = (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (rawTitle?.isEmpty == false) ? rawTitle! : "Pulsar \(rawTag)"
        let releaseNotes = (root["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let publishedAt = (root["published_at"] as? String).flatMap(Formatters.parseRFC3339)

        struct ParsedAsset {
            let name: String
            let downloadURL: URL
            let size: Int64?
        }

        var assets: [ParsedAsset] = []
        if let rawAssets = root["assets"] as? [[String: Any]] {
            for item in rawAssets {
                guard let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty,
                      let rawURL = (item["browser_download_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let url = URL(string: rawURL),
                      isAllowedHost(url) else {
                    continue
                }
                let size = (item["size"] as? NSNumber)?.int64Value
                assets.append(ParsedAsset(name: name, downloadURL: url, size: size))
            }
        }

        let dmgAssets = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let chosenDMG = dmgAssets.first(where: { $0.name.lowercased().contains("arm64") })
            ?? dmgAssets.first(where: { $0.name.lowercased().contains("macos") })
            ?? dmgAssets.first

        let chosenSHA: ParsedAsset?
        if let dmg = chosenDMG {
            let dmgLower = dmg.name.lowercased()
            let dmgStemLower = URL(fileURLWithPath: dmg.name).deletingPathExtension().lastPathComponent.lowercased()
            chosenSHA = assets.first(where: { $0.name.lowercased() == "\(dmgLower).sha256" })
                ?? assets.first(where: {
                    let n = $0.name.lowercased()
                    return n == "\(dmgLower).sha256.txt" || n == "\(dmgLower).sha256sum"
                })
                ?? assets.first(where: {
                    let n = $0.name.lowercased()
                    return n.hasSuffix(".sha256") && n.contains(dmgStemLower)
                })
                ?? assets.first(where: {
                    let n = $0.name.lowercased()
                    return n.hasSuffix(".sha256") && n.contains("arm64")
                })
                ?? assets.first(where: {
                    let n = $0.name.lowercased()
                    return n == "sha256sums" || n == "sha256sums.txt" || n == "checksums.txt"
                })
                ?? assets.first(where: { $0.name.lowercased().hasSuffix(".sha256") })
        } else {
            chosenSHA = nil
        }

        let info = ReleaseUpdateInfo(
            version: remoteVer.normalizedString,
            tagName: rawTag,
            title: title,
            releaseNotes: releaseNotes,
            htmlURL: htmlURL,
            dmgDownloadURL: chosenDMG?.downloadURL,
            dmgFileName: chosenDMG?.name,
            sha256DownloadURL: chosenSHA?.downloadURL,
            publishedAt: publishedAt,
            assetSizeBytes: chosenDMG?.size
        )
        return .updateAvailable(info)
    }

    /// Extracts an exact 64-character lowercase SHA-256 hex digest from standard `shasum`, GNU `sha256sum`,
    /// BSD/OpenSSL tagged format (`SHA256 (file) = <hex>`), or bare single-hash checksum files.
    public static func parseSHA256Text(_ text: String, expectedFileName: String? = nil) -> String? {
        let targetNameLower = expectedFileName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/")
            .last
            .map { String($0).lowercased() }

        struct Entry {
            let hex: String
            let fileName: String?
        }

        var entries: [Entry] = []
        let lines = text.components(separatedBy: .newlines)

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            // Format A: BSD/OpenSSL `SHA256 (filename.dmg) = <64-hex>`
            if let eqRange = line.range(of: "="),
               let openParen = line.firstIndex(of: "("),
               let closeParen = line.lastIndex(of: ")"),
               openParen < closeParen,
               closeParen < eqRange.lowerBound {
                let rawHash = String(line[eqRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let validHex = normalizedHex64(rawHash) {
                    let rawName = String(line[line.index(after: openParen)..<closeParen])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let baseName = URL(fileURLWithPath: rawName).lastPathComponent
                    entries.append(Entry(hex: validHex, fileName: baseName.isEmpty ? nil : baseName))
                    continue
                }
            }

            // Format B: `<64-hex>  [*|./]filename.dmg` or bare `<64-hex>`
            let parts = line.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard let firstToken = parts.first,
                  let validHex = normalizedHex64(String(firstToken)) else {
                continue
            }

            if parts.count == 1 {
                entries.append(Entry(hex: validHex, fileName: nil))
            } else {
                var rawFile = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                if rawFile.hasPrefix("*") {
                    rawFile.removeFirst()
                    rawFile = rawFile.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let baseName = URL(fileURLWithPath: rawFile).lastPathComponent
                entries.append(Entry(hex: validHex, fileName: baseName.isEmpty ? nil : baseName))
            }
        }

        guard !entries.isEmpty else { return nil }

        if let targetNameLower, !targetNameLower.isEmpty {
            if let exact = entries.first(where: { $0.fileName?.lowercased() == targetNameLower }) {
                return exact.hex
            }
            // If file has a single unnamed bare hash, accept it; if it only names other files, reject!
            if entries.count == 1, entries[0].fileName == nil {
                return entries[0].hex
            }
            return nil
        }

        return entries[0].hex
    }

    private static func normalizedHex64(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 64 else { return nil }
        for scalar in trimmed.unicodeScalars {
            let v = scalar.value
            let isDigit = (v >= 48 && v <= 57) // 0-9
            let isLowerHex = (v >= 97 && v <= 102) // a-f
            guard isDigit || isLowerHex else { return nil }
        }
        return trimmed
    }

    /// Computes lowercase hex SHA-256 of a file using streaming 64 KB chunks (`CryptoKit.SHA256`).
    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = CryptoKit.SHA256()
        let chunkSize = 65_536
        while true {
            let chunk: Data? = try autoreleasepool {
                try handle.read(upToCount: chunkSize)
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Escapes any string strictly for POSIX `/bin/sh` single-quoted literals (`'` -> `'\''`).
    public static func shellSingleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Determines whether Pulsar is running from a writable `.app` bundle outside read-only `/Volumes/` / AppTranslocation.
    public static func canInstallInPlace(
        currentAppURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let stdURL = currentAppURL.standardizedFileURL
        guard stdURL.pathExtension.lowercased() == "app" else { return false }
        let path = stdURL.path
        if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") {
            return false
        }
        let parentDir = stdURL.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: parentDir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return fileManager.isWritableFile(atPath: parentDir.path)
    }

    /// Builds a detached POSIX `/bin/sh` atomic app-bundle swap script with strict single-quote escaping,
    /// automatic rollback on failure, and smart LaunchAgent / `open` relaunch.
    public static func buildSwapScript(
        pid: Int32,
        targetAppPath: String,
        stagingAppPath: String,
        backupAppPath: String,
        tempDirPath: String,
        launchAgentLabel: String = AppStore.bundleIdentifier
    ) -> String {
        let qTarget = shellSingleQuote(targetAppPath)
        let qStaging = shellSingleQuote(stagingAppPath)
        let qBackup = shellSingleQuote(backupAppPath)
        let qTempDir = shellSingleQuote(tempDirPath)
        let qLabel = shellSingleQuote(launchAgentLabel)

        return """
        #!/bin/sh
        set -u
        PID=\(pid)
        TARGET=\(qTarget)
        STAGING=\(qStaging)
        BACKUP=\(qBackup)
        TMPDIR_CLEAN=\(qTempDir)
        LABEL=\(qLabel)
        UID_NUM="$(/usr/bin/id -u)"

        i=0
        while [ "$i" -lt 150 ]; do
          if ! /bin/kill -0 "$PID" 2>/dev/null; then
            break
          fi
          /bin/sleep 0.1
          i=$((i + 1))
        done

        /bin/rm -rf "$BACKUP" 2>/dev/null || true
        if [ -e "$TARGET" ]; then
          if ! /bin/mv "$TARGET" "$BACKUP"; then
            /bin/rm -rf "$STAGING" "$TMPDIR_CLEAN" 2>/dev/null || true
            exit 1
          fi
        fi

        if ! /bin/mv "$STAGING" "$TARGET"; then
          if [ -e "$BACKUP" ]; then
            /bin/mv "$BACKUP" "$TARGET" 2>/dev/null || true
          fi
          /bin/rm -rf "$STAGING" "$TMPDIR_CLEAN" 2>/dev/null || true
          exit 1
        fi

        /bin/rm -rf "$BACKUP" 2>/dev/null || true

        if [ "$TARGET" = "/Applications/RoryOrbit.app" ] && /bin/launchctl print "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1; then
          /bin/launchctl kickstart -k "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1 || /usr/bin/open "$TARGET"
        else
          /usr/bin/open "$TARGET"
        fi

        /bin/rm -rf "$TMPDIR_CLEAN" 2>/dev/null || true
        """
    }

    private func readETagCache() -> (etag: String?, data: Data?) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return (cachedETag, cachedReleaseData)
    }

    private func writeETagCache(etag: String?, data: Data) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let etag, !etag.isEmpty {
            cachedETag = etag
        }
        cachedReleaseData = data
    }

    // MARK: - Network Check (`GET /releases/latest` with ETag)

    public func checkLatestRelease(
        currentVersion: String = AppStore.appVersion
    ) async throws -> ReleaseUpdateCheckResult {
        guard Self.isAllowedHost(latestReleaseURL) else {
            throw ReleaseUpdaterError.disallowedHost("更新检查地址不在安全白名单内：\(latestReleaseURL.absoluteString)")
        }

        var request = URLRequest(url: latestReleaseURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15.0
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Pulsar/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (savedETag, savedData) = readETagCache()

        if let savedETag, !savedETag.isEmpty {
            request.setValue(savedETag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await performAllowlistedDataRequest(request, timeout: 15.0)
        guard let http = response as? HTTPURLResponse else {
            throw ReleaseUpdaterError.networkFailure("检查更新失败：未收到有效的 HTTP 响应")
        }
        if let finalURL = http.url, !Self.isAllowedHost(finalURL) {
            throw ReleaseUpdaterError.disallowedHost("响应来源不在安全白名单内：\(finalURL.absoluteString)")
        }

        let now = Date()
        if http.statusCode == 304 {
            if let savedData {
                return try Self.parseLatestReleaseJSON(savedData, currentVersion: currentVersion, checkedAt: now)
            }
            return .notModified(checkedAt: now)
        }

        if http.statusCode == 403 {
            throw ReleaseUpdaterError.networkFailure("GitHub API 触发访问频率限制，请稍后重试")
        }
        if http.statusCode == 404 {
            return .upToDate(latestVersion: nil, checkedAt: now)
        }
        guard (200...299).contains(http.statusCode) else {
            throw ReleaseUpdaterError.networkFailure("检查更新失败（HTTP \(http.statusCode)）")
        }

        let newETag = http.value(forHTTPHeaderField: "ETag")
        writeETagCache(etag: newETag, data: data)

        return try Self.parseLatestReleaseJSON(data, currentVersion: currentVersion, checkedAt: now)
    }

    // MARK: - Download, Verify SHA-256, Mount & Install

    public func downloadAndInstall(
        _ info: ReleaseUpdateInfo,
        onPhase: @escaping @Sendable (ReleaseUpdatePhase) -> Void
    ) async throws -> ReleaseUpdatePhase {
        guard let dmgURL = info.dmgDownloadURL else {
            throw ReleaseUpdaterError.missingAsset("该版本未提供 macOS DMG 安装包，请前往 GitHub Release 页面下载")
        }
        guard Self.isAllowedHost(dmgURL) else {
            throw ReleaseUpdaterError.disallowedHost("安装包下载地址不在安全白名单内：\(dmgURL.absoluteString)")
        }
        guard let shaURL = info.sha256DownloadURL else {
            throw ReleaseUpdaterError.missingChecksum("该版本缺少 SHA-256 校验文件，为保障安全已中止自动安装")
        }
        guard Self.isAllowedHost(shaURL) else {
            throw ReleaseUpdaterError.disallowedHost("校验文件地址不在安全白名单内：\(shaURL.absoluteString)")
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("pulsar-update-\(UUID().uuidString)", isDirectory: true)
        try KeychainStore.ensureDirectory(at: tempDir, mode: 0o700)

        var keepTempDirForSwapScript = false
        defer {
            if !keepTempDirForSwapScript {
                try? fm.removeItem(at: tempDir)
            }
        }

        let rawFileName = info.dmgFileName ?? dmgURL.lastPathComponent
        let sanitizedFileName = Self.sanitizedFilename(rawFileName, fallback: "Pulsar-v\(info.version).dmg")
        let dmgTempURL = tempDir.appendingPathComponent(sanitizedFileName, isDirectory: false)

        // Step 1: Stream-download DMG with live progress reporting & strict redirect host allowlist.
        onPhase(.downloading(info, progress: 0.0))
        try await downloadAllowlistedFile(
            from: dmgURL,
            to: dmgTempURL,
            fallbackExpectedBytes: info.assetSizeBytes,
            onProgress: { progress in
                onPhase(.downloading(info, progress: progress))
            }
        )
        onPhase(.downloading(info, progress: 1.0))

        // Step 2: Mandatory SHA-256 verification (abort & delete immediately on missing/mismatched digest).
        onPhase(.verifying(info))
        let shaText = try await fetchAllowlistedText(from: shaURL)
        guard let expectedSHA = Self.parseSHA256Text(shaText, expectedFileName: sanitizedFileName) else {
            try? fm.removeItem(at: dmgTempURL)
            throw ReleaseUpdaterError.checksumMismatch("无法解析 SHA-256 校验文件，已中止自动安装")
        }

        let actualSHA: String
        do {
            actualSHA = try Self.sha256Hex(ofFileAt: dmgTempURL)
        } catch {
            try? fm.removeItem(at: dmgTempURL)
            throw ReleaseUpdaterError.checksumMismatch("计算安装包 SHA-256 失败：\(error.localizedDescription)")
        }

        guard actualSHA == expectedSHA else {
            try? fm.removeItem(at: dmgTempURL)
            throw ReleaseUpdaterError.checksumMismatch("安装包 SHA-256 校验不一致，已拒绝安装并删除临时文件")
        }

        // Step 3: Mount verified DMG read-only, locate `.app`, verify bundle ID & strict codesign.
        onPhase(.installing(info))
        var mountedVolumePath: String? = try Self.attachDMGReadOnly(at: dmgTempURL)
        defer {
            if let mountPath = mountedVolumePath {
                Self.detachDMG(at: mountPath)
            }
        }

        guard let mountPath = mountedVolumePath else {
            throw ReleaseUpdaterError.mountFailed("未能获取 DMG 挂载路径")
        }

        let mountedAppURL = try Self.locateAppBundle(inMountPath: mountPath)
        try Self.verifyBundleIdentifier(ofAppAt: mountedAppURL, expected: expectedBundleIdentifier)
        try Self.verifyCodeSignature(ofAppAt: mountedAppURL)

        // Step 4: Smart in-place replacement vs manual DMG open fallback.
        if Self.canInstallInPlace(currentAppURL: runningAppBundleURL, fileManager: fm) {
            let targetAppURL = runningAppBundleURL.standardizedFileURL
            let parentDir = targetAppURL.deletingLastPathComponent()
            let uuid = UUID().uuidString
            let stagingAppURL = parentDir.appendingPathComponent(
                ".\(targetAppURL.lastPathComponent).updating.\(uuid)",
                isDirectory: true
            )
            let backupAppURL = parentDir.appendingPathComponent(
                ".\(targetAppURL.lastPathComponent).backup.\(uuid)",
                isDirectory: true
            )

            do {
                try Self.runProcessOrThrow(
                    executable: "/usr/bin/ditto",
                    arguments: [mountedAppURL.path, stagingAppURL.path],
                    failurePrefix: "复制新版本应用失败"
                )
                // Clear quarantine attribute so Gatekeeper does not block self-updated bundle.
                _ = Self.runProcess(
                    executable: "/usr/bin/xattr",
                    arguments: ["-dr", "com.apple.quarantine", stagingAppURL.path]
                )
                try Self.verifyCodeSignature(ofAppAt: stagingAppURL)
            } catch {
                try? fm.removeItem(at: stagingAppURL)
                throw error
            }

            // Detach DMG cleanly before writing and launching the swap script.
            Self.detachDMG(at: mountPath)
            mountedVolumePath = nil
            try? fm.removeItem(at: dmgTempURL)

            let scriptContent = Self.buildSwapScript(
                pid: ProcessInfo.processInfo.processIdentifier,
                targetAppPath: targetAppURL.path,
                stagingAppPath: stagingAppURL.path,
                backupAppPath: backupAppURL.path,
                tempDirPath: tempDir.path,
                launchAgentLabel: expectedBundleIdentifier
            )
            let scriptURL = tempDir.appendingPathComponent("pulsar-swap.sh", isDirectory: false)
            guard let scriptData = scriptContent.data(using: .utf8) else {
                try? fm.removeItem(at: stagingAppURL)
                throw ReleaseUpdaterError.installFailed("生成换包脚本失败")
            }
            try KeychainStore.writeAtomicFile(data: scriptData, to: scriptURL, mode: 0o700)

            try Self.spawnDetachedShellScript(at: scriptURL)
            keepTempDirForSwapScript = true

            let finalPhase = ReleaseUpdatePhase.readyToRelaunch(info)
            onPhase(finalPhase)
            try? await Task.sleep(nanoseconds: 250_000_000)
            await relaunchTerminator()
            return finalPhase
        } else {
            // Fallback: copy verified DMG to ~/Downloads and open it for manual drag-to-Applications.
            Self.detachDMG(at: mountPath)
            mountedVolumePath = nil

            if !fm.fileExists(atPath: downloadsDirectoryURL.path) {
                try fm.createDirectory(at: downloadsDirectoryURL, withIntermediateDirectories: true)
            }
            let destinationDMG = downloadsDirectoryURL.appendingPathComponent(sanitizedFileName, isDirectory: false)
            if fm.fileExists(atPath: destinationDMG.path) {
                try? fm.removeItem(at: destinationDMG)
            }
            try fm.copyItem(at: dmgTempURL, to: destinationDMG)

            await openManualInstaller(destinationDMG)
            let finalPhase = ReleaseUpdatePhase.manualInstallOpened(info, dmgPath: destinationDMG.path)
            onPhase(finalPhase)
            return finalPhase
        }
    }

    // MARK: - Private Network Helpers

    private func performAllowlistedDataRequest(
        _ request: URLRequest,
        timeout: TimeInterval
    ) async throws -> (Data, URLResponse) {
        guard let url = request.url, Self.isAllowedHost(url) else {
            throw ReleaseUpdaterError.disallowedHost("请求地址不在白名单中")
        }

        if let injectedSession {
            do {
                let (data, response) = try await injectedSession.data(for: request)
                if let finalURL = response.url, !Self.isAllowedHost(finalURL) {
                    throw ReleaseUpdaterError.disallowedHost("响应跳转至非白名单域名：\(finalURL.absoluteString)")
                }
                return (data, response)
            } catch let err as ReleaseUpdaterError {
                throw err
            } catch {
                throw ReleaseUpdaterError.networkFailure("网络请求失败：\(error.localizedDescription)")
            }
        }

        let config = HTTPFactory.makeConfiguration(policy: .systemProxy, timeout: timeout)
        let delegate = AllowlistedRedirectDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            if let finalURL = response.url, !Self.isAllowedHost(finalURL) {
                throw ReleaseUpdaterError.disallowedHost("响应跳转至非白名单域名：\(finalURL.absoluteString)")
            }
            return (data, response)
        } catch let err as ReleaseUpdaterError {
            throw err
        } catch {
            throw ReleaseUpdaterError.networkFailure("网络请求失败：\(error.localizedDescription)")
        }
    }

    private func fetchAllowlistedText(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20.0
        request.setValue("Pulsar/\(AppStore.appVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await performAllowlistedDataRequest(request, timeout: 20.0)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ReleaseUpdaterError.missingChecksum("下载 SHA-256 校验文件失败（HTTP \(code)）")
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw ReleaseUpdaterError.checksumMismatch("SHA-256 校验文件内容为空或编码无效")
        }
        return text
    }

    private func downloadAllowlistedFile(
        from url: URL,
        to destinationURL: URL,
        fallbackExpectedBytes: Int64?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard Self.isAllowedHost(url) else {
            throw ReleaseUpdaterError.disallowedHost("下载地址不在安全白名单内：\(url.absoluteString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 60.0
        request.setValue("Pulsar/\(AppStore.appVersion)", forHTTPHeaderField: "User-Agent")

        if let injectedSession {
            let (data, response) = try await injectedSession.data(for: request)
            if let finalURL = response.url, !Self.isAllowedHost(finalURL) {
                throw ReleaseUpdaterError.disallowedHost("下载跳转至非白名单域名：\(finalURL.absoluteString)")
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw ReleaseUpdaterError.networkFailure("下载安装包失败（HTTP \(code)）")
            }
            onProgress(0.5)
            try data.write(to: destinationURL, options: .atomic)
            onProgress(1.0)
            return
        }

        let config = HTTPFactory.makeConfiguration(policy: .systemProxy, timeout: 60.0)
        config.timeoutIntervalForResource = 600.0
        let delegate = AllowlistedDownloadDelegate(
            destinationURL: destinationURL,
            fallbackExpectedBytes: fallbackExpectedBytes,
            onProgress: onProgress
        )
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (_, httpResp) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(URL, HTTPURLResponse?), Error>) in
            delegate.setContinuation(cont)
            let task = session.downloadTask(with: request)
            task.resume()
        }

        if let finalURL = httpResp?.url, !Self.isAllowedHost(finalURL) {
            try? FileManager.default.removeItem(at: destinationURL)
            throw ReleaseUpdaterError.disallowedHost("下载跳转至非白名单域名：\(finalURL.absoluteString)")
        }
        guard let httpResp, (200...299).contains(httpResp.statusCode) else {
            try? FileManager.default.removeItem(at: destinationURL)
            let code = httpResp?.statusCode ?? -1
            throw ReleaseUpdaterError.networkFailure("下载安装包失败（HTTP \(code)）")
        }
    }

    // MARK: - Private DMG / Codesign / Process Helpers

    private static func sanitizedFilename(_ raw: String, fallback: String) -> String {
        let base = URL(fileURLWithPath: raw).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, base != ".", base != "..", !base.contains("/") else {
            return fallback
        }
        return base
    }

    private struct ProcessOutput {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
    }

    private static func runProcess(executable: String, arguments: [String]) -> ProcessOutput {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            let errData = Data(error.localizedDescription.utf8)
            return ProcessOutput(exitCode: -1, stdout: Data(), stderr: errData)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return ProcessOutput(exitCode: proc.terminationStatus, stdout: outData, stderr: errData)
    }

    private static func runProcessOrThrow(
        executable: String,
        arguments: [String],
        failurePrefix: String
    ) throws {
        let result = runProcess(executable: executable, arguments: arguments)
        guard result.exitCode == 0 else {
            let errText = String(data: result.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = errText.isEmpty ? "exit \(result.exitCode)" : errText
            throw ReleaseUpdaterError.installFailed("\(failurePrefix)：\(detail)")
        }
    }

    private static func attachDMGReadOnly(at dmgURL: URL) throws -> String {
        let res = runProcess(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", dmgURL.path, "-nobrowse", "-readonly", "-noautoopen", "-plist"]
        )
        guard res.exitCode == 0 else {
            let errMsg = String(data: res.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(res.exitCode)"
            throw ReleaseUpdaterError.mountFailed("挂载 DMG 安装包失败：\(errMsg)")
        }

        guard let plist = try? PropertyListSerialization.propertyList(
            from: res.stdout,
            options: [],
            format: nil
        ) as? [String: Any],
        let entities = plist["system-entities"] as? [[String: Any]] else {
            throw ReleaseUpdaterError.mountFailed("解析 DMG 挂载信息失败")
        }

        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty {
                return mountPoint
            }
        }
        throw ReleaseUpdaterError.mountFailed("未在挂载结果中找到有效卷路径")
    }

    private static func detachDMG(at mountPath: String) {
        for _ in 0..<3 {
            let res = runProcess(
                executable: "/usr/bin/hdiutil",
                arguments: ["detach", mountPath, "-quiet"]
            )
            if res.exitCode == 0 {
                return
            }
            usleep(300_000)
        }
        _ = runProcess(
            executable: "/usr/bin/hdiutil",
            arguments: ["detach", mountPath, "-force", "-quiet"]
        )
    }

    private static func locateAppBundle(inMountPath mountPath: String) throws -> URL {
        let mountURL = URL(fileURLWithPath: mountPath, isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: mountURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let appBundles = contents.filter { url in
            url.pathExtension.lowercased() == "app"
                && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        }

        if let preferred = appBundles.first(where: { $0.lastPathComponent == "Pulsar.app" })
            ?? appBundles.first(where: { $0.lastPathComponent == "RoryOrbit.app" })
            ?? appBundles.first {
            return preferred
        }
        throw ReleaseUpdaterError.appBundleMissing("DMG 镜像中未找到可安装的 .app 应用包")
    }

    private static func verifyBundleIdentifier(ofAppAt appURL: URL, expected: String) throws {
        let plistURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let bundleId = plist["CFBundleIdentifier"] as? String,
              bundleId == expected else {
            throw ReleaseUpdaterError.bundleIdentifierMismatch("安装包 Bundle Identifier 校验不匹配，已拒绝安装")
        }
    }

    private static func verifyCodeSignature(ofAppAt appURL: URL) throws {
        let res = runProcess(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", appURL.path]
        )
        guard res.exitCode == 0 else {
            let errMsg = String(data: res.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(res.exitCode)"
            throw ReleaseUpdaterError.codeSignatureInvalid("应用签名校验失败，已中止安装：\(errMsg)")
        }
    }

    private static func spawnDetachedShellScript(at scriptURL: URL) throws {
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = [
            "-c",
            "nohup /bin/sh \"$1\" >/dev/null 2>&1 </dev/null &",
            "_",
            scriptURL.path,
        ]
        launcher.standardInput = FileHandle.nullDevice
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        do {
            try launcher.run()
            launcher.waitUntilExit()
            guard launcher.terminationStatus == 0 else {
                throw ReleaseUpdaterError.installFailed("启动换包脚本失败（exit \(launcher.terminationStatus)）")
            }
        } catch let err as ReleaseUpdaterError {
            throw err
        } catch {
            throw ReleaseUpdaterError.installFailed("启动换包脚本失败：\(error.localizedDescription)")
        }
    }
}
