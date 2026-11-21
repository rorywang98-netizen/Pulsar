import Foundation

// MARK: - Token Usage Range & Client Identification

public enum TokenUsageRange: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case today
    case days7
    case days30
    case allTime

    public static let presetCases: [TokenUsageRange] = [.today, .days7, .days30, .allTime]

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .today: return "今日"
        case .days7: return "7天"
        case .days30: return "30天"
        case .allTime: return "全部"
        }
    }

    public var shortLabel: String { displayName }
}

/// Unified date selection supporting both preset ranges (`today`/`days7`/`days30`/`allTime`)
/// and arbitrary custom single-day or multi-day ranges (`YYYY-MM-DD`).
public enum TokenUsageDateSelection: Codable, Equatable, Hashable, Sendable {
    case preset(TokenUsageRange)
    case custom(startDate: String, endDate: String)

    /// Default selection for Token Usage views (今日).
    public static let defaultSelection: TokenUsageDateSelection = .preset(.today)

    public var presetRange: TokenUsageRange? {
        if case .preset(let range) = self { return range }
        return nil
    }

    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    public var customBounds: (startDate: String, endDate: String)? {
        guard case .custom(let start, let end) = self else { return nil }
        let a = start.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = end.trimmingCharacters(in: .whitespacesAndNewlines)
        return a <= b ? (a, b) : (b, a)
    }

    public var displayName: String {
        switch self {
        case .preset(let range):
            return range.displayName
        case .custom(let start, let end):
            return TokenFormatters.customRangeLabel(startDate: start, endDate: end)
        }
    }

    public var shortLabel: String { displayName }

    /// Creates a normalized `.custom` selection (auto-swapping if `startDate > endDate`).
    public static func normalizedCustom(startDate: String, endDate: String) -> TokenUsageDateSelection {
        let a = startDate.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = endDate.trimmingCharacters(in: .whitespacesAndNewlines)
        return a <= b ? .custom(startDate: a, endDate: b) : .custom(startDate: b, endDate: a)
    }

    /// Creates a single-day `.custom` selection for a `YYYY-MM-DD` date key.
    public static func singleDay(_ date: String) -> TokenUsageDateSelection {
        let clean = date.trimmingCharacters(in: .whitespacesAndNewlines)
        return .custom(startDate: clean, endDate: clean)
    }

    /// Creates a normalized `.custom` selection from `Date` endpoints in the given timezone (default: local).
    public static func custom(start: Date, end: Date, timeZone: TimeZone = .current) -> TokenUsageDateSelection {
        normalizedCustom(
            startDate: TokenFormatters.ymdString(from: start, timeZone: timeZone),
            endDate: TokenFormatters.ymdString(from: end, timeZone: timeZone)
        )
    }
}

public enum TokenClientID: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case claude
    case codex
    case cursor
    case antigravity
    case grok
    case dsh
    case kimi
    case opencode
    case zcode
    case workbuddy
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .antigravity: return "Antigravity"
        case .grok: return "Grok"
        case .dsh: return "DeepSeek Harness"
        case .kimi: return "Kimi Code"
        case .opencode: return "OpenCode"
        case .zcode: return "ZCode"
        case .workbuddy: return "WorkBuddy"
        case .other: return "Other"
        }
    }

    public var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .antigravity: return "AGY"
        case .grok: return "Grok"
        case .dsh: return "DSH"
        case .kimi: return "Kimi"
        case .opencode: return "OpenCode"
        case .zcode: return "ZCode"
        case .workbuddy: return "WorkBuddy"
        case .other: return "Other"
        }
    }

    public var hexColor: String {
        switch self {
        case .claude: return "#D97757"
        case .codex: return "#10A37F"
        case .cursor: return "#3B82F6"
        case .antigravity: return "#8B5CF6"
        case .grok: return "#F59E0B"
        case .dsh: return "#06B6D4"
        case .kimi: return "#EC4899"
        case .opencode: return "#6366F1"
        case .zcode: return "#14B8A6"
        case .workbuddy: return "#84CC16"
        case .other: return "#64748B"
        }
    }

    public static func canonical(_ raw: String) -> TokenClientID {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "claude", "claude-code", "claudecode":
            return .claude
        case "codex", "openai-codex":
            return .codex
        case "cursor":
            return .cursor
        case "antigravity", "agy":
            return .antigravity
        case "grok", "grok-cli":
            return .grok
        case "dsh", "deepseek", "deepseek-harness":
            return .dsh
        case "kimi", "kimi-code", "kimicode":
            return .kimi
        case "opencode":
            return .opencode
        case "zcode":
            return .zcode
        case "workbuddy", "codebuddy":
            return .workbuddy
        default:
            return .other
        }
    }
}

// MARK: - Totals & Breakdowns

public struct TokenComponentTotals: Codable, Equatable, Hashable, Sendable {
    public var totalTokens: Int64
    public var uncachedInputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheWriteTokens: Int64
    public var reasoningTokens: Int64
    public var estimatedCostUSD: Double
    public var messageCount: Int

    public init(
        totalTokens: Int64 = 0,
        uncachedInputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        cacheWriteTokens: Int64 = 0,
        reasoningTokens: Int64 = 0,
        estimatedCostUSD: Double = 0.0,
        messageCount: Int = 0
    ) {
        let safeOut = max(Int64(0), outputTokens)
        let safeCR = max(Int64(0), cacheReadTokens)
        let safeCW = max(Int64(0), cacheWriteTokens)
        let safeUncached = max(Int64(0), uncachedInputTokens)
        let minTotal = safeUncached + safeOut + safeCR + safeCW
        self.totalTokens = max(max(Int64(0), totalTokens), minTotal)
        self.uncachedInputTokens = max(Int64(0), self.totalTokens - safeOut - safeCR - safeCW)
        self.outputTokens = safeOut
        self.cacheReadTokens = safeCR
        self.cacheWriteTokens = safeCW
        self.reasoningTokens = min(max(Int64(0), reasoningTokens), safeOut)
        self.estimatedCostUSD = (estimatedCostUSD.isFinite && estimatedCostUSD >= 0) ? estimatedCostUSD : 0.0
        self.messageCount = max(0, messageCount)
    }

    public static let zero = TokenComponentTotals()

    public var totalInputTokens: Int64 {
        uncachedInputTokens + cacheReadTokens + cacheWriteTokens
    }

    public var cacheHitRate: Double {
        let input = totalInputTokens
        guard input > 0 else { return 0.0 }
        return min(max(Double(cacheReadTokens) / Double(input), 0.0), 1.0)
    }

    public mutating func add(_ other: TokenComponentTotals) {
        totalTokens += other.totalTokens
        uncachedInputTokens += other.uncachedInputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheWriteTokens += other.cacheWriteTokens
        reasoningTokens += other.reasoningTokens
        if other.estimatedCostUSD.isFinite && other.estimatedCostUSD >= 0 {
            estimatedCostUSD += other.estimatedCostUSD
        }
        messageCount += other.messageCount
    }

    public func adding(_ other: TokenComponentTotals) -> TokenComponentTotals {
        var copy = self
        copy.add(other)
        return copy
    }
}

public struct TokenClientBreakdown: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String { client.rawValue }
    public var client: TokenClientID
    public var totals: TokenComponentTotals
    public var shareOfTokens: Double
    public var activeDays: Int

    public init(
        client: TokenClientID,
        totals: TokenComponentTotals,
        shareOfTokens: Double,
        activeDays: Int
    ) {
        self.client = client
        self.totals = totals
        self.shareOfTokens = min(max(shareOfTokens, 0.0), 1.0)
        self.activeDays = max(0, activeDays)
    }
}

public struct TokenModelBreakdown: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var client: TokenClientID
    public var modelId: String
    public var providerId: String
    public var totals: TokenComponentTotals
    public var shareOfTokens: Double

    public init(
        client: TokenClientID,
        modelId: String,
        providerId: String = "",
        totals: TokenComponentTotals,
        shareOfTokens: Double
    ) {
        self.id = "\(client.rawValue)|\(modelId)"
        self.client = client
        self.modelId = modelId
        self.providerId = providerId
        self.totals = totals
        self.shareOfTokens = min(max(shareOfTokens, 0.0), 1.0)
    }
}

