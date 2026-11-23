import AppKit
import SwiftUI

// MARK: - Native macOS Vibrancy Background

public struct VisualEffectBackground: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode

    public init(
        material: NSVisualEffectView.Material = .popover,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

// MARK: - Shared UI Color & Style Helpers

enum OrbitTheme {
    static func quotaColor(remainingFraction: Double, warnThreshold: Double) -> Color {
        if remainingFraction <= warnThreshold {
            return Color(nsColor: .systemRed)
        }
        if remainingFraction < 0.50 {
            return Color(nsColor: .systemOrange)
        }
        return Color(nsColor: .systemGreen)
    }

    static func quotaColor(remainingPercent: Int, warnThreshold: Double) -> Color {
        quotaColor(remainingFraction: Double(remainingPercent) / 100.0, warnThreshold: warnThreshold)
    }

    static func planTint(_ kind: PlanKind) -> Color {
        switch kind {
        case .ultra, .max, .enterprise:
            return Color(nsColor: .systemPurple)
        case .pro, .plus, .team, .business:
            return Color(nsColor: .systemBlue)
        case .prolite:
            return Color(nsColor: .systemTeal)
        case .api:
            return Color(nsColor: .systemIndigo)
        case .free, .unknown:
            return Color.secondary
        }
    }

    static func avatarColor(seed: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.23, green: 0.51, blue: 0.96),
            Color(red: 0.08, green: 0.65, blue: 0.56),
            Color(red: 0.55, green: 0.36, blue: 0.93),
            Color(red: 0.90, green: 0.45, blue: 0.18),
            Color(red: 0.85, green: 0.27, blue: 0.47),
            Color(red: 0.16, green: 0.58, blue: 0.78),
        ]
        let hash = seed.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }
}

// MARK: - Popover Interactive Resize Primitives

private enum PopoverResizeEdge: Equatable {
    case left
    case right
    case bottom
    case bottomLeft
    case bottomRight

    var adjustsWidth: Bool {
        switch self {
        case .left, .right, .bottomLeft, .bottomRight: return true
        case .bottom: return false
        }
    }

    var adjustsHeight: Bool {
        switch self {
        case .bottom, .bottomLeft, .bottomRight: return true
        case .left, .right: return false
        }
    }

    var widthSign: CGFloat {
        switch self {
        case .left, .bottomLeft: return -1
        case .right, .bottomRight: return 1
        case .bottom: return 0
        }
    }

    @MainActor
    var cursor: NSCursor {
        switch self {
        case .left, .right:
            return .resizeLeftRight
        case .bottom:
            return .resizeUpDown
        case .bottomLeft:
            return PopoverResizeCursors.diagonalNESW
        case .bottomRight:
            return PopoverResizeCursors.diagonalNWSE
        }
    }
}

@MainActor
private enum PopoverResizeCursors {
    /// Diagonal resize cursor (top-left <-> bottom-right) for the bottom-right handle.
    static let diagonalNWSE: NSCursor = makeDiagonalCursor(topLeftToBottomRight: true)

    /// Diagonal resize cursor (bottom-left <-> top-right) for the bottom-left handle.
    static let diagonalNESW: NSCursor = makeDiagonalCursor(topLeftToBottomRight: false)

    private static func makeDiagonalCursor(topLeftToBottomRight: Bool) -> NSCursor {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let p1 = topLeftToBottomRight ? NSPoint(x: 4.5, y: 13.5) : NSPoint(x: 4.5, y: 4.5)
            let p2 = topLeftToBottomRight ? NSPoint(x: 13.5, y: 4.5) : NSPoint(x: 13.5, y: 13.5)

            func makeArrowPath() -> NSBezierPath {
                let path = NSBezierPath()
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: p1)
                path.line(to: p2)

                let dx = p2.x - p1.x
                let dy = p2.y - p1.y
                let length = hypot(dx, dy)
                guard length > 0 else { return path }
                let ux = dx / length
                let uy = dy / length
                let px = -uy
                let py = ux
                let headLen: CGFloat = 3.6
                let headHalf: CGFloat = 2.6

                // Head at p1
                let b1 = NSPoint(x: p1.x + ux * headLen, y: p1.y + uy * headLen)
                path.move(to: NSPoint(x: b1.x + px * headHalf, y: b1.y + py * headHalf))
                path.line(to: p1)
                path.line(to: NSPoint(x: b1.x - px * headHalf, y: b1.y - py * headHalf))

                // Head at p2
                let b2 = NSPoint(x: p2.x - ux * headLen, y: p2.y - uy * headLen)
                path.move(to: NSPoint(x: b2.x + px * headHalf, y: b2.y + py * headHalf))
                path.line(to: p2)
                path.line(to: NSPoint(x: b2.x - px * headHalf, y: b2.y - py * headHalf))

                return path
            }

            let halo = makeArrowPath()
            NSColor.white.withAlphaComponent(0.92).setStroke()
            halo.lineWidth = 3.2
            halo.stroke()

            let core = makeArrowPath()
            NSColor.black.setStroke()
            core.lineWidth = 1.45
            core.stroke()

            _ = rect
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }
}

private struct PopoverSizePreset: Identifiable {
    let id: String
    let label: String
    let width: Double
    let height: Double

    static let all: [PopoverSizePreset] = [
        PopoverSizePreset(id: "narrow", label: "超窄", width: 350, height: 560),
        PopoverSizePreset(id: "standard", label: "标准", width: 390, height: 620),
        PopoverSizePreset(id: "wide", label: "宽屏", width: 520, height: 720),
    ]
}

// MARK: - Main Menu Bar Popover View

public struct MenuBarView: View {
    @ObservedObject public var store: AppStore
    public var onOpenSettings: () -> Void
    public var onOpenDashboard: (() -> Void)?
    public var onQuit: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var envReduceMotion
    @Namespace private var popoverTabNamespace
    @Namespace private var providerPillNamespace
    @Namespace private var agPoolPillNamespace

    @State private var hoveredAccountId: String? = nil
    @State private var confirmRemoveAccountId: String? = nil
    @State private var showInlineAPIKeyEditor: Bool = false
    @State private var inlineAPIKeyDraft: String = ""
    @State private var showInlineClaudeProfileCreator: Bool = false
    @State private var inlineClaudeProfileSlugDraft: String = ""
    @State private var inlineClaudeProfileLabelDraft: String = ""
    @State private var inlineClaudeProfileError: String? = nil
    @State private var recentlyCopiedClaudeAccountId: String? = nil
    @State private var refreshSpinAngle: Double = 0
    @State private var showQuotaCustomizePopover: Bool = false
    @State private var expandedCurveAccountKeys: Set<String> = []
    @State private var selectedCurveRange: QuotaHistoryRange = .hours24

    // Popover live edge/corner drag resize state
    @State private var activeResizeEdge: PopoverResizeEdge? = nil
    @State private var hoveredResizeEdge: PopoverResizeEdge? = nil
    @State private var resizeStartMouse: NSPoint? = nil
    @State private var resizeStartSize: CGSize? = nil
    @State private var didApplyResizeCursor: Bool = false
    @State private var showTransientSizePill: Bool = false
    @State private var transientSizePillTask: Task<Void, Never>? = nil

    public init(
        store: AppStore,
        onOpenSettings: @escaping () -> Void,
        onOpenDashboard: (() -> Void)? = nil,
        onQuit: @escaping () -> Void = { NSApplication.shared.terminate(nil) },
        initialShowClaudeProfileCreator: Bool = false
    ) {
        self.store = store
        self.onOpenSettings = onOpenSettings
        self.onOpenDashboard = onOpenDashboard
        self.onQuit = onQuit
        self._showInlineClaudeProfileCreator = State(initialValue: initialShowClaudeProfileCreator)
    }

    private var reduceMotion: Bool {
        envReduceMotion || OrbitMotion.isReducedMotion
    }

    private var settings: AppSettings {
        store.registry.settings
    }

    private var accountCardConfig: AccountCardConfig {
        settings.accountCardConfig
    }

    private var popoverWidth: CGFloat {
        CGFloat(
            AppSettings.clamp(
                settings.popoverWidth,
                to: AppSettings.popoverWidthRange,
                fallback: AppSettings.defaultPopoverWidth
            )
        )
    }

    private var popoverHeight: CGFloat {
        CGFloat(
            AppSettings.clamp(
                settings.popoverHeight,
                to: AppSettings.popoverHeightRange,
                fallback: AppSettings.defaultPopoverHeight
            )
        )
    }

    private var isNarrowLayout: Bool {
        popoverWidth < 365
    }

    private var isCompactCards: Bool {
        accountCardConfig.compactDensity
    }

    private var effectiveResizeEdge: PopoverResizeEdge? {
        activeResizeEdge ?? hoveredResizeEdge
    }

    private var selectedProvider: ProviderID {
        let enabled = store.enabledProvidersOrdered
        if enabled.contains(settings.selectedProvider) {
            return settings.selectedProvider
        }
        return enabled.first ?? .antigravity
    }

    private var warnThreshold: Double {
        settings.lowQuotaWarnThreshold
    }

    private var isHeaderRefreshBusy: Bool {
        store.selectedPopoverTab == .tokenUsage ? store.isScanningTokenUsage : store.isRefreshing
    }

