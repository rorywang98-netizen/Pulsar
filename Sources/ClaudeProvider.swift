import Darwin
import Foundation

// MARK: - Passive Local-Only Claude CLI Quota Provider (100% Offline, Multi-Profile)

/// Strictly offline, passive local file reader & local profile pointer manager for Claude CLI quota telemetry.
///
/// Safety guarantees:
/// - Zero network calls (no HTTP clients, no remote endpoints, no sockets).
/// - Zero credential or secret reads (no system vault, no cookies, no auth tokens).
/// - Zero child-command spawning and zero interaction with Claude Desktop.
/// - Reads ONLY non-secret metadata and cached utilization snapshots from:
///   1. `~/.config/pulsar/claude-cli-profiles.json` (v2 multi-profile registry & Desktop exclusion guard;
///      falls back seamlessly to legacy `~/.config/pulsar/claude-cli-profile.json`)
///   2. `~/.config/pulsar/claude-active-profile` (local active default CLI profile pointer)
///   3. `<configDir>/.claude.json` or gated `~/.claude.json` (`oauthAccount` metadata + `cachedUsageUtilization`)
///   4. `~/.cache/pulsar/claude-cli-quotas/<profileId>.json` (and legacy `~/.cache/pulsar/claude-cli-quota.json` for `default`)
public final class ClaudeProvider: ProviderAdapter, @unchecked Sendable {
    public struct Paths: Equatable, Sendable {
        public var claudeConfigURL: URL
        public var statusLineCacheURL: URL
        public var cliProfileURL: URL?
        public var cliProfilesURL: URL?
        public var activeProfileURL: URL?
        public var statusLineCacheDirURL: URL?
        public var profilesBaseDirURL: URL?

        public init(
            claudeConfigURL: URL,
            statusLineCacheURL: URL,
            cliProfileURL: URL? = nil,
            cliProfilesURL: URL? = nil,
            activeProfileURL: URL? = nil,
            statusLineCacheDirURL: URL? = nil,
            profilesBaseDirURL: URL? = nil
        ) {
            self.claudeConfigURL = claudeConfigURL
            self.statusLineCacheURL = statusLineCacheURL
            self.cliProfileURL = cliProfileURL
            self.cliProfilesURL = cliProfilesURL
            self.activeProfileURL = activeProfileURL
            self.statusLineCacheDirURL = statusLineCacheDirURL
            self.profilesBaseDirURL = profilesBaseDirURL
        }

        public static var liveDefaults: Paths {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let env = ProcessInfo.processInfo.environment

            let configDir: URL
            if let override = env["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !override.isEmpty {
                let expanded = (override as NSString).expandingTildeInPath
                configDir = URL(fileURLWithPath: expanded, isDirectory: true)
            } else {
                configDir = home
            }
            let claudeConfig = configDir.appendingPathComponent(".claude.json", isDirectory: false)

            let statusLineCache = home
                .appendingPathComponent(".cache", isDirectory: true)
                .appendingPathComponent("pulsar", isDirectory: true)
                .appendingPathComponent("claude-cli-quota.json", isDirectory: false)

            let cliProfile: URL
            if let profileOverride = env["PULSAR_CLAUDE_PROFILE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !profileOverride.isEmpty {
                let expanded = (profileOverride as NSString).expandingTildeInPath
                cliProfile = URL(fileURLWithPath: expanded, isDirectory: false)
            } else {
                cliProfile = home
                    .appendingPathComponent(".config", isDirectory: true)
                    .appendingPathComponent("pulsar", isDirectory: true)
                    .appendingPathComponent("claude-cli-profile.json", isDirectory: false)
            }

            let cliProfiles: URL
            if let profilesOverride = env["PULSAR_CLAUDE_PROFILES_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !profilesOverride.isEmpty {
                let expanded = (profilesOverride as NSString).expandingTildeInPath
                cliProfiles = URL(fileURLWithPath: expanded, isDirectory: false)
            } else {
                cliProfiles = home
                    .appendingPathComponent(".config", isDirectory: true)
                    .appendingPathComponent("pulsar", isDirectory: true)
                    .appendingPathComponent("claude-cli-profiles.json", isDirectory: false)
            }

            let activeProfile: URL
            if let activeOverride = env["PULSAR_CLAUDE_ACTIVE_PROFILE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !activeOverride.isEmpty {
                let expanded = (activeOverride as NSString).expandingTildeInPath
                activeProfile = URL(fileURLWithPath: expanded, isDirectory: false)
            } else {
                activeProfile = home
                    .appendingPathComponent(".config", isDirectory: true)
                    .appendingPathComponent("pulsar", isDirectory: true)
                    .appendingPathComponent("claude-active-profile", isDirectory: false)
            }

            let statusLineCacheDir: URL
            if let quotasDirOverride = env["PULSAR_CLAUDE_QUOTAS_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !quotasDirOverride.isEmpty {
                let expanded = (quotasDirOverride as NSString).expandingTildeInPath
                statusLineCacheDir = URL(fileURLWithPath: expanded, isDirectory: true)
            } else {
                statusLineCacheDir = home
                    .appendingPathComponent(".cache", isDirectory: true)
                    .appendingPathComponent("pulsar", isDirectory: true)
                    .appendingPathComponent("claude-cli-quotas", isDirectory: true)
            }

            let profilesBaseDir: URL
            if let baseDirOverride = env["PULSAR_CLAUDE_PROFILES_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !baseDirOverride.isEmpty {
                let expanded = (baseDirOverride as NSString).expandingTildeInPath
                profilesBaseDir = URL(fileURLWithPath: expanded, isDirectory: true)
            } else {
                profilesBaseDir = home.appendingPathComponent(".claude-profiles", isDirectory: true)
            }

            return Paths(
                claudeConfigURL: claudeConfig,
                statusLineCacheURL: statusLineCache,
                cliProfileURL: cliProfile,
                cliProfilesURL: cliProfiles,
                activeProfileURL: activeProfile,
                statusLineCacheDirURL: statusLineCacheDir,
                profilesBaseDirURL: profilesBaseDir
            )
        }
    }

    public static let defaultLocalAccountId = "claude-cli-local"
    public static let defaultProfileSlug = "default"
    public static let profileAccountIdPrefix = "claude-profile:"
    public static let defaultCLIProxyPort = 17_892
    public static let passiveUnconfiguredMessage =
        "纯本地被动模式：在终端使用 Claude CLI 回复或输入 /usage 后自动同步余量（零联网）"
    public static let resetElapsedDetailMessage =
        "窗口已重置 · 待下次 CLI 对话同步"
    public static let policyRefusalMessage =
        "安全策略：Claude CLI 仅被动读取本地余量，不操作进程或凭据"
    public static let staleThresholdSeconds: TimeInterval = 86_400

    private static let maxClaudeConfigBytes = 32 * 1024 * 1024
    private static let maxStatusLineCacheBytes = 2 * 1024 * 1024
    private static let maxCLIProfileBytes = 512 * 1024
    private static let maxActiveProfileBytes = 1024
    private static let maxSettingsBytes = 4 * 1024 * 1024
    private static let strippedProxyEnvKeys: Set<String> = [
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "http_proxy",
        "https_proxy",
    ]
    private static let sharedProfileSymlinkNames: [String] = [
        "skills",
        "statusline-command.sh",
        "CLAUDE.md",
        "rules",
        "agents",
        "commands",
    ]

    public let id: ProviderID = .claude
    public let capabilities: ProviderCapability = [.quota]
    public let transportPolicy: TransportPolicy = .systemProxy
    public let isolatedStoreNamespace: String = "com.rory.roryorbit.claude.local"

    public let paths: Paths
    public let processController: ProcessController
    private let fileManager: FileManager
    private let profileWriteLock = NSLock()

    public init(
        paths: Paths = .liveDefaults,
        processController: ProcessController = .shared,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.processController = processController
        self.fileManager = fileManager
    }

    // MARK: - ProviderAdapter

    public func detectClientStatus() async -> ClientRuntimeStatus {
        let runningCLI = processController.inspector
            .allRunningProcesses()
            .filter { Self.isClaudeCLIExecutablePath($0.executablePath, bundleId: $0.bundleId) }
            .sorted { $0.id < $1.id }

        let homePath = fileManager.homeDirectoryForCurrentUser.path
        let candidateBinaries = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(homePath)/.local/bin/claude",
        ]
        let hasCLIInstalled = candidateBinaries.contains { fileManager.fileExists(atPath: $0) }
            || !runningCLI.isEmpty

