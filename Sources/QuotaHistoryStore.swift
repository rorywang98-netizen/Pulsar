import Foundation

// MARK: - Quota History & Burn-Rate Models

public enum QuotaHistoryRange: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case hours6
    case hours24
    case days7

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hours6: return "6小时"
        case .hours24: return "24小时"
        case .days7: return "7天"
        }
    }

    public var durationSeconds: TimeInterval {
        switch self {
        case .hours6: return 6 * 3600
        case .hours24: return 24 * 3600
        case .days7: return 7 * 24 * 3600
        }
    }

    public var bucketSeconds: TimeInterval {
        switch self {
        case .hours6: return 30 * 60
        case .hours24: return 60 * 60
        case .days7: return 6 * 3600
        }
    }
}

public struct QuotaHistorySample: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var remainingByWindow: [String: Double]
    public var resetAtByWindow: [String: Date]

    public init(
        timestamp: Date,
        remainingByWindow: [String: Double],
        resetAtByWindow: [String: Date] = [:]
    ) {
        self.timestamp = timestamp
        var clamped: [String: Double] = [:]
        clamped.reserveCapacity(remainingByWindow.count)
        for (key, value) in remainingByWindow {
            let safe = value.isFinite ? min(max(value, 0.0), 100.0) : 0.0
            clamped[key] = safe
        }
        self.remainingByWindow = clamped
        self.resetAtByWindow = resetAtByWindow
    }
}

public struct QuotaBurnPoint: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var remainingPercent: Double

    public init(timestamp: Date, remainingPercent: Double) {
        self.timestamp = timestamp
        self.remainingPercent = remainingPercent.isFinite ? min(max(remainingPercent, 0.0), 100.0) : 0.0
    }
}

public struct QuotaBurnBucket: Codable, Equatable, Identifiable, Sendable {
    public var start: Date
    public var end: Date
    public var label: String
    public var dropPercent: Double

    public var id: TimeInterval { start.timeIntervalSince1970 }

    public init(start: Date, end: Date, label: String, dropPercent: Double) {
        self.start = start
        self.end = end
        self.label = label
        self.dropPercent = (dropPercent.isFinite && dropPercent > 0.0) ? dropPercent : 0.0
    }
}

public struct QuotaBurnSeries: Codable, Equatable, Identifiable, Sendable {
    public var windowId: String
    public var label: String
    public var points: [QuotaBurnPoint]
    public var resetMarkers: [Date]
    public var buckets: [QuotaBurnBucket]
    public var peakBucket: QuotaBurnBucket?
    public var totalConsumedPercent: Double
    public var averageBurnPerHour: Double

    public var id: String { windowId }

    public init(
        windowId: String,
        label: String,
        points: [QuotaBurnPoint],
        resetMarkers: [Date],
        buckets: [QuotaBurnBucket],
        peakBucket: QuotaBurnBucket?,
        totalConsumedPercent: Double,
        averageBurnPerHour: Double
    ) {
        self.windowId = windowId
        self.label = label
        self.points = points
        self.resetMarkers = resetMarkers
        self.buckets = buckets
        self.peakBucket = peakBucket
        self.totalConsumedPercent = (totalConsumedPercent.isFinite && totalConsumedPercent > 0) ? totalConsumedPercent : 0.0
        self.averageBurnPerHour = (averageBurnPerHour.isFinite && averageBurnPerHour > 0) ? averageBurnPerHour : 0.0
    }
}

// MARK: - Persistent Account Quota History Store

public final class QuotaHistoryStore: @unchecked Sendable {
    public static let retentionSeconds: TimeInterval = 7 * 24 * 3600
    public static let maxSamplesPerAccount: Int = 900
    public static let heartbeatIntervalSeconds: TimeInterval = 15 * 60
    public static let significantRemainingDeltaPercent: Double = 0.1
    public static let resetJumpThresholdPercent: Double = 12.0
    public static let resetForwardThresholdSeconds: TimeInterval = 60.0

    public static var defaultFileURL: URL {
        RegistryData.defaultDirectoryURL.appendingPathComponent("quota-history.json", isDirectory: false)
    }

    public static func accountKey(provider: ProviderID, accountId: String) -> String {
        "\(provider.rawValue)|\(accountId)"
    }

