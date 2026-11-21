import AppKit
import QuartzCore
import SwiftUI

// MARK: - Unified Motion Primitives (Respects macOS Reduce Motion)

public enum OrbitMotion {
    /// Reflects macOS system-wide "Reduce Motion" accessibility preference.
    public static var isReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Crisp spring for selections, button feedback, and inline confirmations.
    public static var snappy: Animation {
        isReducedMotion
            ? .easeOut(duration: 0.06)
            : .spring(response: 0.26, dampingFraction: 0.84)
    }

    /// Smooth spring for progress bar fills, chart heights, and panel transitions.
    public static var smooth: Animation {
        isReducedMotion
            ? .easeOut(duration: 0.08)
            : .spring(response: 0.38, dampingFraction: 0.86)
    }

    /// Tight spring for sliding pill / capsule indicators via `matchedGeometryEffect`.
    public static var pill: Animation {
        isReducedMotion
            ? .easeOut(duration: 0.06)
            : .spring(response: 0.24, dampingFraction: 0.80)
    }

    /// Fast ease-out curve for hover highlights and subtle elevation shifts.
    public static var hover: Animation {
        isReducedMotion
            ? .linear(duration: 0.04)
            : .easeOut(duration: 0.14)
    }

    /// Gentle content transition when switching tabs, providers, or active day panels.
    public static var panelTransition: AnyTransition {
        if isReducedMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 4)),
            removal: .opacity
        )
    }
}

// MARK: - Numeric Content Transition Modifier

private struct OrbitNumericTransitionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var envReduceMotion
    let countsDown: Bool

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *), !envReduceMotion, !OrbitMotion.isReducedMotion {
            content.contentTransition(.numericText(countsDown: countsDown))
        } else {
            content
        }
    }
}

// MARK: - Animated Capsule Progress Bar

public struct OrbitAnimatedProgressBar: View {
    @Environment(\.accessibilityReduceMotion) private var envReduceMotion

    public var fraction: Double
    public var tint: Color
    public var trackColor: Color
    public var height: CGFloat
    public var minFillWidth: CGFloat
    public var animateOnAppear: Bool

    @State private var displayedFraction: Double

    public init(
        fraction: Double,
        tint: Color,
        trackColor: Color = Color.primary.opacity(0.09),
        height: CGFloat = 5,
        minFillWidth: CGFloat = 4,
        animateOnAppear: Bool = true
    ) {
        let clamped = Self.clamp(fraction)
        self.fraction = clamped
        self.tint = tint
        self.trackColor = trackColor
        self.height = height
        self.minFillWidth = minFillWidth
        self.animateOnAppear = animateOnAppear
        let startFromZero = animateOnAppear && !OrbitMotion.isReducedMotion
        self._displayedFraction = State(initialValue: startFromZero ? 0.0 : clamped)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0.0 }
        return min(max(value, 0.0), 1.0)
    }

    private var reduceMotion: Bool {
        envReduceMotion || OrbitMotion.isReducedMotion
    }

    private var clampedTarget: Double {
        Self.clamp(fraction)
    }

    public var body: some View {
        GeometryReader { geo in
            let totalWidth = max(0, geo.size.width)
            let activeFrac = reduceMotion ? clampedTarget : displayedFraction
            let fillWidth: CGFloat = {
                guard totalWidth > 0, activeFrac > 0.0005 else { return 0 }
                let raw = totalWidth * CGFloat(activeFrac)
                return min(totalWidth, max(minFillWidth, raw))
            }()

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)
                Capsule()
                    .fill(tint)
                    .frame(width: fillWidth)
            }
        }
        .frame(height: height)
        .onAppear {
            if reduceMotion {
                displayedFraction = clampedTarget
            } else if displayedFraction != clampedTarget {
                withAnimation(OrbitMotion.smooth) {
                    displayedFraction = clampedTarget
                }
            }
        }
        .onChange(of: clampedTarget) { newValue in
            if reduceMotion {
                displayedFraction = newValue
            } else {
                withAnimation(OrbitMotion.smooth) {
                    displayedFraction = newValue
                }
            }
        }
    }
}

