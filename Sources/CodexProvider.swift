import Darwin
import Foundation

/// Multi-account switcher, usage quota provider, isolated login runner, and safe client controller
/// for OpenAI Codex CLI & ChatGPT Desktop (`com.openai.codex`).
public final class CodexProvider: ProviderAdapter, @unchecked Sendable {

    // MARK: - ProviderAdapter Properties

    public let id: ProviderID = .codex
    public let capabilities: ProviderCapability = [.quota, .accountSwitch, .clientControl]
    public let transportPolicy: TransportPolicy = .systemProxy
    public let isolatedStoreNamespace: String = KeychainStore.roryOrbitCodexService

    // MARK: - Constants

    public static let desktopBundleId = "com.openai.codex"
    public static let desktopBundleIDs = [desktopBundleId]
    public static let externalKeychainService = "Codex Auth"
    public static let oauthClientId = "app_EMoamEEZ73f0CkXaXp7hrann"

    private static let whamUsageURL = "https://chatgpt.com/backend-api/wham/usage"
    private static let whamResetCreditsURL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
    private static let oauthTokenURL = "https://auth.openai.com/oauth/token"

    // MARK: - Storage Mode & Config Snapshot

    public enum StorageMode: Equatable, Sendable {
        case file
        case keyring
        case auto
        case unsupported(String)
    }

    public struct ConfigSnapshot: Equatable, Sendable {
        public let storageMode: StorageMode
        public let modelProvider: String
        public let secretAuthStorage: Bool

        public init(
            storageMode: StorageMode = .file,
            modelProvider: String = "openai",
            secretAuthStorage: Bool = false
        ) {
            self.storageMode = storageMode
            self.modelProvider = modelProvider
            self.secretAuthStorage = secretAuthStorage
        }
    }

    // MARK: - Dependencies

    public let keychain: KeychainStore
    public let processController: ProcessController
    public let environment: [String: String]
    public let homeDirectoryURL: URL
    public let desktopAppURL: URL

    private let session: URLSession
    private let refreshGate = CodexRefreshGate()

    // MARK: - Initializers

