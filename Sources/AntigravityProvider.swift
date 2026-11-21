import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

/// Multi-account switcher, local Connect RPC + Cloud Code quota provider, and safe client controller
/// for Antigravity (supporting dual Stable + Insiders installs and `agy` CLI).
public final class AntigravityProvider: ProviderAdapter, @unchecked Sendable {

    // MARK: - ProviderAdapter Properties

    public let id: ProviderID = .antigravity
    public let capabilities: ProviderCapability = [.quota, .accountSwitch, .localRPC, .clientControl]
    public let transportPolicy: TransportPolicy = .systemProxy
    public let isolatedStoreNamespace: String = KeychainStore.roryOrbitAntigravityService

    // MARK: - Constants

    public static let stableBundleId = "com.google.antigravity"
    public static let insidersBundleId = "com.google.antigravity.insiders"
    public static let bundleIDs = [stableBundleId, insidersBundleId]

    public static let liveKeychainService = "gemini"
    public static let liveKeychainAccount = "antigravity"
    public static let goKeyringBase64Prefix = "go-keyring-base64:"

    public static let consumerClientId = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    public static let oauthScopes = [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/aicode",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs",
    ].joined(separator: " ")

    public static let defaultFallbackAppVersion = "2.33.0"

    private static let googleAuthURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let googleTokenURL = "https://oauth2.googleapis.com/token"
    private static let googleUserInfoURL = "https://www.googleapis.com/oauth2/v2/userinfo"
    private static let dailyQuotaSummaryURL = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    private static let loadCodeAssistURL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private static let fetchAvailableModelsURL = "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
    private static let retrieveUserQuotaURL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"

    // MARK: - Configuration & Dependencies

    public struct Paths: Sendable {
        public var stableAppURL: URL
        public var insidersAppURL: URL
        public var agyCLIURL: URL
        public var mirrorTokenURL: URL

        public init(
            stableAppURL: URL,
            insidersAppURL: URL,
            agyCLIURL: URL,
            mirrorTokenURL: URL
        ) {
            self.stableAppURL = stableAppURL
            self.insidersAppURL = insidersAppURL
            self.agyCLIURL = agyCLIURL
            self.mirrorTokenURL = mirrorTokenURL
        }

        public static var liveDefaults: Paths {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Paths(
                stableAppURL: URL(fileURLWithPath: "/Applications/Antigravity.app", isDirectory: true),
                insidersAppURL: URL(fileURLWithPath: "/Applications/Antigravity - Insiders.app", isDirectory: true),
                agyCLIURL: home
                    .appendingPathComponent(".local", isDirectory: true)
                    .appendingPathComponent("bin", isDirectory: true)
                    .appendingPathComponent("agy", isDirectory: false),
                mirrorTokenURL: home
                    .appendingPathComponent(".gemini", isDirectory: true)
                    .appendingPathComponent("jetski-standalone-oauth-token", isDirectory: false)
            )
        }
    }

    public let keychain: KeychainStore
    public let processController: ProcessController
    public let paths: Paths

    private let session: URLSession
    private let localRPCSession: URLSession
    private let localRPCDelegate: LocalhostSelfSignedDelegate

    private let cacheLock = NSLock()
    private var cachedStableVersion: String?
    private var cachedClientSecret: String?

    // MARK: - Initializers

    public convenience init(
        keychain: KeychainStore = .shared,
        processController: ProcessController = .shared
    ) {
        self.init(
            keychain: keychain,
            processController: processController,
            paths: .liveDefaults,
            session: nil
        )
    }

    public init(
        keychain: KeychainStore,
        processController: ProcessController,
        paths: Paths = .liveDefaults,
        session: URLSession? = nil
    ) {
        self.keychain = keychain
        self.processController = processController
        self.paths = paths
        self.session = session ?? HTTPFactory.makeSession(policy: .systemProxy, timeout: 20.0)

        let delegate = LocalhostSelfSignedDelegate()
        self.localRPCDelegate = delegate
        let localCfg = URLSessionConfiguration.ephemeral
        localCfg.timeoutIntervalForRequest = 4.0
        localCfg.timeoutIntervalForResource = 8.0
        localCfg.waitsForConnectivity = false
        localCfg.urlCache = nil
        localCfg.httpCookieStorage = nil
        localCfg.httpShouldSetCookies = false
        // Explicitly bypass system proxy for 127.0.0.1 Connect RPC.
        localCfg.connectionProxyDictionary = [:]
        self.localRPCSession = URLSession(configuration: localCfg, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Detached Executable Matchers

    private func detachedExecutableMatchers() -> [(String) -> Bool] {
        let agyPath = paths.agyCLIURL.standardizedFileURL.path
        let stablePrefix = paths.stableAppURL.standardizedFileURL.path + "/"
        let insidersPrefix = paths.insidersAppURL.standardizedFileURL.path + "/"
        return [
            { execPath in
                let std = URL(fileURLWithPath: execPath).standardizedFileURL.path
                let lower = std.lowercased()
                let base = URL(fileURLWithPath: std).lastPathComponent.lowercased()

                if std == agyPath || base == "agy" || base == "agy-desktop-helper" {
                    return true
                }
                if std.hasPrefix(stablePrefix) || std.hasPrefix(insidersPrefix) {
                    return true
                }
                if base.hasPrefix("language_server") &&
                    (lower.contains("antigravity") || lower.contains("/.gemini/")) {
                    return true
                }
                return false
            },
        ]
    }

    // MARK: - Client Status Detection

    public func detectClientStatus() async -> ClientRuntimeStatus {
        var extraPaths = [paths.stableAppURL.path, paths.insidersAppURL.path]
        if FileManager.default.fileExists(atPath: paths.agyCLIURL.path) {
            extraPaths.append(paths.agyCLIURL.path)
        }
        return processController.detectClientStatus(
            bundleIDs: Self.bundleIDs,
            extraAppPaths: extraPaths,
            detachedExecutableMatchers: detachedExecutableMatchers()
        )
    }

    // MARK: - Stable App Version & Native User-Agent

    /// Always reads Stable `Antigravity.app/Contents/Resources/app.asar` `package.json` version (never Insiders),
    /// producing the native User-Agent `antigravity/hub/<ver> darwin/arm64`.
    public func resolveNativeUserAgent() -> String {
        let ver = resolveStableAppVersion()
        return "antigravity/hub/\(ver) darwin/arm64"
    }

    public func resolveStableAppVersion() -> String {
        cacheLock.lock()
        if let cached = cachedStableVersion {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let asarURL = paths.stableAppURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("app.asar", isDirectory: false)

        let parsed = Self.readPackageVersionFromASAR(at: asarURL)
        let resolved: String
        if let parsed, Self.isValidStableSemver(parsed) {
            resolved = parsed
        } else {
            resolved = Self.defaultFallbackAppVersion
        }

        cacheLock.lock()
        cachedStableVersion = resolved
        cacheLock.unlock()
        return resolved
    }

    /// Reads `package.json` `version` from an Electron `app.asar` archive without loading the archive into RAM.
    public static func readPackageVersionFromASAR(at url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        guard let header = try? fh.read(upToCount: 16), header.count == 16 else { return nil }
        let headerSize = readUInt32LE(header, offset: 4)
        let jsonSize = readUInt32LE(header, offset: 12)
        guard jsonSize > 0, jsonSize < 32 * 1024 * 1024, headerSize >= jsonSize else {
            return nil
        }

        guard let metaData = try? fh.read(upToCount: Int(jsonSize)), metaData.count == Int(jsonSize) else {
            return nil
        }
        guard let meta = (try? JSONSerialization.jsonObject(with: metaData, options: [])) as? [String: Any],
              let files = meta["files"] as? [String: Any],
              let pkg = files["package.json"] as? [String: Any] else {
            return nil
        }

        let offsetVal: UInt64
        if let s = pkg["offset"] as? String, let parsed = UInt64(s) {
            offsetVal = parsed
        } else if let n = pkg["offset"] as? NSNumber {
            offsetVal = n.uint64Value
        } else {
            return nil
        }

        let sizeVal: Int
        if let n = pkg["size"] as? NSNumber {
            sizeVal = n.intValue
        } else {
            return nil
        }
        guard sizeVal > 0, sizeVal < 1_048_576 else { return nil }

        let absoluteOffset = UInt64(8) + UInt64(headerSize) + offsetVal
        do {
            try fh.seek(toOffset: absoluteOffset)
            guard let pkgData = try fh.read(upToCount: sizeVal), pkgData.count == sizeVal else {
                return nil
            }
            guard let pkgObj = (try JSONSerialization.jsonObject(with: pkgData, options: [])) as? [String: Any],
                  let version = pkgObj["version"] as? String else {
                return nil
            }
            return version.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1]) << 8
        let b2 = UInt32(data[data.startIndex + offset + 2]) << 16
        let b3 = UInt32(data[data.startIndex + offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    private static func isValidStableSemver(_ version: String) -> Bool {
        let parts = version.split(separator: ".")
        guard parts.count == 3 else { return false }
        for part in parts {
            // Reject Insiders timestamp builds like `1.0.20261120010114`.
            guard !part.isEmpty, part.count <= 5, part.allSatisfy({ $0.isNumber }) else {
                return false
            }
        }
        return true
    }

    // MARK: - Live Credential Bundle I/O (Keychain + Mirror File)

    private struct LiveBundle {
        var root: [String: Any]
        var accessToken: String?
        var refreshToken: String?
        var expiry: Date?
        var idToken: String?
        var rawKeychainString: String?
        var rawMirrorData: Data?
    }

    public static func encodeGoKeyringValue(_ jsonData: Data) -> String {
        goKeyringBase64Prefix + jsonData.base64EncodedString()
    }

    public static func decodeGoKeyringValue(_ raw: String) -> Data? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(goKeyringBase64Prefix) {
            let b64 = String(trimmed.dropFirst(goKeyringBase64Prefix.count))
            return Data(base64Encoded: b64)
        }
        if trimmed.hasPrefix("{") {
            return Data(trimmed.utf8)
        }
        return Data(base64Encoded: trimmed)
    }

    private func readLiveBundle() -> LiveBundle? {
        let rawKC = try? keychain.readExternalGenericPassword(
            service: Self.liveKeychainService,
            account: Self.liveKeychainAccount
        )
        let rawMirror = try? Data(contentsOf: paths.mirrorTokenURL)

        let decodedData: Data?
        if let rawKC, !rawKC.isEmpty, let kcData = Self.decodeGoKeyringValue(rawKC) {
            decodedData = kcData
        } else if let rawMirror, !rawMirror.isEmpty {
            decodedData = rawMirror
        } else {
            return nil
        }

        guard let data = decodedData,
              let obj = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }

        let tokenObj = obj["token"] as? [String: Any]
        let accessToken = nonEmpty(tokenObj?["access_token"] as? String)
        let refreshToken = nonEmpty(tokenObj?["refresh_token"] as? String)
        let expiry = (tokenObj?["expiry"] as? String).flatMap { Formatters.parseRFC3339($0) }
        let idToken = nonEmpty(obj["id_token"] as? String)

        return LiveBundle(
            root: obj,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiry: expiry,
            idToken: idToken,
            rawKeychainString: rawKC,
            rawMirrorData: rawMirror
        )
    }

    private func buildUpdatedBundleJSON(
        base: [String: Any]?,
        accessToken: String,
        refreshToken: String,
        expiry: Date,
        idToken: String?
    ) throws -> Data {
        var root = base ?? [:]
        var tokenObj = (root["token"] as? [String: Any]) ?? [:]
        tokenObj["access_token"] = accessToken
        tokenObj["token_type"] = nonEmpty(tokenObj["token_type"] as? String) ?? "Bearer"
        tokenObj["refresh_token"] = refreshToken
        tokenObj["expiry"] = Formatters.formatRFC3339Local(expiry)
        root["token"] = tokenObj

        if nonEmpty(root["auth_method"] as? String) == nil {
            root["auth_method"] = "consumer"
        }

        if let idToken, !idToken.isEmpty {
            root["id_token"] = idToken
        } else {
            // Avoid leaving a stale outgoing account's id_token paired with the new account's access_token.
            root.removeValue(forKey: "id_token")
        }

        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    // MARK: - OAuth Client Secret Discovery (Stream Scan + Probe)

    /// Stream-scans Antigravity binary directories for `GOCSPX-[A-Za-z0-9_-]{28}` candidates without loading files into RAM.
    public static func scanClientSecretCandidates(inBinDirectories dirs: [URL]) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()
        let fm = FileManager.default

        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            // Prioritize `language_server` first since it holds the consumer secret.
            let sorted = items.sorted { lhs, rhs in
                let lName = lhs.lastPathComponent
                let rName = rhs.lastPathComponent
                if lName == "language_server" && rName != "language_server" { return true }
                if rName == "language_server" && lName != "language_server" { return false }
                return lName < rName
            }

            for fileURL in sorted {
                let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isRegular else { continue }
                for match in streamScanGOCSPX(in: fileURL) {
                    if seen.insert(match).inserted {
                        candidates.append(match)
                    }
                }
            }
        }
        return candidates
    }

    private static func streamScanGOCSPX(in fileURL: URL) -> [String] {
        guard let fh = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? fh.close() }

        let prefix: [UInt8] = Array("GOCSPX-".utf8) // 7 bytes
        let suffixLen = 28
        let totalLen = prefix.count + suffixLen      // 35 bytes
        let chunkSize = 2 * 1024 * 1024              // 2 MiB
        let overlap = 64

        var results: [String] = []
        var seen = Set<String>()
        var tail = Data()

        while true {
            guard let chunk = try? fh.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }

            var buf = Data()
            buf.reserveCapacity(tail.count + chunk.count)
            buf.append(tail)
            buf.append(chunk)

            buf.withUnsafeBytes { raw in
                guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                let count = raw.count
                if count < totalLen { return }
                let limit = count - totalLen
                var i = 0
                while i <= limit {
                    if ptr[i] == 0x47, // 'G'
                       ptr[i + 1] == 0x4F, // 'O'
                       ptr[i + 2] == 0x43, // 'C'
                       ptr[i + 3] == 0x53, // 'S'
                       ptr[i + 4] == 0x50, // 'P'
                       ptr[i + 5] == 0x58, // 'X'
                       ptr[i + 6] == 0x2D  // '-'
                    {
                        var valid = true
                        for j in 7..<totalLen {
                            if !isOAuthSecretChar(ptr[i + j]) {
                                valid = false
                                break
                            }
                        }
                        if valid {
                            // Go .rodata string tables pack string literals back-to-back without NUL separators,
                            // so do NOT reject matches based on adjacent ASCII characters.
                            let slice = UnsafeBufferPointer(start: ptr.advanced(by: i), count: totalLen)
                            let str = String(decoding: slice, as: UTF8.self)
                            if seen.insert(str).inserted {
                                results.append(str)
                            }
                            i += totalLen
                            continue
                        }
                    }
                    i += 1
                }
            }

            if buf.count > overlap {
                tail = buf.suffix(overlap)
            } else {
                tail = buf
            }
        }

        return results
    }