public struct TokenProjectBreakdown: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var projectName: String
    public var pathDisplay: String
    public var clients: [TokenClientID]
    public var totals: TokenComponentTotals
    public var shareOfTokens: Double
    public var lastActiveDate: String

    public init(
        id: String,
        projectName: String,
        pathDisplay: String,
        clients: [TokenClientID],
        totals: TokenComponentTotals,
        shareOfTokens: Double,
        lastActiveDate: String
    ) {
        self.id = id
        self.projectName = projectName
        self.pathDisplay = pathDisplay
        self.clients = clients
        self.totals = totals
        self.shareOfTokens = min(max(shareOfTokens, 0.0), 1.0)
        self.lastActiveDate = lastActiveDate
    }
}

public struct TokenDailyPoint: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String { date }
    public var date: String
    public var totals: TokenComponentTotals
    public var activeTimeMs: Int64
    public var byClient: [TokenClientBreakdown]
    public var heatmapLevel: Int

    public init(
        date: String,
        totals: TokenComponentTotals,
        activeTimeMs: Int64 = 0,
        byClient: [TokenClientBreakdown] = [],
        heatmapLevel: Int = 0
    ) {
        self.date = date
        self.totals = totals
        self.activeTimeMs = max(0, activeTimeMs)
        self.byClient = byClient
        self.heatmapLevel = min(max(heatmapLevel, 0), 4)
    }
}

public struct TokenRangeSummary: Codable, Equatable, Sendable {
    public var range: TokenUsageRange
    public var startDate: String
    public var endDate: String
    public var totals: TokenComponentTotals
    public var activeDays: Int
    public var totalDaysInRange: Int
    public var byClient: [TokenClientBreakdown]
    public var byModel: [TokenModelBreakdown]
    public var byProject: [TokenProjectBreakdown]
    public var dailySeries: [TokenDailyPoint]
    public var isCustomRange: Bool

    public init(
        range: TokenUsageRange,
        startDate: String,
        endDate: String,
        totals: TokenComponentTotals,
        activeDays: Int,
        totalDaysInRange: Int,
        byClient: [TokenClientBreakdown],
        byModel: [TokenModelBreakdown],
        byProject: [TokenProjectBreakdown],
        dailySeries: [TokenDailyPoint],
        isCustomRange: Bool = false
    ) {
        self.range = range
        self.startDate = startDate
        self.endDate = endDate
        self.totals = totals
        self.activeDays = activeDays
        self.totalDaysInRange = totalDaysInRange
        self.byClient = byClient
        self.byModel = byModel
        self.byProject = byProject
        self.dailySeries = dailySeries
        self.isCustomRange = isCustomRange
    }

    private enum CodingKeys: String, CodingKey {
        case range
        case startDate
        case endDate
        case totals
        case activeDays
        case totalDaysInRange
        case byClient
        case byModel
        case byProject
        case dailySeries
        case isCustomRange
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.range = try c.decode(TokenUsageRange.self, forKey: .range)
        self.startDate = try c.decode(String.self, forKey: .startDate)
        self.endDate = try c.decode(String.self, forKey: .endDate)
        self.totals = try c.decode(TokenComponentTotals.self, forKey: .totals)
        self.activeDays = try c.decode(Int.self, forKey: .activeDays)
        self.totalDaysInRange = try c.decode(Int.self, forKey: .totalDaysInRange)
        self.byClient = try c.decodeIfPresent([TokenClientBreakdown].self, forKey: .byClient) ?? []
        self.byModel = try c.decodeIfPresent([TokenModelBreakdown].self, forKey: .byModel) ?? []
        self.byProject = try c.decodeIfPresent([TokenProjectBreakdown].self, forKey: .byProject) ?? []
        self.dailySeries = try c.decodeIfPresent([TokenDailyPoint].self, forKey: .dailySeries) ?? []
        self.isCustomRange = try c.decodeIfPresent(Bool.self, forKey: .isCustomRange) ?? false
    }

    public var displayTitle: String {
        isCustomRange
            ? TokenFormatters.customRangeLabel(startDate: startDate, endDate: endDate)
            : range.displayName
    }

    public static func empty(range: TokenUsageRange, date: String = "") -> TokenRangeSummary {
        TokenRangeSummary(
            range: range,
            startDate: date,
            endDate: date,
            totals: .zero,
            activeDays: 0,
            totalDaysInRange: range == .today ? 1 : (range == .days7 ? 7 : (range == .days30 ? 30 : 0)),
            byClient: [],
            byModel: [],
            byProject: [],
            dailySeries: [],
            isCustomRange: false
        )
    }

    public static func emptyCustom(startDate: String, endDate: String) -> TokenRangeSummary {
        let a = startDate.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = endDate.trimmingCharacters(in: .whitespacesAndNewlines)
        let (s, e) = a <= b ? (a, b) : (b, a)
        return TokenRangeSummary(
            range: .allTime,
            startDate: s,
            endDate: e,
            totals: .zero,
            activeDays: 0,
            totalDaysInRange: TokenFormatters.inclusiveDayCount(startDate: s, endDate: e) ?? 0,
            byClient: [],
            byModel: [],
            byProject: [],
            dailySeries: [],
            isCustomRange: true
        )
    }
}

// MARK: - Internal Day-Level Records Stored in Snapshot for Fast Interactive Filtering

public struct TokenModelDayRecord: Codable, Equatable, Hashable, Sendable {
    public var date: String        // YYYY-MM-DD
    public var client: TokenClientID
    public var modelId: String
    public var providerId: String
    public var totals: TokenComponentTotals

    public init(
        date: String,
        client: TokenClientID,
        modelId: String,
        providerId: String = "",
        totals: TokenComponentTotals
    ) {
        self.date = date
        self.client = client
        self.modelId = modelId
        self.providerId = providerId
        self.totals = totals
    }
}

public struct TokenProjectDayRecord: Codable, Equatable, Hashable, Sendable {
    public var date: String
    public var client: TokenClientID
    public var projectId: String
    public var projectName: String
    public var pathDisplay: String
    public var totals: TokenComponentTotals

    public init(
        date: String,
        client: TokenClientID,
        projectId: String,
        projectName: String,
        pathDisplay: String,
        totals: TokenComponentTotals
    ) {
        self.date = date
        self.client = client
        self.projectId = projectId
        self.projectName = projectName
        self.pathDisplay = pathDisplay
        self.totals = totals
    }
}

// MARK: - Live Token Generation Speed Models

public struct ModelSpeedStat: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var client: TokenClientID
    public var modelId: String
    public var latestOutputTokPerSec: Double
    public var averageOutputTokPerSec: Double
    public var peakOutputTokPerSec: Double
    public var latestTotalTokPerSec: Double
    public var sampleCount: Int
    public var lastOutputTokens: Int64
    public var lastDurationSec: Double
    public var lastActiveAt: Date

    public static func makeID(client: TokenClientID, modelId: String) -> String {
        "\(client.rawValue)::\(modelId)"
    }

    public init(
        client: TokenClientID,
        modelId: String,
        latestOutputTokPerSec: Double,
        averageOutputTokPerSec: Double,
        peakOutputTokPerSec: Double,
        latestTotalTokPerSec: Double,
        sampleCount: Int,
        lastOutputTokens: Int64,
        lastDurationSec: Double,
        lastActiveAt: Date
    ) {
        self.id = Self.makeID(client: client, modelId: modelId)
        self.client = client
        self.modelId = modelId
        let safeLatest = Self.sanitizeRate(latestOutputTokPerSec)
        let safeAvg = Self.sanitizeRate(averageOutputTokPerSec)
        let safePeak = max(safeLatest, max(safeAvg, Self.sanitizeRate(peakOutputTokPerSec)))
        self.latestOutputTokPerSec = safeLatest
        self.averageOutputTokPerSec = safeAvg
        self.peakOutputTokPerSec = safePeak
        self.latestTotalTokPerSec = Self.sanitizeRate(latestTotalTokPerSec)
        self.sampleCount = max(0, sampleCount)
        self.lastOutputTokens = max(Int64(0), lastOutputTokens)
        self.lastDurationSec = (lastDurationSec.isFinite && lastDurationSec >= 0) ? lastDurationSec : 0.0
        self.lastActiveAt = lastActiveAt
    }

    private static func sanitizeRate(_ rate: Double) -> Double {
        (rate.isFinite && rate > 0) ? rate : 0.0
    }
}

