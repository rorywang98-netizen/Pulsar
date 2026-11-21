import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

// MARK: - CLI Subcommand Dispatch (Executed Before NSApplication)

enum CLIRunner {
    static let versionString = "RoryOrbit \(AppStore.appVersion)"

    static func printUsage() {
        let usage = """
        RoryOrbit \(AppStore.appVersion) — 原生 macOS 菜单栏 AI 账号切换、配额监控与纯本地 Token 用量分析

        用法:
          RoryOrbit                                       启动菜单栏应用（默认）
          RoryOrbit --version                             显示版本号并退出
          RoryOrbit --help                                显示此帮助信息并退出
          RoryOrbit --migrate-legacy                      执行一次性历史账号与密钥迁移（输出 JSON 统计，零密钥）
          RoryOrbit --smoke-quota                         对已配置服务执行只读配额自检并打印脱敏摘要表
          RoryOrbit --export-accountpool-json [选项]      导出 AccountPool 兼容 JSON（零密钥、零 Claude）
              --max-age <秒>                              缓存最大有效期，默认 240 秒
              --refresh                                   强制在跨进程文件锁保护下执行实时刷新
          RoryOrbit --export-usage-archive [--full]       执行纯本地日志扫描、写出日归档并输出 1 行 JSON 摘要
          RoryOrbit --smoke-usage                         执行纯本地日志扫描并打印脱敏 Token 用量自检表
        """
        print(usage)
    }

