import Darwin
import Foundation

// MARK: - AccountPool Export JSON Models (Zero Secrets, Passive Local-Archive Claude Only)

public struct AccountPoolRateWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double?
    public let windowMinutes: Int?
    public let resetsAt: String?
    public let resetDescription: String?

    public init(
        usedPercent: Double? = nil,
        windowMinutes: Int? = nil,
        resetsAt: String? = nil,
        resetDescription: String? = nil
    ) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }
}

public struct AccountPoolExtraRateWindow: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let window: AccountPoolRateWindow

    public init(id: String, title: String, window: AccountPoolRateWindow) {
        self.id = id
        self.title = title
        self.window = window
    }
}

public struct AccountPoolUsageIdentity: Codable, Equatable, Sendable {
    public let accountEmail: String?
    public let loginMethod: String?

    public init(accountEmail: String? = nil, loginMethod: String? = nil) {
        self.accountEmail = accountEmail
        self.loginMethod = loginMethod
    }
}

public struct AccountPoolUsageBody: Codable, Equatable, Sendable {
    public let accountEmail: String?
    public let identity: AccountPoolUsageIdentity?
    public let loginMethod: String?
    public let updatedAt: String?
    public let primary: AccountPoolRateWindow?
    public let secondary: AccountPoolRateWindow?
    public let tertiary: AccountPoolRateWindow?
    public let extraRateWindows: [AccountPoolExtraRateWindow]?

    public init(
        accountEmail: String? = nil,
        identity: AccountPoolUsageIdentity? = nil,
        loginMethod: String? = nil,
        updatedAt: String? = nil,
        primary: AccountPoolRateWindow? = nil,
        secondary: AccountPoolRateWindow? = nil,
        tertiary: AccountPoolRateWindow? = nil,
        extraRateWindows: [AccountPoolExtraRateWindow]? = nil
    ) {
        self.accountEmail = accountEmail
        self.identity = identity
        self.loginMethod = loginMethod
        self.updatedAt = updatedAt
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.extraRateWindows = extraRateWindows
    }
}

public struct AccountPoolCredits: Codable, Equatable, Sendable {
    public let remaining: Double
    public let balanceReadSucceeded: Bool

    public init(remaining: Double, balanceReadSucceeded: Bool) {
        self.remaining = remaining
        self.balanceReadSucceeded = balanceReadSucceeded
    }
}

public struct AccountPoolResetCredits: Codable, Equatable, Sendable {
    public let available: Int

    public init(available: Int) {
        self.available = available
    }
}

public struct AccountPoolProviderRow: Codable, Equatable, Sendable {
    public let provider: String
    public let account: String?
    public let accountId: String?
    public let sourceKind: String?
    public let sourceLabel: String?
    public let error: String?
    public let rateWindowLabels: [String: String]?
    public let credits: AccountPoolCredits?
    public let resetCredits: AccountPoolResetCredits?
    public let usage: AccountPoolUsageBody?

    public init(
        provider: String,
        account: String? = nil,
        accountId: String? = nil,
        sourceKind: String? = nil,
        sourceLabel: String? = nil,
        error: String? = nil,
        rateWindowLabels: [String: String]? = nil,
        credits: AccountPoolCredits? = nil,
        resetCredits: AccountPoolResetCredits? = nil,
        usage: AccountPoolUsageBody? = nil
    ) {
        self.provider = provider
        self.account = account
        self.accountId = accountId
        self.sourceKind = sourceKind
        self.sourceLabel = sourceLabel
        self.error = error
        self.rateWindowLabels = rateWindowLabels
        self.credits = credits
        self.resetCredits = resetCredits
        self.usage = usage
    }
}

public struct AccountPoolAntigravityPlan: Codable, Equatable, Sendable {
    public let kind: String
    public let name: String

    public init(kind: String, name: String) {
        self.kind = kind
        self.name = name
    }
}

public struct AccountPoolAntigravityRegistryEntry: Codable, Equatable, Sendable {
    public let id: String
    public let provider: String
    public let email: String
    public let plan: AccountPoolAntigravityPlan?

    public init(id: String, provider: String = "antigravity", email: String, plan: AccountPoolAntigravityPlan?) {
        self.id = id
        self.provider = provider
        self.email = email
        self.plan = plan
    }
}

public struct AccountPoolExportPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let providers: [String: [AccountPoolProviderRow]]
    public let antigravityRegistry: [AccountPoolAntigravityRegistryEntry]

    public init(
        schemaVersion: Int = 1,
        generatedAt: String,
        providers: [String: [AccountPoolProviderRow]],
        antigravityRegistry: [AccountPoolAntigravityRegistryEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.providers = providers
        self.antigravityRegistry = antigravityRegistry
    }
}

// MARK: - AccountPoolExporter

public final class AccountPoolExporter: @unchecked Sendable {
    public static let shared = AccountPoolExporter()

    /// Exported providers (Claude is strictly passive local_archive only, zero secrets/network).
    public static let exportedProviders: [ProviderID] = [
        .codex,
        .cursor,
        .grok,
        .deepseek,
        .kimi,
        .antigravity,
        .claude,
    ]

    public static let claudePassiveSourceKind = "local_archive"
    public static let claudePassiveSourceLabel = "Claude CLI 本地被动"