public struct LiveTokenSpeedSnapshot: Codable, Equatable, Sendable {
    public var sampledAt: Date
    public var isGenerating: Bool
    public var currentModel: ModelSpeedStat?
    public var rollingOutputTokPerSec60s: Double
    public var rollingTotalTokPerSec60s: Double
    public var recentModels: [ModelSpeedStat]
    public var modelSpeedIndex: [String: ModelSpeedStat]

    public init(
        sampledAt: Date = Date(),
        isGenerating: Bool = false,
        currentModel: ModelSpeedStat? = nil,
        rollingOutputTokPerSec60s: Double = 0.0,
        rollingTotalTokPerSec60s: Double = 0.0,
        recentModels: [ModelSpeedStat] = [],
        modelSpeedIndex: [String: ModelSpeedStat] = [:]
    ) {
        self.sampledAt = sampledAt
        self.isGenerating = isGenerating
        self.currentModel = currentModel
        self.rollingOutputTokPerSec60s = (rollingOutputTokPerSec60s.isFinite && rollingOutputTokPerSec60s > 0)
            ? rollingOutputTokPerSec60s : 0.0
        self.rollingTotalTokPerSec60s = (rollingTotalTokPerSec60s.isFinite && rollingTotalTokPerSec60s > 0)
            ? rollingTotalTokPerSec60s : 0.0
        self.recentModels = recentModels
        self.modelSpeedIndex = modelSpeedIndex
    }

    public static func empty(sampledAt: Date = Date()) -> LiveTokenSpeedSnapshot {
        LiveTokenSpeedSnapshot(sampledAt: sampledAt)
    }

    /// O(1) lookup by `(client, modelId)` using canonical key `"\(client.rawValue)::\(modelId)"`.
    public func speedStat(for client: TokenClientID, modelId: String) -> ModelSpeedStat? {
        modelSpeedIndex[ModelSpeedStat.makeID(client: client, modelId: modelId)]
    }
}

