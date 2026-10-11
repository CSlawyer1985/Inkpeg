import AppKit
import InkpegCore
import Combine

@MainActor final class TextEditorController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private let line: Line
    var text: String {
        get { textView.string }
        set { if textView.string != newValue { textView.string = newValue } }
    }
    private(set) var session: EditSession?
    var isEditing: Bool { session != nil || opening }
    private var opening = false
    private(set) var window: NSWindow?
    let textView = NSTextView()
    private var saving = false
    private var subscription: AnyCancellable?
    private var content: NSView?
    private var hiddenLabel: NSTextField?
    var onError: (Error) -> Void = { _ in }
    init(line: Line) {
        self.line = line; super.init()
        subscription = line.$snapshot.map(\.privacyHidden).removeDuplicates().sink { [weak self] hidden in self?.setHidden(hidden) }
    }
    func open(_ id: UUID, present: Bool = true) async throws {
        let epoch = line.privacyEpoch
        guard !isEditing, !line.snapshot.privacyHidden,
              let record = line.snapshot.materials.first(where: { $0.id == id && $0.kind == .text }),
              let version = record.activeVersion, version.byteCount <= ClipboardLimits.textBytes else { throw StoreError.invalidEdit }
        opening = true; defer { opening = false }
        let session = try await line.store.createDerivedVersion(of: id, kind: .textEdit)
        try await install(session, present: present, epoch: epoch)
    }
    func resume(_ session: EditSession, present: Bool = true) async throws {
        let epoch = line.privacyEpoch
        guard !isEditing, !line.snapshot.privacyHidden else { throw StoreError.invalidEdit }
        opening = true; defer { opening = false }
        let recovered = try await line.store.resumeEditingSession(session)
        try await install(recovered, present: present, epoch: epoch, recoveredOlderVersion: recovered.baseVersionID != session.baseVersionID)
    }
    private func install(_ session: EditSession, present: Bool, epoch: Int, recoveredOlderVersion: Bool = false) async throws {
        guard self.session == nil, line.permitsPresentation(epoch), session.kind == .textEdit,
              try await line.store.pendingEditSessions().contains(session) else { throw StoreError.invalidEdit }
        let data = try Data(contentsOf: session.workingURL)
        guard data.count <= ClipboardLimits.textBytes, let text = String(data: data, encoding: .utf8), line.permitsPresentation(epoch) else { throw StoreError.invalidEdit }
        textView.undoManager?.removeAllActions()
        self.session = session; self.text = text
        buildWindow(recoveredOlderVersion: recoveredOlderVersion); setHidden(line.snapshot.privacyHidden)
        if present { window?.center(); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(textView); NSApp.activate(ignoringOtherApps: true) }
    }
    func save() async throws {
        guard let session, !saving, !line.snapshot.privacyHidden else { throw StoreError.invalidEdit }
        guard !textView.hasMarkedText() else { throw StoreError.operationInProgress }
        saving = true; textView.isEditable = false
        defer { saving = false; textView.isEditable = !line.snapshot.privacyHidden }
        try await line.store.writeEditingResult(session, data: Data(text.utf8))
        var snapshot = try await line.store.finishEditing(session, result: .save(session.workingURL))
        snapshot.privacyHidden = line.snapshot.privacyHidden
        await line.render(snapshot); textView.undoManager?.removeAllActions()
        self.session = nil; window?.close(); window = nil
    }
    func cancel() async throws {
        guard let session, !saving else { throw StoreError.invalidEdit }
        guard !textView.hasMarkedText() else { throw StoreError.operationInProgress }
        saving = true; textView.isEditable = false
        defer { saving = false; textView.isEditable = !line.snapshot.privacyHidden }
        try await line.store.writeEditingResult(session, data: Data(text.utf8))
        _ = try await line.store.finishEditing(session, result: .cancel)
        textView.undoManager?.removeAllActions()
        self.session = nil; window?.close(); window = nil
    }
    func textDidChange(_ notification: Notification) { text = textView.string }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if session == nil { return true }
        Task { do { try await cancel() } catch { onError(error) } }; return false
    }
    func setHidden(_ hidden: Bool) {
        content?.isHidden = hidden; content?.setAccessibilityHidden(hidden); hiddenLabel?.isHidden = !hidden
        window?.representedURL = nil
        if hidden { window?.makeFirstResponder(nil) }
        textView.isSelectable = !hidden
        textView.isEditable = !hidden && !saving
        window?.title = L(hidden ? .contentHidden : .textEditorTitle)
    }
    private func buildWindow(recoveredOlderVersion: Bool = false) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.delegate = self; window.minSize = NSSize(width: 420, height: 300)
        PanelAppearance.configure(window)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.backgroundColor = PanelAppearance.paper
        textView.isRichText = false; textView.allowsUndo = true; textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        PanelAppearance.editor(textView)
        textView.delegate = self; textView.string = text; scroll.documentView = textView
        let save = ActionButton(title: L(.saveCopy)) { [weak self] in self?.perform { try await $0.save() } }
        PanelAppearance.primary(save)
        let buttons = NSStackView(views: [ActionButton(title: L(.cancel)) { [weak self] in self?.perform { try await $0.cancel() } }, save])
        buttons.orientation = .horizontal; buttons.spacing = 12
        let help = NSTextField(wrappingLabelWithString: L(recoveredOlderVersion ? .textRecoveryChanged : .textEditorHelp))
        PanelAppearance.secondary(help)
        let base = PanelSurface(), body = NSView(), footer = NSView(), label = NSTextField(labelWithString: L(.contentHidden))
        PanelAppearance.secondary(label)
        let rule = NSBox(); rule.boxType = .separator
        base.addSubview(body); base.addSubview(label)
        body.addSubview(help); body.addSubview(scroll); body.addSubview(footer)
        footer.addSubview(rule); footer.addSubview(buttons)
        for v in [body, label, help, scroll, footer, rule, buttons] { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: base.leadingAnchor), body.trailingAnchor.constraint(equalTo: base.trailingAnchor),
            body.topAnchor.constraint(equalTo: base.topAnchor), body.bottomAnchor.constraint(equalTo: base.bottomAnchor),
            help.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 24), help.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24), help.topAnchor.constraint(equalTo: body.topAnchor, constant: 20),
            scroll.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 16), scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: body.leadingAnchor), footer.trailingAnchor.constraint(equalTo: body.trailingAnchor), footer.bottomAnchor.constraint(equalTo: body.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: PanelAppearance.footerHeight),
            rule.topAnchor.constraint(equalTo: footer.topAnchor), rule.leadingAnchor.constraint(equalTo: footer.leadingAnchor), rule.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24), buttons.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            label.centerXAnchor.constraint(equalTo: base.centerXAnchor), label.centerYAnchor.constraint(equalTo: base.centerYAnchor)
        ])
        window.contentView = base; window.defaultButtonCell = save.cell as? NSButtonCell
        self.window = window; content = body; hiddenLabel = label
    }

    private func perform(_ operation: @escaping (TextEditorController) async throws -> Void) {
        Task { do { try await operation(self) } catch { onError(error) } }
    }
}
