import Darwin
import Foundation
import SQLite3

// MARK: - In-Process Dynamic libzstd Streaming Decompressor (Zero Child CLI)

private final class DynamicZstdLoader: @unchecked Sendable {
    static let shared = DynamicZstdLoader()

    private typealias CreateDCtxFn = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias FreeDCtxFn = @convention(c) (UnsafeMutableRawPointer?) -> Int
    /// C signature: `size_t ZSTD_decompressStream(ZSTD_DStream* zds, ZSTD_outBuffer* output, ZSTD_inBuffer* input)`
    /// Both buffer structs have exact 3-word C ABI layout `{ void* ptr; size_t size; size_t pos; }`.
    private typealias DecompressStreamFn = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?
    ) -> Int
    private typealias IsErrorFn = @convention(c) (Int) -> UInt32

    private let createDCtx: CreateDCtxFn?
    private let freeDCtx: FreeDCtxFn?
    private let decompressStream: DecompressStreamFn?
    private let isError: IsErrorFn?

    var isAvailable: Bool {
        createDCtx != nil && freeDCtx != nil && decompressStream != nil && isError != nil
    }

    private init() {
        let candidates = [
            "/opt/homebrew/lib/libzstd.dylib",
            "/usr/local/lib/libzstd.dylib",
            "/opt/homebrew/lib/libzstd.1.dylib",
            "/usr/local/lib/libzstd.1.dylib",
        ]
        var handle: UnsafeMutableRawPointer?
        for path in candidates {
            if let h = dlopen(path, RTLD_LAZY | RTLD_LOCAL) {
                handle = h
                break
            }
        }
        guard let handle else {
            self.createDCtx = nil
            self.freeDCtx = nil
            self.decompressStream = nil
            self.isError = nil
            return
        }
        if let sCreate = dlsym(handle, "ZSTD_createDCtx"),
           let sFree = dlsym(handle, "ZSTD_freeDCtx"),
           let sDecomp = dlsym(handle, "ZSTD_decompressStream"),
           let sIsErr = dlsym(handle, "ZSTD_isError") {
            self.createDCtx = unsafeBitCast(sCreate, to: CreateDCtxFn.self)
            self.freeDCtx = unsafeBitCast(sFree, to: FreeDCtxFn.self)
            self.decompressStream = unsafeBitCast(sDecomp, to: DecompressStreamFn.self)
            self.isError = unsafeBitCast(sIsErr, to: IsErrorFn.self)
        } else {
            dlclose(handle)
            self.createDCtx = nil
            self.freeDCtx = nil
            self.decompressStream = nil
            self.isError = nil
        }
    }

    /// Decompresses a Zstandard frame/stream in memory with a strict upper bound (default 64 MB).
    func decompress(_ compressed: Data, maxOutputBytes: Int = 64 * 1024 * 1024) -> Data? {
        guard let createDCtx, let freeDCtx, let decompressStream, let isError else {
            return nil
        }
        guard !compressed.isEmpty else { return Data() }
        guard let dctx = createDCtx() else { return nil }
        defer { _ = freeDCtx(dctx) }

        let chunkSize = 128 * 1024
        var outChunk = [UInt8](repeating: 0, count: chunkSize)
        var result = Data()
        result.reserveCapacity(min(compressed.count * 4, 2 * 1024 * 1024))

        let ok: Bool = compressed.withUnsafeBytes { rawIn -> Bool in
            guard let basePtr = rawIn.baseAddress else { return false }
            // ZSTD_inBuffer: [srcPtr, size, pos]
            var inWords: [UInt] = [UInt(bitPattern: basePtr), UInt(rawIn.count), 0]

            return outChunk.withUnsafeMutableBytes { rawOut -> Bool in
                guard let outBase = rawOut.baseAddress else { return false }
                var iterations = 0
                while inWords[2] < inWords[1] {
                    iterations += 1
                    if iterations > 100_000 { return false }
                    // ZSTD_outBuffer: [dstPtr, size, pos]
                    var outWords: [UInt] = [UInt(bitPattern: outBase), UInt(chunkSize), 0]
                    let ret: Int = outWords.withUnsafeMutableBytes { outRaw in
                        inWords.withUnsafeMutableBytes { inRaw in
                            decompressStream(dctx, outRaw.baseAddress, inRaw.baseAddress)
                        }
                    }
                    if isError(ret) != 0 {
                        return false
                    }
                    let produced = Int(outWords[2])
                    if produced > 0 {
                        if result.count + produced > maxOutputBytes {
                            return false
                        }
                        result.append(outBase.assumingMemoryBound(to: UInt8.self), count: produced)
                    }
                    // Flush internal output buffer if frame not complete and output buffer filled.
                    var lastRet = ret
                    var lastPos = produced
                    while lastRet > 0 && lastPos == chunkSize {
                        outWords[2] = 0
                        let nextRet: Int = outWords.withUnsafeMutableBytes { outRaw in
                            inWords.withUnsafeMutableBytes { inRaw in
                                decompressStream(dctx, outRaw.baseAddress, inRaw.baseAddress)
                            }
                        }
                        if isError(nextRet) != 0 {
                            return false
                        }
                        lastPos = Int(outWords[2])
                        if lastPos > 0 {
                            if result.count + lastPos > maxOutputBytes {
                                return false
                            }
                            result.append(outBase.assumingMemoryBound(to: UInt8.self), count: lastPos)
                        }
                        lastRet = nextRet
                        if nextRet == 0 || lastPos == 0 {
                            break
                        }
                    }
                }
                return true
            }
        }

        return ok ? result : nil
    }
}

// MARK: - Internal Seed & Scan Cache Structures

private struct PersistedSeedDay: Codable {
    var date: String
    var activeTimeMs: Int64
    var observations: [PersistedSeedObservation]
}

private struct PersistedSeedObservation: Codable {
    var client: String
    var modelId: String
    var providerId: String
    var totals: TokenComponentTotals
}

private struct PersistedSeedStore: Codable {
    var version: Int
    var seededAt: Date
    var sourcePath: String
    var days: [String: PersistedSeedDay]
}

private struct CachedUsageBucket: Codable {
    var date: String
    var client: String
    var modelId: String
    var providerId: String
    var projectId: String?
    var projectName: String?
    var pathDisplay: String?
    var totals: TokenComponentTotals
}

private struct SpeedSample: Codable, Equatable, Hashable {
    var dedupKey: String
    var client: String
    var modelId: String
    var outputTokens: Int64
    var totalTokens: Int64
    var durationSec: Double
    var endedAtSec: Double
}

private struct PendingAntigravityStep: Codable {
    var stepIndex: Int?
    var type: String
    var tsSec: Double
    var modelId: String
    var outputTokens: Int64
    var totalTokens: Int64
}

private struct CodexTailState: Codable {
    var model: String
    var cwd: String?
    var lastTotalIn: Int64
    var lastTotalCached: Int64
    var lastTotalCacheWrite: Int64
    var lastTotalOut: Int64
    var lastTotalReasoning: Int64
    var hasLastTotal: Bool
    var lastTokenCountTsSec: Double? = nil
    var lastTurnAnchorTsSec: Double? = nil
}

private struct CachedClaudeMessage: Codable {
    var msgId: String
    var date: String
    var modelId: String
    var cwd: String?
    var uncachedIn: Int64
    var output: Int64
    var cacheRead: Int64
    var cacheWrite: Int64
    var thinking: Int64
}

private struct CachedFileState: Codable {
    var mtime: Double
    var size: UInt64
    var byteOffset: UInt64
    var buckets: [CachedUsageBucket]
    var claudeMessages: [CachedClaudeMessage]? = nil
    var codexState: CodexTailState? = nil
    var seenAntigravitySteps: [Int]? = nil
    var speedSamples: [SpeedSample]? = nil
    var antigravityPendingStep: PendingAntigravityStep? = nil
    var antigravityPrevStepType: String? = nil
    var antigravityPrevStepTsSec: Double? = nil
    var antigravityLastModel: String? = nil
    var antigravityPlannerOrdinal: Int? = nil
    var kimiLastRequestMs: Double? = nil
    var kimiLastUsageMs: Double? = nil
}

private struct CachedSQLiteState: Codable {
    var dbMtime: Double
    var dbSize: UInt64
    var walMtime: Double
    var walSize: UInt64
    var maxTimeUpdated: Int64
    var buckets: [CachedUsageBucket]
    var speedSamples: [SpeedSample]? = nil
}

private struct TokenScanCache: Codable {
    static let currentVersion = 4
    var version: Int
    var files: [String: CachedFileState]
    var sqliteCaches: [String: CachedSQLiteState]

    init(version: Int = TokenScanCache.currentVersion, files: [String: CachedFileState] = [:], sqliteCaches: [String: CachedSQLiteState] = [:]) {
        self.version = version
        self.files = files
        self.sqliteCaches = sqliteCaches
    }
}

private enum LiveWatchKind {
    case claude
    case codex
    case antigravity(uuid: String)
    case grokUpdates(sid: String)
    case grokUsage(sid: String)
    case kimi(sessionAgentKey: String)
    case dsh
    case workbuddy
}

private struct LiveWatchTarget {
    var path: String
    var kind: LiveWatchKind
    var lastSeenMtime: Double
}

private struct LiveTailCacheEntry {
    var mtime: Double
    var size: UInt64
    var samples: [SpeedSample]
}

private struct LiveSQLiteSpeedEntry {
    var dbMtime: Double
    var dbSize: UInt64
    var walMtime: Double
    var walSize: UInt64
    var samples: [SpeedSample]
}

// MARK: - TokenUsageEngine (100% Offline, Read-Only Local Log Scanner + Archive Exporter)

