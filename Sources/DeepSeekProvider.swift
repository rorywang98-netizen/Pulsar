import Foundation

// MARK: - DeepSeek Balance Provider

public final class DeepSeekProvider: ProviderAdapter, @unchecked Sendable {
    public static let defaultAccountId = "deepseek:api"
    public static let keychainAccount = "deepseek"
    public static let defaultBalanceURL = URL(string: "https://api.deepseek.com/user/balance")!

    public let id: ProviderID = .deepseek
    public let capabilities: ProviderCapability = [.quota, .apiKeyConfig]
    public let transportPolicy: TransportPolicy = .systemProxy
    public let isolatedStoreNamespace: String = "com.rory.roryorbit.deepseek"

    public let keychain: KeychainStore
    private let session: URLSession
    private let balanceURL: URL

    public init(
        keychain: KeychainStore = .shared,
        session: URLSession? = nil,
        balanceURL: URL = DeepSeekProvider.defaultBalanceURL
    ) {
        self.keychain = keychain
        self.session = session ?? HTTPFactory.makeSession(policy: .systemProxy, timeout: 20.0)
        self.balanceURL = balanceURL
    }

    // MARK: - Parsed Balance Model

    public struct ParsedBalanceResponse: Equatable, Sendable {
        public let isAvailable: Bool
        public let primaryBalance: BalanceInfo
        public let allBalances: [BalanceInfo]
    }

    // MARK: - ProviderAdapter