    private struct AccountHistoryRecord: Codable {
        var windowLabels: [String: String]
        var samples: [QuotaHistorySample]
    }

    private struct PersistedPayload: Codable {
        var version: Int
        var accounts: [String: AccountHistoryRecord]
    }

    private let fileURL: URL?
    private let lock = NSLock()
    private var accounts: [String: AccountHistoryRecord] = [:]

    public init(fileURL: URL? = QuotaHistoryStore.defaultFileURL) {
        self.fileURL = fileURL
        if let fileURL {
            self.accounts = Self.loadFromDisk(url: fileURL)
        }
    }

    /// Records a `.ready` non-stale snapshot with non-empty windows using smart deduplication + 15m heartbeat.
    /// Returns `true` when a new sample was recorded (and persisted when `fileURL != nil`).
    @discardableResult
    public func record(snapshot: QuotaSnapshot, now: Date = Date()) -> Bool {
        guard case .ready(_, let stale) = snapshot.status, !stale else { return false }
        guard !snapshot.windows.isEmpty else { return false }

        var remainingByWindow: [String: Double] = [:]
        var resetAtByWindow: [String: Date] = [:]
        var labelsByWindow: [String: String] = [:]

        remainingByWindow.reserveCapacity(snapshot.windows.count)
        for window in snapshot.windows {
            let pct = min(max(window.remainingFraction * 100.0, 0.0), 100.0)
            remainingByWindow[window.id] = pct
            if let resetAt = window.resetAt {
                resetAtByWindow[window.id] = resetAt
            }
            let trimmedLabel = window.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedLabel.isEmpty {
                labelsByWindow[window.id] = trimmedLabel
            }
        }
        guard !remainingByWindow.isEmpty else { return false }

        let key = Self.accountKey(provider: snapshot.provider, accountId: snapshot.accountId)
        let candidate = QuotaHistorySample(
            timestamp: now,
            remainingByWindow: remainingByWindow,
            resetAtByWindow: resetAtByWindow
        )

        lock.lock()
        var record = accounts[key] ?? AccountHistoryRecord(windowLabels: [:], samples: [])
        for (wid, label) in labelsByWindow {
            record.windowLabels[wid] = label
        }

        // Prune expired samples (> 7 days old relative to `now`)
        let cutoff = now.addingTimeInterval(-Self.retentionSeconds)
        let hadPruned = record.samples.contains { $0.timestamp < cutoff }
        if hadPruned {
            record.samples.removeAll { $0.timestamp < cutoff }
        }

        let shouldRecord: Bool
        if let last = record.samples.last {
            shouldRecord = Self.shouldRecordSample(previous: last, current: candidate)
        } else {
            shouldRecord = true
        }

        if !shouldRecord {
            if hadPruned {
                accounts[key] = record
                let snapshotToWrite = PersistedPayload(version: 1, accounts: accounts)
                lock.unlock()
                persistPayload(snapshotToWrite)
            } else {
                lock.unlock()
            }
            return false
        }

        if let last = record.samples.last, candidate.timestamp < last.timestamp {
            // Keep chronological ordering even if synthetic timestamps are inserted out-of-order.
            let insertIdx = record.samples.firstIndex { $0.timestamp > candidate.timestamp } ?? record.samples.endIndex
            record.samples.insert(candidate, at: insertIdx)
        } else {
            record.samples.append(candidate)
        }

        if record.samples.count > Self.maxSamplesPerAccount {
            record.samples = Array(record.samples.suffix(Self.maxSamplesPerAccount))
        }

        accounts[key] = record
        let snapshotToWrite = PersistedPayload(version: 1, accounts: accounts)
        lock.unlock()

        persistPayload(snapshotToWrite)
        return true
    }

    public func samples(for accountKey: String) -> [QuotaHistorySample] {
        lock.lock()
        defer { lock.unlock() }
        return accounts[accountKey]?.samples ?? []
    }

