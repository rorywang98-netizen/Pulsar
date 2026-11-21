import CFNetwork
import CryptoKit
import Foundation

// MARK: - Provider Identification & Capabilities

public enum ProviderID: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case antigravity
    case codex
    case grok
    case cursor
    case kimi
    case deepseek

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .cursor: return "Cursor"
        case .kimi: return "Kimi"
        case .deepseek: return "DeepSeek"
        }
    }

    public var shortName: String {
        switch self {
        case .antigravity: return "AGY"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .cursor: return "Cursor"
        case .kimi: return "Kimi"
        case .deepseek: return "DS"
        }
    }

    public var symbolName: String {
        switch self {
        case .antigravity: return "sparkles"
        case .codex: return "terminal.fill"
        case .grok: return "bolt.fill"
        case .cursor: return "cursorarrow.rays"
        case .kimi: return "moon.stars.fill"
        case .deepseek: return "waveform.path.ecg"
        }
    }

    public var defaultMenuOrder: Int {
        switch self {
        case .antigravity: return 0
        case .codex: return 1
        case .grok: return 2
        case .cursor: return 3
        case .kimi: return 4
        case .deepseek: return 5
        }
    }

    public var supportsAccountSwitch: Bool {
        switch self {
        case .antigravity, .codex:
            return true
        case .grok, .cursor, .kimi, .deepseek:
            return false
        }
    }

    public var supportsLocalRPC: Bool {
        self == .antigravity
    }

    public var supportsAPIKeyConfig: Bool {
        switch self {
        case .kimi, .deepseek:
            return true
        case .antigravity, .codex, .grok, .cursor:
            return false
        }
    }
}

/// Alias matching Phase 2 UI/metrics naming while keeping canonical `ProviderID` intact.
public typealias ProviderKind = ProviderID

public struct ProviderCapability: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let quota         = ProviderCapability(rawValue: 1 << 0)
    public static let accountSwitch = ProviderCapability(rawValue: 1 << 1)
    public static let localRPC      = ProviderCapability(rawValue: 1 << 2)
    public static let apiKeyConfig  = ProviderCapability(rawValue: 1 << 3)
    public static let clientControl = ProviderCapability(rawValue: 1 << 4)
}

// MARK: - Transport Policy & HTTP Factory

public enum TransportPolicy: Equatable, Hashable, Sendable {
    /// Inherit macOS system proxy settings (e.g. FlClash) on an ephemeral session.
    case systemProxy
    /// Strict fail-closed loopback proxy (HTTP/HTTPS/SOCKS pinned to loopback with PAC/auto-discovery/exceptions disabled).
    /// Reserved for isolated adapters that must never fall back to direct egress.
    case failClosedLoopbackProxy(host: String, port: Int)

    public static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "127.0.0.1" || normalized == "localhost" || normalized == "::1"
    }
}

public enum HTTPFactory {
    public static func makeConfiguration(
        policy: TransportPolicy = .systemProxy,
        timeout: TimeInterval = 20.0
    ) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        let clampedTimeout = max(1.0, timeout)
        config.timeoutIntervalForRequest = clampedTimeout
        config.timeoutIntervalForResource = max(clampedTimeout * 2.0, 30.0)
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false

        switch policy {
        case .systemProxy:
            // Leave connectionProxyDictionary nil so URLSession inherits macOS system proxy.
            config.connectionProxyDictionary = nil

        case .failClosedLoopbackProxy(let rawHost, let rawPort):
            // Fail closed if caller supplies non-loopback host or invalid port: route to discard port on loopback.
            let validHost = TransportPolicy.isLoopbackHost(rawHost)
            let validPort = (1...65535).contains(rawPort)
            let host = validHost ? rawHost.trimmingCharacters(in: .whitespacesAndNewlines) : "127.0.0.1"
            let port = (validHost && validPort) ? rawPort : 9

            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port,
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: host,
                kCFNetworkProxiesSOCKSPort as String: port,
                kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
                kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 0,
                kCFNetworkProxiesExcludeSimpleHostnames as String: 0,
                kCFNetworkProxiesExceptionsList as String: [String](),
            ]
        }

        return config
    }

    public static func makeSession(
        policy: TransportPolicy = .systemProxy,
        timeout: TimeInterval = 20.0
    ) -> URLSession {
        URLSession(configuration: makeConfiguration(policy: policy, timeout: timeout))
    }
}

// MARK: - Plan, Quota & Balance Models

public enum PlanKind: String, Codable, Equatable, Hashable, Sendable {
    case free
    case plus
    case pro
    case prolite
    case ultra
    case max
    case team
    case business
    case enterprise
    case api
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = PlanKind.parse(raw)
    }

    public static func parse(_ raw: String?) -> PlanKind {
        guard let raw else { return .unknown }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return .unknown }
        if let direct = PlanKind(rawValue: s) {
            return direct
        }
        let compact = s.replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        if let directCompact = PlanKind(rawValue: compact) {
            return directCompact
        }
        if compact.contains("prolite") { return .prolite }
        if compact.contains("ultra") { return .ultra }
        if compact.contains("enterprise") { return .enterprise }
        if compact.contains("business") { return .business }
        if compact.contains("team") { return .team }
        if compact.contains("plus") { return .plus }
        if compact.contains("max") { return .max }
        if compact.contains("pro") { return .pro }
        if compact.contains("free") { return .free }
        if compact.contains("api") || compact.contains("payg") { return .api }
        return .unknown
    }

    public var defaultDisplayName: String {
        switch self {
        case .free: return "Free"
        case .plus: return "Plus"
        case .pro: return "Pro"
        case .prolite: return "Pro Lite"
        case .ultra: return "Ultra"
        case .max: return "Max"
        case .team: return "Team"
        case .business: return "Business"
        case .enterprise: return "Enterprise"
        case .api: return "API"
        case .unknown: return "Unknown"
        }
    }
}

public struct PlanInfo: Codable, Equatable, Hashable, Sendable {
    public var kind: PlanKind
    public var displayName: String

    public init(kind: PlanKind, displayName: String? = nil) {
        self.kind = kind
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.displayName = trimmed.isEmpty ? kind.defaultDisplayName : trimmed
    }

    public static func normalized(kindRaw: String?, name: String?) -> PlanInfo? {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedKind = kindRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedName.isEmpty && trimmedKind.isEmpty {
            return nil
        }
        var kind = PlanKind.parse(trimmedKind)
        if kind == .unknown && !trimmedName.isEmpty {
            kind = PlanKind.parse(trimmedName)
        }
        let display: String
        if !trimmedName.isEmpty {
            display = (trimmedName.lowercased() == "prolite") ? "Pro Lite" : trimmedName
        } else {
            display = kind.defaultDisplayName
        }
        return PlanInfo(kind: kind, displayName: display)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case displayName
        case name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind)
        let rawDisplay = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? container.decodeIfPresent(String.self, forKey: .name)
        let resolved = PlanInfo.normalized(kindRaw: rawKind, name: rawDisplay)
            ?? PlanInfo(kind: .unknown, displayName: "Unknown")
        self.kind = resolved.kind
        self.displayName = resolved.displayName
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(displayName, forKey: .displayName)
    }
}

public enum QuotaWindowCadence: Int, Codable, Equatable, Hashable, Sendable {
    case fiveHour = 0
    case daily = 1
    case weekly = 2
    case monthly = 3
    case other = 4
}

public struct QuotaWindow: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var remainingFraction: Double
    public var usedPercent: Double?
    public var resetAt: Date?
    public var windowSeconds: Int?
    public var detail: String?
    public var isPrimary: Bool

    public init(
        id: String,
        label: String,
        remainingFraction: Double,
        usedPercent: Double? = nil,
        resetAt: Date? = nil,
        windowSeconds: Int? = nil,
        detail: String? = nil,
        isPrimary: Bool = false
    ) {
        self.id = id
        self.label = label
        self.remainingFraction = min(max(remainingFraction, 0.0), 1.0)
        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.windowSeconds = windowSeconds
        self.detail = detail
        self.isPrimary = isPrimary
    }

    public var remainingPercent: Int {
        Formatters.remainingPercentInt(remainingFraction)
    }

    public var computedUsedPercent: Double {
        if let usedPercent {
            return min(max(usedPercent, 0.0), 100.0)
        }
        return min(max((1.0 - remainingFraction) * 100.0, 0.0), 100.0)
    }

    public var isExhausted: Bool {
        remainingFraction <= 0.0001
    }

    public var cadence: QuotaWindowCadence {
        if let seconds = windowSeconds, seconds > 0 {
            if (14_400...21_600).contains(seconds) {
                return .fiveHour
            }
            if (80_000...92_000).contains(seconds) {
                return .daily
            }
            if (500_000...700_000).contains(seconds) {
                return .weekly
            }
            if (2_400_000...2_800_000).contains(seconds) {
                return .monthly
            }
        }

        let labelLower = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let idLower = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if labelLower.contains("5小时") || labelLower.contains("5 小时")
            || idLower == "5h" || idLower.hasSuffix("_5h") || idLower.hasSuffix("-5h")
            || labelLower == "5h" || labelLower.hasSuffix(" 5h") || labelLower.hasSuffix("· 5h") {
            return .fiveHour
        }
        if labelLower.contains("本周") || labelLower.contains("每周") || labelLower.contains("周额")
            || labelLower.contains("周限") || labelLower.contains("7天")
            || labelLower.hasSuffix("· 周") || labelLower.hasSuffix(" 周") || labelLower == "周"
            || idLower.contains("weekly") || idLower == "week" || idLower == "7d"
            || idLower.hasSuffix("_week") || idLower.hasSuffix("-week")
            || idLower.hasSuffix("_7d") || idLower.hasSuffix("-7d") {
            return .weekly
        }
        if labelLower.contains("每日") || labelLower.contains("24小时") || labelLower.contains("1天")
            || idLower.contains("daily") || idLower.hasSuffix("_1d") || idLower.hasSuffix("-1d") {
            return .daily
        }
        if labelLower.contains("每月") || labelLower.contains("本月") || labelLower.contains("月额")
            || labelLower.contains("30天") || idLower.contains("monthly") {
            return .monthly
        }
        return .other
    }

    /// Identifies the Antigravity model pool for a quota window (`gemini`, `claude`, `argon`), or `nil` for non-Antigravity/unclassified pools.
    public var antigravityPoolKind: AntigravityPoolPreference? {
        let idLower = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let labelLower = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if idLower == "argon" || idLower.hasPrefix("argon_") || idLower.hasPrefix("argon-") || labelLower.contains("argon") {
            return .argon
        }
        if idLower == "gemini" || idLower.hasPrefix("gemini_") || idLower.hasPrefix("gemini-") || labelLower.contains("gemini") {
            return .gemini
        }
        if idLower.hasPrefix("claude") || idLower.contains("3p") || idLower.contains("partner")
            || labelLower.contains("claude") || labelLower.contains("gpt") {
            return .claude
        }
        return nil
    }
}

