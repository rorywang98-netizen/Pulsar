import Foundation

// MARK: - Passive Local-Only Claude CLI Quota Provider (100% Offline)

/// Strictly offline, passive local file reader for Claude CLI quota telemetry.
///
/// Safety guarantees:
/// - Zero network calls (no HTTP clients, no remote endpoints, no sockets).
/// - Zero credential or secret reads (no system vault, no cookies, no auth tokens).
/// - Zero child-command spawning and zero interaction with Claude Desktop.
/// - Reads ONLY non-secret metadata and cached utilization snapshots from:
///   1. `~/.claude.json` (`oauthAccount` metadata + `cachedUsageUtilization`)
///   2. `~/.cache/pulsar/claude-cli-quota.json` (local statusLine passive mirror)
public final class ClaudeProvider: ProviderAdapter, @unchecked Sendable {
    public struct Paths: Equatable, Sendable {
        public var claudeConfigURL: URL
        public var statusLineCacheURL: URL

        public init(claudeConfigURL: URL, statusLineCacheURL: URL) {
            self.claudeConfigURL = claudeConfigURL
            self.statusLineCacheURL = statusLineCacheURL
        }

        public static var liveDefaults: Paths {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let configDir: URL
            if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !override.isEmpty {
                let expanded = (override as NSString).expandingTildeInPath
                configDir = URL(fileURLWithPath: expanded, isDirectory: true)
            } else {
                configDir = home
            }
            let claudeConfig = configDir.appendingPathComponent(".claude.json", isDirectory: false)
            let statusLineCache = home
                .appendingPathComponent(".cache", isDirectory: true)
                .appendingPathComponent("pulsar", isDirectory: true)
                .appendingPathComponent("claude-cli-quota.json", isDirectory: false)
            return Paths(
                claudeConfigURL: claudeConfig,
                statusLineCacheURL: statusLineCache
            )
        }
    }

    public static let defaultLocalAccountId = "claude-cli-local"
    public static let passiveUnconfiguredMessage =
        "纯本地被动模式：在终端使用 Claude CLI 回复或输入 /usage 后自动同步余量（零联网）"
    public static let resetElapsedDetailMessage =
        "窗口已重置 · 待下次 CLI 对话同步"
    public static let policyRefusalMessage =
        "安全策略：Claude CLI 仅被动读取本地余量，不操作进程或凭据"
    public static let staleThresholdSeconds: TimeInterval = 86_400

    private static let maxClaudeConfigBytes = 32 * 1024 * 1024
    private static let maxStatusLineCacheBytes = 2 * 1024 * 1024

    public let id: ProviderID = .claude
    public let capabilities: ProviderCapability = [.quota]
    public let transportPolicy: TransportPolicy = .systemProxy
    public let isolatedStoreNamespace: String = "com.rory.roryorbit.claude.local"

    public let paths: Paths
    public let processController: ProcessController
    private let fileManager: FileManager

    public init(
        paths: Paths = .liveDefaults,
        processController: ProcessController = .shared,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.processController = processController
        self.fileManager = fileManager
    }

    // MARK: - ProviderAdapter

    public func detectClientStatus() async -> ClientRuntimeStatus {
        let runningCLI = processController.inspector
            .allRunningProcesses()
            .filter { Self.isClaudeCLIExecutablePath($0.executablePath, bundleId: $0.bundleId) }
            .sorted { $0.id < $1.id }

        let homePath = fileManager.homeDirectoryForCurrentUser.path
        let candidateBinaries = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(homePath)/.local/bin/claude",
        ]
        let hasCLIInstalled = candidateBinaries.contains { fileManager.fileExists(atPath: $0) }
            || !runningCLI.isEmpty