public struct TokenUsageSnapshot: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var lastScannedAt: Date
    public var seedDaysCount: Int
    public var totalDaysCount: Int
    public var liveScannedFilesCount: Int
    public var archiveFileURLPath: String
    public var heatmap112Days: [TokenDailyPoint]
    public var allDays: [TokenDailyPoint]
    public var ranges: [TokenUsageRange: TokenRangeSummary]

    /// Optional per-day project records retained to support interactive client & custom-date filtering in the dashboard.
    public var projectRecords: [TokenProjectDayRecord]

    /// Optional per-day model records retained to support arbitrary custom date / range model rankings (backward compatible).
    public var modelRecords: [TokenModelDayRecord]

    /// Optional live + recent 7-day model generation speed snapshot (backward compatible with legacy archives/snapshots).
    public var speedSnapshot: LiveTokenSpeedSnapshot?

    public init(
        generatedAt: Date,
        lastScannedAt: Date,
        seedDaysCount: Int,
        totalDaysCount: Int,
        liveScannedFilesCount: Int,
        archiveFileURLPath: String,
        heatmap112Days: [TokenDailyPoint],
        allDays: [TokenDailyPoint],
        ranges: [TokenUsageRange: TokenRangeSummary],
        projectRecords: [TokenProjectDayRecord] = [],
        modelRecords: [TokenModelDayRecord] = [],
        speedSnapshot: LiveTokenSpeedSnapshot? = nil
    ) {
        self.generatedAt = generatedAt
        self.lastScannedAt = lastScannedAt
        self.seedDaysCount = seedDaysCount
        self.totalDaysCount = totalDaysCount
        self.liveScannedFilesCount = liveScannedFilesCount
        self.archiveFileURLPath = archiveFileURLPath
        self.heatmap112Days = heatmap112Days
        self.allDays = allDays
        self.ranges = ranges
        self.projectRecords = projectRecords
        self.modelRecords = modelRecords
        self.speedSnapshot = speedSnapshot
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt
        case lastScannedAt
        case seedDaysCount
        case totalDaysCount
        case liveScannedFilesCount
        case archiveFileURLPath
        case heatmap112Days
        case allDays
        case ranges
        case projectRecords
        case modelRecords
        case speedSnapshot
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        self.lastScannedAt = try c.decode(Date.self, forKey: .lastScannedAt)
        self.seedDaysCount = try c.decode(Int.self, forKey: .seedDaysCount)
        self.totalDaysCount = try c.decode(Int.self, forKey: .totalDaysCount)
        self.liveScannedFilesCount = try c.decode(Int.self, forKey: .liveScannedFilesCount)
        self.archiveFileURLPath = try c.decode(String.self, forKey: .archiveFileURLPath)
        self.heatmap112Days = try c.decodeIfPresent([TokenDailyPoint].self, forKey: .heatmap112Days) ?? []
        self.allDays = try c.decodeIfPresent([TokenDailyPoint].self, forKey: .allDays) ?? []
        self.ranges = try c.decodeIfPresent([TokenUsageRange: TokenRangeSummary].self, forKey: .ranges) ?? [:]
        self.projectRecords = try c.decodeIfPresent([TokenProjectDayRecord].self, forKey: .projectRecords) ?? []
        self.modelRecords = try c.decodeIfPresent([TokenModelDayRecord].self, forKey: .modelRecords) ?? []
        self.speedSnapshot = try c.decodeIfPresent(LiveTokenSpeedSnapshot.self, forKey: .speedSnapshot)
    }

    /// Earliest and latest `YYYY-MM-DD` date strings that have recorded usage in this snapshot.
    public var availableDateBounds: (minDate: String, maxDate: String)? {
        var minDate: String?
        var maxDate: String?

        func consider(_ raw: String) {
            guard TokenFormatters.isValidYMD(raw) else { return }
            if let curMin = minDate {
                if raw < curMin { minDate = raw }
            } else {
                minDate = raw
            }
            if let curMax = maxDate {
                if raw > curMax { maxDate = raw }
            } else {
                maxDate = raw
            }
        }

        for day in allDays where day.totals.totalTokens > 0 {
            consider(day.date)
        }
        if minDate == nil {
            for day in allDays {
                consider(day.date)
            }
        }
        if minDate == nil {
            for rec in modelRecords where rec.totals.totalTokens > 0 {
                consider(rec.date)
            }
            for rec in projectRecords where rec.totals.totalTokens > 0 {
                consider(rec.date)
            }
            for day in heatmap112Days where day.totals.totalTokens > 0 {
                consider(day.date)
            }
        }
        if minDate == nil, let all = ranges[.allTime] {
            consider(all.startDate)
            consider(all.endDate)
        }

        guard let lo = minDate, let hi = maxDate else { return nil }
        return (lo, hi)
    }

    /// Unified query helper accepting either a preset range or a custom `[startDate, endDate]` selection.
    public func summary(
        for selection: TokenUsageDateSelection,
        clientFilter: TokenClientID? = nil
    ) -> TokenRangeSummary {
        switch selection {
        case .preset(let range):
            return summary(for: range, clientFilter: clientFilter)
        case .custom(let startDate, let endDate):
            return summary(startDate: startDate, endDate: endDate, clientFilter: clientFilter)
        }
    }

    /// Computes a full `TokenRangeSummary` for any custom `[startDate, endDate]` (`YYYY-MM-DD`, inclusive),
    /// auto-normalizing reversed bounds, filling contiguous calendar days (<= 180d span) with recomputed
    /// `heatmapLevel` (0..4), and aggregating exact `byClient`, `byModel`, and `byProject` breakdowns.
    public func summary(
        startDate: String,
        endDate: String,
        clientFilter: TokenClientID? = nil
    ) -> TokenRangeSummary {
        let sRaw = startDate.trimmingCharacters(in: .whitespacesAndNewlines)
        let eRaw = endDate.trimmingCharacters(in: .whitespacesAndNewlines)
        let sValid = TokenFormatters.isValidYMD(sRaw)
        let eValid = TokenFormatters.isValidYMD(eRaw)
        guard sValid || eValid else {
            return TokenRangeSummary.emptyCustom(startDate: sRaw, endDate: eRaw)
        }

        let sClean = sValid ? sRaw : eRaw
        let eClean = eValid ? eRaw : sRaw
        let (normStart, normEnd) = sClean <= eClean ? (sClean, eClean) : (eClean, sClean)

        // Build per-day map from `allDays` (with graceful fallbacks for synthetic/legacy snapshots).
        var dayByDate: [String: TokenDailyPoint] = [:]
        if !allDays.isEmpty {
            for day in allDays where day.date >= normStart && day.date <= normEnd {
                dayByDate[day.date] = day
            }
        } else if !heatmap112Days.isEmpty {
            for day in heatmap112Days where day.date >= normStart && day.date <= normEnd {
                dayByDate[day.date] = day
            }
        } else if !modelRecords.isEmpty {
            var byDateClient: [String: [TokenClientID: TokenComponentTotals]] = [:]
            for rec in modelRecords where rec.date >= normStart && rec.date <= normEnd && rec.totals.totalTokens > 0 {
                var cMap = byDateClient[rec.date] ?? [:]
                var cur = cMap[rec.client] ?? .zero
                cur.add(rec.totals)
                cMap[rec.client] = cur
                byDateClient[rec.date] = cMap
            }
            for (dk, cMap) in byDateClient {
                var dayTotals = TokenComponentTotals.zero
                for t in cMap.values { dayTotals.add(t) }
                let dDenom = Double(max(Int64(1), dayTotals.totalTokens))
                let clients = cMap.map { c, t in
                    TokenClientBreakdown(
                        client: c,
                        totals: t,
                        shareOfTokens: Double(t.totalTokens) / dDenom,
                        activeDays: t.totalTokens > 0 ? 1 : 0
                    )
                }
                .sorted { $0.totals.totalTokens > $1.totals.totalTokens }
                dayByDate[dk] = TokenDailyPoint(
                    date: dk,
                    totals: dayTotals,
                    activeTimeMs: 0,
                    byClient: clients,
                    heatmapLevel: 0
                )
            }
        }

        let spanDays = TokenFormatters.inclusiveDayCount(startDate: normStart, endDate: normEnd) ?? 1
        let maxContiguousDays = 180
        let seriesDates: [String]
        if spanDays <= maxContiguousDays {
            seriesDates = TokenFormatters.dateSequence(from: normStart, to: normEnd)
        } else if let filter = clientFilter {
            seriesDates = dayByDate
                .compactMap { dateKey, day -> String? in
                    guard let match = day.byClient.first(where: { $0.client == filter }),
                          match.totals.totalTokens > 0 else {
                        return nil
                    }
                    return dateKey
                }
                .sorted()
        } else {
            seriesDates = dayByDate
                .compactMap { dateKey, day in
                    day.totals.totalTokens > 0 ? dateKey : nil
                }
                .sorted()
        }

        var grandTotals = TokenComponentTotals.zero
        var activeDays = 0
        var clientTotals: [TokenClientID: TokenComponentTotals] = [:]
        var clientActiveDays: [TokenClientID: Int] = [:]
        var dailySeries: [TokenDailyPoint] = []
        dailySeries.reserveCapacity(seriesDates.count)

        for dateKey in seriesDates {
            if let filter = clientFilter {
                if let day = dayByDate[dateKey],
                   let match = day.byClient.first(where: { $0.client == filter }) {
                    grandTotals.add(match.totals)
                    if match.totals.totalTokens > 0 {
                        activeDays += 1
                        var cTot = clientTotals[filter] ?? .zero
                        cTot.add(match.totals)
                        clientTotals[filter] = cTot
                        clientActiveDays[filter, default: 0] += 1
                    }
                    dailySeries.append(
                        TokenDailyPoint(
                            date: dateKey,
                            totals: match.totals,
                            activeTimeMs: day.activeTimeMs,
                            byClient: match.totals.totalTokens > 0
                                ? [
                                    TokenClientBreakdown(
                                        client: filter,
                                        totals: match.totals,
                                        shareOfTokens: 1.0,
                                        activeDays: 1
                                    )
                                ]
                                : [],
                            heatmapLevel: 0
                        )
                    )
                } else {
                    dailySeries.append(TokenDailyPoint(date: dateKey, totals: .zero))
                }
            } else {
                if let day = dayByDate[dateKey] {
                    if day.totals.totalTokens > 0 {
                        grandTotals.add(day.totals)
                        activeDays += 1
                        for cb in day.byClient where cb.totals.totalTokens > 0 {
                            var cTot = clientTotals[cb.client] ?? .zero
                            cTot.add(cb.totals)
                            clientTotals[cb.client] = cTot
                            clientActiveDays[cb.client, default: 0] += 1
                        }
                    }
                    dailySeries.append(
                        TokenDailyPoint(
                            date: dateKey,
                            totals: day.totals,
                            activeTimeMs: day.activeTimeMs,
                            byClient: day.byClient,
                            heatmapLevel: 0
                        )
                    )
                } else {
                    dailySeries.append(TokenDailyPoint(date: dateKey, totals: .zero))
                }
            }
        }

        // Recompute heatmap levels (0..4) across the resulting daily series.
        let positiveTokens = dailySeries.map(\.totals.totalTokens).filter { $0 > 0 }
        let thresholds = Self.heatmapThresholds(from: positiveTokens)
        for idx in dailySeries.indices {
            dailySeries[idx].heatmapLevel = Self.heatmapLevel(
                tokens: dailySeries[idx].totals.totalTokens,
                thresholds: thresholds
            )
        }

        let denom = Double(max(Int64(1), grandTotals.totalTokens))
        let byClient = clientTotals.map { c, tot in
            TokenClientBreakdown(
                client: c,
                totals: tot,
                shareOfTokens: Double(tot.totalTokens) / denom,
                activeDays: clientActiveDays[c] ?? 0
            )
        }
        .sorted { lhs, rhs in
            if lhs.totals.totalTokens != rhs.totals.totalTokens {
                return lhs.totals.totalTokens > rhs.totals.totalTokens
            }
            return lhs.client.rawValue < rhs.client.rawValue
        }

        // Aggregate exact model rankings from `modelRecords` (with graceful fallback for legacy snapshots).
        let byModel: [TokenModelBreakdown]
        if !modelRecords.isEmpty {
            let matchingModels = modelRecords.filter { rec in
                rec.date >= normStart
                    && rec.date <= normEnd
                    && (clientFilter == nil || rec.client == clientFilter)
            }
            byModel = Self.aggregateModels(
                from: matchingModels,
                totalTokensDenominator: grandTotals.totalTokens > 0 ? grandTotals.totalTokens : nil
            )
        } else if let matchedPreset = ranges.values.first(where: { $0.startDate == normStart && $0.endDate == normEnd }) {
            let rawModels = clientFilter == nil
                ? matchedPreset.byModel
                : matchedPreset.byModel.filter { $0.client == clientFilter }
            let fallbackDenom = Double(max(
                Int64(1),
                grandTotals.totalTokens > 0
                    ? grandTotals.totalTokens
                    : rawModels.reduce(Int64(0)) { $0 + $1.totals.totalTokens }
            ))
            byModel = rawModels.map { m in
                TokenModelBreakdown(
                    client: m.client,
                    modelId: m.modelId,
                    providerId: m.providerId,
                    totals: m.totals,
                    shareOfTokens: Double(m.totals.totalTokens) / fallbackDenom
                )
            }
        } else {
            byModel = []
        }

        // Aggregate exact project rankings from `projectRecords` (with graceful fallback for legacy snapshots).
        let byProject: [TokenProjectBreakdown]
        if !projectRecords.isEmpty {
            let matchingProjects = projectRecords.filter { rec in
                rec.date >= normStart
                    && rec.date <= normEnd
                    && (clientFilter == nil || rec.client == clientFilter)
            }
            byProject = Self.aggregateProjects(from: matchingProjects)
        } else if let matchedPreset = ranges.values.first(where: { $0.startDate == normStart && $0.endDate == normEnd }) {
            if let filter = clientFilter {
                let filtered = matchedPreset.byProject.filter { $0.clients.contains(filter) }
                let pDenom = Double(max(Int64(1), filtered.reduce(Int64(0)) { $0 + $1.totals.totalTokens }))
                byProject = filtered.map { p in
                    TokenProjectBreakdown(
                        id: p.id,
                        projectName: p.projectName,
                        pathDisplay: p.pathDisplay,
                        clients: [filter],
                        totals: p.totals,
                        shareOfTokens: Double(p.totals.totalTokens) / pDenom,
                        lastActiveDate: p.lastActiveDate
                    )
                }
            } else {
                byProject = matchedPreset.byProject
            }
        } else {
            byProject = []
        }

        return TokenRangeSummary(
            range: .allTime,
            startDate: normStart,
            endDate: normEnd,
            totals: grandTotals,
            activeDays: activeDays,
            totalDaysInRange: spanDays,
            byClient: byClient,
            byModel: byModel,
            byProject: byProject,
            dailySeries: dailySeries,
            isCustomRange: true
        )
    }

    /// Convenience accessor returning either the precomputed summary or an interactive client-filtered slice.
    public func summary(for range: TokenUsageRange, clientFilter: TokenClientID? = nil) -> TokenRangeSummary {
        let base = ranges[range] ?? TokenRangeSummary.empty(range: range)
        guard let filter = clientFilter else {
            return base
        }

        var filteredTotals = TokenComponentTotals.zero
        var filteredDaily: [TokenDailyPoint] = []
        var activeDays = 0

        for day in base.dailySeries {
            if let match = day.byClient.first(where: { $0.client == filter }) {
                filteredTotals.add(match.totals)
                if match.totals.totalTokens > 0 {
                    activeDays += 1
                }
                let point = TokenDailyPoint(
                    date: day.date,
                    totals: match.totals,
                    activeTimeMs: day.activeTimeMs,
                    byClient: [
                        TokenClientBreakdown(
                            client: filter,
                            totals: match.totals,
                            shareOfTokens: 1.0,
                            activeDays: match.totals.totalTokens > 0 ? 1 : 0
                        )
                    ],
                    heatmapLevel: day.heatmapLevel
                )
                filteredDaily.append(point)
            } else {
                filteredDaily.append(TokenDailyPoint(date: day.date, totals: .zero))
            }
        }

        // Recompute heatmap levels across filtered daily series.
        let positiveTokens = filteredDaily.map(\.totals.totalTokens).filter { $0 > 0 }
        let thresholds = TokenUsageSnapshot.heatmapThresholds(from: positiveTokens)
        for idx in filteredDaily.indices {
            filteredDaily[idx].heatmapLevel = TokenUsageSnapshot.heatmapLevel(
                tokens: filteredDaily[idx].totals.totalTokens,
                thresholds: thresholds
            )
        }

        let filteredClients: [TokenClientBreakdown] = filteredTotals.totalTokens > 0
            ? [TokenClientBreakdown(client: filter, totals: filteredTotals, shareOfTokens: 1.0, activeDays: activeDays)]
            : []

        let denom = Double(max(Int64(1), filteredTotals.totalTokens))
        let filteredModels = base.byModel
            .filter { $0.client == filter }
            .map { m in
                TokenModelBreakdown(
                    client: m.client,
                    modelId: m.modelId,
                    providerId: m.providerId,
                    totals: m.totals,
                    shareOfTokens: Double(m.totals.totalTokens) / denom
                )
            }

        let filteredProjects: [TokenProjectBreakdown]
        if !projectRecords.isEmpty {
            let matchingRecords = projectRecords.filter { rec in
                rec.client == filter && rec.date >= base.startDate && rec.date <= base.endDate
            }
            filteredProjects = TokenUsageSnapshot.aggregateProjects(from: matchingRecords)
        } else {
            filteredProjects = base.byProject
                .filter { $0.clients.contains(filter) }
                .map { p in
                    TokenProjectBreakdown(
                        id: p.id,
                        projectName: p.projectName,
                        pathDisplay: p.pathDisplay,
                        clients: [filter],
                        totals: p.totals,
                        shareOfTokens: Double(p.totals.totalTokens) / denom,
                        lastActiveDate: p.lastActiveDate
                    )
                }
        }

        return TokenRangeSummary(
            range: range,
            startDate: base.startDate,
            endDate: base.endDate,
            totals: filteredTotals,
            activeDays: activeDays,
            totalDaysInRange: base.totalDaysInRange,
            byClient: filteredClients,
            byModel: filteredModels,
            byProject: filteredProjects,
            dailySeries: filteredDaily
        )
    }

    /// Returns the last `days` calendar days (default 112 = 16 weeks) with optional client filtering & recalculated levels 0..4.
    public func heatmap(days: Int = 112, clientFilter: TokenClientID? = nil) -> [TokenDailyPoint] {
        let clampedCount = max(1, days)
        let source: [TokenDailyPoint]
        if clampedCount == heatmap112Days.count {
            source = heatmap112Days
        } else if clampedCount < heatmap112Days.count {
            source = Array(heatmap112Days.suffix(clampedCount))
        } else {
            source = Array(allDays.suffix(clampedCount))
        }

        guard let filter = clientFilter else {
            return source
        }

        var filtered = source.map { day -> TokenDailyPoint in
            if let match = day.byClient.first(where: { $0.client == filter }) {
                return TokenDailyPoint(
                    date: day.date,
                    totals: match.totals,
                    activeTimeMs: day.activeTimeMs,
                    byClient: [
                        TokenClientBreakdown(
                            client: filter,
                            totals: match.totals,
                            shareOfTokens: 1.0,
                            activeDays: match.totals.totalTokens > 0 ? 1 : 0
                        )
                    ],
                    heatmapLevel: 0
                )
            }
            return TokenDailyPoint(date: day.date, totals: .zero)
        }

        let thresholds = Self.heatmapThresholds(from: filtered.map(\.totals.totalTokens).filter { $0 > 0 })
        for idx in filtered.indices {
            filtered[idx].heatmapLevel = Self.heatmapLevel(tokens: filtered[idx].totals.totalTokens, thresholds: thresholds)
        }
        return filtered
    }

    // MARK: - Shared Aggregation Helpers

    public static func heatmapThresholds(from positiveValues: [Int64]) -> (Int64, Int64, Int64) {
        guard !positiveValues.isEmpty else { return (1, 2, 3) }
        let sorted = positiveValues.sorted()
        let q1 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.25))]
        let q2 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.50))]
        let q3 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.75))]
        return (max(1, q1), max(1, q2), max(1, q3))
    }

    public static func heatmapLevel(tokens: Int64, thresholds: (Int64, Int64, Int64)) -> Int {
        guard tokens > 0 else { return 0 }
        if tokens <= thresholds.0 { return 1 }
        if tokens <= thresholds.1 { return 2 }
        if tokens <= thresholds.2 { return 3 }
        return 4
    }

    public static func aggregateModels(
        from records: [TokenModelDayRecord],
        totalTokensDenominator: Int64? = nil
    ) -> [TokenModelBreakdown] {
        struct Key: Hashable {
            let client: TokenClientID
            let modelId: String
        }
        struct Acc {
            var providerId: String
            var totals: TokenComponentTotals
        }
        var map: [Key: Acc] = [:]
        var sumTokens: Int64 = 0

        for rec in records where rec.totals.totalTokens > 0 {
            sumTokens += rec.totals.totalTokens
            let k = Key(client: rec.client, modelId: rec.modelId)
            if var acc = map[k] {
                acc.totals.add(rec.totals)
                if acc.providerId.isEmpty && !rec.providerId.isEmpty {
                    acc.providerId = rec.providerId
                }
                map[k] = acc
            } else {
                map[k] = Acc(providerId: rec.providerId, totals: rec.totals)
            }
        }

        let denom = Double(max(Int64(1), totalTokensDenominator ?? sumTokens))
        return map.map { key, acc in
            let resolvedProvider = acc.providerId.isEmpty
                ? TokenPricingCatalog.defaultProviderId(for: key.modelId, client: key.client)
                : acc.providerId
            return TokenModelBreakdown(
                client: key.client,
                modelId: key.modelId,
                providerId: resolvedProvider,
                totals: acc.totals,
                shareOfTokens: Double(acc.totals.totalTokens) / denom
            )
        }
        .sorted { lhs, rhs in
            if lhs.totals.totalTokens != rhs.totals.totalTokens {
                return lhs.totals.totalTokens > rhs.totals.totalTokens
            }
            if lhs.modelId != rhs.modelId {
                return lhs.modelId < rhs.modelId
            }
            return lhs.client.rawValue < rhs.client.rawValue
        }
    }

    public static func aggregateProjects(from records: [TokenProjectDayRecord]) -> [TokenProjectBreakdown] {
        struct Acc {
            var projectName: String
            var pathDisplay: String
            var clients: Set<TokenClientID> = []
            var totals: TokenComponentTotals = .zero
            var lastActiveDate: String = ""
        }
        var map: [String: Acc] = [:]
        var grandTotal: Int64 = 0
        for rec in records where rec.totals.totalTokens > 0 {
            grandTotal += rec.totals.totalTokens
            if var acc = map[rec.projectId] {
                acc.clients.insert(rec.client)
                acc.totals.add(rec.totals)
                if rec.date > acc.lastActiveDate {
                    acc.lastActiveDate = rec.date
                }
                map[rec.projectId] = acc
            } else {
                map[rec.projectId] = Acc(
                    projectName: rec.projectName,
                    pathDisplay: rec.pathDisplay,
                    clients: [rec.client],
                    totals: rec.totals,
                    lastActiveDate: rec.date
                )
            }
        }
        let denom = Double(max(Int64(1), grandTotal))
        return map.map { id, acc in
            let sortedClients = acc.clients.sorted { $0.rawValue < $1.rawValue }
            return TokenProjectBreakdown(
                id: id,
                projectName: acc.projectName,
                pathDisplay: acc.pathDisplay,
                clients: sortedClients,
                totals: acc.totals,
                shareOfTokens: Double(acc.totals.totalTokens) / denom,
                lastActiveDate: acc.lastActiveDate
            )
        }
        .sorted { lhs, rhs in
            if lhs.totals.totalTokens != rhs.totals.totalTokens {
                return lhs.totals.totalTokens > rhs.totals.totalTokens
            }
            return lhs.projectName < rhs.projectName
        }
    }
}