public struct BalanceInfo: Codable, Equatable, Hashable, Sendable {
    public var currency: String
    public var totalBalance: Double
    public var grantedBalance: Double?
    public var toppedUpBalance: Double?
    public var detail: String?

    public init(
        currency: String,
        totalBalance: Double,
        grantedBalance: Double? = nil,
        toppedUpBalance: Double? = nil,
        detail: String? = nil
    ) {
        self.currency = currency
        self.totalBalance = totalBalance
        self.grantedBalance = grantedBalance
        self.toppedUpBalance = toppedUpBalance
        self.detail = detail
    }

    public var formattedTotal: String {
        Formatters.currencyString(amount: totalBalance, currency: currency)
    }
}

public enum QuotaStatus: Codable, Equatable, Hashable, Sendable {
    case loading
    case ready(fetchedAt: Date, stale: Bool)
    case reauthRequired(String)
    case unconfigured(String)
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var isStale: Bool {
        if case .ready(_, let stale) = self { return stale }
        return false
    }

    public var isError: Bool {
        switch self {
        case .reauthRequired, .failed:
            return true
        case .loading, .ready, .unconfigured:
            return false
        }
    }

    public var fetchedAt: Date? {
        if case .ready(let fetchedAt, _) = self { return fetchedAt }
        return nil
    }

    public var message: String? {
        switch self {
        case .reauthRequired(let msg), .unconfigured(let msg), .failed(let msg):
            return msg
        case .loading, .ready:
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case fetchedAt
        case stale
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "loading":
            self = .loading
        case "ready":
            let fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
            let stale = try container.decodeIfPresent(Bool.self, forKey: .stale) ?? false
            self = .ready(fetchedAt: fetchedAt, stale: stale)
        case "reauthRequired":
            let msg = try container.decodeIfPresent(String.self, forKey: .message) ?? "需要重新登录"
            self = .reauthRequired(msg)
        case "unconfigured":
            let msg = try container.decodeIfPresent(String.self, forKey: .message) ?? "未配置"
            self = .unconfigured(msg)
        default:
            let msg = try container.decodeIfPresent(String.self, forKey: .message) ?? "请求失败"
            self = .failed(msg)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .loading:
            try container.encode("loading", forKey: .kind)
        case .ready(let fetchedAt, let stale):
            try container.encode("ready", forKey: .kind)
            try container.encode(fetchedAt, forKey: .fetchedAt)
            try container.encode(stale, forKey: .stale)
        case .reauthRequired(let msg):
            try container.encode("reauthRequired", forKey: .kind)
            try container.encode(msg, forKey: .message)
        case .unconfigured(let msg):
            try container.encode("unconfigured", forKey: .kind)
            try container.encode(msg, forKey: .message)
        case .failed(let msg):
            try container.encode("failed", forKey: .kind)
            try container.encode(msg, forKey: .message)
        }
    }
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public var provider: ProviderID
    public var accountId: String
    public var plan: PlanInfo?
    public var windows: [QuotaWindow]
    public var balance: BalanceInfo?
    public var status: QuotaStatus
    public var sourceLabel: String
    public var primaryRemainingPercent: Int?
    public var paceNote: String?

    public init(
        provider: ProviderID,
        accountId: String,
        plan: PlanInfo? = nil,
        windows: [QuotaWindow] = [],
        balance: BalanceInfo? = nil,
        status: QuotaStatus,
        sourceLabel: String = "",
        primaryRemainingPercent: Int? = nil,
        paceNote: String? = nil
    ) {
        self.provider = provider
        self.accountId = accountId
        self.plan = plan
        self.windows = windows
        self.balance = balance
        self.status = status
        self.sourceLabel = sourceLabel
        if let explicit = primaryRemainingPercent {
            self.primaryRemainingPercent = min(max(explicit, 0), 100)
        } else if let primary = windows.first(where: { $0.isPrimary }) ?? windows.first {
            self.primaryRemainingPercent = primary.remainingPercent
        } else {
            self.primaryRemainingPercent = nil
        }
        self.paceNote = paceNote
    }

    public static func loading(provider: ProviderID, accountId: String) -> QuotaSnapshot {
        QuotaSnapshot(provider: provider, accountId: accountId, status: .loading, sourceLabel: "")
    }

    public static func unconfigured(
        provider: ProviderID,
        accountId: String,
        sourceLabel: String = "",
        message: String
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            accountId: accountId,
            status: .unconfigured(message),
            sourceLabel: sourceLabel
        )
    }

    public static func reauthRequired(
        provider: ProviderID,
        accountId: String,
        sourceLabel: String = "",
        message: String
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            accountId: accountId,
            status: .reauthRequired(message),
            sourceLabel: sourceLabel
        )
    }

    public static func failed(
        provider: ProviderID,
        accountId: String,
        sourceLabel: String = "",
        message: String
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            accountId: accountId,
            status: .failed(message),
            sourceLabel: sourceLabel
        )
    }
}

// MARK: - Accounts, Processes & Switch Results

public struct AccountRecord: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var provider: ProviderID
    public var email: String
    public var displayName: String
    public var plan: PlanInfo?
    public var addedAt: Date
    public var isActiveLive: Bool
    /// Transient runtime badge computed against current snapshots (not persisted to registry.json).
    public var isBestRemaining: Bool
    public var avatarURL: String?

    public init(
        id: String,
        provider: ProviderID,
        email: String,
        displayName: String,
        plan: PlanInfo? = nil,
        addedAt: Date = Date(),
        isActiveLive: Bool = false,
        isBestRemaining: Bool = false,
        avatarURL: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.email = email
        self.displayName = displayName.isEmpty ? email : displayName
        self.plan = plan
        self.addedAt = addedAt
        self.isActiveLive = isActiveLive
        self.isBestRemaining = isBestRemaining
        self.avatarURL = Formatters.sanitizedHTTPSURLString(avatarURL)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case email
        case displayName
        case plan
        case addedAt
        case isActiveLive
        case avatarURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.provider = try container.decode(ProviderID.self, forKey: .provider)
        self.email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        let rawDisplay = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        self.displayName = rawDisplay.isEmpty ? self.email : rawDisplay
        self.plan = try container.decodeIfPresent(PlanInfo.self, forKey: .plan)
        self.addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        self.isActiveLive = try container.decodeIfPresent(Bool.self, forKey: .isActiveLive) ?? false
        self.isBestRemaining = false
        let rawAvatar = try container.decodeIfPresent(String.self, forKey: .avatarURL)
        self.avatarURL = Formatters.sanitizedHTTPSURLString(rawAvatar)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(email, forKey: .email)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(plan, forKey: .plan)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encode(isActiveLive, forKey: .isActiveLive)
        try container.encodeIfPresent(avatarURL, forKey: .avatarURL)
    }

    /// Computes the account ID with the highest primary remaining quota among eligible accounts for a provider.
    /// Returns nil when fewer than 2 accounts exist or no ready percentage snapshot is available.
    public static func bestRemainingAccountId(
        for provider: ProviderID,
        accounts: [AccountRecord],
        snapshots: [String: QuotaSnapshot]
    ) -> String? {
        let providerAccounts = accounts.filter { $0.provider == provider }
        guard providerAccounts.count >= 2 else { return nil }

        var bestId: String?
        var bestPct: Int = -1
        for account in providerAccounts {
            guard let snap = snapshots[account.id],
                  snap.status.isReady,
                  let pct = snap.primaryRemainingPercent else {
                continue
            }
            if pct > bestPct {
                bestPct = pct
                bestId = account.id
            }
        }
        return bestPct > 0 ? bestId : nil
    }

    public func computeIsBestRemaining(
        among accounts: [AccountRecord],
        snapshots: [String: QuotaSnapshot]
    ) -> Bool {
        Self.bestRemainingAccountId(for: provider, accounts: accounts, snapshots: snapshots) == id
    }
}

public struct ClientProcessInfo: Equatable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let executablePath: String
    public let bundleId: String?
    public let isInteractiveCLI: Bool

    public init(
        id: Int,
        name: String,
        executablePath: String,
        bundleId: String? = nil,
        isInteractiveCLI: Bool = false
    ) {
        self.id = id
        self.name = name
        self.executablePath = executablePath
        self.bundleId = bundleId
        self.isInteractiveCLI = isInteractiveCLI
    }
}

public struct ClientRuntimeStatus: Equatable, Sendable {
    public var installedApps: [String]
    public var runningProcesses: [ClientProcessInfo]
    public var isRunning: Bool

