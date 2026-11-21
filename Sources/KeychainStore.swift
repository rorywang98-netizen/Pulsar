import Darwin
import Foundation
import Security

// MARK: - Keychain Service Namespaces

public let roryOrbitAntigravityService = "com.rory.roryorbit.antigravity"
public let roryOrbitCodexService       = "com.rory.roryorbit.codex"
public let roryOrbitKeysService        = "com.rory.roryorbit.keys"

// MARK: - Errors

public enum KeychainStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidIdentifier(String)
    case commandFailed(operation: String, exitCode: Int32)
    case encodingError(String)
    case corruptedChunkIndex(String)
    case missingChunk(index: Int, total: Int)
    case integrityCheckFailed(service: String, account: String)
    case payloadTooLarge(Int)
    case fileSystemError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let detail):
            return "无效的 Keychain 标识符: \(detail)"
        case .commandFailed(let op, let code):
            return "Keychain 操作失败 (\(op), code=\(code))"
        case .encodingError(let detail):
            return "Keychain 编码错误: \(detail)"
        case .corruptedChunkIndex(let detail):
            return "Keychain 分片索引损坏: \(detail)"
        case .missingChunk(let idx, let total):
            return "Keychain 分片缺失 (\(idx)/\(total))"
        case .integrityCheckFailed(let service, _):
            return "Keychain 完整性校验失败 (\(service))"
        case .payloadTooLarge(let size):
            return "Keychain 数据超过限制 (\(size) bytes)"
        case .fileSystemError(let detail):
            return "文件系统写入失败: \(detail)"
        }
    }
}

// MARK: - Chunk Index Schema

public struct KeychainChunkIndex: Codable, Equatable, Sendable {
    public let generation: String
    public let chunks: Int
    public let digest: String

    public init(generation: String, chunks: Int, digest: String) {
        self.generation = generation
        self.chunks = chunks
        self.digest = digest
    }
}

// MARK: - Injectable Backend Protocol

public protocol KeychainBackend: Sendable {
    func setGenericPassword(service: String, account: String, data: Data) throws
    func getGenericPassword(service: String, account: String) throws -> Data?
    func deleteGenericPassword(service: String, account: String) throws
}

// MARK: - /usr/bin/security Interactive CLI Backend (Zero argv Secret Exposure)

public final class SecurityCLIKeychainBackend: KeychainBackend, @unchecked Sendable {
    public static let securityBinaryPath = "/usr/bin/security"
    /// `/usr/bin/security -i` uses a 4096-byte stdin line buffer; keep generous safety margins.
    public static let maxInteractivePlainASCIIBytes = 3400
    public static let maxInteractiveHexRawBytes = 1600

    public let keychainPath: String?

    public init(keychainPath: String? = nil) {
        self.keychainPath = keychainPath
    }

    public func setGenericPassword(service: String, account: String, data: Data) throws {
        try validateIdentifier(service, name: "service")
        try validateIdentifier(account, name: "account")

        // Prefer `/usr/bin/security -i` (stdin) so ad-hoc rebuilds share `/usr/bin/security` ACL
        // and secrets are NEVER placed on process command-line argv.
        if let ascii = safeInteractiveASCIIString(from: data),
           ascii.utf8.count <= Self.maxInteractivePlainASCIIBytes {
            try writeViaInteractiveSecurity(
                service: service,
                account: account,
                flag: "-w",
                encodedValue: ascii
            )
            return
        }

        if data.count <= Self.maxInteractiveHexRawBytes {
            let hex = Self.hexEncode(data)
            try writeViaInteractiveSecurity(
                service: service,
                account: account,
                flag: "-X",
                encodedValue: hex
            )
            return
        }

        // Large external secrets (e.g. >3.4KB raw JSON for `Codex Auth`) exceed `security -i`'s
        // 4096-byte line buffer; fall back to Security.framework directly in-process (still zero argv).
        if keychainPath == nil {
            try writeViaSecurityFramework(service: service, account: account, data: data)
            return
        }

        throw KeychainStoreError.payloadTooLarge(data.count)
    }