// MARK: - Live Status Pulse Indicator Dot

public struct OrbitPulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var envReduceMotion

    public var color: Color
    public var size: CGFloat
    public var isActive: Bool

    @State private var isPulsing = false

    public init(
        color: Color = Color(nsColor: .systemGreen),
        size: CGFloat = 6,
        isActive: Bool = true
    ) {
        self.color = color
        self.size = size
        self.isActive = isActive
    }

    private var shouldAnimate: Bool {
        isActive && !envReduceMotion && !OrbitMotion.isReducedMotion
    }

    public var body: some View {
        ZStack {
            if shouldAnimate {
                Circle()
                    .fill(color.opacity(isPulsing ? 0.0 : 0.45))
                    .frame(width: size, height: size)
                    .scaleEffect(isPulsing ? 2.15 : 1.0)
            }

            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .onAppear {
            syncAnimationState()
        }
        .onDisappear {
            stopPulseImmediately()
        }
        .onChange(of: isActive) { _ in
            syncAnimationState()
        }
        .onChange(of: envReduceMotion) { _ in
            syncAnimationState()
        }
    }

    private func syncAnimationState() {
        if shouldAnimate {
            stopPulseImmediately()
            withAnimation(.easeOut(duration: 1.65).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        } else {
            stopPulseImmediately()
        }
    }

    private func stopPulseImmediately() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isPulsing = false
        }
    }
}

// MARK: - macOS Liquid Glass Visual System (macOS 26+ Native, macOS 13–15 Graceful Fallback)

/// Visual style for `OrbitLiquidGlassBackdrop` on macOS 26+.
public enum OrbitGlassBackdropStyle: Equatable, Hashable, Sendable {
    case regular
    case clear
}

@available(macOS 26.0, *)
private struct OrbitNativeGlassBackdropRepresentable: NSViewRepresentable {
    let style: OrbitGlassBackdropStyle
    let cornerRadius: CGFloat
    let tint: Color?

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSGlassEffectView) {
        view.style = (style == .clear) ? .clear : .regular
        view.cornerRadius = max(0, cornerRadius)
        view.tintColor = tint.map { NSColor($0) }
    }
}

private struct OrbitLegacyVisualEffectBackdropRepresentable: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

/// Full-bleed translucent backdrop that uses native macOS 26+ Liquid Glass (`NSGlassEffectView`)
/// and falls back cleanly to behind-window vibrancy (`NSVisualEffectView`) on macOS 13–15.
public struct OrbitLiquidGlassBackdrop: View {
    public var style: OrbitGlassBackdropStyle
    public var cornerRadius: CGFloat
    public var tint: Color?
    public var fallbackMaterial: NSVisualEffectView.Material
    public var fallbackBlendingMode: NSVisualEffectView.BlendingMode

    public init(
        style: OrbitGlassBackdropStyle = .regular,
        cornerRadius: CGFloat = 0,
        tint: Color? = nil,
        fallbackMaterial: NSVisualEffectView.Material = .popover,
        fallbackBlendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.style = style
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.fallbackMaterial = fallbackMaterial
        self.fallbackBlendingMode = fallbackBlendingMode
    }

    public var body: some View {
        backdropContent
            .allowsHitTesting(false)
            .ignoresSafeArea()
    }

    @ViewBuilder
    private var backdropContent: some View {
        if #available(macOS 26.0, *) {
            OrbitNativeGlassBackdropRepresentable(
                style: style,
                cornerRadius: cornerRadius,
                tint: tint
            )
        } else {
            let legacy = ZStack {
                OrbitLegacyVisualEffectBackdropRepresentable(
                    material: fallbackMaterial,
                    blendingMode: fallbackBlendingMode
                )
                if let tint {
                    tint.opacity(0.08)
                }
            }
            if cornerRadius > 0 {
                legacy.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                legacy
            }
        }
    }
}