    public init(
        installedApps: [String] = [],
        runningProcesses: [ClientProcessInfo] = [],
        isRunning: Bool? = nil
    ) {
        self.installedApps = installedApps
        self.runningProcesses = runningProcesses
        self.isRunning = isRunning ?? !runningProcesses.isEmpty
    }

    public static let notInstalled = ClientRuntimeStatus()
}

public enum SwitchResult: Equatable, Sendable {
    case switched(reopenedApps: [String])
    case needsForceQuitConfirmation(surviving: [ClientProcessInfo])
    case failed(String)
}

// MARK: - Settings & Registry Persistence

public enum RefreshCadence: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case manual
    case onMenuOpen
    case every5m
    case every10m
    case every15m

    public var id: String { rawValue }

    public var intervalSeconds: TimeInterval? {
        switch self {
        case .manual, .onMenuOpen: return nil
        case .every5m: return 300
        case .every10m: return 600
        case .every15m: return 900
        }
    }

    public var displayName: String {
        switch self {
        case .manual: return "仅手动"
        case .onMenuOpen: return "打开菜单时"
        case .every5m: return "每 5 分钟"
        case .every10m: return "每 10 分钟"
        case .every15m: return "每 15 分钟"
        }
    }
}

public enum MenuBarDisplayMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case selectedProvider
    case lowestQuota
    case custom
    case compactDots
    case iconOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .selectedProvider: return "当前选中服务"
        case .lowestQuota: return "最低余量优先"
        case .custom: return "自定义组合"
        case .compactDots: return "紧凑状态点"
        case .iconOnly: return "仅图标"
        }
    }
}

public enum MenuBarIconStyle: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case provider
    case pulsar
    case hidden

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .provider: return "跟随服务图标"
        case .pulsar: return "Pulsar 脉冲星"
        case .hidden: return "隐藏图标"
        }
    }
}

public enum CardMoveDirection: Int, Codable, Hashable, Sendable {
    case up = -1
    case down = 1
}

public enum MenuBarQuotaWindow: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case weeklyFirst
    case both5hAndWeekly
    case fiveHourFirst
    case lowest

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .weeklyFirst: return "周额度优先"
        case .both5hAndWeekly: return "5h + 周双显"
        case .fiveHourFirst: return "5 小时优先"
        case .lowest: return "最低短板"
        }
    }

    public var shortName: String {
        switch self {
        case .weeklyFirst: return "周额优先"
        case .both5hAndWeekly: return "5h + 周"
        case .fiveHourFirst: return "5h 优先"
        case .lowest: return "最低短板"
        }
    }

    public var descriptionText: String {
        switch self {
        case .weeklyFirst: return "有周额度优先显示周剩余，无周额度则回退 5 小时或余额"
        case .both5hAndWeekly: return "同时看到 5 小时与周剩余额度（如 49%/99%）"
        case .fiveHourFirst: return "优先显示 5 小时窗口，无 5 小时则回退周额度或余额"
        case .lowest: return "在所有配额窗口中取剩余最低的一项作为预警"
        }
    }
}

public enum MenuBarQuotaDualFormat: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case slash
    case labeled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .slash: return "精简 49%/99%"
        case .labeled: return "带标签 5h49/周99"
        }
    }
}

public enum AntigravityPoolPreference: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case autoLowest
    case gemini
    case claude
    case argon

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .autoLowest: return "最低池"
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        case .argon: return "Argon"
        }
    }
}

public enum MenuBarModule: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case quota
    case quotaFiveHour
    case quotaWeekly
    case tokenRate
    case tokenRate60s
    case todayTokens
    case todayCost
    case activeModel
    case cacheHitRate
    case todayMessages
    case sevenDayTokens
    case thirtyDayCost
    case nextResetCountdown
    case deepseekBalance

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .quota: return "服务配额 / 余额"
        case .quotaFiveHour: return "5 小时额度（独立）"
        case .quotaWeekly: return "周额度（独立）"
        case .tokenRate: return "实时速度 (tok/s)"
        case .tokenRate60s: return "近 60 秒均速"
        case .todayTokens: return "今日 Tokens"
        case .todayCost: return "今日估算费用"
        case .activeModel: return "当前活跃模型"
        case .cacheHitRate: return "今日缓存命中率"
        case .todayMessages: return "今日消息数"
        case .sevenDayTokens: return "近 7 天 Tokens"
        case .thirtyDayCost: return "近 30 天估算费用"
        case .nextResetCountdown: return "最近重置倒计时"
        case .deepseekBalance: return "DeepSeek 余额"
        }
    }

    public var displayName: String { title }

    public var subtitle: String {
        switch self {
        case .quota: return "按配额窗口与来源展示（支持周额/双显/多服务）"
        case .quotaFiveHour: return "独立显示目标服务的 5 小时窗口剩余"
        case .quotaWeekly: return "独立显示目标服务的本周 / 7 天剩余"
        case .tokenRate: return "当前输出或近 60 秒实时生成速度"
        case .tokenRate60s: return "近 60 秒滚动窗口平均速率"
        case .todayTokens: return "今日全客户端累计 Token 总量"
        case .todayCost: return "今日全客户端估算 USD 费用"
        case .activeModel: return "当前正在生成或最近活跃模型简称"
        case .cacheHitRate: return "今日 Prompt Cache 命中占比"
        case .todayMessages: return "今日累计交互消息条数"
        case .sevenDayTokens: return "近 7 天累计 Token 消耗总量"
        case .thirtyDayCost: return "近 30 天累计估算费用"
        case .nextResetCountdown: return "目标服务最近一次配额重置倒计时"
        case .deepseekBalance: return "随时独立常驻展示 DeepSeek 余额"
        }
    }

    public var shortDescription: String {
        switch self {
        case .quota: return "主配额/余额"
        case .quotaFiveHour: return "5h 额度"
        case .quotaWeekly: return "周额度"
        case .tokenRate: return "实时速率"
        case .tokenRate60s: return "60s 均速"
        case .todayTokens: return "今日用量"
        case .todayCost: return "今日费用"
        case .activeModel: return "活跃模型"
        case .cacheHitRate: return "缓存命中"
        case .todayMessages: return "今日消息"
        case .sevenDayTokens: return "7天用量"
        case .thirtyDayCost: return "30天费用"
        case .nextResetCountdown: return "重置倒计时"
        case .deepseekBalance: return "DS 余额"
        }
    }

    public var symbolName: String {
        switch self {
        case .quota: return "gauge.with.dots.needle.67percent"
        case .quotaFiveHour: return "clock.fill"
        case .quotaWeekly: return "calendar.badge.clock"
        case .tokenRate: return "bolt.horizontal.fill"
        case .tokenRate60s: return "speedometer"
        case .todayTokens: return "chart.bar.fill"
        case .todayCost: return "dollarsign.circle.fill"
        case .activeModel: return "cpu"
        case .cacheHitRate: return "memorychip"
        case .todayMessages: return "bubble.left.and.bubble.right.fill"
        case .sevenDayTokens: return "calendar"
        case .thirtyDayCost: return "banknote"
        case .nextResetCountdown: return "hourglass"
        case .deepseekBalance: return "yensign.circle.fill"
        }
    }
}

public enum MenuBarQuotaSource: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case selected
    case lowest
    case fixed
    case multi

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .selected: return "跟随当前选中服务"
        case .lowest: return "最低余量预警"
        case .fixed: return "固定指定服务"
        case .multi: return "多服务并排"
        }
    }
}

public enum MenuBarRateMetric: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case output
    case total

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .output: return "当前输出速度 (tok/s)"
        case .total: return "近 60 秒总吞吐 (tok/s)"
        }
    }
}

public enum MenuBarSeparator: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case dot
    case pipe
    case space

    public var id: String { rawValue }

    public var literal: String {
        switch self {
        case .dot: return " · "
        case .pipe: return " | "
        case .space: return " "
        }
    }

    public var displayName: String {
        switch self {
        case .dot: return "·"
        case .pipe: return "|"
        case .space: return "空格"
        }
    }
}

public struct MenuBarSummary: Equatable, Hashable, Sendable {
    public var title: String
    public var symbol: String
    public var tooltip: String
    public var isWarning: Bool
    public var providerKind: ProviderID?

    public init(
        title: String,
        symbol: String,
        tooltip: String,
        isWarning: Bool = false,
        providerKind: ProviderID? = nil
    ) {
        self.title = title
        self.symbol = symbol
        self.tooltip = tooltip
        self.isWarning = isWarning
        self.providerKind = providerKind
    }
}

public struct ProviderQuotaMetrics: Equatable, Hashable, Sendable {
    public var fiveHourPercent: Double?
    public var weeklyPercent: Double?
    public var lowestPercent: Double?
    public var balanceText: String?
    public var nextReset: Date?
    public var shortPrefix: String
    public var primaryPercent: Double?
    public var isReady: Bool
    public var isError: Bool
    public var isLoading: Bool
    public var isUnconfigured: Bool
    public var isBalanceDepleted: Bool

    public init(
        fiveHourPercent: Double? = nil,
        weeklyPercent: Double? = nil,
        lowestPercent: Double? = nil,
        balanceText: String? = nil,
        nextReset: Date? = nil,
        shortPrefix: String,
        primaryPercent: Double? = nil,
        isReady: Bool = false,
        isError: Bool = false,
        isLoading: Bool = false,
        isUnconfigured: Bool = false,
        isBalanceDepleted: Bool = false
    ) {
        self.fiveHourPercent = fiveHourPercent
        self.weeklyPercent = weeklyPercent
        self.lowestPercent = lowestPercent
        self.balanceText = balanceText
        self.nextReset = nextReset
        self.shortPrefix = shortPrefix
        self.primaryPercent = primaryPercent
        self.isReady = isReady
        self.isError = isError
        self.isLoading = isLoading
        self.isUnconfigured = isUnconfigured
        self.isBalanceDepleted = isBalanceDepleted
    }
}

