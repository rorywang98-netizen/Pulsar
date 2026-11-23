import CommonCrypto
import Darwin
import Foundation
import LocalAuthentication
import Security
import SQLite3

// MARK: - Cursor Quota Provider

public final class CursorProvider: ProviderAdapter, @unchecked Sendable {
    public static let defaultAccountId = "cursor:live"
    public static let usageSummaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    public static let sandUsageStatusURL = URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status")!
    public static let unifiedUsageStatusURL = URL(string: "https://cursor.com/api/dashboard/v2/usage-status")!
    public static let fallbackUsageBaseURL = URL(string: "https://cursor.com/api/usage")!
    public static let safeStoragePrefix = "cursor-safe-storage:v1:"
    public static let safeStorageCacheService = "com.rory.roryorbit.cursor"
    public static let safeStorageCacheAccount = "safe-storage-key"
    public static let keychainDeniedNote = "需授权访问 Cursor 钥匙串或刷新浏览器会话"

    private static let safeStorageService = "Cursor Safe Storage"
    private static let safeStorageAccounts = ["Cursor Key", "Cursor"]
    private static let cliAccessTokenService = "cursor-access-token"
    private static let cliAccessTokenAccount = "cursor-user"
    /// Only copy state.vscdb to temp on lock failure when DB is small (real Cursor DB can exceed 2 GB).
    private static let maxTempCopyBytes: UInt64 = 32 * 1024 * 1024

    public let id: ProviderID = .cursor
    public let capabilities: ProviderCapability = [.quota]
    public let transportPolicy: TransportPolicy = .systemProxy
    public let isolatedStoreNamespace: String = "com.rory.roryorbit.cursor"

    public let keychain: KeychainStore
    public let stateDBURL: URL
    private let session: URLSession
    private let summaryURL: URL
    private let sandStatusURL: URL
    private let unifiedStatusURL: URL
    private let fallbackUsageURL: URL
    private let allowInteractiveKeychain: Bool

    private let cacheLock = NSLock()
    private var cachedSafeStoragePassword: String?
    private var cachedCLIAccessToken: String?
    private var keychainAccessDenied: Bool = false

    public init(
        keychain: KeychainStore = .shared,
        stateDBURL: URL? = nil,
        session: URLSession? = nil,
        summaryURL: URL = CursorProvider.usageSummaryURL,
        sandStatusURL: URL = CursorProvider.sandUsageStatusURL,
        unifiedStatusURL: URL = CursorProvider.unifiedUsageStatusURL,
        fallbackUsageURL: URL = CursorProvider.fallbackUsageBaseURL,
        allowInteractiveKeychain: Bool? = nil
    ) {
        self.keychain = keychain
        self.stateDBURL = stateDBURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Cursor", isDirectory: true)
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb", isDirectory: false)
        self.session = session ?? HTTPFactory.makeSession(policy: .systemProxy, timeout: 12.0)
        self.summaryURL = summaryURL
        self.sandStatusURL = sandStatusURL
        self.unifiedStatusURL = unifiedStatusURL
        self.fallbackUsageURL = fallbackUsageURL
        if let explicit = allowInteractiveKeychain {
            self.allowInteractiveKeychain = explicit
        } else {
            let isHeadlessCLI = CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
            self.allowInteractiveKeychain = !isHeadlessCLI
        }
    }

    public func resetKeychainFailureCache() {
        cacheLock.lock()
        keychainAccessDenied = false
        cachedSafeStoragePassword = nil
        cachedCLIAccessToken = nil
        cacheLock.unlock()
    }

    // MARK: - Local State Model

    public struct LocalCursorState: Equatable, Sendable {
        public let cachedEmail: String?
        public let displayName: String?
        public let membershipType: String?
        public let subscriptionStatus: String?
        public let authId: String?
        public let rawAccessToken: String?

        public var resolvedPlan: PlanInfo? {
            guard let membershipType = membershipType?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !membershipType.isEmpty else {
                return nil
            }
            return CursorProvider.normalizedPlan(from: membershipType)
        }

        public var fallbackUserId: String? {
            CursorProvider.extractUserId(fromSubject: authId)
        }
    }

    public struct ParsedUsageResult: Equatable, Sendable {
        public let plan: PlanInfo?
        public let windows: [QuotaWindow]
        public let balance: BalanceInfo?
        public let sourceLabel: String
        public let paceNote: String?

        public init(
            plan: PlanInfo?,
            windows: [QuotaWindow],
            balance: BalanceInfo? = nil,
            sourceLabel: String,
            paceNote: String?
        ) {
            self.plan = plan
            self.windows = windows
            self.balance = balance
            self.sourceLabel = sourceLabel
            self.paceNote = paceNote
        }
    }

    public struct ParsedSandUsage: Equatable, Sendable {
        public let window: QuotaWindow
    }

    public struct ParsedUnifiedUsage: Equatable, Sendable {
        public let window: QuotaWindow
        public let remainingUSD: Double
        public let usedUSD: Double
        public let limitUSD: Double
    }

    // MARK: - ProviderAdapter

    public func detectClientStatus() async -> ClientRuntimeStatus {
        let cliPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/cursor").path
        var status = ProcessController.shared.detectClientStatus(
            bundleIDs: ["com.todesktop.230313mzl4w4u92"],
            extraAppPaths: ["/Applications/Cursor.app"],
            detachedExecutableMatchers: []
        )
        if FileManager.default.fileExists(atPath: cliPath),
           !status.installedApps.contains("Cursor CLI") {
            status.installedApps.append("Cursor CLI")
        }
        return status
    }

    public func syncLiveAccount(registry: inout RegistryData) async -> String? {
        let existing = registry.accounts(for: .cursor).first { $0.id == Self.defaultAccountId }
            ?? registry.accounts(for: .cursor).first
        let accountId = existing?.id ?? Self.defaultAccountId

        if let state = readLocalState() {
            let email = state.cachedEmail ?? existing?.email ?? ""
            let displayName = state.displayName
                ?? (email.isEmpty ? (existing?.displayName ?? "Cursor") : email)
            let plan = state.resolvedPlan ?? existing?.plan
            let record = AccountRecord(
                id: accountId,
                provider: .cursor,
                email: email,
                displayName: displayName,
                plan: plan,
                addedAt: existing?.addedAt ?? Date(),
                isActiveLive: true
            )
            registry.upsertAccount(record)
            registry.setActiveLive(accountId: accountId, for: .cursor)
            return accountId
        }

        let fallbackRecord = AccountRecord(
            id: accountId,
            provider: .cursor,
            email: existing?.email ?? "",
            displayName: existing?.displayName ?? "Cursor",
            plan: existing?.plan,
            addedAt: existing?.addedAt ?? Date(),
            isActiveLive: true
        )
        registry.upsertAccount(fallbackRecord)
        registry.setActiveLive(accountId: accountId, for: .cursor)
        return accountId
    }