    public func detectClientStatus() async -> ClientRuntimeStatus {
        let cliPaths = [
            "/usr/local/bin/dsh",
            "/opt/homebrew/bin/dsh",
        ]
        var status = ProcessController.shared.detectClientStatus(
            bundleIDs: ["com.deepseek.dsh"],
            extraAppPaths: ["/Applications/DeepSeek Harness.app"],
            detachedExecutableMatchers: [
                { path in
                    cliPaths.contains(path) || path.hasSuffix("/bin/dsh")
                }
            ]
        )
        if cliPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }),
           !status.installedApps.contains("DeepSeek CLI (dsh)") {
            status.installedApps.append("DeepSeek CLI (dsh)")
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
            throw ProviderAdapterError.invalidCredential("请输入有效的 DeepSeek API Key")
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
        let existing = registry.accounts(for: .deepseek).first { $0.id == Self.defaultAccountId }
            ?? registry.accounts(for: .deepseek).first
        let accountId = existing?.id ?? Self.defaultAccountId
        let displayName = existing?.displayName.isEmpty == false ? existing!.displayName : "DeepSeek API"
        let email = existing?.email.isEmpty == false ? existing!.email : displayName

        let record = AccountRecord(
            id: accountId,
            provider: .deepseek,
            email: email,
            displayName: displayName,
            plan: existing?.plan ?? PlanInfo(kind: .api, displayName: "API"),
            addedAt: existing?.addedAt ?? Date(),
            isActiveLive: true
        )
        registry.upsertAccount(record)
        registry.setActiveLive(accountId: accountId, for: .deepseek)
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
                    provider: .deepseek,
                    accountId: account.id,
                    sourceLabel: "DeepSeek API",
                    message: "未配置 DeepSeek API Key，请在设置中填入"
                )
            }
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return QuotaSnapshot.unconfigured(
                    provider: .deepseek,
                    accountId: account.id,
                    sourceLabel: "DeepSeek API",
                    message: "未配置 DeepSeek API Key，请在设置中填入"
                )
            }
            apiKey = trimmed
        } catch {
            return QuotaSnapshot.failed(
                provider: .deepseek,
                accountId: account.id,
                sourceLabel: "DeepSeek API",
                message: "读取 DeepSeek Keychain 凭证失败"
            )
        }

        var req = URLRequest(url: balanceURL)
        req.httpMethod = "GET"
        req.httpShouldHandleCookies = false
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("RoryOrbit/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return QuotaSnapshot.failed(
                    provider: .deepseek,
                    accountId: account.id,
                    sourceLabel: "DeepSeek API",
                    message: "DeepSeek 接口无有效响应"
                )
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return QuotaSnapshot.reauthRequired(
                    provider: .deepseek,
                    accountId: account.id,
                    sourceLabel: "DeepSeek API",
                    message: "DeepSeek API Key 无效或已失效，请在设置中更新"
                )
            }
            guard (200...299).contains(http.statusCode) else {
                return QuotaSnapshot.failed(
                    provider: .deepseek,
                    accountId: account.id,
                    sourceLabel: "DeepSeek API",
                    message: "DeepSeek 余额接口返回 HTTP \(http.statusCode)"
                )
            }
            guard let parsed = Self.parseBalanceJSON(data) else {
                return QuotaSnapshot.failed(
                    provider: .deepseek,
                    accountId: account.id,
                    sourceLabel: "DeepSeek API",
                    message: "无法解析 DeepSeek 余额响应"
                )
            }

            let availabilityText = parsed.isAvailable ? "余额可用" : "余额不可用，请充值"
            let plan = PlanInfo(kind: .api, displayName: parsed.isAvailable ? "API · 可用" : "API · 欠费")

            return QuotaSnapshot(
                provider: .deepseek,
                accountId: account.id,
                plan: plan,
                windows: [],
                balance: parsed.primaryBalance,
                status: .ready(fetchedAt: Date(), stale: false),
                sourceLabel: "DeepSeek API",
                primaryRemainingPercent: nil,
                paceNote: availabilityText
            )
        } catch {
            return QuotaSnapshot.failed(
                provider: .deepseek,
                accountId: account.id,
                sourceLabel: "DeepSeek API",
                message: "DeepSeek 网络请求失败: \(Self.sanitizedNetworkError(error))"
            )
        }
    }

    // MARK: - Balance JSON Parser

    public static func parseBalanceJSON(_ data: Data) -> ParsedBalanceResponse? {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }

        let isAvailable: Bool = {
            if let b = root["is_available"] as? Bool { return b }
            if let n = root["is_available"] as? NSNumber { return n.boolValue }
            return false
        }()

        let rawInfos = (root["balance_infos"] as? [[String: Any]]) ?? []
        var parsedBalances: [BalanceInfo] = []
        for item in rawInfos {
            let currency = (item["currency"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() ?? "CNY"
            guard let total = parseDouble(item["total_balance"]) else { continue }
            let granted = parseDouble(item["granted_balance"])
            let toppedUp = parseDouble(item["topped_up_balance"])
            parsedBalances.append(
                BalanceInfo(
                    currency: currency.isEmpty ? "CNY" : currency,
                    totalBalance: total,
                    grantedBalance: granted,
                    toppedUpBalance: toppedUp,
                    detail: nil
                )
            )
        }

        if parsedBalances.isEmpty {
            let emptyInfo = BalanceInfo(
                currency: "CNY",
                totalBalance: 0.0,
                grantedBalance: 0.0,
                toppedUpBalance: 0.0,
                detail: isAvailable ? "余额可用" : "暂无可用余额"
            )
            return ParsedBalanceResponse(
                isAvailable: isAvailable,
                primaryBalance: emptyInfo,
                allBalances: [emptyInfo]
            )
        }

        let primaryIndex = selectPrimaryCurrencyIndex(in: parsedBalances)
        var primary = parsedBalances[primaryIndex]

        var detailParts: [String] = []
        if let toppedUp = primary.toppedUpBalance {
            detailParts.append("充值 \(Formatters.currencyString(amount: toppedUp, currency: primary.currency))")
        }
        if let granted = primary.grantedBalance, granted > 0.0001 {
            detailParts.append("赠金 \(Formatters.currencyString(amount: granted, currency: primary.currency))")
        }

        // Append secondary non-zero currencies if account holds both CNY and USD.
        let secondaryParts: [String] = parsedBalances.enumerated().compactMap { idx, info in
            guard idx != primaryIndex, info.totalBalance > 0.0001 else { return nil }
            return info.formattedTotal
        }
        if !secondaryParts.isEmpty {
            detailParts.append("另有 \(secondaryParts.joined(separator: " / "))")
        }

        detailParts.append(isAvailable ? "可用" : "不可用")
        primary.detail = detailParts.joined(separator: " · ")

        return ParsedBalanceResponse(
            isAvailable: isAvailable,
            primaryBalance: primary,
            allBalances: parsedBalances
        )
    }

    private static func selectPrimaryCurrencyIndex(in balances: [BalanceInfo]) -> Int {
        // 1. Prefer CNY with positive balance, then USD with positive balance, then any positive balance.
        if let idx = balances.firstIndex(where: { $0.currency == "CNY" && $0.totalBalance > 0 }) {
            return idx
        }
        if let idx = balances.firstIndex(where: { $0.currency == "USD" && $0.totalBalance > 0 }) {
            return idx
        }
        if let idx = balances.firstIndex(where: { $0.totalBalance > 0 }) {
            return idx
        }
        // 2. If all zero, prefer CNY then USD then first.
        if let idx = balances.firstIndex(where: { $0.currency == "CNY" }) {
            return idx
        }
        if let idx = balances.firstIndex(where: { $0.currency == "USD" }) {
            return idx
        }
        return 0
    }

    // MARK: - Helpers

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