public struct MenuBarCustomConfig: Codable, Equatable, Hashable, Sendable {
    public static let defaultModules: [MenuBarModule] = [.quota, .tokenRate, .todayTokens]
    public static let defaultMultiProviders: [ProviderID] = [.antigravity, .codex]
    public static let `default` = MenuBarCustomConfig()

    public var iconStyle: MenuBarIconStyle
    public var modules: [MenuBarModule]
    public var quotaSource: MenuBarQuotaSource
    public var fixedQuotaProvider: ProviderID
    public var showProviderPrefix: Bool
    public var rateMetric: MenuBarRateMetric
    public var hideRateWhenIdle: Bool
    public var separator: MenuBarSeparator
    public var quotaWindow: MenuBarQuotaWindow
    public var quotaDualFormat: MenuBarQuotaDualFormat
    public var quotaMultiProviders: [ProviderID]
    public var antigravityPool: AntigravityPoolPreference

    public var enabledModules: [MenuBarModule] {
        get { modules }
        set { modules = Self.deduplicatedModules(newValue) }
    }

    public init(
        iconStyle: MenuBarIconStyle = .provider,
        modules: [MenuBarModule] = MenuBarCustomConfig.defaultModules,
        quotaSource: MenuBarQuotaSource = .selected,
        fixedQuotaProvider: ProviderID = .antigravity,
        showProviderPrefix: Bool = true,
        rateMetric: MenuBarRateMetric = .output,
        hideRateWhenIdle: Bool = false,
        separator: MenuBarSeparator = .dot,
        quotaWindow: MenuBarQuotaWindow = .weeklyFirst,
        quotaDualFormat: MenuBarQuotaDualFormat = .slash,
        quotaMultiProviders: [ProviderID] = MenuBarCustomConfig.defaultMultiProviders,
        antigravityPool: AntigravityPoolPreference = .autoLowest
    ) {
        self.iconStyle = iconStyle
        self.modules = Self.deduplicatedModules(modules)
        self.quotaSource = quotaSource
        self.fixedQuotaProvider = fixedQuotaProvider
        self.showProviderPrefix = showProviderPrefix
        self.rateMetric = rateMetric
        self.hideRateWhenIdle = hideRateWhenIdle
        self.separator = separator
        self.quotaWindow = quotaWindow
        self.quotaDualFormat = quotaDualFormat
        self.quotaMultiProviders = Self.deduplicatedProviders(quotaMultiProviders)
        self.antigravityPool = antigravityPool
    }

    private enum CodingKeys: String, CodingKey {
        case iconStyle
        case modules
        case quotaSource
        case fixedQuotaProvider
        case showProviderPrefix
        case rateMetric
        case hideRateWhenIdle
        case separator
        case quotaWindow
        case quotaDualFormat
        case quotaMultiProviders
        case antigravityPool
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.iconStyle = (try? c.decodeIfPresent(MenuBarIconStyle.self, forKey: .iconStyle)) ?? .provider
        if c.contains(.modules) {
            if let rawStrings = try? c.decode([String].self, forKey: .modules) {
                let valid = rawStrings.compactMap { MenuBarModule(rawValue: $0) }
                self.modules = Self.deduplicatedModules(valid)
            } else if let decodedModules = (try? c.decodeIfPresent([MenuBarModule].self, forKey: .modules)) ?? nil {
                self.modules = Self.deduplicatedModules(decodedModules)
            } else {
                self.modules = Self.defaultModules
            }
        } else {
            self.modules = Self.defaultModules
        }
        self.quotaSource = (try? c.decodeIfPresent(MenuBarQuotaSource.self, forKey: .quotaSource)) ?? .selected
        self.fixedQuotaProvider = (try? c.decodeIfPresent(ProviderID.self, forKey: .fixedQuotaProvider)) ?? .antigravity
        self.showProviderPrefix = try c.decodeIfPresent(Bool.self, forKey: .showProviderPrefix) ?? true
        self.rateMetric = (try? c.decodeIfPresent(MenuBarRateMetric.self, forKey: .rateMetric)) ?? .output
        self.hideRateWhenIdle = try c.decodeIfPresent(Bool.self, forKey: .hideRateWhenIdle) ?? false
        self.separator = (try? c.decodeIfPresent(MenuBarSeparator.self, forKey: .separator)) ?? .dot
        self.quotaWindow = (try? c.decodeIfPresent(MenuBarQuotaWindow.self, forKey: .quotaWindow)) ?? .weeklyFirst
        self.quotaDualFormat = (try? c.decodeIfPresent(MenuBarQuotaDualFormat.self, forKey: .quotaDualFormat)) ?? .slash
        if c.contains(.quotaMultiProviders) {
            if let rawProviders = try? c.decode([String].self, forKey: .quotaMultiProviders) {
                let valid = rawProviders.compactMap { ProviderID(rawValue: $0) }
                self.quotaMultiProviders = Self.deduplicatedProviders(valid)
            } else if let decodedProviders = (try? c.decodeIfPresent([ProviderID].self, forKey: .quotaMultiProviders)) ?? nil {
                self.quotaMultiProviders = Self.deduplicatedProviders(decodedProviders)
            } else {
                self.quotaMultiProviders = Self.defaultMultiProviders
            }
        } else {
            self.quotaMultiProviders = Self.defaultMultiProviders
        }
        self.antigravityPool = (try? c.decodeIfPresent(AntigravityPoolPreference.self, forKey: .antigravityPool)) ?? .autoLowest
    }

    public static func deduplicatedModules(_ raw: [MenuBarModule]) -> [MenuBarModule] {
        var seen = Set<MenuBarModule>()
        var result: [MenuBarModule] = []
        for module in raw where seen.insert(module).inserted {
            result.append(module)
        }
        return result
    }

    public static func deduplicatedProviders(_ raw: [ProviderID]) -> [ProviderID] {
        var seen = Set<ProviderID>()
        var result: [ProviderID] = []
        for provider in raw where seen.insert(provider).inserted {
            result.append(provider)
        }
        return result
    }

    public mutating func toggleModule(_ module: MenuBarModule) {
        var list = Self.deduplicatedModules(modules)
        if let idx = list.firstIndex(of: module) {
            list.remove(at: idx)
        } else {
            list.append(module)
        }
        modules = list
    }

    public mutating func moveModule(_ module: MenuBarModule, direction: CardMoveDirection) {
        moveModule(module, direction: direction.rawValue)
    }

    public mutating func moveModule(_ module: MenuBarModule, direction: Int) {
        var list = Self.deduplicatedModules(modules)
        guard direction != 0, let idx = list.firstIndex(of: module) else { return }
        let target = min(max(idx + direction, 0), list.count - 1)
        guard target != idx else { return }
        let item = list.remove(at: idx)
        list.insert(item, at: target)
        modules = list
    }

    public mutating func toggleMultiProvider(_ provider: ProviderID) {
        var list = Self.deduplicatedProviders(quotaMultiProviders)
        if let idx = list.firstIndex(of: provider) {
            list.remove(at: idx)
        } else {
            list.append(provider)
        }
        quotaMultiProviders = list
    }

    public mutating func moveMultiProvider(_ provider: ProviderID, direction: CardMoveDirection) {
        moveMultiProvider(provider, direction: direction.rawValue)
    }

    public mutating func moveMultiProvider(_ provider: ProviderID, direction: Int) {
        var list = Self.deduplicatedProviders(quotaMultiProviders)
        guard direction != 0, let idx = list.firstIndex(of: provider) else { return }
        let target = min(max(idx + direction, 0), list.count - 1)
        guard target != idx else { return }
        let item = list.remove(at: idx)
        list.insert(item, at: target)
        quotaMultiProviders = list
    }
}

// MARK: - Card Customization Models

public enum PopoverTokenCard: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case summary
    case liveSpeed
    case dailyTrend
    case clientBreakdown
    case topModels
    case miniHeatmap

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .summary: return "核心总览"
        case .liveSpeed: return "实时速度"
        case .dailyTrend: return "近 14 天走势"
        case .clientBreakdown: return "客户端拆分"
        case .topModels: return "热门模型排行"
        case .miniHeatmap: return "近期活跃热力"
        }
    }

    public var displayName: String { title }

    public var subtitle: String {
        switch self {
        case .summary: return "总 Tokens / 费用 / 缓存 / 分布条"
        case .liveSpeed: return "tok/s 活跃模型与 60s 合并吞吐"
        case .dailyTrend: return "近 14 天柱状趋势图"
        case .clientBreakdown: return "各 AI 客户端用量占比"
        case .topModels: return "Top 4 模型含均速徽章"
        case .miniHeatmap: return "紧凑 8 周活跃格子"
        }
    }

    public var symbolName: String {
        switch self {
        case .summary: return "chart.bar.doc.horizontal"
        case .liveSpeed: return "bolt.horizontal.fill"
        case .dailyTrend: return "chart.xyaxis.line"
        case .clientBreakdown: return "square.stack.3d.up.fill"
        case .topModels: return "cpu"
        case .miniHeatmap: return "square.grid.3x3.fill"
        }
    }
}

public struct PopoverTokenCardConfig: Codable, Equatable, Hashable, Sendable {
    public static let defaultOrderedCards: [PopoverTokenCard] = PopoverTokenCard.allCases
    public static let defaultEnabledCards: [PopoverTokenCard] = [
        .summary, .liveSpeed, .dailyTrend, .clientBreakdown,
    ]
    public static let `default` = PopoverTokenCardConfig()

