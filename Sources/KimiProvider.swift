import Foundation

// MARK: - Kimi Code Quota Provider

public final class KimiProvider: ProviderAdapter, @unchecked Sendable {
    public static let defaultAccountId = "kimi:api"
    public static let keychainAccount = "kimi"
    public static let primaryUsagesURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    public static let fallbackUsagesURL = URL(string: "https://api.kimi.ai/coding/v1/usages")!

    public let id: ProviderID = .kimi
    public let capabilities: ProviderCapability = [.quota, .apiKeyConfig]
    public let transportPolicy: TransportPolicy = .systemProxy
    public let isolatedStoreNamespace: String = "com.rory.roryorbit.kimi"

    public let keychain: KeychainStore
    private let session: URLSession
    private let environment: [String: String]

    public init(
        keychain: KeychainStore = .shared,
        session: URLSession? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.keychain = keychain
        self.session = session ?? HTTPFactory.makeSession(policy: .systemProxy, timeout: 20.0)
        self.environment = environment
    }

    // MARK: - Parsed Usage Model

    public struct ParsedKimiUsage: Equatable, Sendable {
        public let plan: PlanInfo?
        public let windows: [QuotaWindow]
        public let paceNote: String?
    }

    // MARK: - ProviderAdapter

    public func detectClientStatus() async -> ClientRuntimeStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidatePaths = [
            "\(home)/.local/bin/kimi",
            "/opt/homebrew/bin/kimi",
            "/usr/local/bin/kimi",
        ]
        var status = ProcessController.shared.detectClientStatus(
            bundleIDs: [],
            extraAppPaths: [],
            detachedExecutableMatchers: [
                { path in
                    candidatePaths.contains(path) || path.hasSuffix("/bin/kimi")
                }
            ]
        )
        if candidatePaths.contains(where: { FileManager.default.fileExists(atPath: $0) }),
           !status.installedApps.contains("Kimi CLI") {
            status.installedApps.append("Kimi CLI")
        }
        return status
    }

    public func hasStoredAPIKey() -> Bool {
        guard let raw = try? keychain.readSecret(
            service: KeychainStore.roryOrbitKeysService,
            account: Self.keychainAccount
        ) else {
            return false
        }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func saveAPIKey(_ key: String, label: String?) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderAdapterError.invalidCredential("请输入有效的 Kimi API Key")
        }
        try keychain.writeSecret(
            service: KeychainStore.roryOrbitKeysService,
            account: Self.keychainAccount,
            value: trimmed
        )
    }

    public func deleteAccountCredentials(accountId: String) throws {
        try keychain.deleteSecret(
            service: KeychainStore.roryOrbitKeysService,
            account: Self.keychainAccount
        )
    }

    public func syncLiveAccount(registry: inout RegistryData) async -> String? {
        let existing = registry.accounts(for: .kimi).first { $0.id == Self.defaultAccountId }
            ?? registry.accounts(for: .kimi).first
        let accountId = existing?.id ?? Self.defaultAccountId
        let displayName = existing?.displayName.isEmpty == false ? existing!.displayName : "Kimi Code"
        let email = existing?.email.isEmpty == false ? existing!.email : displayName

        let record = AccountRecord(
            id: accountId,
            provider: .kimi,
            email: email,
            displayName: displayName,
            plan: existing?.plan ?? PlanInfo(kind: .api, displayName: "Kimi Code"),
            addedAt: existing?.addedAt ?? Date(),
            isActiveLive: true
        )
        registry.upsertAccount(record)
        registry.setActiveLive(accountId: accountId, for: .kimi)
        return accountId
    }

    public func fetchQuota(for account: AccountRecord, isActiveLive: Bool) async -> QuotaSnapshot {
        let apiKey: String
        do {
            guard let stored = try keychain.readSecret(
                service: KeychainStore.roryOrbitKeysService,
                account: Self.keychainAccount
            ) else {
                return QuotaSnapshot.unconfigured(
                    provider: .kimi,
                    accountId: account.id,
                    sourceLabel: "Kimi Code API",
                    message: "未配置 Kimi API Key，请在设置中填入"
                )
            }
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return QuotaSnapshot.unconfigured(
                    provider: .kimi,
                    accountId: account.id,
                    sourceLabel: "Kimi Code API",
                    message: "未配置 Kimi API Key，请在设置中填入"
                )
            }
            apiKey = trimmed
        } catch {
            return QuotaSnapshot.failed(
                provider: .kimi,
                accountId: account.id,
                sourceLabel: "Kimi Code API",
                message: "读取 Kimi Keychain 凭证失败"
            )
        }

        let endpoints = resolvedEndpointURLs()
        var lastError = "Kimi 额度请求失败"
        var allAuthFailures = !endpoints.isEmpty

        for (index, url) in endpoints.enumerated() {
            let outcome = await fetchFromEndpoint(url: url, apiKey: apiKey)
            switch outcome {
            case .success(let parsed):
                let primary = parsed.windows.first(where: { $0.isPrimary }) ?? parsed.windows.first
                let hostLabel = url.host ?? "api.kimi.com"
                return QuotaSnapshot(
                    provider: .kimi,
                    accountId: account.id,
                    plan: parsed.plan ?? account.plan ?? PlanInfo(kind: .api, displayName: "Kimi Code"),
                    windows: parsed.windows,
                    balance: nil,
                    status: .ready(fetchedAt: Date(), stale: false),
                    sourceLabel: "Kimi API (\(hostLabel))",
                    primaryRemainingPercent: primary?.remainingPercent,
                    paceNote: parsed.paceNote
                )

            case .authRequired:
                lastError = "Kimi API Key 无效或已失效，请在设置中更新"
                // If an alternate region endpoint exists (e.g. .com -> .ai), try it before declaring auth failure.
                if index + 1 < endpoints.count {
                    continue
                }

            case .failed(let msg):
                allAuthFailures = false
                lastError = msg
            }
        }

        if allAuthFailures {
            return QuotaSnapshot.reauthRequired(
                provider: .kimi,
                accountId: account.id,
                sourceLabel: "Kimi Code API",
                message: lastError
            )
        }

        return QuotaSnapshot.failed(
            provider: .kimi,
            accountId: account.id,
            sourceLabel: "Kimi Code API",
            message: lastError
        )
    }

    // MARK: - Endpoint Resolution

    public func resolvedEndpointURLs() -> [URL] {
        if let rawBase = environment["KIMI_CODE_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawBase.isEmpty,
           let customURL = Self.normalizeUsagesURL(from: rawBase) {
            return [customURL]
        }
        return [Self.primaryUsagesURL, Self.fallbackUsagesURL]
    }

    public static func normalizeUsagesURL(from rawBase: String) -> URL? {
        var trimmed = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        let finalString: String
        if lower.hasSuffix("/usages") {
            finalString = trimmed
        } else if lower.hasSuffix("/coding/v1") || lower.hasSuffix("/v1") {
            finalString = "\(trimmed)/usages"
        } else if lower.hasSuffix("/coding") {
            finalString = "\(trimmed)/v1/usages"
        } else {
            finalString = "\(trimmed)/coding/v1/usages"
        }

        guard let url = URL(string: finalString),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        return url
    }

    // MARK: - Network Request

    private enum FetchOutcome {
        case success(ParsedKimiUsage)
        case authRequired
        case failed(String)
    }

    private func fetchFromEndpoint(url: URL, apiKey: String) async -> FetchOutcome {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.httpShouldHandleCookies = false
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("RoryOrbit/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Kimi 接口无有效响应")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .authRequired
            }
            guard (200...299).contains(http.statusCode) else {
                return .failed("Kimi 额度接口返回 HTTP \(http.statusCode)")
            }
            if let parsed = Self.parseUsageJSON(data) {
                return .success(parsed)
            }
            return .failed("无法解析 Kimi 额度响应")
        } catch {
            return .failed("Kimi 网络请求失败: \(Self.sanitizedNetworkError(error))")
        }
    }

    // MARK: - Defensive JSON Parser

    public static func parseUsageJSON(_ data: Data, now: Date = Date()) -> ParsedKimiUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }

        let payload = (root["data"] as? [String: Any]) ?? root
        let plan = extractPlan(from: payload)
        let regionNote = extractRegion(from: payload)

        var parsedLimits: [QuotaWindow] = []
        if let limits = payload["limits"] as? [[String: Any]] {
            for (idx, item) in limits.enumerated() {
                let detailObj = (item["detail"] as? [String: Any]) ?? item
                let windowObj = item["window"] as? [String: Any]
                let windowSeconds = parseWindowSeconds(from: windowObj)
                let label = windowLabel(
                    windowSeconds: windowSeconds,
                    explicitName: nonEmptyString(item["name"]) ?? nonEmptyString(item["title"]) ?? nonEmptyString(item["scope"]),
                    index: idx
                )
                let limitId: String
                if let secs = windowSeconds, secs >= 550_000 && secs <= 660_000 {
                    limitId = "kimi-code-7d"
                } else {
                    limitId = "kimi-limit-\(windowSeconds.map(String.init) ?? String(idx))"
                }
                if let win = buildWindow(
                    id: limitId,
                    label: label,
                    dict: detailObj,
                    windowSeconds: windowSeconds,
                    isPrimary: false
                ) {
                    parsedLimits.append(win)
                }
            }
        }

        var usageWindow: QuotaWindow?
        if let usageObj = payload["usage"] as? [String: Any] {
            let hasShortLimit = parsedLimits.contains { ($0.windowSeconds ?? Int.max) <= 86_400 }
            let explicitWindowSeconds = parseWindowSeconds(from: usageObj["window"] as? [String: Any])
            let explicitMeta = [
                nonEmptyString(usageObj["scope"]),
                nonEmptyString(usageObj["name"]),
                nonEmptyString(usageObj["title"]),
                nonEmptyString(usageObj["period"]),
            ].compactMap { $0?.lowercased() }.joined(separator: " ")
            let usageResetAt = parseDate(
                usageObj["resetTime"]
                    ?? usageObj["reset_time"]
                    ?? usageObj["resetAt"]
                    ?? usageObj["reset_at"]
                    ?? usageObj["resetsAt"]
                    ?? usageObj["resets_at"]
            )
            let resetHorizonSeconds = usageResetAt.map { $0.timeIntervalSince(now) }
            let isExplicitMonthly = (explicitWindowSeconds ?? 0) > 660_000
                || explicitMeta.contains("month")
                || explicitMeta.contains("月")
                || ((resetHorizonSeconds ?? 0) > 8.0 * 86_400.0)
            let isExplicitWeekly = !isExplicitMonthly
                && ((explicitWindowSeconds ?? 0) >= 550_000 && (explicitWindowSeconds ?? 0) <= 660_000)

            let usageId: String
            let usageLabel: String
            let usageWindowSeconds: Int?
            if isExplicitMonthly {
                usageId = "kimi-monthly"
                usageLabel = "月度总额度"
                usageWindowSeconds = explicitWindowSeconds ?? 2_592_000
            } else if isExplicitWeekly {
                usageId = "kimi-weekly"
                usageLabel = "每周额度"
                usageWindowSeconds = explicitWindowSeconds
            } else {
                usageId = "kimi-usage"
                usageLabel = hasShortLimit ? "每周额度" : "套餐额度"
                usageWindowSeconds = hasShortLimit ? 604_800 : nil
            }

            usageWindow = buildWindow(
                id: usageId,
                label: usageLabel,
                dict: usageObj,
                windowSeconds: usageWindowSeconds,
                isPrimary: true
            )
        }

        // Parse modern Kimi `usages` object (e.g. `limit_month_total`, `limit_5h`, `limit_week`, `limit_code_7d`).
        var usagesWindows: [QuotaWindow] = []
        if let usagesObj = payload["usages"] as? [String: Any] {
            if let monthTotal = (usagesObj["limit_month_total"] as? [String: Any])
                ?? (usagesObj["month_total"] as? [String: Any])
                ?? (usagesObj["monthly"] as? [String: Any]),
               let win = buildWindow(
                   id: "kimi-monthly",
                   label: "月度总额度",
                   dict: monthTotal,
                   windowSeconds: 2_592_000,
                   isPrimary: true
               ) {
                usagesWindows.append(win)
            }
            if let weekTotal = (usagesObj["limit_week"] as? [String: Any])
                ?? (usagesObj["limit_weekly"] as? [String: Any])
                ?? (usagesObj["week_total"] as? [String: Any]),
               let win = buildWindow(
                   id: "kimi-weekly",
                   label: "每周额度",
                   dict: weekTotal,
                   windowSeconds: 604_800,
                   isPrimary: usagesWindows.isEmpty
               ) {
                usagesWindows.append(win)
            }
            if let code7d = (usagesObj["limit_code_7d"] as? [String: Any])
                ?? (usagesObj["limit_week_code"] as? [String: Any])
                ?? (usagesObj["limit_7d"] as? [String: Any]),
               let win = buildWindow(
                   id: "kimi-code-7d",
                   label: "代码 7 天",
                   dict: code7d,
                   windowSeconds: 604_800,
                   isPrimary: false
               ) {
                usagesWindows.append(win)
            }
            if let fiveH = usagesObj["limit_5h"] as? [String: Any],
               let win = buildWindow(
                   id: "kimi-limit-18000",
                   label: "5小时限额",
                   dict: fiveH,
                   windowSeconds: 18_000,
                   isPrimary: false
               ) {
                usagesWindows.append(win)
            }
        }

        var windows: [QuotaWindow] = []
        if let usageWindow {
            windows.append(usageWindow)
        }

        for uWin in usagesWindows {
            let isDuplicate = windows.contains { existing in
                existing.id == uWin.id
                    || (existing.windowSeconds != nil && existing.windowSeconds == uWin.windowSeconds)
            }
            if !isDuplicate {
                windows.append(uWin)
            }
        }

        // Append limits sorted from shorter window to longer window (e.g., 5h before daily/weekly).
        let sortedLimits = parsedLimits.sorted { lhs, rhs in
            (lhs.windowSeconds ?? Int.max) < (rhs.windowSeconds ?? Int.max)
        }
        for limitWin in sortedLimits {
            let isDuplicate = windows.contains { existing in
                if existing.id == limitWin.id {
                    return true
                }
                if existing.windowSeconds != nil && existing.windowSeconds == limitWin.windowSeconds {
                    let closeReset: Bool
                    if let r1 = existing.resetAt, let r2 = limitWin.resetAt {
                        closeReset = abs(r1.timeIntervalSince(r2)) <= 120.0
                    } else {
                        closeReset = true
                    }
                    if closeReset && abs(existing.remainingFraction - limitWin.remainingFraction) < 0.005 {
                        return true
                    }
                }
                return false
            }
            if !isDuplicate {
                windows.append(limitWin)
            }
        }

        // Fallback if API ever returns flat top-level {limit, used, remaining, resetTime}.
        if windows.isEmpty,
           let directWin = buildWindow(
               id: "kimi-usage",
               label: "套餐额度",
               dict: payload,
               windowSeconds: nil,
               isPrimary: true
           ) {
            windows.append(directWin)
        }

        guard !windows.isEmpty else {
            return nil
        }

        if !windows.contains(where: { $0.isPrimary }) {
            windows[0].isPrimary = true
        }

        var paceParts: [String] = []
        if let regionNote {
            paceParts.append(regionNote)
        }
        if let primaryReset = windows.first(where: { $0.isPrimary })?.resetAt {
            let rel = Formatters.relativeResetString(to: primaryReset)
            if !rel.isEmpty {
                paceParts.append(rel)
            }
        }

        return ParsedKimiUsage(
            plan: plan,
            windows: windows,
            paceNote: paceParts.isEmpty ? nil : paceParts.joined(separator: " · ")
        )
    }

    private static func buildWindow(
        id: String,
        label: String,
        dict: [String: Any],
        windowSeconds: Int?,
        isPrimary: Bool
    ) -> QuotaWindow? {
        let limit = parseDouble(dict["limit"] ?? dict["total"] ?? dict["quota"])
        let used = parseDouble(dict["used"] ?? dict["consumed"])
        let remaining = parseDouble(dict["remaining"] ?? dict["available"])
        let resetAt = parseDate(
            dict["resetTime"]
                ?? dict["reset_time"]
                ?? dict["resetAt"]
                ?? dict["reset_at"]
                ?? dict["resetsAt"]
                ?? dict["resets_at"]
        )

        let remainingFraction: Double
        let detailText: String?

        if let limit, limit > 0 {
            if let remaining {
                remainingFraction = min(max(remaining / limit, 0.0), 1.0)
                detailText = "剩余 \(formatQuantity(remaining)) / \(formatQuantity(limit))"
            } else if let used {
                let computedRemaining = max(limit - used, 0.0)
                remainingFraction = min(max(1.0 - (used / limit), 0.0), 1.0)
                detailText = "剩余 \(formatQuantity(computedRemaining)) / \(formatQuantity(limit))"
            } else {
                return nil
            }
        } else if let remaining, let used, (remaining + used) > 0 {
            let total = remaining + used
            remainingFraction = min(max(remaining / total, 0.0), 1.0)
            detailText = "剩余 \(formatQuantity(remaining)) / \(formatQuantity(total))"
        } else if let ratioUsed = parseDouble(dict["used_ratio"] ?? dict["usedRatio"]) {
            let clampedRatio = min(max(ratioUsed > 1.0 ? ratioUsed / 100.0 : ratioUsed, 0.0), 1.0)
            let clampedUsed = clampedRatio * 100.0
            remainingFraction = min(max(1.0 - clampedRatio, 0.0), 1.0)
            detailText = String(format: "已用 %.1f%%", clampedUsed)
        } else if let ratioRem = parseDouble(dict["remaining_ratio"] ?? dict["remainingRatio"]) {
            let clampedRem = min(max(ratioRem > 1.0 ? ratioRem / 100.0 : ratioRem, 0.0), 1.0)
            remainingFraction = clampedRem
            detailText = String(format: "剩余 %.0f%%", clampedRem * 100.0)
        } else if let pctRem = parseDouble(dict["remainingPercent"] ?? dict["remaining_percent"]) {
            let norm = pctRem > 1.0 ? pctRem / 100.0 : pctRem
            remainingFraction = min(max(norm, 0.0), 1.0)
            detailText = String(format: "剩余 %.0f%%", remainingFraction * 100.0)
        } else if let pctUsed = parseDouble(dict["usedPercent"] ?? dict["used_percent"]) {
            let clampedUsed = min(max(pctUsed > 1.0 ? pctUsed : pctUsed * 100.0, 0.0), 100.0)
            remainingFraction = min(max((100.0 - clampedUsed) / 100.0, 0.0), 1.0)
            detailText = String(format: "已用 %.1f%%", clampedUsed)
        } else {
            return nil
        }

        return QuotaWindow(
            id: id,
            label: label,
            remainingFraction: remainingFraction,
            usedPercent: (1.0 - remainingFraction) * 100.0,
            resetAt: resetAt,
            windowSeconds: windowSeconds,
            detail: detailText,
            isPrimary: isPrimary
        )
    }

    private static func parseWindowSeconds(from window: [String: Any]?) -> Int? {
        guard let window else { return nil }
        guard let duration = parseDouble(window["duration"]), duration > 0 else { return nil }
        let unit = (nonEmptyString(window["timeUnit"]) ?? nonEmptyString(window["time_unit"]) ?? "")
            .uppercased()

        let multiplier: Double
        if unit.contains("SECOND") || unit == "S" || unit == "SEC" {
            multiplier = 1
        } else if unit.contains("MINUTE") || unit == "M" || unit == "MIN" {
            multiplier = 60
        } else if unit.contains("HOUR") || unit == "H" || unit == "HR" {
            multiplier = 3600
        } else if unit.contains("DAY") || unit == "D" {
            multiplier = 86_400
        } else if unit.contains("WEEK") || unit == "W" {
            multiplier = 604_800
        } else if unit.contains("MONTH") || unit == "MO" {
            multiplier = 2_592_000
        } else {
            return nil
        }

        return Int((duration * multiplier).rounded())
    }

    private static func windowLabel(windowSeconds: Int?, explicitName: String?, index: Int) -> String {
        if let seconds = windowSeconds, seconds > 0 {
            if seconds >= 550_000 && seconds <= 660_000 {
                return "每周限额"
            }
            if seconds >= 80_000 && seconds <= 92_000 {
                return "每日限额"
            }
            if seconds % 86_400 == 0 && seconds >= 86_400 {
                return "\(seconds / 86_400)天限额"
            }
            if seconds % 3600 == 0 && seconds >= 3600 {
                return "\(seconds / 3600)小时限额"
            }
            if seconds >= 3600 {
                let hours = Int((Double(seconds) / 3600.0).rounded())
                return "\(hours)小时限额"
            }
            if seconds >= 60 {
                return "\(seconds / 60)分钟限额"
            }
            return "\(seconds)秒限额"
        }
        if let explicitName, !explicitName.isEmpty {
            return explicitName
        }
        return index == 0 ? "5小时限额" : "周期限额 #\(index + 1)"
    }

    private static func extractPlan(from payload: [String: Any]) -> PlanInfo? {
        let user = payload["user"] as? [String: Any]
        let membership = (user?["membership"] as? [String: Any])
            ?? (payload["membership"] as? [String: Any])
        let rawLevel = nonEmptyString(membership?["level"])
            ?? nonEmptyString(payload["plan"])
            ?? nonEmptyString(payload["tier"])

        guard let rawLevel else {
            return PlanInfo(kind: .api, displayName: "Kimi Code")
        }

        let upper = rawLevel.uppercased()
        switch upper {
        case "LEVEL_FREE", "FREE":
            return PlanInfo(kind: .free, displayName: "Free")
        case "LEVEL_BASIC", "BASIC", "LEVEL_ANDANTE":
            return PlanInfo(kind: .prolite, displayName: "Andante")
        case "LEVEL_INTERMEDIATE", "INTERMEDIATE", "LEVEL_MODERATO":
            return PlanInfo(kind: .pro, displayName: "Moderato")
        case "LEVEL_ADVANCED", "ADVANCED", "LEVEL_ALLEGRETTO":
            return PlanInfo(kind: .max, displayName: "Allegretto")
        case "LEVEL_PRO", "PRO", "LEVEL_ALLEGRO":
            return PlanInfo(kind: .ultra, displayName: "Allegro")
        default:
            let cleaned = upper.hasPrefix("LEVEL_")
                ? String(upper.dropFirst("LEVEL_".count)).capitalized
                : rawLevel
            return PlanInfo.normalized(kindRaw: cleaned, name: cleaned)
                ?? PlanInfo(kind: .api, displayName: cleaned)
        }
    }

    private static func extractRegion(from payload: [String: Any]) -> String? {
        guard let user = payload["user"] as? [String: Any],
              let region = nonEmptyString(user["region"]) else {
            return nil
        }
        switch region.uppercased() {
        case "REGION_CN", "CN": return "中国区"
        case "REGION_GLOBAL", "REGION_INTL", "GLOBAL", "INTL": return "国际区"
        default: return nil
        }
    }

    // MARK: - Primitive Parsing Helpers

    private static func formatQuantity(_ value: Double) -> String {
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
