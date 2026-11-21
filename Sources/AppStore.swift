import AppKit
import Combine
import Darwin
import Foundation

// MARK: - Pending Force-Quit Confirmation State

public enum PendingForceQuitAction: Equatable {
    case switchAccount(AccountRecord)
    case controlClient(restart: Bool)

    public func title(for provider: ProviderID) -> String {
        switch self {
        case .switchAccount(let account):
            return "切换 \(provider.displayName) 账号（\(account.displayName)）"
        case .controlClient(let restart):
            return restart ? "重启 \(provider.displayName)" : "结束 \(provider.displayName)"
        }
    }
}

public struct PendingForceQuit: Identifiable {
    public let id = UUID()
    public let provider: ProviderID
    public let action: PendingForceQuitAction
    public let surviving: [ClientProcessInfo]
    public let onRetryGraceful: () -> Void
    public let onConfirmForceQuit: () -> Void
    public let onCancel: () -> Void

    public init(
        provider: ProviderID,
        action: PendingForceQuitAction,
        surviving: [ClientProcessInfo],
        onRetryGraceful: @escaping () -> Void,
        onConfirmForceQuit: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.provider = provider
        self.action = action
        self.surviving = surviving
        self.onRetryGraceful = onRetryGraceful
        self.onConfirmForceQuit = onConfirmForceQuit
        self.onCancel = onCancel
    }
}

// MARK: - Popover Top-Level Tab

public enum PopoverTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case quota
    case tokenUsage

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .quota: return "额度与账号"
        case .tokenUsage: return "Token 用量"
        }
    }

    public var symbolName: String {
        switch self {
        case .quota: return "speedometer"
        case .tokenUsage: return "chart.bar.fill"
        }
    }
}

// MARK: - AppStore

@MainActor
public final class AppStore: ObservableObject {
    public nonisolated static let bundleIdentifier = "com.rory.roryorbit"
    public nonisolated static let appVersion = "1.1.0"

    public nonisolated static var defaultAvatarCacheDirectoryURL: URL {
        RegistryData.defaultDirectoryURL.appendingPathComponent("avatars", isDirectory: true)
    }

    private nonisolated static let maxAvatarImageBytes = 4 * 1024 * 1024

    public let keychain: KeychainStore
    public let processController: ProcessController
    public let adapters: [ProviderID: any ProviderAdapter]
    public let tokenUsageEngine: TokenUsageEngine
    public let accountPoolExporter: AccountPoolExporter

    private let registryURL: URL
    private let migrationPaths: LegacyMigrationPaths
    private let avatarCacheDirectoryURL: URL
    private let avatarSession: URLSession
    private let ownsAvatarSession: Bool
    private let shouldPrewarmAvatars: Bool
    private let shouldPersistAccountPoolExport: Bool
    private let providerRefreshTimeoutSeconds: TimeInterval
    private let accountPoolExportQueue = DispatchQueue(
        label: "com.rory.roryorbit.accountpool-export",
        qos: .utility
    )
    private var schedulerTask: Task<Void, Never>?
    private var liveSpeedTimerTask: Task<Void, Never>?
    private var startupTokenScanTask: Task<Void, Never>?
    private var bannerClearTask: Task<Void, Never>?
    private var windowSizeSaveTask: Task<Void, Never>?
    private var hasPendingWindowSizeSave: Bool = false
    private var hasSampledLiveSpeedOnce: Bool = false
    private var loadedAvatarURLByAccountId: [String: String] = [:]
    private var inFlightAvatarKeys: Set<String> = []

    @Published public var registry: RegistryData
    @Published public var snapshots: [String: QuotaSnapshot] = [:]
    @Published public var clientStatuses: [ProviderID: ClientRuntimeStatus] = [:]
    @Published public var isRefreshing: Bool = false
    @Published public var refreshingProviders: Set<ProviderID> = []
    @Published public var busyActionLabel: String? = nil
    @Published public var lastRefreshedAt: Date? = nil
    @Published public var operationBanner: String? = nil
    @Published public var operationBannerIsError: Bool = false
    @Published public var pendingForceQuit: PendingForceQuit? = nil
    @Published public var migrationReport: MigrationReport? = nil
    @Published public var hasLegacySourcesToMigrate: Bool = false
    @Published public var migrationBannerDismissed: Bool = false
    @Published public var apiKeyConfiguredMap: [ProviderID: Bool] = [:]
    @Published public var tokenUsage: TokenUsageSnapshot? = nil
    @Published public var tokenUsageDateSelection: TokenUsageDateSelection = .defaultSelection
    @Published public var isScanningTokenUsage: Bool = false
    @Published public var selectedPopoverTab: PopoverTab = .quota
    @Published public private(set) var avatarImages: [String: NSImage] = [:]
    @Published public private(set) var liveTokenSpeed: LiveTokenSpeedSnapshot = .empty()

    public nonisolated static func makeDefaultAdapters(
        keychain: KeychainStore = .shared,
        processController: ProcessController = .shared,
        allowInteractiveKeychain: Bool = false
    ) -> [ProviderID: any ProviderAdapter] {
        [
            .antigravity: AntigravityProvider(keychain: keychain, processController: processController),
            .codex: CodexProvider(keychain: keychain, processController: processController),
            .grok: GrokProvider(keychain: keychain),
            .cursor: CursorProvider(keychain: keychain, allowInteractiveKeychain: allowInteractiveKeychain),
            .kimi: KimiProvider(keychain: keychain),
            .deepseek: DeepSeekProvider(keychain: keychain),
        ]
    }

    public init(
        keychain: KeychainStore = .shared,
        processController: ProcessController = .shared,
        adapters: [ProviderID: any ProviderAdapter]? = nil,
        registryURL: URL = RegistryData.defaultFileURL,
        migrationPaths: LegacyMigrationPaths = .liveDefaults,
        startScheduler: Bool = true,
        tokenUsageEngine: TokenUsageEngine = .shared,
        accountPoolExporter: AccountPoolExporter = .shared,
        persistAccountPoolExport: Bool? = nil,
        providerRefreshTimeoutSeconds: TimeInterval = 20.0,
        avatarCacheDirectoryURL: URL? = nil,
        avatarSession: URLSession? = nil
    ) {
        self.keychain = keychain
        self.processController = processController
        self.adapters = adapters ?? Self.makeDefaultAdapters(
            keychain: keychain,
            processController: processController
        )
        self.tokenUsageEngine = tokenUsageEngine
        self.accountPoolExporter = accountPoolExporter
        self.registryURL = registryURL
        self.migrationPaths = migrationPaths
        self.avatarCacheDirectoryURL = avatarCacheDirectoryURL
            ?? registryURL.deletingLastPathComponent().appendingPathComponent("avatars", isDirectory: true)
        self.ownsAvatarSession = (avatarSession == nil)
        self.avatarSession = avatarSession ?? HTTPFactory.makeSession(policy: .systemProxy, timeout: 15.0)
        self.shouldPrewarmAvatars = startScheduler || (avatarSession != nil)
        self.shouldPersistAccountPoolExport = persistAccountPoolExport
            ?? (registryURL.standardizedFileURL == RegistryData.defaultFileURL.standardizedFileURL)
        self.providerRefreshTimeoutSeconds = max(0.5, providerRefreshTimeoutSeconds)

        let loadedRegistry: RegistryData
        var loadError: String? = nil
        do {
            loadedRegistry = try RegistryData.load(from: registryURL)
        } catch {
            loadedRegistry = RegistryData()
            loadError = "读取配置文件失败，已使用默认配置（\(error.localizedDescription)）"
        }
        self.registry = loadedRegistry

        sanitizeSelectedProvider()
        ensureDefaultAccountsForEnabledNonSwitchableProviders()
        if backfillMissingAntigravityAvatarsFromBackup() {
            persistRegistryQuietly()
        }
        refreshAPIKeyStatuses()
        refreshLegacySourceDetection()

        if let loadError {
            setBanner(loadError, isError: true, autoClearSeconds: nil)
        }

        if shouldPrewarmAvatars {
            prewarmMissingAvatarImages(for: registry.accounts)
        }

        if startScheduler {
            restartScheduler()
            startLiveSpeedPolling()
            startupTokenScanTask = Task { [weak self] in
                await self?.refreshTokenUsage()
            }
        }
    }

    deinit {
        schedulerTask?.cancel()
        liveSpeedTimerTask?.cancel()
        startupTokenScanTask?.cancel()
        bannerClearTask?.cancel()
        windowSizeSaveTask?.cancel()
        if ownsAvatarSession {
            avatarSession.invalidateAndCancel()
        }
    }

    // MARK: - Snapshot & Account Helpers

    public static func snapshotKey(provider: ProviderID, accountId: String) -> String {
        "\(provider.rawValue)|\(accountId)"
    }

    public func snapshot(for provider: ProviderID, accountId: String) -> QuotaSnapshot? {
        snapshots[Self.snapshotKey(provider: provider, accountId: accountId)]
    }