        return ClientRuntimeStatus(
            installedApps: hasCLIInstalled ? ["Claude CLI"] : [],
            runningProcesses: runningCLI,
            isRunning: !runningCLI.isEmpty
        )
    }

    public func syncLiveAccount(registry: inout RegistryData) async -> String? {
        let claudeDoc = readClaudeConfigDocument()
        let statusDoc = readStatusLineCacheDocument()

        let oauth = claudeDoc?.oauthAccount
        let accountUuid = Self.firstNonEmpty(oauth?.accountUuid, statusDoc?.accountUuid)
        let email = Self.firstNonEmpty(oauth?.email, statusDoc?.email) ?? ""
        let rawDisplay = Self.firstNonEmpty(oauth?.displayName, statusDoc?.displayName)
        let displayName = Self.firstNonEmpty(rawDisplay, email) ?? "Claude CLI"
        let resolvedPlan = Self.resolvePlan(oauth: oauth, statusLine: statusDoc)

        let existing = registry.accounts(for: .claude)
        let canonicalId: String
        if let accountUuid {
            canonicalId = accountUuid
        } else if let existingReal = existing.first(where: {
            $0.id != "claude:default" && $0.id != Self.defaultLocalAccountId
        }) {
            canonicalId = existingReal.id
        } else {
            canonicalId = Self.defaultLocalAccountId
        }

        let record = AccountRecord(
            id: canonicalId,
            provider: .claude,
            email: email,
            displayName: displayName,
            plan: resolvedPlan,
            addedAt: existing.first?.addedAt ?? Date(),
            isActiveLive: true
        )

        // Keep strictly one local Claude CLI account entry (clean up placeholder IDs).
        for old in existing where old.id != canonicalId {
            registry.removeAccount(id: old.id, provider: .claude)
        }
        registry.upsertAccount(record)
        registry.setActiveLive(accountId: canonicalId, for: .claude)
        return canonicalId
    }

    public func fetchQuota(for account: AccountRecord, isActiveLive: Bool) async -> QuotaSnapshot {
        _ = isActiveLive
        return resolvePassiveQuota(accountId: account.id, now: Date())
    }

    public func addAccount() async throws -> AccountRecord {
        throw ProviderAdapterError.operationFailed(Self.policyRefusalMessage)
    }

    public func importLiveAccount() async throws -> AccountRecord {
        throw ProviderAdapterError.operationFailed(Self.policyRefusalMessage)
    }

    public func switchAccount(to account: AccountRecord, allowForceQuit: Bool) async -> SwitchResult {
        _ = (account, allowForceQuit)
        return .failed(Self.policyRefusalMessage)
    }

    public func controlClient(restart: Bool, allowForceQuit: Bool) async -> SwitchResult {
        _ = (restart, allowForceQuit)
        return .failed(Self.policyRefusalMessage)
    }

    public func hasStoredAPIKey() -> Bool {
        false
    }

    public func saveAPIKey(_ key: String, label: String?) throws {
        _ = (key, label)
        throw ProviderAdapterError.operationFailed(Self.policyRefusalMessage)
    }

    public func deleteAccountCredentials(accountId: String) throws {
        _ = accountId
        // No-op: passive local reader never stores or touches credentials.
    }

    // MARK: - Dual-Source Passive Quota Reconciliation

    public func resolvePassiveQuota(now: Date = Date()) -> QuotaSnapshot {
        resolvePassiveQuota(accountId: nil, now: now)
    }

    public func resolvePassiveQuota(accountId explicitAccountId: String?, now: Date = Date()) -> QuotaSnapshot {
        let claudeDoc = readClaudeConfigDocument()
        let statusDoc = readStatusLineCacheDocument()

        let oauth = claudeDoc?.oauthAccount
        let activeUuid = oauth?.accountUuid

        // Route 1 (`~/.claude.json`): reject cachedUsageUtilization if accountUuid disagrees with oauthAccount.
        let route1: PassiveSourceReading?
        if let cached = claudeDoc?.cachedUsage {
            if let activeUuid, let cachedUuid = cached.accountUuid,
               !Self.uuidsMatch(activeUuid, cachedUuid) {
                route1 = nil
            } else {
                route1 = PassiveSourceReading(
                    sourceLabel: "本地缓存",
                    observedAt: cached.fetchedAt,
                    accountUuid: cached.accountUuid ?? activeUuid,
                    fiveHour: cached.fiveHour,
                    sevenDay: cached.sevenDay
                )
            }
        } else {
            route1 = nil
        }

        // Route 2 (`~/.cache/pulsar/claude-cli-quota.json`): also enforce accountUuid consistency when oauthAccount is known.
        let route2: PassiveSourceReading?
        if let statusDoc, (statusDoc.fiveHour != nil || statusDoc.sevenDay != nil) {
            if let activeUuid, let statusUuid = statusDoc.accountUuid,
               !Self.uuidsMatch(activeUuid, statusUuid) {
                route2 = nil
            } else {
                route2 = PassiveSourceReading(
                    sourceLabel: "本地状态栏",
                    observedAt: statusDoc.observedAt,
                    accountUuid: statusDoc.accountUuid ?? activeUuid,
                    fiveHour: statusDoc.fiveHour,
                    sevenDay: statusDoc.sevenDay
                )
            }
        } else {
            route2 = nil
        }

        let resolvedAccountId = Self.firstNonEmpty(
            explicitAccountId,
            activeUuid,
            route2?.accountUuid,
            route1?.accountUuid
        ) ?? Self.defaultLocalAccountId

        let resolvedPlan = Self.resolvePlan(oauth: oauth, statusLine: statusDoc)

        // Choose newer source as primary; keep older source for same-account future-window backfill.
        let primary: PassiveSourceReading
        let secondary: PassiveSourceReading?
        switch (route2, route1) {
        case (let s2?, let s1?):
            if s2.observedAt >= s1.observedAt {
                primary = s2
                secondary = s1
            } else {
                primary = s1
                secondary = s2
            }
        case (let s2?, nil):
            primary = s2
            secondary = nil
        case (nil, let s1?):
            primary = s1
            secondary = nil
        case (nil, nil):
            return QuotaSnapshot(
                provider: .claude,
                accountId: resolvedAccountId,
                plan: resolvedPlan,
                windows: [],
                balance: nil,
                status: .unconfigured(Self.passiveUnconfiguredMessage),
                sourceLabel: "本地被动"
            )
        }

        var fiveHour = primary.fiveHour
        var sevenDay = primary.sevenDay

        if let secondary, Self.sameAccount(primary.accountUuid, secondary.accountUuid) {
            if fiveHour == nil,
               let fallback5h = secondary.fiveHour,
               let resetAt = fallback5h.resetsAt,
               resetAt > now {
                fiveHour = fallback5h
            }
            if sevenDay == nil,
               let fallback7d = secondary.sevenDay,
               let resetAt = fallback7d.resetsAt,
               resetAt > now {
                sevenDay = fallback7d
            }
        }

        var windows: [QuotaWindow] = []
        var anyResetElapsed = false

        if let sample5h = fiveHour {
            let (win, elapsed) = Self.makeQuotaWindow(
                id: "claude_5h",
                label: "Claude · 5小时",
                windowSeconds: 18_000,
                isPrimary: true,
                sample: sample5h,
                now: now
            )
            if elapsed { anyResetElapsed = true }
            windows.append(win)
        }

        if let sample7d = sevenDay {
            let (win, elapsed) = Self.makeQuotaWindow(
                id: "claude_weekly",
                label: "Claude · 周",
                windowSeconds: 604_800,
                isPrimary: fiveHour == nil,
                sample: sample7d,
                now: now
            )
            if elapsed { anyResetElapsed = true }
            windows.append(win)
        }

        guard !windows.isEmpty else {
            return QuotaSnapshot(
                provider: .claude,
                accountId: resolvedAccountId,
                plan: resolvedPlan,
                windows: [],
                balance: nil,
                status: .unconfigured(Self.passiveUnconfiguredMessage),
                sourceLabel: "本地被动"
            )
        }

        let isStale = (now.timeIntervalSince(primary.observedAt) > Self.staleThresholdSeconds) || anyResetElapsed
        return QuotaSnapshot(
            provider: .claude,
            accountId: resolvedAccountId,
            plan: resolvedPlan,
            windows: windows,
            balance: nil,
            status: .ready(fetchedAt: primary.observedAt, stale: isStale),
            sourceLabel: primary.sourceLabel
        )
    }

    // MARK: - CLI Process Matcher (Strict Desktop Exclusion)

    /// Returns `true` ONLY for standalone Claude CLI executables (e.g. Homebrew or `~/.local/bin/claude`),
    /// strictly excluding `/Applications/Claude.app`, any `.app` bundle, and `~/Library/Application Support/Claude/`.
    public static func isClaudeCLIExecutablePath(_ path: String, bundleId: String? = nil) -> Bool {
        if let bundleId, !bundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()

        // Hard exclusion: NEVER match Claude Desktop or any macOS .app bundle or Desktop support directory.
        if lower.contains("/applications/claude.app")
            || lower.contains("claude.app/")
            || lower.hasSuffix("claude.app")
            || lower.contains("/library/application support/claude")
            || lower.contains(".app/contents/") {
            return false
        }

        let lastComponent = URL(fileURLWithPath: trimmed).lastPathComponent.lowercased()

        // Native Claude Code binary under ~/.local/share/claude/versions/<semver>
        if lower.contains("/.local/share/claude/versions/") && !lastComponent.isEmpty {
            return true
        }

        guard lastComponent == "claude" else {
            return false
        }

        // Accept standard CLI install locations (Homebrew, ~/.local/bin, /usr/local, node/bun version managers).
        if lower.hasPrefix("/opt/homebrew/")
            || lower.hasPrefix("/usr/local/")
            || lower.contains("/.local/bin/")
            || lower.contains("/.local/share/claude/")
            || lower.contains("/.nvm/")
            || lower.contains("/.volta/")
            || lower.contains("/.asdf/")
            || lower.contains("/.fnm/")
            || lower.contains("/.bun/") {
            return true
        }
        return false
    }

    // MARK: - Internal Parsed Models

    private struct OAuthAccountMetadata {
        let accountUuid: String?
        let email: String?
        let displayName: String?
        let billingType: String?
        let organizationType: String?
        let organizationRateLimitTier: String?
    }

    private struct PassiveWindowSample {
        let usedPercent: Double
        let resetsAt: Date?
    }

    private struct CachedUsageSection {
        let fetchedAt: Date
        let accountUuid: String?
        let fiveHour: PassiveWindowSample?
        let sevenDay: PassiveWindowSample?
    }

    private struct ClaudeConfigDocument {
        let oauthAccount: OAuthAccountMetadata?
        let cachedUsage: CachedUsageSection?
    }

    private struct StatusLineCacheDocument {
        let observedAt: Date
        let accountUuid: String?
        let email: String?
        let displayName: String?
        let billingType: String?
        let fiveHour: PassiveWindowSample?
        let sevenDay: PassiveWindowSample?
    }

    private struct PassiveSourceReading {
        let sourceLabel: String
        let observedAt: Date
        let accountUuid: String?
        let fiveHour: PassiveWindowSample?
        let sevenDay: PassiveWindowSample?
    }

    // MARK: - Local JSON Readers (Strict Non-Secret Extraction)

    private func readJSONDictionary(at url: URL, maxBytes: Int) -> [String: Any]? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
           let sizeNum = attrs[.size] as? NSNumber,
           sizeNum.intValue > maxBytes {
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              !data.isEmpty,
              data.count <= maxBytes,
              let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }
        return root
    }

    private func readClaudeConfigDocument() -> ClaudeConfigDocument? {
        guard let root = readJSONDictionary(at: paths.claudeConfigURL, maxBytes: Self.maxClaudeConfigBytes) else {
            return nil
        }

        let oauth: OAuthAccountMetadata?
        if let oa = root["oauthAccount"] as? [String: Any] {
            let uuid = Self.nonEmptyString(oa["accountUuid"])
            let email = Self.nonEmptyString(oa["emailAddress"])
            let display = Self.firstNonEmpty(
                Self.nonEmptyString(oa["displayName"]),
                Self.nonEmptyString(oa["fullName"])
            )
            let billing = Self.nonEmptyString(oa["billingType"])
            let orgType = Self.nonEmptyString(oa["organizationType"])
            let tier = Self.nonEmptyString(oa["organizationRateLimitTier"])
            if uuid != nil || email != nil || display != nil || billing != nil || orgType != nil || tier != nil {
                oauth = OAuthAccountMetadata(
                    accountUuid: uuid,
                    email: email,
                    displayName: display,
                    billingType: billing,
                    organizationType: orgType,
                    organizationRateLimitTier: tier
                )
            } else {
                oauth = nil
            }
        } else {
            oauth = nil
        }

        let cachedUsage: CachedUsageSection?
        if let cu = root["cachedUsageUtilization"] as? [String: Any],
           let util = cu["utilization"] as? [String: Any],
           let fetchedAt = Self.parseFlexibleTimestamp(cu["fetchedAtMs"] ?? cu["fetchedAt"]) {
            let cachedUuid = Self.nonEmptyString(cu["accountUuid"])

            var fiveHour = Self.parseClaudeConfigWindow(util["five_hour"])
            var sevenDay = Self.parseClaudeConfigWindow(util["seven_day"])

            if (fiveHour == nil || sevenDay == nil),
               let limits = util["limits"] as? [[String: Any]] {
                for entry in limits {
                    let kind = Self.nonEmptyString(entry["kind"])?.lowercased() ?? ""
                    let group = Self.nonEmptyString(entry["group"])?.lowercased() ?? ""
                    if fiveHour == nil && (kind == "five_hour" || kind == "session" || group == "session" || group == "five_hour") {
                        fiveHour = Self.parseClaudeConfigWindow(entry)
                    } else if sevenDay == nil && (kind == "seven_day" || kind == "weekly_all" || kind == "weekly" || group == "weekly" || group == "seven_day") {
                        sevenDay = Self.parseClaudeConfigWindow(entry)
                    }
                }
            }

            if fiveHour != nil || sevenDay != nil {
                cachedUsage = CachedUsageSection(
                    fetchedAt: fetchedAt,
                    accountUuid: cachedUuid,
                    fiveHour: fiveHour,
                    sevenDay: sevenDay
                )
            } else {
                cachedUsage = nil
            }
        } else {
            cachedUsage = nil
        }

        return ClaudeConfigDocument(oauthAccount: oauth, cachedUsage: cachedUsage)
    }

    private func readStatusLineCacheDocument() -> StatusLineCacheDocument? {
        guard let root = readJSONDictionary(at: paths.statusLineCacheURL, maxBytes: Self.maxStatusLineCacheBytes) else {
            return nil
        }
        guard let observedAt = Self.parseFlexibleTimestamp(root["observedAt"]) else {
            return nil
        }

        let fiveHour = Self.parseStatusLineWindow(root["fiveHour"] ?? root["five_hour"])
        let sevenDay = Self.parseStatusLineWindow(root["sevenDay"] ?? root["seven_day"])
        guard fiveHour != nil || sevenDay != nil else {
            return nil
        }

        return StatusLineCacheDocument(
            observedAt: observedAt,
            accountUuid: Self.nonEmptyString(root["accountUuid"]),
            email: Self.nonEmptyString(root["email"]),
            displayName: Self.nonEmptyString(root["displayName"]),
            billingType: Self.nonEmptyString(root["billingType"]),
            fiveHour: fiveHour,
            sevenDay: sevenDay
        )
    }

    // MARK: - Window, Plan & Timestamp Normalization

    private static func parseClaudeConfigWindow(_ raw: Any?) -> PassiveWindowSample? {
        guard let dict = raw as? [String: Any] else { return nil }
        guard let used = parseDouble(dict["utilization"] ?? dict["percent"] ?? dict["usedPercent"] ?? dict["used_percentage"]) else {
            return nil
        }
        let resetsAt = parseFlexibleTimestamp(dict["resets_at"] ?? dict["resetsAt"])
        return PassiveWindowSample(
            usedPercent: min(max(used, 0.0), 100.0),
            resetsAt: resetsAt
        )
    }

    private static func parseStatusLineWindow(_ raw: Any?) -> PassiveWindowSample? {
        guard let dict = raw as? [String: Any] else { return nil }
        guard let used = parseDouble(dict["usedPercent"] ?? dict["used_percentage"] ?? dict["utilization"] ?? dict["percent"]) else {
            return nil
        }
        let resetsAt = parseFlexibleTimestamp(dict["resetsAt"] ?? dict["resets_at"])
        return PassiveWindowSample(
            usedPercent: min(max(used, 0.0), 100.0),
            resetsAt: resetsAt
        )
    }

    private static func makeQuotaWindow(
        id: String,
        label: String,
        windowSeconds: Int,
        isPrimary: Bool,
        sample: PassiveWindowSample,
        now: Date
    ) -> (window: QuotaWindow, resetElapsed: Bool) {
        if let resetAt = sample.resetsAt, resetAt <= now {
            let window = QuotaWindow(
                id: id,
                label: label,
                remainingFraction: 1.0,
                usedPercent: 0.0,
                resetAt: nil,
                windowSeconds: windowSeconds,
                detail: resetElapsedDetailMessage,
                isPrimary: isPrimary
            )
            return (window, true)
        }

        let clampedUsed = min(max(sample.usedPercent, 0.0), 100.0)
        let remainingFraction = min(max((100.0 - clampedUsed) / 100.0, 0.0), 1.0)
        let window = QuotaWindow(
            id: id,
            label: label,
            remainingFraction: remainingFraction,
            usedPercent: clampedUsed,
            resetAt: sample.resetsAt,
            windowSeconds: windowSeconds,
            detail: nil,
            isPrimary: isPrimary
        )
        return (window, false)
    }

    private static func resolvePlan(
        oauth: OAuthAccountMetadata?,
        statusLine: StatusLineCacheDocument?
    ) -> PlanInfo {
        let hints = [
            oauth?.organizationRateLimitTier,
            oauth?.organizationType,
            oauth?.billingType,
            statusLine?.billingType,
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        for hint in hints {
            if hint.contains("max") {
                if hint.contains("20x") {
                    return PlanInfo(kind: .max, displayName: "Max 20x")
                }
                if hint.contains("5x") {
                    return PlanInfo(kind: .max, displayName: "Max 5x")
                }
                return PlanInfo(kind: .max, displayName: "Max")
            }
            if hint.contains("enterprise") {
                return PlanInfo(kind: .enterprise, displayName: "Enterprise")
            }
            if hint.contains("team") {
                return PlanInfo(kind: .team, displayName: "Team")
            }
            if hint.contains("pro") {
                return PlanInfo(kind: .pro, displayName: "Pro")
            }
            if hint.contains("free") {
                return PlanInfo(kind: .free, displayName: "Free")
            }
            if hint.contains("api") {
                return PlanInfo(kind: .api, displayName: "API")
            }
        }

        return PlanInfo(kind: .unknown, displayName: "Claude CLI")
    }

    private static func parseFlexibleTimestamp(_ raw: Any?) -> Date? {
        guard let raw, !(raw is NSNull) else { return nil }
        if let str = raw as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let parsed = Formatters.parseRFC3339(trimmed) {
                return parsed
            }
            if let numeric = Double(trimmed), numeric.isFinite, numeric > 0 {
                return dateFromUnixNumber(numeric)
            }
            return nil
        }
        if let num = parseDouble(raw), num > 0 {
            return dateFromUnixNumber(num)
        }
        return nil
    }

    private static func dateFromUnixNumber(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        let seconds = value > 100_000_000_000.0 ? (value / 1000.0) : value
        // Sanity bounds: year 2001 .. year 2150
        guard seconds >= 978_307_200.0 && seconds <= 5_680_281_600.0 else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func parseDouble(_ raw: Any?) -> Double? {
        guard let raw, !(raw is NSNull) else { return nil }
        if raw is Bool { return nil }
        if let d = raw as? Double, d.isFinite { return d }
        if let i = raw as? Int { return Double(i) }
        if let i64 = raw as? Int64 { return Double(i64) }
        if let n = raw as? NSNumber {
            // Guard against CFBoolean bridging to NSNumber
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let s = raw as? String,
           let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)),
           d.isFinite {
            return d
        }
        return nil
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let str = raw as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func uuidsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func sameAccount(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let l = lhs?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty,
              let r = rhs?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else {
            return true
        }
        return l.lowercased() == r.lowercased()
    }
}
