import AppKit
import InkpegCore

/// Minimal P1 recovery; ordinary history and matter management belong to P2.
@MainActor
final class WorkflowRecoveryController: NSObject, NSWindowDelegate {
    private let line: Line
    private let actions: MaterialActions
    private var window: NSWindow?
    private(set) var hasDrafts = false
    var onError: (Error) -> Void = { _ in }
    var onResumeText: (EditSession) -> Void = { _ in }
    var onResumeNote: (NoteDraft) -> Void = { _ in }
    init(line: Line, actions: MaterialActions) { self.line = line; self.actions = actions }
    func prepareMarkupRecovery(_ session: EditSession) async throws -> EditSession {
        guard !line.snapshot.privacyHidden, session.kind == .markup else { throw StoreError.invalidEdit }
        let recovered = try await line.store.resumeEditingSession(session)
        guard !line.snapshot.privacyHidden else { throw StoreError.invalidEdit }
        return recovered
    }
    func refresh(showIfNeeded: Bool = false) async {
        do {
            let edits = try await line.store.pendingEditSessions(), notes = try await line.store.pendingNoteDrafts()
            hasDrafts = !edits.isEmpty || !notes.isEmpty
            if showIfNeeded && line.snapshot.materials.contains(where: { $0.status == .needsReview }) { await show() }
        } catch { onError(error) }
    }
    func show() async {
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
                    guard let self else { return }; Task { do { try await self.actions.open(record.id) } catch { self.onError(error) } }
                })
                row.addArrangedSubview(ActionButton(title: L(.hangReviewed)) { [weak self] in
                    guard let self else { return }; Task {
                        do { await self.line.render(try await self.line.store.apply(.hang(record.id), visibleCapacity: self.line.maxItems)); await self.show() }
                        catch { self.onError(error) }
                    }
                })
                stack.addArrangedSubview(row)
            }
            for session in sessions {
                let row = NSStackView(); row.orientation = .horizontal; row.spacing = 10
                row.addArrangedSubview(NSTextField(labelWithString: L(.retainedDraft)))
                row.addArrangedSubview(ActionButton(title: L(.resumeDraft)) { [weak self] in
                    guard let self, !self.line.snapshot.privacyHidden else { return }
                    if session.kind == .textEdit { self.onResumeText(session); return }
                    Task { [self] in
                        do {
                            let recovered = try await self.prepareMarkupRecovery(session)
                            Markup.shared.edit(recovered, store: self.line.store) { [weak self] result in
                                guard let self else { return }; Task {
                                    do { await self.line.render(try await self.line.store.finishEditing(recovered, result: result)); await self.show() }
                                    catch { self.onError(error) }
                                }
                            }
                        } catch { self.onError(error) }
                    }
                })
                stack.addArrangedSubview(row)
            }
            for draft in notes {
                let row = NSStackView(); row.orientation = .horizontal
                row.addArrangedSubview(NSTextField(labelWithString: L(.noteTitle) + " · " + L(.retainedDraft)))
                row.addArrangedSubview(ActionButton(title: L(.resumeDraft)) { [weak self] in
                    guard let self, !self.line.snapshot.privacyHidden else { return }; self.onResumeNote(draft)
                })
                stack.addArrangedSubview(row)
            }
            if let window { window.close() }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 380), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = L(.reviewPendingTitle); window.isReleasedWhenClosed = false; window.delegate = self
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = stack
            stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
            window.contentView = scroll; window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true); self.window = window
        } catch { onError(error) }
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
