import AppKit
import CFNetwork
import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import SQLite3
import SwiftUI

// MARK: - Minimal Standalone Test Runner

private final class TestRunner {
    private(set) var passed = 0
    private(set) var failed = 0
    private var currentSuite = ""

    func suite(_ name: String, _ body: () throws -> Void) {
        currentSuite = name
        do {
            try body()
            print("  [PASS] \(name)")
        } catch {
            failed += 1
            fputs("  [FAIL] \(name): threw unexpected error: \(error)\n", stderr)
        }
    }

    func asyncSuite(_ name: String, _ body: () async throws -> Void) async {
        currentSuite = name
        do {
            try await body()
            print("  [PASS] \(name)")
        } catch {
            failed += 1
            fputs("  [FAIL] \(name): threw unexpected error: \(error)\n", stderr)
        }
    }

    func expect(_ condition: @autoclosure () -> Bool, _ message: String = "", file: String = #file, line: Int = #line) {
        if condition() {
            passed += 1
        } else {
            failed += 1
            let detail = message.isEmpty ? "assertion failed" : message
            fputs("  [FAIL] \(currentSuite) (\(URL(fileURLWithPath: file).lastPathComponent):\(line)): \(detail)\n", stderr)
        }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: String = #file, line: Int = #line) {
        if actual == expected {
            passed += 1
        } else {
            failed += 1
            let suffix = message.isEmpty ? "" : " — \(message)"
            fputs("  [FAIL] \(currentSuite) (\(URL(fileURLWithPath: file).lastPathComponent):\(line)): expected \(expected), got \(actual)\(suffix)\n", stderr)
        }
    }
}

private let T = TestRunner()

// MARK: - Shared Test Helpers

private func makeTempDir(prefix: String = "roryorbit-test") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeUnsignedJWT(payload: [String: Any]) -> String {
    let headerData = try! JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"], options: [.sortedKeys])
    let payloadData = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return "\(Formatters.base64URLEncode(headerData)).\(Formatters.base64URLEncode(payloadData)).sig"
}

private func makeCodexAuthJSONData(
    userId: String,
    accountId: String,
    email: String,
    name: String = "Test User",
    planType: String = "prolite",
    accessExpOffset: TimeInterval = 3600,
    refreshToken: String = "rt_test_initial"
) -> Data {
    let now = Date().timeIntervalSince1970
    let idToken = makeUnsignedJWT(payload: [
        "sub": userId,
        "email": email,
        "name": name,
        "https://api.openai.com/auth": [
            "chatgpt_user_id": userId,
            "chatgpt_account_id": accountId,
            "chatgpt_plan_type": planType,
        ],
    ])
    let accessToken = makeUnsignedJWT(payload: [
        "sub": userId,
        "exp": Int(now + accessExpOffset),
    ])
    let root: [String: Any] = [
        "auth_mode": "chatgpt",
        "OPENAI_API_KEY": NSNull(),
        "tokens": [
            "id_token": idToken,
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "account_id": accountId,
        ],
        "last_refresh": Formatters.formatRFC3339UTC(Date()),
    ]
    return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

// MARK: - Mock URLProtocol for Deterministic Offline HTTP Tests

private func readRequestBody(_ req: URLRequest) -> Data {
    if let body = req.httpBody {
        return body
    }
    guard let stream = req.httpBodyStream else {
        return Data()
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

private final class StubURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest, Data) throws -> (HTTPURLResponse, Data))?
    static var recordedRequests: [(request: URLRequest, body: Data)] = []

    static func reset(handler: @escaping (URLRequest, Data) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        self.handler = handler
        self.recordedRequests = []
        lock.unlock()
    }

    static func snapshotRequests() -> [(request: URLRequest, body: Data)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = readRequestBody(request)
        Self.lock.lock()
        Self.recordedRequests.append((request, body))
        let h = Self.handler
        Self.lock.unlock()

        guard let h else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (resp, data) = try h(request, body)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeMockSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: cfg)
}

// MARK: - Mock ProcessInspector for ProcessControl Tests

private final class MockProcessInspector: ProcessInspectorProtocol, @unchecked Sendable {
    private let lock = NSLock()
    var guiApps: [RunningGUIApp] = []
    var processes: [ClientProcessInfo] = []
    var installed: [URL] = []
    var argsByPid: [Int: [String]] = [:]

    var terminateRequests: [(pid: Int, bundleId: String?)] = []
    var signalsSent: [(signal: Int32, pid: Int)] = []
    var reopenedURLs: [URL] = []

    /// If true, GUI apps & helpers exit cleanly on graceful terminate / SIGTERM.
    var exitOnGraceful: Bool = true
    /// If true, surviving processes exit when SIGKILL is delivered.
    var exitOnSigKill: Bool = true

    func runningApplications(bundleIDs: [String]) -> [RunningGUIApp] {
        lock.lock()
        defer { lock.unlock() }
        let set = Set(bundleIDs)
        return guiApps.filter { set.contains($0.bundleId) }
    }

    func allRunningProcesses() -> [ClientProcessInfo] {
        lock.lock()
        defer { lock.unlock() }
        return processes
    }

    func processArguments(pid: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return argsByPid[pid] ?? []
    }

    func installedAppURLs(bundleIDs: [String], extraPaths: [String]) -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return installed
    }

    func requestGracefulTerminate(pid: Int, bundleId: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        terminateRequests.append((pid, bundleId))
        if exitOnGraceful {
            guiApps.removeAll { $0.pid == pid }
            processes.removeAll { $0.id == pid }
        }
        return true
    }

    func sendSignal(_ signal: Int32, to pid: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        signalsSent.append((signal, pid))
        if signal == SIGTERM && exitOnGraceful {
            guiApps.removeAll { $0.pid == pid }
            processes.removeAll { $0.id == pid }
        } else if signal == SIGKILL && exitOnSigKill {
            guiApps.removeAll { $0.pid == pid }
            processes.removeAll { $0.id == pid }
        }
        return true
    }

    func isProcessAlive(pid: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return guiApps.contains { $0.pid == pid } || processes.contains { $0.id == pid }
    }

    func openApplication(at url: URL) async throws {
        lock.withLock {
            reopenedURLs.append(url)
        }
    }

    func sleep(nanoseconds: UInt64) async {
        // Fast no-op sleep for deterministic unit tests.
    }
}

// MARK: - Test 1: Models, TransportPolicy, PlanInfo, Formatters & Atomic RegistryData

private func testModels() {
    T.suite("Models.TransportPolicy & HTTPFactory") {
        let sysCfg = HTTPFactory.makeConfiguration(policy: .systemProxy, timeout: 15)
        T.expect(sysCfg.connectionProxyDictionary == nil, "systemProxy must inherit system proxy (nil dict)")
        T.expectEqual(sysCfg.httpShouldSetCookies, false)

        let fcCfg = HTTPFactory.makeConfiguration(policy: .failClosedLoopbackProxy(host: "127.0.0.1", port: 17890))
        let dict = fcCfg.connectionProxyDictionary as? [String: Any]
        T.expect(dict != nil, "failClosedLoopbackProxy must populate connectionProxyDictionary")
        T.expectEqual(dict?[kCFNetworkProxiesHTTPEnable as String] as? Int, 1)
        T.expectEqual(dict?[kCFNetworkProxiesHTTPProxy as String] as? String, "127.0.0.1")
        T.expectEqual(dict?[kCFNetworkProxiesHTTPPort as String] as? Int, 17890)
        T.expectEqual(dict?[kCFNetworkProxiesHTTPSEnable as String] as? Int, 1)
        T.expectEqual(dict?[kCFNetworkProxiesHTTPSPort as String] as? Int, 17890)
        T.expectEqual(dict?[kCFNetworkProxiesSOCKSEnable as String] as? Int, 1)
        T.expectEqual(dict?[kCFNetworkProxiesSOCKSPort as String] as? Int, 17890)
        T.expectEqual(dict?[kCFNetworkProxiesProxyAutoConfigEnable as String] as? Int, 0)
        T.expectEqual(dict?[kCFNetworkProxiesProxyAutoDiscoveryEnable as String] as? Int, 0)
        T.expectEqual(dict?[kCFNetworkProxiesExcludeSimpleHostnames as String] as? Int, 0)
        T.expectEqual((dict?[kCFNetworkProxiesExceptionsList as String] as? [String])?.isEmpty, true)

        // Non-loopback host or invalid port MUST fail closed to 127.0.0.1:9
        let badHostCfg = HTTPFactory.makeConfiguration(policy: .failClosedLoopbackProxy(host: "8.8.8.8", port: 17890))
        let badDict = badHostCfg.connectionProxyDictionary as? [String: Any]
        T.expectEqual(badDict?[kCFNetworkProxiesHTTPProxy as String] as? String, "127.0.0.1")
        T.expectEqual(badDict?[kCFNetworkProxiesHTTPPort as String] as? Int, 9)

        let badPortCfg = HTTPFactory.makeConfiguration(policy: .failClosedLoopbackProxy(host: "localhost", port: 0))
        let badPortDict = badPortCfg.connectionProxyDictionary as? [String: Any]
        T.expectEqual(badPortDict?[kCFNetworkProxiesHTTPSPort as String] as? Int, 9)
    }

    T.suite("Models.PlanInfo & prolite") {
        let prolite = PlanInfo.normalized(kindRaw: "prolite", name: "prolite")
        T.expectEqual(prolite?.kind, .prolite)
        T.expectEqual(prolite?.displayName, "Pro Lite")

        let proliteDash = PlanInfo.normalized(kindRaw: "pro_lite", name: nil)
        T.expectEqual(proliteDash?.kind, .prolite)
        T.expectEqual(proliteDash?.displayName, "Pro Lite")

        let ultra = PlanInfo.normalized(kindRaw: "g1-ultra-tier", name: "Google AI Ultra")
        T.expectEqual(ultra?.kind, .ultra)
        T.expectEqual(ultra?.displayName, "Google AI Ultra")

        let pro = PlanInfo.normalized(kindRaw: "g1-pro-tier", name: "Google AI Pro")
        T.expectEqual(pro?.kind, .pro)

        T.expect(PlanInfo.normalized(kindRaw: nil, name: "") == nil, "empty plan returns nil")
    }

    T.suite("Models.bestRemainingAccountId & Formatters") {
        let a1 = AccountRecord(id: "a1", provider: .antigravity, email: "a1@test", displayName: "A1")
        let a2 = AccountRecord(id: "a2", provider: .antigravity, email: "a2@test", displayName: "A2")
        let a3 = AccountRecord(id: "a3", provider: .antigravity, email: "a3@test", displayName: "A3")

        let now = Date()
        let snaps: [String: QuotaSnapshot] = [
            "a1": QuotaSnapshot(provider: .antigravity, accountId: "a1", status: .ready(fetchedAt: now, stale: false), primaryRemainingPercent: 35),
            "a2": QuotaSnapshot(provider: .antigravity, accountId: "a2", status: .ready(fetchedAt: now, stale: false), primaryRemainingPercent: 92),
            "a3": QuotaSnapshot(provider: .antigravity, accountId: "a3", status: .failed("err"), primaryRemainingPercent: 100),
        ]
        T.expectEqual(AccountRecord.bestRemainingAccountId(for: .antigravity, accounts: [a1, a2, a3], snapshots: snaps), "a2")
        T.expectEqual(AccountRecord.bestRemainingAccountId(for: .antigravity, accounts: [a1], snapshots: snaps), nil, "<2 accounts -> nil")

        let zeroSnaps: [String: QuotaSnapshot] = [
            "a1": QuotaSnapshot(provider: .antigravity, accountId: "a1", status: .ready(fetchedAt: now, stale: false), primaryRemainingPercent: 0),
            "a2": QuotaSnapshot(provider: .antigravity, accountId: "a2", status: .ready(fetchedAt: now, stale: false), primaryRemainingPercent: 0),
        ]
        T.expectEqual(AccountRecord.bestRemainingAccountId(for: .antigravity, accounts: [a1, a2], snapshots: zeroSnaps), nil, "all 0% -> nil")

        // Formatters
        T.expectEqual(Formatters.relativeResetString(to: now.addingTimeInterval(-10), now: now), "即将重置")
        T.expectEqual(Formatters.relativeResetString(to: now.addingTimeInterval(30), now: now), "<1分钟后重置")
        T.expectEqual(Formatters.relativeResetString(to: now.addingTimeInterval(2 * 3600 + 15 * 60), now: now), "2小时15分后重置")
        T.expectEqual(Formatters.relativeResetString(to: now.addingTimeInterval(3 * 86400 + 4 * 3600), now: now), "3天4小时后重置")
        T.expectEqual(Formatters.percentString(remainingFraction: 0.72, showRemaining: true), "72%")
        T.expectEqual(Formatters.percentString(remainingFraction: 0.72, showRemaining: false), "28%")
        T.expectEqual(Formatters.currencyString(amount: 12.345, currency: "CNY"), "¥12.35")
        T.expectEqual(Formatters.currencyString(amount: 9.5, currency: "USD"), "$9.50")

        let parsedMicro = Formatters.parseRFC3339("2026-10-03T17:52:30.076579+08:00")
        T.expect(parsedMicro != nil, "RFC3339 microseconds with +08:00 must parse")
        let parsedUTC = Formatters.parseRFC3339("2026-11-20T08:36:15Z")
        T.expect(parsedUTC != nil, "RFC3339 Z without fractional seconds must parse")
        let localStr = Formatters.formatRFC3339Local(parsedMicro!, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
        T.expect(localStr.hasSuffix("+08:00"), "formatRFC3339Local must carry timezone offset")

        let kcAcct = Formatters.canonicalCodexKeychainAccount(codexHomePath: "/Users/example/.codex")
        T.expect(kcAcct.hasPrefix("cli|") && kcAcct.count == 20, "Codex Keychain account format cli|<16 hex>")
    }

    T.suite("Models.RegistryData Atomic Save & Load") {
        let dir = try makeTempDir(prefix: "roryorbit-reg")
        defer { try? FileManager.default.removeItem(at: dir) }

        let subDir = dir.appendingPathComponent("state", isDirectory: true)
        let regURL = subDir.appendingPathComponent("registry.json", isDirectory: false)

        let early = Date(timeIntervalSince1970: 1_700_000_000)
        var reg = RegistryData()
        reg.upsertAccount(AccountRecord(
            id: "sub_1",
            provider: .antigravity,
            email: "u1@example.com",
            displayName: "U1",
            plan: PlanInfo(kind: .ultra, displayName: "Ultra"),
            addedAt: early,
            isActiveLive: true,
            isBestRemaining: true
        ))
        // Upsert with later date & empty plan must preserve earlier addedAt and plan
        reg.upsertAccount(AccountRecord(
            id: "sub_1",
            provider: .antigravity,
            email: "",
            displayName: "",
            plan: nil,
            addedAt: Date(),
            isActiveLive: true
        ))
        T.expectEqual(reg.accounts[0].email, "u1@example.com")
        T.expectEqual(reg.accounts[0].plan?.kind, .ultra)
        T.expectEqual(Int(reg.accounts[0].addedAt.timeIntervalSince1970), Int(early.timeIntervalSince1970))

        try reg.save(to: regURL)

        let dirPerms = (try FileManager.default.attributesOfItem(atPath: subDir.path)[.posixPermissions] as? NSNumber)?.intValue
        let filePerms = (try FileManager.default.attributesOfItem(atPath: regURL.path)[.posixPermissions] as? NSNumber)?.intValue
        T.expectEqual(dirPerms, 0o700, "directory mode must be 0700")
        T.expectEqual(filePerms, 0o600, "registry.json mode must be 0600")

        let loaded = try RegistryData.load(from: regURL)
        T.expectEqual(loaded.accounts.count, 1)
        T.expectEqual(loaded.accounts[0].id, "sub_1")
        T.expectEqual(loaded.accounts[0].isBestRemaining, false, "isBestRemaining is transient and must not be persisted")
    }

    T.suite("AppStore.compactCurrencyString & exactCurrencyString") {
        // compactCurrencyString (tight pills & status bar)
        T.expectEqual(AppStore.compactCurrencyString(amount: 15_106.29, currency: "CNY"), "¥15.1k")
        T.expectEqual(AppStore.compactCurrencyString(amount: 15_000.0, currency: "CNY"), "¥15k")
        T.expectEqual(AppStore.compactCurrencyString(amount: 125_000.0, currency: "CNY"), "¥125k")
        T.expectEqual(AppStore.compactCurrencyString(amount: 999.5, currency: "CNY"), "¥1k")
        T.expectEqual(AppStore.compactCurrencyString(amount: 999.4, currency: "CNY"), "¥999")
        T.expectEqual(AppStore.compactCurrencyString(amount: 363.83, currency: "USD"), "$364")
        T.expectEqual(AppStore.compactCurrencyString(amount: 100.0, currency: "USD"), "$100")
        T.expectEqual(AppStore.compactCurrencyString(amount: 88.40, currency: "CNY"), "¥88.4")
        T.expectEqual(AppStore.compactCurrencyString(amount: 12.0, currency: "USD"), "$12")
        T.expectEqual(AppStore.compactCurrencyString(amount: 0.0, currency: "CNY"), "¥0")
        T.expectEqual(AppStore.compactCurrencyString(amount: 0.004, currency: "USD"), "$0")
        T.expectEqual(AppStore.compactCurrencyString(amount: 999_500.0, currency: "CNY"), "¥1M")
        T.expectEqual(AppStore.compactCurrencyString(amount: 1_200_000.0, currency: "USD"), "$1.2M")
        T.expectEqual(AppStore.compactCurrencyString(amount: 1_000_000.0, currency: "RMB"), "¥1M")
        T.expectEqual(AppStore.compactCurrencyString(amount: -15_106.29, currency: "CNY"), "-¥15.1k")

        let dsBalance = BalanceInfo(currency: "CNY", totalBalance: 15_106.29, grantedBalance: 0.0, toppedUpBalance: 15_106.29)
        T.expectEqual(AppStore.compactCurrencyString(dsBalance), "¥15.1k")

        // exactCurrencyString (cards, tooltips & --smoke-quota)
        T.expectEqual(AppStore.exactCurrencyString(dsBalance), "¥15,106.29")
        T.expectEqual(AppStore.exactCurrencyString(amount: 363.83, currency: "USD"), "$363.83")
        T.expectEqual(AppStore.exactCurrencyString(amount: 0.0, currency: "CNY"), "¥0.00")
        T.expectEqual(AppStore.exactCurrencyString(amount: 1_234_567.89, currency: "EUR"), "€1,234,567.89")
        T.expectEqual(AppStore.exactCurrencyString(amount: -42.5, currency: "GBP"), "-£42.50")
        T.expectEqual(AppStore.exactCurrencyString(amount: 1_000.0, currency: "JPY"), "JPY 1,000.00")
        T.expectEqual(AppStore.exactCurrencyString(amount: 1_234.5, currency: ""), "1,234.50")
    }
}

// MARK: - Test 2: KeychainStore (In-Memory + Real Temp .keychain-db)

private func runCommandSync(_ path: String, args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

private func testKeychainStore() {
    T.suite("KeychainStore.InMemory Single & Chunked + Tamper Rejection") {
        let backend = InMemoryKeychainBackend()
        let store = KeychainStore(backend: backend)

        try store.writeSecret(service: roryOrbitAntigravityService, account: "acct-1", value: "refresh-token-value-123")
        T.expectEqual(store.hasSecret(service: roryOrbitAntigravityService, account: "acct-1"), true)
        T.expectEqual(try store.readSecret(service: roryOrbitAntigravityService, account: "acct-1"), "refresh-token-value-123")
        T.expectEqual(
            try store.verifySecret(
                service: roryOrbitAntigravityService,
                account: "acct-1",
                expectedSHA256: Formatters.sha256Hex("refresh-token-value-123")
            ),
            true
        )
        try store.deleteSecret(service: roryOrbitAntigravityService, account: "acct-1")
        T.expectEqual(try store.readSecret(service: roryOrbitAntigravityService, account: "acct-1"), nil)

        // Chunked > 4500 bytes (will span >= 4 Base64 chunks of 1800 chars)
        let bigPayload = Data((0..<5200).map { UInt8(($0 * 37 + 11) % 251) })
        let bigSHA = Formatters.sha256Hex(bigPayload)
        try store.writeChunkedSecret(service: roryOrbitCodexService, account: "codex:u1:a1", data: bigPayload)

        let idx1 = try store.readChunkIndex(service: roryOrbitCodexService, account: "codex:u1:a1")
        T.expect(idx1 != nil && idx1!.chunks >= 4, "5200-byte payload should span >=4 chunks")
        T.expectEqual(try store.readChunkedSecret(service: roryOrbitCodexService, account: "codex:u1:a1"), bigPayload)
        T.expectEqual(try store.verifyChunkedSecret(service: roryOrbitCodexService, account: "codex:u1:a1", expectedSHA256: bigSHA), true)

        // Overwrite rotates generation and cleans up old generation chunks
        let updatedPayload = Data("{\"updated\":true,\"pad\":\"\(String(repeating: "X", count: 4000))\"}".utf8)
        try store.writeChunkedSecret(service: roryOrbitCodexService, account: "codex:u1:a1", data: updatedPayload)
        let idx2 = try store.readChunkIndex(service: roryOrbitCodexService, account: "codex:u1:a1")!
        T.expect(idx2.generation != idx1!.generation, "chunk overwrite must rotate generation")
        T.expectEqual(backend.itemCount(forService: roryOrbitCodexService), 1 + idx2.chunks, "old generation chunks must be removed")

        // Tamper chunk 0 -> readChunkedSecret MUST throw integrityCheckFailed
        let chunk0Key = KeychainStore.chunkAccountKey(account: "codex:u1:a1", generation: idx2.generation, index: 0)
        var chunk0Data = try backend.getGenericPassword(service: roryOrbitCodexService, account: chunk0Key)!
        var chunk0Str = String(data: chunk0Data, encoding: .utf8)!
        let firstChar = chunk0Str.first == "A" ? "B" : "A"
        chunk0Str = firstChar + String(chunk0Str.dropFirst())
        chunk0Data = Data(chunk0Str.utf8)
        try backend.setGenericPassword(service: roryOrbitCodexService, account: chunk0Key, data: chunk0Data)

        var tamperCaught = false
        do {
            _ = try store.readChunkedSecret(service: roryOrbitCodexService, account: "codex:u1:a1")
        } catch let err as KeychainStoreError {
            if case .integrityCheckFailed = err { tamperCaught = true }
            if case .encodingError = err { tamperCaught = true }
        }
        T.expect(tamperCaught, "tampered chunk must be rejected")

        // Delete removes index + all chunks
        try store.deleteChunkedSecret(service: roryOrbitCodexService, account: "codex:u1:a1")
        T.expectEqual(backend.itemCount(forService: roryOrbitCodexService), 0, "deleteChunkedSecret must remove index + all chunks")
    }

    T.suite("KeychainStore.RealTempKeychainDB (/usr/bin/security)") {
        let dir = try makeTempDir(prefix: "roryorbit-kc")
        defer { try? FileManager.default.removeItem(at: dir) }

        let kcPath = dir.appendingPathComponent("test.keychain-db").path
        let kcPass = "test-pass-\(UUID().uuidString)"
        let rcCreate = runCommandSync("/usr/bin/security", args: ["create-keychain", "-p", kcPass, kcPath])
        let rcUnlock = runCommandSync("/usr/bin/security", args: ["unlock-keychain", "-p", kcPass, kcPath])
        T.expectEqual(rcCreate, 0, "create-keychain must succeed")
        T.expectEqual(rcUnlock, 0, "unlock-keychain must succeed")

        let store = KeychainStore(keychainPath: kcPath)

        // 1. Plain ASCII secret
        try store.writeSecret(service: roryOrbitAntigravityService, account: "sub-ascii", value: "1//0gTEST_REFRESH_TOKEN_abc-123_XYZ")
        T.expectEqual(try store.readSecret(service: roryOrbitAntigravityService, account: "sub-ascii"), "1//0gTEST_REFRESH_TOKEN_abc-123_XYZ")

        // 2. JSON with quotes, colons, backslashes, UTF-8, and newline (uses -X hex stdin path)
        let trickyJSON = "{\"key\":\"val\\\"quote\",\"cn\":\"配额测试\",\"line\":\"a\\nb\"}\n"
        try store.writeSecret(service: roryOrbitKeysService, account: "tricky", value: trickyJSON)
        T.expectEqual(try store.readSecret(service: roryOrbitKeysService, account: "tricky"), trickyJSON)

        // 3. Large chunked Base64 payload (~5.5 KB -> 5 chunks) + SHA-256 verification
        let authJSON = makeCodexAuthJSONData(
            userId: "user-temp-1",
            accountId: "acct-temp-1",
            email: "temp@example.com",
            name: String(repeating: "LongName", count: 550)
        )
        T.expect(authJSON.count > 4000, "test auth payload should exceed single chunk")
        try store.writeChunkedSecret(service: roryOrbitCodexService, account: "codex:user-temp-1:acct-temp-1", data: authJSON)
        let readBack = try store.readChunkedSecret(service: roryOrbitCodexService, account: "codex:user-temp-1:acct-temp-1")
        T.expectEqual(readBack, authJSON, "chunked payload round-trip on real temp keychain must match byte-for-byte")

        // 4. Tamper chunk 1 directly on temp keychain -> MUST reject
        let idx = try store.readChunkIndex(service: roryOrbitCodexService, account: "codex:user-temp-1:acct-temp-1")!
        let c1Key = KeychainStore.chunkAccountKey(account: "codex:user-temp-1:acct-temp-1", generation: idx.generation, index: 1)
        let origChunk1 = try store.readExternalGenericPassword(service: roryOrbitCodexService, account: c1Key)!
        let flipped = (origChunk1.first == "A" ? "B" : "A") + String(origChunk1.dropFirst())
        try store.writeExternalGenericPassword(service: roryOrbitCodexService, account: c1Key, value: flipped)

        var threwTamper = false
        do {
            _ = try store.readChunkedSecret(service: roryOrbitCodexService, account: "codex:user-temp-1:acct-temp-1")
        } catch is KeychainStoreError {
            threwTamper = true
        }
        T.expect(threwTamper, "real temp keychain tamper must throw KeychainStoreError")

        // 5. Delete & verify gone
        try store.deleteChunkedSecret(service: roryOrbitCodexService, account: "codex:user-temp-1:acct-temp-1")
        T.expectEqual(try store.readChunkIndex(service: roryOrbitCodexService, account: "codex:user-temp-1:acct-temp-1"), nil)
        try store.deleteSecret(service: roryOrbitAntigravityService, account: "sub-ascii")
        T.expectEqual(try store.readSecret(service: roryOrbitAntigravityService, account: "sub-ascii"), nil)
    }
}

// MARK: - Test 3: ProcessControl (Graceful Stop, Timeout Never Auto-SIGKILL, Explicit Force-Quit, Reopen Subset)

private func testProcessControl() async {
    await T.asyncSuite("ProcessControl.GracefulStop & Reopen Subset") {
        let mock = MockProcessInspector()
        let stableURL = URL(fileURLWithPath: "/Applications/Antigravity.app")
        let insidersURL = URL(fileURLWithPath: "/Applications/Antigravity - Insiders.app")
        mock.installed = [stableURL, insidersURL]
        // Only Stable is running (Insiders is NOT running)
        mock.guiApps = [
            RunningGUIApp(
                pid: 1001,
                bundleId: AntigravityProvider.stableBundleId,
                localizedName: "Antigravity",
                bundleURL: stableURL,
                executablePath: "/Applications/Antigravity.app/Contents/MacOS/Antigravity"
            ),
        ]
        mock.processes = [
            ClientProcessInfo(id: 1001, name: "Antigravity", executablePath: "/Applications/Antigravity.app/Contents/MacOS/Antigravity", bundleId: AntigravityProvider.stableBundleId),
            ClientProcessInfo(id: 1002, name: "language_server", executablePath: "/Applications/Antigravity.app/Contents/Resources/bin/language_server"),
            ClientProcessInfo(id: 9999, name: "CodexBar", executablePath: "/Applications/CodexBar.app/Contents/MacOS/CodexBar", bundleId: "com.steipete.codexbar"),
        ]
        mock.exitOnGraceful = true

        let ctrl = ProcessController(inspector: mock, selfPid: 5555)
        let res = await ctrl.gracefulStop(
            bundleIDs: AntigravityProvider.bundleIDs,
            detachedExecutableMatchers: [{ $0.contains("language_server") }],
            timeoutSeconds: 0.5,
            allowForceQuit: false
        )

        guard case .stopped(let reopenURLs) = res else {
            T.expect(false, "expected .stopped, got \(res)")
            return
        }
        T.expectEqual(reopenURLs, [stableURL], "must record ONLY previously running app URLs")
        T.expect(mock.signalsSent.allSatisfy { $0.signal != SIGKILL }, "graceful stop must NEVER send SIGKILL")
        T.expect(mock.signalsSent.allSatisfy { $0.pid != 9999 }, "must NEVER touch unrelated apps like CodexBar")

        await ctrl.reopenApps(urls: reopenURLs)
        T.expectEqual(mock.reopenedURLs, [stableURL], "reopenApps must open ONLY Stable, not Insiders")
    }

    await T.asyncSuite("ProcessControl.Timeout Never Auto-SIGKILL, Explicit Force-Quit Allowed") {
        let mock = MockProcessInspector()
        let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        mock.guiApps = [
            RunningGUIApp(pid: 2001, bundleId: CodexProvider.desktopBundleId, localizedName: "ChatGPT", bundleURL: appURL, executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"),
        ]
        mock.processes = [
            ClientProcessInfo(id: 2001, name: "ChatGPT", executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", bundleId: CodexProvider.desktopBundleId),
            ClientProcessInfo(id: 2002, name: "codex", executablePath: "/Users/example/.codex/packages/app-server-daemon/releases/1/bin/codex"),
        ]
        mock.exitOnGraceful = false
        mock.exitOnSigKill = true

        let ctrl = ProcessController(inspector: mock, selfPid: 5555)

        // 1. allowForceQuit == false -> MUST return .stillRunning and send ZERO SIGKILLs
        let resNoForce = await ctrl.gracefulStop(
            bundleIDs: CodexProvider.desktopBundleIDs,
            detachedExecutableMatchers: [{ $0.hasSuffix("/bin/codex") }],
            timeoutSeconds: 0.25,
            allowForceQuit: false
        )
        guard case .stillRunning(let surviving) = resNoForce else {
            T.expect(false, "expected .stillRunning when graceful quit times out")
            return
        }
        T.expectEqual(surviving.map(\.id).sorted(), [2001, 2002])
        T.expect(mock.signalsSent.allSatisfy { $0.signal != SIGKILL }, "MUST NEVER auto-SIGKILL when allowForceQuit == false")

        // 2. allowForceQuit == true -> explicitly confirmed force-quit sends SIGKILL and stops
        let resForce = await ctrl.gracefulStop(
            bundleIDs: CodexProvider.desktopBundleIDs,
            detachedExecutableMatchers: [{ $0.hasSuffix("/bin/codex") }],
            timeoutSeconds: 0.25,
            allowForceQuit: true
        )
        guard case .stopped(let reopenURLs) = resForce else {
            T.expect(false, "expected .stopped after explicit allowForceQuit == true")
            return
        }
        T.expectEqual(reopenURLs, [appURL])
        let killedPids = Set(mock.signalsSent.filter { $0.signal == SIGKILL }.map(\.pid))
        T.expectEqual(killedPids, Set([2001, 2002]), "explicit allowForceQuit must SIGKILL surviving target PIDs")
    }
}

// MARK: - Test 4: LegacyMigrator (Dedup, Claude Strictly Ignored, Purge, & Abort on SHA-256 Mismatch)

private func stageOrbitSwitchCodexChunks(
    backend: InMemoryKeychainBackend,
    accountId: String,
    sessionJSON: Data,
    generation: String = "gen1234567890abc",
    corruptDigest: Bool = false
) throws {
    let b64 = sessionJSON.base64EncodedString()
    let chunkSize = 200 // small for multi-chunk testing
    var chunks: [String] = []
    var idx = b64.startIndex
    while idx < b64.endIndex {
        let next = b64.index(idx, offsetBy: chunkSize, limitedBy: b64.endIndex) ?? b64.endIndex
        chunks.append(String(b64[idx..<next]))
        idx = next
    }
    let digest = corruptDigest ? String(repeating: "0", count: 64) : Formatters.sha256Hex(sessionJSON)
    let indexObj = KeychainChunkIndex(generation: generation, chunks: chunks.count, digest: digest)
    let indexData = try JSONEncoder().encode(indexObj)
    try backend.setGenericPassword(service: LegacyMigrator.orbitSwitchCodexService, account: accountId, data: indexData)
    for (i, c) in chunks.enumerated() {
        let key = KeychainStore.chunkAccountKey(account: accountId, generation: generation, index: i)
        try backend.setGenericPassword(service: LegacyMigrator.orbitSwitchCodexService, account: key, data: Data(c.utf8))
    }
}

private func testLegacyMigrator() {
    T.suite("LegacyMigrator.Full Migration, Dedup, Zero-Claude & Purge") {
        let dir = try makeTempDir(prefix: "roryorbit-mig")
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = InMemoryKeychainBackend()
        let kc = KeychainStore(backend: backend)

        // OrbitSwitch backup JSON with 2 Antigravity + 2 Codex + 1 forbidden "claude" entry
        let backupURL = dir.appendingPathComponent("orbitswitch-accounts.json")
        let backupPayload: [String: Any] = [
            "version": 1,
            "accounts": [
                ["provider": "antigravity", "id": "100001", "email": "ag1@gmail.com", "name": "AG1", "plan": ["kind": "ultra", "name": "Ultra"], "addedAt": "2026-10-01T00:00:00Z"],
                ["provider": "antigravity", "id": "100002", "email": "ag2@gmail.com", "name": "AG2", "plan": ["kind": "pro", "name": "Pro"], "addedAt": "2026-10-02T00:00:00Z"],
                ["provider": "codex", "id": "codex:u1:acc1", "email": "c1@gmail.com", "name": "C1", "plan": ["kind": "prolite", "name": "prolite"], "addedAt": "2026-10-03T00:00:00Z"],
                ["provider": "codex", "id": "codex:u2:acc2", "email": "c2@gmail.com", "name": "C2", "plan": ["kind": "plus", "name": "Plus"], "addedAt": "2026-10-04T00:00:00Z"],
                ["provider": "claude", "id": "claude-should-never-migrate", "email": "nope@anthropic.test", "name": "Claude"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: backupPayload).write(to: backupURL)

        // Stage OrbitSwitch Keychain items (+ a claude item that must NEVER be touched/deleted)
        try backend.setGenericPassword(service: LegacyMigrator.orbitSwitchAntigravityService, account: "100001", data: Data("rt_ag_1".utf8))
        try backend.setGenericPassword(service: LegacyMigrator.orbitSwitchAntigravityService, account: "100002", data: Data("rt_ag_2".utf8))
        try backend.setGenericPassword(service: LegacyMigrator.orbitSwitchAntigravityService, account: "claude-should-never-migrate", data: Data("forbidden".utf8))

        let c1Auth = makeCodexAuthJSONData(userId: "u1", accountId: "acc1", email: "c1@gmail.com", planType: "prolite")
        let c1Wrap = try JSONSerialization.data(withJSONObject: [
            "credential": try JSONSerialization.jsonObject(with: c1Auth),
            "profile": ["email": "c1@gmail.com"],
        ])
        let c2Auth = makeCodexAuthJSONData(userId: "u2", accountId: "acc2", email: "c2@gmail.com", planType: "plus")
        let c2Wrap = try JSONSerialization.data(withJSONObject: [
            "credential": try JSONSerialization.jsonObject(with: c2Auth),
            "profile": ["email": "c2@gmail.com"],
        ])
        try stageOrbitSwitchCodexChunks(backend: backend, accountId: "codex:u1:acc1", sessionJSON: c1Wrap)
        try stageOrbitSwitchCodexChunks(backend: backend, accountId: "codex:u2:acc2", sessionJSON: c2Wrap)

        // CodexBar managed-codex-accounts.json: 1 duplicate (u1:acc1) + 1 new (u3:acc3)
        let homesDir = dir.appendingPathComponent("managed-codex-homes", isDirectory: true)
        let home1 = homesDir.appendingPathComponent("uuid-1", isDirectory: true)
        let home3 = homesDir.appendingPathComponent("uuid-3", isDirectory: true)
        try FileManager.default.createDirectory(at: home1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home3, withIntermediateDirectories: true)
        try c1Auth.write(to: home1.appendingPathComponent("auth.json"))
        let c3Auth = makeCodexAuthJSONData(userId: "u3", accountId: "acc3", email: "c3@gmail.com", planType: "pro")
        try c3Auth.write(to: home3.appendingPathComponent("auth.json"))

        let managedURL = dir.appendingPathComponent("managed-codex-accounts.json")
        let managedJSON: [String: Any] = [
            "version": 1,
            "accounts": [
                ["id": "uuid-1", "email": "c1@gmail.com", "managedHomePath": home1.path, "createdAt": 1_750_000_000.0],
                ["id": "uuid-3", "email": "c3@gmail.com", "managedHomePath": home3.path, "createdAt": 1_760_000_000.0],
            ],
        ]
        try JSONSerialization.data(withJSONObject: managedJSON).write(to: managedURL)

        // CodexBar config.json with kimi, deepseek, and claude (must ignore claude!)
        let cbConfigURL = dir.appendingPathComponent("codexbar-config.json")
        let cbConfigJSON: [String: Any] = [
            "providers": [
                ["id": "kimi", "enabled": true, "apiKey": "sk-kimi-mock-1234"],
                ["id": "deepseek", "enabled": true, "tokenAccounts": ["activeIndex": 0, "accounts": [["label": "sigo", "token": "sk-ds-mock-5678"]]]],
                ["id": "claude", "enabled": false, "apiKey": "sk-ant-forbidden"],
            ],
        ]
        let cbConfigBytesBefore = try JSONSerialization.data(withJSONObject: cbConfigJSON)
        try cbConfigBytesBefore.write(to: cbConfigURL)

        let regURL = dir.appendingPathComponent("registry.json")
        let paths = LegacyMigrationPaths(
            orbitSwitchBackupAccountsURL: backupURL,
            codexBarManagedAccountsURL: managedURL,
            codexBarManagedHomesDirURL: homesDir,
            codexBarConfigURL: cbConfigURL,
            registryURL: regURL
        )

        let migrator = LegacyMigrator(keychain: kc, paths: paths)
        let report = migrator.runMigration()

        T.expect(report.succeeded, "migration should succeed cleanly: \(report.errors)")
        T.expectEqual(report.orbitSwitchAntigravityMigrated, 2)
        T.expectEqual(report.orbitSwitchCodexMigrated, 2)
        T.expectEqual(report.codexBarCodexImported, 1, "u3:acc3 imported")
        T.expectEqual(report.codexBarCodexSkippedDuplicate, 1, "u1:acc1 deduplicated")
        T.expectEqual(Set(report.codexBarAPIKeysImported), Set(["kimi", "deepseek"]))
        T.expectEqual(report.orbitSwitchPurgeExecuted, true)
        T.expect(report.orbitSwitchLegacyItemsPurged >= 4, "must purge migrated Antigravity + Codex root & chunks")

        // Verify zero Claude accounts or keys imported
        let reg = try RegistryData.load(from: regURL)
        T.expectEqual(reg.accounts(for: .antigravity).count, 2)
        T.expectEqual(reg.accounts(for: .codex).count, 3)
        T.expectEqual(reg.accounts.contains { $0.id.contains("claude") }, false)
        T.expectEqual(try kc.readSecret(service: roryOrbitKeysService, account: "claude"), nil)
        T.expectEqual(try kc.readSecret(service: roryOrbitKeysService, account: "kimi"), "sk-kimi-mock-1234")
        T.expectEqual(try kc.readSecret(service: roryOrbitKeysService, account: "deepseek"), "sk-ds-mock-5678")
        T.expectEqual(reg.settings.legacyMigrationCompleted, true)

        // Verify legacy migrated items purged from orbitswitch & orbitswitch.sessions
        T.expectEqual(try backend.getGenericPassword(service: LegacyMigrator.orbitSwitchAntigravityService, account: "100001"), nil)
        T.expectEqual(try backend.getGenericPassword(service: LegacyMigrator.orbitSwitchAntigravityService, account: "100002"), nil)
        T.expectEqual(backend.itemCount(forService: LegacyMigrator.orbitSwitchCodexService), 0, "all orbitswitch.sessions chunks & indices must be purged")

        // Verify CodexBar config untouched
        T.expectEqual(try Data(contentsOf: cbConfigURL), cbConfigBytesBefore)

        // Idempotent second run
        let report2 = migrator.runMigration()
        T.expect(report2.succeeded)
        T.expectEqual(report2.orbitSwitchAntigravityMigrated, 0)
        T.expectEqual(report2.orbitSwitchCodexMigrated, 0)
        T.expectEqual(report2.orbitSwitchSkippedAlreadyMigrated, 4)
        T.expectEqual(report2.codexBarCodexSkippedDuplicate, 2)
        T.expectEqual(Set(report2.codexBarAPIKeysSkippedExisting), Set(["kimi", "deepseek"]))
    }

    T.suite("LegacyMigrator.Abort Without Purge on SHA-256 Mismatch") {
        let dir = try makeTempDir(prefix: "roryorbit-mig-fail")
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = InMemoryKeychainBackend()
        let kc = KeychainStore(backend: backend)

        let backupURL = dir.appendingPathComponent("orbitswitch-accounts.json")
        let backupPayload: [String: Any] = [
            "version": 1,
            "accounts": [
                ["provider": "antigravity", "id": "100001", "email": "ag1@gmail.com", "name": "AG1"],
                ["provider": "codex", "id": "codex:u1:acc1", "email": "c1@gmail.com", "name": "C1"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: backupPayload).write(to: backupURL)
        try backend.setGenericPassword(service: LegacyMigrator.orbitSwitchAntigravityService, account: "100001", data: Data("rt_ag_1".utf8))
        let c1Auth = makeCodexAuthJSONData(userId: "u1", accountId: "acc1", email: "c1@gmail.com")
        try stageOrbitSwitchCodexChunks(backend: backend, accountId: "codex:u1:acc1", sessionJSON: c1Auth, corruptDigest: true)

        let beforeAGCount = backend.itemCount(forService: LegacyMigrator.orbitSwitchAntigravityService)
        let beforeCodexCount = backend.itemCount(forService: LegacyMigrator.orbitSwitchCodexService)

        let paths = LegacyMigrationPaths(
            orbitSwitchBackupAccountsURL: backupURL,
            codexBarManagedAccountsURL: dir.appendingPathComponent("absent-managed.json"),
            codexBarManagedHomesDirURL: dir.appendingPathComponent("absent-homes"),
            codexBarConfigURL: dir.appendingPathComponent("absent-config.json"),
            registryURL: dir.appendingPathComponent("registry.json")
        )
        let report = LegacyMigrator(keychain: kc, paths: paths).runMigration()

        T.expect(!report.succeeded, "corrupted SHA-256 must fail migration")
        T.expectEqual(report.orbitSwitchPurgeExecuted, false, "MUST NOT purge legacy Keychain on SHA-256 failure")
        T.expectEqual(report.orbitSwitchLegacyItemsPurged, 0)
        T.expectEqual(backend.itemCount(forService: LegacyMigrator.orbitSwitchAntigravityService), beforeAGCount, "AG legacy items preserved")
        T.expectEqual(backend.itemCount(forService: LegacyMigrator.orbitSwitchCodexService), beforeCodexCount, "Codex legacy items preserved")
    }
}

// MARK: - Test 5: AntigravityProvider (Proto3 0.0, 403 Fallback, go-keyring-base64, app.asar, Native UA)

private func writeSyntheticASAR(to url: URL, version: String) throws {
    let pkgBytes = Data("{\"name\":\"antigravity\",\"version\":\"\(version)\"}".utf8)
    let headerObj: [String: Any] = [
        "files": [
            "package.json": [
                "size": pkgBytes.count,
                "offset": "0",
            ],
        ],
    ]
    let jsonBytes = try JSONSerialization.data(withJSONObject: headerObj, options: [])
    // Electron ASAR pickle header:
    // bytes 0..3: size_pickle_payload_size (4)
    // bytes 4..7: header_size (aligned jsonSize + 8)
    // bytes 8..11: header_pickle_payload_size (jsonSize + 4)
    // bytes 12..15: jsonSize
    let jsonSize = UInt32(jsonBytes.count)
    let paddedJsonSize = (jsonSize + 3) & ~UInt32(3)
    let headerSize = paddedJsonSize + 8
    let innerPickleSize = paddedJsonSize + 4

    func u32LE(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    var blob = Data()
    blob.append(contentsOf: u32LE(4))
    blob.append(contentsOf: u32LE(headerSize))
    blob.append(contentsOf: u32LE(innerPickleSize))
    blob.append(contentsOf: u32LE(jsonSize))
    blob.append(jsonBytes)
    if paddedJsonSize > jsonSize {
        blob.append(Data(repeating: 0, count: Int(paddedJsonSize - jsonSize)))
    }
    blob.append(pkgBytes)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try blob.write(to: url)
}

private func testAntigravityProvider() async {
    T.suite("AntigravityProvider.Proto3 Zero-Omission & Pool Mapping") {
        let summaryJSON: [String: Any] = [
            "groups": [
                [
                    "displayName": "Gemini Models",
                    // Proto3 omitted remainingFraction -> MUST be 0.0 (exhausted), NOT skipped!
                    "resetTime": "2026-11-22T00:00:00Z",
                ],
                [
                    "displayName": "Claude and GPT models",
                    "remainingFraction": 0.65,
                    "resetTime": "2026-11-22T01:00:00Z",
                ],
                [
                    "displayName": "Gemini 4 Argon",
                    "remainingFraction": 0.80,
                    "resetTime": "2026-11-27T00:00:00Z",
                ],
                [
                    "displayName": "Disabled Pool",
                    "disabled": true,
                    "remainingFraction": 0.5,
                ],
            ],
        ]
        let windows = AntigravityProvider.parseQuotaSummaryWindows(from: summaryJSON)
        T.expectEqual(windows.count, 3)
        T.expectEqual(windows[0].id, "gemini")
        T.expectEqual(windows[0].remainingPercent, 0, "proto3 omitted remainingFraction must decode as 0%")
        T.expectEqual(windows[0].isExhausted, true)
        T.expectEqual(windows[0].isPrimary, true)

        T.expectEqual(windows[1].id, "claude_gpt")
        T.expectEqual(windows[1].label, "Claude / GPT")
        T.expectEqual(windows[1].remainingPercent, 65)

        T.expectEqual(windows[2].id, "argon")
        T.expectEqual(windows[2].label, "Argon 周额")
        T.expectEqual(windows[2].windowSeconds, 604_800)
        T.expectEqual(windows[2].remainingPercent, 80)

        // Fallback parsers: fetchAvailableModels (dict shape) & retrieveUserQuota (buckets)
        let availJSON: [String: Any] = [
            "models": [
                "gemini-3-pro": ["displayName": "Gemini 3 Pro", "quotaInfo": ["remainingFraction": 0.42, "resetTime": "2026-11-22T02:00:00Z"]],
                "gemini-3-flash": ["displayName": "Gemini 3 Flash", "quotaInfo": ["remainingFraction": 0.90]],
                "partner-gpt": ["displayName": "GPT 6", "quotaInfo": [:]], // proto3 omitted 0.0
            ],
        ]
        let availWins = AntigravityProvider.parseAvailableModelsWindows(from: availJSON)
        T.expectEqual(availWins.count, 2)
        T.expectEqual(availWins[0].id, "gemini")
        T.expectEqual(availWins[0].remainingPercent, 42, "pool should take minimum remainingFraction across models in pool")
        T.expectEqual(availWins[1].id, "claude_gpt")
        T.expectEqual(availWins[1].remainingPercent, 0)

        let bucketsJSON: [String: Any] = [
            "buckets": [
                ["modelId": "gemini-4-argon", "remainingFraction": 0.55],
                ["modelId": "gemini-3-pro", "remainingFraction": 0.77],
            ],
        ]
        let bucketWins = AntigravityProvider.parseRetrieveUserQuotaWindows(from: bucketsJSON)
        T.expectEqual(bucketWins.count, 2)
        T.expectEqual(bucketWins.first(where: { $0.id == "argon" })?.remainingPercent, 55)
    }

    T.suite("AntigravityProvider.Tier 1 & Tier 2 5h/Weekly Split (Ultra/Pro), Proto3 0.0 & userTier") {
        // Tier 1 Local RPC RetrieveUserQuotaSummary: wrapped in {"response":{"groups":[...]}} (Ultra, 4 windows)
        // Intentionally puts weekly before 5h and omits remainingFraction on one bucket (proto3 0.0)
        let tier1Ultra: [String: Any] = [
            "response": [
                "groups": [
                    [
                        "displayName": "Claude and GPT models",
                        "buckets": [
                            [
                                "bucketId": "3p-weekly",
                                "window": "weekly",
                                "remainingFraction": 0.91,
                                "resetTime": "2026-11-27T08:00:00Z",
                            ],
                            [
                                "bucketId": "3p-5h",
                                "window": "5h",
                                // proto3 omitted remainingFraction -> MUST decode as 0.0 (exhausted)
                                "resetTime": "2026-11-21T06:00:00Z",
                            ],
                        ],
                    ],
                    [
                        "displayName": "Gemini Models",
                        "buckets": [
                            [
                                "bucketId": "gemini-weekly",
                                "window": "weekly",
                                "remainingFraction": 0.84,
                                "resetTime": "2026-11-27T08:00:00Z",
                            ],
                            [
                                "bucketId": "gemini-5h",
                                "window": "5h",
                                "remainingFraction": 0.80,
                                "resetTime": "2026-11-21T05:30:00Z",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let ultraWins = AntigravityProvider.parseQuotaSummaryWindows(from: tier1Ultra)
        T.expectEqual(ultraWins.count, 4, "Ultra Tier 1 summary must emit exactly 4 5h/weekly windows")
        T.expectEqual(ultraWins.map(\.id), ["gemini_5h", "gemini_weekly", "claude_gpt_5h", "claude_gpt_weekly"])
        T.expectEqual(ultraWins.map(\.label), ["Gemini · 5小时", "Gemini · 周", "Claude / GPT · 5小时", "Claude / GPT · 周"])
        T.expectEqual(ultraWins[0].windowSeconds, 18_000)
        T.expectEqual(ultraWins[0].remainingPercent, 80)
        T.expectEqual(ultraWins[0].isPrimary, true, "gemini_5h must be primary")
        T.expectEqual(ultraWins[1].windowSeconds, 604_800)
        T.expectEqual(ultraWins[1].remainingPercent, 84)
        T.expectEqual(ultraWins[1].isPrimary, false)
        T.expectEqual(ultraWins[2].windowSeconds, 18_000)
        T.expectEqual(ultraWins[2].remainingPercent, 0, "proto3 omitted remainingFraction in bucket must equal 0%")
        T.expectEqual(ultraWins[2].isExhausted, true)
        T.expectEqual(ultraWins[3].windowSeconds, 604_800)
        T.expectEqual(ultraWins[3].remainingPercent, 91)

        // Tier 2 Remote Cloud Code daily-cloudcode-pa:retrieveUserQuotaSummary: unwrapped {"groups":[...]} (Pro, 5 windows incl. Argon · 周)
        let tier2Pro: [String: Any] = [
            "groups": [
                [
                    "displayName": "Gemini Models",
                    "buckets": [
                        ["bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.63, "resetTime": "2026-11-27T12:00:00Z"],
                        ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.15, "resetTime": "2026-11-21T07:00:00Z"],
                    ],
                ],
                [
                    "displayName": "Claude and GPT models",
                    "buckets": [
                        ["bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 1.0, "resetTime": "2026-11-27T12:00:00Z"],
                        ["bucketId": "3p-5h", "window": "5h", "remainingFraction": 1.0, "resetTime": "2026-11-21T07:00:00Z"],
                    ],
                ],
                [
                    "displayName": "Gemini 4 Argon",
                    "buckets": [
                        ["bucketId": "gemini-argon-wtu-weekly", "window": "weekly", "remainingFraction": 1.0, "resetTime": "2026-11-27T12:00:00Z"],
                    ],
                ],
            ],
        ]
        let proWins = AntigravityProvider.parseQuotaSummaryWindows(from: tier2Pro)
        T.expectEqual(proWins.count, 5, "Pro Tier 2 summary must emit 5 windows including Argon · 周")
        T.expectEqual(proWins.map(\.id), ["gemini_5h", "gemini_weekly", "claude_gpt_5h", "claude_gpt_weekly", "argon_weekly"])
        T.expectEqual(proWins[0].remainingPercent, 15)
        T.expectEqual(proWins[0].isPrimary, true)
        T.expectEqual(proWins[1].remainingPercent, 63)
        T.expectEqual(proWins[4].id, "argon_weekly")
        T.expectEqual(proWins[4].label, "Argon · 周")
        T.expectEqual(proWins[4].windowSeconds, 604_800)
        T.expectEqual(proWins[4].remainingPercent, 100)
        T.expectEqual(proWins[4].isPrimary, false)

        // GetUserStatus plan parsing: userTier MUST beat TEAMS_TIER_PRO, and fallback must strip TEAMS_TIER_ prefix
        let ultraUserStatus: [String: Any] = [
            "userTier": ["id": "g1-ultra-tier", "name": "Google AI Ultra"],
            "planStatus": [
                "planInfo": [
                    "teamsTier": "TEAMS_TIER_PRO",
                    "planShortName": "Pro",
                ],
            ],
        ]
        let parsedUltraPlan = AntigravityProvider.parsePlanFromUserStatus(ultraUserStatus)
        T.expectEqual(parsedUltraPlan?.kind, .ultra, "userTier g1-ultra-tier must override TEAMS_TIER_PRO")
        T.expectEqual(parsedUltraPlan?.displayName, "Google AI Ultra")

        let proUserStatus: [String: Any] = [
            "userTier": ["id": "g1-pro-tier", "name": "Google AI Pro"],
            "planStatus": [
                "planInfo": [
                    "teamsTier": "TEAMS_TIER_PRO",
                    "planShortName": "Pro",
                ],
            ],
        ]
        let parsedProPlan = AntigravityProvider.parsePlanFromUserStatus(proUserStatus)
        T.expectEqual(parsedProPlan?.kind, .pro)
        T.expectEqual(parsedProPlan?.displayName, "Google AI Pro")

        let freeUserStatus: [String: Any] = [
            "userTier": ["id": "free-tier", "name": "Free Starter"],
        ]
        let parsedFreePlan = AntigravityProvider.parsePlanFromUserStatus(freeUserStatus)
        T.expectEqual(parsedFreePlan?.kind, .free)
        T.expectEqual(parsedFreePlan?.displayName, "Free")

        // Fallback when userTier absent: TEAMS_TIER_PRO must NOT misclassify as .team
        let legacyTeamsTierStatus: [String: Any] = [
            "planStatus": [
                "planInfo": [
                    "teamsTier": "TEAMS_TIER_PRO",
                    "planShortName": "Pro",
                ],
            ],
        ]
        let parsedFallbackPlan = AntigravityProvider.parsePlanFromUserStatus(legacyTeamsTierStatus)
        T.expectEqual(parsedFallbackPlan?.kind, .pro, "TEAMS_TIER_PRO fallback must strip TEAMS_TIER_ and resolve as .pro, not .team")
        T.expectEqual(parsedFallbackPlan?.displayName, "Pro")
    }

    T.suite("AntigravityProvider.go-keyring-base64, app.asar, Native UA & GOCSPX Scan") {
        let origJSON = Data("{\"auth_method\":\"consumer\",\"custom_extra\":42,\"token\":{\"access_token\":\"at\",\"refresh_token\":\"rt\"}}".utf8)
        let encoded = AntigravityProvider.encodeGoKeyringValue(origJSON)
        T.expect(encoded.hasPrefix("go-keyring-base64:"))
        let decoded = AntigravityProvider.decodeGoKeyringValue(encoded)
        T.expectEqual(decoded, origJSON, "go-keyring-base64 round-trip must preserve exact bytes & unknown fields")

        let dir = try makeTempDir(prefix: "roryorbit-ag")
        defer { try? FileManager.default.removeItem(at: dir) }

        let stableApp = dir.appendingPathComponent("Antigravity.app", isDirectory: true)
        let asarURL = stableApp.appendingPathComponent("Contents/Resources/app.asar")
        try writeSyntheticASAR(to: asarURL, version: "2.33.0")
        T.expectEqual(AntigravityProvider.readPackageVersionFromASAR(at: asarURL), "2.33.0")

        let insidersApp = dir.appendingPathComponent("Antigravity - Insiders.app", isDirectory: true)
        let insidersAsar = insidersApp.appendingPathComponent("Contents/Resources/app.asar")
        try writeSyntheticASAR(to: insidersAsar, version: "1.0.20261120010114")

        let paths = AntigravityProvider.Paths(
            stableAppURL: stableApp,
            insidersAppURL: insidersApp,
            agyCLIURL: dir.appendingPathComponent("agy"),
            mirrorTokenURL: dir.appendingPathComponent("mirror")
        )
        let provider = AntigravityProvider(
            keychain: KeychainStore(backend: InMemoryKeychainBackend()),
            processController: ProcessController(inspector: MockProcessInspector()),
            paths: paths
        )
        let ua = provider.resolveNativeUserAgent()
        T.expectEqual(ua, "antigravity/hub/2.33.0 darwin/arm64", "UA must be native antigravity/hub/<ver> darwin/arm64")
        T.expect(!ua.contains("OrbitSwitch"), "UA must NEVER contain OrbitSwitch/")

        // Insiders-style timestamp version in stable path falls back to 2.33.0
        let badStablePaths = AntigravityProvider.Paths(
            stableAppURL: insidersApp,
            insidersAppURL: insidersApp,
            agyCLIURL: dir.appendingPathComponent("agy"),
            mirrorTokenURL: dir.appendingPathComponent("mirror")
        )
        let fallbackProvider = AntigravityProvider(
            keychain: KeychainStore(backend: InMemoryKeychainBackend()),
            processController: ProcessController(inspector: MockProcessInspector()),
            paths: badStablePaths
        )
        T.expectEqual(fallbackProvider.resolveNativeUserAgent(), "antigravity/hub/2.33.0 darwin/arm64")

        // Stream-scan packed Go .rodata binary (adjacent ASCII strings with no NUL separator)
        let binDir = stableApp.appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let fakeSecret = "GOCSPX-AbCdEfGhIjKlMnOpQrStUvWxYz01"
        let packedBlob = Data("prefixText\(fakeSecret)nextPackedString".utf8)
        try packedBlob.write(to: binDir.appendingPathComponent("language_server"))
        let found = AntigravityProvider.scanClientSecretCandidates(inBinDirectories: [binDir])
        T.expectEqual(found, [fakeSecret], "stream scanner must find Go .rodata packed GOCSPX secret")
    }

    await T.asyncSuite("AntigravityProvider.403 Fallback Pipeline (Mock HTTP)") {
        let dir = try makeTempDir(prefix: "roryorbit-ag-http")
        defer { try? FileManager.default.removeItem(at: dir) }

        let stableApp = dir.appendingPathComponent("Antigravity.app", isDirectory: true)
        try writeSyntheticASAR(to: stableApp.appendingPathComponent("Contents/Resources/app.asar"), version: "2.33.0")
        let binDir = stableApp.appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try Data("GOCSPX-1234567890abcdefghijklmnopqr".utf8).write(to: binDir.appendingPathComponent("language_server"))

        let backend = InMemoryKeychainBackend()
        let kc = KeychainStore(backend: backend)
        try kc.writeSecret(service: KeychainStore.roryOrbitAntigravityService, account: "sub-403", value: "rt_mock")

        StubURLProtocol.reset { req, bodyData in
            let urlStr = req.url?.absoluteString ?? ""
            let resp: (Int, Any) -> (HTTPURLResponse, Data) = { code, obj in
                let d = try! JSONSerialization.data(withJSONObject: obj)
                return (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, d)
            }
            if urlStr.contains("oauth2.googleapis.com/token") {
                let bodyStr = String(data: bodyData, encoding: .utf8) ?? ""
                if bodyStr.contains("roryorbit_client_secret_probe") {
                    return resp(400, ["error": "invalid_grant"])
                }
                return resp(200, ["access_token": "at_fresh", "expires_in": 3600])
            }
            if urlStr.contains("daily-cloudcode-pa.googleapis.com") {
                return resp(403, ["error": ["code": 403, "message": "forbidden"]])
            }
            if urlStr.contains(":loadCodeAssist") {
                return resp(200, [
                    "paidTier": ["id": "g1-ultra-tier", "name": "Google AI Ultra"],
                    "cloudaicompanionProject": "proj-xyz-123",
                ])
            }
            if urlStr.contains(":fetchAvailableModels") {
                return resp(200, [
                    "models": [
                        "gemini-3-pro": ["displayName": "Gemini 3 Pro", "quotaInfo": ["remainingFraction": 0.75]],
                    ],
                ])
            }
            return resp(404, [:])
        }

        let paths = AntigravityProvider.Paths(
            stableAppURL: stableApp,
            insidersAppURL: dir.appendingPathComponent("Insiders.app"),
            agyCLIURL: dir.appendingPathComponent("agy"),
            mirrorTokenURL: dir.appendingPathComponent("mirror")
        )
        let provider = AntigravityProvider(
            keychain: kc,
            processController: ProcessController(inspector: MockProcessInspector()),
            paths: paths,
            session: makeMockSession()
        )
        let acct = AccountRecord(id: "sub-403", provider: .antigravity, email: "u@gmail.com", displayName: "U")
        let snap = await provider.fetchQuota(for: acct, isActiveLive: false)

        T.expect(snap.status.isReady, "403 on daily summary must recover via loadCodeAssist -> fetchAvailableModels")
        T.expectEqual(snap.plan?.kind, .ultra)
        T.expectEqual(snap.primaryRemainingPercent, 75)
        let reqs = StubURLProtocol.snapshotRequests()
        let dailyReq = reqs.first { $0.request.url?.absoluteString.contains("daily-cloudcode-pa") == true }
        T.expectEqual(dailyReq?.request.value(forHTTPHeaderField: "User-Agent"), "antigravity/hub/2.33.0 darwin/arm64")
        let availReq = reqs.first { $0.request.url?.absoluteString.contains(":fetchAvailableModels") == true }
        let availBody = availReq.flatMap { String(data: $0.body, encoding: .utf8) } ?? ""
        T.expect(availBody.contains("proj-xyz-123"), "fetchAvailableModels must pass cloudaicompanionProject")
    }
}

// MARK: - Test 6: CodexProvider & CodexProjectSync

private func testCodexAndProjectSync() async {
    T.suite("CodexProvider.Window Classification, prolite & Config Guards") {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Deliberately swap slot order: primary_window is weekly (604800), secondary_window is 5h (18000)!
        let whamJSON: [String: Any] = [
            "plan_type": "prolite",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 40.0,
                    "limit_window_seconds": 604_800,
                    "resets_at": now.timeIntervalSince1970 + 86_400,
                ],
                "secondary_window": [
                    "used_percent": 15.0,
                    "limit_window_seconds": 18_000,
                    "reset_after_seconds": 3600,
                ],
            ],
            "code_review_rate_limit": [
                "primary_window": [
                    "used_percent": NSNull(), // null used_percent MUST be treated as absent!
                    "limit_window_seconds": 604_800,
                ],
                "secondary_window": [
                    "used_percent": 25.0,
                    "limit_window_seconds": 86_400,
                ],
            ],
        ]
        let parsed = CodexProvider.parseWhamUsageJSON(whamJSON, now: now)
        T.expectEqual(parsed.plan?.kind, .prolite)
        T.expectEqual(parsed.plan?.displayName, "Pro Lite")
        T.expectEqual(parsed.windows.count, 3, "null used_percent window must be omitted")
        // Sorted: 5h first (primary), then weekly, then extra code_review 1-day
        T.expectEqual(parsed.windows[0].id, "5h")
        T.expectEqual(parsed.windows[0].label, "5小时")
        T.expectEqual(parsed.windows[0].remainingPercent, 85)
        T.expectEqual(parsed.windows[0].isPrimary, true)

        T.expectEqual(parsed.windows[1].id, "weekly")
        T.expectEqual(parsed.windows[1].label, "本周")
        T.expectEqual(parsed.windows[1].remainingPercent, 60)

        T.expectEqual(parsed.windows[2].id, "code_review_window_86400")
        T.expectEqual(parsed.windows[2].remainingPercent, 75)

        // config.toml parser + fail-closed safety guards
        let toml = """
        # comment
        cli_auth_credentials_store = "auto"
        model_provider = "custom-proxy"
        [features]
        secret_auth_storage = true
        """
        let cfg = CodexProvider.parseConfigTOML(toml)
        T.expectEqual(cfg.storageMode, .auto)
        T.expectEqual(cfg.modelProvider, "custom-proxy")
        T.expectEqual(cfg.secretAuthStorage, true)

        let envBlocked = CodexProvider(
            keychain: KeychainStore(backend: InMemoryKeychainBackend()),
            processController: ProcessController(inspector: MockProcessInspector()),
            environment: ["OPENAI_API_KEY": "sk-override"]
        )
        T.expect(envBlocked.validatePreSwitchSafety() != nil, "OPENAI_API_KEY env override must fail closed")
    }

    await T.asyncSuite("CodexProvider.Active-Live Account NEVER Triggers Refresh") {
        let dir = try makeTempDir(prefix: "roryorbit-codex-live")
        defer { try? FileManager.default.removeItem(at: dir) }

        let codexHome = dir.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)

        // Expired live access_token (-3600s)
        let expiredAuth = makeCodexAuthJSONData(
            userId: "u-live",
            accountId: "acc-live",
            email: "live@example.com",
            accessExpOffset: -3600,
            refreshToken: "rt_precious_single_use"
        )
        try expiredAuth.write(to: codexHome.appendingPathComponent("auth.json"))

        StubURLProtocol.reset { req, _ in
            let d = Data("{}".utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, d)
        }

        let provider = CodexProvider(
            keychain: KeychainStore(backend: InMemoryKeychainBackend()),
            processController: ProcessController(inspector: MockProcessInspector()),
            environment: [:],
            homeDirectoryURL: dir,
            desktopAppURL: dir.appendingPathComponent("ChatGPT.app"),
            session: makeMockSession()
        )
        let acct = AccountRecord(id: "codex:u-live:acc-live", provider: .codex, email: "live@example.com", displayName: "Live", isActiveLive: true)
        // Even if caller mistakenly passed isActiveLive: false, re-check of live identity MUST protect it!
        let snap = await provider.fetchQuota(for: acct, isActiveLive: false)

        if case .reauthRequired = snap.status {
            T.expect(true, "expired live account returns reauthRequired")
        } else {
            T.expect(false, "expected .reauthRequired for expired live account, got \(snap.status)")
        }
        let oauthCalls = StubURLProtocol.snapshotRequests().filter { $0.request.url?.absoluteString.contains("/oauth/token") == true }
        T.expectEqual(oauthCalls.count, 0, "CRITICAL: active-live Codex account MUST make ZERO /oauth/token calls!")
    }

    await T.asyncSuite("CodexProvider.Inactive Account Refresh Rotation & Identity Guard") {
        let dir = try makeTempDir(prefix: "roryorbit-codex-inactive")
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = InMemoryKeychainBackend()
        let kc = KeychainStore(backend: backend)
        let expiredInactive = makeCodexAuthJSONData(
            userId: "u-bg",
            accountId: "acc-bg",
            email: "bg@example.com",
            planType: "prolite",
            accessExpOffset: -120,
            refreshToken: "rt_old_1"
        )
        try kc.writeChunkedSecret(service: KeychainStore.roryOrbitCodexService, account: "codex:u-bg:acc-bg", data: expiredInactive)

        let freshAccess = makeUnsignedJWT(payload: ["sub": "u-bg", "exp": Int(Date().timeIntervalSince1970 + 3600)])
        StubURLProtocol.reset { req, _ in
            let urlStr = req.url?.absoluteString ?? ""
            let resp: (Int, Any) -> (HTTPURLResponse, Data) = { code, obj in
                let d = try! JSONSerialization.data(withJSONObject: obj)
                return (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, d)
            }
            if urlStr.contains("/oauth/token") {
                return resp(200, ["access_token": freshAccess, "refresh_token": "rt_rotated_2"])
            }
            if urlStr.contains("/wham/usage") {
                return resp(200, [
                    "account_id": "acc-bg",
                    "user_id": "u-bg",
                    "plan_type": "prolite",
                    "rate_limit": [
                        "primary_window": ["used_percent": 10.0, "limit_window_seconds": 18_000],
                    ],
                ])
            }
            return resp(404, [:])
        }

        let provider = CodexProvider(
            keychain: kc,
            processController: ProcessController(inspector: MockProcessInspector()),
            environment: [:],
            homeDirectoryURL: dir,
            desktopAppURL: dir.appendingPathComponent("ChatGPT.app"),
            session: makeMockSession()
        )
        let acct = AccountRecord(id: "codex:u-bg:acc-bg", provider: .codex, email: "bg@example.com", displayName: "BG", isActiveLive: false)
        let snap = await provider.fetchQuota(for: acct, isActiveLive: false)
        T.expect(snap.status.isReady, "inactive expired account should refresh and fetch usage")
        T.expectEqual(snap.primaryRemainingPercent, 90)
        T.expectEqual(snap.plan?.kind, .prolite)

        // Verify rotated refresh_token persisted immediately to Keychain vault
        let persisted = try kc.readChunkedSecret(service: KeychainStore.roryOrbitCodexService, account: "codex:u-bg:acc-bg")!
        let persistedObj = try JSONSerialization.jsonObject(with: persisted) as! [String: Any]
        let persistedTokens = persistedObj["tokens"] as! [String: Any]
        T.expectEqual(persistedTokens["refresh_token"] as? String, "rt_rotated_2", "rotated refresh_token must be persisted to vault")
    }

    T.suite("CodexProjectSync.Merge Non-Cloud Projects & Rollback") {
        let dir = try makeTempDir(prefix: "roryorbit-proj-sync")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcId = CodexAuthIdentity(canonicalAccountId: "codex:uA:aA", userId: "uA", chatgptAccountId: "aA", email: "a@test", displayName: "A", plan: nil)
        let dstId = CodexAuthIdentity(canonicalAccountId: "codex:uB:aB", userId: "uB", chatgptAccountId: "aB", email: "b@test", displayName: "B", plan: nil)

        // 1. Clean no-op when .codex-global-state.json absent
        let noop1 = try CodexProjectSync.prepareAndApply(codexHomeURL: dir, from: srcId, to: dstId)
        T.expectEqual(noop1.applied, false)

        // 2. Clean no-op when electron-account-renderer-state-v1 absent
        let stateURL = dir.appendingPathComponent(".codex-global-state.json")
        try Data("{\"local-projects\":{}}".utf8).write(to: stateURL)
        let noop2 = try CodexProjectSync.prepareAndApply(codexHomeURL: dir, from: srcId, to: dstId)
        T.expectEqual(noop2.applied, false)

        // 3. Real multi-account merge preserving local projects, skipping cloud (g-p-* & chatGptBacking*), setting sidebar flags
        let srcKey = CodexProjectSync.ownerKey(userId: "uA", accountId: "aA")
        let dstKey = CodexProjectSync.ownerKey(userId: "uB", accountId: "aB")
        let hostKey = CodexProjectSync.localHostKey(codexHomeURL: dir)

        let multiState: [String: Any] = [
            "electron-renderer-content-owner": srcKey,
            "electron-account-renderer-state-v1": [
                srcKey: [
                    "local-projects": [
                        "proj-local-1": ["id": "proj-local-1", "name": "My Repo"],
                        "g-p-cloud-1": ["id": "g-p-cloud-1", "name": "Cloud Proj"],
                        "proj-backed": ["id": "proj-backed", "chatGptBackingId": "backing-99"],
                    ],
                    "thread-project-assignments": [
                        "th-1": "proj-local-1",
                        "th-cloud": "g-p-cloud-1",
                        "th-backed": "proj-backed",
                    ],
                    "project-order": ["proj-local-1", "g-p-cloud-1"],
                    "sidebar-project-thread-orders": [
                        "proj-local-1": ["th-1"],
                        "g-p-cloud-1": ["th-cloud"],
                    ],
                    "app-server-project-id-by-legacy-project-id-by-host": [
                        hostKey: [
                            "proj-local-1": "srv-proj-1",
                            "g-p-cloud-1": "srv-cloud-1",
                        ],
                    ],
                    "sidebar-collapsed-sections-v1": ["threads": true],
                    "sidebar-project-list-expanded-v1": false,
                ],
                dstKey: [
                    "local-projects": [
                        "proj-dst-existing": ["id": "proj-dst-existing", "name": "Existing"],
                    ],
                    "project-order": ["proj-dst-existing"],
                ],
            ],
        ]
        let originalBytes = try JSONSerialization.data(withJSONObject: multiState, options: [.sortedKeys])
        try originalBytes.write(to: stateURL)

        let handle = try CodexProjectSync.prepareAndApply(codexHomeURL: dir, from: srcId, to: dstId)
        T.expectEqual(handle.applied, true)
        T.expect(FileManager.default.fileExists(atPath: handle.backupURL.path), ".bak backup must exist")

        let mergedRoot = try JSONSerialization.jsonObject(with: try Data(contentsOf: stateURL)) as! [String: Any]
        let renderer = mergedRoot["electron-account-renderer-state-v1"] as! [String: Any]
        let dstState = renderer[dstKey] as! [String: Any]
        let dstProjects = dstState["local-projects"] as! [String: Any]
        T.expect(dstProjects["proj-local-1"] != nil, "non-cloud local project must be merged")
        T.expect(dstProjects["proj-dst-existing"] != nil, "existing target project must be preserved")
        T.expect(dstProjects["g-p-cloud-1"] == nil, "g-p-* cloud project MUST be skipped")
        T.expect(dstProjects["proj-backed"] == nil, "chatGptBacking* project MUST be skipped")

        let dstAssign = dstState["thread-project-assignments"] as! [String: Any]
        T.expectEqual(dstAssign["th-1"] as? String, "proj-local-1")
        T.expect(dstAssign["th-cloud"] == nil)
        T.expect(dstAssign["th-backed"] == nil)

        let dstOrder = dstState["project-order"] as! [String]
        T.expectEqual(dstOrder, ["proj-dst-existing", "proj-local-1"])

        let collapsed = dstState["sidebar-collapsed-sections-v1"] as! [String: Any]
        T.expectEqual(collapsed["threads"] as? Bool, false)
        T.expectEqual(dstState["sidebar-project-list-expanded-v1"] as? Bool, true)

        let migByHost = dstState["app-server-projects-migration-by-host"] as! [String: Any]
        let hostMig = migByHost[hostKey] as! [String: Any]
        T.expectEqual(hostMig["pending"] as? Bool, true)

        // 4. Rollback restores exact byte-for-byte original state
        try CodexProjectSync.rollback(handle)
        let restoredBytes = try Data(contentsOf: stateURL)
        T.expectEqual(restoredBytes, originalBytes, "rollback must restore exact original bytes")
    }
}

// MARK: - Test 7: Grok, Cursor, Kimi & DeepSeek Providers

private func encodeVarint(_ value: UInt64) -> [UInt8] {
    var v = value
    var out: [UInt8] = []
    while true {
        if v < 0x80 {
            out.append(UInt8(v))
            break
        }
        out.append(UInt8((v & 0x7F) | 0x80))
        v >>= 7
    }
    return out
}

private func pbLengthDelimited(field: UInt64, payload: [UInt8]) -> [UInt8] {
    var out = encodeVarint((field << 3) | 2)
    out.append(contentsOf: encodeVarint(UInt64(payload.count)))
    out.append(contentsOf: payload)
    return out
}

private func pbFixed32(field: UInt64, value: Float) -> [UInt8] {
    var out = encodeVarint((field << 3) | 5)
    let bits = value.bitPattern
    out.append(UInt8(bits & 0xFF))
    out.append(UInt8((bits >> 8) & 0xFF))
    out.append(UInt8((bits >> 16) & 0xFF))
    out.append(UInt8((bits >> 24) & 0xFF))
    return out
}

private func pbVarint(field: UInt64, value: UInt64) -> [UInt8] {
    encodeVarint((field << 3) | 0) + encodeVarint(value)
}

private func grpcWebFrame(flags: UInt8, body: [UInt8]) -> Data {
    let len = UInt32(body.count)
    var out: [UInt8] = [
        flags,
        UInt8((len >> 24) & 0xFF),
        UInt8((len >> 16) & 0xFF),
        UInt8((len >> 8) & 0xFF),
        UInt8(len & 0xFF),
    ]
    out.append(contentsOf: body)
    return Data(out)
}

private func encryptCursorSafeStorageVector(plaintext: String, password: String) -> String {
    let pwdBytes = Array(password.utf8)
    let saltBytes = Array("saltysalt".utf8)
    var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
    let rc = pwdBytes.withUnsafeBytes { pRaw -> Int32 in
        saltBytes.withUnsafeBytes { sRaw -> Int32 in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pRaw.bindMemory(to: Int8.self).baseAddress,
                pwdBytes.count,
                sRaw.bindMemory(to: UInt8.self).baseAddress,
                saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1003,
                &key,
                key.count
            )
        }
    }
    precondition(rc == kCCSuccess)

    let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
    let plainBytes = Array(plaintext.utf8)
    var outBuf = [UInt8](repeating: 0, count: plainBytes.count + kCCBlockSizeAES128)
    var encLen: size_t = 0
    let cRC = CCCrypt(
        CCOperation(kCCEncrypt),
        CCAlgorithm(kCCAlgorithmAES),
        CCOptions(kCCOptionPKCS7Padding),
        key,
        key.count,
        iv,
        plainBytes,
        plainBytes.count,
        &outBuf,
        outBuf.count,
        &encLen
    )
    precondition(cRC == kCCSuccess)

    var wrapped = Data("v10".utf8)
    wrapped.append(contentsOf: outBuf[0..<encLen])
    return CursorProvider.safeStoragePrefix + wrapped.base64EncodedString()
}

private func testQuotaProviders() async {
    T.suite("GrokProvider.Auth & gRPC-Web Protobuf Decoding") {
        let authJSON = Data("""
        {
          "https://auth.x.ai::uuid-123": {
            "key": "grok_tok_abc",
            "email": "dev@example.com",
            "first_name": "Alex",
            "last_name": "W",
            "auth_mode": "oidc",
            "coding_data_team": "personal",
            "expires_at": "2027-01-01T00:00:00Z"
          }
        }
        """.utf8)
        let entry = try GrokProvider.parseAuthJSON(authJSON)
        T.expectEqual(entry?.email, "dev@example.com")
        T.expectEqual(entry?.displayName, "Alex W")
        T.expectEqual(entry?.resolvedPlan.displayName, "SuperGrok")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetTS: UInt64 = 1_800_500_000
        // Build nested protobuf matching path [1, 1] float=27.5% used and path [1, 5, 1] varint=resetTS
        let tsMsg = pbVarint(field: 1, value: resetTS)
        let inner1 = pbFixed32(field: 1, value: 27.5) + pbLengthDelimited(field: 5, payload: tsMsg)
        let outer = pbLengthDelimited(field: 1, payload: inner1)
        var framed = grpcWebFrame(flags: 0x00, body: outer)
        framed.append(grpcWebFrame(flags: 0x80, body: Array("grpc-status: 0\r\n".utf8)))

        let parsed = GrokProvider.parseGRPCWebResponse(framed, now: now)
        if case .success(let billing) = parsed {
            T.expect(abs(billing.usedPercent - 27.5) < 0.01)
            T.expectEqual(Int(billing.resetAt?.timeIntervalSince1970 ?? 0), Int(resetTS))
            T.expect(abs(billing.remainingFraction - 0.725) < 0.001)
        } else {
            T.expect(false, "expected gRPC-web parse success, got \(parsed)")
        }

        // Proto3 omitted 0% used (only reset timestamp present)
        let zeroInner = pbLengthDelimited(field: 5, payload: tsMsg)
        let zeroOuter = pbLengthDelimited(field: 1, payload: zeroInner)
        let zeroParsed = GrokProvider.parseGRPCWebResponse(grpcWebFrame(flags: 0x00, body: zeroOuter), now: now)
        if case .success(let zeroBilling) = zeroParsed {
            T.expectEqual(zeroBilling.usedPercent, 0.0)
            T.expectEqual(zeroBilling.remainingFraction, 1.0)
        } else {
            T.expect(false, "expected 0% omitted proto3 success")
        }

        // gRPC status 16 in trailer -> .authRequired
        let unauth = GrokProvider.parseGRPCWebResponse(grpcWebFrame(flags: 0x80, body: Array("grpc-status: 16\r\n".utf8)), now: now)
        T.expectEqual(unauth, .authRequired)
    }

    T.suite("CursorProvider.SafeStorage AES-128-CBC, SQLite3 & Usage Parsers") {
        let jwt = makeUnsignedJWT(payload: ["sub": "auth0|user_42", "exp": 1_900_000_000])
        let password = "mock-cursor-safe-storage-pwd"
        let encrypted = encryptCursorSafeStorageVector(plaintext: jwt, password: password)

        T.expectEqual(CursorProvider.decryptSafeStorageToken(encrypted, password: password), jwt, "AES-128-CBC round-trip must recover exact JWT")
        T.expectEqual(CursorProvider.decryptSafeStorageToken(encrypted, password: "wrong-password"), nil, "wrong password must fail cleanly")
        T.expectEqual(CursorProvider.extractUserId(fromSubject: "auth0|user_42"), "user_42")

        // Synthetic SQLite state.vscdb read-only test
        let dir = try makeTempDir(prefix: "roryorbit-cursor")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("state.vscdb")

        var db: OpaquePointer?
        T.expectEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        let ddl = """
        CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO ItemTable VALUES ('cursorAuth/cachedEmail', 'user@cursor.test');
        INSERT INTO ItemTable VALUES ('cursorAuth/stripeMembershipType', 'ultra');
        INSERT INTO ItemTable VALUES ('cursorAuth/stripeSubscriptionStatus', 'active');
        INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(encrypted)');
        """
        T.expectEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let cursorProvider = CursorProvider(
            keychain: KeychainStore(backend: InMemoryKeychainBackend()),
            stateDBURL: dbURL,
            allowInteractiveKeychain: false
        )
        let localState = cursorProvider.readLocalState()
        T.expectEqual(localState?.cachedEmail, "user@cursor.test")
        T.expectEqual(localState?.resolvedPlan?.kind, .ultra)
        T.expectEqual(localState?.rawAccessToken, encrypted)

        // parseUsageSummaryJSON
        let summaryData = Data("""
        {
          "membershipType": "ultra",
          "billingCycleStart": "2026-11-01T00:00:00Z",
          "billingCycleEnd": "2026-12-01T00:00:00Z",
          "individualUsage": {
            "plan": { "used": 2500, "limit": 10000, "totalPercentUsed": 25.0, "autoPercentUsed": 10.0, "apiPercentUsed": 15.0 },
            "onDemand": { "enabled": true, "used": 500, "limit": 5000 }
          }
        }
        """.utf8)
        let parsedSummary = CursorProvider.parseUsageSummaryJSON(summaryData)
        T.expectEqual(parsedSummary?.plan?.kind, .ultra)
        T.expectEqual(parsedSummary?.windows.count, 2)
        T.expectEqual(parsedSummary?.windows[0].remainingPercent, 75)
        T.expectEqual(parsedSummary?.windows[1].remainingPercent, 90)
    }

    T.suite("CursorProvider.Rich Multi-Lane (Ultra, Sand/Grok Bot, On-Demand, Team, Unified & Legacy)") {
        // 1. Live-shaped Ultra usage-summary (includeSubLanes: true) + Sand/Grok Bot + mergeUsageResults
        let ultraSummaryData = Data("""
        {
          "membershipType": "ultra",
          "billingCycleStart": "2026-11-11T17:24:35Z",
          "billingCycleEnd": "2026-12-11T17:24:35Z",
          "individualUsage": {
            "plan": {
              "used": 3617,
              "limit": 40000,
              "remaining": 36383,
              "breakdown": { "included": 3617, "bonus": 500, "total": 4117 },
              "totalPercentUsed": 1.167,
              "autoPercentUsed": 1.152,
              "apiPercentUsed": 1.61
            },
            "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
          }
        }
        """.utf8)
        let ultraParsed = CursorProvider.parseUsageSummaryJSON(ultraSummaryData, includeSubLanes: true)
        T.expect(ultraParsed != nil, "live-shaped Ultra summary must parse")
        T.expectEqual(ultraParsed?.plan?.kind, .ultra)
        T.expectEqual(ultraParsed?.windows.map(\.id), ["cursor-plan", "cursor-auto", "cursor-api"])
        T.expectEqual(ultraParsed?.windows[0].label, "套餐总览")
        T.expectEqual(ultraParsed?.windows[0].isPrimary, true)
        T.expectEqual(ultraParsed?.windows[0].remainingPercent, 99)
        T.expect(ultraParsed?.windows[0].detail?.contains("$36.17 / $400.00") == true)
        T.expect(ultraParsed?.windows[0].detail?.contains("剩余 $363.83") == true)
        T.expect(ultraParsed?.windows[0].detail?.contains("赠金 $5.00") == true)
        T.expectEqual(ultraParsed?.windows[1].label, "Auto + Composer")
        T.expectEqual(ultraParsed?.windows[1].remainingPercent, 99)
        T.expectEqual(ultraParsed?.windows[2].label, "API / 指定模型")
        T.expectEqual(ultraParsed?.windows[2].remainingPercent, 98)

        // Supplementary BalanceInfo + billing cycle / on-demand paceNote
        T.expectEqual(ultraParsed?.balance?.currency, "USD")
        T.expect(abs((ultraParsed?.balance?.totalBalance ?? 0) - 363.83) < 0.001)
        T.expect(abs((ultraParsed?.balance?.grantedBalance ?? 0) - 5.0) < 0.001)
        T.expect(ultraParsed?.balance?.detail?.contains("已用 $36.17 / $400.00") == true)
        T.expect(ultraParsed?.balance?.detail?.contains("按量未开启") == true)
        T.expect(ultraParsed?.paceNote?.contains("账单周期") == true)
        T.expect(ultraParsed?.paceNote?.contains("按量付费: 未开启 ($0.00)") == true)

        // 2. Sand / Grok Bot parser (valid + zero-limit guards)
        let sandData = Data("""
        {
          "usagePercent": 4.020505,
          "currentPeriodStart": "2026-11-17T20:09:21.838Z",
          "nextResetTimestampUtc": "2026-11-24T20:09:21.838Z",
          "grokPlanLabel": "Grok Bot Plan",
          "hasNonZeroIncludedLimit": true
        }
        """.utf8)
        let sandParsed = CursorProvider.parseSandUsageJSON(sandData)
        T.expect(sandParsed != nil, "valid Sand/Grok Bot payload must parse")
        T.expectEqual(sandParsed?.window.id, "cursor-grok-bot")
        T.expectEqual(sandParsed?.window.label, "Grok Bot")
        T.expectEqual(sandParsed?.window.remainingPercent, 96)
        T.expectEqual(sandParsed?.window.windowSeconds, 604_800)
        T.expect(sandParsed?.window.detail?.contains("Grok Bot Plan") == true)

        let sandZeroLimit = Data("""
        { "usagePercent": 0.0, "includedLimitZero": true, "hasNonZeroIncludedLimit": false }
        """.utf8)
        T.expectEqual(CursorProvider.parseSandUsageJSON(sandZeroLimit), nil, "includedLimitZero must return nil")

        // Merge Ultra summary + Sand -> 4 lanes
        let mergedUltra = CursorProvider.mergeUsageResults(
            summary: ultraParsed!,
            sand: sandParsed,
            unified: nil,
            legacy: nil,
            fallbackPlan: nil
        )
        T.expectEqual(mergedUltra.windows.map(\.id), ["cursor-plan", "cursor-auto", "cursor-api", "cursor-grok-bot"])
        T.expectEqual(mergedUltra.balance?.totalBalance, ultraParsed?.balance?.totalBalance)
        T.expectEqual(mergedUltra.paceNote, ultraParsed?.paceNote)

        // 3. On-Demand enabled (capped + uncapped) & Team pooled + Team on-demand + distinct overall
        let teamAndOnDemandData = Data("""
        {
          "membershipType": "business",
          "billingCycleStart": "2026-11-01T00:00:00Z",
          "billingCycleEnd": "2026-12-01T00:00:00Z",
          "individualUsage": {
            "plan": { "used": 1000, "limit": 2000, "totalPercentUsed": 50.0, "autoPercentUsed": 30.0, "apiPercentUsed": 60.0 },
            "overall": { "enabled": true, "used": 1500, "limit": 5000, "remaining": 3500 },
            "onDemand": { "enabled": true, "used": 500, "limit": 3000, "remaining": 2500 }
          },
          "teamUsage": {
            "pooled": { "enabled": true, "used": 12000, "limit": 50000, "remaining": 38000 },
            "onDemand": { "enabled": true, "used": 2500, "limit": 10000, "remaining": 7500 }
          }
        }
        """.utf8)
        let teamParsed = CursorProvider.parseUsageSummaryJSON(teamAndOnDemandData, includeSubLanes: true)
        T.expectEqual(teamParsed?.plan?.kind, .business)
        T.expectEqual(
            teamParsed?.windows.map(\.id),
            ["cursor-plan", "cursor-auto", "cursor-api", "cursor-overall", "cursor-ondemand", "cursor-team-pooled", "cursor-team-ondemand"]
        )
        T.expectEqual(teamParsed?.windows.first(where: { $0.id == "cursor-ondemand" })?.remainingPercent, 83)
        T.expectEqual(teamParsed?.windows.first(where: { $0.id == "cursor-team-pooled" })?.remainingPercent, 76)
        T.expectEqual(teamParsed?.windows.first(where: { $0.id == "cursor-team-ondemand" })?.remainingPercent, 75)
        T.expect(teamParsed?.balance?.detail?.contains("按量 $5.00 / $30.00") == true)

        // Uncapped On-Demand enabled
        let uncappedODData = Data("""
        {
          "membershipType": "pro",
          "individualUsage": {
            "plan": { "used": 2000, "limit": 2000, "totalPercentUsed": 100.0 },
            "onDemand": { "enabled": true, "used": 1234, "limit": null }
          }
        }
        """.utf8)
        let uncappedOD = CursorProvider.parseUsageSummaryJSON(uncappedODData, includeSubLanes: true)
        T.expect(uncappedOD?.paceNote?.contains("按量已用 $12.34 (无上限)") == true)
        T.expect(uncappedOD?.balance?.detail?.contains("按量已用 $12.34") == true)

        // 4. Unified v2 usage-status parser (available vs missing_team_id)
        let unifiedUnavailable = Data("""
        { "availability": "missing_team_id" }
        """.utf8)
        T.expectEqual(CursorProvider.parseUnifiedUsageJSON(unifiedUnavailable), nil)

        let unifiedAvailable = Data("""
        {
          "availability": "available",
          "monthlyUsage": {
            "usedCents": 1250,
            "limitCents": 5000,
            "periodStart": "2026-11-01T00:00:00Z",
            "resetsAt": "2026-12-01T00:00:00Z"
          }
        }
        """.utf8)
        let unifiedParsed = CursorProvider.parseUnifiedUsageJSON(unifiedAvailable)
        T.expect(unifiedParsed != nil, "available unified usage must parse")
        T.expectEqual(unifiedParsed?.window.id, "cursor-unified")
        T.expectEqual(unifiedParsed?.window.remainingPercent, 75)
        T.expect(abs((unifiedParsed?.remainingUSD ?? 0) - 37.5) < 0.001)

        // 5. Legacy /api/usage parser
        let legacyData = Data("""
        {
          "startOfMonth": "2026-11-01T00:00:00Z",
          "gpt-4": { "numRequests": 125, "maxRequestUsage": 500 }
        }
        """.utf8)
        let legacyParsed = CursorProvider.parseLegacyUsageJSON(legacyData, fallbackPlan: PlanInfo(kind: .pro, displayName: "Pro"))
        T.expectEqual(legacyParsed?.windows.count, 1)
        T.expectEqual(legacyParsed?.windows[0].id, "cursor-legacy-requests")
        T.expectEqual(legacyParsed?.windows[0].remainingPercent, 75)
        T.expectEqual(legacyParsed?.windows[0].detail, "125 / 500 次 (gpt-4)")
    }

    await T.asyncSuite("CursorProvider.E2E FetchQuota (Ultra 4-Lane, Unified Fallback & Legacy Fallback)") {
        let dir = try makeTempDir(prefix: "roryorbit-cursor-e2e")
        defer { try? FileManager.default.removeItem(at: dir) }

        let jwt = makeUnsignedJWT(payload: ["sub": "auth0|user_e2e_99", "exp": 1_900_000_000])
        let password = "e2e-safe-storage-secret"
        let encrypted = encryptCursorSafeStorageVector(plaintext: jwt, password: password)

        let dbURL = dir.appendingPathComponent("state.vscdb")
        var db: OpaquePointer?
        T.expectEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        let ddl = """
        CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO ItemTable VALUES ('cursorAuth/cachedEmail', 'ultra@cursor.test');
        INSERT INTO ItemTable VALUES ('cursorAuth/stripeMembershipType', 'ultra');
        INSERT INTO ItemTable VALUES ('cursorAuth/stripeSubscriptionStatus', 'active');
        INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(encrypted)');
        """
        T.expectEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let backend = InMemoryKeychainBackend()
        let kc = KeychainStore(backend: backend)
        try kc.writeExternalGenericPassword(service: "Cursor Safe Storage", account: "Cursor Key", value: password)

        let acct = AccountRecord(id: CursorProvider.defaultAccountId, provider: .cursor, email: "ultra@cursor.test", displayName: "ultra@cursor.test")

        // Scenario A: Live-shaped Ultra 4-endpoint concurrent fetch
        StubURLProtocol.reset { req, _ in
            let urlStr = req.url?.absoluteString ?? ""
            let resp: (Int, String) -> (HTTPURLResponse, Data) = { code, json in
                (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            if urlStr.contains("/api/usage-summary") {
                return resp(200, """
                {
                  "membershipType": "ultra",
                  "billingCycleStart": "2026-11-11T17:24:35Z",
                  "billingCycleEnd": "2026-12-11T17:24:35Z",
                  "individualUsage": {
                    "plan": { "used": 3617, "limit": 40000, "remaining": 36383, "totalPercentUsed": 1.167, "autoPercentUsed": 1.152, "apiPercentUsed": 1.61 },
                    "onDemand": { "enabled": false, "used": 0, "limit": null }
                  }
                }
                """)
            }
            if urlStr.contains("/get-sand-usage-status") {
                return resp(200, """
                {
                  "usagePercent": 4.02,
                  "currentPeriodStart": "2026-11-17T20:09:21.838Z",
                  "nextResetTimestampUtc": "2026-11-24T20:09:21.838Z",
                  "grokPlanLabel": "Grok Bot Plan",
                  "hasNonZeroIncludedLimit": true
                }
                """)
            }
            if urlStr.contains("/v2/usage-status") {
                return resp(200, "{\"availability\":\"missing_team_id\"}")
            }
            if urlStr.contains("/api/usage?") {
                return resp(200, "{\"gpt-4\":{\"numRequests\":12,\"maxRequestUsage\":null}}")
            }
            return resp(404, "{}")
        }

        let provider = CursorProvider(keychain: kc, stateDBURL: dbURL, session: makeMockSession(), allowInteractiveKeychain: false)
        let ultraSnap = await provider.fetchQuota(for: acct, isActiveLive: true)
        T.expect(ultraSnap.status.isReady, "Ultra E2E fetchQuota must succeed")
        T.expectEqual(ultraSnap.plan?.kind, .ultra)
        T.expectEqual(ultraSnap.windows.map(\.id), ["cursor-plan", "cursor-auto", "cursor-api", "cursor-grok-bot"])
        T.expectEqual(ultraSnap.primaryRemainingPercent, 99)
        T.expect(abs((ultraSnap.balance?.totalBalance ?? 0) - 363.83) < 0.001)

        // Scenario B: usage-summary returns 500 -> Unified v2 fallback promotes cursor-unified to primary
        StubURLProtocol.reset { req, _ in
            let urlStr = req.url?.absoluteString ?? ""
            let resp: (Int, String) -> (HTTPURLResponse, Data) = { code, json in
                (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            if urlStr.contains("/api/usage-summary") { return resp(500, "{}") }
            if urlStr.contains("/get-sand-usage-status") { return resp(404, "{}") }
            if urlStr.contains("/v2/usage-status") {
                return resp(200, "{\"availability\":\"available\",\"monthlyUsage\":{\"usedCents\":1000,\"limitCents\":4000,\"periodStart\":\"2026-11-01T00:00:00Z\",\"resetsAt\":\"2026-12-01T00:00:00Z\"}}")
            }
            return resp(404, "{}")
        }
        let unifiedSnap = await provider.fetchQuota(for: acct, isActiveLive: true)
        T.expect(unifiedSnap.status.isReady, "Unified fallback must recover when usage-summary fails")
        T.expectEqual(unifiedSnap.windows.map(\.id), ["cursor-unified"])
        T.expectEqual(unifiedSnap.windows[0].isPrimary, true)
        T.expectEqual(unifiedSnap.primaryRemainingPercent, 75)
        T.expect(abs((unifiedSnap.balance?.totalBalance ?? 0) - 30.0) < 0.001)

        // Scenario C: usage-summary & unified fail -> Legacy /api/usage fallback succeeds
        StubURLProtocol.reset { req, _ in
            let urlStr = req.url?.absoluteString ?? ""
            let resp: (Int, String) -> (HTTPURLResponse, Data) = { code, json in
                (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            if urlStr.contains("/api/usage?") {
                return resp(200, "{\"startOfMonth\":\"2026-11-01T00:00:00Z\",\"gpt-4\":{\"numRequests\":100,\"maxRequestUsage\":500}}")
            }
            return resp(500, "{}")
        }
        let legacySnap = await provider.fetchQuota(for: acct, isActiveLive: true)
        T.expect(legacySnap.status.isReady, "Legacy fallback must recover when summary & unified fail")
        T.expectEqual(legacySnap.windows.map(\.id), ["cursor-legacy-requests"])
        T.expectEqual(legacySnap.windows[0].isPrimary, true)
        T.expectEqual(legacySnap.primaryRemainingPercent, 80)
        T.expectEqual(legacySnap.sourceLabel, "Cursor Usage API")
    }

    T.suite("KimiProvider.Limits/Usage Parsing & Endpoint Resolution") {
        let kimiJSON = Data("""
        {
          "user": { "region": "REGION_CN", "membership": { "level": "LEVEL_ADVANCED" } },
          "usage": { "limit": "100", "used": "22", "remaining": "78", "resetTime": "2026-11-27T00:00:00Z" },
          "limits": [
            {
              "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
              "detail": { "limit": "100", "remaining": "64", "resetTime": "2026-11-21T05:00:00Z" }
            }
          ]
        }
        """.utf8)
        let parsed = KimiProvider.parseUsageJSON(kimiJSON)
        T.expect(parsed != nil)
        T.expectEqual(parsed?.plan?.kind, .max)
        T.expectEqual(parsed?.plan?.displayName, "Allegretto")
        T.expectEqual(parsed?.windows.count, 2)
        T.expectEqual(parsed?.windows[0].label, "每周额度")
        T.expectEqual(parsed?.windows[0].remainingPercent, 78)
        T.expectEqual(parsed?.windows[0].isPrimary, true)
        T.expectEqual(parsed?.windows[1].label, "5小时限额")
        T.expectEqual(parsed?.windows[1].windowSeconds, 18_000)
        T.expectEqual(parsed?.windows[1].remainingPercent, 64)

        T.expectEqual(KimiProvider.normalizeUsagesURL(from: "https://api.kimi.ai")?.absoluteString, "https://api.kimi.ai/coding/v1/usages")
        T.expectEqual(KimiProvider.normalizeUsagesURL(from: "https://api.kimi.com/coding/v1")?.absoluteString, "https://api.kimi.com/coding/v1/usages")

        // Plural `usages` object (`limit_month_total` + `limit_5h` with ~1.4s resetTime drift vs `limits[0]`)
        let kimiPluralJSON = Data("""
        {
          "usages": {
            "limit_month_total": { "used_ratio": 1.0, "reset_time": "2026-12-01T00:00:00Z" },
            "limit_5h": { "used_ratio": 0.0, "reset_time": "2026-11-21T07:15:40.000Z" }
          },
          "limits": [
            {
              "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
              "detail": { "limit": "100", "remaining": "100", "resetTime": "2026-11-21T07:15:41.400Z" }
            }
          ]
        }
        """.utf8)
        let parsedPlural = KimiProvider.parseUsageJSON(kimiPluralJSON)
        T.expect(parsedPlural != nil, "plural Kimi usages JSON must parse")
        T.expectEqual(parsedPlural?.windows.map(\.id), ["kimi-monthly", "kimi-limit-18000"], "must emit deduplicated kimi-monthly + 5h")
        T.expectEqual(parsedPlural?.windows.first(where: { $0.id == "kimi-monthly" })?.remainingPercent, 0)
        T.expectEqual(parsedPlural?.windows.first(where: { $0.id == "kimi-monthly" })?.computedUsedPercent, 100.0)
        T.expectEqual(parsedPlural?.windows.first(where: { $0.id == "kimi-limit-18000" })?.remainingPercent, 100)
    }

    T.suite("DeepSeekProvider.CNY/USD Balance Parsing") {
        let dualJSON = Data("""
        {
          "is_available": true,
          "balance_infos": [
            { "currency": "USD", "total_balance": "3.50", "granted_balance": "0.00", "topped_up_balance": "3.50" },
            { "currency": "CNY", "total_balance": "88.40", "granted_balance": "8.40", "topped_up_balance": "80.00" }
          ]
        }
        """.utf8)
        let dual = DeepSeekProvider.parseBalanceJSON(dualJSON)
        T.expectEqual(dual?.isAvailable, true)
        T.expectEqual(dual?.primaryBalance.currency, "CNY", "prefer positive CNY as primary")
        T.expectEqual(dual?.primaryBalance.formattedTotal, "¥88.40")
        T.expect(dual?.primaryBalance.detail?.contains("$3.50") == true, "must surface secondary USD balance")

        let usdOnlyJSON = Data("""
        {
          "is_available": true,
          "balance_infos": [
            { "currency": "CNY", "total_balance": "0.00", "granted_balance": "0.00", "topped_up_balance": "0.00" },
            { "currency": "USD", "total_balance": "12.00", "granted_balance": "2.00", "topped_up_balance": "10.00" }
          ]
        }
        """.utf8)
        let usd = DeepSeekProvider.parseBalanceJSON(usdOnlyJSON)
        T.expectEqual(usd?.primaryBalance.currency, "USD", "prefer positive USD when CNY is 0")
        T.expectEqual(usd?.primaryBalance.formattedTotal, "$12.00")

        let unavailJSON = Data("""
        { "is_available": false, "balance_infos": [] }
        """.utf8)
        let unavail = DeepSeekProvider.parseBalanceJSON(unavailJSON)
        T.expectEqual(unavail?.isAvailable, false)
        T.expectEqual(unavail?.primaryBalance.totalBalance, 0.0)
    }
}

// MARK: - Test 8: TokenFormatters & TokenUsageModels

private func testTokenFormattersAndModels() {
    T.suite("TokenFormatters.compactTokens, exactTokens, usd & percent") {
        T.expectEqual(TokenFormatters.compactTokens(0), "0")
        T.expectEqual(TokenFormatters.compactTokens(999), "999")
        T.expectEqual(TokenFormatters.compactTokens(1_000), "1.00K")
        T.expectEqual(TokenFormatters.compactTokens(1_550), "1.55K")
        T.expectEqual(TokenFormatters.compactTokens(12_340), "12.3K")
        T.expectEqual(TokenFormatters.compactTokens(1_260_000), "1.3M")
        T.expectEqual(TokenFormatters.compactTokens(123_000_000), "123M")
        T.expectEqual(TokenFormatters.compactTokens(2_345_000_000), "2.35B")
        T.expectEqual(TokenFormatters.compactTokens(-1_500), "-1.50K")

        T.expectEqual(TokenFormatters.exactTokens(0), "0")
        T.expectEqual(TokenFormatters.exactTokens(1_234_567), "1,234,567")

        T.expectEqual(TokenFormatters.usd(0.0), "$0.00")
        T.expectEqual(TokenFormatters.usd(0.0042), "$0.0042")
        T.expectEqual(TokenFormatters.usd(43.24), "$43.24")
        T.expectEqual(TokenFormatters.usd(1_234.56), "$1,234.56")
        T.expectEqual(TokenFormatters.usd(-5.0), "$0.00")
        T.expectEqual(TokenFormatters.usd(.nan), "$0.00")
        T.expectEqual(TokenFormatters.usd(.infinity), "$0.00")

        T.expectEqual(TokenFormatters.percent(0.0), "0.0%")
        T.expectEqual(TokenFormatters.percent(0.885), "88.5%")
        T.expectEqual(TokenFormatters.percent(1.0), "100.0%")
        T.expectEqual(TokenFormatters.percent(1.5), "100.0%")
        T.expectEqual(TokenFormatters.percent(-0.2), "0.0%")
        T.expectEqual(TokenFormatters.percent(.nan), "0.0%")
    }

    T.suite("TokenUsageModels.CanonicalClient, ComponentInvariants & SanitizeModelId") {
        T.expectEqual(TokenClientID.canonical("claude-code"), .claude)
        T.expectEqual(TokenClientID.canonical("openai-codex"), .codex)
        T.expectEqual(TokenClientID.canonical("agy"), .antigravity)
        T.expectEqual(TokenClientID.canonical("kimi-code"), .kimi)
        T.expectEqual(TokenClientID.canonical("deepseek-harness"), .dsh)
        T.expectEqual(TokenClientID.canonical("codebuddy"), .workbuddy)
        T.expectEqual(TokenClientID.canonical("unknown-tool"), .other)

        let totals = TokenComponentTotals(
            totalTokens: 100, // intentionally smaller than component sum -> clamped up
            uncachedInputTokens: 200,
            outputTokens: 100,
            cacheReadTokens: 600,
            cacheWriteTokens: 100,
            reasoningTokens: 250, // intentionally > outputTokens -> clamped to outputTokens
            estimatedCostUSD: 1.25,
            messageCount: 3
        )
        T.expectEqual(totals.totalTokens, 1000)
        T.expectEqual(totals.uncachedInputTokens, 200)
        T.expectEqual(totals.totalInputTokens, 900)
        T.expectEqual(totals.reasoningTokens, 100, "reasoningTokens must not exceed outputTokens")
        T.expect(abs(totals.cacheHitRate - (600.0 / 900.0)) < 0.0001)

        T.expectEqual(TokenUsageEngine.sanitizeModelId("gpt-6-codex"), "gpt-6-codex")
        T.expectEqual(TokenUsageEngine.sanitizeModelId("/etc/passwd"), "unknown-model")
        T.expectEqual(TokenUsageEngine.sanitizeModelId("https://evil.example/m"), "unknown-model")
        T.expectEqual(TokenUsageEngine.sanitizeModelId("sk-secret-key"), "unknown-model")
        T.expectEqual(TokenUsageEngine.sanitizeModelId("user@example.com"), "unknown-model")
    }
}

// MARK: - Test 9: TokenUsageEngine (Seed Overlay, Scanners, max(seed, live), Invariants & 0600)

private func posixPermissions(at url: URL) throws -> Int? {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs[.posixPermissions] as? NSNumber)?.intValue
}

private func testTokenUsageEngine() async {
    let fixedNow = Formatters.parseRFC3339("2026-11-21T04:00:00Z")! // 2026-11-21 12:00 Asia/Shanghai

    await T.asyncSuite("TokenUsageEngine.Seed Merge (days + selectedCalendars Override) & 0600") {
        let dir = try makeTempDir(prefix: "roryorbit-usage-seed")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fakeHome = dir.appendingPathComponent("home", isDirectory: true)
        let fakeSupport = dir.appendingPathComponent("support", isDirectory: true)
        let backupDir = fakeHome.appendingPathComponent("Library/Application Support/Token Monitor", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let calendarsSeed: [String: Any] = [
            "days": [
                "2026-11-18": [
                    "activeTimeMs": 120_000,
                    "observations": [
                        "[\"cursor\",\"gpt-5\"]": [
                            "client": "cursor",
                            "modelId": "gpt-5",
                            "tokens": 1000,
                            "outputTokens": 200,
                            "cacheReadTokens": 300,
                            "cacheWriteTokens": 100,
                            "cost": 0.5,
                            "messages": 2,
                        ],
                    ],
                ],
                "2026-11-19": [
                    "activeTimeMs": 60_000,
                    "observations": [
                        "[\"codex\",\"gpt-5\"]": [
                            "client": "codex",
                            "modelId": "gpt-5",
                            "tokens": 500, // MUST be overridden by selectedCalendars["2026-11-19"]
                            "outputTokens": 100,
                            "cacheReadTokens": 100,
                            "cacheWriteTokens": 0,
                            "cost": 0.25,
                            "messages": 1,
                        ],
                    ],
                ],
            ],
            "selectedCalendars": [
                "2026-11-19": "Asia/Shanghai",
                "2026-11-20": "Asia/Shanghai",
            ],
            "calendars": [
                "Asia/Shanghai": [
                    "days": [
                        "2026-11-19": [
                            "activeTimeMs": 240_000,
                            "observations": [
                                "[\"codex\",\"gpt-5\"]": [
                                    "client": "codex",
                                    "modelId": "gpt-5",
                                    "tokens": 2000,
                                    "outputTokens": 400,
                                    "cacheReadTokens": 800,
                                    "cacheWriteTokens": 100,
                                    "cost": 1.0,
                                    "messages": 4,
                                ],
                            ],
                        ],
                        "2026-11-20": [
                            "activeTimeMs": 300_000,
                            "observations": [
                                "[\"claude\",\"claude-sonnet-4\"]": [
                                    "client": "claude",
                                    "modelId": "claude-sonnet-4",
                                    "tokens": 3000,
                                    "outputTokens": 500,
                                    "cacheReadTokens": 1500,
                                    "cacheWriteTokens": 200,
                                    "cost": 1.5,
                                    "messages": 3,
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let seedBytes = try JSONSerialization.data(withJSONObject: calendarsSeed, options: [.sortedKeys])
        try seedBytes.write(to: backupDir.appendingPathComponent("daily-history-calendars.json"))

        let engine = TokenUsageEngine(homeDirectoryURL: fakeHome, appSupportURL: fakeSupport)
        let snap = await engine.scanAndExportArchive(forceFullRescan: true, now: fixedNow)

        T.expectEqual(snap.seedDaysCount, 3, "must merge top-level days + selectedCalendars days")
        T.expectEqual(snap.totalDaysCount, 3)
        let allSummary = snap.summary(for: .allTime)
        T.expectEqual(allSummary.totals.totalTokens, 6000, "1000 + overridden 2000 + 3000 = 6000")
        let day19 = snap.allDays.first { $0.date == "2026-11-19" }
        T.expectEqual(day19?.totals.totalTokens, 2000, "selectedCalendars must override top-level days[date]")
        T.expectEqual(day19?.activeTimeMs, 240_000)

        // All 4 persisted files must exist with strict 0600 permissions
        for filename in ["daily-history-archive.json", "token-history-seed.json", "token-scan-cache.json", "token-usage-snapshot.json"] {
            let fileURL = fakeSupport.appendingPathComponent(filename)
            T.expect(FileManager.default.fileExists(atPath: fileURL.path), "\(filename) must exist")
            T.expectEqual(try posixPermissions(at: fileURL), 0o600, "\(filename) permissions must be 0600")
        }
    }

    await T.asyncSuite("TokenUsageEngine.Claude message.id Dedup, Codex Delta Diff & Grok costUsdTicks") {
        let dir = try makeTempDir(prefix: "roryorbit-usage-live")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fakeHome = dir.appendingPathComponent("home", isDirectory: true)
        let fakeSupport = dir.appendingPathComponent("support", isDirectory: true)

        // 1. Claude logs across two files (simulating /fork + streaming updates + ignored user/error rows)
        let claudeProjA = fakeHome.appendingPathComponent(".claude/projects/projA", isDirectory: true)
        let claudeProjB = fakeHome.appendingPathComponent(".claude/projects/projB", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeProjA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeProjB, withIntermediateDirectories: true)

        let claudeLinesA = [
            // Streaming chunk 1 (smaller output)
            #"{"type":"assistant","timestamp":"2026-11-21T01:00:00Z","cwd":"/Users/example/projA","message":{"id":"msg_dup_1","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":400,"cache_creation_input_tokens":50}}}"#,
            // Streaming final chunk for same msg_dup_1 (larger output -> wins: total 750)
            #"{"type":"assistant","timestamp":"2026-11-21T01:00:05Z","cwd":"/Users/example/projA","message":{"id":"msg_dup_1","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":400,"cache_creation_input_tokens":50}}}"#,
            // Non-assistant record with usage -> MUST be ignored
            #"{"type":"user","timestamp":"2026-11-21T01:01:00Z","message":{"id":"msg_user_1","model":"claude-sonnet-4","usage":{"input_tokens":9999,"output_tokens":9999}}}"#,
            // API error message -> MUST be ignored
            #"{"type":"assistant","isApiErrorMessage":true,"timestamp":"2026-11-21T01:02:00Z","message":{"id":"msg_err_1","model":"claude-sonnet-4","usage":{"input_tokens":8888,"output_tokens":1111}}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(claudeLinesA.utf8).write(to: claudeProjA.appendingPathComponent("s1.jsonl"))

        let claudeLinesB = [
            // Forked duplicate of msg_dup_1 in another file -> MUST deduplicate globally
            #"{"type":"assistant","timestamp":"2026-11-21T01:00:05Z","cwd":"/Users/example/projB","message":{"id":"msg_dup_1","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":400,"cache_creation_input_tokens":50}}}"#,
            // Unique second message (total 250)
            #"{"type":"assistant","timestamp":"2026-11-21T01:05:00Z","cwd":"/Users/example/projB","message":{"id":"msg_unique_2","model":"claude-sonnet-4","usage":{"input_tokens":50,"output_tokens":100,"cache_read_input_tokens":100,"cache_creation_input_tokens":0}}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(claudeLinesB.utf8).write(to: claudeProjB.appendingPathComponent("s2_fork.jsonl"))

        // 2. Codex logs (cumulative total_token_usage delta + duplicate snapshot skip + incremental append)
        let codexDir = fakeHome.appendingPathComponent(".codex/sessions/2026/11/21", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let codexFile = codexDir.appendingPathComponent("session-1.jsonl")
        let codexInitial = [
            #"{"type":"session_meta","timestamp":"2026-11-21T01:00:00Z","payload":{"cwd":"/tmp/codex-proj"}}"#,
            #"{"type":"turn_context","timestamp":"2026-11-21T01:00:01Z","payload":{"model":"gpt-6-codex","cwd":"/tmp/codex-proj"}}"#,
            #"{"type":"event_msg","timestamp":"2026-11-21T01:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"output_tokens":200,"reasoning_output_tokens":50}}}}"#,
            // Consecutive identical cumulative snapshot -> MUST skip
            #"{"type":"event_msg","timestamp":"2026-11-21T01:01:01Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"output_tokens":200,"reasoning_output_tokens":50}}}}"#,
            // Next cumulative snapshot -> delta: in=1500 (cached=1200, uncached=300), out=300 (reas=100) => deltaTotal=1800
            #"{"type":"event_msg","timestamp":"2026-11-21T01:02:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2500,"cached_input_tokens":1800,"output_tokens":500,"reasoning_output_tokens":150}}}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(codexInitial.utf8).write(to: codexFile)

        // 3. Grok usage.json with costUsdTicks (1e10 ticks per USD)
        let grokDir = fakeHome.appendingPathComponent(".grok/sessions/%2Ftmp%2Fgrok-proj/sess1", isDirectory: true)
        try FileManager.default.createDirectory(at: grokDir, withIntermediateDirectories: true)
        let grokUsage = """
        {
          "updatedAt": "2026-11-21T02:00:00Z",
          "turns": [
            {
              "endedAt": "2026-11-21T02:00:00Z",
              "primaryModelId": "grok-4",
              "modelUsage": {
                "grok-4": {
                  "inputTokens": 1000,
                  "cachedReadTokens": 700,
                  "outputTokens": 200,
                  "reasoningTokens": 80,
                  "totalTokens": 1200,
                  "modelCalls": 2,
                  "costUsdTicks": 25000000000
                }
              }
            }
          ]
        }
        """
        try Data(grokUsage.utf8).write(to: grokDir.appendingPathComponent("usage.json"))

        let engine = TokenUsageEngine(homeDirectoryURL: fakeHome, appSupportURL: fakeSupport)
        let snap1 = await engine.scanAndExportArchive(forceFullRescan: true, now: fixedNow)

        let claudeSum = snap1.summary(for: .today, clientFilter: .claude)
        T.expectEqual(claudeSum.totals.totalTokens, 1000, "Claude cross-file message.id dedup: 750 + 250 = 1000")
        T.expectEqual(claudeSum.totals.outputTokens, 300, "200 + 100")
        T.expectEqual(claudeSum.totals.messageCount, 2)

        let codexSum = snap1.summary(for: .today, clientFilter: .codex)
        T.expectEqual(codexSum.totals.totalTokens, 3000, "Codex cumulative delta: 1200 + 1800 = 3000")
        T.expectEqual(codexSum.totals.uncachedInputTokens, 700, "400 + 300")
        T.expectEqual(codexSum.totals.cacheReadTokens, 1800, "600 + 1200")
        T.expectEqual(codexSum.totals.outputTokens, 500, "200 + 300")
        T.expectEqual(codexSum.totals.reasoningTokens, 150, "50 + 100")
        T.expectEqual(codexSum.totals.messageCount, 2, "duplicate snapshot must be skipped")

        let grokSum = snap1.summary(for: .today, clientFilter: .grok)
        T.expectEqual(grokSum.totals.totalTokens, 1200)
        T.expectEqual(grokSum.totals.uncachedInputTokens, 300, "Grok inputTokens includes cachedReadTokens")
        T.expectEqual(grokSum.totals.cacheReadTokens, 700)
        T.expectEqual(grokSum.totals.outputTokens, 200)
        T.expectEqual(grokSum.totals.reasoningTokens, 80)
        T.expect(abs(grokSum.totals.estimatedCostUSD - 2.50) < 0.0001, "Grok 25e9 costUsdTicks = $2.50")

        // Append a new Codex cumulative delta line and verify incremental byte-offset scan does not double-count
        let appendedLine = #"{"type":"event_msg","timestamp":"2026-11-21T02:30:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"cached_input_tokens":2200,"output_tokens":600,"reasoning_output_tokens":180}}}}"# + "\n"
        try Data((codexInitial + appendedLine).utf8).write(to: codexFile)
        let snap2 = await engine.scanAndExportArchive(forceFullRescan: false, now: fixedNow)
        let codexInc = snap2.summary(for: .today, clientFilter: .codex)
        T.expectEqual(codexInc.totals.totalTokens, 3600, "incremental Codex delta adds +600 (500 in + 100 out)")
        T.expectEqual(codexInc.totals.messageCount, 3)
    }

    await T.asyncSuite("TokenUsageEngine.OpenCode vs ZCode Input Semantics (SQLite)") {
        let dir = try makeTempDir(prefix: "roryorbit-usage-sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fakeHome = dir.appendingPathComponent("home", isDirectory: true)
        let fakeSupport = dir.appendingPathComponent("support", isDirectory: true)
        let openCodeDB = fakeHome.appendingPathComponent(".local/share/opencode/opencode.db")
        let zcodeDB = fakeHome.appendingPathComponent(".zcode/cli/db/db.sqlite")
        try FileManager.default.createDirectory(at: openCodeDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zcodeDB.deletingLastPathComponent(), withIntermediateDirectories: true)

        let tsMs: Int64 = Int64(fixedNow.timeIntervalSince1970 * 1000)

        func writeMessageDB(at url: URL, msgDataJSON: String, userDataJSON: String) throws {
            var db: OpaquePointer?
            T.expectEqual(sqlite3_open(url.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            let ddl = """
            CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
            INSERT INTO session VALUES ('s1', '/tmp/sql-proj');
            """
            T.expectEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)
            var stmt: OpaquePointer?
            T.expectEqual(sqlite3_prepare_v2(db, "INSERT INTO message VALUES (?, 's1', ?, ?, ?)", -1, &stmt, nil), SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (idx, payload) in [msgDataJSON, userDataJSON].enumerated() {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, "m\(idx)", -1, transient)
                sqlite3_bind_int64(stmt, 2, tsMs + Int64(idx))
                sqlite3_bind_int64(stmt, 3, tsMs + Int64(idx))
                sqlite3_bind_text(stmt, 4, payload, -1, transient)
                T.expectEqual(sqlite3_step(stmt), SQLITE_DONE)
            }
        }

        // OpenCode: `input` is UNCACHED; `reasoning` is SEPARATE from `output` (folded into outputTokens); `modelID`
        let openCodeMsg = """
        {"role":"assistant","modelID":"glm-5","providerID":"zai","time":{"completed":\(tsMs)},"tokens":{"input":300,"output":100,"reasoning":50,"cache":{"read":700,"write":100}}}
        """
        let userMsg = """
        {"role":"user","modelID":"glm-5","time":{"completed":\(tsMs)},"tokens":{"input":9999,"output":9999}}
        """
        try writeMessageDB(at: openCodeDB, msgDataJSON: openCodeMsg, userDataJSON: userMsg)

        // ZCode: `input` INCLUDES `cache.read` + `cache.write`; `reasoning` is INCLUDED in `output`; `modelId`
        let zcodeMsg = """
        {"role":"assistant","modelId":"glm-5","providerId":"zai","time":{"completed":\(tsMs)},"tokens":{"input":1000,"output":150,"reasoning":50,"cache":{"read":700,"write":100}}}
        """
        try writeMessageDB(at: zcodeDB, msgDataJSON: zcodeMsg, userDataJSON: userMsg)

        let engine = TokenUsageEngine(homeDirectoryURL: fakeHome, appSupportURL: fakeSupport)
        let snap = await engine.scanAndExportArchive(forceFullRescan: true, now: fixedNow)

        let oc = snap.summary(for: .today, clientFilter: .opencode)
        T.expectEqual(oc.totals.uncachedInputTokens, 300, "OpenCode input is uncached")
        T.expectEqual(oc.totals.cacheReadTokens, 700)
        T.expectEqual(oc.totals.cacheWriteTokens, 100)
        T.expectEqual(oc.totals.outputTokens, 150, "OpenCode folds separate reasoning(50) into output(100)")
        T.expectEqual(oc.totals.reasoningTokens, 50)
        T.expectEqual(oc.totals.totalTokens, 1250, "300 + 700 + 100 + 150 = 1250")
        T.expectEqual(oc.totals.messageCount, 1, "role=user rows must be ignored")

        let zc = snap.summary(for: .today, clientFilter: .zcode)
        T.expectEqual(zc.totals.uncachedInputTokens, 200, "ZCode input(1000) includes cacheRead(700)+cacheWrite(100) -> uncached=200")
        T.expectEqual(zc.totals.cacheReadTokens, 700)
        T.expectEqual(zc.totals.cacheWriteTokens, 100)
        T.expectEqual(zc.totals.outputTokens, 150, "ZCode reasoning(50) is already inside output(150)")
        T.expectEqual(zc.totals.reasoningTokens, 50)
        T.expectEqual(zc.totals.totalTokens, 1150, "200 + 700 + 100 + 150 = 1150")
        T.expectEqual(zc.totals.messageCount, 1)
    }

    await T.asyncSuite("TokenUsageEngine.max(seed, live) Merge & Archive Invariants") {
        let dir = try makeTempDir(prefix: "roryorbit-usage-merge")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fakeHome = dir.appendingPathComponent("home", isDirectory: true)
        let fakeSupport = dir.appendingPathComponent("support", isDirectory: true)
        let backupDir = fakeHome.appendingPathComponent("Library/Application Support/Token Monitor", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        // Seed on 2026-11-21: claude=5000 (> live 2000 -> keep seed), codex=1000 (< live 3000 -> take live), cursor=4000 (seed-only)
        let seedObj: [String: Any] = [
            "days": [
                "2026-11-21": [
                    "activeTimeMs": 90_000,
                    "observations": [
                        "[\"claude\",\"claude-sonnet-4\"]": [
                            "client": "claude",
                            "modelId": "claude-sonnet-4",
                            "tokens": 5000,
                            "outputTokens": 1000,
                            "cacheReadTokens": 3000,
                            "cacheWriteTokens": 500,
                            "cost": 2.0,
                            "messages": 5,
                        ],
                        "[\"codex\",\"gpt-6-codex\"]": [
                            "client": "codex",
                            "modelId": "gpt-6-codex",
                            "tokens": 1000,
                            "outputTokens": 200,
                            "cacheReadTokens": 500,
                            "cacheWriteTokens": 0,
                            "cost": 0.4,
                            "messages": 1,
                        ],
                        "[\"cursor\",\"gpt-5\"]": [
                            "client": "cursor",
                            "modelId": "gpt-5",
                            "tokens": 4000,
                            "outputTokens": 800,
                            "cacheReadTokens": 2000,
                            "cacheWriteTokens": 200,
                            "cost": 1.6,
                            "messages": 4,
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: seedObj).write(to: backupDir.appendingPathComponent("daily-history-calendars.json"))

        // Live on 2026-11-21: claude=2000 (< seed 5000), codex=3000 (>= seed 1000), grok=1200 (live-only)
        let claudeDir = fakeHome.appendingPathComponent(".claude/projects/p1", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let claudeLive = #"{"type":"assistant","timestamp":"2026-11-21T01:00:00Z","message":{"id":"msg_small","model":"claude-sonnet-4","usage":{"input_tokens":500,"output_tokens":500,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0}}}"# + "\n"
        try Data(claudeLive.utf8).write(to: claudeDir.appendingPathComponent("s.jsonl"))

        let codexDir = fakeHome.appendingPathComponent(".codex/sessions/2026/11/21", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let codexLive = [
            #"{"type":"turn_context","timestamp":"2026-11-21T01:00:00Z","payload":{"model":"gpt-6-codex"}}"#,
            #"{"type":"event_msg","timestamp":"2026-11-21T01:05:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2500,"cached_input_tokens":1800,"output_tokens":500,"reasoning_output_tokens":100}}}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(codexLive.utf8).write(to: codexDir.appendingPathComponent("c.jsonl"))

        let grokDir = fakeHome.appendingPathComponent(".grok/sessions/%2Ftmp%2Fg/s1", isDirectory: true)
        try FileManager.default.createDirectory(at: grokDir, withIntermediateDirectories: true)
        let grokLive = #"{"updatedAt":"2026-11-21T02:00:00Z","turns":[{"endedAt":"2026-11-21T02:00:00Z","primaryModelId":"grok-4","inputTokens":1000,"cachedReadTokens":600,"outputTokens":200,"totalTokens":1200,"costUsdTicks":10000000000}]}"#
        try Data(grokLive.utf8).write(to: grokDir.appendingPathComponent("usage.json"))

        let engine = TokenUsageEngine(homeDirectoryURL: fakeHome, appSupportURL: fakeSupport)
        let snap = await engine.scanAndExportArchive(forceFullRescan: true, now: fixedNow)

        let today = snap.summary(for: .today)
        T.expectEqual(today.totals.totalTokens, 13_200, "max(seed, live): claude 5000 + codex 3000 + cursor 4000 + grok 1200 = 13200 (zero double counting)")
        T.expectEqual(snap.summary(for: .today, clientFilter: .claude).totals.totalTokens, 5000, "seed > live must keep seed")
        T.expectEqual(snap.summary(for: .today, clientFilter: .codex).totals.totalTokens, 3000, "live >= seed must take live without summing")
        T.expectEqual(snap.summary(for: .today, clientFilter: .cursor).totals.totalTokens, 4000)
        T.expectEqual(snap.summary(for: .today, clientFilter: .grok).totals.totalTokens, 1200)
        T.expectEqual(snap.heatmap(days: 112, clientFilter: .codex).last?.totals.totalTokens, 3000)

        // Verify exported daily-history-archive.json invariants & 0600 permissions
        let archiveURL = fakeSupport.appendingPathComponent("daily-history-archive.json")
        T.expectEqual(try posixPermissions(at: archiveURL), 0o600, "daily-history-archive.json must be 0600")
        let archiveData = try Data(contentsOf: archiveURL)
        let archiveRoot = try JSONSerialization.jsonObject(with: archiveData) as! [String: Any]
        T.expectEqual(archiveRoot["version"] as? Int, 1)
        let liveDays = archiveRoot["liveDays"] as? [String: Any]
        T.expectEqual(liveDays?.isEmpty, true, "liveDays must be empty dict")

        let days = archiveRoot["days"] as! [String: [String: Any]]
        var obsCount = 0
        for (_, dayObj) in days {
            let obsMap = dayObj["observations"] as! [String: [String: Any]]
            for (_, obs) in obsMap {
                obsCount += 1
                T.expectEqual(obs["tokenComponentsAvailable"] as? Bool, true, "every archive obs must set tokenComponentsAvailable=true")
                let tokens = (obs["tokens"] as? NSNumber)?.int64Value ?? -1
                let cr = (obs["cacheReadTokens"] as? NSNumber)?.int64Value ?? -1
                let cw = (obs["cacheWriteTokens"] as? NSNumber)?.int64Value ?? -1
                let out = (obs["outputTokens"] as? NSNumber)?.int64Value ?? -1
                T.expect(tokens >= 0 && cr >= 0 && cw >= 0 && out >= 0, "non-negative component counts")
                T.expect(cr + cw + out <= tokens, "archive invariant: cacheRead + cacheWrite + output <= tokens")
            }
        }
        T.expectEqual(obsCount, 4, "all 4 clients exported cleanly")
    }
}

// MARK: - Test 10: AccountPoolExporter (Zero-Claude, Kimi/DeepSeek Identity, Zero Credits & @TaskLocal Lock)

private func testAccountPoolExporter() async {
    T.suite("AccountPoolExporter.Zero-Claude, Kimi Identity Omission, DeepSeek Dynamic Account & 0600") {
        let dir = try makeTempDir(prefix: "roryorbit-ap-export")
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Formatters.parseRFC3339("2026-11-21T03:05:00Z")!
        let exporter = AccountPoolExporter(appSupportURL: dir)

        var reg = RegistryData()
        let codexId = "codex:u-ap-test:a-ap-test"
        reg.upsertAccount(AccountRecord(
            id: codexId,
            provider: .codex,
            email: "codex-ap@example.test",
            displayName: "Codex AP",
            plan: PlanInfo(kind: .prolite, displayName: "Pro Lite"),
            isActiveLive: true
        ))
        reg.upsertAccount(AccountRecord(
            id: "kimi:api",
            provider: .kimi,
            email: "Kimi Code", // Non-@ label -> MUST omit accountEmail / account / accountId!
            displayName: "Kimi Code",
            plan: PlanInfo(kind: .ultra, displayName: "Allegro"),
            isActiveLive: true
        ))
        reg.upsertAccount(AccountRecord(
            id: "deepseek:api",
            provider: .deepseek,
            email: "sigo", // Must be emitted dynamically as `account: "sigo"`, never hardcoded "DeepSeek API"
            displayName: "DeepSeek API",
            plan: PlanInfo(kind: .api, displayName: "API"),
            isActiveLive: true
        ))
        reg.upsertAccount(AccountRecord(
            id: "104799291722680492576",
            provider: .antigravity,
            email: "ag-ap@example.test",
            displayName: "AG AP",
            plan: PlanInfo(kind: .pro, displayName: "Google AI Pro"),
            isActiveLive: true
        ))

        // Explicit zero credits & zero resetCredits MUST be preserved
        CodexProvider.recordCreditMetadata(
            CodexProvider.CodexCreditMetadata(
                creditsRemaining: 0.0,
                creditsReadSucceeded: true,
                resetCreditsAvailable: 0,
                updatedAt: now
            ),
            for: codexId
        )

        let snaps: [String: QuotaSnapshot] = [
            "codex|\(codexId)": QuotaSnapshot(
                provider: .codex,
                accountId: codexId,
                plan: PlanInfo(kind: .prolite, displayName: "Pro Lite"),
                windows: [
                    QuotaWindow(id: "5h", label: "5小时", remainingFraction: 0.85, usedPercent: 15.0, windowSeconds: 18_000, isPrimary: true),
                    QuotaWindow(id: "weekly", label: "本周", remainingFraction: 0.70, usedPercent: 30.0, windowSeconds: 604_800),
                    QuotaWindow(id: "add_spark", label: "Spark · 5小时", remainingFraction: 0.90, usedPercent: 10.0, windowSeconds: 18_000),
                ],
                status: .ready(fetchedAt: now, stale: false),
                primaryRemainingPercent: 85
            ),
            "kimi|kimi:api": QuotaSnapshot(
                provider: .kimi,
                accountId: "kimi:api",
                plan: PlanInfo(kind: .ultra, displayName: "Allegro"),
                windows: [
                    QuotaWindow(id: "kimi-limit-18000", label: "5小时限额", remainingFraction: 0.86, usedPercent: 14.0, windowSeconds: 18_000),
                    QuotaWindow(id: "kimi-monthly", label: "月度总额度", remainingFraction: 0.08, usedPercent: 92.0, windowSeconds: 2_592_000, isPrimary: true),
                ],
                status: .ready(fetchedAt: now, stale: false),
                primaryRemainingPercent: 8
            ),
            "deepseek|deepseek:api": QuotaSnapshot(
                provider: .deepseek,
                accountId: "deepseek:api",
                balance: BalanceInfo(currency: "CNY", totalBalance: 88.40, grantedBalance: 8.40, toppedUpBalance: 80.00),
                status: .ready(fetchedAt: now, stale: false)
            ),
            "antigravity|104799291722680492576": QuotaSnapshot(
                provider: .antigravity,
                accountId: "104799291722680492576",
                plan: PlanInfo(kind: .pro, displayName: "Google AI Pro"),
                windows: [
                    QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: 0.80, usedPercent: 20.0, windowSeconds: 18_000, isPrimary: true),
                    QuotaWindow(id: "gemini_weekly", label: "Gemini · 周", remainingFraction: 0.65, usedPercent: 35.0, windowSeconds: 604_800),
                    QuotaWindow(id: "claude_gpt_5h", label: "Claude / GPT · 5小时", remainingFraction: 1.0, usedPercent: 0.0, windowSeconds: 18_000),
                    QuotaWindow(id: "claude_gpt_weekly", label: "Claude / GPT · 周", remainingFraction: 0.90, usedPercent: 10.0, windowSeconds: 604_800),
                    QuotaWindow(id: "argon_weekly", label: "Argon · 周", remainingFraction: 1.0, usedPercent: 0.0, windowSeconds: 604_800),
                ],
                status: .ready(fetchedAt: now, stale: false),
                primaryRemainingPercent: 80
            ),
        ]

        let payload = try exporter.writeSnapshot(registry: reg, snapshots: snaps, now: now)

        // 1. Strict zero-Claude provider set
        T.expectEqual(Set(payload.providers.keys), Set(["codex", "cursor", "grok", "deepseek", "kimi", "antigravity"]))
        T.expectEqual(payload.providers["claude"], nil, "AccountPool export MUST NEVER contain claude provider")

        // 2. Codex zero credits + Pro Lite -> Pro 100 + safe_text middle-dot replacement
        let codexRow = payload.providers["codex"]?.first
        T.expectEqual(codexRow?.usage?.loginMethod, "Pro 100")
        T.expectEqual(codexRow?.credits?.remaining, 0.0, "explicit 0 credits must be preserved")
        T.expectEqual(codexRow?.credits?.balanceReadSucceeded, true)
        T.expectEqual(codexRow?.resetCredits?.available, 0, "explicit 0 resetCredits must be preserved")
        T.expectEqual(codexRow?.usage?.extraRateWindows?.first?.title, "Spark / 5小时", "middle dot must be sanitized to slash")

        // 3. Kimi without '@' email omits identity fields & preserves 5h + kimi-monthly
        let kimiRow = payload.providers["kimi"]?.first
        T.expectEqual(kimiRow?.account, nil, "Kimi without @ email must omit account")
        T.expectEqual(kimiRow?.accountId, nil, "Kimi without @ email must omit accountId")
        T.expectEqual(kimiRow?.usage?.accountEmail, nil, "Kimi without @ email must omit usage.accountEmail")
        T.expectEqual(kimiRow?.usage?.identity?.accountEmail, nil, "Kimi without @ email must omit identity.accountEmail")
        T.expectEqual(kimiRow?.usage?.identity?.loginMethod, "Allegro")
        T.expectEqual(kimiRow?.usage?.secondary?.windowMinutes, 300)
        T.expectEqual(kimiRow?.usage?.extraRateWindows?.first?.id, "kimi-monthly")

        // Kimi WITH '@' email preserves email
        var regWithKimiEmail = RegistryData()
        regWithKimiEmail.upsertAccount(AccountRecord(id: "kimi:api", provider: .kimi, email: "real@kimi.test", displayName: "Kimi"))
        let kimiEmailPayload = exporter.buildPayload(registry: regWithKimiEmail, snapshots: snaps, now: now)
        T.expectEqual(kimiEmailPayload.providers["kimi"]?.first?.usage?.accountEmail, "real@kimi.test")

        // 4. DeepSeek dynamically uses account.email, falling back to account.displayName
        let dsRow = payload.providers["deepseek"]?.first
        T.expectEqual(dsRow?.account, "sigo", "DeepSeek must use dynamic account.email")
        T.expect(dsRow?.usage?.primary?.resetDescription?.contains("¥88.40") == true)

        var regDSFallback = RegistryData()
        regDSFallback.upsertAccount(AccountRecord(id: "deepseek:api", provider: .deepseek, email: "", displayName: "ds-display-fallback"))
        let dsFallbackPayload = exporter.buildPayload(registry: regDSFallback, snapshots: snaps, now: now)
        T.expectEqual(dsFallbackPayload.providers["deepseek"]?.first?.account, "ds-display-fallback", "DeepSeek must fall back to displayName when email is empty")

        // 5. Antigravity numeric Google sub registry + 5 windows incl. argon-weekly
        T.expectEqual(payload.antigravityRegistry.count, 1)
        T.expectEqual(payload.antigravityRegistry[0].id, "104799291722680492576")
        T.expectEqual(payload.antigravityRegistry[0].plan?.kind, "pro")
        let agWindowIds = payload.providers["antigravity"]?.first?.usage?.extraRateWindows?.map(\.id) ?? []
        T.expectEqual(agWindowIds, [
            "antigravity-quota-summary-gemini-5h",
            "antigravity-quota-summary-gemini-weekly",
            "antigravity-quota-summary-3p-5h",
            "antigravity-quota-summary-3p-weekly",
            "antigravity-quota-summary-argon-weekly",
        ])

        // 6. Persisted snapshot file permissions == 0600 & sanitizeSafeText guards
        let snapFile = dir.appendingPathComponent("accountpool-snapshot.json")
        T.expectEqual(try posixPermissions(at: snapFile), 0o600, "accountpool-snapshot.json permissions must be 0600")
        T.expectEqual(AccountPoolExporter.sanitizeSafeText("Gemini · 5小时"), "Gemini / 5小时")
        T.expectEqual(AccountPoolExporter.sanitizeSafeText("secret@domain.com"), nil)
        T.expectEqual(AccountPoolExporter.sanitizeSafeText("sk-1234567890"), nil)
        T.expectEqual(AccountPoolExporter.sanitizeSafeText("Bearer abcdef"), nil)
    }

    await T.asyncSuite("AccountPoolExporter.@TaskLocal Cross-Process Lock Re-entrancy (Zero Self-Deadlock)") {
        let dir = try makeTempDir(prefix: "roryorbit-lock-reentrant")
        defer { try? FileManager.default.removeItem(at: dir) }

        let lockURL = dir.appendingPathComponent(".refresh.lock")
        let start = Date()
        let result: Int = await AccountPoolExporter.withCrossProcessRefreshLock(lockURL: lockURL, timeoutSeconds: 5.0) {
            // Re-enter synchronously in same task
            let nested1 = await AccountPoolExporter.withCrossProcessRefreshLock(lockURL: lockURL, timeoutSeconds: 5.0) {
                // Re-enter inside a structured child TaskGroup task (exact pattern of exportJSONData -> CodexProvider)
                await withTaskGroup(of: Int.self) { group in
                    group.addTask {
                        await AccountPoolExporter.withCrossProcessRefreshLock(lockURL: lockURL, timeoutSeconds: 5.0) {
                            42
                        }
                    }
                    var sum = 0
                    for await v in group { sum += v }
                    return sum
                }
            }
            return nested1
        }
        let elapsed = Date().timeIntervalSince(start)
        T.expectEqual(result, 42)
        T.expect(elapsed < 1.0, "@TaskLocal lock re-entrancy must complete immediately without self-deadlock (took \(elapsed)s)")
        T.expectEqual(try posixPermissions(at: lockURL), 0o600, ".refresh.lock permissions must be 0600")
    }

    await T.asyncSuite("AppStore.PerProviderHardTimeout & Incremental AccountPool Export") {
        struct HangingTestAdapter: ProviderAdapter {
            let id: ProviderID
            let capabilities: ProviderCapability = [.quota]
            let shouldHang: Bool

            func syncLiveAccount(registry: inout RegistryData) async -> String? {
                let acctId = "\(id.rawValue):test"
                registry.upsertAccount(AccountRecord(id: acctId, provider: id, email: "\(id.rawValue)@test.local", displayName: id.displayName, isActiveLive: true))
                return acctId
            }

            func fetchQuota(for account: AccountRecord, isActiveLive: Bool) async -> QuotaSnapshot {
                if shouldHang {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                }
                return QuotaSnapshot(
                    provider: id,
                    accountId: account.id,
                    windows: [QuotaWindow(id: "primary", label: "主窗口", remainingFraction: 0.9, usedPercent: 10.0, windowSeconds: 18_000, isPrimary: true)],
                    status: .ready(fetchedAt: Date(), stale: false),
                    primaryRemainingPercent: 90
                )
            }
        }

        let dir = try makeTempDir(prefix: "roryorbit-appstore-timeout")
        defer { try? FileManager.default.removeItem(at: dir) }

        let regURL = dir.appendingPathComponent("registry.json")
        let exporter = AccountPoolExporter(appSupportURL: dir)
        let engine = TokenUsageEngine(homeDirectoryURL: dir, appSupportURL: dir)
        let kc = KeychainStore(backend: InMemoryKeychainBackend())
        let adapters: [ProviderID: any ProviderAdapter] = [
            .cursor: HangingTestAdapter(id: .cursor, shouldHang: true),
            .grok: HangingTestAdapter(id: .grok, shouldHang: false),
        ]

        let store = await MainActor.run {
            AppStore(
                keychain: kc,
                processController: ProcessController(inspector: MockProcessInspector()),
                adapters: adapters,
                registryURL: regURL,
                startScheduler: false,
                tokenUsageEngine: engine,
                accountPoolExporter: exporter,
                persistAccountPoolExport: true,
                providerRefreshTimeoutSeconds: 0.5
            )
        }

        let t0 = Date()
        await store.refreshAll()
        let elapsed = Date().timeIntervalSince(t0)

        let (stillRefreshing, cursorSnap, grokSnap) = await MainActor.run {
            (
                store.isRefreshing,
                store.primarySnapshot(for: .cursor),
                store.primarySnapshot(for: .grok)
            )
        }

        T.expect(elapsed < 3.0, "refreshAll() must not hang when a provider stalls (took \(elapsed)s)")
        T.expectEqual(stillRefreshing, false, "isRefreshing must reset after per-provider hard timeout")
        if case .failed(let msg) = cursorSnap?.status {
            T.expect(msg.contains("超时"), "hung provider should be marked failed with timeout message")
        } else {
            T.expect(false, "expected hung provider to fail on timeout, got \(String(describing: cursorSnap?.status))")
        }
        T.expectEqual(grokSnap?.status.isReady, true, "healthy provider must still succeed")

        // Wait briefly for detached/queued serial export write to flush
        let snapFile = dir.appendingPathComponent("accountpool-snapshot.json")
        for _ in 0..<20 {
            if FileManager.default.fileExists(atPath: snapFile.path) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        T.expect(FileManager.default.fileExists(atPath: snapFile.path), "accountpool-snapshot.json must be written")
        if FileManager.default.fileExists(atPath: snapFile.path) {
            T.expectEqual(try posixPermissions(at: snapFile), 0o600)
        }
    }
}

// MARK: - 11. Avatar Flow, Disk Cache & Pulsar Brand Regression Tests

private func makeValid1x1PNGData() -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 2,
        pixelsHigh: 2,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.setColor(NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.9, alpha: 1.0), atX: 0, y: 0)
    rep.setColor(NSColor(calibratedRed: 0.1, green: 0.7, blue: 0.4, alpha: 1.0), atX: 1, y: 1)
    return rep.representation(using: .png, properties: [:])!
}

private func testAvatarAndBrand() async {
    T.suite("Avatar.SanitizeAndBackwardCompatDecode") {
        // Formatters.sanitizedHTTPSURLString validation
        T.expectEqual(
            Formatters.sanitizedHTTPSURLString("  https://lh3.googleusercontent.com/a/avatar123=s96-c  "),
            "https://lh3.googleusercontent.com/a/avatar123=s96-c"
        )
        T.expectEqual(
            Formatters.sanitizedHTTPSURLString("HTTPS://example.com/pic.png"),
            "HTTPS://example.com/pic.png"
        )
        T.expectEqual(Formatters.sanitizedHTTPSURLString("http://example.com/pic.png"), nil)
        T.expectEqual(Formatters.sanitizedHTTPSURLString("file:///etc/passwd"), nil)
        T.expectEqual(Formatters.sanitizedHTTPSURLString("javascript:alert(1)"), nil)
        T.expectEqual(Formatters.sanitizedHTTPSURLString("https:///missing-host"), nil)
        T.expectEqual(Formatters.sanitizedHTTPSURLString("   "), nil)
        T.expectEqual(Formatters.sanitizedHTTPSURLString(nil), nil)

        // AccountRecord backward-compatible decode (legacy JSON without avatarURL)
        let legacyJSON = """
        {
          "id": "104799291722680492576",
          "provider": "antigravity",
          "email": "legacy@example.test",
          "displayName": "Legacy User",
          "addedAt": 1763620000,
          "isActiveLive": true
        }
        """
        let decodedLegacy = try JSONDecoder().decode(AccountRecord.self, from: Data(legacyJSON.utf8))
        T.expectEqual(decodedLegacy.avatarURL, nil, "legacy AccountRecord without avatarURL must decode to nil")

        // Decode with valid HTTPS avatarURL
        let validAvatarJSON = """
        {
          "id": "104799291722680492576",
          "provider": "antigravity",
          "email": "valid@example.test",
          "displayName": "Valid User",
          "addedAt": 1763620000,
          "isActiveLive": false,
          "avatarURL": "https://lh3.googleusercontent.com/a/valid=s96-c"
        }
        """
        let decodedValid = try JSONDecoder().decode(AccountRecord.self, from: Data(validAvatarJSON.utf8))
        T.expectEqual(decodedValid.avatarURL, "https://lh3.googleusercontent.com/a/valid=s96-c")

        // Decode with non-HTTPS avatarURL -> sanitized to nil
        let insecureAvatarJSON = """
        {
          "id": "104799291722680492576",
          "provider": "antigravity",
          "email": "insecure@example.test",
          "displayName": "Insecure User",
          "addedAt": 1763620000,
          "isActiveLive": false,
          "avatarURL": "http://insecure.example.test/pic.png"
        }
        """
        let decodedInsecure = try JSONDecoder().decode(AccountRecord.self, from: Data(insecureAvatarJSON.utf8))
        T.expectEqual(decodedInsecure.avatarURL, nil, "non-HTTPS avatarURL must be rejected on decode")

        // Init also sanitizes non-HTTPS avatarURL
        let recBad = AccountRecord(
            id: "ag-bad",
            provider: .antigravity,
            email: "bad@example.test",
            displayName: "Bad",
            avatarURL: "http://example.com/a.png"
        )
        T.expectEqual(recBad.avatarURL, nil)

        // RegistryData.upsertAccount protects non-empty avatarURL from nil overwrite & allows HTTPS updates
        var reg = RegistryData()
        reg.upsertAccount(AccountRecord(
            id: "ag-1",
            provider: .antigravity,
            email: "one@example.test",
            displayName: "One",
            avatarURL: "https://lh3.googleusercontent.com/a/first=s96-c"
        ))
        reg.upsertAccount(AccountRecord(
            id: "ag-1",
            provider: .antigravity,
            email: "one@example.test",
            displayName: "One Renamed",
            avatarURL: nil
        ))
        T.expectEqual(
            reg.accounts(for: .antigravity).first?.avatarURL,
            "https://lh3.googleusercontent.com/a/first=s96-c",
            "upsertAccount with nil avatarURL must preserve existing non-empty avatarURL"
        )
        T.expectEqual(reg.accounts(for: .antigravity).first?.displayName, "One Renamed")

        reg.upsertAccount(AccountRecord(
            id: "ag-1",
            provider: .antigravity,
            email: "one@example.test",
            displayName: "One Renamed",
            avatarURL: "https://lh3.googleusercontent.com/a/second=s96-c"
        ))
        T.expectEqual(
            reg.accounts(for: .antigravity).first?.avatarURL,
            "https://lh3.googleusercontent.com/a/second=s96-c",
            "upsertAccount with new valid HTTPS avatarURL must update it"
        )
    }

    await T.asyncSuite("Avatar.DiskCachePermissionsCorruptRejectAndBackupBackfill") {
        let dir = try makeTempDir(prefix: "roryorbit-avatar-cache")
        defer { try? FileManager.default.removeItem(at: dir) }

        let regURL = dir.appendingPathComponent("registry.json")
        let avatarDir = dir.appendingPathComponent("avatars", isDirectory: true)
        let backupURL = dir.appendingPathComponent("backup-accounts.json")
        let goodURL = "https://lh3.googleusercontent.com/a/good-avatar=s96-c"
        let corruptURL = "https://lh3.googleusercontent.com/a/corrupt-avatar=s96-c"
        let validPNG = makeValid1x1PNGData()

        // Seed registry with an Antigravity account missing avatarURL + OrbitSwitch backup with picture
        var initialReg = RegistryData()
        initialReg.upsertAccount(AccountRecord(
            id: "100000000000000000001",
            provider: .antigravity,
            email: "google-one@example.test",
            displayName: "Google One",
            avatarURL: nil
        ))
        try initialReg.save(to: regURL)

        let backupJSON = """
        {
          "accounts": [
            {
              "provider": "antigravity",
              "id": "100000000000000000001",
              "picture": "\(goodURL)"
            }
          ]
        }
        """
        try Data(backupJSON.utf8).write(to: backupURL)

        let migrationPaths = LegacyMigrationPaths(
            orbitSwitchBackupAccountsURL: backupURL,
            codexBarManagedAccountsURL: dir.appendingPathComponent("none-cb-accts.json"),
            codexBarManagedHomesDirURL: dir.appendingPathComponent("none-cb-homes"),
            codexBarConfigURL: dir.appendingPathComponent("none-cb-config.json"),
            registryURL: regURL
        )

        StubURLProtocol.reset { req, _ in
            let urlStr = req.url?.absoluteString ?? ""
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
            if urlStr == goodURL {
                return (resp, validPNG)
            }
            if urlStr == corruptURL {
                return (resp, Data("NOT_A_VALID_IMAGE_PAYLOAD".utf8))
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let kc = KeychainStore(backend: InMemoryKeychainBackend())
        let engine = TokenUsageEngine(homeDirectoryURL: dir, appSupportURL: dir)
        let exporter = AccountPoolExporter(appSupportURL: dir)
        let mockSession = makeMockSession()

        let store = await MainActor.run {
            AppStore(
                keychain: kc,
                processController: ProcessController(inspector: MockProcessInspector()),
                adapters: [:],
                registryURL: regURL,
                migrationPaths: migrationPaths,
                startScheduler: false,
                tokenUsageEngine: engine,
                accountPoolExporter: exporter,
                persistAccountPoolExport: false,
                avatarCacheDirectoryURL: avatarDir,
                avatarSession: mockSession
            )
        }

        // 1. Verify backup backfill populated avatarURL and persisted to registry.json
        let backfilledURL = await MainActor.run {
            store.registry.accounts(for: .antigravity).first?.avatarURL
        }
        T.expectEqual(backfilledURL, goodURL, "Antigravity avatarURL should be backfilled from OrbitSwitch backup")
        let reloadedReg = try RegistryData.load(from: regURL)
        T.expectEqual(reloadedReg.accounts(for: .antigravity).first?.avatarURL, goodURL)

        // 2. Wait for prewarmed good avatar download to finish and verify 0700/0600 permissions
        let goodCacheFile = AppStore.avatarCacheFileURL(forHTTPSURL: goodURL, in: avatarDir)
        for _ in 0..<40 {
            let loaded = await MainActor.run { store.avatarImages["100000000000000000001"] != nil }
            if loaded && FileManager.default.fileExists(atPath: goodCacheFile.path) { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        let goodLoaded = await MainActor.run {
            if let img = store.avatarImages["100000000000000000001"] {
                return img.size.width > 0 && img.size.height > 0
            }
            return false
        }
        T.expect(goodLoaded, "valid HTTPS avatar image must load into AppStore.avatarImages")
        T.expect(FileManager.default.fileExists(atPath: goodCacheFile.path), "valid avatar bytes must be cached on disk")
        T.expectEqual(try posixPermissions(at: avatarDir), 0o700, "avatars cache directory must be 0700")
        T.expectEqual(try posixPermissions(at: goodCacheFile), 0o600, "avatar cache file must be 0600")

        // 3. Corrupt bytes MUST be rejected and NOT persisted to disk
        let corruptAccount = AccountRecord(
            id: "100000000000000000002",
            provider: .antigravity,
            email: "corrupt@example.test",
            displayName: "Corrupt",
            avatarURL: corruptURL
        )
        let corruptCacheFile = AppStore.avatarCacheFileURL(forHTTPSURL: corruptURL, in: avatarDir)
        await MainActor.run {
            store.ensureAvatarLoaded(for: corruptAccount)
        }
        for _ in 0..<30 {
            let reqs = StubURLProtocol.snapshotRequests()
            if reqs.contains(where: { $0.request.url?.absoluteString == corruptURL }) {
                try? await Task.sleep(nanoseconds: 50_000_000)
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let corruptImgPresent = await MainActor.run { store.avatarImages["100000000000000000002"] != nil }
        T.expect(!corruptImgPresent, "corrupt avatar response must NOT decode into avatarImages")
        T.expect(!FileManager.default.fileExists(atPath: corruptCacheFile.path), "corrupt avatar bytes must NOT be cached to disk")

        // 4. Cold second AppStore instance hits disk cache with ZERO HTTP requests
        StubURLProtocol.reset { req, _ in
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let store2 = await MainActor.run {
            AppStore(
                keychain: kc,
                processController: ProcessController(inspector: MockProcessInspector()),
                adapters: [:],
                registryURL: regURL,
                migrationPaths: migrationPaths,
                startScheduler: false,
                tokenUsageEngine: engine,
                accountPoolExporter: exporter,
                persistAccountPoolExport: false,
                avatarCacheDirectoryURL: avatarDir,
                avatarSession: makeMockSession()
            )
        }
        for _ in 0..<40 {
            let loaded = await MainActor.run { store2.avatarImages["100000000000000000001"] != nil }
            if loaded { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        let cachedImgPresent = await MainActor.run { store2.avatarImages["100000000000000000001"] != nil }
        T.expect(cachedImgPresent, "second AppStore launch must load avatar from disk cache")
        T.expectEqual(StubURLProtocol.snapshotRequests().count, 0, "disk cache hit must issue 0 HTTP requests")
    }
}

// MARK: - 12. MenuBar Customization & AppStore.menuBarSummary() Regression Tests

private func testMenuBarCustomization() async {
    T.suite("MenuBarCustomConfig.BackwardCompatAndEmptyModules") {
        // Legacy AppSettings JSON missing menuBarCustom decodes with defaults
        let legacySettingsJSON = """
        {
          "enabledProviders": ["antigravity", "codex"],
          "selectedProvider": "codex",
          "menuBarDisplayMode": "lowestQuota",
          "showRemainingPercent": true,
          "showResetRelative": true,
          "refreshCadence": "every5m",
          "refreshOnMenuOpen": true,
          "lowQuotaWarnThreshold": 0.2,
          "launchAtLogin": true,
          "legacyMigrationCompleted": true
        }
        """
        let decodedSettings = try JSONDecoder().decode(AppSettings.self, from: Data(legacySettingsJSON.utf8))
        T.expectEqual(decodedSettings.menuBarDisplayMode, .lowestQuota)
        T.expectEqual(decodedSettings.menuBarCustom, MenuBarCustomConfig())
        T.expectEqual(decodedSettings.menuBarCustom.iconStyle, .provider)
        T.expectEqual(decodedSettings.menuBarCustom.modules, [.quota, .tokenRate, .todayTokens])
        T.expectEqual(decodedSettings.menuBarCustom.quotaWindow, .weeklyFirst)

        // Empty JSON object for MenuBarCustomConfig decodes to default modules [.quota, .tokenRate, .todayTokens] & weeklyFirst
        let emptyCfg = try JSONDecoder().decode(MenuBarCustomConfig.self, from: Data("{}".utf8))
        T.expectEqual(emptyCfg.modules, [.quota, .tokenRate, .todayTokens])
        T.expectEqual(emptyCfg.quotaWindow, .weeklyFirst)
        T.expectEqual(emptyCfg.quotaDualFormat, .slash)
        T.expectEqual(emptyCfg.quotaMultiProviders, [.antigravity, .codex])
        T.expectEqual(emptyCfg.antigravityPool, .autoLowest)
        T.expectEqual(emptyCfg.separator, .dot)

        // Explicit empty modules array MUST be preserved (not reset to defaults)
        let explicitEmptyJSON = """
        {
          "iconStyle": "hidden",
          "modules": [],
          "quotaSource": "fixed",
          "fixedQuotaProvider": "deepseek",
          "showProviderPrefix": false,
          "rateMetric": "total",
          "hideRateWhenIdle": true,
          "separator": "pipe"
        }
        """
        let explicitEmptyCfg = try JSONDecoder().decode(MenuBarCustomConfig.self, from: Data(explicitEmptyJSON.utf8))
        T.expectEqual(explicitEmptyCfg.iconStyle, .hidden)
        T.expectEqual(explicitEmptyCfg.modules, [], "explicit empty modules array must be preserved on decode")
        T.expectEqual(explicitEmptyCfg.quotaSource, .fixed)
        T.expectEqual(explicitEmptyCfg.fixedQuotaProvider, .deepseek)
        T.expectEqual(explicitEmptyCfg.showProviderPrefix, false)
        T.expectEqual(explicitEmptyCfg.rateMetric, .total)
        T.expectEqual(explicitEmptyCfg.hideRateWhenIdle, true)
        T.expectEqual(explicitEmptyCfg.separator, .pipe)

        // Duplicate modules are deduplicated preserving order
        let dupJSON = """
        { "modules": ["tokenRate", "quota", "tokenRate", "activeModel", "quota"] }
        """
        let dupCfg = try JSONDecoder().decode(MenuBarCustomConfig.self, from: Data(dupJSON.utf8))
        T.expectEqual(dupCfg.modules, [.tokenRate, .quota, .activeModel])

        // All MenuBarDisplayMode enum cases round-trip cleanly (including .custom and .iconOnly)
        for mode in MenuBarDisplayMode.allCases {
            let encoded = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(MenuBarDisplayMode.self, from: encoded)
            T.expectEqual(decoded, mode)
        }
        T.expect(MenuBarDisplayMode.allCases.contains(.custom))
        T.expect(MenuBarDisplayMode.allCases.contains(.iconOnly))
    }

    await T.asyncSuite("AppStore.menuBarSummary.AllModesModulesFallbackAndPulsarTooltip") {
        let dir = try makeTempDir(prefix: "roryorbit-menubar-summary")
        defer { try? FileManager.default.removeItem(at: dir) }

        let regURL = dir.appendingPathComponent("registry.json")
        let kc = KeychainStore(backend: InMemoryKeychainBackend())
        let engine = TokenUsageEngine(homeDirectoryURL: dir, appSupportURL: dir)
        let exporter = AccountPoolExporter(appSupportURL: dir)
        let now = Date()

        let store = await MainActor.run {
            AppStore(
                keychain: kc,
                processController: ProcessController(inspector: MockProcessInspector()),
                adapters: [:],
                registryURL: regURL,
                startScheduler: false,
                tokenUsageEngine: engine,
                accountPoolExporter: exporter,
                persistAccountPoolExport: false
            )
        }

        let activeSpeedModel = ModelSpeedStat(
            client: .antigravity,
            modelId: "gemini-4-neon-xhigh",
            latestOutputTokPerSec: 84.6,
            averageOutputTokPerSec: 76.2,
            peakOutputTokPerSec: 112.0,
            latestTotalTokPerSec: 340.0,
            sampleCount: 12,
            lastOutputTokens: 423,
            lastDurationSec: 5.0,
            lastActiveAt: now.addingTimeInterval(-3)
        )
        let liveGeneratingSpeed = LiveTokenSpeedSnapshot(
            sampledAt: now,
            isGenerating: true,
            currentModel: activeSpeedModel,
            rollingOutputTokPerSec60s: 52.4,
            rollingTotalTokPerSec60s: 420.0,
            recentModels: [activeSpeedModel],
            modelSpeedIndex: [activeSpeedModel.id: activeSpeedModel]
        )
        let idleSpeed = LiveTokenSpeedSnapshot(
            sampledAt: now,
            isGenerating: false,
            currentModel: activeSpeedModel,
            rollingOutputTokPerSec60s: 0.0,
            rollingTotalTokPerSec60s: 0.0,
            recentModels: [activeSpeedModel],
            modelSpeedIndex: [activeSpeedModel.id: activeSpeedModel]
        )

        let todayTotals = TokenComponentTotals(
            totalTokens: 125_400,
            uncachedInputTokens: 20_000,
            outputTokens: 5_400,
            cacheReadTokens: 90_000,
            cacheWriteTokens: 10_000,
            estimatedCostUSD: 1.42,
            messageCount: 18
        )
        let todayRange = TokenRangeSummary(
            range: .today,
            startDate: "2026-11-21",
            endDate: "2026-11-21",
            totals: todayTotals,
            activeDays: 1,
            totalDaysInRange: 1,
            byClient: [TokenClientBreakdown(client: .antigravity, totals: todayTotals, shareOfTokens: 1.0, activeDays: 1)],
            byModel: [TokenModelBreakdown(client: .antigravity, modelId: "gemini-4-neon-xhigh", totals: todayTotals, shareOfTokens: 1.0)],
            byProject: [],
            dailySeries: []
        )

        let makeSnapshot: @Sendable (LiveTokenSpeedSnapshot?) -> TokenUsageSnapshot = { speed in
            TokenUsageSnapshot(
                generatedAt: now,
                lastScannedAt: now,
                seedDaysCount: 0,
                totalDaysCount: 1,
                liveScannedFilesCount: 1,
                archiveFileURLPath: dir.appendingPathComponent("daily-history-archive.json").path,
                heatmap112Days: [],
                allDays: [],
                ranges: [.today: todayRange],
                speedSnapshot: speed
            )
        }

        await MainActor.run {
            store.registry.upsertAccount(AccountRecord(
                id: "ag-1",
                provider: .antigravity,
                email: "ag@example.test",
                displayName: "AG",
                isActiveLive: true
            ))
            store.registry.upsertAccount(AccountRecord(
                id: "codex-1",
                provider: .codex,
                email: "cx@example.test",
                displayName: "Codex",
                isActiveLive: true
            ))
            store.registry.settings.selectedProvider = .antigravity
            store.registry.settings.lowQuotaWarnThreshold = 0.20

            store.snapshots[AppStore.snapshotKey(provider: .antigravity, accountId: "ag-1")] = QuotaSnapshot(
                provider: .antigravity,
                accountId: "ag-1",
                windows: [QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: 0.82, isPrimary: true)],
                status: .ready(fetchedAt: now, stale: false),
                primaryRemainingPercent: 82
            )
            store.snapshots[AppStore.snapshotKey(provider: .codex, accountId: "codex-1")] = QuotaSnapshot(
                provider: .codex,
                accountId: "codex-1",
                windows: [QuotaWindow(id: "5h", label: "5小时", remainingFraction: 0.15, isPrimary: true)],
                status: .ready(fetchedAt: now, stale: false),
                primaryRemainingPercent: 15
            )
            store.snapshots[AppStore.snapshotKey(provider: .deepseek, accountId: "deepseek:api")] = QuotaSnapshot(
                provider: .deepseek,
                accountId: "deepseek:api",
                balance: BalanceInfo(currency: "CNY", totalBalance: 15_112.66),
                status: .ready(fetchedAt: now, stale: false)
            )
            store.tokenUsage = makeSnapshot(liveGeneratingSpeed)
        }

        // 1. selectedProvider mode + Pulsar tooltip branding
        let sel = await MainActor.run { () -> (symbol: String, title: String, isWarning: Bool, tooltip: String) in
            store.registry.settings.menuBarDisplayMode = .selectedProvider
            return store.menuBarSummary()
        }
        T.expectEqual(sel.symbol, ProviderID.antigravity.symbolName)
        T.expectEqual(sel.title, "AGY 82%")
        T.expectEqual(sel.isWarning, false)
        T.expect(sel.tooltip.hasPrefix("Pulsar \(AppStore.appVersion)"), "tooltip must carry Pulsar brand header")
        T.expect(sel.tooltip.contains("实时速度: Neon 84.6 tok/s"), "tooltip must include live speed when generating")
        T.expect(sel.tooltip.contains("60s 吞吐 420 tok/s"), "tooltip must include 60s throughput")

        // 2. lowestQuota mode
        let low = await MainActor.run { () -> (symbol: String, title: String, isWarning: Bool, tooltip: String) in
            store.registry.settings.menuBarDisplayMode = .lowestQuota
            return store.menuBarSummary()
        }
        T.expectEqual(low.symbol, ProviderID.codex.symbolName)
        T.expectEqual(low.title, "Codex 15%")
        T.expectEqual(low.isWarning, true)

        // 3. compactDots & iconOnly modes
        let dots = await MainActor.run { () -> (symbol: String, title: String, isWarning: Bool, tooltip: String) in
            store.registry.settings.menuBarDisplayMode = .compactDots
            return store.menuBarSummary()
        }
        T.expectEqual(dots.symbol, "sparkles")
        T.expectEqual(dots.title, "1!")
        T.expectEqual(dots.isWarning, true)

        let iconOnly = await MainActor.run { () -> (symbol: String, title: String, isWarning: Bool, tooltip: String) in
            store.registry.settings.menuBarDisplayMode = .iconOnly
            return store.menuBarSummary()
        }
        T.expectEqual(iconOnly.symbol, "sparkles")
        T.expectEqual(iconOnly.title, "")
        T.expectEqual(iconOnly.isWarning, true)

        // 4. custom mode: all 5 modules + separator (.dot / .pipe / .space) + icon styles (.provider / .pulsar / .hidden)
        let custom5Dot = await MainActor.run { () -> (symbol: String, title: String, isWarning: Bool, tooltip: String) in
            store.registry.settings.menuBarDisplayMode = .custom
            store.updateMenuBarCustom { cfg in
                cfg.iconStyle = .provider
                cfg.modules = [.quota, .tokenRate, .todayTokens, .todayCost, .activeModel]
                cfg.quotaSource = .selected
                cfg.showProviderPrefix = true
                cfg.rateMetric = .output
                cfg.hideRateWhenIdle = false
                cfg.separator = .dot
            }
            return store.menuBarSummary()
        }
        T.expectEqual(custom5Dot.symbol, ProviderID.antigravity.symbolName)
        T.expectEqual(custom5Dot.title, "AGY 82% · 84.6 tok/s · 125.4K · $1.42 · Neon")
        T.expectEqual(custom5Dot.isWarning, false)

        // Switch rateMetric to .total, separator to .pipe, iconStyle to .pulsar, quotaSource to .fixed(.deepseek)
        let customPipeTotal = await MainActor.run { () -> (symbol: String, title: String, isWarning: Bool, tooltip: String) in
            store.updateMenuBarCustom { cfg in
                cfg.iconStyle = .pulsar
                cfg.modules = [.activeModel, .tokenRate, .quota]
                cfg.quotaSource = .fixed
                cfg.fixedQuotaProvider = .deepseek
                cfg.showProviderPrefix = true
                cfg.rateMetric = .total
                cfg.separator = .pipe
            }
            return store.menuBarSummary()
        }
        T.expectEqual(customPipeTotal.symbol, "sparkles")
        T.expectEqual(customPipeTotal.title, "Neon | 420 tok/s | DS ¥15.1k")

        // Switch iconStyle to .hidden -> symbol MUST be empty string ""
        let customHidden = await MainActor.run { () -> (symbol: String, title: String, isWarning: Bool, tooltip: String) in
            store.updateMenuBarCustom { cfg in
                cfg.iconStyle = .hidden
                cfg.modules = [.quota, .tokenRate]
                cfg.quotaSource = .fixed
                cfg.fixedQuotaProvider = .deepseek
                cfg.showProviderPrefix = false
                cfg.rateMetric = .output
                cfg.separator = .space
            }
            return store.menuBarSummary()
        }
        T.expectEqual(customHidden.symbol, "", "iconStyle == .hidden must return empty symbol")
        T.expectEqual(customHidden.title, "¥15.1k 84.6 tok/s")

        // Empty modules + hidden icon -> MUST fall back to "Pulsar"
        let customFallback = await MainActor.run { () -> (symbol: String, title: String, isWarning: Bool, tooltip: String) in
            store.updateMenuBarCustom { cfg in
                cfg.iconStyle = .hidden
                cfg.modules = []
            }
            return store.menuBarSummary()
        }
        T.expectEqual(customFallback.symbol, "")
        T.expectEqual(customFallback.title, "Pulsar", "hidden icon with empty modules must fall back to Pulsar")

        // Empty modules + visible icon -> keeps empty title
        let customIconOnly = await MainActor.run { () -> (symbol: String, title: String, isWarning: Bool, tooltip: String) in
            store.updateMenuBarCustom { cfg in
                cfg.iconStyle = .pulsar
                cfg.modules = []
            }
            return store.menuBarSummary()
        }
        T.expectEqual(customIconOnly.symbol, "sparkles")
        T.expectEqual(customIconOnly.title, "")

        // Idle state + hideRateWhenIdle toggling
        let (idleHidden, idleShown, idleOnlyRateFallback) = await MainActor.run {
            () -> ((String, String), (String, String), (String, String)) in
            store.tokenUsage = makeSnapshot(idleSpeed)
            store.updateMenuBarCustom { cfg in
                cfg.iconStyle = .provider
                cfg.modules = [.quota, .tokenRate]
                cfg.quotaSource = .lowest
                cfg.showProviderPrefix = true
                cfg.rateMetric = .output
                cfg.hideRateWhenIdle = true
                cfg.separator = .dot
            }
            let a = store.menuBarSummary()

            store.updateMenuBarCustom { cfg in
                cfg.hideRateWhenIdle = false
            }
            let b = store.menuBarSummary()

            store.updateMenuBarCustom { cfg in
                cfg.iconStyle = .hidden
                cfg.modules = [.tokenRate]
                cfg.hideRateWhenIdle = true
            }
            let c = store.menuBarSummary()
            return ((a.symbol, a.title), (b.symbol, b.title), (c.symbol, c.title))
        }
        T.expectEqual(idleHidden.0, ProviderID.codex.symbolName)
        T.expectEqual(idleHidden.1, "Codex 15%", "hideRateWhenIdle must omit tokenRate when idle")
        T.expectEqual(idleShown.1, "Codex 15% · 0 tok/s", "hideRateWhenIdle == false must show 0 tok/s when idle")
        T.expectEqual(idleOnlyRateFallback.0, "")
        T.expectEqual(idleOnlyRateFallback.1, "Pulsar", "hidden icon + only tokenRate hidden on idle must fall back to Pulsar")

        // Verify updateMenuBarCustom persisted to registry.json
        let reloaded = try RegistryData.load(from: regURL)
        T.expectEqual(reloaded.settings.menuBarCustom.iconStyle, .hidden)
        T.expectEqual(reloaded.settings.menuBarCustom.modules, [.tokenRate])
        T.expectEqual(reloaded.settings.menuBarCustom.hideRateWhenIdle, true)
    }
}

// MARK: - 13. Pure Local Live Token/s Speed Engine Regression Tests

private func testLiveTokenSpeedEngine() async {
    T.suite("TokenSpeed.FormattersModelsAndBackwardCompat") {
        // TokenFormatters.tokensPerSec
        T.expectEqual(TokenFormatters.tokensPerSec(0), "0 tok/s")
        T.expectEqual(TokenFormatters.tokensPerSec(-12.5), "0 tok/s")
        T.expectEqual(TokenFormatters.tokensPerSec(.nan), "0 tok/s")
        T.expectEqual(TokenFormatters.tokensPerSec(.infinity), "0 tok/s")
        T.expectEqual(TokenFormatters.tokensPerSec(0.04), "0 tok/s")
        T.expectEqual(TokenFormatters.tokensPerSec(0.05), "0.1 tok/s")
        T.expectEqual(TokenFormatters.tokensPerSec(64.24), "64.2 tok/s")
        T.expectEqual(TokenFormatters.tokensPerSec(142.6), "143 tok/s")
        T.expectEqual(TokenFormatters.tokensPerSec(1_240.0), "1.2k tok/s")
        T.expectEqual(TokenFormatters.tokensPerSec(12_400.0), "12k tok/s")

        // TokenFormatters.compactModelName
        T.expectEqual(TokenFormatters.compactModelName("claude-opus-5-5-high"), "Opus 5.5")
        T.expectEqual(TokenFormatters.compactModelName("claude-4-5-sonnet-20250514"), "Sonnet 4.5")
        T.expectEqual(TokenFormatters.compactModelName("claude-fable-5-2"), "Fable 5.2")
        T.expectEqual(TokenFormatters.compactModelName("gemini-4-neon-xhigh"), "Neon")
        T.expectEqual(TokenFormatters.compactModelName("gemini-4-carbon-high"), "Carbon")
        T.expectEqual(TokenFormatters.compactModelName("gemini-4-hydrogen-xhigh"), "Hydrogen")
        T.expectEqual(TokenFormatters.compactModelName("gemini-4-argon-high"), "Argon")
        T.expectEqual(TokenFormatters.compactModelName("gpt-6.1-sol"), "GPT-6.1")
        T.expectEqual(TokenFormatters.compactModelName("grok-4.7-build"), "Grok 4.7")
        T.expectEqual(TokenFormatters.compactModelName("deepseek-flash"), "DS Flash")
        T.expectEqual(TokenFormatters.compactModelName("k3.1-pro-highspeed"), "Kimi 3.1")
        T.expectEqual(TokenFormatters.compactModelName("GLM-5.3-Flash"), "GLM-5.3")
        T.expectEqual(TokenFormatters.compactModelName("unknown"), "Model")
        T.expectEqual(TokenFormatters.compactModelName("  "), "Model")

        // ModelSpeedStat sanitization & LiveTokenSpeedSnapshot.speedStat(for:modelId:)
        let now = Date()
        let opusStat = ModelSpeedStat(
            client: .claude,
            modelId: "claude-opus-5-5",
            latestOutputTokPerSec: 92.5,
            averageOutputTokPerSec: 80.0,
            peakOutputTokPerSec: 50.0, // Must clamp upward to >= max(latest, average)
            latestTotalTokPerSec: 410.0,
            sampleCount: 5,
            lastOutputTokens: 370,
            lastDurationSec: 4.0,
            lastActiveAt: now
        )
        T.expectEqual(opusStat.id, "claude::claude-opus-5-5")
        T.expectEqual(opusStat.peakOutputTokPerSec, 92.5, "peak must be at least max(latest, average)")

        let speedSnap = LiveTokenSpeedSnapshot(
            sampledAt: now,
            isGenerating: true,
            currentModel: opusStat,
            rollingOutputTokPerSec60s: 30.0,
            rollingTotalTokPerSec60s: 120.0,
            recentModels: [opusStat],
            modelSpeedIndex: [opusStat.id: opusStat]
        )
        T.expectEqual(speedSnap.speedStat(for: .claude, modelId: "claude-opus-5-5"), opusStat)
        T.expectEqual(speedSnap.speedStat(for: .antigravity, modelId: "claude-opus-5-5"), nil)
        T.expectEqual(speedSnap.speedStat(for: .claude, modelId: "other-model"), nil)

        // TokenUsageSnapshot backward-compatible decoding (without speedSnapshot key & with speedSnapshot key)
        let fullSnap = TokenUsageSnapshot(
            generatedAt: now,
            lastScannedAt: now,
            seedDaysCount: 0,
            totalDaysCount: 0,
            liveScannedFilesCount: 0,
            archiveFileURLPath: "/tmp/archive.json",
            heatmap112Days: [],
            allDays: [],
            ranges: [:],
            speedSnapshot: speedSnap
        )
        let encodedWithSpeed = try JSONEncoder().encode(fullSnap)
        let decodedWithSpeed = try JSONDecoder().decode(TokenUsageSnapshot.self, from: encodedWithSpeed)
        T.expectEqual(decodedWithSpeed.speedSnapshot?.currentModel?.id, "claude::claude-opus-5-5")

        var dict = try JSONSerialization.jsonObject(with: encodedWithSpeed, options: []) as! [String: Any]
        dict.removeValue(forKey: "speedSnapshot")
        let legacyData = try JSONSerialization.data(withJSONObject: dict, options: [])
        let decodedLegacy = try JSONDecoder().decode(TokenUsageSnapshot.self, from: legacyData)
        T.expectEqual(decodedLegacy.speedSnapshot, nil, "legacy TokenUsageSnapshot without speedSnapshot must decode cleanly")
    }

    await T.asyncSuite("TokenUsageEngine.sampleLiveSpeed.SyntheticSpeedAndOutlierFiltering") {
        let homeDir = try makeTempDir(prefix: "roryorbit-speed-home")
        let supportDir = try makeTempDir(prefix: "roryorbit-speed-support")
        defer {
            try? FileManager.default.removeItem(at: homeDir)
            try? FileManager.default.removeItem(at: supportDir)
        }

        let now = Date()
        func iso(_ offsetSec: TimeInterval) -> String {
            Formatters.formatRFC3339UTC(now.addingTimeInterval(offsetSec))
        }

        // 1. Write synthetic Claude Code JSONL containing:
        //    - Outlier A: duration = 0.10s (< 0.25s) -> MUST be filtered out
        //    - Outlier B: duration = 200.0s (> 180s) -> MUST be filtered out
        //    - Outlier C: rate = 25,000 tok/s (> 20,000 tok/s) -> MUST be filtered out
        //    - Valid turn 1: claude-opus-5-5, dt = 4.0s, out = 400 -> 100.0 tok/s
        //    - Valid turn 2: claude-opus-5-5, dt = 2.0s, out = 300 -> 150.0 tok/s
        let claudeProjDir = homeDir
            .appendingPathComponent(".claude/projects/demo-speed", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeProjDir, withIntermediateDirectories: true)
        let claudeJSONL = claudeProjDir.appendingPathComponent("session-speed.jsonl")

        let claudeLines: [String] = [
            // Outlier B: > 180s (200s)
            #"{"type":"user","timestamp":"\#(iso(-250.0))","cwd":"/tmp/demo"}"#,
            #"{"type":"assistant","timestamp":"\#(iso(-50.0))","cwd":"/tmp/demo","message":{"id":"msg_too_long","model":"claude-haiku-4-5","usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
            // Outlier A: < 0.25s (0.10s)
            #"{"type":"user","timestamp":"\#(iso(-20.10))","cwd":"/tmp/demo"}"#,
            #"{"type":"assistant","timestamp":"\#(iso(-20.00))","cwd":"/tmp/demo","message":{"id":"msg_too_short","model":"claude-sonnet-4-5","usage":{"input_tokens":50,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
            // Outlier C: > 20,000 tok/s (25,000 tok / 1.0s)
            #"{"type":"user","timestamp":"\#(iso(-15.0))","cwd":"/tmp/demo"}"#,
            #"{"type":"assistant","timestamp":"\#(iso(-14.0))","cwd":"/tmp/demo","message":{"id":"msg_too_fast","model":"claude-fable-5-2","usage":{"input_tokens":100,"output_tokens":25000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
            // Valid Turn 1: 400 output / 4.0s = 100.0 tok/s (total = 1000)
            #"{"type":"user","timestamp":"\#(iso(-10.0))","cwd":"/tmp/demo"}"#,
            #"{"type":"assistant","timestamp":"\#(iso(-6.0))","cwd":"/tmp/demo","message":{"id":"msg_valid_1","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":400,"cache_read_input_tokens":500,"cache_creation_input_tokens":0}}}"#,
            // Valid Turn 2: 300 output / 2.0s = 150.0 tok/s (total = 600)
            #"{"type":"user","timestamp":"\#(iso(-4.0))","cwd":"/tmp/demo"}"#,
            #"{"type":"assistant","timestamp":"\#(iso(-2.0))","cwd":"/tmp/demo","message":{"id":"msg_valid_2","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":300,"cache_read_input_tokens":200,"cache_creation_input_tokens":0}}}"#,
        ]
        try (claudeLines.joined(separator: "\n") + "\n").write(to: claudeJSONL, atomically: true, encoding: .utf8)

        // 2. Write synthetic Grok usage.json with 1 valid turn (120 out / 2.0s = 60 tok/s) + 2 outliers (<0.25s and >180s)
        let grokSessionDir = homeDir
            .appendingPathComponent(".grok/sessions/demo-cwd/sess-1", isDirectory: true)
        try FileManager.default.createDirectory(at: grokSessionDir, withIntermediateDirectories: true)
        let grokUsageJSON = """
        {
          "updatedAt": "\(iso(-8.0))",
          "turns": [
            {
              "turnNumber": 1,
              "startedAt": "\(iso(-30.0))",
              "endedAt": "\(iso(-29.9))",
              "apiDurationMs": 100,
              "primaryModelId": "grok-too-short",
              "outputTokens": 40,
              "inputTokens": 40,
              "totalTokens": 80
            },
            {
              "turnNumber": 2,
              "startedAt": "\(iso(-240.0))",
              "endedAt": "\(iso(-40.0))",
              "apiDurationMs": 200000,
              "primaryModelId": "grok-too-long",
              "outputTokens": 400,
              "inputTokens": 100,
              "totalTokens": 500
            },
            {
              "turnNumber": 3,
              "startedAt": "\(iso(-10.0))",
              "endedAt": "\(iso(-8.0))",
              "apiDurationMs": 2000,
              "primaryModelId": "grok-4.7-build",
              "outputTokens": 120,
              "inputTokens": 80,
              "totalTokens": 200
            }
          ]
        }
        """
        try grokUsageJSON.write(
            to: grokSessionDir.appendingPathComponent("usage.json"),
            atomically: true,
            encoding: .utf8
        )

        let engine = TokenUsageEngine(homeDirectoryURL: homeDir, appSupportURL: supportDir)
        let speed = await engine.sampleLiveSpeed(now: now)

        // Verify pure read-only: sampleLiveSpeed MUST NOT create archive or scan cache files
        T.expect(
            !FileManager.default.fileExists(atPath: supportDir.appendingPathComponent("daily-history-archive.json").path),
            "sampleLiveSpeed must not write daily-history-archive.json"
        )
        T.expect(
            !FileManager.default.fileExists(atPath: supportDir.appendingPathComponent("token-scan-cache.json").path),
            "sampleLiveSpeed must not write token-scan-cache.json"
        )

        // Verify all outliers were filtered out
        T.expectEqual(speed.speedStat(for: .claude, modelId: "claude-sonnet-4-5"), nil, "<0.25s outlier must be filtered out")
        T.expectEqual(speed.speedStat(for: .claude, modelId: "claude-haiku-4-5"), nil, ">180s outlier must be filtered out")
        T.expectEqual(speed.speedStat(for: .claude, modelId: "claude-fable-5-2"), nil, ">20_000 tok/s outlier must be filtered out")
        T.expectEqual(speed.speedStat(for: .grok, modelId: "grok-too-short"), nil, "Grok <0.25s outlier must be filtered out")
        T.expectEqual(speed.speedStat(for: .grok, modelId: "grok-too-long"), nil, "Grok >180s outlier must be filtered out")

        // Verify valid Claude Opus 5.5 speed calculations
        T.expectEqual(speed.isGenerating, true, "active turn 2s ago must report isGenerating == true")
        T.expectEqual(speed.currentModel?.id, "claude::claude-opus-5-5", "most recent model must be currentModel")
        if let opus = speed.speedStat(for: .claude, modelId: "claude-opus-5-5") {
            T.expectEqual(opus.sampleCount, 2)
            T.expect(abs(opus.latestOutputTokPerSec - 150.0) < 0.5, "latest output speed expected ~150.0, got \(opus.latestOutputTokPerSec)")
            let expectedAvg = 700.0 / 6.0 // (400 + 300) / (4 + 2) = 116.67
            T.expect(abs(opus.averageOutputTokPerSec - expectedAvg) < 0.5, "average output speed expected ~116.67, got \(opus.averageOutputTokPerSec)")
            T.expect(abs(opus.peakOutputTokPerSec - 150.0) < 0.5, "peak output speed expected ~150.0, got \(opus.peakOutputTokPerSec)")
        } else {
            T.expect(false, "expected claude::claude-opus-5-5 speed stat")
        }

        // Verify valid Grok speed calculation & ordering in recentModels
        if let grok = speed.speedStat(for: .grok, modelId: "grok-4.7-build") {
            T.expectEqual(grok.sampleCount, 1)
            T.expect(abs(grok.latestOutputTokPerSec - 60.0) < 0.5, "Grok output speed expected ~60.0, got \(grok.latestOutputTokPerSec)")
        } else {
            T.expect(false, "expected grok::grok-4.7-build speed stat")
        }
        T.expectEqual(speed.recentModels.map(\.id), ["claude::claude-opus-5-5", "grok::grok-4.7-build"])

        // Verify rolling 60s throughput: (400 + 300 + 120) / 60 = 13.67 tok/s output; (1000 + 600 + 200) / 60 = 30.0 tok/s total
        T.expect(abs(speed.rollingOutputTokPerSec60s - (820.0 / 60.0)) < 0.5, "rolling 60s output speed mismatch: \(speed.rollingOutputTokPerSec60s)")
        T.expect(abs(speed.rollingTotalTokPerSec60s - (1800.0 / 60.0)) < 0.5, "rolling 60s total speed mismatch: \(speed.rollingTotalTokPerSec60s)")

        // Verify scanAndExportArchive populates speedSnapshot & smoke report prints speed section
        let fullSnapshot = await engine.scanAndExportArchive(forceFullRescan: true)
        T.expect(fullSnapshot.speedSnapshot != nil, "scanAndExportArchive must populate speedSnapshot")
        T.expectEqual(fullSnapshot.speedSnapshot?.speedStat(for: .claude, modelId: "claude-opus-5-5")?.sampleCount, 2)
        let smokeReport = TokenUsageEngine.formatSmokeReport(fullSnapshot)
        T.expect(smokeReport.contains("tok/s"), "smoke report must display tok/s metrics")
        T.expect(smokeReport.contains("近60s合并输出:") && smokeReport.contains("近60s总吞吐:"), "smoke report must display 60s rolling throughput")
    }
}

// MARK: - 14. Phase 2 Regression Tests (Brand Icons, Window Sizing, Card Customization, Quota Windows & 14 Modules)

private func testPhase2RegressionSuite() async {
    // 14.1 Official Provider Brand Icons
    T.suite("Phase2.OfficialProviderBrandIcons") {
        ProviderBrandIcon.clearCache()

        let expectedProviders: [ProviderID] = [.antigravity, .codex, .grok, .cursor, .kimi, .deepseek]
        T.expectEqual(ProviderID.allCases, expectedProviders, "all 6 providers must be present")

        // Verify template vs full-color classification
        T.expectEqual(ProviderBrandIcon.isTemplateMark(for: .codex), true)
        T.expectEqual(ProviderBrandIcon.isMonochromeMark(for: .codex), true)
        T.expectEqual(ProviderBrandIcon.isTemplateMark(for: .grok), true)
        T.expectEqual(ProviderBrandIcon.isMonochromeMark(for: .grok), true)
        T.expectEqual(ProviderBrandIcon.isTemplateMark(for: .antigravity), false)
        T.expectEqual(ProviderBrandIcon.isMonochromeMark(for: .antigravity), false)
        T.expectEqual(ProviderBrandIcon.isTemplateMark(for: .cursor), false)
        T.expectEqual(ProviderBrandIcon.isTemplateMark(for: .kimi), false)
        T.expectEqual(ProviderBrandIcon.isTemplateMark(for: .deepseek), false)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
        let assetsIconsDir = repoRoot.appendingPathComponent("Assets/ProviderIcons", isDirectory: true)
        let bundleIconsDir = repoRoot.appendingPathComponent("RoryOrbit.app/Contents/Resources/ProviderIcons", isDirectory: true)
        let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])

        for provider in expectedProviders {
            // 1. Source asset PNG & valid PNG header
            let assetURL = assetsIconsDir.appendingPathComponent("\(provider.rawValue).png")
            T.expect(FileManager.default.fileExists(atPath: assetURL.path), "Assets/ProviderIcons/\(provider.rawValue).png must exist")
            let assetData = try Data(contentsOf: assetURL)
            T.expect(assetData.count > 100 && assetData.prefix(4) == pngSignature, "\(provider.rawValue).png must be a valid non-empty PNG")

            // 2. Packaged .app/Contents/Resources/ProviderIcons/ PNG
            let bundledURL = bundleIconsDir.appendingPathComponent("\(provider.rawValue).png")
            T.expect(FileManager.default.fileExists(atPath: bundledURL.path), "RoryOrbit.app/Contents/Resources/ProviderIcons/\(provider.rawValue).png must be packaged")
            let bundledData = try Data(contentsOf: bundledURL)
            T.expect(bundledData.count > 100 && bundledData.prefix(4) == pngSignature, "packaged \(provider.rawValue).png must be a valid PNG")
            let bundledImg = NSImage(contentsOf: bundledURL)
            T.expect(bundledImg != nil && bundledImg!.isValid, "packaged \(provider.rawValue).png must decode via NSImage")

            // 3. Loader resolves URL, caches base image, applies isTemplate accurately
            let resolvedURL = ProviderBrandIcon.resourceURL(for: provider)
            T.expect(resolvedURL != nil && resolvedURL!.lastPathComponent == "\(provider.rawValue).png", "resourceURL must resolve \(provider.rawValue).png")
            T.expectEqual(ProviderBrandIcon.hasOfficialAsset(for: provider), true)

            guard let base1 = ProviderBrandIcon.image(for: provider),
                  let base2 = ProviderBrandIcon.image(for: provider) else {
                T.expect(false, "ProviderBrandIcon.image(for: \(provider.rawValue)) returned nil")
                continue
            }
            T.expect(base1 === base2, "base image cache must return the same NSImage instance")
            T.expect(base1.isValid && !base1.representations.isEmpty, "base image must be valid with representations")
            T.expectEqual(base1.isTemplate, ProviderBrandIcon.isTemplateMark(for: provider), "base image isTemplate must match isTemplateMark")
            let origBaseSize = base1.size
            T.expect(origBaseSize.width > 15 && origBaseSize.height > 15, "base image must keep full resolution (>15pt), got \(origBaseSize)")

            // 4. menuBarImage returns independent sized copy without polluting base cache
            guard let mb15 = ProviderBrandIcon.menuBarImage(for: provider, size: 15),
                  let mb20 = ProviderBrandIcon.menuBarImage(for: provider, size: 20),
                  let mbTiny = ProviderBrandIcon.menuBarImage(for: provider, size: 2) else {
                T.expect(false, "ProviderBrandIcon.menuBarImage(for: \(provider.rawValue)) returned nil")
                continue
            }
            T.expect(mb15 !== base1, "menuBarImage must be a distinct copy from baseImageCache")
            T.expect(mb20 !== base1 && mb20 !== mb15, "distinct menuBarImage sizes must not alias each other")
            T.expectEqual(mb15.size, NSSize(width: 15, height: 15))
            T.expectEqual(mb20.size, NSSize(width: 20, height: 20))
            T.expectEqual(mbTiny.size, NSSize(width: 8, height: 8), "menuBarImage size must clamp lower bound to 8pt")
            T.expectEqual(mb15.isTemplate, ProviderBrandIcon.isTemplateMark(for: provider), "menuBarImage isTemplate must match isTemplateMark")

            // Verify base cache remained completely unpolluted
            let baseAfter = ProviderBrandIcon.image(for: provider)
            T.expect(baseAfter === base1, "base image cache identity must survive menuBarImage calls")
            T.expectEqual(baseAfter?.size, origBaseSize, "menuBarImage must NOT mutate base image size")
        }
    }

    // 14.2 Window Size Clamping, NaN/Inf Guard & Persistence
    T.suite("Phase2.WindowSizingBackwardCompatClampingAndNaNInf") {
        // Verify constants & ranges (updated for v1.1.0 unified popover)
        T.expectEqual(AppSettings.defaultPopoverWidth, 390)
        T.expectEqual(AppSettings.defaultPopoverHeight, 620)
        T.expectEqual(AppSettings.defaultDashboardWidth, 520)
        T.expectEqual(AppSettings.defaultDashboardHeight, 680)
        T.expectEqual(AppSettings.popoverWidthRange, 340...680)
        T.expectEqual(AppSettings.popoverHeightRange, 460...920)
        T.expectEqual(AppSettings.dashboardWidthRange, 380...1100)
        T.expectEqual(AppSettings.dashboardHeightRange, 460...1100)

        // Legacy JSON missing all Phase 2 / v1.1.0 fields decodes with exact defaults
        let legacyJSON = """
        {
          "enabledProviders": ["antigravity", "codex"],
          "selectedProvider": "antigravity"
        }
        """
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))
        T.expectEqual(legacy.popoverWidth, 390)
        T.expectEqual(legacy.popoverHeight, 620)
        T.expectEqual(legacy.dashboardWidth, 520)
        T.expectEqual(legacy.dashboardHeight, 680)
        T.expectEqual(legacy.tokenPopoverCards, .default)
        T.expectEqual(legacy.tokenDashboardCards, .default)
        T.expectEqual(legacy.accountCardConfig, .default)
        T.expectEqual(legacy.tokenClientOrder, [])

        // Out-of-bounds clamping via JSON decode
        let tooSmallJSON = """
        { "popoverWidth": 120, "popoverHeight": 200, "dashboardWidth": 150, "dashboardHeight": 100 }
        """
        let clampedLow = try JSONDecoder().decode(AppSettings.self, from: Data(tooSmallJSON.utf8))
        T.expectEqual(clampedLow.popoverWidth, 340)
        T.expectEqual(clampedLow.popoverHeight, 460)
        T.expectEqual(clampedLow.dashboardWidth, 380)
        T.expectEqual(clampedLow.dashboardHeight, 460)

        let tooLargeJSON = """
        { "popoverWidth": 2000, "popoverHeight": 3000, "dashboardWidth": 5000, "dashboardHeight": 4000 }
        """
        let clampedHigh = try JSONDecoder().decode(AppSettings.self, from: Data(tooLargeJSON.utf8))
        T.expectEqual(clampedHigh.popoverWidth, 680)
        T.expectEqual(clampedHigh.popoverHeight, 920)
        T.expectEqual(clampedHigh.dashboardWidth, 1100)
        T.expectEqual(clampedHigh.dashboardHeight, 1100)

        // Exact boundary preservation
        let exactBounds = AppSettings(popoverWidth: 340, popoverHeight: 920, dashboardWidth: 1100, dashboardHeight: 460)
        T.expectEqual(exactBounds.popoverWidth, 340)
        T.expectEqual(exactBounds.popoverHeight, 920)
        T.expectEqual(exactBounds.dashboardWidth, 1100)
        T.expectEqual(exactBounds.dashboardHeight, 460)

        // NaN / +Inf / -Inf guards
        T.expectEqual(AppSettings.clamp(.nan, to: AppSettings.popoverWidthRange, fallback: 390), 390)
        T.expectEqual(AppSettings.clamp(.signalingNaN, to: AppSettings.popoverHeightRange, fallback: 620), 620)
        T.expectEqual(AppSettings.clamp(.infinity, to: AppSettings.dashboardWidthRange, fallback: 520), 520)
        T.expectEqual(AppSettings.clamp(-.infinity, to: AppSettings.dashboardHeightRange, fallback: 680), 680)

        let nonFiniteSettings = AppSettings(
            popoverWidth: .nan,
            popoverHeight: .infinity,
            dashboardWidth: -.infinity,
            dashboardHeight: .signalingNaN
        )
        T.expectEqual(nonFiniteSettings.popoverWidth, 390)
        T.expectEqual(nonFiniteSettings.popoverHeight, 620)
        T.expectEqual(nonFiniteSettings.dashboardWidth, 520)
        T.expectEqual(nonFiniteSettings.dashboardHeight, 680)
    }

    await T.asyncSuite("Phase2.AppStoreWindowSizePersistenceAndReset") {
        let dir = try makeTempDir(prefix: "roryorbit-phase2-winsize")
        defer { try? FileManager.default.removeItem(at: dir) }

        let regURL = dir.appendingPathComponent("registry.json")
        let kc = KeychainStore(backend: InMemoryKeychainBackend())
        let engine = TokenUsageEngine(homeDirectoryURL: dir, appSupportURL: dir)
        let exporter = AccountPoolExporter(appSupportURL: dir)

        let store = await MainActor.run {
            AppStore(
                keychain: kc,
                processController: ProcessController(inspector: MockProcessInspector()),
                adapters: [:],
                registryURL: regURL,
                startScheduler: false,
                tokenUsageEngine: engine,
                accountPoolExporter: exporter,
                persistAccountPoolExport: false
            )
        }

        // Immediate update + clamping
        await MainActor.run {
            store.updatePopoverSize(width: 520, height: 1200, persistImmediately: true)
            store.updateDashboardSize(width: 200, height: 900, persistImmediately: true)
        }
        let persisted1 = try RegistryData.load(from: regURL)
        T.expectEqual(persisted1.settings.popoverWidth, 520)
        T.expectEqual(persisted1.settings.popoverHeight, 920, "popoverHeight must clamp to 920")
        T.expectEqual(persisted1.settings.dashboardWidth, 380, "dashboardWidth must clamp to 380")
        T.expectEqual(persisted1.settings.dashboardHeight, 900)

        // NaN / Inf guard via AppStore methods
        await MainActor.run {
            store.updatePopoverSize(width: .nan, height: -.infinity, persistImmediately: true)
            store.updateDashboardSize(width: .infinity, height: .nan, persistImmediately: true)
        }
        let persistedNonFinite = try RegistryData.load(from: regURL)
        T.expectEqual(persistedNonFinite.settings.popoverWidth, 390)
        T.expectEqual(persistedNonFinite.settings.popoverHeight, 620)
        T.expectEqual(persistedNonFinite.settings.dashboardWidth, 520)
        T.expectEqual(persistedNonFinite.settings.dashboardHeight, 680)

        // Debounced save (persistImmediately: false) -> flushes to disk after debounce window
        await MainActor.run {
            store.updatePopoverSize(width: 360, height: 500, persistImmediately: false)
            store.updateDashboardSize(width: 720, height: 840, persistImmediately: false)
        }
        try await Task.sleep(nanoseconds: 380_000_000)
        let persistedDebounced = try RegistryData.load(from: regURL)
        T.expectEqual(persistedDebounced.settings.popoverWidth, 360)
        T.expectEqual(persistedDebounced.settings.popoverHeight, 500)
        T.expectEqual(persistedDebounced.settings.dashboardWidth, 720)
        T.expectEqual(persistedDebounced.settings.dashboardHeight, 840)

        // resetWindowSizes restores all defaults & persists immediately
        await MainActor.run {
            store.resetWindowSizes()
        }
        let persistedReset = try RegistryData.load(from: regURL)
        T.expectEqual(persistedReset.settings.popoverWidth, 390)
        T.expectEqual(persistedReset.settings.popoverHeight, 620)
        T.expectEqual(persistedReset.settings.dashboardWidth, 520)
        T.expectEqual(persistedReset.settings.dashboardHeight, 680)
    }

    // 14.3 Card Customization Configs (Popover, Dashboard, AccountCard)
    T.suite("Phase2.CardCustomizationConfigs") {
        // PopoverTokenCardConfig: 6 cards, default 4 visible
        T.expectEqual(PopoverTokenCard.allCases.count, 6)
        var pop = PopoverTokenCardConfig.default
        T.expectEqual(pop.orderedCards, [.summary, .liveSpeed, .dailyTrend, .clientBreakdown, .topModels, .miniHeatmap])
        T.expectEqual(pop.enabledCards, [.summary, .liveSpeed, .dailyTrend, .clientBreakdown])
        T.expectEqual(pop.visibleCards, [.summary, .liveSpeed, .dailyTrend, .clientBreakdown])
        T.expectEqual(pop.compactDensity, false)
        T.expectEqual(pop.isEnabled(.summary), true)
        T.expectEqual(pop.isEnabled(.topModels), false)
        T.expectEqual(pop.isEnabled(.miniHeatmap), false)

        // Toggle & reorder Popover cards
        pop.toggleCard(.topModels)
        pop.setCard(.miniHeatmap, enabled: true)
        pop.toggleCard(.summary)
        T.expectEqual(pop.isEnabled(.summary), false)
        T.expectEqual(pop.visibleCards, [.liveSpeed, .dailyTrend, .clientBreakdown, .topModels, .miniHeatmap])

        T.expectEqual(pop.canMoveCard(.summary, direction: .up), false)
        T.expectEqual(pop.canMoveCard(.miniHeatmap, direction: .down), false)
        T.expectEqual(pop.canMoveCard(.miniHeatmap, direction: .up), true)
        pop.moveCard(.miniHeatmap, direction: .up)
        T.expectEqual(pop.orderedCards[4], .miniHeatmap)
        T.expectEqual(pop.orderedCards[5], .topModels)
        T.expectEqual(pop.visibleCards, [.liveSpeed, .dailyTrend, .clientBreakdown, .miniHeatmap, .topModels])

        // Explicit empty enabledCards preserved on JSON decode
        let popEmptyJSON = """
        { "enabledCards": [], "compactDensity": true }
        """
        let popEmpty = try JSONDecoder().decode(PopoverTokenCardConfig.self, from: Data(popEmptyJSON.utf8))
        T.expectEqual(popEmpty.enabledCards, [], "explicit empty Popover enabledCards must be preserved")
        T.expectEqual(popEmpty.visibleCards, [])
        T.expectEqual(popEmpty.orderedCards.count, 6, "missing orderedCards must default to all 6 cards")
        T.expectEqual(popEmpty.compactDensity, true)

        // Partial/duplicated/unknown orderedCards auto-completes missing enum cases
        let popPartialJSON = """
        { "orderedCards": ["miniHeatmap", "summary", "miniHeatmap", "unknownCardV99"] }
        """
        let popPartial = try JSONDecoder().decode(PopoverTokenCardConfig.self, from: Data(popPartialJSON.utf8))
        T.expectEqual(
            popPartial.orderedCards,
            [.miniHeatmap, .summary, .liveSpeed, .dailyTrend, .clientBreakdown, .topModels],
            "missing Popover cards must auto-append in canonical order after deduplication"
        )
        T.expectEqual(popPartial.enabledCards, PopoverTokenCardConfig.defaultEnabledCards)

        // DashboardTokenCardConfig: 5 cards, default all 5 visible
        T.expectEqual(DashboardTokenCard.allCases.count, 5)
        var dash = DashboardTokenCardConfig.default
        T.expectEqual(dash.orderedCards, [.kpiGrid, .liveSpeed, .heatmap, .dailyTrend, .deepBreakdown])
        T.expectEqual(dash.enabledCards, [.kpiGrid, .liveSpeed, .heatmap, .dailyTrend, .deepBreakdown])
        T.expectEqual(dash.visibleCards.count, 5)
        T.expectEqual(dash.compactDensity, false)

        dash.toggleCard(.heatmap)
        dash.moveCard(.deepBreakdown, direction: .up)
        T.expectEqual(dash.visibleCards, [.kpiGrid, .liveSpeed, .deepBreakdown, .dailyTrend])
        T.expectEqual(dash.canMoveCard(.kpiGrid, direction: .up), false)
        T.expectEqual(dash.canMoveCard(.dailyTrend, direction: .down), false)

        let dashEmptyJSON = """
        { "orderedCards": ["deepBreakdown", "deepBreakdown", "bogus"], "enabledCards": [], "compactDensity": true }
        """
        let dashDecoded = try JSONDecoder().decode(DashboardTokenCardConfig.self, from: Data(dashEmptyJSON.utf8))
        T.expectEqual(dashDecoded.orderedCards, [.deepBreakdown, .kpiGrid, .liveSpeed, .heatmap, .dailyTrend])
        T.expectEqual(dashDecoded.enabledCards, [], "explicit empty Dashboard enabledCards must be preserved")
        T.expectEqual(dashDecoded.visibleCards, [])
        T.expectEqual(dashDecoded.compactDensity, true)

        // AccountCardConfig: all toggles & pillQuotaWindow default .weeklyFirst
        let accDefault = AccountCardConfig.default
        T.expectEqual(accDefault.showAvatar, true)
        T.expectEqual(accDefault.showFiveHour, true)
        T.expectEqual(accDefault.showWeekly, true)
        T.expectEqual(accDefault.showResetFootnote, true)
        T.expectEqual(accDefault.showSourceBadge, true)
        T.expectEqual(accDefault.compactDensity, false)
        T.expectEqual(accDefault.pillQuotaWindow, .weeklyFirst)

        let accCustom = AccountCardConfig(
            showAvatar: false,
            showFiveHour: false,
            showWeekly: true,
            showResetFootnote: false,
            showSourceBadge: false,
            compactDensity: true,
            pillQuotaWindow: .both5hAndWeekly
        )
        let accEncoded = try JSONEncoder().encode(accCustom)
        let accRoundTrip = try JSONDecoder().decode(AccountCardConfig.self, from: accEncoded)
        T.expectEqual(accRoundTrip, accCustom)

        let accEmptyDecoded = try JSONDecoder().decode(AccountCardConfig.self, from: Data("{}".utf8))
        T.expectEqual(accEmptyDecoded, .default)

        let accUnknownWindow = try JSONDecoder().decode(
            AccountCardConfig.self,
            from: Data(#"{"pillQuotaWindow":"nonexistent_window"}"#.utf8)
        )
        T.expectEqual(accUnknownWindow.pillQuotaWindow, .weeklyFirst)
    }

    // 14.4 Quota Extraction, Weekly/Dual Formatting, Multi-Provider, 14 Modules, Icon Linkage & Pill Badge Info
    await T.asyncSuite("Phase2.QuotaMetricsWeeklyDualMulti14ModulesAndPills") {
        let dir = try makeTempDir(prefix: "roryorbit-phase2-menubar")
        defer { try? FileManager.default.removeItem(at: dir) }

        let regURL = dir.appendingPathComponent("registry.json")
        let kc = KeychainStore(backend: InMemoryKeychainBackend())
        let engine = TokenUsageEngine(homeDirectoryURL: dir, appSupportURL: dir)
        let exporter = AccountPoolExporter(appSupportURL: dir)
        let now = Date()

        // A. Formatters.compactResetCountdown coverage
        T.expectEqual(Formatters.compactResetCountdown(to: nil, now: now), nil)
        T.expectEqual(Formatters.compactResetCountdown(to: now.addingTimeInterval(-10), now: now), "即将重置")
        T.expectEqual(Formatters.compactResetCountdown(to: now.addingTimeInterval(35), now: now), "<1m")
        T.expectEqual(Formatters.compactResetCountdown(to: now.addingTimeInterval(45 * 60), now: now), "45m")
        T.expectEqual(Formatters.compactResetCountdown(to: now.addingTimeInterval(2 * 3600 + 15 * 60), now: now), "2h15m")
        T.expectEqual(Formatters.compactResetCountdown(to: now.addingTimeInterval(3 * 86400 + 4 * 3600), now: now), "3d4h")

        // B. AppStore.extractQuotaMetrics across all 6 providers
        let agResetClaude5h = now.addingTimeInterval(2 * 3600 + 15 * 60 + 45)
        let agResetGemini5h = now.addingTimeInterval(3 * 3600)
        let agResetArgonWk = now.addingTimeInterval(3 * 86400)
        let agSnap = QuotaSnapshot(
            provider: .antigravity,
            accountId: "ag-1",
            windows: [
                QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: 0.70, resetAt: agResetGemini5h, windowSeconds: 18_000, isPrimary: true),
                QuotaWindow(id: "gemini_week", label: "Gemini · 周", remainingFraction: 0.90, resetAt: now.addingTimeInterval(4 * 86400), windowSeconds: 604_800),
                QuotaWindow(id: "claude_5h", label: "Claude · 5小时", remainingFraction: 0.45, resetAt: agResetClaude5h, windowSeconds: 18_000),
                QuotaWindow(id: "claude_week", label: "Claude · 周", remainingFraction: 0.80, resetAt: now.addingTimeInterval(5 * 86400), windowSeconds: 604_800),
                QuotaWindow(id: "argon_week", label: "Argon · 周", remainingFraction: 0.60, resetAt: agResetArgonWk, windowSeconds: 604_800),
            ],
            status: .ready(fetchedAt: now, stale: false)
        )

        let agAuto = AppStore.extractQuotaMetrics(for: .antigravity, snapshot: agSnap, agPool: .autoLowest, now: now)
        T.expectEqual(agAuto.isReady, true)
        T.expectEqual(agAuto.fiveHourPercent, 45.0)
        T.expectEqual(agAuto.weeklyPercent, 60.0)
        T.expectEqual(agAuto.lowestPercent, 45.0)
        T.expectEqual(agAuto.nextReset, agResetClaude5h)

        let agGemini = AppStore.extractQuotaMetrics(for: .antigravity, snapshot: agSnap, agPool: .gemini, now: now)
        T.expectEqual(agGemini.fiveHourPercent, 70.0)
        T.expectEqual(agGemini.weeklyPercent, 90.0)
        T.expectEqual(agGemini.lowestPercent, 70.0)
        T.expectEqual(agGemini.nextReset, agResetGemini5h)

        let agClaude = AppStore.extractQuotaMetrics(for: .antigravity, snapshot: agSnap, agPool: .claude, now: now)
        T.expectEqual(agClaude.fiveHourPercent, 45.0)
        T.expectEqual(agClaude.weeklyPercent, 80.0)
        T.expectEqual(agClaude.lowestPercent, 45.0)

        let agArgon = AppStore.extractQuotaMetrics(for: .antigravity, snapshot: agSnap, agPool: .argon, now: now)
        T.expectEqual(agArgon.fiveHourPercent, nil)
        T.expectEqual(agArgon.weeklyPercent, 60.0)
        T.expectEqual(agArgon.lowestPercent, 60.0)
        T.expectEqual(agArgon.nextReset, agResetArgonWk)

        // Codex: must ignore add_* additional rate-limit windows when core windows exist
        let codexReset = now.addingTimeInterval(2 * 3600 + 15 * 60 + 45)
        let codexSnap = QuotaSnapshot(
            provider: .codex,
            accountId: "codex-1",
            windows: [
                QuotaWindow(id: "5h", label: "5小时", remainingFraction: 0.49, resetAt: codexReset, windowSeconds: 18_000, isPrimary: true),
                QuotaWindow(id: "week", label: "本周", remainingFraction: 0.99, resetAt: now.addingTimeInterval(6 * 86400), windowSeconds: 604_800),
                QuotaWindow(id: "add_spark_5h", label: "Spark 5小时", remainingFraction: 0.05, windowSeconds: 18_000),
                QuotaWindow(id: "add_spark_week", label: "Spark 本周", remainingFraction: 0.10, windowSeconds: 604_800),
            ],
            status: .ready(fetchedAt: now, stale: false)
        )
        let codexMetrics = AppStore.extractQuotaMetrics(for: .codex, snapshot: codexSnap, now: now)
        T.expectEqual(codexMetrics.fiveHourPercent, 49.0, "Codex 5h must ignore add_* windows")
        T.expectEqual(codexMetrics.weeklyPercent, 99.0, "Codex weekly must ignore add_* windows")
        T.expectEqual(codexMetrics.lowestPercent, 49.0, "Codex lowest must ignore add_* windows")

        // Kimi: 5h + weekly windows
        let kimiSnap = QuotaSnapshot(
            provider: .kimi,
            accountId: "kimi:api",
            windows: [
                QuotaWindow(id: "5h", label: "5小时", remainingFraction: 0.85, windowSeconds: 18_000, isPrimary: true),
                QuotaWindow(id: "weekly", label: "每周", remainingFraction: 0.62, windowSeconds: 604_800),
            ],
            status: .ready(fetchedAt: now, stale: false)
        )
        let kimiMetrics = AppStore.extractQuotaMetrics(for: .kimi, snapshot: kimiSnap, now: now)
        T.expectEqual(kimiMetrics.fiveHourPercent, 85.0)
        T.expectEqual(kimiMetrics.weeklyPercent, 62.0)
        T.expectEqual(kimiMetrics.lowestPercent, 62.0)

        // Cursor: monthly primary window + USD on-demand balance
        let cursorSnap = QuotaSnapshot(
            provider: .cursor,
            accountId: "cursor:default",
            windows: [
                QuotaWindow(id: "plan_usage", label: "本月套餐", remainingFraction: 0.74, windowSeconds: 2_592_000, isPrimary: true),
            ],
            balance: BalanceInfo(currency: "USD", totalBalance: 12.50),
            status: .ready(fetchedAt: now, stale: false)
        )
        let cursorMetrics = AppStore.extractQuotaMetrics(for: .cursor, snapshot: cursorSnap, now: now)
        T.expectEqual(cursorMetrics.fiveHourPercent, nil)
        T.expectEqual(cursorMetrics.weeklyPercent, nil)
        T.expectEqual(cursorMetrics.primaryPercent, 74.0)
        T.expectEqual(cursorMetrics.lowestPercent, 74.0)
        T.expectEqual(cursorMetrics.balanceText, "$12.5")

        // Grok: daily window
        let grokSnap = QuotaSnapshot(
            provider: .grok,
            accountId: "grok:default",
            windows: [
                QuotaWindow(id: "daily", label: "每日额度", remainingFraction: 0.88, windowSeconds: 86_400, isPrimary: true),
            ],
            status: .ready(fetchedAt: now, stale: false)
        )
        let grokMetrics = AppStore.extractQuotaMetrics(for: .grok, snapshot: grokSnap, now: now)
        T.expectEqual(grokMetrics.fiveHourPercent, nil)
        T.expectEqual(grokMetrics.weeklyPercent, nil)
        T.expectEqual(grokMetrics.primaryPercent, 88.0)
        T.expectEqual(grokMetrics.lowestPercent, 88.0)

        // DeepSeek: CNY balance-only + depleted check
        let dsSnap = QuotaSnapshot(
            provider: .deepseek,
            accountId: "deepseek:api",
            balance: BalanceInfo(currency: "CNY", totalBalance: 15_112.66),
            status: .ready(fetchedAt: now, stale: false)
        )
        let dsMetrics = AppStore.extractQuotaMetrics(for: .deepseek, snapshot: dsSnap, now: now)
        T.expectEqual(dsMetrics.fiveHourPercent, nil)
        T.expectEqual(dsMetrics.weeklyPercent, nil)
        T.expectEqual(dsMetrics.lowestPercent, nil)
        T.expectEqual(dsMetrics.balanceText, "¥15.1k")
        T.expectEqual(dsMetrics.isBalanceDepleted, false)

        let dsZeroSnap = QuotaSnapshot(
            provider: .deepseek,
            accountId: "deepseek:api",
            balance: BalanceInfo(currency: "CNY", totalBalance: 0.0),
            status: .ready(fetchedAt: now, stale: false)
        )
        T.expectEqual(AppStore.extractQuotaMetrics(for: .deepseek, snapshot: dsZeroSnap, now: now).isBalanceDepleted, true)

        // C. Store setup with all 6 providers + full tokenUsage ranges (today, days7, days30) + live speed
        let store = await MainActor.run {
            AppStore(
                keychain: kc,
                processController: ProcessController(inspector: MockProcessInspector()),
                adapters: [:],
                registryURL: regURL,
                startScheduler: false,
                tokenUsageEngine: engine,
                accountPoolExporter: exporter,
                persistAccountPoolExport: false
            )
        }

        let activeModel = ModelSpeedStat(
            client: .antigravity,
            modelId: "gemini-4-neon-xhigh",
            latestOutputTokPerSec: 84.6,
            averageOutputTokPerSec: 76.2,
            peakOutputTokPerSec: 112.0,
            latestTotalTokPerSec: 340.0,
            sampleCount: 12,
            lastOutputTokens: 423,
            lastDurationSec: 5.0,
            lastActiveAt: now.addingTimeInterval(-2)
        )
        let speedSnap = LiveTokenSpeedSnapshot(
            sampledAt: now,
            isGenerating: true,
            currentModel: activeModel,
            rollingOutputTokPerSec60s: 52.4,
            rollingTotalTokPerSec60s: 420.0,
            recentModels: [activeModel],
            modelSpeedIndex: [activeModel.id: activeModel]
        )

        let todayTotals = TokenComponentTotals(
            totalTokens: 125_400,
            uncachedInputTokens: 10_000,
            outputTokens: 25_400,
            cacheReadTokens: 80_000,
            cacheWriteTokens: 10_000,
            estimatedCostUSD: 1.42,
            messageCount: 42
        )
        let days7Totals = TokenComponentTotals(
            totalTokens: 2_500_000,
            uncachedInputTokens: 200_000,
            outputTokens: 300_000,
            cacheReadTokens: 1_800_000,
            cacheWriteTokens: 200_000,
            estimatedCostUSD: 18.50,
            messageCount: 310
        )
        let days30Totals = TokenComponentTotals(
            totalTokens: 12_000_000,
            uncachedInputTokens: 1_000_000,
            outputTokens: 1_500_000,
            cacheReadTokens: 8_500_000,
            cacheWriteTokens: 1_000_000,
            estimatedCostUSD: 128.0,
            messageCount: 1_250
        )
        let tokenSnapshot = TokenUsageSnapshot(
            generatedAt: now,
            lastScannedAt: now,
            seedDaysCount: 0,
            totalDaysCount: 30,
            liveScannedFilesCount: 4,
            archiveFileURLPath: dir.appendingPathComponent("daily-history-archive.json").path,
            heatmap112Days: [],
            allDays: [],
            ranges: [
                .today: TokenRangeSummary(
                    range: .today,
                    startDate: "2026-11-21",
                    endDate: "2026-11-21",
                    totals: todayTotals,
                    activeDays: 1,
                    totalDaysInRange: 1,
                    byClient: [TokenClientBreakdown(client: .antigravity, totals: todayTotals, shareOfTokens: 1.0, activeDays: 1)],
                    byModel: [TokenModelBreakdown(client: .antigravity, modelId: "gemini-4-neon-xhigh", totals: todayTotals, shareOfTokens: 1.0)],
                    byProject: [],
                    dailySeries: []
                ),
                .days7: TokenRangeSummary(
                    range: .days7,
                    startDate: "2026-11-15",
                    endDate: "2026-11-21",
                    totals: days7Totals,
                    activeDays: 7,
                    totalDaysInRange: 7,
                    byClient: [],
                    byModel: [],
                    byProject: [],
                    dailySeries: []
                ),
                .days30: TokenRangeSummary(
                    range: .days30,
                    startDate: "2026-10-23",
                    endDate: "2026-11-21",
                    totals: days30Totals,
                    activeDays: 25,
                    totalDaysInRange: 30,
                    byClient: [],
                    byModel: [],
                    byProject: [],
                    dailySeries: []
                ),
            ],
            speedSnapshot: speedSnap
        )

        await MainActor.run {
            store.registry.upsertAccount(AccountRecord(id: "ag-1", provider: .antigravity, email: "ag@test", displayName: "AG", isActiveLive: true))
            store.registry.upsertAccount(AccountRecord(id: "codex-1", provider: .codex, email: "cx@test", displayName: "Codex", isActiveLive: true))
            store.registry.settings.selectedProvider = .codex
            store.registry.settings.showRemainingPercent = true
            store.registry.settings.lowQuotaWarnThreshold = 0.20

            store.snapshots[AppStore.snapshotKey(provider: .antigravity, accountId: "ag-1")] = agSnap
            store.snapshots[AppStore.snapshotKey(provider: .codex, accountId: "codex-1")] = codexSnap
            store.snapshots[AppStore.snapshotKey(provider: .kimi, accountId: "kimi:api")] = kimiSnap
            store.snapshots[AppStore.snapshotKey(provider: .cursor, accountId: "cursor:default")] = cursorSnap
            store.snapshots[AppStore.snapshotKey(provider: .grok, accountId: "grok:default")] = grokSnap
            store.snapshots[AppStore.snapshotKey(provider: .deepseek, accountId: "deepseek:api")] = dsSnap
            store.tokenUsage = tokenSnapshot
        }

        // D. formattedQuotaText across all 4 MenuBarQuotaWindow & 2 MenuBarQuotaDualFormat
        let formattedChecks = await MainActor.run { () -> [String?] in
            [
                store.formattedQuotaText(for: .codex, window: .weeklyFirst, dualFormat: .slash, includePrefix: true),
                store.formattedQuotaText(for: .codex, window: .both5hAndWeekly, dualFormat: .slash, includePrefix: false),
                store.formattedQuotaText(for: .codex, window: .both5hAndWeekly, dualFormat: .labeled, includePrefix: false),
                store.formattedQuotaText(for: .codex, window: .both5hAndWeekly, dualFormat: .labeled, includePrefix: true),
                store.formattedQuotaText(for: .codex, window: .fiveHourFirst, dualFormat: .slash, includePrefix: true),
                store.formattedQuotaText(for: .codex, window: .lowest, dualFormat: .slash, includePrefix: true),
                store.formattedQuotaText(for: .antigravity, window: .both5hAndWeekly, dualFormat: .slash, includePrefix: true, agPool: .argon),
                store.formattedQuotaText(for: .antigravity, window: .both5hAndWeekly, dualFormat: .labeled, includePrefix: true, agPool: .argon),
                store.formattedQuotaText(for: .antigravity, window: .weeklyFirst, dualFormat: .slash, includePrefix: true, agPool: .gemini),
                store.formattedQuotaText(for: .deepseek, window: .weeklyFirst, dualFormat: .slash, includePrefix: true),
            ]
        }
        T.expectEqual(formattedChecks[0], "Codex 99%")
        T.expectEqual(formattedChecks[1], "49%/99%")
        T.expectEqual(formattedChecks[2], "5h49/周99")
        T.expectEqual(formattedChecks[3], "Codex 5h49/周99")
        T.expectEqual(formattedChecks[4], "Codex 49%")
        T.expectEqual(formattedChecks[5], "Codex 49%")
        T.expectEqual(formattedChecks[6], "AGY 60%")
        T.expectEqual(formattedChecks[7], "AGY 周60")
        T.expectEqual(formattedChecks[8], "AGY 90%")
        T.expectEqual(formattedChecks[9], "DS ¥15.1k")

        // Verify used% inversion (showRemainingPercent == false)
        let usedDual = await MainActor.run { () -> (String?, String?) in
            store.registry.settings.showRemainingPercent = false
            defer { store.registry.settings.showRemainingPercent = true }
            return (
                store.formattedQuotaText(for: .codex, window: .both5hAndWeekly, dualFormat: .slash, includePrefix: false),
                store.formattedQuotaText(for: .codex, window: .both5hAndWeekly, dualFormat: .labeled, includePrefix: false)
            )
        }
        T.expectEqual(usedDual.0, "51%/1%")
        T.expectEqual(usedDual.1, "5h51/周1")

        // E. MenuBarQuotaSource.multi parallel output & ordering control
        let (multi1, multi2, multiNoPrefix, multiDual) = await MainActor.run {
            () -> (MenuBarSummary, MenuBarSummary, MenuBarSummary, MenuBarSummary) in
            store.registry.settings.menuBarDisplayMode = .custom
            store.updateMenuBarCustom { cfg in
                cfg.iconStyle = .provider
                cfg.modules = [.quota]
                cfg.quotaSource = .multi
                cfg.quotaMultiProviders = [.codex, .antigravity, .deepseek]
                cfg.quotaWindow = .weeklyFirst
                cfg.quotaDualFormat = .slash
                cfg.antigravityPool = .autoLowest
                cfg.showProviderPrefix = true
            }
            let r1 = store.menuBarSummaryDetail()

            store.updateMenuBarCustom { cfg in
                cfg.moveMultiProvider(.deepseek, direction: .up)
            }
            let r2 = store.menuBarSummaryDetail()

            store.updateMenuBarCustom { cfg in
                cfg.showProviderPrefix = false
            }
            let r3 = store.menuBarSummaryDetail()

            store.updateMenuBarCustom { cfg in
                cfg.showProviderPrefix = true
                cfg.quotaWindow = .both5hAndWeekly
            }
            let r4 = store.menuBarSummaryDetail()
            return (r1, r2, r3, r4)
        }
        T.expectEqual(multi1.providerKind, .codex)
        T.expectEqual(multi1.title, "Codex 99% AGY 60% DS ¥15.1k")
        T.expectEqual(multi2.title, "Codex 99% DS ¥15.1k AGY 60%")
        T.expectEqual(multiNoPrefix.title, "99% / ¥15.1k / 60%")
        T.expectEqual(multiDual.title, "Codex 49%/99% DS ¥15.1k AGY 45%/60%")

        // F. All 14 MenuBarModule independent rendering & menuBarModulePreviewText(for:)
        T.expectEqual(MenuBarModule.allCases.count, 14, "MenuBarModule must expose all 14 modules")
        let (renderedByModule, previewByModule, rate60sTotal) = await MainActor.run {
            () -> ([MenuBarModule: String], [MenuBarModule: String], String) in
            store.registry.settings.menuBarDisplayMode = .custom
            store.registry.settings.selectedProvider = .codex
            store.updateMenuBarCustom { cfg in
                cfg.iconStyle = .provider
                cfg.quotaSource = .selected
                cfg.quotaWindow = .weeklyFirst
                cfg.quotaDualFormat = .slash
                cfg.showProviderPrefix = true
                cfg.rateMetric = .output
                cfg.hideRateWhenIdle = false
                cfg.separator = .dot
            }

            var rendered: [MenuBarModule: String] = [:]
            var previews: [MenuBarModule: String] = [:]
            for module in MenuBarModule.allCases {
                store.updateMenuBarCustom { cfg in
                    cfg.modules = [module]
                }
                rendered[module] = store.menuBarSummaryDetail().title
                previews[module] = store.menuBarModulePreviewText(for: module)
            }

            store.updateMenuBarCustom { cfg in
                cfg.rateMetric = .total
                cfg.modules = [.tokenRate60s]
            }
            let r60Total = store.menuBarSummaryDetail().title
            return (rendered, previews, r60Total)
        }

        T.expectEqual(renderedByModule[.quota], "Codex 99%")
        T.expectEqual(renderedByModule[.quotaFiveHour], "5h 49%")
        T.expectEqual(renderedByModule[.quotaWeekly], "周 99%")
        T.expectEqual(renderedByModule[.tokenRate], "84.6 tok/s")
        T.expectEqual(renderedByModule[.tokenRate60s], "60s 52.4 tok/s")
        T.expectEqual(rate60sTotal, "60s 420 tok/s")
        T.expectEqual(renderedByModule[.todayTokens], "125.4K")
        T.expectEqual(renderedByModule[.todayCost], "$1.42")
        T.expectEqual(renderedByModule[.activeModel], "Neon")
        T.expectEqual(renderedByModule[.cacheHitRate], "缓存 80%")
        T.expectEqual(renderedByModule[.todayMessages], "42条")
        T.expectEqual(renderedByModule[.sevenDayTokens], "7天 2.5M")
        T.expectEqual(renderedByModule[.thirtyDayCost], "30天 $128")
        T.expect(renderedByModule[.nextResetCountdown]?.hasPrefix("↻2h15m") == true, "expected ↻2h15m, got \(renderedByModule[.nextResetCountdown] ?? "nil")")
        T.expectEqual(renderedByModule[.deepseekBalance], "DS ¥15.1k")

        for module in MenuBarModule.allCases {
            T.expectEqual(
                previewByModule[module],
                renderedByModule[module],
                "menuBarModulePreviewText(\(module.rawValue)) must match live rendered segment"
            )
        }

        // G. menuBarSummaryDetail().providerKind icon linkage, hidden empty icon & empty fallback "Pulsar"
        let (selDetail, fixedKimiDetail, pulsarDetail, hiddenDetail, fallbackDetail) = await MainActor.run {
            () -> (MenuBarSummary, MenuBarSummary, MenuBarSummary, MenuBarSummary, MenuBarSummary) in
            store.registry.settings.menuBarDisplayMode = .selectedProvider
            store.registry.settings.selectedProvider = .codex
            store.updateMenuBarCustom { cfg in
                cfg.quotaWindow = .weeklyFirst
            }
            let d1 = store.menuBarSummaryDetail()

            store.registry.settings.menuBarDisplayMode = .custom
            store.updateMenuBarCustom { cfg in
                cfg.iconStyle = .provider
                cfg.quotaSource = .fixed
                cfg.fixedQuotaProvider = .kimi
                cfg.modules = [.quota]
            }
            let d2 = store.menuBarSummaryDetail()

            store.updateMenuBarCustom { cfg in
                cfg.iconStyle = .pulsar
            }
            let d3 = store.menuBarSummaryDetail()

            store.updateMenuBarCustom { cfg in
                cfg.iconStyle = .hidden
            }
            let d4 = store.menuBarSummaryDetail()

            store.updateMenuBarCustom { cfg in
                cfg.iconStyle = .hidden
                cfg.modules = []
            }
            let d5 = store.menuBarSummaryDetail()
            return (d1, d2, d3, d4, d5)
        }
        T.expectEqual(selDetail.providerKind, .codex)
        T.expectEqual(selDetail.title, "Codex 99%")
        T.expectEqual(fixedKimiDetail.providerKind, .kimi)
        T.expectEqual(fixedKimiDetail.title, "Kimi 62%")
        T.expectEqual(pulsarDetail.providerKind, nil)
        T.expectEqual(pulsarDetail.symbol, "sparkles")
        T.expectEqual(hiddenDetail.providerKind, nil)
        T.expectEqual(hiddenDetail.symbol, "")
        T.expectEqual(fallbackDetail.providerKind, nil)
        T.expectEqual(fallbackDetail.symbol, "")
        T.expectEqual(fallbackDetail.title, "Pulsar")

        // H. pillBadgeInfo(for:) coloring, dual display, balance & error/unconfigured states
        let (pillWeekly, pillDual, pill5h, pillDS, pillDSZero, pillUnconf, pillFail) = await MainActor.run {
            () -> (
                (text: String, remainingPercent: Double?, isReady: Bool, isError: Bool, isUnconfigured: Bool, isBalancePositive: Bool?),
                (text: String, remainingPercent: Double?, isReady: Bool, isError: Bool, isUnconfigured: Bool, isBalancePositive: Bool?),
                (text: String, remainingPercent: Double?, isReady: Bool, isError: Bool, isUnconfigured: Bool, isBalancePositive: Bool?),
                (text: String, remainingPercent: Double?, isReady: Bool, isError: Bool, isUnconfigured: Bool, isBalancePositive: Bool?),
                (text: String, remainingPercent: Double?, isReady: Bool, isError: Bool, isUnconfigured: Bool, isBalancePositive: Bool?),
                (text: String, remainingPercent: Double?, isReady: Bool, isError: Bool, isUnconfigured: Bool, isBalancePositive: Bool?),
                (text: String, remainingPercent: Double?, isReady: Bool, isError: Bool, isUnconfigured: Bool, isBalancePositive: Bool?)
            ) in
            store.updateAccountCardConfig { $0.pillQuotaWindow = .weeklyFirst }
            let pW = store.pillBadgeInfo(for: .codex)

            store.updateAccountCardConfig { $0.pillQuotaWindow = .both5hAndWeekly }
            let pD = store.pillBadgeInfo(for: .codex)

            store.updateAccountCardConfig { $0.pillQuotaWindow = .fiveHourFirst }
            let p5 = store.pillBadgeInfo(for: .codex)

            let pDS = store.pillBadgeInfo(for: .deepseek)

            store.snapshots[AppStore.snapshotKey(provider: .deepseek, accountId: "deepseek:api")] = dsZeroSnap
            let pDS0 = store.pillBadgeInfo(for: .deepseek)

            store.snapshots[AppStore.snapshotKey(provider: .grok, accountId: "grok:default")] = QuotaSnapshot.unconfigured(
                provider: .grok,
                accountId: "grok:default",
                message: "not configured"
            )
            let pU = store.pillBadgeInfo(for: .grok)

            store.snapshots[AppStore.snapshotKey(provider: .cursor, accountId: "cursor:default")] = QuotaSnapshot.failed(
                provider: .cursor,
                accountId: "cursor:default",
                message: "network error"
            )
            let pF = store.pillBadgeInfo(for: .cursor)

            return (pW, pD, p5, pDS, pDS0, pU, pF)
        }

        T.expectEqual(pillWeekly.text, "99%")
        T.expectEqual(pillWeekly.remainingPercent, 99.0)
        T.expectEqual(pillWeekly.isReady, true)
        T.expectEqual(pillWeekly.isBalancePositive, nil)

        T.expectEqual(pillDual.text, "49%/99%")
        T.expectEqual(pillDual.remainingPercent, 49.0, "dual pill must expose min(5h, weekly) for warning color")
        T.expectEqual(pillDual.isReady, true)

        T.expectEqual(pill5h.text, "49%")
        T.expectEqual(pill5h.remainingPercent, 49.0)

        T.expectEqual(pillDS.text, "¥15.1k")
        T.expectEqual(pillDS.remainingPercent, nil)
        T.expectEqual(pillDS.isReady, true)
        T.expectEqual(pillDS.isBalancePositive, true)

        T.expectEqual(pillDSZero.isReady, true)
        T.expectEqual(pillDSZero.isBalancePositive, false)

        T.expectEqual(pillUnconf.text, "未配")
        T.expectEqual(pillUnconf.isUnconfigured, true)
        T.expectEqual(pillUnconf.isReady, false)

        T.expectEqual(pillFail.text, "!")
        T.expectEqual(pillFail.isError, true)
        T.expectEqual(pillFail.isReady, false)

        // Verify card customization persistence helpers on AppStore
        await MainActor.run {
            store.updatePopoverTokenCards { $0.compactDensity = true; $0.toggleCard(.topModels) }
            store.updateDashboardTokenCards { $0.compactDensity = true; $0.toggleCard(.heatmap) }
            store.updateAccountCardConfig { $0.showAvatar = false; $0.pillQuotaWindow = .both5hAndWeekly }
        }
        let reloadedCards = try RegistryData.load(from: regURL)
        T.expectEqual(reloadedCards.settings.tokenPopoverCards.compactDensity, true)
        T.expectEqual(reloadedCards.settings.tokenPopoverCards.isEnabled(.topModels), true)
        T.expectEqual(reloadedCards.settings.tokenDashboardCards.compactDensity, true)
        T.expectEqual(reloadedCards.settings.tokenDashboardCards.isEnabled(.heatmap), false)
        T.expectEqual(reloadedCards.settings.accountCardConfig.showAvatar, false)
        T.expectEqual(reloadedCards.settings.accountCardConfig.pillQuotaWindow, .both5hAndWeekly)

        await MainActor.run {
            store.resetAllCardConfigs()
        }
        let reloadedResetCards = try RegistryData.load(from: regURL)
        T.expectEqual(reloadedResetCards.settings.tokenPopoverCards, .default)
        T.expectEqual(reloadedResetCards.settings.tokenDashboardCards, .default)
        T.expectEqual(reloadedResetCards.settings.accountCardConfig, .default)
    }
}

// MARK: - Test 15: v1.1.0 Regression Suite (Pulsar Brand Assets, Legacy Path Overrides, Custom Date Ranges & Token Client Order)

private func testV110RegressionSuite() async {
    // 15.1 Pulsar Brand Assets & App Bundle Packaging
    T.suite("V110.PulsarBrandIconsAndBundleAssets") {
        ProviderBrandIcon.clearCache()

        T.expectEqual(AppStore.appVersion, "1.3.0", "AppStore.appVersion must match v1.3.0")

        // pulsarAppImage() full-color cached loader
        guard let appImg1 = ProviderBrandIcon.pulsarAppImage(),
              let appImg2 = ProviderBrandIcon.pulsarAppImage() else {
            T.expect(false, "ProviderBrandIcon.pulsarAppImage() must load Assets/ProviderIcons/pulsar.png")
            return
        }
        T.expect(appImg1 === appImg2, "pulsarAppImage() must return cached NSImage identity")
        T.expect(appImg1.isValid && !appImg1.representations.isEmpty, "pulsarAppImage() must have valid representations")
        T.expectEqual(appImg1.isTemplate, false, "pulsarAppImage() must remain full-color (isTemplate == false)")
        T.expect(appImg1.size.width >= 32 && appImg1.size.height >= 32, "pulsarAppImage() must keep high resolution")

        // pulsarMenuBarImage(size:) independent copies & isTemplate == true
        guard let mb15a = ProviderBrandIcon.pulsarMenuBarImage(size: 15),
              let mb15b = ProviderBrandIcon.pulsarMenuBarImage(size: 15),
              let mb22 = ProviderBrandIcon.pulsarMenuBarImage(size: 22),
              let mbTiny = ProviderBrandIcon.pulsarMenuBarImage(size: 3) else {
            T.expect(false, "ProviderBrandIcon.pulsarMenuBarImage(size:) returned nil")
            return
        }
        T.expect(mb15a !== mb15b, "pulsarMenuBarImage() must return an independent NSImage copy per call")
        T.expect(mb15a !== mb22 && mb15a !== appImg1, "pulsarMenuBarImage() must not alias other sizes or pulsarAppImage")
        T.expectEqual(mb15a.isTemplate, true, "pulsarMenuBarImage() must set isTemplate == true")
        T.expectEqual(mb15b.isTemplate, true)
        T.expectEqual(mb22.isTemplate, true)
        T.expectEqual(mbTiny.isTemplate, true)
        T.expectEqual(mb15a.size, NSSize(width: 15, height: 15))
        T.expectEqual(mb22.size, NSSize(width: 22, height: 22))
        T.expectEqual(mbTiny.size, NSSize(width: 8, height: 8), "pulsarMenuBarImage size must clamp lower bound to 8pt")

        // Mutating a returned copy must not affect subsequent calls
        mb15a.size = NSSize(width: 99, height: 99)
        mb15a.isTemplate = false
        let mb15c = ProviderBrandIcon.pulsarMenuBarImage(size: 15)
        T.expectEqual(mb15c?.size, NSSize(width: 15, height: 15), "mutating one copy must not pollute cached pulsar template base")
        T.expectEqual(mb15c?.isTemplate, true)

        // clearCache() drops cached pulsarAppImage identity cleanly
        ProviderBrandIcon.clearCache()
        let appImgAfterClear = ProviderBrandIcon.pulsarAppImage()
        T.expect(appImgAfterClear != nil && appImgAfterClear !== appImg1, "clearCache() must evict pulsarAppImageCache")

        // Verify Assets/AppIcon.icns and all 8 Assets/ProviderIcons/*.png + packaged RoryOrbit.app bundle
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let icnsMagic = Data([0x69, 0x63, 0x6E, 0x73]) // "icns"
        let pngMagic = Data([0x89, 0x50, 0x4E, 0x47])
        let requiredIcons = [
            "antigravity",
            "codex",
            "cursor",
            "deepseek",
            "grok",
            "kimi",
            "pulsar",
            "pulsar-template",
        ]

        let sourceICNS = repoRoot.appendingPathComponent("Assets/AppIcon.icns")
        T.expect(FileManager.default.fileExists(atPath: sourceICNS.path), "Assets/AppIcon.icns must exist")
        let sourceICNSData = try Data(contentsOf: sourceICNS)
        T.expect(sourceICNSData.count > 10_000 && sourceICNSData.prefix(4) == icnsMagic, "Assets/AppIcon.icns must be valid non-empty icns")

        let assetsIconsDir = repoRoot.appendingPathComponent("Assets/ProviderIcons", isDirectory: true)
        for name in requiredIcons {
            let iconURL = assetsIconsDir.appendingPathComponent("\(name).png")
            T.expect(FileManager.default.fileExists(atPath: iconURL.path), "Assets/ProviderIcons/\(name).png must exist")
            let data = try Data(contentsOf: iconURL)
            T.expect(data.count > 100 && data.prefix(4) == pngMagic, "Assets/ProviderIcons/\(name).png must be a valid PNG")
            let decoded = NSImage(contentsOf: iconURL)
            T.expect(decoded != nil && decoded!.isValid, "Assets/ProviderIcons/\(name).png must decode via NSImage")
        }

        let bundledAppURL = repoRoot.appendingPathComponent("RoryOrbit.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: bundledAppURL.path) {
            let bundledICNS = bundledAppURL.appendingPathComponent("Contents/Resources/AppIcon.icns")
            T.expect(FileManager.default.fileExists(atPath: bundledICNS.path), "packaged AppIcon.icns must exist")
            let bundledICNSData = try Data(contentsOf: bundledICNS)
            T.expect(bundledICNSData.prefix(4) == icnsMagic, "packaged AppIcon.icns must have valid icns header")

            let bundledIconsDir = bundledAppURL.appendingPathComponent("Contents/Resources/ProviderIcons", isDirectory: true)
            for name in requiredIcons {
                let bundledIcon = bundledIconsDir.appendingPathComponent("\(name).png")
                T.expect(FileManager.default.fileExists(atPath: bundledIcon.path), "packaged ProviderIcons/\(name).png must exist")
                let data = try Data(contentsOf: bundledIcon)
                T.expect(data.count > 100 && data.prefix(4) == pngMagic, "packaged ProviderIcons/\(name).png must be valid PNG")
            }

            let plistURL = bundledAppURL.appendingPathComponent("Contents/Info.plist")
            let plistData = try Data(contentsOf: plistURL)
            let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
            T.expectEqual(plist?["CFBundleDisplayName"] as? String, "Pulsar")
            T.expectEqual(plist?["CFBundleShortVersionString"] as? String, AppStore.appVersion)
            T.expectEqual(plist?["CFBundleVersion"] as? String, AppStore.appVersion)
            T.expectEqual(plist?["CFBundleIconFile"] as? String, "AppIcon")
        }
    }

    // 15.2 Legacy Path Desensitization & Env Override Tests
    await T.asyncSuite("V110.LegacyPathsEnvOverridesAndStandardResolution") {
        // 1. LegacyMigrationPaths.resolveOrbitSwitchAccountsURL
        T.expectEqual(LegacyMigrationPaths.legacyOrbitSwitchDirEnvKey, "PULSAR_LEGACY_ORBITSWITCH_DIR")
        let fakeHome = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        let defaultOrbitURL = LegacyMigrationPaths.resolveOrbitSwitchAccountsURL(home: fakeHome, environment: [:])
        T.expectEqual(defaultOrbitURL.path, "/Users/example/Library/Application Support/OrbitSwitch/accounts.json")

        let whitespaceEnvURL = LegacyMigrationPaths.resolveOrbitSwitchAccountsURL(
            home: fakeHome,
            environment: [LegacyMigrationPaths.legacyOrbitSwitchDirEnvKey: "   \n  "]
        )
        T.expectEqual(whitespaceEnvURL.path, "/Users/example/Library/Application Support/OrbitSwitch/accounts.json")

        let dirOverrideURL = LegacyMigrationPaths.resolveOrbitSwitchAccountsURL(
            home: fakeHome,
            environment: [LegacyMigrationPaths.legacyOrbitSwitchDirEnvKey: "/tmp/custom-orbitswitch-backup"]
        )
        T.expectEqual(dirOverrideURL.path, "/tmp/custom-orbitswitch-backup/accounts.json")

        let fileOverrideURL = LegacyMigrationPaths.resolveOrbitSwitchAccountsURL(
            home: fakeHome,
            environment: [LegacyMigrationPaths.legacyOrbitSwitchDirEnvKey: "/tmp/custom-orbitswitch/my-accounts.JSON"]
        )
        T.expectEqual(fileOverrideURL.path, "/tmp/custom-orbitswitch/my-accounts.JSON")

        // 2. TokenUsageEngine legacyTokenMonitorDirURL & PULSAR_LEGACY_TOKEN_MONITOR_DIR
        T.expectEqual(TokenUsageEngine.legacyTokenMonitorDirEnvKey, "PULSAR_LEGACY_TOKEN_MONITOR_DIR")
        let dir = try makeTempDir(prefix: "pulsar-legacy-tm-env")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixedNow = Formatters.parseRFC3339("2026-11-21T04:00:00Z")!

        func writeSeedJSON(to url: URL, tokens: Int64) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let payload: [String: Any] = [
                "days": [
                    "2026-11-15": [
                        "activeTimeMs": 60_000,
                        "observations": [
                            "[\"cursor\",\"gpt-5\"]": [
                                "client": "cursor",
                                "modelId": "gpt-5",
                                "tokens": tokens,
                                "outputTokens": 100,
                                "cacheReadTokens": 200,
                                "cacheWriteTokens": 0,
                                "cost": 0.5,
                                "messages": 2,
                            ],
                        ],
                    ],
                ],
            ]
            try JSONSerialization.data(withJSONObject: payload).write(to: url)
        }

        // 2a. Explicit legacyTokenMonitorDirURL (directory + direct .json file)
        let injectedDir = dir.appendingPathComponent("injected-dir", isDirectory: true)
        try writeSeedJSON(to: injectedDir.appendingPathComponent("daily-history-calendars.json"), tokens: 1234)
        let supportInjectedDir = dir.appendingPathComponent("support-injected-dir", isDirectory: true)
        let engineInjectedDir = TokenUsageEngine(
            homeDirectoryURL: dir.appendingPathComponent("empty-home", isDirectory: true),
            appSupportURL: supportInjectedDir,
            legacyTokenMonitorDirURL: injectedDir
        )
        let snapInjectedDir = await engineInjectedDir.scanAndExportArchive(forceFullRescan: true, now: fixedNow)
        T.expectEqual(snapInjectedDir.summary(for: .allTime).totals.totalTokens, 1234, "injected directory override must load legacy seed")

        let injectedFile = dir.appendingPathComponent("direct-file/custom-seed.json")
        try writeSeedJSON(to: injectedFile, tokens: 2345)
        let supportInjectedFile = dir.appendingPathComponent("support-injected-file", isDirectory: true)
        let engineInjectedFile = TokenUsageEngine(
            homeDirectoryURL: dir.appendingPathComponent("empty-home", isDirectory: true),
            appSupportURL: supportInjectedFile,
            legacyTokenMonitorDirURL: injectedFile
        )
        let snapInjectedFile = await engineInjectedFile.scanAndExportArchive(forceFullRescan: true, now: fixedNow)
        T.expectEqual(snapInjectedFile.summary(for: .allTime).totals.totalTokens, 2345, "injected direct .json URL override must load legacy seed")

        // 2b. PULSAR_LEGACY_TOKEN_MONITOR_DIR env var + priority (injected > env > standard)
        let envKey = TokenUsageEngine.legacyTokenMonitorDirEnvKey
        let previousEnvVal = ProcessInfo.processInfo.environment[envKey]
        defer {
            if let prev = previousEnvVal {
                setenv(envKey, prev, 1)
            } else {
                unsetenv(envKey)
            }
        }

        let envDir = dir.appendingPathComponent("env-dir", isDirectory: true)
        try writeSeedJSON(to: envDir.appendingPathComponent("daily-history-archive.json"), tokens: 3456)
        let standardHome = dir.appendingPathComponent("std-home", isDirectory: true)
        try writeSeedJSON(
            to: standardHome.appendingPathComponent("Library/Application Support/Token Monitor/daily-history-calendars.json"),
            tokens: 4567
        )

        setenv(envKey, envDir.path, 1)
        let engineEnv = TokenUsageEngine(
            homeDirectoryURL: standardHome,
            appSupportURL: dir.appendingPathComponent("support-env", isDirectory: true)
        )
        let snapEnv = await engineEnv.scanAndExportArchive(forceFullRescan: true, now: fixedNow)
        T.expectEqual(snapEnv.summary(for: .allTime).totals.totalTokens, 3456, "PULSAR_LEGACY_TOKEN_MONITOR_DIR must take precedence over standard dir")

        // Injected takes precedence over env var
        let enginePriority = TokenUsageEngine(
            homeDirectoryURL: standardHome,
            appSupportURL: dir.appendingPathComponent("support-priority", isDirectory: true),
            legacyTokenMonitorDirURL: injectedDir
        )
        let snapPriority = await enginePriority.scanAndExportArchive(forceFullRescan: true, now: fixedNow)
        T.expectEqual(snapPriority.summary(for: .allTime).totals.totalTokens, 1234, "injected legacyTokenMonitorDirURL must override env var")
    }

    // 15.3 Default Today, Custom Date Selection, TokenFormatters, ModelDayRecord & Legacy Snapshot Decode
    await T.asyncSuite("V110.DateSelectionFormattersCustomRangeAndBackwardCompat") {
        // 1. Default selection & presets
        T.expectEqual(TokenUsageDateSelection.defaultSelection, .preset(.today))
        T.expectEqual(TokenUsageRange.presetCases, [.today, .days7, .days30, .allTime])
        T.expectEqual(TokenUsageDateSelection.defaultSelection.presetRange, .today)
        T.expectEqual(TokenUsageDateSelection.defaultSelection.isCustom, false)
        T.expect(TokenUsageDateSelection.defaultSelection.customBounds == nil)
        T.expectEqual(TokenUsageDateSelection.defaultSelection.displayName, "今日")
        T.expectEqual(TokenUsageDateSelection.defaultSelection.shortLabel, "今日")

        // Single day, reversed custom auto-swap, Date initializer & Codable round-trip
        let singleSel = TokenUsageDateSelection.singleDay(" 2026-11-18 ")
        T.expectEqual(singleSel, .custom(startDate: "2026-11-18", endDate: "2026-11-18"))
        T.expectEqual(singleSel.isCustom, true)
        T.expect(singleSel.presetRange == nil)
        T.expectEqual(singleSel.customBounds?.startDate, "2026-11-18")
        T.expectEqual(singleSel.customBounds?.endDate, "2026-11-18")

        let swappedSel = TokenUsageDateSelection.normalizedCustom(startDate: "2026-11-20", endDate: "2026-11-10")
        T.expectEqual(swappedSel, .custom(startDate: "2026-11-10", endDate: "2026-11-20"))

        let rawReversed = TokenUsageDateSelection.custom(startDate: "2026-11-21", endDate: "2026-11-12")
        T.expectEqual(rawReversed.customBounds?.startDate, "2026-11-12")
        T.expectEqual(rawReversed.customBounds?.endDate, "2026-11-21")

        let utc = TimeZone(secondsFromGMT: 0)!
        let dStart = TokenFormatters.date(fromYMD: "2026-11-19", timeZone: utc)!
        let dEnd = TokenFormatters.date(fromYMD: "2026-11-14", timeZone: utc)!
        T.expectEqual(
            TokenUsageDateSelection.custom(start: dStart, end: dEnd, timeZone: utc),
            .custom(startDate: "2026-11-14", endDate: "2026-11-19")
        )

        let selEncoded = try JSONEncoder().encode(swappedSel)
        let selDecoded = try JSONDecoder().decode(TokenUsageDateSelection.self, from: selEncoded)
        T.expectEqual(selDecoded, swappedSel)

        // 2. TokenFormatters date helpers (leap years, cross-year labels, DST-free sequence)
        T.expectEqual(TokenFormatters.isValidYMD("2024-02-29"), true, "2024 is leap year")
        T.expectEqual(TokenFormatters.isValidYMD("2000-02-29"), true, "2000 is leap year")
        T.expectEqual(TokenFormatters.isValidYMD("2025-02-29"), false, "2025 is non-leap year")
        T.expectEqual(TokenFormatters.isValidYMD("1900-02-29"), false, "1900 is non-leap year")
        T.expectEqual(TokenFormatters.isValidYMD("2026-13-01"), false)
        T.expectEqual(TokenFormatters.isValidYMD("2026-11-31"), false)
        T.expectEqual(TokenFormatters.isValidYMD("2026/11/18"), false)

        let shanghai = TimeZone(secondsFromGMT: 8 * 3600)!
        let parsedLeap = TokenFormatters.date(fromYMD: "2024-02-29", timeZone: shanghai)
        T.expect(parsedLeap != nil)
        T.expectEqual(TokenFormatters.ymdString(from: parsedLeap!, timeZone: shanghai), "2024-02-29")
        T.expect(TokenFormatters.date(fromYMD: "2025-02-29", timeZone: shanghai) == nil)

        T.expectEqual(TokenFormatters.inclusiveDayCount(startDate: "2024-02-28", endDate: "2024-03-01"), 3)
        T.expectEqual(TokenFormatters.inclusiveDayCount(startDate: "2025-02-28", endDate: "2025-03-01"), 2)
        T.expectEqual(TokenFormatters.inclusiveDayCount(startDate: "2026-11-20", endDate: "2026-11-18"), 3, "reversed inclusiveDayCount must auto-swap")
        T.expectEqual(TokenFormatters.inclusiveDayCount(startDate: "2026-01-01", endDate: "2026-06-29"), 180)
        T.expectEqual(TokenFormatters.inclusiveDayCount(startDate: "2026-01-01", endDate: "2026-06-30"), 181)
        T.expect(TokenFormatters.inclusiveDayCount(startDate: "bad", endDate: "2026-11-18") == nil)

        T.expectEqual(
            TokenFormatters.dateSequence(from: "2024-02-28", to: "2024-03-01"),
            ["2024-02-28", "2024-02-29", "2024-03-01"]
        )
        T.expectEqual(
            TokenFormatters.dateSequence(from: "2024-03-01", to: "2024-02-28"),
            ["2024-02-28", "2024-02-29", "2024-03-01"],
            "reversed dateSequence must still return ascending dates"
        )
        T.expectEqual(TokenFormatters.dateSequence(from: "2025-02-29", to: "2025-03-01"), [])

        // customRangeLabel (same-year, cross-year, leap day, reversed)
        T.expectEqual(TokenFormatters.customRangeLabel(startDate: "2026-11-18", endDate: "2026-11-18", referenceYear: 2026), "11-18")
        T.expectEqual(TokenFormatters.customRangeLabel(startDate: "2025-11-18", endDate: "2025-11-18", referenceYear: 2026), "2025-11-18")
        T.expectEqual(TokenFormatters.customRangeLabel(startDate: "2026-11-10", endDate: "2026-11-18", referenceYear: 2026), "11-10 ~ 11-18")
        T.expectEqual(TokenFormatters.customRangeLabel(startDate: "2026-11-18", endDate: "2026-11-10", referenceYear: 2026), "11-10 ~ 11-18")
        T.expectEqual(TokenFormatters.customRangeLabel(startDate: "2025-12-28", endDate: "2026-01-03", referenceYear: 2026), "2025-12-28 ~ 2026-01-03")
        T.expectEqual(TokenFormatters.customRangeLabel(startDate: "2024-02-29", endDate: "2024-02-29", referenceYear: 2024), "02-29")
        T.expectEqual(TokenFormatters.customRangeLabel(startDate: "2024-02-29", endDate: "2024-02-29", referenceYear: 2026), "2024-02-29")
        T.expectEqual(TokenFormatters.customRangeLabel(startDate: "", endDate: "", referenceYear: 2026), "自定义")

        // 3. Synthetic snapshot testing: single day, multi-day zero-fill (<=180d), sparse (>180d), reversed, modelRecords, clientFilter, availableDateBounds
        let now = Formatters.parseRFC3339("2026-11-21T04:00:00Z")!
        let emptySnap = TokenUsageSnapshot(
            generatedAt: now,
            lastScannedAt: now,
            seedDaysCount: 0,
            totalDaysCount: 0,
            liveScannedFilesCount: 0,
            archiveFileURLPath: "",
            heatmap112Days: [],
            allDays: [],
            ranges: [:]
        )
        T.expect(emptySnap.availableDateBounds == nil, "empty snapshot must report nil availableDateBounds")

        let dJanClaude = TokenComponentTotals(totalTokens: 1000, uncachedInputTokens: 400, outputTokens: 200, cacheReadTokens: 400, cacheWriteTokens: 0, estimatedCostUSD: 0.4, messageCount: 2)
        let dNov10Claude = TokenComponentTotals(totalTokens: 2000, uncachedInputTokens: 600, outputTokens: 400, cacheReadTokens: 1000, cacheWriteTokens: 0, estimatedCostUSD: 0.8, messageCount: 3)
        let dNov10Codex = TokenComponentTotals(totalTokens: 1000, uncachedInputTokens: 300, outputTokens: 200, cacheReadTokens: 500, cacheWriteTokens: 0, estimatedCostUSD: 0.3, messageCount: 1)
        let dNov12Codex = TokenComponentTotals(totalTokens: 5000, uncachedInputTokens: 1000, outputTokens: 1000, cacheReadTokens: 3000, cacheWriteTokens: 0, estimatedCostUSD: 1.5, messageCount: 5)
        let dNov15Claude = TokenComponentTotals(totalTokens: 4000, uncachedInputTokens: 1000, outputTokens: 800, cacheReadTokens: 2200, cacheWriteTokens: 0, estimatedCostUSD: 1.6, messageCount: 4)

        let allDays: [TokenDailyPoint] = [
            TokenDailyPoint(
                date: "2026-01-05",
                totals: dJanClaude,
                activeTimeMs: 30_000,
                byClient: [TokenClientBreakdown(client: .claude, totals: dJanClaude, shareOfTokens: 1.0, activeDays: 1)]
            ),
            TokenDailyPoint(
                date: "2026-11-10",
                totals: dNov10Claude.adding(dNov10Codex),
                activeTimeMs: 120_000,
                byClient: [
                    TokenClientBreakdown(client: .claude, totals: dNov10Claude, shareOfTokens: 2.0 / 3.0, activeDays: 1),
                    TokenClientBreakdown(client: .codex, totals: dNov10Codex, shareOfTokens: 1.0 / 3.0, activeDays: 1),
                ]
            ),
            TokenDailyPoint(
                date: "2026-11-12",
                totals: dNov12Codex,
                activeTimeMs: 180_000,
                byClient: [TokenClientBreakdown(client: .codex, totals: dNov12Codex, shareOfTokens: 1.0, activeDays: 1)]
            ),
            TokenDailyPoint(
                date: "2026-11-15",
                totals: dNov15Claude,
                activeTimeMs: 90_000,
                byClient: [TokenClientBreakdown(client: .claude, totals: dNov15Claude, shareOfTokens: 1.0, activeDays: 1)]
            ),
        ]

        let modelRecords: [TokenModelDayRecord] = [
            TokenModelDayRecord(date: "2026-01-05", client: .claude, modelId: "claude-sonnet-4", providerId: "anthropic", totals: dJanClaude),
            TokenModelDayRecord(date: "2026-11-10", client: .claude, modelId: "claude-sonnet-4", providerId: "anthropic", totals: dNov10Claude),
            TokenModelDayRecord(date: "2026-11-10", client: .codex, modelId: "gpt-6-codex", providerId: "openai", totals: dNov10Codex),
            TokenModelDayRecord(date: "2026-11-12", client: .codex, modelId: "gpt-6-codex", providerId: "openai", totals: dNov12Codex),
            TokenModelDayRecord(date: "2026-11-15", client: .claude, modelId: "claude-sonnet-4", providerId: "anthropic", totals: dNov15Claude),
        ]

        let projectRecords: [TokenProjectDayRecord] = [
            TokenProjectDayRecord(date: "2026-11-10", client: .claude, projectId: "p-alpha", projectName: "alpha", pathDisplay: "~/alpha", totals: dNov10Claude),
            TokenProjectDayRecord(date: "2026-11-10", client: .codex, projectId: "p-alpha", projectName: "alpha", pathDisplay: "~/alpha", totals: dNov10Codex),
            TokenProjectDayRecord(date: "2026-11-12", client: .codex, projectId: "p-beta", projectName: "beta", pathDisplay: "~/beta", totals: dNov12Codex),
            TokenProjectDayRecord(date: "2026-11-15", client: .claude, projectId: "p-alpha", projectName: "alpha", pathDisplay: "~/alpha", totals: dNov15Claude),
        ]

        let todayPreset = TokenRangeSummary(
            range: .today,
            startDate: "2026-11-15",
            endDate: "2026-11-15",
            totals: dNov15Claude,
            activeDays: 1,
            totalDaysInRange: 1,
            byClient: [TokenClientBreakdown(client: .claude, totals: dNov15Claude, shareOfTokens: 1.0, activeDays: 1)],
            byModel: [TokenModelBreakdown(client: .claude, modelId: "claude-sonnet-4", providerId: "anthropic", totals: dNov15Claude, shareOfTokens: 1.0)],
            byProject: [TokenProjectBreakdown(id: "p-alpha", projectName: "alpha", pathDisplay: "~/alpha", clients: [.claude], totals: dNov15Claude, shareOfTokens: 1.0, lastActiveDate: "2026-11-15")],
            dailySeries: [allDays[3]],
            isCustomRange: false
        )

        let snap = TokenUsageSnapshot(
            generatedAt: now,
            lastScannedAt: now,
            seedDaysCount: 0,
            totalDaysCount: allDays.count,
            liveScannedFilesCount: 4,
            archiveFileURLPath: "/tmp/archive.json",
            heatmap112Days: allDays,
            allDays: allDays,
            ranges: [.today: todayPreset],
            projectRecords: projectRecords,
            modelRecords: modelRecords
        )

        // availableDateBounds
        T.expectEqual(snap.availableDateBounds?.minDate, "2026-01-05")
        T.expectEqual(snap.availableDateBounds?.maxDate, "2026-11-15")

        // Single day custom query
        let singleDaySum = snap.summary(for: .singleDay("2026-11-10"))
        T.expectEqual(singleDaySum.isCustomRange, true)
        T.expectEqual(singleDaySum.startDate, "2026-11-10")
        T.expectEqual(singleDaySum.endDate, "2026-11-10")
        T.expectEqual(singleDaySum.totalDaysInRange, 1)
        T.expectEqual(singleDaySum.activeDays, 1)
        T.expectEqual(singleDaySum.dailySeries.count, 1)
        T.expectEqual(singleDaySum.totals.totalTokens, 3000)
        T.expectEqual(singleDaySum.byClient.map(\.client), [.claude, .codex])
        T.expectEqual(singleDaySum.byModel.map(\.modelId), ["claude-sonnet-4", "gpt-6-codex"])

        // Multi-day custom query (6 days, gap days zero-filled)
        let rangeSum = snap.summary(startDate: "2026-11-10", endDate: "2026-11-15")
        T.expectEqual(rangeSum.isCustomRange, true)
        T.expectEqual(rangeSum.totalDaysInRange, 6)
        T.expectEqual(rangeSum.activeDays, 3)
        T.expectEqual(rangeSum.dailySeries.count, 6, "<= 180 days must zero-fill contiguous calendar days")
        T.expectEqual(rangeSum.dailySeries.map(\.date), ["2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13", "2026-11-14", "2026-11-15"])
        T.expectEqual(rangeSum.dailySeries[1].totals.totalTokens, 0, "gap day 2026-11-11 must be zero-filled")
        T.expectEqual(rangeSum.dailySeries[1].heatmapLevel, 0)
        T.expect(rangeSum.dailySeries[2].heatmapLevel > 0, "active day must have positive heatmapLevel")
        T.expectEqual(rangeSum.totals.totalTokens, 12_000, "3000 + 5000 + 4000 = 12000")
        T.expectEqual(rangeSum.byModel.count, 2)
        // claude-sonnet-4 = 2000 + 4000 = 6000; gpt-6-codex = 1000 + 5000 = 6000 (tie-broken alphabetically: claude-sonnet-4 < gpt-6-codex)
        T.expectEqual(rangeSum.byModel[0].modelId, "claude-sonnet-4")
        T.expectEqual(rangeSum.byModel[0].totals.totalTokens, 6000)
        T.expect(abs(rangeSum.byModel[0].shareOfTokens - 0.5) < 0.0001)
        T.expectEqual(rangeSum.byModel[1].modelId, "gpt-6-codex")
        T.expectEqual(rangeSum.byModel[1].totals.totalTokens, 6000)
        T.expectEqual(rangeSum.byProject.first?.projectName, "alpha")
        T.expectEqual(rangeSum.byProject.first?.totals.totalTokens, 7000)

        // Reversed range produces identical result
        let reversedSum = snap.summary(startDate: "2026-11-15", endDate: "2026-11-10")
        T.expectEqual(reversedSum, rangeSum, "reversed startDate/endDate must auto-swap to identical summary")

        // Custom range + clientFilter (.codex)
        let codexRangeSum = snap.summary(for: .normalizedCustom(startDate: "2026-11-10", endDate: "2026-11-15"), clientFilter: .codex)
        T.expectEqual(codexRangeSum.totals.totalTokens, 6000)
        T.expectEqual(codexRangeSum.activeDays, 2)
        T.expectEqual(codexRangeSum.dailySeries.count, 6)
        T.expectEqual(codexRangeSum.byClient.map(\.client), [.codex])
        T.expectEqual(codexRangeSum.byModel.map(\.modelId), ["gpt-6-codex"])
        T.expectEqual(codexRangeSum.byModel.first?.totals.totalTokens, 6000)
        T.expectEqual(codexRangeSum.byProject.map(\.projectName), ["beta", "alpha"])

        // Custom range + clientFilter with no data (.grok)
        let grokRangeSum = snap.summary(startDate: "2026-11-10", endDate: "2026-11-15", clientFilter: .grok)
        T.expectEqual(grokRangeSum.totals.totalTokens, 0)
        T.expectEqual(grokRangeSum.activeDays, 0)
        T.expectEqual(grokRangeSum.byClient.isEmpty, true)
        T.expectEqual(grokRangeSum.byModel.isEmpty, true)

        // Exact 180-day boundary -> contiguous zero-fill
        let boundary180 = snap.summary(startDate: "2026-01-01", endDate: "2026-06-29")
        T.expectEqual(boundary180.totalDaysInRange, 180)
        T.expectEqual(boundary180.dailySeries.count, 180, "exact 180-day span must zero-fill all 180 days")
        T.expectEqual(boundary180.activeDays, 1)
        T.expectEqual(boundary180.totals.totalTokens, 1000)

        // > 180-day span -> sparse mode for performance (only non-zero active days)
        let sparseAll = snap.summary(startDate: "2026-01-01", endDate: "2026-11-20")
        T.expectEqual(sparseAll.totalDaysInRange, 324)
        T.expectEqual(sparseAll.activeDays, 4)
        T.expectEqual(sparseAll.dailySeries.count, 4, "> 180 days must stay sparse (active days only)")
        T.expectEqual(sparseAll.dailySeries.map(\.date), ["2026-01-05", "2026-11-10", "2026-11-12", "2026-11-15"])
        T.expectEqual(sparseAll.totals.totalTokens, 13_000)

        let sparseCodex = snap.summary(startDate: "2026-01-01", endDate: "2026-11-20", clientFilter: .codex)
        T.expectEqual(sparseCodex.dailySeries.count, 2, "> 180 days with clientFilter must keep only that client's active days")
        T.expectEqual(sparseCodex.dailySeries.map(\.date), ["2026-11-10", "2026-11-12"])
        T.expectEqual(sparseCodex.totals.totalTokens, 6000)

        // Static aggregateModels helper
        let directAgg = TokenUsageSnapshot.aggregateModels(from: modelRecords, totalTokensDenominator: 13_000)
        T.expectEqual(directAgg.count, 2)
        T.expectEqual(directAgg[0].modelId, "claude-sonnet-4")
        T.expectEqual(directAgg[0].totals.totalTokens, 7000)
        T.expect(abs(directAgg[0].shareOfTokens - (7000.0 / 13_000.0)) < 0.0001)

        // 4. Backward-compatible JSON decode of legacy v1.0.0 snapshot (no `modelRecords`, no `isCustomRange`)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let rawSnapData = try encoder.encode(snap)
        var rawSnapJSON = try JSONSerialization.jsonObject(with: rawSnapData) as! [String: Any]
        rawSnapJSON.removeValue(forKey: "modelRecords")
        rawSnapJSON.removeValue(forKey: "projectRecords")
        if var rangesArr = rawSnapJSON["ranges"] as? [Any] {
            for idx in stride(from: 1, to: rangesArr.count, by: 2) {
                if var summaryDict = rangesArr[idx] as? [String: Any] {
                    summaryDict.removeValue(forKey: "isCustomRange")
                    rangesArr[idx] = summaryDict
                }
            }
            rawSnapJSON["ranges"] = rangesArr
        } else if var rangesDict = rawSnapJSON["ranges"] as? [String: Any] {
            for (k, v) in rangesDict {
                if var summaryDict = v as? [String: Any] {
                    summaryDict.removeValue(forKey: "isCustomRange")
                    rangesDict[k] = summaryDict
                }
            }
            rawSnapJSON["ranges"] = rangesDict
        }
        let legacySnapData = try JSONSerialization.data(withJSONObject: rawSnapJSON)
        let decodedLegacySnap = try decoder.decode(TokenUsageSnapshot.self, from: legacySnapData)
        T.expectEqual(decodedLegacySnap.modelRecords, [], "legacy snapshot without modelRecords must default to []")
        T.expectEqual(decodedLegacySnap.ranges[.today]?.isCustomRange, false, "legacy TokenRangeSummary without isCustomRange must default to false")
        // Legacy snapshot custom query matching preset bounds falls back to preset byModel/byProject
        let fallbackCustom = decodedLegacySnap.summary(startDate: "2026-11-15", endDate: "2026-11-15")
        T.expectEqual(fallbackCustom.byModel.first?.modelId, "claude-sonnet-4", "legacy snapshot without modelRecords must fall back to matching preset models")
        T.expectEqual(fallbackCustom.byProject.first?.projectName, "alpha")

        // 5. Real TokenUsageEngine populates snapshot.modelRecords for custom range queries
        let engineDir = try makeTempDir(prefix: "pulsar-v110-model-records")
        defer { try? FileManager.default.removeItem(at: engineDir) }
        let eHome = engineDir.appendingPathComponent("home", isDirectory: true)
        let eSupport = engineDir.appendingPathComponent("support", isDirectory: true)
        let claudeDir = eHome.appendingPathComponent(".claude/projects/v110", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"assistant","timestamp":"2026-11-18T02:00:00Z","cwd":"/Users/example/v110","message":{"id":"m1","model":"claude-sonnet-4","usage":{"input_tokens":300,"output_tokens":200,"cache_read_input_tokens":500,"cache_creation_input_tokens":0}}}"#,
            #"{"type":"assistant","timestamp":"2026-11-19T02:00:00Z","cwd":"/Users/example/v110","message":{"id":"m2","model":"claude-opus-5-5","usage":{"input_tokens":400,"output_tokens":600,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0}}}"#,
        ].joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: claudeDir.appendingPathComponent("s.jsonl"))

        let engine = TokenUsageEngine(homeDirectoryURL: eHome, appSupportURL: eSupport)
        let scannedSnap = await engine.scanAndExportArchive(forceFullRescan: true, now: now)
        T.expectEqual(scannedSnap.modelRecords.count, 2, "TokenUsageEngine must populate snapshot.modelRecords")
        let nov18Only = scannedSnap.summary(for: .singleDay("2026-11-18"))
        T.expectEqual(nov18Only.byModel.map(\.modelId), ["claude-sonnet-4"])
        T.expectEqual(nov18Only.totals.totalTokens, 1000)
        let nov19Only = scannedSnap.summary(for: .singleDay("2026-11-19"))
        T.expectEqual(nov19Only.byModel.map(\.modelId), ["claude-opus-5-5"])
        T.expectEqual(nov19Only.totals.totalTokens, 2000)

        // 6. AppStore.tokenUsageDateSelection default Today & switching methods
        let regURL = engineDir.appendingPathComponent("registry.json")
        let store = await MainActor.run {
            AppStore(
                keychain: KeychainStore(backend: InMemoryKeychainBackend()),
                processController: ProcessController(inspector: MockProcessInspector()),
                adapters: [:],
                registryURL: regURL,
                startScheduler: false,
                tokenUsageEngine: engine,
                accountPoolExporter: AccountPoolExporter(appSupportURL: engineDir),
                persistAccountPoolExport: false
            )
        }

        let (initialSel, afterPreset, afterSingle, afterReversedCustom, afterDateEnum, afterDateBounds, afterReset, activeSummaryTokens) = await MainActor.run {
            () -> (
                TokenUsageDateSelection,
                TokenUsageDateSelection,
                TokenUsageDateSelection,
                TokenUsageDateSelection,
                TokenUsageDateSelection,
                TokenUsageDateSelection,
                TokenUsageDateSelection,
                Int64?
            ) in
            store.tokenUsage = snap
            let s0 = store.tokenUsageDateSelection
            store.selectTokenUsagePreset(.days7)
            let s1 = store.tokenUsageDateSelection
            store.selectTokenUsageSingleDay("2026-11-12")
            let s2 = store.tokenUsageDateSelection
            let activeTok = store.tokenUsageSummary()?.totals.totalTokens
            store.selectTokenUsageCustomRange(startDate: "2026-11-15", endDate: "2026-11-10")
            let s3 = store.tokenUsageDateSelection
            store.selectTokenUsageDate(.custom(startDate: "2026-11-19", endDate: "2026-11-11"))
            let s4 = store.tokenUsageDateSelection
            store.selectTokenUsageCustomRange(
                start: TokenFormatters.date(fromYMD: "2026-11-18")!,
                end: TokenFormatters.date(fromYMD: "2026-11-14")!
            )
            let s5 = store.tokenUsageDateSelection
            store.resetTokenUsageSelectionToToday()
            let s6 = store.tokenUsageDateSelection
            return (s0, s1, s2, s3, s4, s5, s6, activeTok)
        }
        T.expectEqual(initialSel, .preset(.today), "AppStore.tokenUsageDateSelection must default to .preset(.today)")
        T.expectEqual(afterPreset, .preset(.days7))
        T.expectEqual(afterSingle, .custom(startDate: "2026-11-12", endDate: "2026-11-12"))
        T.expectEqual(activeSummaryTokens, 5000)
        T.expectEqual(afterReversedCustom, .custom(startDate: "2026-11-10", endDate: "2026-11-15"))
        T.expectEqual(afterDateEnum, .custom(startDate: "2026-11-11", endDate: "2026-11-19"))
        T.expectEqual(afterDateBounds, .custom(startDate: "2026-11-14", endDate: "2026-11-18"))
        T.expectEqual(afterReset, .preset(.today))
    }

    // 15.4 Token Client Filter Custom Ordering (AppSettings & AppStore Disk Persistence)
    await T.asyncSuite("V110.TokenClientOrderNormalizationReorderingAndPersistence") {
        // Legacy JSON missing tokenClientOrder -> []
        let legacyJSON = #"{"selectedProvider":"antigravity"}"#
        let legacyDecoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))
        T.expectEqual(legacyDecoded.tokenClientOrder, [])
        T.expectEqual(legacyDecoded.hasCustomTokenClientOrder, false)

        // Normalization & deduplication via JSON decode and static helper
        let messyJSON = #"{"tokenClientOrder":[" codex ", "", "  ", "claude", "codex", "antigravity", "claude"]}"#
        let messyDecoded = try JSONDecoder().decode(AppSettings.self, from: Data(messyJSON.utf8))
        T.expectEqual(messyDecoded.tokenClientOrder, ["codex", "claude", "antigravity"])
        T.expectEqual(messyDecoded.hasCustomTokenClientOrder, true)
        T.expectEqual(
            AppSettings.normalizeTokenClientOrder(["  ", "grok", "grok", " kimi "]),
            ["grok", "kimi"]
        )

        // orderedTokenClients(from:) puts saved items first and appends remaining available items in original order
        var settings = AppSettings(tokenClientOrder: ["cursor", "grok", "kimi"])
        let available: [TokenClientID] = [.claude, .codex, .grok, .antigravity, .cursor]
        T.expectEqual(
            settings.orderedTokenClients(from: available),
            [.cursor, .grok, .claude, .codex, .antigravity],
            "saved items present in available come first; missing 'kimi' is skipped; remaining preserve original order"
        )

        // canMoveTokenClient & moveTokenClient(direction:)
        let availRaw = available.map(\.rawValue)
        T.expectEqual(settings.canMoveTokenClient(rawValue: "cursor", direction: .up, available: availRaw), false)
        T.expectEqual(settings.canMoveTokenClient(rawValue: "cursor", direction: .down, available: availRaw), true)
        T.expectEqual(settings.canMoveTokenClient(rawValue: "antigravity", direction: .down, available: availRaw), false)
        T.expectEqual(settings.canMoveTokenClient(rawValue: "antigravity", direction: .up, available: availRaw), true)

        settings.moveTokenClient(rawValue: "cursor", direction: .down, available: availRaw)
        T.expectEqual(settings.orderedTokenClients(from: available), [.grok, .cursor, .claude, .codex, .antigravity])
        // Hidden 'kimi' must still be preserved at tail!
        T.expectEqual(settings.tokenClientOrder.last, "kimi", "hidden previously-saved client must be preserved at tail")

        // moveTokenClient(toIndex:) drag reorder + bounds clamping
        settings.moveTokenClient(rawValue: "antigravity", toIndex: -5, available: availRaw)
        T.expectEqual(settings.orderedTokenClients(from: available), [.antigravity, .grok, .cursor, .claude, .codex])
        settings.moveTokenClient(rawValue: "grok", toIndex: 99, available: availRaw)
        T.expectEqual(settings.orderedTokenClients(from: available), [.antigravity, .cursor, .claude, .codex, .grok])

        // pinTokenClientToFront / pinTokenClientToEnd / resetTokenClientOrder
        settings.pinTokenClientToFront(rawValue: "codex", available: availRaw)
        T.expectEqual(settings.orderedTokenClients(from: available).first, .codex)
        settings.pinTokenClientToEnd(rawValue: "codex", available: availRaw)
        T.expectEqual(settings.orderedTokenClients(from: available).last, .codex)
        T.expectEqual(settings.tokenClientOrder.contains("kimi"), true, "hidden client survives pin operations")

        settings.resetTokenClientOrder()
        T.expectEqual(settings.tokenClientOrder, [])
        T.expectEqual(settings.hasCustomTokenClientOrder, false)
        T.expectEqual(settings.orderedTokenClients(from: available), available)

        // AppStore persistence & reload round-trip
        let dir = try makeTempDir(prefix: "pulsar-v110-client-order")
        defer { try? FileManager.default.removeItem(at: dir) }
        let regURL = dir.appendingPathComponent("registry.json")

        let store = await MainActor.run {
            AppStore(
                keychain: KeychainStore(backend: InMemoryKeychainBackend()),
                processController: ProcessController(inspector: MockProcessInspector()),
                adapters: [:],
                registryURL: regURL,
                startScheduler: false,
                tokenUsageEngine: TokenUsageEngine(homeDirectoryURL: dir, appSupportURL: dir),
                accountPoolExporter: AccountPoolExporter(appSupportURL: dir),
                persistAccountPoolExport: false
            )
        }

        let clients: [TokenClientID] = [.claude, .codex, .antigravity, .cursor]
        await MainActor.run {
            T.expectEqual(store.hasCustomTokenClientOrder, false)
            T.expectEqual(store.orderedTokenClients(from: clients), clients)
            store.pinTokenClientToFront(.cursor, available: clients)
            T.expectEqual(store.hasCustomTokenClientOrder, true)
            T.expectEqual(store.orderedTokenClients(from: clients), [.cursor, .claude, .codex, .antigravity])
            T.expectEqual(store.canMoveTokenClient(.cursor, direction: .up, available: clients), false)
            T.expectEqual(store.canMoveTokenClient(.cursor, direction: .down, available: clients), true)
            store.moveTokenClient(.codex, direction: .up, available: clients)
            T.expectEqual(store.orderedTokenClients(from: clients), [.cursor, .codex, .claude, .antigravity])
            store.moveTokenClient(.antigravity, toIndex: 1, available: clients)
            T.expectEqual(store.orderedTokenClients(from: clients), [.cursor, .antigravity, .codex, .claude])
            store.pinTokenClientToEnd(.cursor, available: clients)
            T.expectEqual(store.orderedTokenClients(from: clients), [.antigravity, .codex, .claude, .cursor])
        }

        let reloaded1 = try RegistryData.load(from: regURL)
        T.expectEqual(reloaded1.settings.tokenClientOrder, ["antigravity", "codex", "claude", "cursor"])

        await MainActor.run {
            store.resetTokenClientOrder()
            T.expectEqual(store.hasCustomTokenClientOrder, false)
            T.expectEqual(store.orderedTokenClients(from: clients), clients)
        }
        let reloaded2 = try RegistryData.load(from: regURL)
        T.expectEqual(reloaded2.settings.tokenClientOrder, [])
    }
}

// MARK: - Test 16: v1.2.0 Regression Suite (Stable-Only Relaunch, Fresh Reset Sync, AGY Pool Unification, Zero False Warning & ReleaseUpdater)

private func testV120RegressionSuite() async {
    // 16.1 Antigravity Stable-Only Relaunch (filterReopenURLs & AppStore setting)
    await T.asyncSuite("V120.AntigravityFilterReopenURLsAndSetting") {
        let stableURL = URL(fileURLWithPath: "/Applications/Antigravity.app", isDirectory: true)
        let insidersURL = URL(fileURLWithPath: "/Applications/Antigravity - Insiders.app", isDirectory: true)
        let customStableURL = URL(fileURLWithPath: "/Users/example/Applications/Antigravity.app", isDirectory: true)
        let customInsidersURL = URL(fileURLWithPath: "/Users/example/Applications/Antigravity-INSIDERS.app", isDirectory: true)

        // Default includeInsiders == false: filters Insiders & keeps at most 1 Stable URL
        let bothFiltered = AntigravityProvider.filterReopenURLs(
            [insidersURL, stableURL],
            includeInsiders: false,
            stableAppURL: stableURL,
            insidersAppURL: insidersURL,
            fileExists: { _ in true }
        )
        T.expectEqual(bothFiltered, [stableURL], "both running + includeInsiders=false must reopen only 1 Stable app")

        // Stable + Insiders + duplicate Stable -> still strictly 1 Stable URL
        let multiStableFiltered = AntigravityProvider.filterReopenURLs(
            [stableURL, insidersURL, stableURL, customStableURL],
            includeInsiders: false,
            stableAppURL: stableURL,
            insidersAppURL: insidersURL,
            fileExists: { _ in true }
        )
        T.expectEqual(multiStableFiltered, [stableURL], "must never relaunch multiple Stable bundles simultaneously")

        // Only Insiders running + Stable exists on disk -> switches back to Stable
        let insidersToStable = AntigravityProvider.filterReopenURLs(
            [insidersURL],
            includeInsiders: false,
            stableAppURL: stableURL,
            insidersAppURL: insidersURL,
            fileExists: { path in path == stableURL.path }
        )
        T.expectEqual(insidersToStable, [stableURL], "only Insiders running + Stable installed must reopen Stable")

        // Case-insensitive insiders name detection + Stable exists -> switches to Stable
        let customInsidersToStable = AntigravityProvider.filterReopenURLs(
            [customInsidersURL],
            includeInsiders: false,
            stableAppURL: stableURL,
            insidersAppURL: insidersURL,
            fileExists: { path in path == stableURL.path }
        )
        T.expectEqual(customInsidersToStable, [stableURL], "case-insensitive insiders bundle name must be recognized")

        // Only Insiders running + Stable NOT installed -> fallback to [insidersURL] (never empty)
        let insidersFallback = AntigravityProvider.filterReopenURLs(
            [insidersURL],
            includeInsiders: false,
            stableAppURL: stableURL,
            insidersAppURL: insidersURL,
            fileExists: { _ in false }
        )
        T.expectEqual(insidersFallback, [insidersURL], "when Stable does not exist, must fall back to existing Insiders instead of empty")

        // Empty input -> returns [] (never launches GUI unsolicited)
        let emptyResult = AntigravityProvider.filterReopenURLs(
            [],
            includeInsiders: false,
            stableAppURL: stableURL,
            insidersAppURL: insidersURL,
            fileExists: { _ in true }
        )
        T.expectEqual(emptyResult, [], "empty reopen list must stay empty")

        let emptyIncludeInsiders = AntigravityProvider.filterReopenURLs(
            [],
            includeInsiders: true,
            stableAppURL: stableURL,
            insidersAppURL: insidersURL,
            fileExists: { _ in true }
        )
        T.expectEqual(emptyIncludeInsiders, [], "empty reopen list with includeInsiders=true must stay empty")

        // includeInsiders == true -> keeps both Stable and Insiders (deduplicated)
        let bothPreserved = AntigravityProvider.filterReopenURLs(
            [stableURL, insidersURL, stableURL],
            includeInsiders: true,
            stableAppURL: stableURL,
            insidersAppURL: insidersURL,
            fileExists: { _ in true }
        )
        T.expectEqual(bothPreserved, [stableURL, insidersURL], "includeInsiders=true must preserve deduplicated Stable + Insiders")

        // AppStore persistence for relaunchAntigravityInsiders (default false)
        let dir = try makeTempDir(prefix: "pulsar-v120-relaunch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let regURL = dir.appendingPathComponent("registry.json")
        let store = await MainActor.run {
            AppStore(
                keychain: KeychainStore(backend: InMemoryKeychainBackend()),
                processController: ProcessController(inspector: MockProcessInspector()),
                adapters: [:],
                registryURL: regURL,
                startScheduler: false,
                tokenUsageEngine: TokenUsageEngine(homeDirectoryURL: dir, appSupportURL: dir),
                accountPoolExporter: AccountPoolExporter(appSupportURL: dir),
                persistAccountPoolExport: false
            )
        }
        let defaultFlag = await MainActor.run { store.registry.settings.relaunchAntigravityInsiders }
        T.expectEqual(defaultFlag, false, "relaunchAntigravityInsiders must default to false")
        await MainActor.run { store.setRelaunchAntigravityInsiders(true) }
        let reloaded = try RegistryData.load(from: regURL)
        T.expectEqual(reloaded.settings.relaunchAntigravityInsiders, true)
    }

    // 16.2 Antigravity Freshness, Anti-Cache Reset Sanitization & Stale Refresh Detection
    await T.asyncSuite("V120.AntigravityFreshnessAndExpiredResetDetection") {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let past10s = now.addingTimeInterval(-10)
        let past2s = now.addingTimeInterval(-2)
        let future1h = now.addingTimeInterval(3_600)

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let past10sISO = fmt.string(from: past10s)
        let future1hISO = fmt.string(from: future1h)

        // containsExpiredQuotaWindows unit checks
        let expiredWin = QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: 0.40, resetAt: past10s)
        let withinGraceWin = QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: 0.40, resetAt: past2s)
        let fullPastWin = QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: 1.0, resetAt: past10s)
        let futureWin = QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: 0.40, resetAt: future1h)
        let noResetWin = QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: 0.40, resetAt: nil)

        T.expectEqual(AntigravityProvider.containsExpiredQuotaWindows([expiredWin], now: now), true, "remaining < 1.0 & resetAt <= now - 5s must be flagged expired")
        T.expectEqual(AntigravityProvider.containsExpiredQuotaWindows([withinGraceWin], now: now), false, "resetAt within 5s grace must not be flagged expired")
        T.expectEqual(AntigravityProvider.containsExpiredQuotaWindows([fullPastWin], now: now), false, "full 1.0 window must not be flagged expired")
        T.expectEqual(AntigravityProvider.containsExpiredQuotaWindows([futureWin], now: now), false, "future resetAt must not be flagged expired")
        T.expectEqual(AntigravityProvider.containsExpiredQuotaWindows([noResetWin], now: now), false, "nil resetAt must not be flagged expired")

        // parseQuotaSummaryWindows: remaining == 1.0 && resetAt <= now clears stale resetAt;
        // remaining < 1.0 && resetAt <= now - 5s retains past resetAt & triggers containsExpiredQuotaWindows
        let summaryJSON: [String: Any] = [
            "summary": [
                "groups": [
                    [
                        "displayName": "Gemini",
                        "buckets": [
                            [
                                "window": "5h",
                                "remainingFraction": 1.0,
                                "resetTime": past10sISO,
                            ],
                            [
                                "window": "weekly",
                                "remainingFraction": 0.65,
                                "resetTime": future1hISO,
                            ],
                        ],
                    ],
                    [
                        "displayName": "Claude",
                        "buckets": [
                            [
                                "window": "5h",
                                "remainingFraction": 0.25,
                                "resetTime": past10sISO,
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let summaryWindows = AntigravityProvider.parseQuotaSummaryWindows(from: summaryJSON, now: now)
        let summaryGem5h = summaryWindows.first { $0.antigravityPoolKind == .gemini && $0.windowSeconds == 18_000 }
        let summaryGemWk = summaryWindows.first { $0.antigravityPoolKind == .gemini && $0.windowSeconds == 604_800 }
        let summaryClaude5h = summaryWindows.first { $0.antigravityPoolKind == .claude }
        T.expect(summaryGem5h != nil, "expected Gemini 5h window from summary parser")
        T.expectEqual(summaryGem5h?.remainingFraction, 1.0)
        T.expectEqual(summaryGem5h?.resetAt, nil, "parseQuotaSummaryWindows must clear past resetAt when remaining == 1.0")
        T.expect(summaryGemWk?.resetAt != nil, "future resetAt must be preserved")
        T.expect(summaryClaude5h != nil, "expected Claude 5h window from summary parser")
        T.expect(summaryClaude5h?.resetAt != nil, "past resetAt must remain when remaining < 1.0 so expiry is detected")
        T.expectEqual(
            AntigravityProvider.containsExpiredQuotaWindows([summaryGem5h!, summaryGemWk!], now: now),
            false,
            "fresh Gemini windows must not trigger expired check"
        )
        T.expectEqual(
            AntigravityProvider.containsExpiredQuotaWindows(summaryWindows, now: now),
            true,
            "summary windows with remaining < 1.0 & past resetAt must be marked expired"
        )

        // parseModelConfigWindows: same sanitization & expiry detection
        let modelConfigJSON: [String: Any] = [
            "userStatus": [
                "cascadeModelConfigData": [
                    "clientModelConfigs": [
                        [
                            "label": "Gemini 3 Pro",
                            "modelOrAlias": ["model": "gemini-3-pro"],
                            "quotaInfo": [
                                "remainingFraction": 1.0,
                                "resetTime": past10sISO,
                            ],
                        ],
                        [
                            "label": "Claude Sonnet",
                            "modelOrAlias": ["model": "claude-sonnet"],
                            "quotaInfo": [
                                "remainingFraction": 0.50,
                                "resetTime": past10sISO,
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let cfgWindows = AntigravityProvider.parseModelConfigWindows(from: modelConfigJSON, now: now)
        let cfgGem = cfgWindows.first { $0.antigravityPoolKind == .gemini }
        let cfgClaude = cfgWindows.first { $0.antigravityPoolKind == .claude }
        T.expect(cfgGem != nil && cfgClaude != nil, "expected Gemini and Claude windows from modelConfig parser")
        T.expectEqual(cfgGem?.resetAt, nil, "parseModelConfigWindows must clear past resetAt when remaining == 1.0")
        T.expect(cfgClaude?.resetAt != nil, "parseModelConfigWindows must preserve past resetAt when remaining < 1.0")
        T.expectEqual(AntigravityProvider.containsExpiredQuotaWindows(cfgWindows, now: now), true)

        // AppStore.hasExpiredResetWindow
        let snapJustExpired = QuotaSnapshot(
            provider: .antigravity,
            accountId: "ag:a",
            windows: [QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: 0.30, resetAt: now.addingTimeInterval(-30))],
            status: .ready(fetchedAt: now.addingTimeInterval(-120), stale: false),
            primaryRemainingPercent: 30
        )
        let snapFetchedAfterReset = QuotaSnapshot(
            provider: .antigravity,
            accountId: "ag:b",
            windows: [QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: 1.0, resetAt: now.addingTimeInterval(-30))],
            status: .ready(fetchedAt: now.addingTimeInterval(-5), stale: false),
            primaryRemainingPercent: 100
        )
        let snapFutureReset = QuotaSnapshot(
            provider: .antigravity,
            accountId: "ag:c",
            windows: [QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: 0.70, resetAt: future1h)],
            status: .ready(fetchedAt: now.addingTimeInterval(-10), stale: false),
            primaryRemainingPercent: 70
        )
        let snapFailed = QuotaSnapshot.failed(provider: .antigravity, accountId: "ag:d", message: "timeout")

        T.expectEqual(AppStore.hasExpiredResetWindow(in: snapJustExpired, now: now), true, "fetchedAt < resetAt <= now must trigger hasExpiredResetWindow")
        T.expectEqual(AppStore.hasExpiredResetWindow(in: snapFetchedAfterReset, now: now), false, "fetchedAt >= resetAt must not trigger hasExpiredResetWindow")
        T.expectEqual(AppStore.hasExpiredResetWindow(in: snapFutureReset, now: now), false, "future resetAt must not trigger hasExpiredResetWindow")
        T.expectEqual(AppStore.hasExpiredResetWindow(in: snapFailed, now: now), false, "non-ready snapshot must not trigger hasExpiredResetWindow")

        // AppStore.providersNeedingStaleRefresh
        struct StubAdapter: ProviderAdapter {
            let id: ProviderID
            let capabilities: ProviderCapability = [.quota]
            func syncLiveAccount(registry: inout RegistryData) async -> String? { nil }
            func fetchQuota(for account: AccountRecord, isActiveLive: Bool) async -> QuotaSnapshot {
                QuotaSnapshot.unconfigured(provider: id, accountId: account.id, message: "stub")
            }
        }

        let dir = try makeTempDir(prefix: "pulsar-v120-stale")
        defer { try? FileManager.default.removeItem(at: dir) }
        let regURL = dir.appendingPathComponent("registry.json")
        let store = await MainActor.run {
            AppStore(
                keychain: KeychainStore(backend: InMemoryKeychainBackend()),
                processController: ProcessController(inspector: MockProcessInspector()),
                adapters: [
                    .antigravity: StubAdapter(id: .antigravity),
                    .codex: StubAdapter(id: .codex),
                    .grok: StubAdapter(id: .grok),
                ],
                registryURL: regURL,
                startScheduler: false,
                tokenUsageEngine: TokenUsageEngine(homeDirectoryURL: dir, appSupportURL: dir),
                accountPoolExporter: AccountPoolExporter(appSupportURL: dir),
                persistAccountPoolExport: false
            )
        }

        let (freshList, expiredAndStaleList, oldAgeList) = await MainActor.run { () -> ([ProviderID], [ProviderID], [ProviderID]) in
            store.lastRefreshedAt = now.addingTimeInterval(-10)
            store.snapshots[AppStore.snapshotKey(provider: .antigravity, accountId: "ag:1")] = QuotaSnapshot(
                provider: .antigravity,
                accountId: "ag:1",
                windows: [QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: 0.9, resetAt: future1h)],
                status: .ready(fetchedAt: now.addingTimeInterval(-10), stale: false),
                primaryRemainingPercent: 90
            )
            store.snapshots[AppStore.snapshotKey(provider: .codex, accountId: "cx:1")] = QuotaSnapshot(
                provider: .codex,
                accountId: "cx:1",
                windows: [QuotaWindow(id: "5h", label: "5小时", remainingFraction: 0.8, resetAt: future1h)],
                status: .ready(fetchedAt: now.addingTimeInterval(-10), stale: false),
                primaryRemainingPercent: 80
            )
            store.snapshots[AppStore.snapshotKey(provider: .grok, accountId: "gk:1")] = QuotaSnapshot(
                provider: .grok,
                accountId: "gk:1",
                windows: [QuotaWindow(id: "primary", label: "主窗口", remainingFraction: 0.8, resetAt: future1h)],
                status: .ready(fetchedAt: now.addingTimeInterval(-10), stale: false),
                primaryRemainingPercent: 80
            )
            let l1 = store.providersNeedingStaleRefresh(maxAgeSeconds: 45, providers: [.antigravity, .codex, .grok, .cursor], now: now)

            // Mark AGY expired reset and Grok stale, keep Codex fresh
            store.snapshots[AppStore.snapshotKey(provider: .antigravity, accountId: "ag:1")] = snapJustExpired
            store.snapshots[AppStore.snapshotKey(provider: .grok, accountId: "gk:1")] = QuotaSnapshot(
                provider: .grok,
                accountId: "gk:1",
                windows: [QuotaWindow(id: "primary", label: "主窗口", remainingFraction: 0.8, resetAt: future1h)],
                status: .ready(fetchedAt: now.addingTimeInterval(-10), stale: true),
                primaryRemainingPercent: 80
            )
            let l2 = store.providersNeedingStaleRefresh(maxAgeSeconds: 45, providers: [.antigravity, .codex, .grok, .cursor], now: now)

            // Age exceeds 45s -> Codex also becomes eligible, while .cursor without adapter is excluded
            store.lastRefreshedAt = now.addingTimeInterval(-60)
            let l3 = store.providersNeedingStaleRefresh(maxAgeSeconds: 45, providers: [.antigravity, .codex, .grok, .cursor], now: now)
            return (l1, l2, l3)
        }
        T.expectEqual(freshList, [], "fresh non-expired providers must not require stale refresh")
        T.expectEqual(expiredAndStaleList, [.antigravity, .grok], "expired-reset AGY and stale Grok must require refresh; fresh Codex and adapterless Cursor excluded")
        T.expectEqual(oldAgeList, [.antigravity, .codex, .grok], "providers older than maxAgeSeconds must require refresh; adapterless Cursor excluded")
    }

    // 16.3 Antigravity Pool Unification, Backward-Compat Config Decode & Zero False Warning
    await T.asyncSuite("V120.AntigravityPoolUnificationAndZeroFalseWarning") {
        // 1. Backward-compatible decode of AccountCardConfig.filterAntigravityCardPools & AppSettings v1.2.0 fields
        let legacyCardJSON = #"{"showAvatar":true,"showPlanBadge":true,"pillQuotaWindow":"weeklyFirst"}"#
        let decodedLegacyCard = try JSONDecoder().decode(AccountCardConfig.self, from: Data(legacyCardJSON.utf8))
        T.expectEqual(decodedLegacyCard.filterAntigravityCardPools, false, "legacy AccountCardConfig must default filterAntigravityCardPools to false")

        let customCard = AccountCardConfig(filterAntigravityCardPools: true)
        let cardRoundTrip = try JSONDecoder().decode(AccountCardConfig.self, from: JSONEncoder().encode(customCard))
        T.expectEqual(cardRoundTrip.filterAntigravityCardPools, true)

        let legacySettingsJSON = #"{"selectedProvider":"antigravity"}"#
        let decodedLegacySettings = try JSONDecoder().decode(AppSettings.self, from: Data(legacySettingsJSON.utf8))
        T.expectEqual(decodedLegacySettings.relaunchAntigravityInsiders, false)
        T.expectEqual(decodedLegacySettings.autoCheckUpdates, true)
        T.expectEqual(decodedLegacySettings.skippedUpdateVersion, nil)
        T.expectEqual(decodedLegacySettings.lastUpdateCheckAt, nil)

        let checkDate = Date(timeIntervalSince1970: 1_800_000_500)
        let v12Settings = AppSettings(
            relaunchAntigravityInsiders: true,
            autoCheckUpdates: false,
            skippedUpdateVersion: "  1.2.1  ",
            lastUpdateCheckAt: checkDate
        )
        T.expectEqual(v12Settings.skippedUpdateVersion, "1.2.1")
        let settingsEncoder = JSONEncoder()
        settingsEncoder.dateEncodingStrategy = .iso8601
        let settingsDecoder = JSONDecoder()
        settingsDecoder.dateDecodingStrategy = .iso8601
        let settingsRoundTrip = try settingsDecoder.decode(AppSettings.self, from: settingsEncoder.encode(v12Settings))
        T.expectEqual(settingsRoundTrip.relaunchAntigravityInsiders, true)
        T.expectEqual(settingsRoundTrip.autoCheckUpdates, false)
        T.expectEqual(settingsRoundTrip.skippedUpdateVersion, "1.2.1")
        T.expectEqual(settingsRoundTrip.lastUpdateCheckAt, checkDate)

        let whitespaceSkippedJSON = #"{"skippedUpdateVersion":"   "}"#
        let whitespaceDecoded = try JSONDecoder().decode(AppSettings.self, from: Data(whitespaceSkippedJSON.utf8))
        T.expectEqual(whitespaceDecoded.skippedUpdateVersion, nil, "whitespace-only skippedUpdateVersion must normalize to nil")

        // 2. Pool unification: AGY Gemini 100% + Claude/GPT weekly 2% with antigravityPool == .gemini
        let dir = try makeTempDir(prefix: "pulsar-v120-pool-unify")
        defer { try? FileManager.default.removeItem(at: dir) }
        let regURL = dir.appendingPathComponent("registry.json")

        let now = Date()
        let agyAcc1 = AccountRecord(id: "ag:acct1", provider: .antigravity, email: "alpha@example.com", displayName: "Alpha", isActiveLive: true)
        let agyAcc2 = AccountRecord(id: "ag:acct2", provider: .antigravity, email: "beta@example.com", displayName: "Beta", isActiveLive: false)
        let cursorAcc = AccountRecord(id: "cursor:default", provider: .cursor, email: "", displayName: "Cursor", isActiveLive: true)

        let gem5hFull = QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: 1.0, usedPercent: 0.0, windowSeconds: 18_000, isPrimary: true)
        let gemWkFull = QuotaWindow(id: "gemini_weekly", label: "Gemini · 周", remainingFraction: 1.0, usedPercent: 0.0, windowSeconds: 604_800, isPrimary: false)
        let claudeWkLow = QuotaWindow(id: "claude_weekly", label: "Claude / GPT · 周", remainingFraction: 0.02, usedPercent: 98.0, windowSeconds: 604_800, isPrimary: false)
        let argonWkMid = QuotaWindow(id: "argon_weekly", label: "Argon · 周", remainingFraction: 0.55, usedPercent: 45.0, windowSeconds: 604_800, isPrimary: false)

        let snapAgy1 = QuotaSnapshot(
            provider: .antigravity,
            accountId: agyAcc1.id,
            windows: [gem5hFull, gemWkFull, claudeWkLow, argonWkMid],
            status: .ready(fetchedAt: now, stale: false),
            primaryRemainingPercent: 2
        )
        let snapAgy2 = QuotaSnapshot(
            provider: .antigravity,
            accountId: agyAcc2.id,
            windows: [
                QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: 0.45, usedPercent: 55.0, windowSeconds: 18_000, isPrimary: true),
                QuotaWindow(id: "gemini_weekly", label: "Gemini · 周", remainingFraction: 0.40, usedPercent: 60.0, windowSeconds: 604_800, isPrimary: false),
                QuotaWindow(id: "claude_weekly", label: "Claude / GPT · 周", remainingFraction: 0.90, usedPercent: 10.0, windowSeconds: 604_800, isPrimary: false),
            ],
            status: .ready(fetchedAt: now, stale: false),
            primaryRemainingPercent: 40
        )
        let snapCursorReauth = QuotaSnapshot(
            provider: .cursor,
            accountId: cursorAcc.id,
            windows: [],
            status: .reauthRequired("Cursor needs login"),
            primaryRemainingPercent: nil
        )

        // Direct AccountRecord.bestRemainingAccountId verification per pool
        let snapByAccountId: [String: QuotaSnapshot] = [
            agyAcc1.id: snapAgy1,
            agyAcc2.id: snapAgy2,
        ]
        T.expectEqual(
            AccountRecord.bestRemainingAccountId(for: .antigravity, accounts: [agyAcc1, agyAcc2], snapshots: snapByAccountId, antigravityPool: .gemini),
            agyAcc1.id,
            "antigravityPool == .gemini must pick acct1 (Gemini 100% > 40%)"
        )
        T.expectEqual(
            AccountRecord.bestRemainingAccountId(for: .antigravity, accounts: [agyAcc1, agyAcc2], snapshots: snapByAccountId, antigravityPool: .claude),
            agyAcc2.id,
            "antigravityPool == .claude must pick acct2 (Claude 90% > 2%)"
        )
        T.expectEqual(
            AccountRecord.bestRemainingAccountId(for: .antigravity, accounts: [agyAcc1, agyAcc2], snapshots: snapByAccountId, antigravityPool: .autoLowest),
            agyAcc2.id,
            "antigravityPool == .autoLowest must pick acct2 (min 40% > min 2%)"
        )

        let store = await MainActor.run {
            AppStore(
                keychain: KeychainStore(backend: InMemoryKeychainBackend()),
                processController: ProcessController(inspector: MockProcessInspector()),
                adapters: [:],
                registryURL: regURL,
                startScheduler: false,
                tokenUsageEngine: TokenUsageEngine(homeDirectoryURL: dir, appSupportURL: dir),
                accountPoolExporter: AccountPoolExporter(appSupportURL: dir),
                persistAccountPoolExport: false
            )
        }

        let (
            geminiSelectedDetail,
            geminiPillText,
            geminiPillPercent,
            geminiMatch,
            claudeMatch,
            bestIdUnderGemini,
            lowestCustomWithSidelineCursor,
            lowestModeWithSidelineCursor,
            claudePoolDetail,
            claudePillText,
            allErroredLowestDetail
        ) = await MainActor.run {
            () -> (
                MenuBarSummary,
                String,
                Double?,
                Bool,
                Bool,
                String?,
                MenuBarSummary,
                MenuBarSummary,
                MenuBarSummary,
                String,
                MenuBarSummary
            ) in
            store.registry.accounts = [agyAcc1, agyAcc2, cursorAcc]
            store.registry.settings.enabledProviders = [.antigravity, .cursor]
            store.registry.settings.selectedProvider = .antigravity
            store.registry.settings.showRemainingPercent = true
            store.snapshots[AppStore.snapshotKey(provider: .antigravity, accountId: agyAcc1.id)] = snapAgy1
            store.snapshots[AppStore.snapshotKey(provider: .antigravity, accountId: agyAcc2.id)] = snapAgy2
            store.snapshots[AppStore.snapshotKey(provider: .cursor, accountId: cursorAcc.id)] = snapCursorReauth

            // Select Gemini pool
            store.setAntigravityPool(.gemini)
            store.registry.settings.menuBarDisplayMode = .selectedProvider
            let selDetail = store.menuBarSummaryDetail()
            let pillGem = store.pillBadgeInfo(for: .antigravity)
            let isGemMatch = store.isAntigravityWindowMatchingPool(gemWkFull)
            let isClaudeMatch = store.isAntigravityWindowMatchingPool(claudeWkLow)
            let bestGem = store.registry.accounts.first(where: { $0.provider == .antigravity && $0.isBestRemaining })?.id

            // Custom mode + quotaSource == .lowest with sideline Cursor .reauthRequired -> MUST NOT warn yellow!
            store.registry.settings.menuBarDisplayMode = .custom
            store.updateMenuBarCustom { cfg in
                cfg.modules = [.quota]
                cfg.quotaSource = .lowest
                cfg.quotaWindow = .weeklyFirst
                cfg.antigravityPool = .gemini
                cfg.showProviderPrefix = true
            }
            let lowestCustom = store.menuBarSummaryDetail()

            // Built-in .lowestQuota mode with sideline Cursor .reauthRequired -> MUST NOT warn yellow!
            store.registry.settings.menuBarDisplayMode = .lowestQuota
            let lowestBuiltIn = store.menuBarSummaryDetail()

            // Switch to Claude pool -> now AGY 2% must warn yellow and pill returns 2%
            store.setAntigravityPool(.claude)
            store.registry.settings.menuBarDisplayMode = .selectedProvider
            let claudeDetail = store.menuBarSummaryDetail()
            let pillClaude = store.pillBadgeInfo(for: .antigravity)

            // When ALL enabled providers fail, quotaSource == .lowest MUST warn
            store.registry.settings.menuBarDisplayMode = .custom
            store.updateMenuBarCustom { cfg in
                cfg.modules = [.quota]
                cfg.quotaSource = .lowest
                cfg.antigravityPool = .gemini
            }
            store.snapshots[AppStore.snapshotKey(provider: .antigravity, accountId: agyAcc1.id)] = QuotaSnapshot.failed(
                provider: .antigravity,
                accountId: agyAcc1.id,
                message: "offline"
            )
            let allErr = store.menuBarSummaryDetail()

            return (
                selDetail,
                pillGem.text,
                pillGem.remainingPercent,
                isGemMatch,
                isClaudeMatch,
                bestGem,
                lowestCustom,
                lowestBuiltIn,
                claudeDetail,
                pillClaude.text,
                allErr
            )
        }

        T.expectEqual(geminiSelectedDetail.title, "AGY 100%", "Gemini pool must display AGY 100% despite Claude weekly 2%")
        T.expectEqual(geminiSelectedDetail.isWarning, false, "Gemini 100% must have isWarning == false")
        T.expectEqual(geminiPillText, "100%", "pillBadgeInfo(for: .antigravity) must display 100% under Gemini pool")
        T.expectEqual(geminiPillPercent, 100.0)
        T.expectEqual(geminiMatch, true)
        T.expectEqual(claudeMatch, false)
        T.expectEqual(bestIdUnderGemini, agyAcc1.id, "AppStore best-remaining badge must follow antigravityPool == .gemini")

        T.expectEqual(lowestCustomWithSidelineCursor.title, "AGY 100%")
        T.expectEqual(lowestCustomWithSidelineCursor.isWarning, false, "quotaSource == .lowest with healthy AGY 100% and sideline Cursor .reauthRequired must NOT false-warn yellow")
        T.expectEqual(lowestModeWithSidelineCursor.title, "AGY 100%")
        T.expectEqual(lowestModeWithSidelineCursor.isWarning, false, ".lowestQuota with healthy AGY 100% and sideline Cursor .reauthRequired must NOT false-warn yellow")

        T.expectEqual(claudePoolDetail.title, "AGY 2%")
        T.expectEqual(claudePoolDetail.isWarning, true)
        T.expectEqual(claudePillText, "2%")
        T.expectEqual(allErroredLowestDetail.isWarning, true, "when all enabled providers error, isWarning must be true")
    }

    // 16.4 GitHub Releases Auto-Update Engine (ReleaseUpdater)
    await T.asyncSuite("V120.ReleaseUpdaterEngine") {
        // 1. PulsarSemVer comparison & invalid parsing
        guard let v110 = PulsarSemVer.parse("1.1.0"),
              let v120 = PulsarSemVer.parse("v1.2.0"),
              let v120Plain = PulsarSemVer.parse("1.2.0"),
              let v120Build = PulsarSemVer.parse("1.2.0+build.99"),
              let v120Alpha = PulsarSemVer.parse("1.2.0-alpha"),
              let v120Beta1 = PulsarSemVer.parse("1.2.0-beta.1"),
              let v120Beta2 = PulsarSemVer.parse("1.2.0-beta.2"),
              let v120RC1 = PulsarSemVer.parse("v1.2.0-rc.1"),
              let v130 = PulsarSemVer.parse("V1.3.0") else {
            T.expect(false, "valid SemVer strings must parse")
            return
        }
        T.expect(v120 > v110, "v1.2.0 must be > 1.1.0")
        T.expect(v130 > v120, "1.3.0 must be > v1.2.0")
        T.expectEqual(v120, v120Plain)
        T.expectEqual(v120, v120Build, "+build metadata must not change SemVer equality")
        T.expect(v120 > v120RC1, "final release must strictly outrank same-core prerelease")
        T.expect(v120RC1 > v120Beta2)
        T.expect(v120Beta2 > v120Beta1)
        T.expect(v120Beta1 > v120Alpha)
        T.expectEqual(v120.isPrerelease, false)
        T.expectEqual(v120Beta1.isPrerelease, true)

        for invalid in ["", "   ", "v", "abc", "1", "1.2.3.4", "1.2.x", "1.2.0-", "1.2.0-bad_pre", "-1.0.0"] {
            T.expectEqual(PulsarSemVer.parse(invalid), nil, "invalid SemVer '\(invalid)' must return nil")
        }
        let semverRoundTrip = try JSONDecoder().decode(PulsarSemVer.self, from: JSONEncoder().encode(v120Beta2))
        T.expectEqual(semverRoundTrip, v120Beta2)

        // 2. Strict 4-host HTTPS allowlist
        let allowedURLs = [
            "https://api.github.com/repos/rorywang98-netizen/Pulsar/releases/latest",
            "https://github.com/rorywang98-netizen/Pulsar/releases/download/v1.2.0/Pulsar-v1.2.0-macOS-arm64.dmg",
            "https://objects.githubusercontent.com/github-production-release-asset/12345/Pulsar.dmg",
            "https://release-assets.githubusercontent.com/github-production-release-asset/12345/Pulsar.dmg",
            "HTTPS://API.GITHUB.COM/repos/rorywang98-netizen/Pulsar/releases/latest",
        ]
        for raw in allowedURLs {
            T.expectEqual(ReleaseUpdater.isAllowedHost(URL(string: raw)!), true, "must allow \(raw)")
        }
        let blockedHostA = "api." + "anthropic" + ".com"
        let blockedHostB = "claude" + ".ai"
        let blockedURLs = [
            "http://api.github.com/repos/rorywang98-netizen/Pulsar/releases/latest",
            "http://github.com/rorywang98-netizen/Pulsar/releases",
            "https://\(blockedHostA)/v1/messages",
            "https://\(blockedHostB)/api/organizations",
            "https://example.com/Pulsar.dmg",
            "https://api.github.com.evil.example/releases/latest",
            "https://evil-github.com/Pulsar.dmg",
            "https://user:pass@github.com/rorywang98-netizen/Pulsar/releases",
            "file:///tmp/Pulsar.dmg",
        ]
        for raw in blockedURLs {
            T.expectEqual(ReleaseUpdater.isAllowedHost(URL(string: raw)!), false, "must reject \(raw)")
        }

        // 3. parseLatestReleaseJSON (new version with arm64 .dmg + .sha256, up-to-date, draft/prerelease, disallowed hosts)
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let newReleaseJSON = """
        {
          "tag_name": "v1.3.0",
          "name": "Pulsar v1.3.0",
          "body": "New features and fixes.",
          "html_url": "https://github.com/rorywang98-netizen/Pulsar/releases/tag/v1.3.0",
          "published_at": "2026-11-22T08:00:00Z",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "Pulsar-v1.3.0-macOS-x86_64.dmg",
              "size": 5000000,
              "browser_download_url": "https://github.com/rorywang98-netizen/Pulsar/releases/download/v1.3.0/Pulsar-v1.3.0-macOS-x86_64.dmg"
            },
            {
              "name": "Pulsar-v1.3.0-macOS-arm64.dmg",
              "size": 4567890,
              "browser_download_url": "https://github.com/rorywang98-netizen/Pulsar/releases/download/v1.3.0/Pulsar-v1.3.0-macOS-arm64.dmg"
            },
            {
              "name": "Pulsar-v1.3.0-macOS-arm64.dmg.sha256",
              "size": 99,
              "browser_download_url": "https://github.com/rorywang98-netizen/Pulsar/releases/download/v1.3.0/Pulsar-v1.3.0-macOS-arm64.dmg.sha256"
            },
            {
              "name": "bad-host-arm64.dmg",
              "size": 123,
              "browser_download_url": "https://evil.example.com/bad-host-arm64.dmg"
            }
          ]
        }
        """
        let parsedNew = try ReleaseUpdater.parseLatestReleaseJSON(Data(newReleaseJSON.utf8), currentVersion: "1.2.0", checkedAt: fixedNow)
        if case .updateAvailable(let info) = parsedNew {
            T.expectEqual(info.version, "1.3.0")
            T.expectEqual(info.tagName, "v1.3.0")
            T.expectEqual(info.title, "Pulsar v1.3.0")
            T.expectEqual(info.releaseNotes, "New features and fixes.")
            T.expectEqual(info.dmgFileName, "Pulsar-v1.3.0-macOS-arm64.dmg", "must prefer arm64 .dmg over other arches")
            T.expectEqual(
                info.dmgDownloadURL?.absoluteString,
                "https://github.com/rorywang98-netizen/Pulsar/releases/download/v1.3.0/Pulsar-v1.3.0-macOS-arm64.dmg"
            )
            T.expectEqual(
                info.sha256DownloadURL?.absoluteString,
                "https://github.com/rorywang98-netizen/Pulsar/releases/download/v1.3.0/Pulsar-v1.3.0-macOS-arm64.dmg.sha256"
            )
            T.expectEqual(info.assetSizeBytes, 4_567_890)
            T.expect(info.publishedAt != nil)
        } else {
            T.expect(false, "expected .updateAvailable for v1.3.0 vs 1.2.0, got \(parsedNew)")
        }

        // Up-to-date when current >= remote
        let parsedSame = try ReleaseUpdater.parseLatestReleaseJSON(Data(newReleaseJSON.utf8), currentVersion: "1.3.0", checkedAt: fixedNow)
        T.expectEqual(parsedSame, .upToDate(latestVersion: "1.3.0", checkedAt: fixedNow))
        let parsedAhead = try ReleaseUpdater.parseLatestReleaseJSON(Data(newReleaseJSON.utf8), currentVersion: "1.4.0", checkedAt: fixedNow)
        T.expectEqual(parsedAhead, .upToDate(latestVersion: "1.3.0", checkedAt: fixedNow))

        // Draft and prerelease must be ignored
        let draftJSON = #"{"tag_name":"v2.0.0","draft":true,"prerelease":false,"html_url":"https://github.com/rorywang98-netizen/Pulsar/releases/tag/v2.0.0"}"#
        let parsedDraft = try ReleaseUpdater.parseLatestReleaseJSON(Data(draftJSON.utf8), currentVersion: "1.2.0", checkedAt: fixedNow)
        T.expectEqual(parsedDraft, .upToDate(latestVersion: nil, checkedAt: fixedNow), "draft release must be ignored")

        let preJSON = #"{"tag_name":"v2.0.0","draft":false,"prerelease":true,"html_url":"https://github.com/rorywang98-netizen/Pulsar/releases/tag/v2.0.0"}"#
        let parsedPre = try ReleaseUpdater.parseLatestReleaseJSON(Data(preJSON.utf8), currentVersion: "1.2.0", checkedAt: fixedNow)
        T.expectEqual(parsedPre, .upToDate(latestVersion: nil, checkedAt: fixedNow), "prerelease must be ignored")

        // Disallowed html_url must throw disallowedHost
        let badHTMLJSON = #"{"tag_name":"v2.0.0","draft":false,"prerelease":false,"html_url":"https://evil.example.com/release"}"#
        var threwDisallowedHTML = false
        do {
            _ = try ReleaseUpdater.parseLatestReleaseJSON(Data(badHTMLJSON.utf8), currentVersion: "1.2.0", checkedAt: fixedNow)
        } catch ReleaseUpdaterError.disallowedHost {
            threwDisallowedHTML = true
        }
        T.expectEqual(threwDisallowedHTML, true, "non-allowlisted html_url must throw disallowedHost")

        // 4. parseSHA256Text & streaming sha256Hex(ofFileAt:) & mismatch rejection
        let hexA = String(repeating: "a", count: 64)
        let hexB = String(repeating: "b", count: 64)
        T.expectEqual(
            ReleaseUpdater.parseSHA256Text("\(hexA.uppercased())  Pulsar-v1.3.0-macOS-arm64.dmg\n", expectedFileName: "Pulsar-v1.3.0-macOS-arm64.dmg"),
            hexA
        )
        T.expectEqual(
            ReleaseUpdater.parseSHA256Text("\(hexA) *./Pulsar-v1.3.0-macOS-arm64.dmg\n", expectedFileName: "Pulsar-v1.3.0-macOS-arm64.dmg"),
            hexA
        )
        T.expectEqual(
            ReleaseUpdater.parseSHA256Text("SHA256 (Pulsar-v1.3.0-macOS-arm64.dmg) = \(hexA)\n", expectedFileName: "Pulsar-v1.3.0-macOS-arm64.dmg"),
            hexA
        )
        T.expectEqual(
            ReleaseUpdater.parseSHA256Text("\(hexA)\n", expectedFileName: "Pulsar-v1.3.0-macOS-arm64.dmg"),
            hexA,
            "bare single hash must be accepted"
        )
        T.expectEqual(
            ReleaseUpdater.parseSHA256Text("\(hexA)  other.dmg\n\(hexB)  Pulsar-v1.3.0-macOS-arm64.dmg\n", expectedFileName: "Pulsar-v1.3.0-macOS-arm64.dmg"),
            hexB
        )
        T.expectEqual(
            ReleaseUpdater.parseSHA256Text("\(hexA)  other.dmg\n", expectedFileName: "Pulsar-v1.3.0-macOS-arm64.dmg"),
            nil,
            "named checksum file referencing only a different file must be rejected"
        )
        T.expectEqual(ReleaseUpdater.parseSHA256Text("not-a-valid-sha256\n", expectedFileName: "Pulsar.dmg"), nil)

        // Streaming sha256Hex on >128KB multi-chunk temp file
        let tmpDir = try makeTempDir(prefix: "pulsar-v120-updater")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let sampleFile = tmpDir.appendingPathComponent("sample.bin")
        var sampleBytes = Data(capacity: 150_000)
        for i in 0..<150_000 {
            sampleBytes.append(UInt8(i & 0xFF))
        }
        try sampleBytes.write(to: sampleFile)
        let expectedDigest = CryptoKit.SHA256.hash(data: sampleBytes).map { String(format: "%02x", $0) }.joined()
        let streamedDigest = try ReleaseUpdater.sha256Hex(ofFileAt: sampleFile)
        T.expectEqual(streamedDigest, expectedDigest, "streaming sha256Hex must match CryptoKit.SHA256")

        // Offline ETag + 304 Not Modified reuse & SHA-256 mismatch rejection via StubURLProtocol
        let mockSession = makeMockSession()
        let updater = ReleaseUpdater(
            session: mockSession,
            runningAppBundleURL: tmpDir.appendingPathComponent("Pulsar.app", isDirectory: true),
            downloadsDirectoryURL: tmpDir.appendingPathComponent("Downloads", isDirectory: true),
            relaunchTerminator: {},
            openManualInstaller: { _ in }
        )

        var apiCallCount = 0
        StubURLProtocol.reset { request, _ in
            let url = request.url!
            if url.host == "api.github.com" {
                apiCallCount += 1
                if apiCallCount == 1 {
                    let resp = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["ETag": "\"v130-etag\""]
                    )!
                    return (resp, Data(newReleaseJSON.utf8))
                } else {
                    T.expectEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"v130-etag\"")
                    let resp = HTTPURLResponse(url: url, statusCode: 304, httpVersion: "HTTP/1.1", headerFields: nil)!
                    return (resp, Data())
                }
            }
            if url.lastPathComponent.hasSuffix(".dmg") {
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (resp, Data("tampered-dmg-payload".utf8))
            }
            if url.lastPathComponent.hasSuffix(".sha256") {
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (resp, Data("\(hexA)  Pulsar-v1.3.0-macOS-arm64.dmg\n".utf8))
            }
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data())
        }

        let check1 = try await updater.checkLatestRelease(currentVersion: "1.2.0")
        let check2 = try await updater.checkLatestRelease(currentVersion: "1.2.0")
        guard case .updateAvailable(let info1) = check1,
              case .updateAvailable(let info2) = check2 else {
            T.expect(false, "both initial 200 and subsequent 304 ETag check must yield .updateAvailable")
            return
        }
        T.expectEqual(info1.version, "1.3.0")
        T.expectEqual(info2.version, "1.3.0")

        var threwChecksumMismatch = false
        do {
            _ = try await updater.downloadAndInstall(info1, onPhase: { _ in })
        } catch ReleaseUpdaterError.checksumMismatch {
            threwChecksumMismatch = true
        }
        T.expectEqual(threwChecksumMismatch, true, "downloadAndInstall must reject mismatched SHA-256 and abort")

        // 5. shellSingleQuote, canInstallInPlace & buildSwapScript (`sh -n` syntax validation)
        T.expectEqual(ReleaseUpdater.shellSingleQuote("/Applications/Pulsar.app"), "'/Applications/Pulsar.app'")
        T.expectEqual(ReleaseUpdater.shellSingleQuote("/tmp/O'Brien's App $(rm -rf /).app"), "'/tmp/O'\\''Brien'\\''s App $(rm -rf /).app'")

        let writableAppURL = tmpDir.appendingPathComponent("Pulsar.app", isDirectory: true)
        T.expectEqual(ReleaseUpdater.canInstallInPlace(currentAppURL: writableAppURL), true, "writable parent dir .app must allow in-place install")
        T.expectEqual(ReleaseUpdater.canInstallInPlace(currentAppURL: URL(fileURLWithPath: "/Volumes/Pulsar 1.2.0/Pulsar.app")), false, "/Volumes/ read-only mount must forbid in-place install")
        T.expectEqual(ReleaseUpdater.canInstallInPlace(currentAppURL: URL(fileURLWithPath: "/private/var/folders/xx/AppTranslocation/abc/d/Pulsar.app")), false, "AppTranslocation path must forbid in-place install")
        T.expectEqual(ReleaseUpdater.canInstallInPlace(currentAppURL: tmpDir.appendingPathComponent("RoryOrbit")), false, "non-.app binary must forbid in-place install")

        let swapScript = ReleaseUpdater.buildSwapScript(
            pid: 99_999,
            targetAppPath: "/Applications/Pulsar O'Brien.app",
            stagingAppPath: "/Applications/.Pulsar O'Brien.app.updating.123",
            backupAppPath: "/Applications/.Pulsar O'Brien.app.backup.123",
            tempDirPath: "/tmp/pulsar update 'dir'"
        )
        T.expect(swapScript.contains("#!/bin/sh"))
        T.expect(swapScript.contains("launchctl kickstart -k"))
        T.expect(swapScript.contains("/bin/mv \"$BACKUP\" \"$TARGET\""))

        let scriptURL = tmpDir.appendingPathComponent("swap-syntax-check.sh")
        try Data(swapScript.utf8).write(to: scriptURL)
        let shCheck = Process()
        shCheck.executableURL = URL(fileURLWithPath: "/bin/sh")
        shCheck.arguments = ["-n", scriptURL.path]
        let shErr = Pipe()
        shCheck.standardError = shErr
        try shCheck.run()
        shCheck.waitUntilExit()
        let shErrMsg = String(data: shErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        T.expectEqual(shCheck.terminationStatus, 0, "buildSwapScript must pass `/bin/sh -n` syntax validation (stderr: \(shErrMsg))")
    }
}

// MARK: - Test 17: v1.2.1 Regression Suite (AGY writer_id Rotation, Clean Bundle Builder, agy.*.old Matcher & Bridge Respawn Fence)

private final class BridgeRespawnProcessInspector: ProcessInspectorProtocol, @unchecked Sendable {
    private let lock = NSLock()
    var guiApps: [RunningGUIApp] = []
    var processes: [ClientProcessInfo] = []
    var installed: [URL] = []
    var argsByPid: [Int: [String]] = [:]

    var terminateRequests: [(pid: Int, bundleId: String?)] = []
    var signalsSent: [(signal: Int32, pid: Int)] = []
    var reopenedURLs: [URL] = []

    var onAgyACPSigTerm: ((Int) -> Void)?

    func runningApplications(bundleIDs: [String]) -> [RunningGUIApp] {
        lock.lock()
        defer { lock.unlock() }
        let set = Set(bundleIDs)
        return guiApps.filter { set.contains($0.bundleId) }
    }

    func allRunningProcesses() -> [ClientProcessInfo] {
        lock.lock()
        defer { lock.unlock() }
        return processes
    }

    func processArguments(pid: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return argsByPid[pid] ?? []
    }

    func installedAppURLs(bundleIDs: [String], extraPaths: [String]) -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return installed
    }

    func requestGracefulTerminate(pid: Int, bundleId: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        terminateRequests.append((pid, bundleId))
        guiApps.removeAll { $0.pid == pid }
        processes.removeAll { $0.id == pid }
        return true
    }

    func sendSignal(_ signal: Int32, to pid: Int) -> Bool {
        let callback: ((Int) -> Void)? = lock.withLock {
            signalsSent.append((signal, pid))
            if signal == SIGTERM || signal == SIGKILL {
                guiApps.removeAll { $0.pid == pid }
                processes.removeAll { $0.id == pid }
            }
            if signal == SIGTERM,
               let args = argsByPid[pid],
               args.contains(where: { $0.lowercased() == "acp" }) {
                return onAgyACPSigTerm
            }
            return nil
        }
        callback?(pid)
        return true
    }

    func spawnProcess(_ proc: ClientProcessInfo, arguments: [String]) {
        lock.lock()
        defer { lock.unlock() }
        processes.removeAll { $0.id == proc.id }
        processes.append(proc)
        argsByPid[proc.id] = arguments
    }

    func isProcessAlive(pid: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return guiApps.contains { $0.pid == pid } || processes.contains { $0.id == pid }
    }

    func openApplication(at url: URL) async throws {
        lock.withLock {
            reopenedURLs.append(url)
        }
    }

    func sleep(nanoseconds: UInt64) async {}
}

private func testV121RegressionSuite() async {
    await T.asyncSuite("V121.AntigravitySwitchFenceAndAgyMatcher") {
        // 1. generateWriterID(excluding:): 43-char URL-safe unpadded Base64 (32 random bytes), strictly != previous
        let allowedWriterChars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let previousWriter = "prev_writer_id_0123456789abcdefghijklmnopqr"
        var generatedSet = Set<String>()
        for i in 0..<16 {
            let excl = (i % 2 == 0) ? previousWriter : "  \(previousWriter)  "
            let wid = AntigravityProvider.generateWriterID(excluding: excl)
            T.expectEqual(wid.count, 43, "writer_id must be 43 chars (32 bytes URL-safe unpadded Base64)")
            T.expect(!wid.contains("+") && !wid.contains("/") && !wid.contains("="), "writer_id must never contain '+', '/' or '='")
            T.expect(wid.unicodeScalars.allSatisfy { allowedWriterChars.contains($0) }, "writer_id must contain only URL-safe Base64 characters")
            T.expectEqual(Formatters.base64URLDecode(wid)?.count, 32, "writer_id must decode to 32 raw bytes")
            T.expect(wid != previousWriter, "writer_id must strictly differ from previous")
            generatedSet.insert(wid)
        }
        T.expectEqual(generatedSet.count, 16, "16 consecutive generateWriterID calls must be unique")

        // 2. buildUpdatedBundleJSON: strips polluted outgoing fields while preserving auth_method & writing clean target fields
        let expiryDate = Date(timeIntervalSince1970: 1_800_123_456)
        let freshWriter = AntigravityProvider.generateWriterID(excluding: previousWriter)
        let newIDToken = makeUnsignedJWT(payload: [
            "sub": "sub-new-202",
            "email": "jwt-fallback@example.com",
            "name": "New Target User",
        ])
        let pollutedBase: [String: Any] = [
            "auth_method": "enterprise_sso",
            "writer_id": previousWriter,
            "id_token_email": "old@example.com",
            "id_token": makeUnsignedJWT(payload: ["sub": "sub-old-101", "email": "old@example.com"]),
            "legacy_polluted_account": "old-account-meta",
            "extra_stale_dict": ["email": "old@example.com"],
            "token": [
                "access_token": "at_old_stale",
                "refresh_token": "rt_old_stale",
                "token_type": "MAC",
                "stale_token_field": "must_be_removed",
            ],
        ]

        let cleanData = try AntigravityProvider.buildUpdatedBundleJSON(
            base: pollutedBase,
            accessToken: "at_clean_new",
            refreshToken: "rt_clean_new",
            expiry: expiryDate,
            expiresIn: 3600,
            idToken: newIDToken,
            targetEmail: "target@example.com",
            writerID: freshWriter
        )
        let cleanObj = try JSONSerialization.jsonObject(with: cleanData, options: []) as? [String: Any]
        T.expect(cleanObj != nil, "buildUpdatedBundleJSON must emit valid JSON dictionary")
        T.expectEqual(
            cleanObj?.keys.sorted(),
            ["auth_method", "id_token", "id_token_email", "token", "writer_id"],
            "root dictionary must contain ONLY canonical Antigravity fields and zero polluted keys"
        )
        T.expectEqual(cleanObj?["auth_method"] as? String, "enterprise_sso", "valid auth_method from base must be preserved")
        T.expectEqual(cleanObj?["writer_id"] as? String, freshWriter)
        T.expect((cleanObj?["writer_id"] as? String) != previousWriter, "writer_id must never inherit outgoing writer_id")
        T.expectEqual(cleanObj?["id_token_email"] as? String, "target@example.com", "explicit targetEmail must replace old@example.com")
        T.expectEqual(cleanObj?["id_token"] as? String, newIDToken)
        T.expect(cleanObj?["legacy_polluted_account"] == nil, "polluted root field must be stripped")
        T.expect(cleanObj?["extra_stale_dict"] == nil, "polluted nested dict must be stripped")

        let cleanTokenObj = cleanObj?["token"] as? [String: Any]
        T.expectEqual(
            cleanTokenObj?.keys.sorted(),
            ["access_token", "expires_in", "expiry", "refresh_token", "token_type"],
            "token dictionary must strip stale fields and write expires_in"
        )
        T.expectEqual(cleanTokenObj?["access_token"] as? String, "at_clean_new")
        T.expectEqual(cleanTokenObj?["refresh_token"] as? String, "rt_clean_new")
        T.expectEqual(cleanTokenObj?["token_type"] as? String, "Bearer")
        T.expectEqual(cleanTokenObj?["expires_in"] as? Int, 3600)
        T.expect(cleanTokenObj?["stale_token_field"] == nil)
        let parsedExpiry = (cleanTokenObj?["expiry"] as? String).flatMap { Formatters.parseRFC3339($0) }
        T.expect(parsedExpiry != nil && abs(parsedExpiry!.timeIntervalSince(expiryDate)) < 1.0, "expiry must be valid RFC3339")

        // Fallback id_token_email from idToken JWT email when targetEmail is nil/blank + default consumer auth_method + expiresIn floor 60s
        let fallbackData = try AntigravityProvider.buildUpdatedBundleJSON(
            base: ["id_token_email": "old@example.com", "writer_id": previousWriter],
            accessToken: "at_fb",
            refreshToken: "rt_fb",
            expiry: expiryDate,
            expiresIn: 12,
            idToken: newIDToken,
            targetEmail: "   ",
            writerID: freshWriter
        )
        let fallbackObj = try JSONSerialization.jsonObject(with: fallbackData, options: []) as? [String: Any]
        T.expectEqual(fallbackObj?["auth_method"] as? String, "consumer", "missing auth_method must default to consumer")
        T.expectEqual(fallbackObj?["id_token_email"] as? String, "jwt-fallback@example.com", "blank targetEmail must fall back to idToken JWT email")
        T.expectEqual((fallbackObj?["token"] as? [String: Any])?["expires_in"] as? Int, 60, "expiresIn < 60s must clamp to 60")

        // Validation errors on blank required inputs
        var missingATThrew = false
        do {
            _ = try AntigravityProvider.buildUpdatedBundleJSON(
                base: nil,
                accessToken: "  ",
                refreshToken: "rt",
                expiry: expiryDate,
                idToken: nil,
                targetEmail: nil,
                writerID: freshWriter
            )
        } catch {
            missingATThrew = true
        }
        T.expectEqual(missingATThrew, true, "blank accessToken must throw")

        // 3. isAgyExecutableName(_:)
        for validName in ["agy", "agy.1795227640703023000.old", "agy-desktop-helper", "AGY.999.old", "  agy.42.old  "] {
            T.expectEqual(AntigravityProvider.isAgyExecutableName(validName), true, "expected isAgyExecutableName(\(validName)) == true")
        }
        for rejectedName in ["agy-bridge", "agy.", "claude", "codex", "", "   ", "/usr/local/bin/agy", "agy_worker"] {
            T.expectEqual(AntigravityProvider.isAgyExecutableName(rejectedName), false, "expected isAgyExecutableName(\(rejectedName)) == false")
        }

        // 4. isAutoRespawnedAgyACPProcess(_:arguments:)
        let acpPerSession = ClientProcessInfo(
            id: 5101,
            name: "agy",
            executablePath: "/Users/example/.local/bin/agy",
            bundleId: nil,
            isInteractiveCLI: false
        )
        let acpHotUpdatedWorker = ClientProcessInfo(
            id: 5102,
            name: "agy.1795227640703023000.old",
            executablePath: "/Users/example/.local/bin/agy.1795227640703023000.old",
            bundleId: nil,
            isInteractiveCLI: false
        )
        let interactiveAgy = ClientProcessInfo(
            id: 5103,
            name: "agy.1795227640703023000.old",
            executablePath: "/Users/example/.local/bin/agy.1795227640703023000.old",
            bundleId: nil,
            isInteractiveCLI: true
        )
        let guiAntigravity = ClientProcessInfo(
            id: 5104,
            name: "Antigravity",
            executablePath: "/Applications/Antigravity.app/Contents/MacOS/Antigravity",
            bundleId: AntigravityProvider.stableBundleId,
            isInteractiveCLI: false
        )
        let agyBridgeProc = ClientProcessInfo(
            id: 5105,
            name: "agy-bridge",
            executablePath: "/opt/homebrew/bin/agy-bridge",
            bundleId: nil,
            isInteractiveCLI: false
        )

        T.expectEqual(
            AntigravityProvider.isAutoRespawnedAgyACPProcess(acpPerSession, arguments: ["agy", "acp", "--process-per-session"]),
            true,
            "non-interactive `agy acp --process-per-session` must match"
        )
        T.expectEqual(
            AntigravityProvider.isAutoRespawnedAgyACPProcess(acpHotUpdatedWorker, arguments: ["agy", "acp", "--worker"]),
            true,
            "non-interactive `agy.<ts>.old acp --worker` must match"
        )
        T.expectEqual(
            AntigravityProvider.isAutoRespawnedAgyACPProcess(interactiveAgy, arguments: ["agy", "acp", "--process-per-session"]),
            false,
            "interactive terminal `agy` (isInteractiveCLI == true) must be rejected"
        )
        T.expectEqual(
            AntigravityProvider.isAutoRespawnedAgyACPProcess(guiAntigravity, arguments: ["Antigravity", "acp"]),
            false,
            "GUI Antigravity (bundleId != nil) must be rejected"
        )
        T.expectEqual(
            AntigravityProvider.isAutoRespawnedAgyACPProcess(agyBridgeProc, arguments: ["agy-bridge", "serve"]),
            false,
            "`agy-bridge serve` must be rejected"
        )
        T.expectEqual(
            AntigravityProvider.isAutoRespawnedAgyACPProcess(agyBridgeProc, arguments: ["agy-bridge", "acp"]),
            false,
            "`agy-bridge` must be rejected even if arguments contain `acp`"
        )
        T.expectEqual(
            AntigravityProvider.isAutoRespawnedAgyACPProcess(acpPerSession, arguments: ["agy", "chat"]),
            false,
            "non-ACP `agy` subcommand must be rejected"
        )

        // 5. Full Mock `switchAccount` scenarios (interactive `agy.*.old` guard + `agy-bridge` respawning `agy acp` fence)
        let dir = try makeTempDir(prefix: "pulsar-v121-switch")
        defer { try? FileManager.default.removeItem(at: dir) }

        let stableApp = dir.appendingPathComponent("Antigravity.app", isDirectory: true)
        let insidersApp = dir.appendingPathComponent("Antigravity - Insiders.app", isDirectory: true)
        try writeSyntheticASAR(to: stableApp.appendingPathComponent("Contents/Resources/app.asar"), version: "2.33.0")
        let binDir = stableApp.appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try Data("GOCSPX-1234567890abcdefghijklmnopqr".utf8).write(to: binDir.appendingPathComponent("language_server"))

        let agyBinDir = dir.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: agyBinDir, withIntermediateDirectories: true)
        let agyCLIURL = agyBinDir.appendingPathComponent("agy")
        let agyOldPath = agyBinDir.appendingPathComponent("agy.1795227640703023000.old").path
        try Data("#!/bin/sh\n".utf8).write(to: agyCLIURL)

        let mirrorURL = dir.appendingPathComponent(".gemini/jetski-standalone-oauth-token")

        let backend = InMemoryKeychainBackend()
        let kc = KeychainStore(backend: backend)
        try kc.writeSecret(service: KeychainStore.roryOrbitAntigravityService, account: "sub-new-202", value: "rt_seed_202")

        let oldWriterID = "old_writer_id_1111111111111111111111111111111"
        let outgoingIDToken = makeUnsignedJWT(payload: [
            "sub": "sub-old-101",
            "email": "old@example.com",
            "name": "Outgoing User",
        ])
        let outgoingBundleObj: [String: Any] = [
            "auth_method": "consumer",
            "writer_id": oldWriterID,
            "id_token_email": "old@example.com",
            "id_token": outgoingIDToken,
            "polluted_legacy_key": "stale_from_old_account",
            "token": [
                "access_token": "at_old_101",
                "refresh_token": "rt_old_101",
                "token_type": "Bearer",
                "expiry": Formatters.formatRFC3339Local(Date().addingTimeInterval(3600)),
            ],
        ]
        let outgoingBundleData = try JSONSerialization.data(withJSONObject: outgoingBundleObj, options: [.sortedKeys])
        try kc.writeExternalGenericPassword(
            service: AntigravityProvider.liveKeychainService,
            account: AntigravityProvider.liveKeychainAccount,
            value: AntigravityProvider.encodeGoKeyringValue(outgoingBundleData)
        )
        try KeychainStore.writeAtomicFile(data: outgoingBundleData, to: mirrorURL, mode: 0o600)

        let targetIDToken = makeUnsignedJWT(payload: [
            "sub": "sub-new-202",
            "email": "new@example.com",
            "name": "Target User",
        ])
        StubURLProtocol.reset { req, bodyData in
            let urlStr = req.url?.absoluteString ?? ""
            let makeResp: (Int, Any) -> (HTTPURLResponse, Data) = { code, obj in
                let d = try! JSONSerialization.data(withJSONObject: obj)
                return (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, d)
            }
            if urlStr.contains("oauth2.googleapis.com/token") {
                let bodyStr = String(data: bodyData, encoding: .utf8) ?? ""
                if bodyStr.contains("roryorbit_client_secret_probe") {
                    return makeResp(400, ["error": "invalid_grant"])
                }
                return makeResp(200, [
                    "access_token": "at_new_202",
                    "refresh_token": "rt_new_202_rotated",
                    "expires_in": 3600,
                    "id_token": targetIDToken,
                ])
            }
            if urlStr.contains("googleapis.com/oauth2/v2/userinfo") {
                let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
                if auth.contains("at_new_202") {
                    return makeResp(200, [
                        "id": "sub-new-202",
                        "email": "new@example.com",
                        "name": "Target User",
                    ])
                }
                if auth.contains("at_old_101") {
                    return makeResp(200, [
                        "id": "sub-old-101",
                        "email": "old@example.com",
                        "name": "Outgoing User",
                    ])
                }
            }
            return makeResp(404, [:])
        }

        let paths = AntigravityProvider.Paths(
            stableAppURL: stableApp,
            insidersAppURL: insidersApp,
            agyCLIURL: agyCLIURL,
            mirrorTokenURL: mirrorURL
        )
        let inspector = BridgeRespawnProcessInspector()
        inspector.installed = [stableApp, insidersApp]
        let ctrl = ProcessController(inspector: inspector, selfPid: 9999)
        let provider = AntigravityProvider(
            keychain: kc,
            processController: ctrl,
            paths: paths,
            session: makeMockSession()
        )
        let targetAccount = AccountRecord(
            id: "sub-new-202",
            provider: .antigravity,
            email: "new@example.com",
            displayName: "Target User"
        )

        // 5a. Interactive terminal `agy.*.old` session + `allowForceQuit == false` -> MUST return `.needsForceQuitConfirmation`
        let bridgePID = 6100
        let interactiveOldAgyPID = 6200
        inspector.processes = [
            ClientProcessInfo(
                id: bridgePID,
                name: "agy-bridge",
                executablePath: "/opt/homebrew/bin/agy-bridge",
                bundleId: nil,
                isInteractiveCLI: false
            ),
            ClientProcessInfo(
                id: interactiveOldAgyPID,
                name: "agy.1795227640703023000.old",
                executablePath: agyOldPath,
                bundleId: nil,
                isInteractiveCLI: true
            ),
        ]
        inspector.argsByPid = [
            bridgePID: ["agy-bridge", "serve"],
            interactiveOldAgyPID: ["agy"],
        ]

        let detectedWithOldAgy = await provider.detectClientStatus()
        T.expectEqual(
            detectedWithOldAgy.runningProcesses.map(\.id),
            [interactiveOldAgyPID],
            "detectClientStatus must detect `agy.*.old` and exclude `agy-bridge`"
        )

        let blockedByInteractive = await provider.switchAccount(to: targetAccount, allowForceQuit: false)
        if case .needsForceQuitConfirmation(let surviving) = blockedByInteractive {
            T.expectEqual(surviving.map(\.id), [interactiveOldAgyPID], "interactive `agy.*.old` must require confirmation")
        } else {
            T.expect(false, "expected .needsForceQuitConfirmation for interactive `agy.*.old`, got \(blockedByInteractive)")
        }
        T.expectEqual(inspector.signalsSent.count, 0, "interactive guard must abort before sending any signal")
        let kcAfterBlockedRaw = try kc.readExternalGenericPassword(
            service: AntigravityProvider.liveKeychainService,
            account: AntigravityProvider.liveKeychainAccount
        )
        let kcAfterBlockedObj = kcAfterBlockedRaw
            .flatMap { AntigravityProvider.decodeGoKeyringValue($0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        T.expectEqual(kcAfterBlockedObj?["writer_id"] as? String, oldWriterID, "aborted switch must leave outgoing writer_id untouched")
        T.expectEqual(kcAfterBlockedObj?["id_token_email"] as? String, "old@example.com", "aborted switch must leave outgoing email untouched")

        // 5b. Full `switchAccount` with Stable + Insiders GUI & `agy-bridge` continuously respawning non-interactive `agy acp`
        let stableGUIPID = 7001
        let insidersGUIPID = 7002
        let langServerPID = 7003
        let initialACPPID = 7201
        var nextRespawnedACPPID = 7202
        var postWriteACPSignals: [Int] = []
        var credentialsAlreadyRotatedWhenPostWriteSignaled = false

        inspector.guiApps = [
            RunningGUIApp(
                pid: stableGUIPID,
                bundleId: AntigravityProvider.stableBundleId,
                localizedName: "Antigravity",
                bundleURL: stableApp,
                executablePath: stableApp.appendingPathComponent("Contents/MacOS/Antigravity").path
            ),
            RunningGUIApp(
                pid: insidersGUIPID,
                bundleId: AntigravityProvider.insidersBundleId,
                localizedName: "Antigravity - Insiders",
                bundleURL: insidersApp,
                executablePath: insidersApp.appendingPathComponent("Contents/MacOS/Antigravity").path
            ),
        ]
        inspector.processes = [
            ClientProcessInfo(
                id: stableGUIPID,
                name: "Antigravity",
                executablePath: stableApp.appendingPathComponent("Contents/MacOS/Antigravity").path,
                bundleId: AntigravityProvider.stableBundleId
            ),
            ClientProcessInfo(
                id: insidersGUIPID,
                name: "Antigravity - Insiders",
                executablePath: insidersApp.appendingPathComponent("Contents/MacOS/Antigravity").path,
                bundleId: AntigravityProvider.insidersBundleId
            ),
            ClientProcessInfo(
                id: langServerPID,
                name: "language_server",
                executablePath: binDir.appendingPathComponent("language_server").path
            ),
            ClientProcessInfo(
                id: bridgePID,
                name: "agy-bridge",
                executablePath: "/opt/homebrew/bin/agy-bridge",
                bundleId: nil,
                isInteractiveCLI: false
            ),
            ClientProcessInfo(
                id: initialACPPID,
                name: "agy.1795227640703023000.old",
                executablePath: agyOldPath,
                bundleId: nil,
                isInteractiveCLI: false
            ),
        ]
        inspector.argsByPid = [
            bridgePID: ["agy-bridge", "serve"],
            initialACPPID: ["agy", "acp", "--process-per-session"],
        ]

        inspector.onAgyACPSigTerm = { terminatedPID in
            let currentKC = (try? kc.readExternalGenericPassword(
                service: AntigravityProvider.liveKeychainService,
                account: AntigravityProvider.liveKeychainAccount
            ))
            .flatMap { AntigravityProvider.decodeGoKeyringValue($0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let currentMirror = (try? Data(contentsOf: mirrorURL))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }

            let kcWriter = currentKC?["writer_id"] as? String
            let mirrorWriter = currentMirror?["writer_id"] as? String
            let kcEmail = currentKC?["id_token_email"] as? String
            let mirrorEmail = currentMirror?["id_token_email"] as? String

            if kcWriter != nil && kcWriter != oldWriterID {
                postWriteACPSignals.append(terminatedPID)
                if kcWriter == mirrorWriter && kcEmail == "new@example.com" && mirrorEmail == "new@example.com" {
                    credentialsAlreadyRotatedWhenPostWriteSignaled = true
                }
            }
            // Simulate `agy-bridge` supervisor immediately respawning a fresh `agy acp` worker whenever one exits!
            let newPID = nextRespawnedACPPID
            nextRespawnedACPPID += 1
            inspector.spawnProcess(
                ClientProcessInfo(
                    id: newPID,
                    name: "agy",
                    executablePath: agyCLIURL.path,
                    bundleId: nil,
                    isInteractiveCLI: false
                ),
                arguments: ["agy", "acp", "--process-per-session"]
            )
        }

        let switchRes = await provider.switchAccount(to: targetAccount, allowForceQuit: false)
        T.expectEqual(
            switchRes,
            .switched(reopenedApps: ["Antigravity"]),
            "switchAccount must succeed despite respawned `agy acp` and reopen ONLY Stable Antigravity"
        )
        T.expectEqual(inspector.reopenedURLs, [stableApp.standardizedFileURL], "must reopen Stable app only")

        // Signal invariants: 0 SIGKILL, 0 signals/terminates to agy-bridge, and exactly 1 post-write SIGTERM to respawned agy acp
        T.expect(inspector.signalsSent.allSatisfy { $0.signal != SIGKILL }, "switchAccount must send ZERO SIGKILL signals")
        T.expect(!inspector.signalsSent.contains { $0.pid == bridgePID }, "switchAccount must NEVER send any signal to agy-bridge")
        T.expect(!inspector.terminateRequests.contains { $0.pid == bridgePID }, "switchAccount must NEVER terminate agy-bridge")
        T.expectEqual(postWriteACPSignals, [7202], "must send SIGTERM exactly once to respawned `agy acp` after writing credentials")
        T.expectEqual(
            credentialsAlreadyRotatedWhenPostWriteSignaled,
            true,
            "Keychain and mirror file must ALREADY hold rotated writer_id + new id_token_email when post-write SIGTERM fires"
        )

        // Verify live Keychain & mirror file contents and outgoing backup vaulting
        let finalKCRaw = try kc.readExternalGenericPassword(
            service: AntigravityProvider.liveKeychainService,
            account: AntigravityProvider.liveKeychainAccount
        )
        T.expect(finalKCRaw?.hasPrefix(AntigravityProvider.goKeyringBase64Prefix) == true)
        let finalKCData = finalKCRaw.flatMap { AntigravityProvider.decodeGoKeyringValue($0) }
        let finalMirrorData = try Data(contentsOf: mirrorURL)
        T.expectEqual(finalKCData, finalMirrorData, "Keychain JSON payload and mirror file must match byte-for-byte")

        let finalObj = try JSONSerialization.jsonObject(with: finalMirrorData, options: []) as? [String: Any]
        let finalWriterID = finalObj?["writer_id"] as? String ?? ""
        T.expectEqual(finalWriterID.count, 43)
        T.expect(finalWriterID != oldWriterID, "switched live writer_id must rotate away from outgoing writer_id")
        T.expectEqual(finalObj?["id_token_email"] as? String, "new@example.com")
        T.expectEqual(finalObj?["auth_method"] as? String, "consumer")
        T.expect(finalObj?["polluted_legacy_key"] == nil, "polluted outgoing key must be stripped on switch")
        let finalToken = finalObj?["token"] as? [String: Any]
        T.expectEqual(finalToken?["access_token"] as? String, "at_new_202")
        T.expectEqual(finalToken?["refresh_token"] as? String, "rt_new_202_rotated")
        T.expectEqual(finalToken?["expires_in"] as? Int, 3600)

        let mirrorPerms = (try FileManager.default.attributesOfItem(atPath: mirrorURL.path)[.posixPermissions] as? NSNumber)?.intValue
        T.expectEqual(mirrorPerms, 0o600, "mirror file mode must remain 0600")
        T.expectEqual(
            try kc.readSecret(service: KeychainStore.roryOrbitAntigravityService, account: "sub-old-101"),
            "rt_old_101",
            "outgoing live refresh_token must be vaulted before overwrite"
        )
        T.expectEqual(
            try kc.readSecret(service: KeychainStore.roryOrbitAntigravityService, account: "sub-new-202"),
            "rt_new_202_rotated",
            "rotated target refresh_token must be persisted to isolated Keychain"
        )
    }
}

// MARK: - Test 18: v1.2.2 Regression Suite (Dual 5h + Weekly Reset Footnote Across Antigravity / Codex / Kimi & 340pt/390pt NSHostingView Verification)

private func testV122RegressionSuite() async {
    await T.asyncSuite("V122.DualResetFootnoteAndNarrowLayout") {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset3h34m = now.addingTimeInterval(3 * 3600 + 34 * 60 + 20)
        let reset4h59m = now.addingTimeInterval(4 * 3600 + 59 * 60 + 20)
        let reset6d17h = now.addingTimeInterval(6 * 86_400 + 17 * 3600 + 10 * 60)
        let reset3d18h = now.addingTimeInterval(3 * 86_400 + 18 * 3600 + 5 * 60)
        let reset1h56m = now.addingTimeInterval(1 * 3600 + 56 * 60 + 15)
        let reset14d8h = now.addingTimeInterval(14 * 86_400 + 8 * 3600 + 5 * 60)

        // 1. Antigravity Account #1 (5h lower than weekly in Gemini, Claude 100%)
        let snowSnap = QuotaSnapshot(
            provider: .antigravity,
            accountId: "agy-snow",
            plan: PlanInfo(kind: .ultra, displayName: "Ultra"),
            windows: [
                QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: 0.89, usedPercent: 11, resetAt: reset3h34m, windowSeconds: 18_000, isPrimary: true),
                QuotaWindow(id: "gemini_weekly", label: "Gemini · 周", remainingFraction: 0.93, usedPercent: 7, resetAt: reset6d17h, windowSeconds: 604_800),
                QuotaWindow(id: "claude_gpt_5h", label: "Claude / GPT · 5小时", remainingFraction: 1.0, usedPercent: 0, resetAt: reset4h59m, windowSeconds: 18_000),
                QuotaWindow(id: "claude_gpt_weekly", label: "Claude / GPT · 周", remainingFraction: 1.0, usedPercent: 0, resetAt: reset6d17h, windowSeconds: 604_800),
            ],
            status: .ready(fetchedAt: now, stale: false),
            primaryRemainingPercent: 89
        )

        let snow390 = MenuBarView.buildFocusFooterSummary(
            for: snowSnap,
            visibleWindows: snowSnap.windows,
            preferredAntigravityPool: .autoLowest,
            strictPoolFilter: false,
            popoverWidth: 390,
            showResetRelative: true,
            now: now
        )
        T.expectEqual(
            snow390?.text,
            "Gemini · 5h 3小时34分 · 周 6天17小时后重置",
            "390pt regular width must display both 5h and weekly resets for Snow"
        )

        let snow340 = MenuBarView.buildFocusFooterSummary(
            for: snowSnap,
            visibleWindows: snowSnap.windows,
            preferredAntigravityPool: .autoLowest,
            strictPoolFilter: false,
            popoverWidth: 340,
            showResetRelative: true,
            now: now
        )
        T.expectEqual(
            snow340?.text,
            "Gemini · 5h 3h34m · 周 6d17h 后重置",
            "340pt narrow width must use compactResetCountdown for both 5h and weekly resets"
        )

        // 2. Antigravity Account #2 (weekly lower than 5h in Gemini: previously missed 5h reset!)
        let weeklyLowerSnap = QuotaSnapshot(
            provider: .antigravity,
            accountId: "agy-weekly-lower",
            plan: PlanInfo(kind: .pro, displayName: "Pro"),
            windows: [
                QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: 0.99, usedPercent: 1, resetAt: reset3h34m, windowSeconds: 18_000, isPrimary: true),
                QuotaWindow(id: "gemini_weekly", label: "Gemini · 周", remainingFraction: 0.75, usedPercent: 25, resetAt: reset6d17h, windowSeconds: 604_800),
                QuotaWindow(id: "claude_gpt_5h", label: "Claude / GPT · 5小时", remainingFraction: 1.0, usedPercent: 0, resetAt: reset4h59m, windowSeconds: 18_000),
                QuotaWindow(id: "claude_gpt_weekly", label: "Claude / GPT · 周", remainingFraction: 0.86, usedPercent: 14, resetAt: reset3d18h, windowSeconds: 604_800),
            ],
            status: .ready(fetchedAt: now, stale: false),
            primaryRemainingPercent: 99
        )

        let weeklyLower390 = MenuBarView.buildFocusFooterSummary(
            for: weeklyLowerSnap,
            visibleWindows: weeklyLowerSnap.windows,
            preferredAntigravityPool: .autoLowest,
            strictPoolFilter: false,
            popoverWidth: 390,
            showResetRelative: true,
            now: now
        )
        T.expectEqual(
            weeklyLower390?.text,
            "Gemini · 5h 3小时34分 · 周 6天17小时后重置",
            "when Gemini weekly is lowest, 5h reset must STILL be shown alongside weekly"
        )

        // 3. Auto-lowest pool vs explicit pool preference (Claude / GPT lowest at 2%, vs Gemini explicit filter)
        let claudeLowestSnap = QuotaSnapshot(
            provider: .antigravity,
            accountId: "agy-claude-low",
            plan: PlanInfo(kind: .pro, displayName: "Pro"),
            windows: [
                QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: 1.0, usedPercent: 0, resetAt: reset3h34m, windowSeconds: 18_000, isPrimary: true),
                QuotaWindow(id: "gemini_weekly", label: "Gemini · 周", remainingFraction: 0.987, usedPercent: 1.3, resetAt: reset6d17h, windowSeconds: 604_800),
                QuotaWindow(id: "claude_gpt_5h", label: "Claude / GPT · 5小时", remainingFraction: 1.0, usedPercent: 0, resetAt: reset4h59m, windowSeconds: 18_000),
                QuotaWindow(id: "claude_gpt_weekly", label: "Claude / GPT · 周", remainingFraction: 0.018, usedPercent: 98.2, resetAt: reset3d18h, windowSeconds: 604_800),
            ],
            status: .ready(fetchedAt: now, stale: false),
            primaryRemainingPercent: 100
        )

        let autoClaude390 = MenuBarView.buildFocusFooterSummary(
            for: claudeLowestSnap,
            visibleWindows: claudeLowestSnap.windows,
            preferredAntigravityPool: .autoLowest,
            strictPoolFilter: false,
            popoverWidth: 390,
            showResetRelative: true,
            now: now
        )
        T.expectEqual(
            autoClaude390?.text,
            "Claude / GPT · 5h 4小时59分 · 周 3天18小时后重置",
            "autoLowest must lock onto Claude / GPT pool and show both 5h and weekly resets"
        )

        let autoClaude340 = MenuBarView.buildFocusFooterSummary(
            for: claudeLowestSnap,
            visibleWindows: claudeLowestSnap.windows,
            preferredAntigravityPool: .autoLowest,
            strictPoolFilter: false,
            popoverWidth: 340,
            showResetRelative: true,
            now: now
        )
        T.expectEqual(
            autoClaude340?.text,
            "Claude / GPT · 5h 4h59m · 周 3d18h 后重置"
        )

        let explicitGemini390 = MenuBarView.buildFocusFooterSummary(
            for: claudeLowestSnap,
            visibleWindows: claudeLowestSnap.windows,
            preferredAntigravityPool: .gemini,
            strictPoolFilter: false,
            popoverWidth: 390,
            showResetRelative: true,
            now: now
        )
        T.expectEqual(
            explicitGemini390?.text,
            "Gemini · 5h 3小时34分 · 周 6天17小时后重置",
            "explicit Gemini pool selection must override auto-lowest Claude pool"
        )

        // 4. All-100% untouched account + single-window Argon pool + strict missing pool
        let fullAllPoolsSnap = QuotaSnapshot(
            provider: .antigravity,
            accountId: "agy-full",
            plan: PlanInfo(kind: .ultra, displayName: "Ultra"),
            windows: [
                QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: 1.0, usedPercent: 0, resetAt: reset4h59m, windowSeconds: 18_000, isPrimary: true),
                QuotaWindow(id: "gemini_weekly", label: "Gemini · 周", remainingFraction: 1.0, usedPercent: 0, resetAt: reset6d17h, windowSeconds: 604_800),
                QuotaWindow(id: "claude_gpt_5h", label: "Claude / GPT · 5小时", remainingFraction: 1.0, usedPercent: 0, resetAt: reset4h59m.addingTimeInterval(-2), windowSeconds: 18_000),
                QuotaWindow(id: "claude_gpt_weekly", label: "Claude / GPT · 周", remainingFraction: 1.0, usedPercent: 0, resetAt: reset6d17h, windowSeconds: 604_800),
                QuotaWindow(id: "argon_weekly", label: "Argon · 周", remainingFraction: 1.0, usedPercent: 0, resetAt: reset6d17h, windowSeconds: 604_800),
            ],
            status: .ready(fetchedAt: now, stale: false),
            primaryRemainingPercent: 100
        )

        let fullDefault390 = MenuBarView.buildFocusFooterSummary(
            for: fullAllPoolsSnap,
            visibleWindows: fullAllPoolsSnap.windows,
            preferredAntigravityPool: .autoLowest,
            strictPoolFilter: false,
            popoverWidth: 390,
            showResetRelative: true,
            now: now
        )
        T.expectEqual(
            fullDefault390?.text,
            "Gemini · 5h 4小时59分 · 周 6天17小时后重置",
            "untouched 100% account must deterministically focus primary Gemini pool and show 5h + weekly"
        )

        let argonOnly390 = MenuBarView.buildFocusFooterSummary(
            for: fullAllPoolsSnap,
            visibleWindows: fullAllPoolsSnap.windows,
            preferredAntigravityPool: .argon,
            strictPoolFilter: false,
            popoverWidth: 390,
            showResetRelative: true,
            now: now
        )
        T.expectEqual(
            argonOnly390?.text,
            "Argon 周 · 6天17小时后重置",
            "single-window Argon pool must display 'Argon 周 · 6天17小时后重置'"
        )
        T.expect(
            argonOnly390?.tooltip.contains("Gemini") == true
                && argonOnly390?.tooltip.contains("Claude / GPT") == true
                && argonOnly390?.tooltip.contains("Argon") == true,
            "tooltip must preserve complete reset details for all windows"
        )

        let strictMissingArgon = MenuBarView.buildFocusFooterSummary(
            for: snowSnap,
            visibleWindows: [],
            preferredAntigravityPool: .argon,
            strictPoolFilter: true,
            popoverWidth: 390,
            showResetRelative: true,
            now: now
        )
        T.expect(strictMissingArgon == nil, "strictPoolFilter with missing Argon pool must return nil")

        // 5. Non-Antigravity multi-window services: Codex (5h + weekly + Credits) & Kimi (5h + monthly)
        let codexSnap = QuotaSnapshot(
            provider: .codex,
            accountId: "codex-1",
            plan: PlanInfo(kind: .pro, displayName: "Pro"),
            windows: [
                QuotaWindow(id: "5h", label: "5小时", remainingFraction: 1.0, usedPercent: 0, resetAt: reset3h34m, windowSeconds: 18_000, isPrimary: true),
                QuotaWindow(id: "weekly", label: "本周", remainingFraction: 0.74, usedPercent: 26, resetAt: reset6d17h, windowSeconds: 604_800),
            ],
            balance: BalanceInfo(currency: "USD", totalBalance: 12.5, detail: "Credits"),
            status: .ready(fetchedAt: now, stale: false),
            primaryRemainingPercent: 100
        )

        let codex390 = MenuBarView.buildFocusFooterSummary(
            for: codexSnap,
            visibleWindows: codexSnap.windows,
            popoverWidth: 390,
            showResetRelative: true,
            now: now
        )
        T.expectEqual(
            codex390?.text,
            "5h 3小时34分 · 周 6天17小时后重置 · Credits $12.50",
            "Codex must omit pool prefix and show both 5h + weekly resets plus Credits"
        )

        let codex340 = MenuBarView.buildFocusFooterSummary(
            for: codexSnap,
            visibleWindows: codexSnap.windows,
            popoverWidth: 340,
            showResetRelative: true,
            now: now
        )
        T.expectEqual(
            codex340?.text,
            "5h 3h34m · 周 6d17h 后重置 · Credits $12.50"
        )

        let kimiSnap = QuotaSnapshot(
            provider: .kimi,
            accountId: "kimi:api",
            windows: [
                QuotaWindow(id: "kimi-5h", label: "5 小时", remainingFraction: 1.0, usedPercent: 0, resetAt: reset1h56m, windowSeconds: 18_000, isPrimary: true),
                QuotaWindow(id: "kimi-monthly", label: "月度总额度", remainingFraction: 0.20, usedPercent: 80, resetAt: reset14d8h, windowSeconds: 2_592_000),
            ],
            status: .ready(fetchedAt: now, stale: false),
            primaryRemainingPercent: 100
        )
        T.expectEqual(
            MenuBarView.buildFocusFooterSummary(for: kimiSnap, visibleWindows: kimiSnap.windows, popoverWidth: 390, showResetRelative: true, now: now)?.text,
            "5h 1小时56分 · 月 14天8小时后重置"
        )
        T.expectEqual(
            MenuBarView.buildFocusFooterSummary(for: kimiSnap, visibleWindows: kimiSnap.windows, popoverWidth: 340, showResetRelative: true, now: now)?.text,
            "5h 1h56m · 月 14d8h 后重置"
        )

        // Absolute reset mode (`showResetRelative == false`)
        let absSummary = MenuBarView.buildFocusFooterSummary(
            for: snowSnap,
            visibleWindows: snowSnap.windows,
            preferredAntigravityPool: .gemini,
            popoverWidth: 390,
            showResetRelative: false,
            now: now
        )
        T.expect(
            absSummary?.text.hasPrefix("Gemini · 5h ") == true
                && absSummary?.text.contains(" · 周 ") == true
                && absSummary?.text.hasSuffix(" 重置") == true,
            "absolute reset mode must format both 5h and weekly timestamps cleanly"
        )

        // 6. Single-line pixel-width verification at 340pt (<370 compact) and 370pt/390pt (regular) using 10.5pt monospacedDigit system font
        let footnoteFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        func measuredWidth(_ text: String) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: footnoteFont]).width)
        }

        // At 340pt popoverWidth: inner card content width = 340 - 2*9 (scrollInset) - 2*8.5 (cardHPadding) = 305pt
        let maxInnerWidthAt340: CGFloat = 305.0
        for sample340 in [
            snow340?.text ?? "",
            autoClaude340?.text ?? "",
            codex340?.text ?? "",
            "Claude / GPT · 5h 4h59m · 周 6d23h 后重置",
        ] {
            let w = measuredWidth(sample340)
            T.expect(w > 0 && w < maxInnerWidthAt340, "340pt footnote '\(sample340)' width (\(w)pt) must fit < \(maxInnerWidthAt340)pt without truncation")
        }

        // At 370pt popoverWidth: inner card content width = 370 - 2*12 (scrollInset) - 2*11 (cardHPadding) = 324pt
        let maxInnerWidthAt370: CGFloat = 324.0
        for sample370 in [
            snow390?.text ?? "",
            autoClaude390?.text ?? "",
            codex390?.text ?? "",
            "Claude / GPT · 5h 4小时59分 · 周 6天23小时后重置",
        ] {
            let w = measuredWidth(sample370)
            T.expect(w > 0 && w < maxInnerWidthAt370, "370pt+ footnote '\(sample370)' width (\(w)pt) must fit < \(maxInnerWidthAt370)pt without truncation")
        }
    }
}

// MARK: - Test 19: v1.2.3 Regression Suite (Unlinked ProcArgs2 Fallback, Daemon Hub Local RPC, Desktop Truth & Drift Detection, No-Restart Repair)

private func makeSyntheticProcArgs2Data(
    argc: Int32,
    execPath: String,
    nulPaddingCount: Int = 3,
    arguments: [String]
) -> Data {
    var data = Data()
    var mutableArgc = argc
    withUnsafeBytes(of: &mutableArgc) { data.append(contentsOf: $0) }
    data.append(contentsOf: execPath.utf8)
    data.append(contentsOf: [UInt8](repeating: 0, count: max(1, nulPaddingCount)))
    for arg in arguments {
        data.append(contentsOf: arg.utf8)
        data.append(0)
    }
    // Append a realistic env entry after argv to verify parser stops cleanly at argc.
    data.append(contentsOf: "HOME=/Users/example".utf8)
    data.append(0)
    return data
}

private func testV123RegressionSuite() async {
    // 19.1 ProcessControl: KERN_PROCARGS2 parser (unlinked agy.<ts>.old + empty execPath fallback to argv[0])
    T.suite("V123.ProcArgs2UnlinkedBinaryFallback") {
        let unlinkedPath = "/Users/example/.local/bin/agy.1795227640703023000.old"
        let normalBuf = makeSyntheticProcArgs2Data(
            argc: 2,
            execPath: unlinkedPath,
            nulPaddingCount: 4,
            arguments: ["agy", "daemon"]
        )
        let parsedNormal = LiveProcessInspector.parseProcArgs2Buffer(normalBuf)
        T.expectEqual(parsedNormal.execPath, unlinkedPath, "parseProcArgs2Buffer must preserve unlinked execPath")
        T.expectEqual(parsedNormal.arguments, ["agy", "daemon"], "parseProcArgs2Buffer must extract exact argc arguments")

        // Verify unaligned Data slice (startIndex == 1) parses cleanly without alignment crash.
        var padded = Data([0xAA])
        padded.append(normalBuf)
        let unalignedSlice = padded[1...]
        let parsedSlice = LiveProcessInspector.parseProcArgs2Buffer(unalignedSlice)
        T.expectEqual(parsedSlice.execPath, unlinkedPath, "unaligned Data slice must parse identically")
        T.expectEqual(parsedSlice.arguments, ["agy", "daemon"])

        // Empty execPath in KERN_PROCARGS2 -> caller falls back to arguments.first (`argv[0]`).
        let emptyExecBuf = makeSyntheticProcArgs2Data(
            argc: 3,
            execPath: "",
            nulPaddingCount: 4,
            arguments: [unlinkedPath, "acp", "--process-per-session"]
        )
        let parsedEmptyExec = LiveProcessInspector.parseProcArgs2Buffer(emptyExecBuf)
        T.expectEqual(parsedEmptyExec.execPath, "", "empty execPath must parse as empty string")
        T.expectEqual(parsedEmptyExec.arguments, [unlinkedPath, "acp", "--process-per-session"])
        let fallbackExec = parsedEmptyExec.execPath.isEmpty ? (parsedEmptyExec.arguments.first ?? "") : parsedEmptyExec.execPath
        T.expectEqual(fallbackExec, unlinkedPath, "empty execPath must fall back to argv[0]")
        T.expectEqual(
            AntigravityProvider.isAgyExecutableName(URL(fileURLWithPath: fallbackExec).lastPathComponent),
            true,
            "fallback argv[0] basename must match isAgyExecutableName"
        )

        // Malformed / truncated / out-of-range argc buffers must fail closed.
        T.expectEqual(LiveProcessInspector.parseProcArgs2Buffer(Data()).execPath, "")
        T.expectEqual(LiveProcessInspector.parseProcArgs2Buffer(Data([1, 0, 0])).arguments.isEmpty, true)
        let negArgc = makeSyntheticProcArgs2Data(argc: -1, execPath: unlinkedPath, arguments: ["agy"])
        T.expectEqual(LiveProcessInspector.parseProcArgs2Buffer(negArgc).execPath, "")
        let hugeArgc = makeSyntheticProcArgs2Data(argc: 9999, execPath: unlinkedPath, arguments: ["agy"])
        T.expectEqual(LiveProcessInspector.parseProcArgs2Buffer(hugeArgc).execPath, "")
    }

    // 19.2 DaemonHubDescriptor parser (camelCase, snake_case, invalid rejection, port validation)
    T.suite("V123.DaemonHubDescriptorParser") {
        let camelJSON = Data("""
        {"pid": 5432, "httpsPort": 51443, "httpPort": 51080, "csrfToken": "csrf_camel_tok", "lsVersion": "2.34.1"}
        """.utf8)
        let camelDesc = AntigravityProvider.parseDaemonHubDescriptor(from: camelJSON)
        T.expectEqual(
            camelDesc,
            AntigravityProvider.DaemonHubDescriptor(
                pid: 5432,
                httpsPort: 51443,
                httpPort: 51080,
                csrfToken: "csrf_camel_tok",
                lsVersion: "2.34.1"
            ),
            "camelCase hub_*.json must parse all fields"
        )

        let snakeJSON = Data("""
        {"pid": 6789, "https_port": 0, "http_port": 52080, "csrf_token": "csrf_snake_tok", "ls_version": "2.34.2"}
        """.utf8)
        let snakeDesc = AntigravityProvider.parseDaemonHubDescriptor(from: snakeJSON)
        T.expectEqual(
            snakeDesc,
            AntigravityProvider.DaemonHubDescriptor(
                pid: 6789,
                httpsPort: nil,
                httpPort: 52080,
                csrfToken: "csrf_snake_tok",
                lsVersion: "2.34.2"
            ),
            "snake_case hub_*.json with https_port=0 must keep valid http_port"
        )

        // Invalid descriptors must return nil.
        let invalidCases: [(String, String)] = [
            ("pid <= 1", #"{"pid": 1, "httpsPort": 51443, "csrfToken": "tok"}"#),
            ("empty csrfToken", #"{"pid": 5432, "httpsPort": 51443, "csrfToken": "   "}"#),
            ("missing ports", #"{"pid": 5432, "csrfToken": "tok"}"#),
            ("out-of-range ports", #"{"pid": 5432, "httpsPort": 70000, "httpPort": -5, "csrfToken": "tok"}"#),
            ("boolean port", #"{"pid": 5432, "httpsPort": true, "csrfToken": "tok"}"#),
            ("corrupt JSON", #"not-json"#),
        ]
        for (label, raw) in invalidCases {
            T.expect(
                AntigravityProvider.parseDaemonHubDescriptor(from: Data(raw.utf8)) == nil,
                "invalid hub descriptor (\(label)) must return nil"
            )
        }
    }

    // 19.3 Local RPC `hub_*.json` discovery (ignores dead/reused PIDs, https->http port order, returns `本地 RPC` quota)
    await T.asyncSuite("V123.DaemonHubLocalRPCDiscoveryAndPortOrder") {
        let dir = try makeTempDir(prefix: "pulsar-v123-hub-rpc")
        defer { try? FileManager.default.removeItem(at: dir) }

        let stableApp = dir.appendingPathComponent("Antigravity.app", isDirectory: true)
        try writeSyntheticASAR(to: stableApp.appendingPathComponent("Contents/Resources/app.asar"), version: "2.34.0")
        let daemonDir = dir.appendingPathComponent(".gemini/antigravity/daemon", isDirectory: true)
        try FileManager.default.createDirectory(at: daemonDir, withIntermediateDirectories: true)

        // 1. Dead PID hub file (must be ignored)
        let deadHub = daemonDir.appendingPathComponent("hub_dead.json")
        try Data(#"{"pid": 8801, "httpsPort": 59901, "httpPort": 59902, "csrfToken": "csrf_dead"}"#.utf8).write(to: deadHub)

        // 2. Alive PID reused by unrelated process (must be ignored)
        let reusedHub = daemonDir.appendingPathComponent("hub_reused.json")
        try Data(#"{"pid": 8802, "httpsPort": 59903, "csrfToken": "csrf_reused"}"#.utf8).write(to: reusedHub)

        // 3. Live Antigravity language_server PID with BOTH httpsPort (fails) and httpPort (succeeds) to test ordered targets
        let liveHub = daemonDir.appendingPathComponent("hub_live.json")
        try Data(#"{"pid": 8803, "httpsPort": 54321, "httpPort": 54322, "csrfToken": "csrf_live_234", "lsVersion": "2.34.0"}"#.utf8).write(to: liveHub)

        let inspector = MockProcessInspector()
        inspector.processes = [
            ClientProcessInfo(id: 8802, name: "python3", executablePath: "/usr/bin/python3"),
            ClientProcessInfo(
                id: 8803,
                name: "language_server_macos_arm",
                executablePath: stableApp.appendingPathComponent("Contents/Resources/bin/language_server_macos_arm").path
            ),
        ]

        let futureReset = Formatters.formatRFC3339UTC(Date().addingTimeInterval(4 * 3600))
        let weeklyReset = Formatters.formatRFC3339UTC(Date().addingTimeInterval(5 * 86_400))
        StubURLProtocol.reset { req, _ in
            let urlStr = req.url?.absoluteString ?? ""
            let csrf = req.value(forHTTPHeaderField: "X-Codeium-Csrf-Token") ?? ""
            let resp: (Int, Any) -> (HTTPURLResponse, Data) = { code, obj in
                let d = try! JSONSerialization.data(withJSONObject: obj)
                return (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, d)
            }
            // Simulate HTTPS port refusing / failing so provider MUST fall back to HTTP port in order!
            if urlStr.hasPrefix("https://127.0.0.1:54321/") {
                throw URLError(.cannotConnectToHost)
            }
            if urlStr.hasPrefix("http://127.0.0.1:54322/"), csrf == "csrf_live_234" {
                if urlStr.hasSuffix("/GetUserStatus") {
                    return resp(200, [
                        "userStatus": [
                            "email": "snow@example.com",
                            "name": "Snow",
                            "userTier": ["id": "g1-ultra-tier", "name": "Google AI Ultra"],
                        ],
                    ])
                }
                if urlStr.hasSuffix("/RetrieveUserQuotaSummary") {
                    return resp(200, [
                        "response": [
                            "groups": [
                                [
                                    "displayName": "Gemini",
                                    "buckets": [
                                        ["window": "5h", "remainingFraction": 0.88, "resetTime": futureReset],
                                        ["window": "weekly", "remainingFraction": 0.94, "resetTime": weeklyReset],
                                    ],
                                ],
                            ],
                        ],
                    ])
                }
            }
            return resp(404, [:])
        }

        let paths = AntigravityProvider.Paths(
            stableAppURL: stableApp,
            insidersAppURL: dir.appendingPathComponent("Insiders.app"),
            agyCLIURL: dir.appendingPathComponent("agy"),
            mirrorTokenURL: dir.appendingPathComponent("mirror"),
            daemonDirectories: [daemonDir]
        )
        let provider = AntigravityProvider(
            keychain: KeychainStore(backend: InMemoryKeychainBackend()),
            processController: ProcessController(inspector: inspector, selfPid: 9999),
            paths: paths,
            session: makeMockSession(),
            localRPCSession: makeMockSession()
        )
        let snowAcct = AccountRecord(id: "sub-snow", provider: .antigravity, email: "snow@example.com", displayName: "Snow")
        let snap = await provider.fetchQuota(for: snowAcct, isActiveLive: true)

        T.expect(snap.status.isReady, "hub_*.json local RPC must return ready quota")
        T.expectEqual(snap.sourceLabel, "本地 RPC", "hub_*.json discovery must report 本地 RPC source")
        T.expectEqual(snap.plan?.kind, .ultra)
        T.expectEqual(snap.primaryRemainingPercent, 88)

        let reqURLs = StubURLProtocol.snapshotRequests().compactMap { $0.request.url?.absoluteString }
        T.expect(!reqURLs.contains { $0.contains("59901") || $0.contains("59902") }, "dead PID hub file must NEVER be probed")
        T.expect(!reqURLs.contains { $0.contains("59903") }, "PID reused by non-language_server must NEVER be probed")
        let httpsIdx = reqURLs.firstIndex { $0.hasPrefix("https://127.0.0.1:54321/") }
        let httpIdx = reqURLs.firstIndex { $0.hasPrefix("http://127.0.0.1:54322/") }
        T.expect(httpsIdx != nil && httpIdx != nil && httpsIdx! < httpIdx!, "httpsPort MUST be tried before httpPort")
    }

    // 19.4 syncLiveAccount drift detection, offline vaulted refresh_token SHA-256 matching & desktop truth precedence
    await T.asyncSuite("V123.SyncLiveAccountDriftAndDesktopTruth") {
        let dir = try makeTempDir(prefix: "pulsar-v123-drift")
        defer { try? FileManager.default.removeItem(at: dir) }

        let stableApp = dir.appendingPathComponent("Antigravity.app", isDirectory: true)
        try writeSyntheticASAR(to: stableApp.appendingPathComponent("Contents/Resources/app.asar"), version: "2.34.0")
        let daemonDir = dir.appendingPathComponent(".gemini/antigravity/daemon", isDirectory: true)
        try FileManager.default.createDirectory(at: daemonDir, withIntermediateDirectories: true)
        let mirrorURL = dir.appendingPathComponent(".gemini/jetski-standalone-oauth-token")

        let lsPID = 8901
        let staleAgyPID = 668
        let bridgePID = 8902
        let acpPID = 8903
        try Data(#"{"pid": 8901, "httpsPort": 54443, "csrfToken": "csrf_drift_test"}"#.utf8)
            .write(to: daemonDir.appendingPathComponent("hub_8901.json"))

        let inspector = MockProcessInspector()
        inspector.processes = [
            ClientProcessInfo(
                id: lsPID,
                name: "language_server_macos_arm",
                executablePath: stableApp.appendingPathComponent("Contents/Resources/bin/language_server_macos_arm").path
            ),
            ClientProcessInfo(
                id: staleAgyPID,
                name: "agy.1795227640703023000.old",
                executablePath: "/Users/example/.local/bin/agy.1795227640703023000.old",
                bundleId: nil,
                isInteractiveCLI: false
            ),
            ClientProcessInfo(
                id: bridgePID,
                name: "agy-bridge",
                executablePath: "/opt/homebrew/bin/agy-bridge",
                bundleId: nil,
                isInteractiveCLI: false
            ),
            ClientProcessInfo(
                id: acpPID,
                name: "agy",
                executablePath: "/Users/example/.local/bin/agy",
                bundleId: nil,
                isInteractiveCLI: false
            ),
        ]
        inspector.argsByPid = [
            staleAgyPID: ["agy"],
            bridgePID: ["agy-bridge", "serve"],
            acpPID: ["agy", "acp", "--process-per-session"],
        ]

        let backend = InMemoryKeychainBackend()
        let kc = KeychainStore(backend: backend)
        try kc.writeSecret(service: KeychainStore.roryOrbitAntigravityService, account: "sub-snow", value: "rt_snow_vault")
        try kc.writeSecret(service: KeychainStore.roryOrbitAntigravityService, account: "sub-rory", value: "rt_rory_vault")

        let writeLiveBundle: ([String: Any], [String: Any]?) throws -> Void = { kcObj, mirrorObj in
            let kcData = try JSONSerialization.data(withJSONObject: kcObj, options: [.sortedKeys])
            try kc.writeExternalGenericPassword(
                service: AntigravityProvider.liveKeychainService,
                account: AntigravityProvider.liveKeychainAccount,
                value: AntigravityProvider.encodeGoKeyringValue(kcData)
            )
            if let mirrorObj {
                let mData = try JSONSerialization.data(withJSONObject: mirrorObj, options: [.sortedKeys])
                try KeychainStore.writeAtomicFile(data: mData, to: mirrorURL, mode: 0o600)
            } else {
                try? FileManager.default.removeItem(at: mirrorURL)
            }
        }

        let futureExpiry = Formatters.formatRFC3339Local(Date().addingTimeInterval(3600))
        let pastExpiry = Formatters.formatRFC3339Local(Date().addingTimeInterval(-300))
        let futureReset = Formatters.formatRFC3339UTC(Date().addingTimeInterval(4 * 3600))
        StubURLProtocol.reset { req, _ in
            let urlStr = req.url?.absoluteString ?? ""
            let resp: (Int, Any) -> (HTTPURLResponse, Data) = { code, obj in
                let d = try! JSONSerialization.data(withJSONObject: obj)
                return (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, d)
            }
            if urlStr.hasPrefix("https://127.0.0.1:54443/") {
                if urlStr.hasSuffix("/GetUserStatus") {
                    return resp(200, [
                        "userStatus": [
                            "email": "snow@example.com",
                            "name": "Snow",
                            "userTier": ["id": "g1-ultra-tier", "name": "Google AI Ultra"],
                        ],
                    ])
                }
                if urlStr.hasSuffix("/RetrieveUserQuotaSummary") {
                    return resp(200, [
                        "response": [
                            "groups": [
                                [
                                    "displayName": "Gemini",
                                    "buckets": [
                                        ["window": "5h", "remainingFraction": 0.91, "resetTime": futureReset],
                                    ],
                                ],
                            ],
                        ],
                    ])
                }
            }
            return resp(404, [:])
        }

        let paths = AntigravityProvider.Paths(
            stableAppURL: stableApp,
            insidersAppURL: dir.appendingPathComponent("Insiders.app"),
            agyCLIURL: dir.appendingPathComponent("agy"),
            mirrorTokenURL: mirrorURL,
            daemonDirectories: [daemonDir]
        )
        let provider = AntigravityProvider(
            keychain: kc,
            processController: ProcessController(inspector: inspector, selfPid: 9999),
            paths: paths,
            session: makeMockSession(),
            localRPCSession: makeMockSession()
        )

        var reg = RegistryData(accounts: [
            AccountRecord(
                id: "sub-snow",
                provider: .antigravity,
                email: "snow@example.com",
                displayName: "Snow",
                isActiveLive: false,
                avatarURL: "https://lh3.googleusercontent.com/snow.png"
            ),
            AccountRecord(
                id: "sub-rory",
                provider: .antigravity,
                email: "rorywangdev@example.com",
                displayName: "rorywangdev",
                isActiveLive: true,
                avatarURL: "https://lh3.googleusercontent.com/rory.png"
            ),
        ])

        // 4a. Desktop Snow vs Keychain rorywangdev (no id_token in Keychain -> offline SHA-256 match, ZERO userinfo calls)
        let roryBundle: [String: Any] = [
            "auth_method": "consumer",
            "writer_id": "writer_rory_1111111111111111111111111111111",
            "id_token_email": "rorywangdev@example.com",
            "token": [
                "access_token": "at_rory_1",
                "refresh_token": "rt_rory_vault",
                "expiry": futureExpiry,
            ],
        ]
        try writeLiveBundle(roryBundle, roryBundle)

        let liveId = await provider.syncLiveAccount(registry: &reg)
        T.expectEqual(liveId, "sub-snow", "desktop truth must mark Snow active even when Keychain holds rorywangdev")
        T.expectEqual(reg.accounts(for: .antigravity).first { $0.id == "sub-snow" }?.isActiveLive, true)
        T.expectEqual(reg.accounts(for: .antigravity).first { $0.id == "sub-rory" }?.isActiveLive, false)

        let userInfoCalls = StubURLProtocol.snapshotRequests().filter {
            $0.request.url?.absoluteString.contains("oauth2/v2/userinfo") == true
        }
        T.expectEqual(userInfoCalls.count, 0, "offline vaulted refresh_token SHA-256 match must skip Google userinfo when avatar exists")

        let drift4a = provider.currentCredentialDrift
        T.expectEqual(drift4a?.reason, .desktopKeychainMismatch, "must flag .desktopKeychainMismatch")
        T.expectEqual(drift4a?.desktopAccountId, "sub-snow")
        T.expectEqual(drift4a?.desktopEmail, "snow@example.com")
        T.expectEqual(drift4a?.keychainEmail, "rorywangdev@example.com")
        T.expectEqual(drift4a?.mirrorEmail, "rorywangdev@example.com")
        T.expectEqual(drift4a?.staleBackgroundAgyPids, [668], "must detect PID 668 and exclude agy-bridge & agy acp")

        // Active desktop Snow immediately gets 本地 RPC quota even before repair.
        let snowAcct = reg.accounts(for: .antigravity).first { $0.id == "sub-snow" }!
        let snowSnap = await provider.fetchQuota(for: snowAcct, isActiveLive: true)
        T.expectEqual(snowSnap.sourceLabel, "本地 RPC")
        T.expectEqual(snowSnap.primaryRemainingPercent, 91)

        // 4b. Keychain matches Snow's refresh_token, but Keychain id_token_email is stale -> .staleMetadata
        let staleMetaKC: [String: Any] = [
            "auth_method": "consumer",
            "writer_id": "writer_snow_1111111111111111111111111111111",
            "id_token_email": "rorywangdev@example.com",
            "token": [
                "access_token": "at_snow_1",
                "refresh_token": "rt_snow_vault",
                "expiry": futureExpiry,
            ],
        ]
        try writeLiveBundle(staleMetaKC, nil)
        _ = await provider.syncLiveAccount(registry: &reg)
        T.expectEqual(provider.currentCredentialDrift?.reason, .staleMetadata, "stale Keychain id_token_email must flag .staleMetadata")

        // 4c. Keychain is clean Snow, mirror file has stale id_token_email -> .mirrorFileMismatch
        let cleanSnowKC: [String: Any] = [
            "auth_method": "consumer",
            "writer_id": "writer_snow_2222222222222222222222222222222",
            "id_token_email": "snow@example.com",
            "token": [
                "access_token": "at_snow_hour2",
                "refresh_token": "rt_snow_vault",
                "expiry": futureExpiry,
            ],
        ]
        let staleMirrorEmail: [String: Any] = [
            "auth_method": "consumer",
            "writer_id": "writer_snow_1111111111111111111111111111111",
            "id_token_email": "rorywangdev@example.com",
            "token": [
                "access_token": "at_snow_hour1",
                "refresh_token": "rt_snow_vault",
                "expiry": pastExpiry,
            ],
        ]
        try writeLiveBundle(cleanSnowKC, staleMirrorEmail)
        _ = await provider.syncLiveAccount(registry: &reg)
        T.expectEqual(provider.currentCredentialDrift?.reason, .mirrorFileMismatch, "stale mirror id_token_email must flag .mirrorFileMismatch")
        T.expectEqual(provider.currentCredentialDrift?.mirrorEmail, "rorywangdev@example.com")

        // 4c-ii. Mirror file has stale refresh_token (even when id_token_email is absent) -> .mirrorFileMismatch
        let staleMirrorRT: [String: Any] = [
            "auth_method": "consumer",
            "writer_id": "writer_snow_1111111111111111111111111111111",
            "token": [
                "access_token": "at_rory_old",
                "refresh_token": "rt_rory_vault",
                "expiry": pastExpiry,
            ],
        ]
        try writeLiveBundle(cleanSnowKC, staleMirrorRT)
        _ = await provider.syncLiveAccount(registry: &reg)
        T.expectEqual(provider.currentCredentialDrift?.reason, .mirrorFileMismatch, "mismatched mirror refresh_token must flag .mirrorFileMismatch")
        T.expectEqual(provider.currentCredentialDrift?.mirrorEmail, "rorywangdev@example.com")

        // 4d. Normal hourly Keychain refresh (different access_token / expiry / writer_id, same refresh_token & matching id_token_email) -> nil drift!
        let normalHourlyMirror: [String: Any] = [
            "auth_method": "consumer",
            "writer_id": "writer_snow_1111111111111111111111111111111",
            "id_token_email": "snow@example.com",
            "token": [
                "access_token": "at_snow_hour1_old",
                "refresh_token": "rt_snow_vault",
                "expiry": pastExpiry,
            ],
        ]
        try writeLiveBundle(cleanSnowKC, normalHourlyMirror)
        _ = await provider.syncLiveAccount(registry: &reg)
        T.expectEqual(provider.currentCredentialDrift, nil, "normal hourly Keychain refresh must produce ZERO false-positive drift")
    }

    // 19.5 repairLiveCredentials(for:), AppStore.repairAntigravityCredentialDrift(), rollback on write error & MenuBarView drift banner widths
    await T.asyncSuite("V123.RepairLiveCredentialsAndRollback") {
        let dir = try makeTempDir(prefix: "pulsar-v123-repair")
        defer { try? FileManager.default.removeItem(at: dir) }

        let stableApp = dir.appendingPathComponent("Antigravity.app", isDirectory: true)
        try writeSyntheticASAR(to: stableApp.appendingPathComponent("Contents/Resources/app.asar"), version: "2.34.0")
        let binDir = stableApp.appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try Data("GOCSPX-1234567890abcdefghijklmnopqr".utf8).write(to: binDir.appendingPathComponent("language_server"))

        let daemonDir = dir.appendingPathComponent(".gemini/antigravity/daemon", isDirectory: true)
        try FileManager.default.createDirectory(at: daemonDir, withIntermediateDirectories: true)
        try Data(#"{"pid": 9002, "httpsPort": 54555, "csrfToken": "csrf_repair_test"}"#.utf8)
            .write(to: daemonDir.appendingPathComponent("hub_9002.json"))

        let mirrorURL = dir.appendingPathComponent(".gemini/jetski-standalone-oauth-token")
        let backend = InMemoryKeychainBackend()
        let kc = KeychainStore(backend: backend)
        try kc.writeSecret(service: KeychainStore.roryOrbitAntigravityService, account: "sub-snow", value: "rt_snow_seed")
        try kc.writeSecret(service: KeychainStore.roryOrbitAntigravityService, account: "sub-rory", value: "rt_rory_seed")

        let oldWriterID = "old_drift_writer_0123456789abcdefghijklmnop"
        let driftedObj: [String: Any] = [
            "auth_method": "consumer",
            "writer_id": oldWriterID,
            "id_token_email": "rorywangdev@example.com",
            "polluted_field": "must_strip",
            "token": [
                "access_token": "at_rory_stale",
                "refresh_token": "rt_rory_seed",
                "expiry": Formatters.formatRFC3339Local(Date().addingTimeInterval(3600)),
            ],
        ]
        let driftedData = try JSONSerialization.data(withJSONObject: driftedObj, options: [.sortedKeys])
        let driftedKCRaw = AntigravityProvider.encodeGoKeyringValue(driftedData)
        try kc.writeExternalGenericPassword(
            service: AntigravityProvider.liveKeychainService,
            account: AntigravityProvider.liveKeychainAccount,
            value: driftedKCRaw
        )
        try KeychainStore.writeAtomicFile(data: driftedData, to: mirrorURL, mode: 0o600)

        let snowIDToken = makeUnsignedJWT(payload: [
            "sub": "sub-snow",
            "email": "snow@example.com",
            "name": "Snow",
        ])
        let futureReset = Formatters.formatRFC3339UTC(Date().addingTimeInterval(4 * 3600))
        StubURLProtocol.reset { req, bodyData in
            let urlStr = req.url?.absoluteString ?? ""
            let resp: (Int, Any) -> (HTTPURLResponse, Data) = { code, obj in
                let d = try! JSONSerialization.data(withJSONObject: obj)
                return (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, d)
            }
            if urlStr.contains("oauth2.googleapis.com/token") {
                let bodyStr = String(data: bodyData, encoding: .utf8) ?? ""
                if bodyStr.contains("roryorbit_client_secret_probe") {
                    return resp(400, ["error": "invalid_grant"])
                }
                return resp(200, [
                    "access_token": "at_snow_repaired",
                    "refresh_token": "rt_snow_repaired",
                    "expires_in": 3600,
                    "id_token": snowIDToken,
                ])
            }
            if urlStr.contains("googleapis.com/oauth2/v2/userinfo") {
                return resp(200, [
                    "id": "sub-snow",
                    "email": "snow@example.com",
                    "name": "Snow",
                ])
            }
            if urlStr.hasPrefix("https://127.0.0.1:54555/") {
                if urlStr.hasSuffix("/GetUserStatus") {
                    return resp(200, [
                        "userStatus": [
                            "email": "snow@example.com",
                            "name": "Snow",
                            "userTier": ["id": "g1-ultra-tier", "name": "Google AI Ultra"],
                        ],
                    ])
                }
                if urlStr.hasSuffix("/RetrieveUserQuotaSummary") {
                    return resp(200, [
                        "response": [
                            "groups": [
                                [
                                    "displayName": "Gemini",
                                    "buckets": [
                                        ["window": "5h", "remainingFraction": 0.95, "resetTime": futureReset],
                                    ],
                                ],
                            ],
                        ],
                    ])
                }
            }
            return resp(404, [:])
        }

        let guiPID = 9001
        let lsPID = 9002
        let bridgePID = 9003
        let acpPID = 9004
        let nonAcpAgyPID = 668
        let inspector = MockProcessInspector()
        inspector.guiApps = [
            RunningGUIApp(
                pid: guiPID,
                bundleId: AntigravityProvider.stableBundleId,
                localizedName: "Antigravity",
                bundleURL: stableApp,
                executablePath: stableApp.appendingPathComponent("Contents/MacOS/Antigravity").path
            ),
        ]
        inspector.processes = [
            ClientProcessInfo(
                id: guiPID,
                name: "Antigravity",
                executablePath: stableApp.appendingPathComponent("Contents/MacOS/Antigravity").path,
                bundleId: AntigravityProvider.stableBundleId
            ),
            ClientProcessInfo(
                id: lsPID,
                name: "language_server",
                executablePath: binDir.appendingPathComponent("language_server").path
            ),
            ClientProcessInfo(
                id: bridgePID,
                name: "agy-bridge",
                executablePath: "/opt/homebrew/bin/agy-bridge"
            ),
            ClientProcessInfo(
                id: acpPID,
                name: "agy",
                executablePath: "/Users/example/.local/bin/agy",
                bundleId: nil,
                isInteractiveCLI: false
            ),
            ClientProcessInfo(
                id: nonAcpAgyPID,
                name: "agy.1795227640703023000.old",
                executablePath: "/Users/example/.local/bin/agy.1795227640703023000.old",
                bundleId: nil,
                isInteractiveCLI: false
            ),
        ]
        inspector.argsByPid = [
            bridgePID: ["agy-bridge", "serve"],
            acpPID: ["agy", "acp", "--process-per-session"],
            nonAcpAgyPID: ["agy"],
        ]

        // 5a. Rollback test: mirror path is a directory -> write fails -> Keychain MUST roll back cleanly with ZERO signals!
        let blockingDirMirror = dir.appendingPathComponent("unwritable-mirror-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: blockingDirMirror, withIntermediateDirectories: true)
        let rollbackPaths = AntigravityProvider.Paths(
            stableAppURL: stableApp,
            insidersAppURL: dir.appendingPathComponent("Insiders.app"),
            agyCLIURL: dir.appendingPathComponent("agy"),
            mirrorTokenURL: blockingDirMirror,
            daemonDirectories: [daemonDir]
        )
        let rollbackProvider = AntigravityProvider(
            keychain: kc,
            processController: ProcessController(inspector: inspector, selfPid: 9999),
            paths: rollbackPaths,
            session: makeMockSession(),
            localRPCSession: makeMockSession()
        )
        let snowRecord = AccountRecord(
            id: "sub-snow",
            provider: .antigravity,
            email: "snow@example.com",
            displayName: "Snow",
            avatarURL: "https://lh3.googleusercontent.com/snow.png"
        )
        let rollbackRes = await rollbackProvider.repairLiveCredentials(for: snowRecord)
        if case .failed = rollbackRes {
            T.expect(true)
        } else {
            T.expect(false, "repairLiveCredentials must fail when mirror write fails, got \(rollbackRes)")
        }
        let kcAfterRollback = try kc.readExternalGenericPassword(
            service: AntigravityProvider.liveKeychainService,
            account: AntigravityProvider.liveKeychainAccount
        )
        T.expectEqual(kcAfterRollback, driftedKCRaw, "failed repair MUST roll back Keychain to exact previous payload")
        T.expectEqual(inspector.signalsSent.count, 0, "failed repair must send ZERO signals")
        T.expectEqual(inspector.terminateRequests.count, 0, "failed repair must NEVER touch Antigravity.app")

        // Reset vaulted seed for clean success test (repair rotated vault before write failed)
        try kc.writeSecret(service: KeychainStore.roryOrbitAntigravityService, account: "sub-snow", value: "rt_snow_seed")

        // 5b. Full AppStore + AntigravityProvider drift detection -> one-click repair -> clean clear!
        let repairPaths = AntigravityProvider.Paths(
            stableAppURL: stableApp,
            insidersAppURL: dir.appendingPathComponent("Insiders.app"),
            agyCLIURL: dir.appendingPathComponent("agy"),
            mirrorTokenURL: mirrorURL,
            daemonDirectories: [daemonDir]
        )
        let repairProvider = AntigravityProvider(
            keychain: kc,
            processController: ProcessController(inspector: inspector, selfPid: 9999),
            paths: repairPaths,
            session: makeMockSession(),
            localRPCSession: makeMockSession()
        )
        let regURL = dir.appendingPathComponent("registry.json")
        let initialReg = RegistryData(accounts: [
            snowRecord,
            AccountRecord(
                id: "sub-rory",
                provider: .antigravity,
                email: "rorywangdev@example.com",
                displayName: "rorywangdev",
                isActiveLive: true,
                avatarURL: "https://lh3.googleusercontent.com/rory.png"
            ),
        ])
        try initialReg.save(to: regURL)

        let store = await MainActor.run {
            AppStore(
                keychain: kc,
                processController: ProcessController(inspector: inspector, selfPid: 9999),
                adapters: [.antigravity: repairProvider],
                registryURL: regURL,
                startScheduler: false,
                persistAccountPoolExport: false
            )
        }

        await store.refreshProvider(.antigravity, persistExport: false)
        let detectedDrift = await MainActor.run { store.antigravityCredentialDrift }
        T.expectEqual(detectedDrift?.reason, .desktopKeychainMismatch, "AppStore must propagate antigravityCredentialDrift")
        T.expectEqual(detectedDrift?.desktopAccountId, "sub-snow")
        T.expectEqual(detectedDrift?.staleBackgroundAgyPids, [668])

        await store.repairAntigravityCredentialDrift()

        let driftAfterRepair = await MainActor.run { store.antigravityCredentialDrift }
        let bannerAfterRepair = await MainActor.run { store.operationBanner ?? "" }
        let bannerIsError = await MainActor.run { store.operationBannerIsError }
        T.expectEqual(driftAfterRepair, nil, "successful repair must clear AppStore.antigravityCredentialDrift")
        T.expectEqual(repairProvider.currentCredentialDrift, nil, "successful repair must clear provider.currentCredentialDrift")
        T.expectEqual(bannerIsError, false, "repair banner must be non-error")
        T.expect(bannerAfterRepair.contains("无感修复"), "repair banner must confirm silent no-restart repair")

        // Verify Keychain + mirror contents, rotated 43-char writer_id, 0600 mode, and strict zero-restart signal invariants.
        let repairedKCRaw = try kc.readExternalGenericPassword(
            service: AntigravityProvider.liveKeychainService,
            account: AntigravityProvider.liveKeychainAccount
        )
        let repairedKCData = repairedKCRaw.flatMap { AntigravityProvider.decodeGoKeyringValue($0) }
        let repairedMirrorData = try Data(contentsOf: mirrorURL)
        T.expectEqual(repairedKCData, repairedMirrorData, "repaired Keychain and mirror file must match byte-for-byte")

        let repairedObj = try JSONSerialization.jsonObject(with: repairedMirrorData, options: []) as? [String: Any]
        let newWriterID = repairedObj?["writer_id"] as? String ?? ""
        T.expectEqual(newWriterID.count, 43, "repaired writer_id must be 43 chars")
        T.expect(newWriterID != oldWriterID, "repaired writer_id must rotate away from old writer_id")
        T.expectEqual(repairedObj?["id_token_email"] as? String, "snow@example.com")
        T.expect(repairedObj?["polluted_field"] == nil, "polluted field must be stripped during repair")
        let repairedToken = repairedObj?["token"] as? [String: Any]
        T.expectEqual(repairedToken?["access_token"] as? String, "at_snow_repaired")
        T.expectEqual(repairedToken?["refresh_token"] as? String, "rt_snow_repaired")
        let repairedPerms = (try FileManager.default.attributesOfItem(atPath: mirrorURL.path)[.posixPermissions] as? NSNumber)?.intValue
        T.expectEqual(repairedPerms, 0o600, "repaired mirror file mode must remain 0600")

        // Signal invariants: ONLY SIGTERM to `agy acp` (9004); NEVER touch Antigravity.app, language_server, agy-bridge, or PID 668; ZERO SIGKILL; ZERO relaunches!
        T.expectEqual(inspector.terminateRequests.count, 0, "repairLiveCredentials must NEVER terminate Antigravity.app")
        T.expectEqual(inspector.reopenedURLs.count, 0, "repairLiveCredentials must NEVER restart/reopen apps")
        T.expect(inspector.signalsSent.allSatisfy { $0.signal == SIGTERM }, "repairLiveCredentials must send ZERO SIGKILL signals")
        T.expectEqual(inspector.signalsSent.map(\.pid), [acpPID], "repairLiveCredentials must gently SIGTERM ONLY auto-respawned agy acp")

        // Verify drift banner Row 1 fits cleanly inside 340pt narrow popover inner width (340 - 2*9 - 2*9 = 304pt) without clipping.
        let narrowTitleW = ceil(("钥匙串与桌面账号不一致" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width)
        let narrowBtnTextW = ceil(("一键修复钥匙串" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]).width)
        let estimatedRow1W = 14.0 + 6.0 + narrowTitleW + 4.0 + (narrowBtnTextW + 30.0)
        T.expect(estimatedRow1W < 304.0, "340pt drift banner header row (\(estimatedRow1W)pt) must fit comfortably inside 304pt inner width")
    }

    // 19.6 Defensive Edge Cases: Unregistered Desktop Account Guard & Fail-Closed Remote Token Match
    await T.asyncSuite("V123.UnregisteredDesktopAndFailClosedRemoteTokenGuard") {
        let dir = try makeTempDir(prefix: "pulsar-v123-edge")
        defer { try? FileManager.default.removeItem(at: dir) }

        let stableApp = dir.appendingPathComponent("Antigravity.app", isDirectory: true)
        try writeSyntheticASAR(to: stableApp.appendingPathComponent("Contents/Resources/app.asar"), version: "2.34.0")
        let binDir = stableApp.appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try Data("GOCSPX-1234567890abcdefghijklmnopqr".utf8).write(to: binDir.appendingPathComponent("language_server"))

        let daemonDir = dir.appendingPathComponent(".gemini/antigravity/daemon", isDirectory: true)
        try FileManager.default.createDirectory(at: daemonDir, withIntermediateDirectories: true)
        try Data(#"{"pid": 9102, "httpsPort": 54666, "csrfToken": "csrf_edge_test"}"#.utf8)
            .write(to: daemonDir.appendingPathComponent("hub_9102.json"))

        let mirrorURL = dir.appendingPathComponent(".gemini/jetski-standalone-oauth-token")
        let backend = InMemoryKeychainBackend()
        let kc = KeychainStore(backend: backend)
        try kc.writeSecret(service: KeychainStore.roryOrbitAntigravityService, account: "sub-rory", value: "rt_rory_vault")
        try kc.writeSecret(service: KeychainStore.roryOrbitAntigravityService, account: "sub-snow", value: "rt_snow_vault")

        let futureExpiry = Formatters.formatRFC3339Local(Date().addingTimeInterval(3600))
        let roryKCObj: [String: Any] = [
            "auth_method": "consumer",
            "writer_id": "writer_rory_edge_0123456789abcdefghijklmnop",
            "id_token_email": "rorywangdev@example.com",
            "token": [
                "access_token": "at_rory_live",
                "refresh_token": "rt_rory_vault",
                "expiry": futureExpiry,
            ],
        ]
        let roryKCData = try JSONSerialization.data(withJSONObject: roryKCObj, options: [.sortedKeys])
        let roryKCRaw = AntigravityProvider.encodeGoKeyringValue(roryKCData)
        try kc.writeExternalGenericPassword(
            service: AntigravityProvider.liveKeychainService,
            account: AntigravityProvider.liveKeychainAccount,
            value: roryKCRaw
        )
        try KeychainStore.writeAtomicFile(data: roryKCData, to: mirrorURL, mode: 0o600)

        let inspector = MockProcessInspector()
        inspector.processes = [
            ClientProcessInfo(
                id: 9102,
                name: "language_server",
                executablePath: binDir.appendingPathComponent("language_server").path
            ),
        ]

        // Part (a): Unregistered desktop account (`unregistered@example.com`) vs registered Keychain (`rorywangdev`)
        StubURLProtocol.reset { req, _ in
            let urlStr = req.url?.absoluteString ?? ""
            let resp: (Int, Any) -> (HTTPURLResponse, Data) = { code, obj in
                let d = try! JSONSerialization.data(withJSONObject: obj)
                return (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, d)
            }
            if urlStr.hasPrefix("https://127.0.0.1:54666/") && urlStr.hasSuffix("/GetUserStatus") {
                return resp(200, [
                    "userStatus": [
                        "email": "unregistered@example.com",
                        "name": "Unregistered User",
                    ],
                ])
            }
            return resp(404, [:])
        }

        let paths = AntigravityProvider.Paths(
            stableAppURL: stableApp,
            insidersAppURL: dir.appendingPathComponent("Insiders.app"),
            agyCLIURL: dir.appendingPathComponent("agy"),
            mirrorTokenURL: mirrorURL,
            daemonDirectories: [daemonDir]
        )
        let provider = AntigravityProvider(
            keychain: kc,
            processController: ProcessController(inspector: inspector, selfPid: 9999),
            paths: paths,
            session: makeMockSession(),
            localRPCSession: makeMockSession()
        )

        var reg = RegistryData(accounts: [
            AccountRecord(
                id: "sub-rory",
                provider: .antigravity,
                email: "rorywangdev@example.com",
                displayName: "rorywangdev",
                isActiveLive: true,
                avatarURL: "https://lh3.googleusercontent.com/rory.png"
            ),
        ])

        let syncedId = await provider.syncLiveAccount(registry: &reg)
        T.expectEqual(syncedId, nil, "unregistered desktop account must NOT mark another Keychain account active")
        T.expectEqual(reg.accounts(for: .antigravity).first { $0.id == "sub-rory" }?.isActiveLive, false, "rorywangdev must have isActiveLive == false when desktop is unregistered@example.com")
        T.expectEqual(provider.currentCredentialDrift?.reason, .desktopKeychainMismatch)
        T.expectEqual(provider.currentCredentialDrift?.desktopAccountId, nil, "unregistered desktop drift must set desktopAccountId == nil")
        T.expectEqual(provider.currentCredentialDrift?.desktopEmail, "unregistered@example.com")

        // Verify AppStore.repairAntigravityCredentialDrift() refuses to overwrite Keychain with rorywangdev!
        let regURL = dir.appendingPathComponent("registry-edge.json")
        try reg.save(to: regURL)
        let store = await MainActor.run {
            AppStore(
                keychain: kc,
                processController: ProcessController(inspector: inspector, selfPid: 9999),
                adapters: [.antigravity: provider],
                registryURL: regURL,
                startScheduler: false,
                persistAccountPoolExport: false
            )
        }
        await store.refreshProvider(.antigravity, persistExport: false)
        let storeDrift = await MainActor.run { store.antigravityCredentialDrift }
        T.expectEqual(storeDrift?.desktopAccountId, nil)
        T.expectEqual(storeDrift?.desktopEmail, "unregistered@example.com")

        let tokenCallsBeforeRepair = StubURLProtocol.snapshotRequests().filter {
            $0.request.url?.absoluteString.contains("oauth2.googleapis.com/token") == true
        }.count
        await store.repairAntigravityCredentialDrift()

        let errBanner = await MainActor.run { store.operationBanner ?? "" }
        let errFlag = await MainActor.run { store.operationBannerIsError }
        T.expectEqual(errFlag, true, "repairing unregistered desktop account must surface an error banner")
        T.expect(errBanner.contains("请先添加或导入该账号"), "error banner must instruct user to add/import account, got: \(errBanner)")
        T.expect(errBanner.contains("unregistered@example.com"), "error banner must name the unregistered desktop email")
        let kcAfterRefusedRepair = try kc.readExternalGenericPassword(
            service: AntigravityProvider.liveKeychainService,
            account: AntigravityProvider.liveKeychainAccount
        )
        T.expectEqual(kcAfterRefusedRepair, roryKCRaw, "refused repair must NEVER modify Keychain")
        let tokenCallsAfterRepair = StubURLProtocol.snapshotRequests().filter {
            $0.request.url?.absoluteString.contains("oauth2.googleapis.com/token") == true
        }.count
        T.expectEqual(tokenCallsAfterRepair - tokenCallsBeforeRepair, 0, "refused repair must not hit OAuth token endpoint")

        // Part (b): Standalone fetchQuota (before syncLiveAccount, currentCredentialDrift == nil) must NEVER reuse unverified or RT-mismatched live Keychain access_token!
        let futureReset = Formatters.formatRFC3339UTC(Date().addingTimeInterval(4 * 3600))
        let standalonePaths = AntigravityProvider.Paths(
            stableAppURL: stableApp,
            insidersAppURL: dir.appendingPathComponent("Insiders.app"),
            agyCLIURL: dir.appendingPathComponent("agy"),
            mirrorTokenURL: dir.appendingPathComponent("nonexistent-mirror"),
            daemonDirectories: [] // Force Tier 2 Cloud Code path directly
        )
        let snowAcct = AccountRecord(
            id: "sub-snow",
            provider: .antigravity,
            email: "snow@example.com",
            displayName: "Snow"
        )

        // (b-i) Bare live Keychain bundle with NO id_token, NO id_token_email, NO refresh_token (fail-closed!)
        let bareBundleData = try JSONSerialization.data(withJSONObject: [
            "auth_method": "consumer",
            "token": [
                "access_token": "at_unverified_wrong_account",
                "expiry": futureExpiry,
            ],
        ])
        try kc.writeExternalGenericPassword(
            service: AntigravityProvider.liveKeychainService,
            account: AntigravityProvider.liveKeychainAccount,
            value: AntigravityProvider.encodeGoKeyringValue(bareBundleData)
        )

        StubURLProtocol.reset { req, bodyData in
            let urlStr = req.url?.absoluteString ?? ""
            let resp: (Int, Any) -> (HTTPURLResponse, Data) = { code, obj in
                let d = try! JSONSerialization.data(withJSONObject: obj)
                return (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, d)
            }
            if urlStr.contains("oauth2.googleapis.com/token") {
                let bodyStr = String(data: bodyData, encoding: .utf8) ?? ""
                if bodyStr.contains("roryorbit_client_secret_probe") {
                    return resp(400, ["error": "invalid_grant"])
                }
                return resp(200, ["access_token": "at_minted_clean_snow", "expires_in": 3600])
            }
            if urlStr.contains("daily-cloudcode-pa.googleapis.com") {
                return resp(200, [
                    "groups": [
                        [
                            "displayName": "Gemini",
                            "buckets": [
                                ["window": "5h", "remainingFraction": 0.87, "resetTime": futureReset],
                            ],
                        ],
                    ],
                ])
            }
            return resp(404, [:])
        }

        let freshProvider1 = AntigravityProvider(
            keychain: kc,
            processController: ProcessController(inspector: MockProcessInspector(), selfPid: 9999),
            paths: standalonePaths,
            session: makeMockSession(),
            localRPCSession: makeMockSession()
        )
        T.expectEqual(freshProvider1.currentCredentialDrift, nil, "precondition: syncLiveAccount not yet called")
        let snapBare = await freshProvider1.fetchQuota(for: snowAcct, isActiveLive: true)
        T.expect(snapBare.status.isReady, "standalone fetchQuota must succeed by minting from vaulted RT")
        let bareCloudAuth = StubURLProtocol.snapshotRequests()
            .first { $0.request.url?.absoluteString.contains("daily-cloudcode-pa") == true }?
            .request.value(forHTTPHeaderField: "Authorization")
        T.expectEqual(bareCloudAuth, "Bearer at_minted_clean_snow", "fail-closed guard must NEVER reuse unverified live access_token")

        // (b-ii) Poisoned mixed bundle: id_token claims `sub-snow`, BUT refresh_token is `rt_rory_vault` (!= vaulted `rt_snow_vault`)
        let mixedSnowIDToken = makeUnsignedJWT(payload: [
            "sub": "sub-snow",
            "email": "snow@example.com",
        ])
        let mixedBundleData = try JSONSerialization.data(withJSONObject: [
            "auth_method": "consumer",
            "id_token": mixedSnowIDToken,
            "id_token_email": "snow@example.com",
            "token": [
                "access_token": "at_poisoned_rory_token",
                "refresh_token": "rt_rory_vault",
                "expiry": futureExpiry,
            ],
        ])
        try kc.writeExternalGenericPassword(
            service: AntigravityProvider.liveKeychainService,
            account: AntigravityProvider.liveKeychainAccount,
            value: AntigravityProvider.encodeGoKeyringValue(mixedBundleData)
        )

        StubURLProtocol.reset { req, bodyData in
            let urlStr = req.url?.absoluteString ?? ""
            let resp: (Int, Any) -> (HTTPURLResponse, Data) = { code, obj in
                let d = try! JSONSerialization.data(withJSONObject: obj)
                return (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, d)
            }
            if urlStr.contains("oauth2.googleapis.com/token") {
                let bodyStr = String(data: bodyData, encoding: .utf8) ?? ""
                if bodyStr.contains("roryorbit_client_secret_probe") {
                    return resp(400, ["error": "invalid_grant"])
                }
                return resp(200, ["access_token": "at_minted_clean_snow_2", "expires_in": 3600])
            }
            if urlStr.contains("daily-cloudcode-pa.googleapis.com") {
                return resp(200, [
                    "groups": [
                        [
                            "displayName": "Gemini",
                            "buckets": [
                                ["window": "5h", "remainingFraction": 0.92, "resetTime": futureReset],
                            ],
                        ],
                    ],
                ])
            }
            return resp(404, [:])
        }

        let freshProvider2 = AntigravityProvider(
            keychain: kc,
            processController: ProcessController(inspector: MockProcessInspector(), selfPid: 9999),
            paths: standalonePaths,
            session: makeMockSession(),
            localRPCSession: makeMockSession()
        )
        let snapMixed = await freshProvider2.fetchQuota(for: snowAcct, isActiveLive: true)
        T.expect(snapMixed.status.isReady, "standalone fetchQuota must recover via vaulted RT when live RT mismatches")
        let mixedCloudAuth = StubURLProtocol.snapshotRequests()
            .first { $0.request.url?.absoluteString.contains("daily-cloudcode-pa") == true }?
            .request.value(forHTTPHeaderField: "Authorization")
        T.expectEqual(mixedCloudAuth, "Bearer at_minted_clean_snow_2", "mismatched live refresh_token MUST reject live access_token even when id_token matches")
    }
}

// MARK: - Test 20: v1.3.0 Regression Suite (QuotaHistoryStore & Burn-Rate Curve, AGY gen_metadata Recovery & CHECKPOINT Inheritance, Models-Default Breakdown UI)

private func encodeProtoVarint(_ value: UInt64) -> Data {
    var v = value
    var out = Data()
    repeat {
        var byte = UInt8(v & 0x7F)
        v >>= 7
        if v != 0 { byte |= 0x80 }
        out.append(byte)
    } while v != 0
    return out
}

private func encodeProtoLengthDelimited(field: UInt64, payload: Data) -> Data {
    var out = Data()
    out.append(encodeProtoVarint((field << 3) | 2))
    out.append(encodeProtoVarint(UInt64(payload.count)))
    out.append(payload)
    return out
}

private func encodeProtoString(field: UInt64, value: String) -> Data {
    encodeProtoLengthDelimited(field: field, payload: Data(value.utf8))
}

private func makeSyntheticAntigravityGenMetadataBlob(
    baseModel: String?,
    displayName: String?,
    metadataMap: [(String, String)]
) -> Data {
    var inner = Data()
    if let baseModel {
        inner.append(encodeProtoString(field: 19, value: baseModel))
    }
    for (k, v) in metadataMap {
        var entry = Data()
        entry.append(encodeProtoString(field: 1, value: k))
        entry.append(encodeProtoString(field: 2, value: v))
        inner.append(encodeProtoLengthDelimited(field: 20, payload: entry))
    }
    if let displayName {
        inner.append(encodeProtoString(field: 21, value: displayName))
    }
    return encodeProtoLengthDelimited(field: 1, payload: inner)
}

private func writeSyntheticGenMetadataDB(
    at dbURL: URL,
    rows: [(idx: Int, blob: Data)]
) throws {
    try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    let rc = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    guard rc == SQLITE_OK, let db else {
        if let db { sqlite3_close(db) }
        throw NSError(domain: "V130TestSQLite", code: Int(rc))
    }
    defer { sqlite3_close(db) }

    guard sqlite3_exec(db, "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB);", nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "V130TestSQLite", code: 2)
    }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "INSERT INTO gen_metadata (idx, data) VALUES (?, ?);", -1, &stmt, nil) == SQLITE_OK, let stmt else {
        throw NSError(domain: "V130TestSQLite", code: 3)
    }
    defer { sqlite3_finalize(stmt) }

    for row in rows {
        sqlite3_reset(stmt)
        sqlite3_bind_int64(stmt, 1, Int64(row.idx))
        row.blob.withUnsafeBytes { raw in
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(row.blob.count), transient)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "V130TestSQLite", code: 4)
        }
    }
}

private func testV130RegressionSuite() async {
    // 20.1 QuotaHistoryStore: 0600 atomic persistence, dedup vs 15m heartbeat, 7-day pruning, reset-jump exclusion, hourly peak burn math (`20:00–21:00 -24%`) & AppStore integration
    await T.asyncSuite("V130.QuotaHistoryStorePersistenceAndBurnAnalysis") {
        T.expectEqual(AppStore.appVersion, "1.3.0", "AppStore.appVersion must be 1.3.0")

        let dir = try makeTempDir(prefix: "pulsar-v130-history")
        defer { try? FileManager.default.removeItem(at: dir) }

        let historyURL = dir.appendingPathComponent("quota-history.json", isDirectory: false)
        let store = QuotaHistoryStore(fileURL: historyURL)

        var shanghaiCal = Calendar(identifier: .gregorian)
        shanghaiCal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

        func makeDate(day: Int, hour: Int, minute: Int) -> Date {
            var comps = DateComponents()
            comps.calendar = shanghaiCal
            comps.timeZone = shanghaiCal.timeZone
            comps.year = 2026
            comps.month = 11
            comps.day = day
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            return shanghaiCal.date(from: comps)!
        }

        func makeSnap(
            accountId: String = "acct-snow",
            rem5h: Double,
            remWeekly: Double,
            reset5h: Date,
            resetWeekly: Date,
            status: QuotaStatus? = nil,
            at ts: Date
        ) -> QuotaSnapshot {
            QuotaSnapshot(
                provider: .antigravity,
                accountId: accountId,
                plan: PlanInfo(kind: .ultra, displayName: "Ultra"),
                windows: [
                    QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: rem5h / 100.0, resetAt: reset5h, windowSeconds: 18_000, isPrimary: true),
                    QuotaWindow(id: "gemini_weekly", label: "Gemini · 周", remainingFraction: remWeekly / 100.0, resetAt: resetWeekly, windowSeconds: 604_800),
                ],
                status: status ?? .ready(fetchedAt: ts, stale: false),
                primaryRemainingPercent: Int(rem5h.rounded())
            )
        }

        let reset5hBase = makeDate(day: 22, hour: 21, minute: 5)
        let reset5hAfter = makeDate(day: 23, hour: 2, minute: 5)
        let resetWeekly = makeDate(day: 28, hour: 12, minute: 0)

        // Ignored statuses: loading, failed, stale, empty windows
        let t1800 = makeDate(day: 22, hour: 18, minute: 0)
        T.expectEqual(store.record(snapshot: .loading(provider: .antigravity, accountId: "acct-snow"), now: t1800), false)
        T.expectEqual(store.record(snapshot: .failed(provider: .antigravity, accountId: "acct-snow", sourceLabel: "err", message: "boom"), now: t1800), false)
        T.expectEqual(store.record(snapshot: makeSnap(rem5h: 100, remWeekly: 90, reset5h: reset5hBase, resetWeekly: resetWeekly, status: .ready(fetchedAt: t1800, stale: true), at: t1800), now: t1800), false)
        let emptyWinSnap = QuotaSnapshot(provider: .deepseek, accountId: "ds", windows: [], status: .ready(fetchedAt: t1800, stale: false))
        T.expectEqual(store.record(snapshot: emptyWinSnap, now: t1800), false)

        // First real sample at 18:00 (100% / 90%) -> recorded & atomic 0600 file written
        T.expectEqual(store.record(snapshot: makeSnap(rem5h: 100, remWeekly: 90, reset5h: reset5hBase, resetWeekly: resetWeekly, at: t1800), now: t1800), true)
        T.expect(FileManager.default.fileExists(atPath: historyURL.path), "quota-history.json must be persisted")
        let perms = (try FileManager.default.attributesOfItem(atPath: historyURL.path)[.posixPermissions] as? NSNumber)?.intValue
        T.expectEqual(perms, 0o600, "quota-history.json must use strict 0600 permissions")

        // Dedup: identical sample 2 min later -> skipped
        let t1802 = makeDate(day: 22, hour: 18, minute: 2)
        T.expectEqual(store.record(snapshot: makeSnap(rem5h: 100, remWeekly: 90, reset5h: reset5hBase, resetWeekly: resetWeekly, at: t1802), now: t1802), false)

        // Dedup: sub-threshold 0.05% delta 4 min later -> skipped
        let t1804 = makeDate(day: 22, hour: 18, minute: 4)
        T.expectEqual(store.record(snapshot: makeSnap(rem5h: 99.95, remWeekly: 90, reset5h: reset5hBase, resetWeekly: resetWeekly, at: t1804), now: t1804), false)

        // 15-minute heartbeat: identical sample at 18:15 -> recorded!
        let t1815 = makeDate(day: 22, hour: 18, minute: 15)
        T.expectEqual(store.record(snapshot: makeSnap(rem5h: 100, remWeekly: 90, reset5h: reset5hBase, resetWeekly: resetWeekly, at: t1815), now: t1815), true)

        // Remaining series with 20:00–21:00 burning -24% + 21:05 reset jump (+44%)
        let pointsSchedule: [(Date, Double, Double, Date)] = [
            (makeDate(day: 22, hour: 19, minute: 0), 92.0, 88.0, reset5hBase),   // 18:00–19:00: -8%
            (makeDate(day: 22, hour: 19, minute: 30), 84.0, 86.0, reset5hBase),  // 19:00–20:00: -8%
            (makeDate(day: 22, hour: 20, minute: 0), 80.0, 85.0, reset5hBase),   // 19:00–20:00: -4% (total -12%)
            (makeDate(day: 22, hour: 20, minute: 25), 68.0, 82.0, reset5hBase),  // 20:00–21:00: -12%
            (makeDate(day: 22, hour: 20, minute: 55), 56.0, 79.0, reset5hBase),  // 20:00–21:00: -12% (total -24% PEAK!)
            (makeDate(day: 22, hour: 21, minute: 5), 100.0, 79.0, reset5hAfter), // RESET (+44% & resetAt +5h) -> excluded from burn!
            (makeDate(day: 22, hour: 21, minute: 35), 94.0, 78.0, reset5hAfter), // 21:00–22:00: -6%
        ]
        for (ts, r5, rw, rAt) in pointsSchedule {
            T.expectEqual(store.record(snapshot: makeSnap(rem5h: r5, remWeekly: rw, reset5h: rAt, resetWeekly: resetWeekly, at: ts), now: ts), true)
        }

        // Reload from disk and verify full persistence + exact burn-rate analysis
        let reloaded = QuotaHistoryStore(fileURL: historyURL)
        let acctKey = QuotaHistoryStore.accountKey(provider: .antigravity, accountId: "acct-snow")
        T.expectEqual(reloaded.samples(for: acctKey).count, 9, "reloaded store must contain all 9 recorded samples")

        let analysisNow = makeDate(day: 22, hour: 21, minute: 45)
        let series24h = reloaded.analyze(
            accountKey: acctKey,
            range: .hours24,
            preferredWindowIds: ["gemini_5h", "gemini_weekly"],
            now: analysisNow,
            calendar: shanghaiCal
        )
        T.expectEqual(series24h.count, 2, "must produce series for both 5h and weekly windows")
        let s5h = series24h[0]
        T.expectEqual(s5h.windowId, "gemini_5h")
        T.expectEqual(s5h.resetMarkers.count, 1, "must emit exactly 1 reset marker at 21:05")
        T.expectEqual(s5h.resetMarkers.first, makeDate(day: 22, hour: 21, minute: 5))
        T.expectEqual(s5h.peakBucket?.label, "20:00–21:00", "peak burn bucket must be 20:00–21:00")
        T.expect(abs((s5h.peakBucket?.dropPercent ?? 0) - 24.0) < 0.05, "20:00–21:00 drop must be 24%, got \(s5h.peakBucket?.dropPercent ?? -1)")
        T.expect(abs(s5h.totalConsumedPercent - 50.0) < 0.05, "total consumed must be 50% (excluding +44% reset), got \(s5h.totalConsumedPercent)")
        T.expect(s5h.averageBurnPerHour > 13.0 && s5h.averageBurnPerHour < 15.0, "average burn rate must be ~13.95%/h, got \(s5h.averageBurnPerHour)")

        let sWeekly = series24h[1]
        T.expectEqual(sWeekly.windowId, "gemini_weekly")
        T.expectEqual(sWeekly.resetMarkers.count, 0, "weekly window had no reset")
        T.expect(abs(sWeekly.totalConsumedPercent - 12.0) < 0.05, "weekly total drop must be 12%, got \(sWeekly.totalConsumedPercent)")

        // 6h & 7d range bucket sizing sanity
        let series6h = reloaded.analyze(accountKey: acctKey, range: .hours6, preferredWindowIds: ["gemini_5h"], now: analysisNow, calendar: shanghaiCal)
        T.expectEqual(series6h.count, 1)
        T.expect((series6h[0].buckets.count) >= 12, "6h range must generate 30m buckets")
        let series7d = reloaded.analyze(accountKey: acctKey, range: .days7, preferredWindowIds: ["gemini_5h"], now: analysisNow, calendar: shanghaiCal)
        T.expectEqual(series7d.count, 1)
        T.expect((series7d[0].buckets.count) >= 28, "7d range must generate 6h buckets")

        // 7-day pruning + 900-sample per-account cap
        let pruneStore = QuotaHistoryStore(fileURL: nil)
        let pruneKey = QuotaHistoryStore.accountKey(provider: .antigravity, accountId: "acct-cap")
        let eightDaysAgo = analysisNow.addingTimeInterval(-8 * 24 * 3600)
        T.expectEqual(pruneStore.record(snapshot: makeSnap(accountId: "acct-cap", rem5h: 100, remWeekly: 100, reset5h: reset5hBase, resetWeekly: resetWeekly, at: eightDaysAgo), now: eightDaysAgo), true)
        T.expectEqual(pruneStore.record(snapshot: makeSnap(accountId: "acct-cap", rem5h: 95, remWeekly: 99, reset5h: reset5hBase, resetWeekly: resetWeekly, at: analysisNow), now: analysisNow), true)
        T.expectEqual(pruneStore.samples(for: pruneKey).count, 1, "samples older than 7 days must be pruned")

        let capBase = analysisNow.addingTimeInterval(-3 * 24 * 3600)
        for i in 0..<915 {
            let ts = capBase.addingTimeInterval(Double(i) * 120.0)
            let rem = Double(100 - (i % 50))
            _ = pruneStore.record(snapshot: makeSnap(accountId: "acct-cap", rem5h: rem, remWeekly: 90, reset5h: reset5hBase, resetWeekly: resetWeekly, at: ts), now: ts)
        }
        T.expectEqual(pruneStore.samples(for: pruneKey).count, QuotaHistoryStore.maxSamplesPerAccount, "per-account history must cap cleanly at 900 samples")

        // Verify AppStore.refreshProvider records ready snapshots and bumps quotaHistoryRevision
        let regURL = dir.appendingPathComponent("registry.json")
        let reg = RegistryData(accounts: [
            AccountRecord(id: "codex-live", provider: .codex, email: "codex@example.com", displayName: "Codex Live", isActiveLive: true),
        ])
        try reg.save(to: regURL)
        final class StaticQuotaAdapter: ProviderAdapter {
            let id: ProviderID
            let capabilities: ProviderCapability = []
            let snap: QuotaSnapshot
            init(provider: ProviderID, snap: QuotaSnapshot) {
                self.id = provider
                self.snap = snap
            }
            func detectClientStatus() async -> ClientRuntimeStatus { .notInstalled }
            func syncLiveAccount(registry: inout RegistryData) async -> String? { snap.accountId }
            func fetchQuota(for account: AccountRecord, isActiveLive: Bool) async -> QuotaSnapshot { snap }
            func hasStoredAPIKey() -> Bool { false }
            func saveAPIKey(_ key: String, label: String?) throws {}
            func deleteAccountCredentials(accountId: String) throws {}
        }
        let codexSnap = QuotaSnapshot(
            provider: .codex,
            accountId: "codex-live",
            windows: [
                QuotaWindow(id: "5h", label: "5小时", remainingFraction: 0.77, resetAt: Date().addingTimeInterval(3600), windowSeconds: 18_000, isPrimary: true),
                QuotaWindow(id: "weekly", label: "本周", remainingFraction: 0.88, resetAt: Date().addingTimeInterval(3 * 86_400), windowSeconds: 604_800),
            ],
            status: .ready(fetchedAt: Date(), stale: false),
            primaryRemainingPercent: 77
        )
        let appStore = await MainActor.run {
            AppStore(
                keychain: KeychainStore(backend: InMemoryKeychainBackend()),
                processController: ProcessController(inspector: MockProcessInspector(), selfPid: 9999),
                adapters: [.codex: StaticQuotaAdapter(provider: .codex, snap: codexSnap)],
                registryURL: regURL,
                startScheduler: false,
                persistAccountPoolExport: false
            )
        }
        let revBefore = await MainActor.run { appStore.quotaHistoryRevision }
        await appStore.refreshProvider(.codex, persistExport: false)
        let revAfter = await MainActor.run { appStore.quotaHistoryRevision }
        let recordedCount = await MainActor.run {
            appStore.quotaHistoryStore.samples(for: QuotaHistoryStore.accountKey(provider: .codex, accountId: "codex-live")).count
        }
        T.expectEqual(revAfter, revBefore + 1, "AppStore.refreshProvider must bump quotaHistoryRevision on new ready sample")
        T.expectEqual(recordedCount, 1, "AppStore.refreshProvider must record fresh ready snapshot into quotaHistoryStore")
    }

    // 20.2 TokenUsageEngine: Antigravity gen_metadata protobuf decoder, read-only SQLite recovery & CHECKPOINT lastKnownModel inheritance
    await T.asyncSuite("V130.AntigravityGenMetadataProtobufAndCheckpointRecovery") {
        // 1. Direct protobuf wire parser verification across real Antigravity shapes & malformed inputs
        let blobCarbon = makeSyntheticAntigravityGenMetadataBlob(
            baseModel: "gemini-4-carbon",
            displayName: "Gemini 4 Carbon (High)",
            metadataMap: [("last_step_index", "0"), ("model_enum", "MODEL_PLACEHOLDER_M427")]
        )
        let parsedCarbon = TokenUsageEngine.parseAntigravityGenMetadataBlob(blobCarbon)
        T.expectEqual(parsedCarbon.modelId, "gemini-4-carbon-high")
        T.expectEqual(parsedCarbon.lastStepIndex, 0)

        let blobNeon = makeSyntheticAntigravityGenMetadataBlob(
            baseModel: "gemini-4-neon",
            displayName: "Gemini 4 Neon (XHigh)",
            metadataMap: [("last_step_index", "6"), ("model_enum", "MODEL_PLACEHOLDER_M535")]
        )
        let parsedNeon = TokenUsageEngine.parseAntigravityGenMetadataBlob(blobNeon)
        T.expectEqual(parsedNeon.modelId, "gemini-4-neon-xhigh")
        T.expectEqual(parsedNeon.lastStepIndex, 6)

        let blobHydrogen = makeSyntheticAntigravityGenMetadataBlob(
            baseModel: "gemini-4-hydrogen",
            displayName: "Gemini 4 Hydrogen (XHigh)",
            metadataMap: [("last_step_index", "12")]
        )
        let parsedHydrogen = TokenUsageEngine.parseAntigravityGenMetadataBlob(blobHydrogen)
        T.expectEqual(parsedHydrogen.modelId, "gemini-4-hydrogen-xhigh")
        T.expectEqual(parsedHydrogen.lastStepIndex, 12)

        let blobClaude = makeSyntheticAntigravityGenMetadataBlob(
            baseModel: "claude-opus-5-5-high",
            displayName: "Claude Opus 5.5 (High)",
            metadataMap: [("last_step_index", "20")]
        )
        let parsedClaude = TokenUsageEngine.parseAntigravityGenMetadataBlob(blobClaude)
        T.expectEqual(parsedClaude.modelId, "claude-opus-5-5-high", "must NOT duplicate -high suffix when base model already ends with -high")
        T.expectEqual(parsedClaude.lastStepIndex, 20)

        let blobOrch = makeSyntheticAntigravityGenMetadataBlob(
            baseModel: "gemini-pro-orchestrator",
            displayName: "Orchestrator (Carbon)",
            metadataMap: [("last_step_index", "24")]
        )
        let parsedOrch = TokenUsageEngine.parseAntigravityGenMetadataBlob(blobOrch)
        T.expectEqual(parsedOrch.modelId, "gemini-pro-orchestrator", "non-tier parenthetical (Carbon) must not be appended")

        let blobDisplayOnly = makeSyntheticAntigravityGenMetadataBlob(
            baseModel: nil,
            displayName: "Gemini 4 Neon (XHigh)",
            metadataMap: [("last_step_index", "30")]
        )
        let parsedDisplayOnly = TokenUsageEngine.parseAntigravityGenMetadataBlob(blobDisplayOnly)
        T.expectEqual(parsedDisplayOnly.modelId, "gemini-4-neon-xhigh", "field-21-only blob must still normalize to canonical model ID")
        T.expectEqual(parsedDisplayOnly.lastStepIndex, 30)

        // Malformed / truncated / extreme length varint blobs must fail closed without crashing
        let malformedSamples: [Data] = [
            Data(),
            Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
            Data([0x0A, 0xFF, 0xFF, 0xFF, 0x7F, 0x01]), // huge length overflow
            Data([0x0B, 0x01, 0x02]), // unsupported wire type 3
        ]
        for bad in malformedSamples {
            let res = TokenUsageEngine.parseAntigravityGenMetadataBlob(bad)
            T.expectEqual(res.modelId, nil, "malformed protobuf must safely return nil modelId")
            T.expectEqual(res.lastStepIndex, nil, "malformed protobuf must safely return nil lastStepIndex")
        }

        // 2. End-to-end hermetic TokenUsageEngine scan with read-only SQLite recovery & CHECKPOINT inheritance
        let tempHome = try makeTempDir(prefix: "pulsar-v130-agy-home")
        let tempSupport = try makeTempDir(prefix: "pulsar-v130-agy-support")
        defer {
            try? FileManager.default.removeItem(at: tempHome)
            try? FileManager.default.removeItem(at: tempSupport)
        }

        let agyRoot = tempHome.appendingPathComponent(".gemini/antigravity", isDirectory: true)
        let convUUID = "conv-pre-nov19-test"
        let dbURL = agyRoot.appendingPathComponent("conversations/\(convUUID).db", isDirectory: false)
        try writeSyntheticGenMetadataDB(
            at: dbURL,
            rows: [
                (idx: 0, blob: blobCarbon), // last_step_index=0 -> matches step_index=1
                (idx: 1, blob: blobNeon),   // last_step_index=6 -> matches step_index=7
            ]
        )

        let shanghaiTZ = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let todayKey = TokenFormatters.ymdString(from: Date(), timeZone: shanghaiTZ)
        let ts1 = "\(todayKey)T09:00:00Z"
        let ts2 = "\(todayKey)T09:01:00Z"
        let ts3 = "\(todayKey)T09:02:00Z"
        let ts4 = "\(todayKey)T09:03:00Z"

        let transcript1URL = agyRoot
            .appendingPathComponent("brain/\(convUUID)/.system_generated/logs/transcript.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(at: transcript1URL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines1 = [
            #"{"step_index":0,"type":"USER_INPUT","created_at":"\#(ts1)"}"#,
            #"{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"\#(ts1)","input_tokens":10000,"cache_read_tokens":50000,"output_tokens":2000}"#,
            #"{"step_index":7,"type":"PLANNER_RESPONSE","created_at":"\#(ts2)","input_tokens":15000,"cache_read_tokens":80000,"output_tokens":3000}"#,
            #"{"step_index":8,"type":"CHECKPOINT","created_at":"\#(ts3)","input_tokens":4000,"cache_read_tokens":20000,"output_tokens":1000}"#,
        ].joined(separator: "\n") + "\n"
        try Data(lines1.utf8).write(to: transcript1URL)

        // Second conversation with NO sibling DB, explicit model on PLANNER_RESPONSE + CHECKPOINT omitting model
        let conv2UUID = "conv-nov22-checkpoint-test"
        let transcript2URL = agyRoot
            .appendingPathComponent("brain/\(conv2UUID)/.system_generated/logs/transcript.jsonl", isDirectory: false)
        try FileManager.default.createDirectory(at: transcript2URL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines2 = [
            #"{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"\#(ts1)","model":"claude-opus-5-5-high","input_tokens":5000,"cache_read_tokens":30000,"output_tokens":1500}"#,
            #"{"step_index":2,"type":"CHECKPOINT","created_at":"\#(ts2)","input_tokens":2000,"cache_read_tokens":10000,"output_tokens":500}"#,
        ].joined(separator: "\n") + "\n"
        try Data(lines2.utf8).write(to: transcript2URL)

        let engine = TokenUsageEngine(
            homeDirectoryURL: tempHome,
            appSupportURL: tempSupport,
            legacyTokenMonitorDirURL: tempSupport.appendingPathComponent("no-tm", isDirectory: true)
        )
        let snap1 = await engine.scanAndExportArchive(forceFullRescan: true)
        let summary1 = snap1.summary(for: .allTime, clientFilter: .antigravity)

        // Verify ZERO "unknown" models remain!
        T.expectEqual(
            summary1.byModel.contains(where: { $0.modelId.lowercased() == "unknown" }),
            false,
            "recovered Antigravity summary must contain ZERO 'unknown' model entries"
        )
        let carbonRow = summary1.byModel.first { $0.modelId == "gemini-4-carbon-high" }
        let neonRow = summary1.byModel.first { $0.modelId == "gemini-4-neon-xhigh" }
        let opusRow = summary1.byModel.first { $0.modelId == "claude-opus-5-5-high" }

        T.expectEqual(carbonRow?.totals.totalTokens, 62_000, "step 1 must map to gemini-4-carbon-high (62K tok)")
        T.expectEqual(neonRow?.totals.totalTokens, 123_000, "step 7 (98K) + inherited CHECKPOINT step 8 (25K) must map to gemini-4-neon-xhigh (123K tok)")
        T.expectEqual(opusRow?.totals.totalTokens, 49_000, "conv2 PLANNER_RESPONSE (36.5K) + CHECKPOINT (12.5K) must map to claude-opus-5-5-high (49K tok)")
        T.expect((neonRow?.totals.estimatedCostUSD ?? 0) > 0, "recovered model must produce accurate positive pricing")

        // Verify strict read-only open created NO -wal or -shm sidecars next to conversations/<uuid>.db
        T.expectEqual(FileManager.default.fileExists(atPath: dbURL.path + "-wal"), false, "read-only immutable open must NEVER create -wal")
        T.expectEqual(FileManager.default.fileExists(atPath: dbURL.path + "-shm"), false, "read-only immutable open must NEVER create -shm")

        // Incremental resume test: append a new CHECKPOINT line (no "model") to conv2 -> must resume antigravityLastModel from CachedFileState!
        let appendedLine = #"{"step_index":3,"type":"CHECKPOINT","created_at":"\#(ts4)","input_tokens":1000,"cache_read_tokens":5000,"output_tokens":200}"# + "\n"
        let handle = try FileHandle(forWritingTo: transcript2URL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appendedLine.utf8))
        try handle.close()

        let snap2 = await engine.scanAndExportArchive(forceFullRescan: false)
        let summary2 = snap2.summary(for: .allTime, clientFilter: .antigravity)
        T.expectEqual(
            summary2.byModel.contains(where: { $0.modelId.lowercased() == "unknown" }),
            false,
            "incremental CHECKPOINT resume must preserve antigravityLastModel with zero 'unknown'"
        )
        T.expectEqual(
            summary2.byModel.first { $0.modelId == "claude-opus-5-5-high" }?.totals.totalTokens,
            55_200,
            "incremental CHECKPOINT (+6.2K) must add cleanly onto claude-opus-5-5-high"
        )
    }

    // 20.3 UI NSHostingView Smoke Tests (340pt & 390pt): Models-Default Breakdown Tab + Share Progress Bars & QuotaCurvePanelView (0, 1, multi-sample + reset)
    await T.asyncSuite("V130.UINSHostingViewSmokeTests") {
        // BreakdownTab invariants: NO .clients tab, .models is first & default
        T.expectEqual(TokenUsagePopoverView.BreakdownTab.allCases, [.models, .projects], "BreakdownTab must only contain [.models, .projects]")
        T.expectEqual(TokenUsagePopoverView.defaultBreakdownTab, .models, "default breakdown tab must be .models")

        let dir = try makeTempDir(prefix: "pulsar-v130-ui")
        defer { try? FileManager.default.removeItem(at: dir) }

        let regURL = dir.appendingPathComponent("registry.json")
        let reg = RegistryData(accounts: [
            AccountRecord(id: "agy-ui", provider: .antigravity, email: "snow@example.com", displayName: "Snow", isActiveLive: true),
        ])
        try reg.save(to: regURL)

        let now = Date()
        let reset5h = now.addingTimeInterval(3 * 3600)
        let resetWeekly = now.addingTimeInterval(5 * 86_400)
        let agySnap = QuotaSnapshot(
            provider: .antigravity,
            accountId: "agy-ui",
            plan: PlanInfo(kind: .ultra, displayName: "Ultra"),
            windows: [
                QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: 0.68, resetAt: reset5h, windowSeconds: 18_000, isPrimary: true),
                QuotaWindow(id: "gemini_weekly", label: "Gemini · 周", remainingFraction: 0.84, resetAt: resetWeekly, windowSeconds: 604_800),
            ],
            status: .ready(fetchedAt: now, stale: false),
            primaryRemainingPercent: 68
        )

        let shanghaiTZ = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let todayKey = TokenFormatters.ymdString(from: now, timeZone: shanghaiTZ)
        let agyTotals = TokenComponentTotals(totalTokens: 12_400_000, uncachedInputTokens: 1_200_000, outputTokens: 320_000, cacheReadTokens: 10_880_000, estimatedCostUSD: 10.52, messageCount: 48)
        let codexTotals = TokenComponentTotals(totalTokens: 5_100_000, uncachedInputTokens: 600_000, outputTokens: 200_000, cacheReadTokens: 4_300_000, estimatedCostUSD: 4.60, messageCount: 22)
        let combinedTotals = agyTotals.adding(codexTotals)
        let todayRangeSummary = TokenRangeSummary(
            range: .today,
            startDate: todayKey,
            endDate: todayKey,
            totals: combinedTotals,
            activeDays: 1,
            totalDaysInRange: 1,
            byClient: [
                TokenClientBreakdown(client: .antigravity, totals: agyTotals, shareOfTokens: 12.4 / 17.5, activeDays: 1),
                TokenClientBreakdown(client: .codex, totals: codexTotals, shareOfTokens: 5.1 / 17.5, activeDays: 1),
            ],
            byModel: [
                TokenModelBreakdown(client: .antigravity, modelId: "gemini-4-neon-xhigh", providerId: "google", totals: agyTotals, shareOfTokens: 12.4 / 17.5),
                TokenModelBreakdown(client: .codex, modelId: "gpt-6.2-sol", providerId: "openai", totals: codexTotals, shareOfTokens: 5.1 / 17.5),
            ],
            byProject: [
                TokenProjectBreakdown(
                    id: "/Users/rory/Tools/rory-orbit",
                    projectName: "rory-orbit",
                    pathDisplay: "~/Tools/rory-orbit",
                    clients: [.antigravity],
                    totals: agyTotals,
                    shareOfTokens: 12.4 / 17.5,
                    lastActiveDate: todayKey
                ),
            ],
            dailySeries: []
        )
        let syntheticTokenSnap = TokenUsageSnapshot(
            generatedAt: now,
            lastScannedAt: now,
            seedDaysCount: 0,
            totalDaysCount: 1,
            liveScannedFilesCount: 2,
            archiveFileURLPath: dir.appendingPathComponent("daily-history-archive.json").path,
            heatmap112Days: [],
            allDays: [],
            ranges: [
                .today: todayRangeSummary,
                .allTime: todayRangeSummary,
            ]
        )

        let multiSampleStore = QuotaHistoryStore(fileURL: nil)
        let acctKey = QuotaHistoryStore.accountKey(provider: .antigravity, accountId: "agy-ui")
        let t0 = now.addingTimeInterval(-4 * 3600)
        let t1 = now.addingTimeInterval(-3 * 3600)
        let t2 = now.addingTimeInterval(-2 * 3600)
        let t3 = now.addingTimeInterval(-1 * 3600)
        let t4 = now.addingTimeInterval(-20 * 60)
        let seq: [(Date, Double, Double, Date)] = [
            (t0, 100, 92, reset5h.addingTimeInterval(-5 * 3600)),
            (t1, 86, 90, reset5h.addingTimeInterval(-5 * 3600)),
            (t2, 62, 87, reset5h.addingTimeInterval(-5 * 3600)),
            (t3, 100, 87, reset5h), // reset!
            (t4, 78, 84, reset5h),
        ]
        for (ts, r5, rw, rAt) in seq {
            _ = multiSampleStore.record(
                snapshot: QuotaSnapshot(
                    provider: .antigravity,
                    accountId: "agy-ui",
                    windows: [
                        QuotaWindow(id: "gemini_5h", label: "Gemini · 5小时", remainingFraction: r5 / 100.0, resetAt: rAt, windowSeconds: 18_000, isPrimary: true),
                        QuotaWindow(id: "gemini_weekly", label: "Gemini · 周", remainingFraction: rw / 100.0, resetAt: resetWeekly, windowSeconds: 604_800),
                    ],
                    status: .ready(fetchedAt: ts, stale: false),
                    primaryRemainingPercent: Int(r5)
                ),
                now: ts
            )
        }
        let multiSeries = multiSampleStore.analyze(accountKey: acctKey, range: .hours24, preferredWindowIds: ["gemini_5h", "gemini_weekly"], now: now)
        let oneSampleSeries = [
            QuotaBurnSeries(
                windowId: "gemini_5h",
                label: "Gemini · 5小时",
                points: [QuotaBurnPoint(timestamp: now, remainingPercent: 82.0)],
                resetMarkers: [],
                buckets: [],
                peakBucket: nil,
                totalConsumedPercent: 0,
                averageBurnPerHour: 0
            ),
        ]

        let hermeticEngine = TokenUsageEngine(
            homeDirectoryURL: dir.appendingPathComponent("empty-home", isDirectory: true),
            appSupportURL: dir.appendingPathComponent("empty-support", isDirectory: true),
            legacyTokenMonitorDirURL: dir.appendingPathComponent("empty-tm", isDirectory: true)
        )

        await MainActor.run {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)

            let store = AppStore(
                keychain: KeychainStore(backend: InMemoryKeychainBackend()),
                processController: ProcessController(inspector: MockProcessInspector(), selfPid: 9999),
                adapters: [:],
                registryURL: regURL,
                startScheduler: false,
                tokenUsageEngine: hermeticEngine,
                persistAccountPoolExport: false,
                quotaHistoryStore: multiSampleStore
            )
            store.snapshots[AppStore.snapshotKey(provider: .antigravity, accountId: "agy-ui")] = agySnap
            store.tokenUsage = syntheticTokenSnap

            @MainActor
            func smokeHost<V: View>(_ view: V, width: CGFloat, height: CGFloat, fixedHeight: Bool, appearanceName: NSAppearance.Name, label: String) {
                let framed: AnyView = fixedHeight
                    ? AnyView(view.frame(width: width, height: height))
                    : AnyView(view.frame(width: width))
                let host = NSHostingView(rootView: framed)
                host.appearance = NSAppearance(named: appearanceName)
                host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                host.layoutSubtreeIfNeeded()
                let fit = host.fittingSize
                T.expect(fit.width > 0 && fit.height > 0 && fit.width.isFinite && fit.height.isFinite, "\(label) @\(Int(width))pt must lay out with valid finite fittingSize (\(fit))")
            }

            // 1. TokenUsagePopoverView (defaults to .models with share progress bars) at 340pt, 390pt & 560pt in Light & Dark modes
            for w in [CGFloat(340), CGFloat(390), CGFloat(560)] {
                smokeHost(TokenUsagePopoverView(store: store), width: w, height: 620, fixedHeight: true, appearanceName: .aqua, label: "TokenUsagePopoverView.Light")
                smokeHost(TokenUsagePopoverView(store: store), width: w, height: 620, fixedHeight: true, appearanceName: .darkAqua, label: "TokenUsagePopoverView.Dark")
            }

            // 2. QuotaCurvePanelView with 0 samples, 1 sample, and multi-sample + reset markers at 340pt & 390pt
            for w in [CGFloat(340), CGFloat(390)] {
                for (name, series) in [("0-sample", [QuotaBurnSeries]()), ("1-sample", oneSampleSeries), ("multi-reset", multiSeries)] {
                    for range in QuotaHistoryRange.allCases {
                        let panel = QuotaCurvePanelView(
                            seriesList: series,
                            selectedRange: range,
                            onSelectRange: { _ in },
                            poolBadgeText: "Gemini",
                            referenceNow: now,
                            compact: w < 365,
                            availableWidth: w - 36
                        )
                        smokeHost(panel, width: w - 24, height: 220, fixedHeight: false, appearanceName: .darkAqua, label: "QuotaCurvePanelView.\(name).\(range.rawValue)")
                    }
                }
            }

            // 3. Full MenuBarView at 340pt & 390pt with ready account card + mini sparkline curve toggle pill
            for w in [CGFloat(340), CGFloat(390)] {
                store.registry.settings.popoverWidth = Double(w)
                smokeHost(
                    MenuBarView(store: store, onOpenSettings: {}),
                    width: w,
                    height: 580,
                    fixedHeight: true,
                    appearanceName: .aqua,
                    label: "MenuBarView.Light"
                )
            }
        }
    }
}

// MARK: - Main Entry Point

Task {
    print("Running RoryOrbit unit tests...")
    testModels()
    testKeychainStore()
    await testProcessControl()
    testLegacyMigrator()
    await testAntigravityProvider()
    await testCodexAndProjectSync()
    await testQuotaProviders()
    testTokenFormattersAndModels()
    await testTokenUsageEngine()
    await testAccountPoolExporter()
    await testAvatarAndBrand()
    await testMenuBarCustomization()
    await testLiveTokenSpeedEngine()
    await testPhase2RegressionSuite()
    await testV110RegressionSuite()
    await testV120RegressionSuite()
    await testV121RegressionSuite()
    await testV122RegressionSuite()
    await testV123RegressionSuite()
    await testV130RegressionSuite()

    print("Results: \(T.passed) assertions passed, \(T.failed) failed.")
    fflush(stdout)
    Darwin.exit(T.failed == 0 ? 0 : 1)
}

RunLoop.main.run()