    public var orderedCards: [PopoverTokenCard]
    public var enabledCards: [PopoverTokenCard]
    public var compactDensity: Bool

    public init(
        orderedCards: [PopoverTokenCard] = PopoverTokenCardConfig.defaultOrderedCards,
        enabledCards: [PopoverTokenCard] = PopoverTokenCardConfig.defaultEnabledCards,
        compactDensity: Bool = false
    ) {
        self.orderedCards = Self.normalizedOrder(orderedCards)
        self.enabledCards = Self.deduplicated(enabledCards)
        self.compactDensity = compactDensity
    }

    private enum CodingKeys: String, CodingKey {
        case orderedCards
        case enabledCards
        case compactDensity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let rawOrder = try? c.decodeIfPresent([String].self, forKey: .orderedCards) {
            self.orderedCards = Self.normalizedOrder(rawOrder.compactMap { PopoverTokenCard(rawValue: $0) })
        } else {
            self.orderedCards = Self.defaultOrderedCards
        }

        if c.contains(.enabledCards) {
            if let rawEnabled = try? c.decode([String].self, forKey: .enabledCards) {
                self.enabledCards = Self.deduplicated(rawEnabled.compactMap { PopoverTokenCard(rawValue: $0) })
            } else if let decoded = (try? c.decodeIfPresent([PopoverTokenCard].self, forKey: .enabledCards)) ?? nil {
                self.enabledCards = Self.deduplicated(decoded)
            } else {
                self.enabledCards = Self.defaultEnabledCards
            }
        } else {
            self.enabledCards = Self.defaultEnabledCards
        }

        self.compactDensity = try c.decodeIfPresent(Bool.self, forKey: .compactDensity) ?? false
    }

    public var visibleCards: [PopoverTokenCard] {
        let enabledSet = Set(enabledCards)
        return Self.normalizedOrder(orderedCards).filter { enabledSet.contains($0) }
    }

    public func isEnabled(_ card: PopoverTokenCard) -> Bool {
        enabledCards.contains(card)
    }

    public func canMoveCard(_ card: PopoverTokenCard, direction: CardMoveDirection) -> Bool {
        let normalized = Self.normalizedOrder(orderedCards)
        guard let idx = normalized.firstIndex(of: card) else { return false }
        let target = idx + direction.rawValue
        return target >= 0 && target < normalized.count
    }

    public mutating func toggleCard(_ card: PopoverTokenCard) {
        var list = Self.deduplicated(enabledCards)
        if let idx = list.firstIndex(of: card) {
            list.remove(at: idx)
        } else {
            list.append(card)
        }
        enabledCards = list
    }

    public mutating func setCard(_ card: PopoverTokenCard, enabled: Bool) {
        var list = Self.deduplicated(enabledCards)
        if enabled {
            if !list.contains(card) { list.append(card) }
        } else {
            list.removeAll { $0 == card }
        }
        enabledCards = list
    }

    public mutating func moveCard(_ card: PopoverTokenCard, direction: CardMoveDirection) {
        moveCard(card, direction: direction.rawValue)
    }

    public mutating func moveCard(_ card: PopoverTokenCard, direction: Int) {
        var list = Self.normalizedOrder(orderedCards)
        guard direction != 0, let idx = list.firstIndex(of: card) else { return }
        let target = min(max(idx + direction, 0), list.count - 1)
        guard target != idx else { return }
        let item = list.remove(at: idx)
        list.insert(item, at: target)
        orderedCards = list
    }

    public static func deduplicated(_ raw: [PopoverTokenCard]) -> [PopoverTokenCard] {
        var seen = Set<PopoverTokenCard>()
        var result: [PopoverTokenCard] = []
        for card in raw where seen.insert(card).inserted {
            result.append(card)
        }
        return result
    }

    public static func normalizedOrder(_ raw: [PopoverTokenCard]) -> [PopoverTokenCard] {
        var result = deduplicated(raw)
        let seen = Set(result)
        for card in PopoverTokenCard.allCases where !seen.contains(card) {
            result.append(card)
        }
        return result
    }
}

public enum DashboardTokenCard: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case kpiGrid
    case liveSpeed
    case heatmap
    case dailyTrend
    case deepBreakdown

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .kpiGrid: return "核心 KPI 指标卡"
        case .liveSpeed: return "实时与近期模型速度"
        case .heatmap: return "近 16 周活跃热力图"
        case .dailyTrend: return "每日趋势图"
        case .deepBreakdown: return "深度明细排行表"
        }
    }

    public var displayName: String { title }

    public var subtitle: String {
        switch self {
        case .kpiGrid: return "核心总量、估算费用、缓存命中率与活跃天数"
        case .liveSpeed: return "实时 tok/s 脉冲与近期模型速度分布"
        case .heatmap: return "近 16 周每日活跃格子与强度图例"
        case .dailyTrend: return "每日 Token 消耗与费用趋势柱图"
        case .deepBreakdown: return "客户端 / 模型 / 项目三标签深度明细"
        }
    }

    public var symbolName: String {
        switch self {
        case .kpiGrid: return "square.grid.2x2.fill"
        case .liveSpeed: return "bolt.horizontal.fill"
        case .heatmap: return "calendar"
        case .dailyTrend: return "chart.bar.xaxis"
        case .deepBreakdown: return "list.bullet.rectangle.portrait"
        }
    }
}

public struct DashboardTokenCardConfig: Codable, Equatable, Hashable, Sendable {
    public static let defaultOrderedCards: [DashboardTokenCard] = DashboardTokenCard.allCases
    public static let defaultEnabledCards: [DashboardTokenCard] = DashboardTokenCard.allCases
    public static let `default` = DashboardTokenCardConfig()

    public var orderedCards: [DashboardTokenCard]
    public var enabledCards: [DashboardTokenCard]
    public var compactDensity: Bool

    public init(
        orderedCards: [DashboardTokenCard] = DashboardTokenCardConfig.defaultOrderedCards,
        enabledCards: [DashboardTokenCard] = DashboardTokenCardConfig.defaultEnabledCards,
        compactDensity: Bool = false
    ) {
        self.orderedCards = Self.normalizedOrder(orderedCards)
        self.enabledCards = Self.deduplicated(enabledCards)
        self.compactDensity = compactDensity
    }

    private enum CodingKeys: String, CodingKey {
        case orderedCards
        case enabledCards
        case compactDensity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let rawOrder = try? c.decodeIfPresent([String].self, forKey: .orderedCards) {
            self.orderedCards = Self.normalizedOrder(rawOrder.compactMap { DashboardTokenCard(rawValue: $0) })
        } else {
            self.orderedCards = Self.defaultOrderedCards
        }

        if c.contains(.enabledCards) {
            if let rawEnabled = try? c.decode([String].self, forKey: .enabledCards) {
                self.enabledCards = Self.deduplicated(rawEnabled.compactMap { DashboardTokenCard(rawValue: $0) })
            } else if let decoded = (try? c.decodeIfPresent([DashboardTokenCard].self, forKey: .enabledCards)) ?? nil {
                self.enabledCards = Self.deduplicated(decoded)
            } else {
                self.enabledCards = Self.defaultEnabledCards
            }
        } else {
            self.enabledCards = Self.defaultEnabledCards
        }

        self.compactDensity = try c.decodeIfPresent(Bool.self, forKey: .compactDensity) ?? false
    }

    public var visibleCards: [DashboardTokenCard] {
        let enabledSet = Set(enabledCards)
        return Self.normalizedOrder(orderedCards).filter { enabledSet.contains($0) }
    }

    public func isEnabled(_ card: DashboardTokenCard) -> Bool {
        enabledCards.contains(card)
    }

    public func canMoveCard(_ card: DashboardTokenCard, direction: CardMoveDirection) -> Bool {
        let normalized = Self.normalizedOrder(orderedCards)
        guard let idx = normalized.firstIndex(of: card) else { return false }
        let target = idx + direction.rawValue
        return target >= 0 && target < normalized.count
    }

    public mutating func toggleCard(_ card: DashboardTokenCard) {
        var list = Self.deduplicated(enabledCards)
        if let idx = list.firstIndex(of: card) {
            list.remove(at: idx)
        } else {
            list.append(card)
        }
        enabledCards = list
    }

    public mutating func setCard(_ card: DashboardTokenCard, enabled: Bool) {
        var list = Self.deduplicated(enabledCards)
        if enabled {
            if !list.contains(card) { list.append(card) }
        } else {
            list.removeAll { $0 == card }
        }
        enabledCards = list
    }

    public mutating func moveCard(_ card: DashboardTokenCard, direction: CardMoveDirection) {
        moveCard(card, direction: direction.rawValue)
    }

    public mutating func moveCard(_ card: DashboardTokenCard, direction: Int) {
        var list = Self.normalizedOrder(orderedCards)
        guard direction != 0, let idx = list.firstIndex(of: card) else { return }
        let target = min(max(idx + direction, 0), list.count - 1)
        guard target != idx else { return }
        let item = list.remove(at: idx)
        list.insert(item, at: target)
        orderedCards = list
    }

    public static func deduplicated(_ raw: [DashboardTokenCard]) -> [DashboardTokenCard] {
        var seen = Set<DashboardTokenCard>()
        var result: [DashboardTokenCard] = []
        for card in raw where seen.insert(card).inserted {
            result.append(card)
        }
        return result
    }

    public static func normalizedOrder(_ raw: [DashboardTokenCard]) -> [DashboardTokenCard] {
        var result = deduplicated(raw)
        let seen = Set(result)
        for card in DashboardTokenCard.allCases where !seen.contains(card) {
            result.append(card)
        }
        return result
    }
}

public struct AccountCardConfig: Codable, Equatable, Hashable, Sendable {
    public static let `default` = AccountCardConfig()

