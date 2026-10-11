import Foundation

public enum StoreError: Error, Equatable {
    case invalidPath, invalidSource, invalidSnapshot, unsupportedSchema, unavailableSpace
    case budgetExceeded, sourceChanged, recoveryRequired, notFound, operationInProgress, invalidEdit
}
public actor MaterialStore {
    private let paths: OwnedPaths
    private let files: any FileOperations
    private let budget: StorageBudget
    private var state: WorkspaceSnapshot?
    private var loadedExistingWorkspace = false
    private var busy = false
    private var activeNoteMaterials = Set<UUID>()
    public init(root: URL, files: any FileOperations = SystemFileOperations(), budget: StorageBudget = StorageBudget()) {
        paths = OwnedPaths(root); self.files = files; self.budget = budget
    }
    public func load() async throws -> WorkspaceSnapshot {
        guard !busy else { throw StoreError.operationInProgress }
        return try ensureLoaded()
    }
    public func previewStorageCleanup(now: Date = Date()) throws -> StorageCleanupPlan {
        guard !busy else { throw StoreError.operationInProgress }
        return try buildCleanupPlan(exportCutoff: now.addingTimeInterval(-86400))
    }
    public func cleanStorage(_ plan: StorageCleanupPlan) throws -> StorageCleanupResult {
        guard !busy else { throw StoreError.operationInProgress }
        busy = true; defer { busy = false }
        let fresh = try buildCleanupPlan(exportCutoff: plan.exportCutoff)
        let freshSelection = fresh.targets.filter { target in plan.targets.contains(where: { $0.relativePath == target.relativePath }) }
        guard plan.root == paths.root, fresh.generation == plan.generation, freshSelection == plan.targets else { throw StoreError.sourceChanged }
        let before = try ensureLoaded()
        let receiptURL = try paths.url("CleanupRecords/" + UUID().uuidString + ".json")
        var receipt = CleanupReceipt(id: plan.id, createdAt: Date(), authorization: "Confirmed storage-cleanup preview in Settings; move copies to system Trash", snapshotBefore: before, targets: plan.targets, outcomes: [])
        try files.createDirectory(paths.url("CleanupRecords"))
        try files.writeAtomic(JSONEncoder().encode(receipt), to: receiptURL)
        var next = before
        let selected = Set(plan.targets.filter { $0.kind == .material }.compactMap(\.materialID))
        if !selected.isEmpty {
            for index in next.materials.indices where selected.contains(next.materials[index].id) { next.materials[index].status = .trashed }
            next = try persist(next)
            // Anchor both current and fallback snapshots before moving bytes.
            // A crash can leave an interrupted tombstone, which the next preview
            // can retry; journals must never resurrect a cleaned record.
            next = try persist(next)
        }
        var moved = 0, movedBytes: Int64 = 0, failed = 0, unverified = 0
        for target in plan.targets {
            let original = try paths.url(target.relativePath)
            var trashURL: URL?
            do {
                guard try cleanupFingerprints(original) == target.fingerprints else { throw StoreError.sourceChanged }
                trashURL = try files.trash(original)
                guard !(try exists(original)), let destination = trashURL,
                      try cleanupFingerprints(destination) == target.fingerprints else { throw StoreError.recoveryRequired }
                moved += 1; movedBytes += target.byteCount
                receipt.outcomes.append(.init(originalPath: original.path, trashURL: destination, verified: true, error: nil))
            } catch {
                let remains = (try? exists(original)) == true
                if remains {
                    failed += 1
                    if target.kind == .material, let id = target.materialID, let index = next.materials.firstIndex(where: { $0.id == id }),
                       let previous = before.materials.first(where: { $0.id == id }) { next.materials[index].status = previous.status }
                } else {
                    // A failed Trash call can have moved the source already.
                    // Keep its tombstone and record uncertainty, never point a
                    // live record back at missing bytes or claim verified recovery.
                    unverified += 1
                }
                receipt.outcomes.append(.init(originalPath: original.path, trashURL: trashURL, verified: false, error: String(describing: error)))
            }
            try files.writeAtomic(JSONEncoder().encode(receipt), to: receiptURL)
        }
        if next != state { next = try persist(next) }
        return StorageCleanupResult(snapshot: next, movedCount: moved, movedBytes: movedBytes, failedCount: failed, unverifiedCount: unverified, receiptURL: receiptURL)
    }

    private func buildCleanupPlan(exportCutoff: Date) throws -> StorageCleanupPlan {
        let current = try ensureLoaded()
        guard !current.privacyHidden else { throw StoreError.invalidSource }
        var protected = Set(try noteDrafts().filter(\.isPending).map(\.materialID)).union(activeNoteMaterials)
        var completedEdits = [CleanupTarget]()
        for directory in try files.list(paths.url("Drafts")) {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { throw StoreError.recoveryRequired }
            let folder = "Drafts/" + id.uuidString
            let children = try files.list(paths.url(folder))
            let sessionURL = try paths.url(folder + "/session.json")
            if try exists(sessionURL) {
                let (session, disposition) = try editSessionDisposition(id, in: current)
                switch disposition {
                case .pending: protected.insert(session.materialID)
                case .completed:
                    completedEdits.append(try cleanupTarget(folder, kind: .completedEdit,
                        record: current.materials.first { $0.id == session.materialID }))
                }
            } else if !children.isEmpty && Set(children.map(\.lastPathComponent)) != ["note.json"] {
                throw StoreError.recoveryRequired
            }
        }
        for entry in try files.list(paths.url("Transactions")) where entry.pathExtension == "json" {
            let url = try paths.url("Transactions/" + entry.lastPathComponent)
            guard let journal = try? JSONDecoder().decode(StoreJournal.self, from: files.read(url)), entry.lastPathComponent == journal.id.uuidString + ".json" else { throw StoreError.recoveryRequired }
            let existing = current.materials.first { $0.id == journal.record.id }
            if existing == nil || !journal.record.versions.allSatisfy({ version in existing?.versions.contains(version) == true }) { protected.insert(journal.record.id) }
        }
        let staging = try stagingRecoveryInventory(in: current)
        var targets = staging.targets
        for record in current.materials.sorted(by: { $0.id.uuidString < $1.id.uuidString }) where
            [.takenDown, .trashed].contains(record.status) && !record.pinned && !protected.contains(record.id) {
            let relative = "Materials/" + record.id.uuidString
            let url = try paths.url(relative)
            if !(try exists(url)) {
                guard record.status == .trashed else { throw StoreError.recoveryRequired }
                continue
            }
            targets.append(try cleanupTarget(relative, kind: .material, record: record))
        }
        targets += completedEdits.sorted { $0.relativePath < $1.relativePath }
        for entry in try files.list(paths.url("Exports")).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let relative = "Exports/" + entry.lastPathComponent
            let target = try cleanupTarget(relative, kind: .temporaryExport)
            if target.fingerprints.allSatisfy({ $0.modifiedAt < exportCutoff }) { targets.append(target) }
        }
        var total: Int64 = 0
        for target in targets {
            guard total <= Int64.max - target.byteCount else { throw StoreError.budgetExceeded }
            total += target.byteCount
        }
        return StorageCleanupPlan(id: UUID(), targets: targets, stagingInventory: staging.items, root: paths.root, generation: current.generation, exportCutoff: exportCutoff)
    }

    /// Inventory only: orphan evidence is never removed during load or import.
    public func stagingRecoveryInventory() throws -> [StagingRecoveryItem] {
        guard !busy else { throw StoreError.operationInProgress }
        let current = try ensureLoaded()
        guard !current.privacyHidden else { throw StoreError.invalidSource }
        return try stagingRecoveryInventory(in: current).items
    }

    private func stagingRecoveryInventory(in current: WorkspaceSnapshot) throws -> (items: [StagingRecoveryItem], targets: [CleanupTarget]) {
        let entries = try files.list(paths.url("Transactions")).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var items = [StagingRecoveryItem](), candidates = [CleanupTarget]()
        for entry in entries where entry.pathExtension != "json" {
            let relative = "Transactions/" + entry.lastPathComponent
            guard let owned = try? paths.url(relative), let info = try? files.inspect(owned),
                  info.isRegularFile, !info.isSymbolicLink, info.byteCount >= 0,
                  info.byteCount <= budget.maxFileBytes, ContentStore.isStagingFilename(entry.lastPathComponent) else {
                items.append(.init(relativePath: relative, byteCount: nil, disposition: .needsInspection)); continue
            }
            candidates.append(try cleanupTarget(relative, kind: .unownedStaging))
        }
        guard !candidates.isEmpty else { return (items, []) }
        let stagingKeys = Set(candidates.map { ($0.fingerprints.first?.sha256 ?? "") + ":" + String($0.byteCount) })
        var versions = current.materials.flatMap(\.versions)
        for filename in ["state.json", "state.previous.json"] {
            let url = try paths.url(filename)
            if try exists(url) {
                let info = try files.inspect(url)
                guard info.isRegularFile, !info.isSymbolicLink,
                      let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: files.read(url)) else { throw StoreError.recoveryRequired }
                try validate(snapshot)
                guard info == (try files.inspect(url)) else { throw StoreError.sourceChanged }
                versions += snapshot.materials.flatMap(\.versions)
            }
        }
        for entry in entries where entry.pathExtension == "json" {
            let owned = try paths.url("Transactions/" + entry.lastPathComponent)
            let info = try files.inspect(owned)
            guard info.isRegularFile, !info.isSymbolicLink,
                  let journal = try? JSONDecoder().decode(StoreJournal.self, from: files.read(owned)),
                  entry.lastPathComponent == journal.id.uuidString + ".json" else { throw StoreError.recoveryRequired }
            try validateRecord(journal.record)
            versions += journal.record.versions
        }
        // Legacy journals do not name their staging path. An unresolved payload
        // protects matching evidence; a fully verified retained payload does not
        // make a redundant stage permanently uncleanable.
        var unresolved = Set<String>()
        var checked = Set<String>()
        for version in versions {
            let key = version.sha256 + ":" + String(version.byteCount)
            // Only payloads matching an actual stage need disk verification.
            guard stagingKeys.contains(key), checked.insert(version.relativePath + ":" + key).inserted else { continue }
            let verified: Bool
            do {
                let url = try paths.url(version.relativePath), before = try files.inspect(url)
                verified = try before.isRegularFile && !before.isSymbolicLink && before.byteCount == version.byteCount &&
                    ContentStore.digest(try files.read(url)) == version.sha256 && before == (try files.inspect(url))
            } catch { verified = false }
            if !verified { unresolved.insert(key) }
        }
        for draft in try noteDrafts() where draft.isPending {
            let bytes = Data(draft.text.utf8)
            unresolved.insert(ContentStore.digest(bytes) + ":" + String(bytes.count))
        }
        for directory in try files.list(paths.url("Drafts")) {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { throw StoreError.recoveryRequired }
            if try exists(paths.url("Drafts/" + id.uuidString + "/session.json")) {
                let (session, disposition) = try editSessionDisposition(id, in: current)
                if disposition == .pending {
                    let fingerprints = try cleanupFingerprints(session.workingURL)
                    guard let working = fingerprints.first, let hash = working.sha256 else { throw StoreError.recoveryRequired }
                    unresolved.insert(hash + ":" + String(working.bytes))
                }
            }
        }
        var targets = [CleanupTarget]()
        for target in candidates {
            let key = (target.fingerprints.first?.sha256 ?? "") + ":" + String(target.byteCount)
            let referenced = unresolved.contains(key)
            items.append(.init(relativePath: target.relativePath, byteCount: target.byteCount, disposition: referenced ? .referenced : .unowned))
            if !referenced { targets.append(target) }
        }
        return (items.sorted { $0.relativePath < $1.relativePath }, targets)
    }

    /// Export a retained copy outside the library; never overwrite an existing file.
    public func exportStagingCopy(_ target: CleanupTarget, from plan: StorageCleanupPlan, to destination: URL) throws -> URL {
        guard !busy else { throw StoreError.operationInProgress }
        busy = true; defer { busy = false }
        let fresh = try buildCleanupPlan(exportCutoff: plan.exportCutoff)
        guard plan.root == paths.root, plan.generation == fresh.generation, target.kind == .unownedStaging,
              plan.targets.contains(target), fresh.targets.contains(target) else { throw StoreError.sourceChanged }
        let output = destination.standardizedFileURL
        let current = try ensureLoaded()
        guard !current.materials.contains(where: { record in record.source.filePath.map { URL(fileURLWithPath: $0).standardizedFileURL == output } ?? false }) else { throw StoreError.invalidPath }
        let parent = output.deletingLastPathComponent()
        guard destination.isFileURL, output.path != paths.root.path, !output.path.hasPrefix(paths.root.path + "/"),
              parent.resolvingSymlinksInPath().standardizedFileURL == parent,
              try !files.inspect(parent).isSymbolicLink,
              output.resolvingSymlinksInPath() == output, !(try exists(output)) else { throw StoreError.invalidPath }
        let original = try paths.url(target.relativePath)
        guard try cleanupFingerprints(original) == target.fingerprints else { throw StoreError.sourceChanged }
        try files.copy(original, to: output)
        guard try cleanupFingerprints(original) == target.fingerprints,
              try files.inspect(output).isRegularFile,
              ContentStore.digest(try files.read(output)) == target.fingerprints.first?.sha256 else { throw StoreError.sourceChanged }
        return output
    }

    private func cleanupTarget(_ relative: String, kind: CleanupTarget.Kind, record: MaterialRecord? = nil) throws -> CleanupTarget {
        let fingerprints = try cleanupFingerprints(paths.url(relative))
        var bytes: Int64 = 0
        for file in fingerprints where !file.directory {
            guard bytes <= Int64.max - file.bytes else { throw StoreError.budgetExceeded }
            bytes += file.bytes
        }
        return CleanupTarget(kind: kind, materialID: record?.id, title: record?.title ?? URL(fileURLWithPath: relative).lastPathComponent,
            relativePath: relative, byteCount: bytes, fileCount: fingerprints.filter { !$0.directory }.count, fingerprints: fingerprints)
    }

    private func cleanupFingerprints(_ root: URL) throws -> [CleanupFingerprint] {
        var result = [CleanupFingerprint]()
        func visit(_ url: URL, relative: String) throws {
            let info = try files.inspect(url)
            guard !info.isSymbolicLink else { throw StoreError.invalidPath }
            if info.isRegularFile {
                guard info.byteCount >= 0, info.byteCount <= budget.maxFileBytes else { throw StoreError.budgetExceeded }
                let digest = ContentStore.digest(try files.read(url))
                guard info == (try files.inspect(url)) else { throw StoreError.sourceChanged }
                result.append(.init(path: relative, directory: false, bytes: info.byteCount, modifiedAt: info.modificationDate, sha256: digest))
            } else {
                result.append(.init(path: relative, directory: true, bytes: 0, modifiedAt: info.modificationDate, sha256: nil))
                for child in try files.list(url).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    guard child.deletingLastPathComponent().standardizedFileURL.path == url.standardizedFileURL.path else { throw StoreError.invalidPath }
                    try visit(child, relative: relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent)
                }
                guard info == (try files.inspect(url)) else { throw StoreError.sourceChanged }
            }
        }
        try visit(root, relative: "")
        return result
    }
    public func createNoteDraft(for materialID: UUID? = nil) async throws -> NoteDraft {
        guard !busy else { throw StoreError.operationInProgress }
        let current = try ensureLoaded()
        let draft: NoteDraft
        if let materialID {
            guard let record = current.materials.first(where: { $0.id == materialID && $0.source.origin == .note && $0.kind == .text && $0.status != .trashed }) else { throw StoreError.invalidEdit }
            if let pending = try noteDrafts().first(where: { $0.materialID == materialID && $0.isPending }) { return pending }
            let url = try payloadURL(of: materialID)
            let bytes = try files.read(url)
            guard bytes.count <= ClipboardLimits.textBytes, let text = String(data: bytes, encoding: .utf8) else { throw StoreError.invalidEdit }
            draft = NoteDraft(materialID: materialID, matterID: record.matterID, baseVersionID: record.activeVersionID, text: text, publishedRevision: 0)
        } else {
            draft = NoteDraft(matterID: current.selectedMatterID)
        }
        try saveNoteDraft(draft)
        if materialID != nil { activeNoteMaterials.insert(draft.materialID) }
        return draft
    }
    public func updateNoteDraft(_ id: UUID, text: String) async throws -> NoteDraft {
        guard !busy else { throw StoreError.operationInProgress }
        _ = try ensureLoaded()
        guard text.utf8.count <= ClipboardLimits.textBytes else { throw StoreError.budgetExceeded }
        var draft = try readNoteDraft(id)
        if draft.text == text { return draft }
        guard draft.revision < UInt64.max - 1 else { throw StoreError.invalidEdit }
        draft.text = text; draft.revision += 1; draft.updatedAt = Date()
        try saveNoteDraft(draft)
        return draft
    }
    public func pendingNoteDrafts() async throws -> [NoteDraft] {
        guard !busy else { throw StoreError.operationInProgress }
        let current = try ensureLoaded()
        return try noteDrafts().filter { draft in
            draft.isPending && !current.materials.contains { $0.id == draft.materialID && $0.status == .trashed }
        }
    }
    public func publishNoteDraft(_ id: UUID, visibleCapacity: Int = 12) async throws -> WorkspaceSnapshot {
        guard !busy else { throw StoreError.operationInProgress }
        busy = true; defer { busy = false }
        let current = try ensureLoaded()
        var draft = try readNoteDraft(id)
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              current.matters.contains(where: { $0.id == draft.matterID }) else { throw StoreError.invalidSource }
        let title = String((draft.text.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "").trimmingCharacters(in: .whitespaces).prefix(80))
        let bytes = Data(draft.text.utf8), hash = ContentStore.digest(bytes)
        let existing = current.materials.first { $0.id == draft.materialID }
        if let existing {
            guard existing.kind == .text, existing.source.origin == .note, existing.status != .trashed else { throw StoreError.invalidEdit }
            _ = try payloadURL(of: existing.id)
            if existing.activeVersion?.sha256 != hash && existing.activeVersionID != draft.baseVersionID { throw StoreError.invalidEdit }
        } else if draft.baseVersionID != nil { throw StoreError.invalidEdit }
        let matterID = existing?.matterID ?? draft.matterID
        if existing?.status != .hanging && !ShelfPolicy.canAdmit(snapshot: current, matterID: matterID, capacity: visibleCapacity) { throw StoreError.budgetExceeded }
        var record: MaterialRecord
        var next = current
        var journalWritten = false
        do {
            if let existing, existing.activeVersion?.sha256 == hash {
                record = existing
                record.title = title
            } else {
                try checkBudget(bytes: Int64(bytes.count))
                let content = ContentStore(root: paths.root, files: files)
                let staged = try await content.stage(.text(draft.text, SourceRecord(origin: .note)))
                guard staged.byteCount == Int64(bytes.count), staged.sha256 == hash else { throw StoreError.sourceChanged }
                try Task.checkCancellation()
                let versionID = UUID(), transactionID = UUID()
                let version = MaterialVersion(id: versionID, relativePath: "Materials/" + draft.materialID.uuidString + "/" + versionID.uuidString + ".txt", sha256: hash, byteCount: Int64(bytes.count), kind: existing == nil ? .original : .textEdit)
                if let existing {
                    record = existing; record.versions.append(version); record.activeVersionID = versionID; record.title = title
                } else {
                    record = MaterialRecord(id: draft.materialID, kind: .text, matterID: matterID, title: title, source: SourceRecord(origin: .note), versions: [version], originalVersionID: versionID, activeVersionID: versionID)
                }
                var journal = StoreJournal(id: transactionID, phase: .contentReady, record: record, baseVersionID: existing?.activeVersionID)
                let journalURL = try paths.url("Transactions/" + transactionID.uuidString + ".json")
                try files.writeAtomic(JSONEncoder().encode(journal), to: journalURL); journalWritten = true
                _ = try content.commit(staged, materialID: draft.materialID, versionID: versionID)
                journal.phase = .contentCommitted
                try files.writeAtomic(JSONEncoder().encode(journal), to: journalURL)
            }
            if let index = next.materials.firstIndex(where: { $0.id == record.id }) { next.materials.remove(at: index) }
            if existing?.status == .hanging {
                next.materials.append(record)
            } else {
                let admission = ShelfPolicy.admit(record, snapshot: next, capacity: visibleCapacity)
                guard case .hanging = admission.disposition else { throw StoreError.budgetExceeded }
                next = admission.snapshot
            }
            let committed = next == current ? current : try persist(next)
            draft.baseVersionID = record.activeVersionID; draft.publishedRevision = draft.revision
            try saveNoteDraft(draft)
            activeNoteMaterials.remove(draft.materialID)
            return committed
        } catch {
            // Once a version transaction exists, retry must first reconcile it.
            // Never create a second card from the same durable draft UUID.
            if journalWritten { state = nil }
            throw error
        }
    }
    private func noteDrafts() throws -> [NoteDraft] {
        var drafts = [NoteDraft]()
        for directory in try files.list(paths.url("Drafts")) {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { throw StoreError.invalidPath }
            if try exists(paths.url("Drafts/" + id.uuidString + "/note.json")) { drafts.append(try readNoteDraft(id)) }
        }
        return drafts.sorted { $0.updatedAt > $1.updatedAt }
    }
    private func readNoteDraft(_ id: UUID) throws -> NoteDraft {
        let url = try paths.url("Drafts/" + id.uuidString + "/note.json")
        let info = try files.inspect(url)
        guard info.isRegularFile, !info.isSymbolicLink, info.byteCount <= Int64(ClipboardLimits.textBytes * 6 + 8192),
              let draft = try? JSONDecoder().decode(NoteDraft.self, from: files.read(url)), draft.id == id,
              draft.text.utf8.count <= ClipboardLimits.textBytes, draft.revision < UInt64.max,
              draft.publishedRevision.map({ $0 <= draft.revision }) ?? true else { throw StoreError.recoveryRequired }
        return draft
    }
    private func saveNoteDraft(_ draft: NoteDraft) throws {
        let bytes = try JSONEncoder().encode(draft)
        try checkBudget(bytes: Int64(bytes.count))
        try files.createDirectory(paths.url("Drafts/" + draft.id.uuidString))
        try files.writeAtomic(bytes, to: paths.url("Drafts/" + draft.id.uuidString + "/note.json"))
    }
    /// Separate bounded preferences preserve the existing workspace schema.
    public func clipboardPreferences() throws -> ClipboardPreference {
        _ = try ensureLoaded()
        let url = try paths.url("clipboard-settings.json")
        guard try exists(url) else {
            let setting = ClipboardPreference(enabled: loadedExistingWorkspace)
            try files.writeAtomic(JSONEncoder().encode(setting), to: url)
            return setting
        }
        let info = try files.inspect(url)
        guard info.isRegularFile, !info.isSymbolicLink, info.byteCount <= 4096,
              let setting = try? JSONDecoder().decode(ClipboardPreference.self, from: files.read(url)),
              setting.version == 2 else { throw StoreError.recoveryRequired }
        return setting
    }
    public func setClipboardPreferences(_ setting: ClipboardPreference) throws {
        guard setting.version == 2 else { throw StoreError.unsupportedSchema }
        _ = try clipboardPreferences() // Refuse corrupt or unknown settings rather than overwrite them.
        let url = try paths.url("clipboard-settings.json")
        if try exists(url) { try files.writeAtomic(files.read(url), to: paths.url("clipboard-settings.previous.json")) }
        try files.writeAtomic(JSONEncoder().encode(setting), to: url)
    }
    public func clipboardEnabled() throws -> Bool { try clipboardPreferences().enabled }
    public func setClipboardEnabled(_ enabled: Bool) throws {
        var setting = try clipboardPreferences(); setting.enabled = enabled
        try setClipboardPreferences(setting)
    }
    public func clipboardFileFingerprint(_ url: URL) throws -> ClipboardFileFingerprint {
        guard !busy else { throw StoreError.operationInProgress }
        _ = try ensureLoaded()
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { throw StoreError.invalidPath }
        let local = try url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal
        guard local == true else { throw StoreError.invalidPath }
        let before = try files.inspect(url)
        guard before.isRegularFile, !before.isSymbolicLink else { throw StoreError.invalidSource }
        guard before.byteCount >= 0, before.byteCount <= min(budget.maxFileBytes, Int64(ClipboardLimits.fileBytes)) else { throw StoreError.budgetExceeded }
        let data = try files.read(url)
        guard before == (try files.inspect(url)), before.byteCount == Int64(data.count) else { throw StoreError.sourceChanged }
        return ClipboardFileFingerprint(info: before, sha256: ContentStore.digest(data))
    }
    public func apply(_ command: MaterialCommand, visibleCapacity: Int = 12) async throws -> WorkspaceSnapshot {
        guard !busy else { throw StoreError.operationInProgress }
        var next = try ensureLoaded()
        switch command {
        case .setPrivacyHidden(let hidden):
            next.privacyHidden = hidden
        case .renameMaterial(let id, let title):
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 1024,
                  let index = next.materials.firstIndex(where: { $0.id == id && $0.status != .trashed }) else { throw StoreError.invalidSource }
            next.materials[index].title = title
        case .setSource(let id, let source):
            try SourceFormatter.validate(source)
            guard let index = next.materials.firstIndex(where: { $0.id == id && $0.status != .trashed }) else { throw StoreError.notFound }
            next.materials[index].source = source
        case .setCaptureFolder(let setting):
            if let setting {
                guard !setting.bookmark.isEmpty, setting.lastKnownPath.hasPrefix("/") else { throw StoreError.invalidPath }
            }
            next.captureFolder = setting
        case .takeDown(let id):
            guard let index = next.materials.firstIndex(where: { $0.id == id }), next.materials[index].status != .trashed else { throw StoreError.notFound }
            next.materials[index].status = .takenDown
        case .takeDownUnpinned(let matterID):
            for index in next.materials.indices where next.materials[index].matterID == matterID && next.materials[index].status == .hanging && !next.materials[index].pinned {
                next.materials[index].status = .takenDown
            }
        case .hang(let id):
            guard let index = next.materials.firstIndex(where: { $0.id == id }), next.materials[index].status != .trashed else { throw StoreError.notFound }
            if next.materials[index].status == .hanging { return next }
            let result = try rehang(next.materials[index], in: next, visibleCapacity: visibleCapacity)
            guard case .hanging = result.disposition else { throw StoreError.budgetExceeded }
            next = result.snapshot
        default: throw StoreError.invalidSource
        }
        return try persist(next)
    }
    public func createDerivedVersion(of id: UUID, kind: VersionKind) async throws -> EditSession {
        guard !busy else { throw StoreError.operationInProgress }
        let current = try ensureLoaded()
        guard let record = current.materials.first(where: { $0.id == id }),
              record.status != .trashed, kind != .original,
              (kind == .textEdit && record.kind == .text) || (kind == .markup && record.kind == .image) else { throw StoreError.invalidEdit }
        let source = try payloadURL(of: id)
        let info = try files.inspect(source)
        try checkBudget(bytes: info.byteCount)
        let sessionID = UUID(), directory = "Drafts/" + sessionID.uuidString
        try files.createDirectory(paths.url(directory))
        let working = try paths.url(directory + "/working." + source.pathExtension)
        try files.copy(source, to: working)
        guard ContentStore.digest(try files.read(working)) == record.activeVersion?.sha256 else { throw StoreError.sourceChanged }
        let session = EditSession(id: sessionID, materialID: id, baseVersionID: record.activeVersionID, workingURL: working, kind: kind)
        try files.writeAtomic(JSONEncoder().encode(session), to: paths.url(directory + "/session.json"))
        return session
    }
    public func finishEditing(_ session: EditSession, result: EditResult) async throws -> WorkspaceSnapshot {
        guard !busy else { throw StoreError.operationInProgress }
        busy = true; defer { busy = false }
        let current = try ensureLoaded(), directory = "Drafts/" + session.id.uuidString
        let metadata = try paths.url(directory + "/session.json")
        guard let saved = try? JSONDecoder().decode(EditSession.self, from: files.read(metadata)), saved == session,
              let index = current.materials.firstIndex(where: { $0.id == session.materialID }),
              current.materials[index].status != .trashed,
              current.materials[index].activeVersionID == session.baseVersionID else { throw StoreError.invalidEdit }
        let expected = try paths.url(directory + "/" + session.workingURL.lastPathComponent)
        guard expected.standardizedFileURL == session.workingURL.standardizedFileURL else { throw StoreError.invalidEdit }
        if case .cancel = result { return current } // Draft and session are retained for explicit recovery.
        guard case .save(let url) = result, url.standardizedFileURL == expected.standardizedFileURL else { throw StoreError.invalidEdit }
        let info = try files.inspect(expected)
        guard info.isRegularFile, !info.isSymbolicLink else { throw StoreError.invalidPath }
        try checkBudget(bytes: info.byteCount)
        let content = ContentStore(root: paths.root, files: files)
        let staged = try await content.stage(.file(expected, .fileSelection))
        guard (session.kind == .textEdit && staged.kind == .text) || (session.kind == .markup && staged.kind == .image) else { throw StoreError.invalidEdit }
        try Task.checkCancellation()
        let versionID = UUID(), transactionID = session.id
        let version = MaterialVersion(id: versionID, relativePath: "Materials/" + session.materialID.uuidString + "/" + versionID.uuidString + "." + staged.fileExtension,
                                      sha256: staged.sha256, byteCount: staged.byteCount, kind: session.kind)
        var next = current
        next.materials[index].versions.append(version); next.materials[index].activeVersionID = versionID
        var journal = StoreJournal(id: transactionID, phase: .contentReady, record: next.materials[index], baseVersionID: session.baseVersionID)
        let journalURL = try paths.url("Transactions/" + transactionID.uuidString + ".json")
        try files.writeAtomic(JSONEncoder().encode(journal), to: journalURL)
        _ = try content.commit(staged, materialID: session.materialID, versionID: versionID)
        journal.phase = .contentCommitted
        try files.writeAtomic(JSONEncoder().encode(journal), to: journalURL)
        return try persist(next)
    }
    public func exportCopy(of id: UUID, versionID: UUID? = nil, to destination: URL) async throws -> URL {
        guard !busy else { throw StoreError.operationInProgress }
        busy = true; defer { busy = false }
        let current = try ensureLoaded(), source = try payloadURL(of: id, versionID: versionID)
        guard destination.isFileURL else { throw StoreError.invalidPath }
        let target = destination.standardizedFileURL
        let exports = try paths.url("Exports").path + "/"
        let underRoot = target.path.hasPrefix(paths.root.path + "/")
        guard !underRoot || target.path.hasPrefix(exports),
              !current.materials.contains(where: { $0.source.filePath.map { URL(fileURLWithPath: $0).standardizedFileURL == target } ?? false }),
              target.resolvingSymlinksInPath().standardizedFileURL == target else { throw StoreError.invalidPath }
        guard !(try exists(target)) else { throw CocoaError(.fileWriteFileExists) }
        let info = try files.inspect(source)
        if underRoot {
            let relative = String(target.path.dropFirst(paths.root.path.count + 1))
            _ = try paths.url(relative)
            try files.createDirectory(target.deletingLastPathComponent())
        }
        try checkBudget(bytes: info.byteCount)
        try Task.checkCancellation()
        try files.copy(source, to: target) // Foundation refuses an existing destination.
        let copied = try files.inspect(target)
        guard copied.isRegularFile, !copied.isSymbolicLink, copied.byteCount == info.byteCount,
              ContentStore.digest(try files.read(target)) == ContentStore.digest(try files.read(source)) else { throw StoreError.sourceChanged }
        return target
    }
    public func writeEditingResult(_ session: EditSession, data: Data) async throws {
        guard !busy else { throw StoreError.operationInProgress }
        _ = try ensureLoaded()
        let directory = "Drafts/" + session.id.uuidString
        let metadata = try paths.url(directory + "/session.json")
        guard let saved = try? JSONDecoder().decode(EditSession.self, from: files.read(metadata)), saved == session else { throw StoreError.invalidEdit }
        let target = try paths.url(directory + "/" + session.workingURL.lastPathComponent)
        guard target.standardizedFileURL == session.workingURL.standardizedFileURL else { throw StoreError.invalidPath }
        let info = try files.inspect(target)
        guard info.isRegularFile, !info.isSymbolicLink, !data.isEmpty || session.kind == .textEdit else { throw StoreError.invalidPath }
        try checkBudget(bytes: Int64(data.count))
        try files.writeAtomic(data, to: target)
    }
    public func resumeEditingSession(_ session: EditSession) throws -> EditSession {
        guard !busy else { throw StoreError.operationInProgress }
        let current = try ensureLoaded()
        let metadata = try paths.url("Drafts/" + session.id.uuidString + "/session.json")
        guard let saved = try? JSONDecoder().decode(EditSession.self, from: files.read(metadata)), saved == session,
              let record = current.materials.first(where: { $0.id == session.materialID && $0.status != .trashed }),
              record.versions.contains(where: { $0.id == session.baseVersionID }),
              (session.kind == .textEdit && record.kind == .text) || (session.kind == .markup && record.kind == .image) else { throw StoreError.invalidEdit }
        let expected = try paths.url("Drafts/" + session.id.uuidString + "/" + session.workingURL.lastPathComponent)
        guard expected.standardizedFileURL == session.workingURL.standardizedFileURL else { throw StoreError.invalidEdit }
        let info = try files.inspect(expected)
        guard info.isRegularFile, !info.isSymbolicLink, info.byteCount >= 0, info.byteCount <= budget.maxFileBytes else { throw StoreError.invalidPath }
        _ = try payloadURL(of: record.id)
        if record.activeVersionID == session.baseVersionID { return session }
        // Explicit recovery must anchor the recovered base before the session's
        // next journal can replace its old recovery chain.
        _ = try persist(current)
        let rebased = EditSession(id: session.id, materialID: session.materialID, baseVersionID: record.activeVersionID, workingURL: expected, kind: session.kind)
        let bytes = try JSONEncoder().encode(rebased)
        try checkBudget(bytes: Int64(bytes.count))
        try files.writeAtomic(bytes, to: metadata)
        return rebased
    }
    public func pendingEditSessions() async throws -> [EditSession] {
        guard !busy else { throw StoreError.operationInProgress }
        let current = try ensureLoaded()
        var sessions = [EditSession]()
        for directory in try files.list(paths.url("Drafts")) {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { throw StoreError.invalidPath }
            let relative = "Drafts/" + id.uuidString
            let metadata = try paths.url(relative + "/session.json")
            if !(try exists(metadata)) { continue } // Incomplete copy remains accounted for, never deleted.
            let (session, disposition) = try editSessionDisposition(id, in: current)
            if case .pending = disposition { sessions.append(session) }
        }
        return sessions.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private enum EditSessionDisposition { case pending, completed }

    /// Completion needs this session's committed lineage, not only equal bytes.
    /// Unchanged active sessions and unreviewed crash recovery remain pending.
    private func editSessionDisposition(_ id: UUID, in current: WorkspaceSnapshot) throws -> (EditSession, EditSessionDisposition) {
        let folder = "Drafts/" + id.uuidString
        let metadata = try paths.url(folder + "/session.json")
        guard let session = try? JSONDecoder().decode(EditSession.self, from: files.read(metadata)),
              session.id == id, session.kind != .original,
              let record = current.materials.first(where: { $0.id == session.materialID }),
              let baseIndex = record.versions.firstIndex(where: { $0.id == session.baseVersionID }),
              (session.kind == .textEdit && record.kind == .text) || (session.kind == .markup && record.kind == .image) else { throw StoreError.recoveryRequired }
        let working = try paths.url(folder + "/" + session.workingURL.lastPathComponent)
        guard working == session.workingURL.standardizedFileURL,
              Set(try files.list(paths.url(folder)).map(\.lastPathComponent)) == ["session.json", working.lastPathComponent] else { throw StoreError.recoveryRequired }
        let info = try files.inspect(working)
        guard info.isRegularFile, !info.isSymbolicLink, info.byteCount >= 0, info.byteCount <= budget.maxFileBytes else { throw StoreError.invalidPath }
        if record.activeVersionID == session.baseVersionID || record.status == .needsReview { return (session, .pending) }
        let journalURL = try paths.url("Transactions/" + id.uuidString + ".json")
        guard try exists(journalURL) else { return (session, .pending) }
        guard let journal = try? JSONDecoder().decode(StoreJournal.self, from: files.read(journalURL)), journal.id == id else { throw StoreError.recoveryRequired }
        guard journal.record.id == record.id, journal.baseVersionID == session.baseVersionID,
              journal.record.originalVersionID == record.originalVersionID,
              let committed = journal.record.activeVersion,
              committed.kind == session.kind, baseIndex + 1 < record.versions.count,
              record.versions[baseIndex + 1] == committed else { return (session, .pending) }
        let workingDigest = ContentStore.digest(try files.read(working))
        guard info == (try files.inspect(working)) else { throw StoreError.sourceChanged }
        guard info.byteCount == committed.byteCount, workingDigest == committed.sha256 else { return (session, .pending) }
        let committedURL = try paths.url(committed.relativePath)
        if try exists(committedURL) {
            let committedInfo = try files.inspect(committedURL)
            guard committedInfo.isRegularFile, !committedInfo.isSymbolicLink,
                  committedInfo.byteCount == committed.byteCount,
                  ContentStore.digest(try files.read(committedURL)) == committed.sha256,
                  committedInfo == (try files.inspect(committedURL)) else { throw StoreError.recoveryRequired }
        } else {
            // A confirmed material cleanup may have already moved the versions;
            // its durable tombstone permits retrying the completed draft move.
            guard record.status == .trashed else { throw StoreError.recoveryRequired }
        }
        return (session, .completed)
    }
    /// Called only after an explicit recovery choice; damaged evidence is retained.
    public func restorePreviousSnapshot() async throws -> WorkspaceSnapshot {
        guard !busy, state == nil else { throw StoreError.operationInProgress }
        busy = true
        defer { busy = false }
        try prepareDirectories()
        let previousURL = try paths.url("state.previous.json")
        let previousInfo = try files.inspect(previousURL)
        guard previousInfo.isRegularFile, !previousInfo.isSymbolicLink,
              let previous = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: files.read(previousURL)) else { throw StoreError.recoveryRequired }
        try validate(previous)
        for record in previous.materials where record.status != .trashed {
            for version in record.versions {
                let payload = try paths.url(version.relativePath)
                let info = try files.inspect(payload)
                guard info.isRegularFile, !info.isSymbolicLink, info.byteCount == version.byteCount,
                      ContentStore.digest(try files.read(payload)) == version.sha256 else { throw StoreError.recoveryRequired }
            }
        }
        let current = try paths.url("state.json")
        if try exists(current) {
            let data = try files.read(current)
            if let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let schema = header["schemaVersion"] as? Int, schema != 1 { throw StoreError.unsupportedSchema }
            try files.move(current, to: paths.url("state.damaged." + UUID().uuidString + ".json"))
        }
        try files.copy(previousURL, to: current)
        return try ensureLoaded()
    }
    /// Batch the existing integrity checks on this actor. Each record retains its
    /// own result so one damaged payload does not hide unrelated valid cards.
    /// This is presentation-only; export boundaries still validate independently.
    public func presentationPayloads(for records: [MaterialRecord]) -> [UUID: Result<URL, Error>] {
        var results: [UUID: Result<URL, Error>] = [:]
        for record in records {
            results[record.id] = Result { try payloadURL(of: record.id, versionID: record.activeVersionID) }
        }
        return results
    }
    /// Read-only presentation URL. External actions must obtain an export or draft.
    public func payloadURL(of id: UUID, versionID: UUID? = nil) throws -> URL {
        let current = try ensureLoaded()
        guard let record = current.materials.first(where: { $0.id == id }), record.status != .trashed,
              let version = record.versions.first(where: { $0.id == (versionID ?? record.activeVersionID) }) else { throw StoreError.notFound }
        let url = try paths.url(version.relativePath)
        let info = try files.inspect(url)
        guard info.isRegularFile, !info.isSymbolicLink, info.byteCount == version.byteCount,
              info.byteCount <= budget.maxFileBytes,
              ContentStore.digest(try files.read(url)) == version.sha256 else { throw StoreError.recoveryRequired }
        return url
    }
    private func exists(_ url: URL) throws -> Bool {
        do { _ = try files.inspect(url); return true }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) { return false }
            throw error
        }
    }
    private func prepareDirectories() throws {
        try paths.verifyRoot()
        try files.createDirectory(paths.root)
        try paths.verifyRoot()
        for name in ["Materials", "Drafts", "Transactions", "Exports"] {
            try files.createDirectory(paths.url(name))
            _ = try paths.url(name)
        }
    }
    private func ensureLoaded() throws -> WorkspaceSnapshot {
        try paths.verifyRoot()
        if let state { return state }
        try prepareDirectories()
        var loaded = WorkspaceSnapshot()
        let current = try paths.url("state.json")
        let existedBeforeLoad = try exists(current)
        if try exists(current) {
            let info = try files.inspect(current)
            guard info.isRegularFile, !info.isSymbolicLink else { throw StoreError.invalidPath }
            let bytes = try files.read(current)
            guard let header = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], let schema = header["schemaVersion"] as? Int else { throw StoreError.recoveryRequired }
            guard schema == 1 else { throw StoreError.unsupportedSchema }
            guard let decoded = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: bytes) else { throw StoreError.recoveryRequired }
            loaded = decoded
        }
        if !(try exists(current)), try exists(paths.url("state.previous.json")) { throw StoreError.recoveryRequired }
        try validate(loaded)
        for journalURL in try files.list(paths.url("Transactions")) where journalURL.pathExtension == "json" {
            let owned = try paths.url("Transactions/" + journalURL.lastPathComponent)
            guard let journal = try? JSONDecoder().decode(StoreJournal.self, from: files.read(owned)) else { throw StoreError.recoveryRequired }
            guard journalURL.lastPathComponent == journal.id.uuidString + ".json" else { throw StoreError.invalidPath }
            if let index = loaded.materials.firstIndex(where: { $0.id == journal.record.id }) {
                let current = loaded.materials[index]
                if current.status == .trashed { continue }
                guard let base = journal.baseVersionID, current.activeVersionID == base,
                      !current.versions.contains(where: { $0.id == journal.record.activeVersionID }),
                      journal.record.originalVersionID == current.originalVersionID else { continue }
                try validateRecord(journal.record)
                let additions = journal.record.versions.filter { candidate in !current.versions.contains(where: { $0.id == candidate.id }) }
                var complete = true
                for version in additions {
                    if !(try exists(paths.url(version.relativePath))) { complete = false; break }
                    let info = try files.inspect(paths.url(version.relativePath))
                    guard info.isRegularFile, !info.isSymbolicLink, info.byteCount == version.byteCount,
                          ContentStore.digest(try files.read(paths.url(version.relativePath))) == version.sha256 else { throw StoreError.recoveryRequired }
                }
                if complete && !additions.isEmpty {
                    loaded.materials[index].versions += additions
                    loaded.materials[index].activeVersionID = journal.record.activeVersionID
                    loaded.materials[index].status = .needsReview
                }
                continue
            }
            if let version = journal.record.activeVersion, try exists(paths.url(version.relativePath)) {
                try validateRecord(journal.record)
                let payload = try files.read(paths.url(version.relativePath))
                guard ContentStore.digest(payload) == version.sha256 else { throw StoreError.recoveryRequired }
                var recovered = journal.record
                recovered.status = .needsReview
                loaded.materials.append(recovered)
            }
        }
        try validate(loaded)
        state = loaded
        loadedExistingWorkspace = existedBeforeLoad
        return loaded
    }
    private func validateRecord(_ record: MaterialRecord) throws {
        guard !record.versions.isEmpty, Set(record.versions.map(\.id)).count == record.versions.count,
              record.versions.contains(where: { $0.id == record.originalVersionID && $0.kind == .original }),
              record.activeVersion != nil, record.order >= 0 else { throw StoreError.invalidSnapshot }
        if case .pdfIndex(let index) = record.source.locator, index < 0 { throw StoreError.invalidSnapshot }
        for version in record.versions {
            let parent = "Materials/" + record.id.uuidString
            guard version.relativePath.hasPrefix(parent + "/"),
                  URL(fileURLWithPath: version.relativePath).deletingLastPathComponent().lastPathComponent == record.id.uuidString,
                  URL(fileURLWithPath: version.relativePath).lastPathComponent.hasPrefix(version.id.uuidString + "."),
                  version.byteCount >= 0, version.sha256.count == 64,
                  version.sha256.allSatisfy({ $0.isHexDigit }) else { throw StoreError.invalidSnapshot }
            _ = try paths.url(version.relativePath)
        }
    }
    private func validate(_ snapshot: WorkspaceSnapshot) throws {
        guard snapshot.schemaVersion == 1, snapshot.generation < UInt64.max,
              Set(snapshot.matters.map(\.id)).count == snapshot.matters.count,
              Set(snapshot.materials.map(\.id)).count == snapshot.materials.count,
              snapshot.matters.contains(where: { $0.id == snapshot.selectedMatterID }),
              snapshot.matters.contains(where: { $0.id == MatterGroup.ungroupedID }) else { throw StoreError.invalidSnapshot }
        for record in snapshot.materials {
            guard snapshot.matters.contains(where: { $0.id == record.matterID }) else { throw StoreError.invalidSnapshot }
            try validateRecord(record)
        }
    }
    private func retainedBytes(_ folder: String) throws -> Int64 {
        var total: Int64 = 0
        for child in try files.list(paths.url(folder)) {
            let relative = folder + "/" + child.lastPathComponent
            let owned = try paths.url(relative)
            let info = try files.inspect(owned)
            guard !info.isSymbolicLink else { throw StoreError.invalidPath }
            let count = info.isRegularFile ? info.byteCount : try retainedBytes(relative)
            guard count >= 0, total <= Int64.max - count else { throw StoreError.budgetExceeded }
            total += count
        }
        return total
    }
    private func checkBudget(bytes: Int64) throws {
        guard bytes >= 0, bytes <= budget.maxFileBytes, budget.minimumFreeBytes >= 0,
              budget.maxMaterialBytes >= bytes else { throw StoreError.budgetExceeded }
        var used: Int64 = 0
        for directory in ["Materials", "Drafts", "Exports"] {
            let count = try retainedBytes(directory)
            guard used <= Int64.max - count else { throw StoreError.budgetExceeded }
            used += count
        }
        // Keep failed staging bytes charged; evidence is never silently removed.
        for candidate in try files.list(paths.url("Transactions")) where candidate.pathExtension == "stage" {
            let info = try files.inspect(paths.url("Transactions/" + candidate.lastPathComponent))
            guard info.isRegularFile, !info.isSymbolicLink, used <= Int64.max - info.byteCount else { throw StoreError.invalidPath }
            used += info.byteCount
        }
        guard used <= budget.maxMaterialBytes - bytes,
              bytes <= Int64.max - budget.minimumFreeBytes,
              try files.availableBytes(at: paths.root) >= bytes + budget.minimumFreeBytes else { throw StoreError.budgetExceeded }
    }
    private func payloadInfo(_ request: ImportRequest) throws -> (Int64, String, SourceRecord) {
        switch request {
        case let .file(url, origin):
            let before = try files.inspect(url)
            guard url.isFileURL, before.isRegularFile, !before.isSymbolicLink, before.byteCount <= budget.maxFileBytes else { throw StoreError.invalidSource }
            let data = try files.read(url)
            guard before == (try files.inspect(url)), Int64(data.count) == before.byteCount else { throw StoreError.sourceChanged }
            return (before.byteCount, ContentStore.digest(data), SourceRecord(origin: origin, filePath: url.standardizedFileURL.path))
        case let .imageData(data, source): return (Int64(data.count), ContentStore.digest(data), source)
        case let .text(text, source):
            let data = Data(text.utf8)
            return (Int64(data.count), ContentStore.digest(data), source)
        }
    }
    private func rehang(_ record: MaterialRecord, in current: WorkspaceSnapshot, visibleCapacity: Int) throws -> ImportResult {
        _ = try payloadURL(of: record.id)
        var next = current
        next.materials.removeAll { $0.id == record.id }
        let result = ShelfPolicy.admit(record, snapshot: next, capacity: visibleCapacity)
        // Failed admission must leave the retained record in history.
        guard case .hanging = result.disposition else { return ImportResult(disposition: .shelfFull, snapshot: current) }
        return result
    }
    public func importMaterial(_ request: ImportRequest, into matterID: UUID, visibleCapacity: Int, deduplicateClipboardContent: Bool = false, expectedClipboardFile: ClipboardFileFingerprint? = nil, duplicatePolicy: DuplicateImportPolicy = .keepExisting) async throws -> ImportResult {
        guard !busy else { throw StoreError.operationInProgress }
        busy = true
        defer { busy = false }
        let current = try ensureLoaded()
        let (bytes, hash, source) = try payloadInfo(request)
        if let expected = expectedClipboardFile {
            guard case .file(let url, let origin) = request, [.clipboard, .drop, .fileSelection].contains(origin), bytes == expected.info.byteCount,
                  hash == expected.sha256, try files.inspect(url) == expected.info else { throw StoreError.sourceChanged }
        }
        let manualDuplicate: Bool
        if case .rehangTakenDown = duplicatePolicy { manualDuplicate = [.clipboard, .drop, .fileSelection].contains(source.origin) }
        else { manualDuplicate = false }
        if let duplicate = current.materials.first(where: { record in
            let sameSource = record.source == source || (record.source.origin != .note && (manualDuplicate || (deduplicateClipboardContent && source.origin == .clipboard)) &&
                (source.filePath.map { $0 == record.source.filePath } ?? (record.kind == .image || record.kind == .text)))
            return record.matterID == matterID && sameSource && record.status != .trashed && record.versions.first(where: { $0.kind == .original })?.sha256 == hash
        }) {
            if case .rehangTakenDown = duplicatePolicy, duplicate.status == .takenDown {
                let result = try rehang(duplicate, in: current, visibleCapacity: visibleCapacity)
                guard case .hanging = result.disposition else { return result }
                return ImportResult(disposition: result.disposition, snapshot: try persist(result.snapshot))
            }
            return ImportResult(disposition: .duplicate(duplicate.id), snapshot: current)
        }
        guard ShelfPolicy.canAdmit(snapshot: current, matterID: matterID, capacity: visibleCapacity) else { return ImportResult(disposition: .shelfFull, snapshot: current) }
        try checkBudget(bytes: bytes)
        let content = ContentStore(root: paths.root, files: files)
        let staged = try await content.stage(request)
        guard staged.byteCount == bytes, staged.sha256 == hash else { throw StoreError.sourceChanged }
        try Task.checkCancellation()
        let materialID = UUID(), versionID = UUID(), transactionID = UUID()
        let relative = "Materials/" + materialID.uuidString + "/" + versionID.uuidString + "." + staged.fileExtension
        let version = MaterialVersion(id: versionID, relativePath: relative, sha256: hash, byteCount: bytes, kind: .original)
        let record = MaterialRecord(id: materialID, kind: staged.kind, matterID: matterID, title: staged.title, source: staged.source, versions: [version], originalVersionID: versionID, activeVersionID: versionID)
        var journal = StoreJournal(id: transactionID, phase: .contentReady, record: record)
        let journalURL = try paths.url("Transactions/" + transactionID.uuidString + ".json")
        try files.writeAtomic(JSONEncoder().encode(journal), to: journalURL)
        do {
            _ = try content.commit(staged, materialID: materialID, versionID: versionID)
            journal.phase = .contentCommitted
            try files.writeAtomic(JSONEncoder().encode(journal), to: journalURL)
            let admission = ShelfPolicy.admit(record, snapshot: current, capacity: visibleCapacity)
            guard case .hanging = admission.disposition else { throw StoreError.recoveryRequired }
            let committed = try persist(admission.snapshot)
            return ImportResult(disposition: admission.disposition, snapshot: committed)
        } catch {
            // A durable transaction may already own the input. Reconcile it
            // before retry can create another material UUID.
            state = nil
            throw error
        }
    }
    private func persist(_ snapshot: WorkspaceSnapshot) throws -> WorkspaceSnapshot {
        var next = snapshot
        next.generation = (state?.generation ?? 0) + 1
        try validate(next)
        let currentURL = try paths.url("state.json")
        if try exists(currentURL) { try files.writeAtomic(files.read(currentURL), to: paths.url("state.previous.json")) }
        try files.writeAtomic(JSONEncoder().encode(next), to: currentURL)
        state = next
        return next
    }
}