    static func runMigrateLegacy() -> Int32 {
        let migrator = LegacyMigrator(keychain: .shared, paths: .liveDefaults)
        let report = migrator.runMigration()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        } else {
            print(report.summaryText)
        }
        fflush(stdout)
        return report.succeeded ? 0 : 1
    }

    static func runSmokeQuota() async -> Int32 {
        let baseRegistry = (try? RegistryData.load()) ?? RegistryData()
        let adapters = AppStore.makeDefaultAdapters(
            keychain: .shared,
            processController: .shared
        )

        struct AccountSmokeDetail: Sendable {
            let account: AccountRecord
            let snapshot: QuotaSnapshot
        }

        struct ProviderSmokeRow: Sendable {
            let provider: ProviderID
            let accountCount: Int
            let liveCount: Int
            let statusLabel: String
            let remainingLabel: String
            let balanceLabel: String
            let windowCount: Int
            let sourceLabel: String
            let details: [AccountSmokeDetail]
        }

        let providers = ProviderID.allCases
        var rowsByProvider: [ProviderID: ProviderSmokeRow] = [:]

        await withTaskGroup(of: ProviderSmokeRow.self) { group in
            for provider in providers {
                let adapter = adapters[provider]
                let initialAccounts = baseRegistry.accounts(for: provider)
                let settings = baseRegistry.settings
                let schemaVersion = baseRegistry.schemaVersion

                group.addTask {
                    guard let adapter else {
                        return ProviderSmokeRow(
                            provider: provider,
                            accountCount: 0,
                            liveCount: 0,
                            statusLabel: "missing-adapter",
                            remainingLabel: "-",
                            balanceLabel: "-",
                            windowCount: 0,
                            sourceLabel: "-",
                            details: []
                        )
                    }

                    // Strictly read-only in-memory registry copy (never mutates registry.json on disk).
                    var scopedRegistry = RegistryData(
                        schemaVersion: schemaVersion,
                        accounts: initialAccounts,
                        settings: settings
                    )
                    let liveId = await adapter.syncLiveAccount(registry: &scopedRegistry)
                    if let liveId {
                        scopedRegistry.setActiveLive(accountId: liveId, for: provider)
                    }

                    var accounts = scopedRegistry.accounts(for: provider)
                    if !provider.supportsAccountSwitch {
                        let defaultId = provider.supportsAPIKeyConfig
                            ? "\(provider.rawValue):api"
                            : "\(provider.rawValue):default"
                        if let liveId,
                           liveId != defaultId,
                           accounts.count > 1,
                           accounts.contains(where: { $0.id == liveId }) {
                            accounts.removeAll { $0.id == defaultId && $0.email.isEmpty }
                        }
                        if accounts.isEmpty {
                            accounts = [
                                AccountRecord(
                                    id: defaultId,
                                    provider: provider,
                                    email: "",
                                    displayName: provider.displayName,
                                    plan: provider.supportsAPIKeyConfig ? PlanInfo(kind: .api, displayName: "API") : nil,
                                    addedAt: Date(),
                                    isActiveLive: true
                                )
                            ]
                        }
                    } else {
                        accounts.sort { lhs, rhs in
                            if lhs.isActiveLive != rhs.isActiveLive {
                                return lhs.isActiveLive
                            }
                            if lhs.addedAt != rhs.addedAt {
                                return lhs.addedAt < rhs.addedAt
                            }
                            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                        }
                    }

                    guard !accounts.isEmpty else {
                        return ProviderSmokeRow(
                            provider: provider,
                            accountCount: 0,
                            liveCount: 0,
                            statusLabel: "no-accounts",
                            remainingLabel: "-",
                            balanceLabel: "-",
                            windowCount: 0,
                            sourceLabel: "-",
                            details: []
                        )
                    }

                    var details: [AccountSmokeDetail] = []
                    for account in accounts {
                        // CRITICAL: Pass exact `isActiveLive` so active Codex refresh tokens are NEVER touched.
                        let snap = await adapter.fetchQuota(for: account, isActiveLive: account.isActiveLive)
                        details.append(AccountSmokeDetail(account: account, snapshot: snap))
                    }

                    let snapshots = details.map(\.snapshot)
                    let liveCount = accounts.filter { $0.isActiveLive }.count
                    let activeIds = Set(accounts.filter { $0.isActiveLive }.map { $0.id })
                    let representative = snapshots.first(where: { activeIds.contains($0.accountId) })
                        ?? snapshots.first(where: { $0.status.isReady })
                        ?? snapshots.first

                    let readyCount = snapshots.filter { $0.status.isReady }.count
                    let statusLabel: String
                    if let rep = representative {
                        let repKind = Self.statusKindString(rep.status)
                        statusLabel = accounts.count > 1 ? "\(repKind) (\(readyCount)/\(accounts.count) ok)" : repKind
                    } else {
                        statusLabel = "none"
                    }

                    let remainingLabel: String
                    if let pct = representative?.primaryRemainingPercent, representative?.status.isReady == true {
                        remainingLabel = "\(pct)%"
                    } else if let anyReadyPct = snapshots.compactMap({ $0.status.isReady ? $0.primaryRemainingPercent : nil }).first {
                        remainingLabel = "\(anyReadyPct)%"
                    } else {
                        remainingLabel = "-"
                    }

                    let balanceLabel: String
                    if let bal = representative?.balance, representative?.status.isReady == true {
                        balanceLabel = AppStore.exactCurrencyString(bal)
                    } else {
                        balanceLabel = "-"
                    }

                    let totalWindows = snapshots.reduce(0) { $0 + $1.windows.count }
                    let sourceLabel = (representative?.sourceLabel.isEmpty == false)
                        ? representative!.sourceLabel
                        : "-"

                    return ProviderSmokeRow(
                        provider: provider,
                        accountCount: accounts.count,
                        liveCount: liveCount,
                        statusLabel: statusLabel,
                        remainingLabel: remainingLabel,
                        balanceLabel: balanceLabel,
                        windowCount: totalWindows,
                        sourceLabel: sourceLabel,
                        details: details
                    )
                }
            }

            for await row in group {
                rowsByProvider[row.provider] = row
            }
        }

        let rule = String(repeating: "-", count: 94)
        print("RoryOrbit \(AppStore.appVersion) — Quota Smoke Summary (sanitized, zero secrets)")
        print(rule)
        print(
            pad("Provider", 13)
                + pad("Accts", 6)
                + pad("Live", 5)
                + pad("Status", 23)
                + pad("Remain", 8)
                + pad("Wins", 6)
                + pad("Balance", 13)
                + "Source"
        )
        print(rule)

        for provider in providers {
            guard let row = rowsByProvider[provider] else { continue }
            print(
                pad(row.provider.displayName, 13)
                    + pad("\(row.accountCount)", 6)
                    + pad("\(row.liveCount)", 5)
                    + pad(row.statusLabel, 23)
                    + pad(row.remainingLabel, 8)
                    + pad("\(row.windowCount)", 6)
                    + pad(row.balanceLabel, 13)
                    + row.sourceLabel
            )
        }
        print(rule)

        // Detailed per-account & per-window breakdown (sanitized, zero secrets)
        print("")
        print("Detailed Accounts & Quota Windows (sanitized, zero secrets)")
        print(rule)
        let now = Date()
        for provider in providers {
            guard let row = rowsByProvider[provider] else { continue }
            print("[\(provider.displayName)]")
            if row.details.isEmpty {
                print("  (no accounts)")
                continue
            }
            for item in row.details {
                let acct = item.account
                let snap = item.snapshot
                let identity = !acct.email.isEmpty ? acct.email : acct.displayName
                let liveTag = acct.isActiveLive ? " [LIVE]" : ""
                let planName = (snap.plan ?? acct.plan)?.displayName ?? "-"
                let statusStr = Self.statusKindString(snap.status)
                let srcStr = snap.sourceLabel.isEmpty ? "-" : snap.sourceLabel
                print("  - \(identity)\(liveTag) | plan=\(planName) | status=\(statusStr) | source=\(srcStr)")

                if let msg = snap.status.message, !msg.isEmpty {
                    print("      message: \(msg)")
                }

                if snap.windows.isEmpty {
                    if snap.balance == nil && snap.status.isReady {
                        print("      (no windows)")
                    }
                } else {
                    for win in snap.windows {
                        let primaryMark = win.isPrimary ? "*" : " "
                        let durPart = win.windowSeconds.map { " | win=\(Self.compactWindowDuration($0))" } ?? ""
                        let resetPart: String
                        if let resetAt = win.resetAt {
                            let utc = Formatters.formatRFC3339UTC(resetAt)
                            let rel = Formatters.relativeResetString(to: resetAt, now: now)
                            resetPart = " | resetAt=\(utc) (\(rel))"
                        } else {
                            resetPart = " | resetAt=-"
                        }
                        let detailPart: String
                        if let detail = win.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                            detailPart = " | detail=\(detail)"
                        } else {
                            detailPart = ""
                        }
                        print("    \(primaryMark) [\(win.id)] \(win.label): \(win.remainingPercent)% rem\(durPart)\(resetPart)\(detailPart)")
                    }
                }

                if let balance = snap.balance {
                    var balParts: [String] = [
                        "\(AppStore.exactCurrencyString(balance)) (\(balance.currency.uppercased()))",
                    ]
                    if let granted = balance.grantedBalance {
                        balParts.append("granted=\(AppStore.exactCurrencyString(amount: granted, currency: balance.currency))")
                    }
                    if let toppedUp = balance.toppedUpBalance {
                        balParts.append("toppedUp=\(AppStore.exactCurrencyString(amount: toppedUp, currency: balance.currency))")
                    }
                    if let detail = balance.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                        balParts.append("detail=\(detail)")
                    }
                    print("      balance: \(balParts.joined(separator: " | "))")
                }

                if let pace = snap.paceNote?.trimmingCharacters(in: .whitespacesAndNewlines), !pace.isEmpty {
                    print("      pace: \(pace)")
                }
            }
        }
        print(rule)
        fflush(stdout)
        return 0
    }

    private static func compactWindowDuration(_ seconds: Int) -> String {
        if seconds <= 0 { return "\(seconds)s" }
        if seconds % 86_400 == 0 {
            return "\(seconds / 86_400)d"
        }
        if seconds % 3_600 == 0 {
            return "\(seconds / 3_600)h"
        }
        if seconds % 60 == 0 {
            return "\(seconds / 60)m"
        }
        return "\(seconds)s"
    }

    private static func statusKindString(_ status: QuotaStatus) -> String {
        switch status {
        case .loading: return "loading"
        case .ready(_, let stale): return stale ? "ready(stale)" : "ready"
        case .reauthRequired: return "reauthRequired"
        case .unconfigured: return "unconfigured"
        case .failed: return "failed"
        }
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        if text.count >= width {
            return String(text.prefix(max(1, width - 1))) + " "
        }
        return text + String(repeating: " ", count: width - text.count)
    }

    static func runExportAccountPoolJSON(args: [String]) async -> Int32 {
        var maxAgeSeconds: TimeInterval = 240
        var forceRefresh = false
        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            if arg == "--refresh" {
                forceRefresh = true
                idx += 1
            } else if arg == "--max-age" {
                guard idx + 1 < args.count,
                      let parsed = Double(args[idx + 1]),
                      parsed.isFinite,
                      parsed >= 0 else {
                    fputs("错误: --max-age 需要一个非负数字参数\n", stderr)
                    return 2
                }
                maxAgeSeconds = parsed
                idx += 2
            } else if arg.hasPrefix("--max-age=") {
                let rawVal = String(arg.dropFirst("--max-age=".count))
                guard let parsed = Double(rawVal),
                      parsed.isFinite,
                      parsed >= 0 else {
                    fputs("错误: --max-age 需要一个非负数字参数\n", stderr)
                    return 2
                }
                maxAgeSeconds = parsed
                idx += 1
            } else {
                fputs("未知参数: \(arg)\n", stderr)
                return 2
            }
        }

        do {
            let data = try await AccountPoolExporter.shared.exportJSONData(
                maxAgeSeconds: maxAgeSeconds,
                forceRefresh: forceRefresh
            )
            if let text = String(data: data, encoding: .utf8) {
                print(text)
            } else {
                FileHandle.standardOutput.write(data)
            }
            fflush(stdout)
            return 0
        } catch {
            fputs("导出 AccountPool JSON 失败: \(error.localizedDescription)\n", stderr)
            fflush(stderr)
            return 1
        }
    }

    static func runExportUsageArchive(args: [String]) async -> Int32 {
        var forceFullRescan = false
        for arg in args {
            if arg == "--full" {
                forceFullRescan = true
            } else {
                fputs("未知参数: \(arg)\n", stderr)
                return 2
            }
        }

        let snapshot = await TokenUsageEngine.shared.scanAndExportArchive(forceFullRescan: forceFullRescan)
        let summaryJSON = TokenUsageEngine.formatArchiveExportSummaryJSON(snapshot)
        print(summaryJSON)
        fflush(stdout)
        return 0
    }

    static func runSmokeUsage() async -> Int32 {
        let snapshot = await TokenUsageEngine.shared.scanAndExportArchive(forceFullRescan: false)
        let report = TokenUsageEngine.formatSmokeReport(snapshot)
        print(report)
        fflush(stdout)
        return 0
    }

    static func handleCLIArgumentsIfPresent() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else { return }

        // Ignore macOS LaunchServices / AppKit system arguments (e.g. -psn_*, -AppleLanguages).
        let userArgs = args.filter { arg in
            if arg.hasPrefix("-psn_") || arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
                return false
            }
            return true
        }
        guard let first = userArgs.first else { return }
        let rest = Array(userArgs.dropFirst())

        switch first {
        case "--version", "-v":
            print(versionString)
            fflush(stdout)
            Darwin.exit(0)

        case "--help", "-h":
            printUsage()
            fflush(stdout)
            Darwin.exit(0)

        case "--migrate-legacy":
            let code = runMigrateLegacy()
            Darwin.exit(code)

        case "--smoke-quota":
            Task {
                let code = await runSmokeQuota()
                Darwin.exit(code)
            }
            dispatchMain()

        case "--export-accountpool-json":
            Task {
                let code = await runExportAccountPoolJSON(args: rest)
                Darwin.exit(code)
            }
            dispatchMain()

        case "--export-usage-archive":
            Task {
                let code = await runExportUsageArchive(args: rest)
                Darwin.exit(code)
            }
            dispatchMain()

        case "--smoke-usage":
            Task {
                let code = await runSmokeUsage()
                Darwin.exit(code)
            }
            dispatchMain()

        default:
            if first.hasPrefix("--") {
                fputs("未知参数: \(first)\n", stderr)
                printUsage()
                Darwin.exit(2)
            }
        }
    }
}

