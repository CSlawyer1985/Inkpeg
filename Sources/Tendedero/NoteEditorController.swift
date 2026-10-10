import AppKit
import InkpegCore
import Combine

@MainActor final class NoteTextView: NSTextView {
    var onDismiss: () -> Void = {}
    var onHang: () -> Void = {}
    override func cancelOperation(_ sender: Any?) { onDismiss() }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command && [36, 76].contains(event.keyCode) { onHang() }
        else { super.keyDown(with: event) }
    }
}

@MainActor final class NoteEditorController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private let line: Line
    let textView = NoteTextView()
    private(set) var draft: NoteDraft?
    private(set) var window: NSWindow?
    private var opening = false
    private var hanging = false
    private var dismissing = false
    private var presentationHidden = false
    private var persistenceTask: Task<Void, Never>?
    private var pendingText = ""
    private var lastSaveError: Error?
    private var subscription: AnyCancellable?
    private var content: NSView?
    private var hiddenLabel: NSTextField?
    private let statusLabel = NSTextField(labelWithString: "")
    private var hangButton: NSButton?
    private var placeholder: NSTextField?
    private var titleLabel: NSTextField?
    private let statusIcon = NSImageView()
    var isBusy: Bool { opening || hanging || dismissing || persistenceTask != nil }
    var hasUnsavedInput: Bool { draft != nil && textView.string != draft?.text }
    var onError: (Error) -> Void = { _ in }
    var onHung: () -> Void = {}
    init(line: Line) {
        self.line = line; super.init()
        textView.onDismiss = { [weak self] in self?.perform { try await $0.dismiss() } }
        textView.onHang = { [weak self] in self?.requestHang() }
        subscription = line.$snapshot.map(\.privacyHidden).removeDuplicates().sink { [weak self] in self?.setHidden($0) }
    }
    func openNew(present: Bool = true) async throws {
        guard !opening, !hanging, !dismissing, !line.snapshot.privacyHidden else { throw StoreError.operationInProgress }
        if let draft, draft.baseVersionID == nil, !line.snapshot.materials.contains(where: { $0.id == draft.materialID }) { show(present); return }
        try beginOpening(); defer { opening = false; refreshEditability() }
        try await flushAutosave()
        let pending = try await line.store.pendingNoteDrafts()
        let recovering = pending.first { draft in !line.snapshot.materials.contains(where: { $0.id == draft.materialID }) }
        let next: NoteDraft
        if let recovering { next = recovering } else { next = try await line.store.createNoteDraft() }
        try install(next, present: present)
    }
    func open(_ id: UUID, present: Bool = true) async throws {
        guard !opening, !hanging, !dismissing, !line.snapshot.privacyHidden else { throw StoreError.operationInProgress }
        if draft?.materialID == id { show(present); return }
        try beginOpening(); defer { opening = false; refreshEditability() }
        try await flushAutosave()
        try install(try await line.store.createNoteDraft(for: id), present: present)
    }
    func resume(_ draft: NoteDraft, present: Bool = true) async throws {
        try beginOpening(); defer { opening = false; refreshEditability() }
        try await flushAutosave()
        guard let current = try await line.store.pendingNoteDrafts().first(where: { $0.id == draft.id }) else { throw StoreError.invalidEdit }
        try install(current, present: present)
    }
    private func beginOpening() throws {
        guard !opening, !hanging, !dismissing, !line.snapshot.privacyHidden, !textView.hasMarkedText() else { throw StoreError.operationInProgress }
        opening = true; refreshEditability()
    }
    private func install(_ draft: NoteDraft, present: Bool) throws {
        guard !line.snapshot.privacyHidden else { throw StoreError.invalidSource }
        textView.undoManager?.removeAllActions()
        self.draft = draft; pendingText = draft.text; textView.string = draft.text; lastSaveError = nil
        if window == nil { buildWindow() }
        setStatus(.noteSaved); setHidden(false); show(present)
    }
    private func show(_ present: Bool) {
        if present { window?.center(); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(textView); NSApp.activate(ignoringOtherApps: true) }
    }
    func textDidChange(_ notification: Notification) {
        guard draft != nil else { return }
        pendingText = textView.string; refreshEditability(); scheduleAutosave()
    }
    private func scheduleAutosave() {
        guard persistenceTask == nil, let draft, pendingText != draft.text else { return }
        setStatus(.noteSaving)
        persistenceTask = Task { [weak self] in
            guard let self else { return }
            while let current = self.draft, self.pendingText != current.text {
                let text = self.pendingText
                do {
                    let saved = try await self.line.store.updateNoteDraft(current.id, text: text)
                    guard self.draft?.id == current.id else { break }
                    self.draft = saved; self.lastSaveError = nil
                } catch {
                    self.lastSaveError = error; self.setStatus(.noteSaveFailed); break
                }
            }
            if self.lastSaveError == nil { self.setStatus(.noteSaved) }
            self.persistenceTask = nil
        }
    }
    func flushAutosave() async throws {
        guard draft != nil else { return }
        repeat {
            pendingText = textView.string; scheduleAutosave()
            if let task = persistenceTask { await task.value }
            if !hasUnsavedInput { lastSaveError = nil; setStatus(.noteSaved) }
            if let lastSaveError { throw lastSaveError }
        } while hasUnsavedInput
    }
    func hang() async throws {
        guard let draft, !opening, !hanging, !dismissing, !line.snapshot.privacyHidden else { throw StoreError.invalidEdit }
        guard !textView.hasMarkedText() else { throw StoreError.operationInProgress }
        hanging = true; refreshEditability()
        defer { hanging = false; refreshEditability() }
        try await flushAutosave()
        guard !line.snapshot.privacyHidden else { throw StoreError.invalidSource }
        var snapshot = try await line.store.publishNoteDraft(draft.id, visibleCapacity: line.maxItems)
        snapshot.privacyHidden = line.snapshot.privacyHidden
        await line.render(snapshot)
        self.draft = nil; pendingText = ""; window?.close(); window = nil; onHung()
    }
    private func requestHang() {
        perform { editor in
            // Repeated UI actions while the first request is pending are harmless.
            // Keep direct hang() failures and genuine save errors observable.
            guard editor.draft != nil, !editor.opening, !editor.hanging, !editor.dismissing else { return }
            try await editor.hang()
        }
    }
    func dismiss() async throws {
        guard !opening, !hanging, !dismissing else { throw StoreError.operationInProgress }
        dismissing = true; refreshEditability()
        defer { dismissing = false; refreshEditability() }
        try await flushAutosave(); window?.orderOut(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { perform { try await $0.dismiss() }; return false }
    func windowDidResignKey(_ notification: Notification) {
        guard !opening, !hanging, !dismissing, notification.object as? NSWindow === window else { return }
        perform { try await $0.dismiss() }
    }
    func setHidden(_ hidden: Bool) {
        presentationHidden = hidden
        if hidden, draft != nil { pendingText = textView.string; scheduleAutosave() }
        content?.isHidden = hidden; hiddenLabel?.isHidden = !hidden
        window?.title = L(hidden ? .contentHidden : .noteTitle)
        titleLabel?.stringValue = L(hidden ? .contentHidden : .noteTitle)
        if hidden { window?.makeFirstResponder(nil) }
        else if window?.isKeyWindow == true { window?.makeFirstResponder(textView) }
        refreshEditability()
    }
    private func refreshEditability() {
        let enabled = !presentationHidden && !opening && !hanging && !dismissing
        textView.isEditable = enabled; textView.isSelectable = !presentationHidden
        let blank = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        hangButton?.isEnabled = enabled && !blank && !textView.hasMarkedText()
        placeholder?.isHidden = !textView.string.isEmpty
        hangButton?.title = L(lastSaveError == nil ? .noteHang : .noteRetryHang) + "  ⌘↵"
    }
    private func setStatus(_ key: MessageKey) {
        statusLabel.stringValue = L(key)
        let failed = key == .noteSaveFailed
        statusLabel.textColor = failed ? .systemRed : .secondaryLabelColor
        statusIcon.image = NSImage(systemSymbolName: failed ? "exclamationmark.circle" : key == .noteSaving ? "ellipsis" : "checkmark", accessibilityDescription: nil)
        statusIcon.contentTintColor = failed ? .systemRed : .secondaryLabelColor
        refreshEditability()
    }
    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 488, height: 424), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 420, height: 320)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.backgroundColor = .textBackgroundColor
        let base = NSView(), body = NSView(), header = NSVisualEffectView(), footer = NSVisualEffectView()
        header.material = .titlebar; header.blendingMode = .withinWindow; header.state = .active
        footer.material = .windowBackground; footer.blendingMode = .withinWindow; footer.state = .active
        let title = NSTextField(labelWithString: L(.noteTitle)); title.font = .systemFont(ofSize: 14, weight: .semibold); titleLabel = title
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor
        textView.isRichText = false; textView.allowsUndo = true
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero; textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.drawsBackground = false; textView.textColor = .labelColor
        textView.font = .systemFont(ofSize: 17); textView.textContainerInset = NSSize(width: 30, height: 26)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineHeightMultiple = 1.7
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes[.paragraphStyle] = paragraph
        textView.delegate = self; textView.setAccessibilityLabel(L(.noteTitle)); scroll.documentView = textView
        let hint = NSTextField(wrappingLabelWithString: L(.notePlaceholder)); hint.font = .systemFont(ofSize: 17)
        hint.textColor = .placeholderTextColor; hint.setAccessibilityElement(false); placeholder = hint
        let hang = ActionButton(title: L(.noteHang) + "  ⌘↵") { [weak self] in self?.requestHang() }
        hang.bezelStyle = .rounded; hang.controlSize = .large; hang.bezelColor = .controlAccentColor
        hang.keyEquivalent = "\r"; hang.keyEquivalentModifierMask = .command; hangButton = hang
        hang.setAccessibilityLabel(L(.noteHang))
        let hide = ActionButton(title: L(.noteDismiss)) { [weak self] in self?.perform { try await $0.dismiss() } }
        hide.isBordered = false; hide.font = .systemFont(ofSize: 13)
        let buttons = NSStackView(views: [hide, hang]); buttons.orientation = .horizontal; buttons.spacing = 12
        statusLabel.font = .systemFont(ofSize: 12); statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail; statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let status = NSStackView(views: [statusIcon, statusLabel]); status.orientation = .horizontal; status.spacing = 8
        let hidden = NSTextField(labelWithString: L(.contentHidden)); hidden.textColor = .secondaryLabelColor
        let rule = NSBox(); rule.boxType = .separator
        base.addSubview(header); header.addSubview(title); base.addSubview(body); base.addSubview(hidden)
        body.addSubview(scroll); body.addSubview(hint); body.addSubview(footer)
        footer.addSubview(rule); footer.addSubview(status); footer.addSubview(buttons)
        for view in [header, title, body, hidden, scroll, hint, footer, rule, status, buttons] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: base.topAnchor), header.leadingAnchor.constraint(equalTo: base.leadingAnchor), header.trailingAnchor.constraint(equalTo: base.trailingAnchor), header.heightAnchor.constraint(equalToConstant: 54),
            title.centerXAnchor.constraint(equalTo: header.centerXAnchor), title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            body.topAnchor.constraint(equalTo: header.bottomAnchor), body.leadingAnchor.constraint(equalTo: base.leadingAnchor), body.trailingAnchor.constraint(equalTo: base.trailingAnchor), body.bottomAnchor.constraint(equalTo: base.bottomAnchor),
            footer.bottomAnchor.constraint(equalTo: body.bottomAnchor), footer.leadingAnchor.constraint(equalTo: body.leadingAnchor), footer.trailingAnchor.constraint(equalTo: body.trailingAnchor), footer.heightAnchor.constraint(equalToConstant: 72),
            scroll.topAnchor.constraint(equalTo: body.topAnchor), scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            hint.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 28), hint.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 35), hint.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -30),
            rule.topAnchor.constraint(equalTo: footer.topAnchor), rule.leadingAnchor.constraint(equalTo: footer.leadingAnchor), rule.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            status.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 24), status.centerYAnchor.constraint(equalTo: footer.centerYAnchor), status.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),
            statusIcon.widthAnchor.constraint(equalToConstant: 13), statusIcon.heightAnchor.constraint(equalToConstant: 13),
            buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24), buttons.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            hidden.centerXAnchor.constraint(equalTo: base.centerXAnchor), hidden.centerYAnchor.constraint(equalTo: base.centerYAnchor)
        ])
        window.contentView = base; window.defaultButtonCell = hang.cell as? NSButtonCell
        self.window = window; content = body; hiddenLabel = hidden
        refreshEditability()
    }
    private func perform(_ operation: @escaping (NoteEditorController) async throws -> Void) {
        Task {
            do { try await operation(self) }
            catch {
                if error as? StoreError == .invalidSource && textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { setStatus(.noteBlank) }
                else { onError(error) }
            }
        }
    }
}
