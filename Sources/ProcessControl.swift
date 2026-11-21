import AppKit
import Darwin
import Foundation

// MARK: - Process Control Models & Inspector Protocol

public struct RunningGUIApp: Equatable, Hashable, Sendable {
    public let pid: Int
    public let bundleId: String
    public let localizedName: String
    public let bundleURL: URL?
    public let executablePath: String

    public init(
        pid: Int,
        bundleId: String,
        localizedName: String,
        bundleURL: URL?,
        executablePath: String
    ) {
        self.pid = pid
        self.bundleId = bundleId
        self.localizedName = localizedName
        self.bundleURL = bundleURL
        self.executablePath = executablePath
    }
}

public enum GracefulStopResult: Equatable, Sendable {
    case stopped(reopenBundleURLs: [URL])
    case stillRunning([ClientProcessInfo])
}

/// Injectable OS process inspector so unit tests never touch real running applications.
public protocol ProcessInspectorProtocol: Sendable {
    func runningApplications(bundleIDs: [String]) -> [RunningGUIApp]
    func allRunningProcesses() -> [ClientProcessInfo]
    func processArguments(pid: Int) -> [String]
    func installedAppURLs(bundleIDs: [String], extraPaths: [String]) -> [URL]
    func requestGracefulTerminate(pid: Int, bundleId: String?) -> Bool
    func sendSignal(_ signal: Int32, to pid: Int) -> Bool
    func isProcessAlive(pid: Int) -> Bool
    func openApplication(at url: URL) async throws
    func sleep(nanoseconds: UInt64) async
}

public extension ProcessInspectorProtocol {
    func processArguments(pid: Int) -> [String] {
        []
    }
}

// MARK: - Live macOS Process Inspector

public final class LiveProcessInspector: ProcessInspectorProtocol, @unchecked Sendable {
    public init() {}

    public func runningApplications(bundleIDs: [String]) -> [RunningGUIApp] {
        var result: [RunningGUIApp] = []
        var seenPids = Set<Int>()

        for bundleId in bundleIDs {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            for app in apps where !app.isTerminated {
                let pid = Int(app.processIdentifier)
                guard pid > 1, !seenPids.contains(pid) else { continue }
                seenPids.insert(pid)
                result.append(
                    RunningGUIApp(
                        pid: pid,
                        bundleId: app.bundleIdentifier ?? bundleId,
                        localizedName: app.localizedName ?? bundleId,
                        bundleURL: app.bundleURL,
                        executablePath: app.executableURL?.path ?? Self.executablePath(for: pid_t(pid))
                    )
                )
            }
        }
        return result
    }

    public func allRunningProcesses() -> [ClientProcessInfo] {
        // Snapshot GUI bundle info by PID once for enrichment.
        var guiByPid: [Int: (name: String, bundleId: String?, execPath: String?)] = [:]
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            let pid = Int(app.processIdentifier)
            guiByPid[pid] = (
                name: app.localizedName ?? "",
                bundleId: app.bundleIdentifier,
                execPath: app.executableURL?.path
            )
        }

        let estimatedCount = proc_listallpids(nil, 0)
        let capacity = max(Int(estimatedCount) + 128, 1024)
        var pids = [pid_t](repeating: 0, count: capacity)
        let bufferSize = Int32(capacity * MemoryLayout<pid_t>.stride)
        let actualCount = proc_listallpids(&pids, bufferSize)
        guard actualCount > 0 else { return [] }

        var processes: [ClientProcessInfo] = []
        processes.reserveCapacity(Int(actualCount))

