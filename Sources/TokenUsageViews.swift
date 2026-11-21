import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared Theme & Formatting Helpers for Local Token Analytics

enum TokenAnalyticsStyle {
    static let uncachedInputColor = Color(red: 0.24, green: 0.51, blue: 0.96)
    static let outputColor        = Color(red: 0.58, green: 0.36, blue: 0.94)
    static let cacheReadColor     = Color(red: 0.14, green: 0.72, blue: 0.48)
    static let cacheWriteColor    = Color(red: 0.93, green: 0.55, blue: 0.18)
    static let speedAccentColor   = Color(red: 0.95, green: 0.58, blue: 0.14)
    static let privacyGreen       = Color(nsColor: .systemGreen)

    static func color(for client: TokenClientID) -> Color {
        if let parsed = colorFromHex(client.hexColor) {
            return parsed
        }
        switch client {
        case .claude:      return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex:       return Color(red: 0.10, green: 0.68, blue: 0.54)
        case .cursor:      return Color(red: 0.24, green: 0.51, blue: 0.96)
        case .antigravity: return Color(red: 0.54, green: 0.36, blue: 0.94)
        case .grok:        return Color(red: 0.92, green: 0.62, blue: 0.14)
        case .dsh:         return Color(red: 0.14, green: 0.65, blue: 0.86)
        case .kimi:        return Color(red: 0.84, green: 0.34, blue: 0.64)
        case .opencode:    return Color(red: 0.38, green: 0.72, blue: 0.26)
        case .zcode:       return Color(red: 0.88, green: 0.34, blue: 0.36)
        case .workbuddy:   return Color(red: 0.58, green: 0.52, blue: 0.48)
        case .other:       return Color.secondary
        }
    }

    static func heatmapColor(level: Int, tint: Color? = nil) -> Color {
        let base = tint ?? Color(red: 0.14, green: 0.69, blue: 0.43)
        switch level {
        case 0:  return Color.primary.opacity(0.07)
        case 1:  return base.opacity(0.30)
        case 2:  return base.opacity(0.54)
        case 3:  return base.opacity(0.77)
        default: return base
        }
    }

    static func colorFromHex(_ hex: String) -> Color? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else {
            return nil
        }
        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    static func shortMonthDay(_ yyyyMMdd: String) -> String {
        guard yyyyMMdd.count >= 10 else { return yyyyMMdd }
        let idx = yyyyMMdd.index(yyyyMMdd.startIndex, offsetBy: 5)
        return String(yyyyMMdd[idx...])
    }

    static func shortYearMonthDay(_ yyyyMMdd: String) -> String {
        guard yyyyMMdd.count >= 10 else { return yyyyMMdd }
        let start = yyyyMMdd.index(yyyyMMdd.startIndex, offsetBy: 2)
        return String(yyyyMMdd[start...]).replacingOccurrences(of: "-", with: "/", range: nil)
    }

    static func compactCount(_ count: Int) -> String {
        let absVal = abs(count)
        if absVal >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        }
        if absVal >= 10_000 {
            return String(format: "%.1fK", Double(count) / 1_000.0)
        }
        return exactCount(count)
    }

    static func exactCount(_ count: Int) -> String {
        let negative = count < 0
        let digits = String(abs(count))
        guard digits.count > 3 else {
            return negative ? "-\(digits)" : digits
        }
        var out = ""
        out.reserveCapacity(digits.count + digits.count / 3 + (negative ? 1 : 0))
        if negative { out.append("-") }
        let firstGroup = digits.count % 3
        for (idx, ch) in digits.enumerated() {
            if idx > 0 && ((idx - firstGroup) % 3 == 0) {
                out.append(",")
            }
            out.append(ch)
        }
        return out
    }

    static func weekdayShortCN(for yyyyMMdd: String) -> String {
        guard let date = TokenFormatters.date(fromYMD: yyyyMMdd) else { return "" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let wd = cal.component(.weekday, from: date)
        switch wd {
        case 1: return "周日"
        case 2: return "周一"
        case 3: return "周二"
        case 4: return "周三"
        case 5: return "周四"
        case 6: return "周五"
        case 7: return "周六"
        default: return ""
        }
    }

    static func weekdayIndexMonFirst(for yyyyMMdd: String) -> Int {
        guard let date = TokenFormatters.date(fromYMD: yyyyMMdd) else { return 0 }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        // Calendar weekday: 1=Sun, 2=Mon, ..., 7=Sat -> Mon=0, ..., Sun=6
        let wd = cal.component(.weekday, from: date)
        return (wd + 5) % 7
    }

    static func monthLabelCN(for yyyyMMdd: String) -> String {
        guard yyyyMMdd.count >= 7 else { return "" }
        let start = yyyyMMdd.index(yyyyMMdd.startIndex, offsetBy: 5)
        let end = yyyyMMdd.index(yyyyMMdd.startIndex, offsetBy: 7)
        let monthInt = Int(yyyyMMdd[start..<end]) ?? 0
        return monthInt > 0 ? "\(monthInt)月" : ""
    }

    static func shortDuration(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "0s" }
        if seconds < 10.0 {
            return String(format: "%.1fs", seconds)
        }
        return String(format: "%.0fs", seconds)
    }

    /// Compact date label for the toolbar Custom Date button (zero truncation even at 340pt).
    static func toolbarCustomButtonLabel(
        for selection: TokenUsageDateSelection,
        ultraCompact: Bool
    ) -> String {
        guard let bounds = selection.customBounds else {
            return "自定义"
        }
        let fullLabel = TokenFormatters.customRangeLabel(startDate: bounds.startDate, endDate: bounds.endDate)
        if !ultraCompact {
            return fullLabel.replacingOccurrences(of: " ~ ", with: "~")
        }
        if bounds.startDate == bounds.endDate {
            return shortMonthDay(bounds.startDate)
        }
        return "\(shortMonthDay(bounds.startDate))~\(shortMonthDay(bounds.endDate))"
    }

    /// Groups chronological `TokenDailyPoint` items into Monday-first calendar week columns (7 rows each).
    static func buildHeatmapWeeks(from cells: [TokenDailyPoint]) -> [[TokenDailyPoint?]] {
        guard !cells.isEmpty else { return [] }
        let ordered = cells.sorted { $0.date < $1.date }
        var weeks: [[TokenDailyPoint?]] = []
        var currentWeek = Array<TokenDailyPoint?>(repeating: nil, count: 7)

        for (index, cell) in ordered.enumerated() {
            let row = weekdayIndexMonFirst(for: cell.date)
            if index > 0 && row == 0 {
                weeks.append(currentWeek)
                currentWeek = Array<TokenDailyPoint?>(repeating: nil, count: 7)
            }
            currentWeek[row] = cell
        }
        if currentWeek.contains(where: { $0 != nil }) {
            weeks.append(currentWeek)
        }
        return weeks
    }

    /// Returns a month label for column `colIdx` while preventing label collisions on tight narrow grids.
    static func monthHeaderLabel(
        for colIdx: Int,
        weeks: [[TokenDailyPoint?]],
        minColumnGap: Int = 2
    ) -> String {
        guard colIdx < weeks.count else { return "" }
        let firstDateInCol = weeks[colIdx].compactMap({ $0?.date }).first ?? ""
        let currentMonth = monthLabelCN(for: firstDateInCol)
        guard !currentMonth.isEmpty else { return "" }

        if colIdx == 0 {
            if minColumnGap >= 2 && weeks.count > 1 {
                let nextDate = weeks[1].compactMap({ $0?.date }).first ?? ""
                let nextMonth = monthLabelCN(for: nextDate)
                if !nextMonth.isEmpty && nextMonth != currentMonth {
                    return ""
                }
            }
            return currentMonth
        }

        let prevDate = weeks[colIdx - 1].compactMap({ $0?.date }).first ?? ""
        let prevMonth = monthLabelCN(for: prevDate)
        guard currentMonth != prevMonth else { return "" }

        if minColumnGap >= 2 && colIdx == weeks.count - 1 {
            let prevPrevDate = colIdx >= 2 ? (weeks[colIdx - 2].compactMap({ $0?.date }).first ?? "") : ""
            let prevPrevMonth = monthLabelCN(for: prevPrevDate)
            if !prevPrevMonth.isEmpty && prevPrevMonth != prevMonth {
                return ""
            }
        }
        return currentMonth
    }
}

// MARK: - Local JSON Export Payload

private struct ExportedTokenUsageReport: Codable {
    let exportedAt: Date
    let appName: String
    let appVersion: String
    let selectionLabel: String
    let startDate: String
    let endDate: String
    let isCustomRange: Bool
    let clientFilter: String?
    let summary: TokenRangeSummary
    let liveSpeed: LiveTokenSpeedSnapshot
}

// MARK: - Reusable Subcomponents

private struct LocalPrivacyBadge: View {
    var text: String
    var compact: Bool = true

    var body: some View {
        HStack(spacing: compact ? 3.5 : 5) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold))
            Text(text)
                .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundColor(TokenAnalyticsStyle.privacyGreen)
        .padding(.horizontal, compact ? 6.5 : 8.5)
        .padding(.vertical, compact ? 2.5 : 3.5)
        .background(TokenAnalyticsStyle.privacyGreen.opacity(0.13))
        .overlay(
            Capsule()
                .stroke(TokenAnalyticsStyle.privacyGreen.opacity(0.28), lineWidth: 0.7)
        )
        .clipShape(Capsule())
    }
}

private struct TokenCompositionBar: View {
    let totals: TokenComponentTotals
    var height: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var envReduceMotion

    private var reduceMotion: Bool {
        envReduceMotion || OrbitMotion.isReducedMotion
    }

    private var shares: [Double] {
        let input = Double(max(0, totals.uncachedInputTokens))
        let output = Double(max(0, totals.outputTokens))
        let cacheRead = Double(max(0, totals.cacheReadTokens))
        let cacheWrite = Double(max(0, totals.cacheWriteTokens))
        let sum = input + output + cacheRead + cacheWrite
        guard sum > 0 else { return [0, 0, 0, 0] }
        return [input / sum, output / sum, cacheRead / sum, cacheWrite / sum]
    }

    private static let palette: [Color] = [
        TokenAnalyticsStyle.uncachedInputColor,
        TokenAnalyticsStyle.outputColor,
        TokenAnalyticsStyle.cacheReadColor,
        TokenAnalyticsStyle.cacheWriteColor,
    ]

    private func segmentWidths(totalWidth: CGFloat) -> [CGFloat] {
        let ratios = shares
        let activeIndices = ratios.indices.filter { ratios[$0] > 0.0005 }
        guard !activeIndices.isEmpty, totalWidth > 0 else {
            return [0, 0, 0, 0]
        }

        let gap: CGFloat = 1.0
        let totalGap = CGFloat(max(0, activeIndices.count - 1)) * gap
        let usable = max(0, totalWidth - totalGap)
        var widths = [CGFloat](repeating: 0, count: 4)
        var clampedDelta: CGFloat = 0

        for idx in activeIndices {
            let raw = usable * CGFloat(ratios[idx])
            if raw < 2.0 && usable >= CGFloat(activeIndices.count) * 2.0 {
                widths[idx] = 2.0
                clampedDelta += (2.0 - raw)
            } else {
                widths[idx] = raw
            }
        }

        if clampedDelta > 0, let largestIdx = activeIndices.max(by: { widths[$0] < widths[$1] }) {
            widths[largestIdx] = max(2.0, widths[largestIdx] - clampedDelta)
        }
        return widths
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let widths = segmentWidths(totalWidth: w)
            let lastActive = shares.lastIndex(where: { $0 > 0.0005 })

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))

                if lastActive != nil {
                    HStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { idx in
                            let segW = widths[idx]
                            let isActive = segW > 0.1
                            let trailingGap: CGFloat = (isActive && lastActive != nil && idx < lastActive!) ? 1.0 : 0.0
                            Rectangle()
                                .fill(Self.palette[idx])
                                .frame(width: segW)
                                .opacity(isActive ? 1.0 : 0.0)
                                .padding(.trailing, trailingGap)
                        }
                    }
                    .clipShape(Capsule())
                    .animation(reduceMotion ? .linear(duration: 0.05) : OrbitMotion.smooth, value: totals)
                }
            }
        }
        .frame(height: height)
    }
}

private struct TokenCompositionLegend: View {
    let totals: TokenComponentTotals
    var compact: Bool = true
    var twoColumnGrid: Bool = false

    var body: some View {
        if twoColumnGrid {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8, alignment: .leading),
                    GridItem(.flexible(), spacing: 8, alignment: .leading),
                ],
                alignment: .leading,
                spacing: 3
            ) {
                gridLegendItem(color: TokenAnalyticsStyle.uncachedInputColor, label: "输入", value: totals.uncachedInputTokens)
                gridLegendItem(color: TokenAnalyticsStyle.outputColor, label: "输出", value: totals.outputTokens)
                gridLegendItem(color: TokenAnalyticsStyle.cacheReadColor, label: "缓读", value: totals.cacheReadTokens)
                gridLegendItem(color: TokenAnalyticsStyle.cacheWriteColor, label: "缓写", value: totals.cacheWriteTokens)
            }
        } else {
            HStack(spacing: compact ? 6.5 : 10) {
                legendItem(color: TokenAnalyticsStyle.uncachedInputColor, label: "输入", value: totals.uncachedInputTokens)
                legendItem(color: TokenAnalyticsStyle.outputColor, label: "输出", value: totals.outputTokens)
                legendItem(color: TokenAnalyticsStyle.cacheReadColor, label: "缓读", value: totals.cacheReadTokens)
                legendItem(color: TokenAnalyticsStyle.cacheWriteColor, label: "缓写", value: totals.cacheWriteTokens)
                Spacer(minLength: 0)
            }
        }
    }

    private func legendItem(color: Color, label: String, value: Int64) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5.5, height: 5.5)
            Text(label)
                .font(.system(size: compact ? 9.5 : 10))
                .foregroundColor(.secondary)
            Text(TokenFormatters.compactTokens(value))
                .font(.system(size: compact ? 9.5 : 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.primary.opacity(0.88))
                .orbitNumericTransition()
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func gridLegendItem(color: Color, label: String, value: Int64) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5.5, height: 5.5)
            Text(label)
                .font(.system(size: 9.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(TokenFormatters.compactTokens(value))
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.primary.opacity(0.88))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .orbitNumericTransition()
        }
    }
}

private struct ClientPillBadge: View {
    let client: TokenClientID
    var useShortName: Bool = true
    var compact: Bool = false

    var body: some View {
        let tint = TokenAnalyticsStyle.color(for: client)
        HStack(spacing: compact ? 3 : 3.5) {
            Circle()
                .fill(tint)
                .frame(width: compact ? 5 : 5.5, height: compact ? 5 : 5.5)
            Text(useShortName ? client.shortName : client.displayName)
                .font(.system(size: compact ? 9 : 9.5, weight: .semibold))
                .foregroundColor(tint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, compact ? 5 : 6)
        .padding(.vertical, compact ? 1.5 : 2)
        .background(tint.opacity(0.13))
        .clipShape(Capsule())
    }
}

private struct SpeedPillBadge: View {
    let rate: Double
    var isLive: Bool = false
    var compact: Bool = false

    var body: some View {
        let tint: Color = isLive ? Color(nsColor: .systemGreen) : TokenAnalyticsStyle.speedAccentColor
        HStack(spacing: compact ? 2 : 2.5) {
            Image(systemName: "bolt.fill")
                .font(.system(size: compact ? 7.5 : 8, weight: .bold))
            Text(TokenFormatters.tokensPerSec(rate))
                .font(.system(size: compact ? 9 : 9.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .orbitNumericTransition()
        }
        .foregroundColor(tint)
        .padding(.horizontal, compact ? 4.5 : 5.5)
        .padding(.vertical, compact ? 1.5 : 2)
        .background(tint.opacity(0.12))
        .overlay(
            Capsule()
                .stroke(tint.opacity(0.24), lineWidth: 0.6)
        )
        .clipShape(Capsule())
    }
}

private struct CardOrderActionButton: View {
    let systemImage: String
    let disabled: Bool
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(disabled ? .secondary.opacity(0.32) : .secondary)
                .frame(width: 21, height: 21)
                .background(Color.primary.opacity(disabled ? 0.02 : 0.055))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(helpText)
    }
}

// MARK: - Drag & Drop Delegate for Reordering Client Filter Chips

private struct TokenClientChipDropDelegate: DropDelegate {
    let targetClient: TokenClientID
    let availableClients: [TokenClientID]
    @ObservedObject var store: AppStore
    @Binding var draggingClient: TokenClientID?
    @Binding var dragOverClient: TokenClientID?
    let animation: Animation

    func dropEntered(info: DropInfo) {
        dragOverClient = targetClient
        guard let source = draggingClient, source != targetClient else { return }
        let currentOrder = store.orderedTokenClients(from: availableClients)
        guard let targetIndex = currentOrder.firstIndex(of: targetClient) else { return }
        withAnimation(animation) {
            store.moveTokenClient(source, toIndex: targetIndex, available: availableClients)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dragOverClient == targetClient {
            dragOverClient = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let currentOrder = store.orderedTokenClients(from: availableClients)
        if let source = draggingClient {
            if source != targetClient, let targetIndex = currentOrder.firstIndex(of: targetClient) {
                withAnimation(animation) {
                    store.moveTokenClient(source, toIndex: targetIndex, available: availableClients)
                }
            }
            draggingClient = nil
            dragOverClient = nil
            return true
        }

        if let provider = info.itemProviders(for: [.plainText]).first {
            let storeRef = store
            let available = availableClients
            let target = targetClient
            let anim = animation
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let raw = object as? String,
                      let source = TokenClientID(rawValue: raw),
                      source != target else {
                    return
                }
                DispatchQueue.main.async {
                    let ordered = storeRef.orderedTokenClients(from: available)
                    guard let targetIndex = ordered.firstIndex(of: target) else { return }
                    withAnimation(anim) {
                        storeRef.moveTokenClient(source, toIndex: targetIndex, available: available)
                    }
                }
            }
            dragOverClient = nil
            return true
        }

        draggingClient = nil
        dragOverClient = nil
        return false
    }
}

// MARK: - Custom Date Picker Popover (Single Day + Arbitrary Range + Quick Shortcuts)

private struct TokenUsageCustomDatePopoverView: View {
    @ObservedObject var store: AppStore
    let availableBounds: (minDate: String, maxDate: String)?
    @Binding var isPresented: Bool

    private enum PickerMode: String, CaseIterable, Identifiable {
        case singleDay = "单日"
        case range = "日期区间"
        var id: String { rawValue }
    }

