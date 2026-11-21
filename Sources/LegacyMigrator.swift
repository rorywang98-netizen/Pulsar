import Foundation

// MARK: - Migration Paths & Report

public struct LegacyMigrationPaths: Equatable, Sendable {
    public var orbitSwitchBackupAccountsURL: URL
    public var codexBarManagedAccountsURL: URL
    public var codexBarManagedHomesDirURL: URL
    public var codexBarConfigURL: URL
    public var registryURL: URL

    public init(
        orbitSwitchBackupAccountsURL: URL,
        codexBarManagedAccountsURL: URL,
        codexBarManagedHomesDirURL: URL,
        codexBarConfigURL: URL,
        registryURL: URL
    ) {
        self.orbitSwitchBackupAccountsURL = orbitSwitchBackupAccountsURL
        self.codexBarManagedAccountsURL = codexBarManagedAccountsURL
        self.codexBarManagedHomesDirURL = codexBarManagedHomesDirURL
        self.codexBarConfigURL = codexBarConfigURL
        self.registryURL = registryURL
    }

    /// Optional environment variable pointing to a custom OrbitSwitch data/backup directory
    /// (or directly to an `accounts.json` file).
    public static let legacyOrbitSwitchDirEnvKey = "PULSAR_LEGACY_ORBITSWITCH_DIR"

    public static func resolveOrbitSwitchAccountsURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let rawOverride = environment[legacyOrbitSwitchDirEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawOverride.isEmpty {
            let expanded = NSString(string: rawOverride).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if url.pathExtension.lowercased() == "json" {
                return url
            }
            return url.appendingPathComponent("accounts.json", isDirectory: false)
        }
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("OrbitSwitch", isDirectory: true)
            .appendingPathComponent("accounts.json", isDirectory: false)
    }

    public static var liveDefaults: LegacyMigrationPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexBarSupport = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CodexBar", isDirectory: true)
        return LegacyMigrationPaths(
            orbitSwitchBackupAccountsURL: resolveOrbitSwitchAccountsURL(home: home),
            codexBarManagedAccountsURL: codexBarSupport
                .appendingPathComponent("managed-codex-accounts.json", isDirectory: false),
            codexBarManagedHomesDirURL: codexBarSupport
                .appendingPathComponent("managed-codex-homes", isDirectory: true),
            codexBarConfigURL: home
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("codexbar", isDirectory: true)
                .appendingPathComponent("config.json", isDirectory: false),
            registryURL: RegistryData.defaultFileURL
        )
    }
}

/// Structured migration result containing counts and sanitized labels only (ZERO secrets).
public struct MigrationReport: Codable, Equatable, Sendable {
    public var orbitSwitchAntigravityMigrated: Int = 0
    public var orbitSwitchCodexMigrated: Int = 0
    public var orbitSwitchSkippedAlreadyMigrated: Int = 0
    public var orbitSwitchLegacyItemsPurged: Int = 0
    public var orbitSwitchPurgeExecuted: Bool = false

    public var codexBarCodexImported: Int = 0
    public var codexBarCodexSkippedDuplicate: Int = 0
    public var codexBarAPIKeysImported: [String] = []
    public var codexBarAPIKeysSkippedExisting: [String] = []

    public var totalAccountsInRegistry: Int = 0
    public var warnings: [String] = []
    public var errors: [String] = []

    public init() {}

    public var succeeded: Bool {
        errors.isEmpty
    }

