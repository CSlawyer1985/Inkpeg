import AppKit
import Combine
import PDFKit
import InkpegCore

private final class DetailDocumentStack: NSStackView { override var isFlipped: Bool { true } }

@MainActor final class MaterialDetailController: NSObject, NSWindowDelegate {
    enum UnsavedChoice { case save, discard, continueEditing }
    private struct SourceDraft: Equatable {
        var title: String, url: String, path: String, location: String
        var page: Int
    }
    private var savedTitle = ""
    private var savedSource: SourceDraft?
    private var presentationHidden = false
    private var saving = false
    private var dismissing = false
    private var loading = false
    private var saveButton: NSButton?
    private var chooseButton: NSButton?
    private var sourceDisclosure: NSButton?
    private(set) var sourcePanel: NSOpenPanel?
    var chooseUnsavedChanges: (() -> UnsavedChoice)?
    private var sourceDraft: SourceDraft {
        SourceDraft(title: sourceTitle.stringValue, url: sourceURL.stringValue, path: sourcePath.stringValue, location: sourceLocation.stringValue, page: pageKind.indexOfSelectedItem)
    }
    var hasUnsavedChanges: Bool { materialID != nil && (titleField.stringValue != savedTitle || sourceDraft != savedSource) }
    // Match Save/close semantics before inspecting controls, including an active field editor.
    func preventsTermination() -> Bool {
        guard window?.makeFirstResponder(nil) != false else { return true }
        return saving || hasUnsavedChanges
    }
    private let line: Line
    private let actions: MaterialActions
    private let editor: TextEditorController
    private(set) var window: NSWindow?
    private var subscription: AnyCancellable?
    private var materialID: UUID?
    private var requestID = UUID()
    private var content: NSView?
    private var hiddenLabel: NSTextField?
    private let titleField = NSTextField(string: "")
    private let sourceTitle = NSTextField(string: "")
    private let sourceURL = NSTextField(string: "")
    private let sourcePath = NSTextField(string: "")
    private let sourceLocation = NSTextField(string: "")
    private let sourceSummary = NSTextField(wrappingLabelWithString: "")
    private let pageKind = NSPopUpButton()
    var onError: (Error) -> Void = { _ in }
    init(line: Line, actions: MaterialActions, editor: TextEditorController) {
        self.line = line; self.actions = actions; self.editor = editor; super.init()
        subscription = line.$snapshot.map(\.privacyHidden).removeDuplicates().sink { [weak self] hidden in self?.setHidden(hidden) }
    }
    func open(_ id: UUID, present: Bool = true) async throws {
        let epoch = line.privacyEpoch
        guard line.permitsPresentation(epoch),
              let record = line.snapshot.materials.first(where: { $0.id == id && $0.status != .trashed }) else { throw StoreError.notFound }
        while saving { await Task.yield() }
        guard line.permitsPresentation(epoch) else { return }
        guard !dismissing else { throw StoreError.operationInProgress }
        if materialID == id, window != nil {
            if present { window?.makeKeyAndOrderFront(nil) }
            return
        }
        guard try await resolveUnsavedChanges() else { return }
        guard line.permitsPresentation(epoch) else { throw StoreError.invalidSource }
        let request = UUID(); requestID = request
        loading = true; refreshEditability()
        defer { if requestID == request { loading = false; refreshEditability() } }
        let url = try await line.store.payloadURL(of: id, versionID: record.activeVersionID)
        guard requestID == request else { return }
        guard line.permitsPresentation(epoch) else { throw StoreError.invalidSource }
        var textPreviews: [(label: String, text: String)] = []
        if record.kind == .text, let version = record.activeVersion, version.byteCount <= ClipboardLimits.textBytes {
            for (label, versionID) in [(L(record.activeVersionID == record.originalVersionID ? (record.source.origin == .note ? .noteOrigin : .originalText) : .editedText), record.activeVersionID), (L(record.source.origin == .note ? .noteOrigin : .originalText), record.originalVersionID)] {
                if versionID == record.originalVersionID && !textPreviews.isEmpty && record.activeVersionID == record.originalVersionID { continue }
                let original = try await line.store.payloadURL(of: id, versionID: versionID)
                guard requestID == request else { return }
                guard line.permitsPresentation(epoch) else { throw StoreError.invalidSource }
                textPreviews.append((label, try String(contentsOf: original, encoding: .utf8)))
            }
        }
        // Assemble shared form controls only after this request's reads finish.
        // A newer request must never have its controls moved into an older view.
        window?.close(); materialID = id
        titleField.stringValue = record.title; sourceTitle.stringValue = record.source.manualTitle ?? ""
        sourceURL.stringValue = record.source.webURL?.absoluteString ?? ""; sourcePath.stringValue = record.source.filePath ?? ""
        pageKind.removeAllItems(); pageKind.addItems(withTitles: [L(.pageUnknown), L(.physicalPage), L(.printedPage)])
        switch record.source.locator {
        case .pdfIndex(let index): pageKind.selectItem(at: 1); sourceLocation.stringValue = String(index + 1)
        case .printedPage(let label): pageKind.selectItem(at: 2); sourceLocation.stringValue = label
        default: pageKind.selectItem(at: 0); sourceLocation.stringValue = ""
        }
        savedTitle = titleField.stringValue; savedSource = sourceDraft
        let stack = DetailDocumentStack(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let titleLabel = NSTextField(labelWithString: L(.materialTitle)); PanelAppearance.secondary(titleLabel)
        stack.addArrangedSubview(titleLabel); stack.addArrangedSubview(titleField)
        titleField.font = .systemFont(ofSize: 17, weight: .medium)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.cell?.usesSingleLineMode = true; titleField.cell?.isScrollable = true
        titleField.lineBreakMode = .byTruncatingTail; titleField.toolTip = record.title
        titleField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        titleField.heightAnchor.constraint(equalToConstant: 30).isActive = true
        if record.kind == .text, let version = record.activeVersion, version.byteCount <= ClipboardLimits.textBytes {
            let tabs = NSTabView()
            if textPreviews.count == 1 {
                tabs.tabViewType = .noTabsNoBorder
                let caption = NSTextField(labelWithString: textPreviews[0].label); PanelAppearance.secondary(caption)
                stack.addArrangedSubview(caption)
            }
            for (label, text) in textPreviews {
                let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
                scroll.backgroundColor = PanelAppearance.paper
                let view = NSTextView(); view.isEditable = false; view.isRichText = false; view.string = text
                PanelAppearance.editor(view)
                view.isVerticallyResizable = true; view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
                scroll.documentView = view; let tab = NSTabViewItem(); tab.label = label; tab.view = scroll; tabs.addTabViewItem(tab)
            }
            stack.addArrangedSubview(tabs); tabs.heightAnchor.constraint(equalToConstant: 260).isActive = true; tabs.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        } else if record.kind == .image || record.kind == .pdf {
            // Use the existing bounded first-page thumbnail path, never a live PDFView.
            let image = NSImageView(); image.image = makeThumbnail(url, maxPixels: 1600) ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil); image.imageScaling = .scaleProportionallyUpOrDown
            stack.addArrangedSubview(image); image.heightAnchor.constraint(equalToConstant: 260).isActive = true; image.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        } else {
            let metadata = L(.materialMetadata).replacingOccurrences(of: "%@", with: record.kind.rawValue).replacingOccurrences(of: "%d", with: String(record.activeVersion?.byteCount ?? 0))
            let label = NSTextField(wrappingLabelWithString: metadata); PanelAppearance.secondary(label)
            stack.addArrangedSubview(label)
        }
        let actions = NSStackView(views: [ActionButton(title: L(MaterialActions.copyLabel(for: record.kind))) { [weak self] in guard let self else { return }; self.perform { try await $0.actions.copy(id, includeSource: record.kind == .text) } }, ActionButton(title: L(record.kind == .file ? .showInFinder : .openCopy)) { [weak self] in self?.perform { try await $0.actions.open(id) } }]); actions.orientation = .horizontal; actions.spacing = 8
        if record.kind == .text {
            actions.addArrangedSubview(ActionButton(title: L(record.source.origin == .note ? .noteContinue : .editText)) { [weak self] in
                guard let self else { return }
                if record.source.origin == .note { self.line.onOpenNote(id) }
                else { self.perform { try await $0.editor.open(id) } }
            })
        }
        stack.addArrangedSubview(actions)
        let sourceText = SourceFormatter.describe(record.source, localizer: appLocalizer) ?? L(.sourceMissing)
        sourceSummary.stringValue = sourceText; sourceSummary.maximumNumberOfLines = 2
        sourceSummary.lineBreakMode = .byTruncatingTail; sourceSummary.toolTip = sourceText
        PanelAppearance.secondary(sourceSummary)
        stack.addArrangedSubview(sourceSummary); sourceSummary.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        let sourceForm = NSStackView(); sourceForm.orientation = .vertical; sourceForm.alignment = .leading; sourceForm.spacing = 8
        let disclosure = ActionButton(title: L(.sourceLabel)) { [weak self, weak sourceForm] in
            guard let self, !self.presentationHidden, let sourceForm else { return }
            self.window?.makeFirstResponder(nil)
            sourceForm.isHidden.toggle()
            sourceForm.setAccessibilityHidden(sourceForm.isHidden)
            self.sourceDisclosure?.image = NSImage(systemSymbolName: sourceForm.isHidden ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
        }
        disclosure.setButtonType(.onOff); disclosure.bezelStyle = .recessed
        disclosure.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        sourceDisclosure = disclosure
        disclosure.imagePosition = .imageLeading; disclosure.identifier = NSUserInterfaceItemIdentifier("sourceDisclosure")
        disclosure.setAccessibilityLabel(L(.sourceLabel))
        stack.addArrangedSubview(disclosure)
        for (label, field) in [(L(.sourceTitle), sourceTitle), (L(.sourceURL), sourceURL), (L(.sourceFile), sourcePath)] {
            let caption = NSTextField(labelWithString: label); PanelAppearance.secondary(caption)
            sourceForm.addArrangedSubview(caption); sourceForm.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: sourceForm.widthAnchor).isActive = true
        }
        let location = NSStackView(views: [pageKind, sourceLocation]); location.orientation = .horizontal; location.spacing = 8
        sourceLocation.placeholderString = L(.sourceLocation); sourceForm.addArrangedSubview(location)
        location.widthAnchor.constraint(equalTo: sourceForm.widthAnchor).isActive = true
        if let path = record.source.filePath, !FileManager.default.isReadableFile(atPath: path) { sourceForm.addArrangedSubview(NSTextField(wrappingLabelWithString: L(.sourceUnavailable))) }
        let choose = ActionButton(title: L(.chooseSourceFile)) { [weak self] in self?.chooseSource() }
        chooseButton = choose; sourceForm.addArrangedSubview(choose)
        stack.addArrangedSubview(sourceForm); sourceForm.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        sourceForm.isHidden = true; sourceForm.setAccessibilityHidden(true)
        let save = ActionButton(title: L(.saveDetails)) { [weak self] in self?.perform { try await $0.save() } }
        PanelAppearance.primary(save); saveButton = save
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.delegate = self; window.minSize = NSSize(width: 540, height: 400)
        PanelAppearance.configure(window)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false; stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let base = PanelSurface(), body = NSView(), footer = NSView(), hidden = NSTextField(labelWithString: L(.contentHidden))
        PanelAppearance.secondary(hidden)
        let rule = NSBox(); rule.boxType = .separator
        base.addSubview(body); base.addSubview(hidden); body.addSubview(scroll); body.addSubview(footer); footer.addSubview(rule); footer.addSubview(save)
        for view in [body, hidden, scroll, footer, rule, save] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: base.leadingAnchor), body.trailingAnchor.constraint(equalTo: base.trailingAnchor), body.topAnchor.constraint(equalTo: base.topAnchor), body.bottomAnchor.constraint(equalTo: base.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor), scroll.topAnchor.constraint(equalTo: body.topAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: body.leadingAnchor), footer.trailingAnchor.constraint(equalTo: body.trailingAnchor), footer.bottomAnchor.constraint(equalTo: body.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: PanelAppearance.footerHeight),
            rule.topAnchor.constraint(equalTo: footer.topAnchor), rule.leadingAnchor.constraint(equalTo: footer.leadingAnchor), rule.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            save.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24), save.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            hidden.centerXAnchor.constraint(equalTo: base.centerXAnchor), hidden.centerYAnchor.constraint(equalTo: base.centerYAnchor)
        ])
        window.contentView = base; window.defaultButtonCell = save.cell as? NSButtonCell
        self.window = window; content = body; hiddenLabel = hidden; setHidden(line.snapshot.privacyHidden)
        if present { window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }

    func save() async throws { try await persist(includeTitle: true) }
    // Retain the source-only entry for existing internal callers; the UI has one Save.
    func saveSource() async throws { try await persist(includeTitle: false) }
    private func persist(includeTitle: Bool) async throws {
        let epoch = line.privacyEpoch
        guard let id = materialID, !saving, !loading, !line.snapshot.privacyHidden,
              let record = line.snapshot.materials.first(where: { $0.id == id }) else { throw StoreError.invalidSource }
        window?.makeFirstResponder(nil)
        let title = titleField.stringValue, draft = sourceDraft
        let titleChanged = includeTitle && title != savedTitle
        let sourceChanged = draft != savedSource
        // Validate the whole source draft before starting either write.
        let source = sourceChanged ? try validatedSource(draft, original: record.source) : record.source
        saving = true; refreshEditability()
        defer { saving = false; refreshEditability() }
        if titleChanged {
            try await apply(.renameMaterial(id, title))
            savedTitle = title; titleField.toolTip = title
        }
        if sourceChanged {
            guard line.permitsPresentation(epoch) else { throw StoreError.invalidSource }
            try await apply(.setSource(id, source))
            savedSource = draft
            sourceSummary.stringValue = SourceFormatter.describe(source, localizer: appLocalizer) ?? L(.sourceMissing)
            sourceSummary.toolTip = sourceSummary.stringValue
        }
    }
    private func apply(_ command: MaterialCommand) async throws {
        var snapshot = try await line.store.apply(command)
        snapshot.privacyHidden = line.snapshot.privacyHidden
        await line.render(snapshot)
    }
    private func validatedSource(_ draft: SourceDraft, original: SourceRecord) throws -> SourceRecord {
        var source = original
        let urlText = draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
        source.webURL = urlText.isEmpty ? nil : URL(string: urlText)
        if !urlText.isEmpty && source.webURL == nil { throw StoreError.invalidSource }
        source.manualTitle = draft.title.isEmpty ? nil : draft.title
        source.filePath = draft.path.isEmpty ? nil : draft.path
        if source.filePath != original.filePath { source.fileBookmark = nil }
        source.locator = nil; source.isManuallyRegistered = true
        if draft.page == 1 && !draft.location.isEmpty {
            guard let page = Int(draft.location), page > 0, let path = source.filePath,
                  let pdf = PDFDocument(url: URL(fileURLWithPath: path)), !pdf.isLocked, page <= pdf.pageCount else { throw StoreError.invalidSource }
            source.locator = .pdfIndex(page - 1)
        } else if draft.page == 2 && !draft.location.isEmpty { source.locator = .printedPage(draft.location) }
        try SourceFormatter.validate(source)
        return source
    }
    private func resolveUnsavedChanges() async throws -> Bool {
        window?.makeFirstResponder(nil)
        guard hasUnsavedChanges else { return true }
        guard !line.snapshot.privacyHidden else { return false }
        let epoch = line.privacyEpoch
        let choice: UnsavedChoice
        if let chooseUnsavedChanges { choice = chooseUnsavedChanges() }
        else {
            let alert = NSAlert(); alert.messageText = L(.detailUnsavedTitle); alert.informativeText = L(.detailUnsavedMessage)
            alert.addButton(withTitle: L(.saveDetails)); alert.addButton(withTitle: L(.detailDiscard)); alert.addButton(withTitle: L(.detailContinue))
            switch line.runAlert(alert) {
            case .alertFirstButtonReturn: choice = .save
            case .alertSecondButtonReturn: choice = .discard
            default: choice = .continueEditing
            }
        }
        guard line.permitsPresentation(epoch) else { return false }
        switch choice {
        case .continueEditing: return false
        case .discard: return true
        case .save: try await save(); return !hasUnsavedChanges && line.permitsPresentation(epoch)
        }
    }
    func dismiss() async throws {
        guard !saving, !dismissing else { throw StoreError.operationInProgress }
        dismissing = true; defer { dismissing = false }
        guard try await resolveUnsavedChanges() else { return }
        requestID = UUID(); loading = false; materialID = nil; savedSource = nil
        window?.close(); window = nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        perform { try await $0.dismiss() }; return false
    }
    private func refreshEditability() {
        let enabled = !presentationHidden && !saving && !loading
        for field in [titleField, sourceTitle, sourceURL, sourcePath, sourceLocation] { field.isEditable = enabled; field.isSelectable = enabled }
        pageKind.isEnabled = enabled; saveButton?.isEnabled = enabled; chooseButton?.isEnabled = enabled
    }
    func setHidden(_ hidden: Bool) {
        presentationHidden = hidden
        content?.isHidden = hidden; content?.setAccessibilityHidden(hidden); hiddenLabel?.isHidden = !hidden
        window?.representedURL = nil
        if hidden { requestID = UUID(); loading = false; sourcePanel?.cancel(nil); window?.makeFirstResponder(nil) }
        refreshEditability()
        window?.title = L(hidden ? .contentHidden : .materialDetails)
    }
    private func chooseSource() {
        guard !line.snapshot.privacyHidden else { return }
        let panel = NSOpenPanel(); sourcePanel = panel
        defer { sourcePanel = nil }
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        if line.runModal(panel, operation: { panel.runModal() }) == .OK, let url = panel.url { sourcePath.stringValue = url.path; pageKind.selectItem(at: 0); sourceLocation.stringValue = "" }
    }
    private func perform(_ operation: @escaping (MaterialDetailController) async throws -> Void) {
        Task { do { try await operation(self) } catch { onError(error) } }
    }
}
