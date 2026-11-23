import Darwin
import Foundation

// MARK: - Grok Quota Provider

public final class GrokProvider: ProviderAdapter, @unchecked Sendable {
    public static let defaultAccountId = "grok:live"
    public static let primaryCreditsURL = URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!
    public static let fallbackBillingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    public static let defaultOIDCIssuer = "https://auth.x.ai"
    public static let oidcExpiryLeewaySeconds: TimeInterval = 60.0

    public let id: ProviderID = .grok
    public let capabilities: ProviderCapability = [.quota]
    public let transportPolicy: TransportPolicy = .systemProxy
    public let isolatedStoreNamespace: String = "com.rory.roryorbit.grok"

    public let keychain: KeychainStore
    public let authFileURL: URL
    private let session: URLSession
    private let primaryURL: URL
    private let fallbackURL: URL

    public init(
        keychain: KeychainStore = .shared,
        authFileURL: URL? = nil,
        session: URLSession? = nil,
        primaryURL: URL = GrokProvider.primaryCreditsURL,
        fallbackURL: URL = GrokProvider.fallbackBillingURL
    ) {
        self.keychain = keychain
        self.authFileURL = authFileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
        self.session = session ?? HTTPFactory.makeSession(policy: .systemProxy, timeout: 20.0)
        self.primaryURL = primaryURL
        self.fallbackURL = fallbackURL
    }

    // MARK: - Auth File Model

    public struct AuthEntry: Equatable, Sendable {
        public let entryKey: String
        public let accessToken: String
        public let email: String
        public let displayName: String
        public let authMode: String?
        public let codingDataTeam: String?
        public let expiresAt: Date?
        public let refreshToken: String?
        public let oidcIssuer: String?
        public let oidcClientId: String?
        public let isFlatRoot: Bool

        public init(
            entryKey: String,
            accessToken: String,
            email: String,
            displayName: String,
            authMode: String?,
            codingDataTeam: String?,
            expiresAt: Date?,
            refreshToken: String? = nil,
            oidcIssuer: String? = nil,
            oidcClientId: String? = nil,
            isFlatRoot: Bool = false
        ) {
            self.entryKey = entryKey
            self.accessToken = accessToken
            self.email = email
            self.displayName = displayName
            self.authMode = authMode
            self.codingDataTeam = codingDataTeam
            self.expiresAt = expiresAt
            self.refreshToken = refreshToken
            self.oidcIssuer = oidcIssuer
            self.oidcClientId = oidcClientId
            self.isFlatRoot = isFlatRoot
        }

        public var resolvedPlan: PlanInfo {
            if let team = codingDataTeam?.trimmingCharacters(in: .whitespacesAndNewlines),
               !team.isEmpty,
               team.lowercased() != "personal" {
                return PlanInfo(kind: .team, displayName: "SuperGrok · \(team)")
            }
            return PlanInfo(kind: .pro, displayName: "SuperGrok")
        }

        public var resolvedTokenEndpointURL: URL? {
            let rawIssuer = oidcIssuer?.trimmingCharacters(in: .whitespacesAndNewlines)
            let issuerBase = (rawIssuer?.isEmpty == false ? rawIssuer! : GrokProvider.defaultOIDCIssuer)
            var trimmed = issuerBase
            while trimmed.hasSuffix("/") {
                trimmed.removeLast()
            }
            guard let url = URL(string: "\(trimmed)/oauth2/token"),
                  url.scheme?.lowercased() == "https",
                  let host = url.host,
                  !host.isEmpty else {
                return nil
            }
            return url
        }

        public var canRefreshOIDC: Bool {
            guard authMode?.lowercased() == "oidc",
                  let rt = refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines), !rt.isEmpty,
                  let cid = oidcClientId?.trimmingCharacters(in: .whitespacesAndNewlines), !cid.isEmpty else {
                return false
            }
            return resolvedTokenEndpointURL != nil
        }