    public static var defaultSnapshotURL: URL {
        RegistryData.defaultDirectoryURL.appendingPathComponent("accountpool-snapshot.json", isDirectory: false)
    }

    public static var defaultLockURL: URL {
        RegistryData.defaultDirectoryURL.appendingPathComponent(".refresh.lock", isDirectory: false)
    }

    private let appSupportURL: URL
    private let snapshotURL: URL
    private let lockURL: URL

    public init(appSupportURL: URL = RegistryData.defaultDirectoryURL) {
        self.appSupportURL = appSupportURL
        self.snapshotURL = appSupportURL.appendingPathComponent("accountpool-snapshot.json", isDirectory: false)
        self.lockURL = appSupportURL.appendingPathComponent(".refresh.lock", isDirectory: false)
    }

    // MARK: - Cross-Process Advisory File Lock (`flock(LOCK_EX | LOCK_NB)` + `@TaskLocal` Re-entrancy Guard)

    @TaskLocal private static var heldLockPaths: Set<String> = []

    /// Serializes live OAuth/quota refreshes across GUI and CLI processes using `flock` without blocking
    /// the Swift cooperative thread pool. Uses `@TaskLocal` to allow safe re-entrancy when an outer
    /// locked export (`exportJSONData`) invokes nested `CodexProvider` refreshes within the same task tree.
    public static func withCrossProcessRefreshLock<T>(
        lockURL: URL = AccountPoolExporter.defaultLockURL,
        timeoutSeconds: TimeInterval = 60.0,
        operation: () async throws -> T
    ) async rethrows -> T {
        let canonicalPath = lockURL.standardizedFileURL.path
        if heldLockPaths.contains(canonicalPath) {
            return try await operation()
        }

        let dir = lockURL.deletingLastPathComponent()
        try? KeychainStore.ensureDirectory(at: dir, mode: 0o700)

        let fd = open(canonicalPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            return try await $heldLockPaths.withValue(heldLockPaths.union([canonicalPath])) {
                try await operation()
            }
        }
        _ = fchmod(fd, S_IRUSR | S_IWUSR)

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
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms cooperative yield
        }

