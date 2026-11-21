import Foundation

/// Preserves non-cloud local projects, thread assignments, and sidebar layout across Codex account switches
/// in `~/.codex/.codex-global-state.json` with atomic `.bak` backup, readback verification, and rollback.
public enum CodexProjectSync {

    // MARK: - Types

    public struct RollbackHandle: Sendable {
        public let globalStateURL: URL
        public let backupURL: URL
        public let applied: Bool
        public let reason: String
        fileprivate let originalData: Data?

        public static func noop(globalStateURL: URL, reason: String) -> RollbackHandle {
            RollbackHandle(
                globalStateURL: globalStateURL,
                backupURL: globalStateURL.appendingPathExtension("bak"),
                applied: false,
                reason: reason,
                originalData: nil
            )
        }
    }

    public enum SyncError: Error, LocalizedError, Equatable, Sendable {
        case invalidJSON(String)
        case serializationFailed
        case readbackVerificationFailed
        case ioFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidJSON(let detail):
                return "解析 .codex-global-state.json 失败: \(detail)"
            case .serializationFailed:
                return "序列化 .codex-global-state.json 失败"
            case .readbackVerificationFailed:
                return "写入 .codex-global-state.json 后回读校验失败"
            case .ioFailed(let detail):
                return "读写 .codex-global-state.json 失败: \(detail)"
            }
        }
    }

    // MARK: - Constants

    private static let globalStateFilename = ".codex-global-state.json"
    private static let accountRendererStateKey = "electron-account-renderer-state-v1"
    private static let rendererContentOwnerKey = "electron-renderer-content-owner"

    private static let localProjectsKey = "local-projects"
    private static let threadProjectAssignmentsKey = "thread-project-assignments"
    private static let projectOrderKey = "project-order"
    private static let sidebarProjectThreadOrdersKey = "sidebar-project-thread-orders"
    private static let appServerProjectIdMapByHostKey = "app-server-project-id-by-legacy-project-id-by-host"
    private static let appServerProjectsMigrationByHostKey = "app-server-projects-migration-by-host"

    private static let unifiedSidebarProjectOrderKey = "unified-sidebar-project-order-v1"
    private static let sidebarCollapsedSectionsKey = "sidebar-collapsed-sections-v1"
    private static let sidebarProjectListExpandedKey = "sidebar-project-list-expanded-v1"
    private static let expandedProjectKeys = [
        "sidebar-expanded-project-ids-v1",
        "sidebar-project-expanded-v1",
        "expanded-project-ids",
    ]

    // MARK: - Owner Key Computation

    /// Computes Codex Desktop's account owner key: lowercase SHA-256 hex of compact JSON `[userId, accountId]`.
    public static func ownerKey(userId: String, accountId: String) -> String {
        let pair = [userId, accountId]
        if let data = try? JSONSerialization.data(withJSONObject: pair, options: [.withoutEscapingSlashes]) {
            return Formatters.sha256Hex(data)
        }
        let escapedUser = escapeJSONString(userId)
        let escapedAccount = escapeJSONString(accountId)
        return Formatters.sha256Hex("[\"\(escapedUser)\",\"\(escapedAccount)\"]")
    }

    /// Computes the canonical `local:<CODEX_HOME>` host key used inside Codex Desktop's project migration tables.
    public static func localHostKey(codexHomeURL: URL) -> String {
        let canonical = codexHomeURL.standardizedFileURL.resolvingSymlinksInPath().path
        return "local:\(canonical)"
    }

    // MARK: - Prepare, Apply & Rollback

    /// Merges non-cloud local projects and sidebar layout from `from` (or current active renderer owner)
    /// into `to` inside `<codexHomeURL>/.codex-global-state.json`.
    ///
    /// - Clean no-op when `.codex-global-state.json` does not exist or when `electron-account-renderer-state-v1` is absent.
    /// - Atomically writes `.codex-global-state.json.bak` before updating `.codex-global-state.json` and verifies read-back.
    @discardableResult
    public static func prepareAndApply(
        codexHomeURL: URL,
        from sourceIdentity: CodexAuthIdentity?,
        to targetIdentity: CodexAuthIdentity
    ) throws -> RollbackHandle {
        let globalStateURL = codexHomeURL.appendingPathComponent(globalStateFilename, isDirectory: false)
        let backupURL = globalStateURL.appendingPathExtension("bak")
        let fm = FileManager.default

        guard fm.fileExists(atPath: globalStateURL.path) else {
            return .noop(globalStateURL: globalStateURL, reason: "global-state-absent")
        }

        let originalData: Data
        do {
            originalData = try Data(contentsOf: globalStateURL)
        } catch {
            throw SyncError.ioFailed(error.localizedDescription)
        }

        guard !originalData.isEmpty else {
            return .noop(globalStateURL: globalStateURL, reason: "global-state-empty")
        }

        guard var root = (try? JSONSerialization.jsonObject(with: originalData, options: [])) as? [String: Any] else {
            throw SyncError.invalidJSON("根对象不是 JSON 字典")
        }

        // Clean no-op when multi-account renderer state is absent (e.g. legacy top-level single-owner state).
        guard let rawRendererState = root[accountRendererStateKey] as? [String: Any] else {
            return .noop(globalStateURL: globalStateURL, reason: "electron-account-renderer-state-v1-absent")
        }

        let targetKey = ownerKey(userId: targetIdentity.userId, accountId: targetIdentity.chatgptAccountId)
        let explicitSourceKey = sourceIdentity.map {
            ownerKey(userId: $0.userId, accountId: $0.chatgptAccountId)
        }
        let currentRendererOwner = (root[rendererContentOwnerKey] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let sourceKey = explicitSourceKey ?? currentRendererOwner

        if let sourceKey, sourceKey == targetKey {
            return .noop(globalStateURL: globalStateURL, reason: "same-owner")
        }

        let hostKey = localHostKey(codexHomeURL: codexHomeURL)
        let (updatedRendererState, mergedProjectCount) = mergeAccountRendererState(
            rawRendererState,
            root: root,
            sourceOwnerKey: sourceKey,
            targetOwnerKey: targetKey,
            hostKey: hostKey
        )

        root[accountRendererStateKey] = updatedRendererState

        // Also update top-level owner-scoped migration key if present for the target owner.
        if mergedProjectCount > 0 {
            let ownerMigrationKey = "electron-owner-value:\(appServerProjectsMigrationByHostKey):\(targetKey)"
            if var migrationByHost = root[ownerMigrationKey] as? [String: Any] {
                migrationByHost[hostKey] = markMigrationPending(existing: migrationByHost[hostKey])
                root[ownerMigrationKey] = migrationByHost
            }
        }

        guard let encoded = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            throw SyncError.serializationFailed
        }

        let expectedSHA = Formatters.sha256Hex(encoded)

        do {
            // 1. Atomic backup of original bytes before touching live state.
            try KeychainStore.writeAtomicFile(data: originalData, to: backupURL, mode: 0o600)

            // 2. Atomic write of merged state.
            try KeychainStore.writeAtomicFile(data: encoded, to: globalStateURL, mode: 0o600)

            // 3. Read-back SHA-256 + JSON structural verification.
            let readBack = try Data(contentsOf: globalStateURL)
            guard Formatters.sha256Hex(readBack) == expectedSHA,
                  (try? JSONSerialization.jsonObject(with: readBack, options: [])) is [String: Any] else {
                try? KeychainStore.writeAtomicFile(data: originalData, to: globalStateURL, mode: 0o600)
                throw SyncError.readbackVerificationFailed
            }
        } catch let err as SyncError {
            throw err
        } catch {
            try? KeychainStore.writeAtomicFile(data: originalData, to: globalStateURL, mode: 0o600)
            throw SyncError.ioFailed(error.localizedDescription)
        }

        return RollbackHandle(
            globalStateURL: globalStateURL,
            backupURL: backupURL,
            applied: true,
            reason: "merged-\(mergedProjectCount)-local-projects",
            originalData: originalData
        )
    }

    /// Restores `.codex-global-state.json` from the rollback handle (or `.bak` fallback) after a failed switch.
    public static func rollback(_ handle: RollbackHandle) throws {
        guard handle.applied else { return }

        if let original = handle.originalData {
            try KeychainStore.writeAtomicFile(data: original, to: handle.globalStateURL, mode: 0o600)
            return
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: handle.backupURL.path) {
            let backupBytes = try Data(contentsOf: handle.backupURL)
            try KeychainStore.writeAtomicFile(data: backupBytes, to: handle.globalStateURL, mode: 0o600)
        }
    }

    // MARK: - Core Merge Engine

    private static func mergeAccountRendererState(
        _ rendererState: [String: Any],
        root: [String: Any],
        sourceOwnerKey: String?,
        targetOwnerKey: String,
        hostKey: String
    ) -> ([String: Any], Int) {
        // Support both nested container (`accounts` / `byOwner` / `owners`) and flat owner-keyed map.
        let containerKey: String?
        if rendererState["accounts"] is [String: Any] {
            containerKey = "accounts"
        } else if rendererState["byOwner"] is [String: Any] {
            containerKey = "byOwner"
        } else if rendererState["owners"] is [String: Any] {
            containerKey = "owners"
        } else {
            containerKey = nil
        }

        var updatedRenderer = rendererState
        var ownerMap: [String: Any]
        if let containerKey, let nested = rendererState[containerKey] as? [String: Any] {
            ownerMap = nested
        } else {
            ownerMap = rendererState
        }

        let sourceState = resolveSourceOwnerState(
            ownerMap: ownerMap,
            root: root,
            sourceOwnerKey: sourceOwnerKey,
            targetOwnerKey: targetOwnerKey
        )
        var targetState = (ownerMap[targetOwnerKey] as? [String: Any]) ?? [:]

        // 1. Collect & filter non-cloud local projects from source (and top-level fallback if source lacks them).
        let sourceProjectsRaw = sourceState[localProjectsKey] ?? root[localProjectsKey]
        let (mergedProjects, allowedLocalIds, mergedCount) = mergeLocalProjects(
            sourceRaw: sourceProjectsRaw,
            targetRaw: targetState[localProjectsKey]
        )
        if let mergedProjects {
            targetState[localProjectsKey] = mergedProjects
        }

        // 2. Merge thread-project-assignments strictly for non-cloud local projects.
        let sourceAssignments = (sourceState[threadProjectAssignmentsKey] as? [String: Any])
            ?? (root[threadProjectAssignmentsKey] as? [String: Any])
        if let sourceAssignments {
            var targetAssignments = (targetState[threadProjectAssignmentsKey] as? [String: Any]) ?? [:]
            for (threadId, rawProjId) in sourceAssignments {
                guard let projId = rawProjId as? String,
                      !isCloudProjectId(projId),
                      allowedLocalIds.contains(projId) else {
                    continue
                }
                if let existingProjId = targetAssignments[threadId] as? String,
                   isCloudProjectId(existingProjId) {
                    // Never overwrite an existing cloud thread assignment belonging to the target account.
                    continue
                }
                if targetAssignments[threadId] == nil {
                    targetAssignments[threadId] = projId
                }
            }
            targetState[threadProjectAssignmentsKey] = targetAssignments
        }

        // 3. Merge project-order (preserving target order, appending source local projects in order).
        let sourceOrder = (sourceState[projectOrderKey] as? [String])
            ?? (root[projectOrderKey] as? [String])
        if let sourceOrder {
            let targetOrder = (targetState[projectOrderKey] as? [String]) ?? []
            let mergedOrder = mergeStringOrder(
                target: targetOrder,
                source: sourceOrder.filter { !isCloudProjectId($0) && allowedLocalIds.contains($0) }
            )
            targetState[projectOrderKey] = mergedOrder
        }

        // 4. Merge sidebar-project-thread-orders for non-cloud local projects.
        let sourceThreadOrders = (sourceState[sidebarProjectThreadOrdersKey] as? [String: Any])
            ?? (root[sidebarProjectThreadOrdersKey] as? [String: Any])
        if let sourceThreadOrders {
            var targetThreadOrders = (targetState[sidebarProjectThreadOrdersKey] as? [String: Any]) ?? [:]
            for (projId, rawThreads) in sourceThreadOrders {
                guard !isCloudProjectId(projId),
                      allowedLocalIds.contains(projId),
                      let srcThreads = rawThreads as? [String] else {
                    continue
                }
                let existingThreads = (targetThreadOrders[projId] as? [String]) ?? []
                targetThreadOrders[projId] = mergeStringOrder(target: existingThreads, source: srcThreads)
            }
            targetState[sidebarProjectThreadOrdersKey] = targetThreadOrders
        }

        // 5. Merge app-server-project-id-by-legacy-project-id-by-host["local:<CODEX_HOME>"].
        let sourceHostMaps = (sourceState[appServerProjectIdMapByHostKey] as? [String: Any])
            ?? (root[appServerProjectIdMapByHostKey] as? [String: Any])
        if let sourceHostMaps,
           let sourceForHost = sourceHostMaps[hostKey] as? [String: Any] {
            var targetHostMaps = (targetState[appServerProjectIdMapByHostKey] as? [String: Any]) ?? [:]
            var targetForHost = (targetHostMaps[hostKey] as? [String: Any]) ?? [:]
            for (legacyId, mappedValue) in sourceForHost {
                guard !isCloudProjectId(legacyId),
                      allowedLocalIds.contains(legacyId) else {
                    continue
                }
                if targetForHost[legacyId] == nil {
                    targetForHost[legacyId] = mappedValue
                }
            }
            targetHostMaps[hostKey] = targetForHost
            targetState[appServerProjectIdMapByHostKey] = targetHostMaps
        }

        // 6. Mark app-server-projects-migration-by-host pending flags when local projects were merged.
        if mergedCount > 0 {
            var targetMigrationByHost = (targetState[appServerProjectsMigrationByHostKey] as? [String: Any]) ?? [:]
            targetMigrationByHost[hostKey] = markMigrationPending(existing: targetMigrationByHost[hostKey])
            targetState[appServerProjectsMigrationByHostKey] = targetMigrationByHost
        }

        // 7. Carry sidebar order & expansion flags while enforcing visible threads & project list.
        mergeSidebarState(
            sourceState: sourceState,
            targetState: &targetState,
            allowedLocalIds: allowedLocalIds
        )

        ownerMap[targetOwnerKey] = targetState

        if let containerKey {
            updatedRenderer[containerKey] = ownerMap
        } else {
            updatedRenderer = ownerMap
        }

        return (updatedRenderer, mergedCount)
    }

    private static func resolveSourceOwnerState(
        ownerMap: [String: Any],
        root: [String: Any],
        sourceOwnerKey: String?,
        targetOwnerKey: String
    ) -> [String: Any] {
        if let sourceOwnerKey,
           let state = ownerMap[sourceOwnerKey] as? [String: Any] {
            return state
        }
        // Fallback: synthesize from root-level single-owner keys if present.
        var fallback: [String: Any] = [:]
        for key in [
            localProjectsKey,
            threadProjectAssignmentsKey,
            projectOrderKey,
            sidebarProjectThreadOrdersKey,
            appServerProjectIdMapByHostKey,
            unifiedSidebarProjectOrderKey,
        ] {
            if let value = root[key] {
                fallback[key] = value
            }
        }
        if !fallback.isEmpty {
            return fallback
        }
        // Last resort: pick another owner entry if exactly one non-target owner exists.
        let otherOwners = ownerMap.keys.filter { $0 != targetOwnerKey && ownerMap[$0] is [String: Any] }
        if otherOwners.count == 1, let onlyKey = otherOwners.first,
           let state = ownerMap[onlyKey] as? [String: Any] {
            return state
        }
        return [:]
    }

    // MARK: - Local Project Filtering & Merging

    /// Returns `true` if the project ID belongs to a ChatGPT cloud project (`g-p-*`).
    public static func isCloudProjectId(_ projectId: String) -> Bool {
        projectId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("g-p-")
    }

    /// Returns `true` if a project entry represents a cloud-backed project (skip `g-p-*` and `chatGptBacking*`).
    public static func isCloudProjectEntry(id: String?, value: Any) -> Bool {
        if let id, isCloudProjectId(id) {
            return true
        }
        guard let dict = value as? [String: Any] else {
            return false
        }
        if let nestedId = dict["id"] as? String, isCloudProjectId(nestedId) {
            return true
        }
        if let legacyId = dict["projectId"] as? String, isCloudProjectId(legacyId) {
            return true
        }
        for (k, v) in dict {
            let lower = k.lowercased()
            if lower.hasPrefix("chatgptbacking") {
                if !(v is NSNull) {
                    if let s = v as? String, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        continue
                    }
                    if let b = v as? Bool, b == false {
                        continue
                    }
                    return true
                }
            }
        }
        if let isCloud = dict["isCloud"] as? Bool, isCloud {
            return true
        }
        if let kind = (dict["kind"] as? String)?.lowercased(), kind == "cloud" {
            return true
        }
        return false
    }

    /// Handles both dictionary-shaped (`[projectId: projectDict]`) and array-shaped (`[[String: Any]]`) `local-projects`.
    private static func mergeLocalProjects(
        sourceRaw: Any?,
        targetRaw: Any?
    ) -> (merged: Any?, allowedLocalIds: Set<String>, mergedCount: Int) {
        var allowedIds = Set<String>()
        var mergedCount = 0

        // Shape A: Dictionary `[projectId: projectObj]`
        if let sourceDict = sourceRaw as? [String: Any] {
            var targetDict = (targetRaw as? [String: Any]) ?? [:]
            for (projId, projVal) in targetDict {
                if !isCloudProjectEntry(id: projId, value: projVal) {
                    allowedIds.insert(projId)
                }
            }
            for (projId, projVal) in sourceDict {
                guard !isCloudProjectEntry(id: projId, value: projVal) else { continue }
                allowedIds.insert(projId)
                if targetDict[projId] == nil {
                    targetDict[projId] = projVal
                    mergedCount += 1
                }
            }
            return (targetDict, allowedIds, mergedCount)
        }

        // Shape B: Array `[[String: Any]]`
        if let sourceArr = sourceRaw as? [[String: Any]] {
            var targetArr = (targetRaw as? [[String: Any]]) ?? []
            var existingIds = Set<String>()
            for item in targetArr {
                if let id = extractProjectId(from: item) {
                    existingIds.insert(id)
                    if !isCloudProjectEntry(id: id, value: item) {
                        allowedIds.insert(id)
                    }
                }
            }
            for item in sourceArr {
                let id = extractProjectId(from: item)
                guard !isCloudProjectEntry(id: id, value: item) else { continue }
                if let id {
                    allowedIds.insert(id)
                    if !existingIds.contains(id) {
                        targetArr.append(item)
                        existingIds.insert(id)
                        mergedCount += 1
                    }
                }
            }
            return (targetArr, allowedIds, mergedCount)
        }

        // Source has no local projects; preserve target's existing local project IDs.
        if let targetDict = targetRaw as? [String: Any] {
            for (projId, projVal) in targetDict where !isCloudProjectEntry(id: projId, value: projVal) {
                allowedIds.insert(projId)
            }
        } else if let targetArr = targetRaw as? [[String: Any]] {
            for item in targetArr {
                if let id = extractProjectId(from: item), !isCloudProjectEntry(id: id, value: item) {
                    allowedIds.insert(id)
                }
            }
        }
        return (targetRaw, allowedIds, 0)
    }

    private static func extractProjectId(from dict: [String: Any]) -> String? {
        if let id = dict["id"] as? String, !id.isEmpty { return id }
        if let id = dict["projectId"] as? String, !id.isEmpty { return id }
        return nil
    }

    // MARK: - Sidebar Preservation

    private static func mergeSidebarState(
        sourceState: [String: Any],
        targetState: inout [String: Any],
        allowedLocalIds: Set<String>
    ) {
        // 1. Carry unified-sidebar-project-order-v1 (filter out source cloud IDs, preserve target items).
        if let sourceUnified = sourceState[unifiedSidebarProjectOrderKey] as? [String] {
            let targetUnified = (targetState[unifiedSidebarProjectOrderKey] as? [String]) ?? []
            let filteredSource = sourceUnified.filter { id in
                !isCloudProjectId(id) && (allowedLocalIds.isEmpty || allowedLocalIds.contains(id))
            }
            targetState[unifiedSidebarProjectOrderKey] = mergeStringOrder(
                target: targetUnified,
                source: filteredSource
            )
        } else if let sourceUnifiedDict = sourceState[unifiedSidebarProjectOrderKey] as? [String: Any] {
            var targetUnifiedDict = (targetState[unifiedSidebarProjectOrderKey] as? [String: Any]) ?? [:]
            for (k, v) in sourceUnifiedDict {
                if let arr = v as? [String] {
                    let existing = (targetUnifiedDict[k] as? [String]) ?? []
                    let filtered = arr.filter { !isCloudProjectId($0) && (allowedLocalIds.isEmpty || allowedLocalIds.contains($0)) }
                    targetUnifiedDict[k] = mergeStringOrder(target: existing, source: filtered)
                } else if targetUnifiedDict[k] == nil {
                    targetUnifiedDict[k] = v
                }
            }
            targetState[unifiedSidebarProjectOrderKey] = targetUnifiedDict
        }

        // 2. Carry expanded project flags (array or boolean map) without leaking cloud project IDs.
        for key in expandedProjectKeys {
            if let sourceArr = sourceState[key] as? [String] {
                let targetArr = (targetState[key] as? [String]) ?? []
                let filtered = sourceArr.filter { !isCloudProjectId($0) && (allowedLocalIds.isEmpty || allowedLocalIds.contains($0)) }
                targetState[key] = mergeStringOrder(target: targetArr, source: filtered)
            } else if let sourceMap = sourceState[key] as? [String: Any] {
                var targetMap = (targetState[key] as? [String: Any]) ?? [:]
                for (projId, flag) in sourceMap {
                    guard !isCloudProjectId(projId),
                          allowedLocalIds.isEmpty || allowedLocalIds.contains(projId) else {
                        continue
                    }
                    if targetMap[projId] == nil {
                        targetMap[projId] = flag
                    }
                }
                targetState[key] = targetMap
            }
        }

        // 3. Force sidebar-collapsed-sections-v1.threads = false so local threads remain visible.
        var collapsedSections = (targetState[sidebarCollapsedSectionsKey] as? [String: Any])
            ?? (sourceState[sidebarCollapsedSectionsKey] as? [String: Any])
            ?? [:]
        collapsedSections["threads"] = false
        targetState[sidebarCollapsedSectionsKey] = collapsedSections

        // 4. Force sidebar-project-list-expanded-v1 = true so local projects are expanded immediately.
        targetState[sidebarProjectListExpandedKey] = true
    }

    private static func markMigrationPending(existing: Any?) -> [String: Any] {
        var entry = (existing as? [String: Any]) ?? [:]
        entry["status"] = "pending"
        entry["pending"] = true
        entry["completed"] = false
        return entry
    }

    private static func mergeStringOrder(target: [String], source: [String]) -> [String] {
        var result = target
        var seen = Set(target)
        for item in source where seen.insert(item).inserted {
            result.append(item)
        }
        return result
    }

    private static func escapeJSONString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