        for i in 0..<Int(actualCount) {
            let pid = pids[i]
            guard pid > 1 else { continue }
            let intPid = Int(pid)
            let gui = guiByPid[intPid]

            var execPath = Self.executablePath(for: pid)
            if execPath.isEmpty, let fallback = gui?.execPath, !fallback.isEmpty {
                execPath = fallback
            }
            if execPath.isEmpty {
                execPath = Self.execPathFromProcArgs(for: pid)
            }
            if execPath.isEmpty {
                execPath = Self.processShortName(for: pid)
            }
            guard !execPath.isEmpty else { continue }

            let basename = URL(fileURLWithPath: execPath).lastPathComponent
            let name = (gui?.name.isEmpty == false) ? gui!.name : basename
            let isGUI = gui?.bundleId != nil
            let interactiveCLI = !isGUI && Self.hasControllingTTY(pid: pid)

            processes.append(
                ClientProcessInfo(
                    id: intPid,
                    name: name,
                    executablePath: execPath,
                    bundleId: gui?.bundleId,
                    isInteractiveCLI: interactiveCLI
                )
            )
        }

        return processes
    }

    /// Parses a raw Darwin `KERN_PROCARGS2` buffer into `(execPath, arguments)` safely without
    /// assuming buffer alignment, preserving unlinked executable paths (e.g. `agy.<ts>.old`) and `argv`.
    public static func parseProcArgs2Buffer(_ data: Data) -> (execPath: String, arguments: [String]) {
        let headerSize = MemoryLayout<Int32>.size
        guard data.count > headerSize else { return ("", []) }

        var argc: Int32 = 0
        _ = withUnsafeMutableBytes(of: &argc) { dst in
            data.copyBytes(to: dst, from: data.startIndex..<(data.startIndex + headerSize))
        }
        guard argc >= 0, argc < 4096 else { return ("", []) }

        let bytes = [UInt8](data)
        let size = bytes.count
        var idx = headerSize

        // Read exec_path (NUL-terminated string immediately following argc).
        let execStart = idx
        while idx < size && bytes[idx] != 0 {
            idx += 1
        }
        let execPath = String(bytes: bytes[execStart..<idx], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Skip NUL padding between exec_path and argv[0].
        while idx < size && bytes[idx] == 0 {
            idx += 1
        }

        var args: [String] = []
        if argc > 0 {
            args.reserveCapacity(Int(argc))
            while idx < size && args.count < Int(argc) {
                let start = idx
                while idx < size && bytes[idx] != 0 {
                    idx += 1
                }
                if let str = String(bytes: bytes[start..<idx], encoding: .utf8) {
                    args.append(str)
                }
                idx += 1
            }
        }

        return (execPath, args)
    }

    public func processArguments(pid: Int) -> [String] {
        guard pid > 1 else { return [] }
        return Self.readProcArgs2(for: pid_t(pid)).arguments
    }

    public func installedAppURLs(bundleIDs: [String], extraPaths: [String]) -> [URL] {
        var urls: [URL] = []
        var seenPaths = Set<String>()
        let fm = FileManager.default

        for path in extraPaths {
            if fm.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path).standardizedFileURL
                if seenPaths.insert(url.path).inserted {
                    urls.append(url)
                }
            }
        }

        for bundleId in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)?.standardizedFileURL,
               fm.fileExists(atPath: url.path) {
                if seenPaths.insert(url.path).inserted {
                    urls.append(url)
                }
            }
        }

        return urls
    }

    public func requestGracefulTerminate(pid: Int, bundleId: String?) -> Bool {
        let selfPid = Int(ProcessInfo.processInfo.processIdentifier)
        guard pid > 1, pid != selfPid else { return false }

        if let app = NSRunningApplication(processIdentifier: pid_t(pid)), !app.isTerminated {
            return app.terminate()
        }
        if let bundleId {
            let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            var requested = false
            for app in matches where !app.isTerminated && Int(app.processIdentifier) != selfPid {
                if app.terminate() {
                    requested = true
                }
            }
            return requested
        }
        return false
    }

    public func sendSignal(_ signal: Int32, to pid: Int) -> Bool {
        let selfPid = Int(ProcessInfo.processInfo.processIdentifier)
        guard pid > 1, pid != selfPid else { return false }
        if Darwin.kill(pid_t(pid), signal) == 0 {
            return true
        }
        return errno == ESRCH
    }

    public func isProcessAlive(pid: Int) -> Bool {
        guard pid > 1 else { return false }
        if Darwin.kill(pid_t(pid), 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    public func openApplication(at url: URL) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.createsNewApplicationInstance = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    public func sleep(nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    // MARK: - Darwin Syscall Helpers

    private static func executablePath(for pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard len > 0 else { return "" }
        return String(cString: buf)
    }

    private static func readProcArgs2(for pid: pid_t) -> (execPath: String, arguments: [String]) {
        guard pid > 1 else { return ("", []) }

        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.stride
        var argmaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        if sysctl(&argmaxMib, 2, &argmax, &argmaxSize, nil, 0) != 0 || argmax <= 0 {
            argmax = 262_144
        }

        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let rc = sysctl(&mib, 3, &buffer, &size, nil, 0)
        guard rc == 0, size > MemoryLayout<Int32>.size else { return ("", []) }

        return parseProcArgs2Buffer(Data(buffer[0..<size]))
    }

    private static func execPathFromProcArgs(for pid: pid_t) -> String {
        let parsed = readProcArgs2(for: pid)
        if !parsed.execPath.isEmpty {
            return parsed.execPath
        }
        return parsed.arguments.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func processShortName(for pid: pid_t) -> String {
        guard pid > 1 else { return "" }
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize)
        guard ret == infoSize else { return "" }

        let name = cStringFromTuple(info.pbi_name)
        if !name.isEmpty {
            return name
        }
        return cStringFromTuple(info.pbi_comm)
    }

    private static func cStringFromTuple<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            guard !bytes.isEmpty else { return "" }
            return String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func hasControllingTTY(pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = sysctl(&mib, 4, &info, &size, nil, 0)
        guard rc == 0, size > 0 else { return false }
        // NODEV is -1 (dev_t); a valid tty has e_tdev != -1.
        return info.kp_eproc.e_tdev != -1
    }
}

// MARK: - Safe Process Controller (Graceful Quit First; Zero Auto-SIGKILL)

public final class ProcessController: @unchecked Sendable {
    public static let shared = ProcessController()

    public let inspector: ProcessInspectorProtocol
    private let selfPid: Int

    public init(
        inspector: ProcessInspectorProtocol = LiveProcessInspector(),
        selfPid: Int = Int(ProcessInfo.processInfo.processIdentifier)
    ) {
        self.inspector = inspector
        self.selfPid = selfPid
    }

    /// Detects installed apps and currently running processes for a client family.
    public func detectClientStatus(
        bundleIDs: [String],
        extraAppPaths: [String] = [],
        detachedExecutableMatchers: [(String) -> Bool] = []
    ) -> ClientRuntimeStatus {
        let installedURLs = inspector.installedAppURLs(bundleIDs: bundleIDs, extraPaths: extraAppPaths)
        let installedNames = installedURLs.map { $0.deletingPathExtension().lastPathComponent }

        let runningGUI = inspector.runningApplications(bundleIDs: bundleIDs)
        let bundlePrefixes = Self.bundlePathPrefixes(from: runningGUI, installedURLs: installedURLs)
        let running = matchingProcesses(
            bundleIDs: Set(bundleIDs),
            guiApps: runningGUI,
            bundlePrefixes: bundlePrefixes,
            detachedExecutableMatchers: detachedExecutableMatchers
        )

        return ClientRuntimeStatus(
            installedApps: installedNames,
            runningProcesses: running,
            isRunning: !running.isEmpty
        )
    }

    /// Gracefully stops GUI apps via `NSRunningApplication.terminate()` and detached helpers via `SIGTERM`.
    /// NEVER sends `SIGKILL` unless `allowForceQuit == true` (which must only be passed after explicit user confirmation).
    public func gracefulStop(
        bundleIDs: [String],
        detachedExecutableMatchers: [(String) -> Bool],
        timeoutSeconds: TimeInterval = 12.0,
        allowForceQuit: Bool = false
    ) async -> GracefulStopResult {
        let bundleIDSet = Set(bundleIDs)
        let initialGUI = inspector.runningApplications(bundleIDs: bundleIDs)

        // Capture ONLY apps that were actually running so callers can decide which bundle(s) to reopen.
        var reopenURLs: [URL] = []
        var seenReopen = Set<String>()
        for app in initialGUI where app.pid > 1 && app.pid != selfPid {
            if let url = app.bundleURL?.standardizedFileURL,
               seenReopen.insert(url.path).inserted {
                reopenURLs.append(url)
            }
        }

        let installedURLs = inspector.installedAppURLs(bundleIDs: bundleIDs, extraPaths: [])
        let bundlePrefixes = Self.bundlePathPrefixes(from: initialGUI, installedURLs: installedURLs)

        let initialTargets = matchingProcesses(
            bundleIDs: bundleIDSet,
            guiApps: initialGUI,
            bundlePrefixes: bundlePrefixes,
            detachedExecutableMatchers: detachedExecutableMatchers
        )
        if initialTargets.isEmpty {
            return .stopped(reopenBundleURLs: reopenURLs)
        }

        // Phase 1: Request native graceful quit for running GUI apps.
        var requestedGUIPids = Set<Int>()
        for app in initialGUI where app.pid > 1 && app.pid != selfPid {
            requestedGUIPids.insert(app.pid)
            _ = inspector.requestGracefulTerminate(pid: app.pid, bundleId: app.bundleId)
        }

        if !requestedGUIPids.isEmpty {
            await inspector.sleep(nanoseconds: 250_000_000)
        }

        // Phase 2: Send SIGTERM (never SIGKILL) to detached helpers / CLI daemons.
        let afterGUITick = matchingProcesses(
            bundleIDs: bundleIDSet,
            guiApps: inspector.runningApplications(bundleIDs: bundleIDs),
            bundlePrefixes: bundlePrefixes,
            detachedExecutableMatchers: detachedExecutableMatchers
        )
        if afterGUITick.isEmpty {
            return .stopped(reopenBundleURLs: reopenURLs)
        }

        for proc in afterGUITick {
            guard proc.id > 1, proc.id != selfPid else { continue }
            if let bid = proc.bundleId, bundleIDSet.contains(bid) {
                continue
            }
            if requestedGUIPids.contains(proc.id) {
                continue
            }
            _ = inspector.sendSignal(SIGTERM, to: proc.id)
        }

        // Phase 3: Poll until 0 processes remain or timeoutSeconds elapses.
        let pollIntervalSec: TimeInterval = 0.25
        let pollIntervalNs: UInt64 = 250_000_000
        let maxPolls = max(1, Int(ceil(max(timeoutSeconds, 0.25) / pollIntervalSec)))
        let deadline = Date().addingTimeInterval(max(timeoutSeconds, 0.0))

        var surviving = afterGUITick
        for _ in 0..<maxPolls {
            await inspector.sleep(nanoseconds: pollIntervalNs)
            surviving = matchingProcesses(
                bundleIDs: bundleIDSet,
                guiApps: inspector.runningApplications(bundleIDs: bundleIDs),
                bundlePrefixes: bundlePrefixes,
                detachedExecutableMatchers: detachedExecutableMatchers
            )
            if surviving.isEmpty {
                return .stopped(reopenBundleURLs: reopenURLs)
            }
            if Date() >= deadline {
                break
            }
        }

        // Hard safety invariant: NEVER send SIGKILL unless caller explicitly set allowForceQuit == true.
        guard allowForceQuit else {
            return .stillRunning(surviving)
        }

        // Phase 4 (explicitly confirmed force-quit only): SIGKILL surviving processes and verify exit.
        for proc in surviving where proc.id != selfPid && proc.id > 1 {
            _ = inspector.sendSignal(SIGKILL, to: proc.id)
        }

        let forcePollIntervalNs: UInt64 = 200_000_000
        for _ in 0..<15 {
            await inspector.sleep(nanoseconds: forcePollIntervalNs)
            surviving = matchingProcesses(
                bundleIDs: bundleIDSet,
                guiApps: inspector.runningApplications(bundleIDs: bundleIDs),
                bundlePrefixes: bundlePrefixes,
                detachedExecutableMatchers: detachedExecutableMatchers
            )
            if surviving.isEmpty {
                return .stopped(reopenBundleURLs: reopenURLs)
            }
        }

        return .stillRunning(surviving)
    }

    public func reopenApps(urls: [URL]) async {
        var seen = Set<String>()
        for url in urls {
            let std = url.standardizedFileURL
            guard std.isFileURL, !std.path.isEmpty else { continue }
            guard seen.insert(std.path).inserted else { continue }
            try? await inspector.openApplication(at: std)
        }
    }

    // MARK: - Static Convenience Wrappers

    public static func gracefulStop(
        bundleIDs: [String],
        detachedExecutableMatchers: [(String) -> Bool],
        timeoutSeconds: TimeInterval = 12.0,
        allowForceQuit: Bool = false
    ) async -> GracefulStopResult {
        await shared.gracefulStop(
            bundleIDs: bundleIDs,
            detachedExecutableMatchers: detachedExecutableMatchers,
            timeoutSeconds: timeoutSeconds,
            allowForceQuit: allowForceQuit
        )
    }

    public static func reopenApps(urls: [URL]) async {
        await shared.reopenApps(urls: urls)
    }

    // MARK: - Process Matching Helpers

    private static func bundlePathPrefixes(
        from runningGUI: [RunningGUIApp],
        installedURLs: [URL]
    ) -> [String] {
        var prefixes = Set<String>()
        for app in runningGUI {
            if let path = app.bundleURL?.standardizedFileURL.path, !path.isEmpty, path != "/" {
                prefixes.insert(path.hasSuffix("/") ? path : path + "/")
            }
        }
        for url in installedURLs {
            let path = url.standardizedFileURL.path
            if !path.isEmpty, path != "/" {
                prefixes.insert(path.hasSuffix("/") ? path : path + "/")
            }
        }
        return Array(prefixes)
    }

    private func matchingProcesses(
        bundleIDs: Set<String>,
        guiApps: [RunningGUIApp],
        bundlePrefixes: [String],
        detachedExecutableMatchers: [(String) -> Bool]
    ) -> [ClientProcessInfo] {
        var byPid: [Int: ClientProcessInfo] = [:]

        for app in guiApps where app.pid > 1 && app.pid != selfPid {
            byPid[app.pid] = ClientProcessInfo(
                id: app.pid,
                name: app.localizedName,
                executablePath: app.executablePath,
                bundleId: app.bundleId,
                isInteractiveCLI: false
            )
        }

        for proc in inspector.allRunningProcesses() {
            guard proc.id > 1, proc.id != selfPid else { continue }
            var matched = false

            if let bid = proc.bundleId, bundleIDs.contains(bid) {
                matched = true
            }
            if !matched {
                for prefix in bundlePrefixes where proc.executablePath.hasPrefix(prefix) {
                    matched = true
                    break
                }
            }
            if !matched {
                for matcher in detachedExecutableMatchers where matcher(proc.executablePath) {
                    matched = true
                    break
                }
            }

            if matched {
                // Keep richer GUI metadata if already recorded for the same PID.
                if byPid[proc.id] == nil {
                    byPid[proc.id] = proc
                }
            }
        }

        return byPid.values.sorted { $0.id < $1.id }
    }
}