    public convenience init(
        keychain: KeychainStore = .shared,
        processController: ProcessController = .shared
    ) {
        self.init(
            keychain: keychain,
            processController: processController,
            environment: ProcessInfo.processInfo.environment,
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            desktopAppURL: URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true),
            session: nil
        )
    }

    public init(
        keychain: KeychainStore,
        processController: ProcessController,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        desktopAppURL: URL = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true),
        session: URLSession? = nil
    ) {
        self.keychain = keychain
        self.processController = processController
        self.environment = environment
        self.homeDirectoryURL = homeDirectoryURL
        self.desktopAppURL = desktopAppURL
        self.session = session ?? HTTPFactory.makeSession(policy: .systemProxy, timeout: 20.0)
    }

    // MARK: - CODEX_HOME & `config.toml`

    public var defaultCodexHomeURL: URL {
        homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true)
    }

    public var codexHomeURL: URL {
        if let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            if raw == "~" {
                return homeDirectoryURL
            }
            if raw.hasPrefix("~/") {
                return homeDirectoryURL.appendingPathComponent(String(raw.dropFirst(2)), isDirectory: true)
            }
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return defaultCodexHomeURL
    }

    public var authFileURL: URL {
        codexHomeURL.appendingPathComponent("auth.json", isDirectory: false)
    }

    public var configTOMLURL: URL {
        codexHomeURL.appendingPathComponent("config.toml", isDirectory: false)
    }

    public var canonicalKeychainAccount: String {
        Formatters.canonicalCodexKeychainAccount(codexHomePath: codexHomeURL.path)
    }

    public func readConfigSnapshot() -> ConfigSnapshot {
        guard let data = try? Data(contentsOf: configTOMLURL),
              let content = String(data: data, encoding: .utf8) else {
            return ConfigSnapshot()
        }
        return Self.parseConfigTOML(content)
    }

    /// Parses relevant top-level keys (`cli_auth_credentials_store`, `model_provider`) and
    /// `[features].secret_auth_storage` from `~/.codex/config.toml`.
    public static func parseConfigTOML(_ content: String) -> ConfigSnapshot {
        var currentSection = ""
        var rawStore: String?
        var rawModelProvider: String?
        var secretAuthStorage = false

        for rawLine in content.components(separatedBy: .newlines) {
            let line = stripTOMLComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                let inner = line.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
                // Handle [[array_of_tables]] gracefully by stripping extra brackets.
                let cleaned = inner.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                currentSection = cleaned.lowercased()
                continue
            }

            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eqIdx]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valRaw = String(line[line.index(after: eqIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            if currentSection.isEmpty {
                if key == "cli_auth_credentials_store" {
                    rawStore = unquoteTOMLString(valRaw)
                } else if key == "model_provider" {
                    rawModelProvider = unquoteTOMLString(valRaw)
                }
            } else if currentSection == "features" {
                if key == "secret_auth_storage" {
                    secretAuthStorage = (valRaw.lowercased() == "true")
                }
            }
        }

        let storageMode: StorageMode
        if let rawStore {
            switch rawStore.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "", "file":
                storageMode = .file
            case "keyring":
                storageMode = .keyring
            case "auto":
                storageMode = .auto
            default:
                storageMode = .unsupported(rawStore)
            }
        } else {
            storageMode = .file
        }

        let modelProvider = rawModelProvider
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "openai"

        return ConfigSnapshot(
            storageMode: storageMode,
            modelProvider: modelProvider,
            secretAuthStorage: secretAuthStorage
        )
    }

    private static func stripTOMLComment(_ line: String) -> String {
        var inDouble = false
        var inSingle = false
        var escaped = false
        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            if escaped {
                escaped = false
            } else if ch == "\\" && inDouble {
                escaped = true
            } else if ch == "\"" && !inSingle {
                inDouble.toggle()
            } else if ch == "'" && !inDouble {
                inSingle.toggle()
            } else if ch == "#" && !inDouble && !inSingle {
                return String(line[..<idx])
            }
            idx = line.index(after: idx)
        }
        return line
    }

    private static func unquoteTOMLString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2) ||
            (trimmed.hasPrefix("'") && trimmed.hasSuffix("'") && trimmed.count >= 2) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    /// Pre-switch safety guard checks (fail closed on env overrides, custom model_provider, mismatched CODEX_HOME, or unsupported storage).
    public func validatePreSwitchSafety() -> String? {
        if let apiKey = environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !apiKey.isEmpty, apiKey != "0" {
            return "检测到环境变量 OPENAI_API_KEY，当前环境被 API Key 覆盖，已中止账号切换"
        }
        if let accessToken = environment["CODEX_ACCESS_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accessToken.isEmpty, accessToken != "0" {
            return "检测到环境变量 CODEX_ACCESS_TOKEN，已中止账号切换"
        }

        let cfg = readConfigSnapshot()
        if cfg.modelProvider.lowercased() != "openai" {
            return "检测到 ~/.codex/config.toml 中顶层 model_provider=\"\(cfg.modelProvider)\"（非 openai），已中止切换以防破坏自定义配置"
        }

        switch cfg.storageMode {
        case .unsupported(let raw):
            return "不支持的 cli_auth_credentials_store=\"\(raw)\" 存储模式，已中止切换"
        case .keyring, .auto:
            if cfg.secretAuthStorage {
                return "检测到 features.secret_auth_storage=true 与非文件存储模式组合，已中止切换"
            }
        case .file:
            break
        }

        let canonicalCurrentHome = codexHomeURL.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalDefaultHome = defaultCodexHomeURL.standardizedFileURL.resolvingSymlinksInPath().path
        if canonicalCurrentHome != canonicalDefaultHome {
            let desktopInstalled = !processController.inspector.installedAppURLs(
                bundleIDs: Self.desktopBundleIDs,
                extraPaths: [desktopAppURL.path]
            ).isEmpty
            if desktopInstalled {
                return "检测到自定义 CODEX_HOME 与 ChatGPT 桌面端默认目录 (~/.codex) 不一致，已中止切换"
            }
        }

        return nil
    }

    // MARK: - Process Discovery (Desktop + Bundled CLI + Homebrew CLI + Managed App-Server Daemon)

    private func detachedExecutableMatchers() -> [(String) -> Bool] {
        let bundledCLIPath = desktopAppURL
            .appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
            .standardizedFileURL.path
        let legacyBundledCLIPath = desktopAppURL
            .appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
            .standardizedFileURL.path
        let daemonPrefix = codexHomeURL
            .appendingPathComponent("packages/app-server-daemon", isDirectory: true)
            .standardizedFileURL.path + "/"
        let defaultDaemonPrefix = defaultCodexHomeURL
            .appendingPathComponent("packages/app-server-daemon", isDirectory: true)
            .standardizedFileURL.path + "/"

        return [
            { execPath in
                let std = URL(fileURLWithPath: execPath).standardizedFileURL.path
                let base = URL(fileURLWithPath: std).lastPathComponent

                // Exact binary name check (`codex`) — NEVER matches `CodexBar`!
                if std == bundledCLIPath || std == legacyBundledCLIPath {
                    return true
                }
                if (std.hasPrefix(daemonPrefix) || std.hasPrefix(defaultDaemonPrefix)) && base == "codex" {
                    return true
                }
                if std == "/opt/homebrew/bin/codex" || std == "/usr/local/bin/codex" {
                    return true
                }
                if base == "codex" &&
                    (std.contains("/codex") || std.contains("/homebrew/") || std.contains("/Cellar/") ||
                        std.contains("/.nvm/") || std.contains("/.fnm/") || std.contains("/.volta/") ||
                        std.contains("/.local/bin/") || std.contains("/packages/app-server-daemon/")) {
                    return true
                }
                return false
            },
        ]
    }

    public func detectClientStatus() async -> ClientRuntimeStatus {
        processController.detectClientStatus(
            bundleIDs: Self.desktopBundleIDs,
            extraAppPaths: [desktopAppURL.path],
            detachedExecutableMatchers: detachedExecutableMatchers()
        )
    }

    // MARK: - Live Credential I/O (`file` / `keyring` / `auto`)

    private struct StoredCodexCredential {
        let rawData: Data
        let rootObject: [String: Any]
        let tokens: [String: Any]
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let identity: CodexAuthIdentity
    }

    private struct LiveBackupSnapshot {
        let storageMode: StorageMode
        let fileData: Data?
        let keychainValue: String?
    }

    private func parseCodexCredential(from rawData: Data) -> StoredCodexCredential? {
        guard let canonicalData = Formatters.extractCanonicalCodexAuthData(from: rawData),
              let rootObj = (try? JSONSerialization.jsonObject(with: canonicalData, options: [])) as? [String: Any],
              let tokens = rootObj["tokens"] as? [String: Any],
              let accessToken = nonEmpty(tokens["access_token"] as? String),
              let identity = Formatters.extractCodexAuthIdentity(from: rootObj) else {
            return nil
        }

        return StoredCodexCredential(
            rawData: canonicalData,
            rootObject: rootObj,
            tokens: tokens,
            accessToken: accessToken,
            refreshToken: nonEmpty(tokens["refresh_token"] as? String),
            idToken: nonEmpty(tokens["id_token"] as? String),
            identity: identity
        )
    }

    private func readLiveCredential() -> StoredCodexCredential? {
        let cfg = readConfigSnapshot()
        let readFromFile: () -> StoredCodexCredential? = {
            guard let data = try? Data(contentsOf: self.authFileURL) else { return nil }
            return self.parseCodexCredential(from: data)
        }
        let readFromKeyring: () -> StoredCodexCredential? = {
            guard let rawStr = try? self.keychain.readExternalGenericPassword(
                service: Self.externalKeychainService,
                account: self.canonicalKeychainAccount
            ), let data = rawStr.data(using: .utf8) else {
                return nil
            }
            return self.parseCodexCredential(from: data)
        }

        switch cfg.storageMode {
        case .file:
            return readFromFile()
        case .keyring:
            return readFromKeyring()
        case .auto:
            return readFromKeyring() ?? readFromFile()
        case .unsupported:
            return nil
        }
    }

    private func snapshotLiveForRollback(storageMode: StorageMode) -> LiveBackupSnapshot {
        let fileData = try? Data(contentsOf: authFileURL)
        let kcVal = try? keychain.readExternalGenericPassword(
            service: Self.externalKeychainService,
            account: canonicalKeychainAccount
        )
        return LiveBackupSnapshot(storageMode: storageMode, fileData: fileData, keychainValue: kcVal)
    }

    private func writeLiveCredential(data: Data, storageMode: StorageMode) throws {
        switch storageMode {
        case .file:
            try KeychainStore.ensureDirectory(at: codexHomeURL, mode: 0o700)
            try KeychainStore.writeAtomicFile(data: data, to: authFileURL, mode: 0o600)
        case .keyring, .auto:
            guard let jsonStr = String(data: data, encoding: .utf8) else {
                throw ProviderAdapterError.invalidCredential("无法将 Codex auth.json 编码为 UTF-8")
            }
            try keychain.writeExternalGenericPassword(
                service: Self.externalKeychainService,
                account: canonicalKeychainAccount,
                value: jsonStr
            )
            // Per Codex keyring contract: remove auth.json file so keyring is the single source of truth.
            if FileManager.default.fileExists(atPath: authFileURL.path) {
                try? FileManager.default.removeItem(at: authFileURL)
            }
        case .unsupported(let raw):
            throw ProviderAdapterError.operationFailed("不支持的存储模式: \(raw)")
        }
    }

    private func rollbackLiveCredential(_ backup: LiveBackupSnapshot) {
        if let prevFile = backup.fileData {
            try? KeychainStore.ensureDirectory(at: codexHomeURL, mode: 0o700)
            try? KeychainStore.writeAtomicFile(data: prevFile, to: authFileURL, mode: 0o600)
        } else if backup.storageMode == .file {
            try? FileManager.default.removeItem(at: authFileURL)
        }

        if let prevKC = backup.keychainValue {
            try? keychain.writeExternalGenericPassword(
                service: Self.externalKeychainService,
                account: canonicalKeychainAccount,
                value: prevKC
            )
        } else if backup.storageMode == .keyring || backup.storageMode == .auto {
            try? keychain.deleteExternalGenericPassword(
                service: Self.externalKeychainService,
                account: canonicalKeychainAccount
            )
        }
    }

    private func readVaultCredential(accountId: String) throws -> StoredCodexCredential? {
        guard let data = try keychain.readChunkedSecret(
            service: isolatedStoreNamespace,
            account: accountId
        ) else {
            return nil
        }
        return parseCodexCredential(from: data)
    }

    private func saveVaultCredential(accountId: String, data: Data) throws {
        try keychain.writeChunkedSecret(
            service: isolatedStoreNamespace,
            account: accountId,
            data: data
        )
    }

    // MARK: - Live Account Sync & Import

    public func syncLiveAccount(registry: inout RegistryData) async -> String? {
        guard let live = readLiveCredential() else {
            registry.setActiveLive(accountId: nil, for: .codex)
            return nil
        }

        let ident = live.identity
        if var existing = registry.accounts(for: .codex).first(where: { $0.id == ident.canonicalAccountId }) {
            if existing.email.isEmpty && !ident.email.isEmpty { existing.email = ident.email }
            if existing.displayName.isEmpty && !ident.displayName.isEmpty { existing.displayName = ident.displayName }
            if existing.plan == nil { existing.plan = ident.plan }
            existing.isActiveLive = true
            registry.upsertAccount(existing)
        } else {
            registry.upsertAccount(
                AccountRecord(
                    id: ident.canonicalAccountId,
                    provider: .codex,
                    email: ident.email,
                    displayName: ident.displayName,
                    plan: ident.plan,
                    addedAt: Date(),
                    isActiveLive: true
                )
            )
        }

        registry.setActiveLive(accountId: ident.canonicalAccountId, for: .codex)
        return ident.canonicalAccountId
    }

    public func importLiveAccount() async throws -> AccountRecord {
        guard let live = readLiveCredential() else {
            throw ProviderAdapterError.invalidCredential("未检测到本机 Codex 登录凭证，请先运行 codex login 或登录 ChatGPT 桌面端")
        }

        let ident = live.identity
        try saveVaultCredential(accountId: ident.canonicalAccountId, data: live.rawData)

        return AccountRecord(
            id: ident.canonicalAccountId,
            provider: .codex,
            email: ident.email,
            displayName: ident.displayName,
            plan: ident.plan,
            addedAt: Date(),
            isActiveLive: true
        )
    }

    // MARK: - Isolated Add-Account Login (`CODEX_HOME=<0700-tmp> codex login`)

    public func addAccount() async throws -> AccountRecord {
        guard let codexBin = resolveCodexCLIBinary() else {
            throw ProviderAdapterError.operationFailed("未找到 codex 可执行文件，请先安装 Codex CLI 或 ChatGPT 桌面端")
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roryorbit-codex-login-\(UUID().uuidString)", isDirectory: true)
        try KeychainStore.ensureDirectory(at: tmpDir, mode: 0o700)
        defer {
            try? FileManager.default.removeItem(at: tmpDir)
        }

        var childEnv = environment
        childEnv.removeValue(forKey: "OPENAI_API_KEY")
        childEnv.removeValue(forKey: "CODEX_ACCESS_TOKEN")
        childEnv["CODEX_HOME"] = tmpDir.path
        childEnv["PATH"] = buildEnrichedPATH(existing: childEnv["PATH"])

        let exitCode = try await runIsolatedCodexLogin(
            binaryURL: codexBin,
            environment: childEnv,
            timeoutSeconds: 300
        )
        guard exitCode == 0 else {
            throw ProviderAdapterError.authenticationRequired("Codex 登录未完成或被取消 (exit=\(exitCode))")
        }

        let tmpAuthURL = tmpDir.appendingPathComponent("auth.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: tmpAuthURL.path),
              let rawData = try? Data(contentsOf: tmpAuthURL),
              let parsed = parseCodexCredential(from: rawData) else {
            throw ProviderAdapterError.invalidCredential("Codex 登录完成但未生成有效的 auth.json 凭证")
        }

        try saveVaultCredential(accountId: parsed.identity.canonicalAccountId, data: parsed.rawData)

        return AccountRecord(
            id: parsed.identity.canonicalAccountId,
            provider: .codex,
            email: parsed.identity.email,
            displayName: parsed.identity.displayName,
            plan: parsed.identity.plan,
            addedAt: Date(),
            isActiveLive: false
        )
    }

    private func resolveCodexCLIBinary() -> URL? {
        let fm = FileManager.default
        let fixedCandidates = [
            desktopAppURL
                .appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
                .path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            homeDirectoryURL.appendingPathComponent(".local/bin/codex").path,
        ]
        for path in fixedCandidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let enriched = buildEnrichedPATH(existing: environment["PATH"])
        for dir in enriched.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir), isDirectory: true)
                .appendingPathComponent("codex", isDirectory: false).path
            if fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    private func buildEnrichedPATH(existing: String?) -> String {
        let home = homeDirectoryURL.path
        var segments: [String] = []
        if let existing, !existing.isEmpty {
            segments.append(contentsOf: existing.split(separator: ":").map(String.init))
        }
        let extra = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.volta/bin",
            "\(home)/.fnm/current/bin",
            "/usr/bin",
            "/bin",
        ]
        var seen = Set<String>()
        var merged: [String] = []
        for s in segments + extra where !s.isEmpty && seen.insert(s).inserted {
            merged.append(s)
        }
        return merged.joined(separator: ":")
    }

    private func runIsolatedCodexLogin(
        binaryURL: URL,
        environment: [String: String],
        timeoutSeconds: TimeInterval
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = binaryURL
                proc.arguments = ["login", "-c", "cli_auth_credentials_store=\"file\""]
                proc.environment = environment
                // Never echo stdout/stderr (prevents accidental secret leaks).
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                proc.standardInput = FileHandle.nullDevice

                do {
                    try proc.run()
                } catch {
                    continuation.resume(throwing: ProviderAdapterError.operationFailed("启动 codex login 失败"))
                    return
                }

                let deadline = Date().addingTimeInterval(timeoutSeconds)
                while proc.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.2)
                }

                if proc.isRunning {
                    proc.terminate()
                    let graceDeadline = Date().addingTimeInterval(2.0)
                    while proc.isRunning && Date() < graceDeadline {
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    continuation.resume(throwing: ProviderAdapterError.operationFailed("Codex 登录超时（5 分钟）"))
                    return
                }

                continuation.resume(returning: proc.terminationStatus)
            }
        }
    }

    // MARK: - Quota Pipeline (`wham/usage` + `wham/rate-limit-reset-credits` + Strict Refresh Ownership)

    public func fetchQuota(for account: AccountRecord, isActiveLive: Bool) async -> QuotaSnapshot {
        // Re-check live identity to guarantee we NEVER consume the live account's single-use refresh token!
        let liveCred = readLiveCredential()
        let effectivelyLive = isActiveLive || (liveCred?.identity.canonicalAccountId == account.id)

        if effectivelyLive {
            return await fetchLiveAccountQuotaReadOnly(account: account, liveCred: liveCred)
        }

        return await fetchInactiveVaultAccountQuota(account: account)
    }

    /// Strict read-only quota fetch for the currently active live Codex account (ZERO `/oauth/token` refresh calls).
    private func fetchLiveAccountQuotaReadOnly(
        account: AccountRecord,
        liveCred: StoredCodexCredential?
    ) async -> QuotaSnapshot {
        let cred: StoredCodexCredential?
        if let liveCred, liveCred.identity.canonicalAccountId == account.id {
            cred = liveCred
        } else {
            cred = try? readVaultCredential(accountId: account.id)
        }

        guard let cred else {
            return .unconfigured(
                provider: .codex,
                accountId: account.id,
                sourceLabel: "Live（只读）",
                message: "未找到当前 Codex 账号凭证"
            )
        }

        if Self.isJWTExpired(cred.accessToken, marginSeconds: 15) {
            return .reauthRequired(
                provider: .codex,
                accountId: account.id,
                sourceLabel: "Live（只读）",
                message: "当前活跃账号令牌已过期，请通过 Codex 客户端自动刷新或重新登录（已保护单次 Refresh Token）"
            )
        }

        let usageRes = await requestWhamUsage(credential: cred)
        switch usageRes {
        case .success(let parsed):
            let creditsNote = await fetchOptionalResetCredits(credential: cred)
            return buildQuotaSnapshot(
                account: account,
                parsed: parsed,
                resetCredits: creditsNote,
                sourceLabel: "Live（只读）"
            )
        case .unauthorized:
            return .reauthRequired(
                provider: .codex,
                accountId: account.id,
                sourceLabel: "Live（只读）",
                message: "当前活跃账号令牌已失效 (HTTP 401)，请通过 Codex 客户端刷新（未消耗 Refresh Token）"
            )
        case .failed(let msg):
            return .failed(
                provider: .codex,
                accountId: account.id,
                sourceLabel: "Live（只读）",
                message: msg
            )
        }
    }

    /// Inactive vaulted account quota fetch: may refresh expired token AFTER re-verifying it is not live,
    /// persisting rotated refresh_token to Keychain immediately BEFORE any next request.
    private func fetchInactiveVaultAccountQuota(account: AccountRecord) async -> QuotaSnapshot {
        guard var cred = (try? readVaultCredential(accountId: account.id)) else {
            return .unconfigured(
                provider: .codex,
                accountId: account.id,
                sourceLabel: "Vault",
                message: "钥匙串中未找到该 Codex 账号凭证"
            )
        }

        if Self.isJWTExpired(cred.accessToken, marginSeconds: 60) {
            switch await refreshInactiveCredentialSafely(accountId: account.id, current: cred) {
            case .refreshed(let updated):
                cred = updated
            case .becameLive(let liveCred):
                return await fetchLiveAccountQuotaReadOnly(account: account, liveCred: liveCred)
            case .reauthRequired(let msg):
                return .reauthRequired(provider: .codex, accountId: account.id, sourceLabel: "Vault", message: msg)
            case .failed(let msg):
                return .failed(provider: .codex, accountId: account.id, sourceLabel: "Vault", message: msg)
            }
        }

        var usageRes = await requestWhamUsage(credential: cred)
        if case .unauthorized = usageRes {
            switch await refreshInactiveCredentialSafely(accountId: account.id, current: cred) {
            case .refreshed(let updated):
                cred = updated
                usageRes = await requestWhamUsage(credential: cred)
            case .becameLive(let liveCred):
                return await fetchLiveAccountQuotaReadOnly(account: account, liveCred: liveCred)
            case .reauthRequired(let msg):
                return .reauthRequired(provider: .codex, accountId: account.id, sourceLabel: "Vault", message: msg)
            case .failed(let msg):
                return .failed(provider: .codex, accountId: account.id, sourceLabel: "Vault", message: msg)
            }
        }

        switch usageRes {
        case .success(let parsed):
            let creditsNote = await fetchOptionalResetCredits(credential: cred)
            return buildQuotaSnapshot(
                account: account,
                parsed: parsed,
                resetCredits: creditsNote,
                sourceLabel: "Vault"
            )
        case .unauthorized:
            return .reauthRequired(
                provider: .codex,
                accountId: account.id,
                sourceLabel: "Vault",
                message: "Codex 凭证已失效 (HTTP 401)，请重新登录该账号"
            )
        case .failed(let msg):
            return .failed(
                provider: .codex,
                accountId: account.id,
                sourceLabel: "Vault",
                message: msg
            )
        }
    }

    // MARK: - Single-Use Refresh Token Rotation (Serialized & Live-Ownership Guarded)

    private enum RefreshOutcome {
        case refreshed(StoredCodexCredential)
        case becameLive(StoredCodexCredential)
        case reauthRequired(String)
        case failed(String)
    }

    private func refreshInactiveCredentialSafely(
        accountId: String,
        current: StoredCodexCredential
    ) async -> RefreshOutcome {
        await refreshGate.withLock(accountId: accountId) {
            await AccountPoolExporter.withCrossProcessRefreshLock {
                await self.performLockedInactiveRefresh(accountId: accountId, current: current)
            }
        }
    }

    private func performLockedInactiveRefresh(
        accountId: String,
        current: StoredCodexCredential
    ) async -> RefreshOutcome {
        // Re-read live identity IMMEDIATELY before touching `/oauth/token`!
        if let live = self.readLiveCredential(), live.identity.canonicalAccountId == accountId {
            return .becameLive(live)
        }

        // Re-read vault in case a concurrent caller (in-process or cross-process) just refreshed & persisted a fresh token.
        let latest = (try? self.readVaultCredential(accountId: accountId)) ?? current
        if !Self.isJWTExpired(latest.accessToken, marginSeconds: 60),
           latest.accessToken != current.accessToken {
            return .refreshed(latest)
        }

        guard let refreshToken = latest.refreshToken, !refreshToken.isEmpty else {
            return .reauthRequired("缺少 Refresh Token，请重新添加该 Codex 账号")
        }

        let payload: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": Self.oauthClientId,
            "refresh_token": refreshToken,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return .failed("构造 OpenAI 刷新请求失败")
        }

        var req = URLRequest(url: URL(string: Self.oauthTokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = bodyData

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await self.session.data(for: req)
        } catch {
            return .failed("刷新 Codex 令牌网络错误: \(error.localizedDescription)")
        }

        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] ?? [:]

        if !(200...299).contains(status) {
            if Self.isReauthRefreshError(json: obj, statusCode: status) {
                return .reauthRequired("Codex Refresh Token 已失效或已被轮换，请重新添加账号")
            }
            return .failed("刷新 Codex 令牌失败 (HTTP \(status))")
        }

        guard let newAccess = self.nonEmpty(obj["access_token"] as? String) else {
            return .failed("OpenAI 刷新响应缺少 access_token")
        }

        var updatedRoot = latest.rootObject
        var updatedTokens = latest.tokens
        updatedTokens["access_token"] = newAccess
        if let rotatedRefresh = self.nonEmpty(obj["refresh_token"] as? String) {
            updatedTokens["refresh_token"] = rotatedRefresh
        }
        if let rotatedIdToken = self.nonEmpty(obj["id_token"] as? String) {
            updatedTokens["id_token"] = rotatedIdToken
        }
        updatedRoot["tokens"] = updatedTokens
        updatedRoot["last_refresh"] = Formatters.formatRFC3339UTC(Date())

        guard let updatedData = try? JSONSerialization.data(
            withJSONObject: updatedRoot,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ), let updatedCred = self.parseCodexCredential(from: updatedData) else {
            return .failed("序列化刷新后的 Codex 凭证失败")
        }

        // CRITICAL: Persist rotated single-use refresh token to Keychain IMMEDIATELY before ANY next request!
        do {
            try self.saveVaultCredential(accountId: accountId, data: updatedCred.rawData)
        } catch {
            return .failed("保存轮换后的 Codex 凭证失败: \(error.localizedDescription)")
        }

        return .refreshed(updatedCred)
    }

    private static func isReauthRefreshError(json: [String: Any], statusCode: Int) -> Bool {
        let reauthTokens = [
            "invalid_grant",
            "refresh_token_reused",
            "refresh_token_expired",
            "refresh_token_invalidated",
        ]
        var fields: [String] = []
        if let errStr = json["error"] as? String {
            fields.append(errStr.lowercased())
        } else if let errObj = json["error"] as? [String: Any] {
            if let code = errObj["code"] as? String { fields.append(code.lowercased()) }
            if let type = errObj["type"] as? String { fields.append(type.lowercased()) }
            if let msg = errObj["message"] as? String { fields.append(msg.lowercased()) }
        }
        if let desc = json["error_description"] as? String {
            fields.append(desc.lowercased())
        }
        for field in fields {
            for token in reauthTokens where field.contains(token) {
                return true
            }
        }
        return statusCode == 401
    }

    public static func isJWTExpired(_ jwt: String, marginSeconds: TimeInterval = 60, now: Date = Date()) -> Bool {
        guard let payload = Formatters.decodeJWTPayload(jwt),
              let expNum = payload["exp"] as? NSNumber else {
            return false
        }
        let expDate = Date(timeIntervalSince1970: expNum.doubleValue)
        return expDate <= now.addingTimeInterval(marginSeconds)
    }

    // MARK: - `wham/usage` & `wham/rate-limit-reset-credits` HTTP & Parsing

    /// Structured non-secret credit & reset-credit metadata preserved across `0` values for AccountPool export.
    public struct CodexCreditMetadata: Codable, Equatable, Sendable {
        public let creditsRemaining: Double?
        public let creditsReadSucceeded: Bool?
        public let resetCreditsAvailable: Int?
        public let updatedAt: Date

        public init(
            creditsRemaining: Double?,
            creditsReadSucceeded: Bool?,
            resetCreditsAvailable: Int?,
            updatedAt: Date = Date()
        ) {
            self.creditsRemaining = creditsRemaining
            self.creditsReadSucceeded = creditsReadSucceeded
            self.resetCreditsAvailable = resetCreditsAvailable
            self.updatedAt = updatedAt
        }
    }

    private static let creditMetadataLock = NSLock()
    private static var creditMetadataCache: [String: CodexCreditMetadata] = [:]

    public static func latestCreditMetadata(for accountId: String) -> CodexCreditMetadata? {
        creditMetadataLock.lock()
        defer { creditMetadataLock.unlock() }
        return creditMetadataCache[accountId]
    }

    public static func recordCreditMetadata(_ metadata: CodexCreditMetadata, for accountId: String) {
        creditMetadataLock.lock()
        defer { creditMetadataLock.unlock() }
        creditMetadataCache[accountId] = metadata
    }

    public struct ParsedWhamUsage: Equatable, Sendable {
        public let plan: PlanInfo?
        public let windows: [QuotaWindow]
        public let balance: BalanceInfo?
        public let paceNote: String?
        public let creditsRemaining: Double?
        public let creditsReadSucceeded: Bool?

        public init(
            plan: PlanInfo?,
            windows: [QuotaWindow],
            balance: BalanceInfo?,
            paceNote: String?,
            creditsRemaining: Double? = nil,
            creditsReadSucceeded: Bool? = nil
        ) {
            self.plan = plan
            self.windows = windows
            self.balance = balance
            self.paceNote = paceNote
            self.creditsRemaining = creditsRemaining
            self.creditsReadSucceeded = creditsReadSucceeded
        }
    }

    private struct ParsedResetCredits {
        let balance: BalanceInfo?
        let creditsRemaining: Double?
        let availableCount: Int?
        let note: String?
    }

    private enum WhamUsageResult {
        case success(ParsedWhamUsage)
        case unauthorized
        case failed(String)
    }

    private func requestWhamUsage(credential: StoredCodexCredential) async -> WhamUsageResult {
        var req = URLRequest(url: URL(string: Self.whamUsageURL)!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(credential.identity.chatgptAccountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("codex-cli/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            return .failed("请求 Codex 额度失败: \(error.localizedDescription)")
        }

        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            return .unauthorized
        }
        guard (200...299).contains(status) else {
            return .failed("Codex 额度接口返回 HTTP \(status)")
        }

        guard let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return .failed("解析 Codex 额度响应 JSON 失败")
        }

        // Strict identity verification (`account_id` and optional `user_id`).
        if let respAccountId = nonEmpty(json["account_id"] as? String),
           respAccountId != credential.identity.chatgptAccountId {
            return .failed("Codex 响应 account_id 与当前账号不匹配，已拒绝错配数据")
        }
        if let respUserId = nonEmpty(json["user_id"] as? String),
           respUserId != credential.identity.userId {
            return .failed("Codex 响应 user_id 与当前账号不匹配，已拒绝错配数据")
        }

        let parsed = Self.parseWhamUsageJSON(json, fallbackPlan: credential.identity.plan)
        return .success(parsed)
    }

    private func fetchOptionalResetCredits(credential: StoredCodexCredential) async -> ParsedResetCredits? {
        var req = URLRequest(url: URL(string: Self.whamResetCreditsURL)!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(credential.identity.chatgptAccountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("codex-cli/1.0", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }

        let creditsObj = (json["credits"] as? [String: Any]) ?? json
        let availableCount = (creditsObj["available_count"] as? NSNumber)?.intValue
        let hasCredits = (creditsObj["has_credits"] as? Bool) ?? ((availableCount ?? 0) > 0)
        let balanceNum = Self.parseDouble(creditsObj["balance"])

        var balance: BalanceInfo?
        if let balanceNum, balanceNum > 0 {
            balance = BalanceInfo(currency: "USD", totalBalance: balanceNum, detail: "重置额度")
        }

        var note: String?
        if let availableCount, availableCount > 0 {
            note = "可用重置次数: \(availableCount)"
        } else if hasCredits, let remPct = Self.parseDouble(creditsObj["remaining_percent"]) {
            note = "附加重置额度剩余 \(Int(remPct.rounded()))%"
        }

        if balance == nil && balanceNum == nil && availableCount == nil && note == nil {
            return nil
        }
        return ParsedResetCredits(
            balance: balance,
            creditsRemaining: balanceNum,
            availableCount: availableCount,
            note: note
        )
    }

    /// Parses `GET /backend-api/wham/usage` JSON, classifying windows strictly by `limit_window_seconds`
    /// (`18000` -> `5小时`, `604800` -> `本周`, others -> extra) and treating null `used_percent` as absent.
    public static func parseWhamUsageJSON(
        _ json: [String: Any],
        fallbackPlan: PlanInfo? = nil,
        now: Date = Date()
    ) -> ParsedWhamUsage {
        let planRaw = (json["plan_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = PlanInfo.normalized(kindRaw: planRaw, name: planRaw) ?? fallbackPlan

        var coreWindows: [QuotaWindow] = []
        var extraWindows: [QuotaWindow] = []

        // 1. Primary rate_limit (collect both primary_window and secondary_window, classify strictly by duration).
        if let rl = json["rate_limit"] as? [String: Any] {
            for slotKey in ["primary_window", "secondary_window"] {
                if let winObj = rl[slotKey] as? [String: Any],
                   let win = parseCodexWindow(winObj, idPrefix: "", labelPrefix: nil, now: now) {
                    if !coreWindows.contains(where: { $0.id == win.id }) {
                        coreWindows.append(win)
                    }
                }
            }
        }

        // 2. Code review rate limit.
        if let crl = json["code_review_rate_limit"] as? [String: Any] {
            for slotKey in ["primary_window", "secondary_window"] {
                if let winObj = crl[slotKey] as? [String: Any],
                   let win = parseCodexWindow(winObj, idPrefix: "code_review_", labelPrefix: "代码审查", now: now) {
                    if !extraWindows.contains(where: { $0.id == win.id }) {
                        extraWindows.append(win)
                    }
                }
            }
        }

        // 3. Additional rate limits array.
        if let additional = json["additional_rate_limits"] as? [[String: Any]] {
            for (idx, item) in additional.enumerated() {
                let rawName = ((item["limit_name"] as? String)
                    ?? (item["metered_feature"] as? String)
                    ?? "附加限额 \(idx + 1)").trimmingCharacters(in: .whitespacesAndNewlines)
                let slug = rawName.lowercased().replacingOccurrences(of: " ", with: "_")
                let rl = (item["rate_limit"] as? [String: Any]) ?? item
                for slotKey in ["primary_window", "secondary_window"] {
                    if let winObj = rl[slotKey] as? [String: Any],
                       let win = parseCodexWindow(winObj, idPrefix: "add_\(slug)_", labelPrefix: rawName, now: now) {
                        if !extraWindows.contains(where: { $0.id == win.id }) {
                            extraWindows.append(win)
                        }
                    }
                }
            }
        }

        // Order core windows deterministically: 5小时 (18000) -> 本周 (604800) -> other durations ascending.
        coreWindows.sort { lhs, rhs in
            windowSortRank(lhs.windowSeconds) < windowSortRank(rhs.windowSeconds)
        }

        var allWindows = coreWindows + extraWindows
        if !allWindows.isEmpty {
            let primaryIndex = allWindows.firstIndex(where: { $0.windowSeconds == 18_000 })
                ?? allWindows.firstIndex(where: { $0.windowSeconds == 604_800 })
                ?? 0
            for idx in allWindows.indices {
                allWindows[idx].isPrimary = (idx == primaryIndex)
            }
        }

        // Optional credits object inside wham/usage (preserve explicit `0` balance for AccountPool export).
        var balance: BalanceInfo?
        var paceNote: String?
        var creditsRemaining: Double?
        var creditsReadSucceeded: Bool?
        if let credits = json["credits"] as? [String: Any] {
            let hasCredits = (credits["has_credits"] as? Bool) ?? false
            let unlimited = (credits["unlimited"] as? Bool) ?? false
            if let bal = parseDouble(credits["balance"]) {
                creditsRemaining = max(0.0, bal)
                creditsReadSucceeded = true
                if !unlimited && (hasCredits || bal > 0) {
                    balance = BalanceInfo(currency: "USD", totalBalance: bal, detail: "Credits")
                }
            }
            if unlimited {
                paceNote = "附加 Credits: 无限"
            }
        }

        return ParsedWhamUsage(
            plan: plan,
            windows: allWindows,
            balance: balance,
            paceNote: paceNote,
            creditsRemaining: creditsRemaining,
            creditsReadSucceeded: creditsReadSucceeded
        )
    }

    private static func windowSortRank(_ seconds: Int?) -> Int {
        switch seconds {
        case 18_000: return 0
        case 604_800: return 1
        case .some(let s): return 10 + s
        case .none: return 1_000_000
        }
    }

    /// Parses a single Codex rate-limit window object. Null/missing `used_percent` returns `nil` (absent, not exhausted).
    private static func parseCodexWindow(
        _ dict: [String: Any],
        idPrefix: String,
        labelPrefix: String?,
        now: Date
    ) -> QuotaWindow? {
        // CRITICAL: null or missing used_percent means window is absent (NOT exhausted!).
        guard let used = parseDouble(dict["used_percent"]) else {
            return nil
        }

        let clampedUsed = min(max(used, 0.0), 100.0)
        let remaining = min(max(1.0 - clampedUsed / 100.0, 0.0), 1.0)
        let windowSecs = (dict["limit_window_seconds"] as? NSNumber)?.intValue

        let baseId: String
        let baseLabel: String
        switch windowSecs {
        case 18_000:
            baseId = "5h"
            baseLabel = "5小时"
        case 604_800:
            baseId = "weekly"
            baseLabel = "本周"
        case .some(let secs) where secs > 0:
            baseId = "window_\(secs)"
            baseLabel = formatDurationLabel(seconds: secs)
        default:
            baseId = "window"
            baseLabel = "额度"
        }

        let finalLabel: String
        if let prefix = labelPrefix, !prefix.isEmpty {
            finalLabel = "\(prefix) · \(baseLabel)"
        } else {
            finalLabel = baseLabel
        }

        let resetAt = parseResetDate(from: dict, now: now)
        return QuotaWindow(
            id: "\(idPrefix)\(baseId)",
            label: finalLabel,
            remainingFraction: remaining,
            usedPercent: clampedUsed,
            resetAt: resetAt,
            windowSeconds: windowSecs,
            detail: nil,
            isPrimary: false
        )
    }

    private static func formatDurationLabel(seconds: Int) -> String {
        if seconds % 86_400 == 0 {
            let days = seconds / 86_400
            return "\(days)天"
        }
        if seconds % 3_600 == 0 {
            let hours = seconds / 3_600
            return "\(hours)小时"
        }
        let mins = max(1, seconds / 60)
        return "\(mins)分钟"
    }

    private static func parseResetDate(from dict: [String: Any], now: Date) -> Date? {
        for key in ["resets_at", "reset_at"] {
            if let num = parseDouble(dict[key]), num > 1_000_000_000 {
                return Date(timeIntervalSince1970: num)
            }
            if let str = dict[key] as? String, let date = Formatters.parseRFC3339(str) {
                return date
            }
        }
        if let after = parseDouble(dict["reset_after_seconds"]), after > 0 {
            return now.addingTimeInterval(after)
        }
        return nil
    }

    private static func parseDouble(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let num = value as? NSNumber {
            // Avoid treating JSON booleans as numeric 0/1.
            if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
            return num.doubleValue
        }
        if let str = value as? String {
            return Double(str.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func buildQuotaSnapshot(
        account: AccountRecord,
        parsed: ParsedWhamUsage,
        resetCredits: ParsedResetCredits?,
        sourceLabel: String
    ) -> QuotaSnapshot {
        let now = Date()
        let balance = parsed.balance ?? resetCredits?.balance
        let paceNote = [parsed.paceNote, resetCredits?.note]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        let resolvedCreditsRem = parsed.creditsRemaining ?? resetCredits?.creditsRemaining ?? balance?.totalBalance
        let resolvedCreditsOK: Bool? = parsed.creditsReadSucceeded ?? (resolvedCreditsRem != nil ? true : nil)
        let resolvedResetAvail = resetCredits?.availableCount
        if resolvedCreditsRem != nil || resolvedResetAvail != nil {
            Self.recordCreditMetadata(
                CodexCreditMetadata(
                    creditsRemaining: resolvedCreditsRem,
                    creditsReadSucceeded: resolvedCreditsOK,
                    resetCreditsAvailable: resolvedResetAvail,
                    updatedAt: now
                ),
                for: account.id
            )
        }

        return QuotaSnapshot(
            provider: .codex,
            accountId: account.id,
            plan: parsed.plan ?? account.plan,
            windows: parsed.windows,
            balance: balance,
            status: .ready(fetchedAt: now, stale: false),
            sourceLabel: sourceLabel,
            paceNote: paceNote.isEmpty ? nil : paceNote
        )
    }

    // MARK: - Safe Account Switch (Guard -> Verify Target -> Save Outgoing -> GracefulStop -> Write + ProjectSync + Rollback)

    public func switchAccount(to account: AccountRecord, allowForceQuit: Bool) async -> SwitchResult {
        // Step 1: Pre-switch safety guards.
        if let guardFailure = validatePreSwitchSafety() {
            return .failed(guardFailure)
        }
        let cfg = readConfigSnapshot()

        // Step 2: Load & verify target credential BEFORE stopping any Codex/ChatGPT process!
        guard var targetCred = (try? readVaultCredential(accountId: account.id)) else {
            return .failed("未在钥匙串中找到目标 Codex 账号凭证，请重新添加该账号")
        }
        guard targetCred.identity.canonicalAccountId == account.id else {
            return .failed("目标 Codex 凭证身份校验不匹配，已中止切换")
        }

        let outgoingLive = readLiveCredential()
        let targetAlreadyLive = (outgoingLive?.identity.canonicalAccountId == account.id)

        if !targetAlreadyLive && Self.isJWTExpired(targetCred.accessToken, marginSeconds: 60) {
            switch await refreshInactiveCredentialSafely(accountId: account.id, current: targetCred) {
            case .refreshed(let updated):
                targetCred = updated
            case .becameLive(let liveCred):
                targetCred = liveCred
            case .reauthRequired(let msg):
                return .failed("目标账号令牌已失效，未停止任何进程: \(msg)")
            case .failed(let msg):
                return .failed("预刷新目标账号令牌失败，未停止任何进程: \(msg)")
            }
        }

        // Verify target access token & identity via wham/usage BEFORE stopping anything.
        if !targetAlreadyLive {
            var verifyRes = await requestWhamUsage(credential: targetCred)
            if case .unauthorized = verifyRes {
                switch await refreshInactiveCredentialSafely(accountId: account.id, current: targetCred) {
                case .refreshed(let updated):
                    targetCred = updated
                    verifyRes = await requestWhamUsage(credential: targetCred)
                case .becameLive(let liveCred):
                    targetCred = liveCred
                case .reauthRequired(let msg):
                    return .failed("目标账号校验失败，未停止任何进程: \(msg)")
                case .failed(let msg):
                    return .failed("目标账号刷新失败，未停止任何进程: \(msg)")
                }
            }
            if case .unauthorized = verifyRes {
                return .failed("目标 Codex 账号授权已失效 (HTTP 401)，已中止切换")
            }
            if case .failed(let msg) = verifyRes {
                return .failed("目标 Codex 账号预检失败，未停止任何进程: \(msg)")
            }
        }

        // Step 3: Save outgoing live credential to vault so its latest rotated refresh_token is never lost.
        if let outgoingLive, outgoingLive.identity.canonicalAccountId != account.id {
            try? saveVaultCredential(
                accountId: outgoingLive.identity.canonicalAccountId,
                data: outgoingLive.rawData
            )
        }

        // Step 4: Warn on interactive `codex` CLI sessions if !allowForceQuit.
        if !allowForceQuit {
            let status = await detectClientStatus()
            let interactiveCLI = status.runningProcesses.filter { $0.isInteractiveCLI }
            if !interactiveCLI.isEmpty {
                return .needsForceQuitConfirmation(surviving: interactiveCLI)
            }
        }

        // Step 5: Graceful stop `com.openai.codex` + `app-server-daemon` + detached CLIs (12s timeout; no auto-SIGKILL).
        let stopResult = await processController.gracefulStop(
            bundleIDs: Self.desktopBundleIDs,
            detachedExecutableMatchers: detachedExecutableMatchers(),
            timeoutSeconds: 12.0,
            allowForceQuit: allowForceQuit
        )

        let reopenURLs: [URL]
        switch stopResult {
        case .stillRunning(let surviving):
            return .needsForceQuitConfirmation(surviving: surviving)
        case .stopped(let urls):
            reopenURLs = urls
        }

        // Step 6: Atomic credential write + readback verify + CodexProjectSync inside one rollback transaction.
        let liveBackup = snapshotLiveForRollback(storageMode: cfg.storageMode)
        var projectSyncHandle: CodexProjectSync.RollbackHandle?

        do {
            try writeLiveCredential(data: targetCred.rawData, storageMode: cfg.storageMode)

            // Readback verify written live credential matches target SHA-256 and canonicalAccountId.
            guard let verifiedLive = readLiveCredential(),
                  verifiedLive.identity.canonicalAccountId == account.id,
                  Formatters.sha256Hex(verifiedLive.rawData) == Formatters.sha256Hex(targetCred.rawData) else {
                throw ProviderAdapterError.operationFailed("写入 Codex 凭证后回读校验不一致")
            }

            // Preserve non-cloud local projects & sidebar layout across accounts.
            projectSyncHandle = try CodexProjectSync.prepareAndApply(
                codexHomeURL: codexHomeURL,
                from: outgoingLive?.identity,
                to: targetCred.identity
            )
        } catch {
            if let handle = projectSyncHandle {
                try? CodexProjectSync.rollback(handle)
            }
            rollbackLiveCredential(liveBackup)
            await processController.reopenApps(urls: reopenURLs)
            return .failed("写入或同步 Codex 状态失败，已完整回滚原账号: \(error.localizedDescription)")
        }

        // Step 7: Reopen ONLY previously running apps.
        await processController.reopenApps(urls: reopenURLs)
        return .switched(reopenedApps: reopenURLs.map { $0.deletingPathExtension().lastPathComponent })
    }

    // MARK: - Safe Client Control

    public func controlClient(restart: Bool, allowForceQuit: Bool) async -> SwitchResult {
        if !allowForceQuit {
            let status = await detectClientStatus()
            let interactiveCLI = status.runningProcesses.filter { $0.isInteractiveCLI }
            if !interactiveCLI.isEmpty {
                return .needsForceQuitConfirmation(surviving: interactiveCLI)
            }
        }

        let stopResult = await processController.gracefulStop(
            bundleIDs: Self.desktopBundleIDs,
            detachedExecutableMatchers: detachedExecutableMatchers(),
            timeoutSeconds: 12.0,
            allowForceQuit: allowForceQuit
        )

        switch stopResult {
        case .stillRunning(let surviving):
            return .needsForceQuitConfirmation(surviving: surviving)
        case .stopped(let previouslyRunning):
            guard restart else {
                return .switched(reopenedApps: [])
            }
            var toOpen = previouslyRunning
            if toOpen.isEmpty {
                let installed = processController.inspector.installedAppURLs(
                    bundleIDs: Self.desktopBundleIDs,
                    extraPaths: [desktopAppURL.path]
                )
                if let first = installed.first {
                    toOpen = [first]
                }
            }
            await processController.reopenApps(urls: toOpen)
            return .switched(reopenedApps: toOpen.map { $0.deletingPathExtension().lastPathComponent })
        }
    }

    // MARK: - Credential Deletion

    public func deleteAccountCredentials(accountId: String) throws {
        try keychain.deleteChunkedSecret(service: isolatedStoreNamespace, account: accountId)
    }

    // MARK: - Utilities

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

// MARK: - Per-Account Async Refresh Gate (Prevents Concurrent Single-Use Refresh-Token Races)

private actor CodexRefreshGate {
    private var inFlight: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func withLock<T>(accountId: String, operation: () async -> T) async -> T {
        while inFlight.contains(accountId) {
            await withCheckedContinuation { continuation in
                waiters[accountId, default: []].append(continuation)
            }
        }
        inFlight.insert(accountId)
        defer {
            inFlight.remove(accountId)
            if var queue = waiters[accountId], !queue.isEmpty {
                let next = queue.removeFirst()
                if queue.isEmpty {
                    waiters.removeValue(forKey: accountId)
                } else {
                    waiters[accountId] = queue
                }
                next.resume()
            }
        }
        return await operation()
    }
}