    public func getGenericPassword(service: String, account: String) throws -> Data? {
        try validateIdentifier(service, name: "service")
        try validateIdentifier(account, name: "account")

        // `find-generic-password -g` puts no secret on argv and prints exact `0x<HEX>` for
        // any non-ASCII/multiline/quoted payload, avoiding `-w` hex ambiguity.
        var args = ["find-generic-password", "-g", "-s", service, "-a", account]
        if let kc = keychainPath {
            args.append(kc)
        }

        let res = try runSecurity(arguments: args, stdinData: nil)
        if res.exitCode == 44 {
            return nil
        }
        if res.exitCode != 0 {
            throw KeychainStoreError.commandFailed(operation: "find-generic-password", exitCode: res.exitCode)
        }

        if let parsed = Self.parsePasswordFromFindMinusG(stderr: res.stderr) {
            return parsed
        }

        // Defensive fallback to `-w` if `-g` output format ever omits `password:`.
        var wArgs = ["find-generic-password", "-s", service, "-a", account, "-w"]
        if let kc = keychainPath {
            wArgs.append(kc)
        }
        let wRes = try runSecurity(arguments: wArgs, stdinData: nil)
        if wRes.exitCode == 44 {
            return nil
        }
        if wRes.exitCode != 0 {
            throw KeychainStoreError.commandFailed(operation: "find-generic-password(-w)", exitCode: wRes.exitCode)
        }
        return Self.stripSingleTrailingNewline(wRes.stdout)
    }

    public func deleteGenericPassword(service: String, account: String) throws {
        try validateIdentifier(service, name: "service")
        try validateIdentifier(account, name: "account")

        var args = ["delete-generic-password", "-s", service, "-a", account]
        if let kc = keychainPath {
            args.append(kc)
        }
        let res = try runSecurity(arguments: args, stdinData: nil)
        if res.exitCode == 0 || res.exitCode == 44 {
            return
        }
        throw KeychainStoreError.commandFailed(operation: "delete-generic-password", exitCode: res.exitCode)
    }

    // MARK: - Private Helpers

    private func writeViaInteractiveSecurity(
        service: String,
        account: String,
        flag: String,
        encodedValue: String
    ) throws {
        let escapedService = Self.escapeInteractiveArg(service)
        let escapedAccount = Self.escapeInteractiveArg(account)
        var line = "add-generic-password -U -s \"\(escapedService)\" -a \"\(escapedAccount)\" \(flag) \"\(encodedValue)\""
        if let kc = keychainPath {
            let escapedKC = Self.escapeInteractiveArg(kc)
            line += " \"\(escapedKC)\""
        }
        line += "\n"

        guard let stdinData = line.data(using: .utf8) else {
            throw KeychainStoreError.encodingError("UTF-8 encoding failed")
        }
        let res = try runSecurity(arguments: ["-i"], stdinData: stdinData)
        if res.exitCode != 0 {
            throw KeychainStoreError.commandFailed(operation: "add-generic-password", exitCode: res.exitCode)
        }
    }