        return ClientRuntimeStatus(
            installedApps: hasCLIInstalled ? ["Claude CLI"] : [],
            runningProcesses: runningCLI,
            isRunning: !runningCLI.isEmpty
        )
    }

    public func syncLiveAccount(registry: inout RegistryData) async -> String? {
        let existing = registry.accounts(for: .claude)

        // Multi-profile mode (`claude-cli-profiles.json` present and valid)
        if let doc = loadProfilesDocument(), doc.isMultiProfileFile {
            let activeSlug = readActiveProfileSlug()
            var resolvedRecords: [(slug: String, record: AccountRecord)] = []
            var seenCanonicalIds = Set<String>()
            var slugToCanonicalId: [String: String] = [:]

            for profile in doc.profiles {
                if doc.exclusions.isExcluded(email: profile.email, accountUuid: profile.accountUuid) {
                    continue
                }

                let resolved = inspectProfileData(profile, exclusions: doc.exclusions)
                let placeholderId = "\(Self.profileAccountIdPrefix)\(profile.id)"
                let canonicalId = resolved.accountUuid ?? placeholderId
                let lowerCanonical = canonicalId.lowercased()

                // Deduplicate if two profiles accidentally share the same live account UUID.
                if seenCanonicalIds.contains(lowerCanonical) {
                    slugToCanonicalId[profile.id.lowercased()] = canonicalId
                    continue
                }
                seenCanonicalIds.insert(lowerCanonical)
                slugToCanonicalId[profile.id.lowercased()] = canonicalId

                let priorRecord = existing.first(where: { Self.uuidsMatch($0.id, canonicalId) })
                    ?? existing.first(where: { Self.uuidsMatch($0.id, placeholderId) })
                let addedAt = priorRecord?.addedAt ?? profile.addedAt ?? Date()
                let email = resolved.email ?? ""
                let displayName = Self.firstNonEmpty(
                    resolved.displayName,
                    profile.label,
                    email,
                    profile.id
                ) ?? "Claude CLI"

                let record = AccountRecord(
                    id: canonicalId,
                    provider: .claude,
                    email: email,
                    displayName: displayName,
                    plan: resolved.plan,
                    addedAt: addedAt,
                    isActiveLive: false
                )
                resolvedRecords.append((slug: profile.id, record: record))
            }

            guard !resolvedRecords.isEmpty else {
                // Remove stale/excluded Claude records if all configured profiles were excluded or emptied.
                for old in existing {
                    if doc.exclusions.isExcluded(email: old.email, accountUuid: old.id)
                        || old.id == "claude:default"
                        || old.id == Self.defaultLocalAccountId
                        || old.id.hasPrefix(Self.profileAccountIdPrefix) {
                        registry.removeAccount(id: old.id, provider: .claude)
                    }
                }
                return nil
            }

            let activeCanonicalId: String = {
                if let exact = slugToCanonicalId[activeSlug.lowercased()] {
                    return exact
                }
                if let def = slugToCanonicalId[Self.defaultProfileSlug] {
                    return def
                }
                return resolvedRecords[0].record.id
            }()

            let keptLowerIds = Set(resolvedRecords.map { $0.record.id.lowercased() })
            for old in existing where !keptLowerIds.contains(old.id.lowercased()) {
                registry.removeAccount(id: old.id, provider: .claude)
            }

            for item in resolvedRecords {
                var rec = item.record
                rec.isActiveLive = Self.uuidsMatch(rec.id, activeCanonicalId)
                registry.upsertAccount(rec)
            }
            registry.setActiveLive(accountId: activeCanonicalId, for: .claude)
            return activeCanonicalId
        }

        // Legacy single-profile mode (`claude-cli-profile.json` or raw `~/.claude.json` + `claude-cli-quota.json`)
        let legacyDoc = loadLegacySingleProfileDocument()
        let exclusions = legacyDoc?.exclusions ?? .empty
        let singleProfile = legacyDoc?.profiles.first ?? CLIProfileEntry.implicitLegacyDefault
        let resolved = inspectProfileData(singleProfile, exclusions: exclusions)

        let email = resolved.email ?? ""
        let displayName = Self.firstNonEmpty(resolved.displayName, email) ?? "Claude CLI"
        let canonicalId: String
        if let accountUuid = resolved.accountUuid {
            canonicalId = accountUuid
        } else if let existingReal = existing.first(where: {
            $0.id != "claude:default"
                && $0.id != Self.defaultLocalAccountId
                && !$0.id.hasPrefix(Self.profileAccountIdPrefix)
                && !exclusions.isExcluded(email: $0.email, accountUuid: $0.id)
        }) {
            canonicalId = existingReal.id
        } else {
            canonicalId = Self.defaultLocalAccountId
        }

        let record = AccountRecord(
            id: canonicalId,
            provider: .claude,
            email: email,
            displayName: displayName,
            plan: resolved.plan,
            addedAt: existing.first(where: { $0.id == canonicalId })?.addedAt ?? Date(),
            isActiveLive: true
        )

        // Keep strictly one local Claude CLI account entry in legacy mode (clean up placeholder or excluded IDs).
        for old in existing where old.id != canonicalId {
            registry.removeAccount(id: old.id, provider: .claude)
        }
        registry.upsertAccount(record)
        registry.setActiveLive(accountId: canonicalId, for: .claude)
        return canonicalId
    }

    public func fetchQuota(for account: AccountRecord, isActiveLive: Bool) async -> QuotaSnapshot {
        _ = isActiveLive
        return resolvePassiveQuota(accountId: account.id, now: Date())
    }

    public func addAccount() async throws -> AccountRecord {
        throw ProviderAdapterError.operationFailed(Self.policyRefusalMessage)
    }

    public func importLiveAccount() async throws -> AccountRecord {
        throw ProviderAdapterError.operationFailed(Self.policyRefusalMessage)
    }

    /// Pure local default-profile pointer switch (`~/.config/pulsar/claude-active-profile`, `0600` atomic).
    /// Zero credential access, zero process kills, zero network, zero Desktop interaction.
    public func switchAccount(to account: AccountRecord, allowForceQuit: Bool) async -> SwitchResult {
        _ = allowForceQuit
        guard let activeURL = paths.activeProfileURL else {
            return .failed(Self.policyRefusalMessage)
        }
        guard let targetSlug = profileId(for: account.id) else {
            return .failed("未找到对应的 Claude CLI 配置")
        }
        guard targetSlug == Self.defaultProfileSlug || Self.isValidProfileSlug(targetSlug) else {
            return .failed("无效的 Claude CLI 配置标识")
        }
        do {
            let payload = Data("\(targetSlug)\n".utf8)
            try profileWriteLock.withLock {
                try Self.writeAtomicFile(data: payload, to: activeURL, mode: 0o600)
            }
            return .switched(reopenedApps: [])
        } catch {
            return .failed("写入 Claude CLI 活跃配置失败")
        }
    }

    public func controlClient(restart: Bool, allowForceQuit: Bool) async -> SwitchResult {
        _ = (restart, allowForceQuit)
        return .failed(Self.policyRefusalMessage)
    }

    public func hasStoredAPIKey() -> Bool {
        false
    }

    public func saveAPIKey(_ key: String, label: String?) throws {
        _ = (key, label)
        throw ProviderAdapterError.operationFailed(Self.policyRefusalMessage)
    }

    /// Non-destructively unregisters a non-default CLI profile from `claude-cli-profiles.json` and removes
    /// its statusLine quota cache JSON. Refuses/no-ops on `default`, resets `claude-active-profile` to
    /// `"default"` if the removed profile was active, and NEVER deletes `~/.claude-profiles/<id>` or credentials.
    public func deleteAccountCredentials(accountId: String) throws {
        guard let slug = profileId(for: accountId) else {
            return
        }
        if slug.lowercased() == Self.defaultProfileSlug {
            return
        }
        guard let profilesURL = paths.cliProfilesURL else {
            return
        }

        try profileWriteLock.withLock {
            if var root = readJSONDictionary(at: profilesURL, maxBytes: Self.maxCLIProfileBytes),
               let rawProfiles = root["profiles"] as? [[String: Any]] {
                let filtered = rawProfiles.filter { entry in
                    let entryId = Self.nonEmptyString(entry["id"])?.lowercased() ?? ""
                    return entryId != slug.lowercased()
                }
                if filtered.count != rawProfiles.count {
                    root["profiles"] = filtered
                    try Self.writeAtomicJSON(root, to: profilesURL, mode: 0o600)
                }
            }

            if let cacheDir = paths.statusLineCacheDirURL {
                let cacheFile = cacheDir.appendingPathComponent("\(slug).json", isDirectory: false)
                if fileManager.fileExists(atPath: cacheFile.path) {
                    try? fileManager.removeItem(at: cacheFile)
                }
            }

            if let activeURL = paths.activeProfileURL {
                let currentActive = readActiveProfileSlug()
                if currentActive.lowercased() == slug.lowercased() {
                    try Self.writeAtomicFile(
                        data: Data("\(Self.defaultProfileSlug)\n".utf8),
                        to: activeURL,
                        mode: 0o600
                    )
                }
            }
        }
    }

    // MARK: - Local Multi-Profile Management Helpers (Zero Network / Zero Secrets / Zero Process)

    /// Validates a new CLI profile slug (`^[a-z0-9][a-z0-9._-]{0,31}$`, excluding `default` and `desktop`).
    public static func isValidProfileSlug(_ rawSlug: String) -> Bool {
        let slug = rawSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty, slug.count <= 32 else { return false }
        if slug == defaultProfileSlug || slug == "desktop" {
            return false
        }
        if slug.contains("..") {
            return false
        }
        let scalars = Array(slug.unicodeScalars)
        guard let first = scalars.first, Self.isLowerAlphaNumeric(first) else {
            return false
        }
        for scalar in scalars.dropFirst() {
            if !(Self.isLowerAlphaNumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-") {
                return false
            }
        }
        return true
    }

    /// Reads the currently active default CLI profile slug from `activeProfileURL` (falls back to `"default"`).
    public func activeProfileId() -> String {
        readActiveProfileSlug()
    }

    /// Resolves the CLI profile slug (e.g. `"default"`, `"pro2"`) corresponding to a Pulsar `AccountRecord.id`.
    public func profileId(for accountId: String) -> String? {
        let trimmed = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let doc = loadProfilesDocument() {
            if doc.exclusions.isExcluded(email: nil, accountUuid: trimmed) {
                return nil
            }
            if let matched = matchProfile(forAccountId: trimmed, in: doc) {
                return matched.id
            }
            if !doc.isMultiProfileFile {
                // Single-profile legacy file: map known placeholder or non-excluded ID to default.
                if trimmed == Self.defaultLocalAccountId || trimmed == "claude:default" {
                    return Self.defaultProfileSlug
                }
            }
            return nil
        }

        // Pure legacy mode (no profiles file): single local default profile.
        if trimmed == Self.defaultLocalAccountId
            || trimmed == "claude:default"
            || trimmed == Self.defaultProfileSlug
            || trimmed == "\(Self.profileAccountIdPrefix)\(Self.defaultProfileSlug)" {
            return Self.defaultProfileSlug
        }
        let legacyDoc = readClaudeConfigDocument(at: paths.claudeConfigURL)
        let statusDoc = readStatusLineCacheDocument(at: paths.statusLineCacheURL)
        if let oauthUuid = legacyDoc?.oauthAccount?.accountUuid, Self.uuidsMatch(oauthUuid, trimmed) {
            return Self.defaultProfileSlug
        }
        if let statusUuid = statusDoc?.accountUuid, Self.uuidsMatch(statusUuid, trimmed) {
            return Self.defaultProfileSlug
        }
        return nil
    }

    /// Returns the terminal launch command (`CLAUDE_PROFILE=<slug> claude`) for a registered Claude account.
    public func launchCommand(for accountId: String) -> String? {
        guard let slug = profileId(for: accountId) else { return nil }
        return "CLAUDE_PROFILE=\(slug) claude"
    }

    /// Creates a new isolated Claude CLI profile directory (`0700`), copies & sanitizes `settings.json` (`0600`),
    /// symlinks shared read-only assets (`skills`, `statusline-command.sh`, etc.) if present, and atomically
    /// registers the profile in `claude-cli-profiles.json` (`0600`). Pure local file operations only.
    public func createCLIProfile(
        id rawId: String,
        label: String?,
        proxyPort: Int? = nil
    ) throws -> (profileId: String, launchCommand: String) {
        let slug = rawId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isValidProfileSlug(slug) else {
            throw ProviderAdapterError.operationFailed(
                "配置名仅支持 1-32 位小写字母、数字及 . _ -，以字母或数字开头，且不能为 default 或 desktop"
            )
        }
        guard let profilesURL = paths.cliProfilesURL else {
            throw ProviderAdapterError.operationFailed("未配置 Claude CLI 多账号文件路径")
        }

        let homeDir = fileManager.homeDirectoryForCurrentUser
        let baseDir = paths.profilesBaseDirURL
            ?? homeDir.appendingPathComponent(".claude-profiles", isDirectory: true)
        let profileDir = baseDir.appendingPathComponent(slug, isDirectory: true)
        let canonicalConfigDir = Self.stripTrailingSlash(profileDir.standardizedFileURL.path)

        let cleanLabel = Self.nonEmptyString(label) ?? slug

        try profileWriteLock.withLock {
            var root = loadOrSeedProfilesJSONObject(at: profilesURL)
            var rawProfiles = (root["profiles"] as? [[String: Any]]) ?? []
            if rawProfiles.contains(where: {
                Self.nonEmptyString($0["id"])?.lowercased() == slug
            }) {
                throw ProviderAdapterError.operationFailed("配置「\(slug)」已存在")
            }

            let rootDefaultPort: Int = {
                if let p = Self.parseInt(root["defaultProxyPort"]), (1...65535).contains(p) {
                    return p
                }
                return Self.defaultCLIProxyPort
            }()
            let effectiveProxyPort: Int = {
                if let explicit = proxyPort, (1...65535).contains(explicit) {
                    return explicit
                }
                return rootDefaultPort
            }()

            // 1. Create ~/.claude-profiles/<slug> (0700)
            try Self.ensureDirectory(at: baseDir, mode: 0o700)
            try Self.ensureDirectory(at: profileDir, mode: 0o700)

            // 2. Locate source ~/.claude template directory (strictly hermetic when tests use custom baseDir)
            let sourceClaudeDir = resolveSourceClaudeDirectory(homeDir: homeDir, profilesBaseDir: baseDir)

            // 3. Copy & sanitize settings.json (0600)
            var settingsDict: [String: Any] = [:]
            if let srcDir = sourceClaudeDir {
                let srcSettingsURL = srcDir.appendingPathComponent("settings.json", isDirectory: false)
                if let parsed = readJSONDictionary(at: srcSettingsURL, maxBytes: Self.maxSettingsBytes) {
                    settingsDict = parsed
                }
            }
            if var envDict = settingsDict["env"] as? [String: Any] {
                for key in Self.strippedProxyEnvKeys {
                    envDict.removeValue(forKey: key)
                }
                if envDict.isEmpty {
                    settingsDict.removeValue(forKey: "env")
                } else {
                    settingsDict["env"] = envDict
                }
            }

            let statusLineCommand = homeDir
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("pulsar-claude-statusline", isDirectory: false)
                .path
            var statusLineDict = (settingsDict["statusLine"] as? [String: Any]) ?? [:]
            if Self.nonEmptyString(statusLineDict["type"]) == nil {
                statusLineDict["type"] = "command"
            }
            statusLineDict["command"] = statusLineCommand
            settingsDict["statusLine"] = statusLineDict

            let dstSettingsURL = profileDir.appendingPathComponent("settings.json", isDirectory: false)
            try Self.writeAtomicJSON(settingsDict, to: dstSettingsURL, mode: 0o600)

            // 4. Symlink shared read-only directories/files (skills, statusline-command.sh, etc.) if present
            if let srcDir = sourceClaudeDir {
                for name in Self.sharedProfileSymlinkNames {
                    let srcItem = srcDir.appendingPathComponent(name, isDirectory: false)
                    let dstItem = profileDir.appendingPathComponent(name, isDirectory: false)
                    guard Self.pathOrSymlinkExists(at: srcItem.path),
                          !Self.pathOrSymlinkExists(at: dstItem.path) else {
                        continue
                    }
                    try? fileManager.createSymbolicLink(atPath: dstItem.path, withDestinationPath: srcItem.path)
                }
            }

            // 5. Register into claude-cli-profiles.json (0600 atomic)
            let newEntry: [String: Any] = [
                "id": slug,
                "label": cleanLabel,
                "configDir": canonicalConfigDir,
                "accountUuid": NSNull(),
                "email": NSNull(),
                "displayName": NSNull(),
                "plan": NSNull(),
                "planDisplayName": NSNull(),
                "billingType": NSNull(),
                "trustSharedClaudeJson": true,
                "proxyPort": effectiveProxyPort,
                "addedAt": Formatters.formatRFC3339UTC(Date()),
            ]
            rawProfiles.append(newEntry)
            root["schemaVersion"] = 2
            root["defaultProxyPort"] = rootDefaultPort
            root["profiles"] = rawProfiles
            try Self.writeAtomicJSON(root, to: profilesURL, mode: 0o600)
        }

        return (profileId: slug, launchCommand: "CLAUDE_PROFILE=\(slug) claude")
    }

    // MARK: - Dual-Source Passive Quota Reconciliation (Per-Profile)

    public func resolvePassiveQuota(now: Date = Date()) -> QuotaSnapshot {
        resolvePassiveQuota(accountId: nil, now: now)
    }

    public func resolvePassiveQuota(accountId explicitAccountId: String?, now: Date = Date()) -> QuotaSnapshot {
        let loadedDoc = loadProfilesDocument()
        let exclusions = loadedDoc?.exclusions ?? .empty

        let safeExplicitId: String?
        if let explicitAccountId,
           let trimmed = Self.nonEmptyString(explicitAccountId),
           !exclusions.isExcluded(email: nil, accountUuid: trimmed) {
            safeExplicitId = trimmed
        } else {
            safeExplicitId = nil
        }

        let targetProfile: CLIProfileEntry
        if let doc = loadedDoc {
            if let explicit = safeExplicitId,
               let matched = matchProfile(forAccountId: explicit, in: doc) {
                targetProfile = matched
            } else if doc.isMultiProfileFile {
                // If caller passed a specific non-placeholder accountId that does not belong to any
                // configured profile in multi-profile mode, do NOT bleed another profile's quota.
                if let explicit = safeExplicitId,
                   explicit != Self.defaultLocalAccountId,
                   explicit != "claude:default" {
                    return QuotaSnapshot(
                        provider: .claude,
                        accountId: explicit,
                        plan: PlanInfo(kind: .unknown, displayName: "Claude CLI"),
                        windows: [],
                        balance: nil,
                        status: .unconfigured(Self.passiveUnconfiguredMessage),
                        sourceLabel: "本地被动"
                    )
                }
                let activeSlug = readActiveProfileSlug()
                if let activeMatch = doc.profiles.first(where: { $0.id.lowercased() == activeSlug.lowercased() }) {
                    targetProfile = activeMatch
                } else if let defMatch = doc.profiles.first(where: { $0.id.lowercased() == Self.defaultProfileSlug }) {
                    targetProfile = defMatch
                } else if let first = doc.profiles.first {
                    targetProfile = first
                } else {
                    return QuotaSnapshot(
                        provider: .claude,
                        accountId: safeExplicitId ?? Self.defaultLocalAccountId,
                        plan: PlanInfo(kind: .unknown, displayName: "Claude CLI"),
                        windows: [],
                        balance: nil,
                        status: .unconfigured(Self.passiveUnconfiguredMessage),
                        sourceLabel: "本地被动"
                    )
                }
            } else {
                targetProfile = doc.profiles.first ?? CLIProfileEntry.implicitLegacyDefault
            }
        } else {
            targetProfile = CLIProfileEntry.implicitLegacyDefault
        }

        // Enforce Desktop exclusion even if a profile entry itself holds an excluded identity.
        if exclusions.isExcluded(email: targetProfile.email, accountUuid: targetProfile.accountUuid) {
            return QuotaSnapshot(
                provider: .claude,
                accountId: safeExplicitId ?? "\(Self.profileAccountIdPrefix)\(targetProfile.id)",
                plan: PlanInfo(kind: .unknown, displayName: "Claude CLI"),
                windows: [],
                balance: nil,
                status: .unconfigured(Self.passiveUnconfiguredMessage),
                sourceLabel: "本地被动"
            )
        }

        return resolvePassiveQuota(
            for: targetProfile,
            exclusions: exclusions,
            explicitAccountId: safeExplicitId,
            isMultiProfileMode: loadedDoc?.isMultiProfileFile ?? false,
            now: now
        )
    }

    private func resolvePassiveQuota(
        for profile: CLIProfileEntry,
        exclusions: DesktopExclusions,
        explicitAccountId: String?,
        isMultiProfileMode: Bool,
        now: Date
    ) -> QuotaSnapshot {
        let claudeConfigURL = route1ConfigURL(for: profile)
        let claudeDoc = readClaudeConfigDocument(at: claudeConfigURL)
        let rawStatusDoc = readBestStatusLineCacheDocument(for: profile, exclusions: exclusions)

        let oauth = Self.filterOAuthAccount(
            claudeDoc?.oauthAccount,
            profile: profile,
            exclusions: exclusions
        )
        let statusDoc = Self.filterStatusLineCache(rawStatusDoc, exclusions: exclusions)

        let pinnedUuid = profile.accountUuid
        let activeUuid = Self.firstNonEmpty(pinnedUuid, oauth?.accountUuid)

        // Route 1 (`<configDir>/.claude.json` or gated `~/.claude.json`):
        // reject Desktop-excluded or mismatched accountUuid snapshots.
        // When `trustSharedClaudeJson == false`, accept Route 1 ONLY if its `accountUuid` explicitly matches `pinnedUuid`.
        let route1: PassiveSourceReading?
        if let cached = claudeDoc?.cachedUsage {
            let excluded = exclusions.isExcluded(email: nil, accountUuid: cached.accountUuid)
            let sharedBlocked: Bool
            if !profile.trustSharedClaudeJson {
                if let pinnedUuid, let cachedUuid = cached.accountUuid {
                    sharedBlocked = !Self.uuidsMatch(pinnedUuid, cachedUuid)
                } else {
                    sharedBlocked = true
                }
            } else {
                sharedBlocked = false
            }

            if excluded || sharedBlocked {
                route1 = nil
            } else if let activeUuid, let cachedUuid = cached.accountUuid,
                      !Self.uuidsMatch(activeUuid, cachedUuid) {
                route1 = nil
            } else {
                route1 = PassiveSourceReading(
                    sourceLabel: "本地缓存",
                    observedAt: cached.fetchedAt,
                    accountUuid: cached.accountUuid ?? activeUuid,
                    fiveHour: cached.fiveHour,
                    sevenDay: cached.sevenDay
                )
            }
        } else {
            route1 = nil
        }

        // Route 2 (`<statusLineCacheDir>/<profileId>.json`, plus legacy `claude-cli-quota.json` for `default`):
        // already Desktop-filtered; enforce accountUuid consistency when known.
        let route2: PassiveSourceReading?
        if let statusDoc, (statusDoc.fiveHour != nil || statusDoc.sevenDay != nil) {
            if let activeUuid, let statusUuid = statusDoc.accountUuid,
               !Self.uuidsMatch(activeUuid, statusUuid) {
                route2 = nil
            } else {
                route2 = PassiveSourceReading(
                    sourceLabel: "本地状态栏",
                    observedAt: statusDoc.observedAt,
                    accountUuid: statusDoc.accountUuid ?? activeUuid,
                    fiveHour: statusDoc.fiveHour,
                    sevenDay: statusDoc.sevenDay
                )
            }
        } else {
            route2 = nil
        }

        let fallbackId = isMultiProfileMode
            ? "\(Self.profileAccountIdPrefix)\(profile.id)"
            : Self.defaultLocalAccountId
        let resolvedAccountId = Self.firstNonEmpty(
            explicitAccountId,
            activeUuid,
            route2?.accountUuid,
            route1?.accountUuid
        ) ?? fallbackId

        let resolvedPlan = Self.resolvePlan(profile: profile, oauth: oauth, statusLine: statusDoc)

        // Choose newer source as primary; keep older source for same-account future-window backfill.
        let primary: PassiveSourceReading
        let secondary: PassiveSourceReading?
        switch (route2, route1) {
        case (let s2?, let s1?):
            if s2.observedAt >= s1.observedAt {
                primary = s2
                secondary = s1
            } else {
                primary = s1
                secondary = s2
            }
        case (let s2?, nil):
            primary = s2
            secondary = nil
        case (nil, let s1?):
            primary = s1
            secondary = nil
        case (nil, nil):
            return QuotaSnapshot(
                provider: .claude,
                accountId: resolvedAccountId,
                plan: resolvedPlan,
                windows: [],
                balance: nil,
                status: .unconfigured(Self.passiveUnconfiguredMessage),
                sourceLabel: "本地被动"
            )
        }

        var fiveHour = primary.fiveHour
        var sevenDay = primary.sevenDay

        if let secondary, Self.sameAccount(primary.accountUuid, secondary.accountUuid) {
            if fiveHour == nil,
               let fallback5h = secondary.fiveHour,
               let resetAt = fallback5h.resetsAt,
               resetAt > now {
                fiveHour = fallback5h
            }
            if sevenDay == nil,
               let fallback7d = secondary.sevenDay,
               let resetAt = fallback7d.resetsAt,
               resetAt > now {
                sevenDay = fallback7d
            }
        }

        var windows: [QuotaWindow] = []
        var anyResetElapsed = false

        if let sample5h = fiveHour {
            let (win, elapsed) = Self.makeQuotaWindow(
                id: "claude_5h",
                label: "Claude · 5小时",
                windowSeconds: 18_000,
                isPrimary: true,
                sample: sample5h,
                now: now
            )
            if elapsed { anyResetElapsed = true }
            windows.append(win)
        }

        if let sample7d = sevenDay {
            let (win, elapsed) = Self.makeQuotaWindow(
                id: "claude_weekly",
                label: "Claude · 周",
                windowSeconds: 604_800,
                isPrimary: fiveHour == nil,
                sample: sample7d,
                now: now
            )
            if elapsed { anyResetElapsed = true }
            windows.append(win)
        }

        guard !windows.isEmpty else {
            return QuotaSnapshot(
                provider: .claude,
                accountId: resolvedAccountId,
                plan: resolvedPlan,
                windows: [],
                balance: nil,
                status: .unconfigured(Self.passiveUnconfiguredMessage),
                sourceLabel: "本地被动"
            )
        }

        let isStale = (now.timeIntervalSince(primary.observedAt) > Self.staleThresholdSeconds) || anyResetElapsed
        return QuotaSnapshot(
            provider: .claude,
            accountId: resolvedAccountId,
            plan: resolvedPlan,
            windows: windows,
            balance: nil,
            status: .ready(fetchedAt: primary.observedAt, stale: isStale),
            sourceLabel: primary.sourceLabel
        )
    }

    // MARK: - CLI Process Matcher (Strict Desktop Exclusion)

    /// Returns `true` ONLY for standalone Claude CLI executables (e.g. Homebrew or `~/.local/bin/claude`),
    /// strictly excluding `/Applications/Claude.app`, any `.app` bundle, and Claude Desktop support paths.
    public static func isClaudeCLIExecutablePath(_ path: String, bundleId: String? = nil) -> Bool {
        if let bundleId, !bundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()

        // Hard exclusion: NEVER match Claude Desktop or any macOS .app bundle or Desktop support directory.
        if lower.contains("/applications/claude.app")
            || lower.contains("claude.app/")
            || lower.hasSuffix("claude.app")
            || lower.contains("/library/application support/claude")
            || lower.contains(".app/contents/") {
            return false
        }

        let lastComponent = URL(fileURLWithPath: trimmed).lastPathComponent.lowercased()

        // Native Claude Code binary under ~/.local/share/claude/versions/<semver>
        if lower.contains("/.local/share/claude/versions/") && !lastComponent.isEmpty {
            return true
        }

        guard lastComponent == "claude" else {
            return false
        }

        // Accept standard CLI install locations (Homebrew, ~/.local/bin, /usr/local, node/bun version managers).
        if lower.hasPrefix("/opt/homebrew/")
            || lower.hasPrefix("/usr/local/")
            || lower.contains("/.local/bin/")
            || lower.contains("/.local/share/claude/")
            || lower.contains("/.nvm/")
            || lower.contains("/.volta/")
            || lower.contains("/.asdf/")
            || lower.contains("/.fnm/")
            || lower.contains("/.bun/") {
            return true
        }
        return false
    }

    // MARK: - Internal Parsed Models

    private struct DesktopExclusions {
        let emails: Set<String>
        let accountUuids: Set<String>

        static let empty = DesktopExclusions(emails: [], accountUuids: [])

        func isExcluded(email candidateEmail: String?, accountUuid candidateUuid: String?) -> Bool {
            if let e = candidateEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !e.isEmpty,
               emails.contains(e) {
                return true
            }
            if let u = candidateUuid?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !u.isEmpty,
               accountUuids.contains(u) {
                return true
            }
            return false
        }
    }

    private struct CLIProfileEntry {
        let id: String
        let label: String?
        let configDir: String?
        let accountUuid: String?
        let email: String?
        let displayName: String?
        let plan: String?
        let planDisplayName: String?
        let billingType: String?
        let trustSharedClaudeJson: Bool
        let proxyPort: Int?
        let addedAt: Date?

        static let implicitLegacyDefault = CLIProfileEntry(
            id: ClaudeProvider.defaultProfileSlug,
            label: nil,
            configDir: nil,
            accountUuid: nil,
            email: nil,
            displayName: nil,
            plan: nil,
            planDisplayName: nil,
            billingType: nil,
            trustSharedClaudeJson: true,
            proxyPort: nil,
            addedAt: nil
        )
    }

    private struct CLIProfilesDocument {
        let isMultiProfileFile: Bool
        let defaultProxyPort: Int
        let exclusions: DesktopExclusions
        let profiles: [CLIProfileEntry]
    }

    private struct InspectedProfileData {
        let accountUuid: String?
        let email: String?
        let displayName: String?
        let plan: PlanInfo
    }

    private struct OAuthAccountMetadata {
        let accountUuid: String?
        let email: String?
        let displayName: String?
        let billingType: String?
        let organizationType: String?
        let organizationRateLimitTier: String?
    }

    private struct PassiveWindowSample {
        let usedPercent: Double
        let resetsAt: Date?
    }

    private struct CachedUsageSection {
        let fetchedAt: Date
        let accountUuid: String?
        let fiveHour: PassiveWindowSample?
        let sevenDay: PassiveWindowSample?
    }

    private struct ClaudeConfigDocument {
        let oauthAccount: OAuthAccountMetadata?
        let cachedUsage: CachedUsageSection?
    }

    private struct StatusLineCacheDocument {
        let observedAt: Date
        let accountUuid: String?
        let email: String?
        let displayName: String?
        let billingType: String?
        let plan: String?
        let planDisplayName: String?
        let fiveHour: PassiveWindowSample?
        let sevenDay: PassiveWindowSample?
    }

    private struct PassiveSourceReading {
        let sourceLabel: String
        let observedAt: Date
        let accountUuid: String?
        let fiveHour: PassiveWindowSample?
        let sevenDay: PassiveWindowSample?
    }

    // MARK: - Profile & Cache Resolution Helpers

    private func loadProfilesDocument() -> CLIProfilesDocument? {
        if let profilesURL = paths.cliProfilesURL,
           let root = readJSONDictionary(at: profilesURL, maxBytes: Self.maxCLIProfileBytes),
           let rawProfiles = root["profiles"] as? [[String: Any]] {
            let excludedEmails = Self.normalizedStringSet(root["excludeDesktopEmails"])
            let excludedUuids = Self.normalizedStringSet(root["excludeDesktopAccountUuids"])
            let exclusions = DesktopExclusions(emails: excludedEmails, accountUuids: excludedUuids)
            let defaultPort = Self.parseInt(root["defaultProxyPort"]) ?? Self.defaultCLIProxyPort

            var parsedProfiles: [CLIProfileEntry] = []
            var seenIds = Set<String>()
            for item in rawProfiles {
                guard let rawId = Self.nonEmptyString(item["id"]) else { continue }
                let slug = rawId.lowercased()
                guard seenIds.insert(slug).inserted else { continue }

                let configDir: String?
                if let rawDir = Self.nonEmptyString(item["configDir"]) {
                    let expanded = (rawDir as NSString).expandingTildeInPath
                    configDir = Self.stripTrailingSlash(expanded)
                } else {
                    configDir = nil
                }

                let trustShared: Bool
                if let flag = item["trustSharedClaudeJson"] as? Bool {
                    trustShared = flag
                } else {
                    trustShared = (configDir != nil)
                }

                parsedProfiles.append(
                    CLIProfileEntry(
                        id: rawId,
                        label: Self.nonEmptyString(item["label"]),
                        configDir: configDir,
                        accountUuid: Self.nonEmptyString(item["accountUuid"]),
                        email: Self.nonEmptyString(item["email"]),
                        displayName: Self.nonEmptyString(item["displayName"]),
                        plan: Self.nonEmptyString(item["plan"]),
                        planDisplayName: Self.nonEmptyString(item["planDisplayName"]),
                        billingType: Self.nonEmptyString(item["billingType"]),
                        trustSharedClaudeJson: trustShared,
                        proxyPort: Self.parseInt(item["proxyPort"]),
                        addedAt: Self.parseFlexibleTimestamp(item["addedAt"])
                    )
                )
            }

            return CLIProfilesDocument(
                isMultiProfileFile: true,
                defaultProxyPort: defaultPort,
                exclusions: exclusions,
                profiles: parsedProfiles
            )
        }

        return loadLegacySingleProfileDocument()
    }

    private func loadLegacySingleProfileDocument() -> CLIProfilesDocument? {
        guard let url = paths.cliProfileURL,
              let root = readJSONDictionary(at: url, maxBytes: Self.maxCLIProfileBytes) else {
            return nil
        }
        let excludedEmails = Self.normalizedStringSet(root["excludeDesktopEmails"])
        let excludedUuids = Self.normalizedStringSet(root["excludeDesktopAccountUuids"])
        let trustShared: Bool
        if let flag = root["trustSharedClaudeJson"] as? Bool {
            trustShared = flag
        } else {
            trustShared = true
        }
        let entry = CLIProfileEntry(
            id: Self.defaultProfileSlug,
            label: Self.nonEmptyString(root["label"]),
            configDir: nil,
            accountUuid: Self.nonEmptyString(root["accountUuid"]),
            email: Self.nonEmptyString(root["email"]),
            displayName: Self.nonEmptyString(root["displayName"]),
            plan: Self.nonEmptyString(root["plan"]),
            planDisplayName: Self.nonEmptyString(root["planDisplayName"]),
            billingType: Self.nonEmptyString(root["billingType"]),
            trustSharedClaudeJson: trustShared,
            proxyPort: Self.parseInt(root["proxyPort"]),
            addedAt: Self.parseFlexibleTimestamp(root["addedAt"])
        )
        return CLIProfilesDocument(
            isMultiProfileFile: false,
            defaultProxyPort: Self.defaultCLIProxyPort,
            exclusions: DesktopExclusions(emails: excludedEmails, accountUuids: excludedUuids),
            profiles: [entry]
        )
    }

    private func readActiveProfileSlug() -> String {
        guard let url = paths.activeProfileURL,
              fileManager.fileExists(atPath: url.path) else {
            return Self.defaultProfileSlug
        }
        if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
           let sizeNum = attrs[.size] as? NSNumber,
           sizeNum.intValue > Self.maxActiveProfileBytes {
            return Self.defaultProfileSlug
        }
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) else {
            return Self.defaultProfileSlug
        }
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return Self.defaultProfileSlug
    }

    private func route1ConfigURL(for profile: CLIProfileEntry) -> URL {
        if let configDir = profile.configDir {
            return URL(fileURLWithPath: configDir, isDirectory: true)
                .appendingPathComponent(".claude.json", isDirectory: false)
        }
        return paths.claudeConfigURL
    }

    private func readBestStatusLineCacheDocument(
        for profile: CLIProfileEntry,
        exclusions: DesktopExclusions
    ) -> StatusLineCacheDocument? {
        var candidates: [StatusLineCacheDocument] = []
        if let cacheDir = paths.statusLineCacheDirURL {
            let perProfileURL = cacheDir.appendingPathComponent("\(profile.id).json", isDirectory: false)
            if let doc = Self.filterStatusLineCache(readStatusLineCacheDocument(at: perProfileURL), exclusions: exclusions) {
                candidates.append(doc)
            }
        }
        // Only the `default` profile may fall back to legacy single-file `claude-cli-quota.json`.
        if profile.id.lowercased() == Self.defaultProfileSlug {
            if let doc = Self.filterStatusLineCache(
                readStatusLineCacheDocument(at: paths.statusLineCacheURL),
                exclusions: exclusions
            ) {
                candidates.append(doc)
            }
        }
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }
        return candidates[0].observedAt >= candidates[1].observedAt ? candidates[0] : candidates[1]
    }

    private func inspectProfileData(
        _ profile: CLIProfileEntry,
        exclusions: DesktopExclusions
    ) -> InspectedProfileData {
        let claudeDoc = readClaudeConfigDocument(at: route1ConfigURL(for: profile))
        let oauth = Self.filterOAuthAccount(
            claudeDoc?.oauthAccount,
            profile: profile,
            exclusions: exclusions
        )
        let statusDoc = readBestStatusLineCacheDocument(for: profile, exclusions: exclusions)

        let accountUuid = Self.firstNonEmpty(profile.accountUuid, oauth?.accountUuid, statusDoc?.accountUuid)
        let email = Self.firstNonEmpty(profile.email, oauth?.email, statusDoc?.email)
        let displayName = Self.firstNonEmpty(profile.displayName, oauth?.displayName, statusDoc?.displayName)
        let plan = Self.resolvePlan(profile: profile, oauth: oauth, statusLine: statusDoc)

        return InspectedProfileData(
            accountUuid: accountUuid,
            email: email,
            displayName: displayName,
            plan: plan
        )
    }

    private func matchProfile(
        forAccountId accountId: String,
        in doc: CLIProfilesDocument
    ) -> CLIProfileEntry? {
        // 1. Direct match by static accountUuid, placeholder ID (`claude-profile:<slug>`), or raw slug.
        for profile in doc.profiles {
            if doc.exclusions.isExcluded(email: profile.email, accountUuid: profile.accountUuid) {
                continue
            }
            if let uuid = profile.accountUuid, Self.uuidsMatch(uuid, accountId) {
                return profile
            }
            if Self.uuidsMatch("\(Self.profileAccountIdPrefix)\(profile.id)", accountId) {
                return profile
            }
            if Self.uuidsMatch(profile.id, accountId) {
                return profile
            }
        }

        // 2. Dynamic match against isolated `<configDir>/.claude.json` or per-profile statusLine cache
        //    (covers newly logged-in profiles whose accountUuid was discovered live before config backfill).
        for profile in doc.profiles {
            if doc.exclusions.isExcluded(email: profile.email, accountUuid: profile.accountUuid) {
                continue
            }
            let inspected = inspectProfileData(profile, exclusions: doc.exclusions)
            if let liveUuid = inspected.accountUuid, Self.uuidsMatch(liveUuid, accountId) {
                return profile
            }
        }

        return nil
    }

    private func loadOrSeedProfilesJSONObject(at profilesURL: URL) -> [String: Any] {
        if let existing = readJSONDictionary(at: profilesURL, maxBytes: Self.maxCLIProfileBytes),
           existing["profiles"] is [[String: Any]] {
            return existing
        }

        var excludedEmails: [String] = []
        var excludedUuids: [String] = []
        var defaultEntry: [String: Any] = [
            "id": Self.defaultProfileSlug,
            "label": "主账号",
            "configDir": NSNull(),
            "accountUuid": NSNull(),
            "email": NSNull(),
            "displayName": NSNull(),
            "plan": NSNull(),
            "planDisplayName": NSNull(),
            "billingType": NSNull(),
            "trustSharedClaudeJson": false,
            "proxyPort": Self.defaultCLIProxyPort,
            "addedAt": Formatters.formatRFC3339UTC(Date()),
        ]

        if let legacyURL = paths.cliProfileURL,
           let legacy = readJSONDictionary(at: legacyURL, maxBytes: Self.maxCLIProfileBytes) {
            if let emails = legacy["excludeDesktopEmails"] as? [String] {
                excludedEmails = emails
            }
            if let uuids = legacy["excludeDesktopAccountUuids"] as? [String] {
                excludedUuids = uuids
            }
            if let v = Self.nonEmptyString(legacy["accountUuid"]) { defaultEntry["accountUuid"] = v }
            if let v = Self.nonEmptyString(legacy["email"]) { defaultEntry["email"] = v }
            if let v = Self.nonEmptyString(legacy["displayName"]) { defaultEntry["displayName"] = v }
            if let v = Self.nonEmptyString(legacy["plan"]) { defaultEntry["plan"] = v }
            if let v = Self.nonEmptyString(legacy["planDisplayName"]) { defaultEntry["planDisplayName"] = v }
            if let v = Self.nonEmptyString(legacy["billingType"]) { defaultEntry["billingType"] = v }
            if let flag = legacy["trustSharedClaudeJson"] as? Bool {
                defaultEntry["trustSharedClaudeJson"] = flag
            }
        }

        return [
            "schemaVersion": 2,
            "defaultProxyPort": Self.defaultCLIProxyPort,
            "excludeDesktopEmails": excludedEmails,
            "excludeDesktopAccountUuids": excludedUuids,
            "profiles": [defaultEntry],
        ]
    }

    private func resolveSourceClaudeDirectory(homeDir: URL, profilesBaseDir: URL) -> URL? {
        let siblingClaude = paths.claudeConfigURL
            .deletingLastPathComponent()
            .appendingPathComponent(".claude", isDirectory: true)
        if fileManager.fileExists(atPath: siblingClaude.path) {
            return siblingClaude
        }
        let defaultProfilesBase = homeDir
            .appendingPathComponent(".claude-profiles", isDirectory: true)
            .standardizedFileURL.path
        let isLiveDefaultBase = profilesBaseDir.standardizedFileURL.path == defaultProfilesBase
        if isLiveDefaultBase {
            let homeClaude = homeDir.appendingPathComponent(".claude", isDirectory: true)
            if fileManager.fileExists(atPath: homeClaude.path) {
                return homeClaude
            }
        }
        return nil
    }

    // MARK: - Local JSON Readers (Strict Non-Secret Extraction)

    private func readJSONDictionary(at url: URL, maxBytes: Int) -> [String: Any]? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
           let sizeNum = attrs[.size] as? NSNumber,
           sizeNum.intValue > maxBytes {
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              !data.isEmpty,
              data.count <= maxBytes,
              let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }
        return root
    }

    private static func filterOAuthAccount(
        _ oauth: OAuthAccountMetadata?,
        profile: CLIProfileEntry,
        exclusions: DesktopExclusions
    ) -> OAuthAccountMetadata? {
        guard let oauth else { return nil }
        if !profile.trustSharedClaudeJson {
            return nil
        }
        if exclusions.isExcluded(email: oauth.email, accountUuid: oauth.accountUuid) {
            return nil
        }
        return oauth
    }

    private static func filterStatusLineCache(
        _ doc: StatusLineCacheDocument?,
        exclusions: DesktopExclusions
    ) -> StatusLineCacheDocument? {
        guard let doc else { return nil }
        if exclusions.isExcluded(email: doc.email, accountUuid: doc.accountUuid) {
            return nil
        }
        return doc
    }

    private func readClaudeConfigDocument(at url: URL) -> ClaudeConfigDocument? {
        guard let root = readJSONDictionary(at: url, maxBytes: Self.maxClaudeConfigBytes) else {
            return nil
        }

        let oauth: OAuthAccountMetadata?
        if let oa = root["oauthAccount"] as? [String: Any] {
            let uuid = Self.nonEmptyString(oa["accountUuid"])
            let email = Self.nonEmptyString(oa["emailAddress"])
            let display = Self.firstNonEmpty(
                Self.nonEmptyString(oa["displayName"]),
                Self.nonEmptyString(oa["fullName"])
            )
            let billing = Self.nonEmptyString(oa["billingType"])
            let orgType = Self.nonEmptyString(oa["organizationType"])
            let tier = Self.nonEmptyString(oa["organizationRateLimitTier"])
            if uuid != nil || email != nil || display != nil || billing != nil || orgType != nil || tier != nil {
                oauth = OAuthAccountMetadata(
                    accountUuid: uuid,
                    email: email,
                    displayName: display,
                    billingType: billing,
                    organizationType: orgType,
                    organizationRateLimitTier: tier
                )
            } else {
                oauth = nil
            }
        } else {
            oauth = nil
        }

        let cachedUsage: CachedUsageSection?
        if let cu = root["cachedUsageUtilization"] as? [String: Any],
           let util = cu["utilization"] as? [String: Any],
           let fetchedAt = Self.parseFlexibleTimestamp(cu["fetchedAtMs"] ?? cu["fetchedAt"]) {
            let cachedUuid = Self.nonEmptyString(cu["accountUuid"])

            var fiveHour = Self.parseClaudeConfigWindow(util["five_hour"])
            var sevenDay = Self.parseClaudeConfigWindow(util["seven_day"])

            if (fiveHour == nil || sevenDay == nil),
               let limits = util["limits"] as? [[String: Any]] {
                for entry in limits {
                    let kind = Self.nonEmptyString(entry["kind"])?.lowercased() ?? ""
                    let group = Self.nonEmptyString(entry["group"])?.lowercased() ?? ""
                    if fiveHour == nil && (kind == "five_hour" || kind == "session" || group == "session" || group == "five_hour") {
                        fiveHour = Self.parseClaudeConfigWindow(entry)
                    } else if sevenDay == nil && (kind == "seven_day" || kind == "weekly_all" || kind == "weekly" || group == "weekly" || group == "seven_day") {
                        sevenDay = Self.parseClaudeConfigWindow(entry)
                    }
                }
            }

            if fiveHour != nil || sevenDay != nil {
                cachedUsage = CachedUsageSection(
                    fetchedAt: fetchedAt,
                    accountUuid: cachedUuid,
                    fiveHour: fiveHour,
                    sevenDay: sevenDay
                )
            } else {
                cachedUsage = nil
            }
        } else {
            cachedUsage = nil
        }

        return ClaudeConfigDocument(oauthAccount: oauth, cachedUsage: cachedUsage)
    }

    private func readStatusLineCacheDocument(at url: URL) -> StatusLineCacheDocument? {
        guard let root = readJSONDictionary(at: url, maxBytes: Self.maxStatusLineCacheBytes) else {
            return nil
        }
        guard let observedAt = Self.parseFlexibleTimestamp(root["observedAt"]) else {
            return nil
        }

        let fiveHour = Self.parseStatusLineWindow(root["fiveHour"] ?? root["five_hour"])
        let sevenDay = Self.parseStatusLineWindow(root["sevenDay"] ?? root["seven_day"])
        guard fiveHour != nil || sevenDay != nil else {
            return nil
        }

        return StatusLineCacheDocument(
            observedAt: observedAt,
            accountUuid: Self.nonEmptyString(root["accountUuid"]),
            email: Self.nonEmptyString(root["email"]),
            displayName: Self.nonEmptyString(root["displayName"]),
            billingType: Self.nonEmptyString(root["billingType"]),
            plan: Self.nonEmptyString(root["plan"]),
            planDisplayName: Self.nonEmptyString(root["planDisplayName"]),
            fiveHour: fiveHour,
            sevenDay: sevenDay
        )
    }

    // MARK: - Window, Plan & Timestamp Normalization

    private static func parseClaudeConfigWindow(_ raw: Any?) -> PassiveWindowSample? {
        guard let dict = raw as? [String: Any] else { return nil }
        guard let used = parseDouble(dict["utilization"] ?? dict["percent"] ?? dict["usedPercent"] ?? dict["used_percentage"]) else {
            return nil
        }
        let resetsAt = parseFlexibleTimestamp(dict["resets_at"] ?? dict["resetsAt"])
        return PassiveWindowSample(
            usedPercent: min(max(used, 0.0), 100.0),
            resetsAt: resetsAt
        )
    }

    private static func parseStatusLineWindow(_ raw: Any?) -> PassiveWindowSample? {
        guard let dict = raw as? [String: Any] else { return nil }
        guard let used = parseDouble(dict["usedPercent"] ?? dict["used_percentage"] ?? dict["utilization"] ?? dict["percent"]) else {
            return nil
        }
        let resetsAt = parseFlexibleTimestamp(dict["resetsAt"] ?? dict["resets_at"])
        return PassiveWindowSample(
            usedPercent: min(max(used, 0.0), 100.0),
            resetsAt: resetsAt
        )
    }

    private static func makeQuotaWindow(
        id: String,
        label: String,
        windowSeconds: Int,
        isPrimary: Bool,
        sample: PassiveWindowSample,
        now: Date
    ) -> (window: QuotaWindow, resetElapsed: Bool) {
        if let resetAt = sample.resetsAt, resetAt <= now {
            let window = QuotaWindow(
                id: id,
                label: label,
                remainingFraction: 1.0,
                usedPercent: 0.0,
                resetAt: nil,
                windowSeconds: windowSeconds,
                detail: resetElapsedDetailMessage,
                isPrimary: isPrimary
            )
            return (window, true)
        }

        let clampedUsed = min(max(sample.usedPercent, 0.0), 100.0)
        let remainingFraction = min(max((100.0 - clampedUsed) / 100.0, 0.0), 1.0)
        let window = QuotaWindow(
            id: id,
            label: label,
            remainingFraction: remainingFraction,
            usedPercent: clampedUsed,
            resetAt: sample.resetsAt,
            windowSeconds: windowSeconds,
            detail: nil,
            isPrimary: isPrimary
        )
        return (window, false)
    }

    private static func resolvePlan(
        profile: CLIProfileEntry?,
        oauth: OAuthAccountMetadata?,
        statusLine: StatusLineCacheDocument?
    ) -> PlanInfo {
        let hints = [
            profile?.planDisplayName,
            profile?.plan,
            statusLine?.planDisplayName,
            statusLine?.plan,
            oauth?.organizationRateLimitTier,
            oauth?.organizationType,
            oauth?.billingType,
            statusLine?.billingType,
            profile?.billingType,
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        for hint in hints {
            if hint.contains("max") {
                if hint.contains("20x") {
                    return PlanInfo(kind: .max, displayName: "Max 20x")
                }
                if hint.contains("5x") {
                    return PlanInfo(kind: .max, displayName: "Max 5x")
                }
                return PlanInfo(kind: .max, displayName: "Max")
            }
            if hint.contains("enterprise") {
                return PlanInfo(kind: .enterprise, displayName: "Enterprise")
            }
            if hint.contains("team") {
                return PlanInfo(kind: .team, displayName: "Team")
            }
            if hint.contains("pro") {
                return PlanInfo(kind: .pro, displayName: "Pro")
            }
            if hint.contains("free") {
                return PlanInfo(kind: .free, displayName: "Free")
            }
            if hint.contains("api") {
                return PlanInfo(kind: .api, displayName: "API")
            }
        }

        return PlanInfo(kind: .unknown, displayName: "Claude CLI")
    }

    // MARK: - Pure-POSIX Atomic Local File Helpers (0700 Dirs / 0600 Files)

    private static func ensureDirectory(at url: URL, mode: mode_t = 0o700) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: mode)]
            )
        }
        if Darwin.chmod(url.path, mode) != 0 {
            throw ProviderAdapterError.operationFailed("设置目录权限失败 (errno=\(errno))")
        }
    }

    private static func writeAtomicJSON(_ object: [String: Any], to url: URL, mode: mode_t = 0o600) throws {
        var encoded = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        encoded.append(0x0A)
        try writeAtomicFile(data: encoded, to: url, mode: mode)
    }

    private static func writeAtomicFile(data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try ensureDirectory(at: dir, mode: 0o700)
        }

        let tempName = ".\(url.lastPathComponent).tmp.\(UUID().uuidString)"
        let tempURL = dir.appendingPathComponent(tempName, isDirectory: false)
        let tempPath = tempURL.path

        let fd = Darwin.open(tempPath, O_CREAT | O_EXCL | O_WRONLY, mode)
        if fd < 0 {
            throw ProviderAdapterError.operationFailed("创建临时文件失败 (errno=\(errno))")
        }

        var closed = false
        var renamed = false
        defer {
            if !closed {
                _ = Darwin.close(fd)
            }
            if !renamed {
                _ = Darwin.unlink(tempPath)
            }
        }

        if Darwin.fchmod(fd, mode) != 0 {
            throw ProviderAdapterError.operationFailed("设置文件权限失败 (errno=\(errno))")
        }

        try data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var written = 0
            while written < rawBuf.count {
                let n = Darwin.write(fd, base.advanced(by: written), rawBuf.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ProviderAdapterError.operationFailed("写入文件失败 (errno=\(errno))")
                }
                written += n
            }
        }

        if Darwin.fsync(fd) != 0 {
            throw ProviderAdapterError.operationFailed("同步文件失败 (errno=\(errno))")
        }

        if Darwin.close(fd) != 0 {
            closed = true
            throw ProviderAdapterError.operationFailed("关闭临时文件失败 (errno=\(errno))")
        }
        closed = true

        if Darwin.rename(tempPath, url.path) != 0 {
            throw ProviderAdapterError.operationFailed("原子替换文件失败 (errno=\(errno))")
        }
        renamed = true
    }

    private static func pathOrSymlinkExists(at path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    private static func stripTrailingSlash(_ path: String) -> String {
        var s = path
        while s.count > 1 && s.hasSuffix("/") {
            s.removeLast()
        }
        return s
    }

    private static func isLowerAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
        (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
    }

    // MARK: - Parsing Utilities

    private static func parseFlexibleTimestamp(_ raw: Any?) -> Date? {
        guard let raw, !(raw is NSNull) else { return nil }
        if let str = raw as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let parsed = Formatters.parseRFC3339(trimmed) {
                return parsed
            }
            if let numeric = Double(trimmed), numeric.isFinite, numeric > 0 {
                return dateFromUnixNumber(numeric)
            }
            return nil
        }
        if let num = parseDouble(raw), num > 0 {
            return dateFromUnixNumber(num)
        }
        return nil
    }

    private static func dateFromUnixNumber(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        let seconds = value > 100_000_000_000.0 ? (value / 1000.0) : value
        // Sanity bounds: year 2001 .. year 2150
        guard seconds >= 978_307_200.0 && seconds <= 5_680_281_600.0 else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func parseDouble(_ raw: Any?) -> Double? {
        guard let raw, !(raw is NSNull) else { return nil }
        if raw is Bool { return nil }
        if let d = raw as? Double, d.isFinite { return d }
        if let i = raw as? Int { return Double(i) }
        if let i64 = raw as? Int64 { return Double(i64) }
        if let n = raw as? NSNumber {
            // Guard against CFBoolean bridging to NSNumber
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let s = raw as? String,
           let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)),
           d.isFinite {
            return d
        }
        return nil
    }

    private static func parseInt(_ raw: Any?) -> Int? {
        guard let raw, !(raw is NSNull) else { return nil }
        if raw is Bool { return nil }
        if let i = raw as? Int { return i }
        if let i64 = raw as? Int64 { return Int(i64) }
        if let n = raw as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.intValue
        }
        if let s = raw as? String {
            return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let str = raw as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedStringSet(_ raw: Any?) -> Set<String> {
        guard let arr = raw as? [Any] else { return [] }
        var out: Set<String> = []
        for item in arr {
            if let s = nonEmptyString(item) {
                out.insert(s.lowercased())
            }
        }
        return out
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func uuidsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func sameAccount(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let l = lhs?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty,
              let r = rhs?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else {
            return true
        }
        return l.lowercased() == r.lowercased()
    }
}