    private static func isOAuthSecretChar(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) // A-Z
            || (b >= 0x61 && b <= 0x7A) // a-z
            || (b >= 0x30 && b <= 0x39) // 0-9
            || b == 0x5F // '_'
            || b == 0x2D // '-'
    }

    private func getCachedClientSecret() -> String? {
        cacheLock.withLock { cachedClientSecret }
    }

    private func setCachedClientSecret(_ value: String?) {
        cacheLock.withLock { cachedClientSecret = value }
    }

    private func discoverOAuthClientSecret() async throws -> String {
        if let cached = getCachedClientSecret() {
            return cached
        }

        let binDirs = [
            paths.stableAppURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true),
            paths.insidersAppURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true),
        ]

        let candidates = Self.scanClientSecretCandidates(inBinDirectories: binDirs)
        guard !candidates.isEmpty else {
            throw ProviderAdapterError.operationFailed("未在 Antigravity 安装目录中发现 OAuth 客户端配置，请确认已安装 Antigravity.app")
        }

        var lastNetworkError: String?
        for candidate in candidates {
            do {
                let matched = try await probeClientSecret(candidate)
                if matched {
                    setCachedClientSecret(candidate)
                    return candidate
                }
            } catch {
                lastNetworkError = error.localizedDescription
            }
        }

        if let lastNetworkError {
            throw ProviderAdapterError.networkFailure("验证 Antigravity OAuth 客户端配置时网络异常: \(lastNetworkError)")
        }
        throw ProviderAdapterError.operationFailed("未能匹配有效的 Antigravity OAuth 客户端配置")
    }

    private func probeClientSecret(_ candidate: String) async throws -> Bool {
        let form = formURLEncoded([
            ("grant_type", "authorization_code"),
            ("code", "roryorbit_client_secret_probe"),
            ("redirect_uri", "http://127.0.0.1/oauth-callback"),
            ("client_id", Self.consumerClientId),
            ("client_secret", candidate),
        ])

        var req = URLRequest(url: URL(string: Self.googleTokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data(form.utf8)

        let (data, _) = try await session.data(for: req)
        guard let obj = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              let errCode = (obj["error"] as? String)?.lowercased() else {
            return false
        }
        // `invalid_grant` / `redirect_uri_mismatch` confirm client_id + client_secret matched!
        if errCode == "invalid_grant" || errCode == "redirect_uri_mismatch" {
            return true
        }
        return false
    }

    // MARK: - Google OAuth Token Exchange, Refresh & UserInfo

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let expiresIn: TimeInterval
    }

    private struct GoogleIdentity {
        let sub: String
        let email: String
        let displayName: String
        let pictureURL: String?

        init(sub: String, email: String, displayName: String, pictureURL: String? = nil) {
            self.sub = sub
            self.email = email
            self.displayName = displayName
            self.pictureURL = Formatters.sanitizedHTTPSURLString(pictureURL)
        }
    }

    private func refreshAccessToken(refreshToken: String) async throws -> TokenResponse {
        let secret = try await discoverOAuthClientSecret()
        let form = formURLEncoded([
            ("grant_type", "refresh_token"),
            ("client_id", Self.consumerClientId),
            ("client_secret", secret),
            ("refresh_token", refreshToken),
        ])
        return try await performTokenRequest(formBody: form)
    }

    private func exchangeAuthCode(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        clientSecret: String
    ) async throws -> TokenResponse {
        let form = formURLEncoded([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("code_verifier", codeVerifier),
            ("redirect_uri", redirectURI),
            ("client_id", Self.consumerClientId),
            ("client_secret", clientSecret),
        ])
        return try await performTokenRequest(formBody: form)
    }

    private func performTokenRequest(formBody: String) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: Self.googleTokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data(formBody.utf8)

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw ProviderAdapterError.networkFailure("Google OAuth 网络请求失败: \(error.localizedDescription)")
        }

        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] ?? [:]

        if !(200...299).contains(status) {
            let errCode = (obj["error"] as? String)?.lowercased() ?? ""
            if errCode == "invalid_grant" {
                throw ProviderAdapterError.authenticationRequired("Google 授权已失效或被撤销，请重新登录")
            }
            if errCode == "invalid_client" {
                setCachedClientSecret(nil)
                throw ProviderAdapterError.operationFailed("Google OAuth 客户端验证失败 (invalid_client)")
            }
            throw ProviderAdapterError.networkFailure("Google OAuth 令牌请求失败 (HTTP \(status))")
        }

        guard let accessToken = nonEmpty(obj["access_token"] as? String) else {
            throw ProviderAdapterError.invalidCredential("Google OAuth 响应缺少 access_token")
        }
        let refreshToken = nonEmpty(obj["refresh_token"] as? String)
        let idToken = nonEmpty(obj["id_token"] as? String)
        let expiresIn = (obj["expires_in"] as? NSNumber)?.doubleValue ?? 3600.0
        return TokenResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            expiresIn: expiresIn
        )
    }

    private func resolveGoogleIdentity(accessToken: String?, idToken: String?) async -> GoogleIdentity? {
        let idTokenClaims = idToken.flatMap { Formatters.decodeJWTPayload($0) }
        let idTokenPicture = Formatters.sanitizedHTTPSURLString(idTokenClaims?["picture"] as? String)

        if let accessToken, !accessToken.isEmpty {
            var req = URLRequest(url: URL(string: Self.googleUserInfoURL)!)
            req.httpMethod = "GET"
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            if let (data, resp) = try? await session.data(for: req),
               let http = resp as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               let obj = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] {
                let sub = nonEmpty(obj["id"] as? String) ?? nonEmpty(obj["sub"] as? String) ?? ""
                let email = nonEmpty(obj["email"] as? String) ?? ""
                let name = nonEmpty(obj["name"] as? String) ?? email
                let picture = Formatters.sanitizedHTTPSURLString(obj["picture"] as? String) ?? idTokenPicture
                if !sub.isEmpty {
                    return GoogleIdentity(
                        sub: sub,
                        email: email,
                        displayName: name.isEmpty ? sub : name,
                        pictureURL: picture
                    )
                }
            }
        }

        if let claims = idTokenClaims {
            let sub = nonEmpty(claims["sub"] as? String) ?? ""
            let email = nonEmpty(claims["email"] as? String) ?? ""
            let name = nonEmpty(claims["name"] as? String) ?? email
            if !sub.isEmpty {
                return GoogleIdentity(
                    sub: sub,
                    email: email,
                    displayName: name.isEmpty ? sub : name,
                    pictureURL: idTokenPicture
                )
            }
        }

        return nil
    }

    // MARK: - Live Account Sync & Import

    public func syncLiveAccount(registry: inout RegistryData) async -> String? {
        guard let live = readLiveBundle() else {
            registry.setActiveLive(accountId: nil, for: .antigravity)
            return nil
        }

        // Fast offline identity from id_token first, then read-only userinfo if unexpired access_token exists.
        var identity: GoogleIdentity?
        if let idToken = live.idToken, let claims = Formatters.decodeJWTPayload(idToken),
           let sub = nonEmpty(claims["sub"] as? String) {
            let email = nonEmpty(claims["email"] as? String) ?? ""
            let name = nonEmpty(claims["name"] as? String) ?? email
            let picture = Formatters.sanitizedHTTPSURLString(claims["picture"] as? String)
            identity = GoogleIdentity(
                sub: sub,
                email: email,
                displayName: name.isEmpty ? sub : name,
                pictureURL: picture
            )
        }

        let existingMatchedAvatar = identity.flatMap { ident in
            registry.accounts(for: .antigravity)
                .first(where: { $0.id == ident.sub })
                .flatMap { Formatters.sanitizedHTTPSURLString($0.avatarURL) }
        }

        if (identity == nil || (identity?.pictureURL == nil && existingMatchedAvatar == nil)),
           let access = live.accessToken {
            let stillValid = live.expiry.map { $0 > Date().addingTimeInterval(15) } ?? true
            if stillValid,
               let fetched = await resolveGoogleIdentity(accessToken: access, idToken: live.idToken) {
                identity = fetched
            }
        }

        // If live access_token expired and id_token absent, try matching by refresh_token SHA against vaulted accounts.
        if identity == nil, let liveRT = live.refreshToken {
            let liveDigest = Formatters.sha256Hex(liveRT)
            for existing in registry.accounts(for: .antigravity) {
                if let vaulted = try? keychain.readSecret(service: isolatedStoreNamespace, account: existing.id),
                   Formatters.sha256Hex(vaulted) == liveDigest {
                    identity = GoogleIdentity(
                        sub: existing.id,
                        email: existing.email,
                        displayName: existing.displayName,
                        pictureURL: existing.avatarURL
                    )
                    break
                }
            }
        }

        guard let resolved = identity else {
            return nil
        }

        if let existing = registry.accounts(for: .antigravity).first(where: { $0.id == resolved.sub }) {
            var updated = existing
            if updated.email.isEmpty && !resolved.email.isEmpty { updated.email = resolved.email }
            if updated.displayName.isEmpty && !resolved.displayName.isEmpty { updated.displayName = resolved.displayName }
            if let newPicture = resolved.pictureURL {
                updated.avatarURL = newPicture
            }
            updated.isActiveLive = true
            registry.upsertAccount(updated)
        } else {
            registry.upsertAccount(
                AccountRecord(
                    id: resolved.sub,
                    provider: .antigravity,
                    email: resolved.email,
                    displayName: resolved.displayName,
                    plan: nil,
                    addedAt: Date(),
                    isActiveLive: true,
                    avatarURL: resolved.pictureURL
                )
            )
        }
        registry.setActiveLive(accountId: resolved.sub, for: .antigravity)
        return resolved.sub
    }

    public func importLiveAccount() async throws -> AccountRecord {
        guard let live = readLiveBundle(), let refreshToken = live.refreshToken else {
            throw ProviderAdapterError.invalidCredential("未检测到本机 Antigravity 登录凭证，请先在 Antigravity 中登录")
        }

        var accessToken = live.accessToken
        var idToken = live.idToken
        var currentRefreshToken = refreshToken

        let needsMint = accessToken == nil || (live.expiry.map { $0 <= Date().addingTimeInterval(60) } ?? true)
        if needsMint {
            let minted = try await refreshAccessToken(refreshToken: refreshToken)
            accessToken = minted.accessToken
            if let newID = minted.idToken { idToken = newID }
            if let rotatedRT = minted.refreshToken { currentRefreshToken = rotatedRT }
        }

        guard let identity = await resolveGoogleIdentity(accessToken: accessToken, idToken: idToken) else {
            throw ProviderAdapterError.invalidCredential("无法解析当前 Antigravity 账号身份 (sub)")
        }

        try keychain.writeSecret(
            service: isolatedStoreNamespace,
            account: identity.sub,
            value: currentRefreshToken
        )

        var plan: PlanInfo?
        if let accessToken {
            let info = await fetchLoadCodeAssist(accessToken: accessToken)
            plan = info?.plan
        }

        return AccountRecord(
            id: identity.sub,
            provider: .antigravity,
            email: identity.email,
            displayName: identity.displayName,
            plan: plan,
            addedAt: Date(),
            isActiveLive: true,
            avatarURL: identity.pictureURL
        )
    }

    // MARK: - Add Account (Google OAuth PKCE S256 Loopback)

    public func addAccount() async throws -> AccountRecord {
        let clientSecret = try await discoverOAuthClientSecret()

        let codeVerifier = Self.randomBase64URL(byteCount: 32)
        let challengeDigest = SHA256.hash(data: Data(codeVerifier.utf8))
        let codeChallenge = Formatters.base64URLEncode(Data(challengeDigest))
        let state = Self.randomBase64URL(byteCount: 16)

        let server = try LoopbackOAuthServer()
        defer { server.close() }

        let redirectURI = "http://127.0.0.1:\(server.port)/oauth-callback"
        var comps = URLComponents(string: Self.googleAuthURL)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: Self.consumerClientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.oauthScopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authURL = comps.url else {
            throw ProviderAdapterError.operationFailed("构造 Google OAuth 链接失败")
        }

        await MainActor.run {
            _ = NSWorkspace.shared.open(authURL)
        }

        let callback = try await server.waitForCallback(expectedState: state, timeoutSeconds: 180)
        let tokenResp = try await exchangeAuthCode(
            code: callback.code,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI,
            clientSecret: clientSecret
        )

        guard let refreshToken = tokenResp.refreshToken, !refreshToken.isEmpty else {
            throw ProviderAdapterError.invalidCredential("Google 未返回 refresh_token，请在授权页勾选完整权限后重试")
        }

        guard let identity = await resolveGoogleIdentity(accessToken: tokenResp.accessToken, idToken: tokenResp.idToken) else {
            throw ProviderAdapterError.invalidCredential("获取 Google 账号信息失败")
        }

        try keychain.writeSecret(
            service: isolatedStoreNamespace,
            account: identity.sub,
            value: refreshToken
        )

        let assistInfo = await fetchLoadCodeAssist(accessToken: tokenResp.accessToken)
        return AccountRecord(
            id: identity.sub,
            provider: .antigravity,
            email: identity.email,
            displayName: identity.displayName,
            plan: assistInfo?.plan,
            addedAt: Date(),
            isActiveLive: false,
            avatarURL: identity.pictureURL
        )
    }

    // MARK: - 2-Tier Quota Pipeline (Local Connect RPC -> Remote Cloud Code)

    public func fetchQuota(for account: AccountRecord, isActiveLive: Bool) async -> QuotaSnapshot {
        // Tier 1: Local language_server Connect RPC when querying the active live account.
        if isActiveLive, let localSnap = await fetchLocalRPCQuota(for: account) {
            return localSnap
        }

        // Tier 2: Remote Cloud Code via Google OAuth refresh token (works for all inactive & active accounts).
        return await fetchRemoteCloudCodeQuota(for: account, isActiveLive: isActiveLive)
    }

    // MARK: Tier 1 — Local `language_server` Connect RPC

    private struct LocalServerEndpoint {
        let pid: Int
        let csrfToken: String
        let ports: [Int]
    }

    private func fetchLocalRPCQuota(for account: AccountRecord) async -> QuotaSnapshot? {
        let endpoints = discoverLocalLanguageServerEndpoints()
        guard !endpoints.isEmpty else { return nil }

        let version = resolveStableAppVersion()
        endpointLoop: for endpoint in endpoints {
            for port in endpoint.ports {
                for scheme in ["https", "http"] {
                    let baseURL = "\(scheme)://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService"

                    // 1. Probe with GetUnleashData.
                    let probeBody: [String: Any] = [
                        "context": [
                            "properties": [
                                "ide": "antigravity",
                                "ideVersion": version,
                                "os": "macos",
                            ],
                        ],
                    ]
                    guard await postLocalRPC(
                        urlString: "\(baseURL)/GetUnleashData",
                        csrfToken: endpoint.csrfToken,
                        body: probeBody
                    ) != nil else {
                        continue
                    }

                    // 2. Check GetUserStatus to confirm email match & read plan info.
                    var resolvedPlan = account.plan
                    var userStatusObj: [String: Any]?
                    if let statusJSON = await postLocalRPC(
                        urlString: "\(baseURL)/GetUserStatus",
                        csrfToken: endpoint.csrfToken,
                        body: [:]
                    ) {
                        userStatusObj = statusJSON
                        let userStatus = (statusJSON["userStatus"] as? [String: Any]) ?? statusJSON
                        if let localEmail = nonEmpty(userStatus["email"] as? String),
                           !account.email.isEmpty,
                           localEmail.lowercased() != account.email.lowercased() {
                            // Local language_server belongs to a different account; try next endpoint instead of leaking!
                            continue endpointLoop
                        }
                        if let plan = Self.parsePlanFromUserStatus(userStatus) {
                            resolvedPlan = plan
                        }
                    }

                    // 3. Call RetrieveUserQuotaSummary.
                    if let summaryJSON = await postLocalRPC(
                        urlString: "\(baseURL)/RetrieveUserQuotaSummary",
                        csrfToken: endpoint.csrfToken,
                        body: [:]
                    ) {
                        let windows = Self.parseQuotaSummaryWindows(from: summaryJSON)
                        if !windows.isEmpty {
                            return QuotaSnapshot(
                                provider: .antigravity,
                                accountId: account.id,
                                plan: resolvedPlan,
                                windows: windows,
                                balance: nil,
                                status: .ready(fetchedAt: Date(), stale: false),
                                sourceLabel: "本地 RPC"
                            )
                        }
                    }

                    // 4. Fallback to GetUserStatus model configs or GetCommandModelConfigs.
                    if let userStatusObj {
                        let windows = Self.parseModelConfigWindows(from: userStatusObj)
                        if !windows.isEmpty {
                            return QuotaSnapshot(
                                provider: .antigravity,
                                accountId: account.id,
                                plan: resolvedPlan,
                                windows: windows,
                                balance: nil,
                                status: .ready(fetchedAt: Date(), stale: false),
                                sourceLabel: "本地 RPC"
                            )
                        }
                    }

                    if let cmdConfigsJSON = await postLocalRPC(
                        urlString: "\(baseURL)/GetCommandModelConfigs",
                        csrfToken: endpoint.csrfToken,
                        body: [:]
                    ) {
                        let windows = Self.parseModelConfigWindows(from: cmdConfigsJSON)
                        if !windows.isEmpty {
                            return QuotaSnapshot(
                                provider: .antigravity,
                                accountId: account.id,
                                plan: resolvedPlan,
                                windows: windows,
                                balance: nil,
                                status: .ready(fetchedAt: Date(), stale: false),
                                sourceLabel: "本地 RPC"
                            )
                        }
                    }
                }
            }
        }
        return nil
    }

    private func discoverLocalLanguageServerEndpoints() -> [LocalServerEndpoint] {
        let procs = processController.inspector.allRunningProcesses()
        var endpoints: [LocalServerEndpoint] = []

        for proc in procs {
            let base = URL(fileURLWithPath: proc.executablePath).lastPathComponent.lowercased()
            let lowerPath = proc.executablePath.lowercased()
            guard base.hasPrefix("language_server"),
                  (lowerPath.contains("antigravity") || lowerPath.contains("/.gemini/")) else {
                continue
            }

            let args = processController.inspector.processArguments(pid: proc.id)
            guard let csrf = Self.extractFlagValue(from: args, names: ["--csrf_token", "--csrf-token"]) else {
                continue
            }

            var ports = Self.listeningTCPPorts(forPID: proc.id)
            if let extPortStr = Self.extractFlagValue(from: args, names: ["--extension_server_port", "--port"]),
               let extPort = Int(extPortStr),
               !ports.contains(extPort) {
                ports.append(extPort)
            }
            guard !ports.isEmpty else { continue }

            endpoints.append(LocalServerEndpoint(pid: proc.id, csrfToken: csrf, ports: ports))
        }

        return endpoints
    }

    private static func extractFlagValue(from args: [String], names: [String]) -> String? {
        for (idx, arg) in args.enumerated() {
            for name in names {
                if arg == name, idx + 1 < args.count {
                    let val = args[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !val.isEmpty { return val }
                } else if arg.hasPrefix(name + "=") {
                    let val = String(arg.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !val.isEmpty { return val }
                }
            }
        }
        return nil
    }

    private static func listeningTCPPorts(forPID pid: Int) -> [Int] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return []
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var ports: [Int] = []
        var seen = Set<Int>()
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("n") else { continue }
            let addr = String(line.dropFirst())
            guard let colonIdx = addr.lastIndex(of: ":") else { continue }
            let portStr = String(addr[addr.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let port = Int(portStr), (1...65535).contains(port), seen.insert(port).inserted {
                ports.append(port)
            }
        }
        return ports
    }

    private func postLocalRPC(
        urlString: String,
        csrfToken: String,
        body: [String: Any]
    ) async -> [String: Any]? {
        guard let url = URL(string: urlString),
              let bodyData = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            return nil
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        req.httpBody = bodyData

        do {
            let (data, resp) = try await localRPCSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
        } catch {
            return nil
        }
    }

    // MARK: Tier 2 — Remote Cloud Code API

    private struct CodeAssistInfo {
        let plan: PlanInfo?
        let projectId: String?
    }

    private func fetchRemoteCloudCodeQuota(for account: AccountRecord, isActiveLive: Bool) async -> QuotaSnapshot {
        let accessToken: String
        do {
            accessToken = try await resolveRemoteAccessToken(for: account, isActiveLive: isActiveLive)
        } catch let err as ProviderAdapterError {
            if case .authenticationRequired(let msg) = err {
                return .reauthRequired(provider: .antigravity, accountId: account.id, sourceLabel: "Cloud Code", message: msg)
            }
            if case .invalidCredential(let msg) = err {
                return .unconfigured(provider: .antigravity, accountId: account.id, sourceLabel: "Cloud Code", message: msg)
            }
            return .failed(provider: .antigravity, accountId: account.id, sourceLabel: "Cloud Code", message: err.localizedDescription)
        } catch {
            return .failed(provider: .antigravity, accountId: account.id, sourceLabel: "Cloud Code", message: error.localizedDescription)
        }

        let nativeUA = resolveNativeUserAgent()
        var resolvedPlan = account.plan

        // 1. Primary endpoint: daily-cloudcode-pa:retrieveUserQuotaSummary (`{}`) with native UA.
        let primaryResult = await postCloudCode(
            urlString: Self.dailyQuotaSummaryURL,
            accessToken: accessToken,
            userAgent: nativeUA,
            body: [:]
        )

        switch primaryResult {
        case .success(let json):
            let windows = Self.parseQuotaSummaryWindows(from: json)
            if !windows.isEmpty {
                let needsPlanRefresh = resolvedPlan == nil
                    || resolvedPlan?.kind == .unknown
                    || resolvedPlan?.kind == .team
                if needsPlanRefresh,
                   let refreshedPlan = await fetchLoadCodeAssist(accessToken: accessToken)?.plan {
                    resolvedPlan = refreshedPlan
                }
                return QuotaSnapshot(
                    provider: .antigravity,
                    accountId: account.id,
                    plan: resolvedPlan,
                    windows: windows,
                    balance: nil,
                    status: .ready(fetchedAt: Date(), stale: false),
                    sourceLabel: "Cloud Code"
                )
            }
        case .httpError(401):
            return .reauthRequired(
                provider: .antigravity,
                accountId: account.id,
                sourceLabel: "Cloud Code",
                message: "Google 凭证已过期 (HTTP 401)，请重新登录"
            )
        case .httpError(403):
            break // Proceed cleanly to loadCodeAssist + fallback endpoints!
        case .httpError(let code):
            // Try fallback chain for non-401 errors before giving up.
            _ = code
        case .networkError(let msg):
            return .failed(
                provider: .antigravity,
                accountId: account.id,
                sourceLabel: "Cloud Code",
                message: "请求 Cloud Code 失败: \(msg)"
            )
        }

        // 2. On 403 / empty summary: call loadCodeAssist to extract paidTier/currentTier + cloudaicompanionProject.
        let assist = await fetchLoadCodeAssist(accessToken: accessToken)
        if let assistPlan = assist?.plan {
            resolvedPlan = assistPlan
        }

        var projectBody: [String: Any] = [:]
        if let projectId = assist?.projectId, !projectId.isEmpty {
            projectBody["project"] = projectId
        }

        // 3. Fallback A: cloudcode-pa:fetchAvailableModels
        let modelsResult = await postCloudCode(
            urlString: Self.fetchAvailableModelsURL,
            accessToken: accessToken,
            userAgent: nativeUA,
            body: projectBody
        )
        if case .success(let modelsJSON) = modelsResult {
            let windows = Self.parseAvailableModelsWindows(from: modelsJSON)
            if !windows.isEmpty {
                return QuotaSnapshot(
                    provider: .antigravity,
                    accountId: account.id,
                    plan: resolvedPlan,
                    windows: windows,
                    balance: nil,
                    status: .ready(fetchedAt: Date(), stale: false),
                    sourceLabel: "Cloud Code"
                )
            }
        }

        // 4. Fallback B: cloudcode-pa:retrieveUserQuota
        let userQuotaResult = await postCloudCode(
            urlString: Self.retrieveUserQuotaURL,
            accessToken: accessToken,
            userAgent: nativeUA,
            body: projectBody
        )
        switch userQuotaResult {
        case .success(let quotaJSON):
            let windows = Self.parseRetrieveUserQuotaWindows(from: quotaJSON)
            if !windows.isEmpty {
                return QuotaSnapshot(
                    provider: .antigravity,
                    accountId: account.id,
                    plan: resolvedPlan,
                    windows: windows,
                    balance: nil,
                    status: .ready(fetchedAt: Date(), stale: false),
                    sourceLabel: "Cloud Code"
                )
            }
            return QuotaSnapshot(
                provider: .antigravity,
                accountId: account.id,
                plan: resolvedPlan,
                windows: [],
                balance: nil,
                status: .failed("未返回可用的配额分组"),
                sourceLabel: "Cloud Code"
            )
        case .httpError(401):
            return .reauthRequired(
                provider: .antigravity,
                accountId: account.id,
                sourceLabel: "Cloud Code",
                message: "Google 凭证已失效 (HTTP 401)，请重新登录"
            )
        case .httpError(403):
            return QuotaSnapshot(
                provider: .antigravity,
                accountId: account.id,
                plan: resolvedPlan,
                windows: [],
                balance: nil,
                status: .failed("该账号无权访问 Cloud Code 额度 (HTTP 403，请检查订阅或系统代理节点)"),
                sourceLabel: "Cloud Code"
            )
        case .httpError(let code):
            return QuotaSnapshot(
                provider: .antigravity,
                accountId: account.id,
                plan: resolvedPlan,
                windows: [],
                balance: nil,
                status: .failed("Cloud Code 接口返回 HTTP \(code)"),
                sourceLabel: "Cloud Code"
            )
        case .networkError(let msg):
            return QuotaSnapshot(
                provider: .antigravity,
                accountId: account.id,
                plan: resolvedPlan,
                windows: [],
                balance: nil,
                status: .failed("网络错误: \(msg)"),
                sourceLabel: "Cloud Code"
            )
        }
    }

    private struct RemoteAccessCredentials {
        let accessToken: String
        let idToken: String?
    }

    private func resolveRemoteAccessToken(for account: AccountRecord, isActiveLive: Bool) async throws -> String {
        try await resolveRemoteAccessCredentials(for: account, isActiveLive: isActiveLive).accessToken
    }

    private func resolveRemoteAccessCredentials(
        for account: AccountRecord,
        isActiveLive: Bool
    ) async throws -> RemoteAccessCredentials {
        // Reuse valid live access_token for active account when available (saves an OAuth round-trip).
        if isActiveLive, let live = readLiveBundle() {
            if let liveAccess = live.accessToken,
               let expiry = live.expiry,
               expiry > Date().addingTimeInterval(60) {
                if let idToken = live.idToken,
                   let claims = Formatters.decodeJWTPayload(idToken),
                   let sub = nonEmpty(claims["sub"] as? String) {
                    if sub == account.id {
                        return RemoteAccessCredentials(accessToken: liveAccess, idToken: live.idToken)
                    }
                } else {
                    return RemoteAccessCredentials(accessToken: liveAccess, idToken: live.idToken)
                }
            }
            if let liveRT = live.refreshToken,
               (try? keychain.readSecret(service: isolatedStoreNamespace, account: account.id)) == nil {
                let minted = try await refreshAccessToken(refreshToken: liveRT)
                return RemoteAccessCredentials(accessToken: minted.accessToken, idToken: minted.idToken)
            }
        }

        guard let refreshToken = try keychain.readSecret(service: isolatedStoreNamespace, account: account.id),
              !refreshToken.isEmpty else {
            throw ProviderAdapterError.invalidCredential("钥匙串中未找到该 Antigravity 账号的 Refresh Token")
        }

        let minted = try await refreshAccessToken(refreshToken: refreshToken)
        if let rotated = minted.refreshToken, rotated != refreshToken {
            try? keychain.writeSecret(service: isolatedStoreNamespace, account: account.id, value: rotated)
        }
        return RemoteAccessCredentials(accessToken: minted.accessToken, idToken: minted.idToken)
    }

    /// Best-effort read-only lookup for an Antigravity account's Google avatar HTTPS URL when missing.
    public func fetchUserPictureURL(for account: AccountRecord, isActiveLive: Bool) async -> String? {
        guard account.provider == .antigravity else { return nil }
        if let existing = Formatters.sanitizedHTTPSURLString(account.avatarURL) {
            return existing
        }

        if isActiveLive,
           let live = readLiveBundle(),
           let idToken = live.idToken,
           let claims = Formatters.decodeJWTPayload(idToken),
           nonEmpty(claims["sub"] as? String) == account.id,
           let picture = Formatters.sanitizedHTTPSURLString(claims["picture"] as? String) {
            return picture
        }

        guard let creds = try? await resolveRemoteAccessCredentials(for: account, isActiveLive: isActiveLive) else {
            return nil
        }

        if let idToken = creds.idToken,
           let claims = Formatters.decodeJWTPayload(idToken),
           nonEmpty(claims["sub"] as? String) == account.id,
           let picture = Formatters.sanitizedHTTPSURLString(claims["picture"] as? String) {
            return picture
        }

        guard let identity = await resolveGoogleIdentity(accessToken: creds.accessToken, idToken: creds.idToken),
              identity.sub == account.id else {
            return nil
        }
        return identity.pictureURL
    }

    private func fetchLoadCodeAssist(accessToken: String) async -> CodeAssistInfo? {
        let body: [String: Any] = [
            "metadata": [
                "ideType": "ANTIGRAVITY",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ],
        ]
        let res = await postCloudCode(
            urlString: Self.loadCodeAssistURL,
            accessToken: accessToken,
            userAgent: resolveNativeUserAgent(),
            body: body
        )
        guard case .success(let json) = res else { return nil }
        return Self.parseCodeAssistInfo(from: json)
    }

    private enum CloudCodeResult {
        case success([String: Any])
        case httpError(Int)
        case networkError(String)
    }

    private func postCloudCode(
        urlString: String,
        accessToken: String,
        userAgent: String,
        body: [String: Any]
    ) async -> CloudCodeResult {
        guard let url = URL(string: urlString),
              let bodyData = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            return .networkError("无法构造请求")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = bodyData

        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code) else {
                return .httpError(code)
            }
            guard let obj = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
                return .networkError("响应 JSON 解析失败")
            }
            return .success(obj)
        } catch {
            return .networkError(error.localizedDescription)
        }
    }

    // MARK: - Antigravity Quota & Plan Parsers (Proto3 Zero-Omission & 5h/Weekly Aware)

    private struct PoolSpec {
        let id: String
        let baseLabel: String
        let flatLabel: String
        let sortOrder: Int
        let defaultWindowSeconds: Int?
    }

    private struct WindowSpec {
        let idSuffix: String
        let tag: String
        let windowSeconds: Int?
        let sortOrder: Int
    }

    private struct PoolAggregate {
        let id: String
        let label: String
        let poolSortOrder: Int
        let windowSortOrder: Int
        var minRemaining: Double
        var earliestReset: Date?
        var windowSeconds: Int?
        var detail: String?
    }

    private static func classifyPool(rawName: String) -> PoolSpec {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("argon") {
            return PoolSpec(
                id: "argon",
                baseLabel: "Argon",
                flatLabel: "Argon 周额",
                sortOrder: 2,
                defaultWindowSeconds: 604_800
            )
        }
        if lower.contains("gemini") {
            return PoolSpec(
                id: "gemini",
                baseLabel: "Gemini",
                flatLabel: "Gemini",
                sortOrder: 0,
                defaultWindowSeconds: nil
            )
        }
        if lower.contains("gpt")
            || lower.contains("partner")
            || lower.contains("third")
            || lower.contains("anthropic")
            || lower.contains("claud")
            || lower == "3p"
            || lower.hasPrefix("3p-")
            || lower.hasPrefix("3p_") {
            return PoolSpec(
                id: "claude_gpt",
                baseLabel: "Claude / GPT",
                flatLabel: "Claude / GPT",
                sortOrder: 1,
                defaultWindowSeconds: nil
            )
        }
        let slug = lower
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        return PoolSpec(
            id: slug.isEmpty ? "pool" : slug,
            baseLabel: trimmed.isEmpty ? "默认池" : trimmed,
            flatLabel: trimmed.isEmpty ? "默认池" : trimmed,
            sortOrder: 10,
            defaultWindowSeconds: nil
        )
    }

    private static func classifyWindow(from dict: [String: Any]) -> WindowSpec? {
        let rawWindow = nonEmptyStatic(dict["window"] as? String)
            ?? nonEmptyStatic(dict["windowType"] as? String)
            ?? nonEmptyStatic(dict["window_type"] as? String)
            ?? nonEmptyStatic(dict["period"] as? String)

        if let rawWindow {
            let lower = rawWindow.lowercased()
            if lower == "5h"
                || lower == "5hr"
                || lower == "5-hour"
                || lower == "5_hour"
                || lower == "five_hour"
                || lower == "five-hour"
                || lower == "five hour"
                || lower == "5 hour"
                || lower.contains("5-hour")
                || lower.contains("five hour") {
                return WindowSpec(idSuffix: "5h", tag: "5小时", windowSeconds: 18_000, sortOrder: 0)
            }
            if lower == "weekly"
                || lower == "week"
                || lower == "7d"
                || lower == "7-day"
                || lower == "7_day"
                || lower == "seven_day"
                || lower == "seven-day"
                || lower == "1w"
                || lower.contains("week") {
                return WindowSpec(idSuffix: "weekly", tag: "周", windowSeconds: 604_800, sortOrder: 1)
            }
            if lower == "daily" || lower == "day" || lower == "24h" || lower == "1d" {
                return WindowSpec(idSuffix: "daily", tag: "日", windowSeconds: 86_400, sortOrder: 2)
            }
            if lower == "monthly" || lower == "month" || lower == "30d" {
                return WindowSpec(idSuffix: "monthly", tag: "月", windowSeconds: 2_592_000, sortOrder: 3)
            }
            let slug = lower
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: "/", with: "_")
            return WindowSpec(idSuffix: slug.isEmpty ? "window" : slug, tag: rawWindow, windowSeconds: nil, sortOrder: 5)
        }

        // Infer from explicit duration fields if present.
        if let secsNum = (dict["windowSeconds"] as? NSNumber)
            ?? (dict["window_seconds"] as? NSNumber)
            ?? (dict["limitWindowSeconds"] as? NSNumber)
            ?? (dict["limit_window_seconds"] as? NSNumber) {
            let secs = secsNum.intValue
            if secs == 18_000 {
                return WindowSpec(idSuffix: "5h", tag: "5小时", windowSeconds: 18_000, sortOrder: 0)
            }
            if secs == 604_800 {
                return WindowSpec(idSuffix: "weekly", tag: "周", windowSeconds: 604_800, sortOrder: 1)
            }
        }

        // Infer from bucketId / bucket displayName (e.g. `gemini-5h`, `3p-weekly`, `Five Hour Limit Remaining`).
        let bucketId = nonEmptyStatic(dict["bucketId"] as? String)
            ?? nonEmptyStatic(dict["bucket_id"] as? String)
            ?? ""
        let bucketDisplay = nonEmptyStatic(dict["displayName"] as? String)
            ?? nonEmptyStatic(dict["name"] as? String)
            ?? nonEmptyStatic(dict["label"] as? String)
            ?? ""
        let hint = "\(bucketId) \(bucketDisplay)".lowercased()
        if hint.contains("-5h")
            || hint.contains("_5h")
            || hint.contains("5-hour")
            || hint.contains("five hour")
            || hint.contains("five-hour")
            || hint.contains("five_hour")
            || hint.contains("5 hour") {
            return WindowSpec(idSuffix: "5h", tag: "5小时", windowSeconds: 18_000, sortOrder: 0)
        }
        if hint.contains("weekly")
            || hint.contains("-week")
            || hint.contains("_week")
            || hint.contains("7-day")
            || hint.contains("7d") {
            return WindowSpec(idSuffix: "weekly", tag: "周", windowSeconds: 604_800, sortOrder: 1)
        }
        return nil
    }

    private static func isInternalHelperModel(modelId: String?, displayName: String?) -> Bool {
        if nonEmptyStatic(displayName) != nil {
            return false
        }
        guard let raw = nonEmptyStatic(modelId)?.lowercased() else { return true }
        return raw.hasPrefix("chat_") || raw.hasPrefix("tab_") || raw.hasPrefix("rev_")
    }

    /// Parses `retrieveUserQuotaSummary` / local `RetrieveUserQuotaSummary` JSON responses,
    /// splitting each model group cleanly into separate `5小时` and `周` (`QuotaWindow`) entries.
    /// Remember proto3 JSON omits `0.0`: missing `remainingFraction` inside an active bucket/group means `0.0` (exhausted)!
    public static func parseQuotaSummaryWindows(from json: [String: Any]) -> [QuotaWindow] {
        let summaryObj = (json["summary"] as? [String: Any])
            ?? (json["response"] as? [String: Any])
            ?? json
        guard let groups = summaryObj["groups"] as? [[String: Any]], !groups.isEmpty else {
            return []
        }

        var pools: [String: PoolAggregate] = [:]

        for group in groups {
            if let disabled = group["disabled"] as? Bool, disabled {
                continue
            }

            let rawGroupName = nonEmptyStatic(group["displayName"] as? String)
                ?? nonEmptyStatic(group["name"] as? String)
                ?? nonEmptyStatic(group["groupName"] as? String)
                ?? nonEmptyStatic(group["label"] as? String)
                ?? nonEmptyStatic(group["id"] as? String)
                ?? ""

            if let buckets = group["buckets"] as? [[String: Any]] {
                guard !buckets.isEmpty else { continue }
                for bucket in buckets {
                    if let disabled = bucket["disabled"] as? Bool, disabled { continue }

                    let hasBucketSignal = bucket["window"] != nil
                        || bucket["bucketId"] != nil
                        || bucket["bucket_id"] != nil
                        || bucket["displayName"] != nil
                        || bucket["remainingFraction"] != nil
                        || bucket["remaining_fraction"] != nil
                        || bucket["resetTime"] != nil
                        || bucket["reset_time"] != nil
                    guard hasBucketSignal else { continue }

                    let bucketId = nonEmptyStatic(bucket["bucketId"] as? String)
                        ?? nonEmptyStatic(bucket["bucket_id"] as? String)
                        ?? ""
                    let bucketDisplay = nonEmptyStatic(bucket["displayName"] as? String)
                        ?? nonEmptyStatic(bucket["name"] as? String)
                        ?? nonEmptyStatic(bucket["label"] as? String)
                        ?? nonEmptyStatic(bucket["modelId"] as? String)
                        ?? ""

                    let effectivePoolName: String
                    if rawGroupName.lowercased().contains("argon")
                        || bucketId.lowercased().contains("argon")
                        || bucketDisplay.lowercased().contains("argon") {
                        effectivePoolName = "Gemini 4 Argon"
                    } else if !rawGroupName.isEmpty {
                        effectivePoolName = rawGroupName
                    } else if !bucketId.isEmpty {
                        effectivePoolName = bucketId
                    } else {
                        effectivePoolName = bucketDisplay
                    }

                    let windowSpec = classifyWindow(from: bucket)
                    let fraction = extractProto3RemainingFraction(from: bucket)
                    let resetAt = extractResetDate(from: bucket)
                    let detail = nonEmptyStatic(bucket["resetDescription"] as? String)

                    accumulatePool(
                        into: &pools,
                        rawName: effectivePoolName,
                        window: windowSpec,
                        remaining: fraction,
                        resetAt: resetAt,
                        detail: detail
                    )
                }
            } else {
                // Legacy / flat group directly holding remainingFraction / resetTime (proto3 missing remainingFraction == 0.0).
                let hasQuotaSignal = group["remainingFraction"] != nil
                    || group["remaining_fraction"] != nil
                    || group["resetTime"] != nil
                    || group["reset_time"] != nil
                    || group["window"] != nil
                guard hasQuotaSignal else { continue }

                let fallbackName = rawGroupName.isEmpty
                    ? (nonEmptyStatic(group["description"] as? String) ?? "")
                    : rawGroupName
                let windowSpec = classifyWindow(from: group)
                let fraction = extractProto3RemainingFraction(from: group)
                let resetAt = extractResetDate(from: group)
                let detail = nonEmptyStatic(group["resetDescription"] as? String)
                accumulatePool(
                    into: &pools,
                    rawName: fallbackName,
                    window: windowSpec,
                    remaining: fraction,
                    resetAt: resetAt,
                    detail: detail
                )
            }
        }

        return finalizePoolWindows(pools)
    }

    /// Parses local `GetUserStatus` / `GetCommandModelConfigs` `clientModelConfigs` arrays.
    public static func parseModelConfigWindows(from json: [String: Any]) -> [QuotaWindow] {
        let userStatus = (json["userStatus"] as? [String: Any]) ?? json
        let cascade = (userStatus["cascadeModelConfigData"] as? [String: Any]) ?? userStatus
        guard let configs = cascade["clientModelConfigs"] as? [[String: Any]], !configs.isEmpty else {
            return []
        }

        var pools: [String: PoolAggregate] = [:]
        for cfg in configs {
            guard let quotaInfo = cfg["quotaInfo"] as? [String: Any] else { continue }
            let modelAlias = (cfg["modelOrAlias"] as? [String: Any])?["model"] as? String
            let displayName = nonEmptyStatic(cfg["label"] as? String)
            if isInternalHelperModel(modelId: modelAlias, displayName: displayName) {
                continue
            }
            let rawName = displayName ?? nonEmptyStatic(modelAlias) ?? "Gemini"
            let fraction = extractProto3RemainingFraction(from: quotaInfo)
            let resetAt = extractResetDate(from: quotaInfo)
            let windowSpec = classifyWindow(from: quotaInfo)
            accumulatePool(
                into: &pools,
                rawName: rawName,
                window: windowSpec,
                remaining: fraction,
                resetAt: resetAt,
                detail: nil
            )
        }
        return finalizePoolWindows(pools)
    }

    /// Parses `cloudcode-pa:fetchAvailableModels` responses (supports dictionary or array `models`).
    public static func parseAvailableModelsWindows(from json: [String: Any]) -> [QuotaWindow] {
        var pools: [String: PoolAggregate] = [:]

        if let modelsDict = json["models"] as? [String: Any] {
            for (modelId, rawVal) in modelsDict {
                guard let entry = rawVal as? [String: Any],
                      let quotaInfo = entry["quotaInfo"] as? [String: Any] else {
                    continue
                }
                let displayName = nonEmptyStatic(entry["displayName"] as? String)
                    ?? nonEmptyStatic(entry["label"] as? String)
                if isInternalHelperModel(modelId: modelId, displayName: displayName) {
                    continue
                }
                let rawName = displayName ?? modelId
                let fraction = extractProto3RemainingFraction(from: quotaInfo)
                let resetAt = extractResetDate(from: quotaInfo)
                let windowSpec = classifyWindow(from: quotaInfo)
                accumulatePool(
                    into: &pools,
                    rawName: rawName,
                    window: windowSpec,
                    remaining: fraction,
                    resetAt: resetAt,
                    detail: nil
                )
            }
        } else if let modelsArr = json["models"] as? [[String: Any]] {
            for entry in modelsArr {
                guard let quotaInfo = entry["quotaInfo"] as? [String: Any] else { continue }
                let displayName = nonEmptyStatic(entry["displayName"] as? String)
                    ?? nonEmptyStatic(entry["label"] as? String)
                let modelId = nonEmptyStatic(entry["modelId"] as? String)
                    ?? nonEmptyStatic(entry["name"] as? String)
                if isInternalHelperModel(modelId: modelId, displayName: displayName) {
                    continue
                }
                let rawName = displayName ?? modelId ?? "Gemini"
                let fraction = extractProto3RemainingFraction(from: quotaInfo)
                let resetAt = extractResetDate(from: quotaInfo)
                let windowSpec = classifyWindow(from: quotaInfo)
                accumulatePool(
                    into: &pools,
                    rawName: rawName,
                    window: windowSpec,
                    remaining: fraction,
                    resetAt: resetAt,
                    detail: nil
                )
            }
        }

        return finalizePoolWindows(pools)
    }

    /// Parses `cloudcode-pa:retrieveUserQuota` `buckets[]` responses.
    public static func parseRetrieveUserQuotaWindows(from json: [String: Any]) -> [QuotaWindow] {
        guard let buckets = json["buckets"] as? [[String: Any]], !buckets.isEmpty else {
            return []
        }

        var pools: [String: PoolAggregate] = [:]
        for bucket in buckets {
            let modelId = nonEmptyStatic(bucket["modelId"] as? String)
            let displayName = nonEmptyStatic(bucket["displayName"] as? String)
            if isInternalHelperModel(modelId: modelId, displayName: displayName) {
                continue
            }
            let rawName = modelId
                ?? displayName
                ?? nonEmptyStatic(bucket["bucketId"] as? String)
                ?? "Gemini"
            let fraction = extractProto3RemainingFraction(from: bucket)
            let resetAt = extractResetDate(from: bucket)
            let windowSpec = classifyWindow(from: bucket)
            accumulatePool(
                into: &pools,
                rawName: rawName,
                window: windowSpec,
                remaining: fraction,
                resetAt: resetAt,
                detail: nil
            )
        }
        return finalizePoolWindows(pools)
    }

    private static func accumulatePool(
        into pools: inout [String: PoolAggregate],
        rawName: String,
        window: WindowSpec?,
        remaining: Double,
        resetAt: Date?,
        detail: String?
    ) {
        let clamped = min(max(remaining, 0.0), 1.0)
        let pool = classifyPool(rawName: rawName)

        let keyId: String
        let label: String
        let windowSortOrder: Int
        let windowSeconds: Int?
        if let window {
            keyId = "\(pool.id)_\(window.idSuffix)"
            label = "\(pool.baseLabel) · \(window.tag)"
            windowSortOrder = window.sortOrder
            windowSeconds = window.windowSeconds ?? pool.defaultWindowSeconds
        } else {
            keyId = pool.id
            label = pool.flatLabel
            windowSortOrder = 99
            windowSeconds = pool.defaultWindowSeconds
        }

        if var existing = pools[keyId] {
            if clamped < existing.minRemaining {
                existing.minRemaining = clamped
            }
            if let resetAt {
                if let curReset = existing.earliestReset {
                    if resetAt < curReset { existing.earliestReset = resetAt }
                } else {
                    existing.earliestReset = resetAt
                }
            }
            if existing.detail == nil, let detail {
                existing.detail = detail
            }
            pools[keyId] = existing
        } else {
            pools[keyId] = PoolAggregate(
                id: keyId,
                label: label,
                poolSortOrder: pool.sortOrder,
                windowSortOrder: windowSortOrder,
                minRemaining: clamped,
                earliestReset: resetAt,
                windowSeconds: windowSeconds,
                detail: detail
            )
        }
    }

    private static func finalizePoolWindows(_ pools: [String: PoolAggregate]) -> [QuotaWindow] {
        let sorted = pools.values.sorted { lhs, rhs in
            if lhs.poolSortOrder != rhs.poolSortOrder { return lhs.poolSortOrder < rhs.poolSortOrder }
            if lhs.windowSortOrder != rhs.windowSortOrder { return lhs.windowSortOrder < rhs.windowSortOrder }
            return lhs.label < rhs.label
        }
        guard !sorted.isEmpty else { return [] }

        let primaryId = sorted.first(where: { $0.id == "gemini_5h" })?.id
            ?? sorted.first(where: { $0.id == "gemini" })?.id
            ?? sorted.first(where: { $0.id == "gemini_weekly" })?.id
            ?? sorted.first(where: { $0.windowSeconds == 18_000 })?.id
            ?? sorted[0].id
        return sorted.map { p in
            QuotaWindow(
                id: p.id,
                label: p.label,
                remainingFraction: p.minRemaining,
                usedPercent: (1.0 - p.minRemaining) * 100.0,
                resetAt: p.earliestReset,
                windowSeconds: p.windowSeconds,
                detail: p.detail,
                isPrimary: p.id == primaryId
            )
        }
    }

    private static func extractProto3RemainingFraction(from dict: [String: Any]) -> Double {
        // Proto3 JSON omits 0.0: if remainingFraction is absent/null on a present quota object, treat as 0.0.
        if let val = dict["remainingFraction"] as? NSNumber {
            return min(max(val.doubleValue, 0.0), 1.0)
        }
        if let val = dict["remaining_fraction"] as? NSNumber {
            return min(max(val.doubleValue, 0.0), 1.0)
        }
        if let str = dict["remainingFraction"] as? String, let parsed = Double(str) {
            return min(max(parsed, 0.0), 1.0)
        }
        return 0.0
    }

    private static func extractResetDate(from dict: [String: Any]) -> Date? {
        for key in ["resetTime", "reset_time", "resetsAt", "resets_at"] {
            if let str = dict[key] as? String, let parsed = Formatters.parseRFC3339(str) {
                return parsed
            }
            if let num = dict[key] as? NSNumber {
                let v = num.doubleValue
                if v > 1_000_000_000 {
                    return Date(timeIntervalSince1970: v)
                }
            }
        }
        return nil
    }

    private static func normalizeGoogleTier(id rawId: String?, name rawName: String?) -> PlanInfo? {
        let tierId = nonEmptyStatic(rawId)
        let tierName = nonEmptyStatic(rawName)
        guard tierId != nil || tierName != nil else { return nil }

        let lowerId = (tierId ?? "").lowercased()
        if lowerId.contains("ultra") {
            return PlanInfo(kind: .ultra, displayName: tierName ?? "Google AI Ultra")
        }
        if lowerId.contains("prolite") || lowerId.contains("pro_lite") || lowerId.contains("pro-lite") {
            return PlanInfo(kind: .prolite, displayName: tierName ?? "Pro Lite")
        }
        if lowerId.contains("pro") {
            return PlanInfo(kind: .pro, displayName: tierName ?? "Google AI Pro")
        }
        if lowerId.contains("free") {
            return PlanInfo(kind: .free, displayName: "Free")
        }
        return PlanInfo.normalized(kindRaw: tierId, name: tierName)
    }

    private static func parseCodeAssistInfo(from json: [String: Any]) -> CodeAssistInfo {
        let paidTier = json["paidTier"] as? [String: Any]
        let currentTier = json["currentTier"] as? [String: Any]
        let tier = paidTier ?? currentTier
        let tierId = nonEmptyStatic(tier?["id"] as? String)
        let tierName = nonEmptyStatic(tier?["name"] as? String)
        let plan = normalizeGoogleTier(id: tierId, name: tierName)

        var projectId: String?
        if let projStr = nonEmptyStatic(json["cloudaicompanionProject"] as? String) {
            projectId = projStr
        } else if let projObj = json["cloudaicompanionProject"] as? [String: Any] {
            projectId = nonEmptyStatic(projObj["id"] as? String)
                ?? nonEmptyStatic(projObj["projectId"] as? String)
                ?? nonEmptyStatic(projObj["name"] as? String)
        }

        return CodeAssistInfo(plan: plan, projectId: projectId)
    }

    public static func parsePlanFromUserStatus(_ userStatus: [String: Any]) -> PlanInfo? {
        // Prefer `userTier` (`g1-ultra-tier` / `g1-pro-tier` / `free-tier`) over legacy `planStatus.planInfo.teamsTier`
        // (which reports `TEAMS_TIER_PRO` even on Google AI Ultra accounts).
        if let userTier = userStatus["userTier"] as? [String: Any] {
            let tierId = nonEmptyStatic(userTier["id"] as? String)
            let tierName = nonEmptyStatic(userTier["name"] as? String)
            if let plan = normalizeGoogleTier(id: tierId, name: tierName) {
                return plan
            }
        }

        let planStatus = userStatus["planStatus"] as? [String: Any]
        let planInfo = planStatus?["planInfo"] as? [String: Any]
        let rawName = nonEmptyStatic(planInfo?["planDisplayName"] as? String)
            ?? nonEmptyStatic(planInfo?["planName"] as? String)
            ?? nonEmptyStatic(planInfo?["planShortName"] as? String)
            ?? nonEmptyStatic(planInfo?["teamsTier"] as? String)
        var rawKind = nonEmptyStatic(planInfo?["teamsTier"] as? String)
            ?? nonEmptyStatic(planInfo?["planShortName"] as? String)
            ?? rawName
        if let kindStr = rawKind, kindStr.lowercased().hasPrefix("teams_tier_") {
            rawKind = String(kindStr.dropFirst("teams_tier_".count))
        }
        return PlanInfo.normalized(kindRaw: rawKind, name: rawName)
    }

    // MARK: - Safe Account Switch (Transactional Verify -> GracefulStop -> AtomicWrite -> Readback -> Rollback)

    public func switchAccount(to account: AccountRecord, allowForceQuit: Bool) async -> SwitchResult {
        // Step 1: Mint & verify target token BEFORE stopping any running Antigravity process!
        guard let storedRefresh = try? keychain.readSecret(service: isolatedStoreNamespace, account: account.id),
              !storedRefresh.isEmpty else {
            return .failed("未在钥匙串中找到目标 Antigravity 账号凭证，请重新添加账号")
        }

        let minted: TokenResponse
        do {
            minted = try await refreshAccessToken(refreshToken: storedRefresh)
        } catch {
            return .failed("目标账号令牌验证失败，未停止任何进程: \(error.localizedDescription)")
        }

        guard let targetIdentity = await resolveGoogleIdentity(accessToken: minted.accessToken, idToken: minted.idToken) else {
            return .failed("无法校验目标账号 Google 身份，已中止切换")
        }
        guard targetIdentity.sub == account.id else {
            return .failed("目标凭证身份不匹配（安全校验失败），已中止切换")
        }

        let effectiveTargetRefresh = minted.refreshToken ?? storedRefresh
        if effectiveTargetRefresh != storedRefresh {
            try? keychain.writeSecret(service: isolatedStoreNamespace, account: account.id, value: effectiveTargetRefresh)
        }
        let targetExpiry = Date().addingTimeInterval(max(minted.expiresIn, 60.0))

        // Step 2: Check for interactive `agy` CLI sessions before stopping when !allowForceQuit.
        if !allowForceQuit {
            let status = await detectClientStatus()
            let interactiveCLI = status.runningProcesses.filter { $0.isInteractiveCLI }
            if !interactiveCLI.isEmpty {
                return .needsForceQuitConfirmation(surviving: interactiveCLI)
            }
        }

        // Step 3: Snapshot outgoing live bundle for backup & rollback, and save outgoing refresh token if newer.
        let outgoingLive = readLiveBundle()
        let previousKeychainRaw = outgoingLive?.rawKeychainString
        let previousMirrorData = outgoingLive?.rawMirrorData
        if let outgoingLive, let outRT = outgoingLive.refreshToken, !outRT.isEmpty {
            if let outIdentity = await resolveGoogleIdentity(accessToken: outgoingLive.accessToken, idToken: outgoingLive.idToken),
               outIdentity.sub != account.id {
                let existingVaulted = try? keychain.readSecret(service: isolatedStoreNamespace, account: outIdentity.sub)
                if existingVaulted != outRT {
                    try? keychain.writeSecret(service: isolatedStoreNamespace, account: outIdentity.sub, value: outRT)
                }
            }
        }

        // Step 4: Graceful stop across Stable + Insiders + language_server + agy (12s timeout; zero auto-SIGKILL).
        let stopResult = await processController.gracefulStop(
            bundleIDs: Self.bundleIDs,
            detachedExecutableMatchers: detachedExecutableMatchers(),
            timeoutSeconds: 12.0,
            allowForceQuit: allowForceQuit
        )

        let reopenURLs: [URL]
        switch stopResult {
        case .stillRunning(let surviving):
            return .needsForceQuitConfirmation(surviving: surviving)
        case .stopped(let urls):
            reopenURLs = urls
        }

        // Step 5: Atomic write Keychain `(gemini, antigravity)` + mirror `~/.gemini/jetski-standalone-oauth-token`.
        let bundleData: Data
        do {
            bundleData = try buildUpdatedBundleJSON(
                base: outgoingLive?.root,
                accessToken: minted.accessToken,
                refreshToken: effectiveTargetRefresh,
                expiry: targetExpiry,
                idToken: minted.idToken
            )
        } catch {
            await processController.reopenApps(urls: reopenURLs)
            return .failed("构造 Antigravity 凭证失败: \(error.localizedDescription)")
        }

        let encodedKeyring = Self.encodeGoKeyringValue(bundleData)
        do {
            try keychain.writeExternalGenericPassword(
                service: Self.liveKeychainService,
                account: Self.liveKeychainAccount,
                value: encodedKeyring
            )
            try KeychainStore.writeAtomicFile(data: bundleData, to: paths.mirrorTokenURL, mode: 0o600)

            // Step 6: Strict read-back verification of BOTH Keychain and mirror file (`refresh_token` + `sub`).
            try verifyLiveWriteReadback(
                expectedRefreshToken: effectiveTargetRefresh,
                expectedAccessToken: minted.accessToken,
                expectedSub: account.id
            )
        } catch {
            rollbackLiveCredentials(previousKeychainRaw: previousKeychainRaw, previousMirrorData: previousMirrorData)
            await processController.reopenApps(urls: reopenURLs)
            return .failed("写入或校验 Antigravity 凭证失败，已回滚原账号: \(error.localizedDescription)")
        }

        // Step 7: Reopen ONLY previously running bundle(s).
        await processController.reopenApps(urls: reopenURLs)
        let reopenedNames = reopenURLs.map { $0.deletingPathExtension().lastPathComponent }
        return .switched(reopenedApps: reopenedNames)
    }

    private func verifyLiveWriteReadback(
        expectedRefreshToken: String,
        expectedAccessToken: String,
        expectedSub: String
    ) throws {
        // Verify Keychain readback.
        guard let kcRaw = try keychain.readExternalGenericPassword(
            service: Self.liveKeychainService,
            account: Self.liveKeychainAccount
        ),
        let kcData = Self.decodeGoKeyringValue(kcRaw),
        let kcObj = (try? JSONSerialization.jsonObject(with: kcData, options: [])) as? [String: Any],
        let kcToken = kcObj["token"] as? [String: Any],
        (kcToken["refresh_token"] as? String) == expectedRefreshToken,
        (kcToken["access_token"] as? String) == expectedAccessToken else {
            throw ProviderAdapterError.operationFailed("Keychain 回读校验失败")
        }

        if let idToken = nonEmpty(kcObj["id_token"] as? String) {
            guard let claims = Formatters.decodeJWTPayload(idToken),
                  (claims["sub"] as? String) == expectedSub else {
                throw ProviderAdapterError.operationFailed("Keychain id_token sub 回读不一致")
            }
        }

        // Verify mirror file readback.
        let mirrorData = try Data(contentsOf: paths.mirrorTokenURL)
        guard let mirrorObj = (try? JSONSerialization.jsonObject(with: mirrorData, options: [])) as? [String: Any],
              let mirrorToken = mirrorObj["token"] as? [String: Any],
              (mirrorToken["refresh_token"] as? String) == expectedRefreshToken,
              (mirrorToken["access_token"] as? String) == expectedAccessToken else {
            throw ProviderAdapterError.operationFailed("镜像文件 jetski-standalone-oauth-token 回读校验失败")
        }

        if let idToken = nonEmpty(mirrorObj["id_token"] as? String) {
            guard let claims = Formatters.decodeJWTPayload(idToken),
                  (claims["sub"] as? String) == expectedSub else {
                throw ProviderAdapterError.operationFailed("镜像文件 id_token sub 回读不一致")
            }
        }
    }

    private func rollbackLiveCredentials(previousKeychainRaw: String?, previousMirrorData: Data?) {
        if let prevKC = previousKeychainRaw {
            try? keychain.writeExternalGenericPassword(
                service: Self.liveKeychainService,
                account: Self.liveKeychainAccount,
                value: prevKC
            )
        } else {
            try? keychain.deleteExternalGenericPassword(
                service: Self.liveKeychainService,
                account: Self.liveKeychainAccount
            )
        }

        if let prevMirror = previousMirrorData {
            try? KeychainStore.writeAtomicFile(data: prevMirror, to: paths.mirrorTokenURL, mode: 0o600)
        } else {
            try? FileManager.default.removeItem(at: paths.mirrorTokenURL)
        }
    }

    // MARK: - Safe Client Control

    public func controlClient(restart: Bool, allowForceQuit: Bool) async -> SwitchResult {
        if !allowForceQuit {
            let status = await detectClientStatus()
            let interactiveCLI = status.runningProcesses.filter { $0.isInteractiveCLI }
            if !interactiveCLI.isEmpty {
                return .needsForceQuitConfirmation(surviving: interactiveCLI)
            }
        }

        let stopResult = await processController.gracefulStop(
            bundleIDs: Self.bundleIDs,
            detachedExecutableMatchers: detachedExecutableMatchers(),
            timeoutSeconds: 12.0,
            allowForceQuit: allowForceQuit
        )

        switch stopResult {
        case .stillRunning(let surviving):
            return .needsForceQuitConfirmation(surviving: surviving)
        case .stopped(let previouslyRunning):
            guard restart else {
                return .switched(reopenedApps: [])
            }
            var toOpen = previouslyRunning
            if toOpen.isEmpty {
                let installed = processController.inspector.installedAppURLs(
                    bundleIDs: Self.bundleIDs,
                    extraPaths: [paths.stableAppURL.path, paths.insidersAppURL.path]
                )
                if let first = installed.first {
                    toOpen = [first]
                }
            }
            await processController.reopenApps(urls: toOpen)
            return .switched(reopenedApps: toOpen.map { $0.deletingPathExtension().lastPathComponent })
        }
    }

    // MARK: - Credential Deletion

    public func deleteAccountCredentials(accountId: String) throws {
        try keychain.deleteSecret(service: isolatedStoreNamespace, account: accountId)
    }

    // MARK: - Utilities

    private func nonEmpty(_ value: String?) -> String? {
        Self.nonEmptyStatic(value)
    }

    private static func nonEmptyStatic(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status == errSecSuccess {
            return Formatters.base64URLEncode(Data(bytes))
        }
        return Formatters.base64URLEncode(Data((UUID().uuidString + UUID().uuidString).utf8))
    }

    private func formURLEncoded(_ pairs: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return pairs.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
    }
}

