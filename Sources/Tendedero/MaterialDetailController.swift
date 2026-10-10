import AppKit
import Combine
import PDFKit
import InkpegCore

@MainActor final class MaterialDetailController {
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
        self.line = line; self.actions = actions; self.editor = editor
        subscription = line.$snapshot.map(\.privacyHidden).removeDuplicates().sink { [weak self] hidden in self?.setHidden(hidden) }
    }
    func open(_ id: UUID, present: Bool = true) async throws {
        guard !line.snapshot.privacyHidden,
              let record = line.snapshot.materials.first(where: { $0.id == id && $0.status != .trashed }) else { throw StoreError.notFound }
        let request = UUID(); requestID = request
        let url = try await line.store.payloadURL(of: id, versionID: record.activeVersionID)
        guard requestID == request else { return }
        guard !line.snapshot.privacyHidden else { throw StoreError.invalidSource }
        var textPreviews: [(label: String, text: String)] = []
        if record.kind == .text, let version = record.activeVersion, version.byteCount <= ClipboardLimits.textBytes {
            for (label, versionID) in [(L(record.activeVersionID == record.originalVersionID ? (record.source.origin == .note ? .noteOrigin : .originalText) : .editedText), record.activeVersionID), (L(record.source.origin == .note ? .noteOrigin : .originalText), record.originalVersionID)] {
                if versionID == record.originalVersionID && !textPreviews.isEmpty && record.activeVersionID == record.originalVersionID { continue }
                let original = try await line.store.payloadURL(of: id, versionID: versionID)
                guard requestID == request else { return }
                guard !line.snapshot.privacyHidden else { throw StoreError.invalidSource }
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
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for (label, field) in [(L(.materialTitle), titleField), (L(.sourceTitle), sourceTitle), (L(.sourceURL), sourceURL), (L(.sourceFile), sourcePath)] {
            stack.addArrangedSubview(NSTextField(labelWithString: label)); stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        let location = NSStackView(views: [pageKind, sourceLocation]); location.orientation = .horizontal
        sourceLocation.placeholderString = L(.sourceLocation); stack.addArrangedSubview(location)
        if let path = record.source.filePath, !FileManager.default.isReadableFile(atPath: path) { stack.addArrangedSubview(NSTextField(wrappingLabelWithString: L(.sourceUnavailable))) }
        let sourceText = SourceFormatter.describe(record.source, localizer: appLocalizer) ?? L(.sourceMissing)
        sourceSummary.stringValue = sourceText; stack.addArrangedSubview(sourceSummary)
        let controls = NSStackView(views: [ActionButton(title: L(.saveTitle)) { [weak self] in self?.perform { try await $0.saveTitle() } }, ActionButton(title: L(.saveSource)) { [weak self] in self?.perform { try await $0.saveSource() } }, ActionButton(title: L(.chooseSourceFile)) { [weak self] in self?.chooseSource() }]); controls.orientation = .horizontal
        stack.addArrangedSubview(controls)
        let actions = NSStackView(views: [ActionButton(title: L(.copyWithSource)) { [weak self] in guard let self else { return }; self.perform { try await $0.actions.copy(id, includeSource: true) } }, ActionButton(title: L(.openCopy)) { [weak self] in self?.perform { try await $0.actions.open(id) } }]); actions.orientation = .horizontal
        if record.kind == .text {
            actions.addArrangedSubview(ActionButton(title: L(record.source.origin == .note ? .noteContinue : .editText)) { [weak self] in
                guard let self else { return }
                if record.source.origin == .note { self.line.onOpenNote(id) }
                else { self.perform { try await $0.editor.open(id) } }
            })
        }
        stack.addArrangedSubview(actions)
        if record.kind == .text, let version = record.activeVersion, version.byteCount <= ClipboardLimits.textBytes {
            let tabs = NSTabView()
            for (label, text) in textPreviews {
                let scroll = NSScrollView(); scroll.hasVerticalScroller = true
                let view = NSTextView(); view.isEditable = false; view.isRichText = false; view.string = text
                view.font = .systemFont(ofSize: 14); view.isVerticallyResizable = true; view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
                scroll.documentView = view; let tab = NSTabViewItem(); tab.label = label; tab.view = scroll; tabs.addTabViewItem(tab)
            }
            stack.addArrangedSubview(tabs); tabs.heightAnchor.constraint(equalToConstant: 220).isActive = true; tabs.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        } else if record.kind == .image {
            let image = NSImageView(); image.image = makeThumbnail(url, maxPixels: 1600); image.imageScaling = .scaleProportionallyUpOrDown
            stack.addArrangedSubview(image); image.heightAnchor.constraint(equalToConstant: 220).isActive = true; image.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        } else {
            let metadata = L(.materialMetadata).replacingOccurrences(of: "%@", with: record.kind.rawValue).replacingOccurrences(of: "%d", with: String(record.activeVersion?.byteCount ?? 0))
            stack.addArrangedSubview(NSTextField(labelWithString: metadata))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 540, height: 400)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false; stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let base = NSView(), hidden = NSTextField(labelWithString: L(.contentHidden))
        base.addSubview(scroll); base.addSubview(hidden); scroll.translatesAutoresizingMaskIntoConstraints = false; hidden.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: base.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: base.trailingAnchor), scroll.topAnchor.constraint(equalTo: base.topAnchor), scroll.bottomAnchor.constraint(equalTo: base.bottomAnchor), hidden.centerXAnchor.constraint(equalTo: base.centerXAnchor), hidden.centerYAnchor.constraint(equalTo: base.centerYAnchor)])
        window.contentView = base; self.window = window; content = scroll; hiddenLabel = hidden; setHidden(line.snapshot.privacyHidden)
        if present { window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }
    func saveSource() async throws {
        guard let id = materialID, !line.snapshot.privacyHidden, let record = line.snapshot.materials.first(where: { $0.id == id }) else { throw StoreError.notFound }
        let request = requestID
        var source = record.source
        let urlText = sourceURL.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        source.webURL = urlText.isEmpty ? nil : URL(string: urlText)
        if !urlText.isEmpty && source.webURL == nil { throw StoreError.invalidSource }
        source.manualTitle = sourceTitle.stringValue.isEmpty ? nil : sourceTitle.stringValue
        source.filePath = sourcePath.stringValue.isEmpty ? nil : sourcePath.stringValue
        source.fileBookmark = nil; source.locator = nil; source.isManuallyRegistered = true
        if pageKind.indexOfSelectedItem == 1 && !sourceLocation.stringValue.isEmpty {
            guard let page = Int(sourceLocation.stringValue), page > 0, let path = source.filePath,
                  let pdf = PDFDocument(url: URL(fileURLWithPath: path)), !pdf.isLocked, page <= pdf.pageCount else { throw StoreError.invalidSource }
            source.locator = .pdfIndex(page - 1)
        } else if pageKind.indexOfSelectedItem == 2 && !sourceLocation.stringValue.isEmpty { source.locator = .printedPage(sourceLocation.stringValue) }
        var snapshot = try await line.store.apply(.setSource(id, source))
        snapshot.privacyHidden = line.snapshot.privacyHidden
        await line.render(snapshot)
        guard requestID == request, materialID == id else { return }
        sourceSummary.stringValue = SourceFormatter.describe(source, localizer: appLocalizer) ?? L(.sourceMissing)
    }
    private func saveTitle() async throws {
        guard let id = materialID, !line.snapshot.privacyHidden else { throw StoreError.notFound }
        var snapshot = try await line.store.apply(.renameMaterial(id, titleField.stringValue))
        snapshot.privacyHidden = line.snapshot.privacyHidden
        await line.render(snapshot)
    }
    func setHidden(_ hidden: Bool) {
        content?.isHidden = hidden; hiddenLabel?.isHidden = !hidden
        window?.title = L(hidden ? .contentHidden : .materialDetails)
    }
    private func chooseSource() {
        guard !line.snapshot.privacyHidden else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url { sourcePath.stringValue = url.path; pageKind.selectItem(at: 0); sourceLocation.stringValue = "" }
    }
    private func perform(_ operation: @escaping (MaterialDetailController) async throws -> Void) {
        Task { do { try await operation(self) } catch { onError(error) } }
    }
}