// MARK: - GUI Menu Bar AppDelegate

@MainActor
final class RoryOrbitAppDelegate: NSObject, NSApplicationDelegate {
    private enum StatusItemIconKey: Equatable {
        case hidden
        case provider(ProviderID)
        case pulsarBrand
        case sfSymbol(String, isWarning: Bool)
    }

    private struct StatusItemSnapshot: Equatable {
        let summary: MenuBarSummary
        let iconKey: StatusItemIconKey
    }

    private var store: AppStore!
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var storeCancellable: AnyCancellable?
    private var popoverSizeCancellable: AnyCancellable?
    private var quickMenu: NSMenu!
    private var lastStatusItemSnapshot: StatusItemSnapshot?

    nonisolated override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let appStore = AppStore()
        self.store = appStore

        // Configure Liquid Glass translucent popover (follows system Light/Dark mode)
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.appearance = nil
        pop.contentSize = clampedPopoverSize(from: appStore.registry.settings)
        let hostingController = NSHostingController(
            rootView: MenuBarView(
                store: appStore,
                onOpenSettings: { [weak self] in
                    self?.openSettingsWindow()
                },
                onQuit: {
                    NSApp.terminate(nil)
                }
            )
        )
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        pop.contentViewController = hostingController
        self.popover = pop