// MARK: - Formatting Helpers

public enum TokenFormatters {
    public static func compactTokens(_ count: Int64) -> String {
        let absVal = Double(abs(count))
        let sign = count < 0 ? "-" : ""
        if absVal >= 1_000_000_000 {
            return String(format: "%@%.2fB", sign, absVal / 1_000_000_000.0)
        }
        if absVal >= 100_000_000 {
            return String(format: "%@%.0fM", sign, absVal / 1_000_000.0)
        }
        if absVal >= 1_000_000 {
            return String(format: "%@%.1fM", sign, absVal / 1_000_000.0)
        }
        if absVal >= 10_000 {
            return String(format: "%@%.1fK", sign, absVal / 1_000.0)
        }
        if absVal >= 1_000 {
            return String(format: "%@%.2fK", sign, absVal / 1_000.0)
        }
        return "\(count)"
    }

    public static func exactTokens(_ count: Int64) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.groupingSeparator = ","
        return nf.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    public static func usd(_ amount: Double) -> String {
        let safe = (amount.isFinite && amount >= 0) ? amount : 0.0
        if safe >= 1000.0 {
            let nf = NumberFormatter()
            nf.numberStyle = .decimal
            nf.minimumFractionDigits = 2
            nf.maximumFractionDigits = 2
            nf.groupingSeparator = ","
            let formatted = nf.string(from: NSNumber(value: safe)) ?? String(format: "%.2f", safe)
            return "$\(formatted)"
        }
        if safe > 0 && safe < 0.01 {
            return String(format: "$%.4f", safe)
        }
        return String(format: "$%.2f", safe)
    }