// MARK: - Localhost-Only Self-Signed Certificate Delegate (Strictly 127.0.0.1 Only)

private final class LocalhostSelfSignedDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host.lowercased()
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           host == "127.0.0.1",
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - POSIX Loopback OAuth Callback Server (`127.0.0.1:0`, Zero Extra Frameworks)

private final class LoopbackOAuthServer: @unchecked Sendable {
    struct CallbackResult: Sendable {
        let code: String
    }

    let port: UInt16
    private let lock = NSLock()
    private var listenFD: Int32

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ProviderAdapterError.operationFailed("无法创建本地 OAuth 回调监听 Socket (errno=\(errno))")
        }

        var reuse: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // Ephemeral port
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            _ = Darwin.close(fd)
            throw ProviderAdapterError.operationFailed("绑定 127.0.0.1 回调端口失败 (errno=\(errno))")
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.getsockname(fd, sockPtr, &addrLen)
            }
        }
        guard nameResult == 0, Darwin.listen(fd, 4) == 0 else {
            _ = Darwin.close(fd)
            throw ProviderAdapterError.operationFailed("启动本地 OAuth 监听失败 (errno=\(errno))")
        }

        self.port = UInt16(bigEndian: boundAddr.sin_port)
        self.listenFD = fd
    }

    deinit {
        close()
    }

    func close() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            _ = Darwin.close(fd)
        }
    }

    func waitForCallback(expectedState: String, timeoutSeconds: TimeInterval) async throws -> CallbackResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: ProviderAdapterError.operationFailed("OAuth 回调监听已释放"))
                    return
                }
                let deadline = Date().addingTimeInterval(timeoutSeconds)

                while Date() < deadline {
                    self.lock.lock()
                    let fd = self.listenFD
                    self.lock.unlock()
                    if fd < 0 {
                        continuation.resume(throwing: ProviderAdapterError.operationFailed("OAuth 登录已取消"))
                        return
                    }

                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let ready = Darwin.poll(&pfd, 1, 200)
                    if ready < 0 {
                        if errno == EINTR { continue }
                        continuation.resume(throwing: ProviderAdapterError.operationFailed("等待 OAuth 回调出错 (errno=\(errno))"))
                        return
                    }
                    if ready == 0 {
                        continue
                    }

                    var clientAddr = sockaddr_in()
                    var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            Darwin.accept(fd, sockPtr, &clientLen)
                        }
                    }
                    if clientFD < 0 { continue }

                    let outcome = Self.handleConnection(clientFD: clientFD, expectedState: expectedState)
                    _ = Darwin.close(clientFD)

                    switch outcome {
                    case .ignore:
                        continue
                    case .success(let code):
                        self.close()
                        continuation.resume(returning: CallbackResult(code: code))
                        return
                    case .failure(let err):
                        self.close()
                        continuation.resume(throwing: err)
                        return
                    }
                }

                self.close()
                continuation.resume(throwing: ProviderAdapterError.operationFailed("等待 Google 浏览器登录回调超时（3 分钟）"))
            }
        }
    }

    private enum ConnectionOutcome {
        case ignore
        case success(String)
        case failure(ProviderAdapterError)
    }

    private static func handleConnection(clientFD: Int32, expectedState: String) -> ConnectionOutcome {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        _ = Darwin.setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 8192)
        let n = Darwin.recv(clientFD, &buffer, buffer.count, 0)
        guard n > 0, let requestText = String(bytes: buffer[0..<n], encoding: .utf8) else {
            return .ignore
        }

        guard let firstLine = requestText.split(separator: "\r\n", maxSplits: 1).first else {
            return .ignore
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return .ignore }
        let target = String(parts[1])

        guard let comps = URLComponents(string: "http://127.0.0.1\(target)") else {
            return .ignore
        }

        if comps.path != "/oauth-callback" {
            sendHTTPResponse(clientFD: clientFD, status: "404 Not Found", html: "<html><body>Not Found</body></html>")
            return .ignore
        }

        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let oauthErr = items["error"], !oauthErr.isEmpty {
            sendHTTPResponse(
                clientFD: clientFD,
                status: "400 Bad Request",
                html: "<html><meta charset=\"utf-8\"><body><h3>授权未完成</h3><p>您可以关闭此标签页并返回 Pulsar。</p></body></html>"
            )
            return .failure(.authenticationRequired("Google 授权被取消或拒绝 (\(oauthErr))"))
        }

        guard items["state"] == expectedState else {
            sendHTTPResponse(
                clientFD: clientFD,
                status: "400 Bad Request",
                html: "<html><meta charset=\"utf-8\"><body><h3>安全校验失败</h3><p>state 不匹配，请重试。</p></body></html>"
            )
            return .failure(.authenticationRequired("OAuth state 校验失败"))
        }

        guard let code = items["code"], !code.isEmpty else {
            sendHTTPResponse(
                clientFD: clientFD,
                status: "400 Bad Request",
                html: "<html><meta charset=\"utf-8\"><body><h3>缺少授权码</h3></body></html>"
            )
            return .failure(.invalidCredential("OAuth 回调缺少 code"))
        }

        sendHTTPResponse(
            clientFD: clientFD,
            status: "200 OK",
            html: """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8"><title>Pulsar</title>
            <style>body{font-family:-apple-system,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#f5f5f7;color:#1d1d1f;}
            .card{background:#fff;padding:28px 36px;border-radius:14px;box-shadow:0 4px 20px rgba(0,0,0,.08);text-align:center;}</style>
            </head><body><div class="card"><h2>登录成功</h2><p>账号已安全保存至 Pulsar，可关闭此页面。</p></div></body></html>
            """
        )
        return .success(code)
    }

    private static func sendHTTPResponse(clientFD: Int32, status: String, html: String) {
        let body = Data(html.utf8)
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var full = Data(headers.utf8)
        full.append(body)
        full.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(clientFD, base.advanced(by: sent), raw.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
