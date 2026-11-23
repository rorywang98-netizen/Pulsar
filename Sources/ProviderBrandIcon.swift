import AppKit
import Foundation
import SwiftUI

// MARK: - Official Provider Brand Icon Loader & Cache

/// Thread-safe loader and cache for official brand PNG icons of each supported provider.
///
/// Lookup order for `<provider.rawValue>.png`:
/// 1. `Bundle.main.url(forResource: provider.rawValue, withExtension: "png", subdirectory: "ProviderIcons")`
/// 2. `Bundle.main.resourceURL/ProviderIcons/<rawValue>.png`
/// 3. Upward search from the running executable directory (`Assets/ProviderIcons/` or `Contents/Resources/ProviderIcons/`)
/// 4. Upward search from the current working directory (`Assets/ProviderIcons/`)
/// 5. Dev/unit-test source-tree fallback relative to this Swift file (`../Assets/ProviderIcons/`)
public enum ProviderBrandIcon {
    /// Relative subdirectory inside `RoryOrbit.app/Contents/Resources/`.
    public static let bundleSubdirectory = "ProviderIcons"

    /// Relative path inside the source repository for dev / test runs outside the `.app` bundle.
    public static let devRelativeDirectory = "Assets/ProviderIcons"

    private struct MenuBarCacheKey: Hashable {
        let provider: ProviderID
        let sizeTenths: Int
    }

    private static let lock = NSLock()
    private static var baseImageCache: [ProviderID: NSImage] = [:]
    private static var menuBarImageCache: [MenuBarCacheKey: NSImage] = [:]
    private static var pulsarAppImageCache: NSImage?
    private static var pulsarTemplateImageCache: NSImage?

    private static let pulsarAppAssetName = "pulsar"
    private static let pulsarTemplateAssetName = "pulsar-template"

    /// Returns whether the provider's official icon is a monochrome mark that should render
    /// as a template (auto-adapting black/white for macOS Light/Dark mode and accent tints).
    ///
    /// - `codex` (OpenAI 6-petal blossom) and `grok` (xAI Grok slash-orbit): monochrome template marks (`true`)
    /// - `antigravity` (Google gradient A), `claude` (Claude terracotta 12-ray sunburst), `cursor` (3D metallic cube),
    ///   `kimi` (Kimi K + blue dot app icon), `deepseek` (DeepSeek `#4D6BFE` blue whale): full-color official artwork (`false`)
    public static func isTemplateMark(for provider: ProviderID) -> Bool {
        switch provider {
        case .codex, .grok:
            return true
        case .antigravity, .claude, .cursor, .kimi, .deepseek:
            return false
        }
    }

    /// Semantic alias for `isTemplateMark(for:)`.
    public static func isMonochromeMark(for provider: ProviderID) -> Bool {
        isTemplateMark(for: provider)
    }

    /// Resolves the on-disk PNG URL for `provider`, following the bundle-first lookup order.
    public static func resourceURL(for provider: ProviderID, bundle: Bundle = .main) -> URL? {
        resourceURL(named: provider.rawValue, bundle: bundle)
    }

    /// Resolves a named PNG inside `ProviderIcons/` (or dev `Assets/ProviderIcons/`)
    /// following the same 5-tier bundle-first lookup order used by provider icons.
    private static func resourceURL(named filename: String, bundle: Bundle = .main) -> URL? {
        // 1. Primary: app bundle Resources/ProviderIcons/<filename>.png
        if let bundled = bundle.url(
            forResource: filename,
            withExtension: "png",
            subdirectory: bundleSubdirectory
        ) {
            return bundled
        }

        let fm = FileManager.default

        // 2. Direct resourceURL fallback (covers edge cases where Bundle lookup misses uncached subdir)
        if let resURL = bundle.resourceURL?
            .appendingPathComponent(bundleSubdirectory, isDirectory: true)
            .appendingPathComponent("\(filename).png"),
           fm.fileExists(atPath: resURL.path) {
            return resURL
        }

        // 3. Walk upward from the executable URL (dev CLI binaries & test runners inside build dirs)
        if let execDir = bundle.executableURL?.deletingLastPathComponent() {
            if let found = searchUpward(from: execDir, filename: filename, fileManager: fm) {
                return found
            }
        }

        // 4. Walk upward from current working directory
        let cwdURL = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        if let found = searchUpward(from: cwdURL, filename: filename, fileManager: fm) {
            return found
        }

        // 5. Dev/unit-test source-tree fallback (when test binary is compiled into /var/folders temp dir)
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sources/
            .deletingLastPathComponent() // repo root
        let sourceCandidate = sourceRoot
            .appendingPathComponent(devRelativeDirectory, isDirectory: true)
            .appendingPathComponent("\(filename).png")
        if fm.fileExists(atPath: sourceCandidate.path) {
            return sourceCandidate
        }

        return nil
    }