    private func writeViaSecurityFramework(service: String, account: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                return
            }
            throw KeychainStoreError.commandFailed(operation: "SecItemAdd", exitCode: Int32(addStatus))
        }
        throw KeychainStoreError.commandFailed(operation: "SecItemUpdate", exitCode: Int32(updateStatus))
    }

    private func validateIdentifier(_ value: String, name: String) throws {
        if value.isEmpty {
            throw KeychainStoreError.invalidIdentifier("\(name) 不能为空")
        }
        for scalar in value.unicodeScalars {
            if scalar.value == 0 || scalar == "\n" || scalar == "\r" {
                throw KeychainStoreError.invalidIdentifier("\(name) 包含非法控制字符")
            }
        }
    }

    private static func escapeInteractiveArg(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func safeInteractiveASCIIString(from data: Data) -> String? {
        for byte in data {
            // Printable ASCII excluding whitespace, quotes, backslash, dollar, backtick.
            if byte < 0x21 || byte > 0x7E { return nil }
            if byte == 0x22 || byte == 0x27 || byte == 0x5C || byte == 0x24 || byte == 0x60 {
                return nil
            }
        }
        return String(data: data, encoding: .ascii)
    }

    public static func hexEncode(_ data: Data) -> String {
        let lut = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(lut[Int(byte >> 4)])
            out.append(lut[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func hexDecode(_ hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = hexNibble(chars[i]), let lo = hexNibble(chars[i + 1]) else {
                return nil
            }
            bytes.append((hi << 4) | lo)
            i += 2
        }
        return Data(bytes)
    }

    private static func hexNibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30       // '0'...'9'
        case 0x41...0x46: return c - 0x41 + 10  // 'A'...'F'
        case 0x61...0x66: return c - 0x61 + 10  // 'a'...'f'
        default: return nil
        }
    }

    public static func parsePasswordFromFindMinusG(stderr: Data) -> Data? {
        guard let text = String(data: stderr, encoding: .utf8) ?? String(data: stderr, encoding: .isoLatin1) else {
            return nil
        }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard line.hasPrefix("password:") else { continue }
            var rest = String(line.dropFirst("password:".count))
            while rest.hasPrefix(" ") || rest.hasPrefix("\t") {
                rest.removeFirst()
            }
            if rest.isEmpty {
                return Data()
            }
            if rest.hasPrefix("0x") || rest.hasPrefix("0X") {
                let afterPrefix = rest.dropFirst(2)
                let hexPart = String(afterPrefix.prefix { $0.isHexDigit })
                return hexDecode(hexPart)
            }
            if rest.hasPrefix("\"") && rest.hasSuffix("\"") && rest.count >= 2 {
                let inner = String(rest.dropFirst().dropLast())
                return Data(inner.utf8)
            }
            return Data(rest.utf8)
        }
        return nil
    }

    private static func stripSingleTrailingNewline(_ data: Data) -> Data {
        if data.last == 0x0A {
            return data.dropLast()
        }
        return data
    }

    private struct ProcessOutput {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
    }

    private func runSecurity(arguments: [String], stdinData: Data?) throws -> ProcessOutput {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.securityBinaryPath)
        proc.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        let stdinPipe = Pipe()
        if stdinData != nil {
            proc.standardInput = stdinPipe
        } else {
            proc.standardInput = FileHandle.nullDevice
        }

        do {
            try proc.run()
        } catch {
            throw KeychainStoreError.commandFailed(operation: "spawn-security", exitCode: -1)
        }

        let group = DispatchGroup()
        var stdoutBytes = Data()
        var stderrBytes = Data()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutBytes = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrBytes = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        if let stdinData {
            stdinPipe.fileHandleForWriting.write(stdinData)
            try? stdinPipe.fileHandleForWriting.close()
        }

        proc.waitUntilExit()
        group.wait()

        return ProcessOutput(
            exitCode: proc.terminationStatus,
            stdout: stdoutBytes,
            stderr: stderrBytes
        )
    }
}

// MARK: - In-Memory Backend for Unit Tests

public final class InMemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    public init() {}

    private func compositeKey(service: String, account: String) -> String {
        "\(service)\u{0}\(account)"
    }

    public func setGenericPassword(service: String, account: String, data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[compositeKey(service: service, account: account)] = data
    }

    public func getGenericPassword(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[compositeKey(service: service, account: account)]
    }

    public func deleteGenericPassword(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: compositeKey(service: service, account: account))
    }

    public func allKeys(forService service: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let prefix = "\(service)\u{0}"
        return storage.keys
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .sorted()
    }

    public func itemCount(forService service: String) -> Int {
        allKeys(forService: service).count
    }
}

// MARK: - KeychainStore Facade

public final class KeychainStore: @unchecked Sendable {
    public static let roryOrbitAntigravityService = "com.rory.roryorbit.antigravity"
    public static let roryOrbitCodexService       = "com.rory.roryorbit.codex"
    public static let roryOrbitKeysService        = "com.rory.roryorbit.keys"

    public static let maxChunkChars = 1800
    public static let maxChunkCount = 256

    public static let shared = KeychainStore(backend: SecurityCLIKeychainBackend())

    public let backend: KeychainBackend

    public init(backend: KeychainBackend = SecurityCLIKeychainBackend()) {
        self.backend = backend
    }

    public convenience init(keychainPath: String) {
        self.init(backend: SecurityCLIKeychainBackend(keychainPath: keychainPath))
    }

    // MARK: - Single-Item API

    public func writeSecret(service: String, account: String, value: String) throws {
        try writeSecretData(service: service, account: account, data: Data(value.utf8))
    }

    public func writeSecretData(service: String, account: String, data: Data) throws {
        let expectedDigest = Formatters.sha256Hex(data)
        try backend.setGenericPassword(service: service, account: account, data: data)
        guard let readBack = try backend.getGenericPassword(service: service, account: account),
              Formatters.sha256Hex(readBack) == expectedDigest else {
            throw KeychainStoreError.integrityCheckFailed(service: service, account: account)
        }
    }