        public func needsProactiveRefresh(
            now: Date = Date(),
            leeway: TimeInterval = GrokProvider.oidcExpiryLeewaySeconds
        ) -> Bool {
            let cutoff = now.addingTimeInterval(leeway)
            if let exp = expiresAt, exp <= cutoff {
                return true
            }
            if let jwtExp = GrokProvider.jwtExpirationDate(from: accessToken), jwtExp <= cutoff {
                return true
            }
            return false
        }
    }

    public struct ParsedGrokBilling: Equatable, Sendable {
        public let usedPercent: Double
        public let remainingFraction: Double
        public let resetAt: Date?
        public let plan: PlanInfo?
        public let detail: String?

        public init(
            usedPercent: Double,
            remainingFraction: Double,
            resetAt: Date? = nil,
            plan: PlanInfo? = nil,
            detail: String? = nil
        ) {
            self.usedPercent = min(max(usedPercent, 0.0), 100.0)
            self.remainingFraction = min(max(remainingFraction, 0.0), 1.0)
            self.resetAt = resetAt
            self.plan = plan
            self.detail = detail
        }
    }

    // MARK: - ProviderAdapter

    public func detectClientStatus() async -> ClientRuntimeStatus {
        let grokCLIPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/bin/grok").path
        var status = ProcessController.shared.detectClientStatus(
            bundleIDs: ["com.anysphere.sand"],
            extraAppPaths: ["/Applications/Grok Bot.app"],
            detachedExecutableMatchers: {
                [
                    { path in
                        let lower = path.lowercased()
                        return path == grokCLIPath
                            || lower.hasSuffix("/.grok/bin/grok")
                            || lower.hasSuffix("/grok")
                    }
                ]
            }()
        )
        if FileManager.default.fileExists(atPath: grokCLIPath),
           !status.installedApps.contains("Grok CLI") {
            status.installedApps.append("Grok CLI")
        }
        return status
    }

    public func syncLiveAccount(registry: inout RegistryData) async -> String? {
        let existing = registry.accounts(for: .grok).first { $0.id == Self.defaultAccountId }
            ?? registry.accounts(for: .grok).first
        let accountId = existing?.id ?? Self.defaultAccountId

        if let entry = try? readAuthEntry() {
            let record = AccountRecord(
                id: accountId,
                provider: .grok,
                email: entry.email,
                displayName: entry.displayName,
                plan: entry.resolvedPlan,
                addedAt: existing?.addedAt ?? Date(),
                isActiveLive: true
            )
            registry.upsertAccount(record)
            registry.setActiveLive(accountId: accountId, for: .grok)
            return accountId
        }

        let fallbackRecord = AccountRecord(
            id: accountId,
            provider: .grok,
            email: existing?.email ?? "",
            displayName: existing?.displayName ?? "Grok CLI",
            plan: existing?.plan ?? PlanInfo(kind: .pro, displayName: "SuperGrok"),
            addedAt: existing?.addedAt ?? Date(),
            isActiveLive: true
        )
        registry.upsertAccount(fallbackRecord)
        registry.setActiveLive(accountId: accountId, for: .grok)
        return accountId
    }

    public func fetchQuota(for account: AccountRecord, isActiveLive: Bool) async -> QuotaSnapshot {
        _ = isActiveLive
        var entry: AuthEntry
        do {
            guard let loaded = try readAuthEntry() else {
                return QuotaSnapshot.unconfigured(
                    provider: .grok,
                    accountId: account.id,
                    sourceLabel: "Grok CLI",
                    message: "未检测到 ~/.grok/auth.json，请先运行 grok login"
                )
            }
            entry = loaded
        } catch {
            return QuotaSnapshot.failed(
                provider: .grok,
                accountId: account.id,
                sourceLabel: "Grok CLI",
                message: "读取 ~/.grok/auth.json 失败"
            )
        }

        var didAttemptOIDCRefresh = false

        // 1. Proactive OIDC refresh when access token is expired or expiring within 60 seconds.
        if entry.canRefreshOIDC && entry.needsProactiveRefresh() {
            didAttemptOIDCRefresh = true
            switch await refreshOIDCEntry(currentEntry: entry, forceRefresh: false) {
            case .refreshed(let updated):
                entry = updated
            case .reauthRequired:
                return QuotaSnapshot(
                    provider: .grok,
                    accountId: account.id,
                    plan: entry.resolvedPlan,
                    status: .reauthRequired("请重新登录 Grok CLI"),
                    sourceLabel: "Grok CLI",
                    paceNote: expiryHint(for: entry)
                )
            case .failed, .notApplicable:
                break
            }
        }

        // 2. Fetch billing (with at most ONE reactive OIDC refresh + retry on 401 / grpc-status: 16).
        let firstAttempt = await fetchBillingWithFallback(
            accountId: account.id,
            entry: entry,
            allowReactiveOIDCDefer: entry.canRefreshOIDC && !didAttemptOIDCRefresh
        )
        switch firstAttempt {
        case .snapshot(let snap):
            return snap
        case .needsOIDCRefresh:
            didAttemptOIDCRefresh = true
            switch await refreshOIDCEntry(currentEntry: entry, forceRefresh: true) {
            case .refreshed(let updated):
                entry = updated
                let retryAttempt = await fetchBillingWithFallback(
                    accountId: account.id,
                    entry: entry,
                    allowReactiveOIDCDefer: false
                )
                if case .snapshot(let snap) = retryAttempt {
                    return snap
                }
                return QuotaSnapshot(
                    provider: .grok,
                    accountId: account.id,
                    plan: entry.resolvedPlan,
                    status: .reauthRequired("请重新登录 Grok CLI"),
                    sourceLabel: "Grok CLI",
                    paceNote: expiryHint(for: entry)
                )
            case .reauthRequired:
                return QuotaSnapshot(
                    provider: .grok,
                    accountId: account.id,
                    plan: entry.resolvedPlan,
                    status: .reauthRequired("请重新登录 Grok CLI"),
                    sourceLabel: "Grok CLI",
                    paceNote: expiryHint(for: entry)
                )
            case .failed, .notApplicable:
                // Refresh endpoint had a transient issue; still try fallback billing once before concluding.
                let fallbackResult = await fetchFallbackBilling(entry: entry)
                if case .success(let parsed) = fallbackResult {
                    return makeReadySnapshot(
                        accountId: account.id,
                        entry: entry,
                        parsed: parsed,
                        sourceLabel: sourceLabel(base: "Grok Billing API", team: entry.codingDataTeam)
                    )
                }
                return QuotaSnapshot(
                    provider: .grok,
                    accountId: account.id,
                    plan: entry.resolvedPlan,
                    status: .reauthRequired("请重新登录 Grok CLI"),
                    sourceLabel: "Grok CLI",
                    paceNote: expiryHint(for: entry)
                )
            }
        }
    }

    private enum BillingAttemptOutcome {
        case snapshot(QuotaSnapshot)
        case needsOIDCRefresh
    }

    private func fetchBillingWithFallback(
        accountId: String,
        entry: AuthEntry,
        allowReactiveOIDCDefer: Bool
    ) async -> BillingAttemptOutcome {
        let primaryResult = await fetchPrimaryGRPCWeb(entry: entry)
        switch primaryResult {
        case .success(let parsed):
            return .snapshot(
                makeReadySnapshot(
                    accountId: accountId,
                    entry: entry,
                    parsed: parsed,
                    sourceLabel: sourceLabel(base: "Grok gRPC-web", team: entry.codingDataTeam)
                )
            )

        case .authRequired:
            if allowReactiveOIDCDefer {
                return .needsOIDCRefresh
            }
            // Try fallback before concluding re-auth is required, in case only the web gateway rejected the token.
            let fallbackResult = await fetchFallbackBilling(entry: entry)
            switch fallbackResult {
            case .success(let parsed):
                return .snapshot(
                    makeReadySnapshot(
                        accountId: accountId,
                        entry: entry,
                        parsed: parsed,
                        sourceLabel: sourceLabel(base: "Grok Billing API", team: entry.codingDataTeam)
                    )
                )
            case .authRequired, .failed:
                return .snapshot(
                    QuotaSnapshot(
                        provider: .grok,
                        accountId: accountId,
                        plan: entry.resolvedPlan,
                        status: .reauthRequired("请重新登录 Grok CLI"),
                        sourceLabel: "Grok CLI",
                        paceNote: expiryHint(for: entry)
                    )
                )
            }

        case .failed(let primaryErr):
            let fallbackResult = await fetchFallbackBilling(entry: entry)
            switch fallbackResult {
            case .success(let parsed):
                return .snapshot(
                    makeReadySnapshot(
                        accountId: accountId,
                        entry: entry,
                        parsed: parsed,
                        sourceLabel: sourceLabel(base: "Grok Billing API", team: entry.codingDataTeam)
                    )
                )
            case .authRequired:
                if allowReactiveOIDCDefer {
                    return .needsOIDCRefresh
                }
                return .snapshot(
                    QuotaSnapshot(
                        provider: .grok,
                        accountId: accountId,
                        plan: entry.resolvedPlan,
                        status: .reauthRequired("请重新登录 Grok CLI"),
                        sourceLabel: "Grok CLI",
                        paceNote: expiryHint(for: entry)
                    )
                )
            case .failed(let fallbackErr):
                let expiredHint = expiryHint(for: entry)
                if expiredHint != nil {
                    return .snapshot(
                        QuotaSnapshot(
                            provider: .grok,
                            accountId: accountId,
                            plan: entry.resolvedPlan,
                            status: .reauthRequired("请重新登录 Grok CLI"),
                            sourceLabel: "Grok CLI",
                            paceNote: expiredHint
                        )
                    )
                }
                return .snapshot(
                    QuotaSnapshot(
                        provider: .grok,
                        accountId: accountId,
                        plan: entry.resolvedPlan,
                        status: .failed(primaryErr.isEmpty ? fallbackErr : primaryErr),
                        sourceLabel: "Grok CLI"
                    )
                )
            }
        }
    }

    // MARK: - Auth Loader & OIDC Refresh with Advisory Flock

    public func readAuthEntry() throws -> AuthEntry? {
        guard FileManager.default.fileExists(atPath: authFileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: authFileURL)
        return try Self.parseAuthJSON(data)
    }

    public static func parseAuthJSON(_ data: Data) throws -> AuthEntry? {
        guard let root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw ProviderAdapterError.invalidCredential("Grok auth.json 格式无效")
        }

        // Defensive support if a flat object with "key" is ever provided.
        if let directKey = nonEmptyString(root["key"]) {
            return makeAuthEntry(entryKey: "default", dict: root, accessToken: directKey, isFlatRoot: true)
        }

        var candidates: [(entry: AuthEntry, priority: Int)] = []
        for (rawKey, rawValue) in root {
            guard let dict = rawValue as? [String: Any],
                  let token = nonEmptyString(dict["key"]) else {
                continue
            }
            let entry = makeAuthEntry(entryKey: rawKey, dict: dict, accessToken: token, isFlatRoot: false)
            var priority = 0
            if rawKey.hasPrefix("https://auth.x.ai::") {
                priority += 100
            } else if rawKey.contains("auth.x.ai") {
                priority += 50
            }
            if entry.authMode?.lowercased() == "oidc" {
                priority += 20
            }
            if let exp = entry.expiresAt, exp > Date() {
                priority += 10
            }
            candidates.append((entry, priority))
        }

        candidates.sort { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }
            let lExp = lhs.entry.expiresAt ?? .distantPast
            let rExp = rhs.entry.expiresAt ?? .distantPast
            if lExp != rExp {
                return lExp > rExp
            }
            return lhs.entry.entryKey < rhs.entry.entryKey
        }

        return candidates.first?.entry
    }

    private static func makeAuthEntry(
        entryKey: String,
        dict: [String: Any],
        accessToken: String,
        isFlatRoot: Bool
    ) -> AuthEntry {
        let email = nonEmptyString(dict["email"]) ?? ""
        let firstName = nonEmptyString(dict["first_name"]) ?? ""
        let lastName = nonEmptyString(dict["last_name"]) ?? ""
        let combinedName = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        let displayName = !combinedName.isEmpty ? combinedName : (!email.isEmpty ? email : "Grok")
        let authMode = nonEmptyString(dict["auth_mode"])
        let team = nonEmptyString(dict["coding_data_team"])
        let refreshToken = nonEmptyString(dict["refresh_token"])

        var oidcIssuer = nonEmptyString(dict["oidc_issuer"])
        var oidcClientId = nonEmptyString(dict["oidc_client_id"])
        if let sep = entryKey.range(of: "::") {
            let keyIssuer = String(entryKey[..<sep.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let keyClient = String(entryKey[sep.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if oidcIssuer == nil && !keyIssuer.isEmpty {
                oidcIssuer = keyIssuer
            }
            if oidcClientId == nil && !keyClient.isEmpty {
                oidcClientId = keyClient
            }
        }

        let expiresAt: Date?
        if let expStr = nonEmptyString(dict["expires_at"]) {
            expiresAt = Formatters.parseRFC3339(expStr)
        } else if let expNum = parseDouble(dict["expires_at"]) {
            expiresAt = expNum > 1_000_000_000_000
                ? Date(timeIntervalSince1970: expNum / 1000.0)
                : Date(timeIntervalSince1970: expNum)
        } else {
            expiresAt = nil
        }

        return AuthEntry(
            entryKey: entryKey,
            accessToken: accessToken,
            email: email,
            displayName: displayName,
            authMode: authMode,
            codingDataTeam: team,
            expiresAt: expiresAt,
            refreshToken: refreshToken,
            oidcIssuer: oidcIssuer,
            oidcClientId: oidcClientId,
            isFlatRoot: isFlatRoot
        )
    }

    public static func jwtExpirationDate(from token: String) -> Date? {
        guard let payload = Formatters.decodeJWTPayload(token),
              let exp = parseDouble(payload["exp"]),
              exp > 1_000_000_000 else {
            return nil
        }
        return exp > 1_000_000_000_000
            ? Date(timeIntervalSince1970: exp / 1000.0)
            : Date(timeIntervalSince1970: exp)
    }

    private enum OIDCRefreshOutcome {
        case refreshed(AuthEntry)
        case reauthRequired
        case failed(String)
        case notApplicable
    }

    private func refreshOIDCEntry(
        currentEntry: AuthEntry,
        forceRefresh: Bool,
        now: Date = Date()
    ) async -> OIDCRefreshOutcome {
        let lockURL = URL(fileURLWithPath: authFileURL.path + ".lock")
        return await withAdvisoryFileLock(lockURL: lockURL, timeoutSeconds: 15.0) {
            // Re-read auth.json inside flock in case Grok CLI (or another process) already refreshed it.
            let diskEntry = try? readAuthEntry()
            if let latest = diskEntry {
                if !forceRefresh && !latest.needsProactiveRefresh(now: now) {
                    return .refreshed(latest)
                }
                if forceRefresh
                    && latest.accessToken != currentEntry.accessToken
                    && !latest.needsProactiveRefresh(now: now) {
                    return .refreshed(latest)
                }
            }

            let target = diskEntry ?? currentEntry
            guard target.canRefreshOIDC,
                  let tokenURL = target.resolvedTokenEndpointURL,
                  let clientId = target.oidcClientId,
                  let refreshToken = target.refreshToken else {
                return .notApplicable
            }

            let bodyString = [
                "grant_type=refresh_token",
                "client_id=\(Self.formURLEncode(clientId))",
                "refresh_token=\(Self.formURLEncode(refreshToken))",
            ].joined(separator: "&")

            var req = URLRequest(url: tokenURL)
            req.httpMethod = "POST"
            req.httpBody = Data(bodyString.utf8)
            req.httpShouldHandleCookies = false
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("RoryOrbit/1.0", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    return .failed("Grok OIDC 续期无有效响应")
                }
                if http.statusCode == 400 || http.statusCode == 401 {
                    return .reauthRequired
                }
                guard (200...299).contains(http.statusCode) else {
                    return .failed("Grok OIDC 续期返回 HTTP \(http.statusCode)")
                }
                guard let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
                      let newAccessToken = Self.nonEmptyString(json["access_token"]) else {
                    return .failed("Grok OIDC 续期响应格式无效")
                }

                let newExpiresAt: Date?
                if let expiresIn = Self.parseDouble(json["expires_in"]), expiresIn > 0 {
                    newExpiresAt = Date().addingTimeInterval(expiresIn)
                } else {
                    newExpiresAt = Self.jwtExpirationDate(from: newAccessToken)
                }
                let rotatedRefreshToken = Self.nonEmptyString(json["refresh_token"]) ?? target.refreshToken

                // Atomically persist updated auth.json (0600) while preserving all existing fields.
                persistRefreshedAuthEntry(
                    target: target,
                    newAccessToken: newAccessToken,
                    newExpiresAt: newExpiresAt,
                    newRefreshToken: rotatedRefreshToken
                )

                let updatedEntry = AuthEntry(
                    entryKey: target.entryKey,
                    accessToken: newAccessToken,
                    email: target.email,
                    displayName: target.displayName,
                    authMode: target.authMode,
                    codingDataTeam: target.codingDataTeam,
                    expiresAt: newExpiresAt ?? target.expiresAt,
                    refreshToken: rotatedRefreshToken,
                    oidcIssuer: target.oidcIssuer,
                    oidcClientId: target.oidcClientId,
                    isFlatRoot: target.isFlatRoot
                )
                return .refreshed(updatedEntry)
            } catch {
                return .failed("Grok OIDC 续期网络失败: \(Self.sanitizedNetworkError(error))")
            }
        }
    }

    private func persistRefreshedAuthEntry(
        target: AuthEntry,
        newAccessToken: String,
        newExpiresAt: Date?,
        newRefreshToken: String?
    ) {
        guard let existingData = try? Data(contentsOf: authFileURL),
              var root = (try? JSONSerialization.jsonObject(with: existingData, options: [])) as? [String: Any] else {
            return
        }

        if target.isFlatRoot {
            root["key"] = newAccessToken
            if let newExpiresAt {
                root["expires_at"] = Formatters.formatRFC3339UTC(newExpiresAt)
            }
            if let newRefreshToken, !newRefreshToken.isEmpty {
                root["refresh_token"] = newRefreshToken
            }
        } else if var entryDict = root[target.entryKey] as? [String: Any] {
            entryDict["key"] = newAccessToken
            if let newExpiresAt {
                entryDict["expires_at"] = Formatters.formatRFC3339UTC(newExpiresAt)
            }
            if let newRefreshToken, !newRefreshToken.isEmpty {
                entryDict["refresh_token"] = newRefreshToken
            }
            root[target.entryKey] = entryDict
        } else {
            return
        }

        guard var encoded = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            return
        }
        encoded.append(0x0A)
        try? KeychainStore.writeAtomicFile(data: encoded, to: authFileURL, mode: 0o600)
    }

    private func withAdvisoryFileLock<T>(
        lockURL: URL,
        timeoutSeconds: TimeInterval,
        operation: () async -> T
    ) async -> T {
        let dir = lockURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? KeychainStore.ensureDirectory(at: dir, mode: 0o700)
        }

        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            return await operation()
        }
        _ = Darwin.fchmod(fd, S_IRUSR | S_IWUSR)

        var acquired = false
        let deadline = Date().addingTimeInterval(max(1.0, timeoutSeconds))
        while Date() < deadline {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                acquired = true
                break
            }
            if errno != EWOULDBLOCK && errno != EINTR {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        defer {
            if acquired {
                _ = flock(fd, LOCK_UN)
            }
            _ = Darwin.close(fd)
        }
        return await operation()
    }

    private static func formURLEncode(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    // MARK: - Network Fetchers

    private enum FetchOutcome {
        case success(ParsedGrokBilling)
        case authRequired
        case failed(String)
    }

    private func fetchPrimaryGRPCWeb(entry: AuthEntry) async -> FetchOutcome {
        var req = URLRequest(url: primaryURL)
        req.httpMethod = "POST"
        req.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])
        req.httpShouldHandleCookies = false
        req.setValue("Bearer \(entry.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        req.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "x-grpc-web")
        req.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        req.setValue("RoryOrbit/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Grok 服务无有效响应")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .authRequired
            }
            guard (200...299).contains(http.statusCode) else {
                return .failed("Grok 额度接口返回 HTTP \(http.statusCode)")
            }

            if let headerStatus = http.value(forHTTPHeaderField: "grpc-status")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !headerStatus.isEmpty,
               headerStatus != "0" {
                if headerStatus == "16" || headerStatus == "7" {
                    return .authRequired
                }
                return .failed("Grok gRPC 状态异常 (\(headerStatus))")
            }

            switch Self.parseGRPCWebResponse(data) {
            case .success(let parsed):
                return .success(parsed)
            case .authRequired:
                return .authRequired
            case .failed(let msg):
                return .failed(msg)
            }
        } catch {
            return .failed("Grok 网络请求失败: \(Self.sanitizedNetworkError(error))")
        }
    }

    private func fetchFallbackBilling(entry: AuthEntry) async -> FetchOutcome {
        var req = URLRequest(url: fallbackURL)
        req.httpMethod = "GET"
        req.httpShouldHandleCookies = false
        req.setValue(entry.accessToken, forHTTPHeaderField: "x-xai-token-auth")
        req.setValue("Bearer \(entry.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("RoryOrbit/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Grok 备用接口无有效响应")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .authRequired
            }
            guard (200...299).contains(http.statusCode) else {
                return .failed("Grok 备用额度接口返回 HTTP \(http.statusCode)")
            }
            if let parsed = Self.parseFallbackBillingJSON(data) {
                return .success(parsed)
            }
            return .failed("无法解析 Grok 备用额度响应")
        } catch {
            return .failed("Grok 备用网络请求失败: \(Self.sanitizedNetworkError(error))")
        }
    }

    // MARK: - gRPC-Web & Protobuf Decoding

    public enum GRPCWebParseResult: Equatable, Sendable {
        case success(ParsedGrokBilling)
        case authRequired
        case failed(String)
    }

    public static func parseGRPCWebResponse(_ data: Data, now: Date = Date()) -> GRPCWebParseResult {
        guard !data.isEmpty else {
            return .failed("Grok 额度响应为空")
        }

        let bytes = [UInt8](data)
        var payloads: [Data] = []
        var sawValidGRPCFrame = false
        var i = 0

        while i + 5 <= bytes.count {
            let flags = bytes[i]
            let length = (Int(bytes[i + 1]) << 24)
                | (Int(bytes[i + 2]) << 16)
                | (Int(bytes[i + 3]) << 8)
                | Int(bytes[i + 4])
            let start = i + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { break }

            sawValidGRPCFrame = true
            let frameSlice = Data(bytes[start..<end])
            if (flags & 0x80) == 0 {
                payloads.append(frameSlice)
            } else if let trailerText = String(data: frameSlice, encoding: .utf8) {
                for line in trailerText.split(whereSeparator: \.isNewline) {
                    let lower = line.lowercased()
                    if lower.hasPrefix("grpc-status:") {
                        let code = line.split(separator: ":", maxSplits: 1).last?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
                        if code == "16" || code == "7" {
                            return .authRequired
                        }
                        if code != "0" {
                            return .failed("Grok gRPC 状态异常 (\(code))")
                        }
                    }
                }
            }
            i = end
        }

        if payloads.isEmpty && !sawValidGRPCFrame {
            payloads = [data]
        }
        guard !payloads.isEmpty else {
            return .failed("Grok gRPC 响应不含有效数据帧")
        }

        var f32s: [(path: [UInt64], value: Float, order: Int)] = []
        var f64s: [(path: [UInt64], value: Double, order: Int)] = []
        var timestamps: [(path: [UInt64], value: UInt64)] = []
        var order = 0

        for payload in payloads {
            _ = scanProto(
                payload,
                path: [],
                depth: 0,
                requireExactEnd: false,
                order: &order,
                f32s: &f32s,
                f64s: &f64s,
                timestamps: &timestamps
            )
        }

        let nowSec = UInt64(max(0, now.timeIntervalSince1970))
        let futureTimestamps = timestamps
            .filter { $0.value > nowSec && $0.value < 2_100_000_000 }
            .sorted { $0.value < $1.value }

        // Prefer path [1, 5, 1] (proven billing period end path), else earliest future timestamp.
        let resetDate: Date? = futureTimestamps
            .first(where: { $0.path == [1, 5, 1] })
            .map { Date(timeIntervalSince1970: TimeInterval($0.value)) }
            ?? futureTimestamps.first.map { Date(timeIntervalSince1970: TimeInterval($0.value)) }

        // Prefer fixed32 float whose last field tag is 1, shallowest path first (matching proven decoding).
        let pctCandidates = f32s
            .filter { $0.path.last == 1 && $0.value.isFinite && $0.value >= 0 && $0.value <= 100 }
            .sorted { a, b in
                if a.path.count != b.path.count { return a.path.count < b.path.count }
                return a.order < b.order
            }

        let anyPct = f32s.filter { $0.value.isFinite && $0.value >= 0 && $0.value <= 100 }

        let usedPercent: Double
        if let best = pctCandidates.first {
            usedPercent = Double(best.value)
        } else if let nonZero = anyPct.first(where: { $0.value > 0 }) {
            usedPercent = Double(nonZero.value)
        } else if let zero = anyPct.first {
            usedPercent = Double(zero.value)
        } else if let best64 = f64s
            .filter({ $0.path.last == 1 && $0.value.isFinite && $0.value >= 0 && $0.value <= 100 })
            .sorted(by: { $0.path.count != $1.path.count ? $0.path.count < $1.path.count : $0.order < $1.order })
            .first {
            usedPercent = best64.value
        } else if resetDate != nil {
            // Proto3 omits default 0.0 float values; a valid response with a future period reset means 0% used.
            usedPercent = 0.0
        } else {
            return .failed("无法解析 Grok 额度百分比")
        }

        let clampedUsed = min(max(usedPercent, 0.0), 100.0)
        let remaining = min(max((100.0 - clampedUsed) / 100.0, 0.0), 1.0)
        return .success(
            ParsedGrokBilling(
                usedPercent: clampedUsed,
                remainingFraction: remaining,
                resetAt: resetDate,
                plan: nil,
                detail: String(format: "已用 %.1f%%", clampedUsed)
            )
        )
    }

    @discardableResult
    private static func scanProto(
        _ data: Data,
        path: [UInt64],
        depth: Int,
        requireExactEnd: Bool,
        order: inout Int,
        f32s: inout [(path: [UInt64], value: Float, order: Int)],
        f64s: inout [(path: [UInt64], value: Double, order: Int)],
        timestamps: inout [(path: [UInt64], value: UInt64)]
    ) -> Bool {
        guard depth < 16 else { return false }
        let bytes = [UInt8](data)
        var i = 0
        var localF32s: [(path: [UInt64], value: Float, order: Int)] = []
        var localF64s: [(path: [UInt64], value: Double, order: Int)] = []
        var localTimestamps: [(path: [UInt64], value: UInt64)] = []
        var localOrder = order

        while i < bytes.count {
            guard let key = readVarint(bytes, &i) else {
                return !requireExactEnd
            }
            let field = key >> 3
            let wire = key & 0x07
            guard field >= 1 && field <= 536_870_911 else {
                return false
            }
            let fieldPath = path + [field]

            switch wire {
            case 0: // varint
                guard let value = readVarint(bytes, &i) else {
                    return false
                }
                if value >= 1_700_000_000 && value <= 2_100_000_000 {
                    localTimestamps.append((fieldPath, value))
                }
            case 1: // 64-bit
                guard i + 8 <= bytes.count else { return false }
                var bits: UInt64 = 0
                for shift in 0..<8 {
                    bits |= UInt64(bytes[i + shift]) << (shift * 8)
                }
                i += 8
                let d = Double(bitPattern: bits)
                if d.isFinite {
                    localF64s.append((fieldPath, d, localOrder))
                    localOrder += 1
                }
            case 2: // length-delimited
                guard let rawLen = readVarint(bytes, &i) else { return false }
                guard rawLen <= UInt64(bytes.count - i) else { return false }
                let len = Int(rawLen)
                let sub = Data(bytes[i..<(i + len)])
                i += len
                if !sub.isEmpty {
                    var subOrder = localOrder
                    var subF32s: [(path: [UInt64], value: Float, order: Int)] = []
                    var subF64s: [(path: [UInt64], value: Double, order: Int)] = []
                    var subTimestamps: [(path: [UInt64], value: UInt64)] = []
                    let validSub = scanProto(
                        sub,
                        path: fieldPath,
                        depth: depth + 1,
                        requireExactEnd: true,
                        order: &subOrder,
                        f32s: &subF32s,
                        f64s: &subF64s,
                        timestamps: &subTimestamps
                    )
                    if validSub {
                        localF32s.append(contentsOf: subF32s)
                        localF64s.append(contentsOf: subF64s)
                        localTimestamps.append(contentsOf: subTimestamps)
                        localOrder = subOrder
                    }
                }
            case 5: // 32-bit float
                guard i + 4 <= bytes.count else { return false }
                var bits: UInt32 = 0
                bits |= UInt32(bytes[i])
                bits |= UInt32(bytes[i + 1]) << 8
                bits |= UInt32(bytes[i + 2]) << 16
                bits |= UInt32(bytes[i + 3]) << 24
                i += 4
                let f = Float(bitPattern: bits)
                if f.isFinite {
                    localF32s.append((fieldPath, f, localOrder))
                    localOrder += 1
                }
            default:
                return false
            }
        }

        if requireExactEnd && i != bytes.count {
            return false
        }

        f32s.append(contentsOf: localF32s)
        f64s.append(contentsOf: localF64s)
        timestamps.append(contentsOf: localTimestamps)
        order = localOrder
        return true
    }

    private static func readVarint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return result
            }
            shift += 7
            if shift > 63 {
                return nil
            }
        }
        return nil
    }

    // MARK: - Fallback JSON Billing Parser

    public static func parseFallbackBillingJSON(_ data: Data) -> ParsedGrokBilling? {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }

        let containers: [[String: Any]] = [
            root,
            root["billing"] as? [String: Any],
            root["credits"] as? [String: Any],
            root["quota"] as? [String: Any],
            root["usage"] as? [String: Any],
            root["data"] as? [String: Any],
            root["subscription"] as? [String: Any],
        ].compactMap { $0 }

        var resetAt: Date?
        for dict in containers {
            for key in ["reset_at", "resetAt", "resets_at", "resetsAt", "period_end", "periodEnd", "next_reset_at", "cycle_end"] {
                if let parsed = parseDate(dict[key]) {
                    resetAt = parsed
                    break
                }
            }
            if resetAt != nil { break }
        }

        var plan: PlanInfo?
        for dict in containers {
            for key in ["plan_name", "planName", "plan", "tier", "subscription_tier"] {
                if let name = nonEmptyString(dict[key]) {
                    plan = PlanInfo.normalized(kindRaw: name, name: name)
                    break
                }
            }
            if plan != nil { break }
        }

        // 1. Direct remaining / used percentage fields
        for dict in containers {
            if let remPct = firstDouble(in: dict, keys: ["remaining_percent", "remainingPercent", "percent_remaining", "percentRemaining"]) {
                let normalizedRem = remPct > 1.0 ? remPct / 100.0 : remPct
                let clampedRem = min(max(normalizedRem, 0.0), 1.0)
                let used = (1.0 - clampedRem) * 100.0
                return ParsedGrokBilling(
                    usedPercent: used,
                    remainingFraction: clampedRem,
                    resetAt: resetAt,
                    plan: plan,
                    detail: String(format: "剩余 %.0f%%", clampedRem * 100.0)
                )
            }
            if let remFrac = firstDouble(in: dict, keys: ["remaining_fraction", "remainingFraction"]) {
                let clampedRem = min(max(remFrac > 1.0 ? remFrac / 100.0 : remFrac, 0.0), 1.0)
                return ParsedGrokBilling(
                    usedPercent: (1.0 - clampedRem) * 100.0,
                    remainingFraction: clampedRem,
                    resetAt: resetAt,
                    plan: plan,
                    detail: String(format: "剩余 %.0f%%", clampedRem * 100.0)
                )
            }
            if let usedPct = firstDouble(in: dict, keys: ["used_percent", "usedPercent", "percent_used", "percentUsed", "utilization"]) {
                let pct = (usedPct > 0.0 && usedPct <= 1.0 && dict["utilization"] != nil && usedPct < 1.0)
                    ? usedPct * 100.0
                    : usedPct
                let clampedUsed = min(max(pct, 0.0), 100.0)
                return ParsedGrokBilling(
                    usedPercent: clampedUsed,
                    remainingFraction: (100.0 - clampedUsed) / 100.0,
                    resetAt: resetAt,
                    plan: plan,
                    detail: String(format: "已用 %.1f%%", clampedUsed)
                )
            }
        }

        // 2. Numeric credits ratio (remaining / total or used / limit)
        for dict in containers {
            let limit = firstDouble(in: dict, keys: ["total_credits", "totalCredits", "credits_limit", "creditsLimit", "limit", "quota", "max_credits"])
            let remaining = firstDouble(in: dict, keys: ["remaining_credits", "remainingCredits", "credits_remaining", "creditsRemaining", "available_credits", "remaining", "available"])
            let used = firstDouble(in: dict, keys: ["used_credits", "usedCredits", "credits_used", "creditsUsed", "used", "spent"])

            if let limit, limit > 0 {
                let remFrac: Double
                let detail: String
                if let remaining {
                    remFrac = min(max(remaining / limit, 0.0), 1.0)
                    detail = "剩余 \(formatCreditNumber(remaining)) / \(formatCreditNumber(limit))"
                } else if let used {
                    remFrac = min(max(1.0 - (used / limit), 0.0), 1.0)
                    detail = "已用 \(formatCreditNumber(used)) / \(formatCreditNumber(limit))"
                } else {
                    continue
                }
                return ParsedGrokBilling(
                    usedPercent: (1.0 - remFrac) * 100.0,
                    remainingFraction: remFrac,
                    resetAt: resetAt,
                    plan: plan,
                    detail: detail
                )
            } else if let remaining, let used, (remaining + used) > 0 {
                let total = remaining + used
                let remFrac = min(max(remaining / total, 0.0), 1.0)
                return ParsedGrokBilling(
                    usedPercent: (1.0 - remFrac) * 100.0,
                    remainingFraction: remFrac,
                    resetAt: resetAt,
                    plan: plan,
                    detail: "剩余 \(formatCreditNumber(remaining)) / \(formatCreditNumber(total))"
                )
            }
        }

        return nil
    }

    // MARK: - Snapshot & Formatting Helpers

    private func makeReadySnapshot(
        accountId: String,
        entry: AuthEntry,
        parsed: ParsedGrokBilling,
        sourceLabel: String
    ) -> QuotaSnapshot {
        let window = QuotaWindow(
            id: "grok-credits",
            label: "7天额度",
            remainingFraction: parsed.remainingFraction,
            usedPercent: parsed.usedPercent,
            resetAt: parsed.resetAt,
            windowSeconds: 604_800,
            detail: parsed.detail,
            isPrimary: true
        )

        var paceParts: [String] = []
        if let team = entry.codingDataTeam, !team.isEmpty {
            paceParts.append("团队: \(team)")
        }
        if let resetAt = parsed.resetAt {
            let rel = Formatters.relativeResetString(to: resetAt)
            if !rel.isEmpty {
                paceParts.append(rel)
            }
        }

        return QuotaSnapshot(
            provider: .grok,
            accountId: accountId,
            plan: parsed.plan ?? entry.resolvedPlan,
            windows: [window],
            balance: nil,
            status: .ready(fetchedAt: Date(), stale: false),
            sourceLabel: sourceLabel,
            primaryRemainingPercent: window.remainingPercent,
            paceNote: paceParts.isEmpty ? nil : paceParts.joined(separator: " · ")
        )
    }

    private func sourceLabel(base: String, team: String?) -> String {
        if let team = team?.trimmingCharacters(in: .whitespacesAndNewlines), !team.isEmpty {
            return "\(base) (\(team))"
        }
        return base
    }

    private func expiryHint(for entry: AuthEntry) -> String? {
        let now = Date()
        if let exp = entry.expiresAt, exp <= now {
            return "本地 OIDC 会话已过期，请执行 grok login"
        }
        if let jwtExp = Self.jwtExpirationDate(from: entry.accessToken), jwtExp <= now {
            return "本地 OIDC 会话已过期，请执行 grok login"
        }
        return nil
    }

    private static func formatCreditNumber(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.005 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let str = raw as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstDouble(in dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = parseDouble(dict[key]) {
                return value
            }
        }
        return nil
    }

    private static func parseDouble(_ raw: Any?) -> Double? {
        if let d = raw as? Double, d.isFinite { return d }
        if let i = raw as? Int { return Double(i) }
        if let i64 = raw as? Int64 { return Double(i64) }
        if let n = raw as? NSNumber {
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let s = raw as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = Double(trimmed), d.isFinite {
                return d
            }
        }
        return nil
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        if let str = nonEmptyString(raw) {
            if let rfc = Formatters.parseRFC3339(str) {
                return rfc
            }
            if let num = Double(str), num.isFinite, num > 1_000_000_000 {
                return num > 1_000_000_000_000
                    ? Date(timeIntervalSince1970: num / 1000.0)
                    : Date(timeIntervalSince1970: num)
            }
        }
        if let num = parseDouble(raw), num > 1_000_000_000 {
            return num > 1_000_000_000_000
                ? Date(timeIntervalSince1970: num / 1000.0)
                : Date(timeIntervalSince1970: num)
        }
        return nil
    }

    private static func sanitizedNetworkError(_ error: Error) -> String {
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain {
            switch nsErr.code {
            case NSURLErrorTimedOut:
                return "请求超时"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "DNS 解析失败"
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "网络连接中断"
            case NSURLErrorCannotConnectToHost:
                return "无法连接服务器或本地代理"
            case NSURLErrorSecureConnectionFailed:
                return "TLS 握手失败"
            default:
                return "网络错误 (\(nsErr.code))"
            }
        }
        return "请求异常"
    }
}