    public func sampleCount(for accountKey: String, range: QuotaHistoryRange? = nil, now: Date = Date()) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let list = accounts[accountKey]?.samples, !list.isEmpty else { return 0 }
        guard let range else { return list.count }
        let start = now.addingTimeInterval(-range.durationSeconds)
        return list.reduce(into: 0) { count, sample in
            if sample.timestamp >= start && sample.timestamp <= now {
                count += 1
            }
        }
    }

    /// Analyzes quota consumption, reset events, and bucketed burn rates for an account across `range`.
    public func analyze(
        accountKey: String,
        range: QuotaHistoryRange,
        preferredWindowIds: [String]? = nil,
        windowLabels: [String: String] = [:],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [QuotaBurnSeries] {
        lock.lock()
        let record = accounts[accountKey]
        lock.unlock()

        guard let record, !record.samples.isEmpty else { return [] }

        let rangeStart = now.addingTimeInterval(-range.durationSeconds)
        let scopedSamples = record.samples
            .filter { $0.timestamp >= rangeStart && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }

        guard !scopedSamples.isEmpty else { return [] }

        // Resolve target window IDs in clean display order.
        let orderedWindowIds: [String]
        if let preferred = preferredWindowIds, !preferred.isEmpty {
            var seen = Set<String>()
            var filtered: [String] = []
            for wid in preferred where seen.insert(wid).inserted {
                if scopedSamples.contains(where: { $0.remainingByWindow[wid] != nil }) {
                    filtered.append(wid)
                }
            }
            orderedWindowIds = filtered
        } else {
            var discovered: [String] = []
            var seen = Set<String>()
            for sample in scopedSamples.reversed() {
                for wid in sample.remainingByWindow.keys.sorted() where seen.insert(wid).inserted {
                    discovered.append(wid)
                }
            }
            orderedWindowIds = discovered.sorted { lhs, rhs in
                let lRank = Self.cadenceSortRank(for: lhs, label: windowLabels[lhs] ?? record.windowLabels[lhs] ?? lhs)
                let rRank = Self.cadenceSortRank(for: rhs, label: windowLabels[rhs] ?? record.windowLabels[rhs] ?? rhs)
                if lRank != rRank { return lRank < rRank }
                return lhs < rhs
            }
        }

        guard !orderedWindowIds.isEmpty else { return [] }

        let baseBuckets = Self.makeClockAlignedBuckets(
            range: range,
            rangeStart: rangeStart,
            rangeEnd: now,
            calendar: calendar
        )

        var results: [QuotaBurnSeries] = []
        results.reserveCapacity(orderedWindowIds.count)

        for wid in orderedWindowIds {
            var points: [QuotaBurnPoint] = []
            var resetTimes: [Date?] = []
            points.reserveCapacity(scopedSamples.count)
            resetTimes.reserveCapacity(scopedSamples.count)

            for sample in scopedSamples {
                guard let rem = sample.remainingByWindow[wid] else { continue }
                points.append(QuotaBurnPoint(timestamp: sample.timestamp, remainingPercent: rem))
                resetTimes.append(sample.resetAtByWindow[wid])
            }
            guard !points.isEmpty else { continue }

            var buckets = baseBuckets
            var resetMarkers: [Date] = []
            var totalConsumed: Double = 0.0

            if points.count >= 2 {
                for idx in 1..<points.count {
                    let prevPt = points[idx - 1]
                    let currPt = points[idx]
                    let prevReset = resetTimes[idx - 1]
                    let currReset = resetTimes[idx]

                    let delta = currPt.remainingPercent - prevPt.remainingPercent
                    let resetByValue = delta >= Self.resetJumpThresholdPercent
                    let resetByTimestamp: Bool = {
                        guard let prevReset, let currReset else { return false }
                        return currReset.timeIntervalSince(prevReset) >= Self.resetForwardThresholdSeconds
                    }()

                    if resetByValue || resetByTimestamp {
                        resetMarkers.append(currPt.timestamp)
                        continue
                    }

                    let drop = max(0.0, prevPt.remainingPercent - currPt.remainingPercent)
                    guard drop > 0.0 else { continue }

                    totalConsumed += drop
                    Self.distributeDrop(
                        drop,
                        from: prevPt.timestamp,
                        to: currPt.timestamp,
                        into: &buckets
                    )
                }
            }

            let peakBucket = buckets
                .filter { $0.dropPercent >= 0.05 }
                .max { lhs, rhs in
                    if abs(lhs.dropPercent - rhs.dropPercent) > 0.0001 {
                        return lhs.dropPercent < rhs.dropPercent
                    }
                    return lhs.start < rhs.start
                }

            let averageBurnPerHour: Double = {
                guard points.count >= 2, totalConsumed > 0 else { return 0.0 }
                let spanSec = points.last!.timestamp.timeIntervalSince(points.first!.timestamp)
                guard spanSec >= 60.0 else { return 0.0 }
                return totalConsumed / (spanSec / 3600.0)
            }()

            let resolvedLabel = windowLabels[wid]
                ?? record.windowLabels[wid]
                ?? Self.fallbackWindowLabel(for: wid)

            results.append(
                QuotaBurnSeries(
                    windowId: wid,
                    label: resolvedLabel,
                    points: points,
                    resetMarkers: resetMarkers,
                    buckets: buckets,
                    peakBucket: peakBucket,
                    totalConsumedPercent: totalConsumed,
                    averageBurnPerHour: averageBurnPerHour
                )
            )
        }

        return results
    }

    // MARK: - Sampling & Analysis Helpers

    private static func shouldRecordSample(
        previous: QuotaHistorySample,
        current: QuotaHistorySample
    ) -> Bool {
        if current.timestamp.timeIntervalSince(previous.timestamp) >= heartbeatIntervalSeconds {
            return true
        }
        if Set(previous.remainingByWindow.keys) != Set(current.remainingByWindow.keys) {
            return true
        }
        for (wid, currVal) in current.remainingByWindow {
            guard let prevVal = previous.remainingByWindow[wid] else {
                return true
            }
            if abs(currVal - prevVal) >= significantRemainingDeltaPercent {
                return true
            }
        }
        for (wid, currReset) in current.resetAtByWindow {
            if let prevReset = previous.resetAtByWindow[wid] {
                if currReset.timeIntervalSince(prevReset) >= resetForwardThresholdSeconds {
                    return true
                }
            } else {
                return true
            }
        }
        return false
    }

    private static func makeClockAlignedBuckets(
        range: QuotaHistoryRange,
        rangeStart: Date,
        rangeEnd: Date,
        calendar: Calendar
    ) -> [QuotaBurnBucket] {
        let bucketSec = range.bucketSeconds
        let alignedStart = floorToBucketBoundary(date: rangeStart, range: range, calendar: calendar)

        var buckets: [QuotaBurnBucket] = []
        var cursor = alignedStart
        var guardIterations = 0
        while cursor < rangeEnd && guardIterations < 256 {
            let next = cursor.addingTimeInterval(bucketSec)
            let label = formatBucketLabel(start: cursor, end: next, range: range, calendar: calendar)
            buckets.append(QuotaBurnBucket(start: cursor, end: next, label: label, dropPercent: 0.0))
            cursor = next
            guardIterations += 1
        }
        if buckets.isEmpty {
            let next = alignedStart.addingTimeInterval(bucketSec)
            buckets.append(
                QuotaBurnBucket(
                    start: alignedStart,
                    end: next,
                    label: formatBucketLabel(start: alignedStart, end: next, range: range, calendar: calendar),
                    dropPercent: 0.0
                )
            )
        }
        return buckets
    }

    private static func floorToBucketBoundary(
        date: Date,
        range: QuotaHistoryRange,
        calendar: Calendar
    ) -> Date {
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        var aligned = DateComponents()
        aligned.calendar = calendar
        aligned.timeZone = calendar.timeZone
        aligned.year = comps.year
        aligned.month = comps.month
        aligned.day = comps.day
        aligned.second = 0
        aligned.nanosecond = 0

        switch range {
        case .hours6:
            aligned.hour = comps.hour ?? 0
            aligned.minute = ((comps.minute ?? 0) / 30) * 30
        case .hours24:
            aligned.hour = comps.hour ?? 0
            aligned.minute = 0
        case .days7:
            aligned.hour = ((comps.hour ?? 0) / 6) * 6
            aligned.minute = 0
        }
        return calendar.date(from: aligned) ?? date
    }

    private static func formatBucketLabel(
        start: Date,
        end: Date,
        range: QuotaHistoryRange,
        calendar: Calendar
    ) -> String {
        let sComps = calendar.dateComponents([.month, .day, .hour, .minute], from: start)
        let eComps = calendar.dateComponents([.hour, .minute], from: end)
        let sm = sComps.month ?? 1
        let sd = sComps.day ?? 1
        let sh = sComps.hour ?? 0
        let smin = sComps.minute ?? 0
        let eh = eComps.hour ?? 0
        let emin = eComps.minute ?? 0

        switch range {
        case .hours6:
            return String(format: "%02d:%02d–%02d:%02d", sh, smin, eh, emin)
        case .hours24:
            let endHourDisplay = (eh == 0 && sh == 23) ? 24 : eh
            return String(format: "%02d:00–%02d:00", sh, endHourDisplay)
        case .days7:
            let endHourDisplay = (eh == 0 && sh >= 18) ? 24 : eh
            return String(format: "%02d/%02d %02d:00–%02d:00", sm, sd, sh, endHourDisplay)
        }
    }

    private static func distributeDrop(
        _ drop: Double,
        from start: Date,
        to end: Date,
        into buckets: inout [QuotaBurnBucket]
    ) {
        guard !buckets.isEmpty, drop > 0 else { return }
        let span = end.timeIntervalSince(start)
        if span <= 0.001 {
            if let idx = buckets.lastIndex(where: { start >= $0.start && start < $0.end }) ?? buckets.indices.last {
                buckets[idx].dropPercent += drop
            }
            return
        }

        var attributed: Double = 0.0
        for idx in buckets.indices {
            let overlapStart = max(start, buckets[idx].start)
            let overlapEnd = min(end, buckets[idx].end)
            let overlap = overlapEnd.timeIntervalSince(overlapStart)
            if overlap > 0 {
                let share = drop * (overlap / span)
                buckets[idx].dropPercent += share
                attributed += share
            }
        }

        // Guard against edge rounding if interval lay right on boundary outside buckets.
        if attributed <= 0.0001 {
            if let idx = buckets.lastIndex(where: { end > $0.start && end <= $0.end }) ?? buckets.indices.last {
                buckets[idx].dropPercent += drop
            }
        }
    }

    private static func cadenceSortRank(for windowId: String, label: String) -> Int {
        let lowId = windowId.lowercased()
        let lowLabel = label.lowercased()
        if lowId.contains("5h") || lowLabel.contains("5小时") || lowLabel.contains("5 小时") || lowLabel.contains("5h") {
            return 0
        }
        if lowId.contains("daily") || lowId.contains("1d") || lowLabel.contains("每日") {
            return 1
        }
        if lowId.contains("week") || lowId.contains("7d") || lowLabel.contains("周") || lowLabel.contains("7天") {
            return 2
        }
        if lowId.contains("month") || lowLabel.contains("月") {
            return 3
        }
        return 4
    }

    private static func fallbackWindowLabel(for windowId: String) -> String {
        let low = windowId.lowercased()
        if low.contains("5h") { return "5小时" }
        if low.contains("week") || low.contains("7d") { return "本周" }
        if low.contains("month") { return "本月" }
        if low.contains("daily") || low.contains("1d") { return "每日" }
        return windowId
    }

    // MARK: - Atomic 0600 Disk Persistence

    private static func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        return enc
    }

    private static func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    private static func loadFromDisk(url: URL) -> [String: AccountHistoryRecord] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let decoded = try? makeDecoder().decode(PersistedPayload.self, from: data) else {
            return [:]
        }
        var cleaned: [String: AccountHistoryRecord] = [:]
        for (key, var record) in decoded.accounts {
            record.samples.sort { $0.timestamp < $1.timestamp }
            if record.samples.count > maxSamplesPerAccount {
                record.samples = Array(record.samples.suffix(maxSamplesPerAccount))
            }
            if !record.samples.isEmpty {
                cleaned[key] = record
            }
        }
        return cleaned
    }

    private func persistPayload(_ payload: PersistedPayload) {
        guard let fileURL else { return }
        guard let data = try? Self.makeEncoder().encode(payload) else { return }
        try? KeychainStore.writeAtomicFile(data: data, to: fileURL, mode: 0o600)
    }
}
