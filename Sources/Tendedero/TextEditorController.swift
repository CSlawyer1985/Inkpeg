import AppKit
import InkpegCore
import Combine

@MainActor final class TextEditorController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private let line: Line
    var text = "" { didSet { if textView.string != text { textView.string = text } } }
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
        guard !isEditing, !line.snapshot.privacyHidden,
              let record = line.snapshot.materials.first(where: { $0.id == id && $0.kind == .text }),
              let version = record.activeVersion, version.byteCount <= ClipboardLimits.textBytes else { throw StoreError.invalidEdit }
        opening = true; defer { opening = false }
        let session = try await line.store.createDerivedVersion(of: id, kind: .textEdit)
        try await install(session, present: present)
    }
    func resume(_ session: EditSession, present: Bool = true) async throws {
        guard !isEditing, !line.snapshot.privacyHidden else { throw StoreError.invalidEdit }
        opening = true; defer { opening = false }
        let recovered = try await line.store.resumeEditingSession(session)
        try await install(recovered, present: present, recoveredOlderVersion: recovered.baseVersionID != session.baseVersionID)
    }
    private func install(_ session: EditSession, present: Bool, recoveredOlderVersion: Bool = false) async throws {
        guard self.session == nil, !line.snapshot.privacyHidden, session.kind == .textEdit,
              try await line.store.pendingEditSessions().contains(session) else { throw StoreError.invalidEdit }
        let data = try Data(contentsOf: session.workingURL)
        guard data.count <= ClipboardLimits.textBytes, let text = String(data: data, encoding: .utf8), !line.snapshot.privacyHidden else { throw StoreError.invalidEdit }
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
        await line.render(snapshot); self.session = nil; window?.close(); window = nil
    }
    func cancel() async throws {
        guard let session, !saving else { throw StoreError.invalidEdit }
        guard !textView.hasMarkedText() else { throw StoreError.operationInProgress }
        saving = true; textView.isEditable = false
        defer { saving = false; textView.isEditable = !line.snapshot.privacyHidden }
        try await line.store.writeEditingResult(session, data: Data(text.utf8))
        _ = try await line.store.finishEditing(session, result: .cancel)
        self.session = nil; window?.close(); window = nil
    }
    func textDidChange(_ notification: Notification) { text = textView.string }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if session == nil { return true }
        Task { do { try await cancel() } catch { onError(error) } }; return false
    }
    func setHidden(_ hidden: Bool) {
        content?.isHidden = hidden; hiddenLabel?.isHidden = !hidden
        textView.isEditable = !hidden && !saving
        window?.title = L(hidden ? .contentHidden : .textEditorTitle)
    }
    private func buildWindow(recoveredOlderVersion: Bool = false) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.delegate = self; window.minSize = NSSize(width: 420, height: 300)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        textView.isRichText = false; textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 14, height: 14); textView.font = .systemFont(ofSize: 15)
        textView.delegate = self; textView.string = text; scroll.documentView = textView
        let buttons = NSStackView(views: [ActionButton(title: L(.cancel)) { [weak self] in self?.perform { try await $0.cancel() } }, ActionButton(title: L(.saveCopy)) { [weak self] in self?.perform { try await $0.save() } }])
        buttons.orientation = .horizontal; buttons.spacing = 10
        let stack = NSStackView(views: [NSTextField(wrappingLabelWithString: L(recoveredOlderVersion ? .textRecoveryChanged : .textEditorHelp)), scroll, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        let base = NSView(), label = NSTextField(labelWithString: L(.contentHidden))
        base.addSubview(stack); base.addSubview(label)
        for v in [stack, label] { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: base.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: base.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: base.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: base.bottomAnchor, constant: -20), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160), label.centerXAnchor.constraint(equalTo: base.centerXAnchor), label.centerYAnchor.constraint(equalTo: base.centerYAnchor)])
        window.contentView = base; self.window = window; content = stack; hiddenLabel = label
    }
    private func perform(_ operation: @escaping (TextEditorController) async throws -> Void) {
        Task { do { try await operation(self) } catch { onError(error) } }
    }
}