        // Configure right-click quick menu
        self.quickMenu = buildQuickMenu()

        // Configure status bar item
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(handleStatusBarClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }

        // Observe AppStore changes via Combine to keep status bar summary synced
        self.storeCancellable = appStore.objectWillChange
            .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
            }

        // Sync popover size immediately when dragged or adjusted via presets/settings
        self.popoverSizeCancellable = appStore.$registry
            .map { [weak self] registry -> NSSize in
                self?.clampedPopoverSize(from: registry.settings)
                    ?? NSSize(width: registry.settings.popoverWidth, height: registry.settings.popoverHeight)
            }
            .removeDuplicates { lhs, rhs in
                abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
            }
            .sink { [weak self] newSize in
                self?.syncPopoverContentSize(newSize)
            }

        updateStatusItem()

        // Trigger initial read-only quota refresh shortly after launch (TokenUsageEngine scans in parallel)
        Task { [weak self] in
            await self?.store.refreshAll()
        }
    }

    private func clampedPopoverSize(from settings: AppSettings) -> NSSize {
        let width = AppSettings.clamp(
            settings.popoverWidth,
            to: AppSettings.popoverWidthRange,
            fallback: AppSettings.defaultPopoverWidth
        ).rounded()
        let height = AppSettings.clamp(
            settings.popoverHeight,
            to: AppSettings.popoverHeightRange,
            fallback: AppSettings.defaultPopoverHeight
        ).rounded()
        return NSSize(width: width, height: height)
    }

    private func syncPopoverContentSize(_ targetSize: NSSize) {
        guard let popover else { return }
        let clamped = NSSize(
            width: AppSettings.clamp(
                Double(targetSize.width),
                to: AppSettings.popoverWidthRange,
                fallback: AppSettings.defaultPopoverWidth
            ).rounded(),
            height: AppSettings.clamp(
                Double(targetSize.height),
                to: AppSettings.popoverHeightRange,
                fallback: AppSettings.defaultPopoverHeight
            ).rounded()
        )
        let current = popover.contentSize
        guard abs(current.width - clamped.width) >= 0.5
            || abs(current.height - clamped.height) >= 0.5 else {
            return
        }
        popover.contentSize = clamped
    }

    private func buildQuickMenu() -> NSMenu {
        let menu = NSMenu(title: "Pulsar")

        let openItem = NSMenuItem(
            title: "打开 Pulsar",
            action: #selector(menuOpenPopover),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(
            title: "刷新全部配额",
            action: #selector(menuRefreshAll),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        let scanTokenItem = NSMenuItem(
            title: "重新扫描本地 Token",
            action: #selector(menuScanTokenUsage),
            keyEquivalent: ""
        )
        scanTokenItem.target = self
        menu.addItem(scanTokenItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "偏好设置…",
            action: #selector(menuOpenSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "退出 Pulsar",
            action: #selector(menuQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func resolvedStatusItemIconKey(for summary: MenuBarSummary) -> StatusItemIconKey {
        if summary.symbol.isEmpty {
            return .hidden
        }
        if let provider = summary.providerKind {
            return .provider(provider)
        }
        if summary.symbol == "sparkles" {
            return .pulsarBrand
        }
        return .sfSymbol(summary.symbol, isWarning: summary.isWarning)
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button, let store else { return }
        let summary = store.menuBarSummaryDetail()
        let iconKey = resolvedStatusItemIconKey(for: summary)
        let snapshot = StatusItemSnapshot(summary: summary, iconKey: iconKey)

        if lastStatusItemSnapshot == snapshot {
            return
        }
        lastStatusItemSnapshot = snapshot

        switch iconKey {
        case .hidden:
            button.image = nil
            button.imagePosition = .noImage

        case .provider(let provider):
            if let officialImage = ProviderBrandIcon.menuBarImage(for: provider, size: 15) {
                button.image = officialImage
                button.imagePosition = summary.title.isEmpty ? .imageOnly : .imageLeading
            } else {
                button.image = nil
                button.imagePosition = .noImage
            }

        case .pulsarBrand:
            if let pulsarImage = ProviderBrandIcon.pulsarMenuBarImage(size: 15) {
                button.image = pulsarImage
                button.imagePosition = summary.title.isEmpty ? .imageOnly : .imageLeading
            } else {
                button.image = nil
                button.imagePosition = .noImage
            }

        case .sfSymbol(let symbolName, let isWarning):
            if let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Pulsar") {
                let configuredImage: NSImage?
                if isWarning {
                    let sizeConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                    let colorConfig = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
                    configuredImage = baseImage.withSymbolConfiguration(sizeConfig.applying(colorConfig))
                    configuredImage?.isTemplate = false
                } else {
                    let sizeConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                    configuredImage = baseImage.withSymbolConfiguration(sizeConfig)
                    configuredImage?.isTemplate = true
                }
                button.image = configuredImage ?? baseImage
                button.imagePosition = summary.title.isEmpty ? .imageOnly : .imageLeading
            } else {
                button.image = nil
                button.imagePosition = .noImage
            }
        }

        if summary.title.isEmpty {
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            ]
            if summary.isWarning {
                attrs[.foregroundColor] = NSColor.systemOrange
            }
            let leadingGap = button.image == nil ? "" : " "
            button.attributedTitle = NSAttributedString(string: "\(leadingGap)\(summary.title)", attributes: attrs)
        }

        button.toolTip = summary.tooltip
    }

    @objc private func handleStatusBarClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)

        if isRightClick {
            if popover.isShown {
                popover.performClose(sender)
            }
            quickMenu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height + 4),
                in: sender
            )
            return
        }

        togglePopover(sender)
    }

    private func showPopover(from button: NSStatusBarButton) {
        syncPopoverContentSize(clampedPopoverSize(from: store.registry.settings))
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        store.refreshIfStaleOnMenuOpen()
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover(from: sender)
        }
    }

    func openSettingsWindow() {
        if popover.isShown {
            popover.performClose(nil)
        }

        if let existing = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 568, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pulsar · 偏好设置"
        window.minSize = NSSize(width: 540, height: 520)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: SettingsView(store: store)
        )
        window.center()

        self.settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func menuOpenPopover() {
        guard let button = statusItem?.button else { return }
        if !popover.isShown {
            showPopover(from: button)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func menuScanTokenUsage() {
        Task { [weak self] in
            await self?.store.refreshTokenUsage()
        }
    }

    @objc private func menuRefreshAll() {
        Task { [weak self] in
            await self?.store.refreshAll()
        }
    }

    @objc private func menuOpenSettings() {
        openSettingsWindow()
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Process Entry Point

CLIRunner.handleCLIArgumentsIfPresent()

let app = NSApplication.shared
let appDelegate = RoryOrbitAppDelegate()
app.delegate = appDelegate
app.run()