    /// Returns the cached full-resolution (`128×128`) official brand `NSImage` for `provider`,
    /// or `nil` only if no PNG resource is available (e.g. in an isolated sandbox without assets).
    public static func image(for provider: ProviderID) -> NSImage? {
        lock.lock()
        if let cached = baseImageCache[provider] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let url = resourceURL(for: provider),
              let loaded = loadImage(from: url, provider: provider) else {
            return nil
        }

        lock.lock()
        if let existing = baseImageCache[provider] {
            lock.unlock()
            return existing
        }
        baseImageCache[provider] = loaded
        lock.unlock()
        return loaded
    }

    /// Returns an `NSImage` sized and configured for the macOS menu bar (`NSStatusBarButton`).
    ///
    /// - Monochrome marks (`codex`, `grok`) are flagged `isTemplate = true` so AppKit adapts them
    ///   automatically for Light/Dark menu bars and inactive displays.
    /// - Full-color official brand icons (`antigravity`, `claude`, `cursor`, `kimi`, `deepseek`) keep
    ///   `isTemplate = false` at full Retina clarity.
    /// - Falls back gracefully to the provider's SF Symbol if no PNG asset can be found.
    public static func menuBarImage(for provider: ProviderID, size: CGFloat = 15) -> NSImage? {
        let clampedSize = max(8, size)
        let key = MenuBarCacheKey(
            provider: provider,
            sizeTenths: Int((clampedSize * 10).rounded())
        )

        lock.lock()
        if let cached = menuBarImageCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        if let base = image(for: provider) {
            let sized = makeSizedMenuBarCopy(from: base, provider: provider, size: clampedSize)
            lock.lock()
            if let existing = menuBarImageCache[key] {
                lock.unlock()
                return existing
            }
            menuBarImageCache[key] = sized
            lock.unlock()
            return sized
        }

        return fallbackMenuBarSymbolImage(for: provider, size: clampedSize)
    }

    /// Convenience check for whether the official PNG asset for `provider` is resolvable.
    public static func hasOfficialAsset(for provider: ProviderID) -> Bool {
        image(for: provider) != nil
    }

    // MARK: - Pulsar Brand Icon Loaders