/// Container that wraps sibling Liquid Glass controls in `GlassEffectContainer(spacing:)` on macOS 26+
/// so adjacent glass capsules blend organically; transparently passes content through on macOS 13–15.
public struct OrbitGlassContainer<Content: View>: View {
    public var spacing: CGFloat?
    private let content: Content

    public init(
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

private struct OrbitGlassCapsuleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var envReduceMotion

    let interactive: Bool
    let tint: Color?

    @State private var isHovered = false

    private var reduceMotion: Bool {
        envReduceMotion || OrbitMotion.isReducedMotion
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(resolvedNativeGlass, in: Capsule())
        } else {
            let isDark = colorScheme == .dark
            content
                .background(
                    ZStack {
                        Capsule()
                            .fill(.ultraThinMaterial)
                        if let tint {
                            Capsule()
                                .fill(tint.opacity(isDark ? (isHovered ? 0.28 : 0.22) : (isHovered ? 0.20 : 0.14)))
                        } else if interactive && isHovered {
                            Capsule()
                                .fill(Color.primary.opacity(isDark ? 0.08 : 0.05))
                        }
                    }
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            fallbackGlassBorderGradient(isDark: isDark),
                            lineWidth: 0.75
                        )
                )
                .animation(reduceMotion ? .linear(duration: 0.04) : OrbitMotion.hover, value: isHovered)
                .onHover { hovering in
                    if interactive {
                        isHovered = hovering
                    }
                }
        }
    }

    @available(macOS 26.0, *)
    private var resolvedNativeGlass: Glass {
        var glass: Glass = .regular
        if let tint {
            glass = glass.tint(tint)
        }
        if interactive {
            glass = glass.interactive()
        }
        return glass
    }

    private func fallbackGlassBorderGradient(isDark: Bool) -> LinearGradient {
        if let tint {
            return LinearGradient(
                colors: [
                    tint.opacity(isDark ? 0.52 : 0.42),
                    tint.opacity(isDark ? 0.24 : 0.20),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: isDark
                ? [Color.white.opacity(isHovered ? 0.30 : 0.22), Color.white.opacity(isHovered ? 0.10 : 0.06)]
                : [Color.white.opacity(isHovered ? 0.86 : 0.72), Color.black.opacity(isHovered ? 0.14 : 0.10)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct OrbitGlassRoundedModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var envReduceMotion

    let cornerRadius: CGFloat
    let interactive: Bool
    let tint: Color?

    @State private var isHovered = false

    private var reduceMotion: Bool {
        envReduceMotion || OrbitMotion.isReducedMotion
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(resolvedNativeGlass, in: shape)
        } else {
            let isDark = colorScheme == .dark
            content
                .background(
                    ZStack {
                        shape.fill(.regularMaterial)
                        if let tint {
                            shape.fill(tint.opacity(isDark ? (isHovered ? 0.22 : 0.16) : (isHovered ? 0.16 : 0.11)))
                        } else if interactive && isHovered {
                            shape.fill(Color.primary.opacity(isDark ? 0.06 : 0.035))
                        }
                    }
                )
                .overlay(
                    shape.strokeBorder(
                        fallbackGlassBorderGradient(isDark: isDark),
                        lineWidth: 0.75
                    )
                )
                .animation(reduceMotion ? .linear(duration: 0.04) : OrbitMotion.hover, value: isHovered)
                .onHover { hovering in
                    if interactive {
                        isHovered = hovering
                    }
                }
        }
    }

    @available(macOS 26.0, *)
    private var resolvedNativeGlass: Glass {
        var glass: Glass = .regular
        if let tint {
            glass = glass.tint(tint)
        }
        if interactive {
            glass = glass.interactive()
        }
        return glass
    }

    private func fallbackGlassBorderGradient(isDark: Bool) -> LinearGradient {
        if let tint {
            return LinearGradient(
                colors: [
                    tint.opacity(isDark ? 0.48 : 0.38),
                    tint.opacity(isDark ? 0.20 : 0.16),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: isDark
                ? [Color.white.opacity(isHovered ? 0.28 : 0.20), Color.white.opacity(isHovered ? 0.09 : 0.05)]
                : [Color.white.opacity(isHovered ? 0.88 : 0.76), Color.black.opacity(isHovered ? 0.14 : 0.09)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Horizontal Mouse-Wheel Scroll Support

private final class OrbitScrollMonitorBox {
    private var monitor: Any?

    func install(_ handler: @escaping (NSEvent) -> NSEvent?) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: handler)
    }

    func remove() {
        if let token = monitor {
            NSEvent.removeMonitor(token)
            monitor = nil
        }
    }

    deinit {
        remove()
    }
}

private final class OrbitHorizontalWheelProbeView: NSView {
    var stepMultiplier: CGFloat = 20

    private let monitorBox = OrbitScrollMonitorBox()
    private var isTrackingHorizontalGesture = false
    private weak var lastAnimatedScrollView: NSScrollView?
    private var lastAnimatedTargetX: CGFloat = 0
    private var lastAnimatedTimestamp: CFTimeInterval = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            teardownMonitor()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitor()
        } else {
            teardownMonitor()
        }
    }

    func teardownMonitor() {
        monitorBox.remove()
        isTrackingHorizontalGesture = false
        lastAnimatedScrollView = nil
    }

    private func installMonitor() {
        monitorBox.install { [weak self] event in
            guard let self else { return event }
            return self.handleScrollWheel(event)
        }
    }

    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard let window = self.window,
              window.isVisible,
              !self.isHiddenOrHasHiddenAncestor else {
            isTrackingHorizontalGesture = false
            return event
        }
        if let eventWindow = event.window, eventWindow !== window {
            return event
        }

        let windowPoint = event.locationInWindow
        let pointInProbe = convert(windowPoint, from: nil)
        guard !visibleRect.isEmpty, visibleRect.contains(pointInProbe) else {
            if event.phase == .began || event.phase == .changed {
                isTrackingHorizontalGesture = false
            }
            return event
        }

        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY

        // Pass native horizontal gestures (e.g. trackpad two-finger swipe, Shift+wheel) straight to AppKit.
        guard deltaY != 0, abs(deltaY) > abs(deltaX) else {
            if event.phase == .began || event.phase == .changed {
                isTrackingHorizontalGesture = false
            }
            return event
        }

        // Prevent outer vertical scroll inertia from being hijacked when the cursor drifts over this strip.
        if !event.momentumPhase.isEmpty {
            guard isTrackingHorizontalGesture else {
                return event
            }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                isTrackingHorizontalGesture = false
            }
        } else if event.phase.contains(.began) || event.phase.contains(.changed) {
            isTrackingHorizontalGesture = true
        } else if event.phase.contains(.cancelled) {
            isTrackingHorizontalGesture = false
        }

        guard let scrollView = resolveTargetScrollView(at: windowPoint),
              let documentView = scrollView.documentView else {
            isTrackingHorizontalGesture = false
            return event
        }

        let clipView = scrollView.contentView
        let visibleWidth = clipView.bounds.width
        let docFrame = documentView.frame
        let minX = docFrame.minX - scrollView.contentInsets.left
        let maxX = max(minX, docFrame.maxX + scrollView.contentInsets.right - visibleWidth)

        // Only consume vertical wheel events when the horizontal strip actually overflows.
        guard maxX - minX > 0.5 else {
            isTrackingHorizontalGesture = false
            return event
        }

        let currentOrigin = clipView.bounds.origin
        if event.hasPreciseScrollingDeltas || OrbitMotion.isReducedMotion {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : stepMultiplier
            let horizontalDelta = -deltaY * scale
            let nextX = min(max(currentOrigin.x + horizontalDelta, minX), maxX)
            lastAnimatedScrollView = nil
            clipView.scroll(to: NSPoint(x: nextX, y: currentOrigin.y))
            scrollView.reflectScrolledClipView(clipView)
        } else {
            let rawDelta = -deltaY * stepMultiplier
            let horizontalDelta = min(max(rawDelta, -360), 360)
            let now = CACurrentMediaTime()
            let baseX: CGFloat
            if lastAnimatedScrollView === scrollView, (now - lastAnimatedTimestamp) < 0.22 {
                baseX = lastAnimatedTargetX
            } else {
                baseX = currentOrigin.x
            }
            let nextX = min(max(baseX + horizontalDelta, minX), maxX)
            lastAnimatedScrollView = scrollView
            lastAnimatedTargetX = nextX
            lastAnimatedTimestamp = now

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                ctx.allowsImplicitAnimation = true
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clipView.animator().setBoundsOrigin(NSPoint(x: nextX, y: currentOrigin.y))
            }, completionHandler: { [weak scrollView, weak clipView] in
                guard let scrollView, let clipView else { return }
                scrollView.reflectScrolledClipView(clipView)
            })
        }

        return nil
    }

    private func resolveTargetScrollView(at windowPoint: NSPoint) -> NSScrollView? {
        let probeWindowRect = convert(visibleRect, to: nil)
        guard !probeWindowRect.isEmpty else { return nil }

        // Build ancestor set so sibling/overlay lookup never mistakes an outer vertical ScrollView for this strip.
        var ancestorIDs = Set<ObjectIdentifier>()
        var cursor: NSView? = self
        while let current = cursor {
            ancestorIDs.insert(ObjectIdentifier(current))
            cursor = current.superview
        }

        // Case A (applied directly on `ScrollView(.horizontal) { ... }.orbitHorizontalWheelScroll()`):
        // Fast path via hitTest under cursor, then bounded sibling DFS.
        if let contentView = window?.contentView {
            let hitPoint = contentView.superview?.convert(windowPoint, from: nil) ?? windowPoint
            if let hit = contentView.hitTest(hitPoint) {
                var candidate: NSView? = hit
                while let view = candidate {
                    if let sv = view as? NSScrollView,
                       !ancestorIDs.contains(ObjectIdentifier(sv)),
                       isMatchingScrollView(sv, windowPoint: windowPoint, probeWindowRect: probeWindowRect) {
                        return sv
                    }
                    candidate = view.superview
                }
            }
        }

        var searchRoot: NSView? = superview?.superview
        var depth = 0
        while let root = searchRoot, depth < 4 {
            if let found = findDescendantScrollView(
                under: root,
                excludingAncestors: ancestorIDs,
                windowPoint: windowPoint,
                probeWindowRect: probeWindowRect
            ) {
                return found
            }
            if root === window?.contentView { break }
            searchRoot = root.superview
            depth += 1
        }

        // Case B (applied on content inside `ScrollView(.horizontal) { HStack { ... }.orbitHorizontalWheelScroll() }`):
        if let enclosing = enclosingScrollView,
           isMatchingScrollView(enclosing, windowPoint: windowPoint, probeWindowRect: probeWindowRect) {
            return enclosing
        }

        return nil
    }

    private func findDescendantScrollView(
        under root: NSView,
        excludingAncestors ancestorIDs: Set<ObjectIdentifier>,
        windowPoint: NSPoint,
        probeWindowRect: NSRect
    ) -> NSScrollView? {
        if let sv = root as? NSScrollView,
           !ancestorIDs.contains(ObjectIdentifier(sv)),
           isMatchingScrollView(sv, windowPoint: windowPoint, probeWindowRect: probeWindowRect) {
            return sv
        }
        for subview in root.subviews {
            if let found = findDescendantScrollView(
                under: subview,
                excludingAncestors: ancestorIDs,
                windowPoint: windowPoint,
                probeWindowRect: probeWindowRect
            ) {
                return found
            }
        }
        return nil
    }

    private func isMatchingScrollView(
        _ scrollView: NSScrollView,
        windowPoint: NSPoint,
        probeWindowRect: NSRect
    ) -> Bool {
        guard !scrollView.isHiddenOrHasHiddenAncestor,
              !scrollView.visibleRect.isEmpty else {
            return false
        }
        let pointInSV = scrollView.convert(windowPoint, from: nil)
        guard scrollView.visibleRect.contains(pointInSV) else {
            return false
        }
        let svWindowRect = scrollView.convert(scrollView.visibleRect, to: nil)
        return svWindowRect.intersects(probeWindowRect)
    }
}

private struct OrbitHorizontalWheelProbeRepresentable: NSViewRepresentable {
    let stepMultiplier: CGFloat

    func makeNSView(context: Context) -> OrbitHorizontalWheelProbeView {
        let view = OrbitHorizontalWheelProbeView(frame: .zero)
        view.stepMultiplier = stepMultiplier
        return view
    }

    func updateNSView(_ nsView: OrbitHorizontalWheelProbeView, context: Context) {
        nsView.stepMultiplier = stepMultiplier
    }

    static func dismantleNSView(_ nsView: OrbitHorizontalWheelProbeView, coordinator: ()) {
        nsView.teardownMonitor()
    }
}

private struct OrbitHorizontalWheelScrollModifier: ViewModifier {
    let stepMultiplier: CGFloat

    func body(content: Content) -> some View {
        content.background(
            OrbitHorizontalWheelProbeRepresentable(stepMultiplier: stepMultiplier)
        )
    }
}

// MARK: - Card Style & Hover Feedback

private struct OrbitCardStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var envReduceMotion

    let cornerRadius: CGFloat
    let isHighlighted: Bool
    let highlightColor: Color
    let fillColor: Color?
    let hoverFillColor: Color?
    let borderColor: Color?
    let hoverLift: Bool
    let onHoverChanged: ((Bool) -> Void)?

    @State private var isHovered = false

    private var reduceMotion: Bool {
        envReduceMotion || OrbitMotion.isReducedMotion
    }

    private var isDark: Bool {
        colorScheme == .dark
    }

    /// Adaptive frosted glass base layer (HIG-aligned: crisp legibility over translucent Liquid Glass
    /// without stacking heavy multi-pass blur inside scrolling lists).
    private var adaptiveFrostedBase: Color {
        if fillColor == nil {
            if isDark {
                return Color(nsColor: .controlBackgroundColor).opacity(isHovered ? 0.56 : 0.46)
            } else {
                return Color.white.opacity(isHovered ? 0.68 : 0.56)
            }
        } else {
            // Preserve caller's custom fill while providing a delicate frosted contrast veil over Liquid Glass.
            if isDark {
                return Color(nsColor: .windowBackgroundColor).opacity(0.32)
            } else {
                return Color.white.opacity(0.46)
            }
        }
    }

    private var resolvedOverlayFill: Color? {
        if isHovered, let hoverFillColor {
            return hoverFillColor
        }
        if let fillColor {
            return fillColor
        }
        if isDark {
            return Color.white.opacity(isHovered ? 0.075 : 0.04)
        }
        return nil
    }

    private var strokeWidth: CGFloat {
        isHighlighted ? 1.0 : 0.75
    }

    private var resolvedBorderGradient: LinearGradient {
        if let borderColor {
            let primaryOpacity: Double = isHovered ? 0.96 : 0.85
            return LinearGradient(
                colors: [
                    borderColor.opacity(primaryOpacity),
                    borderColor.opacity(primaryOpacity * 0.72),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        if isHighlighted {
            return LinearGradient(
                colors: [
                    highlightColor.opacity(isHovered ? 0.78 : 0.60),
                    highlightColor.opacity(isHovered ? 0.46 : 0.32),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        if isDark {
            return LinearGradient(
                colors: [
                    Color.white.opacity(isHovered ? 0.26 : 0.18),
                    Color.white.opacity(isHovered ? 0.10 : 0.06),
                    Color.white.opacity(isHovered ? 0.06 : 0.035),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            return LinearGradient(
                colors: [
                    Color.white.opacity(isHovered ? 0.92 : 0.80),
                    Color.black.opacity(isHovered ? 0.09 : 0.06),
                    Color.black.opacity(isHovered ? 0.14 : 0.095),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var shadowColor: Color {
        if hoverLift {
            if isDark {
                return Color.black.opacity(isHovered ? 0.28 : 0.15)
            }
            return Color.black.opacity(isHovered ? 0.095 : 0.042)
        }
        return Color.black.opacity(isDark ? 0.09 : 0.025)
    }

    private var shadowRadius: CGFloat {
        hoverLift ? (isHovered ? 5.5 : 2.2) : 1.4
    }

    private var shadowYOffset: CGFloat {
        hoverLift ? (isHovered ? 2.0 : 0.8) : 0.5
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                ZStack {
                    shape.fill(adaptiveFrostedBase)
                    if let resolvedOverlayFill {
                        shape.fill(resolvedOverlayFill)
                    }
                    if isHighlighted {
                        shape.fill(highlightColor.opacity(isHovered ? 0.09 : 0.055))
                    } else if isHovered && hoverFillColor == nil && fillColor != nil {
                        shape.fill(Color.primary.opacity(isDark ? 0.035 : 0.02))
                    }
                }
            )
            .overlay(
                shape.strokeBorder(resolvedBorderGradient, lineWidth: strokeWidth)
            )
            .clipShape(shape)
            .shadow(
                color: shadowColor,
                radius: shadowRadius,
                x: 0,
                y: shadowYOffset
            )
            .animation(reduceMotion ? .linear(duration: 0.04) : OrbitMotion.hover, value: isHovered)
            .animation(reduceMotion ? .linear(duration: 0.04) : OrbitMotion.snappy, value: isHighlighted)
            .onHover { hovering in
                isHovered = hovering
                onHoverChanged?(hovering)
            }
    }
}

// MARK: - Interactive Button Style & Row Hover Highlight

public struct OrbitInteractiveButtonStyle: ButtonStyle {
    public var pressedScale: CGFloat
    public var hoverTint: Color?
    public var cornerRadius: CGFloat

    public init(
        pressedScale: CGFloat = 0.96,
        hoverTint: Color? = Color.primary.opacity(0.06),
        cornerRadius: CGFloat = 7
    ) {
        self.pressedScale = pressedScale
        self.hoverTint = hoverTint
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        OrbitInteractiveButtonBody(
            configuration: configuration,
            pressedScale: pressedScale,
            hoverTint: hoverTint,
            cornerRadius: cornerRadius
        )
    }
}

private struct OrbitInteractiveButtonBody: View {
    @Environment(\.accessibilityReduceMotion) private var envReduceMotion
    @Environment(\.isEnabled) private var isEnabled

    let configuration: ButtonStyle.Configuration
    let pressedScale: CGFloat
    let hoverTint: Color?
    let cornerRadius: CGFloat

    @State private var isHovered = false

    private var reduceMotion: Bool {
        envReduceMotion || OrbitMotion.isReducedMotion
    }

    var body: some View {
        configuration.label
            .background(
                Group {
                    if let hoverTint, isHovered, isEnabled {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(hoverTint)
                    }
                }
            )
            .scaleEffect((configuration.isPressed && isEnabled && !reduceMotion) ? pressedScale : 1.0)
            .opacity(configuration.isPressed && isEnabled ? 0.84 : 1.0)
            .animation(reduceMotion ? .linear(duration: 0.04) : OrbitMotion.hover, value: isHovered)
            .animation(reduceMotion ? .linear(duration: 0.04) : OrbitMotion.snappy, value: configuration.isPressed)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

private struct OrbitHoverHighlightModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var envReduceMotion

    let cornerRadius: CGFloat
    let tint: Color

    @State private var isHovered = false

    private var reduceMotion: Bool {
        envReduceMotion || OrbitMotion.isReducedMotion
    }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovered ? tint : Color.clear)
            )
            .animation(reduceMotion ? .linear(duration: 0.04) : OrbitMotion.hover, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

// MARK: - View Extensions

public extension View {
    /// Applies `.contentTransition(.numericText())` on macOS 14+ when Reduce Motion is off; safe no-op on macOS 13.
    func orbitNumericTransition(countsDown: Bool = false) -> some View {
        modifier(OrbitNumericTransitionModifier(countsDown: countsDown))
    }

    /// Applies native macOS 26+ Liquid Glass capsule styling (`.glassEffect(..., in: Capsule())`)
    /// with an ultra-thin material + fine translucent rim fallback on macOS 13–15.
    func orbitGlassCapsule(
        interactive: Bool = true,
        tint: Color? = nil
    ) -> some View {
        modifier(OrbitGlassCapsuleModifier(interactive: interactive, tint: tint))
    }

    /// Applies native macOS 26+ Liquid Glass rounded-rect styling
    /// with a regular material + specular highlight border fallback on macOS 13–15.
    func orbitGlassRounded(
        cornerRadius: CGFloat = 12,
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        modifier(
            OrbitGlassRoundedModifier(
                cornerRadius: cornerRadius,
                interactive: interactive,
                tint: tint
            )
        )
    }

    /// Translates vertical mouse-wheel scrolling over a horizontal `ScrollView(.horizontal)` into smooth
    /// horizontal scrolling while preserving native horizontal trackpad swipes and outer vertical scrolling.
    func orbitHorizontalWheelScroll(stepMultiplier: CGFloat = 20) -> some View {
        modifier(OrbitHorizontalWheelScrollModifier(stepMultiplier: stepMultiplier))
    }

    /// Elevated translucent frosted-glass card container tuned for Apple Liquid Glass HIG contrast
    /// with top-lit specular border highlight and subtle elevation shadow.
    func orbitCardStyle(
        cornerRadius: CGFloat = 11,
        isHighlighted: Bool = false,
        highlightColor: Color = .accentColor,
        fillColor: Color? = nil,
        hoverFillColor: Color? = nil,
        borderColor: Color? = nil,
        hoverLift: Bool = true,
        onHoverChanged: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(
            OrbitCardStyleModifier(
                cornerRadius: cornerRadius,
                isHighlighted: isHighlighted,
                highlightColor: highlightColor,
                fillColor: fillColor,
                hoverFillColor: hoverFillColor,
                borderColor: borderColor,
                hoverLift: hoverLift,
                onHoverChanged: onHoverChanged
            )
        )
    }

    /// Applies gentle hover background feedback and tactile press micro-scaling to a Button.
    func orbitInteractiveButton(
        pressedScale: CGFloat = 0.96,
        hoverTint: Color? = Color.primary.opacity(0.06),
        cornerRadius: CGFloat = 7
    ) -> some View {
        buttonStyle(
            OrbitInteractiveButtonStyle(
                pressedScale: pressedScale,
                hoverTint: hoverTint,
                cornerRadius: cornerRadius
            )
        )
    }

    /// Subtle rounded hover highlight for non-button interactive rows.
    func orbitHoverHighlight(
        cornerRadius: CGFloat = 7,
        tint: Color = Color.primary.opacity(0.045)
    ) -> some View {
        modifier(OrbitHoverHighlightModifier(cornerRadius: cornerRadius, tint: tint))
    }
}