    public var showAvatar: Bool
    public var showFiveHour: Bool
    public var showWeekly: Bool
    public var showResetFootnote: Bool
    public var showSourceBadge: Bool
    public var compactDensity: Bool
    public var pillQuotaWindow: MenuBarQuotaWindow

    public init(
        showAvatar: Bool = true,
        showFiveHour: Bool = true,
        showWeekly: Bool = true,
        showResetFootnote: Bool = true,
        showSourceBadge: Bool = true,
        compactDensity: Bool = false,
        pillQuotaWindow: MenuBarQuotaWindow = .weeklyFirst
    ) {
        self.showAvatar = showAvatar
        self.showFiveHour = showFiveHour
        self.showWeekly = showWeekly
        self.showResetFootnote = showResetFootnote
        self.showSourceBadge = showSourceBadge
        self.compactDensity = compactDensity
        self.pillQuotaWindow = pillQuotaWindow
    }

    private enum CodingKeys: String, CodingKey {
        case showAvatar
        case showFiveHour
        case showWeekly
        case showResetFootnote
        case showSourceBadge
        case compactDensity
        case pillQuotaWindow
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.showAvatar = try c.decodeIfPresent(Bool.self, forKey: .showAvatar) ?? true
        self.showFiveHour = try c.decodeIfPresent(Bool.self, forKey: .showFiveHour) ?? true
        self.showWeekly = try c.decodeIfPresent(Bool.self, forKey: .showWeekly) ?? true
        self.showResetFootnote = try c.decodeIfPresent(Bool.self, forKey: .showResetFootnote) ?? true
        self.showSourceBadge = try c.decodeIfPresent(Bool.self, forKey: .showSourceBadge) ?? true
        self.compactDensity = try c.decodeIfPresent(Bool.self, forKey: .compactDensity) ?? false
        self.pillQuotaWindow = (try? c.decodeIfPresent(MenuBarQuotaWindow.self, forKey: .pillQuotaWindow)) ?? .weeklyFirst
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let defaultPopoverWidth: Double = 390
    public static let defaultPopoverHeight: Double = 620
    public static let defaultDashboardWidth: Double = 520
    public static let defaultDashboardHeight: Double = 680

    public static let popoverWidthRange: ClosedRange<Double> = 340...680
    public static let popoverHeightRange: ClosedRange<Double> = 460...920
    public static let dashboardWidthRange: ClosedRange<Double> = 380...1100
    public static let dashboardHeightRange: ClosedRange<Double> = 460...1100

    public static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    public var enabledProviders: [ProviderID]
    public var selectedProvider: ProviderID
    public var menuBarDisplayMode: MenuBarDisplayMode
    public var menuBarCustom: MenuBarCustomConfig
    public var showRemainingPercent: Bool
    public var showResetRelative: Bool
    public var refreshCadence: RefreshCadence
    public var refreshOnMenuOpen: Bool
    public var lowQuotaWarnThreshold: Double
    public var launchAtLogin: Bool
    public var legacyMigrationCompleted: Bool
    public var popoverWidth: Double
    public var popoverHeight: Double
    public var dashboardWidth: Double
    public var dashboardHeight: Double
    public var tokenPopoverCards: PopoverTokenCardConfig
    public var tokenDashboardCards: DashboardTokenCardConfig
    public var accountCardConfig: AccountCardConfig
    public var tokenClientOrder: [String]

    public init(
        enabledProviders: [ProviderID] = ProviderID.allCases,
        selectedProvider: ProviderID = .antigravity,
        menuBarDisplayMode: MenuBarDisplayMode = .selectedProvider,
        showRemainingPercent: Bool = true,
        showResetRelative: Bool = true,
        refreshCadence: RefreshCadence = .every5m,
        refreshOnMenuOpen: Bool = true,
        lowQuotaWarnThreshold: Double = 0.20,
        launchAtLogin: Bool = true,
        legacyMigrationCompleted: Bool = false,
        menuBarCustom: MenuBarCustomConfig = MenuBarCustomConfig(),
        popoverWidth: Double = AppSettings.defaultPopoverWidth,
        popoverHeight: Double = AppSettings.defaultPopoverHeight,
        dashboardWidth: Double = AppSettings.defaultDashboardWidth,
        dashboardHeight: Double = AppSettings.defaultDashboardHeight,
        tokenPopoverCards: PopoverTokenCardConfig = .default,
        tokenDashboardCards: DashboardTokenCardConfig = .default,
        accountCardConfig: AccountCardConfig = .default,
        tokenClientOrder: [String] = []
    ) {
        self.enabledProviders = enabledProviders.isEmpty ? ProviderID.allCases : enabledProviders
        self.selectedProvider = selectedProvider
        self.menuBarDisplayMode = menuBarDisplayMode
        self.menuBarCustom = menuBarCustom
        self.showRemainingPercent = showRemainingPercent
        self.showResetRelative = showResetRelative
        self.refreshCadence = refreshCadence
        self.refreshOnMenuOpen = refreshOnMenuOpen
        self.lowQuotaWarnThreshold = min(max(lowQuotaWarnThreshold, 0.01), 0.95)
        self.launchAtLogin = launchAtLogin
        self.legacyMigrationCompleted = legacyMigrationCompleted
        self.popoverWidth = Self.clamp(popoverWidth, to: Self.popoverWidthRange, fallback: Self.defaultPopoverWidth)
        self.popoverHeight = Self.clamp(popoverHeight, to: Self.popoverHeightRange, fallback: Self.defaultPopoverHeight)
        self.dashboardWidth = Self.clamp(dashboardWidth, to: Self.dashboardWidthRange, fallback: Self.defaultDashboardWidth)
        self.dashboardHeight = Self.clamp(dashboardHeight, to: Self.dashboardHeightRange, fallback: Self.defaultDashboardHeight)
        self.tokenPopoverCards = tokenPopoverCards
        self.tokenDashboardCards = tokenDashboardCards
        self.accountCardConfig = accountCardConfig
        self.tokenClientOrder = Self.normalizeTokenClientOrder(tokenClientOrder)
    }

    private enum CodingKeys: String, CodingKey {
        case enabledProviders
        case selectedProvider
        case menuBarDisplayMode
        case menuBarCustom
        case showRemainingPercent
        case showResetRelative
        case refreshCadence
        case refreshOnMenuOpen
        case lowQuotaWarnThreshold
        case launchAtLogin
        case legacyMigrationCompleted
        case popoverWidth
        case popoverHeight
        case dashboardWidth
        case dashboardHeight
        case tokenPopoverCards
        case tokenDashboardCards
        case accountCardConfig
        case tokenClientOrder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedEnabled = try c.decodeIfPresent([ProviderID].self, forKey: .enabledProviders) ?? ProviderID.allCases
        self.enabledProviders = decodedEnabled.isEmpty ? ProviderID.allCases : decodedEnabled
        self.selectedProvider = try c.decodeIfPresent(ProviderID.self, forKey: .selectedProvider) ?? .antigravity
        self.menuBarDisplayMode = (try? c.decodeIfPresent(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode)) ?? .selectedProvider
        self.menuBarCustom = (try? c.decodeIfPresent(MenuBarCustomConfig.self, forKey: .menuBarCustom)) ?? MenuBarCustomConfig()
        self.showRemainingPercent = try c.decodeIfPresent(Bool.self, forKey: .showRemainingPercent) ?? true
        self.showResetRelative = try c.decodeIfPresent(Bool.self, forKey: .showResetRelative) ?? true
        self.refreshCadence = try c.decodeIfPresent(RefreshCadence.self, forKey: .refreshCadence) ?? .every5m
        self.refreshOnMenuOpen = try c.decodeIfPresent(Bool.self, forKey: .refreshOnMenuOpen) ?? true
        let rawThreshold = try c.decodeIfPresent(Double.self, forKey: .lowQuotaWarnThreshold) ?? 0.20
        self.lowQuotaWarnThreshold = min(max(rawThreshold, 0.01), 0.95)
        self.launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        self.legacyMigrationCompleted = try c.decodeIfPresent(Bool.self, forKey: .legacyMigrationCompleted) ?? false

        let rawPopW = (try? c.decodeIfPresent(Double.self, forKey: .popoverWidth)) ?? Self.defaultPopoverWidth
        let rawPopH = (try? c.decodeIfPresent(Double.self, forKey: .popoverHeight)) ?? Self.defaultPopoverHeight
        let rawDashW = (try? c.decodeIfPresent(Double.self, forKey: .dashboardWidth)) ?? Self.defaultDashboardWidth
        let rawDashH = (try? c.decodeIfPresent(Double.self, forKey: .dashboardHeight)) ?? Self.defaultDashboardHeight
        self.popoverWidth = Self.clamp(rawPopW, to: Self.popoverWidthRange, fallback: Self.defaultPopoverWidth)
        self.popoverHeight = Self.clamp(rawPopH, to: Self.popoverHeightRange, fallback: Self.defaultPopoverHeight)
        self.dashboardWidth = Self.clamp(rawDashW, to: Self.dashboardWidthRange, fallback: Self.defaultDashboardWidth)
        self.dashboardHeight = Self.clamp(rawDashH, to: Self.dashboardHeightRange, fallback: Self.defaultDashboardHeight)

        self.tokenPopoverCards = (try? c.decodeIfPresent(PopoverTokenCardConfig.self, forKey: .tokenPopoverCards)) ?? .default
        self.tokenDashboardCards = (try? c.decodeIfPresent(DashboardTokenCardConfig.self, forKey: .tokenDashboardCards)) ?? .default
        self.accountCardConfig = (try? c.decodeIfPresent(AccountCardConfig.self, forKey: .accountCardConfig)) ?? .default
        let rawClientOrder = (try? c.decodeIfPresent([String].self, forKey: .tokenClientOrder)) ?? []
        self.tokenClientOrder = Self.normalizeTokenClientOrder(rawClientOrder)
    }