        defer {
            if acquired {
                _ = flock(fd, LOCK_UN)
            }
            close(fd)
        }
        return try await $heldLockPaths.withValue(heldLockPaths.union([canonicalPath])) {
            try await operation()
        }
    }

    // MARK: - Payload Building & Atomic Snapshot Persistence

    /// Builds the sanitized `AccountPoolExportPayload` from current registry + quota snapshots.
    /// Claude rows are emitted strictly as passive `local_archive` entries when ready (zero secrets, zero error fabrication).
    /// When `fallbackCached` is supplied, accounts whose current snapshot is missing or `.loading` retain
    /// their previous cached row so partial GUI startup refreshes never degrade AccountPool data.
    public func buildPayload(
        registry: RegistryData,
        snapshots: [String: QuotaSnapshot],
        now: Date = Date(),
        fallbackCached: AccountPoolExportPayload? = nil
    ) -> AccountPoolExportPayload {
        var providersMap: [String: [AccountPoolProviderRow]] = [:]

        for provider in Self.exportedProviders {
            let accounts = sortedAccounts(for: provider, in: registry)
            let prevRows: [AccountPoolProviderRow]
            if provider == .claude {
                prevRows = (fallbackCached?.providers[provider.rawValue] ?? [])
                    .filter { $0.provider == "claude" && $0.sourceKind == Self.claudePassiveSourceKind }
            } else {
                prevRows = fallbackCached?.providers[provider.rawValue] ?? []
            }
            var rows: [AccountPoolProviderRow] = []

            for account in accounts {
                let key = "\(provider.rawValue)|\(account.id)"
                let snap = snapshots[key] ?? snapshots[account.id]

                // If GUI hasn't finished fetching this account yet, retain prior warm row if available.
                if snap == nil || snap?.status == .loading {
                    if let cachedRow = matchCachedRow(for: account, provider: provider, in: prevRows) {
                        rows.append(cachedRow)
                        continue
                    }
                }

                if provider == .claude {
                    if let claudeRow = buildClaudeRow(account: account, snapshot: snap) {
                        rows.append(claudeRow)
                    }
                    continue
                }

                let row = buildProviderRow(provider: provider, account: account, snapshot: snap)
                rows.append(row)
            }

            if provider == .claude {
                if !rows.isEmpty {
                    providersMap[provider.rawValue] = rows
                }
            } else {
                if rows.isEmpty && !prevRows.isEmpty {
                    rows = prevRows
                }
                providersMap[provider.rawValue] = rows
            }
        }

        // Build Antigravity numeric-sub registry (replaces deleted OrbitSwitch accounts.json).
        let agyRegistry: [AccountPoolAntigravityRegistryEntry] = sortedAccounts(for: .antigravity, in: registry)
            .filter { Self.isNumericGoogleSub($0.id) }
            .map { account in
                let planEntry = account.plan.map {
                    AccountPoolAntigravityPlan(
                        kind: $0.kind.rawValue,
                        name: Self.sanitizeSafeText($0.displayName) ?? $0.kind.defaultDisplayName
                    )
                }
                return AccountPoolAntigravityRegistryEntry(
                    id: account.id,
                    provider: "antigravity",
                    email: account.email.trimmingCharacters(in: .whitespacesAndNewlines),
                    plan: planEntry
                )
            }

        return AccountPoolExportPayload(
            schemaVersion: 1,
            generatedAt: Self.formatRFC3339UTCSeconds(now),
            providers: providersMap,
            antigravityRegistry: agyRegistry
        )
    }

    /// Writes `accountpool-snapshot.json` (`0600` atomic) after GUI refreshes.
    @discardableResult
    public func writeSnapshot(
        registry: RegistryData,
        snapshots: [String: QuotaSnapshot],
        now: Date = Date()
    ) throws -> AccountPoolExportPayload {
        let existing = readCachedPayload()
        let payload = buildPayload(registry: registry, snapshots: snapshots, now: now, fallbackCached: existing)
        try persistPayload(payload)
        return payload
    }

    /// CLI entry point for `--export-accountpool-json [--max-age 240] [--refresh]`.
    /// Warm path returns GUI-persisted `accountpool-snapshot.json` in <10ms; cold/stale path acquires
    /// cross-process `flock`, double-checks cache freshness, refreshes all 6 non-Claude providers safely,
    /// writes updated cache (`0600`), and returns JSON Data.
    public func exportJSONData(
        maxAgeSeconds: TimeInterval = 240,
        forceRefresh: Bool = false,
        registryURL: URL = RegistryData.defaultFileURL,
        keychain: KeychainStore = .shared,
        processController: ProcessController = .shared,
        now: Date = Date()
    ) async throws -> Data {
        if !forceRefresh, let warmData = readFreshCachedData(maxAgeSeconds: maxAgeSeconds, now: now) {
            return warmData
        }

        return try await Self.withCrossProcessRefreshLock(lockURL: lockURL) {
            // Double-check after acquiring cross-process lock in case GUI just wrote a fresh snapshot.
            let checkNow = Date()
            if !forceRefresh, let warmData = self.readFreshCachedData(maxAgeSeconds: maxAgeSeconds, now: checkNow) {
                return warmData
            }

            let baseRegistry = (try? RegistryData.load(from: registryURL)) ?? RegistryData()
            // CRITICAL: Always force non-interactive Keychain for headless CLI export so macOS SecurityAgent
            // can NEVER block `--export-accountpool-json` or LaunchAgent collectors waiting on a GUI prompt.
            var adapters = AppStore.makeDefaultAdapters(
                keychain: keychain,
                processController: processController
            )
            adapters[.cursor] = CursorProvider(
                keychain: keychain,
                allowInteractiveKeychain: false
            )

            var mergedAccounts: [AccountRecord] = []
            var fetchedSnapshots: [String: QuotaSnapshot] = [:]

            await withTaskGroup(of: (ProviderID, [AccountRecord], [(String, QuotaSnapshot)]).self) { group in
                for provider in Self.exportedProviders {
                    let adapter = adapters[provider]
                    let initialAccounts = baseRegistry.accounts(for: provider)
                    let settings = baseRegistry.settings
                    let schemaVersion = baseRegistry.schemaVersion

                    group.addTask {
                        guard let adapter else {
                            return (provider, initialAccounts, [])
                        }

                        var scopedRegistry = RegistryData(
                            schemaVersion: schemaVersion,
                            accounts: initialAccounts,
                            settings: settings
                        )
                        let liveId = await adapter.syncLiveAccount(registry: &scopedRegistry)
                        if let liveId {
                            scopedRegistry.setActiveLive(accountId: liveId, for: provider)
                        }

                        var accounts = scopedRegistry.accounts(for: provider)
                        if !provider.supportsMultiAccount {
                            let defaultId = provider.supportsAPIKeyConfig
                                ? "\(provider.rawValue):api"
                                : "\(provider.rawValue):default"
                            if let liveId,
                               liveId != defaultId,
                               accounts.count > 1,
                               accounts.contains(where: { $0.id == liveId }) {
                                accounts.removeAll { $0.id == defaultId && $0.email.isEmpty }
                            }
                            if accounts.isEmpty {
                                accounts = [
                                    AccountRecord(
                                        id: defaultId,
                                        provider: provider,
                                        email: "",
                                        displayName: provider.displayName,
                                        plan: provider.supportsAPIKeyConfig ? PlanInfo(kind: .api, displayName: "API") : nil,
                                        addedAt: checkNow,
                                        isActiveLive: true
                                    )
                                ]
                            }
                        }

                        var pairs: [(String, QuotaSnapshot)] = []
                        for account in accounts {
                            // CRITICAL: pass exact `isActiveLive` so live Codex single-use refresh tokens are NEVER touched.
                            let snap = await adapter.fetchQuota(for: account, isActiveLive: account.isActiveLive)
                            pairs.append(("\(provider.rawValue)|\(account.id)", snap))
                        }

                        // Enrich in-memory account plans from live snapshots without mutating registry.json.
                        for (idx, acc) in accounts.enumerated() {
                            if let snap = pairs.first(where: { $0.0 == "\(provider.rawValue)|\(acc.id)" })?.1,
                               let plan = snap.plan, plan.kind != .unknown {
                                accounts[idx].plan = plan
                            }
                        }

                        return (provider, accounts, pairs)
                    }
                }

                for await (_, accounts, pairs) in group {
                    mergedAccounts.append(contentsOf: accounts)
                    for (k, snap) in pairs {
                        fetchedSnapshots[k] = snap
                    }
                }
            }

            let effectiveRegistry = RegistryData(
                schemaVersion: baseRegistry.schemaVersion,
                accounts: mergedAccounts,
                settings: baseRegistry.settings
            )
            let finishedAt = Date()
            let payload = self.buildPayload(
                registry: effectiveRegistry,
                snapshots: fetchedSnapshots,
                now: finishedAt,
                fallbackCached: self.readCachedPayload()
            )
            let data = try Self.encodePayload(payload)
            try? KeychainStore.ensureDirectory(at: self.appSupportURL, mode: 0o700)
            try? KeychainStore.writeAtomicFile(data: data, to: self.snapshotURL, mode: 0o600)
            return data
        }
    }

    // MARK: - Cache Read/Write Helpers

    private func readCachedPayload() -> AccountPoolExportPayload? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path),
              let data = try? Data(contentsOf: snapshotURL) else {
            return nil
        }
        return try? JSONDecoder().decode(AccountPoolExportPayload.self, from: data)
    }

    /// Validates passive-only safety invariants on any cached export payload:
    /// if `"claude"` rows exist, every row MUST strictly declare `sourceKind == "local_archive"`.
    public static func isValidCachedPayload(_ payload: AccountPoolExportPayload) -> Bool {
        if let claudeRows = payload.providers["claude"] {
            return claudeRows.allSatisfy {
                $0.provider == "claude" && $0.sourceKind == Self.claudePassiveSourceKind
            }
        }
        return true
    }

    private func readFreshCachedData(maxAgeSeconds: TimeInterval, now: Date) -> Data? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path),
              let data = try? Data(contentsOf: snapshotURL),
              let payload = try? JSONDecoder().decode(AccountPoolExportPayload.self, from: data),
              let generatedDate = Formatters.parseRFC3339(payload.generatedAt) else {
            return nil
        }
        let age = now.timeIntervalSince(generatedDate)
        guard age >= -60.0 && age <= max(0.0, maxAgeSeconds) else {
            return nil
        }
        // Safety gate: if "claude" is present, every row MUST strictly declare sourceKind == "local_archive".
        guard Self.isValidCachedPayload(payload) else {
            return nil
        }
        return data
    }

    private func persistPayload(_ payload: AccountPoolExportPayload) throws {
        let data = try Self.encodePayload(payload)
        try KeychainStore.ensureDirectory(at: appSupportURL, mode: 0o700)
        try KeychainStore.writeAtomicFile(data: data, to: snapshotURL, mode: 0o600)
    }

    private static func encodePayload(_ payload: AccountPoolExportPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    // MARK: - Per-Provider Row Mapping

    private func buildProviderRow(
        provider: ProviderID,
        account: AccountRecord,
        snapshot: QuotaSnapshot?
    ) -> AccountPoolProviderRow {
        switch provider {
        case .codex:
            return buildCodexRow(account: account, snapshot: snapshot)
        case .cursor:
            return buildCursorRow(account: account, snapshot: snapshot)
        case .grok:
            return buildGrokRow(account: account, snapshot: snapshot)
        case .deepseek:
            return buildDeepSeekRow(account: account, snapshot: snapshot)
        case .kimi:
            return buildKimiRow(account: account, snapshot: snapshot)
        case .antigravity:
            return buildAntigravityRow(account: account, snapshot: snapshot)
        case .claude:
            return buildClaudeRow(account: account, snapshot: snapshot) ?? AccountPoolProviderRow(
                provider: "claude",
                sourceKind: Self.claudePassiveSourceKind,
                sourceLabel: Self.claudePassiveSourceLabel,
                error: Self.sanitizedStatusError(snapshot?.status)
            )
        }
    }

    private func buildClaudeRow(account: AccountRecord, snapshot: QuotaSnapshot?) -> AccountPoolProviderRow? {
        guard let snapshot, case .ready(let fetchedAt, _) = snapshot.status else {
            // Never fabricate error rows for passive local Claude when unconfigured/unavailable.
            return nil
        }

        let trimmedEmail = Self.nonEmptyTrimmed(account.email)
        let email: String? = (trimmedEmail?.contains("@") == true) ? trimmedEmail : nil
        let accountId = Self.nonEmptyTrimmed(account.id)
        let effectivePlan = snapshot.plan ?? account.plan
        let loginMethod = Self.sanitizeSafeText(effectivePlan?.displayName) ?? "Claude CLI"

        var primary: AccountPoolRateWindow?
        var secondary: AccountPoolRateWindow?

        for w in snapshot.windows {
            if w.id == "claude_5h" || w.cadence == .fiveHour || w.windowSeconds == 18_000 {
                if primary == nil {
                    primary = Self.toRateWindow(w, defaultWindowMinutes: 300)
                }
            } else if w.id == "claude_weekly" || w.cadence == .weekly || w.windowSeconds == 604_800 {
                if secondary == nil {
                    secondary = Self.toRateWindow(w, defaultWindowMinutes: 10_080)
                }
            }
        }

        guard primary != nil || secondary != nil else {
            return nil
        }

        return AccountPoolProviderRow(
            provider: "claude",
            account: nil,
            accountId: accountId,
            sourceKind: Self.claudePassiveSourceKind,
            sourceLabel: Self.claudePassiveSourceLabel,
            rateWindowLabels: ["primary": "5 小时", "secondary": "每周"],
            usage: AccountPoolUsageBody(
                accountEmail: email,
                identity: AccountPoolUsageIdentity(accountEmail: email, loginMethod: loginMethod),
                loginMethod: loginMethod,
                updatedAt: Self.formatRFC3339UTCSeconds(fetchedAt),
                primary: primary,
                secondary: secondary
            )
        )
    }

    private func buildCodexRow(account: AccountRecord, snapshot: QuotaSnapshot?) -> AccountPoolProviderRow {
        let email = Self.nonEmptyTrimmed(account.email)
        let effectivePlan = snapshot?.plan ?? account.plan
        let loginMethod = Self.codexLoginMethod(effectivePlan)

        guard let snapshot, case .ready(let fetchedAt, _) = snapshot.status else {
            return AccountPoolProviderRow(
                provider: "codex",
                error: Self.sanitizedStatusError(snapshot?.status),
                usage: AccountPoolUsageBody(accountEmail: email, loginMethod: loginMethod)
            )
        }

        var primary: AccountPoolRateWindow?
        var secondary: AccountPoolRateWindow?
        var tertiary: AccountPoolRateWindow?
        var extras: [AccountPoolExtraRateWindow] = []

        for w in snapshot.windows {
            let mapped = Self.toRateWindow(w)
            if w.id == "5h" || (w.windowSeconds == 18_000 && !w.id.hasPrefix("code_review_") && !w.id.hasPrefix("add_")) {
                if primary == nil { primary = mapped }
            } else if w.id == "weekly" || (w.windowSeconds == 604_800 && !w.id.hasPrefix("code_review_") && !w.id.hasPrefix("add_")) {
                if secondary == nil { secondary = mapped }
            } else if w.id.hasPrefix("code_review_") {
                if tertiary == nil { tertiary = mapped }
            } else {
                let safeTitle = Self.sanitizeSafeText(w.label) ?? w.id
                extras.append(AccountPoolExtraRateWindow(id: Self.sanitizeSafeText(w.id) ?? "extra", title: safeTitle, window: mapped))
            }
        }

        // Preserve Codex credits & reset credits including explicit `0` (GAP 1).
        let meta = CodexProvider.latestCreditMetadata(for: account.id)
        let credits: AccountPoolCredits?
        if let meta, let rem = meta.creditsRemaining {
            credits = AccountPoolCredits(remaining: rem, balanceReadSucceeded: meta.creditsReadSucceeded ?? true)
        } else if let bal = snapshot.balance {
            credits = AccountPoolCredits(remaining: bal.totalBalance, balanceReadSucceeded: true)
        } else {
            credits = nil
        }

        let resetCredits: AccountPoolResetCredits?
        if let meta, let avail = meta.resetCreditsAvailable {
            resetCredits = AccountPoolResetCredits(available: max(0, avail))
        } else if let parsedCount = Self.parseCodexResetCount(from: snapshot.paceNote) {
            resetCredits = AccountPoolResetCredits(available: parsedCount)
        } else {
            resetCredits = nil
        }

        return AccountPoolProviderRow(
            provider: "codex",
            rateWindowLabels: ["primary": "5 小时", "secondary": "每周", "tertiary": "代码审查"],
            credits: credits,
            resetCredits: resetCredits,
            usage: AccountPoolUsageBody(
                accountEmail: email,
                loginMethod: loginMethod,
                updatedAt: Self.formatRFC3339UTCSeconds(fetchedAt),
                primary: primary,
                secondary: secondary,
                tertiary: tertiary,
                extraRateWindows: extras.isEmpty ? nil : extras
            )
        )
    }

    private func buildCursorRow(account: AccountRecord, snapshot: QuotaSnapshot?) -> AccountPoolProviderRow {
        let email = Self.nonEmptyTrimmed(account.email)
        let effectivePlan = snapshot?.plan ?? account.plan
        let loginMethod = Self.cursorLoginMethod(effectivePlan)

        guard let snapshot, case .ready(let fetchedAt, _) = snapshot.status else {
            return AccountPoolProviderRow(
                provider: "cursor",
                error: Self.sanitizedStatusError(snapshot?.status),
                usage: AccountPoolUsageBody(accountEmail: email, loginMethod: loginMethod)
            )
        }

        var primary: AccountPoolRateWindow?
        var secondary: AccountPoolRateWindow?
        var tertiary: AccountPoolRateWindow?
        var extras: [AccountPoolExtraRateWindow] = []

        for w in snapshot.windows {
            let mapped = Self.toRateWindow(w)
            switch w.id {
            case "cursor-plan", "cursor-overall", "cursor-unified", "cursor-legacy-requests":
                if primary == nil { primary = mapped }
            case "cursor-auto":
                if secondary == nil { secondary = mapped }
            case "cursor-api":
                if tertiary == nil { tertiary = mapped }
            case "cursor-grok-bot":
                extras.append(AccountPoolExtraRateWindow(id: "cursor-grok-bot", title: "Grok Bot", window: mapped))
            case "cursor-ondemand":
                extras.append(AccountPoolExtraRateWindow(id: "cursor-ondemand", title: "On-Demand", window: mapped))
            case "cursor-team-pooled":
                extras.append(AccountPoolExtraRateWindow(id: "cursor-team-pooled", title: "Team Pooled", window: mapped))
            case "cursor-team-ondemand":
                extras.append(AccountPoolExtraRateWindow(id: "cursor-team-ondemand", title: "Team On-Demand", window: mapped))
            default:
                if primary == nil && w.isPrimary {
                    primary = mapped
                } else if let safeId = Self.sanitizeSafeText(w.id) {
                    let safeTitle = Self.sanitizeSafeText(w.label) ?? safeId
                    extras.append(AccountPoolExtraRateWindow(id: safeId, title: safeTitle, window: mapped))
                }
            }
        }

        return AccountPoolProviderRow(
            provider: "cursor",
            usage: AccountPoolUsageBody(
                accountEmail: email,
                loginMethod: loginMethod,
                updatedAt: Self.formatRFC3339UTCSeconds(fetchedAt),
                primary: primary,
                secondary: secondary,
                tertiary: tertiary,
                extraRateWindows: extras.isEmpty ? nil : extras
            )
        )
    }

    private func buildGrokRow(account: AccountRecord, snapshot: QuotaSnapshot?) -> AccountPoolProviderRow {
        let email = Self.nonEmptyTrimmed(account.email)
        let effectivePlan = snapshot?.plan ?? account.plan
        let loginMethod = Self.grokLoginMethod(effectivePlan)

        guard let snapshot, case .ready(let fetchedAt, _) = snapshot.status else {
            return AccountPoolProviderRow(
                provider: "grok",
                error: Self.sanitizedStatusError(snapshot?.status),
                usage: AccountPoolUsageBody(accountEmail: email, loginMethod: loginMethod)
            )
        }

        let primaryWin = snapshot.windows.first(where: { $0.id == "grok-credits" }) ?? snapshot.windows.first
        let primary = primaryWin.map { Self.toRateWindow($0, defaultWindowMinutes: 10_080) }

        return AccountPoolProviderRow(
            provider: "grok",
            usage: AccountPoolUsageBody(
                accountEmail: email,
                loginMethod: loginMethod,
                updatedAt: Self.formatRFC3339UTCSeconds(fetchedAt),
                primary: primary
            )
        )
    }

    private func buildDeepSeekRow(account: AccountRecord, snapshot: QuotaSnapshot?) -> AccountPoolProviderRow {
        // Dynamic identity from registry (`account.email` fallback `account.displayName`) per #51 so hash
        // strictly preserves production `deepseek-43b3a1e1f7b183ba0e65e442`.
        let dsIdentity = Self.nonEmptyTrimmed(account.email) ?? Self.nonEmptyTrimmed(account.displayName)

        guard let snapshot, case .ready(let fetchedAt, _) = snapshot.status else {
            return AccountPoolProviderRow(
                provider: "deepseek",
                account: dsIdentity,
                error: Self.sanitizedStatusError(snapshot?.status),
                usage: AccountPoolUsageBody()
            )
        }

        let primaryWindow: AccountPoolRateWindow?
        if let bal = snapshot.balance {
            let symbol = (bal.currency.uppercased() == "USD") ? "$" : "¥"
            let totalStr = String(format: "%.2f", bal.totalBalance)
            let desc: String
            if let paid = bal.toppedUpBalance, let granted = bal.grantedBalance {
                desc = "\(symbol)\(totalStr) (Paid: \(symbol)\(String(format: "%.2f", paid)) / Granted: \(symbol)\(String(format: "%.2f", granted)))"
            } else {
                desc = "\(symbol)\(totalStr)"
            }
            primaryWindow = AccountPoolRateWindow(usedPercent: 0.0, resetDescription: desc)
        } else {
            primaryWindow = nil
        }

        return AccountPoolProviderRow(
            provider: "deepseek",
            account: dsIdentity,
            usage: AccountPoolUsageBody(
                updatedAt: Self.formatRFC3339UTCSeconds(fetchedAt),
                primary: primaryWindow
            )
        )
    }

    private func buildKimiRow(account: AccountRecord, snapshot: QuotaSnapshot?) -> AccountPoolProviderRow {
        // CRITICAL (#43): Only emit `accountEmail` if Kimi has a real `@` email; otherwise omit
        // `accountEmail` / `account` / `accountId` so `collect.py` hashes `"unidentified"` ->
        // `kimi-39887a4032b2e91df15f6e3a` (100% production parity!).
        let trimmedEmail = account.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let realEmail: String? = trimmedEmail.contains("@") ? trimmedEmail : nil
        let effectivePlan = snapshot?.plan ?? account.plan
        let loginMethod = Self.sanitizeSafeText(effectivePlan?.displayName)

        guard let snapshot, case .ready(let fetchedAt, _) = snapshot.status else {
            return AccountPoolProviderRow(
                provider: "kimi",
                error: Self.sanitizedStatusError(snapshot?.status),
                usage: AccountPoolUsageBody(
                    accountEmail: realEmail,
                    identity: AccountPoolUsageIdentity(accountEmail: realEmail, loginMethod: loginMethod)
                )
            )
        }

        var primary: AccountPoolRateWindow?
        var secondary: AccountPoolRateWindow?
        var extras: [AccountPoolExtraRateWindow] = []
        var labels: [String: String] = [:]

        for w in snapshot.windows {
            if w.id == "kimi-limit-18000" || w.windowSeconds == 18_000 || w.label.contains("5小时") {
                if secondary == nil {
                    secondary = Self.toRateWindow(w, defaultWindowMinutes: 300)
                    labels["secondary"] = "5 小时"
                }
            } else if w.id == "kimi-monthly" || w.id == "kimi-usage" || (w.windowSeconds ?? 0) > 660_000 {
                if !extras.contains(where: { $0.id == "kimi-monthly" }) {
                    extras.append(
                        AccountPoolExtraRateWindow(
                            id: "kimi-monthly",
                            title: "月度总额度",
                            window: Self.toRateWindow(w, defaultWindowMinutes: 43_200)
                        )
                    )
                }
            } else if w.id == "kimi-code-7d"
                || (w.id.hasPrefix("kimi-limit-") && (550_000...660_000).contains(w.windowSeconds ?? 0)) {
                if !extras.contains(where: { $0.id == "kimi-code-7d" }) {
                    extras.append(
                        AccountPoolExtraRateWindow(
                            id: "kimi-code-7d",
                            title: "代码 7 天",
                            window: Self.toRateWindow(w, defaultWindowMinutes: 10_080)
                        )
                    )
                }
            } else if w.id == "kimi-weekly" {
                if primary == nil {
                    primary = Self.toRateWindow(w, defaultWindowMinutes: 10_080)
                    labels["primary"] = "每周"
                }
            }
        }

        return AccountPoolProviderRow(
            provider: "kimi",
            rateWindowLabels: labels.isEmpty ? nil : labels,
            usage: AccountPoolUsageBody(
                accountEmail: realEmail,
                identity: AccountPoolUsageIdentity(accountEmail: realEmail, loginMethod: loginMethod),
                updatedAt: Self.formatRFC3339UTCSeconds(fetchedAt),
                primary: primary,
                secondary: secondary,
                extraRateWindows: extras.isEmpty ? nil : extras
            )
        )
    }

    private func buildAntigravityRow(account: AccountRecord, snapshot: QuotaSnapshot?) -> AccountPoolProviderRow {
        let email = Self.nonEmptyTrimmed(account.email)
        let effectivePlan = snapshot?.plan ?? account.plan
        let loginMethod = Self.sanitizeSafeText(effectivePlan?.displayName)

        guard let snapshot, case .ready(let fetchedAt, _) = snapshot.status else {
            return AccountPoolProviderRow(
                provider: "antigravity",
                error: Self.sanitizedStatusError(snapshot?.status),
                usage: AccountPoolUsageBody(accountEmail: email, loginMethod: loginMethod)
            )
        }

        var extras: [AccountPoolExtraRateWindow] = []
        var seenIds = Set<String>()

        for w in snapshot.windows {
            guard let (groupSlug, groupTitle, periodSlug, defaultMins) = Self.classifyAntigravityWindow(w) else {
                continue
            }
            let exportId = "antigravity-quota-summary-\(groupSlug)-\(periodSlug)"
            guard seenIds.insert(exportId).inserted else { continue }
            extras.append(
                AccountPoolExtraRateWindow(
                    id: exportId,
                    title: "\(groupTitle) \(periodSlug)",
                    window: Self.toRateWindow(w, defaultWindowMinutes: defaultMins)
                )
            )
        }

        return AccountPoolProviderRow(
            provider: "antigravity",
            usage: AccountPoolUsageBody(
                accountEmail: email,
                loginMethod: loginMethod,
                updatedAt: Self.formatRFC3339UTCSeconds(fetchedAt),
                extraRateWindows: extras.isEmpty ? nil : extras
            )
        )
    }

    private static func classifyAntigravityWindow(_ w: QuotaWindow) -> (groupSlug: String, groupTitle: String, periodSlug: String, windowMinutes: Int)? {
        let idLower = w.id.lowercased()
        let groupSlug: String
        let groupTitle: String
        if idLower.hasPrefix("gemini") {
            groupSlug = "gemini"
            groupTitle = "Gemini"
        } else if idLower.hasPrefix("claude_gpt") || idLower.hasPrefix("3p") || idLower.contains("claude") || idLower.contains("gpt") {
            groupSlug = "3p"
            groupTitle = "Claude"
        } else if idLower.hasPrefix("argon") {
            groupSlug = "argon"
            groupTitle = "Argon"
        } else {
            return nil
        }

        let isFiveHour: Bool
        if idLower.hasSuffix("_5h") || idLower.hasSuffix("-5h") {
            isFiveHour = true
        } else if idLower.hasSuffix("_weekly") || idLower.hasSuffix("-weekly") {
            isFiveHour = false
        } else if let secs = w.windowSeconds {
            isFiveHour = secs <= 36_000
        } else {
            isFiveHour = (groupSlug != "argon") && w.label.contains("5")
        }

        return isFiveHour
            ? (groupSlug, groupTitle, "5h", 300)
            : (groupSlug, groupTitle, "weekly", 10_080)
    }

    // MARK: - Formatting & Sanitization Helpers

    private func sortedAccounts(for provider: ProviderID, in registry: RegistryData) -> [AccountRecord] {
        let list = registry.accounts(for: provider)
        guard provider.supportsMultiAccount else { return list }
        return list.sorted { lhs, rhs in
            if lhs.isActiveLive != rhs.isActiveLive { return lhs.isActiveLive }
            if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func matchCachedRow(
        for account: AccountRecord,
        provider: ProviderID,
        in rows: [AccountPoolProviderRow]
    ) -> AccountPoolProviderRow? {
        let accountId = account.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !accountId.isEmpty {
            if let hit = rows.first(where: {
                ($0.accountId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == accountId
            }) {
                return hit
            }
        }
        let email = account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !email.isEmpty && email.contains("@") {
            if let hit = rows.first(where: {
                let rowEmail = ($0.usage?.accountEmail ?? $0.usage?.identity?.accountEmail ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                return rowEmail == email
            }) {
                return hit
            }
        }
        if provider == .deepseek {
            let ident = (Self.nonEmptyTrimmed(account.email) ?? Self.nonEmptyTrimmed(account.displayName))?.lowercased()
            if let ident, let hit = rows.first(where: { ($0.account ?? "").lowercased() == ident }) {
                return hit
            }
        }
        if !provider.supportsMultiAccount && rows.count == 1 {
            return rows[0]
        }
        return nil
    }

    private static func toRateWindow(_ w: QuotaWindow, defaultWindowMinutes: Int? = nil) -> AccountPoolRateWindow {
        let used = (w.computedUsedPercent * 100.0).rounded() / 100.0
        let clampedUsed = min(max(used, 0.0), 100.0)
        let mins = w.windowSeconds.map { max(1, $0 / 60) } ?? defaultWindowMinutes
        let resetsAt = w.resetAt.map { formatRFC3339UTCSeconds($0) }
        return AccountPoolRateWindow(
            usedPercent: clampedUsed,
            windowMinutes: mins,
            resetsAt: resetsAt,
            resetDescription: nil
        )
    }

    private static func codexLoginMethod(_ plan: PlanInfo?) -> String? {
        guard let plan else { return nil }
        switch plan.kind {
        case .prolite: return "Pro 100"
        case .pro: return "Pro 200"
        case .plus: return "Plus"
        case .team: return "Team"
        case .business: return "Business"
        case .enterprise: return "Enterprise"
        case .free: return "Free"
        default: return sanitizeSafeText(plan.displayName)
        }
    }

    private static func cursorLoginMethod(_ plan: PlanInfo?) -> String? {
        guard let plan else { return nil }
        switch plan.kind {
        case .ultra: return "Cursor Ultra"
        case .pro: return "Cursor Pro"
        case .prolite: return "Cursor Pro Lite"
        case .business, .team: return "Cursor Business"
        case .enterprise: return "Cursor Enterprise"
        case .free: return "Cursor Free"
        default: return sanitizeSafeText(plan.displayName)
        }
    }

    private static func grokLoginMethod(_ plan: PlanInfo?) -> String? {
        guard let plan else { return nil }
        let clean = sanitizeSafeText(plan.displayName) ?? plan.kind.defaultDisplayName
        if clean.lowercased().contains("grok") {
            return clean
        }
        switch plan.kind {
        case .ultra, .max: return "SuperGrok Heavy"
        case .pro, .plus: return "SuperGrok"
        case .free: return "Grok Free"
        default: return clean
        }
    }

    private static func sanitizedStatusError(_ status: QuotaStatus?) -> String {
        guard let status else { return "unavailable" }
        switch status {
        case .reauthRequired:
            return "unauthorized: auth required"
        case .unconfigured:
            return "unconfigured"
        case .failed:
            return "fetch_failed"
        case .loading:
            return "loading"
        case .ready:
            return "ok"
        }
    }

    /// Sanitizes text to strictly pass `collect.py:safe_text()` regex `[\w .+/()×%\-\u4e00-\u9fff]+`
    /// (notably replacing middle dot `·` U+00B7 with `/` and rejecting secrets/long tokens).
    public static func sanitizeSafeText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var cleaned = raw
            .replacingOccurrences(of: " · ", with: " / ")
            .replacingOccurrences(of: "·", with: "/")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        guard !cleaned.isEmpty, cleaned.count <= 64 else { return nil }
        let lower = cleaned.lowercased()
        if lower.contains("@") || lower.contains("sk-") || lower.contains("bearer ") || lower.contains("cookie") || lower.contains("token") || lower.contains("secret") || cleaned.contains("eyJ") {
            return nil
        }
        return cleaned
    }

    private static func nonEmptyTrimmed(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func isNumericGoogleSub(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 32 else { return false }
        return id.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func parseCodexResetCount(from paceNote: String?) -> Int? {
        guard let paceNote, let range = paceNote.range(of: "可用重置次数:") else { return nil }
        let rest = paceNote[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let digits = rest.prefix(while: { $0.isNumber })
        return Int(digits)
    }

    private static func formatRFC3339UTCSeconds(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