public actor TokenUsageEngine {
    public static let shared = TokenUsageEngine()

    public static var defaultArchiveURL: URL {
        RegistryData.defaultDirectoryURL.appendingPathComponent("daily-history-archive.json", isDirectory: false)
    }

    public static var defaultSeedURL: URL {
        RegistryData.defaultDirectoryURL.appendingPathComponent("token-history-seed.json", isDirectory: false)
    }

    public static var defaultScanCacheURL: URL {
        RegistryData.defaultDirectoryURL.appendingPathComponent("token-scan-cache.json", isDirectory: false)
    }

    /// Optional environment variable pointing to a custom legacy Token Monitor export directory
    /// (or directly to a `daily-history-calendars.json` / `daily-history-archive.json` file).
    public static let legacyTokenMonitorDirEnvKey = "PULSAR_LEGACY_TOKEN_MONITOR_DIR"

    private static let speedMinDurationSec: Double = 0.25
    private static let speedAntigravityMinDurationSec: Double = 0.50
    private static let speedMaxDurationSec: Double = 180.0
    private static let speedMaxOutputTokPerSec: Double = 20_000.0
    private static let speedActiveGeneratingWindowSec: Double = 30.0
    private static let speedRollingWindowSec: Double = 60.0
    private static let speedHistoryWindowSec: Double = 7.0 * 86_400.0
    private static let speedLiveMtimeWindowSec: Double = 600.0
    private static let speedWatchRetainWindowSec: Double = 1800.0
    private static let speedFullDiscoveryIntervalSec: Double = 20.0
    private static let speedMaxRecentModels: Int = 20
    private static let speedMaxSamplesPerFile: Int = 120
    private static let speedMaxSamplesPerModel: Int = 200
    private static let speedTailReadBytes: UInt64 = 512 * 1024

    private let homeDirectoryURL: URL
    private let appSupportURL: URL
    private let legacyTokenMonitorDirURL: URL?
    private let archiveURL: URL
    private let seedURL: URL
    private let scanCacheURL: URL
    private let snapshotCacheURL: URL

    private var memorySnapshot: TokenUsageSnapshot?
    private var historySpeedSamples: [String: [SpeedSample]] = [:]
    private var liveTailCache: [String: LiveTailCacheEntry] = [:]
    private var liveCodexModelCache: [String: String] = [:]
    private var liveSQLiteCache: [String: LiveSQLiteSpeedEntry] = [:]
    private var liveWatchTargets: [String: LiveWatchTarget] = [:]
    private var liveDirMtimeCache: [String: Double] = [:]
    private var lastLiveDiscoveryWallSec: Double = 0.0
    private var lastLiveDiscoveryTotalFiles: Int = 0
    private var didHydrateHistorySpeed = false
    private var speedAggregateDirty = true
    private var cachedAggregateBuiltAtSec: Double = 0.0
    private var cachedRecentModels: [ModelSpeedStat] = []
    private var cachedModelSpeedIndex: [String: ModelSpeedStat] = [:]
    private var cachedRollingWindowCandidates: [SpeedSample] = []

    public init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        appSupportURL: URL = RegistryData.defaultDirectoryURL,
        legacyTokenMonitorDirURL: URL? = nil
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.appSupportURL = appSupportURL
        self.legacyTokenMonitorDirURL = legacyTokenMonitorDirURL
        self.archiveURL = appSupportURL.appendingPathComponent("daily-history-archive.json", isDirectory: false)
        self.seedURL = appSupportURL.appendingPathComponent("token-history-seed.json", isDirectory: false)
        self.scanCacheURL = appSupportURL.appendingPathComponent("token-scan-cache.json", isDirectory: false)
        self.snapshotCacheURL = appSupportURL.appendingPathComponent("token-usage-snapshot.json", isDirectory: false)
    }

    // MARK: - Public API

    /// Returns cached snapshot from memory or disk without scanning local log files.
    public func cachedSnapshot() -> TokenUsageSnapshot? {
        if let memorySnapshot {
            return memorySnapshot
        }
        guard FileManager.default.fileExists(atPath: snapshotCacheURL.path),
              let data = try? Data(contentsOf: snapshotCacheURL),
              let decoded = try? Self.makeDecoder().decode(TokenUsageSnapshot.self, from: data) else {
            return nil
        }
        self.memorySnapshot = decoded
        return decoded
    }

    /// Runs an incremental 100%-offline local log scan, merges with persisted 112-day historical seed,
    /// atomically writes `daily-history-archive.json` (`0600`), and returns the full `TokenUsageSnapshot`.
    public func scanAndExportArchive(forceFullRescan: Bool = false, now: Date = Date()) async -> TokenUsageSnapshot {
        let seedStore = loadOrImportSeedStore(now: now)
        var scanCache: TokenScanCache = forceFullRescan ? TokenScanCache() : loadScanCache()
        let todayKey = Self.shanghaiDateString(from: now)
        let nowSec = now.timeIntervalSince1970
        let speedCutoffSec = nowSec - Self.speedHistoryWindowSec
        let speedMtimeCutoffSec = min(nowSec, Date().timeIntervalSince1970) - Self.speedHistoryWindowSec

        var activePaths = Set<String>()
        var liveScannedFilesCount = 0

        // 1. Claude Code (~/.claude/projects/**/*.jsonl & ~/.claude-profiles/*/projects/**/*.jsonl)
        liveScannedFilesCount += scanClaudeLogs(
            cache: &scanCache,
            activePaths: &activePaths,
            todayKey: todayKey,
            speedCutoffSec: speedCutoffSec,
            speedMtimeCutoffSec: speedMtimeCutoffSec
        )

        // 2. Codex (~/.codex/sessions/**/*.jsonl & archived_sessions/**/*.jsonl)
        liveScannedFilesCount += scanCodexLogs(
            cache: &scanCache,
            activePaths: &activePaths,
            todayKey: todayKey,
            speedCutoffSec: speedCutoffSec,
            speedMtimeCutoffSec: speedMtimeCutoffSec
        )

        // 3. Antigravity (~/.gemini/{antigravity,antigravity-insiders,antigravity-cli}/brain/*/.system_generated/logs/transcript.jsonl)
        liveScannedFilesCount += scanAntigravityLogs(
            cache: &scanCache,
            activePaths: &activePaths,
            todayKey: todayKey,
            speedCutoffSec: speedCutoffSec,
            speedMtimeCutoffSec: speedMtimeCutoffSec
        )

        // 4. Grok (~/.grok/sessions/*/*/usage.json & recent updates.jsonl)
        liveScannedFilesCount += scanGrokLogs(
            cache: &scanCache,
            activePaths: &activePaths,
            todayKey: todayKey,
            speedCutoffSec: speedCutoffSec,
            speedMtimeCutoffSec: speedMtimeCutoffSec
        )

        // 5. Kimi Code (~/.kimi-code/sessions/*/*/agents/*/wire.jsonl)
        liveScannedFilesCount += scanKimiLogs(
            cache: &scanCache,
            activePaths: &activePaths,
            todayKey: todayKey,
            speedCutoffSec: speedCutoffSec,
            speedMtimeCutoffSec: speedMtimeCutoffSec
        )

        // 6. DSH (~/.dsh/sessions/*/*/session.v4.jsonl.zstd & session.jsonl.zstd) via in-process libzstd
        liveScannedFilesCount += scanDSHLogs(
            cache: &scanCache,
            activePaths: &activePaths,
            todayKey: todayKey,
            speedCutoffSec: speedCutoffSec,
            speedMtimeCutoffSec: speedMtimeCutoffSec
        )

        // 7. WorkBuddy (~/.workbuddy/projects/**/*.jsonl)
        liveScannedFilesCount += scanWorkBuddyLogs(
            cache: &scanCache,
            activePaths: &activePaths,
            todayKey: todayKey,
            speedCutoffSec: speedCutoffSec,
            speedMtimeCutoffSec: speedMtimeCutoffSec
        )

        // 8. OpenCode (~/.local/share/opencode/opencode.db) read-only SQLite
        liveScannedFilesCount += scanSQLiteMessageDB(
            cacheKey: "opencode",
            dbURL: homeDirectoryURL.appendingPathComponent(".local/share/opencode/opencode.db"),
            client: .opencode,
            camelCaseModelKeys: false,
            inputIncludesCacheRead: false,
            reasoningSeparateFromOutput: true,
            cache: &scanCache,
            todayKey: todayKey,
            speedCutoffSec: speedCutoffSec
        )

        // 9. ZCode (~/.zcode/cli/db/db.sqlite) read-only SQLite
        liveScannedFilesCount += scanSQLiteMessageDB(
            cacheKey: "zcode",
            dbURL: homeDirectoryURL.appendingPathComponent(".zcode/cli/db/db.sqlite"),
            client: .zcode,
            camelCaseModelKeys: true,
            inputIncludesCacheRead: true,
            reasoningSeparateFromOutput: false,
            cache: &scanCache,
            todayKey: todayKey,
            speedCutoffSec: speedCutoffSec
        )

        // Prune deleted files from file cache.
        for key in Array(scanCache.files.keys) where !activePaths.contains(key) {
            scanCache.files.removeValue(forKey: key)
        }
        saveScanCacheQuietly(scanCache)

        // Aggregate all live buckets from cache, applying GLOBAL cross-file `message.id` deduplication
        // for Claude Code (prevents 3x-5x inflation from `/fork` and relocated session copies).
        var allLiveBuckets: [CachedUsageBucket] = []
        var globalClaudeById: [String: CachedClaudeMessage] = [:]
        var refreshedHistorySpeed: [String: [SpeedSample]] = [:]
        for (path, entry) in scanCache.files {
            allLiveBuckets.append(contentsOf: entry.buckets)
            if let s = entry.speedSamples, !s.isEmpty {
                let recent = s.filter { $0.endedAtSec >= speedCutoffSec }
                if !recent.isEmpty {
                    refreshedHistorySpeed[path] = recent
                }
            }
            if let cMsgs = entry.claudeMessages {
                for m in cMsgs {
                    if let prev = globalClaudeById[m.msgId] {
                        let mTot = m.uncachedIn + m.output + m.cacheRead + m.cacheWrite
                        let prevTot = prev.uncachedIn + prev.output + prev.cacheRead + prev.cacheWrite
                        if mTot > prevTot || (mTot == prevTot && m.output > prev.output) {
                            globalClaudeById[m.msgId] = m
                        }
                    } else {
                        globalClaudeById[m.msgId] = m
                    }
                }
            }
        }
        if !globalClaudeById.isEmpty {
            var claudeBuilder = BucketAccumulator(homePath: homeDirectoryURL.path)
            for rec in globalClaudeById.values {
                let cost = TokenPricingCatalog.pricing(for: rec.modelId, client: .claude).estimateCostUSD(
                    uncachedInput: rec.uncachedIn,
                    output: rec.output,
                    cacheRead: rec.cacheRead,
                    cacheWrite: rec.cacheWrite
                )
                claudeBuilder.add(
                    date: rec.date,
                    client: .claude,
                    modelId: rec.modelId,
                    providerId: "anthropic",
                    cwd: rec.cwd,
                    totals: TokenComponentTotals(
                        totalTokens: rec.uncachedIn + rec.output + rec.cacheRead + rec.cacheWrite,
                        uncachedInputTokens: rec.uncachedIn,
                        outputTokens: rec.output,
                        cacheReadTokens: rec.cacheRead,
                        cacheWriteTokens: rec.cacheWrite,
                        reasoningTokens: rec.thinking,
                        estimatedCostUSD: cost,
                        messageCount: 1
                    )
                )
            }
            allLiveBuckets.append(contentsOf: claudeBuilder.finalize())
        }
        for (dbKey, entry) in scanCache.sqliteCaches {
            allLiveBuckets.append(contentsOf: entry.buckets)
            if let s = entry.speedSamples, !s.isEmpty {
                let recent = s.filter { $0.endedAtSec >= speedCutoffSec }
                if !recent.isEmpty {
                    refreshedHistorySpeed["sqlite:\(dbKey)"] = recent
                }
            }
        }

        // Sync actor speed state with scan results so `sampleLiveSpeed` shares 7-day history seamlessly.
        self.historySpeedSamples = refreshedHistorySpeed
        self.didHydrateHistorySpeed = true
        self.speedAggregateDirty = true
        let speedSnapshot = rebuildOrQuerySpeedSnapshot(now: now)

        // Build merged day map + AccountPool archive + UI snapshot.
        let (mergedDays, projectDayRecords) = mergeSeedAndLive(
            seedStore: seedStore,
            liveBuckets: allLiveBuckets,
            todayKey: todayKey
        )

        writeAccountPoolArchiveQuietly(mergedDays: mergedDays)

        let snapshot = buildSnapshot(
            mergedDays: mergedDays,
            projectRecords: projectDayRecords,
            seedDaysCount: seedStore.days.count,
            liveScannedFilesCount: liveScannedFilesCount,
            now: now,
            todayKey: todayKey,
            speedSnapshot: speedSnapshot
        )

        self.memorySnapshot = snapshot
        saveSnapshotCacheQuietly(snapshot)
        return snapshot
    }

    // MARK: - Live Token/s Speed Sampler (< 10ms, Pure Local Read-Only, Zero Archive Writes)

    /// Samples real-time generation speed (`tok/s`) and rolling 60s throughput from recently modified local logs
    /// (mtime within 10 minutes + SQLite `time_updated > cutoff`), merging with 7-day cached per-model stats.
    /// Strictly read-only: never triggers a full-disk scan and never writes archive or cache files.
    public func sampleLiveSpeed(now: Date = Date()) async -> LiveTokenSpeedSnapshot {
        let nowSec = now.timeIntervalSince1970
        let wallNowSec = Date().timeIntervalSince1970
        let historyCutoffSec = nowSec - Self.speedHistoryWindowSec
        let liveMtimeCutoff = min(nowSec, wallNowSec) - Self.speedLiveMtimeWindowSec
        let watchCutoff = liveMtimeCutoff - Self.speedWatchRetainWindowSec

        // Lazily hydrate 7-day historical samples once from existing disk scan cache (read-only).
        if !didHydrateHistorySpeed {
            didHydrateHistorySpeed = true
            let diskCache = loadScanCache()
            for (path, entry) in diskCache.files {
                if let s = entry.speedSamples, !s.isEmpty {
                    let recent = s.filter { $0.endedAtSec >= historyCutoffSec }
                    if !recent.isEmpty {
                        historySpeedSamples[path] = recent
                        speedAggregateDirty = true
                    }
                }
                if let model = entry.codexState?.model, !model.isEmpty {
                    liveCodexModelCache[path] = model
                }
            }
            for (dbKey, entry) in diskCache.sqliteCaches {
                if let s = entry.speedSamples, !s.isEmpty {
                    let recent = s.filter { $0.endedAtSec >= historyCutoffSec }
                    if !recent.isEmpty {
                        historySpeedSamples["sqlite:\(dbKey)"] = recent
                        speedAggregateDirty = true
                    }
                }
            }
        }

        // Fast-path vs periodic shallow discovery:
        // - Always run full shallow discovery on first call, small workspaces (e.g. unit tests <= 120 files),
        //   every 20s, or immediately whenever any watched parent directory's mtime changes (brand-new session created).
        // - Between discovery ticks (steady-state 4s timer), stat ONLY active watch targets + Codex today/yesterday + SQLite (~1-2ms!).
        let needsFullDiscovery: Bool = (lastLiveDiscoveryWallSec == 0.0)
            || (lastLiveDiscoveryTotalFiles <= 120)
            || (abs(wallNowSec - lastLiveDiscoveryWallSec) >= Self.speedFullDiscoveryIntervalSec)
            || hasAnyParentDirectoryChanged()

        if needsFullDiscovery {
            var newDirMtimes: [String: Double] = [:]
            var totalSeen = 0
            totalSeen += sampleLiveClaudeFiles(
                mtimeCutoff: liveMtimeCutoff,
                watchCutoff: watchCutoff,
                historyCutoffSec: historyCutoffSec,
                dirMtimes: &newDirMtimes
            )
            totalSeen += sampleLiveCodexFiles(
                now: now,
                mtimeCutoff: liveMtimeCutoff,
                watchCutoff: watchCutoff,
                historyCutoffSec: historyCutoffSec
            )
            totalSeen += sampleLiveAntigravityFiles(
                mtimeCutoff: liveMtimeCutoff,
                watchCutoff: watchCutoff,
                historyCutoffSec: historyCutoffSec,
                dirMtimes: &newDirMtimes
            )
            totalSeen += sampleLiveGrokFiles(
                mtimeCutoff: liveMtimeCutoff,
                watchCutoff: watchCutoff,
                historyCutoffSec: historyCutoffSec,
                dirMtimes: &newDirMtimes
            )
            totalSeen += sampleLiveKimiFiles(
                mtimeCutoff: liveMtimeCutoff,
                watchCutoff: watchCutoff,
                historyCutoffSec: historyCutoffSec,
                dirMtimes: &newDirMtimes
            )
            totalSeen += sampleLiveDSHFiles(
                mtimeCutoff: liveMtimeCutoff,
                watchCutoff: watchCutoff,
                historyCutoffSec: historyCutoffSec,
                dirMtimes: &newDirMtimes
            )
            totalSeen += sampleLiveWorkBuddyFiles(
                mtimeCutoff: liveMtimeCutoff,
                watchCutoff: watchCutoff,
                historyCutoffSec: historyCutoffSec,
                dirMtimes: &newDirMtimes
            )
            liveDirMtimeCache = newDirMtimes
            lastLiveDiscoveryWallSec = wallNowSec
            lastLiveDiscoveryTotalFiles = totalSeen
        } else {
            // Ultra-fast hot-set tick (< 2ms): re-stat only recently active files + Codex today/yesterday.
            for (path, target) in liveWatchTargets {
                guard let attrs = fileMtimeAndSize(at: path) else {
                    liveWatchTargets.removeValue(forKey: path)
                    continue
                }
                if attrs.mtime < watchCutoff {
                    liveWatchTargets.removeValue(forKey: path)
                    continue
                }
                guard attrs.mtime >= liveMtimeCutoff else { continue }
                ingestLiveTarget(target: target, mtime: attrs.mtime, size: attrs.size, historyCutoffSec: historyCutoffSec)
            }
            _ = sampleLiveCodexFiles(
                now: now,
                mtimeCutoff: liveMtimeCutoff,
                watchCutoff: watchCutoff,
                historyCutoffSec: historyCutoffSec
            )
        }

        // 8 & 9. OpenCode & ZCode read-only SQLite tail (2 stat calls when unchanged -> < 0.05ms)
        sampleLiveSQLite(
            cacheKey: "opencode",
            dbURL: homeDirectoryURL.appendingPathComponent(".local/share/opencode/opencode.db"),
            client: .opencode,
            camelCaseModelKeys: false,
            reasoningSeparateFromOutput: true,
            mtimeCutoff: liveMtimeCutoff,
            historyCutoffSec: historyCutoffSec
        )
        sampleLiveSQLite(
            cacheKey: "zcode",
            dbURL: homeDirectoryURL.appendingPathComponent(".zcode/cli/db/db.sqlite"),
            client: .zcode,
            camelCaseModelKeys: true,
            reasoningSeparateFromOutput: false,
            mtimeCutoff: liveMtimeCutoff,
            historyCutoffSec: historyCutoffSec
        )

        // Prune stale liveTailCache & watch entries (> 30 min old) to keep memory minimal.
        if liveTailCache.count > 64 {
            for (k, v) in liveTailCache where v.mtime < watchCutoff {
                liveTailCache.removeValue(forKey: k)
            }
        }
        if liveWatchTargets.count > 64 {
            for (k, v) in liveWatchTargets where v.lastSeenMtime < watchCutoff {
                liveWatchTargets.removeValue(forKey: k)
            }
        }

        // Merge 7-day history + live samples and construct snapshot (O(1) fast-path when unchanged).
        return rebuildOrQuerySpeedSnapshot(now: now)
    }

    private func rebuildOrQuerySpeedSnapshot(now: Date) -> LiveTokenSpeedSnapshot {
        let nowSec = now.timeIntervalSince1970
        let mustRebuild = speedAggregateDirty || abs(nowSec - cachedAggregateBuiltAtSec) >= 300.0
        if mustRebuild {
            var combined: [SpeedSample] = []
            combined.reserveCapacity(512)
            for list in historySpeedSamples.values {
                combined.append(contentsOf: list)
            }
            let built = Self.buildSpeedSnapshotAndRollingCandidates(samples: combined, now: now)
            cachedRecentModels = built.snapshot.recentModels
            cachedModelSpeedIndex = built.snapshot.modelSpeedIndex
            cachedRollingWindowCandidates = built.rollingCandidates
            cachedAggregateBuiltAtSec = nowSec
            speedAggregateDirty = false
            return built.snapshot
        }

        // Fast path (< 0.05ms): reuse cached 7-day per-model stats and recompute rolling 60s & isGenerating for `now`.
        let rollingStart = nowSec - Self.speedRollingWindowSec
        let futureLimit = nowSec + 5.0
        var rollingOutTokens = 0.0
        var rollingTotTokens = 0.0
        for s in cachedRollingWindowCandidates {
            guard s.endedAtSec > rollingStart, s.endedAtSec <= futureLimit else { continue }
            let startSec = s.endedAtSec - s.durationSec
            let overlapEnd = min(s.endedAtSec, nowSec)
            let overlapStart = max(startSec, rollingStart)
            let overlap = max(0.0, overlapEnd - overlapStart)
            if overlap > 0.0 {
                let frac = min(1.0, overlap / s.durationSec)
                rollingOutTokens += Double(s.outputTokens) * frac
                rollingTotTokens += Double(max(s.totalTokens, s.outputTokens)) * frac
            }
        }
        let currentModel = cachedRecentModels.first
        let isGenerating: Bool
        if let cur = currentModel {
            let age = nowSec - cur.lastActiveAt.timeIntervalSince1970
            isGenerating = (age >= -5.0 && age <= Self.speedActiveGeneratingWindowSec)
        } else {
            isGenerating = false
        }
        return LiveTokenSpeedSnapshot(
            sampledAt: now,
            isGenerating: isGenerating,
            currentModel: currentModel,
            rollingOutputTokPerSec60s: rollingOutTokens / Self.speedRollingWindowSec,
            rollingTotalTokPerSec60s: rollingTotTokens / Self.speedRollingWindowSec,
            recentModels: cachedRecentModels,
            modelSpeedIndex: cachedModelSpeedIndex
        )
    }

    // MARK: - Live Speed File Discovery & Tail Parsing (POSIX Shallow, Zero Recursion)

    private func dirMtime(at path: String) -> Double? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000.0
    }

    private func hasAnyParentDirectoryChanged() -> Bool {
        for (dirPath, cachedMtime) in liveDirMtimeCache {
            if let cur = dirMtime(at: dirPath), cur != cachedMtime {
                return true
            }
        }
        return false
    }

    private func trackWatchTarget(path: String, kind: LiveWatchKind, mtime: Double, watchCutoff: Double) {
        guard mtime >= watchCutoff else { return }
        liveWatchTargets[path] = LiveWatchTarget(path: path, kind: kind, lastSeenMtime: mtime)
    }

    private func ingestLiveTarget(target: LiveWatchTarget, mtime: Double, size: UInt64, historyCutoffSec: Double) {
        switch target.kind {
        case .claude:
            ingestLiveClaudeFile(path: target.path, mtime: mtime, size: size, historyCutoffSec: historyCutoffSec)
        case .codex:
            ingestLiveCodexFile(path: target.path, mtime: mtime, size: size, historyCutoffSec: historyCutoffSec)
        case .antigravity(let uuid):
            ingestLiveAntigravityFile(path: target.path, uuid: uuid, mtime: mtime, size: size, historyCutoffSec: historyCutoffSec)
        case .grokUpdates(let sid):
            _ = ingestLiveGrokUpdatesFile(path: target.path, sid: sid, mtime: mtime, size: size, historyCutoffSec: historyCutoffSec)
        case .grokUsage(let sid):
            ingestLiveGrokUsageFile(path: target.path, sid: sid, mtime: mtime, size: size, historyCutoffSec: historyCutoffSec)
        case .kimi(let sessionAgentKey):
            ingestLiveKimiFile(path: target.path, sessionAgentKey: sessionAgentKey, mtime: mtime, size: size, historyCutoffSec: historyCutoffSec)
        case .dsh:
            ingestLiveDSHFile(path: target.path, mtime: mtime, size: size, historyCutoffSec: historyCutoffSec)
        case .workbuddy:
            ingestLiveWorkBuddyFile(path: target.path, mtime: mtime, size: size, historyCutoffSec: historyCutoffSec)
        }
    }

    private func mergeHistorySpeedSamples(forKey key: String, newSamples: [SpeedSample], historyCutoffSec: Double) {
        guard !newSamples.isEmpty else { return }
        var byKey: [String: SpeedSample] = [:]
        if let existing = historySpeedSamples[key] {
            for s in existing where s.endedAtSec >= historyCutoffSec {
                byKey[s.dedupKey] = s
            }
        }
        for s in newSamples where s.endedAtSec >= historyCutoffSec {
            byKey[s.dedupKey] = Self.pickBetterSpeedSample(existing: byKey[s.dedupKey], incoming: s)
        }
        let sorted = byKey.values.sorted { $0.endedAtSec < $1.endedAtSec }
        let updated = Array(sorted.suffix(Self.speedMaxSamplesPerFile))
        if historySpeedSamples[key] != updated {
            historySpeedSamples[key] = updated
            speedAggregateDirty = true
        }
    }

    private func sampleLiveClaudeFiles(
        mtimeCutoff: Double,
        watchCutoff: Double,
        historyCutoffSec: Double,
        dirMtimes: inout [String: Double]
    ) -> Int {
        var rootPaths: [String] = []
        let defaultRoot = homeDirectoryURL.appendingPathComponent(".claude/projects", isDirectory: true).path
        if let dm = dirMtime(at: defaultRoot) { dirMtimes[defaultRoot] = dm }
        rootPaths.append(defaultRoot)

        let profilesBase = homeDirectoryURL.appendingPathComponent(".claude-profiles", isDirectory: true).path
        if let dm = dirMtime(at: profilesBase) {
            dirMtimes[profilesBase] = dm
            for profileName in listSubdirectoryNames(at: profilesBase) {
                let profilePath = profilesBase + "/" + profileName
                if let pdm = dirMtime(at: profilePath) { dirMtimes[profilePath] = pdm }
                let projectsPath = profilePath + "/projects"
                if let projMtime = dirMtime(at: projectsPath) {
                    dirMtimes[projectsPath] = projMtime
                    rootPaths.append(projectsPath)
                }
            }
        }

        var seen = 0
        for rootPath in rootPaths {
            for projName in listSubdirectoryNames(at: rootPath) {
                let projPath = rootPath + "/" + projName
                if let dm = dirMtime(at: projPath) { dirMtimes[projPath] = dm }
                let entries = listDirectoryEntries(at: projPath)
                for ent in entries {
                    if ent.isDirectory {
                        let subagentsPath = projPath + "/" + ent.name + "/subagents"
                        for file in listRecentRegularFiles(at: subagentsPath, suffix: ".jsonl", mtimeCutoff: watchCutoff) {
                            seen += 1
                            trackWatchTarget(path: file.path, kind: .claude, mtime: file.mtime, watchCutoff: watchCutoff)
                            if file.mtime >= mtimeCutoff {
                                ingestLiveClaudeFile(path: file.path, mtime: file.mtime, size: file.size, historyCutoffSec: historyCutoffSec)
                            }
                        }
                    } else if ent.name.hasSuffix(".jsonl") {
                        seen += 1
                        let fPath = projPath + "/" + ent.name
                        if let attrs = fileMtimeAndSize(at: fPath), attrs.mtime >= watchCutoff {
                            trackWatchTarget(path: fPath, kind: .claude, mtime: attrs.mtime, watchCutoff: watchCutoff)
                            if attrs.mtime >= mtimeCutoff {
                                ingestLiveClaudeFile(path: fPath, mtime: attrs.mtime, size: attrs.size, historyCutoffSec: historyCutoffSec)
                            }
                        }
                    }
                }
            }
        }
        return seen
    }

    private func ingestLiveClaudeFile(path: String, mtime: Double, size: UInt64, historyCutoffSec: Double) {
        if let cached = liveTailCache[path], cached.mtime == mtime && cached.size == size {
            return
        }
        guard let data = readTailBytes(atPath: path, maxBytes: Self.speedTailReadBytes) else { return }
        let samples = autoreleasepool {
            parseClaudeSpeedSamplesOnly(data: data, speedCutoffSec: historyCutoffSec)
        }
        liveTailCache[path] = LiveTailCacheEntry(mtime: mtime, size: size, samples: samples)
        mergeHistorySpeedSamples(forKey: path, newSamples: samples, historyCutoffSec: historyCutoffSec)
    }

    private func sampleLiveCodexFiles(
        now: Date,
        mtimeCutoff: Double,
        watchCutoff: Double,
        historyCutoffSec: Double
    ) -> Int {
        let sessionsRoot = homeDirectoryURL.appendingPathComponent(".codex/sessions", isDirectory: true).path
        var candidateDirs = Set<String>()
        candidateDirs.insert(sessionsRoot)

        // Check YYYY/MM/DD for today, yesterday, and tomorrow (UTC & Asia/Shanghai) for both `now` and wall-clock Date().
        let anchors = [now, Date()]
        var calUTC = Calendar(identifier: .gregorian)
        calUTC.timeZone = TimeZone(secondsFromGMT: 0)!
        var calLocal = Calendar(identifier: .gregorian)
        calLocal.timeZone = Self.shanghaiTimeZone
        for anchor in anchors {
            for cal in [calLocal, calUTC] {
                for delta in [-1, 0, 1] {
                    if let d = cal.date(byAdding: .day, value: delta, to: anchor) {
                        let c = cal.dateComponents([.year, .month, .day], from: d)
                        let sub = String(format: "%@/%04d/%02d/%02d", sessionsRoot, c.year ?? 1970, c.month ?? 1, c.day ?? 1)
                        candidateDirs.insert(sub)
                    }
                }
            }
        }

        var seen = 0
        for dir in candidateDirs {
            for file in listRecentRegularFiles(at: dir, suffix: ".jsonl", mtimeCutoff: watchCutoff) {
                seen += 1
                trackWatchTarget(path: file.path, kind: .codex, mtime: file.mtime, watchCutoff: watchCutoff)
                if file.mtime >= mtimeCutoff {
                    ingestLiveCodexFile(path: file.path, mtime: file.mtime, size: file.size, historyCutoffSec: historyCutoffSec)
                }
            }
        }
        return seen
    }

    private func ingestLiveCodexFile(path: String, mtime: Double, size: UInt64, historyCutoffSec: Double) {
        if let cached = liveTailCache[path], cached.mtime == mtime && cached.size == size {
            return
        }
        guard let data = readTailBytes(atPath: path, maxBytes: Self.speedTailReadBytes) else { return }
        let fallbackModel = resolveCodexFallbackModel(atPath: path)
        let result = autoreleasepool {
            parseCodexSpeedSamplesOnly(
                data: data,
                fileName: URL(fileURLWithPath: path).lastPathComponent,
                initialModel: fallbackModel,
                speedCutoffSec: historyCutoffSec
            )
        }
        if let detected = result.lastModel, !detected.isEmpty {
            liveCodexModelCache[path] = detected
        }
        liveTailCache[path] = LiveTailCacheEntry(mtime: mtime, size: size, samples: result.samples)
        mergeHistorySpeedSamples(forKey: path, newSamples: result.samples, historyCutoffSec: historyCutoffSec)
    }

    private func resolveCodexFallbackModel(atPath path: String) -> String {
        if let cached = liveCodexModelCache[path], !cached.isEmpty {
            return cached
        }
        // Peek first 32 KB to find initial `turn_context` model when tailing large rollout files.
        if let head = readHeadBytes(atPath: path, maxBytes: 32 * 1024) {
            var found: String?
            forEachJSONLine(in: head) { lineData in
                guard found == nil else { return }
                guard Self.utf8Contains(lineData, needle: "\"turn_context\"") else { return }
                if let rec = (try? JSONSerialization.jsonObject(with: lineData, options: [])) as? [String: Any],
                   (rec["type"] as? String) == "turn_context",
                   let payload = rec["payload"] as? [String: Any],
                   let model = payload["model"] as? String, !model.isEmpty {
                    found = Self.sanitizeModelId(model)
                }
            }
            if let found {
                liveCodexModelCache[path] = found
                return found
            }
        }
        return "gpt-6-codex"
    }

    private func sampleLiveAntigravityFiles(
        mtimeCutoff: Double,
        watchCutoff: Double,
        historyCutoffSec: Double,
        dirMtimes: inout [String: Double]
    ) -> Int {
        let roots = [
            homeDirectoryURL.appendingPathComponent(".gemini/antigravity/brain", isDirectory: true).path,
            homeDirectoryURL.appendingPathComponent(".gemini/antigravity-insiders/brain", isDirectory: true).path,
            homeDirectoryURL.appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true).path,
        ]
        var seenUUIDs = Set<String>()
        var seen = 0
        for brainPath in roots {
            if let dm = dirMtime(at: brainPath) { dirMtimes[brainPath] = dm }
            for uuid in listSubdirectoryNames(at: brainPath) {
                let transcriptPath = brainPath + "/" + uuid + "/.system_generated/logs/transcript.jsonl"
                guard let attrs = fileMtimeAndSize(at: transcriptPath) else { continue }
                guard seenUUIDs.insert(uuid).inserted else { continue }
                seen += 1
                guard attrs.mtime >= watchCutoff else { continue }
                trackWatchTarget(path: transcriptPath, kind: .antigravity(uuid: uuid), mtime: attrs.mtime, watchCutoff: watchCutoff)
                if attrs.mtime >= mtimeCutoff {
                    ingestLiveAntigravityFile(
                        path: transcriptPath,
                        uuid: uuid,
                        mtime: attrs.mtime,
                        size: attrs.size,
                        historyCutoffSec: historyCutoffSec
                    )
                }
            }
        }
        return seen
    }

    private func ingestLiveAntigravityFile(path: String, uuid: String, mtime: Double, size: UInt64, historyCutoffSec: Double) {
        if let cached = liveTailCache[path], cached.mtime == mtime && cached.size == size {
            return
        }
        guard let data = readTailBytes(atPath: path, maxBytes: Self.speedTailReadBytes) else { return }
        // Derive root (<root>/brain/<uuid>/.system_generated/logs/transcript.jsonl -> <root>)
        let rootURL = URL(fileURLWithPath: path)
            .deletingLastPathComponent() // logs
            .deletingLastPathComponent() // .system_generated
            .deletingLastPathComponent() // <uuid>
            .deletingLastPathComponent() // brain
            .deletingLastPathComponent() // <root>
        let samples = autoreleasepool {
            parseAntigravitySpeedSamplesOnly(
                data: data,
                convUUID: uuid,
                rootURL: rootURL,
                fileMtime: mtime,
                speedCutoffSec: historyCutoffSec
            )
        }
        liveTailCache[path] = LiveTailCacheEntry(mtime: mtime, size: size, samples: samples)
        mergeHistorySpeedSamples(forKey: path, newSamples: samples, historyCutoffSec: historyCutoffSec)
    }

    private func sampleLiveGrokFiles(
        mtimeCutoff: Double,
        watchCutoff: Double,
        historyCutoffSec: Double,
        dirMtimes: inout [String: Double]
    ) -> Int {
        let rootPath = homeDirectoryURL.appendingPathComponent(".grok/sessions", isDirectory: true).path
        if let dm = dirMtime(at: rootPath) { dirMtimes[rootPath] = dm }
        var seen = 0
        for cwdName in listSubdirectoryNames(at: rootPath) {
            let cwdPath = rootPath + "/" + cwdName
            if let dm = dirMtime(at: cwdPath) { dirMtimes[cwdPath] = dm }
            for sid in listSubdirectoryNames(at: cwdPath) {
                let sPath = cwdPath + "/" + sid
                let updatesPath = sPath + "/updates.jsonl"
                if let attrs = fileMtimeAndSize(at: updatesPath) {
                    seen += 1
                    if attrs.mtime >= watchCutoff {
                        trackWatchTarget(path: updatesPath, kind: .grokUpdates(sid: sid), mtime: attrs.mtime, watchCutoff: watchCutoff)
                        if attrs.mtime >= mtimeCutoff {
                            let got = ingestLiveGrokUpdatesFile(
                                path: updatesPath,
                                sid: sid,
                                mtime: attrs.mtime,
                                size: attrs.size,
                                historyCutoffSec: historyCutoffSec
                            )
                            if got { continue }
                        } else {
                            continue
                        }
                    } else {
                        continue
                    }
                }
                let usagePath = sPath + "/usage.json"
                if let attrs = fileMtimeAndSize(at: usagePath) {
                    seen += 1
                    if attrs.mtime >= watchCutoff {
                        trackWatchTarget(path: usagePath, kind: .grokUsage(sid: sid), mtime: attrs.mtime, watchCutoff: watchCutoff)
                        if attrs.mtime >= mtimeCutoff {
                            ingestLiveGrokUsageFile(
                                path: usagePath,
                                sid: sid,
                                mtime: attrs.mtime,
                                size: attrs.size,
                                historyCutoffSec: historyCutoffSec
                            )
                        }
                    }
                }
            }
        }
        return seen
    }

    private func ingestLiveGrokUpdatesFile(path: String, sid: String, mtime: Double, size: UInt64, historyCutoffSec: Double) -> Bool {
        if let cached = liveTailCache[path], cached.mtime == mtime && cached.size == size {
            return !cached.samples.isEmpty
        }
        guard let data = readTailBytes(atPath: path, maxBytes: Self.speedTailReadBytes) else { return false }
        let samples = autoreleasepool {
            parseGrokUpdatesSpeedSamples(data: data, sessionKey: sid, speedCutoffSec: historyCutoffSec)
        }
        liveTailCache[path] = LiveTailCacheEntry(mtime: mtime, size: size, samples: samples)
        mergeHistorySpeedSamples(forKey: path, newSamples: samples, historyCutoffSec: historyCutoffSec)
        return !samples.isEmpty
    }

    private func ingestLiveGrokUsageFile(path: String, sid: String, mtime: Double, size: UInt64, historyCutoffSec: Double) {
        if let cached = liveTailCache[path], cached.mtime == mtime && cached.size == size {
            return
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else { return }
        let samples = parseGrokUsageSpeedSamples(root: root, sessionKey: sid, speedCutoffSec: historyCutoffSec)
        liveTailCache[path] = LiveTailCacheEntry(mtime: mtime, size: size, samples: samples)
        mergeHistorySpeedSamples(forKey: path, newSamples: samples, historyCutoffSec: historyCutoffSec)
    }

    private func sampleLiveKimiFiles(
        mtimeCutoff: Double,
        watchCutoff: Double,
        historyCutoffSec: Double,
        dirMtimes: inout [String: Double]
    ) -> Int {
        let rootPath = homeDirectoryURL.appendingPathComponent(".kimi-code/sessions", isDirectory: true).path
        if let dm = dirMtime(at: rootPath) { dirMtimes[rootPath] = dm }
        var seen = 0
        for hashDir in listSubdirectoryNames(at: rootPath) {
            let hashPath = rootPath + "/" + hashDir
            if let dm = dirMtime(at: hashPath) { dirMtimes[hashPath] = dm }
            for sid in listSubdirectoryNames(at: hashPath) {
                let agentsPath = hashPath + "/" + sid + "/agents"
                for agentId in listSubdirectoryNames(at: agentsPath) {
                    let wirePath = agentsPath + "/" + agentId + "/wire.jsonl"
                    guard let attrs = fileMtimeAndSize(at: wirePath) else { continue }
                    seen += 1
                    guard attrs.mtime >= watchCutoff else { continue }
                    let key = "\(sid):\(agentId)"
                    trackWatchTarget(path: wirePath, kind: .kimi(sessionAgentKey: key), mtime: attrs.mtime, watchCutoff: watchCutoff)
                    if attrs.mtime >= mtimeCutoff {
                        ingestLiveKimiFile(path: wirePath, sessionAgentKey: key, mtime: attrs.mtime, size: attrs.size, historyCutoffSec: historyCutoffSec)
                    }
                }
            }
        }
        return seen
    }

    private func ingestLiveKimiFile(path: String, sessionAgentKey: String, mtime: Double, size: UInt64, historyCutoffSec: Double) {
        if let cached = liveTailCache[path], cached.mtime == mtime && cached.size == size {
            return
        }
        guard let data = readTailBytes(atPath: path, maxBytes: Self.speedTailReadBytes) else { return }
        let samples = autoreleasepool {
            parseKimiSpeedSamplesOnly(
                data: data,
                sessionAgentKey: sessionAgentKey,
                speedCutoffSec: historyCutoffSec
            )
        }
        liveTailCache[path] = LiveTailCacheEntry(mtime: mtime, size: size, samples: samples)
        mergeHistorySpeedSamples(forKey: path, newSamples: samples, historyCutoffSec: historyCutoffSec)
    }

    private func sampleLiveDSHFiles(
        mtimeCutoff: Double,
        watchCutoff: Double,
        historyCutoffSec: Double,
        dirMtimes: inout [String: Double]
    ) -> Int {
        guard DynamicZstdLoader.shared.isAvailable else { return 0 }
        let rootPath = homeDirectoryURL.appendingPathComponent(".dsh/sessions", isDirectory: true).path
        if let dm = dirMtime(at: rootPath) { dirMtimes[rootPath] = dm }
        var seen = 0
        for projDir in listSubdirectoryNames(at: rootPath) {
            let projPath = rootPath + "/" + projDir
            if let dm = dirMtime(at: projPath) { dirMtimes[projPath] = dm }
            for sid in listSubdirectoryNames(at: projPath) {
                let sPath = projPath + "/" + sid
                let v4Path = sPath + "/session.v4.jsonl.zstd"
                if let attrs = fileMtimeAndSize(at: v4Path) {
                    seen += 1
                    if attrs.mtime >= watchCutoff {
                        trackWatchTarget(path: v4Path, kind: .dsh, mtime: attrs.mtime, watchCutoff: watchCutoff)
                        if attrs.mtime >= mtimeCutoff {
                            ingestLiveDSHFile(path: v4Path, mtime: attrs.mtime, size: attrs.size, historyCutoffSec: historyCutoffSec)
                        }
                    }
                    continue
                }
                let v1Path = sPath + "/session.jsonl.zstd"
                if let attrs = fileMtimeAndSize(at: v1Path) {
                    seen += 1
                    if attrs.mtime >= watchCutoff {
                        trackWatchTarget(path: v1Path, kind: .dsh, mtime: attrs.mtime, watchCutoff: watchCutoff)
                        if attrs.mtime >= mtimeCutoff {
                            ingestLiveDSHFile(path: v1Path, mtime: attrs.mtime, size: attrs.size, historyCutoffSec: historyCutoffSec)
                        }
                    }
                }
            }
        }
        return seen
    }

    private func ingestLiveDSHFile(path: String, mtime: Double, size: UInt64, historyCutoffSec: Double) {
        if let cached = liveTailCache[path], cached.mtime == mtime && cached.size == size {
            return
        }
        let samples: [SpeedSample] = autoreleasepool {
            guard let compressed = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let decompressed = DynamicZstdLoader.shared.decompress(compressed) else {
                return []
            }
            return parseDSHSpeedSamplesOnly(data: decompressed, speedCutoffSec: historyCutoffSec)
        }
        liveTailCache[path] = LiveTailCacheEntry(mtime: mtime, size: size, samples: samples)
        mergeHistorySpeedSamples(forKey: path, newSamples: samples, historyCutoffSec: historyCutoffSec)
    }

    private func sampleLiveWorkBuddyFiles(
        mtimeCutoff: Double,
        watchCutoff: Double,
        historyCutoffSec: Double,
        dirMtimes: inout [String: Double]
    ) -> Int {
        let rootPath = homeDirectoryURL.appendingPathComponent(".workbuddy/projects", isDirectory: true).path
        if let dm = dirMtime(at: rootPath) { dirMtimes[rootPath] = dm }
        var seen = 0
        for projDir in listSubdirectoryNames(at: rootPath) {
            let projPath = rootPath + "/" + projDir
            if let dm = dirMtime(at: projPath) { dirMtimes[projPath] = dm }
            for file in listRecentRegularFiles(at: projPath, suffix: ".jsonl", mtimeCutoff: watchCutoff) {
                seen += 1
                trackWatchTarget(path: file.path, kind: .workbuddy, mtime: file.mtime, watchCutoff: watchCutoff)
                if file.mtime >= mtimeCutoff {
                    ingestLiveWorkBuddyFile(path: file.path, mtime: file.mtime, size: file.size, historyCutoffSec: historyCutoffSec)
                }
            }
        }
        return seen
    }

    private func ingestLiveWorkBuddyFile(path: String, mtime: Double, size: UInt64, historyCutoffSec: Double) {
        if let cached = liveTailCache[path], cached.mtime == mtime && cached.size == size {
            return
        }
        guard let data = readTailBytes(atPath: path, maxBytes: Self.speedTailReadBytes) else { return }
        let samples = autoreleasepool {
            parseWorkBuddySpeedSamplesOnly(data: data, speedCutoffSec: historyCutoffSec)
        }
        liveTailCache[path] = LiveTailCacheEntry(mtime: mtime, size: size, samples: samples)
        mergeHistorySpeedSamples(forKey: path, newSamples: samples, historyCutoffSec: historyCutoffSec)
    }

    private func sampleLiveSQLite(
        cacheKey: String,
        dbURL: URL,
        client: TokenClientID,
        camelCaseModelKeys: Bool,
        reasoningSeparateFromOutput: Bool,
        mtimeCutoff: Double,
        historyCutoffSec: Double
    ) {
        let path = dbURL.path
        guard let dbAttrs = fileMtimeAndSize(at: path) else { return }
        let walAttrs = fileMtimeAndSize(at: path + "-wal")
        let walMtime = walAttrs?.mtime ?? 0
        let walSize = walAttrs?.size ?? 0
        let latestMtime = max(dbAttrs.mtime, walMtime)
        guard latestMtime >= mtimeCutoff else { return }

        if let cached = liveSQLiteCache[cacheKey],
           cached.dbMtime == dbAttrs.mtime && cached.dbSize == dbAttrs.size
            && cached.walMtime == walMtime && cached.walSize == walSize {
            return
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)

        let queryCutoffMs = Int64(max(0.0, (historyCutoffSec - 60.0)) * 1000.0)
        var stmt: OpaquePointer?
        let sql = "SELECT id, time_created, time_updated, data FROM message WHERE time_updated > ? ORDER BY time_updated DESC LIMIT 64"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, queryCutoffMs)

        var samples: [SpeedSample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let msgId = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let timeCreated = sqlite3_column_int64(stmt, 1)
            let timeUpdated = sqlite3_column_int64(stmt, 2)
            guard let cData = sqlite3_column_text(stmt, 3) else { continue }
            let jsonData = Data(String(cString: cData).utf8)
            guard let d = (try? JSONSerialization.jsonObject(with: jsonData, options: [])) as? [String: Any],
                  (d["role"] as? String) == "assistant",
                  let tok = d["tokens"] as? [String: Any] else { continue }

            if let sample = Self.extractSQLiteSpeedSample(
                msgId: msgId.isEmpty ? "\(timeCreated)-\(timeUpdated)" : msgId,
                timeCreated: timeCreated,
                dataDict: d,
                tokensDict: tok,
                client: client,
                camelCaseModelKeys: camelCaseModelKeys,
                reasoningSeparateFromOutput: reasoningSeparateFromOutput,
                speedCutoffSec: historyCutoffSec
            ) {
                samples.append(sample)
            }
        }

        liveSQLiteCache[cacheKey] = LiveSQLiteSpeedEntry(
            dbMtime: dbAttrs.mtime,
            dbSize: dbAttrs.size,
            walMtime: walMtime,
            walSize: walSize,
            samples: samples
        )
        mergeHistorySpeedSamples(forKey: "sqlite:\(cacheKey)", newSamples: samples, historyCutoffSec: historyCutoffSec)
    }

    // MARK: - Speed Snapshot Aggregation & Guardrails

    private static func makeValidSpeedSample(
        dedupKey: String,
        client: TokenClientID,
        modelId: String,
        outputTokens: Int64,
        totalTokens: Int64,
        durationSec: Double,
        endedAtSec: Double,
        speedCutoffSec: Double,
        minDurationSec: Double = speedMinDurationSec,
        maxDurationSec: Double = speedMaxDurationSec
    ) -> SpeedSample? {
        guard outputTokens > 0,
              durationSec.isFinite,
              durationSec >= minDurationSec,
              durationSec <= maxDurationSec,
              endedAtSec.isFinite,
              endedAtSec >= speedCutoffSec,
              endedAtSec >= 1_577_836_800.0 else {
            return nil
        }
        let outRate = Double(outputTokens) / durationSec
        guard outRate.isFinite, outRate > 0.0, outRate <= speedMaxOutputTokPerSec else {
            return nil
        }
        return SpeedSample(
            dedupKey: dedupKey,
            client: client.rawValue,
            modelId: sanitizeModelId(modelId),
            outputTokens: outputTokens,
            totalTokens: max(totalTokens, outputTokens),
            durationSec: durationSec,
            endedAtSec: endedAtSec
        )
    }

    private static func pickBetterSpeedSample(existing: SpeedSample?, incoming: SpeedSample) -> SpeedSample {
        guard let existing else { return incoming }
        if incoming.outputTokens != existing.outputTokens {
            return incoming.outputTokens > existing.outputTokens ? incoming : existing
        }
        if incoming.endedAtSec != existing.endedAtSec {
            return incoming.endedAtSec > existing.endedAtSec ? incoming : existing
        }
        return incoming
    }

    private static func buildSpeedSnapshotAndRollingCandidates(
        samples: [SpeedSample],
        now: Date
    ) -> (snapshot: LiveTokenSpeedSnapshot, rollingCandidates: [SpeedSample]) {
        let nowSec = now.timeIntervalSince1970
        let historyCutoff = nowSec - speedHistoryWindowSec
        let futureLimit = nowSec + 5.0
        let rollingCandidateCutoff = nowSec - 600.0

        // Global dedup by `dedupKey` (handles Claude `/fork`, Antigravity multi-root overlap, live+history overlap).
        var deduped: [String: SpeedSample] = [:]
        deduped.reserveCapacity(samples.count)
        for s in samples {
            guard s.outputTokens > 0,
                  s.durationSec.isFinite, s.durationSec >= speedMinDurationSec,
                  s.endedAtSec.isFinite, s.endedAtSec >= historyCutoff, s.endedAtSec <= futureLimit else {
                continue
            }
            let outRate = Double(s.outputTokens) / s.durationSec
            guard outRate.isFinite, outRate > 0.0, outRate <= speedMaxOutputTokPerSec else { continue }
            deduped[s.dedupKey] = pickBetterSpeedSample(existing: deduped[s.dedupKey], incoming: s)
        }

        guard !deduped.isEmpty else {
            return (LiveTokenSpeedSnapshot.empty(sampledAt: now), [])
        }

        // Group samples by (client, modelId) in-place (zero COW O(N^2) copies) and compute rolling 60s throughput.
        let rollingStart = nowSec - speedRollingWindowSec
        var rollingOutTokens = 0.0
        var rollingTotTokens = 0.0
        var rollingCandidates: [SpeedSample] = []
        var byModelItems: [String: [SpeedSample]] = [:]
        var byModelMeta: [String: (client: TokenClientID, modelId: String)] = [:]

        for s in deduped.values {
            let client = TokenClientID.canonical(s.client)
            let key = ModelSpeedStat.makeID(client: client, modelId: s.modelId)
            if byModelMeta[key] == nil {
                byModelMeta[key] = (client, s.modelId)
            }
            byModelItems[key, default: []].append(s)

            if s.endedAtSec >= rollingCandidateCutoff {
                rollingCandidates.append(s)
            }

            // Rolling 60s window contribution (prorated by interval overlap with [now - 60, now]).
            if s.endedAtSec > rollingStart {
                let startSec = s.endedAtSec - s.durationSec
                let overlapEnd = min(s.endedAtSec, nowSec)
                let overlapStart = max(startSec, rollingStart)
                let overlap = max(0.0, overlapEnd - overlapStart)
                if overlap > 0.0 {
                    let frac = min(1.0, overlap / s.durationSec)
                    rollingOutTokens += Double(s.outputTokens) * frac
                    rollingTotTokens += Double(max(s.totalTokens, s.outputTokens)) * frac
                }
            }
        }

        var stats: [ModelSpeedStat] = []
        stats.reserveCapacity(byModelItems.count)
        var speedIndex: [String: ModelSpeedStat] = [:]
        speedIndex.reserveCapacity(byModelItems.count)

        for (key, items) in byModelItems {
            guard let meta = byModelMeta[key] else { continue }
            let sorted = items.sorted { lhs, rhs in
                if lhs.endedAtSec != rhs.endedAtSec {
                    return lhs.endedAtSec < rhs.endedAtSec
                }
                return lhs.dedupKey < rhs.dedupKey
            }
            let recentSlice = sorted.suffix(speedMaxSamplesPerModel)
            guard let latest = recentSlice.last else { continue }

            var sumOut: Int64 = 0
            var sumDur: Double = 0.0
            var peakOutRate: Double = 0.0
            for item in recentSlice {
                sumOut += item.outputTokens
                sumDur += item.durationSec
                let r = Double(item.outputTokens) / item.durationSec
                if r > peakOutRate { peakOutRate = r }
            }

            let latestOutRate = Double(latest.outputTokens) / latest.durationSec
            let latestTotRate = Double(max(latest.totalTokens, latest.outputTokens)) / latest.durationSec
            let avgOutRate = sumDur > 0.0 ? (Double(sumOut) / sumDur) : latestOutRate

            let stat = ModelSpeedStat(
                client: meta.client,
                modelId: meta.modelId,
                latestOutputTokPerSec: latestOutRate,
                averageOutputTokPerSec: avgOutRate,
                peakOutputTokPerSec: peakOutRate,
                latestTotalTokPerSec: latestTotRate,
                sampleCount: recentSlice.count,
                lastOutputTokens: latest.outputTokens,
                lastDurationSec: latest.durationSec,
                lastActiveAt: Date(timeIntervalSince1970: latest.endedAtSec)
            )
            stats.append(stat)
            speedIndex[key] = stat
        }

        stats.sort { lhs, rhs in
            if lhs.lastActiveAt != rhs.lastActiveAt {
                return lhs.lastActiveAt > rhs.lastActiveAt
            }
            return lhs.id < rhs.id
        }

        let recentModels = Array(stats.prefix(speedMaxRecentModels))
        let currentModel = recentModels.first
        let isGenerating: Bool
        if let cur = currentModel {
            let age = nowSec - cur.lastActiveAt.timeIntervalSince1970
            isGenerating = (age >= -5.0 && age <= speedActiveGeneratingWindowSec)
        } else {
            isGenerating = false
        }

        let snapshot = LiveTokenSpeedSnapshot(
            sampledAt: now,
            isGenerating: isGenerating,
            currentModel: currentModel,
            rollingOutputTokPerSec60s: rollingOutTokens / speedRollingWindowSec,
            rollingTotalTokPerSec60s: rollingTotTokens / speedRollingWindowSec,
            recentModels: recentModels,
            modelSpeedIndex: speedIndex
        )
        return (snapshot, rollingCandidates)
    }

    // MARK: - CLI Reporting Formatters

    public static func formatSmokeReport(_ snapshot: TokenUsageSnapshot) -> String {
        var lines: [String] = []
        let rule = String(repeating: "-", count: 88)
        lines.append("RoryOrbit \(AppStore.appVersion) — 本地只读 Token 用量统计（零联网 / 零子进程 / 零密钥）")
        lines.append(rule)
        lines.append(
            "历史种子天数: \(snapshot.seedDaysCount) | 合并总天数: \(snapshot.totalDaysCount) | 已索引本地文件: \(snapshot.liveScannedFilesCount)"
        )
        lines.append("归档路径: \(snapshot.archiveFileURLPath)")
        lines.append(rule)
        lines.append(
            pad("周期", 10)
                + pad("总 Tokens", 14)
                + pad("估算费用", 12)
                + pad("缓存命中", 10)
                + pad("消息数", 10)
                + pad("活跃天", 8)
                + "日期范围"
        )
        lines.append(rule)
        for range in TokenUsageRange.allCases {
            let s = snapshot.summary(for: range)
            lines.append(
                pad(range.displayName, 10)
                    + pad(TokenFormatters.compactTokens(s.totals.totalTokens), 14)
                    + pad(TokenFormatters.usd(s.totals.estimatedCostUSD), 12)
                    + pad(TokenFormatters.percent(s.totals.cacheHitRate), 10)
                    + pad("\(s.totals.messageCount)", 10)
                    + pad("\(s.activeDays)", 8)
                    + "\(s.startDate) .. \(s.endDate)"
            )
        }

        if let sp = snapshot.speedSnapshot {
            lines.append("")
            let statusLabel = sp.isGenerating ? "生成中" : "空闲"
            lines.append("实时生成速度 (纯本地日志测速):")
            lines.append(
                "  状态: \(statusLabel) | 近60s合并输出: \(TokenFormatters.tokensPerSec(sp.rollingOutputTokPerSec60s)) | 近60s总吞吐: \(TokenFormatters.tokensPerSec(sp.rollingTotalTokPerSec60s))"
            )
            if let cur = sp.currentModel {
                lines.append(
                    "  当前活跃模型: [\(cur.client.shortName)] \(cur.modelId) (\(TokenFormatters.compactModelName(cur.modelId))) · 最新 \(TokenFormatters.tokensPerSec(cur.latestOutputTokPerSec)) | 均值 \(TokenFormatters.tokensPerSec(cur.averageOutputTokPerSec)) | 峰值 \(TokenFormatters.tokensPerSec(cur.peakOutputTokPerSec)) (\(cur.sampleCount)轮)"
                )
            } else {
                lines.append("  当前活跃模型: 暂无近 7 天有效测速样本")
            }
            if !sp.recentModels.isEmpty {
                lines.append("  近期测速模型 Top 8:")
                for m in sp.recentModels.prefix(8) {
                    lines.append(
                        "    "
                            + pad("[\(m.client.shortName)]", 12)
                            + pad(m.modelId, 32)
                            + pad("最新 " + TokenFormatters.tokensPerSec(m.latestOutputTokPerSec), 18)
                            + pad("均值 " + TokenFormatters.tokensPerSec(m.averageOutputTokPerSec), 18)
                            + "峰值 " + TokenFormatters.tokensPerSec(m.peakOutputTokPerSec)
                            + " (\(m.sampleCount)轮)"
                    )
                }
            }
        }

        let s30 = snapshot.summary(for: .days30)
        lines.append("")
        lines.append("近 30 天客户端分布:")
        for c in s30.byClient {
            lines.append(
                "  "
                    + pad(c.client.displayName, 18)
                    + pad(TokenFormatters.compactTokens(c.totals.totalTokens), 12)
                    + pad(TokenFormatters.percent(c.shareOfTokens), 9)
                    + pad(TokenFormatters.usd(c.totals.estimatedCostUSD), 12)
                    + "缓存 " + TokenFormatters.percent(c.totals.cacheHitRate)
            )
        }

        lines.append("")
        lines.append("近 30 天 Top 8 模型:")
        for m in s30.byModel.prefix(8) {
            let speedSuffix: String
            if let stat = snapshot.speedSnapshot?.speedStat(for: m.client, modelId: m.modelId) {
                speedSuffix = "  均速 " + TokenFormatters.tokensPerSec(stat.averageOutputTokPerSec)
            } else {
                speedSuffix = ""
            }
            lines.append(
                "  "
                    + pad("[\(m.client.shortName)]", 12)
                    + pad(m.modelId, 34)
                    + pad(TokenFormatters.compactTokens(m.totals.totalTokens), 12)
                    + pad(TokenFormatters.usd(m.totals.estimatedCostUSD), 10)
                    + speedSuffix
            )
        }

        if !s30.byProject.isEmpty {
            lines.append("")
            lines.append("近 30 天 Top 8 项目 (本地 cwd):")
            for p in s30.byProject.prefix(8) {
                lines.append(
                    "  "
                        + pad(p.projectName, 26)
                        + pad(TokenFormatters.compactTokens(p.totals.totalTokens), 12)
                        + pad(TokenFormatters.usd(p.totals.estimatedCostUSD), 12)
                        + p.pathDisplay
                )
            }
        }

        return lines.joined(separator: "\n")
    }

    public static func formatArchiveExportSummaryJSON(_ snapshot: TokenUsageSnapshot) -> String {
        let today = snapshot.summary(for: .today)
        let d30 = snapshot.summary(for: .days30)
        let all = snapshot.summary(for: .allTime)
        let payload: [String: Any] = [
            "status": "ok",
            "generatedAt": Formatters.formatRFC3339UTC(snapshot.generatedAt),
            "archivePath": snapshot.archiveFileURLPath,
            "seedDaysCount": snapshot.seedDaysCount,
            "totalDaysCount": snapshot.totalDaysCount,
            "liveScannedFilesCount": snapshot.liveScannedFilesCount,
            "todayTokens": today.totals.totalTokens,
            "days30Tokens": d30.totals.totalTokens,
            "allTimeTokens": all.totals.totalTokens,
            "days30CostUSD": (d30.totals.estimatedCostUSD * 100.0).rounded() / 100.0,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"status\":\"ok\",\"totalDaysCount\":\(snapshot.totalDaysCount)}"
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        if text.count >= width { return text + " " }
        return text + String(repeating: " ", count: width - text.count)
    }

    // MARK: - Historical Seed Loading & Persistence (Lossless 112-day Migration)

    private func loadOrImportSeedStore(now: Date) -> PersistedSeedStore {
        if FileManager.default.fileExists(atPath: seedURL.path),
           let data = try? Data(contentsOf: seedURL),
           let decoded = try? Self.makeDecoder().decode(PersistedSeedStore.self, from: data),
           !decoded.days.isEmpty {
            return decoded
        }

        var candidates: [URL] = []

        func appendLegacySeedCandidates(from baseURL: URL) {
            if baseURL.pathExtension.lowercased() == "json" {
                candidates.append(baseURL)
            } else {
                candidates.append(baseURL.appendingPathComponent("daily-history-calendars.json", isDirectory: false))
                candidates.append(baseURL.appendingPathComponent("daily-history-archive.json", isDirectory: false))
            }
        }

        if let injectedDir = legacyTokenMonitorDirURL {
            appendLegacySeedCandidates(from: injectedDir)
        }
        if let rawEnvDir = ProcessInfo.processInfo.environment[Self.legacyTokenMonitorDirEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawEnvDir.isEmpty {
            let expanded = NSString(string: rawEnvDir).expandingTildeInPath
            appendLegacySeedCandidates(from: URL(fileURLWithPath: expanded))
        }

        let standardTokenMonitorDir = homeDirectoryURL
            .appendingPathComponent("Library/Application Support/Token Monitor", isDirectory: true)
        appendLegacySeedCandidates(from: standardTokenMonitorDir)

        for candidate in candidates {
            guard FileManager.default.fileExists(atPath: candidate.path),
                  let data = try? Data(contentsOf: candidate),
                  let imported = Self.parseTokenMonitorCalendarsSeed(data: data, sourcePath: candidate.path, now: now),
                  !imported.days.isEmpty else {
                continue
            }
            saveSeedStoreQuietly(imported)
            return imported
        }

        return PersistedSeedStore(version: 1, seededAt: now, sourcePath: "", days: [:])
    }

    private static func parseTokenMonitorCalendarsSeed(data: Data, sourcePath: String, now: Date) -> PersistedSeedStore? {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }

        // Start with top-level `days`, then overlay `selectedCalendars[date] -> calendars[tz].days[date]`
        // (exact #44 rule covering 2026-06-06 .. 2026-11-21 across all 112 unique days).
        var rawDays: [String: [String: Any]] = [:]
        if let baseDays = root["days"] as? [String: Any] {
            for (dateKey, val) in baseDays {
                if let dict = val as? [String: Any], isValidDateKey(dateKey) {
                    rawDays[dateKey] = dict
                }
            }
        }

        if let selectedCalendars = root["selectedCalendars"] as? [String: Any],
           let calendars = root["calendars"] as? [String: Any] {
            for (dateKey, tzAny) in selectedCalendars {
                guard isValidDateKey(dateKey),
                      let tzName = tzAny as? String,
                      let calObj = calendars[tzName] as? [String: Any],
                      let calDays = calObj["days"] as? [String: Any],
                      let dayDict = calDays[dateKey] as? [String: Any] else {
                    continue
                }
                rawDays[dateKey] = dayDict
            }
        }

        var parsedDays: [String: PersistedSeedDay] = [:]
        for (dateKey, dayDict) in rawDays {
            let activeTimeMs = parseInt64(dayDict["activeTimeMs"]) ?? 0
            guard let obsMap = dayDict["observations"] as? [String: Any] else { continue }
            var obsList: [PersistedSeedObservation] = []
            for (_, obsAny) in obsMap {
                guard let obs = obsAny as? [String: Any] else { continue }
                let rawClient = (obs["client"] as? String) ?? "unknown"
                let client = TokenClientID.canonical(rawClient)
                let rawModel = (obs["modelId"] as? String) ?? "unknown"
                let modelId = sanitizeModelId(rawModel)
                let providerId = ((obs["providerId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                    ?? TokenPricingCatalog.defaultProviderId(for: modelId, client: client)

                let totalTokens = max(Int64(0), parseInt64(obs["tokens"]) ?? 0)
                let outputTokens = max(Int64(0), parseInt64(obs["outputTokens"]) ?? 0)
                let cacheReadTokens = max(Int64(0), parseInt64(obs["cacheReadTokens"]) ?? 0)
                let cacheWriteTokens = max(Int64(0), parseInt64(obs["cacheWriteTokens"]) ?? 0)
                let reasoningTokens = max(Int64(0), parseInt64(obs["reasoningTokens"]) ?? 0)
                let messages = Int(max(Int64(0), parseInt64(obs["messages"]) ?? 0))

                // Enforce cacheRead + cacheWrite + output <= totalTokens (reasoning is inside output).
                let clampedOut = min(outputTokens, totalTokens)
                let clampedCR = min(cacheReadTokens, max(0, totalTokens - clampedOut))
                let clampedCW = min(cacheWriteTokens, max(0, totalTokens - clampedOut - clampedCR))
                let uncachedIn = max(Int64(0), totalTokens - clampedOut - clampedCR - clampedCW)

                let rawCost = parseDouble(obs["cost"])
                let costUSD: Double
                if let rawCost, rawCost.isFinite, rawCost >= 0 {
                    costUSD = rawCost
                } else {
                    costUSD = TokenPricingCatalog.pricing(for: modelId, client: client).estimateCostUSD(
                        uncachedInput: uncachedIn,
                        output: clampedOut,
                        cacheRead: clampedCR,
                        cacheWrite: clampedCW
                    )
                }

                let totals = TokenComponentTotals(
                    totalTokens: totalTokens,
                    uncachedInputTokens: uncachedIn,
                    outputTokens: clampedOut,
                    cacheReadTokens: clampedCR,
                    cacheWriteTokens: clampedCW,
                    reasoningTokens: min(reasoningTokens, clampedOut),
                    estimatedCostUSD: costUSD,
                    messageCount: messages
                )
                obsList.append(
                    PersistedSeedObservation(
                        client: client.rawValue,
                        modelId: modelId,
                        providerId: providerId,
                        totals: totals
                    )
                )
            }
            if !obsList.isEmpty {
                parsedDays[dateKey] = PersistedSeedDay(
                    date: dateKey,
                    activeTimeMs: activeTimeMs,
                    observations: obsList
                )
            }
        }

        return PersistedSeedStore(
            version: 1,
            seededAt: now,
            sourcePath: sourcePath,
            days: parsedDays
        )
    }

    private func saveSeedStoreQuietly(_ store: PersistedSeedStore) {
        do {
            try KeychainStore.ensureDirectory(at: appSupportURL, mode: 0o700)
            let data = try Self.makeEncoder().encode(store)
            try KeychainStore.writeAtomicFile(data: data, to: seedURL, mode: 0o600)
        } catch {
            // Non-fatal: seed remains in memory.
        }
    }

    // MARK: - Scan Cache Persistence

    private func loadScanCache() -> TokenScanCache {
        guard FileManager.default.fileExists(atPath: scanCacheURL.path),
              let data = try? Data(contentsOf: scanCacheURL),
              let decoded = try? Self.makeDecoder().decode(TokenScanCache.self, from: data),
              decoded.version == TokenScanCache.currentVersion else {
            return TokenScanCache()
        }
        return decoded
    }

    private func saveScanCacheQuietly(_ cache: TokenScanCache) {
        do {
            try KeychainStore.ensureDirectory(at: appSupportURL, mode: 0o700)
            let data = try JSONEncoder().encode(cache)
            try KeychainStore.writeAtomicFile(data: data, to: scanCacheURL, mode: 0o600)
        } catch {
            // Non-fatal.
        }
    }

    private func saveSnapshotCacheQuietly(_ snapshot: TokenUsageSnapshot) {
        do {
            try KeychainStore.ensureDirectory(at: appSupportURL, mode: 0o700)
            let data = try Self.makeEncoder().encode(snapshot)
            try KeychainStore.writeAtomicFile(data: data, to: snapshotCacheURL, mode: 0o600)
        } catch {
            // Non-fatal.
        }
    }

    // MARK: - 1. Claude Code Scanner (`~/.claude/projects/**/*.jsonl`)

    private struct ClaudeSpeedTracker {
        struct MsgTiming {
            var msgId: String
            var modelId: String
            var anchorTs: Double?
            var firstTs: Double
            var lastTs: Double
            var outputTokens: Int64
            var totalTokens: Int64
            var turnDurationSec: Double?
        }

        var lastAnchorTs: Double? = nil
        var assistantCountSinceUser: Int = 0
        var lastMsgIdInTurn: String? = nil
        var byMsgId: [String: MsgTiming] = [:]
        var anonSamples: [SpeedSample] = []

        mutating func recordAnchor(tsSec: Double) {
            lastAnchorTs = tsSec
            assistantCountSinceUser = 0
            lastMsgIdInTurn = nil
        }

        mutating func recordTurnDuration(durationMs: Int64) {
            if durationMs > 0, assistantCountSinceUser == 1, let mid = lastMsgIdInTurn, var st = byMsgId[mid] {
                st.turnDurationSec = Double(durationMs) / 1000.0
                byMsgId[mid] = st
            }
            assistantCountSinceUser = 0
            lastMsgIdInTurn = nil
        }

        mutating func recordAssistant(
            msgId: String?,
            modelId: String,
            tsSec: Double,
            outputTokens: Int64,
            totalTokens: Int64,
            speedCutoffSec: Double
        ) {
            if let msgId, !msgId.isEmpty {
                if var prev = byMsgId[msgId] {
                    if tsSec < prev.firstTs { prev.firstTs = tsSec }
                    if tsSec > prev.lastTs { prev.lastTs = tsSec }
                    if outputTokens > prev.outputTokens { prev.outputTokens = outputTokens }
                    if totalTokens > prev.totalTokens { prev.totalTokens = totalTokens }
                    byMsgId[msgId] = prev
                } else {
                    byMsgId[msgId] = MsgTiming(
                        msgId: msgId,
                        modelId: modelId,
                        anchorTs: lastAnchorTs,
                        firstTs: tsSec,
                        lastTs: tsSec,
                        outputTokens: outputTokens,
                        totalTokens: totalTokens,
                        turnDurationSec: nil
                    )
                    assistantCountSinceUser += 1
                    lastMsgIdInTurn = msgId
                }
                lastAnchorTs = tsSec
            } else {
                if let anchor = lastAnchorTs {
                    let dt = tsSec - anchor
                    if let sample = TokenUsageEngine.makeValidSpeedSample(
                        dedupKey: "claude-anon:\(Int64(tsSec * 1000.0)):\(outputTokens)",
                        client: .claude,
                        modelId: modelId,
                        outputTokens: outputTokens,
                        totalTokens: totalTokens,
                        durationSec: dt,
                        endedAtSec: tsSec,
                        speedCutoffSec: speedCutoffSec
                    ) {
                        anonSamples.append(sample)
                    }
                }
                lastAnchorTs = tsSec
            }
        }

        func finalize(speedCutoffSec: Double) -> [SpeedSample] {
            var out = anonSamples
            out.reserveCapacity(out.count + byMsgId.count)
            for st in byMsgId.values {
                guard st.outputTokens > 0, st.lastTs >= speedCutoffSec else { continue }
                var chosenDt: Double? = nil
                if let anchor = st.anchorTs {
                    let d = st.lastTs - anchor
                    if d >= TokenUsageEngine.speedMinDurationSec && d <= TokenUsageEngine.speedMaxDurationSec {
                        chosenDt = d
                    }
                }
                if chosenDt == nil, let td = st.turnDurationSec {
                    if td >= TokenUsageEngine.speedMinDurationSec && td <= TokenUsageEngine.speedMaxDurationSec {
                        chosenDt = td
                    }
                }
                if let dt = chosenDt,
                   let sample = TokenUsageEngine.makeValidSpeedSample(
                    dedupKey: "claude:\(st.msgId)",
                    client: .claude,
                    modelId: st.modelId,
                    outputTokens: st.outputTokens,
                    totalTokens: st.totalTokens,
                    durationSec: dt,
                    endedAtSec: st.lastTs,
                    speedCutoffSec: speedCutoffSec
                   ) {
                    out.append(sample)
                }
            }
            out.sort { $0.endedAtSec < $1.endedAtSec }
            return Array(out.suffix(TokenUsageEngine.speedMaxSamplesPerFile))
        }
    }

    private func scanClaudeLogs(
        cache: inout TokenScanCache,
        activePaths: inout Set<String>,
        todayKey: String,
        speedCutoffSec: Double,
        speedMtimeCutoffSec: Double
    ) -> Int {
        var roots: [URL] = [
            homeDirectoryURL.appendingPathComponent(".claude/projects", isDirectory: true),
        ]
        let profilesBase = homeDirectoryURL.appendingPathComponent(".claude-profiles", isDirectory: true)
        for profileName in listSubdirectoryNames(at: profilesBase.path) {
            let projectsURL = profilesBase
                .appendingPathComponent(profileName, isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
            roots.append(projectsURL)
        }

        var files: [URL] = []
        var seenFilePaths = Set<String>()
        for root in roots {
            for url in enumerateFiles(under: root, suffix: ".jsonl") {
                if seenFilePaths.insert(url.path).inserted {
                    files.append(url)
                }
            }
        }
        guard !files.isEmpty else { return 0 }

        var count = 0
        for url in files {
            let path = url.path
            activePaths.insert(path)
            count += 1
            guard let attrs = fileMtimeAndSize(at: path) else { continue }
            if let existing = cache.files[path],
               existing.mtime == attrs.mtime && existing.size == attrs.size {
                continue
            }

            guard let data = try? Data(contentsOf: url) else { continue }
            let collectSpeed = attrs.mtime >= speedMtimeCutoffSec
            let parsed = autoreleasepool {
                parseClaudeJSONL(
                    data: data,
                    todayKey: todayKey,
                    collectSpeed: collectSpeed,
                    speedCutoffSec: speedCutoffSec
                )
            }
            cache.files[path] = CachedFileState(
                mtime: attrs.mtime,
                size: attrs.size,
                byteOffset: attrs.size,
                buckets: parsed.anonBuckets,
                claudeMessages: parsed.messages,
                codexState: nil,
                seenAntigravitySteps: nil,
                speedSamples: parsed.speedSamples.isEmpty ? nil : parsed.speedSamples
            )
        }
        return count
    }

    private func parseClaudeJSONL(
        data: Data,
        todayKey: String,
        collectSpeed: Bool,
        speedCutoffSec: Double
    ) -> (messages: [CachedClaudeMessage], anonBuckets: [CachedUsageBucket], speedSamples: [SpeedSample]) {
        // Dedup streaming/multi-block assistant chunks by `message.id` within file;
        // caller additionally deduplicates globally across forked/relocated files.
        var dedupByMsgId: [String: CachedClaudeMessage] = [:]
        var anonBuilder = BucketAccumulator(homePath: homeDirectoryURL.path)
        var speedTracker = ClaudeSpeedTracker()

        forEachJSONLine(in: data) { lineData in
            let hasUsage = Self.utf8Contains(lineData, bytes: Self.needleUsage)
            let isAssistantHint = hasUsage && (
                Self.utf8Contains(lineData, bytes: Self.needleTypeAssistantCompact)
                    || Self.utf8Contains(lineData, bytes: Self.needleTypeAssistantSpaced)
            )

            if !isAssistantHint {
                guard collectSpeed else { return }
                if Self.utf8Contains(lineData, bytes: Self.needleTypeUserCompact)
                    || Self.utf8Contains(lineData, bytes: Self.needleTypeUserSpaced) {
                    if Self.extractJSONString(in: lineData, afterKey: "type") == "user",
                       let tsStr = Self.extractJSONString(in: lineData, afterKey: "timestamp"),
                       let tsSec = Self.parseISOToEpochSeconds(tsStr) {
                        speedTracker.recordAnchor(tsSec: tsSec)
                    }
                } else if Self.utf8Contains(lineData, bytes: Self.needleTurnDuration) {
                    if Self.extractJSONString(in: lineData, afterKey: "type") == "system",
                       Self.extractJSONString(in: lineData, afterKey: "subtype") == "turn_duration",
                       let durMs = Self.extractJSONInt64(in: lineData, afterKey: "durationMs") {
                        speedTracker.recordTurnDuration(durationMs: durMs)
                    }
                }
                return
            }

            guard !Self.utf8Contains(lineData, bytes: Self.needleIsApiErrorTrue) else { return }

            let usage: [String: Any]
            let rawModel: String
            let tsStr: String
            let cwd: String?
            let msgId: String?

            if lineData.count > 16_384 {
                // Large assistant message (e.g. big tool output / thinking): extract ONLY scalar metadata + tiny `usage` object.
                guard let msgRange = Self.findBytes(in: lineData, needle: Self.needleMessageKey) else { return }
                // Confirm top-level type is "assistant" (not an embedded assistant snippet inside a user/tool_result record).
                let topType = Self.extractJSONString(in: lineData, afterKey: "type")
                if topType == "user" {
                    if collectSpeed,
                       let ts = Self.extractJSONString(in: lineData, afterKey: "timestamp"),
                       let tsSec = Self.parseISOToEpochSeconds(ts) {
                        speedTracker.recordAnchor(tsSec: tsSec)
                    }
                    return
                }
                guard topType == "assistant" else { return }
                guard let u = Self.extractJSONObject(in: lineData, afterKey: "usage", searchStart: msgRange.upperBound),
                      let m = Self.extractJSONString(in: lineData, afterKey: "model", searchStart: msgRange.upperBound),
                      let ts = Self.extractJSONString(in: lineData, afterKey: "timestamp") else {
                    return
                }
                usage = u
                rawModel = m
                tsStr = ts
                cwd = Self.extractJSONString(in: lineData, afterKey: "cwd")
                // Strictly extract `msg_...` ID inside `message` (never match a nested `toolu_...` block ID!).
                msgId = Self.extractClaudeMsgId(in: lineData, searchStart: msgRange.upperBound)
            } else {
                guard let rec = (try? JSONSerialization.jsonObject(with: lineData, options: [])) as? [String: Any] else { return }
                let topType = rec["type"] as? String
                if topType == "user" {
                    if collectSpeed,
                       let ts = rec["timestamp"] as? String,
                       let tsSec = Self.parseISOToEpochSeconds(ts) {
                        speedTracker.recordAnchor(tsSec: tsSec)
                    }
                    return
                }
                guard topType == "assistant" else { return }
                if (rec["isApiErrorMessage"] as? Bool) == true { return }
                guard let msg = rec["message"] as? [String: Any],
                      let u = msg["usage"] as? [String: Any],
                      let m = msg["model"] as? String,
                      let ts = rec["timestamp"] as? String else { return }
                usage = u
                rawModel = m
                tsStr = ts
                cwd = rec["cwd"] as? String
                msgId = msg["id"] as? String
            }

            if rawModel == "<synthetic>" || rawModel.isEmpty { return }
            guard let dateKey = Self.parseISOToShanghaiDateKey(tsStr),
                  dateKey <= todayKey else { return }

            let inputTok = max(Int64(0), Self.parseInt64(usage["input_tokens"]) ?? 0)
            let outputTok = max(Int64(0), Self.parseInt64(usage["output_tokens"]) ?? 0)
            let cacheWriteTok = max(Int64(0), Self.parseInt64(usage["cache_creation_input_tokens"]) ?? 0)
            let cacheReadTok = max(Int64(0), Self.parseInt64(usage["cache_read_input_tokens"]) ?? 0)
            let outDetails = usage["output_tokens_details"] as? [String: Any]
            let thinkingTok = max(Int64(0), Self.parseInt64(outDetails?["thinking_tokens"]) ?? 0)

            let total = inputTok + outputTok + cacheWriteTok + cacheReadTok
            guard total > 0 else { return }

            let modelId = Self.sanitizeModelId(rawModel)
            if collectSpeed, let tsSec = Self.parseISOToEpochSeconds(tsStr) {
                speedTracker.recordAssistant(
                    msgId: msgId,
                    modelId: modelId,
                    tsSec: tsSec,
                    outputTokens: outputTok,
                    totalTokens: total,
                    speedCutoffSec: speedCutoffSec
                )
            }

            if let msgId, !msgId.isEmpty {
                let item = CachedClaudeMessage(
                    msgId: msgId,
                    date: dateKey,
                    modelId: modelId,
                    cwd: cwd,
                    uncachedIn: inputTok,
                    output: outputTok,
                    cacheRead: cacheReadTok,
                    cacheWrite: cacheWriteTok,
                    thinking: min(thinkingTok, outputTok)
                )
                if let prev = dedupByMsgId[msgId] {
                    let prevTot = prev.uncachedIn + prev.output + prev.cacheRead + prev.cacheWrite
                    if total > prevTot || (total == prevTot && item.output >= prev.output) {
                        dedupByMsgId[msgId] = item
                    }
                } else {
                    dedupByMsgId[msgId] = item
                }
            } else {
                let cost = TokenPricingCatalog.pricing(for: modelId, client: .claude).estimateCostUSD(
                    uncachedInput: inputTok,
                    output: outputTok,
                    cacheRead: cacheReadTok,
                    cacheWrite: cacheWriteTok
                )
                anonBuilder.add(
                    date: dateKey,
                    client: .claude,
                    modelId: modelId,
                    providerId: "anthropic",
                    cwd: cwd,
                    totals: TokenComponentTotals(
                        totalTokens: total,
                        uncachedInputTokens: inputTok,
                        outputTokens: outputTok,
                        cacheReadTokens: cacheReadTok,
                        cacheWriteTokens: cacheWriteTok,
                        reasoningTokens: min(thinkingTok, outputTok),
                        estimatedCostUSD: cost,
                        messageCount: 1
                    )
                )
            }
        }

        let speedSamples = collectSpeed ? speedTracker.finalize(speedCutoffSec: speedCutoffSec) : []
        return (Array(dedupByMsgId.values), anonBuilder.finalize(), speedSamples)
    }

    private func parseClaudeSpeedSamplesOnly(data: Data, speedCutoffSec: Double) -> [SpeedSample] {
        var speedTracker = ClaudeSpeedTracker()
        forEachJSONLine(in: data) { lineData in
            if Self.utf8Contains(lineData, bytes: Self.needleUsage),
               (Self.utf8Contains(lineData, bytes: Self.needleTypeAssistantCompact)
                    || Self.utf8Contains(lineData, bytes: Self.needleTypeAssistantSpaced)),
               !Self.utf8Contains(lineData, bytes: Self.needleIsApiErrorTrue) {
                let topType = Self.extractJSONString(in: lineData, afterKey: "type")
                if topType == "user" {
                    if let ts = Self.extractJSONString(in: lineData, afterKey: "timestamp"),
                       let tsSec = Self.parseISOToEpochSeconds(ts) {
                        speedTracker.recordAnchor(tsSec: tsSec)
                    }
                    return
                }
                guard topType == "assistant",
                      let msgRange = Self.findBytes(in: lineData, needle: Self.needleMessageKey),
                      let usage = Self.extractJSONObject(in: lineData, afterKey: "usage", searchStart: msgRange.upperBound),
                      let rawModel = Self.extractJSONString(in: lineData, afterKey: "model", searchStart: msgRange.upperBound),
                      !rawModel.isEmpty, rawModel != "<synthetic>",
                      let tsStr = Self.extractJSONString(in: lineData, afterKey: "timestamp"),
                      let tsSec = Self.parseISOToEpochSeconds(tsStr) else {
                    return
                }
                let inputTok = max(Int64(0), Self.parseInt64(usage["input_tokens"]) ?? 0)
                let outputTok = max(Int64(0), Self.parseInt64(usage["output_tokens"]) ?? 0)
                let cacheWriteTok = max(Int64(0), Self.parseInt64(usage["cache_creation_input_tokens"]) ?? 0)
                let cacheReadTok = max(Int64(0), Self.parseInt64(usage["cache_read_input_tokens"]) ?? 0)
                let total = inputTok + outputTok + cacheWriteTok + cacheReadTok
                guard outputTok > 0 else { return }
                let msgId = Self.extractClaudeMsgId(in: lineData, searchStart: msgRange.upperBound)
                speedTracker.recordAssistant(
                    msgId: msgId,
                    modelId: Self.sanitizeModelId(rawModel),
                    tsSec: tsSec,
                    outputTokens: outputTok,
                    totalTokens: total,
                    speedCutoffSec: speedCutoffSec
                )
            } else if Self.utf8Contains(lineData, bytes: Self.needleTypeUserCompact)
                || Self.utf8Contains(lineData, bytes: Self.needleTypeUserSpaced) {
                if Self.extractJSONString(in: lineData, afterKey: "type") == "user",
                   let ts = Self.extractJSONString(in: lineData, afterKey: "timestamp"),
                   let tsSec = Self.parseISOToEpochSeconds(ts) {
                    speedTracker.recordAnchor(tsSec: tsSec)
                }
            } else if Self.utf8Contains(lineData, bytes: Self.needleTurnDuration) {
                if Self.extractJSONString(in: lineData, afterKey: "type") == "system",
                   Self.extractJSONString(in: lineData, afterKey: "subtype") == "turn_duration",
                   let durMs = Self.extractJSONInt64(in: lineData, afterKey: "durationMs") {
                    speedTracker.recordTurnDuration(durationMs: durMs)
                }
            }
        }
        return speedTracker.finalize(speedCutoffSec: speedCutoffSec)
    }

    // MARK: - 2. Codex Scanner (`~/.codex/sessions/**/*.jsonl` & `archived_sessions/**/*.jsonl`)

    private func scanCodexLogs(
        cache: inout TokenScanCache,
        activePaths: inout Set<String>,
        todayKey: String,
        speedCutoffSec: Double,
        speedMtimeCutoffSec: Double
    ) -> Int {
        let roots = [
            homeDirectoryURL.appendingPathComponent(".codex/sessions", isDirectory: true),
            homeDirectoryURL.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
        ]
        var files: [URL] = []
        for root in roots {
            files.append(contentsOf: enumerateFiles(under: root, suffix: ".jsonl"))
        }
        guard !files.isEmpty else { return 0 }

        var count = 0
        for url in files {
            let path = url.path
            activePaths.insert(path)
            count += 1
            guard let attrs = fileMtimeAndSize(at: path) else { continue }

            let existing = cache.files[path]
            if let existing, existing.mtime == attrs.mtime && existing.size == attrs.size {
                continue
            }

            let canResume = existing != nil && attrs.size >= (existing?.byteOffset ?? 0) && existing?.codexState != nil
            let startOffset: UInt64 = canResume ? (existing?.byteOffset ?? 0) : 0
            guard let chunk = readFileBytes(at: url, fromOffset: startOffset) else { continue }

            var state = canResume ? existing!.codexState! : CodexTailState(
                model: "gpt-6-codex",
                cwd: nil,
                lastTotalIn: 0,
                lastTotalCached: 0,
                lastTotalCacheWrite: 0,
                lastTotalOut: 0,
                lastTotalReasoning: 0,
                hasLastTotal: false,
                lastTokenCountTsSec: nil,
                lastTurnAnchorTsSec: nil
            )
            var builder = BucketAccumulator(homePath: homeDirectoryURL.path)
            if canResume, let prevBuckets = existing?.buckets {
                builder.seed(prevBuckets)
            }
            let collectSpeed = attrs.mtime >= speedMtimeCutoffSec
            var speedSamples: [SpeedSample] = canResume
                ? (existing?.speedSamples ?? []).filter { $0.endedAtSec >= speedCutoffSec }
                : []
            let fileName = url.lastPathComponent

            forEachJSONLine(in: chunk) { lineData in
                let interesting = Self.utf8Contains(lineData, needle: "\"token_count\"")
                    || Self.utf8Contains(lineData, needle: "\"turn_context\"")
                    || Self.utf8Contains(lineData, needle: "\"session_meta\"")
                    || (collectSpeed && (
                        Self.utf8Contains(lineData, needle: "\"task_started\"")
                            || Self.utf8Contains(lineData, needle: "\"user_message\"")
                    ))
                guard interesting else { return }

                guard let rec = (try? JSONSerialization.jsonObject(with: lineData, options: [])) as? [String: Any],
                      let recType = rec["type"] as? String,
                      let payload = rec["payload"] as? [String: Any] else { return }

                if recType == "session_meta" {
                    if let cwd = payload["cwd"] as? String, !cwd.isEmpty, state.cwd == nil {
                        state.cwd = cwd
                    }
                    return
                }
                if recType == "turn_context" {
                    if let model = payload["model"] as? String, !model.isEmpty {
                        state.model = Self.sanitizeModelId(model)
                    }
                    if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                        state.cwd = cwd
                    }
                    if collectSpeed, let tsStr = rec["timestamp"] as? String,
                       let tsSec = Self.parseISOToEpochSeconds(tsStr) {
                        state.lastTurnAnchorTsSec = tsSec
                    }
                    return
                }
                if recType == "event_msg", let pType = payload["type"] as? String,
                   (pType == "task_started" || pType == "user_message") {
                    if collectSpeed, let tsStr = rec["timestamp"] as? String,
                       let tsSec = Self.parseISOToEpochSeconds(tsStr) {
                        state.lastTurnAnchorTsSec = tsSec
                    }
                    return
                }
                guard recType == "event_msg",
                      (payload["type"] as? String) == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let totalUsage = info["total_token_usage"] as? [String: Any] else {
                    return
                }

                let curIn = max(Int64(0), Self.parseInt64(totalUsage["input_tokens"]) ?? 0)
                let curCached = max(Int64(0), Self.parseInt64(totalUsage["cached_input_tokens"]) ?? 0)
                let curCW = max(Int64(0), Self.parseInt64(totalUsage["cache_write_input_tokens"]) ?? 0)
                let curOut = max(Int64(0), Self.parseInt64(totalUsage["output_tokens"]) ?? 0)
                let curReas = max(Int64(0), Self.parseInt64(totalUsage["reasoning_output_tokens"]) ?? 0)

                // Skip consecutive identical cumulative snapshots (Codex emits duplicate token_count events).
                if state.hasLastTotal
                    && curIn == state.lastTotalIn
                    && curCached == state.lastTotalCached
                    && curCW == state.lastTotalCacheWrite
                    && curOut == state.lastTotalOut {
                    return
                }

                let deltaIn: Int64
                let deltaCached: Int64
                let deltaCW: Int64
                let deltaOut: Int64
                let deltaReas: Int64

                if state.hasLastTotal && curIn >= state.lastTotalIn && curOut >= state.lastTotalOut {
                    deltaIn = curIn - state.lastTotalIn
                    deltaCached = max(0, curCached - state.lastTotalCached)
                    deltaCW = max(0, curCW - state.lastTotalCacheWrite)
                    deltaOut = curOut - state.lastTotalOut
                    deltaReas = max(0, curReas - state.lastTotalReasoning)
                } else if let lastUsage = info["last_token_usage"] as? [String: Any] {
                    deltaIn = max(0, Self.parseInt64(lastUsage["input_tokens"]) ?? 0)
                    deltaCached = max(0, Self.parseInt64(lastUsage["cached_input_tokens"]) ?? 0)
                    deltaCW = max(0, Self.parseInt64(lastUsage["cache_write_input_tokens"]) ?? 0)
                    deltaOut = max(0, Self.parseInt64(lastUsage["output_tokens"]) ?? 0)
                    deltaReas = max(0, Self.parseInt64(lastUsage["reasoning_output_tokens"]) ?? 0)
                } else {
                    deltaIn = curIn
                    deltaCached = curCached
                    deltaCW = curCW
                    deltaOut = curOut
                    deltaReas = curReas
                }

                state.lastTotalIn = curIn
                state.lastTotalCached = curCached
                state.lastTotalCacheWrite = curCW
                state.lastTotalOut = curOut
                state.lastTotalReasoning = curReas
                state.hasLastTotal = true

                // In Codex, `input_tokens` INCLUDES `cached_input_tokens`, and `output_tokens` INCLUDES `reasoning_output_tokens`.
                let clampedCached = min(deltaCached, deltaIn)
                let clampedCW = min(deltaCW, max(0, deltaIn - clampedCached))
                let uncachedIn = max(Int64(0), deltaIn - clampedCached - clampedCW)
                let totalTok = uncachedIn + clampedCached + clampedCW + deltaOut
                guard totalTok > 0 else { return }

                guard let tsStr = rec["timestamp"] as? String,
                      let dateKey = Self.parseISOToShanghaiDateKey(tsStr),
                      dateKey <= todayKey else { return }

                let modelId = state.model
                if collectSpeed, let tsSec = Self.parseISOToEpochSeconds(tsStr) {
                    let prevStart = max(state.lastTokenCountTsSec ?? -1.0, state.lastTurnAnchorTsSec ?? -1.0)
                    if prevStart > 0.0 {
                        let dt = tsSec - prevStart
                        if let sample = Self.makeValidSpeedSample(
                            dedupKey: "codex:\(fileName):\(Int64(tsSec * 1000.0)):\(curOut)",
                            client: .codex,
                            modelId: modelId,
                            outputTokens: deltaOut,
                            totalTokens: totalTok,
                            durationSec: dt,
                            endedAtSec: tsSec,
                            speedCutoffSec: speedCutoffSec
                        ) {
                            speedSamples.append(sample)
                        }
                    }
                    state.lastTokenCountTsSec = tsSec
                }

                let cost = TokenPricingCatalog.pricing(for: modelId, client: .codex).estimateCostUSD(
                    uncachedInput: uncachedIn,
                    output: deltaOut,
                    cacheRead: clampedCached,
                    cacheWrite: clampedCW
                )
                builder.add(
                    date: dateKey,
                    client: .codex,
                    modelId: modelId,
                    providerId: "openai",
                    cwd: state.cwd,
                    totals: TokenComponentTotals(
                        totalTokens: totalTok,
                        uncachedInputTokens: uncachedIn,
                        outputTokens: deltaOut,
                        cacheReadTokens: clampedCached,
                        cacheWriteTokens: clampedCW,
                        reasoningTokens: min(deltaReas, deltaOut),
                        estimatedCostUSD: cost,
                        messageCount: 1
                    )
                )
            }

            let trimmedSpeed = Array(speedSamples.filter { $0.endedAtSec >= speedCutoffSec }.suffix(Self.speedMaxSamplesPerFile))
            cache.files[path] = CachedFileState(
                mtime: attrs.mtime,
                size: attrs.size,
                byteOffset: attrs.size,
                buckets: builder.finalize(),
                codexState: state,
                seenAntigravitySteps: nil,
                speedSamples: trimmedSpeed.isEmpty ? nil : trimmedSpeed
            )
            if !state.model.isEmpty {
                liveCodexModelCache[path] = state.model
            }
        }
        return count
    }

    private func parseCodexSpeedSamplesOnly(
        data: Data,
        fileName: String,
        initialModel: String,
        speedCutoffSec: Double
    ) -> (samples: [SpeedSample], lastModel: String?) {
        var model = initialModel
        var detectedModel: String? = nil
        var hasLastTotal = false
        var lastTotalIn: Int64 = 0
        var lastTotalCached: Int64 = 0
        var lastTotalCW: Int64 = 0
        var lastTotalOut: Int64 = 0
        var lastTokenCountTs: Double? = nil
        var lastTurnAnchorTs: Double? = nil
        var samples: [SpeedSample] = []

        forEachJSONLine(in: data) { lineData in
            guard Self.utf8Contains(lineData, needle: "\"token_count\"")
                || Self.utf8Contains(lineData, needle: "\"turn_context\"")
                || Self.utf8Contains(lineData, needle: "\"task_started\"")
                || Self.utf8Contains(lineData, needle: "\"user_message\"") else { return }

            guard let rec = (try? JSONSerialization.jsonObject(with: lineData, options: [])) as? [String: Any],
                  let recType = rec["type"] as? String,
                  let payload = rec["payload"] as? [String: Any] else { return }

            if recType == "turn_context" {
                if let m = payload["model"] as? String, !m.isEmpty {
                    model = Self.sanitizeModelId(m)
                    detectedModel = model
                }
                if let tsStr = rec["timestamp"] as? String, let tsSec = Self.parseISOToEpochSeconds(tsStr) {
                    lastTurnAnchorTs = tsSec
                }
                return
            }
            if recType == "event_msg", let pType = payload["type"] as? String,
               (pType == "task_started" || pType == "user_message") {
                if let tsStr = rec["timestamp"] as? String, let tsSec = Self.parseISOToEpochSeconds(tsStr) {
                    lastTurnAnchorTs = tsSec
                }
                return
            }
            guard recType == "event_msg",
                  (payload["type"] as? String) == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let totalUsage = info["total_token_usage"] as? [String: Any],
                  let tsStr = rec["timestamp"] as? String,
                  let tsSec = Self.parseISOToEpochSeconds(tsStr) else {
                return
            }

            let curIn = max(Int64(0), Self.parseInt64(totalUsage["input_tokens"]) ?? 0)
            let curCached = max(Int64(0), Self.parseInt64(totalUsage["cached_input_tokens"]) ?? 0)
            let curCW = max(Int64(0), Self.parseInt64(totalUsage["cache_write_input_tokens"]) ?? 0)
            let curOut = max(Int64(0), Self.parseInt64(totalUsage["output_tokens"]) ?? 0)

            if hasLastTotal && curIn == lastTotalIn && curCached == lastTotalCached && curCW == lastTotalCW && curOut == lastTotalOut {
                return
            }

            let deltaIn: Int64
            let deltaOut: Int64
            if hasLastTotal && curIn >= lastTotalIn && curOut >= lastTotalOut {
                deltaIn = curIn - lastTotalIn
                deltaOut = curOut - lastTotalOut
            } else if let lastUsage = info["last_token_usage"] as? [String: Any] {
                deltaIn = max(0, Self.parseInt64(lastUsage["input_tokens"]) ?? 0)
                deltaOut = max(0, Self.parseInt64(lastUsage["output_tokens"]) ?? 0)
            } else {
                deltaIn = curIn
                deltaOut = curOut
            }

            lastTotalIn = curIn
            lastTotalCached = curCached
            lastTotalCW = curCW
            lastTotalOut = curOut
            hasLastTotal = true

            let totalTok = deltaIn + deltaOut
            let prevStart = max(lastTokenCountTs ?? -1.0, lastTurnAnchorTs ?? -1.0)
            if prevStart > 0.0, deltaOut > 0 {
                let dt = tsSec - prevStart
                if let sample = Self.makeValidSpeedSample(
                    dedupKey: "codex:\(fileName):\(Int64(tsSec * 1000.0)):\(curOut)",
                    client: .codex,
                    modelId: model,
                    outputTokens: deltaOut,
                    totalTokens: totalTok,
                    durationSec: dt,
                    endedAtSec: tsSec,
                    speedCutoffSec: speedCutoffSec
                ) {
                    samples.append(sample)
                }
            }
            lastTokenCountTs = tsSec
        }

        return (Array(samples.suffix(Self.speedMaxSamplesPerFile)), detectedModel)
    }

    // MARK: - 3. Antigravity Scanner (`~/.gemini/{antigravity,antigravity-insiders,antigravity-cli}/brain/*/transcript.jsonl`)

    private func scanAntigravityLogs(
        cache: inout TokenScanCache,
        activePaths: inout Set<String>,
        todayKey: String,
        speedCutoffSec: Double,
        speedMtimeCutoffSec: Double
    ) -> Int {
        // Explicitly SKIP `antigravity-ide` & `antigravity-backup` (100% UUID overlap with `antigravity`).
        let allowedRoots = [
            homeDirectoryURL.appendingPathComponent(".gemini/antigravity", isDirectory: true),
            homeDirectoryURL.appendingPathComponent(".gemini/antigravity-insiders", isDirectory: true),
            homeDirectoryURL.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true),
        ]

        // Optional fast read-only lookup of conversationId -> workspace path from conversation_summaries.db.
        let workspaceMap = loadAntigravityWorkspaces(roots: allowedRoots)

        var seenConversationUUIDs = Set<String>()
        var count = 0
        let fm = FileManager.default

        for root in allowedRoots {
            let brainDir = root.appendingPathComponent("brain", isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(at: brainDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for convDir in entries {
                let uuid = convDir.lastPathComponent
                let transcriptURL = convDir
                    .appendingPathComponent(".system_generated", isDirectory: true)
                    .appendingPathComponent("logs", isDirectory: true)
                    .appendingPathComponent("transcript.jsonl", isDirectory: false)
                let path = transcriptURL.path
                guard fm.fileExists(atPath: path) else { continue }
                guard seenConversationUUIDs.insert(uuid).inserted else { continue }

                activePaths.insert(path)
                count += 1
                guard let attrs = fileMtimeAndSize(at: path) else { continue }

                let existing = cache.files[path]
                if let existing, existing.mtime == attrs.mtime && existing.size == attrs.size {
                    continue
                }

                let canResume = existing != nil && attrs.size >= (existing?.byteOffset ?? 0)
                let startOffset: UInt64 = canResume ? (existing?.byteOffset ?? 0) : 0
                guard let chunk = readFileBytes(at: transcriptURL, fromOffset: startOffset) else { continue }

                var seenSteps = Set<Int>(canResume ? (existing?.seenAntigravitySteps ?? []) : [])
                var builder = BucketAccumulator(homePath: homeDirectoryURL.path)
                if canResume, let prevBuckets = existing?.buckets {
                    builder.seed(prevBuckets)
                }
                let cwd = workspaceMap[uuid]
                let collectSpeed = attrs.mtime >= speedMtimeCutoffSec
                var speedByKey: [String: SpeedSample] = [:]
                if canResume, let prevSpeed = existing?.speedSamples {
                    for s in prevSpeed where s.endedAtSec >= speedCutoffSec {
                        speedByKey[s.dedupKey] = s
                    }
                }
                var pendingStep: PendingAntigravityStep? = canResume ? existing?.antigravityPendingStep : nil
                var prevStepType: String? = canResume ? existing?.antigravityPrevStepType : nil
                var prevStepTsSec: Double? = canResume ? existing?.antigravityPrevStepTsSec : nil
                var lastKnownModel: String? = canResume ? existing?.antigravityLastModel : nil
                var plannerOrdinal: Int = canResume ? (existing?.antigravityPlannerOrdinal ?? 0) : 0
                var didLoadGenMeta = false
                var genMetaIndex: AntigravityGenMetadataIndex? = nil

                let loadGenMetaIfNeeded: () -> AntigravityGenMetadataIndex? = {
                    if !didLoadGenMeta {
                        didLoadGenMeta = true
                        genMetaIndex = self.loadAntigravityGenMetadata(forUUID: uuid, primaryRoot: root, fallbackRoots: allowedRoots)
                    }
                    return genMetaIndex
                }

                forEachJSONLine(in: chunk) { lineData in
                    let hasTokens = Self.utf8Contains(lineData, needle: "\"input_tokens\"")
                    let isPlannerHint = hasTokens && (
                        Self.utf8Contains(lineData, needle: "\"PLANNER_RESPONSE\"")
                            || Self.utf8Contains(lineData, needle: "\"CHECKPOINT\"")
                    )

                    if !collectSpeed && !isPlannerHint {
                        return
                    }

                    // Fast byte-slice extraction avoids parsing megabytes of `content`/`thinking`/`tool_calls`.
                    let recType = Self.extractJSONString(in: lineData, afterKey: "type")
                    let tsStr = Self.extractJSONString(in: lineData, afterKey: "created_at")
                    let tsSec = tsStr.flatMap { Self.parseISOToEpochSeconds($0) }

                    // Close out previous pending PLANNER_RESPONSE using this next step's `created_at`
                    // (Antigravity sets `created_at` at step start, so next tool/response step's `created_at` is the exact end time).
                    if collectSpeed, let pending = pendingStep, let curType = recType, let curTs = tsSec {
                        if curType != "USER_INPUT" && curType != "SYSTEM_MESSAGE" {
                            let dt = curTs - pending.tsSec
                            let key = "agy:\(uuid):\(pending.stepIndex ?? Int(pending.tsSec))"
                            if let sample = Self.makeValidSpeedSample(
                                dedupKey: key,
                                client: .antigravity,
                                modelId: pending.modelId,
                                outputTokens: pending.outputTokens,
                                totalTokens: pending.totalTokens,
                                durationSec: dt,
                                endedAtSec: curTs,
                                speedCutoffSec: speedCutoffSec,
                                minDurationSec: Self.speedAntigravityMinDurationSec
                            ) {
                                speedByKey[key] = sample
                            }
                        }
                        pendingStep = nil
                    }

                    defer {
                        if collectSpeed, let recType, let tsSec {
                            prevStepType = recType
                            prevStepTsSec = tsSec
                        }
                    }

                    guard isPlannerHint, (recType == "PLANNER_RESPONSE" || recType == "CHECKPOINT") else { return }

                    let stepIdx = Self.extractJSONInt64(in: lineData, afterKey: "step_index").map(Int.init)
                    if let stepIdx {
                        guard seenSteps.insert(stepIdx).inserted else { return }
                    }

                    // In Antigravity transcript.jsonl, `input_tokens` is UNCACHED input.
                    let uncachedIn = max(Int64(0), Self.extractJSONInt64(in: lineData, afterKey: "input_tokens") ?? 0)
                    let cacheRead = max(Int64(0), Self.extractJSONInt64(in: lineData, afterKey: "cache_read_tokens") ?? 0)
                    let outputTok = max(Int64(0), Self.extractJSONInt64(in: lineData, afterKey: "output_tokens") ?? 0)
                    let totalTok = uncachedIn + cacheRead + outputTok
                    guard totalTok > 0 else { return }

                    guard let tsStr,
                          let dateKey = Self.parseISOToShanghaiDateKey(tsStr),
                          dateKey <= todayKey else { return }

                    let isCheckpoint = (recType == "CHECKPOINT")
                    let rawModel = Self.extractJSONString(in: lineData, afterKey: "model")?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let modelId = Self.resolveAntigravityModelId(
                        rawModel: rawModel,
                        isCheckpoint: isCheckpoint,
                        stepIndex: stepIdx,
                        plannerOrdinal: plannerOrdinal,
                        lastKnownModel: lastKnownModel,
                        loadGenMetadata: loadGenMetaIfNeeded
                    )
                    if !isCheckpoint {
                        plannerOrdinal += 1
                        if Self.isConcreteAntigravityModelId(modelId) {
                            lastKnownModel = modelId
                        }
                    } else if lastKnownModel == nil && Self.isConcreteAntigravityModelId(modelId) {
                        lastKnownModel = modelId
                    }

                    let providerId = TokenPricingCatalog.defaultProviderId(for: modelId, client: .antigravity)
                    let cost = TokenPricingCatalog.pricing(for: modelId, client: .antigravity).estimateCostUSD(
                        uncachedInput: uncachedIn,
                        output: outputTok,
                        cacheRead: cacheRead,
                        cacheWrite: 0
                    )

                    if collectSpeed, outputTok > 0, let tsSec {
                        pendingStep = PendingAntigravityStep(
                            stepIndex: stepIdx,
                            type: recType ?? "PLANNER_RESPONSE",
                            tsSec: tsSec,
                            modelId: modelId,
                            outputTokens: outputTok,
                            totalTokens: totalTok
                        )
                    }

                    builder.add(
                        date: dateKey,
                        client: .antigravity,
                        modelId: modelId,
                        providerId: providerId,
                        cwd: cwd,
                        totals: TokenComponentTotals(
                            totalTokens: totalTok,
                            uncachedInputTokens: uncachedIn,
                            outputTokens: outputTok,
                            cacheReadTokens: cacheRead,
                            cacheWriteTokens: 0,
                            reasoningTokens: 0,
                            estimatedCostUSD: cost,
                            messageCount: 1
                        )
                    )
                }

                // If the file ends on a PLANNER_RESPONSE, compute a provisional speed sample from file mtime
                // (or preceding USER_INPUT/GENERIC step as fallback for historical synthetic fixtures).
                if collectSpeed, let pending = pendingStep {
                    let key = "agy:\(uuid):\(pending.stepIndex ?? Int(pending.tsSec))"
                    let mtimeDt = attrs.mtime - pending.tsSec
                    if let sample = Self.makeValidSpeedSample(
                        dedupKey: key,
                        client: .antigravity,
                        modelId: pending.modelId,
                        outputTokens: pending.outputTokens,
                        totalTokens: pending.totalTokens,
                        durationSec: mtimeDt,
                        endedAtSec: attrs.mtime,
                        speedCutoffSec: speedCutoffSec,
                        minDurationSec: Self.speedAntigravityMinDurationSec
                    ) {
                        speedByKey[key] = sample
                    } else if let pTs = prevStepTsSec,
                              let pType = prevStepType,
                              (pType == "USER_INPUT" || pType == "GENERIC" || pType == "SYSTEM_MESSAGE") {
                        let prevDt = pending.tsSec - pTs
                        if let sample = Self.makeValidSpeedSample(
                            dedupKey: key,
                            client: .antigravity,
                            modelId: pending.modelId,
                            outputTokens: pending.outputTokens,
                            totalTokens: pending.totalTokens,
                            durationSec: prevDt,
                            endedAtSec: pending.tsSec,
                            speedCutoffSec: speedCutoffSec,
                            minDurationSec: Self.speedAntigravityMinDurationSec
                        ) {
                            speedByKey[key] = sample
                        }
                    }
                }

                let finalSpeed = Array(speedByKey.values.sorted { $0.endedAtSec < $1.endedAtSec }.suffix(Self.speedMaxSamplesPerFile))
                cache.files[path] = CachedFileState(
                    mtime: attrs.mtime,
                    size: attrs.size,
                    byteOffset: attrs.size,
                    buckets: builder.finalize(),
                    codexState: nil,
                    seenAntigravitySteps: Array(seenSteps),
                    speedSamples: finalSpeed.isEmpty ? nil : finalSpeed,
                    antigravityPendingStep: pendingStep,
                    antigravityPrevStepType: prevStepType,
                    antigravityPrevStepTsSec: prevStepTsSec,
                    antigravityLastModel: lastKnownModel,
                    antigravityPlannerOrdinal: plannerOrdinal
                )
            }
        }
        return count
    }

    private func parseAntigravitySpeedSamplesOnly(
        data: Data,
        convUUID: String,
        rootURL: URL? = nil,
        fileMtime: Double,
        speedCutoffSec: Double
    ) -> [SpeedSample] {
        var speedByKey: [String: SpeedSample] = [:]
        var pendingStep: PendingAntigravityStep? = nil
        var prevStepType: String? = nil
        var prevStepTsSec: Double? = nil
        var lastKnownModel: String? = nil
        var plannerOrdinal: Int = 0
        var didLoadGenMeta = false
        var genMetaIndex: AntigravityGenMetadataIndex? = nil

        let loadGenMetaIfNeeded: () -> AntigravityGenMetadataIndex? = {
            if !didLoadGenMeta {
                didLoadGenMeta = true
                if let rootURL {
                    genMetaIndex = self.loadAntigravityGenMetadata(forUUID: convUUID, primaryRoot: rootURL, fallbackRoots: [])
                }
            }
            return genMetaIndex
        }

        forEachJSONLine(in: data) { lineData in
            guard let recType = Self.extractJSONString(in: lineData, afterKey: "type"),
                  let tsStr = Self.extractJSONString(in: lineData, afterKey: "created_at"),
                  let tsSec = Self.parseISOToEpochSeconds(tsStr) else {
                return
            }

            if let pending = pendingStep {
                if recType != "USER_INPUT" && recType != "SYSTEM_MESSAGE" {
                    let dt = tsSec - pending.tsSec
                    let key = "agy:\(convUUID):\(pending.stepIndex ?? Int(pending.tsSec))"
                    if let sample = Self.makeValidSpeedSample(
                        dedupKey: key,
                        client: .antigravity,
                        modelId: pending.modelId,
                        outputTokens: pending.outputTokens,
                        totalTokens: pending.totalTokens,
                        durationSec: dt,
                        endedAtSec: tsSec,
                        speedCutoffSec: speedCutoffSec,
                        minDurationSec: Self.speedAntigravityMinDurationSec
                    ) {
                        speedByKey[key] = sample
                    }
                }
                pendingStep = nil
            }

            if (recType == "PLANNER_RESPONSE" || recType == "CHECKPOINT"),
               Self.utf8Contains(lineData, needle: "\"output_tokens\"") {
                let outputTok = max(Int64(0), Self.extractJSONInt64(in: lineData, afterKey: "output_tokens") ?? 0)
                if outputTok > 0 {
                    let uncachedIn = max(Int64(0), Self.extractJSONInt64(in: lineData, afterKey: "input_tokens") ?? 0)
                    let cacheRead = max(Int64(0), Self.extractJSONInt64(in: lineData, afterKey: "cache_read_tokens") ?? 0)
                    let totalTok = uncachedIn + cacheRead + outputTok
                    let stepIdx = Self.extractJSONInt64(in: lineData, afterKey: "step_index").map(Int.init)
                    let isCheckpoint = (recType == "CHECKPOINT")
                    let rawModel = Self.extractJSONString(in: lineData, afterKey: "model")?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let modelId = Self.resolveAntigravityModelId(
                        rawModel: rawModel,
                        isCheckpoint: isCheckpoint,
                        stepIndex: stepIdx,
                        plannerOrdinal: plannerOrdinal,
                        lastKnownModel: lastKnownModel,
                        loadGenMetadata: loadGenMetaIfNeeded
                    )
                    if !isCheckpoint {
                        plannerOrdinal += 1
                        if Self.isConcreteAntigravityModelId(modelId) {
                            lastKnownModel = modelId
                        }
                    } else if lastKnownModel == nil && Self.isConcreteAntigravityModelId(modelId) {
                        lastKnownModel = modelId
                    }
                    pendingStep = PendingAntigravityStep(
                        stepIndex: stepIdx,
                        type: recType,
                        tsSec: tsSec,
                        modelId: modelId,
                        outputTokens: outputTok,
                        totalTokens: totalTok
                    )
                }
            }

            prevStepType = recType
            prevStepTsSec = tsSec
        }

        if let pending = pendingStep {
            let key = "agy:\(convUUID):\(pending.stepIndex ?? Int(pending.tsSec))"
            let mtimeDt = fileMtime - pending.tsSec
            if let sample = Self.makeValidSpeedSample(
                dedupKey: key,
                client: .antigravity,
                modelId: pending.modelId,
                outputTokens: pending.outputTokens,
                totalTokens: pending.totalTokens,
                durationSec: mtimeDt,
                endedAtSec: fileMtime,
                speedCutoffSec: speedCutoffSec,
                minDurationSec: Self.speedAntigravityMinDurationSec
            ) {
                speedByKey[key] = sample
            } else if let pTs = prevStepTsSec,
                      let pType = prevStepType,
                      (pType == "USER_INPUT" || pType == "GENERIC" || pType == "SYSTEM_MESSAGE") {
                let prevDt = pending.tsSec - pTs
                if let sample = Self.makeValidSpeedSample(
                    dedupKey: key,
                    client: .antigravity,
                    modelId: pending.modelId,
                    outputTokens: pending.outputTokens,
                    totalTokens: pending.totalTokens,
                    durationSec: prevDt,
                    endedAtSec: pending.tsSec,
                    speedCutoffSec: speedCutoffSec,
                    minDurationSec: Self.speedAntigravityMinDurationSec
                ) {
                    speedByKey[key] = sample
                }
            }
        }

        return Array(speedByKey.values.sorted { $0.endedAtSec < $1.endedAtSec }.suffix(Self.speedMaxSamplesPerFile))
    }

    // MARK: - Antigravity `conversations/<uuid>.db` (`gen_metadata`) Protobuf & Read-Only SQLite Recovery

    private struct AntigravityGenMetadataEntry {
        let idx: Int
        let modelId: String
        let lastStepIndex: Int?
    }

    private struct AntigravityGenMetadataIndex {
        let entries: [AntigravityGenMetadataEntry]
        let byLastStepIndex: [Int: String]
        let byOrdinalIdx: [Int: String]
        let dominantModel: String?

        func lookupModel(forStepIndex stepIdx: Int?, plannerOrdinal: Int) -> String? {
            if let stepIdx {
                // Fast exact match: Antigravity records `last_step_index == step_index - 1` for each PLANNER_RESPONSE.
                if let exactPrev = byLastStepIndex[stepIdx - 1] {
                    return exactPrev
                }
                // Closest preceding `last_step_index < stepIdx` within a reasonable step window.
                var bestDelta = Int.max
                var bestModel: String? = nil
                for entry in entries {
                    guard let lsi = entry.lastStepIndex, lsi < stepIdx else { continue }
                    let delta = stepIdx - lsi
                    if delta <= 64 && delta < bestDelta {
                        bestDelta = delta
                        bestModel = entry.modelId
                    }
                }
                if let bestModel {
                    return bestModel
                }
                if let sameStep = byLastStepIndex[stepIdx] {
                    return sameStep
                }
            }
            if let byIdx = byOrdinalIdx[plannerOrdinal] {
                return byIdx
            }
            return nil
        }
    }

    private static func isConcreteAntigravityModelId(_ modelId: String) -> Bool {
        let lower = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !lower.isEmpty && lower != "unknown" && lower != "unknown-model"
    }

    private static func resolveAntigravityModelId(
        rawModel: String?,
        isCheckpoint: Bool,
        stepIndex: Int?,
        plannerOrdinal: Int,
        lastKnownModel: String?,
        loadGenMetadata: () -> AntigravityGenMetadataIndex?
    ) -> String {
        if let rawModel, Self.isConcreteAntigravityModelId(rawModel) {
            return Self.sanitizeModelId(rawModel)
        }

        if isCheckpoint {
            if let last = lastKnownModel, Self.isConcreteAntigravityModelId(last) {
                return last
            }
            if let meta = loadGenMetadata() {
                if let lookedUp = meta.lookupModel(forStepIndex: stepIndex, plannerOrdinal: plannerOrdinal) {
                    return lookedUp
                }
                if let dominant = meta.dominantModel {
                    return dominant
                }
            }
            return "unknown"
        } else {
            if let meta = loadGenMetadata() {
                if let lookedUp = meta.lookupModel(forStepIndex: stepIndex, plannerOrdinal: plannerOrdinal) {
                    return lookedUp
                }
                if let last = lastKnownModel, Self.isConcreteAntigravityModelId(last) {
                    return last
                }
                if let dominant = meta.dominantModel {
                    return dominant
                }
            } else if let last = lastKnownModel, Self.isConcreteAntigravityModelId(last) {
                return last
            }
            return "unknown"
        }
    }

    /// Parses a single `gen_metadata.data` protobuf BLOB from `~/.gemini/antigravity/conversations/<uuid>.db`.
    /// Strictly bounds-checked pure Swift wire decoder (zero external dependencies):
    /// - Top-level field `1` (length-delimited submessage):
    ///   - Field `19` (UTF-8): canonical model base ID (e.g. `"gemini-4-carbon"`, `"claude-opus-5-5-high"`).
    ///   - Field `20` (repeated map entry `f1=key`, `f2=value`): extracts `"last_step_index"`.
    ///   - Field `21` (UTF-8): human display name including reasoning tier (e.g. `"Gemini 4 Carbon (High)"`).
    public static func parseAntigravityGenMetadataBlob(_ data: Data) -> (modelId: String?, lastStepIndex: Int?) {
        guard !data.isEmpty else { return (nil, nil) }

        return data.withUnsafeBytes { rawBuf -> (modelId: String?, lastStepIndex: Int?) in
            guard let basePtr = rawBuf.bindMemory(to: UInt8.self).baseAddress else {
                return (nil, nil)
            }
            let bytes = UnsafeBufferPointer(start: basePtr, count: rawBuf.count)

            var baseModel: String? = nil
            var displayName: String? = nil
            var lastStepIndex: Int? = nil

            var offset = 0
            let end = bytes.count
            while offset < end {
                guard let tag = readProtoVarint(bytes, offset: &offset, end: end) else { break }
                let fieldNumber = tag >> 3
                let wireType = tag & 0x7
                guard fieldNumber > 0 else { break }

                if fieldNumber == 1 && wireType == 2 {
                    guard let len64 = readProtoVarint(bytes, offset: &offset, end: end),
                          len64 <= UInt64(end - offset) else {
                        break
                    }
                    let subStart = offset
                    let subEnd = offset + Int(len64)
                    offset = subEnd

                    parseAntigravityGenMetadataSubmessage(
                        bytes,
                        start: subStart,
                        end: subEnd,
                        baseModel: &baseModel,
                        displayName: &displayName,
                        lastStepIndex: &lastStepIndex
                    )
                } else {
                    guard skipProtoField(bytes, wireType: wireType, offset: &offset, end: end) else {
                        break
                    }
                }
            }

            let resolvedModel = normalizeAntigravityGenMetadataModel(
                baseModel: baseModel,
                displayName: displayName
            )
            return (resolvedModel, lastStepIndex)
        }
    }

    private static func parseAntigravityGenMetadataSubmessage(
        _ bytes: UnsafeBufferPointer<UInt8>,
        start: Int,
        end: Int,
        baseModel: inout String?,
        displayName: inout String?,
        lastStepIndex: inout Int?
    ) {
        var offset = start
        while offset < end {
            guard let tag = readProtoVarint(bytes, offset: &offset, end: end) else { break }
            let fieldNumber = tag >> 3
            let wireType = tag & 0x7
            guard fieldNumber > 0 else { break }

            if wireType == 2 {
                guard let len64 = readProtoVarint(bytes, offset: &offset, end: end),
                      len64 <= UInt64(end - offset) else {
                    break
                }
                let subStart = offset
                let subEnd = offset + Int(len64)
                offset = subEnd

                switch fieldNumber {
                case 19:
                    if let str = decodeProtoUTF8(bytes, start: subStart, end: subEnd)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !str.isEmpty {
                        baseModel = str
                    }
                case 20:
                    var key: String? = nil
                    var value: String? = nil
                    var kvOffset = subStart
                    while kvOffset < subEnd {
                        guard let kvTag = readProtoVarint(bytes, offset: &kvOffset, end: subEnd) else { break }
                        let kvField = kvTag >> 3
                        let kvWire = kvTag & 0x7
                        guard kvField > 0 else { break }
                        if kvWire == 2 {
                            guard let kvLen64 = readProtoVarint(bytes, offset: &kvOffset, end: subEnd),
                                  kvLen64 <= UInt64(subEnd - kvOffset) else {
                                break
                            }
                            let valStart = kvOffset
                            let valEnd = kvOffset + Int(kvLen64)
                            kvOffset = valEnd
                            if kvField == 1 {
                                key = decodeProtoUTF8(bytes, start: valStart, end: valEnd)
                            } else if kvField == 2 {
                                value = decodeProtoUTF8(bytes, start: valStart, end: valEnd)
                            }
                        } else {
                            guard skipProtoField(bytes, wireType: kvWire, offset: &kvOffset, end: subEnd) else {
                                break
                            }
                        }
                    }
                    if key == "last_step_index",
                       let rawIdx = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                       let parsedIdx = Int(rawIdx) {
                        lastStepIndex = parsedIdx
                    }
                case 21:
                    if let str = decodeProtoUTF8(bytes, start: subStart, end: subEnd)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !str.isEmpty {
                        displayName = str
                    }
                default:
                    break
                }
            } else {
                guard skipProtoField(bytes, wireType: wireType, offset: &offset, end: end) else {
                    break
                }
            }
        }
    }

    private static func readProtoVarint(
        _ bytes: UnsafeBufferPointer<UInt8>,
        offset: inout Int,
        end: Int
    ) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < end {
            let b = bytes[offset]
            offset += 1
            let low = UInt64(b & 0x7F)
            if shift >= 64 || (shift == 63 && low > 1) {
                return nil
            }
            result |= (low << shift)
            if (b & 0x80) == 0 {
                return result
            }
            shift += 7
        }
        return nil
    }

    private static func skipProtoField(
        _ bytes: UnsafeBufferPointer<UInt8>,
        wireType: UInt64,
        offset: inout Int,
        end: Int
    ) -> Bool {
        switch wireType {
        case 0:
            return readProtoVarint(bytes, offset: &offset, end: end) != nil
        case 1:
            guard end - offset >= 8 else { return false }
            offset += 8
            return true
        case 2:
            guard let len64 = readProtoVarint(bytes, offset: &offset, end: end),
                  len64 <= UInt64(end - offset) else {
                return false
            }
            offset += Int(len64)
            return true
        case 5:
            guard end - offset >= 4 else { return false }
            offset += 4
            return true
        default:
            return false
        }
    }

    private static func decodeProtoUTF8(
        _ bytes: UnsafeBufferPointer<UInt8>,
        start: Int,
        end: Int
    ) -> String? {
        guard start <= end, end <= bytes.count else { return nil }
        guard start < end else { return "" }
        let slice = UnsafeBufferPointer(rebasing: bytes[start..<end])
        return String(decoding: slice, as: UTF8.self)
    }

    private static func extractReasoningTierSuffix(from displayName: String?) -> String? {
        guard let displayName else { return nil }
        let lower = displayName.lowercased()
        // Check `(xhigh)` before `(high)` so XHigh never misclassifies as High.
        if lower.contains("(xhigh)") || lower.contains("（xhigh）") {
            return "-xhigh"
        }
        if lower.contains("(high)") || lower.contains("（high）") {
            return "-high"
        }
        if lower.contains("(medium)") || lower.contains("（medium）") {
            return "-medium"
        }
        if lower.contains("(low)") || lower.contains("（low）") {
            return "-low"
        }
        return nil
    }

    private static func normalizeAntigravityGenMetadataModel(
        baseModel: String?,
        displayName: String?
    ) -> String? {
        let tierSuffix = extractReasoningTierSuffix(from: displayName)
        let knownTierSuffixes = ["-xhigh", "-high", "-medium", "-low"]

        let candidateBase: String?
        if let rawBase = baseModel?.trimmingCharacters(in: .whitespacesAndNewlines), !rawBase.isEmpty {
            candidateBase = rawBase
        } else if let rawDisplay = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !rawDisplay.isEmpty {
            // Fallback when protobuf field 19 is absent and only field 21 (e.g. "Gemini 4 Carbon (High)") is present.
            var stripped = rawDisplay
            for token in ["(XHigh)", "(High)", "(Medium)", "(Low)", "(xhigh)", "(high)", "(medium)", "(low)"] {
                stripped = stripped.replacingOccurrences(of: token, with: "")
            }
            let slug = stripped
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: "-")
            if slug.hasPrefix("claude-") {
                candidateBase = slug.replacingOccurrences(of: ".", with: "-")
            } else {
                candidateBase = slug.isEmpty ? nil : slug
            }
        } else {
            candidateBase = nil
        }

        guard var model = candidateBase, !model.isEmpty else { return nil }
        if let tierSuffix {
            let lowerModel = model.lowercased()
            let alreadyHasTier = knownTierSuffixes.contains { lowerModel.hasSuffix($0) }
            if !alreadyHasTier {
                model += tierSuffix
            }
        }
        let sanitized = sanitizeModelId(model)
        return isConcreteAntigravityModelId(sanitized) ? sanitized : nil
    }

    private static func sqliteReadOnlyImmutableURI(forPath path: String) -> String {
        var encoded = path
        encoded = encoded.replacingOccurrences(of: "%", with: "%25")
        encoded = encoded.replacingOccurrences(of: "?", with: "%3F")
        encoded = encoded.replacingOccurrences(of: "#", with: "%23")
        encoded = encoded.replacingOccurrences(of: " ", with: "%20")
        return "file:\(encoded)?mode=ro&immutable=1"
    }

    private func loadAntigravityGenMetadata(
        forUUID uuid: String,
        primaryRoot: URL,
        fallbackRoots: [URL]
    ) -> AntigravityGenMetadataIndex? {
        let fm = FileManager.default
        var candidateRoots: [URL] = [primaryRoot]
        for r in fallbackRoots where r.path != primaryRoot.path {
            candidateRoots.append(r)
        }

        var foundDBURL: URL? = nil
        for root in candidateRoots {
            let dbURL = root
                .appendingPathComponent("conversations", isDirectory: true)
                .appendingPathComponent("\(uuid).db", isDirectory: false)
            if fm.fileExists(atPath: dbURL.path) {
                foundDBURL = dbURL
                break
            }
        }
        guard let dbURL = foundDBURL else { return nil }

        var db: OpaquePointer?
        let uri = Self.sqliteReadOnlyImmutableURI(forPath: dbURL.path)
        let uriFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        var rc = sqlite3_open_v2(uri, &db, uriFlags, nil)
        if rc != SQLITE_OK || db == nil {
            if let db { sqlite3_close(db) }
            db = nil
            let plainFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            rc = sqlite3_open_v2(dbURL.path, &db, plainFlags, nil)
        }
        guard rc == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)

        var stmt: OpaquePointer?
        let sql = "SELECT idx, data FROM gen_metadata ORDER BY idx ASC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var entries: [AntigravityGenMetadataEntry] = []
        var byLastStepIndex: [Int: String] = [:]
        var byOrdinalIdx: [Int: String] = [:]
        var countsByModel: [String: (count: Int, lastIdx: Int)] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let idx = Int(sqlite3_column_int64(stmt, 0))
            guard let rawPtr = sqlite3_column_blob(stmt, 1) else { continue }
            let byteCount = Int(sqlite3_column_bytes(stmt, 1))
            guard byteCount > 0 else { continue }
            let blobData = Data(bytes: rawPtr, count: byteCount)
            let parsed = Self.parseAntigravityGenMetadataBlob(blobData)
            guard let modelId = parsed.modelId else { continue }

            entries.append(
                AntigravityGenMetadataEntry(
                    idx: idx,
                    modelId: modelId,
                    lastStepIndex: parsed.lastStepIndex
                )
            )
            byOrdinalIdx[idx] = modelId
            if let lsi = parsed.lastStepIndex {
                byLastStepIndex[lsi] = modelId
            }
            let prev = countsByModel[modelId] ?? (0, idx)
            countsByModel[modelId] = (prev.count + 1, max(prev.lastIdx, idx))
        }

        guard !entries.isEmpty else { return nil }
        let dominantModel = countsByModel.max { lhs, rhs in
            if lhs.value.count != rhs.value.count {
                return lhs.value.count < rhs.value.count
            }
            return lhs.value.lastIdx < rhs.value.lastIdx
        }?.key

        return AntigravityGenMetadataIndex(
            entries: entries,
            byLastStepIndex: byLastStepIndex,
            byOrdinalIdx: byOrdinalIdx,
            dominantModel: dominantModel
        )
    }

    private func loadAntigravityWorkspaces(roots: [URL]) -> [String: String] {
        var map: [String: String] = [:]
        for root in roots {
            let dbURL = root.appendingPathComponent("conversation_summaries.db", isDirectory: false)
            guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }
            var db: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }
                continue
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 500)

            var stmt: OpaquePointer?
            let sql = "SELECT conversation_id, workspace_uris FROM conversation_summaries WHERE workspace_uris != ''"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let cId = sqlite3_column_text(stmt, 0),
                          let cUri = sqlite3_column_text(stmt, 1) else { continue }
                    let convId = String(cString: cId)
                    let uriRaw = String(cString: cUri)
                    if let firstPath = Self.extractFirstWorkspacePath(from: uriRaw) {
                        map[convId] = firstPath
                    }
                }
            }
        }
        return map
    }

    private static func extractFirstWorkspacePath(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [String],
           let first = arr.first {
            return cleanFileURI(first)
        }
        let firstPart = trimmed.split(separator: ",").first.map(String.init) ?? trimmed
        return cleanFileURI(firstPart)
    }

    private static func cleanFileURI(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: " \"'\n\r\t"))
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            return url.path
        }
        return trimmed.hasPrefix("/") ? trimmed : nil
    }

    // MARK: - 4. Grok Scanner (`~/.grok/sessions/*/*/usage.json` & recent `updates.jsonl`)

    private func scanGrokLogs(
        cache: inout TokenScanCache,
        activePaths: inout Set<String>,
        todayKey: String,
        speedCutoffSec: Double,
        speedMtimeCutoffSec: Double
    ) -> Int {
        let sessionsRoot = homeDirectoryURL.appendingPathComponent(".grok/sessions", isDirectory: true)
        let fm = FileManager.default
        guard let cwdDirs = try? fm.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return 0
        }

        var count = 0
        for cwdDir in cwdDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: cwdDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let decodedCwd = cwdDir.lastPathComponent.removingPercentEncoding
            guard let sessionDirs = try? fm.contentsOfDirectory(at: cwdDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for sDir in sessionDirs {
                let sid = sDir.lastPathComponent
                let usageURL = sDir.appendingPathComponent("usage.json", isDirectory: false)
                let path = usageURL.path
                if fm.fileExists(atPath: path) {
                    activePaths.insert(path)
                    count += 1
                    if let attrs = fileMtimeAndSize(at: path) {
                        if let existing = cache.files[path], existing.mtime == attrs.mtime && existing.size == attrs.size {
                            // Unchanged
                        } else if let data = try? Data(contentsOf: usageURL),
                                  let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] {
                            let buckets = parseGrokUsageJSON(root: root, cwd: decodedCwd, todayKey: todayKey)
                            let speedSamples: [SpeedSample] = attrs.mtime >= speedMtimeCutoffSec
                                ? parseGrokUsageSpeedSamples(root: root, sessionKey: sid, speedCutoffSec: speedCutoffSec)
                                : []
                            cache.files[path] = CachedFileState(
                                mtime: attrs.mtime,
                                size: attrs.size,
                                byteOffset: attrs.size,
                                buckets: buckets,
                                codexState: nil,
                                seenAntigravitySteps: nil,
                                speedSamples: speedSamples.isEmpty ? nil : speedSamples
                            )
                        }
                    }
                }

                // Also inspect recent 7-day `updates.jsonl` for exact per-turn `apiDurationMs` speed samples
                // (never increments `liveScannedFilesCount` and stores empty `buckets` so usage totals are untouched).
                let updatesURL = sDir.appendingPathComponent("updates.jsonl", isDirectory: false)
                let updatesPath = updatesURL.path
                if let uAttrs = fileMtimeAndSize(at: updatesPath), uAttrs.mtime >= speedMtimeCutoffSec {
                    activePaths.insert(updatesPath)
                    if let existing = cache.files[updatesPath], existing.mtime == uAttrs.mtime && existing.size == uAttrs.size {
                        continue
                    }
                    if let data = try? Data(contentsOf: updatesURL) {
                        let samples = autoreleasepool {
                            parseGrokUpdatesSpeedSamples(data: data, sessionKey: sid, speedCutoffSec: speedCutoffSec)
                        }
                        cache.files[updatesPath] = CachedFileState(
                            mtime: uAttrs.mtime,
                            size: uAttrs.size,
                            byteOffset: uAttrs.size,
                            buckets: [],
                            codexState: nil,
                            seenAntigravitySteps: nil,
                            speedSamples: samples.isEmpty ? nil : samples
                        )
                    }
                }
            }
        }
        return count
    }

    private func parseGrokUsageJSON(root: [String: Any], cwd: String?, todayKey: String) -> [CachedUsageBucket] {
        var builder = BucketAccumulator(homePath: homeDirectoryURL.path)
        let fallbackDate = (root["updatedAt"] as? String).flatMap { Self.parseISOToShanghaiDateKey($0) }

        func ingestUsageEntry(_ obj: [String: Any], dateKey: String, defaultModel: String) {
            if let modelUsage = obj["modelUsage"] as? [String: Any], !modelUsage.isEmpty {
                for (rawModel, mVal) in modelUsage {
                    guard let md = mVal as? [String: Any] else { continue }
                    addGrokModelDict(md, rawModel: rawModel, dateKey: dateKey, cwd: cwd, builder: &builder)
                }
            } else {
                addGrokModelDict(obj, rawModel: defaultModel, dateKey: dateKey, cwd: cwd, builder: &builder)
            }
        }

        if let turns = root["turns"] as? [[String: Any]], !turns.isEmpty {
            for turn in turns {
                guard let dateKey = ((turn["endedAt"] as? String).flatMap { Self.parseISOToShanghaiDateKey($0) }) ?? fallbackDate,
                      dateKey <= todayKey else { continue }
                let defaultModel = (turn["primaryModelId"] as? String) ?? "grok-4"
                ingestUsageEntry(turn, dateKey: dateKey, defaultModel: defaultModel)
            }
        } else if let session = root["session"] as? [String: Any],
                  let dateKey = fallbackDate,
                  dateKey <= todayKey {
            let defaultModel = (session["primaryModelId"] as? String) ?? "grok-4"
            ingestUsageEntry(session, dateKey: dateKey, defaultModel: defaultModel)
        }

        return builder.finalize()
    }

    private func parseGrokUsageSpeedSamples(root: [String: Any], sessionKey: String, speedCutoffSec: Double) -> [SpeedSample] {
        guard let turns = root["turns"] as? [[String: Any]], !turns.isEmpty else { return [] }
        let fallbackEndSec = (root["updatedAt"] as? String).flatMap { Self.parseISOToEpochSeconds($0) }
        var out: [SpeedSample] = []

        for (idx, turn) in turns.enumerated() {
            let endSec = ((turn["endedAt"] as? String).flatMap { Self.parseISOToEpochSeconds($0) }) ?? fallbackEndSec
            guard let endSec, endSec >= speedCutoffSec else { continue }
            let startSec = (turn["startedAt"] as? String).flatMap { Self.parseISOToEpochSeconds($0) }
            let turnApiDurMs = Self.parseDouble(turn["apiDurationMs"])
            let turnCalls = Int(max(Int64(1), Self.parseInt64(turn["modelCalls"]) ?? 1))
            let turnTag = (turn["turnNumber"].flatMap { Self.parseInt64($0) }).map(String.init) ?? "\(idx)"

            func emit(_ md: [String: Any], rawModel: String) {
                let outTok = max(Int64(0), Self.parseInt64(md["outputTokens"]) ?? 0)
                guard outTok > 0 else { return }
                let inTok = max(Int64(0), Self.parseInt64(md["inputTokens"]) ?? 0)
                let totTok = max(Self.parseInt64(md["totalTokens"]) ?? 0, inTok + outTok)
                let calls = Int(max(Int64(1), Self.parseInt64(md["modelCalls"]) ?? Int64(turnCalls)))
                let durSec: Double?
                if let ms = Self.parseDouble(md["apiDurationMs"]) ?? turnApiDurMs, ms > 0 {
                    durSec = ms / 1000.0
                } else if let startSec, endSec > startSec {
                    durSec = endSec - startSec
                } else {
                    durSec = nil
                }
                guard let durSec else { return }
                let perCall = durSec / Double(calls)
                guard perCall >= Self.speedMinDurationSec && perCall <= Self.speedMaxDurationSec else { return }
                let modelId = Self.sanitizeModelId(rawModel)
                if let sample = Self.makeValidSpeedSample(
                    dedupKey: "grok:\(sessionKey):\(Int64(endSec / 2.0)):\(turnTag):\(modelId)",
                    client: .grok,
                    modelId: modelId,
                    outputTokens: outTok,
                    totalTokens: totTok,
                    durationSec: durSec,
                    endedAtSec: endSec,
                    speedCutoffSec: speedCutoffSec,
                    minDurationSec: Self.speedMinDurationSec,
                    maxDurationSec: min(3600.0, Self.speedMaxDurationSec * Double(calls))
                ) {
                    out.append(sample)
                }
            }

            if let modelUsage = turn["modelUsage"] as? [String: Any], !modelUsage.isEmpty {
                for (rawModel, mVal) in modelUsage {
                    if let md = mVal as? [String: Any] {
                        emit(md, rawModel: rawModel)
                    }
                }
            } else {
                let defaultModel = (turn["primaryModelId"] as? String) ?? "grok-4"
                emit(turn, rawModel: defaultModel)
            }
        }
        return Array(out.sorted { $0.endedAtSec < $1.endedAtSec }.suffix(Self.speedMaxSamplesPerFile))
    }

    private func parseGrokUpdatesSpeedSamples(data: Data, sessionKey: String, speedCutoffSec: Double) -> [SpeedSample] {
        var out: [SpeedSample] = []
        forEachJSONLine(in: data) { lineData in
            guard Self.utf8Contains(lineData, bytes: Self.needleGrokTurnCompleted) else { return }
            guard let rec = (try? JSONSerialization.jsonObject(with: lineData, options: [])) as? [String: Any],
                  let params = rec["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  (update["sessionUpdate"] as? String) == "turn_completed",
                  let usage = update["usage"] as? [String: Any] else { return }

            let endSecRaw = Self.parseDouble(rec["timestamp_us"]).flatMap { Self.epochToSeconds($0) }
                ?? Self.parseDouble(rec["timestamp"]).flatMap { Self.epochToSeconds($0) }
            guard let endSec = endSecRaw, endSec >= speedCutoffSec else { return }

            let promptId = (update["prompt_id"] as? String) ?? String(Int64(endSec))
            let fallbackDurMs = Self.parseDouble(usage["apiDurationMs"]) ?? Self.parseDouble(update["elapsed_ms"])
            let fallbackCalls = Int(max(Int64(1), Self.parseInt64(usage["modelCalls"]) ?? 1))

            func emit(_ md: [String: Any], rawModel: String) {
                let outTok = max(Int64(0), Self.parseInt64(md["outputTokens"]) ?? 0)
                guard outTok > 0 else { return }
                let inTok = max(Int64(0), Self.parseInt64(md["inputTokens"]) ?? 0)
                let totTok = max(Self.parseInt64(md["totalTokens"]) ?? 0, inTok + outTok)
                guard let durMs = Self.parseDouble(md["apiDurationMs"]) ?? fallbackDurMs, durMs > 0 else { return }
                let durSec = durMs / 1000.0
                let calls = Int(max(Int64(1), Self.parseInt64(md["modelCalls"]) ?? Int64(fallbackCalls)))
                let perCall = durSec / Double(calls)
                guard perCall >= Self.speedMinDurationSec && perCall <= Self.speedMaxDurationSec else { return }
                let modelId = Self.sanitizeModelId(rawModel)
                if let sample = Self.makeValidSpeedSample(
                    dedupKey: "grok:\(sessionKey):\(promptId):\(modelId)",
                    client: .grok,
                    modelId: modelId,
                    outputTokens: outTok,
                    totalTokens: totTok,
                    durationSec: durSec,
                    endedAtSec: endSec,
                    speedCutoffSec: speedCutoffSec,
                    minDurationSec: Self.speedMinDurationSec,
                    maxDurationSec: min(3600.0, Self.speedMaxDurationSec * Double(calls))
                ) {
                    out.append(sample)
                }
            }

            if let modelUsage = usage["modelUsage"] as? [String: Any], !modelUsage.isEmpty {
                for (rawModel, mVal) in modelUsage {
                    if let md = mVal as? [String: Any] {
                        emit(md, rawModel: rawModel)
                    }
                }
            } else {
                let defaultModel = (usage["primaryModelId"] as? String) ?? "grok-4"
                emit(usage, rawModel: defaultModel)
            }
        }
        return Array(out.sorted { $0.endedAtSec < $1.endedAtSec }.suffix(Self.speedMaxSamplesPerFile))
    }

    private func addGrokModelDict(
        _ md: [String: Any],
        rawModel: String,
        dateKey: String,
        cwd: String?,
        builder: inout BucketAccumulator
    ) {
        // In Grok usage.json: `inputTokens` INCLUDES `cachedReadTokens`, `outputTokens` INCLUDES `reasoningTokens`.
        let inTok = max(Int64(0), Self.parseInt64(md["inputTokens"]) ?? 0)
        let outTok = max(Int64(0), Self.parseInt64(md["outputTokens"]) ?? 0)
        let crTok = min(max(Int64(0), Self.parseInt64(md["cachedReadTokens"]) ?? 0), inTok)
        let cwTok = min(max(Int64(0), Self.parseInt64(md["cacheCreationTokens"]) ?? 0), max(0, inTok - crTok))
        let uncachedIn = max(Int64(0), inTok - crTok - cwTok)
        let reasTok = min(max(Int64(0), Self.parseInt64(md["reasoningTokens"]) ?? 0), outTok)
        let totalTok = max(Self.parseInt64(md["totalTokens"]) ?? 0, uncachedIn + crTok + cwTok + outTok)
        guard totalTok > 0 else { return }

        let modelId = Self.sanitizeModelId(rawModel)
        let calls = Int(max(Int64(1), Self.parseInt64(md["modelCalls"]) ?? 1))
        let costUSD: Double
        if let ticks = Self.parseDouble(md["costUsdTicks"]), ticks > 0 {
            costUSD = ticks / 10_000_000_000.0 // 1e10 ticks per USD
        } else {
            costUSD = TokenPricingCatalog.pricing(for: modelId, client: .grok).estimateCostUSD(
                uncachedInput: uncachedIn,
                output: outTok,
                cacheRead: crTok,
                cacheWrite: cwTok
            )
        }

        builder.add(
            date: dateKey,
            client: .grok,
            modelId: modelId,
            providerId: "xai",
            cwd: cwd,
            totals: TokenComponentTotals(
                totalTokens: totalTok,
                uncachedInputTokens: uncachedIn,
                outputTokens: outTok,
                cacheReadTokens: crTok,
                cacheWriteTokens: cwTok,
                reasoningTokens: reasTok,
                estimatedCostUSD: costUSD,
                messageCount: calls
            )
        )
    }

    // MARK: - 5. Kimi Code Scanner (`~/.kimi-code/sessions/*/*/agents/*/wire.jsonl`, Byte-Offset Incremental)

    private func scanKimiLogs(
        cache: inout TokenScanCache,
        activePaths: inout Set<String>,
        todayKey: String,
        speedCutoffSec: Double,
        speedMtimeCutoffSec: Double
    ) -> Int {
        let root = homeDirectoryURL.appendingPathComponent(".kimi-code/sessions", isDirectory: true)
        let files = enumerateFiles(under: root, exactFileName: "wire.jsonl")
        guard !files.isEmpty else { return 0 }

        var count = 0
        for url in files {
            let path = url.path
            activePaths.insert(path)
            count += 1
            guard let attrs = fileMtimeAndSize(at: path) else { continue }

            let existing = cache.files[path]
            if let existing, existing.mtime == attrs.mtime && existing.size == attrs.size {
                continue
            }

            let canResume = existing != nil && attrs.size >= (existing?.byteOffset ?? 0)
            let startOffset: UInt64 = canResume ? (existing?.byteOffset ?? 0) : 0
            guard let chunk = readFileBytes(at: url, fromOffset: startOffset) else { continue }

            // Sibling `../../state.json` carries session `cwd`.
            let agentDir = url.deletingLastPathComponent()
            let sessionDir = agentDir.deletingLastPathComponent().deletingLastPathComponent()
            let stateURL = sessionDir.appendingPathComponent("state.json", isDirectory: false)
            let cwd = Self.readJSONStringField(at: stateURL, key: "cwd")
            let sessionAgentKey = "\(sessionDir.lastPathComponent):\(agentDir.lastPathComponent)"

            var builder = BucketAccumulator(homePath: homeDirectoryURL.path)
            if canResume, let prevBuckets = existing?.buckets {
                builder.seed(prevBuckets)
            }
            let collectSpeed = attrs.mtime >= speedMtimeCutoffSec
            var speedSamples: [SpeedSample] = canResume
                ? (existing?.speedSamples ?? []).filter { $0.endedAtSec >= speedCutoffSec }
                : []
            var lastRequestMs: Double? = canResume ? existing?.kimiLastRequestMs : nil
            var lastUsageMs: Double? = canResume ? existing?.kimiLastUsageMs : nil

            forEachJSONLine(in: chunk) { lineData in
                if collectSpeed && Self.utf8Contains(lineData, needle: "\"llm.request\"") {
                    if let rec = (try? JSONSerialization.jsonObject(with: lineData, options: [])) as? [String: Any],
                       (rec["type"] as? String) == "llm.request",
                       let ms = Self.parseDouble(rec["time"]) {
                        lastRequestMs = ms
                    }
                    return
                }
                guard Self.utf8Contains(lineData, needle: "\"usage.record\"") else { return }
                guard let rec = (try? JSONSerialization.jsonObject(with: lineData, options: [])) as? [String: Any],
                      (rec["type"] as? String) == "usage.record",
                      let usage = rec["usage"] as? [String: Any] else { return }

                // In Kimi Code wire.jsonl, `inputOther` is UNCACHED input.
                let uncachedIn = max(Int64(0), Self.parseInt64(usage["inputOther"]) ?? 0)
                let outputTok = max(Int64(0), Self.parseInt64(usage["output"]) ?? 0)
                let cacheRead = max(Int64(0), Self.parseInt64(usage["inputCacheRead"]) ?? 0)
                let cacheWrite = max(Int64(0), Self.parseInt64(usage["inputCacheCreation"]) ?? 0)
                let totalTok = uncachedIn + outputTok + cacheRead + cacheWrite
                guard totalTok > 0 else { return }

                guard let ms = Self.parseDouble(rec["time"]),
                      let dateKey = Self.epochMsToShanghaiDateKey(ms),
                      dateKey <= todayKey else { return }

                let rawModel = (rec["model"] as? String) ?? "kimi-code"
                let modelId = Self.sanitizeModelId(rawModel)

                if collectSpeed, let endSec = Self.epochToSeconds(ms) {
                    if let startMs = lastRequestMs ?? lastUsageMs,
                       let startSec = Self.epochToSeconds(startMs),
                       outputTok > 0 {
                        let dt = endSec - startSec
                        if let sample = Self.makeValidSpeedSample(
                            dedupKey: "kimi:\(sessionAgentKey):\(Int64(ms)):\(outputTok)",
                            client: .kimi,
                            modelId: modelId,
                            outputTokens: outputTok,
                            totalTokens: totalTok,
                            durationSec: dt,
                            endedAtSec: endSec,
                            speedCutoffSec: speedCutoffSec
                        ) {
                            speedSamples.append(sample)
                        }
                    }
                    lastRequestMs = nil
                    lastUsageMs = ms
                }

                let cost = TokenPricingCatalog.pricing(for: modelId, client: .kimi).estimateCostUSD(
                    uncachedInput: uncachedIn,
                    output: outputTok,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite
                )
                builder.add(
                    date: dateKey,
                    client: .kimi,
                    modelId: modelId,
                    providerId: "moonshot",
                    cwd: cwd,
                    totals: TokenComponentTotals(
                        totalTokens: totalTok,
                        uncachedInputTokens: uncachedIn,
                        outputTokens: outputTok,
                        cacheReadTokens: cacheRead,
                        cacheWriteTokens: cacheWrite,
                        reasoningTokens: 0,
                        estimatedCostUSD: cost,
                        messageCount: 1
                    )
                )
            }

            let trimmedSpeed = Array(speedSamples.filter { $0.endedAtSec >= speedCutoffSec }.suffix(Self.speedMaxSamplesPerFile))
            cache.files[path] = CachedFileState(
                mtime: attrs.mtime,
                size: attrs.size,
                byteOffset: attrs.size,
                buckets: builder.finalize(),
                codexState: nil,
                seenAntigravitySteps: nil,
                speedSamples: trimmedSpeed.isEmpty ? nil : trimmedSpeed,
                kimiLastRequestMs: lastRequestMs,
                kimiLastUsageMs: lastUsageMs
            )
        }
        return count
    }

    private func parseKimiSpeedSamplesOnly(data: Data, sessionAgentKey: String, speedCutoffSec: Double) -> [SpeedSample] {
        var lastRequestMs: Double? = nil
        var lastUsageMs: Double? = nil
        var out: [SpeedSample] = []

        forEachJSONLine(in: data) { lineData in
            if Self.utf8Contains(lineData, needle: "\"llm.request\"") {
                if let rec = (try? JSONSerialization.jsonObject(with: lineData, options: [])) as? [String: Any],
                   (rec["type"] as? String) == "llm.request",
                   let ms = Self.parseDouble(rec["time"]) {
                    lastRequestMs = ms
                }
                return
            }
            guard Self.utf8Contains(lineData, needle: "\"usage.record\"") else { return }
            guard let rec = (try? JSONSerialization.jsonObject(with: lineData, options: [])) as? [String: Any],
                  (rec["type"] as? String) == "usage.record",
                  let usage = rec["usage"] as? [String: Any],
                  let ms = Self.parseDouble(rec["time"]),
                  let endSec = Self.epochToSeconds(ms) else { return }

            let uncachedIn = max(Int64(0), Self.parseInt64(usage["inputOther"]) ?? 0)
            let outputTok = max(Int64(0), Self.parseInt64(usage["output"]) ?? 0)
            let cacheRead = max(Int64(0), Self.parseInt64(usage["inputCacheRead"]) ?? 0)
            let cacheWrite = max(Int64(0), Self.parseInt64(usage["inputCacheCreation"]) ?? 0)
            let totalTok = uncachedIn + outputTok + cacheRead + cacheWrite

            if let startMs = lastRequestMs ?? lastUsageMs,
               let startSec = Self.epochToSeconds(startMs),
               outputTok > 0 {
                let dt = endSec - startSec
                let rawModel = (rec["model"] as? String) ?? "kimi-code"
                if let sample = Self.makeValidSpeedSample(
                    dedupKey: "kimi:\(sessionAgentKey):\(Int64(ms)):\(outputTok)",
                    client: .kimi,
                    modelId: Self.sanitizeModelId(rawModel),
                    outputTokens: outputTok,
                    totalTokens: totalTok,
                    durationSec: dt,
                    endedAtSec: endSec,
                    speedCutoffSec: speedCutoffSec
                ) {
                    out.append(sample)
                }
            }
            lastRequestMs = nil
            lastUsageMs = ms
        }
        return Array(out.suffix(Self.speedMaxSamplesPerFile))
    }

    // MARK: - 6. DSH Scanner (`~/.dsh/sessions/*/*/session.v4.jsonl.zstd` & `session.jsonl.zstd`, In-Process libzstd)

    private func scanDSHLogs(
        cache: inout TokenScanCache,
        activePaths: inout Set<String>,
        todayKey: String,
        speedCutoffSec: Double,
        speedMtimeCutoffSec: Double
    ) -> Int {
        guard DynamicZstdLoader.shared.isAvailable else { return 0 }
        let root = homeDirectoryURL.appendingPathComponent(".dsh/sessions", isDirectory: true)
        let files = enumerateFiles(under: root, suffix: ".jsonl.zstd")
        guard !files.isEmpty else { return 0 }

        var count = 0
        for url in files {
            let path = url.path
            activePaths.insert(path)
            count += 1
            guard let attrs = fileMtimeAndSize(at: path) else { continue }
            if let existing = cache.files[path], existing.mtime == attrs.mtime && existing.size == attrs.size {
                continue
            }

            let collectSpeed = attrs.mtime >= speedMtimeCutoffSec
            let parsed: (buckets: [CachedUsageBucket], speedSamples: [SpeedSample]) = autoreleasepool {
                guard let compressed = try? Data(contentsOf: url),
                      let decompressed = DynamicZstdLoader.shared.decompress(compressed) else {
                    return ([], [])
                }
                let projectDirName = url
                    .deletingLastPathComponent() // session-<uuid>
                    .deletingLastPathComponent() // --Users-<user>-...--
                    .lastPathComponent
                let cwd = Self.decodeDSHDirectoryName(projectDirName)
                return parseDSHJSONL(
                    data: decompressed,
                    cwd: cwd,
                    todayKey: todayKey,
                    collectSpeed: collectSpeed,
                    speedCutoffSec: speedCutoffSec
                )
            }
            cache.files[path] = CachedFileState(
                mtime: attrs.mtime,
                size: attrs.size,
                byteOffset: attrs.size,
                buckets: parsed.buckets,
                codexState: nil,
                seenAntigravitySteps: nil,
                speedSamples: parsed.speedSamples.isEmpty ? nil : parsed.speedSamples
            )
        }
        return count
    }

    private func parseDSHJSONL(
        data: Data,
        cwd: String?,
        todayKey: String,
        collectSpeed: Bool,
        speedCutoffSec: Double
    ) -> (buckets: [CachedUsageBucket], speedSamples: [SpeedSample]) {
        var builder = BucketAccumulator(homePath: homeDirectoryURL.path)
        var seenMessageIds = Set<String>()
        var lastStepStartMs: Double? = nil
        var lastAssistantMs: Double? = nil
        var speedSamples: [SpeedSample] = []

        forEachJSONLine(in: data) { lineData in
            if collectSpeed && Self.utf8Contains(lineData, bytes: Self.needleDSHStepStart) {
                if Self.extractJSONString(in: lineData, afterKey: "type") == "step/start",
                   let startMs = Self.extractJSONInt64(in: lineData, afterKey: "time").map(Double.init) {
                    lastStepStartMs = startMs
                }
                return
            }

            // Fast pre-filter: skips 95%+ of lines without touching JSON.
            guard Self.utf8Contains(lineData, needle: "\"assistant/message\"")
                && Self.utf8Contains(lineData, needle: "\"usage\"") else { return }

            // Byte-slice extract ONLY the tiny `usage` sub-object + scalar metadata (avoids parsing MBs of `stream`/`replayState`).
            guard let usage = Self.extractJSONObject(in: lineData, afterKey: "usage") else { return }

            // In DSH v4, `inputTokens` is UNCACHED input (`totalTokens = input + output + cacheRead + cacheWrite`).
            let uncachedIn = max(Int64(0), Self.parseInt64(usage["inputTokens"]) ?? 0)
            let outputTok = max(Int64(0), Self.parseInt64(usage["outputTokens"]) ?? 0)
            let cacheRead = max(Int64(0), Self.parseInt64(usage["cacheReadTokens"]) ?? 0)
            let cacheWrite = max(Int64(0), Self.parseInt64(usage["cacheWriteTokens"]) ?? 0)
            let totalTok = max(Self.parseInt64(usage["totalTokens"]) ?? 0, uncachedIn + outputTok + cacheRead + cacheWrite)
            guard totalTok > 0 else { return }

            // Verify record type is `assistant/message` near start of line.
            guard Self.extractJSONString(in: lineData, afterKey: "type") == "assistant/message" else { return }

            // Dedup by `data.message.id` if present.
            var msgId: String? = nil
            if let msgRange = Self.findBytes(in: lineData, needle: Self.needleMessageKey),
               let mid = Self.extractJSONString(in: lineData, afterKey: "id", searchStart: msgRange.upperBound),
               !mid.isEmpty {
                guard seenMessageIds.insert(mid).inserted else { return }
                msgId = mid
            }

            guard let ms = Self.extractJSONInt64(in: lineData, afterKey: "time").map(Double.init),
                  let dateKey = Self.epochMsToShanghaiDateKey(ms),
                  dateKey <= todayKey else { return }

            let srcStart = Self.findBytes(in: lineData, needle: Self.needleSourceKey)?.upperBound ?? lineData.startIndex
            let rawModel = Self.extractJSONString(in: lineData, afterKey: "model", searchStart: srcStart) ?? "deepseek-flash"
            let modelId = Self.sanitizeModelId(rawModel)
            let rawProvider = Self.extractJSONString(in: lineData, afterKey: "provider", searchStart: srcStart)
            let providerId = (rawProvider?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "deepseek-official"

            if collectSpeed, outputTok > 0, let endSec = Self.epochToSeconds(ms) {
                var chosenDt: Double? = nil
                if let sMs = lastStepStartMs, let sSec = Self.epochToSeconds(sMs) {
                    let d = endSec - sSec
                    if d >= Self.speedMinDurationSec && d <= Self.speedMaxDurationSec {
                        chosenDt = d
                    }
                }
                if chosenDt == nil,
                   let streamRange = Self.findBytes(in: lineData, needle: Self.needleStreamKey),
                   let firstChunkMs = Self.extractJSONInt64(in: lineData, afterKey: "time", searchStart: streamRange.upperBound).map(Double.init),
                   let firstChunkSec = Self.epochToSeconds(firstChunkMs) {
                    let d = endSec - firstChunkSec
                    if d >= Self.speedMinDurationSec && d <= Self.speedMaxDurationSec {
                        chosenDt = d
                    }
                }
                if chosenDt == nil, let prevMs = lastAssistantMs, let prevSec = Self.epochToSeconds(prevMs) {
                    let d = endSec - prevSec
                    if d >= Self.speedMinDurationSec && d <= Self.speedMaxDurationSec {
                        chosenDt = d
                    }
                }
                if let dt = chosenDt,
                   let sample = Self.makeValidSpeedSample(
                    dedupKey: "dsh:\(msgId ?? String(Int64(ms)))",
                    client: .dsh,
                    modelId: modelId,
                    outputTokens: outputTok,
                    totalTokens: totalTok,
                    durationSec: dt,
                    endedAtSec: endSec,
                    speedCutoffSec: speedCutoffSec
                   ) {
                    speedSamples.append(sample)
                }
                lastStepStartMs = nil
                lastAssistantMs = ms
            }

            let cost = TokenPricingCatalog.pricing(for: modelId, client: .dsh).estimateCostUSD(
                uncachedInput: uncachedIn,
                output: outputTok,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite
            )
            builder.add(
                date: dateKey,
                client: .dsh,
                modelId: modelId,
                providerId: providerId,
                cwd: cwd,
                totals: TokenComponentTotals(
                    totalTokens: totalTok,
                    uncachedInputTokens: uncachedIn,
                    outputTokens: outputTok,
                    cacheReadTokens: cacheRead,
                    cacheWriteTokens: cacheWrite,
                    reasoningTokens: 0,
                    estimatedCostUSD: cost,
                    messageCount: 1
                )
            )
        }
        let trimmedSpeed = Array(speedSamples.sorted { $0.endedAtSec < $1.endedAtSec }.suffix(Self.speedMaxSamplesPerFile))
        return (builder.finalize(), trimmedSpeed)
    }

    private func parseDSHSpeedSamplesOnly(data: Data, speedCutoffSec: Double) -> [SpeedSample] {
        let todayKey = "2100-12-31"
        return parseDSHJSONL(
            data: data,
            cwd: nil,
            todayKey: todayKey,
            collectSpeed: true,
            speedCutoffSec: speedCutoffSec
        ).speedSamples
    }

    private static func decodeDSHDirectoryName(_ raw: String) -> String? {
        var trimmed = raw
        if trimmed.hasPrefix("--") { trimmed = String(trimmed.dropFirst(2)) }
        if trimmed.hasSuffix("--") { trimmed = String(trimmed.dropLast(2)) }
        guard !trimmed.isEmpty else { return nil }
        // Heuristic conversion of leading `Users-<user>-...` back into readable path display.
        if trimmed.hasPrefix("Users-") {
            let comps = trimmed.split(separator: "-", maxSplits: 2).map(String.init)
            if comps.count == 3 {
                return "/Users/\(comps[1])/\(comps[2])"
            }
        }
        return "/\(trimmed)"
    }

    // MARK: - 7. WorkBuddy Scanner (`~/.workbuddy/projects/**/*.jsonl`)

    private func scanWorkBuddyLogs(
        cache: inout TokenScanCache,
        activePaths: inout Set<String>,
        todayKey: String,
        speedCutoffSec: Double,
        speedMtimeCutoffSec: Double
    ) -> Int {
        let root = homeDirectoryURL.appendingPathComponent(".workbuddy/projects", isDirectory: true)
        let files = enumerateFiles(under: root, suffix: ".jsonl")
        guard !files.isEmpty else { return 0 }

        var count = 0
        for url in files {
            let path = url.path
            activePaths.insert(path)
            count += 1
            guard let attrs = fileMtimeAndSize(at: path) else { continue }
            if let existing = cache.files[path], existing.mtime == attrs.mtime && existing.size == attrs.size {
                continue
            }

            guard let data = try? Data(contentsOf: url) else { continue }
            let collectSpeed = attrs.mtime >= speedMtimeCutoffSec
            let parsed = parseWorkBuddyJSONL(
                data: data,
                todayKey: todayKey,
                collectSpeed: collectSpeed,
                speedCutoffSec: speedCutoffSec
            )
            cache.files[path] = CachedFileState(
                mtime: attrs.mtime,
                size: attrs.size,
                byteOffset: attrs.size,
                buckets: parsed.buckets,
                codexState: nil,
                seenAntigravitySteps: nil,
                speedSamples: parsed.speedSamples.isEmpty ? nil : parsed.speedSamples
            )
        }
        return count
    }

    private func parseWorkBuddyJSONL(
        data: Data,
        todayKey: String,
        collectSpeed: Bool,
        speedCutoffSec: Double
    ) -> (buckets: [CachedUsageBucket], speedSamples: [SpeedSample]) {
        var builder = BucketAccumulator(homePath: homeDirectoryURL.path)
        var seenReqIds = Set<String>()
        var lastAnchorSec: Double? = nil
        var speedSamples: [SpeedSample] = []

        forEachJSONLine(in: data) { lineData in
            let hasUsage = Self.utf8Contains(lineData, bytes: Self.needleUsage)
            if !hasUsage {
                guard collectSpeed else { return }
                if let rec = (try? JSONSerialization.jsonObject(with: lineData, options: [])) as? [String: Any] {
                    let t = rec["type"] as? String
                    if t == "function_call_result" || t == "user" {
                        if let ms = Self.parseDouble(rec["timestamp"]), let s = Self.epochToSeconds(ms) {
                            lastAnchorSec = s
                        } else if let tsStr = rec["timestamp"] as? String, let s = Self.parseISOToEpochSeconds(tsStr) {
                            lastAnchorSec = s
                        }
                    }
                }
                return
            }

            guard let rec = (try? JSONSerialization.jsonObject(with: lineData, options: [])) as? [String: Any] else { return }

            let msg = rec["message"] as? [String: Any]
            guard let usage = (msg?["usage"] as? [String: Any]) ?? (rec["usage"] as? [String: Any]) else { return }

            let pd = rec["providerData"] as? [String: Any]
            let reqId = (pd?["messageId"] as? String) ?? (rec["id"] as? String)
            if let reqId, !reqId.isEmpty {
                guard seenReqIds.insert(reqId).inserted else { return }
            }

            // In WorkBuddy, `input_tokens` INCLUDES `cache_read_input_tokens` (`total = input + output`).
            let inTok = max(Int64(0), Self.parseInt64(usage["input_tokens"]) ?? 0)
            let outTok = max(Int64(0), Self.parseInt64(usage["output_tokens"]) ?? 0)
            let crTok = min(max(Int64(0), Self.parseInt64(usage["cache_read_input_tokens"]) ?? 0), inTok)
            let cwTok = min(max(Int64(0), Self.parseInt64(usage["cache_creation_input_tokens"]) ?? 0), max(0, inTok - crTok))
            let uncachedIn = max(Int64(0), inTok - crTok - cwTok)
            let totalTok = max(Self.parseInt64(usage["total_tokens"]) ?? 0, uncachedIn + crTok + cwTok + outTok)
            guard totalTok > 0 else { return }

            let dateKey: String?
            let tsSec: Double?
            if let ms = Self.parseDouble(rec["timestamp"]) {
                dateKey = Self.epochMsToShanghaiDateKey(ms)
                tsSec = Self.epochToSeconds(ms)
            } else if let tsStr = rec["timestamp"] as? String {
                dateKey = Self.parseISOToShanghaiDateKey(tsStr)
                tsSec = Self.parseISOToEpochSeconds(tsStr)
            } else {
                dateKey = nil
                tsSec = nil
            }
            guard let dateKey, dateKey <= todayKey else { return }

            let rawModel = (pd?["model"] as? String)
                ?? (pd?["requestModelId"] as? String)
                ?? (msg?["model"] as? String)
                ?? "workbuddy"
            let modelId = Self.sanitizeModelId(rawModel)
            let cwd = rec["cwd"] as? String

            if collectSpeed, let tsSec {
                if let anchor = lastAnchorSec, outTok > 0 {
                    let dt = tsSec - anchor
                    if let sample = Self.makeValidSpeedSample(
                        dedupKey: "workbuddy:\(reqId ?? String(Int64(tsSec * 1000.0)))",
                        client: .workbuddy,
                        modelId: modelId,
                        outputTokens: outTok,
                        totalTokens: totalTok,
                        durationSec: dt,
                        endedAtSec: tsSec,
                        speedCutoffSec: speedCutoffSec
                    ) {
                        speedSamples.append(sample)
                    }
                }
                lastAnchorSec = tsSec
            }

            let cost = TokenPricingCatalog.pricing(for: modelId, client: .workbuddy).estimateCostUSD(
                uncachedInput: uncachedIn,
                output: outTok,
                cacheRead: crTok,
                cacheWrite: cwTok
            )
            builder.add(
                date: dateKey,
                client: .workbuddy,
                modelId: modelId,
                providerId: TokenPricingCatalog.defaultProviderId(for: modelId, client: .workbuddy),
                cwd: cwd,
                totals: TokenComponentTotals(
                    totalTokens: totalTok,
                    uncachedInputTokens: uncachedIn,
                    outputTokens: outTok,
                    cacheReadTokens: crTok,
                    cacheWriteTokens: cwTok,
                    reasoningTokens: 0,
                    estimatedCostUSD: cost,
                    messageCount: 1
                )
            )
        }
        let trimmedSpeed = Array(speedSamples.sorted { $0.endedAtSec < $1.endedAtSec }.suffix(Self.speedMaxSamplesPerFile))
        return (builder.finalize(), trimmedSpeed)
    }

    private func parseWorkBuddySpeedSamplesOnly(data: Data, speedCutoffSec: Double) -> [SpeedSample] {
        parseWorkBuddyJSONL(data: data, todayKey: "2100-12-31", collectSpeed: true, speedCutoffSec: speedCutoffSec).speedSamples
    }

    // MARK: - 8 & 9. OpenCode & ZCode Read-Only SQLite Scanner

    private static func extractSQLiteSpeedSample(
        msgId: String,
        timeCreated: Int64,
        dataDict d: [String: Any],
        tokensDict tok: [String: Any],
        client: TokenClientID,
        camelCaseModelKeys: Bool,
        reasoningSeparateFromOutput: Bool,
        speedCutoffSec: Double
    ) -> SpeedSample? {
        let timeObj = d["time"] as? [String: Any]
        guard let completedMs = parseDouble(timeObj?["completed"]),
              let createdMs = parseDouble(timeObj?["created"]) ?? (timeCreated > 0 ? Double(timeCreated) : nil),
              completedMs > createdMs,
              let endSec = epochToSeconds(completedMs),
              let startSec = epochToSeconds(createdMs) else {
            return nil
        }

        let rawIn = max(Int64(0), parseInt64(tok["input"]) ?? 0)
        let rawOut = max(Int64(0), parseInt64(tok["output"]) ?? 0)
        let rawReas = max(Int64(0), parseInt64(tok["reasoning"]) ?? 0)
        let cacheObj = tok["cache"] as? [String: Any]
        let cacheRead = max(Int64(0), parseInt64(cacheObj?["read"]) ?? 0)
        let cacheWrite = max(Int64(0), parseInt64(cacheObj?["write"]) ?? 0)

        let effectiveOut: Int64 = reasoningSeparateFromOutput
            ? (rawOut + rawReas)
            : (rawOut > 0 ? rawOut : rawReas)
        guard effectiveOut > 0 else { return nil }
        let totalTok = max(parseInt64(tok["total"]) ?? 0, rawIn + cacheRead + cacheWrite + effectiveOut)

        let rawModel = (camelCaseModelKeys
            ? ((d["modelId"] as? String) ?? (d["modelID"] as? String))
            : ((d["modelID"] as? String) ?? (d["modelId"] as? String)))
            ?? "unknown"

        return makeValidSpeedSample(
            dedupKey: "\(client.rawValue):\(msgId)",
            client: client,
            modelId: sanitizeModelId(rawModel),
            outputTokens: effectiveOut,
            totalTokens: totalTok,
            durationSec: endSec - startSec,
            endedAtSec: endSec,
            speedCutoffSec: speedCutoffSec
        )
    }

    private func scanSQLiteMessageDB(
        cacheKey: String,
        dbURL: URL,
        client: TokenClientID,
        camelCaseModelKeys: Bool,
        inputIncludesCacheRead: Bool,
        reasoningSeparateFromOutput: Bool,
        cache: inout TokenScanCache,
        todayKey: String,
        speedCutoffSec: Double
    ) -> Int {
        let path = dbURL.path
        guard let dbAttrs = fileMtimeAndSize(at: path) else {
            cache.sqliteCaches.removeValue(forKey: cacheKey)
            return 0
        }
        let walAttrs = fileMtimeAndSize(at: path + "-wal")
        let walMtime = walAttrs?.mtime ?? 0
        let walSize = walAttrs?.size ?? 0

        let existing = cache.sqliteCaches[cacheKey]
        if let existing,
           existing.dbMtime == dbAttrs.mtime && existing.dbSize == dbAttrs.size
            && existing.walMtime == walMtime && existing.walSize == walSize {
            return 1
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return 1
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        // Load session -> directory map for project attribution.
        var sessionDirs: [String: String] = [:]
        do {
            var sStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT id, directory FROM session", -1, &sStmt, nil) == SQLITE_OK, let sStmt {
                defer { sqlite3_finalize(sStmt) }
                while sqlite3_step(sStmt) == SQLITE_ROW {
                    if let cid = sqlite3_column_text(sStmt, 0), let cdir = sqlite3_column_text(sStmt, 1) {
                        sessionDirs[String(cString: cid)] = String(cString: cdir)
                    }
                }
            }
        }

        // Incremental watermark query (`time_updated > watermark`) when DB grew monotonically; otherwise full read.
        let canIncremental = existing != nil && dbAttrs.size >= (existing?.dbSize ?? 0) && (existing?.maxTimeUpdated ?? 0) > 0
        let watermark: Int64 = canIncremental ? (existing?.maxTimeUpdated ?? 0) : -1

        var builder = BucketAccumulator(homePath: homeDirectoryURL.path)
        if canIncremental, let prevBuckets = existing?.buckets {
            builder.seed(prevBuckets)
        }
        var speedSamples: [SpeedSample] = canIncremental
            ? (existing?.speedSamples ?? []).filter { $0.endedAtSec >= speedCutoffSec }
            : []
        var maxUpdated: Int64 = watermark

        var stmt: OpaquePointer?
        let sql = "SELECT id, session_id, time_created, time_updated, data FROM message WHERE time_updated > ? ORDER BY time_updated ASC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return 1
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, watermark)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let msgId = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let sid = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let timeCreated = sqlite3_column_int64(stmt, 2)
            let timeUpdated = sqlite3_column_int64(stmt, 3)
            if timeUpdated > maxUpdated { maxUpdated = timeUpdated }

            guard let cData = sqlite3_column_text(stmt, 4) else { continue }
            let jsonData = Data(String(cString: cData).utf8)
            guard let d = (try? JSONSerialization.jsonObject(with: jsonData, options: [])) as? [String: Any],
                  (d["role"] as? String) == "assistant",
                  let tok = d["tokens"] as? [String: Any] else { continue }

            let rawIn = max(Int64(0), Self.parseInt64(tok["input"]) ?? 0)
            let rawOut = max(Int64(0), Self.parseInt64(tok["output"]) ?? 0)
            let rawReas = max(Int64(0), Self.parseInt64(tok["reasoning"]) ?? 0)
            let cacheObj = tok["cache"] as? [String: Any]
            let cacheRead = max(Int64(0), Self.parseInt64(cacheObj?["read"]) ?? 0)
            let cacheWrite = max(Int64(0), Self.parseInt64(cacheObj?["write"]) ?? 0)

            let uncachedIn: Int64
            let effectiveOut: Int64
            let clampedCR: Int64
            let clampedCW: Int64
            if inputIncludesCacheRead {
                // ZCode: `input` INCLUDES `cache.read` & `cache.write`.
                clampedCR = min(cacheRead, rawIn)
                clampedCW = min(cacheWrite, max(0, rawIn - clampedCR))
                uncachedIn = max(Int64(0), rawIn - clampedCR - clampedCW)
            } else {
                // OpenCode: `input` is UNCACHED.
                clampedCR = cacheRead
                clampedCW = cacheWrite
                uncachedIn = rawIn
            }
            if reasoningSeparateFromOutput {
                // OpenCode: `reasoning` is separate from `output`; fold into `outputTokens` so components sum cleanly to `total`.
                effectiveOut = rawOut + rawReas
            } else {
                effectiveOut = rawOut
            }
            let totalTok = max(Self.parseInt64(tok["total"]) ?? 0, uncachedIn + clampedCR + clampedCW + effectiveOut)
            guard totalTok > 0 else { continue }

            let timeObj = d["time"] as? [String: Any]
            let tsMs = Self.parseDouble(timeObj?["completed"])
                ?? Self.parseDouble(timeObj?["created"])
                ?? Double(timeCreated)
            guard let dateKey = Self.epochMsToShanghaiDateKey(tsMs), dateKey <= todayKey else { continue }

            if let sample = Self.extractSQLiteSpeedSample(
                msgId: msgId.isEmpty ? "\(sid)-\(timeCreated)-\(timeUpdated)" : msgId,
                timeCreated: timeCreated,
                dataDict: d,
                tokensDict: tok,
                client: client,
                camelCaseModelKeys: camelCaseModelKeys,
                reasoningSeparateFromOutput: reasoningSeparateFromOutput,
                speedCutoffSec: speedCutoffSec
            ) {
                speedSamples.append(sample)
            }

            let rawModel = (camelCaseModelKeys
                ? ((d["modelId"] as? String) ?? (d["modelID"] as? String))
                : ((d["modelID"] as? String) ?? (d["modelId"] as? String)))
                ?? "unknown"
            let modelId = Self.sanitizeModelId(rawModel)
            let rawProvider = (camelCaseModelKeys
                ? ((d["providerId"] as? String) ?? (d["providerID"] as? String))
                : ((d["providerID"] as? String) ?? (d["providerId"] as? String)))
            let providerId = (rawProvider?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? TokenPricingCatalog.defaultProviderId(for: modelId, client: client)

            let reportedCost = Self.parseDouble(d["cost"])
            let costUSD: Double
            if let reportedCost, reportedCost > 0, reportedCost.isFinite {
                costUSD = reportedCost
            } else {
                costUSD = TokenPricingCatalog.pricing(for: modelId, client: client).estimateCostUSD(
                    uncachedInput: uncachedIn,
                    output: effectiveOut,
                    cacheRead: clampedCR,
                    cacheWrite: clampedCW
                )
            }

            builder.add(
                date: dateKey,
                client: client,
                modelId: modelId,
                providerId: providerId,
                cwd: sessionDirs[sid],
                totals: TokenComponentTotals(
                    totalTokens: totalTok,
                    uncachedInputTokens: uncachedIn,
                    outputTokens: effectiveOut,
                    cacheReadTokens: clampedCR,
                    cacheWriteTokens: clampedCW,
                    reasoningTokens: min(rawReas, effectiveOut),
                    estimatedCostUSD: costUSD,
                    messageCount: 1
                )
            )
        }

        let trimmedSpeed = Array(speedSamples.filter { $0.endedAtSec >= speedCutoffSec }.sorted { $0.endedAtSec < $1.endedAtSec }.suffix(Self.speedMaxSamplesPerModel))
        cache.sqliteCaches[cacheKey] = CachedSQLiteState(
            dbMtime: dbAttrs.mtime,
            dbSize: dbAttrs.size,
            walMtime: walMtime,
            walSize: walSize,
            maxTimeUpdated: maxUpdated,
            buckets: builder.finalize(),
            speedSamples: trimmedSpeed.isEmpty ? nil : trimmedSpeed
        )
        return 1
    }

    // MARK: - Seed + Live Day Merge (Zero Double Counting)

    private struct MergedObsKey: Hashable {
        let client: TokenClientID
        let modelId: String
    }

    private struct MergedObservation {
        var client: TokenClientID
        var modelId: String
        var providerId: String
        var totals: TokenComponentTotals
    }

    private struct MergedDay {
        var date: String
        var activeTimeMs: Int64
        var observations: [MergedObsKey: MergedObservation]
    }

    private func mergeSeedAndLive(
        seedStore: PersistedSeedStore,
        liveBuckets: [CachedUsageBucket],
        todayKey: String
    ) -> ([String: MergedDay], [TokenProjectDayRecord]) {
        // 1. Aggregate live buckets per (date, client, modelId) AND per (date, client, projectId).
        var liveByDay: [String: [MergedObsKey: MergedObservation]] = [:]
        var projectMap: [String: TokenProjectDayRecord] = [:]

        for b in liveBuckets {
            guard Self.isValidDateKey(b.date), b.date <= todayKey, b.totals.totalTokens > 0 else { continue }
            let client = TokenClientID.canonical(b.client)
            let key = MergedObsKey(client: client, modelId: b.modelId)

            var dayMap = liveByDay[b.date] ?? [:]
            if var existing = dayMap[key] {
                existing.totals.add(b.totals)
                if existing.providerId.isEmpty { existing.providerId = b.providerId }
                dayMap[key] = existing
            } else {
                dayMap[key] = MergedObservation(
                    client: client,
                    modelId: b.modelId,
                    providerId: b.providerId,
                    totals: b.totals
                )
            }
            liveByDay[b.date] = dayMap

            if let projId = b.projectId, let projName = b.projectName, let pathDisplay = b.pathDisplay {
                let pKey = "\(b.date)|\(client.rawValue)|\(projId)"
                if var pRec = projectMap[pKey] {
                    pRec.totals.add(b.totals)
                    projectMap[pKey] = pRec
                } else {
                    projectMap[pKey] = TokenProjectDayRecord(
                        date: b.date,
                        client: client,
                        projectId: projId,
                        projectName: projName,
                        pathDisplay: pathDisplay,
                        totals: b.totals
                    )
                }
            }
        }

        // 2. Start from seed days (preserving Cursor + pre-retention history + activeTimeMs).
        var merged: [String: MergedDay] = [:]
        for (dateKey, seedDay) in seedStore.days where Self.isValidDateKey(dateKey) && dateKey <= todayKey {
            var obsDict: [MergedObsKey: MergedObservation] = [:]
            for sObs in seedDay.observations {
                let client = TokenClientID.canonical(sObs.client)
                let key = MergedObsKey(client: client, modelId: sObs.modelId)
                if var prev = obsDict[key] {
                    prev.totals.add(sObs.totals)
                    obsDict[key] = prev
                } else {
                    obsDict[key] = MergedObservation(
                        client: client,
                        modelId: sObs.modelId,
                        providerId: sObs.providerId,
                        totals: sObs.totals
                    )
                }
            }
            merged[dateKey] = MergedDay(date: dateKey, activeTimeMs: seedDay.activeTimeMs, observations: obsDict)
        }

        // 3. Merge live per (date, client, modelId) using non-double-counting max/richer rule:
        //    - If seed has no entry -> insert live.
        //    - If both exist -> prefer live when live.totalTokens >= seed.totalTokens; otherwise keep seed
        //      (protects historical days where older local logs were rotated/pruned or model name normalized).
        for (dateKey, liveObsMap) in liveByDay {
            var day = merged[dateKey] ?? MergedDay(date: dateKey, activeTimeMs: 0, observations: [:])

            // Also check client-level overlap when model names differ slightly between Token Monitor seed and local logs
            // (e.g. Antigravity pre-Nov 18 had `unknown` in transcript.jsonl vs concrete model names in seed,
            // or Antigravity `gemini-4-neon-xhigh` vs `gemini-4-neon`).
            var seedClientTotals: [TokenClientID: Int64] = [:]
            for obs in day.observations.values {
                seedClientTotals[obs.client, default: 0] += obs.totals.totalTokens
            }
            var liveClientTotals: [TokenClientID: Int64] = [:]
            for obs in liveObsMap.values {
                liveClientTotals[obs.client, default: 0] += obs.totals.totalTokens
            }

            let liveClients = Set(liveObsMap.values.map(\.client))
            for client in liveClients {
                let seedClientSum = seedClientTotals[client] ?? 0
                let liveClientSum = liveClientTotals[client] ?? 0
                if seedClientSum == 0 {
                    // Purely live client on this date -> insert all live models for this client.
                    for (k, v) in liveObsMap where k.client == client {
                        day.observations[k] = v
                    }
                } else if liveClientSum >= seedClientSum {
                    // Live local logs have grown beyond the historical seed snapshot (e.g. today after 10:39) ->
                    // replace this client's day rows cleanly with live rows (zero double-counting even if model naming differs!).
                    for k in Array(day.observations.keys) where k.client == client {
                        day.observations.removeValue(forKey: k)
                    }
                    for (k, v) in liveObsMap where k.client == client {
                        day.observations[k] = v
                    }
                } else {
                    // Seed has equal-or-higher total for this client on this historical day -> keep seed untouched.
                }
            }

            merged[dateKey] = day
        }

        return (merged, Array(projectMap.values))
    }

    // MARK: - AccountPool-Compatible `daily-history-archive.json` Writer

    private func writeAccountPoolArchiveQuietly(mergedDays: [String: MergedDay]) {
        var daysDict: [String: Any] = [:]
        for dateKey in mergedDays.keys.sorted() {
            guard let day = mergedDays[dateKey] else { continue }
            var obsDict: [String: Any] = [:]
            for (_, obs) in day.observations.sorted(by: { lhs, rhs in
                if lhs.key.client.rawValue != rhs.key.client.rawValue {
                    return lhs.key.client.rawValue < rhs.key.client.rawValue
                }
                return lhs.key.modelId < rhs.key.modelId
            }) {
                let safeModel = Self.sanitizeModelId(obs.modelId)
                let keyJSON: String
                if let keyData = try? JSONSerialization.data(withJSONObject: [obs.client.rawValue, safeModel], options: []),
                   let keyStr = String(data: keyData, encoding: .utf8) {
                    keyJSON = keyStr
                } else {
                    keyJSON = "[\"\(obs.client.rawValue)\",\"\(safeModel)\"]"
                }

                // Enforce strict iOS/AccountPool invariant: cacheRead + cacheWrite + output <= tokens.
                let total = max(Int64(0), obs.totals.totalTokens)
                let out = min(max(Int64(0), obs.totals.outputTokens), total)
                let cr = min(max(Int64(0), obs.totals.cacheReadTokens), max(0, total - out))
                let cw = min(max(Int64(0), obs.totals.cacheWriteTokens), max(0, total - out - cr))
                let reas = min(max(Int64(0), obs.totals.reasoningTokens), out)
                let safeCost = (obs.totals.estimatedCostUSD.isFinite && obs.totals.estimatedCostUSD >= 0)
                    ? ((obs.totals.estimatedCostUSD * 1_000_000.0).rounded() / 1_000_000.0)
                    : 0.0

                var row: [String: Any] = [
                    "client": obs.client.rawValue,
                    "modelId": safeModel,
                    "providerId": obs.providerId.isEmpty ? TokenPricingCatalog.defaultProviderId(for: safeModel, client: obs.client) : obs.providerId,
                    "tokens": total,
                    "cost": safeCost,
                    "messages": max(0, obs.totals.messageCount),
                    "tokenComponentsAvailable": true,
                    "cacheReadTokens": cr,
                    "cacheWriteTokens": cw,
                    "outputTokens": out,
                ]
                if reas > 0 {
                    row["reasoningTokens"] = reas
                }
                obsDict[keyJSON] = row
            }

            if !obsDict.isEmpty {
                daysDict[dateKey] = [
                    "date": dateKey,
                    "activeTimeMs": day.activeTimeMs,
                    "observations": obsDict,
                ] as [String: Any]
            }
        }

        let archiveRoot: [String: Any] = [
            "version": 1,
            "pricingRevision": TokenPricingCatalog.pricingRevision,
            "days": daysDict,
            "liveDays": [:] as [String: Any],
        ]

        do {
            try KeychainStore.ensureDirectory(at: appSupportURL, mode: 0o700)
            let data = try JSONSerialization.data(withJSONObject: archiveRoot, options: [.sortedKeys])
            try KeychainStore.writeAtomicFile(data: data, to: archiveURL, mode: 0o600)
        } catch {
            // Non-fatal: UI snapshot still succeeds.
        }
    }

    // MARK: - Build UI Snapshot (`today`, `days7`, `days30`, `allTime` + 112-day Heatmap)

    private func buildSnapshot(
        mergedDays: [String: MergedDay],
        projectRecords: [TokenProjectDayRecord],
        seedDaysCount: Int,
        liveScannedFilesCount: Int,
        now: Date,
        todayKey: String,
        speedSnapshot: LiveTokenSpeedSnapshot? = nil
    ) -> TokenUsageSnapshot {
        let sortedDateKeys = mergedDays.keys.sorted()
        let earliestKey = sortedDateKeys.first ?? todayKey

        // Build full per-day points and per-day model records for all dates present.
        var dayPointByDate: [String: TokenDailyPoint] = [:]
        var allPositiveTotals: [Int64] = []
        var modelRecords: [TokenModelDayRecord] = []
        modelRecords.reserveCapacity(sortedDateKeys.count * 4)

        for dateKey in sortedDateKeys {
            guard let day = mergedDays[dateKey] else { continue }
            var dayTotals = TokenComponentTotals.zero
            var clientMap: [TokenClientID: TokenComponentTotals] = [:]

            let sortedObs = day.observations.values.sorted { lhs, rhs in
                if lhs.totals.totalTokens != rhs.totals.totalTokens {
                    return lhs.totals.totalTokens > rhs.totals.totalTokens
                }
                if lhs.client.rawValue != rhs.client.rawValue {
                    return lhs.client.rawValue < rhs.client.rawValue
                }
                return lhs.modelId < rhs.modelId
            }

            for obs in sortedObs {
                dayTotals.add(obs.totals)
                var cur = clientMap[obs.client] ?? .zero
                cur.add(obs.totals)
                clientMap[obs.client] = cur

                if obs.totals.totalTokens > 0 {
                    let resolvedProvider = obs.providerId.isEmpty
                        ? TokenPricingCatalog.defaultProviderId(for: obs.modelId, client: obs.client)
                        : obs.providerId
                    modelRecords.append(
                        TokenModelDayRecord(
                            date: dateKey,
                            client: obs.client,
                            modelId: obs.modelId,
                            providerId: resolvedProvider,
                            totals: obs.totals
                        )
                    )
                }
            }
            if dayTotals.totalTokens > 0 {
                allPositiveTotals.append(dayTotals.totalTokens)
            }
            let denom = Double(max(Int64(1), dayTotals.totalTokens))
            let byClient = clientMap.map { c, t in
                TokenClientBreakdown(
                    client: c,
                    totals: t,
                    shareOfTokens: Double(t.totalTokens) / denom,
                    activeDays: t.totalTokens > 0 ? 1 : 0
                )
            }
            .sorted { $0.totals.totalTokens > $1.totals.totalTokens }

            dayPointByDate[dateKey] = TokenDailyPoint(
                date: dateKey,
                totals: dayTotals,
                activeTimeMs: day.activeTimeMs,
                byClient: byClient,
                heatmapLevel: 0
            )
        }

        let globalThresholds = TokenUsageSnapshot.heatmapThresholds(from: allPositiveTotals)
        for key in dayPointByDate.keys {
            if var pt = dayPointByDate[key] {
                pt.heatmapLevel = TokenUsageSnapshot.heatmapLevel(tokens: pt.totals.totalTokens, thresholds: globalThresholds)
                dayPointByDate[key] = pt
            }
        }

        let allDays = sortedDateKeys.compactMap { dayPointByDate[$0] }

        // Build contiguous 112-day (16-week) calendar grid ending today.
        let last112Keys = Self.shanghaiDateSequence(endingOn: now, count: 112)
        let heatmapPositive = last112Keys.compactMap { dayPointByDate[$0]?.totals.totalTokens }.filter { $0 > 0 }
        let heatmapThresholds = TokenUsageSnapshot.heatmapThresholds(from: heatmapPositive)
        let heatmap112: [TokenDailyPoint] = last112Keys.map { dk in
            if var pt = dayPointByDate[dk] {
                pt.heatmapLevel = TokenUsageSnapshot.heatmapLevel(tokens: pt.totals.totalTokens, thresholds: heatmapThresholds)
                return pt
            }
            return TokenDailyPoint(date: dk, totals: .zero)
        }

        // Precompute summaries for all 4 UI ranges.
        var ranges: [TokenUsageRange: TokenRangeSummary] = [:]
        for range in TokenUsageRange.allCases {
            ranges[range] = buildRangeSummary(
                range: range,
                now: now,
                todayKey: todayKey,
                earliestKey: earliestKey,
                mergedDays: mergedDays,
                dayPointByDate: dayPointByDate,
                projectRecords: projectRecords
            )
        }

        return TokenUsageSnapshot(
            generatedAt: now,
            lastScannedAt: now,
            seedDaysCount: seedDaysCount,
            totalDaysCount: sortedDateKeys.count,
            liveScannedFilesCount: liveScannedFilesCount,
            archiveFileURLPath: archiveURL.path,
            heatmap112Days: heatmap112,
            allDays: allDays,
            ranges: ranges,
            projectRecords: projectRecords,
            modelRecords: modelRecords,
            speedSnapshot: speedSnapshot
        )
    }

    private func buildRangeSummary(
        range: TokenUsageRange,
        now: Date,
        todayKey: String,
        earliestKey: String,
        mergedDays: [String: MergedDay],
        dayPointByDate: [String: TokenDailyPoint],
        projectRecords: [TokenProjectDayRecord]
    ) -> TokenRangeSummary {
        let seriesKeys: [String]
        let startDate: String
        let endDate = todayKey

        switch range {
        case .today:
            seriesKeys = [todayKey]
            startDate = todayKey
        case .days7:
            seriesKeys = Self.shanghaiDateSequence(endingOn: now, count: 7)
            startDate = seriesKeys.first ?? todayKey
        case .days30:
            seriesKeys = Self.shanghaiDateSequence(endingOn: now, count: 30)
            startDate = seriesKeys.first ?? todayKey
        case .allTime:
            let allKeys = mergedDays.keys.sorted()
            seriesKeys = allKeys.isEmpty ? [todayKey] : allKeys
            startDate = earliestKey
        }

        var grandTotals = TokenComponentTotals.zero
        var activeDays = 0
        var clientTotals: [TokenClientID: TokenComponentTotals] = [:]
        var clientActiveDays: [TokenClientID: Int] = [:]
        var modelTotals: [MergedObsKey: (providerId: String, totals: TokenComponentTotals)] = [:]

        let includedDateKeys: [String]
        if range == .allTime {
            includedDateKeys = mergedDays.keys.sorted()
        } else {
            includedDateKeys = seriesKeys.filter { mergedDays[$0] != nil }
        }

        for dateKey in includedDateKeys {
            guard let day = mergedDays[dateKey] else { continue }
            var dayHadTokens = false
            var clientsActiveToday = Set<TokenClientID>()

            for (obsKey, obs) in day.observations where obs.totals.totalTokens > 0 {
                dayHadTokens = true
                grandTotals.add(obs.totals)
                clientsActiveToday.insert(obs.client)

                var cTot = clientTotals[obs.client] ?? .zero
                cTot.add(obs.totals)
                clientTotals[obs.client] = cTot

                if var mEntry = modelTotals[obsKey] {
                    mEntry.totals.add(obs.totals)
                    modelTotals[obsKey] = mEntry
                } else {
                    modelTotals[obsKey] = (obs.providerId, obs.totals)
                }
            }

            if dayHadTokens {
                activeDays += 1
                for c in clientsActiveToday {
                    clientActiveDays[c, default: 0] += 1
                }
            }
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

        let byModel = modelTotals.map { key, entry in
            TokenModelBreakdown(
                client: key.client,
                modelId: key.modelId,
                providerId: entry.providerId,
                totals: entry.totals,
                shareOfTokens: Double(entry.totals.totalTokens) / denom
            )
        }
        .sorted { lhs, rhs in
            if lhs.totals.totalTokens != rhs.totals.totalTokens {
                return lhs.totals.totalTokens > rhs.totals.totalTokens
            }
            return lhs.modelId < rhs.modelId
        }

        let filteredProjects = projectRecords.filter { $0.date >= startDate && $0.date <= endDate }
        let byProject = TokenUsageSnapshot.aggregateProjects(from: filteredProjects)

        let dailySeries: [TokenDailyPoint] = seriesKeys.map { dk in
            dayPointByDate[dk] ?? TokenDailyPoint(date: dk, totals: .zero)
        }

        return TokenRangeSummary(
            range: range,
            startDate: startDate,
            endDate: endDate,
            totals: grandTotals,
            activeDays: activeDays,
            totalDaysInRange: seriesKeys.count,
            byClient: byClient,
            byModel: byModel,
            byProject: byProject,
            dailySeries: dailySeries
        )
    }

    // MARK: - Bucket Accumulator & Sanitization Utilities

    private struct BucketAccumulator {
        struct Key: Hashable {
            let date: String
            let client: String
            let modelId: String
            let projectId: String?
        }

        let homePath: String
        private var map: [Key: CachedUsageBucket] = [:]

        init(homePath: String) {
            self.homePath = homePath
        }

        mutating func seed(_ existing: [CachedUsageBucket]) {
            for b in existing {
                let k = Key(date: b.date, client: b.client, modelId: b.modelId, projectId: b.projectId)
                if var prev = map[k] {
                    prev.totals.add(b.totals)
                    map[k] = prev
                } else {
                    map[k] = b
                }
            }
        }

        mutating func add(
            date: String,
            client: TokenClientID,
            modelId: String,
            providerId: String,
            cwd: String?,
            totals: TokenComponentTotals
        ) {
            let proj = sanitizeProject(cwd: cwd, homePath: homePath)
            let k = Key(date: date, client: client.rawValue, modelId: modelId, projectId: proj?.id)
            if var prev = map[k] {
                prev.totals.add(totals)
                map[k] = prev
            } else {
                map[k] = CachedUsageBucket(
                    date: date,
                    client: client.rawValue,
                    modelId: modelId,
                    providerId: providerId,
                    projectId: proj?.id,
                    projectName: proj?.name,
                    pathDisplay: proj?.display,
                    totals: totals
                )
            }
        }

        func finalize() -> [CachedUsageBucket] {
            Array(map.values)
        }

        private func sanitizeProject(cwd: String?, homePath: String) -> (id: String, name: String, display: String)? {
            guard let raw = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            var clean = raw
            while clean.count > 1 && clean.hasSuffix("/") {
                clean.removeLast()
            }
            guard !clean.isEmpty else { return nil }
            let display: String
            if clean == homePath {
                display = "~"
            } else if clean.hasPrefix(homePath + "/") {
                display = "~/" + String(clean.dropFirst(homePath.count + 1))
            } else {
                display = clean
            }
            let lastComp = URL(fileURLWithPath: clean).lastPathComponent
            let name = (display == "~" || lastComp.isEmpty || lastComp == "/") ? "~" : lastComp
            return (display, name, display)
        }
    }

    /// Sanitizes model IDs to strictly match `AccountPool/collector/token_monitor.py:model_label()`.
    public static func sanitizeModelId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 96 else { return "unknown-model" }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".") || trimmed.contains("://") {
            return "unknown-model"
        }
        let lower = trimmed.lowercased()
        if lower.contains("@") || lower.contains("bearer ") || lower.contains("token=") || lower.contains("secret=") || lower.contains("sk-") {
            return "unknown-model"
        }
        var out = ""
        out.reserveCapacity(trimmed.count)
        for scalar in trimmed.unicodeScalars {
            let v = scalar.value
            let allowed = (v >= 0x30 && v <= 0x39) // 0-9
                || (v >= 0x41 && v <= 0x5A) // A-Z
                || (v >= 0x61 && v <= 0x7A) // a-z
                || v == 0x5F || v == 0x20 || v == 0x2E || v == 0x3A || v == 0x2F
                || v == 0x2B || v == 0x28 || v == 0x29 || v == 0xD7 || v == 0x25 || v == 0x2D
            if allowed {
                out.unicodeScalars.append(scalar)
            } else {
                out.append("-")
            }
        }
        let finalStr = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return finalStr.isEmpty ? "unknown-model" : String(finalStr.prefix(96))
    }

    // MARK: - Low-Level Fast File / Line / Date / Number Utilities

    private func enumerateFiles(under root: URL, suffix: String? = nil, exactFileName: String? = nil) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }
        var results: [URL] = []
        while let next = enumerator.nextObject() as? URL {
            let name = next.lastPathComponent
            if let exactFileName, name != exactFileName { continue }
            if let suffix, !name.hasSuffix(suffix) { continue }
            results.append(next)
        }
        return results
    }

    private func fileMtimeAndSize(at path: String) -> (mtime: Double, size: UInt64)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000.0
        return (mtime, UInt64(max(0, st.st_size)))
    }

    private func listSubdirectoryNames(at dirPath: String) -> [String] {
        guard let dir = opendir(dirPath) else { return [] }
        defer { closedir(dir) }
        var out: [String] = []
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) { String(cString: $0) }
            }
            if name == "." || name == ".." || name.hasPrefix(".") { continue }
            if ent.pointee.d_type == DT_DIR {
                out.append(name)
            } else if ent.pointee.d_type == DT_UNKNOWN {
                var st = stat()
                if stat(dirPath + "/" + name, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR {
                    out.append(name)
                }
            }
        }
        return out
    }

    private func listDirectoryEntries(at dirPath: String) -> [(name: String, isDirectory: Bool)] {
        guard let dir = opendir(dirPath) else { return [] }
        defer { closedir(dir) }
        var out: [(name: String, isDirectory: Bool)] = []
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) { String(cString: $0) }
            }
            if name == "." || name == ".." || name.hasPrefix(".") { continue }
            if ent.pointee.d_type == DT_DIR {
                out.append((name, true))
            } else if ent.pointee.d_type == DT_REG {
                out.append((name, false))
            } else if ent.pointee.d_type == DT_UNKNOWN {
                var st = stat()
                if stat(dirPath + "/" + name, &st) == 0 {
                    let kind = st.st_mode & S_IFMT
                    if kind == S_IFDIR {
                        out.append((name, true))
                    } else if kind == S_IFREG {
                        out.append((name, false))
                    }
                }
            }
        }
        return out
    }

    private func listRecentRegularFiles(
        at dirPath: String,
        suffix: String,
        mtimeCutoff: Double
    ) -> [(path: String, mtime: Double, size: UInt64)] {
        guard let dir = opendir(dirPath) else { return [] }
        defer { closedir(dir) }
        var out: [(path: String, mtime: Double, size: UInt64)] = []
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) { String(cString: $0) }
            }
            guard name.hasSuffix(suffix), !name.hasPrefix(".") else { continue }
            let fullPath = dirPath + "/" + name
            guard let attrs = fileMtimeAndSize(at: fullPath), attrs.mtime >= mtimeCutoff else { continue }
            out.append((fullPath, attrs.mtime, attrs.size))
        }
        return out
    }

    private func readTailBytes(atPath path: String, maxBytes: UInt64) -> Data? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { return Data() }
        let fileSize = UInt64(st.st_size)
        let offset: UInt64 = fileSize > maxBytes ? (fileSize - maxBytes) : 0
        let toRead = Int(fileSize - offset)
        guard toRead > 0 else { return Data() }

        var buf = Data(count: toRead)
        let bytesRead: Int = buf.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress else { return -1 }
            var total = 0
            while total < toRead {
                let n = pread(fd, ptr.advanced(by: total), toRead - total, off_t(offset) + off_t(total))
                if n <= 0 { break }
                total += n
            }
            return total
        }
        guard bytesRead > 0 else { return nil }
        if bytesRead < toRead {
            buf.count = bytesRead
        }
        if offset > 0 {
            // Skip potentially truncated leading partial line.
            guard let firstNL = buf.firstIndex(of: 0x0A) else { return Data() }
            let nextIdx = buf.index(after: firstNL)
            return nextIdx < buf.endIndex ? Data(buf[nextIdx..<buf.endIndex]) : Data()
        }
        return buf
    }

    private func readHeadBytes(atPath path: String, maxBytes: Int) -> Data? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { return Data() }
        let toRead = min(Int(st.st_size), maxBytes)
        guard toRead > 0 else { return Data() }

        var buf = Data(count: toRead)
        let bytesRead: Int = buf.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress else { return -1 }
            var total = 0
            while total < toRead {
                let n = pread(fd, ptr.advanced(by: total), toRead - total, off_t(total))
                if n <= 0 { break }
                total += n
            }
            return total
        }
        guard bytesRead > 0 else { return nil }
        if bytesRead < toRead {
            buf.count = bytesRead
        }
        return buf
    }

    private func readFileBytes(at url: URL, fromOffset offset: UInt64) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        if offset > 0 {
            do {
                try fh.seek(toOffset: offset)
            } catch {
                return nil
            }
        }
        return try? fh.readToEnd()
    }

    private func forEachJSONLine(in data: Data, _ body: (Data) -> Void) {
        guard !data.isEmpty else { return }
        let newline: UInt8 = 0x0A
        var start = data.startIndex
        let end = data.endIndex
        while start < end {
            let lineEnd = data[start..<end].firstIndex(of: newline) ?? end
            if lineEnd > start {
                var sliceEnd = lineEnd
                if data[data.index(before: sliceEnd)] == 0x0D { // \r
                    sliceEnd = data.index(before: sliceEnd)
                }
                if sliceEnd > start {
                    body(data[start..<sliceEnd])
                }
            }
            start = lineEnd < end ? data.index(after: lineEnd) : end
        }
    }

    private static let needleUsage = Array("\"usage\"".utf8)
    private static let needleTypeAssistantCompact = Array("\"type\":\"assistant\"".utf8)
    private static let needleTypeAssistantSpaced = Array("\"type\": \"assistant\"".utf8)
    private static let needleTypeUserCompact = Array("\"type\":\"user\"".utf8)
    private static let needleTypeUserSpaced = Array("\"type\": \"user\"".utf8)
    private static let needleTurnDuration = Array("\"turn_duration\"".utf8)
    private static let needleGrokTurnCompleted = Array("\"turn_completed\"".utf8)
    private static let needleDSHStepStart = Array("\"step/start\"".utf8)
    private static let needleIsApiErrorTrue = Array("\"isApiErrorMessage\":true".utf8)
    private static let needleMessageKey = Array("\"message\":".utf8)
    private static let needleSourceKey = Array("\"source\":".utf8)
    private static let needleStreamKey = Array("\"stream\":".utf8)
    private static let needleClaudeMsgIdPrefix = Array("\"id\":\"msg_".utf8)

    private static func utf8Contains(_ data: Data, needle: String) -> Bool {
        let bytes = Array(needle.utf8)
        return utf8Contains(data, bytes: bytes)
    }

    private static func utf8Contains(_ data: Data, bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty, data.count >= bytes.count else { return bytes.isEmpty }
        return data.withUnsafeBytes { rawHay in
            guard let hayPtr = rawHay.baseAddress else { return false }
            return bytes.withUnsafeBytes { rawNeed in
                guard let needPtr = rawNeed.baseAddress else { return false }
                return memmem(hayPtr, rawHay.count, needPtr, rawNeed.count) != nil
            }
        }
    }

    private static func findBytes(in data: Data, needle: [UInt8], searchStart: Data.Index? = nil) -> Range<Data.Index>? {
        let start = searchStart ?? data.startIndex
        let end = data.endIndex
        guard !needle.isEmpty, start < end else { return nil }
        let slice = data[start..<end]
        guard slice.count >= needle.count else { return nil }
        let offset: Int? = slice.withUnsafeBytes { rawHay -> Int? in
            guard let hayPtr = rawHay.baseAddress else { return nil }
            return needle.withUnsafeBytes { rawNeed -> Int? in
                guard let needPtr = rawNeed.baseAddress else { return nil }
                guard let hit = memmem(hayPtr, rawHay.count, needPtr, rawNeed.count) else { return nil }
                return UnsafeRawPointer(hit) - hayPtr
            }
        }
        guard let offset else { return nil }
        let lo = data.index(start, offsetBy: offset)
        let hi = data.index(lo, offsetBy: needle.count)
        return lo..<hi
    }

    /// Extracts Claude `message.id` (`msg_...`), avoiding accidental match on nested `tool_use` `toolu_...` IDs.
    private static func extractClaudeMsgId(in data: Data, searchStart: Data.Index) -> String? {
        if let hit = findBytes(in: data, needle: needleClaudeMsgIdPrefix, searchStart: searchStart) {
            // hit.lowerBound points to `"id":"msg_`; extract string starting right at `"msg_`
            let quoteStart = data.index(hit.lowerBound, offsetBy: 5) // points at opening `"` of `"msg_...`
            let end = data.endIndex
            var idx = data.index(after: quoteStart)
            while idx < end {
                if data[idx] == 0x22 { // closing `"`
                    return String(data: data[data.index(after: quoteStart)..<idx], encoding: .utf8)
                }
                idx = data.index(after: idx)
            }
        }
        if let candidate = extractJSONString(in: data, afterKey: "id", searchStart: searchStart),
           candidate.hasPrefix("msg_") {
            return candidate
        }
        return nil
    }

    /// Fast byte-level JSON value locator: finds `"key":` and returns the index of the first non-whitespace value byte.
    private static func findJSONValueStart(
        in data: Data,
        afterKey key: String,
        searchStart: Data.Index? = nil
    ) -> Data.Index? {
        let pattern = Array("\"\(key)\"".utf8)
        var cursor = searchStart ?? data.startIndex
        let end = data.endIndex
        while cursor < end {
            guard let found = findBytes(in: data, needle: pattern, searchStart: cursor) else {
                return nil
            }
            var idx = found.upperBound
            while idx < end && (data[idx] == 0x20 || data[idx] == 0x09 || data[idx] == 0x0A || data[idx] == 0x0D) {
                idx = data.index(after: idx)
            }
            if idx < end && data[idx] == 0x3A { // ':'
                idx = data.index(after: idx)
                while idx < end && (data[idx] == 0x20 || data[idx] == 0x09 || data[idx] == 0x0A || data[idx] == 0x0D) {
                    idx = data.index(after: idx)
                }
                return idx < end ? idx : nil
            }
            cursor = found.upperBound
        }
        return nil
    }

    /// Extracts ONLY a balanced `{...}` JSON sub-object after `"key":`, avoiding deserializing megabytes of sibling blobs.
    private static func extractJSONObject(
        in data: Data,
        afterKey key: String,
        searchStart: Data.Index? = nil
    ) -> [String: Any]? {
        var cursor = searchStart ?? data.startIndex
        let end = data.endIndex
        while cursor < end {
            guard let valStart = findJSONValueStart(in: data, afterKey: key, searchStart: cursor) else {
                return nil
            }
            guard data[valStart] == 0x7B else { // '{'
                cursor = data.index(after: valStart)
                continue
            }
            var idx = valStart
            var depth = 0
            var inString = false
            var escaped = false
            while idx < end {
                let b = data[idx]
                if inString {
                    if escaped {
                        escaped = false
                    } else if b == 0x5C { // '\\'
                        escaped = true
                    } else if b == 0x22 { // '"'
                        inString = false
                    }
                } else {
                    if b == 0x22 {
                        inString = true
                    } else if b == 0x7B { // '{'
                        depth += 1
                    } else if b == 0x7D { // '}'
                        depth -= 1
                        if depth == 0 {
                            let sliceEnd = data.index(after: idx)
                            let slice = data[valStart..<sliceEnd]
                            if let obj = (try? JSONSerialization.jsonObject(with: slice, options: [])) as? [String: Any] {
                                return obj
                            }
                            return nil
                        }
                    }
                }
                idx = data.index(after: idx)
            }
            return nil
        }
        return nil
    }

    /// Fast byte-level extractor for a scalar JSON string `"key":"value"`.
    private static func extractJSONString(
        in data: Data,
        afterKey key: String,
        searchStart: Data.Index? = nil
    ) -> String? {
        guard let valStart = findJSONValueStart(in: data, afterKey: key, searchStart: searchStart),
              data[valStart] == 0x22 else { // '"'
            return nil
        }
        let end = data.endIndex
        var idx = data.index(after: valStart)
        var hasEscape = false
        while idx < end {
            let b = data[idx]
            if b == 0x5C { // '\\'
                hasEscape = true
                idx = data.index(after: idx)
                if idx < end { idx = data.index(after: idx) }
                continue
            }
            if b == 0x22 { // closing '"'
                if !hasEscape {
                    return String(data: data[data.index(after: valStart)..<idx], encoding: .utf8)
                }
                // Unescape via tiny JSON fragment parse.
                let slice = data[valStart..<data.index(after: idx)]
                if let str = (try? JSONSerialization.jsonObject(with: slice, options: [.fragmentsAllowed])) as? String {
                    return str
                }
                return nil
            }
            idx = data.index(after: idx)
        }
        return nil
    }

    /// Fast byte-level extractor for a scalar JSON integer `"key":12345`.
    private static func extractJSONInt64(
        in data: Data,
        afterKey key: String,
        searchStart: Data.Index? = nil
    ) -> Int64? {
        guard let valStart = findJSONValueStart(in: data, afterKey: key, searchStart: searchStart) else {
            return nil
        }
        let end = data.endIndex
        var idx = valStart
        var negative = false
        if data[idx] == 0x2D { // '-'
            negative = true
            idx = data.index(after: idx)
        }
        var value: Int64 = 0
        var digits = 0
        while idx < end {
            let b = data[idx]
            guard b >= 48 && b <= 57 else { break }
            let d = Int64(b - 48)
            if value > (Int64.max - d) / 10 { return nil }
            value = value * 10 + d
            digits += 1
            idx = data.index(after: idx)
        }
        guard digits > 0 else { return nil }
        return negative ? -value : value
    }

    private static func readJSONStringField(at url: URL, key: String) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
              let val = obj[key] as? String,
              !val.isEmpty else {
            return nil
        }
        return val
    }

    private static let shanghaiTimeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!

    private static func shanghaiDateString(from date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = shanghaiTimeZone
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    private static func shanghaiDateSequence(endingOn endDate: Date, count: Int) -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = shanghaiTimeZone
        let endStart = cal.startOfDay(for: endDate)
        var out: [String] = []
        out.reserveCapacity(count)
        for offset in stride(from: -(count - 1), through: 0, by: 1) {
            if let d = cal.date(byAdding: .day, value: offset, to: endStart) {
                out.append(shanghaiDateString(from: d))
            }
        }
        return out
    }

    private static func epochToSeconds(_ raw: Double) -> Double? {
        guard raw.isFinite, raw > 1_000_000_000 else { return nil }
        if raw > 100_000_000_000_000 { // microseconds
            return raw / 1_000_000.0
        }
        if raw > 10_000_000_000 { // milliseconds
            return raw / 1_000.0
        }
        return raw
    }

    private static func epochMsToShanghaiDateKey(_ raw: Double) -> String? {
        guard let secs = epochToSeconds(raw) else { return nil }
        let date = Date(timeIntervalSince1970: secs)
        let key = shanghaiDateString(from: date)
        return (key >= "2020-01-01") ? key : nil
    }

    /// Fast zero-formatter ISO-8601 UTC/offset timestamp -> Unix epoch seconds (with sub-second fractional precision).
    private static func parseISOToEpochSeconds(_ raw: String) -> Double? {
        let bytes = Array(raw.utf8)
        guard bytes.count >= 19 else { return nil }

        func digit(_ i: Int) -> Int? {
            let b = bytes[i]
            guard b >= 48 && b <= 57 else { return nil }
            return Int(b - 48)
        }
        func num2(_ i: Int) -> Int? {
            guard let a = digit(i), let b = digit(i + 1) else { return nil }
            return a * 10 + b
        }
        func num4(_ i: Int) -> Int? {
            guard let a = num2(i), let b = num2(i + 2) else { return nil }
            return a * 100 + b
        }

        guard let year = num4(0), bytes[4] == 45,
              let month = num2(5), bytes[7] == 45,
              let day = num2(8),
              (bytes[10] == 84 || bytes[10] == 32), // 'T' or ' '
              let hour = num2(11), bytes[13] == 58,
              let minute = num2(14), bytes[16] == 58,
              let second = num2(17) else {
            return Formatters.parseRFC3339(raw)?.timeIntervalSince1970
        }

        var idx = 19
        var frac = 0.0
        if idx < bytes.count && bytes[idx] == 46 { // '.'
            idx += 1
            var scale = 0.1
            while idx < bytes.count && bytes[idx] >= 48 && bytes[idx] <= 57 {
                frac += Double(bytes[idx] - 48) * scale
                scale *= 0.1
                idx += 1
            }
        }
        var tzOffsetSeconds = 0
        if idx < bytes.count {
            let tzChar = bytes[idx]
            if tzChar == 90 || tzChar == 122 { // 'Z' or 'z'
                tzOffsetSeconds = 0
            } else if (tzChar == 43 || tzChar == 45), idx + 5 < bytes.count { // '+' or '-'
                let sign = (tzChar == 43) ? 1 : -1
                if let tzH = num2(idx + 1) {
                    let minIdx = (bytes[idx + 3] == 58) ? (idx + 4) : (idx + 3)
                    let tzM = (minIdx + 1 < bytes.count) ? (num2(minIdx) ?? 0) : 0
                    tzOffsetSeconds = sign * (tzH * 3600 + tzM * 60)
                }
            }
        }

        guard year >= 2020 && year <= 2100 else { return nil }
        let days = civilToDays(year: year, month: month, day: day)
        let utcSeconds = Int64(days) * 86_400 + Int64(hour * 3600 + minute * 60 + second - tzOffsetSeconds)
        return Double(utcSeconds) + frac
    }

    /// Fast zero-formatter ISO-8601 UTC/offset timestamp -> `Asia/Shanghai` `YYYY-MM-DD` converter.
    private static func parseISOToShanghaiDateKey(_ raw: String) -> String? {
        let bytes = Array(raw.utf8)
        guard bytes.count >= 19 else { return nil }

        func digit(_ i: Int) -> Int? {
            let b = bytes[i]
            guard b >= 48 && b <= 57 else { return nil }
            return Int(b - 48)
        }
        func num2(_ i: Int) -> Int? {
            guard let a = digit(i), let b = digit(i + 1) else { return nil }
            return a * 10 + b
        }
        func num4(_ i: Int) -> Int? {
            guard let a = num2(i), let b = num2(i + 2) else { return nil }
            return a * 100 + b
        }

        guard let year = num4(0), bytes[4] == 45,
              let month = num2(5), bytes[7] == 45,
              let day = num2(8),
              (bytes[10] == 84 || bytes[10] == 32), // 'T' or ' '
              let hour = num2(11), bytes[13] == 58,
              let minute = num2(14), bytes[16] == 58,
              let second = num2(17) else {
            if let parsed = Formatters.parseRFC3339(raw) {
                return shanghaiDateString(from: parsed)
            }
            return nil
        }

        // Parse optional fractional seconds and timezone offset (`Z` or `+HH:MM` / `-HH:MM`).
        var idx = 19
        if idx < bytes.count && bytes[idx] == 46 { // '.'
            idx += 1
            while idx < bytes.count && bytes[idx] >= 48 && bytes[idx] <= 57 {
                idx += 1
            }
        }
        var tzOffsetSeconds = 0
        if idx < bytes.count {
            let tzChar = bytes[idx]
            if tzChar == 90 || tzChar == 122 { // 'Z' or 'z'
                tzOffsetSeconds = 0
            } else if (tzChar == 43 || tzChar == 45), idx + 5 < bytes.count { // '+' or '-'
                let sign = (tzChar == 43) ? 1 : -1
                if let tzH = num2(idx + 1) {
                    let minIdx = (bytes[idx + 3] == 58) ? (idx + 4) : (idx + 3)
                    let tzM = (minIdx + 1 < bytes.count) ? (num2(minIdx) ?? 0) : 0
                    tzOffsetSeconds = sign * (tzH * 3600 + tzM * 60)
                }
            }
        }

        // Convert civil date/time -> unix epoch seconds via Howard Hinnant's civil-to-days algorithm (pure integer math).
        let days = civilToDays(year: year, month: month, day: day)
        let utcSeconds = Int64(days) * 86_400 + Int64(hour * 3600 + minute * 60 + second - tzOffsetSeconds)
        // Shift to Asia/Shanghai (UTC+8, no DST since 1991).
        let shanghaiSeconds = utcSeconds + 8 * 3600
        let shanghaiDays = floorDiv(shanghaiSeconds, 86_400)
        let (sy, sm, sd) = daysToCivil(Int(shanghaiDays))
        guard sy >= 2020 && sy <= 2100 else { return nil }
        return String(format: "%04d-%02d-%02d", sy, sm, sd)
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        let r = a % b
        return (r != 0 && ((r < 0) != (b < 0))) ? (q - 1) : q
    }

    private static func civilToDays(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func daysToCivil(_ z0: Int) -> (Int, Int, Int) {
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

    private static func isValidDateKey(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard b.count == 10, b[4] == 45, b[7] == 45 else { return false }
        for idx in [0, 1, 2, 3, 5, 6, 8, 9] {
            if b[idx] < 48 || b[idx] > 57 { return false }
        }
        return s >= "2020-01-01" && s <= "2100-12-31"
    }

    private static func parseInt64(_ raw: Any?) -> Int64? {
        guard let raw, !(raw is NSNull) else { return nil }
        if let i = raw as? Int64 { return i }
        if let i = raw as? Int { return Int64(i) }
        if let n = raw as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.int64Value
        }
        if let s = raw as? String {
            return Int64(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func parseDouble(_ raw: Any?) -> Double? {
        guard let raw, !(raw is NSNull) else { return nil }
        if let d = raw as? Double, d.isFinite { return d }
        if let i = raw as? Int { return Double(i) }
        if let i64 = raw as? Int64 { return Double(i64) }
        if let n = raw as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let s = raw as? String, let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)), d.isFinite {
            return d
        }
        return nil
    }

    private static func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(Formatters.formatRFC3339UTC(date))
        }
        return enc
    }

    private static func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let str = try? c.decode(String.self), let d = Formatters.parseRFC3339(str) {
                return d
            }
            if let ts = try? c.decode(Double.self) {
                return Date(timeIntervalSince1970: ts)
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date")
        }
        return dec
    }
}
