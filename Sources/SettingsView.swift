import AppKit
import SwiftUI

public struct SettingsView: View {
    @ObservedObject public var store: AppStore
    public var onOpenTokenDashboard: () -> Void

    private struct WindowSizePreset: Identifiable {
        let id: String
        let label: String
        let width: Double
        let height: Double

        var sizeText: String {
            "\(Int(width))×\(Int(height))"
        }
    }

    private static let popoverSizePresets: [WindowSizePreset] = [
        WindowSizePreset(id: "pop_narrow", label: "超窄", width: 350, height: 560),
        WindowSizePreset(id: "pop_standard", label: "标准", width: 390, height: 620),
        WindowSizePreset(id: "pop_wide", label: "宽屏", width: 520, height: 720),
    ]

    @State private var kimiAPIKeyDraft: String = ""
    @State private var deepSeekAPIKeyDraft: String = ""
    @State private var apiKeyFeedback: String? = nil
    @State private var isFixedProviderPopoverPresented: Bool = false

    public init(
        store: AppStore,
        onOpenTokenDashboard: @escaping () -> Void = {}
    ) {
        self.store = store
        self.onOpenTokenDashboard = onOpenTokenDashboard
    }

    public var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }

            providersTab
                .tabItem {
                    Label("服务与密钥", systemImage: "square.grid.2x2")
                }

            migrationAndDataTab
                .tabItem {
                    Label("迁移与数据", systemImage: "externaldrive")
                }
        }
        .padding(16)
        .frame(
            minWidth: 540,
            idealWidth: 568,
            maxWidth: .infinity,
            minHeight: 520,
            idealHeight: 620,
            maxHeight: .infinity
        )
    }

    // MARK: - General Tab

    private var generalTab: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                settingsBrandHeader
                softwareUpdateCard
                startupAndRefreshCard
                menuBarCustomizationCard
                windowSizeAndCardsCard
                displayAndAlertsCard
            }
            .padding(.vertical, 6)
            .padding(.leading, 2)
            .padding(.trailing, 8)
        }
    }

    private var settingsBrandHeader: some View {
        HStack(spacing: 11) {
            PulsarBrandIconView(size: 36, showGlowShadow: true)

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 6) {
                    Text("Pulsar")
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                    Text("v\(AppStore.appVersion)")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1.5)
                        .background(Color.accentColor.opacity(0.13))
                        .overlay(
                            Capsule()
                                .stroke(Color.accentColor.opacity(0.28), lineWidth: 0.65)
                        )
                        .clipShape(Capsule())
                }

                Text("多服务配额与账号切换 · 纯本地只读 · 零 Claude 联网")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(nsColor: .systemGreen))
                Text("纯本地零联网")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(nsColor: .systemGreen))
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .systemGreen).opacity(0.11))
            .overlay(
                Capsule()
                    .stroke(Color(nsColor: .systemGreen).opacity(0.28), lineWidth: 0.65)
            )
            .clipShape(Capsule())
            .help("Token 统计仅只读本地会话日志，绝不联网请求 Claude 或读取 Claude 凭据")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitCardStyle(cornerRadius: 11, hoverLift: false)
    }

    // MARK: - Software Update Card (GitHub Releases)

    private var effectiveLastUpdateCheckAt: Date? {
        if case .upToDate(let checkedAt) = store.updatePhase {
            return checkedAt
        }
        return store.registry.settings.lastUpdateCheckAt
    }

    private func formattedVersionTag(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            return "v" + trimmed.dropFirst()
        }
        return "v\(trimmed)"
    }

    private func isUpdateVersionSkipped(_ version: String) -> Bool {
        guard let skipped = store.registry.settings.skippedUpdateVersion else {
            return false
        }
        return skipped.caseInsensitiveCompare(version) == .orderedSame
    }

    private func briefReleaseNotes(for info: ReleaseUpdateInfo) -> String? {
        let rawLines = info.releaseNotes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var cleaned: [String] = []
        cleaned.reserveCapacity(4)

        for rawLine in rawLines {
            var line = rawLine
            while line.hasPrefix("#") {
                line.removeFirst()
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = "• " + String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }
            cleaned.append(line)
            if cleaned.count >= 4 {
                break
            }
        }

        if !cleaned.isEmpty {
            let joined = cleaned.joined(separator: "\n")
            if joined.count > 260 {
                return String(joined.prefix(259)) + "…"
            }
            return joined
        }

        let trimmedTitle = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty,
           trimmedTitle.caseInsensitiveCompare(info.tagName) != .orderedSame,
           trimmedTitle.caseInsensitiveCompare(info.version) != .orderedSame {
            return trimmedTitle
        }
        return nil
    }

    private var softwareUpdateCard: some View {
        let lastChecked = effectiveLastUpdateCheckAt
        let lastCheckedSummary: String = {
            if let lastChecked {
                return "上次检查：\(store.relativeTimeAgoString(since: lastChecked))"
            }
            return "上次检查：尚未检查"
        }()

        return settingsCard(title: "软件更新（GitHub Releases）", icon: "arrow.down.circle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("当前版本")
                                .font(.system(size: 12, weight: .medium))
                            Text(formattedVersionTag(AppStore.appVersion))
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 6.5)
                                .padding(.vertical, 1.5)
                                .background(Color.accentColor.opacity(0.12))
                                .clipShape(Capsule())
                        }

                        Text(lastCheckedSummary)
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .help(lastChecked.map { "检查时间：\($0.formatted(date: .numeric, time: .shortened))" } ?? "尚未执行过更新检查")
                    }

                    Spacer(minLength: 8)

                    Button {
                        Task { await store.checkForUpdates(userInitiated: true) }
                    } label: {
                        Label(
                            store.updatePhase == .checking ? "检查中…" : "立即检查更新",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.updatePhase.isBusy)
                    .fixedSize()
                }

                updatePhaseStatusBox
                    .animation(OrbitMotion.snappy, value: store.updatePhase)

                Divider().opacity(0.35)

                settingsSwitchRow(
                    title: "自动检查更新（每 12 小时）",
                    isOn: Binding(
                        get: { store.registry.settings.autoCheckUpdates },
                        set: { enabled in
                            store.setAutoCheckUpdates(enabled)
                        }
                    )
                )

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: .systemGreen))
                        .padding(.top, 1.5)
                    Text("仅访问 GitHub Releases（HTTPS 白名单），下载前强制校验 SHA-256，零 Claude 联网")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var updatePhaseStatusBox: some View {
        switch store.updatePhase {
        case .idle, .upToDate:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(nsColor: .systemGreen))
                Text("当前已是最新版本")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.primary)
                Spacer(minLength: 6)
                Button("前往 Release 页面") {
                    store.openUpdateReleasePage()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.accentColor)
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .systemGreen).opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .systemGreen).opacity(0.22), lineWidth: 0.7)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
                Text("正在检查 GitHub Releases…")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.7)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .available(let info):
            let versionLabel = formattedVersionTag(info.version)
            let notesPreview = briefReleaseNotes(for: info)
            let skipped = isUpdateVersionSkipped(info.version)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.accentColor)
                    Text("发现新版本 \(versionLabel)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.primary)
                    if let bytes = info.assetSizeBytes, bytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 1.5)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(Capsule())
                            .fixedSize()
                    }
                    Spacer(minLength: 4)
                    if skipped {
                        Text("已忽略横幅提醒")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 1.5)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(Capsule())
                            .fixedSize()
                    }
                }

                if let notesPreview {
                    Text(notesPreview)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button {
                        store.startUpdateDownloadAndInstall()
                    } label: {
                        Label("一键下载并更新", systemImage: "arrow.down.to.line")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .fixedSize()

                    Button("前往 Release 页面") {
                        store.openUpdateReleasePage()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()

                    Spacer(minLength: 4)

                    if !skipped {
                        Button("忽略此版本") {
                            store.skipAvailableUpdate()
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize()
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.28), lineWidth: 0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .downloading(let info, let progress):
            let clamped = min(max(progress.isFinite ? progress : 0.0, 0.0), 1.0)
            let percent = Int((clamped * 100.0).rounded())

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                    Text("正在下载 Pulsar \(formattedVersionTag(info.version))…")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer(minLength: 8)
                    Text("\(percent)%")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .orbitNumericTransition()
                        .foregroundColor(.accentColor)
                }

                OrbitAnimatedProgressBar(
                    fraction: clamped,
                    tint: .accentColor,
                    height: 6,
                    animateOnAppear: false
                )

                Text("下载完成后将强制校验 SHA-256 摘要，校验通过后自动安全替换。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.24), lineWidth: 0.75)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .verifying(let info):
            updateStageProgressBox(
                title: "正在校验 \(formattedVersionTag(info.version)) SHA-256…",
                detail: "强制核对官方发布的 SHA-256 摘要与安装包完整性，不匹配将立即中止。",
                tint: .accentColor
            )

        case .installing(let info):
            updateStageProgressBox(
                title: "正在安全替换并重启至 \(formattedVersionTag(info.version))…",
                detail: "SHA-256 与签名校验通过，正在挂载安装包并准备原地替换应用。",
                tint: .accentColor
            )

        case .readyToRelaunch(let info):
            updateStageProgressBox(
                title: "Pulsar \(formattedVersionTag(info.version)) 已就绪，正在安全替换并重启…",
                detail: "应用将自动关闭并在数秒内以新版本重新启动，请稍候。",
                tint: Color(nsColor: .systemGreen)
            )

        case .manualInstallOpened(let info, let dmgPath):
            let fileName = URL(fileURLWithPath: dmgPath).lastPathComponent
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(nsColor: .systemGreen))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2.5) {
                        Text("已通过 SHA-256 校验并打开 DMG（\(formattedVersionTag(info.version))）")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("已自动打开安装包 \(fileName)，请将 Pulsar 拖入 Applications 完成更新。")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dmgPath)])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()

                    Button("前往 Release 页面") {
                        store.openUpdateReleasePage()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .systemGreen).opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .systemGreen).opacity(0.25), lineWidth: 0.75)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .failed(let message):
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(nsColor: .systemRed))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2.5) {
                        Text("更新失败")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(Color(nsColor: .systemRed))
                        Text(message)
                            .font(.system(size: 10.5))
                            .foregroundColor(.primary.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await store.checkForUpdates(userInitiated: true) }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .fixedSize()

                    Button("前往 GitHub 页面") {
                        store.openUpdateReleasePage()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .systemRed).opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .systemRed).opacity(0.28), lineWidth: 0.75)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func updateStageProgressBox(title: String, detail: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.75)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2.5) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.24), lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var startupAndRefreshCard: some View {
        settingsCard(title: "启动与刷新", icon: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 11) {
                settingsSwitchRow(
                    title: "登录 macOS 时自动启动 Pulsar",
                    isOn: Binding(
                        get: { store.registry.settings.launchAtLogin },
                        set: { enabled in
                            store.updateSettings { $0.launchAtLogin = enabled }
                        }
                    )
                )

                Divider().opacity(0.4)

                HStack(spacing: 10) {
                    Text("后台自动刷新频率")
                        .font(.system(size: 12))
                        .fixedSize()
                    Spacer(minLength: 8)
                    Picker("", selection: Binding(
                        get: { store.registry.settings.refreshCadence },
                        set: { cadence in
                            store.updateSettings { $0.refreshCadence = cadence }
                        }
                    )) {
                        ForEach(RefreshCadence.allCases) { cadence in
                            Text(cadence.displayName).tag(cadence)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 165)
                }

                Divider().opacity(0.35)

                settingsSwitchRow(
                    title: "打开菜单栏弹窗时自动刷新过期数据",
                    isOn: Binding(
                        get: { store.registry.settings.refreshOnMenuOpen },
                        set: { enabled in
                            store.updateSettings { $0.refreshOnMenuOpen = enabled }
                        }
                    )
                )
            }
        }
    }

    private var menuBarCustomizationCard: some View {
        let mode = store.registry.settings.menuBarDisplayMode
        return settingsCard(title: "菜单栏自定义", icon: "menubar.rectangle") {
            VStack(alignment: .leading, spacing: 12) {
                menuBarLivePreviewStrip

                HStack {
                    Text("菜单栏显示模式")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { store.registry.settings.menuBarDisplayMode },
                        set: { nextMode in
                            withAnimation(OrbitMotion.snappy) {
                                store.updateSettings { $0.menuBarDisplayMode = nextMode }
                            }
                        }
                    )) {
                        ForEach(MenuBarDisplayMode.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 175)
                }

                if mode == .custom {
                    Divider().opacity(0.4)
                    customMenuBarEditor
                        .transition(.opacity)
                } else {
                    nonCustomModeQuotaOptions(for: mode)
                        .transition(.opacity)
                }
            }
        }
    }

    private var displayAndAlertsCard: some View {
        settingsCard(title: "显示与预警", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 11) {
                settingsSwitchRow(
                    title: "优先显示剩余百分比（关闭则显示已使用百分比）",
                    isOn: Binding(
                        get: { store.registry.settings.showRemainingPercent },
                        set: { enabled in
                            store.updateSettings { $0.showRemainingPercent = enabled }
                        }
                    )
                )

                Divider().opacity(0.35)

                settingsSwitchRow(
                    title: "使用相对倒计时显示重置时间（如「2小时15分后重置」）",
                    isOn: Binding(
                        get: { store.registry.settings.showResetRelative },
                        set: { enabled in
                            store.updateSettings { $0.showResetRelative = enabled }
                        }
                    )
                )

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("低余量警告阈值")
                        Spacer()
                        let pct = Int((clampedWarnThreshold * 100.0).rounded())
                        Text("\(pct)%")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .orbitNumericTransition()
                            .foregroundColor(Color(nsColor: .systemOrange))
                    }

                    Slider(
                        value: Binding(
                            get: { clampedWarnThreshold },
                            set: { newVal in
                                let rounded = (newVal * 20.0).rounded() / 20.0
                                store.updateSettings { $0.lowQuotaWarnThreshold = min(max(rounded, 0.10), 0.40) }
                            }
                        ),
                        in: 0.10...0.40,
                        step: 0.05
                    )

                    HStack {
                        Text("10%")
                        Spacer()
                        Text("20%")
                        Spacer()
                        Text("30%")
                        Spacer()
                        Text("40%")
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Menu Bar Live Preview

    private var menuBarLivePreviewStrip: some View {
        let summary = store.menuBarSummaryDetail()
        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                OrbitPulseDot(
                    color: summary.isWarning ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen),
                    size: 5.5,
                    isActive: summary.isWarning
                )
                Text("菜单栏实时预览")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .fixedSize()
            }

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                if !summary.symbol.isEmpty {
                    if let provider = summary.providerKind {
                        ProviderBrandIconView(
                            provider: provider,
                            size: 14,
                            renderingAccent: summary.isWarning ? Color(nsColor: .systemOrange) : nil
                        )
                    } else if summary.symbol == "sparkles",
                              let pulsarImage = ProviderBrandIcon.pulsarMenuBarImage(size: 14) {
                        Image(nsImage: pulsarImage)
                            .renderingMode(.template)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                            .foregroundColor(summary.isWarning ? Color(nsColor: .systemOrange) : .primary)
                    } else {
                        Image(systemName: summary.symbol)
                            .font(.system(size: 12, weight: summary.isWarning ? .semibold : .medium))
                            .foregroundColor(summary.isWarning ? Color(nsColor: .systemOrange) : .primary)
                    }
                }
                if !summary.title.isEmpty {
                    Text(summary.title)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .orbitNumericTransition()
                        .foregroundColor(summary.isWarning ? Color(nsColor: .systemOrange) : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background(
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(
                        summary.isWarning
                            ? Color(nsColor: .systemOrange).opacity(0.12)
                            : Color(nsColor: .controlBackgroundColor).opacity(0.68)
                    )
                }
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        summary.isWarning
                            ? Color(nsColor: .systemOrange).opacity(0.48)
                            : Color.primary.opacity(0.16),
                        lineWidth: 0.8
                    )
            )
            .clipShape(Capsule())
            .animation(OrbitMotion.snappy, value: summary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.055))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 0.7)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(summary.tooltip)
    }

    // MARK: - Non-Custom Mode Quota Quick Controls

    @ViewBuilder
    private func nonCustomModeQuotaOptions(for mode: MenuBarDisplayMode) -> some View {
        let custom = store.registry.settings.menuBarCustom
        VStack(alignment: .leading, spacing: 9) {
            if mode == .selectedProvider || mode == .compactDots {
                quotaWindowSelectorBlock(
                    window: custom.quotaWindow,
                    dualFormat: custom.quotaDualFormat,
                    showDualFormatOption: mode == .selectedProvider,
                    onSelectWindow: { nextWindow in
                        withAnimation(OrbitMotion.snappy) {
                            store.updateMenuBarCustom { $0.quotaWindow = nextWindow }
                        }
                    },
                    onSelectDualFormat: { nextFormat in
                        withAnimation(OrbitMotion.snappy) {
                            store.updateMenuBarCustom { $0.quotaDualFormat = nextFormat }
                        }
                    }
                )
            }

            if mode == .selectedProvider || mode == .lowestQuota || mode == .compactDots {
                antigravityPoolSelectorRow
            }

            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                Text("想在状态栏并排看多家服务余额，或任选 14 项实时指标？")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("切换自定义组合") {
                    withAnimation(OrbitMotion.snappy) {
                        store.updateSettings { $0.menuBarDisplayMode = .custom }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .fixedSize()
            }
            .padding(.top, mode == .iconOnly ? 0 : 2)
        }
        .padding(9)
        .background(Color.primary.opacity(0.025))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.7)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Custom Menu Bar Editor (14 Modules + Weekly/Dual/Multi Quota)

    private var orderedCustomModules: [MenuBarModule] {
        let enabled = MenuBarCustomConfig.deduplicatedModules(store.registry.settings.menuBarCustom.modules)
        let disabled = MenuBarModule.allCases.filter { !enabled.contains($0) }
        return enabled + disabled
    }

    private var orderedMultiQuotaProviders: [ProviderID] {
        let selected = MenuBarCustomConfig.deduplicatedProviders(store.registry.settings.menuBarCustom.quotaMultiProviders)
        let remaining = ProviderID.allCases.filter { !selected.contains($0) }
        return selected + remaining
    }

    private func iconStyleLabel(for style: MenuBarIconStyle) -> String {
        switch style {
        case .provider: return "跟随服务官方图标"
        case .pulsar: return "Pulsar 图标"
        case .hidden: return "隐藏图标仅文字"
        }
    }

    private func quotaSourceShortLabel(for source: MenuBarQuotaSource) -> String {
        switch source {
        case .selected: return "当前选中服务"
        case .lowest: return "全局最低"
        case .fixed: return "指定单个服务"
        case .multi: return "多服务并排"
        }
    }

    private var customMenuBarEditor: some View {
        let custom = store.registry.settings.menuBarCustom
        let enabledModules = MenuBarCustomConfig.deduplicatedModules(custom.modules)
        let hasQuotaModule = enabledModules.contains(.quota)
            || enabledModules.contains(.quotaFiveHour)
            || enabledModules.contains(.quotaWeekly)
            || enabledModules.contains(.nextResetCountdown)
        let hasRateModule = enabledModules.contains(.tokenRate) || enabledModules.contains(.tokenRate60s)
        let isDefaultModules = (enabledModules == MenuBarCustomConfig.defaultModules)

        return VStack(alignment: .leading, spacing: 12) {
            // 1. Icon style & separator
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text("图标样式")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .fixedSize()
                    Picker("", selection: Binding(
                        get: { store.registry.settings.menuBarCustom.iconStyle },
                        set: { style in
                            withAnimation(OrbitMotion.snappy) {
                                store.updateMenuBarCustom { $0.iconStyle = style }
                            }
                        }
                    )) {
                        ForEach(MenuBarIconStyle.allCases) { style in
                            Text(iconStyleLabel(for: style)).tag(style)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 152)
                }

                Spacer(minLength: 6)

                HStack(spacing: 6) {
                    Text("分隔符")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .fixedSize()
                    Picker("", selection: Binding(
                        get: { store.registry.settings.menuBarCustom.separator },
                        set: { sep in
                            store.updateMenuBarCustom { $0.separator = sep }
                        }
                    )) {
                        ForEach(MenuBarSeparator.allCases) { sep in
                            Text(sep.displayName).tag(sep)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 124)
                }
            }

            // 2. Service Quota / Balance Fine-Grained Customization
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)
                    Text("服务配额 / 余额定制")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    if !hasQuotaModule {
                        Text("需勾选下方配额类模块生效")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                // Default Quota Window + Dual Format
                quotaWindowSelectorBlock(
                    window: custom.quotaWindow,
                    dualFormat: custom.quotaDualFormat,
                    showDualFormatOption: true,
                    onSelectWindow: { nextWindow in
                        withAnimation(OrbitMotion.snappy) {
                            store.updateMenuBarCustom { $0.quotaWindow = nextWindow }
                        }
                    },
                    onSelectDualFormat: { nextFormat in
                        withAnimation(OrbitMotion.snappy) {
                            store.updateMenuBarCustom { $0.quotaDualFormat = nextFormat }
                        }
                    }
                )

                Divider().opacity(0.35)

                // Quota Source: Selected / Lowest / Fixed / Multi-Provider Side-by-Side
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("配额来源")
                            .font(.system(size: 11.5, weight: .medium))
                        Spacer()
                        if custom.quotaSource == .multi {
                            Text("支持同时常驻多家服务余额")
                                .font(.system(size: 10))
                                .foregroundColor(.accentColor)
                        }
                    }

                    Picker("", selection: Binding(
                        get: { store.registry.settings.menuBarCustom.quotaSource },
                        set: { source in
                            withAnimation(OrbitMotion.snappy) {
                                store.updateMenuBarCustom { $0.quotaSource = source }
                            }
                        }
                    )) {
                        ForEach(MenuBarQuotaSource.allCases) { source in
                            Text(quotaSourceShortLabel(for: source)).tag(source)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    if custom.quotaSource == .fixed {
                        fixedProviderPickerRow(custom: custom)
                            .transition(.opacity)
                    } else if custom.quotaSource == .multi {
                        multiProviderSelectorCard(custom: custom)
                            .transition(.opacity)
                    }
                }

                Divider().opacity(0.35)

                // Antigravity Pool Preference
                antigravityPoolSelectorRow

                // Provider Short Prefix Toggle
                settingsSwitchRow(
                    title: "显示服务缩写前缀（如 AGY、Codex、DS）",
                    fontSize: 11.5,
                    controlSize: .mini,
                    isOn: Binding(
                        get: { store.registry.settings.menuBarCustom.showProviderPrefix },
                        set: { showPrefix in
                            store.updateMenuBarCustom { $0.showProviderPrefix = showPrefix }
                        }
                    )
                )
            }
            .padding(10)
            .background(Color.primary.opacity(0.025))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.065), lineWidth: 0.7)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(hasQuotaModule ? 1.0 : 0.58)

            // 3. All 14 Display Modules & Ordering
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text("显示模块与顺序")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("已启用 \(enabledModules.count) / \(MenuBarModule.allCases.count)")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.secondary)

                    Button("恢复默认") {
                        withAnimation(OrbitMotion.snappy) {
                            store.updateMenuBarCustom { cfg in
                                cfg.modules = MenuBarCustomConfig.defaultModules
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isDefaultModules)
                    .help("恢复默认启用的 3 项核心模块（服务配额 · 实时速度 · 今日 Tokens）")
                }

                VStack(spacing: 3) {
                    ForEach(orderedCustomModules) { module in
                        customModuleRow(module: module, enabledModules: enabledModules)
                    }
                }
                .padding(6)
                .background(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 0.7)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            // 4. Token/s Rate Options
            VStack(alignment: .leading, spacing: 8) {
                Text("实时测速 (tok/s) 选项")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack {
                    Text("速率口径")
                        .font(.system(size: 11.5))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { store.registry.settings.menuBarCustom.rateMetric },
                        set: { metric in
                            store.updateMenuBarCustom { $0.rateMetric = metric }
                        }
                    )) {
                        ForEach(MenuBarRateMetric.allCases) { metric in
                            Text(metric.displayName).tag(metric)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 195)
                }

                settingsSwitchRow(
                    title: "空闲无生成时自动隐藏 tok/s",
                    fontSize: 11.5,
                    controlSize: .mini,
                    isOn: Binding(
                        get: { store.registry.settings.menuBarCustom.hideRateWhenIdle },
                        set: { hideIdle in
                            store.updateMenuBarCustom { $0.hideRateWhenIdle = hideIdle }
                        }
                    )
                )
            }
            .padding(10)
            .background(Color.primary.opacity(0.025))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.065), lineWidth: 0.7)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(hasRateModule ? 1.0 : 0.58)
        }
    }

    private func quotaWindowSelectorBlock(
        window: MenuBarQuotaWindow,
        dualFormat: MenuBarQuotaDualFormat,
        showDualFormatOption: Bool,
        onSelectWindow: @escaping (MenuBarQuotaWindow) -> Void,
        onSelectDualFormat: @escaping (MenuBarQuotaDualFormat) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("默认配额窗口")
                    .font(.system(size: 11.5, weight: .medium))
                if window == .weeklyFirst {
                    Text("默认推荐")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.13))
                        .clipShape(Capsule())
                }
                Spacer()
            }

            Picker("", selection: Binding(
                get: { window },
                set: { onSelectWindow($0) }
            )) {
                ForEach(MenuBarQuotaWindow.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text(window.descriptionText)
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if showDualFormatOption && window == .both5hAndWeekly {
                HStack(spacing: 8) {
                    Text("双显格式")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize()
                    Spacer(minLength: 6)
                    Picker("", selection: Binding(
                        get: { dualFormat },
                        set: { onSelectDualFormat($0) }
                    )) {
                        ForEach(MenuBarQuotaDualFormat.allCases) { fmt in
                            Text(fmt.displayName).tag(fmt)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 242)
                }
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
    }

    private var antigravityPoolSelectorRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                ProviderBrandIconView(provider: .antigravity, size: 14)
                Text("Antigravity 追踪池")
                    .font(.system(size: 11.5))
                    .fixedSize()
            }
            Spacer(minLength: 6)
            Picker("", selection: Binding(
                get: { store.registry.settings.menuBarCustom.antigravityPool },
                set: { pool in
                    store.setAntigravityPool(pool)
                }
            )) {
                ForEach(AntigravityPoolPreference.allCases) { pool in
                    Text(pool.displayName).tag(pool)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(maxWidth: 256)
        }
    }

    private func liveProviderQuotaPreview(for provider: ProviderID, custom: MenuBarCustomConfig) -> String {
        if let formatted = store.formattedQuotaText(
            for: provider,
            window: custom.quotaWindow,
            dualFormat: custom.quotaDualFormat,
            includePrefix: false,
            agPool: custom.antigravityPool
        ) {
            return formatted
        }
        let metrics = store.quotaMetrics(for: provider, agPool: custom.antigravityPool)
        if metrics.isLoading { return "刷新中" }
        if metrics.isUnconfigured { return "未配置" }
        if metrics.isError { return "异常" }
        return "--"
    }

    private func fixedProviderPickerRow(custom: MenuBarCustomConfig) -> some View {
        let selected = custom.fixedQuotaProvider
        let currentPreview = liveProviderQuotaPreview(for: selected, custom: custom)

        return HStack(spacing: 8) {
            Text("指定单个服务")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
            Spacer()

            Button {
                isFixedProviderPopoverPresented.toggle()
            } label: {
                HStack(spacing: 6) {
                    ProviderBrandIconView(provider: selected, size: 14)
                    Text(selected.displayName)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(currentPreview)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .frame(minWidth: 204)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.16), lineWidth: 0.7)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .orbitInteractiveButton(pressedScale: 0.98, hoverTint: nil, cornerRadius: 6)
            .popover(isPresented: $isFixedProviderPopoverPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(ProviderID.allCases) { prov in
                        let isCurrent = (prov == selected)
                        let previewText = liveProviderQuotaPreview(for: prov, custom: custom)
                        Button {
                            withAnimation(OrbitMotion.snappy) {
                                store.updateMenuBarCustom { $0.fixedQuotaProvider = prov }
                            }
                            isFixedProviderPopoverPresented = false
                        } label: {
                            HStack(spacing: 8) {
                                ProviderBrandIconView(provider: prov, size: 15)
                                Text(prov.displayName)
                                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                                    .foregroundColor(.primary)
                                Spacer(minLength: 8)
                                Text(previewText)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.accentColor)
                                    .opacity(isCurrent ? 1.0 : 0.0)
                                    .frame(width: 12)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(isCurrent ? Color.accentColor.opacity(0.10) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .orbitInteractiveButton(
                            pressedScale: 0.98,
                            hoverTint: Color.primary.opacity(0.06),
                            cornerRadius: 6
                        )
                    }
                }
                .padding(8)
                .frame(width: 224)
            }
        }
        .padding(.top, 2)
    }

    private func multiProviderSelectorCard(custom: MenuBarCustomConfig) -> some View {
        let selectedProviders = MenuBarCustomConfig.deduplicatedProviders(custom.quotaMultiProviders)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("多服务并排展示（勾选并调整显示顺序）")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("已选 \(selectedProviders.count) / \(ProviderID.allCases.count)")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(selectedProviders.isEmpty ? Color(nsColor: .systemOrange) : .secondary)
            }

            if selectedProviders.isEmpty {
                Text("未勾选任何服务时，状态栏将自动回退显示当前选中服务。")
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: .systemOrange))
            }

            VStack(spacing: 3) {
                ForEach(orderedMultiQuotaProviders) { provider in
                    multiProviderRow(
                        provider: provider,
                        selectedProviders: selectedProviders,
                        custom: custom
                    )
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.03))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.075), lineWidth: 0.7)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.top, 2)
    }

    private func multiProviderRow(
        provider: ProviderID,
        selectedProviders: [ProviderID],
        custom: MenuBarCustomConfig
    ) -> some View {
        let selectedIndex = selectedProviders.firstIndex(of: provider)
        let isSelected = (selectedIndex != nil)
        let preview = liveProviderQuotaPreview(for: provider, custom: custom)

        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in
                    withAnimation(OrbitMotion.snappy) {
                        store.updateMenuBarCustom { $0.toggleMultiProvider(provider) }
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            ProviderBrandIconView(
                provider: provider,
                size: 15,
                renderingAccent: isSelected ? nil : .secondary
            )
            .opacity(isSelected ? 1.0 : 0.5)

            Text(provider.displayName)
                .font(.system(size: 11.5, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? .primary : .secondary)
                .lineLimit(1)

            if custom.showProviderPrefix {
                Text(provider.shortName)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.055))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .fixedSize()
            }

            Spacer(minLength: 4)

            Text(preview)
                .font(.system(size: 10.5, weight: isSelected ? .medium : .regular, design: .monospaced))
                .foregroundColor(isSelected ? .primary.opacity(0.85) : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.05))
                .clipShape(Capsule())
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .orbitNumericTransition()

            HStack(spacing: 2) {
                Button {
                    withAnimation(OrbitMotion.snappy) {
                        store.updateMenuBarCustom { $0.moveMultiProvider(provider, direction: .up) }
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9.5, weight: .semibold))
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(selectedIndex == nil || selectedIndex == 0)
                .help("上移")

                Button {
                    withAnimation(OrbitMotion.snappy) {
                        store.updateMenuBarCustom { $0.moveMultiProvider(provider, direction: .down) }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .semibold))
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(selectedIndex == nil || selectedIndex == selectedProviders.count - 1)
                .help("下移")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(isSelected ? Color.primary.opacity(0.03) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .orbitHoverHighlight(cornerRadius: 6)
    }

    private func customModuleRow(module: MenuBarModule, enabledModules: [MenuBarModule]) -> some View {
        let enabledIndex = enabledModules.firstIndex(of: module)
        let isEnabled = (enabledIndex != nil)
        let sample = store.menuBarModulePreviewText(for: module)

        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { _ in
                    withAnimation(OrbitMotion.snappy) {
                        store.updateMenuBarCustom { $0.toggleModule(module) }
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            Group {
                if module == .deepseekBalance {
                    ProviderBrandIconView(
                        provider: .deepseek,
                        size: 14,
                        renderingAccent: isEnabled ? nil : .secondary
                    )
                    .opacity(isEnabled ? 1.0 : 0.5)
                } else {
                    Image(systemName: module.symbolName)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(isEnabled ? .accentColor : .secondary)
                }
            }
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(module.title)
                    .font(.system(size: 11.5, weight: isEnabled ? .medium : .regular))
                    .foregroundColor(isEnabled ? .primary : .secondary)
                    .lineLimit(1)
                Text(module.subtitle)
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)
            .help(module.subtitle)

            Spacer(minLength: 6)

            Text(sample)
                .font(.system(size: 10.5, weight: isEnabled ? .medium : .regular, design: .monospaced))
                .foregroundColor(isEnabled ? .primary.opacity(0.85) : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isEnabled ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.05))
                .clipShape(Capsule())
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 148, alignment: .trailing)
                .orbitNumericTransition()
                .help("实时值：\(sample)")

            HStack(spacing: 2) {
                Button {
                    withAnimation(OrbitMotion.snappy) {
                        store.updateMenuBarCustom { $0.moveModule(module, direction: .up) }
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9.5, weight: .semibold))
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(enabledIndex == nil || enabledIndex == 0)
                .help("上移")

                Button {
                    withAnimation(OrbitMotion.snappy) {
                        store.updateMenuBarCustom { $0.moveModule(module, direction: .down) }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .semibold))
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(enabledIndex == nil || enabledIndex == enabledModules.count - 1)
                .help("下移")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(isEnabled ? Color.primary.opacity(0.03) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .orbitHoverHighlight(cornerRadius: 6)
    }

    // MARK: - Window Size & Card Customization Section

    private var windowSizeAndCardsCard: some View {
        settingsCard(title: "窗口尺寸与卡片", icon: "macwindow.on.rectangle") {
            VStack(alignment: .leading, spacing: 12) {
                windowSizesSubCard
                accountCardCustomizationSubCard
                tokenCardsCustomizationSubCard
                tokenClientOrderSubCard
            }
        }
    }

    private var isDefaultWindowSizes: Bool {
        let s = store.registry.settings
        return abs(s.popoverWidth - AppSettings.defaultPopoverWidth) < 0.5
            && abs(s.popoverHeight - AppSettings.defaultPopoverHeight) < 0.5
    }

    private var windowSizesSubCard: some View {
        let s = store.registry.settings
        let popW = Int(s.popoverWidth.rounded())
        let popH = Int(s.popoverHeight.rounded())

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("主弹窗尺寸")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Text("\(popW) × \(popH) pt")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .orbitNumericTransition()
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.11))
                    .clipShape(Capsule())
                Button("恢复默认尺寸") {
                    withAnimation(OrbitMotion.snappy) {
                        store.resetWindowSizes()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(isDefaultWindowSizes)
            }

            HStack(spacing: 8) {
                Text("宽度")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 28, alignment: .leading)
                Slider(
                    value: Binding(
                        get: {
                            AppSettings.clamp(
                                store.registry.settings.popoverWidth,
                                to: AppSettings.popoverWidthRange,
                                fallback: AppSettings.defaultPopoverWidth
                            )
                        },
                        set: { newWidth in
                            let snapped = (newWidth / 10.0).rounded() * 10.0
                            store.updatePopoverSize(
                                width: snapped,
                                height: store.registry.settings.popoverHeight,
                                persistImmediately: false
                            )
                        }
                    ),
                    in: AppSettings.popoverWidthRange,
                    step: 10,
                    onEditingChanged: { editing in
                        if !editing {
                            store.updatePopoverSize(
                                width: store.registry.settings.popoverWidth,
                                height: store.registry.settings.popoverHeight,
                                persistImmediately: true
                            )
                        }
                    }
                )
                .help("主弹窗宽度：340–680 pt（步进 10 pt）")
                Text("\(popW) pt")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Text("高度")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 28, alignment: .leading)
                Slider(
                    value: Binding(
                        get: {
                            AppSettings.clamp(
                                store.registry.settings.popoverHeight,
                                to: AppSettings.popoverHeightRange,
                                fallback: AppSettings.defaultPopoverHeight
                            )
                        },
                        set: { newHeight in
                            let snapped = (newHeight / 10.0).rounded() * 10.0
                            store.updatePopoverSize(
                                width: store.registry.settings.popoverWidth,
                                height: snapped,
                                persistImmediately: false
                            )
                        }
                    ),
                    in: AppSettings.popoverHeightRange,
                    step: 10,
                    onEditingChanged: { editing in
                        if !editing {
                            store.updatePopoverSize(
                                width: store.registry.settings.popoverWidth,
                                height: store.registry.settings.popoverHeight,
                                persistImmediately: true
                            )
                        }
                    }
                )
                .help("主弹窗高度：460–920 pt（步进 10 pt）")
                Text("\(popH) pt")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            HStack(spacing: 6) {
                Text("快捷预设")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .fixedSize()
                Spacer(minLength: 4)
                ForEach(Self.popoverSizePresets) { preset in
                    let isActive = abs(s.popoverWidth - preset.width) < 1.0
                        && abs(s.popoverHeight - preset.height) < 1.0
                    sizePresetButton(
                        title: "\(preset.label) \(preset.sizeText)",
                        isActive: isActive
                    ) {
                        withAnimation(OrbitMotion.snappy) {
                            store.updatePopoverSize(
                                width: preset.width,
                                height: preset.height,
                                persistImmediately: true
                            )
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "hand.point.up.left")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.top, 1.5)
                Text("也可直接拖拽主弹窗左/右/下边缘或底角自由缩放，拉宽至 430pt 以上时 KPI 自动展开为 2×2 网格")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.025))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.065), lineWidth: 0.7)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func sizePresetButton(
        title: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: isActive ? .semibold : .medium))
                .monospacedDigit()
                .foregroundColor(isActive ? .accentColor : .primary.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(isActive ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            isActive ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.10),
                            lineWidth: 0.7
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .orbitInteractiveButton(pressedScale: 0.96, hoverTint: nil, cornerRadius: 6)
        .fixedSize()
    }

    private var accountCardCustomizationSubCard: some View {
        let cfg = store.registry.settings.accountCardConfig
        let gridColumns = [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8),
        ]

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.topthird.inset.filled")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("顶部服务胶囊与额度卡片")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Button("恢复默认") {
                    withAnimation(OrbitMotion.snappy) {
                        store.resetAccountCardConfig()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(cfg == .default)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("顶部服务胶囊额度口径")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Picker("", selection: Binding(
                    get: { store.registry.settings.accountCardConfig.pillQuotaWindow },
                    set: { nextWindow in
                        withAnimation(OrbitMotion.snappy) {
                            store.updateAccountCardConfig { $0.pillQuotaWindow = nextWindow }
                        }
                    }
                )) {
                    ForEach(MenuBarQuotaWindow.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Text(cfg.pillQuotaWindow.descriptionText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: gridColumns, spacing: 6) {
                compactSwitchTile(
                    title: "显示账号头像",
                    isOn: Binding(
                        get: { store.registry.settings.accountCardConfig.showAvatar },
                        set: { val in store.updateAccountCardConfig { $0.showAvatar = val } }
                    )
                )
                compactSwitchTile(
                    title: "显示 5 小时额度",
                    isOn: Binding(
                        get: { store.registry.settings.accountCardConfig.showFiveHour },
                        set: { val in store.updateAccountCardConfig { $0.showFiveHour = val } }
                    )
                )
                compactSwitchTile(
                    title: "显示周额度",
                    isOn: Binding(
                        get: { store.registry.settings.accountCardConfig.showWeekly },
                        set: { val in store.updateAccountCardConfig { $0.showWeekly = val } }
                    )
                )
                compactSwitchTile(
                    title: "显示重置倒计时",
                    isOn: Binding(
                        get: { store.registry.settings.accountCardConfig.showResetFootnote },
                        set: { val in store.updateAccountCardConfig { $0.showResetFootnote = val } }
                    )
                )
                compactSwitchTile(
                    title: "显示来源角标",
                    isOn: Binding(
                        get: { store.registry.settings.accountCardConfig.showSourceBadge },
                        set: { val in store.updateAccountCardConfig { $0.showSourceBadge = val } }
                    )
                )
                compactSwitchTile(
                    title: "卡片紧凑密度",
                    isOn: Binding(
                        get: { store.registry.settings.accountCardConfig.compactDensity },
                        set: { val in store.updateAccountCardConfig { $0.compactDensity = val } }
                    )
                )
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2.5) {
                        HStack(spacing: 5) {
                            ProviderBrandIconView(provider: .antigravity, size: 13)
                            Text("AGY 卡片仅显示所选追踪池")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("关闭时显示全部模型池；开启后 Antigravity 账号卡片仅显示当前追踪池（\(store.registry.settings.menuBarCustom.antigravityPool.displayName)）对应配额")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 8)

                    Toggle("", isOn: Binding(
                        get: { store.registry.settings.accountCardConfig.filterAntigravityCardPools },
                        set: { val in
                            withAnimation(OrbitMotion.snappy) {
                                store.updateAccountCardConfig { $0.filterAntigravityCardPools = val }
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .padding(.top, 1)
                }

                if cfg.filterAntigravityCardPools {
                    Divider().opacity(0.3)
                    antigravityPoolSelectorRow
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.6)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(10)
        .background(Color.primary.opacity(0.025))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.065), lineWidth: 0.7)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func compactSwitchTile(title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
            Spacer(minLength: 4)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var tokenCardsCustomizationSubCard: some View {
        let dashCfg = store.registry.settings.tokenDashboardCards
        let ordered = DashboardTokenCardConfig.normalizedOrder(dashCfg.orderedCards)

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("Token 用量卡片（5 卡）")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Text("已启用 \(dashCfg.visibleCards.count) / \(DashboardTokenCard.allCases.count)")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.secondary)

                Button("恢复默认") {
                    withAnimation(OrbitMotion.snappy) {
                        store.resetDashboardTokenCards()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(dashCfg == .default)
            }

            VStack(spacing: 3) {
                ForEach(ordered) { card in
                    tokenCardOrderRow(
                        title: card.title,
                        subtitle: card.subtitle,
                        symbolName: card.symbolName,
                        isEnabled: dashCfg.isEnabled(card),
                        canMoveUp: dashCfg.canMoveCard(card, direction: .up),
                        canMoveDown: dashCfg.canMoveCard(card, direction: .down),
                        onToggle: {
                            withAnimation(OrbitMotion.snappy) {
                                store.updateDashboardTokenCards { $0.toggleCard(card) }
                            }
                        },
                        onMoveUp: {
                            withAnimation(OrbitMotion.snappy) {
                                store.updateDashboardTokenCards { $0.moveCard(card, direction: .up) }
                            }
                        },
                        onMoveDown: {
                            withAnimation(OrbitMotion.snappy) {
                                store.updateDashboardTokenCards { $0.moveCard(card, direction: .down) }
                            }
                        }
                    )
                }
            }
            .padding(6)
            .background(Color.primary.opacity(0.03))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 0.7)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            settingsSwitchRow(
                title: "Token 用量卡片使用紧凑密度",
                fontSize: 11.5,
                controlSize: .mini,
                isOn: Binding(
                    get: { store.registry.settings.tokenDashboardCards.compactDensity },
                    set: { compact in
                        store.updateDashboardTokenCards { $0.compactDensity = compact }
                    }
                )
            )
        }
        .padding(10)
        .background(Color.primary.opacity(0.025))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.065), lineWidth: 0.7)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Token Client Filter Bar Ordering

    private var snapshotClientBreakdownsByID: [TokenClientID: TokenClientBreakdown] {
        guard let snapshot = store.tokenUsage else { return [:] }
        var map: [TokenClientID: TokenClientBreakdown] = [:]
        for item in snapshot.summary(for: .allTime).byClient {
            map[item.client] = item
        }
        return map
    }

    private var availableTokenClientsForOrdering: [TokenClientID] {
        if let snapshot = store.tokenUsage {
            let fromAllTime = snapshot.summary(for: .allTime).byClient.map(\.client)
            if !fromAllTime.isEmpty {
                return fromAllTime
            }
            var seen = Set<TokenClientID>()
            var discovered: [TokenClientID] = []
            for day in snapshot.allDays {
                for item in day.byClient where item.totals.totalTokens > 0 {
                    if seen.insert(item.client).inserted {
                        discovered.append(item.client)
                    }
                }
            }
            if !discovered.isEmpty {
                return discovered
            }
        }
        return TokenClientID.allCases.filter { $0 != .other }
    }

    private func tokenClientColor(for client: TokenClientID) -> Color {
        let cleaned = client.hexColor.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else {
            return .accentColor
        }
        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    private var tokenClientOrderSubCard: some View {
        let available = availableTokenClientsForOrdering
        let ordered = store.orderedTokenClients(from: available)
        let breakdowns = snapshotClientBreakdownsByID
        let hasCustomOrder = store.hasCustomTokenClientOrder

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("客户端筛选栏顺序")
                    .font(.system(size: 11.5, weight: .semibold))
                if hasCustomOrder {
                    Text("已自定义")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.13))
                        .clipShape(Capsule())
                }
                Spacer(minLength: 4)
                Button("恢复默认（按用量排序）") {
                    withAnimation(OrbitMotion.snappy) {
                        store.resetTokenClientOrder()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(!hasCustomOrder)
            }

            VStack(spacing: 3) {
                ForEach(ordered) { client in
                    let idx = ordered.firstIndex(of: client) ?? 0
                    tokenClientOrderRow(
                        client: client,
                        index: idx,
                        totalCount: ordered.count,
                        breakdown: breakdowns[client],
                        available: available
                    )
                }
            }
            .padding(6)
            .background(Color.primary.opacity(0.03))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 0.7)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.top, 1.5)
                Text("在主弹窗客户端栏支持鼠标滚轮左右滑动及直接拖拽调整前后顺序")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.025))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.065), lineWidth: 0.7)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func tokenClientOrderRow(
        client: TokenClientID,
        index: Int,
        totalCount: Int,
        breakdown: TokenClientBreakdown?,
        available: [TokenClientID]
    ) -> some View {
        let canUp = store.canMoveTokenClient(client, direction: .up, available: available)
        let canDown = store.canMoveTokenClient(client, direction: .down, available: available)
        let dotColor = tokenClientColor(for: client)

        return HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 16, alignment: .trailing)

            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                )

            Text(client.displayName)
                .font(.system(size: 11.5, weight: index == 0 ? .semibold : .medium))
                .foregroundColor(.primary)
                .lineLimit(1)

            if let breakdown, breakdown.totals.totalTokens > 0 {
                Text(TokenFormatters.compactTokens(breakdown.totals.totalTokens))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.055))
                    .clipShape(Capsule())
                    .fixedSize()
            }

            Spacer(minLength: 6)

            Button {
                withAnimation(OrbitMotion.snappy) {
                    store.pinTokenClientToFront(client, available: available)
                }
            } label: {
                HStack(spacing: 2.5) {
                    Image(systemName: "arrow.up.to.line")
                        .font(.system(size: 8.5, weight: .semibold))
                    Text("置顶")
                        .font(.system(size: 10, weight: .medium))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(index == 0)
            .help("移到筛选栏最前")

            HStack(spacing: 2) {
                Button {
                    withAnimation(OrbitMotion.snappy) {
                        store.moveTokenClient(client, direction: .up, available: available)
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9.5, weight: .semibold))
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(!canUp)
                .help("上移")

                Button {
                    withAnimation(OrbitMotion.snappy) {
                        store.moveTokenClient(client, direction: .down, available: available)
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .semibold))
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(!canDown)
                .help("下移")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.028))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .orbitHoverHighlight(cornerRadius: 6)
        .contextMenu {
            Button("移至最前（置顶）") {
                withAnimation(OrbitMotion.snappy) {
                    store.pinTokenClientToFront(client, available: available)
                }
            }
            .disabled(index == 0)

            Button("上移一位") {
                withAnimation(OrbitMotion.snappy) {
                    store.moveTokenClient(client, direction: .up, available: available)
                }
            }
            .disabled(!canUp)

            Button("下移一位") {
                withAnimation(OrbitMotion.snappy) {
                    store.moveTokenClient(client, direction: .down, available: available)
                }
            }
            .disabled(!canDown)

            Button("移至末尾") {
                withAnimation(OrbitMotion.snappy) {
                    store.pinTokenClientToEnd(client, available: available)
                }
            }
            .disabled(index >= totalCount - 1)

            Divider()

            Button("恢复默认（按用量排序）") {
                withAnimation(OrbitMotion.snappy) {
                    store.resetTokenClientOrder()
                }
            }
            .disabled(!store.hasCustomTokenClientOrder)
        }
    }

    private func tokenCardOrderRow(
        title: String,
        subtitle: String,
        symbolName: String,
        isEnabled: Bool,
        canMoveUp: Bool,
        canMoveDown: Bool,
        onToggle: @escaping () -> Void,
        onMoveUp: @escaping () -> Void,
        onMoveDown: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            Image(systemName: symbolName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(isEnabled ? .accentColor : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: isEnabled ? .medium : .regular))
                    .foregroundColor(isEnabled ? .primary : .secondary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(subtitle)

            Spacer(minLength: 6)

            HStack(spacing: 2) {
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9.5, weight: .semibold))
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveUp)
                .help("上移")

                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .semibold))
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveDown)
                .help("下移")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(isEnabled ? Color.primary.opacity(0.03) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .orbitHoverHighlight(cornerRadius: 6)
    }

    private var clampedWarnThreshold: Double {
        min(max(store.registry.settings.lowQuotaWarnThreshold, 0.10), 0.40)
    }

    // MARK: - Providers & API Keys Tab

    private var providersTab: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                settingsCard(title: "已启用服务", icon: "checkmark.seal") {
                    VStack(spacing: 8) {
                        ForEach(ProviderID.allCases) { provider in
                            providerToggleRow(for: provider)
                            if provider != ProviderID.allCases.last {
                                Divider().opacity(0.35)
                            }
                        }
                    }
                }

                antigravityBehaviorCard

                settingsCard(title: "API Key 安全配置（系统钥匙串）", icon: "key.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        apiKeyConfigRow(
                            provider: .kimi,
                            placeholder: "输入 Kimi Coding API Key（不回显明文）",
                            draft: $kimiAPIKeyDraft
                        )

                        Divider().opacity(0.35)

                        apiKeyConfigRow(
                            provider: .deepseek,
                            placeholder: "输入 DeepSeek API Key（不回显明文）",
                            draft: $deepSeekAPIKeyDraft
                        )

                        if let feedback = apiKeyFeedback {
                            Text(feedback)
                                .font(.system(size: 11))
                                .foregroundColor(Color(nsColor: .systemGreen))
                        }

                        Text("所有 API Key 仅通过 macOS 钥匙串隔离命名空间 com.rory.roryorbit.keys 加密存储，界面与日志绝不输出明文。")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Passive local-only Claude CLI safety notice (zero network, zero Keychain, zero Desktop access).
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 13))
                        .foregroundColor(Color(nsColor: .systemGreen))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude CLI 多账号纯本地被动模式（零联网 · 不碰桌面端）")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("仅离线读取 ~/.config/pulsar/claude-cli-profiles.json、独立配置目录 .claude.json 与 ~/.cache/pulsar/claude-cli-quotas/ 中的非敏感余量，切号仅更新本地默认配置指针，绝不请求远端接口、读取系统钥匙串/Cookie 或触碰 Claude 桌面端。")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .systemGreen).opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color(nsColor: .systemGreen).opacity(0.24), lineWidth: 0.7)
                )
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .padding(.vertical, 6)
            .padding(.leading, 2)
            .padding(.trailing, 8)
        }
    }

    private var antigravityBehaviorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ProviderBrandIconView(provider: .antigravity, size: 15)
                Text("Antigravity 切号与重启行为")
                    .font(.system(size: 12.5, weight: .bold))
            }

            settingsSwitchRow(
                title: "切换 / 重启时同时打开 Antigravity 预览版（Insiders）",
                subtitle: "默认关闭：切换账号或重启后仅启动正式版 Antigravity，避免同时弹出两个窗口",
                isOn: Binding(
                    get: { store.registry.settings.relaunchAntigravityInsiders },
                    set: { enabled in
                        store.setRelaunchAntigravityInsiders(enabled)
                    }
                )
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitCardStyle(cornerRadius: 11, hoverLift: false)
    }

    private func providerToggleRow(for provider: ProviderID) -> some View {
        let isEnabled = store.registry.settings.enabledProviders.contains(provider)
        let isOnlyEnabled = isEnabled && store.registry.settings.enabledProviders.count <= 1

        return HStack(spacing: 10) {
            ProviderBrandIconView(
                provider: provider,
                size: 18,
                renderingAccent: isEnabled ? nil : .secondary
            )
            .opacity(isEnabled ? 1.0 : 0.45)
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(isEnabled ? .primary : .secondary)
                        .fixedSize()
                    Text(capabilitySummary(for: provider))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Capsule())
                }
            }

            Spacer(minLength: 6)

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { nextOn in
                    store.updateSettings { settings in
                        var set = Set(settings.enabledProviders)
                        if nextOn {
                            set.insert(provider)
                        } else if set.count > 1 {
                            set.remove(provider)
                        }
                        settings.enabledProviders = ProviderID.allCases.filter { set.contains($0) }
                    }
                    if nextOn {
                        Task { await store.refreshProvider(provider) }
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(isOnlyEnabled)
        }
    }

    private func capabilitySummary(for provider: ProviderID) -> String {
        switch provider {
        case .antigravity: return "多账号切换 · 本地 RPC + Cloud Code"
        case .codex: return "多账号切换 · 5小时 / 本周配额"
        case .claude: return "多账号本地被动 · 零联网 · 5h / 周余量"
        case .grok: return "CLI 账单配额监控"
        case .cursor: return "本地会话配额监控"
        case .kimi: return "API 用量监控"
        case .deepseek: return "API 余额监控"
        }
    }

    private func apiKeyConfigRow(
        provider: ProviderID,
        placeholder: String,
        draft: Binding<String>
    ) -> some View {
        let configured = store.apiKeyConfiguredMap[provider] ?? false
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 6) {
                    ProviderBrandIconView(provider: provider, size: 15)
                    Text(provider.displayName)
                        .font(.system(size: 12, weight: .semibold))
                }
                Spacer()
                Text(configured ? "已配置" : "未配置")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(configured ? Color(nsColor: .systemGreen) : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background((configured ? Color(nsColor: .systemGreen) : Color.secondary).opacity(0.14))
                    .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                SecureField(placeholder, text: draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))

                Button("保存") {
                    let keyValue = draft.wrappedValue
                    draft.wrappedValue = ""
                    Task {
                        await store.saveAPIKey(provider: provider, key: keyValue)
                        apiKeyFeedback = "已更新 \(provider.displayName) 密钥状态"
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Migration & Data Tab

    private var migrationAndDataTab: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                localTokenStatsCard

                settingsCard(title: "历史账号与密钥迁移", icon: "arrow.down.doc") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("迁移状态")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            let completed = store.registry.settings.legacyMigrationCompleted
                            Text(completed ? "已完成初始迁移" : "尚未迁移")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(completed ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background((completed ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange)).opacity(0.14))
                                .clipShape(Capsule())
                        }

                        Text("支持从原 OrbitSwitch 卸载备份（Antigravity / Codex）与 CodexBar（只读导入托管 Codex 账号及 Kimi / DeepSeek API Key）幂等迁移至 Pulsar 独立钥匙串（com.rory.roryorbit.*）。仅在 100% SHA-256 校验通过后才会清理旧 OrbitSwitch 钥匙串项，且绝不修改 CodexBar 原始文件。")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Button {
                                Task { await store.runLegacyMigration() }
                            } label: {
                                Label("重新执行一键迁移", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(store.busyActionLabel != nil)

                            if store.busyActionLabel != nil {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.75)
                            }
                        }

                        if let report = store.migrationReport {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("最近一次迁移摘要")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(report.summaryText)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.045))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                    }
                }

                settingsCard(title: "本地数据存储", icon: "folder") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("配置与元数据目录")
                                    .font(.system(size: 12, weight: .medium))
                                Text(RegistryData.defaultDirectoryURL.path)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button("打开数据目录") {
                                store.openDataDirectory()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Divider().opacity(0.35)

                        HStack {
                            Text("已注册账号总数")
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(store.registry.accounts.count) 个")
                                .font(.system(size: 11.5, weight: .semibold))
                                .monospacedDigit()
                        }
                    }
                }

                aboutPulsarCard
            }
            .padding(.vertical, 6)
            .padding(.leading, 2)
            .padding(.trailing, 8)
        }
    }

    private var aboutPulsarCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                PulsarBrandIconView(size: 36, showGlowShadow: true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Pulsar v\(AppStore.appVersion)")
                            .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        Spacer(minLength: 6)
                        Text("兼容标识: RoryOrbit")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Text("纯本地只读统计 · 零 Claude 联网 · 绝不读取 Claude 凭据或拉起 CLI 探测。")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(Color(nsColor: .systemGreen))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider().opacity(0.35)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(aboutUpdateStatusHeadline)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(aboutUpdateStatusColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("仅访问 GitHub Releases（HTTPS 白名单），下载前强制校验 SHA-256")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if case .available = store.updatePhase {
                    Button("一键下载并更新") {
                        store.startUpdateDownloadAndInstall()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .fixedSize()
                } else {
                    Button {
                        Task { await store.checkForUpdates(userInitiated: true) }
                    } label: {
                        Label(
                            store.updatePhase == .checking ? "检查中…" : "检查更新",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.updatePhase.isBusy)
                    .fixedSize()
                }

                Button("Release 页面") {
                    store.openUpdateReleasePage()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }

            Divider().opacity(0.35)

            Text("底层数据目录（RoryOrbit）、钥匙串命名空间（com.rory.roryorbit.*）及后台服务均保持兼容沿用，原有授权与号池采集链路不受影响。")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitCardStyle(cornerRadius: 11, hoverLift: false)
    }

    private var aboutUpdateStatusHeadline: String {
        switch store.updatePhase {
        case .idle, .upToDate:
            if let checkedAt = effectiveLastUpdateCheckAt {
                return "当前已是最新版本 · 上次检查 \(store.relativeTimeAgoString(since: checkedAt))"
            }
            return "当前已是最新版本"
        case .checking:
            return "正在检查 GitHub Releases…"
        case .available(let info):
            return "发现新版本 \(formattedVersionTag(info.version))"
        case .downloading(let info, let progress):
            let pct = Int((min(max(progress.isFinite ? progress : 0.0, 0.0), 1.0) * 100.0).rounded())
            return "正在下载 \(formattedVersionTag(info.version))（\(pct)%）"
        case .verifying(let info):
            return "正在校验 \(formattedVersionTag(info.version)) SHA-256…"
        case .installing(let info), .readyToRelaunch(let info):
            return "正在安全替换并重启至 \(formattedVersionTag(info.version))…"
        case .manualInstallOpened(let info, _):
            return "已校验并打开 \(formattedVersionTag(info.version)) 安装包"
        case .failed:
            return "检查或安装更新失败，可在「通用」页查看详情"
        }
    }

    private var aboutUpdateStatusColor: Color {
        switch store.updatePhase {
        case .available:
            return .accentColor
        case .failed:
            return Color(nsColor: .systemRed)
        case .idle, .upToDate, .checking, .downloading, .verifying, .installing, .readyToRelaunch, .manualInstallOpened:
            return .primary
        }
    }

    private var localTokenStatsCard: some View {
        let archivePath = store.tokenUsage?.archiveFileURLPath ?? TokenUsageEngine.defaultArchiveURL.path
        let seedExistsOnDisk = FileManager.default.fileExists(atPath: TokenUsageEngine.defaultSeedURL.path)
        let seedStatusText: String = {
            if let snap = store.tokenUsage {
                if snap.seedDaysCount > 0 {
                    return "已导入 \(snap.seedDaysCount) 天历史基线（共 \(snap.totalDaysCount) 天）"
                }
                return "当前共 \(snap.totalDaysCount) 天本地记录"
            }
            return seedExistsOnDisk ? "历史基线已落盘（待本次扫描载入）" : "首次扫描自动导入 112 天历史基线"
        }()

        return settingsCard(title: "本地 Token 统计", icon: "chart.bar.xaxis") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("日归档输出路径")
                            .font(.system(size: 12, weight: .medium))
                        Text(archivePath)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(archivePath)
                    }
                    Spacer(minLength: 8)
                    Button("显示文件") {
                        store.revealTokenArchiveInFinder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Divider().opacity(0.35)

                HStack {
                    Text("历史基线状态")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(seedStatusText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(nsColor: .systemGreen))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: .systemGreen).opacity(0.14))
                        .clipShape(Capsule())
                }

                if let snap = store.tokenUsage {
                    HStack {
                        Text("本地增量扫描")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("已扫描 \(snap.liveScannedFilesCount) 文件 · \(store.relativeTimeAgoString(since: snap.lastScannedAt))更新")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await store.refreshTokenUsage(forceFullRescan: true) }
                    } label: {
                        Label(store.isScanningTokenUsage ? "正在全量扫描..." : "立即全量扫描", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(store.isScanningTokenUsage)

                    if store.isScanningTokenUsage {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.75)
                    }
                }

                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(nsColor: .systemGreen))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("纯本地只读 · 零 Claude 联网")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(nsColor: .systemGreen))
                        Text("仅只读本机已落盘会话日志，绝不联网请求 Claude、绝不拉起 CLI 探测、绝不读取 Claude 凭据。")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .systemGreen).opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .systemGreen).opacity(0.24), lineWidth: 0.7)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    // MARK: - Section Card & Switch Row Helpers

    private func settingsSwitchRow(
        title: String,
        subtitle: String? = nil,
        fontSize: CGFloat = 12,
        controlSize: ControlSize = .small,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2.5) {
                Text(title)
                    .font(.system(size: fontSize, weight: subtitle == nil ? .regular : .medium))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 10)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(controlSize)
                .padding(.top, subtitle == nil ? 0 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.system(size: 12.5, weight: .bold))
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitCardStyle(cornerRadius: 11, hoverLift: false)
    }
}