    // MARK: - Token Client Filter Custom Ordering

    /// Indicates whether a custom token client chip order is currently stored.
    public var hasCustomTokenClientOrder: Bool {
        !Self.normalizeTokenClientOrder(tokenClientOrder).isEmpty
    }

    /// Trims whitespace, strips empty strings, and removes duplicates while preserving first occurrence.
    public static func normalizeTokenClientOrder(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(raw.count)
        for item in raw {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// Returns `availableRawValues` ordered with any entries present in `tokenClientOrder` first (in saved order),
    /// followed by all remaining entries in their original `availableRawValues` order.
    public func orderedTokenClientRawValues(from availableRawValues: [String]) -> [String] {
        let available = Self.normalizeTokenClientOrder(availableRawValues)
        guard !available.isEmpty else { return [] }

        let availableSet = Set(available)
        let savedOrder = Self.normalizeTokenClientOrder(tokenClientOrder)

        var result: [String] = []
        result.reserveCapacity(available.count)
        var placed = Set<String>()

        for raw in savedOrder where availableSet.contains(raw) {
            if placed.insert(raw).inserted {
                result.append(raw)
            }
        }
        for raw in available where placed.insert(raw).inserted {
            result.append(raw)
        }
        return result
    }

    /// Generic helper that orders any `RawRepresentable` client values (`RawValue == String`, e.g. `TokenClientID`)
    /// without introducing a compile-time dependency on external files.
    public func orderedTokenClients<Client: RawRepresentable>(
        from available: [Client]
    ) -> [Client] where Client.RawValue == String {
        var lookup: [String: Client] = [:]
        lookup.reserveCapacity(available.count)
        var rawList: [String] = []
        rawList.reserveCapacity(available.count)
        for client in available {
            let key = client.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, lookup[key] == nil else { continue }
            lookup[key] = client
            rawList.append(key)
        }
        return orderedTokenClientRawValues(from: rawList).compactMap { lookup[$0] }
    }

    /// Reports whether `rawValue` can move one slot earlier (`.up`) or later (`.down`) within `available`.
    public func canMoveTokenClient(
        rawValue: String,
        direction: CardMoveDirection,
        available: [String]
    ) -> Bool {
        let key = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        let ordered = orderedTokenClientRawValues(from: available)
        guard let idx = ordered.firstIndex(of: key) else { return false }
        let target = idx + direction.rawValue
        return target >= 0 && target < ordered.count
    }

    /// Materializes the current effective order for `available` and shifts `rawValue` one slot earlier (`.up`) or later (`.down`).
    public mutating func moveTokenClient(
        rawValue: String,
        direction: CardMoveDirection,
        available: [String]
    ) {
        let key = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let ordered = orderedTokenClientRawValues(from: available)
        guard let idx = ordered.firstIndex(of: key) else { return }
        let target = min(max(idx + direction.rawValue, 0), ordered.count - 1)
        guard target != idx else { return }
        moveTokenClient(rawValue: key, toIndex: target, available: ordered)
    }

    /// Materializes the current effective order for `available` and moves `rawValue` to `toIndex` (clamped to valid bounds).
    /// Any previously-saved client IDs absent from `available` are preserved at the tail so time-range filters do not erase them.
    public mutating func moveTokenClient(
        rawValue: String,
        toIndex: Int,
        available: [String]
    ) {
        let key = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        var ordered = orderedTokenClientRawValues(from: available)
        guard !ordered.isEmpty, let idx = ordered.firstIndex(of: key) else { return }
        let clampedTarget = min(max(toIndex, 0), ordered.count - 1)
        if clampedTarget != idx {
            let item = ordered.remove(at: idx)
            ordered.insert(item, at: clampedTarget)
        }
        let visibleSet = Set(ordered)
        let hiddenTail = Self.normalizeTokenClientOrder(tokenClientOrder).filter { !visibleSet.contains($0) }
        tokenClientOrder = ordered + hiddenTail
    }

    /// Pins `rawValue` to the front of the client chip order.
    public mutating func pinTokenClientToFront(rawValue: String, available: [String]) {
        moveTokenClient(rawValue: rawValue, toIndex: 0, available: available)
    }

    /// Pins `rawValue` to the end of the client chip order.
    public mutating func pinTokenClientToEnd(rawValue: String, available: [String]) {
        let ordered = orderedTokenClientRawValues(from: available)
        guard !ordered.isEmpty else { return }
        moveTokenClient(rawValue: rawValue, toIndex: ordered.count - 1, available: ordered)
    }

    /// Clears custom client chip order and restores default usage-based ordering.
    public mutating func resetTokenClientOrder() {
        tokenClientOrder = []
    }
}

public struct RegistryData: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var accounts: [AccountRecord]
    public var settings: AppSettings

    public init(
        schemaVersion: Int = RegistryData.currentSchemaVersion,
        accounts: [AccountRecord] = [],
        settings: AppSettings = AppSettings()
    ) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
        self.settings = settings
    }

    public static var defaultDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("RoryOrbit", isDirectory: true)
    }

    public static var defaultFileURL: URL {
        defaultDirectoryURL.appendingPathComponent("registry.json", isDirectory: false)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Formatters.formatRFC3339UTC(date))
        }
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let str = try? container.decode(String.self),
               let parsed = Formatters.parseRFC3339(str) {
                return parsed
            }
            if let ts = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: ts)
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected RFC3339 date string or unix timestamp"
            )
        }
        return decoder
    }

    public static func load(from url: URL = RegistryData.defaultFileURL) throws -> RegistryData {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return RegistryData()
        }
        let data = try Data(contentsOf: url)
        if data.isEmpty {
            return RegistryData()
        }
        return try makeDecoder().decode(RegistryData.self, from: data)
    }

    public func save(to url: URL = RegistryData.defaultFileURL) throws {
        let dir = url.deletingLastPathComponent()
        try KeychainStore.ensureDirectory(at: dir, mode: 0o700)
        let data = try Self.makeEncoder().encode(self)
        try KeychainStore.writeAtomicFile(data: data, to: url, mode: 0o600)
    }

    public func accounts(for provider: ProviderID) -> [AccountRecord] {
        accounts.filter { $0.provider == provider }
    }

    public mutating func upsertAccount(_ account: AccountRecord) {
        if let idx = accounts.firstIndex(where: { $0.provider == account.provider && $0.id == account.id }) {
            var merged = account
            // Preserve earlier addedAt and non-empty fields when merging updates.
            if accounts[idx].addedAt < merged.addedAt {
                merged.addedAt = accounts[idx].addedAt
            }
            if merged.email.isEmpty {
                merged.email = accounts[idx].email
            }
            if merged.displayName.isEmpty {
                merged.displayName = accounts[idx].displayName
            }
            if merged.plan == nil {
                merged.plan = accounts[idx].plan
            }
            if merged.avatarURL == nil {
                merged.avatarURL = accounts[idx].avatarURL
            }
            accounts[idx] = merged
        } else {
            accounts.append(account)
        }
    }

    public mutating func setActiveLive(accountId: String?, for provider: ProviderID) {
        for idx in accounts.indices where accounts[idx].provider == provider {
            accounts[idx].isActiveLive = (accountId != nil && accounts[idx].id == accountId)
        }
    }

    public mutating func removeAccount(id: String, provider: ProviderID) {
        accounts.removeAll { $0.provider == provider && $0.id == id }
    }

    public mutating func refreshBestRemainingFlags(snapshots: [String: QuotaSnapshot]) {
        for provider in ProviderID.allCases {
            let bestId = AccountRecord.bestRemainingAccountId(
                for: provider,
                accounts: accounts,
                snapshots: snapshots
            )
            for idx in accounts.indices where accounts[idx].provider == provider {
                accounts[idx].isBestRemaining = (bestId != nil && accounts[idx].id == bestId)
            }
        }
    }
}

// MARK: - Provider Adapter Protocol

public enum ProviderAdapterError: Error, LocalizedError, Equatable, Sendable {
    case unsupported(ProviderID, String)
    case invalidCredential(String)
    case networkFailure(String)
    case authenticationRequired(String)
    case clientConflict(String)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let provider, let op):
            return "\(provider.displayName) 不支持操作: \(op)"
        case .invalidCredential(let msg):
            return msg
        case .networkFailure(let msg):
            return msg
        case .authenticationRequired(let msg):
            return msg
        case .clientConflict(let msg):
            return msg
        case .operationFailed(let msg):
            return msg
        }
    }
}

public protocol ProviderAdapter {
    var id: ProviderID { get }
    var capabilities: ProviderCapability { get }
    var transportPolicy: TransportPolicy { get }
    var isolatedStoreNamespace: String { get }

    func detectClientStatus() async -> ClientRuntimeStatus
    func syncLiveAccount(registry: inout RegistryData) async -> String?
    func fetchQuota(for account: AccountRecord, isActiveLive: Bool) async -> QuotaSnapshot

    func addAccount() async throws -> AccountRecord
    func importLiveAccount() async throws -> AccountRecord
    func switchAccount(to account: AccountRecord, allowForceQuit: Bool) async -> SwitchResult
    func controlClient(restart: Bool, allowForceQuit: Bool) async -> SwitchResult
    func hasStoredAPIKey() -> Bool
    func saveAPIKey(_ key: String, label: String?) throws
    func deleteAccountCredentials(accountId: String) throws
}

public extension ProviderAdapter {
    var transportPolicy: TransportPolicy { .systemProxy }