    private var glassHairlineDivider: some View {
        Rectangle()
            .fill(colorScheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.08))
            .frame(height: 0.5)
    }

    /// Explicit appearance-resolved foreground inks used inside macOS 26/27 `.glassEffect` controls
    /// so dynamic glass vibrancy passes never invert label/icon contrast across Light/Dark wallpapers.
    private var glassPrimaryInk: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.84)
    }

    private var glassSecondaryInk: Color {
        colorScheme == .dark ? Color.white.opacity(0.64) : Color.black.opacity(0.56)
    }

    private var glassControlTintFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.075) : Color.black.opacity(0.042)
    }

    private var glassControlSpecularBorder: LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color.white.opacity(0.24), Color.white.opacity(0.06)]
                : [Color.white.opacity(0.90), Color.black.opacity(0.10)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    public var body: some View {
        ZStack {
            OrbitLiquidGlassBackdrop(style: .regular)

            VStack(spacing: 0) {
                headerBar
                glassHairlineDivider

                if shouldDisplayUpdateBanner {
                    updateBannerView
                        .padding(.horizontal, isNarrowLayout ? 10 : 12)
                        .padding(.top, 7)
                        .transition(OrbitMotion.panelTransition)
                }

                popoverTabSwitcherBar
                    .padding(.horizontal, isNarrowLayout ? 10 : 12)
                    .padding(.top, 7)
                    .padding(.bottom, 3)

                Group {
                    if store.selectedPopoverTab == .quota {
                        quotaPopoverContent
                            .transition(OrbitMotion.panelTransition)
                    } else {
                        TokenUsagePopoverView(store: store)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(OrbitMotion.panelTransition)
                    }
                }
                .clipped()
                .animation(OrbitMotion.snappy, value: store.selectedPopoverTab)
            }
            .animation(OrbitMotion.snappy, value: shouldDisplayUpdateBanner)
            .animation(OrbitMotion.snappy, value: store.updatePhase)

            if activeResizeEdge != nil || showTransientSizePill {
                VStack {
                    Spacer()
                    floatingResizeSizePill
                        .padding(.bottom, 14)
                }
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .overlay(alignment: .leading) {
            resizeEdgeStrip(.left)
                .frame(width: 5)
                .padding(.top, 6)
                .padding(.bottom, 14)
        }
        .overlay(alignment: .trailing) {
            resizeEdgeStrip(.right)
                .frame(width: 5)
                .padding(.top, 6)
                .padding(.bottom, 14)
        }
        .overlay(alignment: .bottom) {
            resizeEdgeStrip(.bottom)
                .frame(height: 5)
                .padding(.horizontal, 14)
        }
        .overlay(alignment: .bottomLeading) {
            resizeCornerHandle(.bottomLeft)
                .frame(width: 14, height: 14)
        }
        .overlay(alignment: .bottomTrailing) {
            resizeCornerHandle(.bottomRight)
                .frame(width: 14, height: 14)
        }
        .animation(OrbitMotion.hover, value: activeResizeEdge != nil || showTransientSizePill)
        .frame(width: popoverWidth, height: popoverHeight)
        .onChange(of: selectedProvider) { _ in
            confirmRemoveAccountId = nil
            showInlineAPIKeyEditor = false
            inlineAPIKeyDraft = ""
            showInlineClaudeProfileCreator = false
            inlineClaudeProfileSlugDraft = ""
            inlineClaudeProfileLabelDraft = ""
            inlineClaudeProfileError = nil
            recentlyCopiedClaudeAccountId = nil
        }
        .onChange(of: effectiveResizeEdge) { newEdge in
            syncResizeCursor(for: newEdge)
        }
        .onDisappear {
            cleanupResizeStateOnDisappear()
        }
    }

    private var quotaPopoverContent: some View {
        let horizontalInset: CGFloat = isNarrowLayout ? 9 : 11
        let scrollInset: CGFloat = isNarrowLayout ? 9 : 12

        return VStack(spacing: 0) {
            providerSwitcherStrip
                .padding(.horizontal, horizontalInset)
                .padding(.top, 4)
                .padding(.bottom, 4)

            quotaStatusToolbar
                .padding(.horizontal, scrollInset)
                .padding(.bottom, 4)

            if selectedProvider == .antigravity {
                antigravityPoolFilterBar
                    .padding(.horizontal, scrollInset)
                    .padding(.bottom, 5)
                    .transition(OrbitMotion.panelTransition)
            }

            if store.shouldShowMigrationBanner {
                migrationBanner
                    .padding(.horizontal, scrollInset)
                    .padding(.bottom, 7)
                    .transition(OrbitMotion.panelTransition)
            }

            if let pending = store.pendingForceQuit {
                forceQuitBanner(pending)
                    .padding(.horizontal, scrollInset)
                    .padding(.bottom, 7)
                    .transition(OrbitMotion.panelTransition)
            }

            if let busy = store.busyActionLabel {
                busyBanner(busy)
                    .padding(.horizontal, scrollInset)
                    .padding(.bottom, 7)
                    .transition(OrbitMotion.panelTransition)
            } else if let banner = store.operationBanner, !shouldSuppressDuplicateUpdateOperationBanner {
                operationBannerView(banner, isError: store.operationBannerIsError)
                    .padding(.horizontal, scrollInset)
                    .padding(.bottom, 7)
                    .transition(OrbitMotion.panelTransition)
            }

            if selectedProvider == .antigravity, let drift = store.antigravityCredentialDrift {
                antigravityCredentialDriftBanner(drift)
                    .padding(.horizontal, scrollInset)
                    .padding(.bottom, 7)
                    .transition(OrbitMotion.panelTransition)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: isCompactCards ? 4.5 : 6) {
                    if selectedProvider.supportsMultiAccount {
                        switchableProviderContent(for: selectedProvider)
                    } else {
                        singleProviderContent(for: selectedProvider)
                    }
                }
                .id(selectedProvider)
                .transition(OrbitMotion.panelTransition)
                .padding(.horizontal, scrollInset)
                .padding(.top, 1)
                .padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(OrbitMotion.snappy, value: selectedProvider)
            .animation(OrbitMotion.snappy, value: showInlineClaudeProfileCreator)

            glassHairlineDivider
            bottomActionBar
        }
        .animation(OrbitMotion.snappy, value: store.busyActionLabel != nil)
        .animation(OrbitMotion.snappy, value: store.operationBanner)
        .animation(OrbitMotion.snappy, value: store.pendingForceQuit?.id)
        .animation(OrbitMotion.snappy, value: store.antigravityCredentialDrift)
        .animation(OrbitMotion.snappy, value: store.effectiveAntigravityPool())
    }

    // MARK: - Top Dual-Tab Switcher (Liquid Glass Full-Width Segmented Capsule)

    private var popoverTabSwitcherBar: some View {
        let isDark = (colorScheme == .dark)

        return OrbitGlassContainer(spacing: 4) {
            HStack(spacing: 3) {
                ForEach(PopoverTab.allCases) { tab in
                    let isSelected = (store.selectedPopoverTab == tab)
                    Button {
                        withAnimation(OrbitMotion.pill) {
                            store.selectPopoverTab(tab)
                        }
                    } label: {
                        HStack(spacing: 5.5) {
                            Image(systemName: tab.symbolName)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(isSelected ? .accentColor : glassSecondaryInk)
                            Text(tab.displayName)
                                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                                .foregroundColor(isSelected ? glassPrimaryInk : glassSecondaryInk)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5.5)
                        .contentShape(Capsule())
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: isDark
                                                ? [Color.white.opacity(0.19), Color.white.opacity(0.11)]
                                                : [Color.white.opacity(0.92), Color.white.opacity(0.74)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(
                                                LinearGradient(
                                                    colors: isDark
                                                        ? [Color.white.opacity(0.32), Color.white.opacity(0.09)]
                                                        : [Color.white.opacity(0.98), Color.black.opacity(0.09)],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                ),
                                                lineWidth: 0.7
                                            )
                                    )
                                    .shadow(
                                        color: Color.black.opacity(isDark ? 0.28 : 0.09),
                                        radius: 2.5,
                                        y: 1
                                    )
                                    .matchedGeometryEffect(id: "activePopoverTab", in: popoverTabNamespace)
                            }
                        }
                    }
                    .orbitInteractiveButton(pressedScale: 0.98, hoverTint: nil, cornerRadius: 99)
                }
            }
            .padding(3)
            .background(Capsule().fill(glassControlTintFill))
            .overlay(Capsule().strokeBorder(glassControlSpecularBorder, lineWidth: 0.65))
            .orbitGlassCapsule(interactive: false)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        let isDark = (colorScheme == .dark)
        let actionBtnSize: CGFloat = isNarrowLayout ? 26 : 28

        return HStack(spacing: isNarrowLayout ? 8 : 10) {
            PulsarBrandIconView(size: 32, showGlowShadow: true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: isNarrowLayout ? 4 : 5.5) {
                    Text("Pulsar")
                        .font(.system(size: isNarrowLayout ? 14 : 14.5, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Text("v\(AppStore.appVersion)")
                        .font(.system(size: isNarrowLayout ? 9 : 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, isNarrowLayout ? 4.5 : 5.5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
                                .fill(isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.055))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    isDark ? Color.white.opacity(0.15) : Color.white.opacity(0.72),
                                    lineWidth: 0.6
                                )
                        )
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    headerUpdatePill
                }

                HStack(spacing: 5) {
                    OrbitPulseDot(
                        color: headerStatusDotColor,
                        size: 6,
                        isActive: isHeaderStatusPulseActive
                    )
                    Text(headerStatusSubtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 4)

            OrbitGlassContainer(spacing: 6) {
                HStack(spacing: isNarrowLayout ? 5 : 6) {
                    Button {
                        if store.selectedPopoverTab == .tokenUsage {
                            Task { await store.refreshTokenUsage() }
                        } else {
                            Task { await store.refreshAll() }
                        }
                    } label: {
                        refreshIconView
                            .frame(width: actionBtnSize, height: actionBtnSize)
                            .background(Circle().fill(glassControlTintFill))
                            .overlay(Circle().strokeBorder(glassControlSpecularBorder, lineWidth: 0.65))
                            .contentShape(Circle())
                            .orbitGlassCapsule(interactive: true)
                    }
                    .orbitInteractiveButton(pressedScale: 0.92, hoverTint: nil, cornerRadius: 99)
                    .disabled(isHeaderRefreshBusy)
                    .help(store.selectedPopoverTab == .tokenUsage ? "扫描本地 Token 用量日志" : "立即刷新全部服务配额")

                    Button {
                        onOpenSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(glassPrimaryInk)
                            .frame(width: actionBtnSize, height: actionBtnSize)
                            .background(Circle().fill(glassControlTintFill))
                            .overlay(Circle().strokeBorder(glassControlSpecularBorder, lineWidth: 0.65))
                            .contentShape(Circle())
                            .orbitGlassCapsule(interactive: true)
                    }
                    .orbitInteractiveButton(pressedScale: 0.92, hoverTint: nil, cornerRadius: 99)
                    .help("偏好设置")

                    Menu {
                        Button("扫描本地 Token 日志") {
                            Task { await store.refreshTokenUsage() }
                        }
                        Divider()
                        Button("刷新当前服务 (\(selectedProvider.displayName))") {
                            Task { await store.refreshProvider(selectedProvider, userInitiated: true) }
                        }
                        Button("刷新全部服务") {
                            Task { await store.refreshAll() }
                        }
                        Divider()
                        Button("检查更新…") {
                            Task {
                                await store.checkForUpdates(userInitiated: true)
                                if case .upToDate = store.updatePhase, store.selectedPopoverTab != .quota {
                                    withAnimation(OrbitMotion.pill) {
                                        store.selectPopoverTab(.quota)
                                    }
                                }
                            }
                        }
                        .disabled(store.updatePhase.isBusy)
                        Button("偏好设置...") {
                            onOpenSettings()
                        }
                        Button("打开数据目录") {
                            store.openDataDirectory()
                        }
                        Divider()
                        Button("退出 Pulsar") {
                            onQuit()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(glassPrimaryInk)
                            .frame(width: actionBtnSize, height: actionBtnSize)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: actionBtnSize, height: actionBtnSize)
                    .background(Circle().fill(glassControlTintFill))
                    .overlay(Circle().strokeBorder(glassControlSpecularBorder, lineWidth: 0.65))
                    .contentShape(Circle())
                    .orbitGlassCapsule(interactive: true)
                    .help("更多操作")
                }
            }
        }
        .padding(.horizontal, isNarrowLayout ? 10 : 13)
        .padding(.top, 9)
        .padding(.bottom, 7)
    }

    // MARK: - Built-in GitHub Releases Update Badge & Liquid Glass Banner

    private struct HeaderUpdateBadgeSpec {
        let icon: String
        let text: String
        let tooltip: String
        let lightTextColor: Color
        let lightGradient: [Color]
        let darkGradient: [Color]
        let borderColor: Color
    }

    private var headerUpdateBadgeSpec: HeaderUpdateBadgeSpec? {
        guard store.availableUpdateInfo != nil else { return nil }
        switch store.updatePhase {
        case .available(let info):
            return HeaderUpdateBadgeSpec(
                icon: "arrow.up.circle.fill",
                text: isNarrowLayout ? "新 v\(info.version)" : "有新版本 v\(info.version)",
                tooltip: "发现 Pulsar v\(info.version)，点击展开更新详情",
                lightTextColor: Color(nsColor: .systemBlue),
                lightGradient: [
                    Color(nsColor: .systemBlue).opacity(0.18),
                    Color(nsColor: .systemTeal).opacity(0.15),
                ],
                darkGradient: [
                    Color(nsColor: .systemBlue).opacity(0.46),
                    Color(nsColor: .systemTeal).opacity(0.36),
                ],
                borderColor: Color(nsColor: .systemBlue)
            )
        case .downloading(let info, let progress):
            let pct = Int((min(max(progress, 0.0), 1.0) * 100.0).rounded())
            return HeaderUpdateBadgeSpec(
                icon: "arrow.down.circle.fill",
                text: "下载中 \(pct)%",
                tooltip: "正在下载 Pulsar v\(info.version)（\(pct)%）",
                lightTextColor: Color(nsColor: .systemBlue),
                lightGradient: [
                    Color(nsColor: .systemBlue).opacity(0.16),
                    Color(nsColor: .systemIndigo).opacity(0.14),
                ],
                darkGradient: [
                    Color(nsColor: .systemBlue).opacity(0.42),
                    Color(nsColor: .systemIndigo).opacity(0.34),
                ],
                borderColor: Color(nsColor: .systemBlue)
            )
        case .verifying(let info):
            return HeaderUpdateBadgeSpec(
                icon: "checkmark.shield.fill",
                text: "校验中…",
                tooltip: "正在校验 Pulsar v\(info.version) 的 SHA-256 与签名",
                lightTextColor: Color(nsColor: .systemIndigo),
                lightGradient: [
                    Color(nsColor: .systemIndigo).opacity(0.16),
                    Color(nsColor: .systemBlue).opacity(0.13),
                ],
                darkGradient: [
                    Color(nsColor: .systemIndigo).opacity(0.44),
                    Color(nsColor: .systemBlue).opacity(0.34),
                ],
                borderColor: Color(nsColor: .systemIndigo)
            )
        case .installing(let info):
            return HeaderUpdateBadgeSpec(
                icon: "gearshape.2.fill",
                text: "安装中…",
                tooltip: "正在安装 Pulsar v\(info.version)",
                lightTextColor: Color(nsColor: .systemIndigo),
                lightGradient: [
                    Color(nsColor: .systemIndigo).opacity(0.16),
                    Color(nsColor: .systemTeal).opacity(0.13),
                ],
                darkGradient: [
                    Color(nsColor: .systemIndigo).opacity(0.44),
                    Color(nsColor: .systemTeal).opacity(0.34),
                ],
                borderColor: Color(nsColor: .systemIndigo)
            )
        case .readyToRelaunch(let info):
            return HeaderUpdateBadgeSpec(
                icon: "arrow.triangle.2.circlepath",
                text: "重启中…",
                tooltip: "Pulsar v\(info.version) 已就绪，正在重启",
                lightTextColor: Color(nsColor: .systemGreen),
                lightGradient: [
                    Color(nsColor: .systemGreen).opacity(0.18),
                    Color(nsColor: .systemTeal).opacity(0.14),
                ],
                darkGradient: [
                    Color(nsColor: .systemGreen).opacity(0.42),
                    Color(nsColor: .systemTeal).opacity(0.34),
                ],
                borderColor: Color(nsColor: .systemGreen)
            )
        case .manualInstallOpened(let info, _):
            return HeaderUpdateBadgeSpec(
                icon: "externaldrive.fill",
                text: isNarrowLayout ? "DMG" : "已打开 DMG",
                tooltip: "已校验并打开 Pulsar v\(info.version) DMG，点击查看说明",
                lightTextColor: Color(nsColor: .systemGreen),
                lightGradient: [
                    Color(nsColor: .systemGreen).opacity(0.18),
                    Color(nsColor: .systemTeal).opacity(0.14),
                ],
                darkGradient: [
                    Color(nsColor: .systemGreen).opacity(0.42),
                    Color(nsColor: .systemTeal).opacity(0.34),
                ],
                borderColor: Color(nsColor: .systemGreen)
            )
        case .idle, .checking, .upToDate, .failed:
            return nil
        }
    }

    @ViewBuilder
    private var headerUpdatePill: some View {
        if let pill = headerUpdateBadgeSpec {
            let isDark = (colorScheme == .dark)
            Button {
                withAnimation(OrbitMotion.snappy) {
                    if let info = store.availableUpdateInfo,
                       let skipped = store.registry.settings.skippedUpdateVersion,
                       skipped.caseInsensitiveCompare(info.version) == .orderedSame {
                        store.updateSettings { $0.skippedUpdateVersion = nil }
                    }
                    store.isUpdateBannerDismissed = false
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: pill.icon)
                        .font(.system(size: isNarrowLayout ? 8.5 : 9, weight: .semibold))
                    Text(pill.text)
                        .font(.system(size: isNarrowLayout ? 9 : 9.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.84)
                        .allowsTightening(true)
                }
                .foregroundColor(isDark ? Color.white.opacity(0.95) : pill.lightTextColor)
                .padding(.horizontal, isNarrowLayout ? 5 : 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: isDark ? pill.darkGradient : pill.lightGradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            pill.borderColor.opacity(isDark ? 0.56 : 0.36),
                            lineWidth: 0.7
                        )
                )
                .shadow(
                    color: pill.borderColor.opacity(isDark ? 0.24 : 0.11),
                    radius: 2,
                    y: 0.8
                )
                .contentShape(Capsule())
            }
            .orbitInteractiveButton(pressedScale: 0.95, hoverTint: nil, cornerRadius: 99)
            .help(pill.tooltip)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
    }

    private var shouldDisplayUpdateBanner: Bool {
        switch store.updatePhase {
        case .available:
            return store.shouldShowUpdateBanner
        case .downloading, .verifying, .installing, .readyToRelaunch:
            return true
        case .manualInstallOpened, .failed:
            return !store.isUpdateBannerDismissed
        case .idle, .checking, .upToDate:
            return false
        }
    }

    private var shouldSuppressDuplicateUpdateOperationBanner: Bool {
        guard shouldDisplayUpdateBanner, let banner = store.operationBanner else {
            return false
        }
        switch store.updatePhase {
        case .failed:
            return banner.hasPrefix("检查更新失败") || banner.hasPrefix("自动更新失败")
        case .manualInstallOpened:
            return banner.hasPrefix("已校验并打开安装包")
        default:
            return false
        }
    }

    private var updateBannerHighlightColor: Color {
        switch store.updatePhase {
        case .failed:
            return Color(nsColor: .systemRed)
        case .manualInstallOpened, .readyToRelaunch:
            return Color(nsColor: .systemGreen)
        case .available, .downloading, .verifying, .installing, .idle, .checking, .upToDate:
            return Color.accentColor
        }
    }

    private func closeUpdateBanner() {
        withAnimation(OrbitMotion.snappy) {
            let shouldClearOp = shouldSuppressDuplicateUpdateOperationBanner
            store.dismissUpdateBanner()
            if shouldClearOp {
                store.dismissOperationBanner()
            }
        }
    }

    @ViewBuilder
    private var updateBannerView: some View {
        let isDark = (colorScheme == .dark)

        VStack(alignment: .leading, spacing: 7) {
            switch store.updatePhase {
            case .available(let info):
                let notesSummary = compactReleaseNotesSummary(from: info.releaseNotes)
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.accentColor)

                    Text("发现新版本 v\(info.version)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let bytes = info.assetSizeBytes, bytes > 0, !isNarrowLayout {
                        Text(formattedByteSize(bytes))
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(isDark ? 0.10 : 0.06))
                            .clipShape(Capsule())
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Spacer(minLength: 4)

                    Button {
                        closeUpdateBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("暂时收起")
                }

                if !notesSummary.isEmpty {
                    Text(notesSummary)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: isNarrowLayout ? 5 : 6) {
                    Button {
                        store.startUpdateDownloadAndInstall()
                    } label: {
                        HStack(spacing: 3.5) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text("一键更新")
                                .font(.system(size: 10.5, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        store.openUpdateReleasePage()
                    } label: {
                        HStack(spacing: 3) {
                            Text("Release")
                                .font(.system(size: 10.5, weight: .medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8.5, weight: .semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer(minLength: 4)

                    Button {
                        withAnimation(OrbitMotion.snappy) {
                            store.skipAvailableUpdate()
                        }
                    } label: {
                        Text("忽略")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .help("忽略 v\(info.version)，不再自动提示此版本")
                }

            case .downloading(let info, let progress):
                let clamped = min(max(progress, 0.0), 1.0)
                let pct = Int((clamped * 100.0).rounded())
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.accentColor)
                    Text("正在下载 Pulsar v\(info.version)…")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text("\(pct)%")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .orbitNumericTransition()
                        .foregroundColor(.accentColor)
                }

                OrbitAnimatedProgressBar(
                    fraction: clamped,
                    tint: .accentColor,
                    trackColor: Color.primary.opacity(isDark ? 0.14 : 0.10),
                    height: 5,
                    minFillWidth: 4,
                    animateOnAppear: false
                )

                Text("完成后将自动校验 SHA-256 哈希与代码签名")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

            case .verifying(let info):
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.76)
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text("正在校验 Pulsar v\(info.version)…")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text("核对 SHA-256 校验和、Bundle ID 与代码签名")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                }

            case .installing(let info):
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.76)
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text("正在安装 Pulsar v\(info.version)…")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text("正在安全替换应用包并保留本地账号与配置")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                }

            case .readyToRelaunch(let info):
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(nsColor: .systemGreen))
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text("Pulsar v\(info.version) 安装完成，正在重启…")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text("片刻后将自动恢复菜单栏图标")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                }

            case .manualInstallOpened(let info, let dmgPath):
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(nsColor: .systemGreen))
                    Text("已打开 v\(info.version) 安装包")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        closeUpdateBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("关闭提示")
                }

                Text("已通过 SHA-256 校验并打开 DMG，请拖入 Applications 完成替换")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dmgPath)])
                    } label: {
                        Label("在访达中显示", systemImage: "folder")
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        store.openUpdateReleasePage()
                    } label: {
                        Text("Release")
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer(minLength: 2)
                }

            case .failed(let message):
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(nsColor: .systemRed))
                    Text("更新失败")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        closeUpdateBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("关闭错误提示")
                }

                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Button {
                        Task { await store.checkForUpdates(userInitiated: true) }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        store.openUpdateReleasePage()
                    } label: {
                        HStack(spacing: 3) {
                            Text("前往 GitHub 下载")
                                .font(.system(size: 10.5, weight: .medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8.5, weight: .semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer(minLength: 2)
                }

            case .idle, .checking, .upToDate:
                EmptyView()
            }
        }
        .padding(.horizontal, isNarrowLayout ? 9.5 : 11)
        .padding(.vertical, 8.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitCardStyle(
            cornerRadius: 11,
            isHighlighted: true,
            highlightColor: updateBannerHighlightColor,
            hoverLift: false
        )
    }

    private func compactReleaseNotesSummary(from raw: String) -> String {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .map { line -> String in
                var cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                while cleaned.hasPrefix("#") {
                    cleaned = String(cleaned.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                if cleaned.hasPrefix("- ") || cleaned.hasPrefix("* ") || cleaned.hasPrefix("• ") {
                    cleaned = "• " + String(cleaned.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                cleaned = cleaned
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "__", with: "")
                    .replacingOccurrences(of: "`", with: "")
                return cleaned
            }
            .filter { !$0.isEmpty }
        return lines.prefix(3).joined(separator: "  ")
    }

    private func formattedByteSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    @ViewBuilder
    private var refreshIconView: some View {
        if isHeaderRefreshBusy && !reduceMotion {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.accentColor)
                .rotationEffect(.degrees(refreshSpinAngle))
                .onAppear {
                    refreshSpinAngle = 0
                    withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                        refreshSpinAngle = 360
                    }
                }
                .onDisappear {
                    refreshSpinAngle = 0
                }
        } else {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isHeaderRefreshBusy ? .accentColor : glassPrimaryInk)
        }
    }

    private var isHeaderStatusPulseActive: Bool {
        if store.selectedPopoverTab == .tokenUsage {
            return store.isScanningTokenUsage || store.tokenUsage != nil
        }
        if selectedProvider == .claude {
            let claudeAccounts = store.accounts(for: .claude)
            let hasReadyOrLoading = claudeAccounts.contains { account in
                guard let status = store.snapshot(for: .claude, accountId: account.id)?.status else {
                    return false
                }
                switch status {
                case .ready, .loading:
                    return true
                case .unconfigured, .reauthRequired, .failed:
                    return false
                }
            }
            return hasReadyOrLoading || (store.clientStatuses[.claude]?.isRunning == true)
        }
        if selectedProvider.supportsClientControl {
            return store.clientStatuses[selectedProvider]?.isRunning == true
        }
        if let status = store.primarySnapshot(for: selectedProvider)?.status {
            switch status {
            case .ready, .loading:
                return true
            case .unconfigured, .reauthRequired, .failed:
                return false
            }
        }
        return false
    }

    private var headerStatusDotColor: Color {
        if store.selectedPopoverTab == .tokenUsage {
            if store.isScanningTokenUsage {
                return Color(nsColor: .systemBlue)
            }
            return Color(nsColor: .systemGreen)
        }
        if selectedProvider == .claude {
            let claudeAccounts = store.accounts(for: .claude)
            let hasReady = claudeAccounts.contains {
                store.snapshot(for: .claude, accountId: $0.id)?.status.isReady == true
            }
            if hasReady || (store.clientStatuses[.claude]?.isRunning == true) {
                return Color(nsColor: .systemGreen)
            }
            let hasLoading = claudeAccounts.contains {
                store.snapshot(for: .claude, accountId: $0.id)?.status == .loading
            }
            if hasLoading {
                return Color(nsColor: .systemBlue)
            }
            return claudeAccounts.isEmpty ? Color.secondary.opacity(0.45) : Color(nsColor: .systemOrange)
        }
        if selectedProvider.supportsClientControl {
            if let status = store.clientStatuses[selectedProvider] {
                return status.isRunning ? Color(nsColor: .systemGreen) : Color.secondary.opacity(0.55)
            }
            return Color.secondary.opacity(0.45)
        } else {
            guard let snap = store.primarySnapshot(for: selectedProvider) else {
                return Color.secondary.opacity(0.45)
            }
            switch snap.status {
            case .ready:
                return Color(nsColor: .systemGreen)
            case .loading:
                return Color(nsColor: .systemBlue)
            case .unconfigured:
                return Color(nsColor: .systemOrange)
            case .reauthRequired, .failed:
                return Color(nsColor: .systemRed)
            }
        }
    }

    private var headerStatusSubtitle: String {
        if store.selectedPopoverTab == .tokenUsage {
            if store.isScanningTokenUsage {
                return "正在扫描本地日志..."
            }
            if let scannedAt = store.tokenUsage?.lastScannedAt {
                return "纯本地只读 · \(store.relativeTimeAgoString(since: scannedAt))扫描"
            }
            return "纯本地只读 · 零 Claude 联网"
        }
        let stateLabel: String
        if selectedProvider == .claude {
            let count = store.accounts(for: .claude).count
            let procCount = store.clientStatuses[.claude]?.runningProcesses.count ?? 0
            if procCount > 0 {
                stateLabel = "Claude CLI · 本地被动 · \(count) 账号 · \(procCount) 进程"
            } else {
                stateLabel = "Claude CLI · 本地被动 · \(count) 账号"
            }
        } else if selectedProvider.supportsClientControl {
            let running = store.clientStatuses[selectedProvider]?.isRunning ?? false
            stateLabel = running ? "运行中" : "未运行"
        } else if let snap = store.primarySnapshot(for: selectedProvider) {
            switch snap.status {
            case .ready: stateLabel = "已连接"
            case .loading: stateLabel = "刷新中"
            case .unconfigured: stateLabel = "未配置"
            case .reauthRequired: stateLabel = "需重新登录"
            case .failed: stateLabel = "获取异常"
            }
        } else {
            stateLabel = "待刷新"
        }

        if let lastRefreshedAt = store.lastRefreshedAt {
            let ago = store.relativeTimeAgoString(since: lastRefreshedAt)
            return "\(stateLabel) · \(ago)更新"
        }
        return stateLabel
    }

    // MARK: - Provider Switcher Strip (Balanced Adaptive Rows across 340pt–680pt)

    /// Partitions enabled providers into balanced full-width rows (e.g. 7 providers -> [3, 2, 2] at 390pt,
    /// [4, 3] at >= 510pt, [2, 2, 2, 1] at 340pt) with zero dangling half-empty grid columns.
    public nonisolated static func providerSwitcherRows(
        for providers: [ProviderID],
        maxColumns: Int
    ) -> [[ProviderID]] {
        guard !providers.isEmpty else { return [] }
        let safeCols = max(1, maxColumns)
        let count = providers.count
        let rowCount = Int(ceil(Double(count) / Double(safeCols)))
        let baseSize = count / rowCount
        let extraRows = count % rowCount

        var rows: [[ProviderID]] = []
        rows.reserveCapacity(rowCount)
        var offset = 0
        for rowIndex in 0..<rowCount {
            let rowSize = baseSize + (rowIndex < extraRows ? 1 : 0)
            rows.append(Array(providers[offset..<(offset + rowSize)]))
            offset += rowSize
        }
        return rows
    }

    private var providerPillColumnCount: Int {
        let isDualMode = (accountCardConfig.pillQuotaWindow == .both5hAndWeekly)
        if popoverWidth < 375 {
            return 2
        }
        if isDualMode {
            return popoverWidth < 440 ? 2 : 3
        }
        if popoverWidth >= 510 {
            return 4
        }
        return 3
    }

    private var providerSwitcherStrip: some View {
        let providers = store.enabledProvidersOrdered
        let maxCols = providerPillColumnCount
        let rows = Self.providerSwitcherRows(for: providers, maxColumns: maxCols)
        let isCompactMultiCol = (maxCols >= 3 && (popoverWidth < 420 || (accountCardConfig.pillQuotaWindow == .both5hAndWeekly && popoverWidth < 500)))
        let gridSpacing: CGFloat = isCompactMultiCol ? 4 : 5

        return VStack(spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: gridSpacing) {
                    ForEach(row) { provider in
                        providerPill(for: provider, columnCount: row.count)
                    }
                }
            }
        }
    }

    private func providerPill(for provider: ProviderID, columnCount: Int) -> some View {
        let isSelected = (provider == selectedProvider)
        let badge = pillMetricBadge(for: provider)
        let isDualMode = (accountCardConfig.pillQuotaWindow == .both5hAndWeekly)
        let isDualThreeCol = (columnCount >= 3 && isDualMode && popoverWidth < 500)
        let isTightMultiCol = (columnCount == 3 && popoverWidth < 420)
            || (columnCount >= 4 && popoverWidth < 570)
            || isDualThreeCol
        let iconSize: CGFloat = isTightMultiCol ? 12.5 : 14.5
        let nameFontSize: CGFloat = isTightMultiCol ? 10 : 11
        let badgeFontSize: CGFloat = isDualThreeCol
            ? (popoverWidth < 475 ? 9 : 9.5)
            : (isTightMultiCol ? 9.5 : 10.5)
        let hPadding: CGFloat = isTightMultiCol ? 4.5 : 6.5
        let innerSpacing: CGFloat = isTightMultiCol ? 2.5 : 4

        return Button {
            withAnimation(OrbitMotion.pill) {
                store.selectProvider(provider)
            }
        } label: {
            HStack(spacing: innerSpacing) {
                ProviderBrandIconView(
                    provider: provider,
                    size: iconSize,
                    renderingAccent: isSelected ? .accentColor : .primary.opacity(0.82)
                )

                Text(provider.displayName)
                    .font(.system(size: nameFontSize, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .primary : .primary.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .allowsTightening(true)
                    .layoutPriority(1)

                Spacer(minLength: isTightMultiCol ? 1 : 2)

                Text(badge.text)
                    .font(.system(size: badgeFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .orbitNumericTransition()
                    .foregroundColor(badge.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .allowsTightening(true)
                    .layoutPriority(2)
            }
            .padding(.horizontal, hPadding)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.09))
                        .matchedGeometryEffect(id: "activeProviderPill", in: providerPillNamespace)
                }
            }
            .orbitCardStyle(
                cornerRadius: 9,
                isHighlighted: isSelected,
                highlightColor: .accentColor,
                hoverLift: false
            )
        }
        .orbitInteractiveButton(
            pressedScale: 0.97,
            hoverTint: nil,
            cornerRadius: 9
        )
    }

    private func pillMetricBadge(for provider: ProviderID) -> (text: String, color: Color) {
        let info = store.pillBadgeInfo(for: provider)
        if info.isError {
            return (info.text, Color(nsColor: .systemRed))
        }
        if info.isUnconfigured {
            return (info.text, Color(nsColor: .systemOrange))
        }
        guard info.isReady else {
            return (info.text, .secondary)
        }
        if let remPct = info.remainingPercent {
            let color = OrbitTheme.quotaColor(
                remainingFraction: remPct / 100.0,
                warnThreshold: warnThreshold
            )
            return (info.text, color)
        }
        if let isPositive = info.isBalancePositive {
            let color = isPositive
                ? Color(nsColor: .systemGreen)
                : Color(nsColor: .systemRed)
            return (info.text, color)
        }
        return (info.text, Color(nsColor: .systemGreen))
    }

    // MARK: - Quota Status & Quick Customize Toolbar

    private var quotaStatusToolbar: some View {
        HStack(spacing: 6) {
            if selectedProvider == .claude {
                let claudeAccounts = store.accounts(for: .claude)
                let readyCount = claudeAccounts.filter {
                    store.snapshot(for: .claude, accountId: $0.id)?.status.isReady == true
                }.count
                let procCount = store.clientStatuses[.claude]?.runningProcesses.count ?? 0
                let isActive = (readyCount > 0 || procCount > 0)
                let dotColor: Color = isActive
                    ? Color(nsColor: .systemGreen)
                    : (claudeAccounts.isEmpty ? Color.secondary.opacity(0.45) : Color(nsColor: .systemOrange))
                let toolbarLabel = procCount > 0
                    ? "Claude CLI · 本地被动 · \(claudeAccounts.count) 账号 · \(procCount) 进程"
                    : "Claude CLI · 本地被动 · \(claudeAccounts.count) 账号"

                OrbitPulseDot(
                    color: dotColor,
                    size: 6,
                    isActive: isActive
                )

                Text(toolbarLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if selectedProvider.supportsClientControl {
                let status = store.clientStatuses[selectedProvider]
                let installedText: String = {
                    if let apps = status?.installedApps, !apps.isEmpty {
                        return apps.joined(separator: " / ")
                    }
                    return selectedProvider.displayName
                }()
                let procCount = status?.runningProcesses.count ?? 0
                let running = status?.isRunning ?? false

                OrbitPulseDot(
                    color: running ? Color(nsColor: .systemGreen) : Color.secondary.opacity(0.45),
                    size: 6,
                    isActive: running
                )

                Text(installedText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("·")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary.opacity(0.65))

                Text(running ? "\(procCount) 进程" : "未运行")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                let snap = store.primarySnapshot(for: selectedProvider)
                let stateColor: Color = {
                    guard let status = snap?.status else { return .secondary.opacity(0.45) }
                    switch status {
                    case .ready: return Color(nsColor: .systemGreen)
                    case .loading: return Color(nsColor: .systemBlue)
                    case .unconfigured: return Color(nsColor: .systemOrange)
                    case .reauthRequired, .failed: return Color(nsColor: .systemRed)
                    }
                }()
                let stateActive: Bool = {
                    guard let status = snap?.status else { return false }
                    switch status {
                    case .ready, .loading: return true
                    case .unconfigured, .reauthRequired, .failed: return false
                    }
                }()
                let stateLabel: String = {
                    guard let status = snap?.status else { return "待刷新" }
                    switch status {
                    case .ready: return "已连接"
                    case .loading: return "刷新中"
                    case .unconfigured: return "未配置"
                    case .reauthRequired: return "需重新登录"
                    case .failed: return "获取异常"
                    }
                }()

                OrbitPulseDot(color: stateColor, size: 6, isActive: stateActive)

                Text("\(selectedProvider.displayName) · \(stateLabel)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(accountCardConfig.pillQuotaWindow.shortName)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 4)

            OrbitGlassContainer {
                Button {
                    showQuotaCustomizePopover.toggle()
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10, weight: .semibold))
                        Text("自定义")
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundColor(showQuotaCustomizePopover ? .accentColor : glassPrimaryInk.opacity(0.86))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(
                                showQuotaCustomizePopover
                                    ? Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.14)
                                    : glassControlTintFill
                            )
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                showQuotaCustomizePopover
                                    ? LinearGradient(
                                        colors: [Color.accentColor.opacity(0.65), Color.accentColor.opacity(0.32)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                    : glassControlSpecularBorder,
                                lineWidth: 0.65
                            )
                    )
                    .contentShape(Capsule())
                    .orbitGlassCapsule(
                        interactive: true,
                        tint: showQuotaCustomizePopover ? Color.accentColor.opacity(0.24) : nil
                    )
                }
                .orbitInteractiveButton(pressedScale: 0.95, hoverTint: nil, cornerRadius: 99)
                .help("自定义胶囊口径、额度卡片显示项与弹窗尺寸")
                .popover(isPresented: $showQuotaCustomizePopover, arrowEdge: .bottom) {
                    quotaCustomizePopoverView
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(minHeight: 20)
    }

    // MARK: - Antigravity Pool Quick Filter Bar & Label Helpers

    private func agPoolGridLabel(_ pool: AntigravityPoolPreference) -> String {
        switch pool {
        case .autoLowest: return "全部池最低"
        case .gemini: return "Gemini (AGY)"
        case .claude: return "Claude / GPT"
        case .argon: return "Argon"
        }
    }

    private func agPoolFilterChipLabel(_ pool: AntigravityPoolPreference) -> String {
        switch pool {
        case .autoLowest: return "全部"
        case .gemini: return "Gemini"
        case .claude: return "Claude / GPT"
        case .argon: return "Argon"
        }
    }

    private func agPoolHumanName(_ pool: AntigravityPoolPreference) -> String {
        switch pool {
        case .autoLowest: return "全部"
        case .gemini: return "Gemini"
        case .claude: return "Claude / GPT"
        case .argon: return "Argon"
        }
    }

    private var antigravityPoolFilterBar: some View {
        let activePool = store.effectiveAntigravityPool()
        let isDark = (colorScheme == .dark)

        return HStack(spacing: isNarrowLayout ? 5 : 7) {
            HStack(spacing: 3) {
                if !isNarrowLayout {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                Text("追踪池")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            OrbitGlassContainer(spacing: 2) {
                HStack(spacing: 2) {
                    ForEach(AntigravityPoolPreference.allCases) { pool in
                        let isSelected = (activePool == pool)
                        Button {
                            withAnimation(OrbitMotion.pill) {
                                store.setAntigravityPool(pool)
                            }
                        } label: {
                            Text(agPoolFilterChipLabel(pool))
                                .font(.system(
                                    size: isNarrowLayout ? 10 : 10.5,
                                    weight: isSelected ? .semibold : .medium
                                ))
                                .foregroundColor(
                                    isSelected
                                        ? (isDark ? Color.white : Color.accentColor)
                                        : glassSecondaryInk
                                )
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, isNarrowLayout ? 6 : 8)
                                .padding(.vertical, 3.5)
                                .frame(maxWidth: .infinity)
                                .contentShape(Capsule())
                                .background {
                                    if isSelected {
                                        Capsule()
                                            .fill(
                                                LinearGradient(
                                                    colors: isDark
                                                        ? [Color.accentColor.opacity(0.36), Color.accentColor.opacity(0.22)]
                                                        : [Color.white.opacity(0.95), Color.accentColor.opacity(0.12)],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                )
                                            )
                                            .overlay(
                                                Capsule()
                                                    .strokeBorder(
                                                        Color.accentColor.opacity(isDark ? 0.62 : 0.45),
                                                        lineWidth: 0.75
                                                    )
                                            )
                                            .shadow(
                                                color: Color.black.opacity(isDark ? 0.24 : 0.07),
                                                radius: 1.8,
                                                y: 0.8
                                            )
                                            .matchedGeometryEffect(id: "activeAgPoolPill", in: agPoolPillNamespace)
                                    }
                                }
                        }
                        .orbitInteractiveButton(pressedScale: 0.96, hoverTint: nil, cornerRadius: 99)
                        .help("追踪 \(agPoolGridLabel(pool))：同步作用于顶部状态栏、AGY 胶囊、预警色与「最多」角标")
                    }
                }
                .padding(2)
                .background(Capsule().fill(glassControlTintFill))
                .overlay(Capsule().strokeBorder(glassControlSpecularBorder, lineWidth: 0.6))
                .orbitGlassCapsule(interactive: false)
            }
        }
        .padding(.horizontal, 1)
    }

    var quotaCustomizePopoverView: some View {
        let cfg = accountCardConfig
        let activeAgPool = store.effectiveAntigravityPool()
        let isSingleAgPoolSelected = (activeAgPool != .autoLowest)
        let currentW = Int(settings.popoverWidth.rounded())
        let currentH = Int(settings.popoverHeight.rounded())

        return VStack(alignment: .leading, spacing: 8.5) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("自定义额度视图")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Text("\(currentW) × \(currentH)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(Capsule())
            }

            Divider().opacity(0.45)

            // 1. Pill quota window mode
            VStack(alignment: .leading, spacing: 5) {
                Text("顶部胶囊额度口径")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 5),
                        GridItem(.flexible(), spacing: 5),
                    ],
                    spacing: 5
                ) {
                    ForEach(MenuBarQuotaWindow.allCases) { mode in
                        let isSelected = (cfg.pillQuotaWindow == mode)
                        Button {
                            withAnimation(OrbitMotion.snappy) {
                                store.updateAccountCardConfig { $0.pillQuotaWindow = mode }
                            }
                        } label: {
                            Text(mode.displayName)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                                .foregroundColor(isSelected ? .accentColor : .primary.opacity(0.85))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                        .fill(
                                            isSelected
                                                ? Color.accentColor.opacity(0.15)
                                                : Color.primary.opacity(0.05)
                                        )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                        .stroke(
                                            isSelected
                                                ? Color.accentColor.opacity(0.55)
                                                : Color.primary.opacity(0.08),
                                            lineWidth: isSelected ? 1 : 0.6
                                        )
                                )
                        }
                        .orbitInteractiveButton(pressedScale: 0.96, hoverTint: nil, cornerRadius: 6.5)
                    }
                }

                Text(cfg.pillQuotaWindow.descriptionText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.45)

            // 2. Account card display toggles (strictly right-aligned switches)
            VStack(alignment: .leading, spacing: 4.5) {
                Text("额度卡片显示项")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                customizeToggleRow(
                    title: "显示头像 / 品牌徽章",
                    isOn: Binding(
                        get: { store.registry.settings.accountCardConfig.showAvatar },
                        set: { value in store.updateAccountCardConfig { $0.showAvatar = value } }
                    )
                )
                customizeToggleRow(
                    title: "显示 5 小时额度条",
                    isOn: Binding(
                        get: { store.registry.settings.accountCardConfig.showFiveHour },
                        set: { value in store.updateAccountCardConfig { $0.showFiveHour = value } }
                    )
                )
                customizeToggleRow(
                    title: "显示周额度条",
                    isOn: Binding(
                        get: { store.registry.settings.accountCardConfig.showWeekly },
                        set: { value in store.updateAccountCardConfig { $0.showWeekly = value } }
                    )
                )
                customizeToggleRow(
                    title: "显示重置倒计时",
                    isOn: Binding(
                        get: { store.registry.settings.accountCardConfig.showResetFootnote },
                        set: { value in store.updateAccountCardConfig { $0.showResetFootnote = value } }
                    )
                )
                customizeToggleRow(
                    title: "显示来源标签",
                    isOn: Binding(
                        get: { store.registry.settings.accountCardConfig.showSourceBadge },
                        set: { value in store.updateAccountCardConfig { $0.showSourceBadge = value } }
                    )
                )
                customizeToggleRow(
                    title: "紧凑密度布局",
                    isOn: Binding(
                        get: { store.registry.settings.accountCardConfig.compactDensity },
                        set: { value in store.updateAccountCardConfig { $0.compactDensity = value } }
                    )
                )
            }

            Divider().opacity(0.45)

            // 3. Antigravity tracked pool selector (right below 紧凑密度布局)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Antigravity 追踪池")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    if isSingleAgPoolSelected {
                        Text(agPoolHumanName(activeAgPool))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor.opacity(0.13))
                            .clipShape(Capsule())
                    }
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 5),
                        GridItem(.flexible(), spacing: 5),
                    ],
                    spacing: 5
                ) {
                    ForEach(AntigravityPoolPreference.allCases) { pool in
                        let isSelected = (activeAgPool == pool)
                        Button {
                            withAnimation(OrbitMotion.snappy) {
                                store.setAntigravityPool(pool)
                            }
                        } label: {
                            Text(agPoolGridLabel(pool))
                                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                                .foregroundColor(isSelected ? .accentColor : .primary.opacity(0.85))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                        .fill(
                                            isSelected
                                                ? Color.accentColor.opacity(0.15)
                                                : Color.primary.opacity(0.05)
                                        )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                        .stroke(
                                            isSelected
                                                ? Color.accentColor.opacity(0.55)
                                                : Color.primary.opacity(0.08),
                                            lineWidth: isSelected ? 1 : 0.6
                                        )
                                )
                        }
                        .orbitInteractiveButton(pressedScale: 0.96, hoverTint: nil, cornerRadius: 6.5)
                    }
                }

                Text("同步作用于顶部状态栏、AGY 胶囊、预警色与「最多」角标（选 Gemini 时不再被 Claude/GPT 低周额拉黄）")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 2) {
                    customizeToggleRow(
                        title: "卡片仅显示所选池",
                        isOn: Binding(
                            get: { store.registry.settings.accountCardConfig.filterAntigravityCardPools },
                            set: { value in store.updateAccountCardConfig { $0.filterAntigravityCardPools = value } }
                        ),
                        disabled: !isSingleAgPoolSelected
                    )
                    .opacity(isSingleAgPoolSelected ? 1.0 : 0.72)

                    if !isSingleAgPoolSelected {
                        Text("选择单个追踪池后生效（当前为全部池最低）")
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
            }

            Divider().opacity(0.45)

            // 4. Popover size presets
            VStack(alignment: .leading, spacing: 5) {
                Text("弹窗尺寸预设")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack(spacing: 5) {
                    ForEach(PopoverSizePreset.all) { preset in
                        let isActive = abs(settings.popoverWidth - preset.width) <= 4
                            && abs(settings.popoverHeight - preset.height) <= 4
                        Button {
                            applyPopoverSizePreset(width: preset.width, height: preset.height)
                        } label: {
                            VStack(spacing: 1.5) {
                                Text(preset.label)
                                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                                    .foregroundColor(isActive ? .accentColor : .primary)
                                Text("\(Int(preset.width))×\(Int(preset.height))")
                                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                    .foregroundColor(isActive ? .accentColor.opacity(0.9) : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                    .fill(
                                        isActive
                                            ? Color.accentColor.opacity(0.15)
                                            : Color.primary.opacity(0.05)
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                    .stroke(
                                        isActive
                                            ? Color.accentColor.opacity(0.55)
                                            : Color.primary.opacity(0.08),
                                        lineWidth: isActive ? 1 : 0.6
                                    )
                            )
                        }
                        .orbitInteractiveButton(pressedScale: 0.96, hoverTint: nil, cornerRadius: 6.5)
                    }
                }

                Text("提示：也可直接拖拽弹窗左/右/底边或底角自由缩放，双击底角恢复默认。")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.45)

            HStack {
                Button("恢复默认") {
                    withAnimation(OrbitMotion.snappy) {
                        store.resetAccountCardConfig()
                        store.setAntigravityPool(.autoLowest)
                        store.resetWindowSizes()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("完成") {
                    showQuotaCustomizePopover = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 286)
    }

    private func customizeToggleRow(
        title: String,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundColor(disabled ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(disabled)
        }
        .frame(maxWidth: .infinity)
    }

    private func applyPopoverSizePreset(width: Double, height: Double) {
        transientSizePillTask?.cancel()
        store.updatePopoverSize(width: width, height: height, persistImmediately: true)
        showTransientSizePill = true
        scheduleTransientSizePillHide(delayNanoseconds: 900_000_000)
    }

    // MARK: - Popover Interactive Edge & Corner Resize Controls

    private func resizeEdgeStrip(_ edge: PopoverResizeEdge) -> some View {
        let isHighlighted = (activeResizeEdge == edge || hoveredResizeEdge == edge)
        let isVertical = (edge == .left || edge == .right)

        return ZStack {
            Color.clear
            if isHighlighted {
                Capsule()
                    .fill(Color.accentColor.opacity(activeResizeEdge == edge ? 0.55 : 0.28))
                    .frame(
                        width: isVertical ? 2 : 34,
                        height: isVertical ? 34 : 2
                    )
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            handleResizeHover(edge: edge, hovering: hovering)
        }
        .gesture(resizeDragGesture(for: edge))
        .help("拖拽调整弹窗尺寸")
    }

    private func resizeCornerHandle(_ edge: PopoverResizeEdge) -> some View {
        let isHighlighted = (activeResizeEdge == edge || hoveredResizeEdge == edge)
        let isBottomRight = (edge == .bottomRight)

        return ZStack(alignment: isBottomRight ? .bottomTrailing : .bottomLeading) {
            Color.clear

            if isBottomRight {
                // Subtle macOS-style diagonal grip lines in the bottom-right corner
                Canvas { context, size in
                    var path = Path()
                    path.move(to: CGPoint(x: size.width - 2.5, y: size.height - 9.5))
                    path.addLine(to: CGPoint(x: size.width - 9.5, y: size.height - 2.5))
                    path.move(to: CGPoint(x: size.width - 2.5, y: size.height - 5.5))
                    path.addLine(to: CGPoint(x: size.width - 5.5, y: size.height - 2.5))

                    let color: Color = isHighlighted
                        ? Color.accentColor.opacity(0.92)
                        : Color.secondary.opacity(0.38)
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(lineWidth: 1.25, lineCap: .round)
                    )
                }
                .padding(2)
            } else {
                // Subtle corner L-grip cue on the bottom-left corner (reveals clearly on hover/drag)
                Canvas { context, size in
                    var path = Path()
                    path.move(to: CGPoint(x: 2.5, y: size.height - 9.5))
                    path.addLine(to: CGPoint(x: 9.5, y: size.height - 2.5))
                    path.move(to: CGPoint(x: 2.5, y: size.height - 5.5))
                    path.addLine(to: CGPoint(x: 5.5, y: size.height - 2.5))

                    let color: Color = isHighlighted
                        ? Color.accentColor.opacity(0.88)
                        : Color.secondary.opacity(0.14)
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(lineWidth: 1.25, lineCap: .round)
                    )
                }
                .padding(2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            handleResizeHover(edge: edge, hovering: hovering)
        }
        .gesture(resizeDragGesture(for: edge))
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                resetPopoverSizeToDefault()
            }
        )
        .help("拖拽自由缩放宽×高 · 双击重置为 \(Int(AppSettings.defaultPopoverWidth))×\(Int(AppSettings.defaultPopoverHeight))")
    }

    private var floatingResizeSizePill: some View {
        OrbitGlassContainer {
            HStack(spacing: 5.5) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("\(Int(settings.popoverWidth.rounded())) × \(Int(settings.popoverHeight.rounded()))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(glassPrimaryInk)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5.5)
            .background(
                Capsule()
                    .fill(colorScheme == .dark ? Color.black.opacity(0.36) : Color.white.opacity(0.76))
            )
            .overlay(Capsule().strokeBorder(glassControlSpecularBorder, lineWidth: 0.7))
            .orbitGlassCapsule(interactive: false)
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.34 : 0.14), radius: 8, y: 3)
        }
    }

    private func handleResizeHover(edge: PopoverResizeEdge, hovering: Bool) {
        if hovering {
            hoveredResizeEdge = edge
        } else if hoveredResizeEdge == edge {
            hoveredResizeEdge = nil
        }
    }

    private func syncResizeCursor(for edge: PopoverResizeEdge?) {
        if let edge {
            edge.cursor.set()
            didApplyResizeCursor = true
        } else if didApplyResizeCursor {
            NSCursor.arrow.set()
            didApplyResizeCursor = false
        }
    }

    private func resizeDragGesture(for edge: PopoverResizeEdge) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { _ in
                let currentMouse = NSEvent.mouseLocation
                if resizeStartMouse == nil || resizeStartSize == nil || activeResizeEdge != edge {
                    resizeStartMouse = currentMouse
                    resizeStartSize = CGSize(
                        width: settings.popoverWidth,
                        height: settings.popoverHeight
                    )
                    activeResizeEdge = edge
                    transientSizePillTask?.cancel()
                    showTransientSizePill = true
                }
                guard let startMouse = resizeStartMouse, let startSize = resizeStartSize else {
                    return
                }
                let (nextW, nextH) = computedResizedDimensions(
                    edge: edge,
                    startSize: startSize,
                    startMouse: startMouse,
                    currentMouse: currentMouse
                )
                store.updatePopoverSize(width: nextW, height: nextH, persistImmediately: false)
            }
            .onEnded { _ in
                let currentMouse = NSEvent.mouseLocation
                if let startMouse = resizeStartMouse, let startSize = resizeStartSize {
                    let (finalW, finalH) = computedResizedDimensions(
                        edge: edge,
                        startSize: startSize,
                        startMouse: startMouse,
                        currentMouse: currentMouse
                    )
                    store.updatePopoverSize(width: finalW, height: finalH, persistImmediately: true)
                } else {
                    store.updatePopoverSize(
                        width: settings.popoverWidth,
                        height: settings.popoverHeight,
                        persistImmediately: true
                    )
                }
                resizeStartMouse = nil
                resizeStartSize = nil
                activeResizeEdge = nil
                scheduleTransientSizePillHide(delayNanoseconds: 350_000_000)
            }
    }

    private func computedResizedDimensions(
        edge: PopoverResizeEdge,
        startSize: CGSize,
        startMouse: NSPoint,
        currentMouse: NSPoint
    ) -> (Double, Double) {
        let dx = currentMouse.x - startMouse.x
        let dy = startMouse.y - currentMouse.y

        let rawWidth = edge.adjustsWidth
            ? Double(startSize.width + edge.widthSign * dx)
            : Double(startSize.width)
        let rawHeight = edge.adjustsHeight
            ? Double(startSize.height + dy)
            : Double(startSize.height)

        let clampedWidth = AppSettings.clamp(
            rawWidth.rounded(),
            to: AppSettings.popoverWidthRange,
            fallback: AppSettings.defaultPopoverWidth
        )
        let clampedHeight = AppSettings.clamp(
            rawHeight.rounded(),
            to: AppSettings.popoverHeightRange,
            fallback: AppSettings.defaultPopoverHeight
        )
        return (clampedWidth, clampedHeight)
    }

    private func resetPopoverSizeToDefault() {
        transientSizePillTask?.cancel()
        store.resetWindowSizes()
        showTransientSizePill = true
        scheduleTransientSizePillHide(delayNanoseconds: 950_000_000)
    }

    private func scheduleTransientSizePillHide(delayNanoseconds: UInt64) {
        transientSizePillTask?.cancel()
        transientSizePillTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            if activeResizeEdge == nil {
                showTransientSizePill = false
            }
        }
    }

    private func cleanupResizeStateOnDisappear() {
        transientSizePillTask?.cancel()
        transientSizePillTask = nil
        if activeResizeEdge != nil {
            store.updatePopoverSize(
                width: settings.popoverWidth,
                height: settings.popoverHeight,
                persistImmediately: true
            )
        }
        activeResizeEdge = nil
        hoveredResizeEdge = nil
        resizeStartMouse = nil
        resizeStartSize = nil
        showTransientSizePill = false
        if didApplyResizeCursor {
            NSCursor.arrow.set()
            didApplyResizeCursor = false
        }
    }

    // MARK: - Banners (Migration, Force Quit, Busy, Info/Error)

    private var migrationBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("检测到原 OrbitSwitch / CodexBar 账号与密钥")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Button {
                    store.dismissMigrationBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("暂时隐藏")
            }

            HStack(spacing: 8) {
                Button {
                    Task { await store.runLegacyMigration() }
                } label: {
                    Label("一键导入原 OrbitSwitch / CodexBar 账号与密钥", systemImage: "square.and.arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.busyActionLabel != nil)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func forceQuitBanner(_ pending: PendingForceQuit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color(nsColor: .systemOrange))
                VStack(alignment: .leading, spacing: 2) {
                    Text("客户端未能按时优雅退出")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.primary)
                    Text("操作：\(pending.action.title(for: pending.provider))。以下进程仍在运行，未自动强杀：")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(pending.surviving) { proc in
                    HStack(spacing: 6) {
                        Text("PID \(proc.id)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                        Text(proc.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        if proc.isInteractiveCLI {
                            Text("交互式终端")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(Color(nsColor: .systemOrange))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color(nsColor: .systemOrange).opacity(0.15))
                                .clipShape(Capsule())
                        }
                        Spacer()
                    }
                }
            }
            .padding(7)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            HStack(spacing: 6) {
                Button("重试优雅退出") {
                    pending.onRetryGraceful()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("取消") {
                    pending.onCancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button(role: .destructive) {
                    pending.onConfirmForceQuit()
                } label: {
                    Text("强制结束并继续")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(nsColor: .systemRed))
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color(nsColor: .systemOrange).opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .systemOrange).opacity(0.55), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func busyBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.75)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func operationBannerView(_ text: String, isError: Bool) -> some View {
        let tint: Color = isError ? Color(nsColor: .systemRed) : Color(nsColor: .systemGreen)
        return HStack(alignment: .center, spacing: 7) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(tint)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                store.dismissOperationBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tint.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.32), lineWidth: 0.7)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func antigravityCredentialDriftBanner(_ drift: AntigravityCredentialDrift) -> some View {
        let isDark = (colorScheme == .dark)
        let orange = Color(nsColor: .systemOrange)
        let isBusy = (store.busyActionLabel != nil || store.refreshingProviders.contains(.antigravity))
        let title: String = {
            switch drift.reason {
            case .desktopKeychainMismatch:
                return "钥匙串与桌面账号不一致"
            case .mirrorFileMismatch:
                return "本地镜像凭证不一致"
            case .staleMetadata:
                return "钥匙串元数据不一致"
            }
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(orange)

                Text(title)
                    .font(.system(size: isNarrowLayout ? 11 : 11.5, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Button {
                    Task { await store.repairAntigravityCredentialDrift() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text("一键修复钥匙串")
                            .font(.system(size: isNarrowLayout ? 10 : 10.5, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(orange)
                .controlSize(.small)
                .disabled(isBusy)
                .help("无感同步钥匙串与本地镜像至 \(drift.desktopEmail)（不重启 Antigravity）")
            }

            Text(drift.summaryMessage)
                .font(.system(size: 10.5))
                .foregroundColor(isDark ? Color.white.opacity(0.84) : Color.black.opacity(0.76))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if !drift.staleBackgroundAgyPids.isEmpty {
                let pidList = drift.staleBackgroundAgyPids.map(String.init).joined(separator: ", ")
                HStack(spacing: 4.5) {
                    Image(systemName: "terminal")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(orange)
                    Text("后台进程 PID \(pidList)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(isDark ? Color.white.opacity(0.78) : Color.black.opacity(0.68))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(orange.opacity(isDark ? 0.18 : 0.12))
                )
            }
        }
        .padding(.horizontal, isNarrowLayout ? 9 : 10.5)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitCardStyle(
            cornerRadius: 11,
            isHighlighted: true,
            highlightColor: orange,
            fillColor: orange.opacity(isDark ? 0.16 : 0.11),
            hoverLift: false
        )
    }

    // MARK: - Multi-Account Switchable View (Antigravity, Codex & Claude CLI)

    @ViewBuilder
    private func switchableProviderContent(for provider: ProviderID) -> some View {
        let accountList = store.accounts(for: provider)
        if provider == .claude {
            HStack(spacing: 6) {
                claudePassiveSafetyPill
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showInlineClaudeProfileCreator {
                inlineClaudeProfileCreatorCard
                    .transition(OrbitMotion.panelTransition)
            }
        }
        if accountList.isEmpty {
            emptySwitchableAccountsCard(for: provider)
        } else {
            ForEach(accountList) { account in
                accountCard(account: account, provider: provider)
            }
        }
    }

    private func accountCard(account: AccountRecord, provider: ProviderID) -> some View {
        let _ = store.quotaHistoryRevision
        let snap = store.snapshot(for: provider, accountId: account.id)
        let isHovered = (hoveredAccountId == account.id)
        let isConfirmingRemove = (confirmRemoveAccountId == account.id)
        let displayPlan = snap?.plan ?? account.plan
        let avatarTint = OrbitTheme.avatarColor(seed: account.email.isEmpty ? account.displayName : account.email)
        let cfg = accountCardConfig
        let claudeSlug: String? = (provider == .claude) ? store.claudeProfileId(for: account.id) : nil
        let isDefaultClaudeProfile = (provider == .claude && claudeSlug?.lowercased() == ClaudeProvider.defaultProfileSlug)
        let canRemoveAccount = !isDefaultClaudeProfile
        let showBestRemainingBadge: Bool = {
            guard account.isBestRemaining else { return false }
            if provider == .claude {
                let readyCount = store.accounts(for: .claude).filter {
                    store.snapshot(for: .claude, accountId: $0.id)?.status.isReady == true
                }.count
                return readyCount >= 2
            }
            return true
        }()
        let activeAgPool: AntigravityPoolPreference = (provider == .antigravity)
            ? store.effectiveAntigravityPool()
            : .autoLowest
        let isAgPoolFocused = (provider == .antigravity && activeAgPool != .autoLowest)
        let isAgPoolFiltered = (isAgPoolFocused && cfg.filterAntigravityCardPools)
        let rawWindows = snap?.windows ?? []
        let poolScopedRawWindows = isAgPoolFiltered
            ? rawWindows.filter { store.isAntigravityWindowMatchingPool($0) }
            : rawWindows
        let visibleWindows = filteredVisibleWindows(from: poolScopedRawWindows)
        let missingFilteredAgPool = isAgPoolFiltered
            && !rawWindows.isEmpty
            && poolScopedRawWindows.isEmpty
        let focusFooter: (text: String, tooltip: String)? = {
            guard cfg.showResetFootnote, let snap, snap.status.isReady else { return nil }
            return focusFooterSummary(
                for: snap,
                visibleWindows: visibleWindows,
                preferredAntigravityPool: activeAgPool,
                strictPoolFilter: isAgPoolFiltered
            )
        }()
        let hasSourceBadge = cfg.showSourceBadge && (snap?.sourceLabel.isEmpty == false)
        let showStandaloneFooter = hasSourceBadge || (canRemoveAccount && isConfirmingRemove)
        let showRemoveInFootnoteRow = canRemoveAccount && !showStandaloneFooter && focusFooter != nil
        let showRemoveInHeader = canRemoveAccount && !showStandaloneFooter && focusFooter == nil && isHovered

        let accountKey = QuotaHistoryStore.accountKey(provider: provider, accountId: account.id)
        let canShowCurve = (snap?.status.isReady == true && !rawWindows.isEmpty)
        let isCurveExpanded = canShowCurve && expandedCurveAccountKeys.contains(accountKey)
        let curveConfig = snap.map {
            curveWindowSelection(for: $0, preferredAntigravityPool: activeAgPool)
        }
        let sparklinePoints: [QuotaBurnPoint] = {
            guard canShowCurve, let curveConfig else { return [] }
            let previewSeries = store.quotaHistoryStore.analyze(
                accountKey: accountKey,
                range: .hours24,
                preferredWindowIds: curveConfig.windowIds,
                windowLabels: curveConfig.labels
            )
            return previewSeries.first(where: { $0.points.count >= 2 })?.points
                ?? previewSeries.first?.points
                ?? []
        }()
        let showCurveInFootnote = canShowCurve && focusFooter != nil
        let showCurveInStandaloneFooter = canShowCurve && !showCurveInFootnote && showStandaloneFooter
        let showCurveInHeader = canShowCurve && !showCurveInFootnote && !showCurveInStandaloneFooter

        let cardSpacing: CGFloat = isCompactCards ? 2.5 : 4.5
        let cardHPadding: CGFloat = isNarrowLayout
            ? (isCompactCards ? 8 : 8.5)
            : (isCompactCards ? 9 : 11)
        let cardVPadding: CGFloat = isCompactCards ? 5 : 7.5
        let cardInnerWidth = max(240, popoverWidth - (isNarrowLayout ? 18 : 24) - cardHPadding * 2)

        return VStack(alignment: .leading, spacing: cardSpacing) {
            // Card top row: Optional 28x28 Avatar + Identity + Status / Quick Switch
            HStack(alignment: .center, spacing: isNarrowLayout ? 6 : 8) {
                if cfg.showAvatar {
                    accountAvatarView(for: account, tint: avatarTint)
                }

                VStack(alignment: .leading, spacing: isCompactCards ? 0.5 : 1.5) {
                    HStack(spacing: 4.5) {
                        Text(account.displayName)
                            .font(.system(size: isCompactCards ? 12 : 12.5, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if let slug = claudeSlug, !slug.isEmpty {
                            claudeProfileSlugBadge(slug, isDefault: isDefaultClaudeProfile)
                        }

                        if let plan = displayPlan, plan.kind != .unknown {
                            planBadge(plan)
                        }
                    }

                    if !account.email.isEmpty && account.email != account.displayName {
                        Text(account.email)
                            .font(.system(size: isCompactCards ? 10 : 10.5))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    if showCurveInHeader {
                        curveTogglePill(
                            accountKey: accountKey,
                            sparklinePoints: sparklinePoints,
                            isExpanded: isCurveExpanded,
                            compact: true
                        )
                    }

                    if showBestRemainingBadge {
                        bestRemainingBadge
                    }

                    if account.isActiveLive {
                        activeLiveBadge(for: provider)
                    } else {
                        Button {
                            Task { await store.switchAccount(provider: provider, account: account) }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: provider == .claude ? "checkmark.circle" : "arrow.left.arrow.right")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(provider == .claude ? "设为默认" : "切换")
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, isNarrowLayout ? 7 : 8)
                            .padding(.vertical, isCompactCards ? 2.5 : 3.5)
                            .background(Capsule().fill(Color.accentColor))
                        }
                        .orbitInteractiveButton(pressedScale: 0.94, hoverTint: nil, cornerRadius: 99)
                        .disabled(store.busyActionLabel != nil)
                        .opacity(store.busyActionLabel != nil ? 0.55 : 1.0)
                        .help(
                            provider == .claude
                                ? "将新终端 Claude CLI 默认账号切换为 \(account.displayName)（纯本地指针，不重启进行中的终端）"
                                : "切换当前 \(provider.displayName) 账号为 \(account.displayName)"
                        )
                    }

                    if showRemoveInHeader {
                        Button {
                            withAnimation(OrbitMotion.snappy) {
                                confirmRemoveAccountId = account.id
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(Color(nsColor: .systemRed).opacity(0.9))
                                .frame(width: 20, height: 20)
                                .background(
                                    Circle()
                                        .fill(Color(nsColor: .systemRed).opacity(0.10))
                                )
                        }
                        .orbitInteractiveButton(pressedScale: 0.92, hoverTint: nil, cornerRadius: 99)
                        .disabled(store.busyActionLabel != nil)
                        .help(provider == .claude ? "移除此 Claude CLI 配置（保留本地目录）" : "移除此账号")
                        .transition(.opacity.combined(with: .scale(scale: 0.88)))
                    }
                }
                .layoutPriority(1)
                .animation(OrbitMotion.hover, value: showRemoveInHeader)
            }

            // Compact high-density single-row-per-pool quota matrix + optional focus reset footnote
            accountQuotaBody(
                provider: provider,
                snapshot: snap,
                visibleWindows: visibleWindows,
                focusFooter: focusFooter,
                showInlineRemoveOnFootnote: showRemoveInFootnoteRow,
                isHovered: isHovered,
                accountId: account.id,
                focusedAntigravityPool: isAgPoolFocused ? activeAgPool : nil,
                missingFilteredAntigravityPool: missingFilteredAgPool ? activeAgPool : nil,
                curveFootnoteAccountKey: showCurveInFootnote ? accountKey : nil,
                curveFootnoteSparkline: sparklinePoints,
                isCurveExpanded: isCurveExpanded
            )

            // Inline expandable Quota History & Burn-Rate Curve (zero extra card height when collapsed)
            if isCurveExpanded, let curveConfig {
                let series = store.quotaHistoryStore.analyze(
                    accountKey: accountKey,
                    range: selectedCurveRange,
                    preferredWindowIds: curveConfig.windowIds,
                    windowLabels: curveConfig.labels
                )
                QuotaCurvePanelView(
                    seriesList: series,
                    selectedRange: selectedCurveRange,
                    onSelectRange: { newRange in
                        withAnimation(OrbitMotion.pill) {
                            selectedCurveRange = newRange
                        }
                    },
                    poolBadgeText: curveConfig.poolBadge,
                    compact: isCompactCards || isNarrowLayout,
                    availableWidth: cardInnerWidth
                )
                .padding(.top, isCompactCards ? 2 : 3)
                .transition(OrbitMotion.panelTransition)
            }

            // Compact footer: source label + curve toggle + hover-revealed remove / inline confirmation
            if showStandaloneFooter {
                HStack(spacing: 6) {
                    if hasSourceBadge, let snap {
                        sourceBadge(snap.sourceLabel, isStale: snap.status.isStale)
                    }

                    Spacer(minLength: 4)

                    if canRemoveAccount && isConfirmingRemove {
                        inlineRemoveConfirmation(account: account, provider: provider)
                    } else {
                        if showCurveInStandaloneFooter {
                            curveTogglePill(
                                accountKey: accountKey,
                                sparklinePoints: sparklinePoints,
                                isExpanded: isCurveExpanded,
                                compact: isNarrowLayout
                            )
                        }
                        if canRemoveAccount {
                            hoverRemovePillButton(accountId: account.id, isHovered: isHovered)
                        }
                    }
                }
                .frame(minHeight: isCompactCards ? 14 : 16)
            }
        }
        .animation(OrbitMotion.snappy, value: isCurveExpanded)
        .padding(.horizontal, cardHPadding)
        .padding(.vertical, cardVPadding)
        .orbitCardStyle(
            cornerRadius: 11,
            isHighlighted: account.isActiveLive,
            highlightColor: .accentColor,
            hoverLift: true,
            onHoverChanged: { hovering in
                hoveredAccountId = hovering ? account.id : (hoveredAccountId == account.id ? nil : hoveredAccountId)
            }
        )
        .contextMenu {
            if !account.isActiveLive {
                Button(provider == .claude ? "设为新终端默认账号" : "切换为此账号") {
                    Task { await store.switchAccount(provider: provider, account: account) }
                }
                .disabled(store.busyActionLabel != nil)
            }
            if provider == .claude, let launchCmd = store.claudeLaunchCommand(for: account.id) {
                Button("复制登录命令（\(launchCmd)）") {
                    store.copyClaudeLaunchCommand(launchCmd)
                }
            }
            if canRemoveAccount {
                Button(provider == .claude ? "移除配置" : "移除账号", role: .destructive) {
                    withAnimation(OrbitMotion.snappy) {
                        confirmRemoveAccountId = account.id
                    }
                }
                .disabled(store.busyActionLabel != nil)
            }
        }
    }

    private func claudeProfileSlugBadge(_ slug: String, isDefault: Bool) -> some View {
        let tint: Color = isDefault ? Color(nsColor: .systemGreen) : Color(nsColor: .systemIndigo)
        let isDark = (colorScheme == .dark)
        return Text(slug)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(tint)
            .padding(.horizontal, 5.5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(isDark ? 0.18 : 0.12))
            .overlay(
                Capsule()
                    .strokeBorder(tint.opacity(isDark ? 0.34 : 0.24), lineWidth: 0.55)
            )
            .clipShape(Capsule())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .help(isDefault ? "默认 Claude CLI 配置（不可移除）" : "独立配置：CLAUDE_PROFILE=\(slug) claude")
    }

    private var inlineClaudeProfileCreatorCard: some View {
        let normalizedSlug = inlineClaudeProfileSlugDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isSlugValid = ClaudeProvider.isValidProfileSlug(normalizedSlug)
        let showValidationHint = !normalizedSlug.isEmpty && !isSlugValid
        let previewCommand = isSlugValid ? "CLAUDE_PROFILE=\(normalizedSlug) claude" : nil

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(nsColor: .systemGreen))
                Text("添加 Claude CLI 独立配置")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 4)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("配置别名（如 pro2）", text: $inlineClaudeProfileSlugDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
                    .onChange(of: inlineClaudeProfileSlugDraft) { _ in
                        inlineClaudeProfileError = nil
                    }

                TextField("备注名（可选，如 副号 Pro）", text: $inlineClaudeProfileLabelDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
            }

            if showValidationHint {
                Text("仅支持 1-32 位小写字母、数字及 . _ -，以字母或数字开头，不能为 default 或 desktop")
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let previewCommand {
                HStack(spacing: 4.5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(nsColor: .systemGreen))
                    Text(previewCommand)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.86))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .systemGreen).opacity(colorScheme == .dark ? 0.13 : 0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            if let errorText = inlineClaudeProfileError, !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Button("创建") {
                    let slugToCreate = normalizedSlug
                    let trimmedLabel = inlineClaudeProfileLabelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    let labelArg: String? = trimmedLabel.isEmpty ? nil : trimmedLabel
                    Task {
                        let res = await store.createClaudeCLIProfile(id: slugToCreate, label: labelArg)
                        switch res {
                        case .success:
                            withAnimation(OrbitMotion.snappy) {
                                inlineClaudeProfileSlugDraft = ""
                                inlineClaudeProfileLabelDraft = ""
                                inlineClaudeProfileError = nil
                                showInlineClaudeProfileCreator = false
                            }
                        case .failure(let err):
                            inlineClaudeProfileError = err.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!isSlugValid || store.busyActionLabel != nil)

                Button("取消") {
                    withAnimation(OrbitMotion.snappy) {
                        inlineClaudeProfileSlugDraft = ""
                        inlineClaudeProfileLabelDraft = ""
                        inlineClaudeProfileError = nil
                        showInlineClaudeProfileCreator = false
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer(minLength: 4)
            }

            Text("纯本地创建 ~/.claude-profiles/<别名> 隔离目录并复制去代理的 settings.json，不触碰 Claude 桌面端或钥匙串。")
                .font(.system(size: 9.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color(nsColor: .systemGreen).opacity(0.35), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func inlineRemoveConfirmation(account: AccountRecord, provider: ProviderID) -> some View {
        HStack(spacing: 5) {
            Text("确认移除？")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color(nsColor: .systemRed))

            Button("确定") {
                withAnimation(OrbitMotion.snappy) {
                    confirmRemoveAccountId = nil
                }
                Task { await store.removeAccount(provider: provider, account: account) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(nsColor: .systemRed))
            .controlSize(.mini)

            Button("取消") {
                withAnimation(OrbitMotion.snappy) {
                    confirmRemoveAccountId = nil
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    private func hoverRemovePillButton(accountId: String, isHovered: Bool) -> some View {
        Button {
            withAnimation(OrbitMotion.snappy) {
                confirmRemoveAccountId = accountId
            }
        } label: {
            Text("移除")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color(nsColor: .systemRed).opacity(0.92))
                .padding(.horizontal, 6.5)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color(nsColor: .systemRed).opacity(0.10))
                )
        }
        .orbitInteractiveButton(pressedScale: 0.94, hoverTint: nil, cornerRadius: 99)
        .disabled(store.busyActionLabel != nil)
        .opacity(isHovered ? 1.0 : 0.0)
        .allowsHitTesting(isHovered && store.busyActionLabel == nil)
        .animation(OrbitMotion.hover, value: isHovered)
    }

    private func accountAvatarView(for account: AccountRecord, tint: Color) -> some View {
        let initial = avatarInitial(for: account)
        let loadedImage = store.avatarImages[account.id]

        return ZStack {
            Circle()
                .fill(tint.opacity(0.18))
            Text(initial)
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .foregroundColor(tint)

            if let nsImage = loadedImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                    .transition(.opacity)
            }
        }
        .frame(width: 28, height: 28)
        .overlay(
            Circle()
                .stroke(
                    loadedImage != nil ? Color.primary.opacity(0.14) : Color.clear,
                    lineWidth: 0.75
                )
        )
        .animation(OrbitMotion.hover, value: loadedImage != nil)
        .onAppear {
            store.ensureAvatarLoaded(for: account)
        }
        .onChange(of: account.avatarURL) { _ in
            store.ensureAvatarLoaded(for: account)
        }
    }

    private func activeLiveBadge(for provider: ProviderID) -> some View {
        let labelText: String = {
            if provider == .claude {
                return "当前默认"
            }
            return isNarrowLayout ? "当前" : "当前使用"
        }()
        return HStack(spacing: 4) {
            OrbitPulseDot(color: Color(nsColor: .systemGreen), size: 5.5, isActive: true)
            Text(labelText)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(nsColor: .systemGreen))
        }
        .padding(.horizontal, isNarrowLayout ? 5.5 : 6.5)
        .padding(.vertical, isCompactCards ? 2 : 2.5)
        .background(Color(nsColor: .systemGreen).opacity(0.14))
        .clipShape(Capsule())
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var bestRemainingBadge: some View {
        HStack(spacing: 2.5) {
            Image(systemName: "crown.fill")
                .font(.system(size: 8.5))
            Text(isNarrowLayout ? "最多" : "余量最多")
                .font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundColor(Color(nsColor: .systemTeal))
        .padding(.horizontal, isNarrowLayout ? 5 : 6)
        .padding(.vertical, isCompactCards ? 2 : 2.5)
        .background(Color(nsColor: .systemTeal).opacity(0.14))
        .clipShape(Capsule())
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Window Cadence & Pool Grouping Helpers

    private enum WindowCadence: Int, Equatable {
        case fiveHour = 0
        case daily = 1
        case weekly = 2
        case monthly = 3
        case other = 4

        nonisolated init(from cadence: QuotaWindowCadence) {
            switch cadence {
            case .fiveHour: self = .fiveHour
            case .daily: self = .daily
            case .weekly: self = .weekly
            case .monthly: self = .monthly
            case .other: self = .other
            }
        }

        nonisolated var tagText: String? {
            switch self {
            case .fiveHour: return "5小时"
            case .daily: return "日"
            case .weekly: return "周"
            case .monthly: return "月"
            case .other: return nil
            }
        }

        nonisolated var matrixLabel: String? {
            switch self {
            case .fiveHour: return "5 小时"
            case .daily: return "每日"
            case .weekly: return "本周"
            case .monthly: return "本月"
            case .other: return nil
            }
        }

        nonisolated var compactMatrixLabel: String? {
            switch self {
            case .fiveHour: return "5h"
            case .daily: return "日"
            case .weekly: return "周"
            case .monthly: return "月"
            case .other: return nil
            }
        }

        var tint: Color {
            switch self {
            case .fiveHour: return Color(nsColor: .systemBlue)
            case .daily: return Color(nsColor: .systemTeal)
            case .weekly: return Color(nsColor: .systemPurple)
            case .monthly: return Color(nsColor: .systemIndigo)
            case .other: return Color.secondary
            }
        }
    }

    private struct ParsedWindowMeta {
        let window: QuotaWindow
        let poolName: String
        let cadence: WindowCadence
        let fallbackTileTitle: String
    }

    private struct AccountWindowGroup: Identifiable {
        let id: String
        let poolName: String?
        let items: [ParsedWindowMeta]
    }

    private func classifyCadence(for window: QuotaWindow) -> WindowCadence {
        WindowCadence(from: window.cadence)
    }

    private func filteredVisibleWindows(from windows: [QuotaWindow]) -> [QuotaWindow] {
        let cfg = accountCardConfig
        return windows.filter { window in
            switch window.cadence {
            case .fiveHour:
                return cfg.showFiveHour
            case .weekly:
                return cfg.showWeekly
            case .daily, .monthly, .other:
                return true
            }
        }
    }

    private func parseWindowMeta(_ window: QuotaWindow) -> ParsedWindowMeta {
        Self.parseWindowMetaStatic(window)
    }

    private nonisolated static func parseWindowMetaStatic(_ window: QuotaWindow) -> ParsedWindowMeta {
        let rawLabel = window.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cadence = WindowCadence(from: window.cadence)

        // Primary split convention shared by Antigravity & Codex extra limits: "<Pool> · <Cadence>"
        if let dotRange = rawLabel.range(of: " · ", options: .backwards) {
            let left = String(rawLabel[..<dotRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let right = String(rawLabel[dotRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !left.isEmpty {
                return ParsedWindowMeta(
                    window: window,
                    poolName: left,
                    cadence: cadence,
                    fallbackTileTitle: right.isEmpty ? rawLabel : right
                )
            }
        }

        // Strip trailing cadence token when present (e.g. "Argon 周额" -> "Argon", "5小时" -> "", "本周" -> "")
        let cadenceSuffixes = [
            "5小时限额", "5小时额度", "5小时", "5 小时", "5h",
            "每周限额", "每周额度", "本周限额", "本周额度", "周限额", "周额度", "周额", "本周", "每周", "7天额度", "7天限额", "7天", "周", "weekly",
            "每日限额", "每日额度", "每日", "24小时", "1天", "daily",
            "每月限额", "每月额度", "每月", "本月", "monthly",
        ]

        var stripped = rawLabel
        let lowerRaw = rawLabel.lowercased()
        for suffix in cadenceSuffixes {
            if lowerRaw == suffix.lowercased() {
                stripped = ""
                break
            }
            if lowerRaw.hasSuffix(" " + suffix.lowercased()) || lowerRaw.hasSuffix("·" + suffix.lowercased()) {
                stripped = String(rawLabel.dropLast(suffix.count + 1))
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "·-:/()（）")))
                break
            }
            if lowerRaw.hasSuffix("(\(suffix.lowercased()))") || lowerRaw.hasSuffix("（\(suffix.lowercased())）") {
                stripped = String(rawLabel.dropLast(suffix.count + 2))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        return ParsedWindowMeta(
            window: window,
            poolName: stripped,
            cadence: cadence,
            fallbackTileTitle: rawLabel
        )
    }

    private func groupAccountWindows(_ windows: [QuotaWindow]) -> [AccountWindowGroup] {
        let parsed = windows.map(parseWindowMeta)
        var groupIndexByKey: [String: Int] = [:]
        var groups: [(key: String, poolName: String?, items: [ParsedWindowMeta])] = []

        for meta in parsed {
            let normalizedPool = meta.poolName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedPool.isEmpty ? "__core__" : normalizedPool.lowercased()

            if let idx = groupIndexByKey[key], meta.cadence != .other {
                // Only merge into the same pool group when cadences differ (e.g. 5h + weekly).
                let existingCadences = Set(groups[idx].items.map(\.cadence))
                if !existingCadences.contains(meta.cadence) {
                    groups[idx].items.append(meta)
                    continue
                }
            }

            let uniqueKey = groupIndexByKey[key] == nil ? key : "\(key)#\(meta.window.id)"
            let newIdx = groups.count
            if groupIndexByKey[key] == nil {
                groupIndexByKey[key] = newIdx
            }
            groups.append((
                key: uniqueKey,
                poolName: normalizedPool.isEmpty ? nil : normalizedPool,
                items: [meta]
            ))
        }

        return groups.map { entry in
            let orderedItems = entry.items.count > 1
                ? entry.items.sorted { $0.cadence.rawValue < $1.cadence.rawValue }
                : entry.items
            return AccountWindowGroup(
                id: entry.key,
                poolName: entry.poolName,
                items: orderedItems
            )
        }
    }

    private var hiddenQuotaWindowsCompactRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.8))
            Text("已隐藏 5h / 周额度条")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button("开启") {
                showQuotaCustomizePopover = true
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, isCompactCards ? 3 : 4)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func missingAntigravityPoolRow(pool: AntigravityPoolPreference) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.slash")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary.opacity(0.75))
            Text("该账号不含 \(agPoolHumanName(pool)) 额度池")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 7.5)
        .padding(.vertical, isCompactCards ? 3.5 : 4.5)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.035))
        .overlay(
            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                .stroke(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06), lineWidth: 0.6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
    }

    @ViewBuilder
    private func accountQuotaBody(
        provider: ProviderID,
        snapshot: QuotaSnapshot?,
        visibleWindows: [QuotaWindow],
        focusFooter: (text: String, tooltip: String)?,
        showInlineRemoveOnFootnote: Bool,
        isHovered: Bool,
        accountId: String,
        focusedAntigravityPool: AntigravityPoolPreference? = nil,
        missingFilteredAntigravityPool: AntigravityPoolPreference? = nil,
        curveFootnoteAccountKey: String? = nil,
        curveFootnoteSparkline: [QuotaBurnPoint] = [],
        isCurveExpanded: Bool = false
    ) -> some View {
        if let snapshot {
            switch snapshot.status {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    Text("正在拉取配额...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 3)

            case .ready:
                if snapshot.windows.isEmpty && snapshot.balance == nil {
                    Text("已连接，暂无可用配额窗口数据")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    let groups = groupAccountWindows(visibleWindows)
                    let hasActivePoolFocus = (focusedAntigravityPool != nil)
                    VStack(alignment: .leading, spacing: isCompactCards ? 2.5 : 4) {
                        if let missingPool = missingFilteredAntigravityPool {
                            missingAntigravityPoolRow(pool: missingPool)
                        } else if groups.isEmpty && !snapshot.windows.isEmpty {
                            hiddenQuotaWindowsCompactRow
                        } else {
                            ForEach(groups) { group in
                                let isFocusedRow = hasActivePoolFocus
                                    && group.items.contains { store.isAntigravityWindowMatchingPool($0.window) }
                                accountMatrixGroupRows(
                                    group,
                                    isFocusedPool: isFocusedRow,
                                    hasPoolFocusContext: hasActivePoolFocus
                                )
                            }
                        }

                        if let focusFooter {
                            HStack(spacing: 5) {
                                Text(focusFooter.text)
                                    .font(.system(size: isCompactCards ? 10 : 10.5))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.82)
                                    .truncationMode(.tail)
                                    .help(focusFooter.tooltip)

                                Spacer(minLength: 2)

                                if showInlineRemoveOnFootnote && isHovered {
                                    hoverRemovePillButton(accountId: accountId, isHovered: isHovered)
                                }

                                if let curveKey = curveFootnoteAccountKey {
                                    curveTogglePill(
                                        accountKey: curveKey,
                                        sparklinePoints: curveFootnoteSparkline,
                                        isExpanded: isCurveExpanded,
                                        compact: isNarrowLayout
                                    )
                                }
                            }
                            .frame(minHeight: isCompactCards ? 14 : 16)
                            .padding(.top, isCompactCards ? 0.5 : 1)
                        }
                    }
                }

            case .reauthRequired(let message):
                statusMessageRow(icon: "key.slash.fill", color: Color(nsColor: .systemOrange), message: message)

            case .unconfigured(let message):
                if provider == .claude {
                    claudeUnconfiguredProfileBody(accountId: accountId, fallbackMessage: message)
                } else {
                    statusMessageRow(icon: "slider.horizontal.3", color: Color(nsColor: .systemOrange), message: message)
                }

            case .failed(let message):
                statusMessageRow(icon: "exclamationmark.triangle.fill", color: Color(nsColor: .systemRed), message: message)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                Text("尚未获取配额，点击右上角刷新")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func claudeUnconfiguredProfileBody(accountId: String, fallbackMessage: String) -> some View {
        let launchCommand = store.claudeLaunchCommand(for: accountId)
        let isCopied = (recentlyCopiedClaudeAccountId == accountId)
        let hasLoggedInEmail = store.accounts(for: .claude)
            .first(where: { $0.id == accountId })
            .map { !$0.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        let green = Color(nsColor: .systemGreen)
        let isDark = (colorScheme == .dark)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 10.5))
                    .foregroundColor(green)
                    .padding(.top, 1.5)
                Text(
                    launchCommand != nil
                        ? (hasLoggedInEmail
                            ? "已登录 · 在该终端发一条消息或输入 /usage 后自动同步余量"
                            : "在终端运行后执行 /login 即可自动同步余量")
                        : fallbackMessage
                )
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let launchCommand {
                HStack(spacing: 6) {
                    Text(launchCommand)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Spacer(minLength: 4)

                    Button {
                        store.copyClaudeLaunchCommand(launchCommand)
                        recentlyCopiedClaudeAccountId = accountId
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            if recentlyCopiedClaudeAccountId == accountId {
                                recentlyCopiedClaudeAccountId = nil
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 9, weight: .semibold))
                            Text(isCopied ? "已复制" : "复制命令")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(isCopied ? green : .accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule()
                                .fill((isCopied ? green : Color.accentColor).opacity(isDark ? 0.18 : 0.12))
                        )
                    }
                    .orbitInteractiveButton(pressedScale: 0.94, hoverTint: nil, cornerRadius: 99)
                    .help("复制 \(launchCommand)")
                }
                .padding(.horizontal, 7.5)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(isDark ? 0.06 : 0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.primary.opacity(isDark ? 0.11 : 0.08), lineWidth: 0.65)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(7.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(green.opacity(isDark ? 0.09 : 0.065))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(green.opacity(isDark ? 0.24 : 0.18), lineWidth: 0.65)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func accountMatrixGroupRows(
        _ group: AccountWindowGroup,
        isFocusedPool: Bool = false,
        hasPoolFocusContext: Bool = false
    ) -> some View {
        let poolTitle = (group.poolName?.isEmpty == false) ? group.poolName! : "主额度"
        let rowChunks: [[ParsedWindowMeta]] = stride(from: 0, to: group.items.count, by: 2).map { start in
            Array(group.items[start..<min(start + 2, group.items.count)])
        }
        let baseLabelWidth: CGFloat = isNarrowLayout ? 54 : (popoverWidth < 410 ? 64 : 74)
        let poolLabelWidth: CGFloat = hasPoolFocusContext ? (baseLabelWidth + 5) : baseLabelWidth
        let rowGap: CGFloat = isNarrowLayout ? 4 : 6
        let cellGap: CGFloat = isNarrowLayout ? 6 : (popoverWidth < 410 ? 8 : 10)
        let isDark = (colorScheme == .dark)

        ForEach(Array(rowChunks.enumerated()), id: \.offset) { chunkIdx, chunk in
            HStack(alignment: .center, spacing: rowGap) {
                if chunkIdx == 0 {
                    HStack(spacing: 4) {
                        if isFocusedPool {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 4.5, height: 4.5)
                        }
                        Text(poolTitle)
                            .font(.system(
                                size: isNarrowLayout ? 10.5 : 11,
                                weight: isFocusedPool ? .semibold : .medium
                            ))
                            .foregroundColor(
                                isFocusedPool
                                    ? .primary
                                    : (hasPoolFocusContext ? .primary.opacity(0.68) : .primary.opacity(0.86))
                            )
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(width: poolLabelWidth, alignment: .leading)
                    .help(isFocusedPool ? "\(poolTitle)（当前追踪池）" : poolTitle)
                } else {
                    Color.clear
                        .frame(width: poolLabelWidth, height: 1)
                }

                if chunk.count == 2 {
                    HStack(alignment: .center, spacing: cellGap) {
                        matrixWindowCell(
                            chunk[0],
                            poolTitle: poolTitle,
                            labelWidth: matrixLabelWidth(for: chunk[0].cadence, narrow: isNarrowLayout),
                            compactLabel: isNarrowLayout
                        )
                        .frame(maxWidth: .infinity)

                        matrixWindowCell(
                            chunk[1],
                            poolTitle: poolTitle,
                            labelWidth: matrixLabelWidth(for: chunk[1].cadence, narrow: isNarrowLayout),
                            compactLabel: isNarrowLayout
                        )
                        .frame(maxWidth: .infinity)
                    }
                } else if let only = chunk.first {
                    matrixWindowCell(
                        only,
                        poolTitle: poolTitle,
                        labelWidth: matrixLabelWidth(for: only.cadence, narrow: isNarrowLayout),
                        compactLabel: isNarrowLayout
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(minHeight: isCompactCards ? 13 : 15)
            .background {
                if isFocusedPool {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.accentColor.opacity(isDark ? 0.13 : 0.075))
                        .padding(.horizontal, -4)
                        .padding(.vertical, -1.5)
                }
            }
        }
    }

    private func matrixLabelWidth(for cadence: WindowCadence, narrow: Bool) -> CGFloat {
        if narrow {
            switch cadence {
            case .fiveHour: return 17
            case .daily, .weekly, .monthly: return 14
            case .other: return 22
            }
        }
        switch cadence {
        case .fiveHour: return 32
        case .daily, .weekly, .monthly: return 24
        case .other: return 30
        }
    }

    private func matrixWindowCell(
        _ item: ParsedWindowMeta,
        poolTitle: String,
        labelWidth: CGFloat,
        compactLabel: Bool
    ) -> some View {
        let window = item.window
        let showRemaining = settings.showRemainingPercent
        let fillFraction = showRemaining ? window.remainingFraction : (1.0 - window.remainingFraction)
        let barColor = OrbitTheme.quotaColor(remainingFraction: window.remainingFraction, warnThreshold: warnThreshold)
        let pctText = Formatters.percentString(remainingFraction: window.remainingFraction, showRemaining: showRemaining)
        let pctColor: Color = window.remainingFraction <= warnThreshold
            ? Color(nsColor: .systemRed)
            : Color.primary.opacity(0.86)
        let cadenceLabel = cadenceMatrixLabel(for: item, poolTitle: poolTitle, compact: compactLabel)
        let fullCadenceLabel = cadenceMatrixLabel(for: item, poolTitle: poolTitle, compact: false)

        return HStack(alignment: .center, spacing: compactLabel ? 3 : 4) {
            Text(cadenceLabel)
                .font(.system(size: compactLabel ? 10 : 10.5, weight: .regular))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: labelWidth, alignment: .leading)

            OrbitAnimatedProgressBar(
                fraction: fillFraction,
                tint: barColor,
                trackColor: Color.primary.opacity(0.085),
                height: isCompactCards ? 4 : 5,
                minFillWidth: 3.5
            )

            Text(pctText)
                .font(.system(size: compactLabel ? 10.5 : 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .orbitNumericTransition()
                .foregroundColor(pctColor)
                .lineLimit(1)
                .minimumScaleFactor(0.88)
                .frame(width: compactLabel ? 30 : 33, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .help(windowTooltip(window, poolTitle: poolTitle, cadenceLabel: fullCadenceLabel))
    }

    private func cadenceMatrixLabel(
        for item: ParsedWindowMeta,
        poolTitle: String,
        compact: Bool = false
    ) -> String {
        Self.cadenceMatrixLabelStatic(for: item, poolTitle: poolTitle, compact: compact)
    }

    private nonisolated static func cadenceMatrixLabelStatic(
        for item: ParsedWindowMeta,
        poolTitle: String,
        compact: Bool = false
    ) -> String {
        if compact, let shortLabel = item.cadence.compactMatrixLabel {
            return shortLabel
        }
        if let label = item.cadence.matrixLabel {
            return label
        }
        let fallback = item.fallbackTileTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if fallback.isEmpty || fallback == poolTitle {
            return "额度"
        }
        return fallback
    }

    private func windowTooltip(_ window: QuotaWindow, poolTitle: String, cadenceLabel: String) -> String {
        let title = (cadenceLabel == poolTitle) ? poolTitle : "\(poolTitle) · \(cadenceLabel)"
        var parts: [String] = [
            title,
            "剩余 \(window.remainingPercent)%（已用 \(Int(window.computedUsedPercent.rounded()))%）",
        ]
        if let resetAt = window.resetAt {
            let rel = Formatters.relativeResetString(to: resetAt)
            let abs = Formatters.absoluteResetString(resetAt)
            if !rel.isEmpty && !abs.isEmpty {
                parts.append("重置：\(rel)（\(abs)）")
            } else if !rel.isEmpty {
                parts.append("重置：\(rel)")
            }
        }
        if let detail = window.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            parts.append(detail)
        }
        return parts.joined(separator: "\n")
    }

    private func focusFooterSummary(
        for snapshot: QuotaSnapshot,
        visibleWindows: [QuotaWindow],
        preferredAntigravityPool: AntigravityPoolPreference = .autoLowest,
        strictPoolFilter: Bool = false
    ) -> (text: String, tooltip: String)? {
        Self.buildFocusFooterSummary(
            for: snapshot,
            visibleWindows: visibleWindows,
            preferredAntigravityPool: preferredAntigravityPool,
            strictPoolFilter: strictPoolFilter,
            popoverWidth: popoverWidth,
            showResetRelative: settings.showResetRelative
        )
    }

    /// Builds the single-line card reset footnote (displaying both `5h` and `周`/`月` countdowns when both exist
    /// in the focused pool/card) along with the full multi-window tooltip.
    public nonisolated static func buildFocusFooterSummary(
        for snapshot: QuotaSnapshot,
        visibleWindows: [QuotaWindow],
        preferredAntigravityPool: AntigravityPoolPreference = .autoLowest,
        strictPoolFilter: Bool = false,
        popoverWidth: CGFloat = CGFloat(AppSettings.defaultPopoverWidth),
        showResetRelative: Bool = true,
        now: Date = Date()
    ) -> (text: String, tooltip: String)? {
        let isAntigravity = (snapshot.provider == .antigravity)
        let baseWindows: [QuotaWindow]
        if isAntigravity && strictPoolFilter && preferredAntigravityPool != .autoLowest {
            baseWindows = visibleWindows.isEmpty
                ? snapshot.windows.filter { AppStore.isAntigravityWindowMatchingPool($0, pool: preferredAntigravityPool) }
                : visibleWindows
        } else {
            baseWindows = visibleWindows.isEmpty ? snapshot.windows : visibleWindows
        }

        let allResetWindows = baseWindows.filter { $0.resetAt != nil }

        func selectLowestAnchor(from candidates: [QuotaWindow]) -> QuotaWindow? {
            let nonFull = candidates.filter { $0.remainingFraction < 0.999 }
            let searchPool = nonFull.isEmpty ? candidates : nonFull
            return searchPool.min { lhs, rhs in
                if abs(lhs.remainingFraction - rhs.remainingFraction) > 0.005 {
                    return lhs.remainingFraction < rhs.remainingFraction
                }
                if nonFull.isEmpty && lhs.isPrimary != rhs.isPrimary {
                    return lhs.isPrimary && !rhs.isPrimary
                }
                let lDate = lhs.resetAt ?? .distantFuture
                let rDate = rhs.resetAt ?? .distantFuture
                if lDate != rDate {
                    return lDate < rDate
                }
                return lhs.isPrimary && !rhs.isPrimary
            }
        }

        func lockPoolWindows(for anchor: QuotaWindow, in candidates: [QuotaWindow]) -> [QuotaWindow] {
            if let kind = anchor.antigravityPoolKind {
                return candidates.filter { $0.antigravityPoolKind == kind }
            }
            let anchorPool = parseWindowMetaStatic(anchor).poolName
            return candidates.filter {
                parseWindowMetaStatic($0).poolName.caseInsensitiveCompare(anchorPool) == .orderedSame
            }
        }

        let scopedResetWindows: [QuotaWindow]
        let poolPrefix: String?

        if isAntigravity {
            if preferredAntigravityPool != .autoLowest {
                let preferredMatches = allResetWindows.filter {
                    AppStore.isAntigravityWindowMatchingPool($0, pool: preferredAntigravityPool)
                }
                if !preferredMatches.isEmpty {
                    scopedResetWindows = preferredMatches
                } else if strictPoolFilter {
                    scopedResetWindows = []
                } else if let anchor = selectLowestAnchor(from: allResetWindows) {
                    scopedResetWindows = lockPoolWindows(for: anchor, in: allResetWindows)
                } else {
                    scopedResetWindows = []
                }
            } else if let anchor = selectLowestAnchor(from: allResetWindows) {
                scopedResetWindows = lockPoolWindows(for: anchor, in: allResetWindows)
            } else {
                scopedResetWindows = []
            }

            if let explicitPool = scopedResetWindows
                .map({ parseWindowMetaStatic($0).poolName })
                .first(where: { !$0.isEmpty }) {
                poolPrefix = explicitPool
            } else if let kind = scopedResetWindows.first?.antigravityPoolKind {
                switch kind {
                case .gemini: poolPrefix = "Gemini"
                case .claude: poolPrefix = "Claude / GPT"
                case .argon: poolPrefix = "Argon"
                case .autoLowest: poolPrefix = nil
                }
            } else {
                poolPrefix = nil
            }
        } else {
            poolPrefix = nil
            if snapshot.provider == .codex {
                let coreOnly = allResetWindows.filter { !$0.id.lowercased().hasPrefix("add_") }
                scopedResetWindows = coreOnly.isEmpty ? allResetWindows : coreOnly
            } else {
                scopedResetWindows = allResetWindows
            }
        }

        var segments: [String] = []

        if !scopedResetWindows.isEmpty {
            let fiveHourReset = scopedResetWindows
                .filter { $0.cadence == .fiveHour }
                .compactMap(\.resetAt)
                .min()

            let weeklyWindows = scopedResetWindows.filter { $0.cadence == .weekly }
            let monthlyWindows = scopedResetWindows.filter { $0.cadence == .monthly }
            let longCadenceWindows = !weeklyWindows.isEmpty ? weeklyWindows : monthlyWindows
            let longCadenceTag = (!weeklyWindows.isEmpty || monthlyWindows.isEmpty) ? "周" : "月"
            let weeklyReset = longCadenceWindows.compactMap(\.resetAt).min()

            if let fiveHourReset, let weeklyReset {
                let isCompactWidth = (popoverWidth < 370)
                let dualBody: String
                if showResetRelative {
                    if isCompactWidth {
                        let c5h = Formatters.compactResetCountdown(to: fiveHourReset, now: now) ?? ""
                        let cLong = Formatters.compactResetCountdown(to: weeklyReset, now: now) ?? ""
                        let longPart = (cLong == "即将重置") ? cLong : "\(cLong) 后重置"
                        dualBody = "5h \(c5h) · \(longCadenceTag) \(longPart)"
                    } else {
                        let full5h = Formatters.relativeResetString(to: fiveHourReset, now: now)
                        let short5h = full5h.hasSuffix("后重置") ? String(full5h.dropLast(3)) : full5h
                        let fullLong = Formatters.relativeResetString(to: weeklyReset, now: now)
                        dualBody = "5h \(short5h) · \(longCadenceTag) \(fullLong)"
                    }
                } else {
                    let abs5h = Formatters.absoluteResetString(fiveHourReset)
                    let short5h = abs5h.hasSuffix(" 重置") ? String(abs5h.dropLast(3)) : abs5h
                    let absLong = Formatters.absoluteResetString(weeklyReset)
                    dualBody = "5h \(short5h) · \(longCadenceTag) \(absLong)"
                }

                if let poolPrefix, !poolPrefix.isEmpty {
                    segments.append("\(poolPrefix) · \(dualBody)")
                } else {
                    segments.append(dualBody)
                }
            } else if let singleFocus = selectLowestAnchor(from: scopedResetWindows),
                      let resetAt = singleFocus.resetAt {
                let meta = parseWindowMetaStatic(singleFocus)
                let effectivePool = (poolPrefix?.isEmpty == false) ? poolPrefix! : meta.poolName
                let shortCad = meta.cadence.compactMatrixLabel
                    ?? cadenceMatrixLabelStatic(
                        for: meta,
                        poolTitle: effectivePool.isEmpty ? "主额度" : effectivePool,
                        compact: true
                    )
                let focusTitle: String
                if effectivePool.isEmpty {
                    focusTitle = shortCad
                } else if shortCad.isEmpty || effectivePool == shortCad || effectivePool.contains(shortCad) {
                    focusTitle = effectivePool
                } else {
                    focusTitle = "\(effectivePool) \(shortCad)"
                }
                let resetText = Formatters.resetDisplayString(resetAt, relative: showResetRelative, now: now)
                if !resetText.isEmpty {
                    segments.append("\(focusTitle) · \(resetText)")
                }
            }
        }

        if let balance = snapshot.balance {
            let balDetail = balance.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (balDetail?.isEmpty == false && balDetail!.count <= 12) ? balDetail! : "Credits"
            segments.append("\(label) \(AppStore.exactCurrencyString(balance))")
        }

        if let pace = snapshot.paceNote?.trimmingCharacters(in: .whitespacesAndNewlines), !pace.isEmpty {
            segments.append(pace)
        }

        guard !segments.isEmpty else { return nil }

        var tooltipLines: [String] = []
        for win in snapshot.windows {
            let meta = parseWindowMetaStatic(win)
            let poolTitle = meta.poolName.isEmpty ? "主额度" : meta.poolName
            let cadLabel = cadenceMatrixLabelStatic(for: meta, poolTitle: poolTitle)
            let title = (cadLabel == poolTitle) ? poolTitle : "\(poolTitle) \(cadLabel)"
            if let resetAt = win.resetAt {
                let rel = Formatters.relativeResetString(to: resetAt, now: now)
                let abs = Formatters.absoluteResetString(resetAt)
                tooltipLines.append("\(title)：\(win.remainingPercent)% · \(rel)（\(abs)）")
            } else {
                tooltipLines.append("\(title)：\(win.remainingPercent)%")
            }
        }
        if let balance = snapshot.balance {
            tooltipLines.append("Credits：\(AppStore.exactCurrencyString(balance))")
        }
        if let pace = snapshot.paceNote?.trimmingCharacters(in: .whitespacesAndNewlines), !pace.isEmpty {
            tooltipLines.append(pace)
        }

        return (segments.joined(separator: " · "), tooltipLines.joined(separator: "\n"))
    }

    private func cadenceTagBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundColor(tint)
            .padding(.horizontal, 5.5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.13))
            .clipShape(Capsule())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func emptySwitchableAccountsCard(for provider: ProviderID) -> some View {
        VStack(spacing: 10) {
            ProviderBrandIconView(
                provider: provider,
                size: 28,
                renderingAccent: .secondary
            )
            Text(provider == .claude ? "尚未检测到 Claude CLI 配置" : "尚未添加 \(provider.displayName) 账号")
                .font(.system(size: 13, weight: .semibold))
            Text(
                provider == .claude
                    ? "点击下方「+ 添加配置」创建独立配置，或在终端使用 Claude CLI 回复 / 输入 /usage 后自动同步余量。"
                    : "点击下方「+ 添加账号」进行授权登录，或点击「导入当前」将本机正在使用的账号纳入管理。"
            )
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 16)
        .orbitCardStyle(cornerRadius: 11, hoverLift: false)
    }

    // MARK: - Single-Provider CodexBar-Style Card (Grok, Cursor, Kimi, DeepSeek)

    @ViewBuilder
    private func singleProviderContent(for provider: ProviderID) -> some View {
        let account = store.primaryAccount(for: provider)
        let snap = store.primarySnapshot(for: provider)
        let plan = snap?.plan ?? account?.plan
        let cfg = accountCardConfig
        let cardSpacing: CGFloat = isCompactCards ? 8.5 : 12
        let cardPadding: CGFloat = isCompactCards ? (isNarrowLayout ? 9 : 10) : (isNarrowLayout ? 11 : 13)
        let iconBoxSize: CGFloat = isCompactCards ? 30 : 34
        let iconSize: CGFloat = isCompactCards ? 18 : 20

        VStack(alignment: .leading, spacing: cardSpacing) {
            // Top header
            HStack(spacing: isNarrowLayout ? 8 : 10) {
                if cfg.showAvatar {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(
                                ProviderBrandIcon.isTemplateMark(for: provider)
                                    ? Color.accentColor.opacity(0.13)
                                    : Color.primary.opacity(0.055)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(Color.primary.opacity(0.075), lineWidth: 0.6)
                            )
                            .frame(width: iconBoxSize, height: iconBoxSize)
                        ProviderBrandIconView(
                            provider: provider,
                            size: iconSize,
                            renderingAccent: .accentColor
                        )
                    }
                }

                VStack(alignment: .leading, spacing: isCompactCards ? 1 : 2) {
                    HStack(spacing: 6) {
                        Text(provider.displayName)
                            .font(.system(size: isCompactCards ? 13 : 14, weight: .bold))
                            .lineLimit(1)
                        if let plan, plan.kind != .unknown {
                            planBadge(plan)
                        }
                    }

                    let subtitle = resolvedSingleProviderSubtitle(provider: provider, account: account)
                    Text(subtitle)
                        .font(.system(size: isCompactCards ? 10.5 : 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                if cfg.showSourceBadge, let snap, !snap.sourceLabel.isEmpty {
                    sourceBadge(snap.sourceLabel, isStale: snap.status.isStale)
                }
            }

            if provider == .claude {
                claudePassiveSafetyPill
            }

            Divider().opacity(0.35)

            // Main Hero + Progress Bars
            if let snap {
                switch snap.status {
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在获取 \(provider.displayName) 最新配额...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)

                case .ready(let fetchedAt, _):
                    readySingleProviderBody(provider: provider, snapshot: snap, fetchedAt: fetchedAt)

                case .unconfigured(let message):
                    unconfiguredRecoveryCard(provider: provider, message: message)

                case .reauthRequired(let message):
                    errorRecoveryCard(provider: provider, icon: "key.slash.fill", tint: Color(nsColor: .systemOrange), title: "需要重新授权", message: message)

                case .failed(let message):
                    errorRecoveryCard(provider: provider, icon: "exclamationmark.triangle.fill", tint: Color(nsColor: .systemRed), title: "获取配额失败", message: message)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise.circle")
                        .foregroundColor(.secondary)
                    Text("等待刷新 \(provider.displayName) 配额数据")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
            }

            // Inline API Key quick editor (Kimi / DeepSeek)
            if provider.supportsAPIKeyConfig && showInlineAPIKeyEditor {
                inlineAPIKeyEditorCard(for: provider)
                    .transition(OrbitMotion.panelTransition)
            }
        }
        .padding(cardPadding)
        .orbitCardStyle(
            cornerRadius: 12,
            isHighlighted: false,
            hoverLift: false
        )
        .animation(OrbitMotion.snappy, value: showInlineAPIKeyEditor)
    }

    private var claudePassiveSafetyPill: some View {
        let green = Color(nsColor: .systemGreen)
        let isDark = (colorScheme == .dark)
        return HStack(spacing: 4.5) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(green)
            Text("纯本地被动 · 零联网 · 不碰桌面端")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isDark ? green.opacity(0.95) : green.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.84)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(green.opacity(isDark ? 0.14 : 0.10))
        .overlay(
            Capsule()
                .strokeBorder(green.opacity(isDark ? 0.34 : 0.24), lineWidth: 0.65)
        )
        .clipShape(Capsule())
        .help("仅离线读取 ~/.config/pulsar/claude-cli-profiles.json、独立配置目录 .claude.json 与 ~/.cache/pulsar/claude-cli-quotas/，零网络请求、零钥匙串读取、不触碰 Claude 桌面端")
    }

    @ViewBuilder
    private func readySingleProviderBody(provider: ProviderID, snapshot: QuotaSnapshot, fetchedAt: Date) -> some View {
        let _ = store.quotaHistoryRevision
        let cfg = accountCardConfig
        let visibleWindows = filteredVisibleWindows(from: snapshot.windows)
        let primaryWindow = visibleWindows.first(where: { $0.isPrimary }) ?? visibleWindows.first
        let heroFontSize: CGFloat = isCompactCards ? 25 : 30
        let accountKey = QuotaHistoryStore.accountKey(provider: provider, accountId: snapshot.accountId)
        let canShowCurve = !snapshot.windows.isEmpty
        let isCurveExpanded = canShowCurve && expandedCurveAccountKeys.contains(accountKey)
        let curveConfig = curveWindowSelection(for: snapshot, preferredAntigravityPool: .autoLowest)
        let sparklinePoints: [QuotaBurnPoint] = {
            guard canShowCurve else { return [] }
            let previewSeries = store.quotaHistoryStore.analyze(
                accountKey: accountKey,
                range: .hours24,
                preferredWindowIds: curveConfig.windowIds,
                windowLabels: curveConfig.labels
            )
            return previewSeries.first(where: { $0.points.count >= 2 })?.points
                ?? previewSeries.first?.points
                ?? []
        }()
        let singleCardPad: CGFloat = isCompactCards ? (isNarrowLayout ? 9 : 10) : (isNarrowLayout ? 11 : 13)
        let cardInnerWidth = max(240, popoverWidth - (isNarrowLayout ? 18 : 24) - singleCardPad * 2)

        VStack(alignment: .leading, spacing: isCompactCards ? 8 : 12) {
            if snapshot.windows.isEmpty, let balance = snapshot.balance {
                // Hero Balance Display for pure balance providers (e.g. DeepSeek)
                VStack(alignment: .leading, spacing: isCompactCards ? 4 : 6) {
                    Text("可用余额")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(AppStore.exactCurrencyString(balance))
                            .font(.system(size: heroFontSize, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .orbitNumericTransition()
                            .foregroundColor(balance.totalBalance > 0 ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed))

                        Text(balance.currency.uppercased())
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: isNarrowLayout ? 8 : 12) {
                        if let toppedUp = balance.toppedUpBalance {
                            Label(
                                "充值 \(AppStore.exactCurrencyString(amount: toppedUp, currency: balance.currency))",
                                systemImage: "creditcard"
                            )
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        }
                        if let granted = balance.grantedBalance {
                            Label(
                                "赠送 \(AppStore.exactCurrencyString(amount: granted, currency: balance.currency))",
                                systemImage: "gift"
                            )
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        }
                    }

                    if let extraDetail = nonRedundantBalanceDetail(balance, paceNote: snapshot.paceNote) {
                        Text(extraDetail)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if let primary = primaryWindow {
                // Hero Remaining Percentage Display (Cursor / Grok / Kimi)
                let showRemaining = settings.showRemainingPercent
                let pctValue = showRemaining ? primary.remainingPercent : (100 - primary.remainingPercent)
                let heroColor = OrbitTheme.quotaColor(remainingFraction: primary.remainingFraction, warnThreshold: warnThreshold)
                let primaryCadence = nonRedundantCadenceBadge(for: primary, title: primary.label)

                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(primary.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            if let cadence = primaryCadence, let tag = cadence.tagText {
                                cadenceTagBadge(tag, tint: cadence.tint)
                            }
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("\(pctValue)%")
                                .font(.system(size: heroFontSize, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .orbitNumericTransition()
                                .foregroundColor(heroColor)
                            Text(showRemaining ? "剩余可用" : "已使用")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if cfg.showResetFootnote {
                        let resetText = Formatters.resetDisplayString(
                            primary.resetAt,
                            relative: settings.showResetRelative
                        )
                        if !resetText.isEmpty {
                            Text(resetText)
                                .font(.system(size: 10.5, weight: .medium))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.06))
                                .clipShape(Capsule())
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }

            // Visible Quota Windows / Lanes (honors showFiveHour / showWeekly while preserving non-5h/weekly lanes)
            if !snapshot.windows.isEmpty {
                if visibleWindows.isEmpty {
                    hiddenQuotaWindowsCompactRow
                } else {
                    VStack(alignment: .leading, spacing: isCompactCards ? 5.5 : 8) {
                        if visibleWindows.count >= 2 {
                            HStack {
                                Text("配额通道明细")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(visibleWindows.count) 项")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                            }
                        }

                        ForEach(visibleWindows) { window in
                            let cadence = nonRedundantCadenceBadge(for: window, title: window.label)
                            quotaWindowProgressRow(
                                window,
                                displayTitle: window.label,
                                cadenceBadge: cadence,
                                showDetail: true,
                                contained: visibleWindows.count >= 2,
                                highlightPrimary: visibleWindows.count >= 2 && window.isPrimary
                            )
                        }
                    }
                }
            }

            // Supplementary Balance / Spend / Credits Card when windows are ALSO present (e.g. Cursor On-Demand / Credits)
            if !snapshot.windows.isEmpty, let balance = snapshot.balance {
                supplementaryBalanceCard(balance, compact: isCompactCards)
            }

            if let pace = snapshot.paceNote, !pace.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .padding(.top, 1.5)
                    Text(pace)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if cfg.showResetFootnote,
               let dualFootnote = focusFooterSummary(for: snapshot, visibleWindows: visibleWindows),
               (provider == .claude || visibleWindows.filter({ $0.resetAt != nil }).count >= 2) {
                HStack(spacing: 4.5) {
                    Image(systemName: "clock")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.85))
                    Text(dualFootnote.text)
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                .help(dualFootnote.tooltip)
            }

            if isCurveExpanded {
                let series = store.quotaHistoryStore.analyze(
                    accountKey: accountKey,
                    range: selectedCurveRange,
                    preferredWindowIds: curveConfig.windowIds,
                    windowLabels: curveConfig.labels
                )
                QuotaCurvePanelView(
                    seriesList: series,
                    selectedRange: selectedCurveRange,
                    onSelectRange: { newRange in
                        withAnimation(OrbitMotion.pill) {
                            selectedCurveRange = newRange
                        }
                    },
                    poolBadgeText: curveConfig.poolBadge,
                    compact: isCompactCards || isNarrowLayout,
                    availableWidth: cardInnerWidth
                )
                .transition(OrbitMotion.panelTransition)
            }

            HStack(spacing: 6) {
                Text("最近同步：\(store.relativeTimeAgoString(since: fetchedAt))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if canShowCurve {
                    curveTogglePill(
                        accountKey: accountKey,
                        sparklinePoints: sparklinePoints,
                        isExpanded: isCurveExpanded,
                        compact: isNarrowLayout
                    )
                }
                if provider.supportsAPIKeyConfig {
                    let configured = store.apiKeyConfiguredMap[provider] ?? false
                    Text(configured ? "密钥状态：已配置" : "密钥状态：未配置")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(configured ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
                        .lineLimit(1)
                }
            }
        }
        .animation(OrbitMotion.snappy, value: isCurveExpanded)
    }

    // MARK: - Quota Curve Helpers & Toggle Pill

    private func curveWindowSelection(
        for snapshot: QuotaSnapshot,
        preferredAntigravityPool: AntigravityPoolPreference
    ) -> (windowIds: [String], labels: [String: String], poolBadge: String?) {
        var labels: [String: String] = [:]
        for w in snapshot.windows {
            labels[w.id] = w.label
        }

        if snapshot.provider == .antigravity {
            let scopedWindows: [QuotaWindow]
            let resolvedPool: AntigravityPoolPreference?

            if preferredAntigravityPool != .autoLowest {
                let matched = snapshot.windows.filter {
                    AppStore.isAntigravityWindowMatchingPool($0, pool: preferredAntigravityPool)
                }
                if !matched.isEmpty {
                    scopedWindows = matched
                    resolvedPool = preferredAntigravityPool
                } else {
                    scopedWindows = snapshot.windows
                    resolvedPool = nil
                }
            } else {
                let nonFull = snapshot.windows.filter { $0.remainingFraction < 0.999 }
                let anchorPool = nonFull.isEmpty ? snapshot.windows : nonFull
                let anchor = anchorPool.min { lhs, rhs in
                    if abs(lhs.remainingFraction - rhs.remainingFraction) > 0.005 {
                        return lhs.remainingFraction < rhs.remainingFraction
                    }
                    return lhs.isPrimary && !rhs.isPrimary
                }
                if let anchorKind = anchor?.antigravityPoolKind {
                    scopedWindows = snapshot.windows.filter { $0.antigravityPoolKind == anchorKind }
                    resolvedPool = anchorKind
                } else {
                    scopedWindows = snapshot.windows
                    resolvedPool = nil
                }
            }

            let ordered = scopedWindows.sorted { lhs, rhs in
                if lhs.cadence.rawValue != rhs.cadence.rawValue {
                    return lhs.cadence.rawValue < rhs.cadence.rawValue
                }
                return lhs.isPrimary && !rhs.isPrimary
            }
            let badge: String? = resolvedPool.map { agPoolHumanName($0) }
            return (Array(ordered.prefix(2).map(\.id)), labels, badge)
        }

        if snapshot.provider == .codex {
            let core = snapshot.windows.filter { !$0.id.lowercased().hasPrefix("add_") }
            let base = core.isEmpty ? snapshot.windows : core
            let ordered = base.sorted { lhs, rhs in
                if lhs.cadence.rawValue != rhs.cadence.rawValue {
                    return lhs.cadence.rawValue < rhs.cadence.rawValue
                }
                return lhs.isPrimary && !rhs.isPrimary
            }
            return (Array(ordered.prefix(2).map(\.id)), labels, nil)
        }

        let ordered = snapshot.windows.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary {
                return lhs.isPrimary && !rhs.isPrimary
            }
            return lhs.cadence.rawValue < rhs.cadence.rawValue
        }
        return (Array(ordered.prefix(2).map(\.id)), labels, nil)
    }

    private func curveTogglePill(
        accountKey: String,
        sparklinePoints: [QuotaBurnPoint],
        isExpanded: Bool,
        compact: Bool
    ) -> some View {
        let isDark = (colorScheme == .dark)
        let accentTint = Color(red: 0.23, green: 0.51, blue: 0.96)
        let hasSparkline = sparklinePoints.count >= 2

        return Button {
            withAnimation(OrbitMotion.snappy) {
                if expandedCurveAccountKeys.contains(accountKey) {
                    expandedCurveAccountKeys.remove(accountKey)
                } else {
                    expandedCurveAccountKeys.insert(accountKey)
                }
            }
        } label: {
            HStack(spacing: compact ? 3 : 4) {
                if hasSparkline {
                    QuotaMiniSparklineView(
                        points: sparklinePoints,
                        tint: isExpanded ? .accentColor : accentTint
                    )
                    .frame(width: 28, height: 12)
                } else {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(isExpanded ? .accentColor : .secondary)
                }

                Text("曲线")
                    .font(.system(size: compact ? 9 : 9.5, weight: isExpanded ? .semibold : .medium))
                    .foregroundColor(isExpanded ? .accentColor : .secondary)
                    .lineLimit(1)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundColor(isExpanded ? .accentColor : .secondary.opacity(0.8))
            }
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(
                        isExpanded
                            ? Color.accentColor.opacity(isDark ? 0.20 : 0.12)
                            : Color.primary.opacity(isDark ? 0.08 : 0.05)
                    )
            )
            .overlay(
                Capsule()
                    .stroke(
                        isExpanded
                            ? Color.accentColor.opacity(isDark ? 0.42 : 0.28)
                            : Color.primary.opacity(isDark ? 0.12 : 0.08),
                        lineWidth: 0.6
                    )
            )
        }
        .orbitInteractiveButton(pressedScale: 0.94, hoverTint: nil, cornerRadius: 99)
        .fixedSize(horizontal: true, vertical: false)
        .help(isExpanded ? "收起额度消耗曲线" : "展开额度消耗与时段掉额曲线")
    }

    private func supplementaryBalanceCard(_ balance: BalanceInfo, compact: Bool) -> some View {
        let trimmedDetail = balance.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let useDetailAsTitle = !trimmedDetail.isEmpty && trimmedDetail.count <= 16
        let titleText = useDetailAsTitle ? trimmedDetail : "费用 / 附加额度"

        return VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "creditcard")
                    .font(.system(size: compact ? 10 : 11, weight: .medium))
                    .foregroundColor(.secondary)

                Text(titleText)
                    .font(.system(size: compact ? 10.5 : 11, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.88))
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(AppStore.exactCurrencyString(balance))
                    .font(.system(size: compact ? 11.5 : 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: true, vertical: false)

                if !balance.currency.isEmpty {
                    Text(balance.currency.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }

            if !useDetailAsTitle && !trimmedDetail.isEmpty {
                Text(trimmedDetail)
                    .font(.system(size: compact ? 10 : 10.5))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if balance.grantedBalance != nil || balance.toppedUpBalance != nil {
                HStack(spacing: 10) {
                    if let toppedUp = balance.toppedUpBalance {
                        Text("充值 \(AppStore.exactCurrencyString(amount: toppedUp, currency: balance.currency))")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    if let granted = balance.grantedBalance {
                        Text("赠送 \(AppStore.exactCurrencyString(amount: granted, currency: balance.currency))")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 6 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.075), lineWidth: 0.7)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func nonRedundantCadenceBadge(for window: QuotaWindow, title: String) -> WindowCadence? {
        let cadence = classifyCadence(for: window)
        guard let tag = cadence.tagText else { return nil }
        let lowerTitle = title.lowercased()
        switch cadence {
        case .fiveHour:
            if lowerTitle.contains("5小时") || lowerTitle.contains("5 小时") || lowerTitle.contains("5h") {
                return nil
            }
        case .weekly:
            if lowerTitle.contains("周") || lowerTitle.contains("7天") || lowerTitle.contains("7d") || lowerTitle.contains("week") {
                return nil
            }
        case .daily:
            if lowerTitle.contains("每日") || lowerTitle.contains("1天") || lowerTitle.contains("24小时") || lowerTitle.contains("daily") {
                return nil
            }
        case .monthly:
            if lowerTitle.contains("月") || lowerTitle.contains("30天") || lowerTitle.contains("month") {
                return nil
            }
        case .other:
            return nil
        }
        return tag.isEmpty ? nil : cadence
    }

    private func nonRedundantBalanceDetail(_ balance: BalanceInfo, paceNote: String?) -> String? {
        guard let raw = balance.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        guard balance.toppedUpBalance != nil || balance.grantedBalance != nil else {
            return raw
        }
        let segments = raw.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let filtered = segments.filter { seg in
            guard !seg.isEmpty else { return false }
            if balance.toppedUpBalance != nil && seg.hasPrefix("充值 ") { return false }
            if balance.grantedBalance != nil && (seg.hasPrefix("赠金 ") || seg.hasPrefix("赠送 ")) { return false }
            if let pace = paceNote, !pace.isEmpty, (seg == "可用" || seg == "不可用") { return false }
            return true
        }
        let joined = filtered.joined(separator: " · ")
        return joined.isEmpty ? nil : joined
    }

    private func unconfiguredRecoveryCard(provider: ProviderID, message: String) -> some View {
        let iconName = (provider == .claude) ? "terminal.fill" : "key.fill"
        let tint = (provider == .claude) ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange)

        return VStack(alignment: .leading, spacing: 10) {
            statusMessageRow(icon: iconName, color: tint, message: message)

            HStack(spacing: 8) {
                if provider == .claude {
                    Button {
                        Task { await store.refreshProvider(.claude, userInitiated: true) }
                    } label: {
                        Label("重新读取本地缓存", systemImage: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else if provider.supportsAPIKeyConfig {
                    Button {
                        withAnimation(OrbitMotion.snappy) {
                            showInlineAPIKeyEditor.toggle()
                        }
                    } label: {
                        Label(showInlineAPIKeyEditor ? "收起配置" : "立即配置 API Key", systemImage: "lock.shield")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Button("前往设置") {
                    onOpenSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func errorRecoveryCard(
        provider: ProviderID,
        icon: String,
        tint: Color,
        title: String,
        message: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(tint)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
            }

            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    Task { await store.refreshProvider(provider, userInitiated: true) }
                } label: {
                    Label("重试刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if provider.supportsAPIKeyConfig {
                    Button("更新 API Key") {
                        withAnimation(OrbitMotion.snappy) {
                            showInlineAPIKeyEditor = true
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func inlineAPIKeyEditorCard(for provider: ProviderID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("保存 \(provider.displayName) API Key 至系统钥匙串")
                .font(.system(size: 11.5, weight: .semibold))

            HStack(spacing: 6) {
                SecureField("粘贴 \(provider.displayName) API Key", text: $inlineAPIKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))

                Button("保存") {
                    let keyToSave = inlineAPIKeyDraft
                    inlineAPIKeyDraft = ""
                    showInlineAPIKeyEditor = false
                    Task {
                        await store.saveAPIKey(provider: provider, key: keyToSave)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(inlineAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("密钥仅以密文形式写入 com.rory.roryorbit.keys 钥匙串，界面永不回显明文。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Reusable Quota Progress Row & Badges

    @ViewBuilder
    private func quotaWindowProgressRow(
        _ window: QuotaWindow,
        displayTitle: String? = nil,
        cadenceBadge: WindowCadence? = nil,
        showDetail: Bool = false,
        contained: Bool = false,
        highlightPrimary: Bool = false
    ) -> some View {
        let showRemaining = settings.showRemainingPercent
        let fillFraction = showRemaining ? window.remainingFraction : (1.0 - window.remainingFraction)
        let barColor = OrbitTheme.quotaColor(remainingFraction: window.remainingFraction, warnThreshold: warnThreshold)
        let pctText = Formatters.percentString(remainingFraction: window.remainingFraction, showRemaining: showRemaining)
        let resetText = accountCardConfig.showResetFootnote
            ? Formatters.resetDisplayString(window.resetAt, relative: settings.showResetRelative)
            : ""
        let titleText = displayTitle ?? window.label

        let content = VStack(alignment: .leading, spacing: isCompactCards ? 3 : 4.5) {
            HStack(alignment: .center, spacing: 5) {
                Text(titleText)
                    .font(.system(size: 11, weight: highlightPrimary ? .semibold : .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let cadence = cadenceBadge, let tag = cadence.tagText {
                    cadenceTagBadge(tag, tint: cadence.tint)
                }

                Spacer(minLength: 4)

                if !resetText.isEmpty {
                    Text(resetText)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Text(pctText)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .orbitNumericTransition()
                    .foregroundColor(barColor)
                    .frame(minWidth: 34, alignment: .trailing)
                    .fixedSize(horizontal: true, vertical: false)
            }

            OrbitAnimatedProgressBar(
                fraction: fillFraction,
                tint: barColor,
                trackColor: Color.primary.opacity(0.10),
                height: isCompactCards ? 5 : 6,
                minFillWidth: 4
            )

            if showDetail, let detail = window.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if contained {
            content
                .padding(.horizontal, isCompactCards ? 7.5 : 9)
                .padding(.vertical, isCompactCards ? 5 : 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(highlightPrimary ? Color.accentColor.opacity(0.055) : Color.primary.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            highlightPrimary ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.065),
                            lineWidth: 0.65
                        )
                )
        } else {
            content
        }
    }

    private func planBadge(_ plan: PlanInfo) -> some View {
        let tint = OrbitTheme.planTint(plan.kind)
        return Text(plan.displayName.uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundColor(tint)
            .padding(.horizontal, 5.5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.14))
            .clipShape(Capsule())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func sourceBadge(_ label: String, isStale: Bool) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(.secondary)
            if isStale {
                Text("缓存")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(nsColor: .systemOrange))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.06))
        .clipShape(Capsule())
    }

    private func statusMessageRow(icon: String, color: Color, message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(color)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func resolvedSingleProviderSubtitle(provider: ProviderID, account: AccountRecord?) -> String {
        if let email = account?.email, !email.isEmpty {
            return email
        }
        if let name = account?.displayName, !name.isEmpty, name != provider.displayName {
            return name
        }
        switch provider {
        case .claude: return "Claude CLI 本地被动余量"
        case .grok: return "本机 Grok CLI / 账单配额"
        case .cursor: return "本机 Cursor 会话配额"
        case .kimi: return "Kimi Coding API 用量"
        case .deepseek: return "DeepSeek API 账户余额"
        default: return provider.displayName
        }
    }

    private func avatarInitial(for account: AccountRecord) -> String {
        let source = account.displayName.isEmpty ? account.email : account.displayName
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    // MARK: - Bottom Action Bar

    private var bottomActionBar: some View {
        HStack(spacing: isNarrowLayout ? 5 : 7) {
            if selectedProvider.supportsClientControl {
                Button {
                    Task { await store.addAccount(provider: selectedProvider) }
                } label: {
                    Label(isNarrowLayout ? "添加" : "添加账号", systemImage: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.busyActionLabel != nil)
                .help("添加 \(selectedProvider.displayName) 账号")

                Button {
                    Task { await store.importLiveAccount(provider: selectedProvider) }
                } label: {
                    Label(isNarrowLayout ? "导入" : "导入当前", systemImage: "tray.and.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.busyActionLabel != nil)
                .help("导入本机当前正在使用的 \(selectedProvider.displayName) 账号")

                Spacer(minLength: 4)

                Button {
                    Task { await store.controlClient(provider: selectedProvider, restart: true) }
                } label: {
                    Text("重启")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.busyActionLabel != nil)
                .help("优雅关闭并重新打开当前运行的 \(selectedProvider.displayName)")

                Button {
                    Task { await store.controlClient(provider: selectedProvider, restart: false) }
                } label: {
                    Text("结束")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.busyActionLabel != nil)
                .help("优雅退出当前运行的 \(selectedProvider.displayName)")
            } else if selectedProvider == .claude {
                Button {
                    withAnimation(OrbitMotion.snappy) {
                        showInlineClaudeProfileCreator.toggle()
                        if !showInlineClaudeProfileCreator {
                            inlineClaudeProfileSlugDraft = ""
                            inlineClaudeProfileLabelDraft = ""
                            inlineClaudeProfileError = nil
                        }
                    }
                } label: {
                    Label(
                        showInlineClaudeProfileCreator
                            ? "收起创建"
                            : (isNarrowLayout ? "添加配置" : "添加配置"),
                        systemImage: showInlineClaudeProfileCreator ? "xmark" : "plus"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.busyActionLabel != nil)
                .help("创建独立的 Claude CLI 配置目录（零联网、不碰桌面端）")

                Spacer(minLength: 4)

                Button {
                    Task { await store.refreshProvider(.claude, userInitiated: true) }
                } label: {
                    Label(
                        isNarrowLayout ? "刷新" : "刷新 Claude",
                        systemImage: "arrow.clockwise"
                    )
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.refreshingProviders.contains(.claude))
                .help("重新读取本地 Claude CLI 被动缓存与配置")
            } else {
                Button {
                    Task { await store.refreshProvider(selectedProvider, userInitiated: true) }
                } label: {
                    Label(
                        isNarrowLayout ? "刷新" : "刷新 \(selectedProvider.displayName)",
                        systemImage: "arrow.clockwise"
                    )
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.refreshingProviders.contains(selectedProvider))
                .help("立即刷新 \(selectedProvider.displayName) 配额")

                if selectedProvider.supportsAPIKeyConfig {
                    Button {
                        withAnimation(OrbitMotion.snappy) {
                            showInlineAPIKeyEditor.toggle()
                        }
                    } label: {
                        let configured = store.apiKeyConfiguredMap[selectedProvider] ?? false
                        Label(configured ? "更新密钥" : "配置密钥", systemImage: "key")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer(minLength: 4)

                Button {
                    onOpenSettings()
                } label: {
                    Label("设置", systemImage: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, isNarrowLayout ? 10 : 13)
        .padding(.top, 7)
        .padding(.bottom, 9)
    }
}

// MARK: - Inline Mini Quota Sparkline (28x12pt)

public struct QuotaMiniSparklineView: View {
    public let points: [QuotaBurnPoint]
    public var tint: Color

    public init(
        points: [QuotaBurnPoint],
        tint: Color = Color(red: 0.23, green: 0.51, blue: 0.96)
    ) {
        self.points = points
        self.tint = tint
    }

    public var body: some View {
        Canvas { context, size in
            guard points.count >= 2, size.width > 2, size.height > 2 else { return }
            let sorted = points.sorted { $0.timestamp < $1.timestamp }
            let minT = sorted.first!.timestamp.timeIntervalSince1970
            let maxT = sorted.last!.timestamp.timeIntervalSince1970
            let spanT = max(maxT - minT, 1.0)

            let padX: CGFloat = 1.2
            let padY: CGFloat = 1.5
            let plotW = max(1, size.width - padX * 2)
            let plotH = max(1, size.height - padY * 2)

            var path = Path()
            var lastPoint: CGPoint = .zero
            for (idx, pt) in sorted.enumerated() {
                let fracX = CGFloat((pt.timestamp.timeIntervalSince1970 - minT) / spanT)
                let fracY = CGFloat(min(max(pt.remainingPercent / 100.0, 0.0), 1.0))
                let x = padX + fracX * plotW
                let y = padY + (1.0 - fracY) * plotH
                let cgPt = CGPoint(x: x, y: y)
                if idx == 0 {
                    path.move(to: cgPt)
                } else {
                    path.addLine(to: cgPt)
                }
                lastPoint = cgPt
            }

            context.stroke(
                path,
                with: .color(tint.opacity(0.92)),
                style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
            )

            let dotRect = CGRect(x: lastPoint.x - 1.5, y: lastPoint.y - 1.5, width: 3.0, height: 3.0)
            context.fill(Path(ellipseIn: dotRect), with: .color(tint))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Expandable Liquid Glass Quota Curve & Hourly Burn Panel

public struct QuotaCurvePanelView: View {
    public let seriesList: [QuotaBurnSeries]
    public let selectedRange: QuotaHistoryRange
    public let onSelectRange: (QuotaHistoryRange) -> Void
    public var poolBadgeText: String?
    public var referenceNow: Date
    public var compact: Bool
    public var availableWidth: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @State private var scrubbedFraction: Double? = nil

    private static let primaryBlue = Color(red: 0.23, green: 0.51, blue: 0.96)
    private static let secondaryEmerald = Color(red: 0.06, green: 0.72, blue: 0.50)
    private static let tertiaryPurple = Color(red: 0.58, green: 0.40, blue: 0.96)

    public init(
        seriesList: [QuotaBurnSeries],
        selectedRange: QuotaHistoryRange,
        onSelectRange: @escaping (QuotaHistoryRange) -> Void,
        poolBadgeText: String? = nil,
        referenceNow: Date = Date(),
        compact: Bool = false,
        availableWidth: CGFloat = 350
    ) {
        self.seriesList = seriesList
        self.selectedRange = selectedRange
        self.onSelectRange = onSelectRange
        self.poolBadgeText = poolBadgeText
        self.referenceNow = referenceNow
        self.compact = compact
        self.availableWidth = availableWidth
    }

    private var maxSampleCount: Int {
        seriesList.map(\.points.count).max() ?? 0
    }

    private var primaryBurnSeries: QuotaBurnSeries? {
        if let fiveH = seriesList.first(where: { Self.shortLegendTitle(for: $0) == "5h" && $0.points.count >= 2 }) {
            return fiveH
        }
        return seriesList.first(where: { $0.points.count >= 2 }) ?? seriesList.first
    }

    private var effectiveRangeBounds: (start: Date, end: Date) {
        let latestSample = seriesList.compactMap { $0.points.last?.timestamp }.max()
        let end = max(referenceNow, latestSample ?? referenceNow)
        let start = end.addingTimeInterval(-selectedRange.durationSeconds)
        return (start, end)
    }

    private var isUltraNarrow: Bool {
        availableWidth < 335
    }

    private var panelBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.052) : Color.black.opacity(0.030)
    }

    private var panelBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.075)
    }

    public var body: some View {
        let pad: CGFloat = compact ? 7.5 : 9

        VStack(alignment: .leading, spacing: compact ? 6 : 7.5) {
            headerControlBar

            if maxSampleCount < 2 {
                dayZeroWaitingState
            } else {
                let bounds = effectiveRangeBounds
                let scrubbedDate: Date? = scrubbedFraction.map { frac in
                    let clamped = min(max(frac, 0.0), 1.0)
                    return bounds.start.addingTimeInterval(selectedRange.durationSeconds * clamped)
                }

                scrubbingStatusStrip(scrubbedDate: scrubbedDate)

                remainingCurveCanvas(bounds: bounds, scrubbedDate: scrubbedDate)

                timeAxisRow(bounds: bounds)

                if let burnSeries = primaryBurnSeries, !burnSeries.buckets.isEmpty {
                    bucketBurnBarSection(
                        series: burnSeries,
                        bounds: bounds,
                        scrubbedDate: scrubbedDate
                    )
                }

                if let burnSeries = primaryBurnSeries {
                    peakBurnCalloutRow(series: burnSeries)
                }
            }
        }
        .padding(pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(panelBorder, lineWidth: 0.7)
        )
    }

    // MARK: Header: Legend + Pool Tag + Range Pills

    @ViewBuilder
    private var headerControlBar: some View {
        if isUltraNarrow {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    legendCluster
                    Spacer(minLength: 4)
                    rangeSegmentedControl
                }
            }
        } else {
            HStack(alignment: .center, spacing: 6) {
                legendCluster
                Spacer(minLength: 4)
                rangeSegmentedControl
            }
        }
    }

    private var legendCluster: some View {
        HStack(spacing: isUltraNarrow ? 4 : 6) {
            if let pool = poolBadgeText, !pool.isEmpty {
                Text(pool)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.11))
                    .clipShape(Capsule())
                    .lineLimit(1)
            }

            if seriesList.isEmpty {
                HStack(spacing: 3.5) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("额度曲线")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            } else {
                ForEach(Array(seriesList.prefix(2).enumerated()), id: \.element.id) { idx, series in
                    let color = Self.seriesColor(for: series, index: idx)
                    let title = Self.shortLegendTitle(for: series)
                    HStack(spacing: 3) {
                        Circle()
                            .fill(color)
                            .frame(width: 5.5, height: 5.5)
                        Text(title)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.84))
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var rangeSegmentedControl: some View {
        let isDark = (colorScheme == .dark)
        return HStack(spacing: 1.5) {
            ForEach(QuotaHistoryRange.allCases) { range in
                let isSelected = (selectedRange == range)
                Button {
                    scrubbedFraction = nil
                    onSelectRange(range)
                } label: {
                    Text(range.displayName)
                        .font(.system(size: isUltraNarrow ? 9 : 9.5, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? .primary : .secondary)
                        .padding(.horizontal, isUltraNarrow ? 5 : 6.5)
                        .padding(.vertical, 2.5)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(isDark ? Color.white.opacity(0.18) : Color.white.opacity(0.88))
                                    .shadow(color: Color.black.opacity(isDark ? 0.22 : 0.08), radius: 1.2, y: 0.5)
                            }
                        }
                        .contentShape(Capsule())
                }
                .orbitInteractiveButton(
                    pressedScale: 0.96,
                    hoverTint: isSelected ? nil : Color.primary.opacity(0.04),
                    cornerRadius: 99
                )
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(isDark ? 0.09 : 0.055)))
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: Day-0 Waiting State (< 2 Samples)

    private var dayZeroWaitingState: some View {
        VStack(alignment: .leading, spacing: 5) {
            if maxSampleCount == 1 {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Self.primaryBlue)
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text("已记录 1 个采样点，等待下次刷新生成曲线")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.primary.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                        let currentSummary = seriesList.prefix(2).compactMap { series -> String? in
                            guard let pt = series.points.last else { return nil }
                            return "\(Self.shortLegendTitle(for: series)) \(Self.formatCompactNumber(pt.remainingPercent))%"
                        }.joined(separator: " · ")
                        if !currentSummary.isEmpty {
                            Text("当前基准：\(currentSummary)")
                                .font(.system(size: 9.5, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("暂无该时段采样记录，刷新配额后自动追踪消耗曲线与掉额峰值")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    // MARK: Interactive Scrubbing Readout

    private func scrubbingStatusStrip(scrubbedDate: Date?) -> some View {
        HStack(spacing: 6) {
            if let scrubbedDate {
                Text(Self.formatScrubTimestamp(scrubbedDate, range: selectedRange))
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.primary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06))
                    .clipShape(Capsule())

                ForEach(Array(seriesList.prefix(2).enumerated()), id: \.element.id) { idx, series in
                    if let nearest = Self.nearestPoint(in: series.points, to: scrubbedDate) {
                        let color = Self.seriesColor(for: series, index: idx)
                        HStack(spacing: 2.5) {
                            Circle()
                                .fill(color)
                                .frame(width: 4.5, height: 4.5)
                            Text("\(Self.shortLegendTitle(for: series)) \(Self.formatCompactNumber(nearest.remainingPercent))%")
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(.primary.opacity(0.9))
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 2)

                if let burnSeries = primaryBurnSeries,
                   let bucket = burnSeries.buckets.first(where: { scrubbedDate >= $0.start && scrubbedDate < $0.end }),
                   bucket.dropPercent >= 0.05 {
                    Text("-\(Self.formatCompactNumber(bucket.dropPercent))%")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(Self.burnColor(for: bucket.dropPercent))
                        .lineLimit(1)
                }
            } else {
                Text("剩余额度曲线 (0%–100%)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("悬停查看明细")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.72))
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 14)
    }

    // MARK: Remaining-% Curve Canvas (0%–100% + Reset Markers + Crosshair)

    private func remainingCurveCanvas(
        bounds: (start: Date, end: Date),
        scrubbedDate: Date?
    ) -> some View {
        let chartHeight: CGFloat = compact ? 80 : 92
        let yAxisWidth: CGFloat = 26
        let topPad: CGFloat = 11
        let bottomPad: CGFloat = 5
        let rightPad: CGFloat = 4
        let isDark = (colorScheme == .dark)

        let startSec = bounds.start.timeIntervalSince1970
        let spanSec = max(bounds.end.timeIntervalSince(bounds.start), 60.0)

        return GeometryReader { geo in
            let totalW = max(60, geo.size.width)
            let plotLeft = yAxisWidth
            let plotW = max(20, totalW - plotLeft - rightPad)
            let plotTop = topPad
            let plotH = max(20, chartHeight - topPad - bottomPad)

            ZStack {
                Canvas { context, _ in
                    // 1. Horizontal reference grid (100%, 50%, 0%)
                    let gridLevels: [(pct: Double, label: String)] = [
                        (100, "100%"),
                        (50, "50%"),
                        (0, "0%"),
                    ]
                    for level in gridLevels {
                        let y = plotTop + (1.0 - CGFloat(level.pct / 100.0)) * plotH
                        var line = Path()
                        line.move(to: CGPoint(x: plotLeft, y: y))
                        line.addLine(to: CGPoint(x: plotLeft + plotW, y: y))
                        context.stroke(
                            line,
                            with: .color(Color.primary.opacity(level.pct == 0 ? 0.14 : 0.08)),
                            style: StrokeStyle(
                                lineWidth: 0.65,
                                dash: level.pct == 50 ? [2.5, 2.5] : []
                            )
                        )

                        let text = Text(level.label)
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary.opacity(0.78))
                        context.draw(
                            text,
                            at: CGPoint(x: plotLeft - 4, y: y),
                            anchor: .trailing
                        )
                    }

                    // 2. Dashed emerald reset markers across plotted series
                    let uniqueResets = Self.mergedResetMarkers(from: Array(seriesList.prefix(2)))
                    for resetDate in uniqueResets {
                        let frac = (resetDate.timeIntervalSince1970 - startSec) / spanSec
                        guard frac >= 0.0 && frac <= 1.0 else { continue }
                        let x = plotLeft + CGFloat(frac) * plotW

                        var markerPath = Path()
                        markerPath.move(to: CGPoint(x: x, y: plotTop))
                        markerPath.addLine(to: CGPoint(x: x, y: plotTop + plotH))
                        context.stroke(
                            markerPath,
                            with: .color(Self.secondaryEmerald.opacity(0.78)),
                            style: StrokeStyle(lineWidth: 1.0, dash: [3, 2.5])
                        )

                        let labelX = min(max(x, plotLeft + 13), plotLeft + plotW - 13)
                        let resetCaption = Text("重置")
                            .font(.system(size: 7.5, weight: .semibold))
                            .foregroundColor(Self.secondaryEmerald)
                        context.draw(
                            resetCaption,
                            at: CGPoint(x: labelX, y: max(5, plotTop - 5.5)),
                            anchor: .center
                        )
                    }

                    // 3. Draw series (secondary first so primary 5h sits cleanly on top)
                    let displayed = Array(seriesList.prefix(2).enumerated())
                    for (idx, series) in displayed.reversed() {
                        let color = Self.seriesColor(for: series, index: idx)
                        let isPrimary = (idx == 0)
                        let segments = Self.splitSegmentsAcrossResets(
                            points: series.points,
                            resetMarkers: series.resetMarkers
                        )

                        for segment in segments {
                            let cgPts: [CGPoint] = segment.map { pt in
                                let fx = min(max((pt.timestamp.timeIntervalSince1970 - startSec) / spanSec, 0.0), 1.0)
                                let fy = min(max(pt.remainingPercent / 100.0, 0.0), 1.0)
                                return CGPoint(
                                    x: plotLeft + CGFloat(fx) * plotW,
                                    y: plotTop + (1.0 - CGFloat(fy)) * plotH
                                )
                            }
                            guard !cgPts.isEmpty else { continue }

                            if cgPts.count == 1 {
                                let p = cgPts[0]
                                let r = CGRect(x: p.x - 2.2, y: p.y - 2.2, width: 4.4, height: 4.4)
                                context.fill(Path(ellipseIn: r), with: .color(color))
                                continue
                            }

                            let curvePath = Self.makeMonotoneCubicPath(points: cgPts, minY: plotTop, maxY: plotTop + plotH)

                            // Area gradient fill under each contiguous segment
                            var fillPath = curvePath
                            fillPath.addLine(to: CGPoint(x: cgPts.last!.x, y: plotTop + plotH))
                            fillPath.addLine(to: CGPoint(x: cgPts.first!.x, y: plotTop + plotH))
                            fillPath.closeSubpath()

                            let topAlpha: Double = isPrimary ? (isDark ? 0.24 : 0.18) : (isDark ? 0.12 : 0.09)
                            context.fill(
                                fillPath,
                                with: .linearGradient(
                                    Gradient(colors: [color.opacity(topAlpha), color.opacity(0.01)]),
                                    startPoint: CGPoint(x: 0, y: plotTop),
                                    endPoint: CGPoint(x: 0, y: plotTop + plotH)
                                )
                            )

                            context.stroke(
                                curvePath,
                                with: .color(color),
                                style: StrokeStyle(
                                    lineWidth: isPrimary ? 1.85 : 1.55,
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                        }

                        // Subtle sample point dots when sparse enough to read cleanly
                        if series.points.count <= 24 {
                            for pt in series.points {
                                let fx = min(max((pt.timestamp.timeIntervalSince1970 - startSec) / spanSec, 0.0), 1.0)
                                let fy = min(max(pt.remainingPercent / 100.0, 0.0), 1.0)
                                let cx = plotLeft + CGFloat(fx) * plotW
                                let cy = plotTop + (1.0 - CGFloat(fy)) * plotH
                                let r = CGRect(x: cx - 1.7, y: cy - 1.7, width: 3.4, height: 3.4)
                                context.fill(Path(ellipseIn: r), with: .color(color.opacity(0.9)))
                            }
                        }
                    }

                    // 4. Interactive crosshair + highlighted snap points
                    if let scrubbedDate {
                        let frac = min(max((scrubbedDate.timeIntervalSince1970 - startSec) / spanSec, 0.0), 1.0)
                        let cx = plotLeft + CGFloat(frac) * plotW

                        var guide = Path()
                        guide.move(to: CGPoint(x: cx, y: plotTop))
                        guide.addLine(to: CGPoint(x: cx, y: plotTop + plotH))
                        context.stroke(
                            guide,
                            with: .color(Color.primary.opacity(isDark ? 0.42 : 0.32)),
                            style: StrokeStyle(lineWidth: 0.9, dash: [2.5, 2])
                        )

                        for (idx, series) in displayed {
                            guard let nearest = Self.nearestPoint(in: series.points, to: scrubbedDate) else { continue }
                            let color = Self.seriesColor(for: series, index: idx)
                            let fx = min(max((nearest.timestamp.timeIntervalSince1970 - startSec) / spanSec, 0.0), 1.0)
                            let fy = min(max(nearest.remainingPercent / 100.0, 0.0), 1.0)
                            let px = plotLeft + CGFloat(fx) * plotW
                            let py = plotTop + (1.0 - CGFloat(fy)) * plotH

                            let halo = CGRect(x: px - 4.5, y: py - 4.5, width: 9, height: 9)
                            context.fill(Path(ellipseIn: halo), with: .color(color.opacity(0.24)))
                            let core = CGRect(x: px - 2.6, y: py - 2.6, width: 5.2, height: 5.2)
                            context.fill(Path(ellipseIn: core), with: .color(color))
                            context.stroke(Path(ellipseIn: core), with: .color(Color.white.opacity(0.9)), lineWidth: 0.9)
                        }
                    }
                }

                // Transparent hover + drag scrubbing surface aligned to plot frame
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            let frac = Double((loc.x - plotLeft) / plotW)
                            scrubbedFraction = min(max(frac, 0.0), 1.0)
                        case .ended:
                            scrubbedFraction = nil
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let frac = Double((value.location.x - plotLeft) / plotW)
                                scrubbedFraction = min(max(frac, 0.0), 1.0)
                            }
                            .onEnded { _ in
                                scrubbedFraction = nil
                            }
                    )
            }
        }
        .frame(height: chartHeight)
    }

    // MARK: Time Axis Row

    private func timeAxisRow(bounds: (start: Date, end: Date)) -> some View {
        let mid = bounds.start.addingTimeInterval(bounds.end.timeIntervalSince(bounds.start) * 0.5)
        return HStack {
            Text(Self.formatAxisTick(bounds.start, range: selectedRange))
            Spacer()
            Text(Self.formatAxisTick(mid, range: selectedRange))
            Spacer()
            Text("现在")
        }
        .font(.system(size: 8.5, design: .rounded))
        .monospacedDigit()
        .foregroundColor(.secondary.opacity(0.75))
        .padding(.leading, 26)
        .padding(.trailing, 4)
    }

    // MARK: Bucket Burn-Rate Bar Chart (时段掉额柱状图)

    private func bucketBurnBarSection(
        series: QuotaBurnSeries,
        bounds: (start: Date, end: Date),
        scrubbedDate: Date?
    ) -> some View {
        let barHeight: CGFloat = compact ? 26 : 30
        let leftInset: CGFloat = 26
        let rightInset: CGFloat = 4
        let maxDrop = max(series.buckets.map(\.dropPercent).max() ?? 0.0, 5.0)
        let peakStart = series.peakBucket?.start
        let startSec = bounds.start.timeIntervalSince1970
        let spanSec = max(bounds.end.timeIntervalSince(bounds.start), 60.0)

        return VStack(alignment: .leading, spacing: 3.5) {
            HStack(spacing: 6) {
                Text("时段掉额")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)

                Spacer(minLength: 4)

                HStack(spacing: isUltraNarrow ? 4 : 6) {
                    burnLegendDot(color: Color(nsColor: .systemGreen), label: "<5%")
                    burnLegendDot(color: Color(nsColor: .systemOrange), label: "5–15%")
                    burnLegendDot(color: Color(nsColor: .systemRed), label: "≥15%")
                }
            }

            GeometryReader { geo in
                let totalW = max(60, geo.size.width)
                let plotW = max(20, totalW - leftInset - rightInset)

                ZStack {
                    Canvas { context, _ in
                        // Baseline
                        var base = Path()
                        base.move(to: CGPoint(x: leftInset, y: barHeight - 1))
                        base.addLine(to: CGPoint(x: leftInset + plotW, y: barHeight - 1))
                        context.stroke(base, with: .color(Color.primary.opacity(0.10)), lineWidth: 0.6)

                        for bucket in series.buckets {
                            let sFrac = min(max((bucket.start.timeIntervalSince1970 - startSec) / spanSec, 0.0), 1.0)
                            let eFrac = min(max((bucket.end.timeIntervalSince1970 - startSec) / spanSec, 0.0), 1.0)
                            guard eFrac > sFrac else { continue }

                            let rawX = leftInset + CGFloat(sFrac) * plotW
                            let rawW = CGFloat(eFrac - sFrac) * plotW
                            let gap: CGFloat = rawW > 5 ? 1.5 : 0.6
                            let barW = max(1.5, rawW - gap)
                            let barX = rawX + gap * 0.5

                            let isPeak = (peakStart != nil && bucket.start == peakStart && bucket.dropPercent >= 0.1)
                            let isScrubbed: Bool = {
                                guard let scrubbedDate else { return false }
                                return scrubbedDate >= bucket.start && scrubbedDate < bucket.end
                            }()

                            if bucket.dropPercent < 0.05 {
                                let tickRect = CGRect(x: barX, y: barHeight - 2.5, width: barW, height: 1.5)
                                context.fill(
                                    Path(roundedRect: tickRect, cornerRadius: 0.75),
                                    with: .color(Color.primary.opacity(isScrubbed ? 0.25 : 0.10))
                                )
                            } else {
                                let frac = min(max(bucket.dropPercent / maxDrop, 0.0), 1.0)
                                let h = max(3.5, CGFloat(frac) * (barHeight - 3.5))
                                let rect = CGRect(x: barX, y: barHeight - 1 - h, width: barW, height: h)
                                let color = Self.burnColor(for: bucket.dropPercent)
                                let opacity: Double = (isPeak || isScrubbed) ? 0.96 : 0.76
                                context.fill(
                                    Path(roundedRect: rect, cornerRadius: min(2.2, barW * 0.45)),
                                    with: .color(color.opacity(opacity))
                                )
                                if isPeak || isScrubbed {
                                    context.stroke(
                                        Path(roundedRect: rect, cornerRadius: min(2.2, barW * 0.45)),
                                        with: .color(Color.primary.opacity(0.28)),
                                        lineWidth: 0.65
                                    )
                                }
                            }
                        }
                    }

                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc):
                                let frac = Double((loc.x - leftInset) / plotW)
                                scrubbedFraction = min(max(frac, 0.0), 1.0)
                            case .ended:
                                scrubbedFraction = nil
                            }
                        }
                }
            }
            .frame(height: barHeight)
        }
    }

    private func burnLegendDot(color: Color, label: String) -> some View {
        HStack(spacing: 2.5) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color.opacity(0.88))
                .frame(width: 5.5, height: 5.5)
            Text(label)
                .font(.system(size: 8.5, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.secondary.opacity(0.82))
                .lineLimit(1)
        }
    }

    // MARK: Peak Burn Callout Footer

    private func peakBurnCalloutRow(series: QuotaBurnSeries) -> some View {
        let calloutText: String
        let accent: Color
        if let peak = series.peakBucket, peak.dropPercent >= 0.1 {
            let peakDrop = Self.formatCompactNumber(peak.dropPercent)
            let avgRate = Self.formatRate(series.averageBurnPerHour)
            let totalDrop = Self.formatCompactNumber(series.totalConsumedPercent)
            calloutText = "⚡ 掉额最快：\(peak.label) (-\(peakDrop)%) · 均速 -\(avgRate)%/h · 累计 -\(totalDrop)%"
            accent = Self.burnColor(for: peak.dropPercent)
        } else {
            calloutText = "⚡ 本时段额度平稳 · 均速 0%/h · 累计 0%"
            accent = Color(nsColor: .systemGreen)
        }

        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(calloutText)
                .font(.system(size: compact ? 9.5 : 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.primary.opacity(0.86))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6.5)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent.opacity(colorScheme == .dark ? 0.12 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(accent.opacity(colorScheme == .dark ? 0.22 : 0.16), lineWidth: 0.55)
        )
    }

    // MARK: Static Geometry & Formatting Helpers

    private static func seriesColor(for series: QuotaBurnSeries, index: Int) -> Color {
        let short = shortLegendTitle(for: series)
        if short == "5h" { return primaryBlue }
        if short == "周" || short == "月" { return secondaryEmerald }
        switch index {
        case 0: return primaryBlue
        case 1: return secondaryEmerald
        default: return tertiaryPurple
        }
    }

    private static func burnColor(for dropPercent: Double) -> Color {
        if dropPercent >= 15.0 {
            return Color(nsColor: .systemRed)
        }
        if dropPercent >= 5.0 {
            return Color(nsColor: .systemOrange)
        }
        return Color(nsColor: .systemGreen)
    }

    private static func shortLegendTitle(for series: QuotaBurnSeries) -> String {
        let lowId = series.windowId.lowercased()
        let lowLabel = series.label.lowercased()
        if lowId.contains("5h") || lowLabel.contains("5小时") || lowLabel.contains("5 小时") || lowLabel.contains("5h") {
            return "5h"
        }
        if lowId.contains("week") || lowId.contains("7d") || lowLabel.contains("周") || lowLabel.contains("7天") {
            return "周"
        }
        if lowId.contains("month") || lowLabel.contains("月") {
            return "月"
        }
        if lowId.contains("daily") || lowId.contains("1d") || lowLabel.contains("每日") {
            return "日"
        }
        return String(series.label.prefix(8))
    }

    private static func mergedResetMarkers(from seriesList: [QuotaBurnSeries]) -> [Date] {
        var all: [Date] = []
        for s in seriesList {
            all.append(contentsOf: s.resetMarkers)
        }
        all.sort()
        var deduped: [Date] = []
        for date in all {
            if let last = deduped.last, abs(date.timeIntervalSince(last)) < 120 {
                continue
            }
            deduped.append(date)
        }
        return deduped
    }

    private static func splitSegmentsAcrossResets(
        points: [QuotaBurnPoint],
        resetMarkers: [Date]
    ) -> [[QuotaBurnPoint]] {
        guard !points.isEmpty else { return [] }
        guard !resetMarkers.isEmpty else { return [points] }
        let resetSet = Set(resetMarkers.map { Int($0.timeIntervalSince1970.rounded()) })
        var segments: [[QuotaBurnPoint]] = []
        var current: [QuotaBurnPoint] = []

        for pt in points {
            let key = Int(pt.timestamp.timeIntervalSince1970.rounded())
            if !current.isEmpty && resetSet.contains(key) {
                segments.append(current)
                current = [pt]
            } else {
                current.append(pt)
            }
        }
        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }

    /// Monotone-clamped cubic Bezier curve that stays strictly within `[minY, maxY]` with zero overshoot.
    private static func makeMonotoneCubicPath(
        points: [CGPoint],
        minY: CGFloat,
        maxY: CGFloat
    ) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }

        let n = points.count
        var slopes = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = max(points[i + 1].x - points[i].x, 0.001)
            slopes[i] = (points[i + 1].y - points[i].y) / dx
        }

        var tangents = [CGFloat](repeating: 0, count: n)
        tangents[0] = slopes[0]
        tangents[n - 1] = slopes[n - 2]
        for i in 1..<(n - 1) {
            if slopes[i - 1] * slopes[i] <= 0 {
                tangents[i] = 0
            } else {
                tangents[i] = 0.5 * (slopes[i - 1] + slopes[i])
            }
        }

        for i in 0..<(n - 1) {
            let p0 = points[i]
            let p1 = points[i + 1]
            let dx = p1.x - p0.x
            if dx <= 0.001 {
                path.addLine(to: p1)
                continue
            }
            let c1 = CGPoint(
                x: p0.x + dx / 3.0,
                y: min(max(p0.y + tangents[i] * dx / 3.0, minY), maxY)
            )
            let c2 = CGPoint(
                x: p1.x - dx / 3.0,
                y: min(max(p1.y - tangents[i + 1] * dx / 3.0, minY), maxY)
            )
            path.addCurve(to: p1, control1: c1, control2: c2)
        }
        return path
    }

    private static func nearestPoint(in points: [QuotaBurnPoint], to target: Date) -> QuotaBurnPoint? {
        guard !points.isEmpty else { return nil }
        return points.min { lhs, rhs in
            abs(lhs.timestamp.timeIntervalSince(target)) < abs(rhs.timestamp.timeIntervalSince(target))
        }
    }

    private static func formatAxisTick(_ date: Date, range: QuotaHistoryRange) -> String {
        let comps = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        let h = comps.hour ?? 0
        let min = comps.minute ?? 0
        switch range {
        case .hours6, .hours24:
            return String(format: "%02d:%02d", h, min)
        case .days7:
            return String(format: "%02d/%02d", m, d)
        }
    }

    private static func formatScrubTimestamp(_ date: Date, range: QuotaHistoryRange) -> String {
        let comps = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        let h = comps.hour ?? 0
        let min = comps.minute ?? 0
        switch range {
        case .hours6, .hours24:
            return String(format: "%02d:%02d", h, min)
        case .days7:
            return String(format: "%02d/%02d %02d:%02d", m, d, h, min)
        }
    }

    private static func formatCompactNumber(_ value: Double) -> String {
        let rounded = (value * 10.0).rounded() / 10.0
        if abs(rounded - rounded.rounded()) < 0.05 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }

    private static func formatRate(_ value: Double) -> String {
        let rounded = (value * 10.0).rounded() / 10.0
        if rounded >= 100.0 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }
}