    public static func percent(_ ratio: Double) -> String {
        let clamped = min(max(ratio.isFinite ? ratio : 0.0, 0.0), 1.0)
        return String(format: "%.1f%%", clamped * 100.0)
    }

    public static func tokensPerSec(_ rate: Double) -> String {
        guard rate.isFinite, rate >= 0.05 else {
            return "0 tok/s"
        }
        if rate >= 10_000.0 {
            return String(format: "%.0fk tok/s", rate / 1_000.0)
        }
        if rate >= 1_000.0 {
            return String(format: "%.1fk tok/s", rate / 1_000.0)
        }
        if rate >= 100.0 {
            return String(format: "%.0f tok/s", rate)
        }
        return String(format: "%.1f tok/s", rate)
    }

    public static func compactModelName(_ modelId: String) -> String {
        let trimmed = modelId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !trimmed.isEmpty else { return "Model" }
        let baseRaw = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        let base = baseRaw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let lower = base.lowercased()
        if lower.isEmpty || lower == "unknown" || lower == "unknown-model" {
            return "Model"
        }

        let tokens = lower.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).map(String.init)

        // Anthropic Claude models (e.g. claude-opus-5-5 -> "Opus 5.5", claude-4-5-sonnet -> "Sonnet 4.5")
        let claudeFamilies: [(key: String, label: String)] = [
            ("opus", "Opus"),
            ("sonnet", "Sonnet"),
            ("haiku", "Haiku"),
            ("fable", "Fable"),
        ]
        for fam in claudeFamilies where tokens.contains(fam.key) {
            var nums: [String] = []
            for tok in tokens {
                if Self.isShortVersionToken(tok) {
                    nums.append(tok)
                    if nums.count == 2 { break }
                }
            }
            if nums.isEmpty { return fam.label }
            if nums.count == 2 && !nums[0].contains(".") && !nums[1].contains(".") {
                return "\(fam.label) \(nums[0]).\(nums[1])"
            }
            return "\(fam.label) \(nums[0])"
        }

        // Google Gemini / Antigravity models
        if lower.contains("neon") { return "Neon" }
        if lower.contains("carbon") { return "Carbon" }
        if lower.contains("hydrogen") { return "Hydrogen" }
        if lower.contains("argon") { return "Argon" }
        if lower.contains("orchestrator") { return "Orch" }
        if lower.hasPrefix("gemini") {
            if let ver = tokens.dropFirst().first(where: { Self.isShortVersionToken($0) }) {
                return "Gemini \(ver)"
            }
            return "Gemini"
        }

        // OpenAI / Codex GPT models (e.g. gpt-6.1-sol -> "GPT-6.1", gpt-6-astra -> "GPT-6")
        if lower.hasPrefix("gpt") {
            if let ver = tokens.dropFirst().first(where: { tok in
                Self.isShortVersionToken(tok) || tok == "4o"
            }) {
                return "GPT-\(ver)"
            }
            return "GPT"
        }
        if lower.contains("codex") {
            return "Codex"
        }

        // xAI Grok models (e.g. grok-4.7-build -> "Grok 4.7", cursor-grok-4.6-high -> "Grok 4.6")
        if lower.contains("grok") {
            if lower.contains("grok-bot") { return "Grok Bot" }
            if let grokIdx = tokens.firstIndex(of: "grok"),
               grokIdx + 1 < tokens.count,
               Self.isShortVersionToken(tokens[grokIdx + 1]) {
                return "Grok \(tokens[grokIdx + 1])"
            }
            return "Grok"
        }

        // DeepSeek models
        if lower.contains("deepseek") {
            if let vTok = tokens.first(where: { $0.hasPrefix("v") && $0.count <= 5 && $0.dropFirst().first?.isNumber == true }) {
                return "DS \(vTok)"
            }
            if let rTok = tokens.first(where: { $0.hasPrefix("r") && $0.count <= 4 && $0.dropFirst().first?.isNumber == true }) {
                return "DS \(rTok.uppercased())"
            }
            if lower.contains("flash") { return "DS Flash" }
            if lower.contains("pro") { return "DS Pro" }
            return "DeepSeek"
        }

        // Kimi / Moonshot models (e.g. k3.1-pro-highspeed -> "Kimi 3.1", kimi-k3 -> "Kimi K3")
        if lower.contains("kimi") || lower.hasPrefix("k2") || lower.hasPrefix("k3") {
            if let kTok = tokens.first(where: { ($0.hasPrefix("k2") || $0.hasPrefix("k3")) && $0.count <= 5 }) {
                let ver = String(kTok.dropFirst())
                if ver.contains(".") {
                    return "Kimi \(ver)"
                }
                return "Kimi \(kTok.uppercased())"
            }
            return "Kimi"
        }

        // ZAI / GLM models (e.g. GLM-5.3-Flash -> "GLM-5.3")
        if lower.hasPrefix("glm") {
            if let ver = tokens.dropFirst().first(where: { Self.isShortVersionToken($0) }) {
                return "GLM-\(ver)"
            }
            return "GLM"
        }

        // Qwen models (e.g. qwen3.8-max -> "Qwen 3.8")
        if lower.hasPrefix("qwen") {
            let after = String(lower.dropFirst(4))
            let ver = after.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
            if Self.isShortVersionToken(ver) {
                return "Qwen \(ver)"
            }
            if let tokVer = tokens.dropFirst().first(where: { Self.isShortVersionToken($0) }) {
                return "Qwen \(tokVer)"
            }
            return "Qwen"
        }