    public func fetchQuota(for account: AccountRecord, isActiveLive: Bool) async -> QuotaSnapshot {
        let localState = readLocalState()
        guard let state = localState else {
            return QuotaSnapshot.unconfigured(
                provider: .cursor,
                accountId: account.id,
                sourceLabel: "Cursor",
                message: "未检测到 Cursor 本地状态库，请先安装并登录 Cursor"
            )
        }

        let fallbackPlan = state.resolvedPlan ?? account.plan
        let profileNote = buildLocalProfileNote(state: state, fallbackPlan: fallbackPlan)

        guard let jwt = resolveAccessToken(from: state) else {
            return QuotaSnapshot(
                provider: .cursor,
                accountId: account.id,
                plan: fallbackPlan,
                windows: [],
                balance: nil,
                status: .reauthRequired(Self.keychainDeniedNote),
                sourceLabel: "Cursor 本地缓存",
                primaryRemainingPercent: nil,
                paceNote: profileNote
            )
        }

        guard let userId = resolveUserId(jwt: jwt, state: state) else {
            return QuotaSnapshot(
                provider: .cursor,
                accountId: account.id,
                plan: fallbackPlan,
                windows: [],
                balance: nil,
                status: .reauthRequired("无法识别 Cursor 用户标识，请重新登录 Cursor"),
                sourceLabel: "Cursor",
                primaryRemainingPercent: nil,
                paceNote: profileNote
            )
        }

        let cookieHeader = "WorkosCursorSessionToken=\(userId)%3A%3A\(jwt)"

        // Fetch primary usage-summary + enrichment endpoints concurrently over HTTP/2.
        async let summaryTask = fetchUsageSummary(cookieHeader: cookieHeader, fallbackPlan: fallbackPlan)
        async let sandTask = fetchSandUsageStatus(cookieHeader: cookieHeader)
        async let unifiedTask = fetchUnifiedUsageStatus(cookieHeader: cookieHeader)
        async let legacyTask = fetchLegacyUsage(userId: userId, cookieHeader: cookieHeader, fallbackPlan: fallbackPlan)

        let primaryOutcome = await summaryTask
        let sandUsage = await sandTask
        let unifiedUsage = await unifiedTask
        let legacyOutcome = await legacyTask

        let legacyParsed: ParsedUsageResult? = {
            if case .success(let parsed) = legacyOutcome { return parsed }
            return nil
        }()

        switch primaryOutcome {
        case .success(let summaryParsed):
            let merged = Self.mergeUsageResults(
                summary: summaryParsed,
                sand: sandUsage,
                unified: unifiedUsage,
                legacy: legacyParsed,
                fallbackPlan: fallbackPlan
            )
            return makeReadySnapshot(accountId: account.id, parsed: merged, fallbackPlan: fallbackPlan)

        case .authRequired:
            if let fallback = Self.mergeUsageResultsIfAny(
                sand: sandUsage,
                unified: unifiedUsage,
                legacy: legacyParsed,
                fallbackPlan: fallbackPlan
            ) {
                return makeReadySnapshot(accountId: account.id, parsed: fallback, fallbackPlan: fallbackPlan)
            }
            return QuotaSnapshot(
                provider: .cursor,
                accountId: account.id,
                plan: fallbackPlan,
                status: .reauthRequired("Cursor 会话已过期，请重新登录 Cursor"),
                sourceLabel: "Cursor API",
                paceNote: profileNote
            )

        case .failed(let primaryErr):
            if let fallback = Self.mergeUsageResultsIfAny(
                sand: sandUsage,
                unified: unifiedUsage,
                legacy: legacyParsed,
                fallbackPlan: fallbackPlan
            ) {
                return makeReadySnapshot(accountId: account.id, parsed: fallback, fallbackPlan: fallbackPlan)
            }
            if case .authRequired = legacyOutcome {
                return QuotaSnapshot(
                    provider: .cursor,
                    accountId: account.id,
                    plan: fallbackPlan,
                    status: .reauthRequired("Cursor 会话已过期，请重新登录 Cursor"),
                    sourceLabel: "Cursor API",
                    paceNote: profileNote
                )
            }
            let fallbackErr: String = {
                if case .failed(let msg) = legacyOutcome { return msg }
                return ""
            }()
            return QuotaSnapshot(
                provider: .cursor,
                accountId: account.id,
                plan: fallbackPlan,
                status: .failed(primaryErr.isEmpty ? fallbackErr : primaryErr),
                sourceLabel: "Cursor API",
                paceNote: profileNote
            )
        }
    }

    // MARK: - SQLite3 Read-Only State Reader (Never Locks Running Cursor)

    public func readLocalState() -> LocalCursorState? {
        guard FileManager.default.fileExists(atPath: stateDBURL.path) else {
            return nil
        }

        let rows: [String: String]
        if let direct = queryItemTable(path: stateDBURL.path, immutable: false) {
            rows = direct
        } else if let immutableRows = queryItemTable(path: stateDBURL.path, immutable: true) {
            rows = immutableRows
        } else if let copiedRows = queryItemTableViaTempCopy(sourceURL: stateDBURL) {
            rows = copiedRows
        } else {
            return nil
        }

        if rows.isEmpty {
            return nil
        }

        let cachedEmail = Self.nonEmptyString(rows["cursorAuth/cachedEmail"])
        let membershipType = Self.nonEmptyString(rows["cursorAuth/stripeMembershipType"])
        let subscriptionStatus = Self.nonEmptyString(rows["cursorAuth/stripeSubscriptionStatus"])
        let accessToken = Self.nonEmptyString(rows["cursorAuth/accessToken"])
        var authId = Self.nonEmptyString(rows["cursorAuth/stripeMembershipAuthId"])
        var displayName: String?

        if let profileRaw = Self.nonEmptyString(rows["cursorAuth/cachedScopedProfile"]),
           let profileData = profileRaw.data(using: .utf8),
           let profileObj = (try? JSONSerialization.jsonObject(with: profileData, options: [])) as? [String: Any] {
            displayName = Self.nonEmptyString(profileObj["displayName"])
            if authId == nil {
                authId = Self.nonEmptyString(profileObj["authId"])
            }
        }

        return LocalCursorState(
            cachedEmail: cachedEmail,
            displayName: displayName,
            membershipType: membershipType,
            subscriptionStatus: subscriptionStatus,
            authId: authId,
            rawAccessToken: accessToken
        )
    }

    private func queryItemTable(path: String, immutable: Bool) -> [String: String]? {
        let uri = Self.sqliteFileURI(path: path, immutable: immutable)
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let openRC = sqlite3_open_v2(uri, &db, flags, nil)
        guard openRC == SQLITE_OK, let handle = db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(handle) }

        if !immutable {
            sqlite3_busy_timeout(handle, 1500)
        }

        let targetKeys = [
            "cursorAuth/cachedEmail",
            "cursorAuth/stripeMembershipType",
            "cursorAuth/stripeSubscriptionStatus",
            "cursorAuth/accessToken",
            "cursorAuth/cachedScopedProfile",
            "cursorAuth/stripeMembershipAuthId",
        ]