    public func accounts(for provider: ProviderID) -> [AccountRecord] {
        let list = registry.accounts(for: provider)
        guard provider.supportsAccountSwitch else {
            return list
        }
        return list.sorted { lhs, rhs in
            if lhs.isActiveLive != rhs.isActiveLive {
                return lhs.isActiveLive
            }
            if lhs.isBestRemaining != rhs.isBestRemaining {
                return lhs.isBestRemaining
            }
            if lhs.addedAt != rhs.addedAt {
                return lhs.addedAt < rhs.addedAt
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    public func primaryAccount(for provider: ProviderID) -> AccountRecord? {
        let list = accounts(for: provider)
        return list.first(where: { $0.isActiveLive }) ?? list.first
    }

    public func primarySnapshot(for provider: ProviderID) -> QuotaSnapshot? {
        guard let account = primaryAccount(for: provider) else {
            return nil
        }
        return snapshot(for: provider, accountId: account.id)
    }

    public var enabledProvidersOrdered: [ProviderID] {
        let enabledSet = Set(registry.settings.enabledProviders)
        let ordered = ProviderID.allCases.filter { enabledSet.contains($0) }
        return ordered.isEmpty ? ProviderID.allCases : ordered
    }

    public var shouldShowMigrationBanner: Bool {
        !registry.settings.legacyMigrationCompleted
            && hasLegacySourcesToMigrate
            && !migrationBannerDismissed
    }

    public func selectProvider(_ provider: ProviderID) {
        guard registry.settings.selectedProvider != provider else { return }
        registry.settings.selectedProvider = provider
        persistRegistryQuietly()
    }

    public func selectPopoverTab(_ tab: PopoverTab) {
        selectedPopoverTab = tab
        if tab == .tokenUsage && tokenUsage == nil && !isScanningTokenUsage {
            Task { [weak self] in
                await self?.refreshTokenUsage()
            }
        }
    }

    public func dismissMigrationBanner() {
        migrationBannerDismissed = true
    }

    public func dismissOperationBanner() {
        bannerClearTask?.cancel()
        operationBanner = nil
        operationBannerIsError = false
    }

    // MARK: - Background Scheduler

    public func restartScheduler() {
        schedulerTask?.cancel()
        schedulerTask = nil

        guard let interval = registry.settings.refreshCadence.intervalSeconds, interval > 0 else {
            return
        }

        let nanos = UInt64(interval * 1_000_000_000)
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { break }
                guard let self else { break }
                await self.refreshAll()
                await self.refreshTokenUsage()
            }
        }
    }

    public func refreshIfStaleOnMenuOpen(staleSeconds: TimeInterval = 45) {
        let cadenceWantsMenuOpen = registry.settings.refreshCadence == .onMenuOpen
        guard registry.settings.refreshOnMenuOpen || cadenceWantsMenuOpen else {
            return
        }
        guard !isRefreshing else { return }

        if let lastRefreshedAt, Date().timeIntervalSince(lastRefreshedAt) < staleSeconds {
            return
        }

        Task { [weak self] in
            await self?.refreshAll()
        }
    }

    // MARK: - Local Token Usage Scan & Live Speed Polling (100% Offline Read-Only)

    private func startLiveSpeedPolling() {
        liveSpeedTimerTask?.cancel()
        liveSpeedTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.refreshLiveTokenSpeed(onlyPublishIfChanged: self.hasSampledLiveSpeedOnce)
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    public func refreshLiveTokenSpeed(now: Date = Date(), onlyPublishIfChanged: Bool = false) async {
        let engine = self.tokenUsageEngine
        let sampled = await engine.sampleLiveSpeed(now: now)
        hasSampledLiveSpeedOnce = true
        if onlyPublishIfChanged && Self.liveSpeedSemanticallyEqual(liveTokenSpeed, sampled) {
            return
        }
        liveTokenSpeed = sampled
    }

    private nonisolated static func liveSpeedSemanticallyEqual(
        _ lhs: LiveTokenSpeedSnapshot,
        _ rhs: LiveTokenSpeedSnapshot
    ) -> Bool {
        lhs.isGenerating == rhs.isGenerating
            && lhs.currentModel == rhs.currentModel
            && lhs.rollingOutputTokPerSec60s == rhs.rollingOutputTokPerSec60s
            && lhs.rollingTotalTokPerSec60s == rhs.rollingTotalTokPerSec60s
            && lhs.recentModels == rhs.recentModels
            && lhs.modelSpeedIndex == rhs.modelSpeedIndex
    }

    public func refreshTokenUsage(forceFullRescan: Bool = false) async {
        guard !isScanningTokenUsage else { return }
        isScanningTokenUsage = true
        defer { isScanningTokenUsage = false }

        let engine = self.tokenUsageEngine
        let snapshot = await engine.scanAndExportArchive(forceFullRescan: forceFullRescan)
        self.tokenUsage = snapshot
        if let speed = snapshot.speedSnapshot {
            self.hasSampledLiveSpeedOnce = true
            self.liveTokenSpeed = speed
        }
    }

    public func refreshTokenUsageIfStale(staleSeconds: TimeInterval = 240) async {
        guard !isScanningTokenUsage else { return }
        if let last = tokenUsage?.lastScannedAt, Date().timeIntervalSince(last) < staleSeconds {
            return
        }
        await refreshTokenUsage(forceFullRescan: false)
    }

    public func selectTokenUsageDate(_ selection: TokenUsageDateSelection) {
        switch selection {
        case .preset:
            tokenUsageDateSelection = selection
        case .custom(let startDate, let endDate):
            tokenUsageDateSelection = .normalizedCustom(startDate: startDate, endDate: endDate)
        }
    }

    public func selectTokenUsagePreset(_ range: TokenUsageRange) {
        tokenUsageDateSelection = .preset(range)
    }

    public func selectTokenUsageCustomRange(startDate: String, endDate: String) {
        tokenUsageDateSelection = .normalizedCustom(startDate: startDate, endDate: endDate)
    }

    public func selectTokenUsageCustomRange(start: Date, end: Date) {
        tokenUsageDateSelection = .custom(start: start, end: end)
    }

    public func selectTokenUsageSingleDay(_ date: String) {
        tokenUsageDateSelection = .singleDay(date)
    }

    public func resetTokenUsageSelectionToToday() {
        tokenUsageDateSelection = .defaultSelection
    }

    public func tokenUsageSummary(
        for selection: TokenUsageDateSelection? = nil,
        clientFilter: TokenClientID? = nil
    ) -> TokenRangeSummary? {
        tokenUsage?.summary(for: selection ?? tokenUsageDateSelection, clientFilter: clientFilter)
    }

    // MARK: - Refresh Pipeline

    public func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        refreshLegacySourceDetection()
        refreshAPIKeyStatuses()

        let providers = enabledProvidersOrdered
        await withTaskGroup(of: Void.self) { group in
            for provider in providers {
                group.addTask { [weak self] in
                    // Incrementally persist accountpool-snapshot.json as each provider completes so
                    // one slow or blocked provider never delays exporting healthy providers.
                    await self?.refreshProvider(provider, persistExport: true)
                }
            }
        }

        refreshBestRemainingBadges()
        lastRefreshedAt = Date()
        persistAccountPoolSnapshotQuietly()

        Task { [weak self] in
            await self?.refreshTokenUsageIfStale(staleSeconds: 240)
        }
    }

    private struct ProviderRefreshBatchResult: Sendable {
        let runtimeStatus: ClientRuntimeStatus
        let syncedAccounts: [AccountRecord]
        let syncedLiveId: String?
        let fetchedSnapshots: [(AccountRecord, QuotaSnapshot)]
        let fetchedAvatarURLs: [String: String]
        let hasStoredAPIKey: Bool
    }

    private final class UncheckedSendableBox<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) {
            self.value = value
        }
    }

    private final class HardTimeoutResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func tryClaim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    private final class HardTimeoutCancelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var workTask: Task<Void, Never>?
        private var timerTask: Task<Void, Never>?
        func setWork(_ task: Task<Void, Never>) {
            lock.lock()
            workTask = task
            lock.unlock()
        }
        func setTimer(_ task: Task<Void, Never>) {
            lock.lock()
            timerTask = task
            lock.unlock()
        }
        func cancelWork() {
            lock.lock()
            let t = workTask
            workTask = nil
            lock.unlock()
            t?.cancel()
        }
        func cancelTimer() {
            lock.lock()
            let t = timerTask
            timerTask = nil
            lock.unlock()
            t?.cancel()
        }
    }

    /// Runs `operation` with a hard wall-clock timeout that returns `nil` immediately even if
    /// the inner task is blocked in a non-cancellable system call (e.g. Keychain/SQLite/socket).
    private nonisolated static func runWithHardTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let gate = HardTimeoutResumeGate()
        let cancelBox = HardTimeoutCancelBox()
        let nanos = UInt64(max(0.1, seconds) * 1_000_000_000)

        return await withCheckedContinuation { continuation in
            let timerTask = Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled else { return }
                if gate.tryClaim() {
                    cancelBox.cancelWork()
                    continuation.resume(returning: nil)
                }
            }
            cancelBox.setTimer(timerTask)

            let workTask = Task.detached(priority: .utility) {
                let result = await operation()
                cancelBox.cancelTimer()
                if gate.tryClaim() {
                    continuation.resume(returning: result)
                }
            }
            cancelBox.setWork(workTask)
        }
    }

    public func refreshProvider(
        _ provider: ProviderID,
        userInitiated: Bool = false,
        persistExport: Bool = true
    ) async {
        guard let adapter = adapters[provider] else { return }
        guard !refreshingProviders.contains(provider) else { return }

        // Unattended/startup/scheduled refreshes NEVER trigger interactive macOS SecurityAgent
        // prompts; only an explicit user-initiated Cursor refresh may invoke interactive ACL consent.
        let isInteractiveCursorConsent: Bool
        let activeAdapter: any ProviderAdapter
        if userInitiated,
           provider == .cursor,
           let cursorAdapter = adapter as? CursorProvider {
            cursorAdapter.resetKeychainFailureCache()
            if cursorAdapter.keychain.backend is SecurityCLIKeychainBackend {
                isInteractiveCursorConsent = true
                activeAdapter = CursorProvider(
                    keychain: cursorAdapter.keychain,
                    stateDBURL: cursorAdapter.stateDBURL,
                    allowInteractiveKeychain: true
                )
            } else {
                isInteractiveCursorConsent = false
                activeAdapter = cursorAdapter
            }
        } else {
            isInteractiveCursorConsent = false
            activeAdapter = adapter
        }

        refreshingProviders.insert(provider)
        defer {
            refreshingProviders.remove(provider)
            if userInitiated, provider == .cursor {
                (adapter as? CursorProvider)?.resetKeychainFailureCache()
            }
        }

        if provider == .antigravity, backfillMissingAntigravityAvatarsFromBackup() {
            persistRegistryQuietly()
        }

        let beforeAccounts = registry.accounts(for: provider)
        for account in beforeAccounts {
            let key = Self.snapshotKey(provider: provider, accountId: account.id)
            if snapshots[key] == nil {
                snapshots[key] = .loading(provider: provider, accountId: account.id)
            }
        }

        let schemaVersion = registry.schemaVersion
        let settings = registry.settings
        let syntheticDefaultId = defaultAccountId(for: provider)
        let adapterBox = UncheckedSendableBox(activeAdapter)
        let timeoutSeconds: TimeInterval = isInteractiveCursorConsent
            ? max(providerRefreshTimeoutSeconds, 90.0)
            : providerRefreshTimeoutSeconds

        let batchResult = await Self.runWithHardTimeout(seconds: timeoutSeconds) { () async -> ProviderRefreshBatchResult in
            let currentAdapter = adapterBox.value
            let runtimeStatus = await currentAdapter.detectClientStatus()

            var providerScopedRegistry = RegistryData(
                schemaVersion: schemaVersion,
                accounts: beforeAccounts,
                settings: settings
            )
            let syncedLiveId = await currentAdapter.syncLiveAccount(registry: &providerScopedRegistry)

            var effectiveAccounts = providerScopedRegistry.accounts(for: provider)
            if !provider.supportsAccountSwitch {
                if let liveId = syncedLiveId,
                   liveId != syntheticDefaultId,
                   effectiveAccounts.count > 1,
                   effectiveAccounts.contains(where: { $0.id == liveId }) {
                    effectiveAccounts.removeAll { $0.id == syntheticDefaultId && $0.email.isEmpty }
                }
                if effectiveAccounts.isEmpty {
                    effectiveAccounts.append(
                        AccountRecord(
                            id: syntheticDefaultId,
                            provider: provider,
                            email: "",
                            displayName: provider.displayName,
                            plan: provider.supportsAPIKeyConfig ? PlanInfo(kind: .api, displayName: "API") : nil,
                            addedAt: Date(),
                            isActiveLive: true
                        )
                    )
                }
            }

            if let syncedLiveId {
                for idx in effectiveAccounts.indices {
                    effectiveAccounts[idx].isActiveLive = (effectiveAccounts[idx].id == syncedLiveId)
                }
            } else if !provider.supportsAccountSwitch, !effectiveAccounts.isEmpty {
                for idx in effectiveAccounts.indices {
                    effectiveAccounts[idx].isActiveLive = (idx == 0)
                }
            }

            var fetchedSnapshots: [(AccountRecord, QuotaSnapshot)] = []
            var fetchedAvatarURLs: [String: String] = [:]
            await withTaskGroup(of: (AccountRecord, QuotaSnapshot, String?).self) { group in
                for account in effectiveAccounts {
                    let isLive = account.isActiveLive
                    let needsAvatarFetch = (provider == .antigravity)
                        && (Formatters.sanitizedHTTPSURLString(account.avatarURL) == nil)
                    group.addTask {
                        let snap = await adapterBox.value.fetchQuota(for: account, isActiveLive: isLive)
                        var avatarURL: String? = nil
                        if needsAvatarFetch, let agProvider = adapterBox.value as? AntigravityProvider {
                            avatarURL = await agProvider.fetchUserPictureURL(for: account, isActiveLive: isLive)
                        }
                        return (account, snap, avatarURL)
                    }
                }
                for await (account, snap, avatarURL) in group {
                    fetchedSnapshots.append((account, snap))
                    if let avatarURL = Formatters.sanitizedHTTPSURLString(avatarURL) {
                        fetchedAvatarURLs[account.id] = avatarURL
                    }
                }
            }

            let hasKey = currentAdapter.hasStoredAPIKey()
            return ProviderRefreshBatchResult(
                runtimeStatus: runtimeStatus,
                syncedAccounts: effectiveAccounts,
                syncedLiveId: syncedLiveId,
                fetchedSnapshots: fetchedSnapshots,
                fetchedAvatarURLs: fetchedAvatarURLs,
                hasStoredAPIKey: hasKey
            )
        }

        guard let batchResult else {
            // Hard timeout hit: never leave accounts stuck in `.loading` or block `isRefreshing`.
            let timeoutInt = Int(timeoutSeconds.rounded())
            for account in registry.accounts(for: provider) {
                let key = Self.snapshotKey(provider: provider, accountId: account.id)
                if snapshots[key] == nil || snapshots[key]?.status == .loading {
                    snapshots[key] = QuotaSnapshot.failed(
                        provider: provider,
                        accountId: account.id,
                        sourceLabel: "超时保护",
                        message: "刷新超时（>\(timeoutInt)秒），已自动跳过以免阻塞"
                    )
                }
            }
            if persistExport {
                persistAccountPoolSnapshotQuietly()
            }
            return
        }

        clientStatuses[provider] = batchResult.runtimeStatus
        let accountsChangedFromSync = mergeSyncedAccounts(
            provider: provider,
            syncedAccounts: batchResult.syncedAccounts,
            liveAccountId: batchResult.syncedLiveId
        )

        var metadataChanged = accountsChangedFromSync
        for (account, snap) in batchResult.fetchedSnapshots {
            let key = Self.snapshotKey(provider: provider, accountId: account.id)
            snapshots[key] = snap

            if let plan = snap.plan, plan.kind != .unknown {
                if let idx = registry.accounts.firstIndex(where: { $0.provider == provider && $0.id == account.id }),
                   registry.accounts[idx].plan != plan {
                    registry.accounts[idx].plan = plan
                    metadataChanged = true
                }
            }
        }

        for (accountId, avatarURL) in batchResult.fetchedAvatarURLs {
            if let idx = registry.accounts.firstIndex(where: { $0.provider == provider && $0.id == accountId }),
               let cleanURL = Formatters.sanitizedHTTPSURLString(avatarURL),
               registry.accounts[idx].avatarURL != cleanURL {
                registry.accounts[idx].avatarURL = cleanURL
                metadataChanged = true
            }
        }

        apiKeyConfiguredMap[provider] = batchResult.hasStoredAPIKey
        refreshBestRemainingBadges()

        if metadataChanged {
            persistRegistryQuietly()
        }
        if shouldPrewarmAvatars {
            prewarmMissingAvatarImages(for: registry.accounts(for: provider))
        }
        lastRefreshedAt = Date()
        if persistExport {
            persistAccountPoolSnapshotQuietly()
        }
    }

    private func persistAccountPoolSnapshotQuietly() {
        guard shouldPersistAccountPoolExport else { return }
        let registryCopy = self.registry
        let snapshotsCopy = self.snapshots
        let exporter = self.accountPoolExporter
        accountPoolExportQueue.async {
            _ = try? exporter.writeSnapshot(
                registry: registryCopy,
                snapshots: snapshotsCopy
            )
        }
    }

    // MARK: - Account Switching, Adding, Importing & Removal

    public func switchAccount(
        provider: ProviderID,
        account: AccountRecord,
        allowForceQuit: Bool = false
    ) async {
        guard let adapter = adapters[provider] else { return }
        guard busyActionLabel == nil else { return }

        pendingForceQuit = nil
        busyActionLabel = "正在切换 \(provider.displayName) 账号..."
        defer { busyActionLabel = nil }

        let result = await adapter.switchAccount(to: account, allowForceQuit: allowForceQuit)
        switch result {
        case .switched(let reopenedApps):
            registry.setActiveLive(accountId: account.id, for: provider)
            persistRegistryQuietly()
            if reopenedApps.isEmpty {
                setBanner("已切换 \(provider.displayName) 至 \(account.displayName)", isError: false)
            } else {
                setBanner("已切换至 \(account.displayName)，已重新打开 \(reopenedApps.joined(separator: "、"))", isError: false)
            }
            await refreshProvider(provider)

        case .needsForceQuitConfirmation(let surviving):
            pendingForceQuit = PendingForceQuit(
                provider: provider,
                action: .switchAccount(account),
                surviving: surviving,
                onRetryGraceful: { [weak self] in
                    guard let self else { return }
                    Task {
                        await self.switchAccount(provider: provider, account: account, allowForceQuit: false)
                    }
                },
                onConfirmForceQuit: { [weak self] in
                    guard let self else { return }
                    Task {
                        await self.switchAccount(provider: provider, account: account, allowForceQuit: true)
                    }
                },
                onCancel: { [weak self] in
                    self?.pendingForceQuit = nil
                    self?.setBanner("已取消切换 \(provider.displayName) 账号", isError: false)
                }
            )

        case .failed(let message):
            setBanner("切换失败：\(message)", isError: true, autoClearSeconds: nil)
        }
    }

    public func addAccount(provider: ProviderID) async {
        guard let adapter = adapters[provider] else { return }
        guard busyActionLabel == nil else { return }

        busyActionLabel = "等待完成 \(provider.displayName) 账号授权..."
        defer { busyActionLabel = nil }

        do {
            let newAccount = try await adapter.addAccount()
            registry.upsertAccount(newAccount)
            persistRegistryQuietly()
            if shouldPrewarmAvatars {
                ensureAvatarLoaded(for: newAccount)
            }
            setBanner("已添加 \(provider.displayName) 账号：\(newAccount.displayName)", isError: false)
            await refreshProvider(provider)
        } catch {
            setBanner("添加账号失败：\(error.localizedDescription)", isError: true, autoClearSeconds: nil)
        }
    }

    public func importLiveAccount(provider: ProviderID) async {
        guard let adapter = adapters[provider] else { return }
        guard busyActionLabel == nil else { return }

        busyActionLabel = "正在导入当前 \(provider.displayName) 登录账号..."
        defer { busyActionLabel = nil }

        do {
            let imported = try await adapter.importLiveAccount()
            registry.upsertAccount(imported)
            registry.setActiveLive(accountId: imported.id, for: provider)
            persistRegistryQuietly()
            if shouldPrewarmAvatars {
                ensureAvatarLoaded(for: imported)
            }
            setBanner("已导入当前账号：\(imported.displayName)", isError: false)
            await refreshProvider(provider)
        } catch {
            setBanner("导入当前账号失败：\(error.localizedDescription)", isError: true, autoClearSeconds: nil)
        }
    }

    public func removeAccount(provider: ProviderID, account: AccountRecord) async {
        guard let adapter = adapters[provider] else { return }
        guard busyActionLabel == nil else { return }

        busyActionLabel = "正在移除账号..."
        defer { busyActionLabel = nil }

        do {
            try adapter.deleteAccountCredentials(accountId: account.id)
        } catch {
            setBanner("移除钥匙串凭证失败：\(error.localizedDescription)", isError: true, autoClearSeconds: nil)
            return
        }

        registry.removeAccount(id: account.id, provider: provider)
        snapshots.removeValue(forKey: Self.snapshotKey(provider: provider, accountId: account.id))
        avatarImages.removeValue(forKey: account.id)
        loadedAvatarURLByAccountId.removeValue(forKey: account.id)
        refreshBestRemainingBadges()
        persistRegistryQuietly()
        setBanner("已移除 \(provider.displayName) 账号：\(account.displayName)", isError: false)
    }

    // MARK: - Client Control (Restart / Quit)

    public func controlClient(
        provider: ProviderID,
        restart: Bool,
        allowForceQuit: Bool = false
    ) async {
        guard let adapter = adapters[provider] else { return }
        guard busyActionLabel == nil else { return }

        pendingForceQuit = nil
        busyActionLabel = restart
            ? "正在优雅重启 \(provider.displayName)..."
            : "正在优雅退出 \(provider.displayName)..."
        defer { busyActionLabel = nil }

        let result = await adapter.controlClient(restart: restart, allowForceQuit: allowForceQuit)
        switch result {
        case .switched(let reopenedApps):
            if restart {
                if reopenedApps.isEmpty {
                    setBanner("\(provider.displayName) 当前未运行，无需重启", isError: false)
                } else {
                    setBanner("已重启 \(reopenedApps.joined(separator: "、"))", isError: false)
                }
            } else {
                setBanner("已优雅退出 \(provider.displayName)", isError: false)
            }
            clientStatuses[provider] = await adapter.detectClientStatus()

        case .needsForceQuitConfirmation(let surviving):
            pendingForceQuit = PendingForceQuit(
                provider: provider,
                action: .controlClient(restart: restart),
                surviving: surviving,
                onRetryGraceful: { [weak self] in
                    guard let self else { return }
                    Task {
                        await self.controlClient(provider: provider, restart: restart, allowForceQuit: false)
                    }
                },
                onConfirmForceQuit: { [weak self] in
                    guard let self else { return }
                    Task {
                        await self.controlClient(provider: provider, restart: restart, allowForceQuit: true)
                    }
                },
                onCancel: { [weak self] in
                    self?.pendingForceQuit = nil
                    self?.setBanner("已取消客户端操作", isError: false)
                }
            )

        case .failed(let message):
            setBanner("操作失败：\(message)", isError: true, autoClearSeconds: nil)
        }
    }

    // MARK: - API Key Management (Kimi / DeepSeek)

    public func saveAPIKey(provider: ProviderID, key: String, label: String? = nil) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setBanner("请输入有效的 \(provider.displayName) API Key", isError: true)
            return
        }
        guard let adapter = adapters[provider] else { return }

        do {
            try adapter.saveAPIKey(trimmed, label: label)
            apiKeyConfiguredMap[provider] = adapter.hasStoredAPIKey()
            ensureDefaultAccountIfNeeded(for: provider)
            persistRegistryQuietly()
            setBanner("\(provider.displayName) API Key 已安全写入钥匙串", isError: false)
            await refreshProvider(provider)
        } catch {
            // Never log or include `trimmed` in error messages.
            setBanner("保存 \(provider.displayName) API Key 失败：\(error.localizedDescription)", isError: true, autoClearSeconds: nil)
        }
    }

    // MARK: - Legacy Migration (OrbitSwitch + CodexBar Read-Only)

    public func runLegacyMigration() async {
        guard busyActionLabel == nil else { return }
        busyActionLabel = "正在迁移原 OrbitSwitch / CodexBar 账号与密钥..."
        defer { busyActionLabel = nil }

        // Save any unsaved settings before migrator reads & writes registry.json.
        persistRegistryQuietly()

        let keychainRef = self.keychain
        let pathsRef = self.migrationPaths
        let report: MigrationReport = await Task.detached(priority: .userInitiated) {
            let migrator = LegacyMigrator(keychain: keychainRef, paths: pathsRef)
            return migrator.runMigration()
        }.value

        self.migrationReport = report

        if let reloaded = try? RegistryData.load(from: registryURL) {
            self.registry = reloaded
        }
        sanitizeSelectedProvider()
        ensureDefaultAccountsForEnabledNonSwitchableProviders()
        if backfillMissingAntigravityAvatarsFromBackup() {
            persistRegistryQuietly()
        }
        if shouldPrewarmAvatars {
            prewarmMissingAvatarImages(for: registry.accounts)
        }
        refreshAPIKeyStatuses()
        refreshLegacySourceDetection()

        let migratedTotal = report.orbitSwitchAntigravityMigrated
            + report.orbitSwitchCodexMigrated
            + report.codexBarCodexImported
        let keysText = report.codexBarAPIKeysImported.isEmpty
            ? ""
            : "，API Key \(report.codexBarAPIKeysImported.count) 项"

        if report.succeeded {
            setBanner(
                "迁移完成：导入账号 \(migratedTotal) 个\(keysText)（共 \(report.totalAccountsInRegistry) 个）",
                isError: false,
                autoClearSeconds: 8
            )
        } else {
            let errHint = report.errors.first ?? "部分项目校验未通过"
            setBanner("迁移存在错误：\(errHint)", isError: true, autoClearSeconds: nil)
        }

        await refreshAll()
    }

    // MARK: - Settings & Launch at Login

    public func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        let oldCadence = registry.settings.refreshCadence
        let oldLaunchAtLogin = registry.settings.launchAtLogin

        var updated = registry.settings
        mutate(&updated)

        if updated.enabledProviders.isEmpty {
            updated.enabledProviders = [.antigravity]
        } else {
            let enabledSet = Set(updated.enabledProviders)
            updated.enabledProviders = ProviderID.allCases.filter { enabledSet.contains($0) }
        }
        if !updated.enabledProviders.contains(updated.selectedProvider) {
            updated.selectedProvider = updated.enabledProviders[0]
        }
        updated.lowQuotaWarnThreshold = min(max(updated.lowQuotaWarnThreshold, 0.05), 0.90)
        updated.popoverWidth = AppSettings.clamp(
            updated.popoverWidth,
            to: AppSettings.popoverWidthRange,
            fallback: AppSettings.defaultPopoverWidth
        )
        updated.popoverHeight = AppSettings.clamp(
            updated.popoverHeight,
            to: AppSettings.popoverHeightRange,
            fallback: AppSettings.defaultPopoverHeight
        )
        updated.dashboardWidth = AppSettings.clamp(
            updated.dashboardWidth,
            to: AppSettings.dashboardWidthRange,
            fallback: AppSettings.defaultDashboardWidth
        )
        updated.dashboardHeight = AppSettings.clamp(
            updated.dashboardHeight,
            to: AppSettings.dashboardHeightRange,
            fallback: AppSettings.defaultDashboardHeight
        )
        updated.menuBarCustom.modules = MenuBarCustomConfig.deduplicatedModules(updated.menuBarCustom.modules)
        updated.menuBarCustom.quotaMultiProviders = MenuBarCustomConfig.deduplicatedProviders(updated.menuBarCustom.quotaMultiProviders)
        updated.tokenPopoverCards.orderedCards = PopoverTokenCardConfig.normalizedOrder(updated.tokenPopoverCards.orderedCards)
        updated.tokenPopoverCards.enabledCards = PopoverTokenCardConfig.deduplicated(updated.tokenPopoverCards.enabledCards)
        updated.tokenDashboardCards.orderedCards = DashboardTokenCardConfig.normalizedOrder(updated.tokenDashboardCards.orderedCards)
        updated.tokenDashboardCards.enabledCards = DashboardTokenCardConfig.deduplicated(updated.tokenDashboardCards.enabledCards)
        updated.tokenClientOrder = AppSettings.normalizeTokenClientOrder(updated.tokenClientOrder)

        windowSizeSaveTask?.cancel()
        windowSizeSaveTask = nil
        hasPendingWindowSizeSave = false

        registry.settings = updated
        ensureDefaultAccountsForEnabledNonSwitchableProviders()
        persistRegistryQuietly()

        if updated.refreshCadence != oldCadence {
            restartScheduler()
        }
        if updated.launchAtLogin != oldLaunchAtLogin {
            setLaunchAtLogin(updated.launchAtLogin)
        }
    }

    public func updateMenuBarCustom(_ update: (inout MenuBarCustomConfig) -> Void) {
        updateSettings { settings in
            var custom = settings.menuBarCustom
            update(&custom)
            custom.modules = MenuBarCustomConfig.deduplicatedModules(custom.modules)
            custom.quotaMultiProviders = MenuBarCustomConfig.deduplicatedProviders(custom.quotaMultiProviders)
            settings.menuBarCustom = custom
        }
    }

    // MARK: - Window Size Persistence (Clamped + Immediate / Debounced)

    public func updatePopoverSize(width: Double, height: Double, persistImmediately: Bool = true) {
        let clampedWidth = AppSettings.clamp(
            width,
            to: AppSettings.popoverWidthRange,
            fallback: AppSettings.defaultPopoverWidth
        )
        let clampedHeight = AppSettings.clamp(
            height,
            to: AppSettings.popoverHeightRange,
            fallback: AppSettings.defaultPopoverHeight
        )
        let changed = abs(registry.settings.popoverWidth - clampedWidth) > 0.001
            || abs(registry.settings.popoverHeight - clampedHeight) > 0.001

        if changed {
            registry.settings.popoverWidth = clampedWidth
            registry.settings.popoverHeight = clampedHeight
        }

        if persistImmediately {
            windowSizeSaveTask?.cancel()
            windowSizeSaveTask = nil
            if changed || hasPendingWindowSizeSave {
                hasPendingWindowSizeSave = false
                persistRegistryQuietly()
            }
        } else if changed {
            scheduleDebouncedWindowSizeSave()
        }
    }

    public func updateDashboardSize(width: Double, height: Double, persistImmediately: Bool = true) {
        let clampedWidth = AppSettings.clamp(
            width,
            to: AppSettings.dashboardWidthRange,
            fallback: AppSettings.defaultDashboardWidth
        )
        let clampedHeight = AppSettings.clamp(
            height,
            to: AppSettings.dashboardHeightRange,
            fallback: AppSettings.defaultDashboardHeight
        )
        let changed = abs(registry.settings.dashboardWidth - clampedWidth) > 0.001
            || abs(registry.settings.dashboardHeight - clampedHeight) > 0.001

        if changed {
            registry.settings.dashboardWidth = clampedWidth
            registry.settings.dashboardHeight = clampedHeight
        }

        if persistImmediately {
            windowSizeSaveTask?.cancel()
            windowSizeSaveTask = nil
            if changed || hasPendingWindowSizeSave {
                hasPendingWindowSizeSave = false
                persistRegistryQuietly()
            }
        } else if changed {
            scheduleDebouncedWindowSizeSave()
        }
    }

    public func resetWindowSizes() {
        updateSettings { settings in
            settings.popoverWidth = AppSettings.defaultPopoverWidth
            settings.popoverHeight = AppSettings.defaultPopoverHeight
            settings.dashboardWidth = AppSettings.defaultDashboardWidth
            settings.dashboardHeight = AppSettings.defaultDashboardHeight
        }
    }

    private func scheduleDebouncedWindowSizeSave(delayNanoseconds: UInt64 = 250_000_000) {
        hasPendingWindowSizeSave = true
        windowSizeSaveTask?.cancel()
        windowSizeSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.windowSizeSaveTask = nil
            if self.hasPendingWindowSizeSave {
                self.hasPendingWindowSizeSave = false
                self.persistRegistryQuietly()
            }
        }
    }

    // MARK: - Card Customization Helpers

    public func updatePopoverTokenCards(_ update: (inout PopoverTokenCardConfig) -> Void) {
        updateSettings { settings in
            var cfg = settings.tokenPopoverCards
            update(&cfg)
            cfg.orderedCards = PopoverTokenCardConfig.normalizedOrder(cfg.orderedCards)
            cfg.enabledCards = PopoverTokenCardConfig.deduplicated(cfg.enabledCards)
            settings.tokenPopoverCards = cfg
        }
    }

    public func updateDashboardTokenCards(_ update: (inout DashboardTokenCardConfig) -> Void) {
        updateSettings { settings in
            var cfg = settings.tokenDashboardCards
            update(&cfg)
            cfg.orderedCards = DashboardTokenCardConfig.normalizedOrder(cfg.orderedCards)
            cfg.enabledCards = DashboardTokenCardConfig.deduplicated(cfg.enabledCards)
            settings.tokenDashboardCards = cfg
        }
    }

    public func updateAccountCardConfig(_ update: (inout AccountCardConfig) -> Void) {
        updateSettings { settings in
            var cfg = settings.accountCardConfig
            update(&cfg)
            settings.accountCardConfig = cfg
        }
    }

    public func resetPopoverTokenCards() {
        updateSettings { settings in
            settings.tokenPopoverCards = .default
        }
    }

    public func resetDashboardTokenCards() {
        updateSettings { settings in
            settings.tokenDashboardCards = .default
        }
    }

    public func resetAccountCardConfig() {
        updateSettings { settings in
            settings.accountCardConfig = .default
        }
    }

    public func resetAllCardConfigs() {
        updateSettings { settings in
            settings.tokenPopoverCards = .default
            settings.tokenDashboardCards = .default
            settings.accountCardConfig = .default
        }
    }

    // MARK: - Token Client Filter Custom Ordering

    public var hasCustomTokenClientOrder: Bool {
        registry.settings.hasCustomTokenClientOrder
    }

    public func orderedTokenClients(from available: [TokenClientID]) -> [TokenClientID] {
        registry.settings.orderedTokenClients(from: available)
    }

    public func canMoveTokenClient(
        _ client: TokenClientID,
        direction: CardMoveDirection,
        available: [TokenClientID]
    ) -> Bool {
        registry.settings.canMoveTokenClient(
            rawValue: client.rawValue,
            direction: direction,
            available: available.map(\.rawValue)
        )
    }

    public func moveTokenClient(
        _ client: TokenClientID,
        direction: CardMoveDirection,
        available: [TokenClientID]
    ) {
        let availableRaw = available.map(\.rawValue)
        updateSettings { settings in
            settings.moveTokenClient(
                rawValue: client.rawValue,
                direction: direction,
                available: availableRaw
            )
        }
    }

    public func moveTokenClient(
        _ client: TokenClientID,
        toIndex: Int,
        available: [TokenClientID]
    ) {
        let availableRaw = available.map(\.rawValue)
        updateSettings { settings in
            settings.moveTokenClient(
                rawValue: client.rawValue,
                toIndex: toIndex,
                available: availableRaw
            )
        }
    }

    public func pinTokenClientToFront(_ client: TokenClientID, available: [TokenClientID]) {
        let availableRaw = available.map(\.rawValue)
        updateSettings { settings in
            settings.pinTokenClientToFront(rawValue: client.rawValue, available: availableRaw)
        }
    }

    public func pinTokenClientToEnd(_ client: TokenClientID, available: [TokenClientID]) {
        let availableRaw = available.map(\.rawValue)
        updateSettings { settings in
            settings.pinTokenClientToEnd(rawValue: client.rawValue, available: availableRaw)
        }
    }

    public func resetTokenClientOrder() {
        updateSettings { settings in
            settings.resetTokenClientOrder()
        }
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let launchAgentsDir = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        let plistURL = launchAgentsDir
            .appendingPathComponent("\(Self.bundleIdentifier).plist", isDirectory: false)
        let guiDomain = "gui/\(getuid())"
        let serviceTarget = "\(guiDomain)/\(Self.bundleIdentifier)"

        do {
            if enabled {
                try KeychainStore.ensureDirectory(at: launchAgentsDir, mode: 0o755)
                try KeychainStore.ensureDirectory(at: RegistryData.defaultDirectoryURL, mode: 0o700)

                let installedAppBinary = "/Applications/RoryOrbit.app/Contents/MacOS/RoryOrbit"
                let execPath: String
                if fm.isExecutableFile(atPath: installedAppBinary) {
                    execPath = installedAppBinary
                } else {
                    execPath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
                }

                let supportPath = RegistryData.defaultDirectoryURL.path
                let plistObject: [String: Any] = [
                    "Label": Self.bundleIdentifier,
                    "ProgramArguments": [execPath],
                    "RunAtLoad": true,
                    "KeepAlive": ["SuccessfulExit": false],
                    "ThrottleInterval": 15,
                    "ProcessType": "Interactive",
                    "EnvironmentVariables": [
                        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(home.path)/.local/bin",
                        "HOME": home.path,
                    ],
                    "StandardOutPath": "\(supportPath)/roryorbit.out.log",
                    "StandardErrorPath": "\(supportPath)/roryorbit.err.log",
                ]
                let plistData = try PropertyListSerialization.data(
                    fromPropertyList: plistObject,
                    format: .xml,
                    options: 0
                )
                try KeychainStore.writeAtomicFile(data: plistData, to: plistURL, mode: 0o600)
                // Re-enable in launchd without double-spawning the already-running GUI process.
                runLaunchctl(arguments: ["enable", serviceTarget])
            } else {
                // Disable in launchd and remove ONLY our own plist without killing the running UI session.
                runLaunchctl(arguments: ["disable", serviceTarget])
                if fm.fileExists(atPath: plistURL.path) {
                    try fm.removeItem(at: plistURL)
                }
            }
        } catch {
            setBanner("更新开机自启失败：\(error.localizedDescription)", isError: true)
        }
    }

    public func openDataDirectory() {
        let dir = RegistryData.defaultDirectoryURL
        try? KeychainStore.ensureDirectory(at: dir, mode: 0o700)
        NSWorkspace.shared.open(dir)
    }

    public func revealTokenArchiveInFinder() {
        let archiveURL = TokenUsageEngine.defaultArchiveURL
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
        } else {
            openDataDirectory()
        }
    }

    // MARK: - Quota Metrics & Menu Bar Summary Engine

    /// Pure, deterministic quota metrics extraction for any provider snapshot and Antigravity pool preference.
    public nonisolated static func extractQuotaMetrics(
        for provider: ProviderID,
        snapshot: QuotaSnapshot?,
        agPool: AntigravityPoolPreference = .autoLowest,
        now: Date = Date()
    ) -> ProviderQuotaMetrics {
        guard let snap = snapshot else {
            return ProviderQuotaMetrics(shortPrefix: provider.shortName)
        }

        switch snap.status {
        case .loading:
            return ProviderQuotaMetrics(shortPrefix: provider.shortName, isLoading: true)
        case .unconfigured:
            return ProviderQuotaMetrics(shortPrefix: provider.shortName, isUnconfigured: true)
        case .reauthRequired, .failed:
            return ProviderQuotaMetrics(shortPrefix: provider.shortName, isError: true)
        case .ready:
            break
        }

        let candidateWindows: [QuotaWindow]
        switch provider {
        case .antigravity:
            if agPool == .autoLowest {
                candidateWindows = snap.windows
            } else {
                let matched = snap.windows.filter { $0.antigravityPoolKind == agPool }
                candidateWindows = matched.isEmpty ? snap.windows : matched
            }
        case .codex:
            let core = snap.windows.filter { !$0.id.hasPrefix("add_") }
            candidateWindows = core.isEmpty ? snap.windows : core
        case .grok, .cursor, .kimi, .deepseek:
            candidateWindows = snap.windows
        }

        let fiveHourWindows = candidateWindows.filter { $0.cadence == .fiveHour }
        let weeklyWindows = candidateWindows.filter { $0.cadence == .weekly }

        let fiveHourPercent: Double? = fiveHourWindows
            .map { min(max($0.remainingFraction * 100.0, 0.0), 100.0) }
            .min()

        let weeklyPercent: Double? = weeklyWindows
            .map { min(max($0.remainingFraction * 100.0, 0.0), 100.0) }
            .min()

        let lowestPercent: Double?
        if !candidateWindows.isEmpty {
            lowestPercent = candidateWindows
                .map { min(max($0.remainingFraction * 100.0, 0.0), 100.0) }
                .min()
        } else if let primary = snap.primaryRemainingPercent {
            lowestPercent = Double(min(max(primary, 0), 100))
        } else {
            lowestPercent = nil
        }

        let primaryPercent: Double?
        if provider == .antigravity, agPool != .autoLowest {
            if let explicitPrimary = candidateWindows.first(where: { $0.isPrimary }) {
                primaryPercent = min(max(explicitPrimary.remainingFraction * 100.0, 0.0), 100.0)
            } else {
                primaryPercent = weeklyPercent ?? fiveHourPercent ?? lowestPercent
            }
        } else if let explicitPrimary = snap.primaryRemainingPercent {
            primaryPercent = Double(min(max(explicitPrimary, 0), 100))
        } else if let firstPrimary = candidateWindows.first(where: { $0.isPrimary }) ?? candidateWindows.first {
            primaryPercent = min(max(firstPrimary.remainingFraction * 100.0, 0.0), 100.0)
        } else {
            primaryPercent = nil
        }

        let allResets = candidateWindows.compactMap(\.resetAt)
        let recentOrFutureResets = allResets.filter { $0 >= now.addingTimeInterval(-60) }
        let nextReset = recentOrFutureResets.min() ?? allResets.min()

        let balanceText: String?
        let isBalanceDepleted: Bool
        if let balance = snap.balance {
            balanceText = Self.compactCurrencyString(balance)
            isBalanceDepleted = (balance.totalBalance <= 0.0)
        } else {
            balanceText = nil
            isBalanceDepleted = false
        }

        return ProviderQuotaMetrics(
            fiveHourPercent: fiveHourPercent,
            weeklyPercent: weeklyPercent,
            lowestPercent: lowestPercent,
            balanceText: balanceText,
            nextReset: nextReset,
            shortPrefix: provider.shortName,
            primaryPercent: primaryPercent,
            isReady: true,
            isError: false,
            isLoading: false,
            isUnconfigured: false,
            isBalanceDepleted: isBalanceDepleted
        )
    }

    public func quotaMetrics(
        for provider: ProviderID,
        agPool: AntigravityPoolPreference? = nil
    ) -> ProviderQuotaMetrics {
        let effectivePool = agPool ?? registry.settings.menuBarCustom.antigravityPool
        return Self.extractQuotaMetrics(
            for: provider,
            snapshot: primarySnapshot(for: provider),
            agPool: effectivePool
        )
    }

    public nonisolated static func displayPercentInt(
        _ remainingPercent: Double,
        showRemaining: Bool
    ) -> Int {
        let clampedRem = min(max(Int(remainingPercent.rounded()), 0), 100)
        return showRemaining ? clampedRem : (100 - clampedRem)
    }

    public nonisolated static func effectiveRemainingPercent(
        for metrics: ProviderQuotaMetrics,
        window: MenuBarQuotaWindow
    ) -> Double? {
        guard metrics.isReady else { return nil }
        switch window {
        case .weeklyFirst:
            return metrics.weeklyPercent ?? metrics.fiveHourPercent ?? metrics.primaryPercent ?? metrics.lowestPercent
        case .both5hAndWeekly:
            if let h5 = metrics.fiveHourPercent, let wk = metrics.weeklyPercent {
                return min(h5, wk)
            }
            return metrics.weeklyPercent ?? metrics.fiveHourPercent ?? metrics.primaryPercent ?? metrics.lowestPercent
        case .fiveHourFirst:
            return metrics.fiveHourPercent ?? metrics.weeklyPercent ?? metrics.primaryPercent ?? metrics.lowestPercent
        case .lowest:
            return metrics.lowestPercent ?? metrics.primaryPercent
        }
    }

    public nonisolated static func isQuotaWarning(
        metrics: ProviderQuotaMetrics,
        window: MenuBarQuotaWindow,
        warnThresholdPct: Int
    ) -> Bool {
        if metrics.isError {
            return true
        }
        guard metrics.isReady else { return false }
        if let effectivePct = effectiveRemainingPercent(for: metrics, window: window) {
            return Int(effectivePct.rounded()) <= warnThresholdPct
        }
        if metrics.balanceText != nil {
            return metrics.isBalanceDepleted
        }
        return false
    }

    public nonisolated static func formatQuotaText(
        metrics: ProviderQuotaMetrics,
        window: MenuBarQuotaWindow,
        dualFormat: MenuBarQuotaDualFormat,
        includePrefix: Bool,
        showRemaining: Bool
    ) -> String? {
        let prefix = includePrefix ? "\(metrics.shortPrefix) " : ""
        if metrics.isError {
            return "\(prefix)!"
        }
        guard metrics.isReady else {
            return nil
        }

        switch window {
        case .weeklyFirst:
            if let pct = metrics.weeklyPercent ?? metrics.fiveHourPercent ?? metrics.primaryPercent ?? metrics.lowestPercent {
                return "\(prefix)\(displayPercentInt(pct, showRemaining: showRemaining))%"
            }
            if let bal = metrics.balanceText {
                return "\(prefix)\(bal)"
            }
            return nil

        case .both5hAndWeekly:
            if let h5 = metrics.fiveHourPercent, let wk = metrics.weeklyPercent {
                let d5 = displayPercentInt(h5, showRemaining: showRemaining)
                let dw = displayPercentInt(wk, showRemaining: showRemaining)
                switch dualFormat {
                case .slash:
                    return "\(prefix)\(d5)%/\(dw)%"
                case .labeled:
                    return "\(prefix)5h\(d5)/周\(dw)"
                }
            }
            if let wk = metrics.weeklyPercent {
                let dw = displayPercentInt(wk, showRemaining: showRemaining)
                switch dualFormat {
                case .slash:
                    return "\(prefix)\(dw)%"
                case .labeled:
                    return "\(prefix)周\(dw)"
                }
            }
            if let h5 = metrics.fiveHourPercent {
                let d5 = displayPercentInt(h5, showRemaining: showRemaining)
                switch dualFormat {
                case .slash:
                    return "\(prefix)\(d5)%"
                case .labeled:
                    return "\(prefix)5h\(d5)"
                }
            }
            if let pct = metrics.primaryPercent ?? metrics.lowestPercent {
                return "\(prefix)\(displayPercentInt(pct, showRemaining: showRemaining))%"
            }
            if let bal = metrics.balanceText {
                return "\(prefix)\(bal)"
            }
            return nil

        case .fiveHourFirst:
            if let pct = metrics.fiveHourPercent ?? metrics.weeklyPercent ?? metrics.primaryPercent ?? metrics.lowestPercent {
                return "\(prefix)\(displayPercentInt(pct, showRemaining: showRemaining))%"
            }
            if let bal = metrics.balanceText {
                return "\(prefix)\(bal)"
            }
            return nil

        case .lowest:
            if let pct = metrics.lowestPercent ?? metrics.primaryPercent {
                return "\(prefix)\(displayPercentInt(pct, showRemaining: showRemaining))%"
            }
            if let bal = metrics.balanceText {
                return "\(prefix)\(bal)"
            }
            return nil
        }
    }

    public func formattedQuotaText(
        for provider: ProviderID,
        window: MenuBarQuotaWindow,
        dualFormat: MenuBarQuotaDualFormat,
        includePrefix: Bool,
        agPool: AntigravityPoolPreference? = nil
    ) -> String? {
        let metrics = quotaMetrics(for: provider, agPool: agPool)
        return Self.formatQuotaText(
            metrics: metrics,
            window: window,
            dualFormat: dualFormat,
            includePrefix: includePrefix,
            showRemaining: registry.settings.showRemainingPercent
        )
    }

    public func pillBadgeInfo(
        for provider: ProviderID
    ) -> (text: String, remainingPercent: Double?, isReady: Bool, isError: Bool, isUnconfigured: Bool, isBalancePositive: Bool?) {
        if refreshingProviders.contains(provider) && primarySnapshot(for: provider) == nil {
            return ("...", nil, false, false, false, nil)
        }
        guard let snap = primarySnapshot(for: provider) else {
            return ("--", nil, false, false, false, nil)
        }
        switch snap.status {
        case .loading:
            return ("...", nil, false, false, false, nil)
        case .unconfigured:
            return ("未配", nil, false, false, true, nil)
        case .reauthRequired, .failed:
            return ("!", nil, false, true, false, nil)
        case .ready:
            let pillWindow = registry.settings.accountCardConfig.pillQuotaWindow
            let metrics = quotaMetrics(for: provider)
            if let formatted = Self.formatQuotaText(
                metrics: metrics,
                window: pillWindow,
                dualFormat: .slash,
                includePrefix: false,
                showRemaining: registry.settings.showRemainingPercent
            ) {
                let effectiveRem = Self.effectiveRemainingPercent(for: metrics, window: pillWindow)
                let balancePositive: Bool? = (effectiveRem == nil && metrics.balanceText != nil)
                    ? !metrics.isBalanceDepleted
                    : nil
                return (formatted, effectiveRem, true, false, false, balancePositive)
            }
            return ("OK", nil, true, false, false, nil)
        }
    }

    /// Concise badge text for the top provider switcher pills in `MenuBarView`, honoring `settings.accountCardConfig.pillQuotaWindow`.
    public func formattedPillBadge(for provider: ProviderID) -> String {
        pillBadgeInfo(for: provider).text
    }

    /// Full structured menu bar summary including `providerKind` for official brand icon rendering in `main.swift` and `SettingsView`.
    public func menuBarSummaryDetail() -> MenuBarSummary {
        let settings = registry.settings
        let warnThresholdPct = Int((settings.lowQuotaWarnThreshold * 100.0).rounded())
        let enabled = enabledProvidersOrdered
        let tooltip = buildMenuBarTooltip(enabledProviders: enabled)

        switch settings.menuBarDisplayMode {
        case .selectedProvider:
            let provider = enabled.contains(settings.selectedProvider)
                ? settings.selectedProvider
                : (enabled.first ?? .antigravity)
            let custom = settings.menuBarCustom
            return formatMenuBarSummaryForProvider(
                provider: provider,
                window: custom.quotaWindow,
                dualFormat: custom.quotaDualFormat,
                agPool: custom.antigravityPool,
                showRemaining: settings.showRemainingPercent,
                warnThresholdPct: warnThresholdPct,
                tooltip: tooltip
            )

        case .lowestQuota:
            var lowestProvider: ProviderID?
            var lowestPct = Double.greatestFiniteMagnitude
            var anyError = false

            for provider in enabled {
                let metrics = quotaMetrics(for: provider)
                if metrics.isError {
                    anyError = true
                }
                if metrics.isReady,
                   let pct = Self.effectiveRemainingPercent(for: metrics, window: .lowest),
                   pct < lowestPct {
                    lowestPct = pct
                    lowestProvider = provider
                }
            }

            if let lowestProvider {
                var result = formatMenuBarSummaryForProvider(
                    provider: lowestProvider,
                    window: .lowest,
                    dualFormat: .slash,
                    agPool: settings.menuBarCustom.antigravityPool,
                    showRemaining: settings.showRemainingPercent,
                    warnThresholdPct: warnThresholdPct,
                    tooltip: tooltip
                )
                result.isWarning = result.isWarning || anyError
                return result
            }

            let fallbackProvider = enabled.contains(settings.selectedProvider)
                ? settings.selectedProvider
                : (enabled.first ?? .antigravity)
            var fallback = formatMenuBarSummaryForProvider(
                provider: fallbackProvider,
                window: .lowest,
                dualFormat: .slash,
                agPool: settings.menuBarCustom.antigravityPool,
                showRemaining: settings.showRemainingPercent,
                warnThresholdPct: warnThresholdPct,
                tooltip: tooltip
            )
            fallback.isWarning = fallback.isWarning || anyError
            return fallback

        case .compactDots:
            let (warnCount, minPct) = computeAggregateWarningStats(
                enabledProviders: enabled,
                window: settings.menuBarCustom.quotaWindow,
                warnThresholdPct: warnThresholdPct
            )
            let isWarning = warnCount > 0
            let title: String
            if isWarning {
                title = "\(warnCount)!"
            } else if let minPct {
                title = settings.showRemainingPercent ? "\(minPct)%" : "\(100 - minPct)%"
            } else {
                title = ""
            }
            return MenuBarSummary(
                title: title,
                symbol: "sparkles",
                tooltip: tooltip,
                isWarning: isWarning,
                providerKind: nil
            )

        case .iconOnly:
            let (warnCount, _) = computeAggregateWarningStats(
                enabledProviders: enabled,
                window: settings.menuBarCustom.quotaWindow,
                warnThresholdPct: warnThresholdPct
            )
            return MenuBarSummary(
                title: "",
                symbol: "sparkles",
                tooltip: tooltip,
                isWarning: warnCount > 0,
                providerKind: nil
            )

        case .custom:
            return buildCustomMenuBarSummary(
                settings: settings,
                enabledProviders: enabled,
                warnThresholdPct: warnThresholdPct,
                tooltip: tooltip
            )
        }
    }

    public func menuBarSummary() -> (symbol: String, title: String, isWarning: Bool, tooltip: String) {
        let summary = menuBarSummaryDetail()
        return (
            symbol: summary.symbol,
            title: summary.title,
            isWarning: summary.isWarning,
            tooltip: summary.tooltip
        )
    }

    public func menuBarModulePreviewText(for module: MenuBarModule) -> String {
        let settings = registry.settings
        let warnThresholdPct = Int((settings.lowQuotaWarnThreshold * 100.0).rounded())
        let enabled = enabledProvidersOrdered
        let cfg = settings.menuBarCustom
        let resolvedQuota = resolveCustomQuotaTarget(
            config: cfg,
            settings: settings,
            enabledProviders: enabled
        )
        return formatCustomModuleSegment(
            module: module,
            config: cfg,
            settings: settings,
            enabledProviders: enabled,
            quotaProvider: resolvedQuota.provider,
            warnThresholdPct: warnThresholdPct,
            forPreview: true
        )?.text ?? "隐藏"
    }

    /// Legacy compatibility alias forwarding to `menuBarModulePreviewText(for:)`.
    public func customMenuBarModulePreviewText(for module: MenuBarModule) -> String {
        menuBarModulePreviewText(for: module)
    }

    // MARK: - Private Helpers

    private var effectiveLiveTokenSpeed: LiveTokenSpeedSnapshot {
        if liveTokenSpeed.isGenerating
            || liveTokenSpeed.currentModel != nil
            || liveTokenSpeed.rollingOutputTokPerSec60s >= 0.05
            || liveTokenSpeed.rollingTotalTokPerSec60s >= 0.05
            || !liveTokenSpeed.recentModels.isEmpty {
            return liveTokenSpeed
        }
        return tokenUsage?.speedSnapshot ?? liveTokenSpeed
    }

    private func computeAggregateWarningStats(
        enabledProviders: [ProviderID],
        window: MenuBarQuotaWindow,
        warnThresholdPct: Int
    ) -> (warnCount: Int, minPct: Int?) {
        var warnCount = 0
        var minDisplayedPct: Int? = nil

        for provider in enabledProviders {
            let metrics = quotaMetrics(for: provider)
            if metrics.isError {
                warnCount += 1
            } else if metrics.isReady {
                // Warning count checks the lowest window across the provider so a critical 5h bottleneck is never missed.
                if let lowPct = metrics.lowestPercent ?? metrics.primaryPercent {
                    if Int(lowPct.rounded()) <= warnThresholdPct {
                        warnCount += 1
                    }
                } else if metrics.isBalanceDepleted {
                    warnCount += 1
                }

                // Healthy display percent honors the configured quotaWindow (e.g. weeklyFirst by default).
                if let effectivePct = Self.effectiveRemainingPercent(for: metrics, window: window) {
                    let rounded = min(max(Int(effectivePct.rounded()), 0), 100)
                    if minDisplayedPct == nil || rounded < minDisplayedPct! {
                        minDisplayedPct = rounded
                    }
                }
            }
        }
        return (warnCount, minDisplayedPct)
    }

    private func resolveCustomQuotaTarget(
        config: MenuBarCustomConfig,
        settings: AppSettings,
        enabledProviders: [ProviderID]
    ) -> (provider: ProviderID, anyError: Bool) {
        let selectedFallback = enabledProviders.contains(settings.selectedProvider)
            ? settings.selectedProvider
            : (enabledProviders.first ?? .antigravity)

        switch config.quotaSource {
        case .selected:
            return (selectedFallback, false)

        case .lowest:
            var lowestProvider: ProviderID?
            var lowestPct = Double.greatestFiniteMagnitude
            var anyError = false

            for provider in enabledProviders {
                let metrics = quotaMetrics(for: provider, agPool: config.antigravityPool)
                if metrics.isError {
                    anyError = true
                }
                if metrics.isReady,
                   let pct = Self.effectiveRemainingPercent(for: metrics, window: config.quotaWindow),
                   pct < lowestPct {
                    lowestPct = pct
                    lowestProvider = provider
                }
            }
            if let lowestProvider {
                return (lowestProvider, anyError)
            }
            return (selectedFallback, anyError)

        case .fixed:
            return (config.fixedQuotaProvider, false)

        case .multi:
            let providers = MenuBarCustomConfig.deduplicatedProviders(config.quotaMultiProviders)
            let primary = providers.first ?? selectedFallback
            let anyError = (providers.isEmpty ? [primary] : providers).contains {
                quotaMetrics(for: $0, agPool: config.antigravityPool).isError
            }
            return (primary, anyError)
        }
    }

    private func buildCustomMenuBarSummary(
        settings: AppSettings,
        enabledProviders: [ProviderID],
        warnThresholdPct: Int,
        tooltip: String
    ) -> MenuBarSummary {
        let cfg = settings.menuBarCustom
        let resolvedQuota = resolveCustomQuotaTarget(
            config: cfg,
            settings: settings,
            enabledProviders: enabledProviders
        )

        let symbol: String
        let providerKind: ProviderID?
        switch cfg.iconStyle {
        case .provider:
            symbol = resolvedQuota.provider.symbolName
            providerKind = resolvedQuota.provider
        case .pulsar:
            symbol = "sparkles"
            providerKind = nil
        case .hidden:
            symbol = ""
            providerKind = nil
        }

        var segments: [String] = []
        var isWarning = false
        for module in cfg.modules {
            if let seg = formatCustomModuleSegment(
                module: module,
                config: cfg,
                settings: settings,
                enabledProviders: enabledProviders,
                quotaProvider: resolvedQuota.provider,
                warnThresholdPct: warnThresholdPct,
                forPreview: false
            ) {
                segments.append(seg.text)
                if seg.isWarning {
                    isWarning = true
                }
                if module == .quota && (cfg.quotaSource == .lowest || cfg.quotaSource == .multi) && resolvedQuota.anyError {
                    isWarning = true
                }
            }
        }

        var title = segments.joined(separator: cfg.separator.literal)
        if title.isEmpty && symbol.isEmpty {
            title = "Pulsar"
        }
        return MenuBarSummary(
            title: title,
            symbol: symbol,
            tooltip: tooltip,
            isWarning: isWarning,
            providerKind: providerKind
        )
    }

    private nonisolated static func compactUSDCostString(_ amount: Double) -> String {
        let safe = (amount.isFinite && amount >= 0) ? amount : 0.0
        if safe < 0.005 {
            return "$0"
        }
        if safe < 10.0 {
            return String(format: "$%.2f", safe)
        }
        return compactCurrencyString(amount: safe, currency: "USD")
    }

    private nonisolated static func compactMessageCountString(_ count: Int) -> String {
        let safe = max(0, count)
        if safe >= 1_000 {
            let k = Double(safe) / 1_000.0
            let raw = String(format: "%.1f", k)
            let trimmed = raw.hasSuffix(".0") ? String(raw.dropLast(2)) : raw
            return "\(trimmed)k条"
        }
        return "\(safe)条"
    }

    private func formatCustomModuleSegment(
        module: MenuBarModule,
        config: MenuBarCustomConfig,
        settings: AppSettings,
        enabledProviders: [ProviderID],
        quotaProvider: ProviderID,
        warnThresholdPct: Int,
        forPreview: Bool
    ) -> (text: String, isWarning: Bool)? {
        let speed = effectiveLiveTokenSpeed

        switch module {
        case .quota:
            if config.quotaSource == .multi {
                let rawList = MenuBarCustomConfig.deduplicatedProviders(config.quotaMultiProviders)
                let targets = rawList.isEmpty ? [quotaProvider] : rawList
                var parts: [String] = []
                var anyWarn = false
                for target in targets {
                    let metrics = quotaMetrics(for: target, agPool: config.antigravityPool)
                    let partText = Self.formatQuotaText(
                        metrics: metrics,
                        window: config.quotaWindow,
                        dualFormat: config.quotaDualFormat,
                        includePrefix: config.showProviderPrefix,
                        showRemaining: settings.showRemainingPercent
                    ) ?? (config.showProviderPrefix ? "\(target.shortName) --" : "--")
                    parts.append(partText)
                    if Self.isQuotaWarning(metrics: metrics, window: config.quotaWindow, warnThresholdPct: warnThresholdPct) {
                        anyWarn = true
                    }
                }
                let joiner = config.showProviderPrefix ? " " : " / "
                return (parts.joined(separator: joiner), anyWarn)
            }

            let metrics = quotaMetrics(for: quotaProvider, agPool: config.antigravityPool)
            if let formatted = Self.formatQuotaText(
                metrics: metrics,
                window: config.quotaWindow,
                dualFormat: config.quotaDualFormat,
                includePrefix: config.showProviderPrefix,
                showRemaining: settings.showRemainingPercent
            ) {
                let warn = Self.isQuotaWarning(
                    metrics: metrics,
                    window: config.quotaWindow,
                    warnThresholdPct: warnThresholdPct
                )
                return (formatted, warn)
            }
            return (config.showProviderPrefix ? quotaProvider.shortName : "--", false)

        case .quotaFiveHour:
            let metrics = quotaMetrics(for: quotaProvider, agPool: config.antigravityPool)
            if metrics.isError {
                return ("5h !", true)
            }
            if metrics.isReady, let h5 = metrics.fiveHourPercent {
                let shown = Self.displayPercentInt(h5, showRemaining: settings.showRemainingPercent)
                return ("5h \(shown)%", Int(h5.rounded()) <= warnThresholdPct)
            }
            return forPreview ? ("5h --", false) : nil

        case .quotaWeekly:
            let metrics = quotaMetrics(for: quotaProvider, agPool: config.antigravityPool)
            if metrics.isError {
                return ("周 !", true)
            }
            if metrics.isReady, let wk = metrics.weeklyPercent {
                let shown = Self.displayPercentInt(wk, showRemaining: settings.showRemainingPercent)
                return ("周 \(shown)%", Int(wk.rounded()) <= warnThresholdPct)
            }
            return forPreview ? ("周 --", false) : nil

        case .tokenRate:
            if config.hideRateWhenIdle && !speed.isGenerating {
                return nil
            }
            let rate: Double
            switch config.rateMetric {
            case .output:
                if speed.isGenerating,
                   let curRate = speed.currentModel?.latestOutputTokPerSec,
                   curRate >= 0.05 {
                    rate = curRate
                } else {
                    rate = speed.rollingOutputTokPerSec60s
                }
            case .total:
                if speed.rollingTotalTokPerSec60s >= 0.05 {
                    rate = speed.rollingTotalTokPerSec60s
                } else if speed.isGenerating,
                          let curTotal = speed.currentModel?.latestTotalTokPerSec,
                          curTotal >= 0.05 {
                    rate = curTotal
                } else {
                    rate = 0.0
                }
            }
            return (TokenFormatters.tokensPerSec(rate), false)

        case .tokenRate60s:
            let rate60s: Double = (config.rateMetric == .total)
                ? speed.rollingTotalTokPerSec60s
                : speed.rollingOutputTokPerSec60s
            if config.hideRateWhenIdle && !speed.isGenerating && rate60s < 0.05 {
                return nil
            }
            return ("60s \(TokenFormatters.tokensPerSec(rate60s))", false)

        case .todayTokens:
            let todayTokens = tokenUsage?.summary(for: .today).totals.totalTokens ?? 0
            let text = todayTokens < 1_000 ? "\(todayTokens) tok" : TokenFormatters.compactTokens(todayTokens)
            return (text, false)

        case .todayCost:
            let todayCost = tokenUsage?.summary(for: .today).totals.estimatedCostUSD ?? 0.0
            return (Self.compactUSDCostString(todayCost), false)

        case .activeModel:
            let rawModel = speed.currentModel?.modelId
                ?? speed.recentModels.first?.modelId
                ?? tokenUsage?.summary(for: .today).byModel.first?.modelId
            guard let rawModel, !rawModel.isEmpty else {
                return forPreview ? ("--", false) : nil
            }
            return (TokenFormatters.compactModelName(rawModel), false)

        case .cacheHitRate:
            let totals = tokenUsage?.summary(for: .today).totals ?? .zero
            let pct = totals.totalInputTokens > 0
                ? min(max(Int((totals.cacheHitRate * 100.0).rounded()), 0), 100)
                : 0
            return ("缓存 \(pct)%", false)

        case .todayMessages:
            let msgCount = tokenUsage?.summary(for: .today).totals.messageCount ?? 0
            return (Self.compactMessageCountString(msgCount), false)

        case .sevenDayTokens:
            let tokens7d = tokenUsage?.summary(for: .days7).totals.totalTokens ?? 0
            let val = tokens7d < 1_000 ? "\(tokens7d)" : TokenFormatters.compactTokens(tokens7d)
            return ("7天 \(val)", false)

        case .thirtyDayCost:
            let cost30d = tokenUsage?.summary(for: .days30).totals.estimatedCostUSD ?? 0.0
            return ("30天 \(Self.compactUSDCostString(cost30d))", false)

        case .nextResetCountdown:
            let primaryReset: Date?
            if config.quotaSource == .multi {
                let rawList = MenuBarCustomConfig.deduplicatedProviders(config.quotaMultiProviders)
                let targets = rawList.isEmpty ? [quotaProvider] : rawList
                primaryReset = targets
                    .compactMap { quotaMetrics(for: $0, agPool: config.antigravityPool).nextReset }
                    .min()
            } else {
                primaryReset = quotaMetrics(for: quotaProvider, agPool: config.antigravityPool).nextReset
            }
            let effectiveReset = primaryReset ?? enabledProviders
                .compactMap { quotaMetrics(for: $0, agPool: config.antigravityPool).nextReset }
                .min()
            if let countdown = Formatters.compactResetCountdown(to: effectiveReset) {
                return ("↻\(countdown)", false)
            }
            return forPreview ? ("↻--", false) : nil

        case .deepseekBalance:
            let ds = quotaMetrics(for: .deepseek)
            if ds.isError {
                return ("DS !", true)
            }
            if ds.isReady, let bal = ds.balanceText {
                return ("DS \(bal)", ds.isBalanceDepleted)
            }
            if ds.isUnconfigured {
                return ("DS 未配", false)
            }
            return ("DS --", false)
        }
    }

    private func formatMenuBarSummaryForProvider(
        provider: ProviderID,
        window: MenuBarQuotaWindow,
        dualFormat: MenuBarQuotaDualFormat,
        agPool: AntigravityPoolPreference,
        showRemaining: Bool,
        warnThresholdPct: Int,
        tooltip: String
    ) -> MenuBarSummary {
        let symbol = provider.symbolName
        let metrics = quotaMetrics(for: provider, agPool: agPool)

        if let formatted = Self.formatQuotaText(
            metrics: metrics,
            window: window,
            dualFormat: dualFormat,
            includePrefix: true,
            showRemaining: showRemaining
        ) {
            let warn = Self.isQuotaWarning(
                metrics: metrics,
                window: window,
                warnThresholdPct: warnThresholdPct
            )
            return MenuBarSummary(
                title: formatted,
                symbol: symbol,
                tooltip: tooltip,
                isWarning: warn,
                providerKind: provider
            )
        }

        return MenuBarSummary(
            title: provider.shortName,
            symbol: symbol,
            tooltip: tooltip,
            isWarning: false,
            providerKind: provider
        )
    }

    private func buildMenuBarTooltip(enabledProviders: [ProviderID]) -> String {
        var lines: [String] = ["Pulsar \(Self.appVersion)"]
        let showRemaining = registry.settings.showRemainingPercent
        let agPool = registry.settings.menuBarCustom.antigravityPool

        for provider in enabledProviders {
            guard let snap = primarySnapshot(for: provider) else {
                lines.append("\(provider.displayName): 等待刷新")
                continue
            }
            switch snap.status {
            case .loading:
                lines.append("\(provider.displayName): 刷新中...")
            case .ready:
                let metrics = Self.extractQuotaMetrics(for: provider, snapshot: snap, agPool: agPool)
                let labelPrefix = showRemaining ? "剩余" : "已用"
                var parts: [String] = []
                if let h5 = metrics.fiveHourPercent, let wk = metrics.weeklyPercent {
                    let d5 = Self.displayPercentInt(h5, showRemaining: showRemaining)
                    let dw = Self.displayPercentInt(wk, showRemaining: showRemaining)
                    parts.append("5h \(labelPrefix) \(d5)%")
                    parts.append("周 \(labelPrefix) \(dw)%")
                } else if let wk = metrics.weeklyPercent {
                    let dw = Self.displayPercentInt(wk, showRemaining: showRemaining)
                    parts.append("周 \(labelPrefix) \(dw)%")
                } else if let h5 = metrics.fiveHourPercent {
                    let d5 = Self.displayPercentInt(h5, showRemaining: showRemaining)
                    parts.append("5h \(labelPrefix) \(d5)%")
                } else if let pct = snap.primaryRemainingPercent {
                    let display = showRemaining ? "剩余 \(pct)%" : "已用 \(100 - pct)%"
                    parts.append(display)
                    if let primary = snap.windows.first(where: { $0.isPrimary }) ?? snap.windows.first,
                       let secondary = snap.windows.first(where: { $0.id != primary.id }) {
                        let secVal = showRemaining ? secondary.remainingPercent : (100 - secondary.remainingPercent)
                        parts.append("\(secondary.label) \(secVal)%")
                    }
                }
                if let balance = snap.balance {
                    if parts.isEmpty {
                        parts.append("余额 \(Self.exactCurrencyString(balance))")
                    } else if balance.totalBalance > 0.0001 {
                        parts.append(Self.exactCurrencyString(balance))
                    }
                }
                if parts.isEmpty {
                    lines.append("\(provider.displayName): 已连接")
                } else {
                    lines.append("\(provider.displayName): \(parts.joined(separator: " · "))")
                }
            case .reauthRequired:
                lines.append("\(provider.displayName): 需要重新登录")
            case .unconfigured:
                lines.append("\(provider.displayName): 未配置")
            case .failed:
                lines.append("\(provider.displayName): 获取失败")
            }
        }

        let speed = effectiveLiveTokenSpeed
        if let cur = speed.currentModel {
            let modelShort = TokenFormatters.compactModelName(cur.modelId)
            if speed.isGenerating {
                lines.append(
                    "实时速度: \(modelShort) \(TokenFormatters.tokensPerSec(cur.latestOutputTokPerSec)) · 60s 吞吐 \(TokenFormatters.tokensPerSec(speed.rollingTotalTokPerSec60s))"
                )
            } else if speed.rollingOutputTokPerSec60s >= 0.05 || speed.rollingTotalTokPerSec60s >= 0.05 {
                lines.append(
                    "近 60 秒速率: 输出 \(TokenFormatters.tokensPerSec(speed.rollingOutputTokPerSec60s)) · 总吞吐 \(TokenFormatters.tokensPerSec(speed.rollingTotalTokPerSec60s))"
                )
            } else {
                lines.append(
                    "最近模型: \(modelShort)（均速 \(TokenFormatters.tokensPerSec(cur.averageOutputTokPerSec))）"
                )
            }
        } else if speed.rollingOutputTokPerSec60s >= 0.05 || speed.rollingTotalTokPerSec60s >= 0.05 {
            lines.append(
                "近 60 秒速率: 输出 \(TokenFormatters.tokensPerSec(speed.rollingOutputTokPerSec60s)) · 总吞吐 \(TokenFormatters.tokensPerSec(speed.rollingTotalTokPerSec60s))"
            )
        }

        if let lastRefreshedAt {
            lines.append("更新于 \(relativeTimeAgoString(since: lastRefreshedAt))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Shared Currency & Duration Formatters

    public nonisolated static func currencySymbol(for currency: String) -> String {
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch code {
        case "CNY", "RMB": return "¥"
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        default: return ""
        }
    }

    /// Formats an exact currency amount with thousands grouping separators (e.g. `¥15,112.66`, `$400.00`).
    public nonisolated static func exactCurrencyString(amount: Double, currency: String) -> String {
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let sign = amount < 0 ? "-" : ""
        let absAmount = abs(amount)

        let nf = NumberFormatter()
        nf.locale = Locale(identifier: "en_US_POSIX")
        nf.numberStyle = .decimal
        nf.usesGroupingSeparator = true
        nf.groupingSeparator = ","
        nf.decimalSeparator = "."
        nf.minimumFractionDigits = 2
        nf.maximumFractionDigits = 2
        let formatted = nf.string(from: NSNumber(value: absAmount)) ?? String(format: "%.2f", absAmount)

        let symbol = currencySymbol(for: code)
        if !symbol.isEmpty {
            return "\(sign)\(symbol)\(formatted)"
        }
        if code.isEmpty {
            return "\(sign)\(formatted)"
        }
        return "\(sign)\(code) \(formatted)"
    }

    public nonisolated static func exactCurrencyString(_ balance: BalanceInfo) -> String {
        exactCurrencyString(amount: balance.totalBalance, currency: balance.currency)
    }

    /// Formats a compact currency string for tight pills and menu bar titles (e.g. `¥15.1k`, `$1.2M`, `¥88.4`).
    public nonisolated static func compactCurrencyString(amount: Double, currency: String) -> String {
        let symbol = currencySymbol(for: currency)
        let sign = amount < 0 ? "-" : ""
        let absVal = abs(amount)

        func trimZeroDecimal(_ raw: String) -> String {
            raw.hasSuffix(".0") ? String(raw.dropLast(2)) : raw
        }

        if absVal >= 999_500 {
            let millions = absVal / 1_000_000.0
            let num = millions >= 100
                ? String(format: "%.0f", millions)
                : trimZeroDecimal(String(format: "%.1f", millions))
            return "\(sign)\(symbol)\(num)M"
        }
        if absVal >= 999.5 {
            let thousands = absVal / 1_000.0
            let num = thousands >= 100
                ? String(format: "%.0f", thousands)
                : trimZeroDecimal(String(format: "%.1f", thousands))
            return "\(sign)\(symbol)\(num)k"
        }
        if absVal >= 100 {
            return "\(sign)\(symbol)\(Int(absVal.rounded()))"
        }
        if absVal < 0.005 {
            return "\(symbol)0"
        }
        let num = trimZeroDecimal(String(format: "%.1f", absVal))
        return "\(sign)\(symbol)\(num)"
    }

    public nonisolated static func compactCurrencyString(_ balance: BalanceInfo) -> String {
        compactCurrencyString(amount: balance.totalBalance, currency: balance.currency)
    }

    public func relativeTimeAgoString(since date: Date, now: Date = Date()) -> String {
        let delta = max(0, Int(now.timeIntervalSince(date)))
        if delta < 45 {
            return "刚刚"
        }
        if delta < 3600 {
            return "\(delta / 60) 分钟前"
        }
        let hours = delta / 3600
        if hours < 24 {
            return "\(hours) 小时前"
        }
        return "\(hours / 24) 天前"
    }

    private func sanitizeSelectedProvider() {
        if registry.settings.enabledProviders.isEmpty {
            registry.settings.enabledProviders = ProviderID.allCases
        }
        if !registry.settings.enabledProviders.contains(registry.settings.selectedProvider) {
            registry.settings.selectedProvider = registry.settings.enabledProviders[0]
        }
    }

    private func defaultAccountId(for provider: ProviderID) -> String {
        provider.supportsAPIKeyConfig ? "\(provider.rawValue):api" : "\(provider.rawValue):default"
    }

    private func ensureDefaultAccountsForEnabledNonSwitchableProviders() {
        for provider in enabledProvidersOrdered where !provider.supportsAccountSwitch {
            ensureDefaultAccountIfNeeded(for: provider)
        }
    }

    private func ensureDefaultAccountIfNeeded(for provider: ProviderID) {
        guard !provider.supportsAccountSwitch else { return }
        guard registry.accounts(for: provider).isEmpty else { return }
        let record = AccountRecord(
            id: defaultAccountId(for: provider),
            provider: provider,
            email: "",
            displayName: provider.displayName,
            plan: provider.supportsAPIKeyConfig ? PlanInfo(kind: .api, displayName: "API") : nil,
            addedAt: Date(),
            isActiveLive: true
        )
        registry.upsertAccount(record)
    }

    private func mergeSyncedAccounts(
        provider: ProviderID,
        syncedAccounts: [AccountRecord],
        liveAccountId: String?
    ) -> Bool {
        let previousForProvider = registry.accounts(for: provider)

        var mergedProviderAccounts = syncedAccounts
        if !provider.supportsAccountSwitch {
            let syntheticDefaultId = defaultAccountId(for: provider)
            if let liveId = liveAccountId,
               liveId != syntheticDefaultId,
               mergedProviderAccounts.count > 1,
               mergedProviderAccounts.contains(where: { $0.id == liveId }) {
                mergedProviderAccounts.removeAll { $0.id == syntheticDefaultId && $0.email.isEmpty }
            }
            if mergedProviderAccounts.isEmpty {
                mergedProviderAccounts.append(
                    AccountRecord(
                        id: syntheticDefaultId,
                        provider: provider,
                        email: "",
                        displayName: provider.displayName,
                        plan: provider.supportsAPIKeyConfig ? PlanInfo(kind: .api, displayName: "API") : nil,
                        addedAt: Date(),
                        isActiveLive: true
                    )
                )
            }
        }

        var nextAll = registry.accounts.filter { $0.provider != provider }
        nextAll.append(contentsOf: mergedProviderAccounts)
        registry.accounts = nextAll

        if let liveAccountId {
            registry.setActiveLive(accountId: liveAccountId, for: provider)
        } else if !provider.supportsAccountSwitch, let firstId = mergedProviderAccounts.first?.id {
            registry.setActiveLive(accountId: firstId, for: provider)
        }

        let updatedForProvider = registry.accounts(for: provider)
        return !persistedAccountsEqual(previousForProvider, updatedForProvider)
    }

    private func persistedAccountsEqual(_ lhs: [AccountRecord], _ rhs: [AccountRecord]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            if a.id != b.id
                || a.provider != b.provider
                || a.email != b.email
                || a.displayName != b.displayName
                || a.plan != b.plan
                || a.isActiveLive != b.isActiveLive
                || a.avatarURL != b.avatarURL {
                return false
            }
        }
        return true
    }

    // MARK: - Avatar Backfill & Reactive Cache

    private struct OrbitSwitchAvatarBackupRoot: Decodable {
        let accounts: [OrbitSwitchAvatarBackupEntry]
    }

    private struct OrbitSwitchAvatarBackupEntry: Decodable {
        let provider: String?
        let id: String?
        let picture: String?
    }

    /// Backfills missing `avatarURL` for existing Antigravity accounts from a read-only
    /// legacy OrbitSwitch accounts file (`id` -> HTTPS `picture` URL only, never touches secrets).
    @discardableResult
    private func backfillMissingAntigravityAvatarsFromBackup() -> Bool {
        let needsBackfill = registry.accounts.contains { account in
            account.provider == .antigravity && Formatters.sanitizedHTTPSURLString(account.avatarURL) == nil
        }
        guard needsBackfill else { return false }

        let backupURL = migrationPaths.orbitSwitchBackupAccountsURL
        guard FileManager.default.fileExists(atPath: backupURL.path),
              let data = try? Data(contentsOf: backupURL),
              let parsed = try? JSONDecoder().decode(OrbitSwitchAvatarBackupRoot.self, from: data) else {
            return false
        }

        var pictureById: [String: String] = [:]
        for entry in parsed.accounts {
            guard entry.provider == ProviderID.antigravity.rawValue,
                  let id = entry.id?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty,
                  let pictureURL = Formatters.sanitizedHTTPSURLString(entry.picture) else {
                continue
            }
            pictureById[id] = pictureURL
        }
        guard !pictureById.isEmpty else { return false }

        var changed = false
        for idx in registry.accounts.indices where registry.accounts[idx].provider == .antigravity {
            guard Formatters.sanitizedHTTPSURLString(registry.accounts[idx].avatarURL) == nil,
                  let matchedPicture = pictureById[registry.accounts[idx].id] else {
                continue
            }
            registry.accounts[idx].avatarURL = matchedPicture
            changed = true
        }
        return changed
    }

    private func prewarmMissingAvatarImages(for accounts: [AccountRecord]) {
        for account in accounts where Formatters.sanitizedHTTPSURLString(account.avatarURL) != nil {
            ensureAvatarLoaded(for: account)
        }
    }

    public nonisolated static func avatarCacheFileURL(
        forHTTPSURL urlString: String,
        in directory: URL = defaultAvatarCacheDirectoryURL
    ) -> URL {
        let digest = Formatters.sha256Hex(urlString)
        return directory.appendingPathComponent("\(digest).img", isDirectory: false)
    }

    public func ensureAvatarLoaded(for account: AccountRecord) {
        let accountId = account.id
        guard let urlString = Formatters.sanitizedHTTPSURLString(account.avatarURL),
              let requestURL = URL(string: urlString) else {
            if avatarImages[accountId] != nil {
                avatarImages.removeValue(forKey: accountId)
            }
            loadedAvatarURLByAccountId.removeValue(forKey: accountId)
            return
        }

        if avatarImages[accountId] != nil,
           loadedAvatarURLByAccountId[accountId] == urlString {
            return
        }

        let requestKey = "\(accountId)|\(urlString)"
        guard !inFlightAvatarKeys.contains(requestKey) else {
            return
        }
        inFlightAvatarKeys.insert(requestKey)

        let existedInRegistryAtStart = registry.accounts.contains {
            $0.id == accountId && $0.provider == account.provider
        }
        let cacheDir = avatarCacheDirectoryURL
        let cacheFileURL = Self.avatarCacheFileURL(forHTTPSURL: urlString, in: cacheDir)
        let session = avatarSession

        Task.detached(priority: .utility) { [weak self] in
            let loadedImageBox = await Self.loadOrDownloadAvatarImage(
                url: requestURL,
                cacheDirectoryURL: cacheDir,
                cacheFileURL: cacheFileURL,
                session: session
            ).map { UncheckedSendableBox($0) }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlightAvatarKeys.remove(requestKey)

                if existedInRegistryAtStart {
                    guard let current = self.registry.accounts.first(where: {
                        $0.id == accountId && $0.provider == account.provider
                    }),
                    Formatters.sanitizedHTTPSURLString(current.avatarURL) == urlString else {
                        return
                    }
                }

                if let loadedImage = loadedImageBox?.value {
                    self.loadedAvatarURLByAccountId[accountId] = urlString
                    self.avatarImages[accountId] = loadedImage
                }
            }
        }
    }

    private nonisolated static func decodeValidatedNSImage(from data: Data) -> NSImage? {
        guard !data.isEmpty, data.count <= maxAvatarImageBytes else { return nil }
        guard let image = NSImage(data: data),
              !image.representations.isEmpty,
              image.size.width > 0,
              image.size.height > 0 else {
            return nil
        }
        return image
    }

    private nonisolated static func loadOrDownloadAvatarImage(
        url: URL,
        cacheDirectoryURL: URL,
        cacheFileURL: URL,
        session: URLSession
    ) async -> NSImage? {
        guard url.scheme?.lowercased() == "https" else { return nil }

        if FileManager.default.fileExists(atPath: cacheFileURL.path),
           let cachedData = try? Data(contentsOf: cacheFileURL),
           let cachedImage = decodeValidatedNSImage(from: cachedData) {
            return cachedImage
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15.0
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return nil
            }
            if let finalScheme = response.url?.scheme?.lowercased(), finalScheme != "https" {
                return nil
            }
            guard let image = decodeValidatedNSImage(from: data) else {
                return nil
            }
            try? KeychainStore.ensureDirectory(at: cacheDirectoryURL, mode: 0o700)
            try? KeychainStore.writeAtomicFile(data: data, to: cacheFileURL, mode: 0o600)
            return image
        } catch {
            return nil
        }
    }

    private func refreshBestRemainingBadges() {
        var byAccountId: [String: QuotaSnapshot] = [:]
        for account in registry.accounts where account.provider.supportsAccountSwitch {
            if let snap = snapshot(for: account.provider, accountId: account.id) {
                byAccountId[account.id] = snap
            }
        }
        registry.refreshBestRemainingFlags(snapshots: byAccountId)
    }

    private func refreshAPIKeyStatuses() {
        for provider in ProviderID.allCases where provider.supportsAPIKeyConfig {
            apiKeyConfiguredMap[provider] = adapters[provider]?.hasStoredAPIKey() ?? false
        }
    }

    private func refreshLegacySourceDetection() {
        let fm = FileManager.default
        if fm.fileExists(atPath: migrationPaths.orbitSwitchBackupAccountsURL.path) {
            hasLegacySourcesToMigrate = true
            return
        }
        if fm.fileExists(atPath: migrationPaths.codexBarManagedAccountsURL.path) {
            hasLegacySourcesToMigrate = true
            return
        }
        if fm.fileExists(atPath: migrationPaths.codexBarConfigURL.path),
           let data = try? Data(contentsOf: migrationPaths.codexBarConfigURL),
           let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
           let providers = root["providers"] as? [[String: Any]] {
            // Strictly inspect ONLY whitelisted kimi / deepseek entries (never touch Claude).
            let hasSupportedKey = providers.contains { item in
                guard let id = item["id"] as? String, id == "kimi" || id == "deepseek" else {
                    return false
                }
                if let direct = item["apiKey"] as? String,
                   !direct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
                if let tokenAccounts = item["tokenAccounts"] as? [String: Any],
                   let accounts = tokenAccounts["accounts"] as? [[String: Any]] {
                    return accounts.contains { entry in
                        if let tok = entry["token"] as? String {
                            return !tok.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        }
                        return false
                    }
                }
                return false
            }
            hasLegacySourcesToMigrate = hasSupportedKey
            return
        }
        hasLegacySourcesToMigrate = false
    }

    private func persistRegistryQuietly() {
        do {
            try registry.save(to: registryURL)
        } catch {
            setBanner("保存配置失败：\(error.localizedDescription)", isError: true)
        }
    }

    private func setBanner(_ message: String, isError: Bool, autoClearSeconds: TimeInterval? = 5.0) {
        bannerClearTask?.cancel()
        operationBanner = message
        operationBannerIsError = isError

        guard let autoClearSeconds, autoClearSeconds > 0 else { return }
        let nanos = UInt64(autoClearSeconds * 1_000_000_000)
        bannerClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            if self?.operationBanner == message {
                self?.operationBanner = nil
                self?.operationBannerIsError = false
            }
        }
    }

    private func runLaunchctl(arguments: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }
}