        // MiniMax models
        if lower.contains("minimax") {
            if let mTok = tokens.first(where: { $0.hasPrefix("m") && $0.count <= 5 && $0.dropFirst().first?.isNumber == true }) {
                return "MiniMax \(mTok.uppercased())"
            }
            return "MiniMax"
        }

        // Generic fallback: drop noisy trailing tier/effort suffixes and cap length cleanly.
        let noiseSuffixes: Set<String> = [
            "xhigh", "high", "medium", "low", "fast", "free", "thinking",
            "max", "preview", "build", "contributor", "exp", "tiered", "highspeed",
        ]
        var cleaned = tokens
        while cleaned.count > 1, let last = cleaned.last, noiseSuffixes.contains(last) {
            cleaned.removeLast()
        }
        let joined = cleaned.joined(separator: "-")
        if joined.count <= 14 {
            return joined
        }
        return String(joined.prefix(14))
    }

    private static func isShortVersionToken(_ tok: String) -> Bool {
        guard !tok.isEmpty, tok.count <= 5 else { return false }
        var hasDigit = false
        for ch in tok {
            if ch.isNumber {
                hasDigit = true
            } else if ch != "." {
                return false
            }
        }
        // Exclude 4+ digit integer date stamps like 0813 or 20250514
        if !tok.contains(".") && tok.count >= 4 {
            return false
        }
        return hasDigit
    }

    // MARK: - Date Range & YMD Formatting Helpers

    private static func parseYMDComponents(_ raw: String) -> (year: Int, month: Int, day: Int)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = Array(trimmed.utf8)
        guard b.count == 10, b[4] == 45, b[7] == 45 else { return nil }

        func digit(_ i: Int) -> Int? {
            let v = b[i]
            guard v >= 48 && v <= 57 else { return nil }
            return Int(v - 48)
        }
        guard let y0 = digit(0), let y1 = digit(1), let y2 = digit(2), let y3 = digit(3),
              let m0 = digit(5), let m1 = digit(6),
              let d0 = digit(8), let d1 = digit(9) else {
            return nil
        }

        let year = y0 * 1000 + y1 * 100 + y2 * 10 + y3
        let month = m0 * 10 + m1
        let day = d0 * 10 + d1

        guard year >= 1970 && year <= 2100, (1...12).contains(month) else {
            return nil
        }
        let maxDay = daysInMonth(year: year, month: month)
        guard (1...maxDay).contains(day) else {
            return nil
        }
        return (year, month, day)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12:
            return 31
        case 4, 6, 9, 11:
            return 30
        case 2:
            let isLeap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
            return isLeap ? 29 : 28
        default:
            return 0
        }
    }

    private static func civilToEpochDays(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func epochDaysToCivil(_ z0: Int) -> (year: Int, month: Int, day: Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (y + (m <= 2 ? 1 : 0), m, d)
    }

    /// Returns `true` when `string` is a valid Gregorian calendar date in `YYYY-MM-DD` format.
    public static func isValidYMD(_ string: String) -> Bool {
        parseYMDComponents(string) != nil
    }

    /// Formats a `Date` as `YYYY-MM-DD` in the given timezone (default: local `.current`).
    public static func ymdString(from date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    /// Parses a `YYYY-MM-DD` date string into start-of-day `Date` in the given timezone (default: local `.current`).
    public static func date(fromYMD string: String, timeZone: TimeZone = .current) -> Date? {
        guard let (year, month, day) = parseYMDComponents(string) else {
            return nil
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var comps = DateComponents()
        comps.calendar = cal
        comps.timeZone = timeZone
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 0
        comps.minute = 0
        comps.second = 0
        return cal.date(from: comps)
    }

    /// Returns inclusive calendar day count between `startDate` and `endDate` (auto-swaps if reversed).
    public static func inclusiveDayCount(startDate: String, endDate: String) -> Int? {
        guard let s = parseYMDComponents(startDate),
              let e = parseYMDComponents(endDate) else {
            return nil
        }
        let d1 = civilToEpochDays(year: s.year, month: s.month, day: s.day)
        let d2 = civilToEpochDays(year: e.year, month: e.month, day: e.day)
        return abs(d2 - d1) + 1
    }

    /// Returns contiguous `YYYY-MM-DD` calendar dates from `startDate` through `endDate` inclusive (auto-swaps if reversed).
    public static func dateSequence(from startDate: String, to endDate: String) -> [String] {
        guard let s = parseYMDComponents(startDate),
              let e = parseYMDComponents(endDate) else {
            return []
        }
        let raw1 = civilToEpochDays(year: s.year, month: s.month, day: s.day)
        let raw2 = civilToEpochDays(year: e.year, month: e.month, day: e.day)
        let lo = min(raw1, raw2)
        let hi = max(raw1, raw2)
        var out: [String] = []
        out.reserveCapacity(hi - lo + 1)
        for dayNum in lo...hi {
            let (y, m, d) = epochDaysToCivil(dayNum)
            out.append(String(format: "%04d-%02d-%02d", y, m, d))
        }
        return out
    }

    /// Formats a concise display label for a custom date or range (e.g. `"11-18"`, `"2025-11-18"`, `"11-10 ~ 11-18"`).
    public static func customRangeLabel(
        startDate: String,
        endDate: String,
        referenceYear: Int? = nil
    ) -> String {
        let sRaw = startDate.trimmingCharacters(in: .whitespacesAndNewlines)
        let eRaw = endDate.trimmingCharacters(in: .whitespacesAndNewlines)
        if sRaw.isEmpty && eRaw.isEmpty {
            return "自定义"
        }
        guard let sComp = parseYMDComponents(sRaw),
              let eComp = parseYMDComponents(eRaw) else {
            let lo = sRaw.isEmpty ? eRaw : sRaw
            let hi = eRaw.isEmpty ? sRaw : eRaw
            if lo == hi { return lo }
            return lo <= hi ? "\(lo) ~ \(hi)" : "\(hi) ~ \(lo)"
        }

        let (lo, hi) = sRaw <= eRaw ? (sComp, eComp) : (eComp, sComp)
        let currentYear = referenceYear ?? Calendar(identifier: .gregorian).component(.year, from: Date())

        if lo.year == hi.year && lo.month == hi.month && lo.day == hi.day {
            if lo.year == currentYear {
                return String(format: "%02d-%02d", lo.month, lo.day)
            }
            return String(format: "%04d-%02d-%02d", lo.year, lo.month, lo.day)
        }

        if lo.year == hi.year && lo.year == currentYear {
            return String(format: "%02d-%02d ~ %02d-%02d", lo.month, lo.day, hi.month, hi.day)
        }
        return String(
            format: "%04d-%02d-%02d ~ %04d-%02d-%02d",
            lo.year, lo.month, lo.day,
            hi.year, hi.month, hi.day
        )
    }
}

// MARK: - Official Offline Model Pricing Catalog (USD per 1M tokens)

public struct TokenModelPricing: Equatable, Sendable {
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public let cacheReadPerMillion: Double
    public let cacheWritePerMillion: Double

    public init(
        inputPerMillion: Double,
        outputPerMillion: Double,
        cacheReadPerMillion: Double,
        cacheWritePerMillion: Double
    ) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
    }

    public func estimateCostUSD(
        uncachedInput: Int64,
        output: Int64,
        cacheRead: Int64,
        cacheWrite: Int64
    ) -> Double {
        let m = 1_000_000.0
        let cost = (Double(max(0, uncachedInput)) * inputPerMillion
            + Double(max(0, output)) * outputPerMillion
            + Double(max(0, cacheRead)) * cacheReadPerMillion
            + Double(max(0, cacheWrite)) * cacheWritePerMillion) / m
        return (cost.isFinite && cost >= 0) ? cost : 0.0
    }
}

public enum TokenPricingCatalog {
    public static let pricingRevision = "roryorbit-local-v1"

    /// Resolves USD per 1M token pricing for a model ID (prefix & family normalized, 100% offline).
    public static func pricing(for modelId: String, client: TokenClientID) -> TokenModelPricing {
        let raw = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Strip provider prefix like "kimi for coding/" or "anthropic/"
        let normalized = raw.split(separator: "/").last.map(String.init) ?? raw

        // Anthropic Claude models
        if normalized.contains("claude-opus") || normalized.contains("opus-5") || normalized.contains("opus-4") {
            return TokenModelPricing(inputPerMillion: 5.0, outputPerMillion: 25.0, cacheReadPerMillion: 0.50, cacheWritePerMillion: 6.25)
        }
        if normalized.contains("claude-fable") {
            return TokenModelPricing(inputPerMillion: 5.0, outputPerMillion: 25.0, cacheReadPerMillion: 0.50, cacheWritePerMillion: 6.25)
        }
        if normalized.contains("claude-sonnet") || normalized.contains("sonnet") {
            return TokenModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75)
        }
        if normalized.contains("claude-haiku") || normalized.contains("haiku") {
            return TokenModelPricing(inputPerMillion: 1.0, outputPerMillion: 5.0, cacheReadPerMillion: 0.10, cacheWritePerMillion: 1.25)
        }

        // OpenAI / Codex GPT models
        if normalized.contains("gpt-6") && normalized.contains("astra") {
            return TokenModelPricing(inputPerMillion: 2.50, outputPerMillion: 15.0, cacheReadPerMillion: 0.25, cacheWritePerMillion: 2.50)
        }
        if normalized.contains("gpt-6") && normalized.contains("sol") {
            return TokenModelPricing(inputPerMillion: 1.75, outputPerMillion: 14.0, cacheReadPerMillion: 0.175, cacheWritePerMillion: 1.75)
        }
        if normalized.contains("gpt-6") && normalized.contains("terra") {
            return TokenModelPricing(inputPerMillion: 1.25, outputPerMillion: 10.0, cacheReadPerMillion: 0.125, cacheWritePerMillion: 1.25)
        }
        if normalized.contains("gpt-5") || normalized.contains("o3") || normalized.contains("o4") || normalized.contains("codex") {
            return TokenModelPricing(inputPerMillion: 1.75, outputPerMillion: 14.0, cacheReadPerMillion: 0.175, cacheWritePerMillion: 1.75)
        }
        if normalized.contains("gpt-4o-mini") || normalized.contains("mini") {
            return TokenModelPricing(inputPerMillion: 0.25, outputPerMillion: 2.0, cacheReadPerMillion: 0.025, cacheWritePerMillion: 0.25)
        }
        if normalized.contains("gpt-") {
            return TokenModelPricing(inputPerMillion: 2.0, outputPerMillion: 10.0, cacheReadPerMillion: 0.20, cacheWritePerMillion: 2.0)
        }

        // Google Gemini / Antigravity models
        if normalized.contains("gemini-4-neon") || normalized.contains("gemini-4-hydrogen") || normalized.contains("gemini-4-argon") {
            return TokenModelPricing(inputPerMillion: 2.50, outputPerMillion: 15.0, cacheReadPerMillion: 0.25, cacheWritePerMillion: 2.50)
        }
        if normalized.contains("gemini-4-carbon") || normalized.contains("gemini-pro-orchestrator") || normalized.contains("gemini-3") && normalized.contains("pro") {
            return TokenModelPricing(inputPerMillion: 2.0, outputPerMillion: 12.0, cacheReadPerMillion: 0.20, cacheWritePerMillion: 2.0)
        }
        if normalized.contains("gemini") && (normalized.contains("flash") || normalized.contains("worker")) {
            return TokenModelPricing(inputPerMillion: 0.30, outputPerMillion: 2.50, cacheReadPerMillion: 0.03, cacheWritePerMillion: 0.30)
        }
        if normalized.contains("gemini") {
            return TokenModelPricing(inputPerMillion: 1.50, outputPerMillion: 10.0, cacheReadPerMillion: 0.15, cacheWritePerMillion: 1.50)
        }

        // xAI Grok models
        if normalized.contains("grok-bot") {
            return TokenModelPricing(inputPerMillion: 2.0, outputPerMillion: 10.0, cacheReadPerMillion: 0.50, cacheWritePerMillion: 2.0)
        }
        if normalized.contains("grok") && normalized.contains("fast") {
            return TokenModelPricing(inputPerMillion: 0.60, outputPerMillion: 3.0, cacheReadPerMillion: 0.15, cacheWritePerMillion: 0.60)
        }
        if normalized.contains("grok") {
            return TokenModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.75, cacheWritePerMillion: 3.0)
        }

        // DeepSeek models
        if normalized.contains("deepseek") && normalized.contains("flash") {
            return TokenModelPricing(inputPerMillion: 0.14, outputPerMillion: 0.28, cacheReadPerMillion: 0.014, cacheWritePerMillion: 0.14)
        }
        if normalized.contains("deepseek") {
            return TokenModelPricing(inputPerMillion: 0.28, outputPerMillion: 0.42, cacheReadPerMillion: 0.028, cacheWritePerMillion: 0.28)
        }

        // Kimi / Moonshot models
        if normalized.contains("kimi") || normalized.contains("k2") || normalized.contains("k3") || normalized.contains("moonshot") {
            return TokenModelPricing(inputPerMillion: 0.60, outputPerMillion: 2.50, cacheReadPerMillion: 0.15, cacheWritePerMillion: 0.60)
        }

        // ZAI / GLM models
        if normalized.contains("glm") && normalized.contains("flash") {
            return TokenModelPricing(inputPerMillion: 0.10, outputPerMillion: 0.40, cacheReadPerMillion: 0.02, cacheWritePerMillion: 0.10)
        }
        if normalized.contains("glm") {
            return TokenModelPricing(inputPerMillion: 0.60, outputPerMillion: 2.20, cacheReadPerMillion: 0.12, cacheWritePerMillion: 0.60)
        }

        // Free / zero-cost tagged models
        if normalized.hasSuffix("-free") || normalized.contains(":free") {
            return TokenModelPricing(inputPerMillion: 0.0, outputPerMillion: 0.0, cacheReadPerMillion: 0.0, cacheWritePerMillion: 0.0)
        }

        // Sensible per-client fallback
        switch client {
        case .claude:
            return TokenModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75)
        case .codex:
            return TokenModelPricing(inputPerMillion: 1.75, outputPerMillion: 14.0, cacheReadPerMillion: 0.175, cacheWritePerMillion: 1.75)
        case .antigravity:
            return TokenModelPricing(inputPerMillion: 1.50, outputPerMillion: 10.0, cacheReadPerMillion: 0.15, cacheWritePerMillion: 1.50)
        case .grok:
            return TokenModelPricing(inputPerMillion: 2.0, outputPerMillion: 10.0, cacheReadPerMillion: 0.50, cacheWritePerMillion: 2.0)
        case .dsh:
            return TokenModelPricing(inputPerMillion: 0.14, outputPerMillion: 0.28, cacheReadPerMillion: 0.014, cacheWritePerMillion: 0.14)
        case .kimi:
            return TokenModelPricing(inputPerMillion: 0.60, outputPerMillion: 2.50, cacheReadPerMillion: 0.15, cacheWritePerMillion: 0.60)
        case .zcode:
            return TokenModelPricing(inputPerMillion: 0.40, outputPerMillion: 1.60, cacheReadPerMillion: 0.08, cacheWritePerMillion: 0.40)
        default:
            return TokenModelPricing(inputPerMillion: 1.0, outputPerMillion: 5.0, cacheReadPerMillion: 0.10, cacheWritePerMillion: 1.0)
        }
    }

    public static func defaultProviderId(for modelId: String, client: TokenClientID) -> String {
        let lower = modelId.lowercased()
        if lower.contains("claude") { return "anthropic" }
        if lower.contains("gpt") || lower.contains("o3") || lower.contains("o4") || lower.contains("codex") { return "openai" }
        if lower.contains("gemini") { return "google" }
        if lower.contains("grok") { return "xai" }
        if lower.contains("deepseek") { return "deepseek-official" }
        if lower.contains("kimi") || lower.contains("k2") || lower.contains("k3") { return "moonshot" }
        if lower.contains("glm") { return "zhipu" }
        switch client {
        case .claude: return "anthropic"
        case .codex: return "openai"
        case .antigravity: return "google"
        case .grok: return "xai"
        case .dsh: return "deepseek-official"
        case .kimi: return "moonshot"
        case .zcode: return "zhipu"
        case .opencode: return "opencode"
        case .workbuddy: return "tencent"
        case .cursor: return "cursor"
        case .other: return "unknown"
        }
    }
}