        // Indexed PRIMARY KEY lookup (takes ~2ms even on multi-GB Cursor state.vscdb).
        let sql = "SELECT key, value FROM ItemTable WHERE key IN (?, ?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
            return nil
        }
        defer { sqlite3_finalize(prepared) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (idx, key) in targetKeys.enumerated() {
            sqlite3_bind_text(prepared, Int32(idx + 1), key, -1, transient)
        }

        var result: [String: String] = [:]
        while true {
            let stepRC = sqlite3_step(prepared)
            if stepRC == SQLITE_ROW {
                guard let keyC = sqlite3_column_text(prepared, 0) else { continue }
                let key = String(cString: keyC)
                let colType = sqlite3_column_type(prepared, 1)
                if colType == SQLITE_TEXT, let valC = sqlite3_column_text(prepared, 1) {
                    result[key] = String(cString: valC)
                } else if colType == SQLITE_BLOB, let blobPtr = sqlite3_column_blob(prepared, 1) {
                    let byteCount = Int(sqlite3_column_bytes(prepared, 1))
                    if byteCount > 0 {
                        let data = Data(bytes: blobPtr, count: byteCount)
                        if let str = String(data: data, encoding: .utf8) {
                            result[key] = str
                        }
                    }
                }
            } else if stepRC == SQLITE_DONE {
                return result
            } else {
                // SQLITE_BUSY / SQLITE_LOCKED / SQLITE_IOERR -> allow caller to fall back cleanly.
                return nil
            }
        }
    }

    private func queryItemTableViaTempCopy(sourceURL: URL) -> [String: String]? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.uint64Value ?? UInt64.max
        guard fileSize <= Self.maxTempCopyBytes else {
            return nil
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roryorbit-cursor-\(UUID().uuidString).vscdb", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: tempURL)
            return queryItemTable(path: tempURL.path, immutable: true)
        } catch {
            return nil
        }
    }

    private static func sqliteFileURI(path: String, immutable: Bool) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return immutable ? "file:\(encoded)?mode=ro&immutable=1" : "file:\(encoded)?mode=ro"
    }

    // MARK: - Token Resolution & Electron SafeStorage Decryption

    private func resolveAccessToken(from state: LocalCursorState) -> String? {
        if let rawToken = state.rawAccessToken {
            if rawToken.hasPrefix(Self.safeStoragePrefix) {
                // 1. In-memory cached SafeStorage master key (0ms)
                cacheLock.lock()
                let memPassword = cachedSafeStoragePassword
                cacheLock.unlock()
                if let memPassword {
                    if let decrypted = Self.decryptSafeStorageToken(rawToken, password: memPassword),
                       Self.looksLikeJWT(decrypted) {
                        return decrypted
                    }
                    cacheLock.lock()
                    cachedSafeStoragePassword = nil
                    cacheLock.unlock()
                }

                // 2. Persistent Pulsar KeychainStore cache (`com.rory.roryorbit.cursor` / `safe-storage-key`),
                //    backed by `/usr/bin/security` so it survives every ad-hoc RoryOrbit.app rebuild with zero UI prompts.
                let persistedPassword = readCachedSafeStorageKeyFromKeychainStore()
                if let persistedPassword,
                   let decrypted = Self.decryptSafeStorageToken(rawToken, password: persistedPassword),
                   Self.looksLikeJWT(decrypted) {
                    cacheLock.lock()
                    cachedSafeStoragePassword = persistedPassword
                    keychainAccessDenied = false
                    cacheLock.unlock()
                    return decrypted
                }

                // 3. Fallback: read Electron's `"Cursor Safe Storage"` item (respecting allowInteractiveKeychain),
                //    and upon successful decryption immediately persist it into Pulsar's KeychainStore.
                if let cursorPassword = readSafeStoragePasswordFromCursorKeychain(),
                   let decrypted = Self.decryptSafeStorageToken(rawToken, password: cursorPassword),
                   Self.looksLikeJWT(decrypted) {
                    if persistedPassword != cursorPassword {
                        persistSafeStorageKeyToKeychainStore(cursorPassword)
                    }
                    cacheLock.lock()
                    cachedSafeStoragePassword = cursorPassword
                    keychainAccessDenied = false
                    cacheLock.unlock()
                    return decrypted
                }
            } else if Self.looksLikeJWT(rawToken) {
                return rawToken
            }
        }

        // Secondary fallback: Cursor CLI keychain token (`cursor-access-token` / `cursor-user`), non-interactive only.
        if let cliToken = readCLIAccessTokenNonInteractive(), Self.looksLikeJWT(cliToken) {
            return cliToken
        }

        return nil
    }

    private func readCachedSafeStorageKeyFromKeychainStore() -> String? {
        guard let secret = try? keychain.readSecret(
            service: Self.safeStorageCacheService,
            account: Self.safeStorageCacheAccount
        ), !secret.isEmpty else {
            return nil
        }
        return secret
    }

    private func persistSafeStorageKeyToKeychainStore(_ password: String) {
        guard !password.isEmpty else { return }
        try? keychain.writeSecret(
            service: Self.safeStorageCacheService,
            account: Self.safeStorageCacheAccount,
            value: password
        )
    }

    private func readSafeStoragePasswordFromCursorKeychain() -> String? {
        cacheLock.lock()
        let wasDenied = keychainAccessDenied
        cacheLock.unlock()

        // Injectable non-CLI backend (e.g., InMemoryKeychainBackend in unit tests).
        if !(keychain.backend is SecurityCLIKeychainBackend) {
            for account in Self.safeStorageAccounts {
                if let pwd = try? keychain.readExternalGenericPassword(
                    service: Self.safeStorageService,
                    account: account
                ), !pwd.isEmpty {
                    return pwd
                }
            }
            cacheLock.lock()
            keychainAccessDenied = true
            cacheLock.unlock()
            return nil
        }

        // 1. Live macOS: ALWAYS try <1ms zero-prompt non-interactive Security.framework first,
        //    so background refreshes auto-recover if ACL is granted later (even after a prior denial).
        var blockedAccounts: [String] = []
        for account in Self.safeStorageAccounts {
            let status = readKeychainNonInteractive(service: Self.safeStorageService, account: account)
            switch status {
            case .found(let secret):
                return secret
            case .notFound:
                continue
            case .interactionRequiredOrDenied:
                blockedAccounts.append(account)
            }
        }

        // 2. If ACL requires user consent and interactive prompt is allowed (GUI app only, never CLI smoke,
        //    and only when not already denied this session unless reset by manual retry), prompt once via
        //    Security.framework strictly for the blocked account(s) so macOS attributes the ACL to RoryOrbit.app.
        if !wasDenied && allowInteractiveKeychain && !blockedAccounts.isEmpty {
            for account in blockedAccounts {
                if let pwd = readKeychainInteractive(service: Self.safeStorageService, account: account),
                   !pwd.isEmpty {
                    return pwd
                }
                // Denied or canceled — stop immediately and cache denial for this session.
                break
            }
        }

        if !blockedAccounts.isEmpty || wasDenied {
            cacheLock.lock()
            keychainAccessDenied = true
            cacheLock.unlock()
        }
        return nil
    }

    private func readCLIAccessTokenNonInteractive() -> String? {
        cacheLock.lock()
        if let cached = cachedCLIAccessToken {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        if !(keychain.backend is SecurityCLIKeychainBackend) {
            if let token = try? keychain.readExternalGenericPassword(
                service: Self.cliAccessTokenService,
                account: Self.cliAccessTokenAccount
            ), !token.isEmpty {
                cacheLock.lock()
                cachedCLIAccessToken = token
                cacheLock.unlock()
                return token
            }
            return nil
        }

        if case .found(let secret) = readKeychainNonInteractive(
            service: Self.cliAccessTokenService,
            account: Self.cliAccessTokenAccount
        ) {
            cacheLock.lock()
            cachedCLIAccessToken = secret
            cacheLock.unlock()
            return secret
        }
        return nil
    }

    private enum NonInteractiveKeychainResult {
        case found(String)
        case notFound
        case interactionRequiredOrDenied
    }

    private typealias SecKeychainGetUIAllowedFn = @convention(c) (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus
    private typealias SecKeychainSetUIAllowedFn = @convention(c) (DarwinBoolean) -> OSStatus
    private static let keychainUILock = NSLock()

    /// Temporarily disables legacy macOS Login Keychain ACL UI prompts (`SecKeychainSetUserInteractionAllowed(false)`)
    /// so non-interactive probes (`--smoke-quota`, background checks) return immediately instead of blocking on SecurityAgent.
    private static func withKeychainUserInteractionDisabled<T>(_ body: () -> T) -> T {
        keychainUILock.lock()
        defer { keychainUILock.unlock() }

        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        let getFn: SecKeychainGetUIAllowedFn? = dlsym(rtldDefault, "SecKeychainGetUserInteractionAllowed")
            .map { unsafeBitCast($0, to: SecKeychainGetUIAllowedFn.self) }
        let setFn: SecKeychainSetUIAllowedFn? = dlsym(rtldDefault, "SecKeychainSetUserInteractionAllowed")
            .map { unsafeBitCast($0, to: SecKeychainSetUIAllowedFn.self) }

        var prevAllowed: DarwinBoolean = true
        let hadPrev = (getFn?(&prevAllowed) == errSecSuccess)
        _ = setFn?(false)
        defer {
            _ = setFn?(hadPrev ? prevAllowed : true)
        }
        return body()
    }

    private func readKeychainNonInteractive(service: String, account: String) -> NonInteractiveKeychainResult {
        let authContext = LAContext()
        authContext.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authContext,
        ]
        var item: CFTypeRef?
        let status = Self.withKeychainUserInteractionDisabled {
            SecItemCopyMatching(query as CFDictionary, &item)
        }
        if status == errSecSuccess,
           let data = item as? Data,
           let secret = String(data: data, encoding: .utf8),
           !secret.isEmpty {
            return .found(secret)
        }
        if status == errSecItemNotFound {
            return .notFound
        }
        return .interactionRequiredOrDenied
    }

    private func readKeychainInteractive(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let secret = String(data: data, encoding: .utf8),
           !secret.isEmpty {
            return secret
        }
        return nil
    }

    /// Decrypts Electron macOS `safeStorage` payloads (`cursor-safe-storage:v1:<base64("v10" + AES-128-CBC)>`):
    /// PBKDF2-HMAC-SHA1(password, salt="saltysalt", 1003 iterations, 16-byte key) + AES-128-CBC(IV=16x0x20, PKCS7).
    public static func decryptSafeStorageToken(_ encryptedToken: String, password: String) -> String? {
        guard encryptedToken.hasPrefix(safeStoragePrefix) else {
            return nil
        }
        let b64Payload = String(encryptedToken.dropFirst(safeStoragePrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: b64Payload), raw.count > 3 else {
            return nil
        }

        let prefixBytes = Array(raw.prefix(3))
        let v10Prefix: [UInt8] = [0x76, 0x31, 0x30] // "v10"
        let v11Prefix: [UInt8] = [0x76, 0x31, 0x31] // "v11"
        guard prefixBytes == v10Prefix || prefixBytes == v11Prefix else {
            return nil
        }

        let ciphertext = Data(raw.dropFirst(3))
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else {
            return nil
        }

        guard let key = deriveSafeStorageKey(password: password) else {
            return nil
        }

        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var outBuf = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var decryptedLen: size_t = 0

        let status = ciphertext.withUnsafeBytes { cipherRaw -> CCCryptorStatus in
            guard let cipherBase = cipherRaw.baseAddress else {
                return CCCryptorStatus(kCCParamError)
            }
            return CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionPKCS7Padding),
                key,
                key.count,
                iv,
                cipherBase,
                ciphertext.count,
                &outBuf,
                outBuf.count,
                &decryptedLen
            )
        }

        guard status == kCCSuccess, decryptedLen > 0, decryptedLen <= outBuf.count else {
            return nil
        }

        let plainData = Data(outBuf[0..<decryptedLen])
        guard let text = String(data: plainData, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func deriveSafeStorageKey(password: String) -> [UInt8]? {
        let passwordBytes = Array(password.utf8)
        let saltBytes = Array("saltysalt".utf8)
        var derived = [UInt8](repeating: 0, count: kCCKeySizeAES128)

        let rc = passwordBytes.withUnsafeBytes { pwdRaw -> Int32 in
            let pwdPtr = pwdRaw.bindMemory(to: Int8.self).baseAddress
            return saltBytes.withUnsafeBytes { saltRaw -> Int32 in
                let saltPtr = saltRaw.bindMemory(to: UInt8.self).baseAddress
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwdPtr,
                    passwordBytes.count,
                    saltPtr,
                    saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    &derived,
                    derived.count
                )
            }
        }

        return rc == kCCSuccess ? derived : nil
    }

    public static func looksLikeJWT(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else {
            return false
        }
        return Formatters.decodeJWTPayload(token) != nil
    }

    public static func extractUserId(fromSubject subject: String?) -> String? {
        guard let raw = nonEmptyString(subject) else { return nil }
        if let pipe = raw.lastIndex(of: "|") {
            let after = String(raw[raw.index(after: pipe)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return after.isEmpty ? nil : after
        }
        return raw
    }

    private func resolveUserId(jwt: String, state: LocalCursorState) -> String? {
        if let claims = Formatters.decodeJWTPayload(jwt),
           let sub = claims["sub"] as? String,
           let extracted = Self.extractUserId(fromSubject: sub) {
            return extracted
        }
        return state.fallbackUserId
    }

    // MARK: - Cursor Usage API Requests

    private enum FetchOutcome {
        case success(ParsedUsageResult)
        case authRequired
        case failed(String)
    }

    private func makeCursorRequest(
        url: URL,
        method: String = "GET",
        cookieHeader: String,
        jsonBody: Data? = nil,
        timeout: TimeInterval = 12.0
    ) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        req.httpShouldHandleCookies = false
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        req.setValue("https://cursor.com/dashboard?tab=usage", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = jsonBody
        }
        return req
    }

    private func fetchUsageSummary(cookieHeader: String, fallbackPlan: PlanInfo?) async -> FetchOutcome {
        let req = makeCursorRequest(url: summaryURL, method: "GET", cookieHeader: cookieHeader, timeout: 12.0)

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Cursor 接口无有效响应")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .authRequired
            }
            guard (200...299).contains(http.statusCode) else {
                return .failed("Cursor 额度接口返回 HTTP \(http.statusCode)")
            }
            if let parsed = Self.parseUsageSummaryJSON(data, fallbackPlan: fallbackPlan, includeSubLanes: true) {
                return .success(parsed)
            }
            return .failed("无法解析 Cursor 用量摘要")
        } catch {
            return .failed("Cursor 网络请求失败: \(Self.sanitizedNetworkError(error))")
        }
    }

    private func fetchSandUsageStatus(cookieHeader: String) async -> ParsedSandUsage? {
        let req = makeCursorRequest(
            url: sandStatusURL,
            method: "POST",
            cookieHeader: cookieHeader,
            jsonBody: Data("{}".utf8),
            timeout: 8.0
        )

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return nil
            }
            return Self.parseSandUsageJSON(data)
        } catch {
            return nil
        }
    }

    private func fetchUnifiedUsageStatus(cookieHeader: String) async -> ParsedUnifiedUsage? {
        var comps = URLComponents(url: unifiedStatusURL, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "scope", value: "user")]
        guard let url = comps?.url else {
            return nil
        }
        let req = makeCursorRequest(url: url, method: "GET", cookieHeader: cookieHeader, timeout: 8.0)

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return nil
            }
            return Self.parseUnifiedUsageJSON(data)
        } catch {
            return nil
        }
    }

    private func fetchLegacyUsage(userId: String, cookieHeader: String, fallbackPlan: PlanInfo?) async -> FetchOutcome {
        var comps = URLComponents(url: fallbackUsageURL, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "user", value: userId)]
        guard let url = comps?.url else {
            return .failed("Cursor 备用接口 URL 构造失败")
        }

        let req = makeCursorRequest(url: url, method: "GET", cookieHeader: cookieHeader, timeout: 8.0)

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Cursor 备用接口无有效响应")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .authRequired
            }
            guard (200...299).contains(http.statusCode) else {
                return .failed("Cursor 备用接口返回 HTTP \(http.statusCode)")
            }
            if let parsed = Self.parseLegacyUsageJSON(data, fallbackPlan: fallbackPlan) {
                return .success(parsed)
            }
            return .failed("无法解析 Cursor 备用用量响应")
        } catch {
            return .failed("Cursor 备用网络请求失败: \(Self.sanitizedNetworkError(error))")
        }
    }

    // MARK: - Response Parsers

    public static func parseUsageSummaryJSON(
        _ data: Data,
        fallbackPlan: PlanInfo? = nil,
        includeSubLanes: Bool = false
    ) -> ParsedUsageResult? {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }

        let membershipRaw = nonEmptyString(root["membershipType"]) ?? nonEmptyString(root["membership_type"])
        let plan = membershipRaw.map { normalizedPlan(from: $0) } ?? fallbackPlan

        let cycleEnd = parseDate(root["billingCycleEnd"] ?? root["billing_cycle_end"])
        let cycleStart = parseDate(root["billingCycleStart"] ?? root["billing_cycle_start"])
        let cycleSeconds: Int? = {
            if let s = cycleStart, let e = cycleEnd, e > s {
                return Int(e.timeIntervalSince(s))
            }
            return 30 * 86_400
        }()

        var windows: [QuotaWindow] = []
        var paceNotes: [String] = []
        var planUsedCents: Double?
        var planLimitCents: Double?
        var planRemainingCents: Double?
        var planBonusCents: Double?
        var onDemandEnabled: Bool?
        var onDemandUsedCents: Double = 0.0
        var onDemandLimitCents: Double?

        if let individual = root["individualUsage"] as? [String: Any] {
            if let planUsage = individual["plan"] as? [String: Any] {
                let used = parseDouble(planUsage["used"])
                let limit = parseDouble(planUsage["limit"])
                let remaining = parseDouble(planUsage["remaining"])
                let totalPctUsed = parseDouble(planUsage["totalPercentUsed"])
                let autoPctUsed = parseDouble(planUsage["autoPercentUsed"])
                let apiPctUsed = parseDouble(planUsage["apiPercentUsed"])
                let breakdown = planUsage["breakdown"] as? [String: Any]
                let bonusCents = parseDouble(breakdown?["bonus"])

                planUsedCents = used
                planLimitCents = limit
                if let remaining {
                    planRemainingCents = max(remaining, 0.0)
                } else if let used, let limit, limit > 0 {
                    planRemainingCents = max(limit - used, 0.0)
                }
                if let bonusCents, bonusCents > 0 {
                    planBonusCents = bonusCents
                }

                var computedUsedPercent: Double?
                if let totalPctUsed {
                    computedUsedPercent = min(max(totalPctUsed, 0.0), 100.0)
                }
                if let limit, limit > 0 {
                    let ratioUsed: Double?
                    if let used {
                        ratioUsed = min(max((used / limit) * 100.0, 0.0), 100.0)
                    } else if let remaining {
                        ratioUsed = min(max(((limit - remaining) / limit) * 100.0, 0.0), 100.0)
                    } else {
                        ratioUsed = nil
                    }
                    if computedUsedPercent == nil || ((computedUsedPercent ?? 0) == 0 && (ratioUsed ?? 0) > 0) {
                        computedUsedPercent = ratioUsed
                    }
                }

                if let usedPct = computedUsedPercent {
                    let remainingFraction = min(max((100.0 - usedPct) / 100.0, 0.0), 1.0)
                    var detailParts: [String] = []
                    if includeSubLanes {
                        detailParts.append(String(format: "已用 %.1f%%", usedPct))
                        if let used, let limit, limit > 0 {
                            let rem = planRemainingCents ?? max(limit - used, 0.0)
                            detailParts.append("额度 \(formatCentsUSD(used)) / \(formatCentsUSD(limit))")
                            detailParts.append("剩余 \(formatCentsUSD(rem))")
                        }
                        if let bonusCents, bonusCents > 0 {
                            detailParts.append("赠金 \(formatCentsUSD(bonusCents))")
                        }
                    } else {
                        if let used, let limit, limit > 0 {
                            detailParts.append("\(formatCentsUSD(used)) / \(formatCentsUSD(limit))")
                        } else {
                            detailParts.append(String(format: "已用 %.1f%%", usedPct))
                        }
                        if let autoPctUsed, let apiPctUsed {
                            detailParts.append(String(format: "Auto %.0f%% · API %.0f%%", autoPctUsed, apiPctUsed))
                        }
                    }
                    windows.append(
                        QuotaWindow(
                            id: "cursor-plan",
                            label: includeSubLanes ? "套餐总览" : "套餐包含额度",
                            remainingFraction: remainingFraction,
                            usedPercent: usedPct,
                            resetAt: cycleEnd,
                            windowSeconds: cycleSeconds,
                            detail: detailParts.joined(separator: " · "),
                            isPrimary: true
                        )
                    )
                } else if (root["isUnlimited"] as? Bool) == true {
                    windows.append(
                        QuotaWindow(
                            id: "cursor-plan",
                            label: includeSubLanes ? "套餐总览" : "套餐包含额度",
                            remainingFraction: 1.0,
                            usedPercent: 0.0,
                            resetAt: cycleEnd,
                            windowSeconds: cycleSeconds,
                            detail: "无限额度",
                            isPrimary: true
                        )
                    )
                }

                // Separate Auto + Composer and API / Named Model lanes (matching CodexBar multi-lane view)
                if includeSubLanes {
                    if let autoPctUsed {
                        let clampedAuto = min(max(autoPctUsed, 0.0), 100.0)
                        let remFrac = min(max((100.0 - clampedAuto) / 100.0, 0.0), 1.0)
                        windows.append(
                            QuotaWindow(
                                id: "cursor-auto",
                                label: "Auto + Composer",
                                remainingFraction: remFrac,
                                usedPercent: clampedAuto,
                                resetAt: cycleEnd,
                                windowSeconds: cycleSeconds,
                                detail: String(format: "已用 %.1f%% · 自动路由与 Composer 通道", clampedAuto),
                                isPrimary: windows.isEmpty
                            )
                        )
                    }

                    if let apiPctUsed {
                        let clampedAPI = min(max(apiPctUsed, 0.0), 100.0)
                        let remFrac = min(max((100.0 - clampedAPI) / 100.0, 0.0), 1.0)
                        windows.append(
                            QuotaWindow(
                                id: "cursor-api",
                                label: "API / 指定模型",
                                remainingFraction: remFrac,
                                usedPercent: clampedAPI,
                                resetAt: cycleEnd,
                                windowSeconds: cycleSeconds,
                                detail: String(format: "已用 %.1f%% · 指定模型 API 通道", clampedAPI),
                                isPrimary: windows.isEmpty
                            )
                        )
                    }
                }
            }

            if includeSubLanes,
               let overall = individual["overall"] as? [String: Any],
               (overall["enabled"] as? Bool) ?? true,
               let limit = parseDouble(overall["limit"]),
               limit > 0 {
                let used = parseDouble(overall["used"]) ?? 0.0
                let rem = parseDouble(overall["remaining"]).map { max($0, 0.0) } ?? max(limit - used, 0.0)
                let duplicatesPlan = (planUsedCents == used && planLimitCents == limit)
                if !duplicatesPlan {
                    let usedPct = min(max((used / limit) * 100.0, 0.0), 100.0)
                    let remFrac = min(max(rem / limit, 0.0), 1.0)
                    windows.append(
                        QuotaWindow(
                            id: "cursor-overall",
                            label: "综合套餐额度",
                            remainingFraction: remFrac,
                            usedPercent: usedPct,
                            resetAt: cycleEnd,
                            windowSeconds: cycleSeconds,
                            detail: "已用 \(formatCentsUSD(used)) / \(formatCentsUSD(limit)) · 剩余 \(formatCentsUSD(rem))",
                            isPrimary: windows.isEmpty
                        )
                    )
                }
            }

            if let onDemand = individual["onDemand"] as? [String: Any] {
                let enabled = (onDemand["enabled"] as? Bool) ?? false
                let used = parseDouble(onDemand["used"]) ?? 0.0
                let limit = parseDouble(onDemand["limit"])
                onDemandEnabled = enabled
                onDemandUsedCents = used
                onDemandLimitCents = (limit ?? 0.0) > 0 ? limit : nil

                if enabled {
                    if let limit, limit > 0 {
                        let usedPct = min(max((used / limit) * 100.0, 0.0), 100.0)
                        let rem = parseDouble(onDemand["remaining"]).map { max($0, 0.0) } ?? max(limit - used, 0.0)
                        let remFrac = min(max(rem / limit, 0.0), 1.0)
                        let detail = includeSubLanes
                            ? "已用 \(formatCentsUSD(used)) / 上限 \(formatCentsUSD(limit)) · 剩余 \(formatCentsUSD(rem))"
                            : "\(formatCentsUSD(used)) / \(formatCentsUSD(limit))"
                        windows.append(
                            QuotaWindow(
                                id: "cursor-ondemand",
                                label: "按量付费额度",
                                remainingFraction: remFrac,
                                usedPercent: usedPct,
                                resetAt: cycleEnd,
                                windowSeconds: cycleSeconds,
                                detail: detail,
                                isPrimary: windows.isEmpty
                            )
                        )
                    } else if used > 0 {
                        paceNotes.append("按量已用 \(formatCentsUSD(used)) (无上限)")
                    } else if includeSubLanes {
                        paceNotes.append("按量付费: 已开启 ($0.00 / 无上限)")
                    }
                } else if includeSubLanes {
                    paceNotes.append("按量付费: 未开启 (\(formatCentsUSD(used)))")
                }
            }
        }

        if let teamUsage = root["teamUsage"] as? [String: Any] {
            if includeSubLanes,
               let pooled = teamUsage["pooled"] as? [String: Any],
               (pooled["enabled"] as? Bool) ?? true,
               let limit = parseDouble(pooled["limit"]),
               limit > 0 {
                let used = parseDouble(pooled["used"]) ?? 0.0
                let rem = parseDouble(pooled["remaining"]).map { max($0, 0.0) } ?? max(limit - used, 0.0)
                let usedPct = min(max((used / limit) * 100.0, 0.0), 100.0)
                windows.append(
                    QuotaWindow(
                        id: "cursor-team-pooled",
                        label: "团队共享池",
                        remainingFraction: min(max(rem / limit, 0.0), 1.0),
                        usedPercent: usedPct,
                        resetAt: cycleEnd,
                        windowSeconds: cycleSeconds,
                        detail: "已用 \(formatCentsUSD(used)) / \(formatCentsUSD(limit)) · 剩余 \(formatCentsUSD(rem))",
                        isPrimary: windows.isEmpty
                    )
                )
            }

            if (windows.isEmpty || includeSubLanes),
               let onDemand = teamUsage["onDemand"] as? [String: Any],
               (onDemand["enabled"] as? Bool) ?? true,
               let limit = parseDouble(onDemand["limit"]),
               limit > 0 {
                let used = parseDouble(onDemand["used"]) ?? 0.0
                let rem = parseDouble(onDemand["remaining"]).map { max($0, 0.0) } ?? max(limit - used, 0.0)
                let usedPct = min(max((used / limit) * 100.0, 0.0), 100.0)
                windows.append(
                    QuotaWindow(
                        id: "cursor-team-ondemand",
                        label: "团队按量额度",
                        remainingFraction: min(max(rem / limit, 0.0), 1.0),
                        usedPercent: usedPct,
                        resetAt: cycleEnd,
                        windowSeconds: cycleSeconds,
                        detail: includeSubLanes
                            ? "已用 \(formatCentsUSD(used)) / \(formatCentsUSD(limit)) · 剩余 \(formatCentsUSD(rem))"
                            : "\(formatCentsUSD(used)) / \(formatCentsUSD(limit))",
                        isPrimary: windows.isEmpty
                    )
                )
            }
        }

        guard !windows.isEmpty else {
            return nil
        }

        // Build supplementary USD credits / spend card when rich multi-lane mode is enabled.
        let balance: BalanceInfo? = {
            guard includeSubLanes else { return nil }
            if let limit = planLimitCents, limit > 0 {
                let used = planUsedCents ?? 0.0
                let rem = planRemainingCents ?? max(limit - used, 0.0)
                var parts: [String] = [
                    "套餐包含额度剩余",
                    "已用 \(formatCentsUSD(used)) / \(formatCentsUSD(limit))",
                ]
                if let onDemandEnabled {
                    if onDemandEnabled {
                        if let odLimit = onDemandLimitCents, odLimit > 0 {
                            parts.append("按量 \(formatCentsUSD(onDemandUsedCents)) / \(formatCentsUSD(odLimit))")
                        } else {
                            parts.append("按量已用 \(formatCentsUSD(onDemandUsedCents))")
                        }
                    } else {
                        parts.append("按量未开启")
                    }
                }
                return BalanceInfo(
                    currency: "USD",
                    totalBalance: rem / 100.0,
                    grantedBalance: planBonusCents.map { $0 / 100.0 },
                    toppedUpBalance: nil,
                    detail: parts.joined(separator: " · ")
                )
            }
            if onDemandEnabled == true, onDemandUsedCents > 0 {
                let capSuffix = onDemandLimitCents.map { " / 上限 \(formatCentsUSD($0))" } ?? " (无上限)"
                return BalanceInfo(
                    currency: "USD",
                    totalBalance: onDemandUsedCents / 100.0,
                    detail: "按量付费已消费 \(formatCentsUSD(onDemandUsedCents))\(capSuffix)"
                )
            }
            return nil
        }()

        if let cycleEnd {
            let rel = Formatters.relativeResetString(to: cycleEnd)
            let rangePrefix: String
            if includeSubLanes, let cycleStart {
                rangePrefix = "账单周期 \(formatMonthDay(cycleStart))–\(formatMonthDay(cycleEnd))"
            } else {
                rangePrefix = "账单周期"
            }
            if !rel.isEmpty {
                let text = includeSubLanes && cycleStart != nil
                    ? "\(rangePrefix) · \(rel)"
                    : "\(rangePrefix)\(rel)"
                paceNotes.insert(text, at: 0)
            } else if includeSubLanes, cycleStart != nil {
                paceNotes.insert(rangePrefix, at: 0)
            }
        }

        return ParsedUsageResult(
            plan: plan,
            windows: windows,
            balance: balance,
            sourceLabel: "Cursor API",
            paceNote: paceNotes.isEmpty ? nil : paceNotes.joined(separator: " · ")
        )
    }

    public static func parseSandUsageJSON(_ data: Data) -> ParsedSandUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }

        if (root["includedLimitZero"] as? Bool) == true {
            return nil
        }
        if let hasNonZero = root["hasNonZeroIncludedLimit"] as? Bool, !hasNonZero {
            return nil
        }
        guard let rawPct = parseDouble(root["usagePercent"]) else {
            return nil
        }

        let usedPct = min(max(rawPct, 0.0), 100.0)
        let remFrac = min(max((100.0 - usedPct) / 100.0, 0.0), 1.0)
        let periodStart = parseDate(root["currentPeriodStart"])
        let nextReset = parseDate(root["nextResetTimestampUtc"])
        let windowSeconds: Int = {
            if let s = periodStart, let e = nextReset, e > s {
                return Int(e.timeIntervalSince(s))
            }
            return 7 * 86_400
        }()

        var detailParts: [String] = [String(format: "已用 %.1f%%", usedPct)]
        if let planLabel = nonEmptyString(root["grokPlanLabel"]) {
            detailParts.append(planLabel)
        } else {
            detailParts.append("周周期额度")
        }
        if let trialEnd = parseDate(root["sandTrialExpiresAt"]), trialEnd > Date() {
            detailParts.append("试用到期 \(formatMonthDay(trialEnd))")
        }

        let window = QuotaWindow(
            id: "cursor-grok-bot",
            label: "Grok Bot",
            remainingFraction: remFrac,
            usedPercent: usedPct,
            resetAt: nextReset,
            windowSeconds: windowSeconds,
            detail: detailParts.joined(separator: " · "),
            isPrimary: false
        )
        return ParsedSandUsage(window: window)
    }

    public static func parseUnifiedUsageJSON(_ data: Data) -> ParsedUnifiedUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }
        if let availability = nonEmptyString(root["availability"])?.lowercased(),
           availability != "available" {
            return nil
        }
        guard let monthly = root["monthlyUsage"] as? [String: Any],
              let limitCents = parseDouble(monthly["limitCents"]),
              limitCents > 0 else {
            return nil
        }
        let usedCents = max(parseDouble(monthly["usedCents"]) ?? 0.0, 0.0)
        let remainingCents = max(limitCents - usedCents, 0.0)
        let usedPct = min(max((usedCents / limitCents) * 100.0, 0.0), 100.0)
        let remFrac = min(max(remainingCents / limitCents, 0.0), 1.0)
        let periodStart = parseDate(monthly["periodStart"])
        let resetsAt = parseDate(monthly["resetsAt"])
        let windowSeconds: Int = {
            if let s = periodStart, let e = resetsAt, e > s {
                return Int(e.timeIntervalSince(s))
            }
            return 30 * 86_400
        }()

        let window = QuotaWindow(
            id: "cursor-unified",
            label: "统一套餐月度额度",
            remainingFraction: remFrac,
            usedPercent: usedPct,
            resetAt: resetsAt,
            windowSeconds: windowSeconds,
            detail: "已用 \(formatCentsUSD(usedCents)) / \(formatCentsUSD(limitCents)) · 剩余 \(formatCentsUSD(remainingCents))",
            isPrimary: false
        )
        return ParsedUnifiedUsage(
            window: window,
            remainingUSD: remainingCents / 100.0,
            usedUSD: usedCents / 100.0,
            limitUSD: limitCents / 100.0
        )
    }

    public static func mergeUsageResults(
        summary: ParsedUsageResult,
        sand: ParsedSandUsage?,
        unified: ParsedUnifiedUsage?,
        legacy: ParsedUsageResult?,
        fallbackPlan: PlanInfo?
    ) -> ParsedUsageResult {
        var windows = summary.windows
        var balance = summary.balance

        if let unified {
            var unifiedWin = unified.window
            if windows.isEmpty {
                unifiedWin.isPrimary = true
            }
            if !windows.contains(where: { $0.id == unifiedWin.id }) {
                windows.append(unifiedWin)
            }
            if balance == nil && unified.limitUSD > 0 {
                balance = BalanceInfo(
                    currency: "USD",
                    totalBalance: unified.remainingUSD,
                    detail: "统一套餐月度剩余 · 已用 \(Formatters.currencyString(amount: unified.usedUSD, currency: "USD")) / \(Formatters.currencyString(amount: unified.limitUSD, currency: "USD"))"
                )
            }
        }

        if let sand {
            var sandWin = sand.window
            if windows.isEmpty {
                sandWin.isPrimary = true
            }
            if !windows.contains(where: { $0.id == sandWin.id }) {
                windows.append(sandWin)
            }
        }

        if let legacy {
            for var legacyWin in legacy.windows where !windows.contains(where: { $0.id == legacyWin.id }) {
                legacyWin.isPrimary = windows.isEmpty
                windows.append(legacyWin)
            }
        }

        return ParsedUsageResult(
            plan: summary.plan ?? fallbackPlan,
            windows: windows,
            balance: balance,
            sourceLabel: summary.sourceLabel,
            paceNote: summary.paceNote
        )
    }

    private static func mergeUsageResultsIfAny(
        sand: ParsedSandUsage?,
        unified: ParsedUnifiedUsage?,
        legacy: ParsedUsageResult?,
        fallbackPlan: PlanInfo?
    ) -> ParsedUsageResult? {
        var windows: [QuotaWindow] = []
        var balance: BalanceInfo?
        var paceNote: String?
        var sourceLabel = "Cursor API"

        if let unified {
            var w = unified.window
            w.isPrimary = true
            windows.append(w)
            balance = BalanceInfo(
                currency: "USD",
                totalBalance: unified.remainingUSD,
                detail: "统一套餐月度剩余 · 已用 \(Formatters.currencyString(amount: unified.usedUSD, currency: "USD")) / \(Formatters.currencyString(amount: unified.limitUSD, currency: "USD"))"
            )
            if let resetAt = w.resetAt {
                let rel = Formatters.relativeResetString(to: resetAt)
                if !rel.isEmpty { paceNote = "账单周期\(rel)" }
            }
        }

        if let legacy {
            for var w in legacy.windows {
                w.isPrimary = windows.isEmpty
                windows.append(w)
            }
            if paceNote == nil { paceNote = legacy.paceNote }
            if unified == nil { sourceLabel = legacy.sourceLabel }
        }

        if let sand {
            var w = sand.window
            w.isPrimary = windows.isEmpty
            windows.append(w)
        }

        guard !windows.isEmpty else {
            return nil
        }

        return ParsedUsageResult(
            plan: legacy?.plan ?? fallbackPlan,
            windows: windows,
            balance: balance,
            sourceLabel: sourceLabel,
            paceNote: paceNote
        )
    }

    public static func parseLegacyUsageJSON(_ data: Data, fallbackPlan: PlanInfo? = nil) -> ParsedUsageResult? {
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }

        let startOfMonth = parseDate(root["startOfMonth"])
        let resetAt = startOfMonth.flatMap { Calendar.current.date(byAdding: .month, value: 1, to: $0) }

        let preferredModels = ["gpt-4", "gpt-4-32k", "gpt-3.5-turbo"]
        var chosen: (name: String, used: Double, limit: Double)?

        for key in preferredModels {
            if let entry = root[key] as? [String: Any],
               let limit = parseDouble(entry["maxRequestUsage"]),
               limit > 0 {
                let used = parseDouble(entry["numRequests"]) ?? parseDouble(entry["numRequestsTotal"]) ?? 0.0
                chosen = (key, used, limit)
                break
            }
        }

        if chosen == nil {
            for (key, value) in root {
                if let entry = value as? [String: Any],
                   let limit = parseDouble(entry["maxRequestUsage"]),
                   limit > 0 {
                    let used = parseDouble(entry["numRequests"]) ?? parseDouble(entry["numRequestsTotal"]) ?? 0.0
                    chosen = (key, used, limit)
                    break
                }
            }
        }

        guard let match = chosen else {
            return nil
        }

        let usedPct = min(max((match.used / match.limit) * 100.0, 0.0), 100.0)
        let remFrac = min(max((match.limit - match.used) / match.limit, 0.0), 1.0)
        let window = QuotaWindow(
            id: "cursor-legacy-requests",
            label: "月度快速请求",
            remainingFraction: remFrac,
            usedPercent: usedPct,
            resetAt: resetAt,
            windowSeconds: 30 * 86_400,
            detail: "\(Int(match.used)) / \(Int(match.limit)) 次 (\(match.name))",
            isPrimary: true
        )

        return ParsedUsageResult(
            plan: fallbackPlan,
            windows: [window],
            balance: nil,
            sourceLabel: "Cursor Usage API",
            paceNote: resetAt.map { Formatters.relativeResetString(to: $0) }
        )
    }

    // MARK: - Formatting & Helpers

    private func makeReadySnapshot(
        accountId: String,
        parsed: ParsedUsageResult,
        fallbackPlan: PlanInfo?
    ) -> QuotaSnapshot {
        let primary = parsed.windows.first(where: { $0.isPrimary }) ?? parsed.windows.first
        return QuotaSnapshot(
            provider: .cursor,
            accountId: accountId,
            plan: parsed.plan ?? fallbackPlan,
            windows: parsed.windows,
            balance: parsed.balance,
            status: .ready(fetchedAt: Date(), stale: false),
            sourceLabel: parsed.sourceLabel,
            primaryRemainingPercent: primary?.remainingPercent,
            paceNote: parsed.paceNote
        )
    }

    private static func formatMonthDay(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.month, .day], from: date)
        guard let m = comps.month, let d = comps.day else {
            return ""
        }
        return String(format: "%02d/%02d", m, d)
    }

    private func buildLocalProfileNote(state: LocalCursorState, fallbackPlan: PlanInfo?) -> String? {
        var parts: [String] = []
        if let email = state.cachedEmail, !email.isEmpty {
            parts.append(email)
        }
        if let plan = fallbackPlan {
            if let subStatus = state.subscriptionStatus, !subStatus.isEmpty {
                parts.append("\(plan.displayName) (\(subStatus))")
            } else {
                parts.append(plan.displayName)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func normalizedPlan(from raw: String) -> PlanInfo {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()
        switch lower {
        case "ultra":
            return PlanInfo(kind: .ultra, displayName: "Ultra")
        case "pro_plus", "proplus", "pro+":
            return PlanInfo(kind: .pro, displayName: "Pro+")
        case "pro":
            return PlanInfo(kind: .pro, displayName: "Pro")
        case "business", "team":
            return PlanInfo(kind: .business, displayName: "Business")
        case "enterprise":
            return PlanInfo(kind: .enterprise, displayName: "Enterprise")
        case "free", "free_trial":
            return PlanInfo(kind: .free, displayName: lower == "free_trial" ? "Free Trial" : "Free")
        default:
            return PlanInfo.normalized(kindRaw: cleaned, name: cleaned.capitalized)
                ?? PlanInfo(kind: .unknown, displayName: cleaned)
        }
    }

    private static func formatCentsUSD(_ cents: Double) -> String {
        Formatters.currencyString(amount: cents / 100.0, currency: "USD")
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