    /// Returns the cached full-color Pulsar brand `NSImage` (`ProviderIcons/pulsar.png`,
    /// falling back to `Assets/ProviderIcons/pulsar.png` in dev/test runs), or `nil` if unavailable.
    public static func pulsarAppImage() -> NSImage? {
        lock.lock()
        if let cached = pulsarAppImageCache {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let url = resourceURL(named: pulsarAppAssetName),
              let loaded = loadNamedImage(
                  from: url,
                  isTemplate: false,
                  accessibilityDescription: "Pulsar"
              ) else {
            return nil
        }

        lock.lock()
        if let existing = pulsarAppImageCache {
            lock.unlock()
            return existing
        }
        pulsarAppImageCache = loaded
        lock.unlock()
        return loaded
    }

    /// Returns an independent, sized template `NSImage` (`isTemplate = true`) of the Pulsar
    /// monochrome menu bar mark (`ProviderIcons/pulsar-template.png`), falling back gracefully
    /// to the `sparkles` SF Symbol when the PNG asset cannot be resolved.
    public static func pulsarMenuBarImage(size: CGFloat = 15) -> NSImage? {
        let clampedSize = max(8, size)
        if let base = cachedPulsarTemplateBaseImage() {
            return makeSizedCopy(
                from: base,
                size: clampedSize,
                isTemplate: true,
                accessibilityDescription: "Pulsar"
            )
        }
        return fallbackPulsarMenuBarSymbolImage(size: clampedSize)
    }

    /// Clears in-memory icon caches (primarily for unit tests).
    public static func clearCache() {
        lock.lock()
        baseImageCache.removeAll()
        menuBarImageCache.removeAll()
        pulsarAppImageCache = nil
        pulsarTemplateImageCache = nil
        lock.unlock()
    }

    // MARK: - Private Helpers

    private static func searchUpward(
        from startDirectory: URL,
        filename: String,
        fileManager: FileManager,
        maxDepth: Int = 6
    ) -> URL? {
        var current = startDirectory.standardizedFileURL
        for _ in 0...maxDepth {
            let devCandidate = current
                .appendingPathComponent(devRelativeDirectory, isDirectory: true)
                .appendingPathComponent("\(filename).png")
            if fileManager.fileExists(atPath: devCandidate.path) {
                return devCandidate
            }

            let bundleCandidate = current
                .appendingPathComponent("Contents/Resources/\(bundleSubdirectory)", isDirectory: true)
                .appendingPathComponent("\(filename).png")
            if fileManager.fileExists(atPath: bundleCandidate.path) {
                return bundleCandidate
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }
        return nil
    }

    private static func loadImage(from url: URL, provider: ProviderID) -> NSImage? {
        loadNamedImage(
            from: url,
            isTemplate: isTemplateMark(for: provider),
            accessibilityDescription: provider.displayName
        )
    }

    private static func loadNamedImage(
        from url: URL,
        isTemplate: Bool,
        accessibilityDescription: String
    ) -> NSImage? {
        guard let image = NSImage(contentsOf: url),
              image.isValid,
              !image.representations.isEmpty else {
            return nil
        }
        image.isTemplate = isTemplate
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private static func cachedPulsarTemplateBaseImage() -> NSImage? {
        lock.lock()
        if let cached = pulsarTemplateImageCache {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let url = resourceURL(named: pulsarTemplateAssetName),
              let loaded = loadNamedImage(
                  from: url,
                  isTemplate: true,
                  accessibilityDescription: "Pulsar"
              ) else {
            return nil
        }

        lock.lock()
        if let existing = pulsarTemplateImageCache {
            lock.unlock()
            return existing
        }
        pulsarTemplateImageCache = loaded
        lock.unlock()
        return loaded
    }

    private static func makeSizedMenuBarCopy(
        from base: NSImage,
        provider: ProviderID,
        size: CGFloat
    ) -> NSImage {
        makeSizedCopy(
            from: base,
            size: size,
            isTemplate: isTemplateMark(for: provider),
            accessibilityDescription: provider.displayName
        )
    }

    private static func makeSizedCopy(
        from base: NSImage,
        size: CGFloat,
        isTemplate: Bool,
        accessibilityDescription: String
    ) -> NSImage {
        let targetSize = NSSize(width: size, height: size)
        let copy: NSImage
        if let copied = base.copy() as? NSImage, !copied.representations.isEmpty {
            copy = copied
        } else {
            copy = NSImage(size: targetSize)
            for rep in base.representations {
                copy.addRepresentation(rep)
            }
        }
        copy.size = targetSize
        copy.isTemplate = isTemplate
        copy.accessibilityDescription = accessibilityDescription
        return copy
    }

    private static func fallbackMenuBarSymbolImage(
        for provider: ProviderID,
        size: CGFloat
    ) -> NSImage? {
        fallbackSymbolImage(
            systemSymbolName: provider.symbolName,
            accessibilityDescription: provider.displayName,
            size: size
        )
    }

    private static func fallbackPulsarMenuBarSymbolImage(size: CGFloat) -> NSImage? {
        fallbackSymbolImage(
            systemSymbolName: "sparkles",
            accessibilityDescription: "Pulsar",
            size: size
        )
    }

    private static func fallbackSymbolImage(
        systemSymbolName: String,
        accessibilityDescription: String,
        size: CGFloat
    ) -> NSImage? {
        guard let symbol = NSImage(
            systemSymbolName: systemSymbolName,
            accessibilityDescription: accessibilityDescription
        ) else {
            return nil
        }
        let pointSize = max(11, size - 2)
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        let configured = symbol.withSymbolConfiguration(config) ?? symbol
        configured.isTemplate = true
        return configured
    }
}

// MARK: - SwiftUI Official Brand Icon View

/// Renders the official brand PNG icon for a `ProviderID` (`ProviderKind`) with high-quality
/// interpolation, theme-aware template rendering for monochrome marks, optional rounded clipping,
/// and graceful SF Symbol fallback when running in an asset-less sandbox test environment.
public struct ProviderBrandIconView: View {
    public let provider: ProviderID
    public var size: CGFloat
    public var cornerRadius: CGFloat?
    public var renderingAccent: Color?

    public init(
        provider: ProviderID,
        size: CGFloat = 15,
        cornerRadius: CGFloat? = nil,
        renderingAccent: Color? = nil
    ) {
        self.provider = provider
        self.size = size
        self.cornerRadius = cornerRadius
        self.renderingAccent = renderingAccent
    }

    public var body: some View {
        Group {
            if let nsImage = ProviderBrandIcon.image(for: provider) {
                renderedBrandImage(nsImage)
            } else {
                fallbackSymbolView
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(provider.displayName))
    }

    @ViewBuilder
    private func renderedBrandImage(_ nsImage: NSImage) -> some View {
        let isTemplate = ProviderBrandIcon.isTemplateMark(for: provider)
        let base = Image(nsImage: nsImage)
            .renderingMode(isTemplate ? .template : .original)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)

        let styled = Group {
            if isTemplate {
                base.foregroundColor(renderingAccent ?? .primary)
            } else {
                base
            }
        }

        if let radius = cornerRadius, radius > 0 {
            styled.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            styled
        }
    }

    private var fallbackSymbolView: some View {
        Image(systemName: provider.symbolName)
            .font(.system(size: max(10, size * 0.8), weight: .semibold))
            .foregroundColor(renderingAccent ?? .secondary)
    }
}

// MARK: - SwiftUI Pulsar Brand Icon View

/// Renders the official Pulsar app icon (`ProviderIcons/pulsar.png`) with high-quality
/// interpolation, continuous squircle framing, ultra-thin glass highlight edge, optional
/// cosmic blue-violet glow shadow, and a graceful cosmic gradient fallback when assets are absent.
public struct PulsarBrandIconView: View {
    public var size: CGFloat
    public var cornerRadius: CGFloat?
    public var showGlowShadow: Bool

    public init(size: CGFloat = 32, cornerRadius: CGFloat? = nil, showGlowShadow: Bool = true) {
        self.size = size
        self.cornerRadius = cornerRadius
        self.showGlowShadow = showGlowShadow
    }

    private var effectiveCornerRadius: CGFloat {
        if let explicit = cornerRadius {
            return max(0, explicit)
        }
        return max(4, size * 0.224)
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: effectiveCornerRadius, style: .continuous)

        Group {
            if let nsImage = ProviderBrandIcon.pulsarAppImage() {
                renderedArtwork(nsImage, shape: shape)
            } else {
                fallbackBadgeView(shape: shape)
            }
        }
        .frame(width: size, height: size)
        .shadow(
            color: showGlowShadow
                ? Color(red: 0.34, green: 0.44, blue: 1.0).opacity(0.32)
                : .clear,
            radius: showGlowShadow ? max(3, size * 0.16) : 0,
            x: 0,
            y: showGlowShadow ? max(1, size * 0.06) : 0
        )
        .shadow(
            color: showGlowShadow
                ? Color(red: 0.24, green: 0.78, blue: 1.0).opacity(0.14)
                : .clear,
            radius: showGlowShadow ? max(1.5, size * 0.07) : 0,
            x: 0,
            y: 0
        )
        .accessibilityLabel(Text("Pulsar"))
    }

    @ViewBuilder
    private func renderedArtwork(
        _ nsImage: NSImage,
        shape: RoundedRectangle
    ) -> some View {
        let img = Image(nsImage: nsImage)
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)

        Group {
            if let explicit = cornerRadius, explicit > 0 {
                img.clipShape(shape)
            } else {
                img
            }
        }
        .overlay(glassHighlightOverlay(shape: shape))
    }

    private func fallbackBadgeView(shape: RoundedRectangle) -> some View {
        ZStack {
            shape.fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.07, green: 0.10, blue: 0.25),
                        Color(red: 0.16, green: 0.11, blue: 0.38),
                        Color(red: 0.06, green: 0.09, blue: 0.22)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            shape.fill(
                RadialGradient(
                    colors: [
                        Color(red: 0.38, green: 0.84, blue: 1.0).opacity(0.42),
                        Color(red: 0.45, green: 0.34, blue: 0.96).opacity(0.16),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.62
                )
            )
            Image(systemName: "sparkles")
                .font(.system(size: max(11, size * 0.48), weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color.white,
                            Color(red: 0.62, green: 0.92, blue: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay(glassHighlightOverlay(shape: shape))
    }

    private func glassHighlightOverlay(shape: RoundedRectangle) -> some View {
        shape
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color(red: 0.74, green: 0.90, blue: 1.0).opacity(0.30),
                        Color(red: 0.56, green: 0.52, blue: 1.0).opacity(0.16),
                        Color(red: 0.42, green: 0.58, blue: 1.0).opacity(0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: max(0.5, min(1.25, size * 0.025))
            )
            .padding(cornerRadius == nil ? max(0, size * 0.008) : 0)
    }
}