    var isolatedStoreNamespace: String {
        "com.rory.roryorbit.\(id.rawValue)"
    }

    func detectClientStatus() async -> ClientRuntimeStatus {
        .notInstalled
    }

    func addAccount() async throws -> AccountRecord {
        throw ProviderAdapterError.unsupported(id, "addAccount")
    }

    func importLiveAccount() async throws -> AccountRecord {
        throw ProviderAdapterError.unsupported(id, "importLiveAccount")
    }

    func switchAccount(to account: AccountRecord, allowForceQuit: Bool) async -> SwitchResult {
        .failed("\(id.displayName) 不支持多账号切换")
    }

    func controlClient(restart: Bool, allowForceQuit: Bool) async -> SwitchResult {
        .failed("\(id.displayName) 不支持客户端控制")
    }

    func hasStoredAPIKey() -> Bool {
        false
    }

    func saveAPIKey(_ key: String, label: String?) throws {
        throw ProviderAdapterError.unsupported(id, "saveAPIKey")
    }

    func deleteAccountCredentials(accountId: String) throws {
        // No-op for read-only / non-vaulted adapters.
    }
}

// MARK: - Codex Auth Identity Helper

public struct CodexAuthIdentity: Equatable, Sendable {
    public let canonicalAccountId: String
    public let userId: String
    public let chatgptAccountId: String
    public let email: String
    public let displayName: String
    public let plan: PlanInfo?

    public init(
        canonicalAccountId: String,
        userId: String,
        chatgptAccountId: String,
        email: String,
        displayName: String,
        plan: PlanInfo?
    ) {
        self.canonicalAccountId = canonicalAccountId
        self.userId = userId
        self.chatgptAccountId = chatgptAccountId
        self.email = email
        self.displayName = displayName
        self.plan = plan
    }
}

// MARK: - Formatters & Cryptographic/Parsing Utilities

public enum Formatters {
    /// Formats a future reset date as a concise Chinese relative countdown (e.g. "2小时15分后重置", "3天4小时后重置").
    public static func relativeResetString(to date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let delta = Int(date.timeIntervalSince(now))
        if delta <= 0 {
            return "即将重置"
        }
        if delta < 60 {
            return "<1分钟后重置"
        }
        if delta < 3600 {
            let mins = delta / 60
            return "\(mins)分钟后重置"
        }
        if delta < 86400 {
            let hours = delta / 3600
            let mins = (delta % 3600) / 60
            return mins > 0 ? "\(hours)小时\(mins)分后重置" : "\(hours)小时后重置"
        }
        let days = delta / 86400
        let hours = (delta % 86400) / 3600
        return hours > 0 ? "\(days)天\(hours)小时后重置" : "\(days)天后重置"
    }

    public static func absoluteResetString(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "" }
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.timeZone = timeZone
        df.dateFormat = "MM-dd HH:mm"
        return "\(df.string(from: date)) 重置"
    }

    public static func resetDisplayString(_ date: Date?, relative: Bool, now: Date = Date()) -> String {
        relative ? relativeResetString(to: date, now: now) : absoluteResetString(date)
    }

    /// Formats a compact reset countdown suitable for tight menu bar slots (e.g. "2h15m", "45m", "3d4h", "<1m", "即将重置").
    public static func compactResetCountdown(to date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let delta = Int(date.timeIntervalSince(now))
        if delta <= 0 {
            return "即将重置"
        }
        if delta < 60 {
            return "<1m"
        }
        if delta < 3600 {
            return "\(delta / 60)m"
        }
        if delta < 86400 {
            let hours = delta / 3600
            let mins = (delta % 3600) / 60
            return mins > 0 ? "\(hours)h\(mins)m" : "\(hours)h"
        }
        let days = delta / 86400
        let hours = (delta % 86400) / 3600
        return hours > 0 ? "\(days)d\(hours)h" : "\(days)d"
    }

    public static func remainingPercentInt(_ fraction: Double) -> Int {
        let clamped = min(max(fraction, 0.0), 1.0)
        return Int((clamped * 100.0).rounded())
    }

    public static func percentString(remainingFraction: Double, showRemaining: Bool = true) -> String {
        let rem = remainingPercentInt(remainingFraction)
        if showRemaining {
            return "\(rem)%"
        }
        return "\(100 - rem)%"
    }

    public static func currencyString(amount: Double, currency: String) -> String {
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let formatted = String(format: "%.2f", amount)
        switch code {
        case "USD": return "$\(formatted)"
        case "CNY", "RMB": return "¥\(formatted)"
        case "EUR": return "€\(formatted)"
        case "GBP": return "£\(formatted)"
        case "": return formatted
        default: return "\(code) \(formatted)"
        }
    }

    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    /// Validates and normalizes an HTTPS-only URL string (rejecting non-HTTPS schemes and empty hosts).
    public static func sanitizedHTTPSURLString(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return trimmed
    }

    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func base64URLDecode(_ string: String) -> Data? {
        var s = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = s.count % 4
        if rem == 2 {
            s.append("==")
        } else if rem == 3 {
            s.append("=")
        } else if rem == 1 {
            return nil
        }
        return Data(base64Encoded: s)
    }

    /// Decodes the payload segment (middle part) of a JWT into a JSON dictionary without verifying signature.
    public static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        guard let payloadData = base64URLDecode(String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: payloadData, options: [])) as? [String: Any]
    }

    /// Parses RFC3339 timestamps with optional fractional seconds (up to nanoseconds) and `Z` or `±HH:MM` timezone offsets.
    public static func parseRFC3339(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Normalize >3 fractional digits (e.g. microseconds/nanoseconds from Go/Rust) down to milliseconds for ISO8601DateFormatter.
        let normalized = normalizeFractionalSeconds(trimmed)

        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFrac.date(from: normalized) {
            return date
        }

        let noFrac = ISO8601DateFormatter()
        noFrac.formatOptions = [.withInternetDateTime]
        if let date = noFrac.date(from: trimmed) {
            return date
        }

        return nil
    }

    private static func normalizeFractionalSeconds(_ input: String) -> String {
        guard let dotIdx = input.firstIndex(of: ".") else { return input }
        let afterDot = input.index(after: dotIdx)
        var endFrac = afterDot
        while endFrac < input.endIndex && input[endFrac].isNumber {
            endFrac = input.index(after: endFrac)
        }
        let frac = input[afterDot..<endFrac]
        guard !frac.isEmpty else { return input }
        let millis: String
        if frac.count >= 3 {
            millis = String(frac.prefix(3))
        } else {
            millis = String(frac) + String(repeating: "0", count: 3 - frac.count)
        }
        return String(input[..<afterDot]) + millis + String(input[endFrac...])
    }

    /// Formats a Date in RFC3339 UTC with fractional seconds (e.g. "2026-11-20T08:36:15.936Z").
    public static func formatRFC3339UTC(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Formats a Date in RFC3339 with the current local timezone offset (matching Go `oauth2.Token` / Antigravity live bundle).
    public static func formatRFC3339Local(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Computes Codex's `Codex Auth` Keychain account name for a given `CODEX_HOME` directory path.
    public static func canonicalCodexKeychainAccount(codexHomePath: String) -> String {
        let canonical = URL(fileURLWithPath: codexHomePath).standardizedFileURL.resolvingSymlinksInPath().path
        let digestPrefix = String(sha256Hex(canonical).prefix(16))
        return "cli|\(digestPrefix)"
    }

    /// Extracts canonical Codex identity (`codex:<userId>:<accountId>`) from either a raw `auth.json` object
    /// or an OrbitSwitch session wrapper (`{"credential": <auth.json>, "profile": ...}`).
    public static func extractCodexAuthIdentity(from jsonObject: [String: Any]) -> CodexAuthIdentity? {
        let authObj = (jsonObject["credential"] as? [String: Any]) ?? jsonObject
        guard let tokens = authObj["tokens"] as? [String: Any] else { return nil }

        let idToken = tokens["id_token"] as? String
        let claims = idToken.flatMap { decodeJWTPayload($0) }
            ?? (jsonObject["profile"] as? [String: Any])
            ?? [:]
        let authClaims = (claims["https://api.openai.com/auth"] as? [String: Any]) ?? [:]

        let chatgptAccountId = (tokens["account_id"] as? String)
            ?? (authClaims["chatgpt_account_id"] as? String)
            ?? ""
        let userId = (authClaims["chatgpt_user_id"] as? String)
            ?? (authClaims["user_id"] as? String)
            ?? (claims["sub"] as? String)
            ?? ""

        guard !chatgptAccountId.isEmpty, !userId.isEmpty else { return nil }

        let email = (claims["email"] as? String) ?? ""
        let name = (claims["name"] as? String) ?? email
        let planRaw = authClaims["chatgpt_plan_type"] as? String
        let plan = PlanInfo.normalized(kindRaw: planRaw, name: planRaw)

        return CodexAuthIdentity(
            canonicalAccountId: "codex:\(userId):\(chatgptAccountId)",
            userId: userId,
            chatgptAccountId: chatgptAccountId,
            email: email,
            displayName: name.isEmpty ? email : name,
            plan: plan
        )
    }

    /// Normalizes a Codex credential blob (either OrbitSwitch wrapper or raw `auth.json`) into canonical `auth.json` UTF-8 JSON bytes.
    public static func extractCanonicalCodexAuthData(from rawData: Data) -> Data? {
        guard let obj = (try? JSONSerialization.jsonObject(with: rawData, options: [])) as? [String: Any] else {
            return nil
        }
        if let credential = obj["credential"] as? [String: Any] {
            return try? JSONSerialization.data(withJSONObject: credential, options: [.sortedKeys])
        }
        if obj["tokens"] is [String: Any] {
            return rawData
        }
        return nil
    }
}