    public func readSecret(service: String, account: String) throws -> String? {
        guard let data = try readSecretData(service: service, account: account) else {
            return nil
        }
        guard let str = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.encodingError("UTF-8 decode failed")
        }
        return str
    }

    public func readSecretData(service: String, account: String) throws -> Data? {
        try backend.getGenericPassword(service: service, account: account)
    }

    public func deleteSecret(service: String, account: String) throws {
        try backend.deleteGenericPassword(service: service, account: account)
    }

    public func hasSecret(service: String, account: String) -> Bool {
        (try? backend.getGenericPassword(service: service, account: account)) != nil
    }

    public func verifySecret(service: String, account: String, expectedSHA256: String) throws -> Bool {
        guard let data = try readSecretData(service: service, account: account) else {
            return false
        }
        return Formatters.sha256Hex(data) == expectedSHA256.lowercased()
    }

    // MARK: - Chunked Secret API (<= 1800 Base64 chars/chunk + SHA-256 Digest Index)

    public func writeChunkedSecret(service: String, account: String, data: Data) throws {
        let previousIndex = try? readChunkIndex(service: service, account: account)

        let base64 = data.base64EncodedString()
        let chunks = Self.splitString(base64, maxLength: Self.maxChunkChars)
        guard chunks.count <= Self.maxChunkCount else {
            throw KeychainStoreError.payloadTooLarge(data.count)
        }

        let generation = Self.randomGenerationToken()
        let digest = Formatters.sha256Hex(data)

        // Stage all chunks for the new generation first before updating the index atomically.
        for (idx, chunk) in chunks.enumerated() {
            let chunkAccount = Self.chunkAccountKey(account: account, generation: generation, index: idx)
            try backend.setGenericPassword(service: service, account: chunkAccount, data: Data(chunk.utf8))
        }

        let index = KeychainChunkIndex(generation: generation, chunks: chunks.count, digest: digest)
        let indexData = try JSONEncoder().encode(index)
        try backend.setGenericPassword(service: service, account: account, data: indexData)

        // Read back & verify SHA-256 integrity.
        guard let verified = try readChunkedSecret(service: service, account: account),
              Formatters.sha256Hex(verified) == digest else {
            throw KeychainStoreError.integrityCheckFailed(service: service, account: account)
        }

        // Clean up superseded generation chunks only after the new generation verified cleanly.
        if let old = previousIndex, old.generation != generation {
            for idx in 0..<old.chunks {
                let oldKey = Self.chunkAccountKey(account: account, generation: old.generation, index: idx)
                try? backend.deleteGenericPassword(service: service, account: oldKey)
            }
        }
    }

    public func readChunkIndex(service: String, account: String) throws -> KeychainChunkIndex? {
        guard let indexData = try backend.getGenericPassword(service: service, account: account) else {
            return nil
        }
        do {
            let index = try JSONDecoder().decode(KeychainChunkIndex.self, from: indexData)
            guard !index.generation.isEmpty,
                  (1...Self.maxChunkCount).contains(index.chunks),
                  !index.digest.isEmpty else {
                throw KeychainStoreError.corruptedChunkIndex("invalid metadata bounds")
            }
            return index
        } catch let err as KeychainStoreError {
            throw err
        } catch {
            throw KeychainStoreError.corruptedChunkIndex("JSON decode failed")
        }
    }

    public func readChunkedSecret(service: String, account: String) throws -> Data? {
        guard let index = try readChunkIndex(service: service, account: account) else {
            return nil
        }

        var combined = ""
        combined.reserveCapacity(index.chunks * Self.maxChunkChars)

        for idx in 0..<index.chunks {
            let chunkAccount = Self.chunkAccountKey(account: account, generation: index.generation, index: idx)
            guard let chunkData = try backend.getGenericPassword(service: service, account: chunkAccount),
                  let chunkStr = String(data: chunkData, encoding: .utf8) else {
                throw KeychainStoreError.missingChunk(index: idx, total: index.chunks)
            }
            combined.append(chunkStr)
        }

        guard let decoded = Data(base64Encoded: combined) else {
            throw KeychainStoreError.encodingError("chunk Base64 decode failed")
        }

        if Formatters.sha256Hex(decoded) != index.digest.lowercased() {
            throw KeychainStoreError.integrityCheckFailed(service: service, account: account)
        }

        return decoded
    }

    public func verifyChunkedSecret(service: String, account: String, expectedSHA256: String) throws -> Bool {
        guard let decoded = try readChunkedSecret(service: service, account: account) else {
            return false
        }
        return Formatters.sha256Hex(decoded) == expectedSHA256.lowercased()
    }

    public func deleteChunkedSecret(service: String, account: String) throws {
        if let index = try? readChunkIndex(service: service, account: account) {
            for idx in 0..<index.chunks {
                let chunkKey = Self.chunkAccountKey(account: account, generation: index.generation, index: idx)
                try backend.deleteGenericPassword(service: service, account: chunkKey)
            }
        }
        try backend.deleteGenericPassword(service: service, account: account)
    }

    // MARK: - External Generic Password Helpers (Antigravity / Codex / Migration)

    public func readExternalGenericPassword(service: String, account: String) throws -> String? {
        guard let data = try backend.getGenericPassword(service: service, account: account) else {
            return nil
        }
        guard let str = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.encodingError("UTF-8 decode failed")
        }
        return str
    }

    public func readExternalGenericPasswordData(service: String, account: String) throws -> Data? {
        try backend.getGenericPassword(service: service, account: account)
    }

    public func writeExternalGenericPassword(service: String, account: String, value: String) throws {
        try backend.setGenericPassword(service: service, account: account, data: Data(value.utf8))
    }

    public func deleteExternalGenericPassword(service: String, account: String) throws {
        try backend.deleteGenericPassword(service: service, account: account)
    }

    // MARK: - Chunking & Random Generation Helpers

    public static func chunkAccountKey(account: String, generation: String, index: Int) -> String {
        "\(account):\(generation):\(index)"
    }

    private static func splitString(_ input: String, maxLength: Int) -> [String] {
        if input.isEmpty {
            return [""]
        }
        var chunks: [String] = []
        var idx = input.startIndex
        while idx < input.endIndex {
            let next = input.index(idx, offsetBy: maxLength, limitedBy: input.endIndex) ?? input.endIndex
            chunks.append(String(input[idx..<next]))
            idx = next
        }
        return chunks
    }

    private static func randomGenerationToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return Formatters.base64URLEncode(Data(bytes))
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    }

    // MARK: - Atomic 0600 / 0700 File Helpers

    public static func ensureDirectory(at url: URL, mode: mode_t = 0o700) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: mode)]
                )
            } catch {
                throw KeychainStoreError.fileSystemError("创建目录失败: \(url.lastPathComponent)")
            }
        }
        if Darwin.chmod(url.path, mode) != 0 {
            throw KeychainStoreError.fileSystemError("设置目录权限失败: \(url.lastPathComponent) (errno=\(errno))")
        }
    }

    /// Atomically writes `data` to `url` with restrictive POSIX mode (`0600` default):
    /// creates temp file in same directory with `O_CREAT | O_EXCL | O_WRONLY` + `mode`,
    /// enforces `fchmod`, writes full buffer, calls `fsync`, closes fd, and `rename`s into place.
    public static func writeAtomicFile(data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try ensureDirectory(at: dir, mode: 0o700)
        }

        let tempName = ".\(url.lastPathComponent).tmp.\(UUID().uuidString)"
        let tempURL = dir.appendingPathComponent(tempName, isDirectory: false)
        let tempPath = tempURL.path

        let fd = Darwin.open(tempPath, O_CREAT | O_EXCL | O_WRONLY, mode)
        if fd < 0 {
            throw KeychainStoreError.fileSystemError("创建临时文件失败 (errno=\(errno))")
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
            throw KeychainStoreError.fileSystemError("设置临时文件权限失败 (errno=\(errno))")
        }

        try data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var written = 0
            while written < rawBuf.count {
                let n = Darwin.write(fd, base.advanced(by: written), rawBuf.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw KeychainStoreError.fileSystemError("写入文件失败 (errno=\(errno))")
                }
                written += n
            }
        }

        if Darwin.fsync(fd) != 0 {
            throw KeychainStoreError.fileSystemError("fsync 失败 (errno=\(errno))")
        }

        if Darwin.close(fd) != 0 {
            closed = true
            throw KeychainStoreError.fileSystemError("关闭临时文件失败 (errno=\(errno))")
        }
        closed = true

        if Darwin.rename(tempPath, url.path) != 0 {
            throw KeychainStoreError.fileSystemError("原子替换文件失败 (errno=\(errno))")
        }
        renamed = true
    }
}