    public var summaryText: String {
        var parts: [String] = []
        parts.append("OrbitSwitch: Antigravity=\(orbitSwitchAntigravityMigrated), Codex=\(orbitSwitchCodexMigrated), 跳过已迁移=\(orbitSwitchSkippedAlreadyMigrated), 清理旧 Keychain 项=\(orbitSwitchLegacyItemsPurged)")
        parts.append("CodexBar(只读导入): Codex新增=\(codexBarCodexImported), 去重跳过=\(codexBarCodexSkippedDuplicate), API Key导入=\(codexBarAPIKeysImported.isEmpty ? "无" : codexBarAPIKeysImported.joined(separator: ","))")
        parts.append("注册表总账号数=\(totalAccountsInRegistry)")
        if !warnings.isEmpty {
            parts.append("警告(\(warnings.count)): \(warnings.joined(separator: "; "))")
        }
        if !errors.isEmpty {
            parts.append("错误(\(errors.count)): \(errors.joined(separator: "; "))")
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Transactional Prompt-Free Legacy Migrator

public final class LegacyMigrator {
    public static let orbitSwitchAntigravityService = "orbitswitch"
    public static let orbitSwitchCodexService       = "orbitswitch.sessions"

    public let keychain: KeychainStore
    public let paths: LegacyMigrationPaths

    public init(
        keychain: KeychainStore = .shared,
        paths: LegacyMigrationPaths = .liveDefaults
    ) {
        self.keychain = keychain
        self.paths = paths
    }

    /// Runs the idempotent, transactional one-time migration from OrbitSwitch backup/Keychain
    /// and read-only CodexBar stores into RoryOrbit's isolated Keychain namespaces & `registry.json`.
    /// Legacy OrbitSwitch Keychain items are purged ONLY if 100% of present accounts pass SHA-256
    /// read-back verification and `registry.json` is atomically saved and verified.
    public func runMigration() -> MigrationReport {
        var report = MigrationReport()
        var registry: RegistryData
        do {
            registry = try RegistryData.load(from: paths.registryURL)
        } catch {
            report.errors.append("读取现有 registry.json 失败: \(error.localizedDescription)")
            return report
        }

        var legacyItemsToPurge: [(service: String, account: String)] = []
        var verifiedAccountKeys: [(provider: ProviderID, id: String)] = []
        var allPresentOrbitSwitchVerified = true

        // 1. OrbitSwitch Migration (strictly whitelisted: antigravity & codex only)
        migrateOrbitSwitch(
            into: &registry,
            report: &report,
            legacyItemsToPurge: &legacyItemsToPurge,
            verifiedAccountKeys: &verifiedAccountKeys,
            allPresentVerified: &allPresentOrbitSwitchVerified
        )

        // 2. CodexBar Read-Only Import (NEVER modifies or deletes CodexBar files)
        importCodexBarManagedCodexAccounts(
            into: &registry,
            report: &report,
            verifiedAccountKeys: &verifiedAccountKeys
        )
        importCodexBarAPIKeys(
            into: &registry,
            report: &report
        )

        // 3. Atomic registry.json save + read-back verification
        if report.errors.isEmpty && allPresentOrbitSwitchVerified {
            registry.settings.legacyMigrationCompleted = true
        }

        var registryVerified = false
        do {
            try registry.save(to: paths.registryURL)
            let reloaded = try RegistryData.load(from: paths.registryURL)
            let reloadedSet = Set(reloaded.accounts.map { "\($0.provider.rawValue)|\($0.id)" })
            let allPresentInRegistry = verifiedAccountKeys.allSatisfy {
                reloadedSet.contains("\($0.provider.rawValue)|\($0.id)")
            }
            if allPresentInRegistry {
                registryVerified = true
                report.totalAccountsInRegistry = reloaded.accounts.count
            } else {
                report.errors.append("registry.json 回读校验失败：部分已迁移账号未落盘")
            }
        } catch {
            report.errors.append("原子保存 registry.json 失败: \(error.localizedDescription)")
        }

        // 4. Transactional Purge of Legacy OrbitSwitch Keychain Items (ONLY on 100% verification)
        if !legacyItemsToPurge.isEmpty && allPresentOrbitSwitchVerified && report.errors.isEmpty && registryVerified {
            var purgedCount = 0
            for item in legacyItemsToPurge {
                do {
                    try keychain.deleteExternalGenericPassword(service: item.service, account: item.account)
                    purgedCount += 1
                } catch {
                    report.warnings.append("清理旧 Keychain 项失败 (\(item.service))")
                }
            }
            report.orbitSwitchLegacyItemsPurged = purgedCount
            report.orbitSwitchPurgeExecuted = true
        }

        return report
    }

    // MARK: - Step 1: OrbitSwitch Migration

    private struct OrbitSwitchBackupFile: Decodable {
        let version: Int?
        let accounts: [OrbitSwitchAccountEntry]
    }

    private struct OrbitSwitchPlanEntry: Decodable {
        let kind: String?
        let name: String?
    }

    private struct OrbitSwitchAccountEntry: Decodable {
        let provider: String
        let id: String
        let email: String?
        let name: String?
        let plan: OrbitSwitchPlanEntry?
        let addedAt: String?
    }

    private func migrateOrbitSwitch(
        into registry: inout RegistryData,
        report: inout MigrationReport,
        legacyItemsToPurge: inout [(service: String, account: String)],
        verifiedAccountKeys: inout [(provider: ProviderID, id: String)],
        allPresentVerified: inout Bool
    ) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.orbitSwitchBackupAccountsURL.path) else {
            return
        }

        let backup: OrbitSwitchBackupFile
        do {
            let data = try Data(contentsOf: paths.orbitSwitchBackupAccountsURL)
            backup = try JSONDecoder().decode(OrbitSwitchBackupFile.self, from: data)
        } catch {
            report.errors.append("解析 OrbitSwitch 备份元数据失败")
            allPresentVerified = false
            return
        }

        // Strict whitelist: ONLY antigravity and codex. Ignore everything else completely.
        let allowedEntries = backup.accounts.filter {
            $0.provider == "antigravity" || $0.provider == "codex"
        }

        for entry in allowedEntries {
            switch entry.provider {
            case "antigravity":
                migrateOrbitSwitchAntigravity(
                    entry: entry,
                    into: &registry,
                    report: &report,
                    legacyItemsToPurge: &legacyItemsToPurge,
                    verifiedAccountKeys: &verifiedAccountKeys,
                    allPresentVerified: &allPresentVerified
                )
            case "codex":
                migrateOrbitSwitchCodex(
                    entry: entry,
                    into: &registry,
                    report: &report,
                    legacyItemsToPurge: &legacyItemsToPurge,
                    verifiedAccountKeys: &verifiedAccountKeys,
                    allPresentVerified: &allPresentVerified
                )
            default:
                continue
            }
        }
    }

    private func migrateOrbitSwitchAntigravity(
        entry: OrbitSwitchAccountEntry,
        into registry: inout RegistryData,
        report: inout MigrationReport,
        legacyItemsToPurge: inout [(service: String, account: String)],
        verifiedAccountKeys: inout [(provider: ProviderID, id: String)],
        allPresentVerified: inout Bool
    ) {
        let label = entry.email ?? entry.id
        do {
            let legacyToken = try keychain.readExternalGenericPassword(
                service: Self.orbitSwitchAntigravityService,
                account: entry.id
            )

            guard let token = legacyToken, !token.isEmpty else {
                if keychain.hasSecret(service: roryOrbitAntigravityService, account: entry.id) {
                    upsertOrbitSwitchMetadata(entry: entry, provider: .antigravity, into: &registry)
                    verifiedAccountKeys.append((.antigravity, entry.id))
                    report.orbitSwitchSkippedAlreadyMigrated += 1
                } else {
                    report.warnings.append("OrbitSwitch Antigravity 账号 (\(label)) 未找到旧 Keychain 凭证")
                    allPresentVerified = false
                }
                return
            }

            let expectedSHA = Formatters.sha256Hex(token)
            try keychain.writeSecret(
                service: roryOrbitAntigravityService,
                account: entry.id,
                value: token
            )
            guard let readBack = try keychain.readSecret(
                service: roryOrbitAntigravityService,
                account: entry.id
            ), Formatters.sha256Hex(readBack) == expectedSHA else {
                report.errors.append("Antigravity 账号 (\(label)) 迁移后 SHA-256 校验不一致")
                allPresentVerified = false
                return
            }

            upsertOrbitSwitchMetadata(entry: entry, provider: .antigravity, into: &registry)
            verifiedAccountKeys.append((.antigravity, entry.id))
            legacyItemsToPurge.append((Self.orbitSwitchAntigravityService, entry.id))
            report.orbitSwitchAntigravityMigrated += 1
        } catch {
            report.errors.append("迁移 OrbitSwitch Antigravity 账号 (\(label)) 失败: \(error.localizedDescription)")
            allPresentVerified = false
        }
    }

    private func migrateOrbitSwitchCodex(
        entry: OrbitSwitchAccountEntry,
        into registry: inout RegistryData,
        report: inout MigrationReport,
        legacyItemsToPurge: inout [(service: String, account: String)],
        verifiedAccountKeys: inout [(provider: ProviderID, id: String)],
        allPresentVerified: inout Bool
    ) {
        let label = entry.email ?? entry.id
        do {
            guard let indexData = try keychain.readExternalGenericPasswordData(
                service: Self.orbitSwitchCodexService,
                account: entry.id
            ) else {
                if (try? keychain.readChunkIndex(service: roryOrbitCodexService, account: entry.id)) != nil {
                    upsertOrbitSwitchMetadata(entry: entry, provider: .codex, into: &registry)
                    verifiedAccountKeys.append((.codex, entry.id))
                    report.orbitSwitchSkippedAlreadyMigrated += 1
                } else {
                    report.warnings.append("OrbitSwitch Codex 账号 (\(label)) 未找到旧 Keychain 分片索引")
                    allPresentVerified = false
                }
                return
            }

            let index = try JSONDecoder().decode(KeychainChunkIndex.self, from: indexData)
            guard !index.generation.isEmpty, (1...KeychainStore.maxChunkCount).contains(index.chunks) else {
                report.errors.append("OrbitSwitch Codex 账号 (\(label)) 分片索引非法")
                allPresentVerified = false
                return
            }

            var combinedBase64 = ""
            var chunkKeysForPurge: [(service: String, account: String)] = []
            for idx in 0..<index.chunks {
                let chunkKey = KeychainStore.chunkAccountKey(
                    account: entry.id,
                    generation: index.generation,
                    index: idx
                )
                guard let chunkStr = try keychain.readExternalGenericPassword(
                    service: Self.orbitSwitchCodexService,
                    account: chunkKey
                ) else {
                    report.errors.append("OrbitSwitch Codex 账号 (\(label)) 缺失分片 \(idx)/\(index.chunks)")
                    allPresentVerified = false
                    return
                }
                combinedBase64.append(chunkStr)
                chunkKeysForPurge.append((Self.orbitSwitchCodexService, chunkKey))
            }

            guard let rawSessionData = Data(base64Encoded: combinedBase64) else {
                report.errors.append("OrbitSwitch Codex 账号 (\(label)) Base64 解码失败")
                allPresentVerified = false
                return
            }

            guard Formatters.sha256Hex(rawSessionData) == index.digest.lowercased() else {
                report.errors.append("OrbitSwitch Codex 账号 (\(label)) 源分片 SHA-256 校验失败")
                allPresentVerified = false
                return
            }

            guard let canonicalAuthData = Formatters.extractCanonicalCodexAuthData(from: rawSessionData) else {
                report.errors.append("OrbitSwitch Codex 账号 (\(label)) 凭证格式无法识别")
                allPresentVerified = false
                return
            }

            let expectedAuthSHA = Formatters.sha256Hex(canonicalAuthData)
            try keychain.writeChunkedSecret(
                service: roryOrbitCodexService,
                account: entry.id,
                data: canonicalAuthData
            )

            guard let readBack = try keychain.readChunkedSecret(
                service: roryOrbitCodexService,
                account: entry.id
            ), Formatters.sha256Hex(readBack) == expectedAuthSHA else {
                report.errors.append("Codex 账号 (\(label)) 迁移后 SHA-256 回读校验失败")
                allPresentVerified = false
                return
            }

            upsertOrbitSwitchMetadata(entry: entry, provider: .codex, into: &registry)
            verifiedAccountKeys.append((.codex, entry.id))
            legacyItemsToPurge.append((Self.orbitSwitchCodexService, entry.id))
            legacyItemsToPurge.append(contentsOf: chunkKeysForPurge)
            report.orbitSwitchCodexMigrated += 1
        } catch {
            report.errors.append("迁移 OrbitSwitch Codex 账号 (\(label)) 失败: \(error.localizedDescription)")
            allPresentVerified = false
        }
    }

    private func upsertOrbitSwitchMetadata(
        entry: OrbitSwitchAccountEntry,
        provider: ProviderID,
        into registry: inout RegistryData
    ) {
        let email = entry.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let plan = PlanInfo.normalized(kindRaw: entry.plan?.kind, name: entry.plan?.name)
        let addedAt = entry.addedAt.flatMap { Formatters.parseRFC3339($0) } ?? Date()

        registry.upsertAccount(
            AccountRecord(
                id: entry.id,
                provider: provider,
                email: email,
                displayName: name.isEmpty ? email : name,
                plan: plan,
                addedAt: addedAt,
                isActiveLive: false
            )
        )
    }

    // MARK: - Step 2A: CodexBar Read-Only Managed Codex Import

    private struct CodexBarManagedAccountsFile: Decodable {
        let version: Int?
        let accounts: [CodexBarManagedAccountEntry]
    }

    private struct CodexBarManagedAccountEntry: Decodable {
        let id: String
        let email: String?
        let managedHomePath: String?
        let providerAccountID: String?
        let createdAt: Double?
    }

    private func importCodexBarManagedCodexAccounts(
        into registry: inout RegistryData,
        report: inout MigrationReport,
        verifiedAccountKeys: inout [(provider: ProviderID, id: String)]
    ) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.codexBarManagedAccountsURL.path) else {
            return
        }

