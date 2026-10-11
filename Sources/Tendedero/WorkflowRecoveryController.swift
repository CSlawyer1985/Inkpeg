import AppKit
import Combine
import InkpegCore

/// Draft recovery and a small, read-only list of retained taken-down materials.
@MainActor
final class WorkflowRecoveryController: NSObject, NSWindowDelegate {
    private let line: Line
    private let actions: MaterialActions
    private let markup: Markup
    private(set) var window: NSWindow?
    private(set) var exportPanel: NSSavePanel?
    private(set) var recentWindow: NSWindow?
    private var recentMatterID: UUID?
    private var snapshotObserver: AnyCancellable?
    private var undoIDs: [UUID] = []
    private var undoDeadline = Date.distantPast
    private var undoToken = UUID()
    private(set) var hasDrafts = false
    var onError: (Error) -> Void = { _ in }
    var onResumeText: (EditSession) -> Void = { _ in }
    var onResumeNote: (NoteDraft) -> Void = { _ in }
    init(line: Line, actions: MaterialActions, markup: Markup? = nil) {
        self.line = line; self.actions = actions; self.markup = markup ?? .shared
        super.init()
        snapshotObserver = line.$snapshot.sink { [weak self] snapshot in
            guard let self else { return }
            if snapshot.privacyHidden {
                for window in [self.window, self.recentWindow].compactMap({ $0 }) {
                    window.orderOut(nil); window.title = L(.contentHidden)
                    window.contentView = privacyPlaceholder(in: window)
                }
                self.window = nil; self.recentWindow = nil
                self.exportPanel?.cancel(nil)
                self.undoIDs = []
                if self.line.inputFeedback == L(.takeDownUndoFeedback) { self.line.inputFeedback = "" }
            } else if let window = self.recentWindow, window.isVisible {
                self.updateTakenDownContent(window, snapshot: snapshot)
            }
        }
    }
    var takenDownRecords: [MaterialRecord] { takenDownRecords(in: line.snapshot) }
    private func takenDownRecords(in snapshot: WorkspaceSnapshot) -> [MaterialRecord] {
        guard !snapshot.privacyHidden else { return [] }
        return snapshot.materials.filter { $0.status == .takenDown && $0.matterID == snapshot.selectedMatterID }.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    func showTakenDown() async {
        let epoch = line.privacyEpoch
        guard line.permitsPresentation(epoch) else { return }
        do {
            var snapshot = try await line.store.load()
            guard line.permitsPresentation(epoch) else { return }
            snapshot.privacyHidden = snapshot.privacyHidden || line.snapshot.privacyHidden
            await line.render(snapshot)
            guard line.permitsPresentation(epoch) else { return }
            let window = recentWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 380), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = L(.takenDownMaterials); window.isReleasedWhenClosed = false
            updateTakenDownContent(window, snapshot: line.snapshot)
            window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true); recentWindow = window
        } catch { onError(error) }
    }
    private func updateTakenDownContent(_ window: NSWindow, snapshot: WorkspaceSnapshot) {
        var distanceFromTop: CGFloat = 0
        if recentMatterID == snapshot.selectedMatterID,
           let previous = window.contentView as? NSScrollView, let document = previous.documentView {
            distanceFromTop = max(0, document.bounds.maxY - previous.documentVisibleRect.maxY)
        }
        let scroll = takenDownContent(snapshot)
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
        if let document = scroll.documentView {
            document.layoutSubtreeIfNeeded()
            let top = document.bounds.maxY - scroll.contentView.bounds.height
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(document.bounds.minY, top - distanceFromTop)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        recentMatterID = snapshot.selectedMatterID
    }
    private func takenDownContent(_ snapshot: WorkspaceSnapshot) -> NSScrollView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: L(.takenDownHelp)))
        let records = takenDownRecords(in: snapshot)
        if records.isEmpty { stack.addArrangedSubview(NSTextField(labelWithString: L(.takenDownEmpty))) }
        for record in records {
            let type: MessageKey
            switch record.kind { case .text: type = .inputText; case .image: type = .inputImages; case .file: type = .inputFiles; case .pdf: type = .materialPDF }
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 10
            row.addArrangedSubview(NSTextField(wrappingLabelWithString: String(record.title.prefix(100)) + " · " + L(type)))
            row.addArrangedSubview(ActionButton(title: L(.rehangMaterial)) { [weak self] in
                guard let self else { return }
                Task { do { try await self.rehang(record.id) } catch { self.onError(error) } }
            })
            stack.addArrangedSubview(row)
        }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        return scroll
    }
    func rehang(_ id: UUID) async throws {
        guard !line.snapshot.privacyHidden else { return }
        let snapshot = try await line.store.load()
        guard !line.snapshot.privacyHidden, !snapshot.privacyHidden,
              snapshot.materials.contains(where: { $0.id == id && [.takenDown, .archived].contains($0.status) }) else { return }
        var next = try await line.store.apply(.hang(id), visibleCapacity: line.maxItems)
        next.privacyHidden = next.privacyHidden || line.snapshot.privacyHidden
        await line.render(next)
        guard !line.snapshot.privacyHidden else { return }
        line.inputFeedback = L(.inputSaved)
    }
    func noteTakenDown(_ ids: [UUID], at now: Date = Date()) {
        guard !line.snapshot.privacyHidden, !ids.isEmpty else { return }
        undoIDs = ids; undoDeadline = now.addingTimeInterval(8); undoToken = UUID()
        let token = undoToken
        line.inputFeedback = L(.takeDownUndoFeedback)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.undoToken == token else { return }
            self.undoIDs = []
            if self.line.inputFeedback == L(.takeDownUndoFeedback) { self.line.inputFeedback = "" }
        }
    }
    func canUndoTakeDown(at now: Date = Date()) -> Bool {
        !line.snapshot.privacyHidden && now < undoDeadline && undoIDs.contains { id in line.snapshot.materials.contains { $0.id == id && $0.status == .takenDown } }
    }
    func undoTakeDown(at now: Date = Date()) async throws {
        guard canUndoTakeDown(at: now) else { return }
        for id in undoIDs {
            try await rehang(id)
            undoIDs.removeAll { $0 == id }
        }
    }
    func prepareMarkupRecovery(_ session: EditSession) async throws -> EditSession {
        let epoch = line.privacyEpoch
        guard line.permitsPresentation(epoch), session.kind == .markup else { throw StoreError.invalidEdit }
        let recovered = try await line.store.resumeEditingSession(session)
        guard line.permitsPresentation(epoch) else { throw StoreError.invalidEdit }
        return recovered
    }
    func refresh(showIfNeeded: Bool = false) async {
        let epoch = line.privacyEpoch
        do {
            let edits = try await line.store.pendingEditSessions(), notes = try await line.store.pendingNoteDrafts()
            let staging = try await line.store.stagingRecoveryInventory()
            hasDrafts = !edits.isEmpty || !notes.isEmpty || !staging.isEmpty
            if showIfNeeded && (!staging.isEmpty || line.snapshot.materials.contains(where: { $0.status == .needsReview })) { await show(privacyEpoch: epoch) }
        } catch { if line.permitsPresentation(epoch) { onError(error) } }
    }
    private func exportStaging(_ relativePath: String) async {
        let epoch = line.privacyEpoch
        guard line.permitsPresentation(epoch) else { return }
        do {
            let plan = try await line.store.previewStorageCleanup()
            guard line.permitsPresentation(epoch), let target = plan.targets.first(where: { $0.kind == .unownedStaging && $0.relativePath == relativePath }) else { throw StoreError.sourceChanged }
            let panel = NSSavePanel(); exportPanel = panel
            defer { exportPanel = nil }
            panel.nameFieldStringValue = target.title
            guard line.runModal(panel, operation: { panel.runModal() }) == .OK, let destination = panel.url, !line.snapshot.privacyHidden else { return }
            _ = try await line.store.exportStagingCopy(target, from: plan, to: destination)
            guard line.permitsPresentation(epoch) else { return }
            line.inputFeedback = L(.stagingExportDone)
        } catch { onError(error) }
    }
    func show(privacyEpoch: Int? = nil) async {
        let epoch = privacyEpoch ?? line.privacyEpoch
        guard line.permitsPresentation(epoch) else { return }
        do {
            let sessions = try await line.store.pendingEditSessions()
            let notes = try await line.store.pendingNoteDrafts()
            let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
            stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
            stack.addArrangedSubview(NSTextField(wrappingLabelWithString: L(.reviewPendingMessage)))
            for record in line.snapshot.materials where record.status == .needsReview {
                let title = line.snapshot.privacyHidden ? L(.recoveryTitle) : record.title
                let row = NSStackView(); row.orientation = .horizontal; row.spacing = 10
                row.addArrangedSubview(NSTextField(labelWithString: String(title.prefix(100))))
                row.addArrangedSubview(ActionButton(title: L(.open)) { [weak self] in
                    guard let self, self.line.permitsPresentation(epoch) else { return }
                    Task {
                        guard self.line.permitsPresentation(epoch) else { return }
                        do { try await self.actions.open(record.id) }
                        catch { if self.line.permitsPresentation(epoch) { self.onError(error) } }
                    }
                })
                row.addArrangedSubview(ActionButton(title: L(.hangReviewed)) { [weak self] in
                    guard let self, self.line.permitsPresentation(epoch) else { return }
                    Task {
                        guard self.line.permitsPresentation(epoch) else { return }
                        do {
                            let next = try await self.line.store.apply(.hang(record.id), visibleCapacity: self.line.maxItems)
                            guard self.line.permitsPresentation(epoch) else { return }
                            await self.line.render(next)
                            await self.show(privacyEpoch: epoch)
                        } catch { if self.line.permitsPresentation(epoch) { self.onError(error) } }
                    }
                })
                stack.addArrangedSubview(row)
            }
            for session in sessions {
                let row = NSStackView(); row.orientation = .horizontal; row.spacing = 10
                row.addArrangedSubview(NSTextField(labelWithString: L(.retainedDraft)))
                row.addArrangedSubview(ActionButton(title: L(.resumeDraft)) { [weak self] in
                    guard let self, self.line.permitsPresentation(epoch) else { return }
                    if session.kind == .textEdit { self.onResumeText(session); return }
                    Task { [self] in
                        guard self.line.permitsPresentation(epoch) else { return }
                        do {
                            let recovered = try await self.prepareMarkupRecovery(session)
                            guard self.line.permitsPresentation(epoch) else { return }
                            self.markup.edit(recovered, store: self.line.store) { [weak self] result in
                                guard let self else { return }; Task {
                                    do {
                                        // Finish the accepted result even if privacy changed; only
                                        // its presentation is revoked, never the saved version.
                                        let next = try await self.line.store.finishEditing(recovered, result: result)
                                        guard self.line.permitsPresentation(epoch) else { return }
                                        await self.line.render(next)
                                        await self.show(privacyEpoch: epoch)
                                    } catch { if self.line.permitsPresentation(epoch) { self.onError(error) } }
                                }
                            }
                        } catch { if self.line.permitsPresentation(epoch) { self.onError(error) } }
                    }
                })
                stack.addArrangedSubview(row)
            }
            for draft in notes {
                let row = NSStackView(); row.orientation = .horizontal
                row.addArrangedSubview(NSTextField(labelWithString: L(.noteTitle) + " · " + L(.retainedDraft)))
                row.addArrangedSubview(ActionButton(title: L(.resumeDraft)) { [weak self] in
                    guard let self, self.line.permitsPresentation(epoch) else { return }; self.onResumeNote(draft)
                })
                stack.addArrangedSubview(row)
            }
            if !line.snapshot.privacyHidden {
                let staging = try await line.store.stagingRecoveryInventory()
                if !line.snapshot.privacyHidden && !staging.isEmpty {
                    stack.addArrangedSubview(NSTextField(wrappingLabelWithString: L(.stagingHelp)))
                    for item in staging {
                        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 10
                        let key: MessageKey = item.disposition == .unowned ? .stagingTitle : item.disposition == .referenced ? .stagingReferenced : .stagingInspect
                        let title = L(key) + (item.byteCount.map { " · " + IntakeSettingsModel.size($0) } ?? "")
                        row.addArrangedSubview(NSTextField(wrappingLabelWithString: title))
                        if item.disposition == .unowned {
                            row.addArrangedSubview(ActionButton(title: L(.stagingExport)) { [weak self] in
                                guard let self, self.line.permitsPresentation(epoch) else { return }
                                Task {
                                    guard self.line.permitsPresentation(epoch) else { return }
                                    await self.exportStaging(item.relativePath)
                                }
                            })
                        }
                        stack.addArrangedSubview(row)
                    }
                    stack.addArrangedSubview(ActionButton(title: L(.cleanupPreview)) { [weak self] in
                        guard let self, self.line.permitsPresentation(epoch) else { return }
                        self.line.onOpenIntakeSettings()
                    })
                }
            }
            guard line.permitsPresentation(epoch) else { return }
            if let window { window.close() }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 380), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = L(.reviewPendingTitle); window.isReleasedWhenClosed = false; window.delegate = self
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = stack
            stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
            window.contentView = scroll; window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true); self.window = window
        } catch { if line.permitsPresentation(epoch) { onError(error) } }
    }
}

@MainActor
final class ActionButton: NSButton {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler; super.init(frame: .zero)
        self.title = title; bezelStyle = .rounded; target = self; action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { handler() }
}