    @Environment(\.accessibilityReduceMotion) private var envReduceMotion
    @Namespace private var modePillNamespace

    @State private var mode: PickerMode = .singleDay
    @State private var draftSingleDate: Date = Date()
    @State private var draftStartDate: Date = Date()
    @State private var draftEndDate: Date = Date()
    @State private var hasInitializedDraft: Bool = false

    private var reduceMotion: Bool {
        envReduceMotion || OrbitMotion.isReducedMotion
    }

    private var pillAnim: Animation {
        reduceMotion ? .linear(duration: 0.05) : OrbitMotion.pill
    }

    private var snappyAnim: Animation {
        reduceMotion ? .linear(duration: 0.05) : OrbitMotion.snappy
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = 2 // Monday
        return cal
    }

    private var todayStart: Date {
        calendar.startOfDay(for: Date())
    }

    private var pickerDateRange: ClosedRange<Date> {
        let fallbackMin = calendar.date(byAdding: .year, value: -5, to: todayStart) ?? todayStart
        let parsedMin = availableBounds.flatMap { TokenFormatters.date(fromYMD: $0.minDate) }
        let parsedMax = availableBounds.flatMap { TokenFormatters.date(fromYMD: $0.maxDate) }
        let lower = min(parsedMin ?? fallbackMin, todayStart)
        let upper = max(parsedMax ?? todayStart, todayStart)
        return lower...upper
    }

    private func clampToPickerBounds(_ date: Date) -> Date {
        let range = pickerDateRange
        if date < range.lowerBound { return range.lowerBound }
        if date > range.upperBound { return range.upperBound }
        return date
    }

    private func initializeDraftIfNeeded() {
        guard !hasInitializedDraft else { return }
        hasInitializedDraft = true

        switch store.tokenUsageDateSelection {
        case .custom(let startStr, let endStr):
            let sDate = clampToPickerBounds(TokenFormatters.date(fromYMD: startStr) ?? todayStart)
            let eDate = clampToPickerBounds(TokenFormatters.date(fromYMD: endStr) ?? todayStart)
            if startStr == endStr {
                mode = .singleDay
                draftSingleDate = sDate
                draftStartDate = sDate
                draftEndDate = sDate
            } else {
                mode = .range
                draftStartDate = min(sDate, eDate)
                draftEndDate = max(sDate, eDate)
                draftSingleDate = draftEndDate
            }
        case .preset(let preset):
            if preset == .today {
                mode = .singleDay
                draftSingleDate = clampToPickerBounds(todayStart)
                draftStartDate = draftSingleDate
                draftEndDate = draftSingleDate
            } else if let snap = store.tokenUsage {
                let s = snap.summary(for: preset)
                let sDate = clampToPickerBounds(TokenFormatters.date(fromYMD: s.startDate) ?? todayStart)
                let eDate = clampToPickerBounds(TokenFormatters.date(fromYMD: s.endDate) ?? todayStart)
                mode = .range
                draftStartDate = min(sDate, eDate)
                draftEndDate = max(sDate, eDate)
                draftSingleDate = draftEndDate
            } else {
                mode = .singleDay
                draftSingleDate = clampToPickerBounds(todayStart)
                draftStartDate = draftSingleDate
                draftEndDate = draftSingleDate
            }
        }
    }

    private struct QuickShortcut: Identifiable {
        let id: String
        let title: String
        let startDate: Date
        let endDate: Date
        let isSingleDay: Bool
    }

    private var shortcuts: [QuickShortcut] {
        let today = todayStart
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let last3Start = calendar.date(byAdding: .day, value: -2, to: today) ?? today
        let last14Start = calendar.date(byAdding: .day, value: -13, to: today) ?? today

        let weekday = calendar.component(.weekday, from: today)
        let daysSinceMonday = (weekday + 5) % 7
        let weekStart = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today) ?? today

        let monthComps = calendar.dateComponents([.year, .month], from: today)
        let monthStart = calendar.date(from: monthComps) ?? today

        return [
            QuickShortcut(id: "yesterday", title: "昨日", startDate: yesterday, endDate: yesterday, isSingleDay: true),
            QuickShortcut(id: "last3", title: "近 3 天", startDate: last3Start, endDate: today, isSingleDay: false),
            QuickShortcut(id: "last14", title: "近 14 天", startDate: last14Start, endDate: today, isSingleDay: false),
            QuickShortcut(id: "thisWeek", title: "本周", startDate: weekStart, endDate: today, isSingleDay: false),
            QuickShortcut(id: "thisMonth", title: "本月", startDate: monthStart, endDate: today, isSingleDay: false),
        ]
    }

    private func isShortcutActive(_ item: QuickShortcut) -> Bool {
        guard let cur = store.tokenUsageDateSelection.customBounds else { return false }
        let s = TokenFormatters.ymdString(from: item.startDate)
        let e = TokenFormatters.ymdString(from: item.endDate)
        return cur.startDate == s && cur.endDate == e
    }

    var body: some View {
        let boundsRange = pickerDateRange

        VStack(alignment: .leading, spacing: 10) {
            // Header + Mode Segment Switch
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.accentColor)
                    Text("自定义日期")
                        .font(.system(size: 12.5, weight: .bold))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                HStack(spacing: 2) {
                    ForEach(PickerMode.allCases) { item in
                        let isOn = (mode == item)
                        Button {
                            withAnimation(pillAnim) {
                                mode = item
                            }
                        } label: {
                            Text(item.rawValue)
                                .font(.system(size: 10.5, weight: isOn ? .semibold : .medium))
                                .foregroundColor(isOn ? .primary : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background {
                                    if isOn {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color(nsColor: .controlBackgroundColor))
                                            .shadow(color: Color.black.opacity(0.08), radius: 1.2, y: 0.5)
                                            .matchedGeometryEffect(id: "customDateModePill", in: modePillNamespace)
                                    }
                                }
                                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .orbitInteractiveButton(pressedScale: 0.97, hoverTint: isOn ? nil : Color.primary.opacity(0.045), cornerRadius: 6)
                    }
                }
                .padding(2)
                .background(Color.primary.opacity(0.065))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            // Quick Shortcut Chips
            VStack(alignment: .leading, spacing: 5) {
                Text("快捷选择")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack(spacing: 5) {
                    ForEach(shortcuts) { item in
                        let active = isShortcutActive(item)
                        Button {
                            withAnimation(snappyAnim) {
                                if item.isSingleDay {
                                    let ymd = TokenFormatters.ymdString(from: item.startDate)
                                    store.selectTokenUsageSingleDay(ymd)
                                } else {
                                    store.selectTokenUsageCustomRange(start: item.startDate, end: item.endDate)
                                }
                            }
                            isPresented = false
                        } label: {
                            Text(item.title)
                                .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                                .foregroundColor(active ? .accentColor : .primary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 7.5)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(active ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06))
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(active ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.09), lineWidth: 0.65)
                                )
                        }
                        .orbitInteractiveButton(pressedScale: 0.96, hoverTint: nil, cornerRadius: 99)
                    }
                }
            }

            Divider().opacity(0.45)