        let managedFile: CodexBarManagedAccountsFile
        do {
            let data = try Data(contentsOf: paths.codexBarManagedAccountsURL)
            managedFile = try JSONDecoder().decode(CodexBarManagedAccountsFile.self, from: data)
        } catch {
            report.warnings.append("读取 CodexBar managed-codex-accounts.json 失败")
            return
        }

        for entry in managedFile.accounts {
            let authURL: URL
            if let explicitHome = entry.managedHomePath, !explicitHome.isEmpty {
                authURL = URL(fileURLWithPath: explicitHome, isDirectory: true)
                    .appendingPathComponent("auth.json", isDirectory: false)
            } else {
                authURL = paths.codexBarManagedHomesDirURL
                    .appendingPathComponent(entry.id, isDirectory: true)
                    .appendingPathComponent("auth.json", isDirectory: false)
            }

            guard fm.fileExists(atPath: authURL.path) else {
                report.warnings.append("CodexBar 托管目录缺少 auth.json (\(entry.email ?? entry.id))")
                continue
            }

            do {
                let rawAuthData = try Data(contentsOf: authURL)
                guard let authObj = (try JSONSerialization.jsonObject(with: rawAuthData, options: [])) as? [String: Any],
                      let identity = Formatters.extractCodexAuthIdentity(from: authObj),
                      let canonicalAuthData = Formatters.extractCanonicalCodexAuthData(from: rawAuthData) else {
                    report.warnings.append("跳过无法解析的 CodexBar auth.json (\(entry.email ?? entry.id))")
                    continue
                }

                let canonicalId = identity.canonicalAccountId
                let alreadyInRegistry = registry.accounts.contains {
                    $0.provider == .codex && $0.id == canonicalId
                }
                let alreadyInVault = (try? keychain.readChunkIndex(
                    service: roryOrbitCodexService,
                    account: canonicalId
                )) != nil

                if alreadyInRegistry && alreadyInVault {
                    report.codexBarCodexSkippedDuplicate += 1
                    continue
                }

                let expectedSHA = Formatters.sha256Hex(canonicalAuthData)
                try keychain.writeChunkedSecret(
                    service: roryOrbitCodexService,
                    account: canonicalId,
                    data: canonicalAuthData
                )
                guard let readBack = try keychain.readChunkedSecret(
                    service: roryOrbitCodexService,
                    account: canonicalId
                ), Formatters.sha256Hex(readBack) == expectedSHA else {
                    report.errors.append("CodexBar Codex 账号 (\(entry.email ?? canonicalId)) 回读校验失败")
                    continue
                }

                let resolvedEmail = !identity.email.isEmpty ? identity.email : (entry.email ?? "")
                let resolvedName = !identity.displayName.isEmpty ? identity.displayName : resolvedEmail
                let addedAt: Date
                if let ts = entry.createdAt {
                    addedAt = ts > 1_000_000_000
                        ? Date(timeIntervalSince1970: ts)
                        : Date(timeIntervalSinceReferenceDate: ts)
                } else {
                    addedAt = Date()
                }

                registry.upsertAccount(
                    AccountRecord(
                        id: canonicalId,
                        provider: .codex,
                        email: resolvedEmail,
                        displayName: resolvedName,
                        plan: identity.plan,
                        addedAt: addedAt,
                        isActiveLive: false
                    )
                )
                verifiedAccountKeys.append((.codex, canonicalId))
                report.codexBarCodexImported += 1
            } catch {
                report.warnings.append("导入 CodexBar Codex 账号 (\(entry.email ?? entry.id)) 失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Step 2B: CodexBar Read-Only API Key Import (Kimi & DeepSeek ONLY)

    private func importCodexBarAPIKeys(
        into registry: inout RegistryData,
        report: inout MigrationReport
    ) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.codexBarConfigURL.path) else {
            return
        }

        let providers: [[String: Any]]
        do {
            let data = try Data(contentsOf: paths.codexBarConfigURL)
            guard let root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let arr = root["providers"] as? [[String: Any]] else {
                return
            }
            providers = arr
        } catch {
            report.warnings.append("读取 CodexBar config.json 失败")
            return
        }

        // Strict whitelist: ONLY kimi and deepseek.
        for item in providers {
            guard let rawId = item["id"] as? String else { continue }
            switch rawId {
            case "kimi":
                importSingleAPIKey(
                    provider: .kimi,
                    accountKey: "kimi",
                    from: item,
                    preferTokenAccounts: false,
                    into: &registry,
                    report: &report
                )
            case "deepseek":
                importSingleAPIKey(
                    provider: .deepseek,
                    accountKey: "deepseek",
                    from: item,
                    preferTokenAccounts: true,
                    into: &registry,
                    report: &report
                )
            default:
                continue
            }
        }
    }

    private func importSingleAPIKey(
        provider: ProviderID,
        accountKey: String,
        from dict: [String: Any],
        preferTokenAccounts: Bool,
        into registry: inout RegistryData,
        report: inout MigrationReport
    ) {
        if keychain.hasSecret(service: roryOrbitKeysService, account: accountKey) {
            report.codexBarAPIKeysSkippedExisting.append(accountKey)
            return
        }

        let tokenAccount = extractActiveTokenAccount(from: dict)
        let directKey = nonEmptyTrimmed(dict["apiKey"] as? String)
        let resolvedKey: String? = preferTokenAccounts
            ? (tokenAccount?.token ?? directKey)
            : (directKey ?? tokenAccount?.token)

        guard let apiKey = resolvedKey, !apiKey.isEmpty else {
            return
        }

        do {
            let expectedSHA = Formatters.sha256Hex(apiKey)
            try keychain.writeSecret(service: roryOrbitKeysService, account: accountKey, value: apiKey)
            guard let readBack = try keychain.readSecret(service: roryOrbitKeysService, account: accountKey),
                  Formatters.sha256Hex(readBack) == expectedSHA else {
                report.errors.append("导入 \(provider.displayName) API Key 回读校验失败")
                return
            }
            report.codexBarAPIKeysImported.append(accountKey)

            if registry.accounts(for: provider).isEmpty {
                let label = tokenAccount?.label ?? provider.displayName
                registry.upsertAccount(
                    AccountRecord(
                        id: "\(provider.rawValue):api",
                        provider: provider,
                        email: label,
                        displayName: label,
                        plan: PlanInfo(kind: .api, displayName: "API"),
                        addedAt: Date(),
                        isActiveLive: true
                    )
                )
            }
        } catch {
            report.warnings.append("导入 \(provider.displayName) API Key 失败: \(error.localizedDescription)")
        }
    }

    private func extractActiveTokenAccount(from dict: [String: Any]) -> (token: String, label: String?)? {
        guard let tokenAccounts = dict["tokenAccounts"] as? [String: Any],
              let accounts = tokenAccounts["accounts"] as? [[String: Any]],
              !accounts.isEmpty else {
            return nil
        }

        let activeIndex = (tokenAccounts["activeIndex"] as? Int) ?? 0
        let orderedIndices: [Int]
        if accounts.indices.contains(activeIndex) {
            orderedIndices = [activeIndex] + accounts.indices.filter { $0 != activeIndex }
        } else {
            orderedIndices = Array(accounts.indices)
        }

        for idx in orderedIndices {
            let entry = accounts[idx]
            if let token = nonEmptyTrimmed(entry["token"] as? String) {
                let label = nonEmptyTrimmed(entry["label"] as? String)
                return (token, label)
            }
        }
        return nil
    }

    private func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