            // Native DatePicker Area
            if mode == .singleDay {
                VStack(alignment: .leading, spacing: 6) {
                    DatePicker(
                        "选择单日",
                        selection: $draftSingleDate,
                        in: boundsRange,
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .center)

                    let singleYMD = TokenFormatters.ymdString(from: draftSingleDate)
                    HStack(spacing: 6) {
                        Text("已选单日")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(singleYMD) \(TokenAnalyticsStyle.weekdayShortCN(for: singleYMD))")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.accentColor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.045))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("开始日期")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.primary)
                        Spacer()
                        DatePicker(
                            "开始日期",
                            selection: $draftStartDate,
                            in: boundsRange,
                            displayedComponents: [.date]
                        )
                        .datePickerStyle(.compact)
                        .labelsHidden()
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    HStack {
                        Text("结束日期")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.primary)
                        Spacer()
                        DatePicker(
                            "结束日期",
                            selection: $draftEndDate,
                            in: boundsRange,
                            displayedComponents: [.date]
                        )
                        .datePickerStyle(.compact)
                        .labelsHidden()
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    let rawStartYMD = TokenFormatters.ymdString(from: draftStartDate)
                    let rawEndYMD = TokenFormatters.ymdString(from: draftEndDate)
                    let normStart = min(rawStartYMD, rawEndYMD)
                    let normEnd = max(rawStartYMD, rawEndYMD)
                    let dayCount = TokenFormatters.inclusiveDayCount(startDate: normStart, endDate: normEnd) ?? 1

                    VStack(alignment: .leading, spacing: 2.5) {
                        HStack(spacing: 5) {
                            Text("已选区间")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(normStart) ~ \(normEnd)")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(.accentColor)
                            Text("共 \(dayCount) 天")
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.primary.opacity(0.06))
                                .clipShape(Capsule())
                        }
                        if rawStartYMD > rawEndYMD {
                            Text("开始日期晚于结束日期，应用时将自动对齐先后顺序。")
                                .font(.system(size: 9.5))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.045))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }

            // Local History Bounds Caption
            HStack(spacing: 4.5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                if let bounds = availableBounds {
                    Text("本地历史：\(bounds.minDate) ~ \(bounds.maxDate)")
                        .font(.system(size: 10, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text("本地历史：等待首次扫描")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Divider().opacity(0.45)

            // Footer Actions
            HStack(spacing: 8) {
                Button {
                    withAnimation(snappyAnim) {
                        store.resetTokenUsageSelectionToToday()
                    }
                    isPresented = false
                } label: {
                    Label("回到今日", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.tokenUsageDateSelection == .preset(.today))

                Spacer()

                Button {
                    withAnimation(snappyAnim) {
                        if mode == .singleDay {
                            let ymd = TokenFormatters.ymdString(from: draftSingleDate)
                            store.selectTokenUsageSingleDay(ymd)
                        } else {
                            store.selectTokenUsageCustomRange(start: draftStartDate, end: draftEndDate)
                        }
                    }
                    isPresented = false
                } label: {
                    Text("应用")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 306)
        .onAppear {
            initializeDraftIfNeeded()
        }
    }
}

// MARK: - Unified Card & Client Order Customizer Popover

private struct UnifiedTokenCustomizerPopoverView: View {
    @ObservedObject var store: AppStore
    let availableClients: [TokenClientID]

    private enum CustomizerTab: String, CaseIterable, Identifiable {
        case cards = "显示卡片"
        case clients = "客户端排序"
        var id: String { rawValue }
    }

    @Environment(\.accessibilityReduceMotion) private var envReduceMotion
    @Namespace private var customizerTabNamespace

    @State private var selectedTab: CustomizerTab = .cards

    private var reduceMotion: Bool {
        envReduceMotion || OrbitMotion.isReducedMotion
    }

    private var snappyAnim: Animation {
        reduceMotion ? .linear(duration: 0.05) : OrbitMotion.snappy
    }

    private var pillAnim: Animation {
        reduceMotion ? .linear(duration: 0.05) : OrbitMotion.pill
    }

    private var effectiveAvailableClients: [TokenClientID] {
        if !availableClients.isEmpty {
            return availableClients
        }
        return TokenClientID.allCases.filter { $0 != .other }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header + Segmented Switcher
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("面板自定义")
                    .font(.system(size: 12.5, weight: .bold))
                    .lineLimit(1)

                Spacer(minLength: 4)

                HStack(spacing: 2) {
                    ForEach(CustomizerTab.allCases) { tab in
                        let isOn = (selectedTab == tab)
                        Button {
                            withAnimation(pillAnim) {
                                selectedTab = tab
                            }
                        } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 10.5, weight: isOn ? .semibold : .medium))
                                .foregroundColor(isOn ? .primary : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background {
                                    if isOn {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color(nsColor: .controlBackgroundColor))
                                            .shadow(color: Color.black.opacity(0.08), radius: 1.2, y: 0.5)
                                            .matchedGeometryEffect(id: "customizerTabPill", in: customizerTabNamespace)
                                    }
                                }
                                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .orbitInteractiveButton(pressedScale: 0.97, hoverTint: isOn ? nil : Color.primary.opacity(0.045), cornerRadius: 6)
                    }
                }
                .padding(2)
                .background(Color.primary.opacity(0.065))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if selectedTab == .cards {
                cardsTabContent
            } else {
                clientOrderTabContent
            }
        }
        .padding(12)
        .frame(width: 324)
    }

    private var cardsTabContent: some View {
        let cfg = store.registry.settings.tokenDashboardCards
        let visibleCount = cfg.visibleCards.count
        let totalCount = DashboardTokenCard.allCases.count

        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("选择要显示的统计卡片与上下顺序")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("已启 \(visibleCount)/\(totalCount)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(Capsule())
                    .orbitNumericTransition()
            }

            VStack(spacing: 4) {
                ForEach(cfg.orderedCards) { card in
                    let enabled = cfg.isEnabled(card)
                    let canUp = cfg.canMoveCard(card, direction: .up)
                    let canDown = cfg.canMoveCard(card, direction: .down)

                    HStack(spacing: 7) {
                        Button {
                            withAnimation(snappyAnim) {
                                store.updateDashboardTokenCards { $0.toggleCard(card) }
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: enabled ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundColor(enabled ? .accentColor : .secondary.opacity(0.6))

                                Image(systemName: card.symbolName)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(enabled ? .primary : .secondary)
                                    .frame(width: 15, alignment: .center)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(card.title)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundColor(enabled ? .primary : .secondary)
                                        .lineLimit(1)
                                    Text(card.subtitle)
                                        .font(.system(size: 9.5))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 3) {
                            CardOrderActionButton(
                                systemImage: "chevron.up",
                                disabled: !canUp,
                                helpText: "上移卡片"
                            ) {
                                withAnimation(snappyAnim) {
                                    store.updateDashboardTokenCards { $0.moveCard(card, direction: .up) }
                                }
                            }
                            CardOrderActionButton(
                                systemImage: "chevron.down",
                                disabled: !canDown,
                                helpText: "下移卡片"
                            ) {
                                withAnimation(snappyAnim) {
                                    store.updateDashboardTokenCards { $0.moveCard(card, direction: .down) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(enabled ? Color.primary.opacity(0.04) : Color.primary.opacity(0.015))
                    )
                    .orbitHoverHighlight(cornerRadius: 7)
                }
            }
            .animation(snappyAnim, value: cfg.orderedCards)

            Divider().opacity(0.45)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("紧凑密度")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("收紧卡片内边距与图表高度，单屏容纳更多内容")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(
                    get: { store.registry.settings.tokenDashboardCards.compactDensity },
                    set: { newVal in
                        withAnimation(snappyAnim) {
                            store.updateDashboardTokenCards { $0.compactDensity = newVal }
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            Divider().opacity(0.45)

            HStack {
                Button {
                    withAnimation(snappyAnim) {
                        store.resetDashboardTokenCards()
                    }
                } label: {
                    Label("恢复默认卡片", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(cfg == .default)

                Spacer()

                Text("实时保存")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var clientOrderTabContent: some View {
        let baseClients = effectiveAvailableClients
        let orderedClients = store.orderedTokenClients(from: baseClients)

        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("把常用客户端放前，不常用的放后")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(store.hasCustomTokenClientOrder ? "已自定义" : "默认按用量")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(store.hasCustomTokenClientOrder ? .accentColor : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (store.hasCustomTokenClientOrder ? Color.accentColor : Color.primary).opacity(0.09)
                    )
                    .clipShape(Capsule())
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 4) {
                    ForEach(Array(orderedClients.enumerated()), id: \.element.id) { idx, client in
                        let tint = TokenAnalyticsStyle.color(for: client)
                        let canUp = store.canMoveTokenClient(client, direction: .up, available: baseClients)
                        let canDown = store.canMoveTokenClient(client, direction: .down, available: baseClients)

                        HStack(spacing: 7) {
                            Text("\(idx + 1)")
                                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(idx < 3 ? .accentColor : .secondary)
                                .frame(width: 14, alignment: .center)

                            Circle()
                                .fill(tint)
                                .frame(width: 7.5, height: 7.5)

                            Text(client.displayName)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Spacer(minLength: 4)

                            HStack(spacing: 3) {
                                CardOrderActionButton(
                                    systemImage: "arrow.up.to.line",
                                    disabled: idx == 0,
                                    helpText: "置顶到最前"
                                ) {
                                    withAnimation(snappyAnim) {
                                        store.pinTokenClientToFront(client, available: baseClients)
                                    }
                                }
                                CardOrderActionButton(
                                    systemImage: "chevron.up",
                                    disabled: !canUp,
                                    helpText: "向前一位"
                                ) {
                                    withAnimation(snappyAnim) {
                                        store.moveTokenClient(client, direction: .up, available: baseClients)
                                    }
                                }
                                CardOrderActionButton(
                                    systemImage: "chevron.down",
                                    disabled: !canDown,
                                    helpText: "向后一位"
                                ) {
                                    withAnimation(snappyAnim) {
                                        store.moveTokenClient(client, direction: .down, available: baseClients)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                        .orbitHoverHighlight(cornerRadius: 7)
                    }
                }
                .animation(snappyAnim, value: orderedClients)
            }
            .frame(maxHeight: 236)

            Text("提示：客户端筛选栏支持鼠标滚轮左右滑动、直接拖拽芯片或右键调序。")
                .font(.system(size: 9.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().opacity(0.45)

            HStack {
                Button {
                    withAnimation(snappyAnim) {
                        store.resetTokenClientOrder()
                    }
                } label: {
                    Label("恢复默认（按用量排序）", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!store.hasCustomTokenClientOrder)

                Spacer()

                Text("实时保存")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Unified Token Usage Panel (340...680pt Adaptive, Liquid Glass, 5 Customizable Cards)

public struct TokenUsagePopoverView: View {
    @ObservedObject public var store: AppStore
    public var onOpenDashboard: (() -> Void)?

    private enum TrendMetric: String, CaseIterable, Identifiable {
        case tokens = "Tokens"
        case cost = "费用 ($)"
        var id: String { rawValue }
    }

    private enum BreakdownTab: String, CaseIterable, Identifiable {
        case clients = "客户端分布"
        case models = "模型排行"
        case projects = "项目排行"
        var id: String { rawValue }

        var shortTitle: String {
            switch self {
            case .clients: return "客户端"
            case .models: return "模型"
            case .projects: return "项目"
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var envReduceMotion

    @Namespace private var rangePillNamespace
    @Namespace private var trendMetricNamespace
    @Namespace private var breakdownTabNamespace

    @State private var selectedClient: TokenClientID? = nil
    @State private var trendMetric: TrendMetric = .tokens
    @State private var selectedHeatmapDate: String? = nil
    @State private var hoveredHeatmapDate: String? = nil
    @State private var hoveredHeatmapRow: Int? = nil
    @State private var hoveredTrendDate: String? = nil
    @State private var selectedBreakdownTab: BreakdownTab = .clients
    @State private var showAllModels: Bool = false
    @State private var showAllProjects: Bool = false
    @State private var showCustomDatePopover: Bool = false
    @State private var showCardCustomizer: Bool = false
    @State private var draggingClient: TokenClientID? = nil
    @State private var dragOverClient: TokenClientID? = nil
    @State private var exportToastMessage: String? = nil
    @State private var exportToastIsError: Bool = false
    @State private var exportToastTask: Task<Void, Never>? = nil

    public init(
        store: AppStore,
        onOpenDashboard: (() -> Void)? = nil
    ) {
        self.store = store
        self.onOpenDashboard = onOpenDashboard
    }

    private var reduceMotion: Bool {
        envReduceMotion || OrbitMotion.isReducedMotion
    }

    private var pillAnim: Animation {
        reduceMotion ? .linear(duration: 0.05) : OrbitMotion.pill
    }

    private var snappyAnim: Animation {
        reduceMotion ? .linear(duration: 0.05) : OrbitMotion.snappy
    }

    private var smoothAnim: Animation {
        reduceMotion ? .linear(duration: 0.06) : OrbitMotion.smooth
    }

    private var hoverAnim: Animation {
        reduceMotion ? .linear(duration: 0.04) : OrbitMotion.hover
    }

    private var activePanelTransition: AnyTransition {
        reduceMotion ? .opacity : OrbitMotion.panelTransition
    }

    private var cardTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.988, anchor: .top)),
            removal: .opacity
        )
    }

    private var effectiveSpeed: LiveTokenSpeedSnapshot {
        let live = store.liveTokenSpeed
        if live.currentModel == nil && live.recentModels.isEmpty,
           let fallback = store.tokenUsage?.speedSnapshot {
            return fallback
        }
        return live
    }

    private var nestedSubtleSurface: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.055)
            : Color.black.opacity(0.036)
    }

    private var nestedSubtleBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.06)
    }

    /// Explicit appearance-resolved inks used inside macOS 26/27 `.glassEffect` controls
    /// so dynamic Liquid Glass vibrancy passes never invert label/icon contrast across Light/Dark wallpapers.
    private var glassPrimaryInk: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.84)
    }

    private var glassSecondaryInk: Color {
        colorScheme == .dark ? Color.white.opacity(0.64) : Color.black.opacity(0.56)
    }

    private var glassControlTintFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.085) : Color.black.opacity(0.042)
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
        let speed = effectiveSpeed
        let cardConfig = store.registry.settings.tokenDashboardCards
        let visibleCards = cardConfig.visibleCards
        let compactDensity = cardConfig.compactDensity
        let dateSelection = store.tokenUsageDateSelection

        return GeometryReader { geo in
            let availableWidth = geo.size.width > 1 ? geo.size.width : CGFloat(store.registry.settings.popoverWidth)
            let isUltraNarrow = availableWidth < 370
            let isCompactWidth = availableWidth < 460
            let contentPad: CGFloat = isUltraNarrow ? 9 : (isCompactWidth ? 10.5 : 12.5)
            let cardPad: CGFloat = compactDensity ? 8.5 : (isUltraNarrow ? 9.5 : 11.5)
            let cardSpacing: CGFloat = compactDensity ? 7 : (isUltraNarrow ? 8.5 : 10.5)
            let cardInnerWidth = max(180, availableWidth - contentPad * 2 - cardPad * 2)
            let availableClients = store.tokenUsage?.summary(for: .allTime).byClient.map(\.client) ?? []

            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    unifiedTopControlBar(
                        availableWidth: availableWidth,
                        contentPad: contentPad,
                        cardConfig: cardConfig,
                        availableClients: availableClients,
                        dateSelection: dateSelection
                    )

                    Divider().opacity(0.32)

                    if let snapshot = store.tokenUsage {
                        let summary = snapshot.summary(for: dateSelection, clientFilter: selectedClient)
                        let heatmapCells = snapshot.heatmap(days: 112, clientFilter: selectedClient)

                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: cardSpacing) {
                                if visibleCards.isEmpty {
                                    emptyCardsNoticeCard(cardPad: cardPad)
                                        .transition(cardTransition)
                                } else {
                                    ForEach(visibleCards) { card in
                                        unifiedCardView(
                                            for: card,
                                            snapshot: snapshot,
                                            summary: summary,
                                            heatmapCells: heatmapCells,
                                            speed: speed,
                                            dateSelection: dateSelection,
                                            availableWidth: availableWidth,
                                            cardInnerWidth: cardInnerWidth,
                                            cardPad: cardPad,
                                            compactDensity: compactDensity
                                        )
                                        .transition(cardTransition)
                                    }
                                }
                            }
                            .padding(.horizontal, contentPad)
                            .padding(.top, compactDensity ? 7 : 9)
                            .padding(.bottom, compactDensity ? 10 : 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .animation(snappyAnim, value: dateSelection)
                            .animation(snappyAnim, value: selectedClient)
                            .animation(snappyAnim, value: visibleCards)
                            .animation(snappyAnim, value: compactDensity)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if store.isScanningTokenUsage {
                        ScrollView(.vertical, showsIndicators: false) {
                            scanningPlaceholderCard(availableWidth: availableWidth)
                                .padding(.horizontal, contentPad)
                                .padding(.top, 10)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            emptyScanCard
                                .padding(.horizontal, contentPad)
                                .padding(.top, 10)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    Divider().opacity(0.32)
                    unifiedFooterBar(availableWidth: availableWidth, contentPad: contentPad)
                }
                .frame(width: availableWidth, height: geo.size.height > 1 ? geo.size.height : nil)

                if let toast = exportToastMessage {
                    exportToastBanner(message: toast, isError: exportToastIsError)
                        .padding(.bottom, 34)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(snappyAnim, value: exportToastMessage)
        }
        .background(Color.clear)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if store.tokenUsage == nil && !store.isScanningTokenUsage {
                Task { await store.refreshTokenUsage() }
            }
            Task { await store.refreshLiveTokenSpeed() }
        }
        .onDisappear {
            exportToastTask?.cancel()
            exportToastTask = nil
        }
    }

    // MARK: - Top Control Bar & Horizontal Client Filter Strip

    private func unifiedTopControlBar(
        availableWidth: CGFloat,
        contentPad: CGFloat,
        cardConfig: DashboardTokenCardConfig,
        availableClients: [TokenClientID],
        dateSelection: TokenUsageDateSelection
    ) -> some View {
        let isUltraNarrow = availableWidth < 370
        let isSingleRowToolbar = availableWidth >= (dateSelection.isCustom ? 565 : 515)
        let isCustomized = (cardConfig != .default) || store.hasCustomTokenClientOrder

        return VStack(alignment: .leading, spacing: isUltraNarrow ? 6 : 7) {
            if isSingleRowToolbar {
                HStack(spacing: 7) {
                    OrbitGlassContainer(spacing: 5) {
                        HStack(spacing: 5) {
                            presetRangeSegmentBar(
                                dateSelection: dateSelection,
                                expandEqually: false,
                                ultraCompact: false
                            )
                            customDateButton(
                                dateSelection: dateSelection,
                                ultraCompact: false
                            )
                        }
                    }

                    if dateSelection.isCustom {
                        resetToTodayMiniButton
                    }

                    Spacer(minLength: 4)

                    toolbarActionCluster(
                        isUltraNarrow: false,
                        isCustomized: isCustomized,
                        availableClients: availableClients
                    )
                }
            } else {
                // Row 1: Preset Ranges + Custom Date Pill
                OrbitGlassContainer(spacing: 5) {
                    HStack(spacing: isUltraNarrow ? 4.5 : 5.5) {
                        presetRangeSegmentBar(
                            dateSelection: dateSelection,
                            expandEqually: true,
                            ultraCompact: isUltraNarrow
                        )
                        .frame(maxWidth: .infinity)

                        customDateButton(
                            dateSelection: dateSelection,
                            ultraCompact: availableWidth < 420
                        )
                    }
                }

                // Row 2: Active Date Context / Quick Return to Today + Tools (卡片 / 扫描 / …)
                HStack(spacing: 6) {
                    if dateSelection.isCustom {
                        HStack(spacing: 4.5) {
                            resetToTodayMiniButton
                            if availableWidth >= 380, let bounds = dateSelection.customBounds,
                               let days = TokenFormatters.inclusiveDayCount(startDate: bounds.startDate, endDate: bounds.endDate) {
                                Text(days == 1 ? "单日统计" : "共 \(days) 天")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    } else if let snap = store.tokenUsage {
                        let spanSummary = snap.summary(for: dateSelection, clientFilter: selectedClient)
                        let spanCaption: String = {
                            if !spanSummary.startDate.isEmpty {
                                if spanSummary.startDate == spanSummary.endDate {
                                    return "\(spanSummary.startDate) \(TokenAnalyticsStyle.weekdayShortCN(for: spanSummary.startDate))"
                                }
                                return "\(TokenAnalyticsStyle.shortMonthDay(spanSummary.startDate)) ~ \(TokenAnalyticsStyle.shortMonthDay(spanSummary.endDate))"
                            }
                            return "\(dateSelection.displayName) · \(store.relativeTimeAgoString(since: snap.lastScannedAt))更新"
                        }()
                        HStack(spacing: 4) {
                            Image(systemName: "calendar.badge.clock")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(spanCaption)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.84)
                        }
                    } else {
                        Text("今日默认视图")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    toolbarActionCluster(
                        isUltraNarrow: isUltraNarrow,
                        isCustomized: isCustomized,
                        availableClients: availableClients
                    )
                }
            }

            // Client Filter Strip (Horizontal Mouse-Wheel Scroll + Drag Reorder + Right-Click Menu)
            if !availableClients.isEmpty {
                clientFilterChipsStrip(
                    availableClients: availableClients,
                    isUltraNarrow: isUltraNarrow
                )
            }
        }
        .padding(.horizontal, contentPad)
        .padding(.top, isUltraNarrow ? 6.5 : 8)
        .padding(.bottom, isUltraNarrow ? 6 : 7.5)
    }

    private func presetRangeSegmentBar(
        dateSelection: TokenUsageDateSelection,
        expandEqually: Bool,
        ultraCompact: Bool
    ) -> some View {
        let activePreset = dateSelection.presetRange
        let isDark = (colorScheme == .dark)
        return HStack(spacing: ultraCompact ? 1.5 : 2) {
            ForEach(TokenUsageRange.presetCases) { range in
                let isSelected = (activePreset == range)
                Button {
                    withAnimation(pillAnim) {
                        store.selectTokenUsagePreset(range)
                    }
                } label: {
                    Text(range.displayName)
                        .font(.system(size: ultraCompact ? 10.5 : 11, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? glassPrimaryInk : glassSecondaryInk)
                        .lineLimit(1)
                        .fixedSize(horizontal: !expandEqually, vertical: false)
                        .frame(maxWidth: expandEqually ? .infinity : nil)
                        .padding(.horizontal, ultraCompact ? 4 : (expandEqually ? 6 : 9))
                        .padding(.vertical, 4.5)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: isDark
                                                ? [Color.white.opacity(0.20), Color.white.opacity(0.12)]
                                                : [Color.white.opacity(0.92), Color.white.opacity(0.76)],
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
                                    .shadow(color: Color.black.opacity(isDark ? 0.24 : 0.09), radius: 2, y: 0.8)
                                    .matchedGeometryEffect(id: "tokenRangePresetPill", in: rangePillNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .orbitInteractiveButton(
                    pressedScale: 0.97,
                    hoverTint: isSelected ? nil : Color.primary.opacity(0.045),
                    cornerRadius: 99
                )
            }
        }
        .padding(2.5)
        .background(Capsule().fill(glassControlTintFill))
        .overlay(Capsule().strokeBorder(glassControlSpecularBorder, lineWidth: 0.65))
        .orbitGlassCapsule(interactive: false)
    }

    private func customDateButton(
        dateSelection: TokenUsageDateSelection,
        ultraCompact: Bool
    ) -> some View {
        let isCustom = dateSelection.isCustom
        let isActive = isCustom || showCustomDatePopover
        let isDark = (colorScheme == .dark)
        let labelText = TokenAnalyticsStyle.toolbarCustomButtonLabel(
            for: dateSelection,
            ultraCompact: ultraCompact
        )
        let fullHelpText: String = {
            if let bounds = dateSelection.customBounds {
                let full = bounds.startDate == bounds.endDate
                    ? bounds.startDate
                    : "\(bounds.startDate) ~ \(bounds.endDate)"
                return "当前自定义日期：\(full)（点击修改单日或区间）"
            }
            return "自定义选择单日或任意日期区间"
        }()

        return Button {
            showCustomDatePopover.toggle()
        } label: {
            HStack(spacing: 3.5) {
                Image(systemName: isCustom ? "calendar.badge.checkmark" : "calendar")
                    .font(.system(size: ultraCompact ? 9.5 : 10, weight: .semibold))
                Text(labelText)
                    .font(.system(size: ultraCompact ? 10 : 10.5, weight: isCustom ? .semibold : .medium, design: isCustom ? .rounded : .default))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
            }
            .foregroundColor(isActive ? .accentColor : glassPrimaryInk.opacity(0.88))
            .padding(.horizontal, ultraCompact ? 7 : 8.5)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(
                        isActive
                            ? Color.accentColor.opacity(isDark ? 0.24 : 0.14)
                            : glassControlTintFill
                    )
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isActive
                            ? LinearGradient(
                                colors: [Color.accentColor.opacity(0.68), Color.accentColor.opacity(0.32)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            : glassControlSpecularBorder,
                        lineWidth: isActive ? 0.85 : 0.65
                    )
            )
            .contentShape(Capsule())
            .orbitGlassCapsule(interactive: true)
        }
        .orbitInteractiveButton(pressedScale: 0.96, hoverTint: nil, cornerRadius: 99)
        .fixedSize(horizontal: true, vertical: false)
        .help(fullHelpText)
        .popover(isPresented: $showCustomDatePopover, arrowEdge: .bottom) {
            TokenUsageCustomDatePopoverView(
                store: store,
                availableBounds: store.tokenUsage?.availableDateBounds,
                isPresented: $showCustomDatePopover
            )
        }
    }

    private var resetToTodayMiniButton: some View {
        Button {
            withAnimation(snappyAnim) {
                store.resetTokenUsageSelectionToToday()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 8.5, weight: .semibold))
                Text("回今日")
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(.accentColor)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 3.5)
            .background(Color.accentColor.opacity(0.11))
            .overlay(
                Capsule()
                    .stroke(Color.accentColor.opacity(0.32), lineWidth: 0.65)
            )
            .clipShape(Capsule())
        }
        .orbitInteractiveButton(pressedScale: 0.96, hoverTint: nil, cornerRadius: 99)
        .fixedSize(horizontal: true, vertical: false)
        .help("一键回到「今日」统计")
    }

    private func toolbarActionCluster(
        isUltraNarrow: Bool,
        isCustomized: Bool,
        availableClients: [TokenClientID]
    ) -> some View {
        let isDark = (colorScheme == .dark)
        let customizerActive = showCardCustomizer || isCustomized

        return OrbitGlassContainer(spacing: isUltraNarrow ? 4 : 5) {
            HStack(spacing: isUltraNarrow ? 4 : 5) {
                // 卡片 (Cards & Client Order Customizer)
                Button {
                    showCardCustomizer.toggle()
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10, weight: .semibold))
                        Text("卡片")
                            .font(.system(size: isUltraNarrow ? 10 : 10.5, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundColor(customizerActive ? .accentColor : glassPrimaryInk.opacity(0.88))
                    .padding(.horizontal, isUltraNarrow ? 7 : 8.5)
                    .padding(.vertical, 4.5)
                    .background(
                        Capsule()
                            .fill(
                                customizerActive
                                    ? Color.accentColor.opacity(isDark ? 0.22 : 0.13)
                                    : glassControlTintFill
                            )
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                customizerActive
                                    ? LinearGradient(
                                        colors: [Color.accentColor.opacity(0.65), Color.accentColor.opacity(0.30)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                    : glassControlSpecularBorder,
                                lineWidth: customizerActive ? 0.8 : 0.65
                            )
                    )
                    .contentShape(Capsule())
                    .orbitGlassCapsule(interactive: true)
                }
                .orbitInteractiveButton(pressedScale: 0.96, hoverTint: nil, cornerRadius: 99)
                .fixedSize(horizontal: true, vertical: false)
                .help("自定义显示卡片、顺序、紧凑密度与客户端排序")
                .popover(isPresented: $showCardCustomizer, arrowEdge: .bottom) {
                    UnifiedTokenCustomizerPopoverView(
                        store: store,
                        availableClients: availableClients
                    )
                }

                // 扫描 (Incremental Local Scan)
                Button {
                    Task { await store.refreshTokenUsage(forceFullRescan: false) }
                } label: {
                    HStack(spacing: 3.5) {
                        if store.isScanningTokenUsage {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.66)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text(store.isScanningTokenUsage ? "扫描中" : "扫描")
                            .font(.system(size: isUltraNarrow ? 10 : 10.5, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundColor(glassPrimaryInk.opacity(0.88))
                    .padding(.horizontal, isUltraNarrow ? 7 : 8.5)
                    .padding(.vertical, 4.5)
                    .background(Capsule().fill(glassControlTintFill))
                    .overlay(Capsule().strokeBorder(glassControlSpecularBorder, lineWidth: 0.65))
                    .contentShape(Capsule())
                    .orbitGlassCapsule(interactive: true)
                }
                .orbitInteractiveButton(pressedScale: 0.96, hoverTint: nil, cornerRadius: 99)
                .disabled(store.isScanningTokenUsage)
                .fixedSize(horizontal: true, vertical: false)
                .help("增量扫描本机客户端会话日志（纯本地只读）")

                // … (Export JSON / Full Rescan / Open Archive Directory)
                Menu {
                    Button {
                        Task { await store.refreshTokenUsage(forceFullRescan: false) }
                    } label: {
                        Label("增量扫描本地日志", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isScanningTokenUsage)

                    Button {
                        Task { await store.refreshTokenUsage(forceFullRescan: true) }
                    } label: {
                        Label("立即全量重扫", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(store.isScanningTokenUsage)

                    Divider()

                    Button {
                        showCardCustomizer = true
                    } label: {
                        Label("自定义卡片与客户端排序…", systemImage: "slider.horizontal.3")
                    }

                    Button {
                        exportCurrentReportAsJSON()
                    } label: {
                        Label("导出当前统计为 JSON…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.tokenUsage == nil)

                    Divider()

                    Button {
                        store.revealTokenArchiveInFinder()
                    } label: {
                        Label("在 Finder 中显示归档文件", systemImage: "doc.text.magnifyingglass")
                    }

                    Button {
                        store.openDataDirectory()
                    } label: {
                        Label("打开归档数据目录", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(glassPrimaryInk.opacity(0.88))
                        .frame(width: 24, height: 22)
                        .background(Capsule().fill(glassControlTintFill))
                        .overlay(Capsule().strokeBorder(glassControlSpecularBorder, lineWidth: 0.65))
                        .contentShape(Capsule())
                        .orbitGlassCapsule(interactive: true)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多操作：导出 JSON、全量重扫、打开归档目录")
            }
        }
    }

    private func clientFilterChipsStrip(
        availableClients: [TokenClientID],
        isUltraNarrow: Bool
    ) -> some View {
        let orderedClients = store.orderedTokenClients(from: availableClients)

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: isUltraNarrow ? 4.5 : 5.5) {
                // Pinned "All Clients" Chip
                clientFilterChipButton(
                    title: "全部客户端",
                    dotColor: nil,
                    isSelected: selectedClient == nil,
                    isDragging: false,
                    isDropTarget: false,
                    ultraNarrow: isUltraNarrow
                ) {
                    withAnimation(pillAnim) {
                        selectedClient = nil
                    }
                }
                .contextMenu {
                    if selectedClient != nil {
                        Button("显示全部客户端") {
                            withAnimation(pillAnim) {
                                selectedClient = nil
                            }
                        }
                    }
                    Button("恢复客户端默认顺序") {
                        withAnimation(snappyAnim) {
                            store.resetTokenClientOrder()
                        }
                    }
                    .disabled(!store.hasCustomTokenClientOrder)
                }
                .help("显示全部客户端汇总（滚轮可左右滑动）")

                // User-Orderable Client Chips (Drag & Drop + Right-Click Context Menu)
                ForEach(Array(orderedClients.enumerated()), id: \.element.id) { idx, client in
                    let canUp = store.canMoveTokenClient(client, direction: .up, available: availableClients)
                    let canDown = store.canMoveTokenClient(client, direction: .down, available: availableClients)
                    let isFirst = (idx == 0)
                    let isLast = (idx == orderedClients.count - 1)

                    clientFilterChipButton(
                        title: client.displayName,
                        dotColor: TokenAnalyticsStyle.color(for: client),
                        isSelected: selectedClient == client,
                        isDragging: draggingClient == client,
                        isDropTarget: dragOverClient == client && draggingClient != client,
                        ultraNarrow: isUltraNarrow
                    ) {
                        withAnimation(pillAnim) {
                            selectedClient = (selectedClient == client) ? nil : client
                        }
                    }
                    .onDrag {
                        draggingClient = client
                        return NSItemProvider(object: client.rawValue as NSString)
                    }
                    .onDrop(
                        of: [.plainText],
                        delegate: TokenClientChipDropDelegate(
                            targetClient: client,
                            availableClients: availableClients,
                            store: store,
                            draggingClient: $draggingClient,
                            dragOverClient: $dragOverClient,
                            animation: snappyAnim
                        )
                    )
                    .contextMenu {
                        Button {
                            withAnimation(snappyAnim) {
                                store.pinTokenClientToFront(client, available: availableClients)
                            }
                        } label: {
                            Label("移到最前", systemImage: "arrow.left.to.line")
                        }
                        .disabled(isFirst)

                        Button {
                            withAnimation(snappyAnim) {
                                store.moveTokenClient(client, direction: .up, available: availableClients)
                            }
                        } label: {
                            Label("向前一位", systemImage: "chevron.left")
                        }
                        .disabled(!canUp)

                        Button {
                            withAnimation(snappyAnim) {
                                store.moveTokenClient(client, direction: .down, available: availableClients)
                            }
                        } label: {
                            Label("向后一位", systemImage: "chevron.right")
                        }
                        .disabled(!canDown)

                        Button {
                            withAnimation(snappyAnim) {
                                store.pinTokenClientToEnd(client, available: availableClients)
                            }
                        } label: {
                            Label("移到最后", systemImage: "arrow.right.to.line")
                        }
                        .disabled(isLast)

                        Divider()

                        Button {
                            withAnimation(snappyAnim) {
                                store.resetTokenClientOrder()
                            }
                        } label: {
                            Label("恢复默认顺序", systemImage: "arrow.counterclockwise")
                        }
                        .disabled(!store.hasCustomTokenClientOrder)
                    }
                    .help("点击筛选 \(client.displayName) · 滚轮横滑 · 拖拽或右键可放前放后")
                }
            }
            .padding(.vertical, 2.5)
            .padding(.horizontal, 2)
            .animation(snappyAnim, value: orderedClients)
        }
        .orbitHorizontalWheelScroll()
    }

    private func clientFilterChipButton(
        title: String,
        dotColor: Color?,
        isSelected: Bool,
        isDragging: Bool,
        isDropTarget: Bool,
        ultraNarrow: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isDark = (colorScheme == .dark)
        let activeTint = dotColor ?? Color.accentColor
        let unselectedFill: Color = isDark
            ? Color.white.opacity(0.085)
            : Color.white.opacity(0.58)

        return Button(action: action) {
            HStack(spacing: 4.5) {
                if let dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6.5, height: 6.5)
                }
                Text(title)
                    .font(.system(size: ultraNarrow ? 10.5 : 11, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? glassPrimaryInk : glassSecondaryInk)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, ultraNarrow ? 8 : 9)
            .padding(.vertical, 4)
            .background {
                if isSelected {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    activeTint.opacity(isDark ? 0.30 : 0.21),
                                    activeTint.opacity(isDark ? 0.18 : 0.12),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                } else {
                    Capsule()
                        .fill(unselectedFill)
                }
            }
            .overlay {
                if isDropTarget {
                    Capsule()
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                } else if isSelected {
                    Capsule()
                        .strokeBorder(activeTint.opacity(isDark ? 0.72 : 0.56), lineWidth: 1.0)
                } else {
                    Capsule()
                        .strokeBorder(glassControlSpecularBorder, lineWidth: 0.65)
                }
            }
            .shadow(
                color: isSelected
                    ? activeTint.opacity(isDark ? 0.22 : 0.12)
                    : Color.black.opacity(isDark ? 0.14 : 0.04),
                radius: isSelected ? 2.5 : 1.2,
                y: 0.6
            )
            .contentShape(Capsule())
        }
        .orbitInteractiveButton(
            pressedScale: 0.96,
            hoverTint: isSelected ? nil : Color.primary.opacity(0.05),
            cornerRadius: 99
        )
        .opacity(isDragging ? 0.52 : 1.0)
        .scaleEffect((isDropTarget && !reduceMotion) ? 1.05 : 1.0)
        .animation(hoverAnim, value: isDropTarget)
        .animation(hoverAnim, value: isDragging)
    }

    // MARK: - Unified Card Dispatcher

    @ViewBuilder
    private func unifiedCardView(
        for card: DashboardTokenCard,
        snapshot: TokenUsageSnapshot,
        summary: TokenRangeSummary,
        heatmapCells: [TokenDailyPoint],
        speed: LiveTokenSpeedSnapshot,
        dateSelection: TokenUsageDateSelection,
        availableWidth: CGFloat,
        cardInnerWidth: CGFloat,
        cardPad: CGFloat,
        compactDensity: Bool
    ) -> some View {
        switch card {
        case .kpiGrid:
            kpiCardsGrid(
                summary: summary,
                dateSelection: dateSelection,
                availableWidth: availableWidth,
                cardPad: cardPad,
                compactDensity: compactDensity
            )
        case .liveSpeed:
            liveSpeedSectionCard(
                speed: speed,
                availableWidth: availableWidth,
                cardInnerWidth: cardInnerWidth,
                cardPad: cardPad,
                compactDensity: compactDensity
            )
        case .heatmap:
            heatmapCard(
                cells: heatmapCells,
                dateSelection: dateSelection,
                availableWidth: availableWidth,
                cardInnerWidth: cardInnerWidth,
                cardPad: cardPad,
                compactDensity: compactDensity
            )
        case .dailyTrend:
            dailyTrendCard(
                snapshot: snapshot,
                summary: summary,
                dateSelection: dateSelection,
                availableWidth: availableWidth,
                cardInnerWidth: cardInnerWidth,
                cardPad: cardPad,
                compactDensity: compactDensity
            )
        case .deepBreakdown:
            deepBreakdownSection(
                summary: summary,
                speed: speed,
                availableWidth: availableWidth,
                cardPad: cardPad,
                compactDensity: compactDensity
            )
        }
    }

    // MARK: - Empty & Scanning Placeholder States

    private func emptyCardsNoticeCard(cardPad: CGFloat) -> some View {
        glassContentCard(padding: cardPad + 8, hoverLift: false) {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.stack.badge.minus")
                    .font(.system(size: 26))
                    .foregroundColor(.secondary)
                Text("已隐藏全部统计卡片")
                    .font(.system(size: 13, weight: .semibold))
                Text("可点击上方「卡片」按需勾选，或一键恢复默认 5 张统计卡片。")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        showCardCustomizer = true
                    } label: {
                        Label("自定义卡片", systemImage: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        withAnimation(snappyAnim) {
                            store.resetDashboardTokenCards()
                        }
                    } label: {
                        Label("恢复默认卡片", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }

    private func scanningPlaceholderCard(availableWidth: CGFloat) -> some View {
        glassContentCard(padding: 18, hoverLift: false) {
            VStack(spacing: 10) {
                PulsarBrandIconView(size: 32, showGlowShadow: true)
                ProgressView()
                    .controlSize(.regular)
                Text("正在扫描本机历史与会话日志...")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("纯本地只读解析本机落盘日志，绝不联网请求 Claude 或拉起子进程。")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                LocalPrivacyBadge(
                    text: availableWidth < 380 ? "纯本地 · 零联网" : "100% 本地只读 · 零 Claude 联网",
                    compact: availableWidth < 380
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private var emptyScanCard: some View {
        glassContentCard(padding: 18, hoverLift: false) {
            VStack(spacing: 10) {
                PulsarBrandIconView(size: 34, showGlowShadow: true)
                Text("尚未扫描本机 Token 日志")
                    .font(.system(size: 13, weight: .semibold))
                Text("点击下方按钮扫描历史基线及本机客户端会话日志。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await store.refreshTokenUsage() }
                } label: {
                    Label("立即扫描本地日志", systemImage: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Card 1: Adaptive KPI Grid (Single Column < 430pt, Balanced 2×2 >= 430pt)

    private func kpiCardsGrid(
        summary: TokenRangeSummary,
        dateSelection: TokenUsageDateSelection,
        availableWidth: CGFloat,
        cardPad: CGFloat,
        compactDensity: Bool
    ) -> some View {
        let isSingleCol = availableWidth < 430
        let gridGap: CGFloat = compactDensity ? 6.5 : (availableWidth < 500 ? 8 : 9.5)

        return Group {
            if isSingleCol {
                VStack(spacing: gridGap) {
                    kpiTokensCard(
                        summary: summary,
                        dateSelection: dateSelection,
                        availableWidth: availableWidth,
                        cardPad: cardPad,
                        compactDensity: compactDensity,
                        singleColumn: true
                    )
                    kpiCostCard(
                        summary: summary,
                        availableWidth: availableWidth,
                        cardPad: cardPad,
                        compactDensity: compactDensity,
                        singleColumn: true
                    )
                    kpiCacheCard(
                        summary: summary,
                        availableWidth: availableWidth,
                        cardPad: cardPad,
                        compactDensity: compactDensity,
                        singleColumn: true
                    )
                    kpiMessagesCard(
                        summary: summary,
                        availableWidth: availableWidth,
                        cardPad: cardPad,
                        compactDensity: compactDensity,
                        singleColumn: true
                    )
                }
            } else {
                Grid(horizontalSpacing: gridGap, verticalSpacing: gridGap) {
                    GridRow {
                        kpiTokensCard(
                            summary: summary,
                            dateSelection: dateSelection,
                            availableWidth: availableWidth,
                            cardPad: cardPad,
                            compactDensity: compactDensity,
                            singleColumn: false
                        )
                        kpiCostCard(
                            summary: summary,
                            availableWidth: availableWidth,
                            cardPad: cardPad,
                            compactDensity: compactDensity,
                            singleColumn: false
                        )
                    }
                    GridRow {
                        kpiCacheCard(
                            summary: summary,
                            availableWidth: availableWidth,
                            cardPad: cardPad,
                            compactDensity: compactDensity,
                            singleColumn: false
                        )
                        kpiMessagesCard(
                            summary: summary,
                            availableWidth: availableWidth,
                            cardPad: cardPad,
                            compactDensity: compactDensity,
                            singleColumn: false
                        )
                    }
                }
            }
        }
    }

    private func kpiHeroFontSize(availableWidth: CGFloat, compactDensity: Bool, singleColumn: Bool) -> CGFloat {
        if singleColumn {
            if availableWidth < 365 {
                return compactDensity ? 19.5 : 21
            }
            return compactDensity ? 21 : 23
        }
        if availableWidth < 490 {
            return compactDensity ? 19 : 20.5
        }
        if availableWidth < 560 {
            return compactDensity ? 20.5 : 22
        }
        return compactDensity ? 22 : 24.5
    }

    private func kpiTokensCard(
        summary: TokenRangeSummary,
        dateSelection: TokenUsageDateSelection,
        availableWidth: CGFloat,
        cardPad: CGFloat,
        compactDensity: Bool,
        singleColumn: Bool
    ) -> some View {
        let totals = summary.totals
        let heroSize = kpiHeroFontSize(availableWidth: availableWidth, compactDensity: compactDensity, singleColumn: singleColumn)
        let showExactInline = singleColumn || availableWidth >= 590
        let rangeBadgeText = dateSelection.displayName

        return glassContentCard(padding: cardPad, fillHeight: !singleColumn) {
            VStack(alignment: .leading, spacing: compactDensity ? 5 : 6.5) {
                HStack(spacing: 6) {
                    Label("总 Tokens", systemImage: "sum")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(rangeBadgeText)
                        .font(.system(size: 9.5, weight: .semibold, design: dateSelection.isCustom ? .rounded : .default))
                        .monospacedDigit()
                        .foregroundColor(.accentColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.80)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                }

                if showExactInline {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(TokenFormatters.compactTokens(totals.totalTokens))
                            .font(.system(size: heroSize, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.80)
                            .fixedSize(horizontal: true, vertical: false)
                            .orbitNumericTransition()

                        Spacer(minLength: 2)

                        Text("精确 \(TokenFormatters.exactTokens(totals.totalTokens))")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text(TokenFormatters.compactTokens(totals.totalTokens))
                            .font(.system(size: heroSize, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .orbitNumericTransition()
                            .help("精确：\(TokenFormatters.exactTokens(totals.totalTokens)) tokens")

                        Text("精确 \(TokenFormatters.exactTokens(totals.totalTokens))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.80)
                    }
                }

                TokenCompositionBar(totals: totals, height: compactDensity ? 5 : 6)

                if singleColumn {
                    TokenCompositionLegend(totals: totals, compact: true, twoColumnGrid: availableWidth < 405)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                        alignment: .leading,
                        spacing: 3
                    ) {
                        kpiComponentMiniRow(color: TokenAnalyticsStyle.uncachedInputColor, name: "输入", value: totals.uncachedInputTokens)
                        kpiComponentMiniRow(color: TokenAnalyticsStyle.outputColor, name: "输出", value: totals.outputTokens)
                        kpiComponentMiniRow(color: TokenAnalyticsStyle.cacheReadColor, name: "缓读", value: totals.cacheReadTokens)
                        kpiComponentMiniRow(color: TokenAnalyticsStyle.cacheWriteColor, name: "缓写", value: totals.cacheWriteTokens)
                    }
                }
            }
        }
    }

    private func kpiCostCard(
        summary: TokenRangeSummary,
        availableWidth: CGFloat,
        cardPad: CGFloat,
        compactDensity: Bool,
        singleColumn: Bool
    ) -> some View {
        let totals = summary.totals
        let dailyAvg = summary.activeDays > 0
            ? totals.estimatedCostUSD / Double(summary.activeDays)
            : 0.0
        let heroSize = kpiHeroFontSize(availableWidth: availableWidth, compactDensity: compactDensity, singleColumn: singleColumn)
        let footnote = availableWidth < 490 && !singleColumn
            ? "按公开 API 单价 / 账单 ticks 估算"
            : "按各模型公开 API 单价 / 账单 ticks 估算"

        return glassContentCard(padding: cardPad, fillHeight: !singleColumn) {
            if singleColumn {
                VStack(alignment: .leading, spacing: compactDensity ? 4.5 : 5.5) {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("估算费用 (USD)", systemImage: "dollarsign.circle")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Text(TokenFormatters.usd(totals.estimatedCostUSD))
                                .font(.system(size: heroSize, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(Color(nsColor: .systemGreen))
                                .lineLimit(1)
                                .minimumScaleFactor(0.80)
                                .fixedSize(horizontal: true, vertical: false)
                                .orbitNumericTransition()
                        }

                        Spacer(minLength: 6)

                        VStack(alignment: .trailing, spacing: 2) {
                            Text("活跃日均")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text("\(TokenFormatters.usd(dailyAvg)) / 天")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.84)
                                .fixedSize(horizontal: true, vertical: false)
                                .orbitNumericTransition()
                        }
                    }

                    Text(footnote)
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.84)
                }
            } else {
                VStack(alignment: .leading, spacing: compactDensity ? 5 : 6.5) {
                    Label("估算费用 (USD)", systemImage: "dollarsign.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Text(TokenFormatters.usd(totals.estimatedCostUSD))
                        .font(.system(size: heroSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(Color(nsColor: .systemGreen))
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                        .orbitNumericTransition()

                    Spacer(minLength: 2)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text("活跃日均")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text("\(TokenFormatters.usd(dailyAvg)) / 天")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.84)
                                .orbitNumericTransition()
                        }
                        Text(footnote)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.84)
                    }
                }
            }
        }
    }

    private func kpiCacheCard(
        summary: TokenRangeSummary,
        availableWidth: CGFloat,
        cardPad: CGFloat,
        compactDensity: Bool,
        singleColumn: Bool
    ) -> some View {
        let totals = summary.totals
        let hitRate = max(0.0, min(1.0, totals.cacheHitRate))
        let heroSize = kpiHeroFontSize(availableWidth: availableWidth, compactDensity: compactDensity, singleColumn: singleColumn)

        return glassContentCard(padding: cardPad, fillHeight: !singleColumn) {
            if singleColumn {
                VStack(alignment: .leading, spacing: compactDensity ? 5 : 6) {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("缓存命中率", systemImage: "bolt.shield")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Text(TokenFormatters.percent(hitRate))
                                .font(.system(size: heroSize, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(TokenAnalyticsStyle.cacheReadColor)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .orbitNumericTransition()
                        }

                        Spacer(minLength: 6)

                        VStack(alignment: .trailing, spacing: 2.5) {
                            HStack(spacing: 5) {
                                Text("缓存读取")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Text(TokenFormatters.compactTokens(totals.cacheReadTokens))
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .orbitNumericTransition()
                            }
                            HStack(spacing: 5) {
                                Text("总输入规模")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Text(TokenFormatters.compactTokens(totals.totalInputTokens))
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .orbitNumericTransition()
                            }
                        }
                    }

                    OrbitAnimatedProgressBar(
                        fraction: hitRate,
                        tint: TokenAnalyticsStyle.cacheReadColor,
                        trackColor: Color.primary.opacity(0.09),
                        height: compactDensity ? 5 : 6,
                        minFillWidth: 4
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: compactDensity ? 5 : 6.5) {
                    Label("缓存命中率", systemImage: "bolt.shield")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Text(TokenFormatters.percent(hitRate))
                        .font(.system(size: heroSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(TokenAnalyticsStyle.cacheReadColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .orbitNumericTransition()

                    OrbitAnimatedProgressBar(
                        fraction: hitRate,
                        tint: TokenAnalyticsStyle.cacheReadColor,
                        trackColor: Color.primary.opacity(0.09),
                        height: compactDensity ? 5 : 6,
                        minFillWidth: 4
                    )

                    Spacer(minLength: 0)

                    VStack(alignment: .leading, spacing: 2.5) {
                        HStack(spacing: 4) {
                            Text("缓存读取")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text(TokenFormatters.compactTokens(totals.cacheReadTokens))
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .orbitNumericTransition()
                        }
                        HStack(spacing: 4) {
                            Text("总输入规模")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text(TokenFormatters.compactTokens(totals.totalInputTokens))
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .orbitNumericTransition()
                        }
                    }
                }
            }
        }
    }

    private func kpiMessagesCard(
        summary: TokenRangeSummary,
        availableWidth: CGFloat,
        cardPad: CGFloat,
        compactDensity: Bool,
        singleColumn: Bool
    ) -> some View {
        let totals = summary.totals
        let avgPerMsg = totals.messageCount > 0
            ? totals.totalTokens / Int64(totals.messageCount)
            : 0
        let heroSize = kpiHeroFontSize(availableWidth: availableWidth, compactDensity: compactDensity, singleColumn: singleColumn)

        return glassContentCard(padding: cardPad, fillHeight: !singleColumn) {
            if singleColumn {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("消息与活跃度", systemImage: "bubble.left.and.bubble.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(TokenAnalyticsStyle.exactCount(totals.messageCount))
                                .font(.system(size: heroSize, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.80)
                                .fixedSize(horizontal: true, vertical: false)
                                .orbitNumericTransition()
                            Text("条")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer(minLength: 6)

                    VStack(alignment: .trailing, spacing: 2.5) {
                        HStack(spacing: 5) {
                            Text("活跃天数")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text("\(summary.activeDays) / \(max(summary.totalDaysInRange, summary.activeDays)) 天")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .orbitNumericTransition()
                        }
                        HStack(spacing: 5) {
                            Text("单条均值")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text("\(TokenFormatters.compactTokens(avgPerMsg)) tok")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .orbitNumericTransition()
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: compactDensity ? 5 : 6.5) {
                    Label("消息与活跃度", systemImage: "bubble.left.and.bubble.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(TokenAnalyticsStyle.exactCount(totals.messageCount))
                            .font(.system(size: heroSize, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .orbitNumericTransition()
                        Text("条")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Spacer(minLength: 2)

                    VStack(alignment: .leading, spacing: 2.5) {
                        HStack(spacing: 4) {
                            Text("活跃天数")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text("\(summary.activeDays) / \(max(summary.totalDaysInRange, summary.activeDays)) 天")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .orbitNumericTransition()
                        }
                        HStack(spacing: 4) {
                            Text("单条均值")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text("\(TokenFormatters.compactTokens(avgPerMsg)) tok")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .orbitNumericTransition()
                        }
                    }
                }
            }
        }
    }

    private func kpiComponentMiniRow(color: Color, name: String, value: Int64) -> some View {
        HStack(spacing: 3.5) {
            Circle()
                .fill(color)
                .frame(width: 5.5, height: 5.5)
            Text(name)
                .font(.system(size: 9.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(TokenFormatters.compactTokens(value))
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .orbitNumericTransition()
        }
    }

    // MARK: - Card 2: Complete Live & Recent Model Speed Card (.liveSpeed)

    private func liveSpeedSectionCard(
        speed: LiveTokenSpeedSnapshot,
        availableWidth: CGFloat,
        cardInnerWidth: CGFloat,
        cardPad: CGFloat,
        compactDensity: Bool
    ) -> some View {
        let isStacked = availableWidth < 480
        let filteredRecent: [ModelSpeedStat] = {
            if let filter = selectedClient {
                return Array(speed.recentModels.filter { $0.client == filter }.prefix(6))
            }
            return Array(speed.recentModels.prefix(6))
        }()

        let activeModel: ModelSpeedStat? = {
            if let filter = selectedClient {
                if let cur = speed.currentModel, cur.client == filter {
                    return cur
                }
                return filteredRecent.first
            }
            return speed.currentModel ?? filteredRecent.first
        }()

        let isDisplayedModelGenerating: Bool = {
            guard speed.isGenerating, let cur = speed.currentModel, let shown = activeModel else {
                return false
            }
            return cur.id == shown.id
        }()

        let maxAvgSpeed = max(filteredRecent.map(\.averageOutputTokPerSec).max() ?? 0.0, 1.0)
        let statusColor: Color = isDisplayedModelGenerating
            ? Color(nsColor: .systemGreen)
            : (activeModel != nil ? Color.accentColor : Color.secondary.opacity(0.6))
        let statusText: String = isDisplayedModelGenerating
            ? "生成中"
            : (activeModel != nil ? "最近活跃" : "待机")
        let nameColWidth: CGFloat = min(204, max(145, cardInnerWidth * 0.37))

        return glassContentCard(
            padding: cardPad,
            isHighlighted: isDisplayedModelGenerating,
            highlightColor: Color(nsColor: .systemGreen)
        ) {
            VStack(alignment: .leading, spacing: compactDensity ? 7.5 : 9.5) {
                // Header
                HStack(spacing: 6) {
                    Label(availableWidth < 385 ? "实时模型速度" : "实时与近期模型速度", systemImage: "bolt.horizontal.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        OrbitPulseDot(color: statusColor, size: 6, isActive: isDisplayedModelGenerating)
                        Text(statusText)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(isDisplayedModelGenerating ? Color(nsColor: .systemGreen) : .secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.12))
                    .clipShape(Capsule())
                    .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 4)

                    if let filter = selectedClient {
                        Text("仅看 \(filter.shortName)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    } else {
                        Text(availableWidth < 440 ? "4s 本地采样" : "每 4 秒本地只读采样")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                // Upper Zone: Current Model Live Speed + 60s Rolling Merged Throughput
                Group {
                    if isStacked {
                        VStack(alignment: .leading, spacing: 7.5) {
                            activeModelSpeedBlock(
                                activeModel: activeModel,
                                isGenerating: isDisplayedModelGenerating,
                                availableWidth: availableWidth,
                                narrow: true
                            )
                            Divider().opacity(0.38)
                            rollingThroughputBlock(speed: speed, horizontalRow: true)
                        }
                    } else {
                        HStack(alignment: .center, spacing: 10) {
                            activeModelSpeedBlock(
                                activeModel: activeModel,
                                isGenerating: isDisplayedModelGenerating,
                                availableWidth: availableWidth,
                                narrow: false
                            )
                            Rectangle()
                                .fill(Color.primary.opacity(0.09))
                                .frame(width: 0.75, height: 50)
                            rollingThroughputBlock(speed: speed, horizontalRow: false)
                                .frame(width: availableWidth < 560 ? 140 : 156, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 9.5)
                .padding(.vertical, compactDensity ? 7 : 8.5)
                .background(nestedSubtleSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                        .strokeBorder(nestedSubtleBorder, lineWidth: 0.6)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8.5, style: .continuous))

                // Lower Zone: Recent Active Models Speed Comparison Bars (Top 6)
                if !filteredRecent.isEmpty {
                    VStack(alignment: .leading, spacing: compactDensity ? 4 : 5) {
                        HStack {
                            Text("近期活跃模型均速对比（Top \(filteredRecent.count)）")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text("基准峰值 \(TokenFormatters.tokensPerSec(maxAvgSpeed))")
                                .font(.system(size: 9.5, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .orbitNumericTransition()
                        }

                        VStack(spacing: compactDensity ? 2 : 3) {
                            ForEach(filteredRecent) { stat in
                                let tint = TokenAnalyticsStyle.color(for: stat.client)
                                let fraction = min(1.0, max(0.0, stat.averageOutputTokPerSec / maxAvgSpeed))
                                let isRowGenerating = speed.isGenerating && speed.currentModel?.id == stat.id
                                let tooltip = "\(stat.modelId) (\(stat.client.displayName))\n均速 \(TokenFormatters.tokensPerSec(stat.averageOutputTokPerSec)) · 最新 \(TokenFormatters.tokensPerSec(stat.latestOutputTokPerSec)) · 峰值 \(TokenFormatters.tokensPerSec(stat.peakOutputTokPerSec))\n末轮 \(TokenFormatters.compactTokens(stat.lastOutputTokens)) tok / \(TokenAnalyticsStyle.shortDuration(stat.lastDurationSec)) · 共 \(stat.sampleCount) 轮样本"

                                if isStacked {
                                    VStack(alignment: .leading, spacing: 3.5) {
                                        HStack(alignment: .center, spacing: 5) {
                                            ClientPillBadge(client: stat.client, useShortName: true, compact: true)
                                                .layoutPriority(1)

                                            Text(stat.modelId)
                                                .font(.system(size: 10.5, weight: isRowGenerating ? .bold : .semibold))
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)

                                            if isRowGenerating {
                                                OrbitPulseDot(color: Color(nsColor: .systemGreen), size: 5.5, isActive: true)
                                                    .layoutPriority(1)
                                            }

                                            Spacer(minLength: 4)

                                            Text(TokenFormatters.tokensPerSec(stat.averageOutputTokPerSec))
                                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                                .monospacedDigit()
                                                .foregroundColor(isRowGenerating ? Color(nsColor: .systemGreen) : .primary)
                                                .lineLimit(1)
                                                .fixedSize(horizontal: true, vertical: false)
                                                .orbitNumericTransition()

                                            Text("\(stat.sampleCount)轮")
                                                .font(.system(size: 9.5, design: .rounded))
                                                .monospacedDigit()
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                                .fixedSize(horizontal: true, vertical: false)
                                        }

                                        HStack(alignment: .center, spacing: 6) {
                                            OrbitAnimatedProgressBar(
                                                fraction: fraction,
                                                tint: isRowGenerating ? Color(nsColor: .systemGreen) : tint,
                                                trackColor: Color.primary.opacity(0.08),
                                                height: 5,
                                                minFillWidth: 4
                                            )
                                            .frame(maxWidth: .infinity)

                                            Text("最新 \(TokenFormatters.tokensPerSec(stat.latestOutputTokPerSec))")
                                                .font(.system(size: 9, design: .rounded))
                                                .monospacedDigit()
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                                .fixedSize(horizontal: true, vertical: false)
                                                .orbitNumericTransition()
                                        }
                                    }
                                    .padding(.horizontal, 6.5)
                                    .padding(.vertical, compactDensity ? 3.5 : 4.5)
                                    .orbitHoverHighlight(cornerRadius: 7)
                                    .help(tooltip)
                                } else {
                                    HStack(alignment: .center, spacing: 7) {
                                        HStack(spacing: 5) {
                                            ClientPillBadge(client: stat.client, useShortName: true, compact: availableWidth < 560)
                                                .layoutPriority(1)

                                            Text(stat.modelId)
                                                .font(.system(size: 11, weight: isRowGenerating ? .bold : .medium))
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)

                                            if isRowGenerating {
                                                OrbitPulseDot(color: Color(nsColor: .systemGreen), size: 5.5, isActive: true)
                                                    .layoutPriority(1)
                                            }
                                        }
                                        .frame(width: nameColWidth, alignment: .leading)

                                        OrbitAnimatedProgressBar(
                                            fraction: fraction,
                                            tint: isRowGenerating ? Color(nsColor: .systemGreen) : tint,
                                            trackColor: Color.primary.opacity(0.08),
                                            height: 6,
                                            minFillWidth: 4
                                        )
                                        .frame(maxWidth: .infinity)

                                        VStack(alignment: .trailing, spacing: 1) {
                                            Text(TokenFormatters.tokensPerSec(stat.averageOutputTokPerSec))
                                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                                .monospacedDigit()
                                                .foregroundColor(isRowGenerating ? Color(nsColor: .systemGreen) : .primary)
                                                .lineLimit(1)
                                                .orbitNumericTransition()
                                            Text("最新 \(TokenFormatters.tokensPerSec(stat.latestOutputTokPerSec))")
                                                .font(.system(size: 9, design: .rounded))
                                                .monospacedDigit()
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                                .orbitNumericTransition()
                                        }
                                        .frame(width: availableWidth < 560 ? 74 : 84, alignment: .trailing)

                                        Text(availableWidth < 560 ? "\(stat.sampleCount)轮" : "\(stat.sampleCount) 轮")
                                            .font(.system(size: 9.5, design: .rounded))
                                            .monospacedDigit()
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .frame(width: availableWidth < 560 ? 34 : 40, alignment: .trailing)
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, compactDensity ? 4 : 5)
                                    .orbitHoverHighlight(cornerRadius: 7)
                                    .help(tooltip)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func activeModelSpeedBlock(
        activeModel: ModelSpeedStat?,
        isGenerating: Bool,
        availableWidth: CGFloat,
        narrow: Bool
    ) -> some View {
        let rateFontSize: CGFloat = availableWidth < 375 ? 16 : (narrow ? 17.5 : 19.5)

        if let cur = activeModel {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5.5) {
                    ClientPillBadge(client: cur.client, useShortName: true, compact: narrow)
                        .layoutPriority(1)

                    Text(cur.modelId)
                        .font(.system(size: narrow ? 11 : 11.5, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("\(cur.modelId) (\(cur.client.displayName))")

                    Spacer(minLength: 2)

                    Text(store.relativeTimeAgoString(since: cur.lastActiveAt))
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                HStack(alignment: .center, spacing: narrow ? 7.5 : 10) {
                    Text(TokenFormatters.tokensPerSec(cur.latestOutputTokPerSec))
                        .font(.system(size: rateFontSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(isGenerating ? Color(nsColor: .systemGreen) : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.84)
                        .fixedSize(horizontal: true, vertical: false)
                        .orbitNumericTransition()

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("均速 \(TokenFormatters.tokensPerSec(cur.averageOutputTokPerSec))")
                                .orbitNumericTransition()
                            Text("·")
                                .foregroundColor(.secondary.opacity(0.55))
                            Text("峰值 \(TokenFormatters.tokensPerSec(cur.peakOutputTokPerSec))")
                                .orbitNumericTransition()
                        }
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.primary.opacity(0.86))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                        Text("末轮 \(TokenFormatters.compactTokens(cur.lastOutputTokens)) tok / \(TokenAnalyticsStyle.shortDuration(cur.lastDurationSec)) · \(cur.sampleCount) 轮样本")
                            .font(.system(size: 9.5, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedClient == nil ? "当前待机 · 暂无近期测速样本" : "所选客户端暂无近期测速样本")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.primary)
                Text("本地客户端产生新回复后将自动采集输出速度与总吞吐。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rollingThroughputBlock(
        speed: LiveTokenSpeedSnapshot,
        horizontalRow: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4.5) {
            Text("近 60 秒全客户端合并")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)

            if horizontalRow {
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Text("输出速率")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Text(TokenFormatters.tokensPerSec(speed.rollingOutputTokPerSec60s))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(speed.rollingOutputTokPerSec60s >= 0.05 ? Color(nsColor: .systemGreen) : .primary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .orbitNumericTransition()
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        Text("总吞吐")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Text(TokenFormatters.tokensPerSec(speed.rollingTotalTokPerSec60s))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.primary.opacity(0.88))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .orbitNumericTransition()
                    }
                }
            } else {
                HStack(spacing: 4) {
                    Text("输出速率")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(TokenFormatters.tokensPerSec(speed.rollingOutputTokPerSec60s))
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(speed.rollingOutputTokPerSec60s >= 0.05 ? Color(nsColor: .systemGreen) : .primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .orbitNumericTransition()
                }

                HStack(spacing: 4) {
                    Text("总吞吐")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(TokenFormatters.tokensPerSec(speed.rollingTotalTokPerSec60s))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.primary.opacity(0.88))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .orbitNumericTransition()
                }
            }
        }
    }

    // MARK: - Card 3: Adaptive 16-Week Activity Heatmap (.heatmap)

    private func heatmapCard(
        cells: [TokenDailyPoint],
        dateSelection: TokenUsageDateSelection,
        availableWidth: CGFloat,
        cardInnerWidth: CGFloat,
        cardPad: CGFloat,
        compactDensity: Bool
    ) -> some View {
        let weeks = TokenAnalyticsStyle.buildHeatmapWeeks(from: cells)
        let activeTint = selectedClient.map { TokenAnalyticsStyle.color(for: $0) }
        let customBounds = dateSelection.customBounds
        let todayYMD = TokenFormatters.ymdString(from: Date())

        let hoveredCell = hoveredHeatmapDate.flatMap { d in cells.first(where: { $0.date == d }) }
        let customFocusDate: String? = {
            guard let b = customBounds else { return nil }
            if cells.contains(where: { $0.date == b.endDate }) {
                return b.endDate
            }
            if cells.contains(where: { $0.date == b.startDate }) {
                return b.startDate
            }
            return nil
        }()
        let focusDate: String? = {
            if let h = hoveredCell { return h.date }
            if let cf = customFocusDate { return cf }
            if let chosen = selectedHeatmapDate, cells.contains(where: { $0.date == chosen }) {
                return chosen
            }
            return cells.last(where: { $0.totals.totalTokens > 0 })?.date ?? cells.last?.date
        }()
        let focusCell = focusDate.flatMap { d in cells.first(where: { $0.date == d }) }

        let colCount = max(weeks.count, 1)
        let weekdayColW: CGFloat = availableWidth < 430 ? 11 : 15
        let cellGap: CGFloat = availableWidth < 380 ? 2.0 : (availableWidth < 460 ? 2.4 : (availableWidth < 560 ? 3.0 : 4.0))
        let matrixInset: CGFloat = 4
        let totalGapsWidth = CGFloat(colCount) * cellGap
        let availableForCells = max(120, cardInnerWidth - matrixInset - weekdayColW - totalGapsWidth)
        let rawCellSize = floor((availableForCells / CGFloat(colCount)) * 2.0) / 2.0
        let maxCellSize: CGFloat = compactDensity ? 18 : 22
        let minReadableCell: CGFloat = 10.5
        let cellSize = min(maxCellSize, max(minReadableCell, rawCellSize))
        let needsHorizontalScroll = rawCellSize < minReadableCell
        let cellCornerRadius: CGFloat = cellSize < 15 ? 2.6 : 3.6
        let legendSquareSize: CGFloat = availableWidth < 430 ? 8 : 9.5

        return glassContentCard(padding: cardPad) {
            VStack(alignment: .leading, spacing: compactDensity ? 7 : 9) {
                HStack(spacing: 6) {
                    Label(
                        availableWidth < 450 ? "近 16 周活跃热力" : "近 16 周活跃热力图（112 天）",
                        systemImage: "square.grid.3x3.fill"
                    )
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)

                    Spacer(minLength: 4)

                    HStack(spacing: 3) {
                        Text("少")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        ForEach(0..<5, id: \.self) { lv in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(TokenAnalyticsStyle.heatmapColor(level: lv, tint: activeTint))
                                .frame(width: legendSquareSize, height: legendSquareSize)
                        }
                        Text("多")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                // 7-row × ~17-col Matrix (fits 340...680pt seamlessly with zero clipping)
                Group {
                    if needsHorizontalScroll {
                        ScrollView(.horizontal, showsIndicators: false) {
                            heatmapMatrixView(
                                weeks: weeks,
                                weekdayColW: weekdayColW,
                                cellSize: cellSize,
                                cellGap: cellGap,
                                cellCornerRadius: cellCornerRadius,
                                activeTint: activeTint,
                                customBounds: customBounds,
                                todayYMD: todayYMD,
                                isTodayPreset: dateSelection == .preset(.today),
                                minMonthGap: 2
                            )
                        }
                        .orbitHorizontalWheelScroll()
                    } else {
                        heatmapMatrixView(
                            weeks: weeks,
                            weekdayColW: weekdayColW,
                            cellSize: cellSize,
                            cellGap: cellGap,
                            cellCornerRadius: cellCornerRadius,
                            activeTint: activeTint,
                            customBounds: customBounds,
                            todayYMD: todayYMD,
                            isTodayPreset: dateSelection == .preset(.today),
                            minMonthGap: availableWidth < 480 ? 2 : 1
                        )
                    }
                }

                Divider().opacity(0.36)

                // Hover / Selected Day Detail Box
                if let cell = focusCell {
                    let isHoverPreview = (hoveredCell != nil)
                    let isCurrentCustomSingleDay = (customBounds?.startDate == cell.date && customBounds?.endDate == cell.date)
                    let isCustomRangeEnd = (!isCurrentCustomSingleDay && customBounds?.endDate == cell.date)
                    let isAccentTag = isHoverPreview || isCurrentCustomSingleDay || isCustomRangeEnd
                    let statusTag: String = {
                        if isHoverPreview { return "悬停预览" }
                        if isCurrentCustomSingleDay { return "已选单日" }
                        if isCustomRangeEnd { return "区间末日" }
                        return "近期活跃"
                    }()

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            Text(statusTag)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(isAccentTag ? .accentColor : .secondary)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1.5)
                                .background((isAccentTag ? Color.accentColor : Color.primary).opacity(0.10))
                                .clipShape(Capsule())
                                .fixedSize(horizontal: true, vertical: false)

                            Text("\(cell.date) \(TokenAnalyticsStyle.weekdayShortCN(for: cell.date))")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.84)

                            Spacer(minLength: 4)

                            Text(TokenFormatters.compactTokens(cell.totals.totalTokens))
                                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .orbitNumericTransition()
                                .help("精确：\(TokenFormatters.exactTokens(cell.totals.totalTokens))")

                            Text(TokenFormatters.usd(cell.totals.estimatedCostUSD))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(Color(nsColor: .systemGreen))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .orbitNumericTransition()
                        }

                        if cell.totals.totalTokens == 0 {
                            Text("当日无用量记录 · 点击热力图任意格子可直接切换到该日统计")
                                .font(.system(size: 9.5))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            if availableWidth < 460 {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("精确 \(TokenFormatters.exactTokens(cell.totals.totalTokens)) tok")
                                        .lineLimit(1)
                                    HStack(spacing: 5) {
                                        Text("缓存命中 \(TokenFormatters.percent(cell.totals.cacheHitRate))")
                                        Text("·")
                                        Text("\(TokenAnalyticsStyle.exactCount(cell.totals.messageCount)) 条消息")
                                    }
                                    .lineLimit(1)
                                }
                                .font(.system(size: 9.5, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                            } else {
                                HStack(spacing: 8) {
                                    Text("精确 \(TokenFormatters.exactTokens(cell.totals.totalTokens)) tok")
                                    Text("·")
                                    Text("缓存命中 \(TokenFormatters.percent(cell.totals.cacheHitRate))")
                                    Text("·")
                                    Text("\(TokenAnalyticsStyle.exactCount(cell.totals.messageCount)) 条消息")
                                }
                                .font(.system(size: 10, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.86)
                            }

                            if !cell.byClient.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 5) {
                                        ForEach(cell.byClient) { item in
                                            let tint = TokenAnalyticsStyle.color(for: item.client)
                                            HStack(spacing: 3.5) {
                                                Circle()
                                                    .fill(tint)
                                                    .frame(width: 5.5, height: 5.5)
                                                Text(item.client.displayName)
                                                    .font(.system(size: 9.5, weight: .semibold))
                                                Text(TokenFormatters.compactTokens(item.totals.totalTokens))
                                                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                                    .monospacedDigit()
                                                Text(TokenFormatters.usd(item.totals.estimatedCostUSD))
                                                    .font(.system(size: 9, design: .rounded))
                                                    .monospacedDigit()
                                                    .foregroundColor(.secondary)
                                            }
                                            .padding(.horizontal, 6.5)
                                            .padding(.vertical, 3)
                                            .background(tint.opacity(0.11))
                                            .clipShape(Capsule())
                                        }
                                    }
                                }
                                .orbitHorizontalWheelScroll()
                            }
                        }

                        if !isHoverPreview {
                            Text("提示：点击任意日期格可一键切换到该日的自定义单日统计")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary.opacity(0.85))
                                .lineLimit(1)
                                .minimumScaleFactor(0.86)
                        }
                    }
                    .padding(compactDensity ? 7 : 8.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(nestedSubtleSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(nestedSubtleBorder, lineWidth: 0.6)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .animation(hoverAnim, value: cell.date)
                }
            }
        }
    }

    private func heatmapMatrixView(
        weeks: [[TokenDailyPoint?]],
        weekdayColW: CGFloat,
        cellSize: CGFloat,
        cellGap: CGFloat,
        cellCornerRadius: CGFloat,
        activeTint: Color?,
        customBounds: (startDate: String, endDate: String)?,
        todayYMD: String,
        isTodayPreset: Bool,
        minMonthGap: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 3.5) {
            // Month Header Row
            HStack(alignment: .center, spacing: cellGap) {
                Color.clear
                    .frame(width: weekdayColW, height: 11)
                ForEach(Array(weeks.enumerated()), id: \.offset) { colIdx, _ in
                    let label = TokenAnalyticsStyle.monthHeaderLabel(
                        for: colIdx,
                        weeks: weeks,
                        minColumnGap: minMonthGap
                    )
                    let labelAlign: Alignment = (colIdx >= weeks.count - 1) ? .trailing : .leading
                    Color.clear
                        .frame(width: cellSize, height: 11)
                        .overlay(alignment: labelAlign) {
                            if !label.isEmpty {
                                Text(label)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                }
            }
            .frame(height: 11)
            .padding(.horizontal, 2)

            // 7 Weekday Rows
            VStack(alignment: .leading, spacing: cellGap) {
                ForEach(0..<7, id: \.self) { row in
                    let weekdayLabel: String = {
                        switch row {
                        case 0: return "一"
                        case 2: return "三"
                        case 4: return "五"
                        default: return ""
                        }
                    }()
                    let rowContainsHover = (hoveredHeatmapRow == row)

                    HStack(alignment: .center, spacing: cellGap) {
                        Text(weekdayLabel)
                            .font(.system(size: 8.5))
                            .foregroundColor(.secondary)
                            .frame(width: weekdayColW, alignment: .leading)

                        ForEach(Array(weeks.enumerated()), id: \.offset) { colIdx, week in
                            if let point = week[row] {
                                let isInCustomRange: Bool = {
                                    guard let b = customBounds else { return false }
                                    return point.date >= b.startDate && point.date <= b.endDate
                                }()
                                let isCustomEndpoint: Bool = {
                                    guard let b = customBounds else { return false }
                                    return point.date == b.startDate || point.date == b.endDate
                                }()
                                let isTodayHighlighted = isTodayPreset && (point.date == todayYMD)
                                let isHovered = (hoveredHeatmapDate == point.date)

                                let strokeColor: Color = {
                                    if isInCustomRange {
                                        return Color.accentColor
                                    }
                                    if isHovered {
                                        return Color.primary.opacity(0.68)
                                    }
                                    if isTodayHighlighted {
                                        return Color(nsColor: .systemGreen).opacity(0.92)
                                    }
                                    return Color.primary.opacity(0.065)
                                }()
                                let strokeWidth: CGFloat = {
                                    if isCustomEndpoint { return 1.8 }
                                    if isInCustomRange { return 1.35 }
                                    if isHovered { return 1.15 }
                                    if isTodayHighlighted { return 1.25 }
                                    return 0.45
                                }()

                                Button {
                                    withAnimation(snappyAnim) {
                                        selectedHeatmapDate = point.date
                                        store.selectTokenUsageSingleDay(point.date)
                                    }
                                } label: {
                                    RoundedRectangle(cornerRadius: cellCornerRadius, style: .continuous)
                                        .fill(TokenAnalyticsStyle.heatmapColor(level: point.heatmapLevel, tint: activeTint))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: cellCornerRadius, style: .continuous)
                                                .strokeBorder(strokeColor, lineWidth: strokeWidth)
                                        )
                                        .frame(width: cellSize, height: cellSize)
                                        .scaleEffect((isHovered && !reduceMotion) ? 1.16 : 1.0)
                                        .shadow(
                                            color: isInCustomRange
                                                ? Color.accentColor.opacity(0.32)
                                                : (isHovered ? (activeTint ?? Color.accentColor).opacity(0.28) : .clear),
                                            radius: isInCustomRange ? 2.5 : 3,
                                            y: 0.5
                                        )
                                        .animation(hoverAnim, value: isHovered)
                                        .animation(snappyAnim, value: isInCustomRange)
                                }
                                .buttonStyle(.plain)
                                .zIndex(isHovered ? 5 : (isInCustomRange ? 3 : Double(colIdx) * 0.001))
                                .onHover { hovering in
                                    if hovering {
                                        hoveredHeatmapDate = point.date
                                        hoveredHeatmapRow = row
                                    } else {
                                        if hoveredHeatmapDate == point.date {
                                            hoveredHeatmapDate = nil
                                        }
                                        if hoveredHeatmapRow == row && hoveredHeatmapDate == nil {
                                            hoveredHeatmapRow = nil
                                        }
                                    }
                                }
                                .help("\(point.date) (\(TokenAnalyticsStyle.weekdayShortCN(for: point.date)))\nTokens: \(TokenFormatters.exactTokens(point.totals.totalTokens))\n费用: \(TokenFormatters.usd(point.totals.estimatedCostUSD))\n点击切换到该日单日统计")
                            } else {
                                Color.clear
                                    .frame(width: cellSize, height: cellSize)
                            }
                        }
                    }
                    .zIndex(rowContainsHover ? 3 : 0)
                }
            }
            .padding(2)
        }
    }

    // MARK: - Card 4: Adaptive Daily Trend Chart (.dailyTrend)

    private func dailyTrendCard(
        snapshot: TokenUsageSnapshot,
        summary: TokenRangeSummary,
        dateSelection: TokenUsageDateSelection,
        availableWidth: CGFloat,
        cardInnerWidth: CGFloat,
        cardPad: CGFloat,
        compactDensity: Bool
    ) -> some View {
        let series: [TokenDailyPoint] = {
            switch dateSelection {
            case .preset(.today):
                return snapshot.heatmap(days: 14, clientFilter: selectedClient)
            case .preset(.days7):
                return summary.dailySeries.isEmpty ? snapshot.heatmap(days: 7, clientFilter: selectedClient) : summary.dailySeries
            case .preset(.days30):
                return summary.dailySeries.isEmpty ? snapshot.heatmap(days: 30, clientFilter: selectedClient) : summary.dailySeries
            case .preset(.allTime):
                let tail = summary.dailySeries.suffix(30)
                return tail.isEmpty ? snapshot.heatmap(days: 30, clientFilter: selectedClient) : Array(tail)
            case .custom(let start, let end):
                let lo = min(start, end)
                let hi = max(start, end)
                if lo == hi {
                    // For a single custom day, show a crisp 14-day trailing context ending on that day with the chosen day highlighted.
                    if let targetDate = TokenFormatters.date(fromYMD: lo),
                       let ctxStart = Calendar(identifier: .gregorian).date(byAdding: .day, value: -13, to: targetDate) {
                        let ctxSummary = snapshot.summary(
                            startDate: TokenFormatters.ymdString(from: ctxStart),
                            endDate: hi,
                            clientFilter: selectedClient
                        )
                        if !ctxSummary.dailySeries.isEmpty {
                            return ctxSummary.dailySeries
                        }
                    }
                }
                return summary.dailySeries
            }
        }()

        let values: [Double] = series.map { pt in
            trendMetric == .tokens ? Double(pt.totals.totalTokens) : pt.totals.estimatedCostUSD
        }
        let maxValue = max(values.max() ?? 0.0, 0.0001)
        let activeTint = selectedClient.map { TokenAnalyticsStyle.color(for: $0) }
            ?? (trendMetric == .tokens ? Color.accentColor : Color(nsColor: .systemGreen))
        let highlightedSingleDate: String? = {
            switch dateSelection {
            case .preset(.today):
                return series.last?.date
            case .custom(let s, let e) where s == e:
                return s
            default:
                return nil
            }
        }()

        let focusedPoint: TokenDailyPoint? = {
            if let hovered = hoveredTrendDate, let pt = series.first(where: { $0.date == hovered }) {
                return pt
            }
            if let hl = highlightedSingleDate, let pt = series.first(where: { $0.date == hl }) {
                return pt
            }
            if let sel = selectedHeatmapDate, let pt = series.first(where: { $0.date == sel }) {
                return pt
            }
            return series.last
        }()

        let chartSubtitle: String = {
            switch dateSelection {
            case .preset(.today):
                return "近 14 天对比（高亮今日）"
            case .preset(.days7):
                return "近 7 天每日明细"
            case .preset(.days30):
                return "近 30 天每日明细"
            case .preset(.allTime):
                return "近期 30 天走势"
            case .custom(let s, let e):
                let lo = min(s, e)
                let hi = max(s, e)
                if lo == hi {
                    return "近 14 天上下文（高亮 \(TokenAnalyticsStyle.shortMonthDay(lo))）"
                }
                return "自定义区间 · \(TokenFormatters.customRangeLabel(startDate: lo, endDate: hi))（\(series.count)天）"
            }
        }()

        let isNarrowChart = availableWidth < 460
        let yAxisWidth: CGFloat = isNarrowChart ? 40 : 50
        let barsLeadingPad: CGFloat = yAxisWidth + 6
        let plotWidth = max(120, cardInnerWidth - barsLeadingPad)
        let chartHeight: CGFloat = compactDensity ? 116 : 142
        let maxBarHeight: CGFloat = compactDensity ? 94 : 116

        let minBarPitch: CGFloat = 4.0
        let needsHorizontalBarScroll = CGFloat(series.count) * minBarPitch > plotWidth
        let barSpacing: CGFloat = {
            if needsHorizontalBarScroll { return 1.5 }
            if series.count <= 10 { return isNarrowChart ? 4.5 : 7.5 }
            if series.count <= 16 { return isNarrowChart ? 2.5 : 4.5 }
            if series.count <= 35 { return isNarrowChart ? 1.5 : 3.0 }
            return 1.0
        }()
        let crossYearSpan: Bool = {
            guard let f = series.first?.date, let l = series.last?.date, f.count >= 4, l.count >= 4 else {
                return false
            }
            return f.prefix(4) != l.prefix(4)
        }()

        return glassContentCard(padding: cardPad) {
            VStack(alignment: .leading, spacing: compactDensity ? 7 : 9) {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Label("每日趋势柱图", systemImage: "chart.bar.fill")
                            .font(.system(size: 12, weight: .bold))
                            .lineLimit(1)
                        Text(chartSubtitle)
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 4)

                    HStack(spacing: 2) {
                        ForEach(TrendMetric.allCases) { metric in
                            let isOn = (trendMetric == metric)
                            Button {
                                withAnimation(pillAnim) {
                                    trendMetric = metric
                                }
                            } label: {
                                Text(metric.rawValue)
                                    .font(.system(size: 10, weight: isOn ? .semibold : .medium))
                                    .foregroundColor(isOn ? .primary : .secondary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, isNarrowChart ? 6.5 : 8.5)
                                    .padding(.vertical, 3.5)
                                    .background {
                                        if isOn {
                                            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                                .fill(
                                                    colorScheme == .dark
                                                        ? Color.white.opacity(0.16)
                                                        : Color.white.opacity(0.84)
                                                )
                                                .shadow(color: Color.black.opacity(0.08), radius: 1.2, y: 0.5)
                                                .matchedGeometryEffect(id: "trendMetricPill", in: trendMetricNamespace)
                                        }
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                            }
                            .orbitInteractiveButton(
                                pressedScale: 0.96,
                                hoverTint: isOn ? nil : Color.primary.opacity(0.045),
                                cornerRadius: 5.5
                            )
                        }
                    }
                    .padding(2)
                    .background(Color.primary.opacity(0.065))
                    .clipShape(RoundedRectangle(cornerRadius: 7.5, style: .continuous))
                }

                // Focused Day Readout Strip
                if let focus = focusedPoint {
                    HStack(spacing: 6) {
                        let dateStr = isNarrowChart
                            ? "\(TokenAnalyticsStyle.shortMonthDay(focus.date)) \(TokenAnalyticsStyle.weekdayShortCN(for: focus.date))"
                            : "\(focus.date) \(TokenAnalyticsStyle.weekdayShortCN(for: focus.date))"
                        Text(dateStr)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 4)

                        Text(TokenFormatters.compactTokens(focus.totals.totalTokens))
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .orbitNumericTransition()

                        Text(TokenFormatters.usd(focus.totals.estimatedCostUSD))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(Color(nsColor: .systemGreen))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .orbitNumericTransition()

                        if availableWidth >= 380 {
                            Text("\(TokenAnalyticsStyle.compactCount(focus.totals.messageCount))条")
                                .font(.system(size: 9.5, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(minHeight: 24)
                    .background(nestedSubtleSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(nestedSubtleBorder, lineWidth: 0.6)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .animation(hoverAnim, value: focus.date)
                }

                if series.isEmpty {
                    Text("所选日期范围内暂无每日趋势数据")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: chartHeight, alignment: .center)
                } else {
                    ZStack(alignment: .bottomLeading) {
                        // Y-Axis Gridlines
                        VStack {
                            gridLine(
                                label: trendMetric == .tokens
                                    ? TokenFormatters.compactTokens(Int64(maxValue.rounded()))
                                    : AppStore.compactCurrencyString(amount: maxValue, currency: "USD"),
                                labelWidth: yAxisWidth
                            )
                            Spacer()
                            gridLine(
                                label: trendMetric == .tokens
                                    ? TokenFormatters.compactTokens(Int64((maxValue * 0.5).rounded()))
                                    : AppStore.compactCurrencyString(amount: maxValue * 0.5, currency: "USD"),
                                labelWidth: yAxisWidth
                            )
                            Spacer()
                            gridLine(label: "0", labelWidth: yAxisWidth)
                        }
                        .frame(height: chartHeight)

                        // Bars (Flexible when fitting; smooth horizontal wheel scroll when span is very wide)
                        Group {
                            if needsHorizontalBarScroll {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    trendBarsRow(
                                        series: series,
                                        values: values,
                                        maxValue: maxValue,
                                        activeTint: activeTint,
                                        highlightedSingleDate: highlightedSingleDate,
                                        chartHeight: chartHeight,
                                        maxBarHeight: maxBarHeight,
                                        barSpacing: barSpacing,
                                        fixedBarWidth: 4.5,
                                        isNarrowChart: isNarrowChart
                                    )
                                }
                                .orbitHorizontalWheelScroll()
                            } else {
                                trendBarsRow(
                                    series: series,
                                    values: values,
                                    maxValue: maxValue,
                                    activeTint: activeTint,
                                    highlightedSingleDate: highlightedSingleDate,
                                    chartHeight: chartHeight,
                                    maxBarHeight: maxBarHeight,
                                    barSpacing: barSpacing,
                                    fixedBarWidth: nil,
                                    isNarrowChart: isNarrowChart
                                )
                            }
                        }
                        .padding(.leading, barsLeadingPad)
                    }
                    .frame(height: chartHeight)

                    // Adaptive X-axis Labels
                    trendXAxisLabels(
                        series: series,
                        availableWidth: availableWidth,
                        crossYearSpan: crossYearSpan
                    )
                    .padding(.leading, barsLeadingPad)
                }
            }
        }
    }

    private func trendBarsRow(
        series: [TokenDailyPoint],
        values: [Double],
        maxValue: Double,
        activeTint: Color,
        highlightedSingleDate: String?,
        chartHeight: CGFloat,
        maxBarHeight: CGFloat,
        barSpacing: CGFloat,
        fixedBarWidth: CGFloat?,
        isNarrowChart: Bool
    ) -> some View {
        HStack(alignment: .bottom, spacing: barSpacing) {
            ForEach(Array(series.enumerated()), id: \.element.id) { idx, pt in
                let val = values[idx]
                let ratio = val / maxValue
                let isHovered = (hoveredTrendDate == pt.date)
                let isSelectedDay = (selectedHeatmapDate == pt.date)
                let isHighlightBar = (highlightedSingleDate == pt.date)
                let barHeight: CGFloat = val > 0 ? max(4, CGFloat(ratio) * maxBarHeight) : 2.5
                let cornerRadius: CGFloat = series.count <= 14 ? 4 : (series.count <= 35 ? 2.5 : 1.5)
                let barBaseColor: Color = isHighlightBar ? Color(nsColor: .systemGreen) : activeTint
                let barFill: Color = {
                    if isHovered || isSelectedDay { return barBaseColor }
                    if isHighlightBar { return Color(nsColor: .systemGreen).opacity(0.92) }
                    return val > 0 ? activeTint.opacity(0.70) : Color.primary.opacity(0.08)
                }()
                let barTopLabel: String = trendMetric == .tokens
                    ? TokenFormatters.compactTokens(pt.totals.totalTokens)
                    : TokenFormatters.usd(pt.totals.estimatedCostUSD)
                let showTopLabel = (series.count <= (isNarrowChart ? 7 : 10) && val > 0) || isHovered
                let topLabelAlignment: Alignment = {
                    if idx == 0 { return .topLeading }
                    if idx == series.count - 1 { return .topTrailing }
                    return .top
                }()

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(barFill)
                        .frame(height: barHeight)
                        .animation(smoothAnim, value: barHeight)
                        .overlay(alignment: .top) {
                            if isHovered && val > 0 {
                                Capsule()
                                    .fill(Color.white.opacity(0.55))
                                    .frame(height: 1.5)
                                    .padding(.horizontal, 1)
                            }
                        }
                        .scaleEffect(
                            x: (isHovered && !reduceMotion) ? 1.08 : 1.0,
                            y: (isHovered && !reduceMotion) ? 1.04 : 1.0,
                            anchor: .bottom
                        )
                        .shadow(
                            color: isHovered ? barBaseColor.opacity(0.30) : .clear,
                            radius: 4,
                            y: 0
                        )
                        .animation(hoverAnim, value: isHovered)
                        .overlay(alignment: topLabelAlignment) {
                            Text(barTopLabel)
                                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(isHovered ? barBaseColor : .secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .offset(y: -14)
                                .opacity(showTopLabel ? 1.0 : 0.0)
                                .animation(hoverAnim, value: showTopLabel)
                                .allowsHitTesting(false)
                        }
                }
                .frame(
                    minWidth: fixedBarWidth,
                    maxWidth: fixedBarWidth ?? .infinity,
                    minHeight: chartHeight,
                    maxHeight: chartHeight
                )
                .zIndex(isHovered ? 3 : (isHighlightBar || isSelectedDay ? 1 : 0))
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        hoveredTrendDate = pt.date
                    } else if hoveredTrendDate == pt.date {
                        hoveredTrendDate = nil
                    }
                }
                .onTapGesture {
                    withAnimation(snappyAnim) {
                        selectedHeatmapDate = pt.date
                        store.selectTokenUsageSingleDay(pt.date)
                    }
                }
                .help("\(pt.date) · \(TokenFormatters.compactTokens(pt.totals.totalTokens)) · \(TokenFormatters.usd(pt.totals.estimatedCostUSD))\n点击查看当日统计")
            }
        }
    }

    private func trendXAxisLabels(
        series: [TokenDailyPoint],
        availableWidth: CGFloat,
        crossYearSpan: Bool
    ) -> some View {
        func axisText(_ ymd: String) -> String {
            crossYearSpan ? TokenAnalyticsStyle.shortYearMonthDay(ymd) : TokenAnalyticsStyle.shortMonthDay(ymd)
        }

        return HStack {
            if series.count == 1, let only = series.first {
                Spacer()
                Text(axisText(only.date))
                Spacer()
            } else {
                if let first = series.first {
                    Text(axisText(first.date))
                }
                Spacer()
                if availableWidth < 430 {
                    if series.count >= 5 {
                        Text(axisText(series[series.count / 2].date))
                        Spacer()
                    }
                } else if series.count >= 6 {
                    Text(axisText(series[series.count / 3].date))
                    Spacer()
                    Text(axisText(series[(series.count * 2) / 3].date))
                    Spacer()
                }
                if let last = series.last {
                    Text(axisText(last.date))
                }
            }
        }
        .font(.system(size: 9.5, design: .rounded))
        .monospacedDigit()
        .foregroundColor(.secondary)
        .lineLimit(1)
    }

    private func gridLine(label: String, labelWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 8.5, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.80)
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.6)
        }
    }

    // MARK: - Card 5: Adaptive 3-Tab Deep Breakdown Section (.deepBreakdown)

    private func deepBreakdownSection(
        summary: TokenRangeSummary,
        speed: LiveTokenSpeedSnapshot,
        availableWidth: CGFloat,
        cardPad: CGFloat,
        compactDensity: Bool
    ) -> some View {
        let useShortTabTitles = availableWidth < 435
        let stackFilterPill = availableWidth < 510 && selectedClient != nil

        return glassContentCard(padding: cardPad) {
            VStack(alignment: .leading, spacing: compactDensity ? 7.5 : 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        HStack(spacing: 2) {
                            ForEach(BreakdownTab.allCases) { tab in
                                let isSelected = (selectedBreakdownTab == tab)
                                let count: Int = {
                                    switch tab {
                                    case .clients: return summary.byClient.count
                                    case .models: return summary.byModel.count
                                    case .projects: return summary.byProject.count
                                    }
                                }()

                                Button {
                                    withAnimation(pillAnim) {
                                        selectedBreakdownTab = tab
                                    }
                                } label: {
                                    HStack(spacing: 3.5) {
                                        Text(useShortTabTitles ? tab.shortTitle : tab.rawValue)
                                            .font(.system(size: useShortTabTitles ? 10.5 : 11.5, weight: isSelected ? .semibold : .medium))
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                        Text("\(count)")
                                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                                            .monospacedDigit()
                                            .foregroundColor(
                                                isSelected
                                                    ? (colorScheme == .dark ? Color(red: 0.48, green: 0.76, blue: 1.0) : .accentColor)
                                                    : .secondary
                                            )
                                            .padding(.horizontal, 4.5)
                                            .padding(.vertical, 1)
                                            .background(
                                                (isSelected ? Color.accentColor : Color.primary)
                                                    .opacity(colorScheme == .dark ? (isSelected ? 0.24 : 0.10) : 0.08)
                                            )
                                            .clipShape(Capsule())
                                    }
                                    .foregroundColor(isSelected ? .primary : .secondary)
                                    .padding(.horizontal, useShortTabTitles ? 7 : 9)
                                    .padding(.vertical, 4.5)
                                    .background {
                                        if isSelected {
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .fill(
                                                    colorScheme == .dark
                                                        ? Color.white.opacity(0.16)
                                                        : Color.white.opacity(0.84)
                                                )
                                                .shadow(color: Color.black.opacity(0.08), radius: 1.5, y: 0.5)
                                                .matchedGeometryEffect(id: "breakdownTabPill", in: breakdownTabNamespace)
                                        }
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                }
                                .orbitInteractiveButton(
                                    pressedScale: 0.97,
                                    hoverTint: isSelected ? nil : Color.primary.opacity(0.045),
                                    cornerRadius: 7
                                )
                            }
                        }
                        .padding(2.5)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                        Spacer(minLength: 4)

                        if !stackFilterPill, let filter = selectedClient {
                            clearClientFilterPill(filter: filter)
                        }
                    }

                    if stackFilterPill, let filter = selectedClient {
                        clearClientFilterPill(filter: filter)
                    }
                }

                ZStack(alignment: .top) {
                    Group {
                        switch selectedBreakdownTab {
                        case .clients:
                            clientsDeepTable(
                                rows: summary.byClient,
                                availableWidth: availableWidth,
                                compactDensity: compactDensity
                            )
                        case .models:
                            modelsDeepTable(
                                allRows: summary.byModel,
                                speed: speed,
                                availableWidth: availableWidth,
                                compactDensity: compactDensity
                            )
                        case .projects:
                            projectsDeepTable(
                                allRows: summary.byProject,
                                availableWidth: availableWidth,
                                compactDensity: compactDensity
                            )
                        }
                    }
                    .id(selectedBreakdownTab)
                    .transition(activePanelTransition)
                }
                .animation(snappyAnim, value: selectedBreakdownTab)
            }
        }
    }

    private func clearClientFilterPill(filter: TokenClientID) -> some View {
        Button {
            withAnimation(pillAnim) {
                selectedClient = nil
            }
        } label: {
            HStack(spacing: 4) {
                Text("已筛选：\(filter.displayName)")
                    .lineLimit(1)
                Image(systemName: "xmark.circle.fill")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.11))
            .clipShape(Capsule())
        }
        .orbitInteractiveButton(
            pressedScale: 0.96,
            hoverTint: Color.accentColor.opacity(0.15),
            cornerRadius: 99
        )
        .fixedSize(horizontal: true, vertical: false)
        .transition(.opacity)
    }

    // MARK: Breakdown Tab 1 — Clients Table

    private func clientsDeepTable(
        rows: [TokenClientBreakdown],
        availableWidth: CGFloat,
        compactDensity: Bool
    ) -> some View {
        let isNarrowRows = availableWidth < 480
        let showMessageCol = availableWidth >= 600
        let nameColW: CGFloat = showMessageCol ? 128 : 114
        let tokColW: CGFloat = showMessageCol ? 58 : 54
        let hitColW: CGFloat = showMessageCol ? 50 : 46
        let costColW: CGFloat = showMessageCol ? 76 : 68

        return VStack(spacing: 0) {
            if !isNarrowRows {
                HStack(spacing: 6) {
                    Text("客户端")
                        .frame(width: nameColW, alignment: .leading)
                    Text("占比")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("总 Tokens")
                        .frame(width: tokColW, alignment: .trailing)
                    Text("缓存命中")
                        .frame(width: hitColW, alignment: .trailing)
                    Text("估算费用")
                        .frame(width: costColW, alignment: .trailing)
                    if showMessageCol {
                        Text("消息数")
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(nestedSubtleSurface)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            if rows.isEmpty {
                emptyTableNotice("当前筛选条件下暂无客户端数据")
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    let tint = TokenAnalyticsStyle.color(for: row.client)
                    let pct = max(0.0, min(1.0, row.shareOfTokens))
                    let isClientActive = (selectedClient == row.client)

                    Button {
                        withAnimation(pillAnim) {
                            selectedClient = isClientActive ? nil : row.client
                        }
                    } label: {
                        if isNarrowRows {
                            VStack(alignment: .leading, spacing: compactDensity ? 3.5 : 4.5) {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(tint)
                                        .frame(width: 7, height: 7)

                                    Text(row.client.displayName)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)

                                    Text("· \(row.activeDays)天")
                                        .font(.system(size: 9.5))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)

                                    Spacer(minLength: 4)

                                    Text(TokenFormatters.compactTokens(row.totals.totalTokens))
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .orbitNumericTransition()
                                        .help("精确：\(TokenFormatters.exactTokens(row.totals.totalTokens))")

                                    Text(TokenFormatters.usd(row.totals.estimatedCostUSD))
                                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundColor(.primary.opacity(0.88))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .orbitNumericTransition()
                                }

                                HStack(spacing: 5.5) {
                                    OrbitAnimatedProgressBar(
                                        fraction: pct,
                                        tint: tint,
                                        trackColor: Color.primary.opacity(0.08),
                                        height: 5,
                                        minFillWidth: 4
                                    )
                                    .frame(maxWidth: .infinity)

                                    Text(TokenFormatters.percent(pct))
                                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)

                                    Text("命中 \(TokenFormatters.percent(row.totals.cacheHitRate))")
                                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundColor(TokenAnalyticsStyle.cacheReadColor)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)

                                    if availableWidth >= 420 {
                                        Text("\(TokenAnalyticsStyle.compactCount(row.totals.messageCount))条")
                                            .font(.system(size: 9.5, design: .rounded))
                                            .monospacedDigit()
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                }
                            }
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, compactDensity ? 5 : 6.5)
                        } else {
                            HStack(spacing: 6) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(tint)
                                        .frame(width: 7.5, height: 7.5)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(row.client.displayName)
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Text(showMessageCol
                                            ? "活跃 \(row.activeDays) 天"
                                            : "\(row.activeDays)天 · \(TokenAnalyticsStyle.compactCount(row.totals.messageCount))条")
                                            .font(.system(size: 9.5))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(width: nameColW, alignment: .leading)

                                HStack(spacing: 5) {
                                    OrbitAnimatedProgressBar(
                                        fraction: pct,
                                        tint: tint,
                                        trackColor: Color.primary.opacity(0.08),
                                        height: 6,
                                        minFillWidth: 4
                                    )

                                    Text(TokenFormatters.percent(pct))
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundColor(.secondary)
                                        .frame(width: 38, alignment: .trailing)
                                        .lineLimit(1)
                                        .orbitNumericTransition()
                                }
                                .frame(maxWidth: .infinity)

                                Text(TokenFormatters.compactTokens(row.totals.totalTokens))
                                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .frame(width: tokColW, alignment: .trailing)
                                    .orbitNumericTransition()
                                    .help("精确：\(TokenFormatters.exactTokens(row.totals.totalTokens))")

                                Text(TokenFormatters.percent(row.totals.cacheHitRate))
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(TokenAnalyticsStyle.cacheReadColor)
                                    .lineLimit(1)
                                    .frame(width: hitColW, alignment: .trailing)
                                    .orbitNumericTransition()

                                Text(TokenFormatters.usd(row.totals.estimatedCostUSD))
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.86)
                                    .frame(width: costColW, alignment: .trailing)
                                    .orbitNumericTransition()

                                if showMessageCol {
                                    Text(TokenAnalyticsStyle.exactCount(row.totals.messageCount))
                                        .font(.system(size: 10.5, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.86)
                                        .frame(width: 52, alignment: .trailing)
                                        .orbitNumericTransition()
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, compactDensity ? 5.5 : 7)
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isClientActive ? tint.opacity(0.09) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .orbitInteractiveButton(
                        pressedScale: 0.992,
                        hoverTint: Color.primary.opacity(0.045),
                        cornerRadius: 7
                    )

                    if idx < rows.count - 1 {
                        Divider().opacity(0.28)
                    }
                }
            }
        }
    }

    // MARK: Breakdown Tab 2 — Models Table (with SpeedPillBadge)

    private func modelsDeepTable(
        allRows: [TokenModelBreakdown],
        speed: LiveTokenSpeedSnapshot,
        availableWidth: CGFloat,
        compactDensity: Bool
    ) -> some View {
        let isStackedNarrow = availableWidth < 455
        let isWide = availableWidth >= 560
        let tokColW: CGFloat = isWide ? 70 : 60
        let costColW: CGFloat = isWide ? 80 : 70
        let displayedRows = showAllModels ? allRows : Array(allRows.prefix(12))

        return VStack(spacing: 0) {
            if !isStackedNarrow {
                HStack(spacing: isWide ? 8 : 6) {
                    Text("#")
                        .frame(width: isWide ? 22 : 18, alignment: .center)
                    Text(isWide ? "模型 · 四分项 (入 / 出 / 缓读 / 缓写)" : "模型 · 测速与分项")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("总 Tokens")
                        .frame(width: tokColW, alignment: .trailing)
                    Text("估算费用")
                        .frame(width: costColW, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(nestedSubtleSurface)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            if displayedRows.isEmpty {
                emptyTableNotice("当前筛选条件下暂无模型排行数据")
            } else {
                ForEach(Array(displayedRows.enumerated()), id: \.element.id) { idx, item in
                    let speedStat = speed.speedStat(for: item.client, modelId: item.modelId)
                    let isModelLive = speed.isGenerating && speedStat != nil && speed.currentModel?.id == speedStat?.id

                    if isStackedNarrow {
                        VStack(alignment: .leading, spacing: compactDensity ? 3 : 4) {
                            HStack(alignment: .center, spacing: 5) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(idx < 3 ? .accentColor : .secondary)
                                    .frame(width: 15, alignment: .center)

                                Text(item.modelId)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help("\(item.modelId) · provider: \(item.providerId)")

                                Spacer(minLength: 4)

                                Text(TokenFormatters.compactTokens(item.totals.totalTokens))
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .orbitNumericTransition()
                                    .help("精确：\(TokenFormatters.exactTokens(item.totals.totalTokens))")

                                Text(TokenFormatters.usd(item.totals.estimatedCostUSD))
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.primary.opacity(0.88))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .orbitNumericTransition()
                            }

                            HStack(alignment: .center, spacing: 5) {
                                ClientPillBadge(client: item.client, useShortName: true, compact: true)
                                    .layoutPriority(1)

                                if let stat = speedStat, stat.averageOutputTokPerSec >= 0.05 {
                                    SpeedPillBadge(rate: stat.averageOutputTokPerSec, isLive: isModelLive, compact: true)
                                        .layoutPriority(1)
                                        .help("实测均速 \(TokenFormatters.tokensPerSec(stat.averageOutputTokPerSec)) · 最新 \(TokenFormatters.tokensPerSec(stat.latestOutputTokPerSec)) · 峰值 \(TokenFormatters.tokensPerSec(stat.peakOutputTokPerSec))（\(stat.sampleCount) 轮样本）")
                                }

                                Spacer(minLength: 4)

                                Text(TokenFormatters.percent(item.shareOfTokens))
                                    .font(.system(size: 9.5, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)

                                Text("命中 \(TokenFormatters.percent(item.totals.cacheHitRate))")
                                    .font(.system(size: 9.5, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(TokenAnalyticsStyle.cacheReadColor.opacity(0.95))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .padding(.leading, 20)

                            modelFourPartStrip(totals: item.totals)
                                .padding(.leading, 20)
                        }
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, compactDensity ? 4.5 : 6)
                        .orbitHoverHighlight(cornerRadius: 7)
                    } else {
                        HStack(alignment: .center, spacing: isWide ? 8 : 6) {
                            Text("\(idx + 1)")
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(idx < 3 ? .accentColor : .secondary)
                                .frame(width: isWide ? 22 : 18, alignment: .center)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    Text(item.modelId)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help("\(item.modelId) · provider: \(item.providerId)")

                                    ClientPillBadge(client: item.client, useShortName: true, compact: !isWide)
                                        .layoutPriority(1)

                                    if isWide, let stat = speedStat, stat.averageOutputTokPerSec >= 0.05 {
                                        SpeedPillBadge(rate: stat.averageOutputTokPerSec, isLive: isModelLive)
                                            .layoutPriority(1)
                                            .help("实测均速 \(TokenFormatters.tokensPerSec(stat.averageOutputTokPerSec)) · 最新 \(TokenFormatters.tokensPerSec(stat.latestOutputTokPerSec)) · 峰值 \(TokenFormatters.tokensPerSec(stat.peakOutputTokPerSec))（\(stat.sampleCount) 轮样本）")
                                    }
                                }

                                if !isWide, let stat = speedStat, stat.averageOutputTokPerSec >= 0.05 {
                                    HStack(spacing: 5) {
                                        SpeedPillBadge(rate: stat.averageOutputTokPerSec, isLive: isModelLive, compact: true)
                                            .layoutPriority(1)
                                            .help("实测均速 \(TokenFormatters.tokensPerSec(stat.averageOutputTokPerSec)) · 最新 \(TokenFormatters.tokensPerSec(stat.latestOutputTokPerSec)) · 峰值 \(TokenFormatters.tokensPerSec(stat.peakOutputTokPerSec))（\(stat.sampleCount) 轮样本）")
                                        modelFourPartStrip(totals: item.totals)
                                    }
                                } else {
                                    modelFourPartStrip(totals: item.totals)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            VStack(alignment: .trailing, spacing: 1.5) {
                                Text(TokenFormatters.compactTokens(item.totals.totalTokens))
                                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .orbitNumericTransition()
                                Text(TokenFormatters.percent(item.shareOfTokens))
                                    .font(.system(size: 9.5, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .orbitNumericTransition()
                            }
                            .frame(width: tokColW, alignment: .trailing)
                            .help("精确：\(TokenFormatters.exactTokens(item.totals.totalTokens))")

                            VStack(alignment: .trailing, spacing: 1.5) {
                                Text(TokenFormatters.usd(item.totals.estimatedCostUSD))
                                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.86)
                                    .orbitNumericTransition()
                                Text("命中 \(TokenFormatters.percent(item.totals.cacheHitRate))")
                                    .font(.system(size: 9.5, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(TokenAnalyticsStyle.cacheReadColor.opacity(0.9))
                                    .lineLimit(1)
                                    .orbitNumericTransition()
                            }
                            .frame(width: costColW, alignment: .trailing)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, compactDensity ? 5 : 6.5)
                        .orbitHoverHighlight(cornerRadius: 7)
                    }

                    if idx < displayedRows.count - 1 {
                        Divider().opacity(0.28)
                    }
                }

                if allRows.count > 12 {
                    expandCollapseTableButton(
                        isExpanded: showAllModels,
                        totalCount: allRows.count
                    ) {
                        withAnimation(snappyAnim) {
                            showAllModels.toggle()
                        }
                    }
                }
            }
        }
    }

    private func modelFourPartStrip(totals: TokenComponentTotals) -> some View {
        HStack(spacing: 3.5) {
            Text("入 \(TokenFormatters.compactTokens(totals.uncachedInputTokens))")
                .foregroundColor(TokenAnalyticsStyle.uncachedInputColor)
            Text("/")
                .foregroundColor(.secondary.opacity(0.55))
            Text("出 \(TokenFormatters.compactTokens(totals.outputTokens))")
                .foregroundColor(TokenAnalyticsStyle.outputColor)
            Text("/")
                .foregroundColor(.secondary.opacity(0.55))
            Text("读 \(TokenFormatters.compactTokens(totals.cacheReadTokens))")
                .foregroundColor(TokenAnalyticsStyle.cacheReadColor)
            Text("/")
                .foregroundColor(.secondary.opacity(0.55))
            Text("写 \(TokenFormatters.compactTokens(totals.cacheWriteTokens))")
                .foregroundColor(TokenAnalyticsStyle.cacheWriteColor)
            Text("·")
                .foregroundColor(.secondary.opacity(0.55))
            Text("\(TokenAnalyticsStyle.compactCount(totals.messageCount))条")
                .foregroundColor(.secondary)
        }
        .font(.system(size: 9, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.76)
    }

    // MARK: Breakdown Tab 3 — Projects Table

    private func projectsDeepTable(
        allRows: [TokenProjectBreakdown],
        availableWidth: CGFloat,
        compactDensity: Bool
    ) -> some View {
        let isStackedNarrow = availableWidth < 455
        let showLastActiveCol = availableWidth >= 560
        let tokColW: CGFloat = showLastActiveCol ? 68 : 60
        let costColW: CGFloat = showLastActiveCol ? 78 : 68
        let displayedRows = showAllProjects ? allRows : Array(allRows.prefix(12))

        return VStack(spacing: 0) {
            if !isStackedNarrow {
                HStack(spacing: showLastActiveCol ? 8 : 6) {
                    Text("#")
                        .frame(width: showLastActiveCol ? 22 : 18, alignment: .center)
                    Text("项目 · 来源客户端")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("总 Tokens")
                        .frame(width: tokColW, alignment: .trailing)
                    Text("估算费用")
                        .frame(width: costColW, alignment: .trailing)
                    if showLastActiveCol {
                        Text("最近活跃")
                            .frame(width: 68, alignment: .trailing)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(nestedSubtleSurface)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            if displayedRows.isEmpty {
                emptyTableNotice("当前筛选条件下暂无项目排行数据")
            } else {
                ForEach(Array(displayedRows.enumerated()), id: \.element.id) { idx, item in
                    if isStackedNarrow {
                        VStack(alignment: .leading, spacing: compactDensity ? 3 : 4) {
                            HStack(alignment: .center, spacing: 5) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(idx < 3 ? .accentColor : .secondary)
                                    .frame(width: 15, alignment: .center)

                                Text(item.projectName)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Spacer(minLength: 4)

                                Text(TokenFormatters.compactTokens(item.totals.totalTokens))
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .orbitNumericTransition()
                                    .help("精确：\(TokenFormatters.exactTokens(item.totals.totalTokens))")

                                Text(TokenFormatters.usd(item.totals.estimatedCostUSD))
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.primary.opacity(0.88))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .orbitNumericTransition()
                            }

                            HStack(alignment: .center, spacing: 5) {
                                HStack(spacing: 3) {
                                    ForEach(Array(item.clients.prefix(2))) { client in
                                        ClientPillBadge(client: client, useShortName: true, compact: true)
                                    }
                                    if item.clients.count > 2 {
                                        Text("+\(item.clients.count - 2)")
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .layoutPriority(1)

                                Text(item.pathDisplay)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(item.pathDisplay)

                                Spacer(minLength: 4)

                                if !item.lastActiveDate.isEmpty {
                                    Text(TokenAnalyticsStyle.shortMonthDay(item.lastActiveDate))
                                        .font(.system(size: 9.5, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                            .padding(.leading, 20)
                        }
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, compactDensity ? 4.5 : 6)
                        .orbitHoverHighlight(cornerRadius: 7)
                    } else {
                        HStack(alignment: .center, spacing: showLastActiveCol ? 8 : 6) {
                            Text("\(idx + 1)")
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(idx < 3 ? .accentColor : .secondary)
                                .frame(width: showLastActiveCol ? 22 : 18, alignment: .center)

                            VStack(alignment: .leading, spacing: 2.5) {
                                HStack(spacing: 5) {
                                    Text(item.projectName)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)

                                    HStack(spacing: 3) {
                                        let maxShown = showLastActiveCol ? 3 : 2
                                        ForEach(Array(item.clients.prefix(maxShown))) { client in
                                            ClientPillBadge(client: client, useShortName: true, compact: !showLastActiveCol)
                                        }
                                        if item.clients.count > maxShown {
                                            Text("+\(item.clients.count - maxShown)")
                                                .font(.system(size: 9, weight: .medium))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .layoutPriority(1)
                                }

                                HStack(spacing: 5) {
                                    Text(item.pathDisplay)
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(item.pathDisplay)

                                    if !showLastActiveCol && !item.lastActiveDate.isEmpty {
                                        Text("· \(TokenAnalyticsStyle.shortMonthDay(item.lastActiveDate))")
                                            .font(.system(size: 9.5, design: .rounded))
                                            .monospacedDigit()
                                            .foregroundColor(.secondary.opacity(0.85))
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            VStack(alignment: .trailing, spacing: 1.5) {
                                Text(TokenFormatters.compactTokens(item.totals.totalTokens))
                                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .orbitNumericTransition()
                                Text(TokenFormatters.percent(item.shareOfTokens))
                                    .font(.system(size: 9.5, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .orbitNumericTransition()
                            }
                            .frame(width: tokColW, alignment: .trailing)
                            .help("精确：\(TokenFormatters.exactTokens(item.totals.totalTokens))")

                            Text(TokenFormatters.usd(item.totals.estimatedCostUSD))
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.86)
                                .frame(width: costColW, alignment: .trailing)
                                .orbitNumericTransition()

                            if showLastActiveCol {
                                Text(item.lastActiveDate.isEmpty ? "-" : item.lastActiveDate)
                                    .font(.system(size: 10, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .frame(width: 68, alignment: .trailing)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, compactDensity ? 5 : 6.5)
                        .orbitHoverHighlight(cornerRadius: 7)
                    }

                    if idx < displayedRows.count - 1 {
                        Divider().opacity(0.28)
                    }
                }

                if allRows.count > 12 {
                    expandCollapseTableButton(
                        isExpanded: showAllProjects,
                        totalCount: allRows.count
                    ) {
                        withAnimation(snappyAnim) {
                            showAllProjects.toggle()
                        }
                    }
                }
            }
        }
    }

    private func expandCollapseTableButton(
        isExpanded: Bool,
        totalCount: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(isExpanded ? "收起列表" : "展开全部 \(totalCount) 项")
                    .font(.system(size: 10.5, weight: .semibold))
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .orbitInteractiveButton(pressedScale: 0.985, hoverTint: Color.accentColor.opacity(0.10), cornerRadius: 7)
        .padding(.top, 6)
    }

    private func emptyTableNotice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .padding(.horizontal, 12)
    }

    // MARK: - Slim Privacy & Metadata Footer (No Legacy Dashboard Button)

    private func unifiedFooterBar(availableWidth: CGFloat, contentPad: CGFloat) -> some View {
        let privacyText: String = {
            if availableWidth < 395 { return "纯本地 · 零联网" }
            if availableWidth < 500 { return "本地只读 · 零 Claude 联网" }
            return "100% 本地只读日志 · 零 Claude 联网"
        }()

        return HStack(spacing: 6) {
            LocalPrivacyBadge(text: privacyText, compact: true)
                .help("100% 纯本地只读解析本机客户端落盘日志，绝不联网请求 Claude 或拉起子进程")

            Spacer(minLength: 4)

            if let snap = store.tokenUsage {
                let meta: String = {
                    let updatedAgo = store.relativeTimeAgoString(since: snap.lastScannedAt)
                    if availableWidth < 385 {
                        return "\(snap.totalDaysCount)天 · \(updatedAgo)"
                    }
                    if availableWidth < 500 {
                        return "共 \(snap.totalDaysCount) 天 · \(snap.liveScannedFilesCount) 文件 · \(updatedAgo)"
                    }
                    return "历史基线 \(snap.seedDaysCount) 天 · 共 \(snap.totalDaysCount) 天 · 已扫 \(snap.liveScannedFilesCount) 文件 · \(updatedAgo)更新"
                }()
                Text(meta)
                    .font(.system(size: 9.5, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, contentPad)
        .padding(.vertical, 6.5)
    }

    // MARK: - Local JSON Export Action & Toast

    private func exportCurrentReportAsJSON() {
        guard let snapshot = store.tokenUsage else { return }
        let selection = store.tokenUsageDateSelection
        let summary = snapshot.summary(for: selection, clientFilter: selectedClient)
        let speed = effectiveSpeed

        let report = ExportedTokenUsageReport(
            exportedAt: Date(),
            appName: "Pulsar",
            appVersion: AppStore.appVersion,
            selectionLabel: selection.displayName,
            startDate: summary.startDate,
            endDate: summary.endDate,
            isCustomRange: summary.isCustomRange,
            clientFilter: selectedClient?.rawValue,
            summary: summary,
            liveSpeed: speed
        )

        let slugRange: String = {
            if !summary.startDate.isEmpty {
                return summary.startDate == summary.endDate
                    ? summary.startDate
                    : "\(summary.startDate)_to_\(summary.endDate)"
            }
            return TokenFormatters.ymdString(from: Date())
        }()
        let clientSuffix = selectedClient.map { "-\($0.rawValue)" } ?? ""
        let suggestedName = "pulsar-token-usage-\(slugRange)\(clientSuffix).json"

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let payloadData = try? encoder.encode(report) else {
            showExportToast("JSON 序列化失败", isError: true)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "导出 Token 用量统计 (JSON)"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let targetURL = panel.url else { return }
            do {
                try payloadData.write(to: targetURL, options: .atomic)
                Task { @MainActor in
                    showExportToast("已导出 \(targetURL.lastPathComponent)", isError: false)
                }
            } catch {
                Task { @MainActor in
                    showExportToast("导出失败：\(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    private func showExportToast(_ message: String, isError: Bool) {
        exportToastTask?.cancel()
        exportToastIsError = isError
        exportToastMessage = message
        exportToastTask = Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                exportToastMessage = nil
            }
        }
    }

    private func exportToastBanner(message: String, isError: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isError ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen))
            Text(message)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(glassPrimaryInk)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(glassControlTintFill))
        .overlay(Capsule().strokeBorder(glassControlSpecularBorder, lineWidth: 0.65))
        .orbitGlassCapsule(interactive: false)
        .shadow(color: Color.black.opacity(0.16), radius: 6, y: 2)
    }

    // MARK: - Liquid Glass Adaptive Card Container (Omits Opaque fillColor per HIG)

    private func glassContentCard<Content: View>(
        padding: CGFloat = 11.5,
        fillHeight: Bool = false,
        isHighlighted: Bool = false,
        highlightColor: Color = .accentColor,
        hoverLift: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .orbitCardStyle(
                cornerRadius: 11,
                isHighlighted: isHighlighted,
                highlightColor: highlightColor,
                hoverLift: hoverLift
            )
    }
}

// MARK: - Backward-Compatible Dashboard Wrapper (Forwards Directly to Unified Panel)

public struct TokenUsageDashboardView: View {
    @ObservedObject public var store: AppStore

    public init(store: AppStore) {
        self.store = store
    }

    public var body: some View {
        TokenUsagePopoverView(store: store)
    }
}
