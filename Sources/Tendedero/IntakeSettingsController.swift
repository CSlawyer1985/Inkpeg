import AppKit
import SwiftUI
import InkpegCore
import Combine

@MainActor final class IntakeSettingsModel: ObservableObject {
    @Published private(set) var preferences: ClipboardPreference
    @Published private(set) var saving = false
    @Published private(set) var failed = false
    @Published private(set) var captureEnabled = false
    @Published private(set) var capturePath = ""
    @Published private(set) var captureStatus = ""
    private let service: ClipboardImportService
    private let capture: CaptureFolderCoordinator
    weak var privacyLine: Line?
    private(set) var exportPanel: NSSavePanel?
    private var saveRevision = 0
    private var retryPreferences: ClipboardPreference?
    let libraryURL: URL
    @Published private(set) var usage: [String: Int64]?
    @Published private(set) var usageFailed = false
    @Published private(set) var didSave = false
    @Published private(set) var cleanupPlan: StorageCleanupPlan?
    @Published private(set) var cleanupBusy = false
    @Published private(set) var cleanupMessage: String?
    @Published private(set) var cleanupFailed = false
    @Published var page = 0
    @Published var showCleanup = false
    @Published var selectedCleanupPaths = Set<String>()
    var selectedCleanupPlan: StorageCleanupPlan? { cleanupPlan?.selecting(selectedCleanupPaths) }
    private let cleanupStore: MaterialStore?
    private let onCleanup: (WorkspaceSnapshot) async -> Void
    private let canClean: () -> Bool
    var canOfferCleanup: Bool { cleanupStore != nil && !cleanupBusy }
    init(service: ClipboardImportService, capture: CaptureFolderCoordinator, libraryURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Inkpeg", isDirectory: true), store: MaterialStore? = nil, canClean: @escaping () -> Bool = { true }, onCleanup: @escaping (WorkspaceSnapshot) async -> Void = { _ in }) {
        self.service = service; self.capture = capture; self.libraryURL = libraryURL; preferences = service.preferences
        cleanupStore = store; self.canClean = canClean; self.onCleanup = onCleanup
        refresh()
    }
    func previewCleanup() async {
        let epoch = privacyLine?.privacyEpoch
        guard let cleanupStore, !cleanupBusy else { return }
        cleanupBusy = true; cleanupMessage = nil; cleanupFailed = false
        defer { cleanupBusy = false }
        do {
            guard canClean() else { throw StoreError.invalidSource }
            let plan = try await cleanupStore.previewStorageCleanup()
            guard privacyLine?.privacyEpoch == epoch, canClean() else { throw StoreError.invalidSource }
            cleanupPlan = plan
            selectedCleanupPaths = Set(plan.targets.map(\.relativePath))
            if plan.targets.isEmpty && plan.stagingInventory.isEmpty { cleanupMessage = L(.cleanupEmpty) }
            else { showCleanup = true }
        } catch { cleanupFailed = true; cleanupMessage = L(.cleanupUnavailable) }
    }
    func confirmCleanup() async {
        guard let cleanupStore, let plan = selectedCleanupPlan, !plan.targets.isEmpty, showCleanup, !cleanupBusy else { return }
        cleanupBusy = true; cleanupMessage = nil; cleanupFailed = false
        defer { cleanupBusy = false; showCleanup = false; cleanupPlan = nil }
        do {
            guard canClean() else { throw StoreError.invalidSource }
            let result = try await cleanupStore.cleanStorage(plan)
            await onCleanup(result.snapshot)
            cleanupFailed = result.failedCount > 0 || result.unverifiedCount > 0
            cleanupMessage = String(format: L(cleanupFailed ? .cleanupPartial : .cleanupDone), result.movedCount, Self.size(result.movedBytes))
        } catch {
            cleanupFailed = true
            cleanupMessage = L(error as? StoreError == .sourceChanged ? .cleanupChanged : .cleanupUnavailable)
            if let snapshot = try? await cleanupStore.load() { await onCleanup(snapshot) }
        }
        await refreshUsage()
    }
    func chooseStagingExport(_ target: CleanupTarget) {
        guard !cleanupBusy, canClean() else { return }
        let epoch = privacyLine?.privacyEpoch
        let panel = NSSavePanel(); exportPanel = panel
        defer { exportPanel = nil }
        panel.nameFieldStringValue = target.title
        let response = privacyLine.map { line in line.runModal(panel) { panel.runModal() } } ?? panel.runModal()
        guard response == .OK, let destination = panel.url, canClean(), privacyLine?.privacyEpoch == epoch else { return }
        Task { [self] in
            guard canClean(), privacyLine?.privacyEpoch == epoch else { return }
            await exportStaging(target, to: destination)
        }
    }
    func exportStaging(_ target: CleanupTarget, to destination: URL) async {
        guard let cleanupStore, let plan = cleanupPlan, !cleanupBusy, canClean() else { return }
        cleanupBusy = true; defer { cleanupBusy = false }
        do {
            _ = try await cleanupStore.exportStagingCopy(target, from: plan, to: destination)
            guard canClean() else { return }
            cleanupFailed = false; cleanupMessage = L(.stagingExportDone)
        } catch { cleanupFailed = true; cleanupMessage = L(.stagingExportFailed) }
    }
    func cancelCleanup() { guard !cleanupBusy else { return }; showCleanup = false; cleanupPlan = nil }
    func hideCleanup() { exportPanel?.cancel(nil); capture.cancelPrivacyPanel(); showCleanup = false; cleanupPlan = nil }
    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter(); formatter.countStyle = .file; formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
    func refresh() {
        if !saving { preferences = service.preferences }
        saving = service.isSavingPreferences
        captureEnabled = capture.isEnabled; capturePath = capture.selectedPath ?? L(.captureNoFolder)
        captureStatus = L(capture.status)
    }
    func binding(_ key: WritableKeyPath<ClipboardPreference, Bool>) -> Binding<Bool> {
        Binding(get: { self.preferences[keyPath: key] }, set: { value in
            var next = self.preferences; next[keyPath: key] = value
            Task { await self.save(next) }
        })
    }
    func save(_ value: ClipboardPreference) async {
        guard !saving else { return }
        saveRevision += 1
        let revision = saveRevision
        saving = true; preferences = value; failed = false
        let saved = await service.updatePreferences(value)
        guard revision == saveRevision else { return }
        failed = !saved; retryPreferences = saved ? nil : value; didSave = didSave || saved
        preferences = service.preferences; saving = false
    }
    func retry() { if let retryPreferences { Task { await save(retryPreferences) } } }
    func refreshUsage() async {
        let root = libraryURL
        let bytes = await Task.detached(priority: .utility) { Self.measureUsage(root) }.value
        usage = bytes; usageFailed = bytes == nil
    }
    nonisolated static func measureUsage(_ root: URL) -> [String: Int64]? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let info = try? root.resourceValues(forKeys: keys), info.isDirectory == true, info.isSymbolicLink != true else { return nil }
        guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        let existingNames = Set(children.map(\.lastPathComponent))
        var result: [String: Int64] = [:]
        for name in ["Materials", "Exports", "Drafts", "Transactions", "CleanupRecords"] {
            let folder = root.appendingPathComponent(name)
            guard existingNames.contains(name) else { result[name] = 0; continue }
            var enumerationFailed = false
            guard let values = try? folder.resourceValues(forKeys: keys), values.isDirectory == true, values.isSymbolicLink != true,
                  let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in enumerationFailed = true; return false }) else { return nil }
            var total: Int64 = 0
            for case let file as URL in entries {
                guard let value = try? file.resourceValues(forKeys: keys) else { return nil }
                if value.isSymbolicLink == true { entries.skipDescendants(); continue }
                if value.isRegularFile == true { total += Int64(value.fileSize ?? 0) }
            }
            guard !enumerationFailed else { return nil }
            result[name] = total
        }
        return result
    }
    func chooseFolder() { capture.chooseFolder(); refresh() }
    func toggleCapture() { capture.toggleEnabled(); refresh() }
}

@MainActor final class IntakeSettingsController: NSWindowController {
    let model: IntakeSettingsModel
    private var privacySubscription: AnyCancellable?
    private var settingsContent: NSView?
    init(service: ClipboardImportService, capture: CaptureFolderCoordinator, libraryURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Inkpeg", isDirectory: true), store: MaterialStore? = nil, line: Line? = nil, hotKey: HotKey? = nil) {
        model = IntakeSettingsModel(service: service, capture: capture, libraryURL: libraryURL, store: store,
            canClean: { [weak line] in line?.snapshot.privacyHidden != true }, onCleanup: { [weak line] snapshot in
                guard let line else { return }
                var next = (try? await line.store.load()) ?? snapshot; next.privacyHidden = line.snapshot.privacyHidden
                await line.render(next)
            })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 576, height: 730), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L(.intakeSettings); window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        PanelAppearance.configure(window)
        // Express the usable minimum in hosted content, so native layout keeps
        // it across privacy replacement instead of overwriting a window setter.
        window.contentView = NSHostingView(rootView: IntakeSettingsView(model: model, hotKey: hotKey).frame(minWidth: 500, minHeight: 480))
        let privacyContent = NSHostingView(rootView: Text(L(.contentHidden))
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .frame(minWidth: 500, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
            .background(Color(nsColor: PanelAppearance.paper)))
        super.init(window: window)
        settingsContent = window.contentView
        model.privacyLine = line
        if let line {
            privacySubscription = line.$snapshot.map(\.privacyHidden).removeDuplicates().sink { [weak self] hidden in
                guard let self else { return }
                if hidden {
                    self.model.hideCleanup(); window.makeFirstResponder(nil)
                    if let sheet = window.attachedSheet {
                        window.endSheet(sheet, returnCode: .cancel)
                        sheet.orderOut(nil)
                    }
                }
                window.title = L(hidden ? .contentHidden : .intakeSettings)
                window.representedURL = nil
                window.contentView = hidden ? privacyContent : self.settingsContent
            }
        }
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("Unavailable") }
    func present(page: Int = 0) {
        model.page = page
        model.refresh(); showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        Task { await model.refreshUsage() }
    }
}

private struct IntakeSettingsView: View {
    @ObservedObject var model: IntakeSettingsModel
    var hotKey: HotKey?
    private let spacing: CGFloat = 22
    var body: some View {
        VStack(spacing: 0) {
            Picker(L(.intakeSettings), selection: $model.page) {
                Text(L(.settingsIntake)).tag(0); Text(L(.settingsStorage)).tag(1)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 184).padding(.top, 16).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: spacing) {
                    if model.page == 0 { intake } else { storage }
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 10) {
                Link("chenshi.ai", destination: URL(string: "https://chenshi.ai")!)
                Spacer()
                if model.failed {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(L(.inputSettingsFailed)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Button(L(.settingsRetry), action: model.retry).disabled(model.saving)
                } else if model.saving || model.didSave {
                    Text(L(model.saving ? .settingsSaving : .settingsSaved)).foregroundStyle(.secondary)
                }
            }.font(.system(size: 12)).padding(.horizontal, 24).padding(.vertical, 14)
        }.background(Color(nsColor: PanelAppearance.paper)).tint(Color(nsColor: PanelAppearance.forest))
            .sheet(isPresented: $model.showCleanup) {
                if let plan = model.cleanupPlan { CleanupPreviewView(model: model, plan: plan) }
            }
    }
    @ViewBuilder private var intake: some View {
        if let hotKey { ShortcutSettingsView(hotKey: hotKey) }
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "square.on.square").font(.system(size: 19)).foregroundStyle(Color(nsColor: PanelAppearance.forest))
                .frame(width: 42, height: 42).background(Color(nsColor: PanelAppearance.forest).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 7) {
                Text(L(.manualInputTitle)).font(.system(size: 14, weight: .semibold))
                Text(L(.manualInputHelp)).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        Divider().padding(.vertical, 2)
        VStack(alignment: .leading, spacing: 12) {
            heading(.automaticInputTitle, symbol: "clipboard")
            VStack(spacing: 0) {
                switchRow(.automaticInputEnabled, value: model.binding(\.enabled))
                Divider()
                HStack {
                    Text(L(.settingsTypes)).foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 8) {
                        Toggle(L(.inputImages), isOn: model.binding(\.images))
                        Toggle(L(.inputText), isOn: model.binding(\.text))
                        Toggle(L(.inputFiles), isOn: model.binding(\.files))
                    }.toggleStyle(.button).controlSize(.small)
                }.padding(16)
                Divider()
                switchRow(.inputExisting, value: model.binding(\.includeExisting))
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
                .disabled(model.saving)
            Text(L(.settingsTypeHelp)).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4).padding(.horizontal, 3)
        }
        VStack(alignment: .leading, spacing: 12) {
            heading(.captureSettingsTitle, symbol: "folder")
            VStack(spacing: 0) {
                switchRow(.captureSettingsEnabled, value: Binding(get: { model.captureEnabled }, set: { _ in model.toggleCapture() }))
                Divider()
                HStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 22)).foregroundStyle(Color(nsColor: PanelAppearance.forest))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.capturePath == L(.captureNoFolder) ? model.capturePath : URL(fileURLWithPath: model.capturePath).lastPathComponent)
                            .font(.system(size: 13, weight: .medium))
                        if model.capturePath != L(.captureNoFolder) {
                            Text(model.capturePath).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button(L(.chooseCaptureFolder), action: model.chooseFolder).controlSize(.small)
                }.padding(16)
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
            Label(model.captureStatus, systemImage: model.captureEnabled ? "circle.fill" : "pause.circle").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(L(.captureSettingsHelp)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(4)
        }
    }
    @ViewBuilder private var storage: some View {
        HStack(spacing: 16) {
            Image(systemName: "archivebox").font(.system(size: 22)).foregroundStyle(Color(nsColor: PanelAppearance.forest))
                .frame(width: 48, height: 48).background(Color(nsColor: PanelAppearance.forest).opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(L(.libraryTitle)).font(.system(size: 14, weight: .semibold))
                Text(model.usage.map { size($0.values.reduce(0, +)) } ?? L(.libraryLoading)).font(.system(size: 25, weight: .medium, design: .rounded))
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            heading(.libraryLocation, symbol: "folder")
            VStack(alignment: .leading, spacing: 14) {
                Text((model.libraryURL.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button(L(.libraryReveal)) { NSWorkspace.shared.activateFileViewerSelecting([model.libraryURL]) }.controlSize(.small)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
        VStack(alignment: .leading, spacing: 12) {
            heading(.libraryUsage, symbol: "externaldrive")
            if let usage = model.usage {
                VStack(spacing: 0) {
                    usageRow(.libraryMaterials, bytes: usage["Materials", default: 0]); Divider()
                    usageRow(.libraryExports, bytes: usage["Exports", default: 0]); Divider()
                    usageRow(.libraryDrafts, bytes: usage["Drafts", default: 0] + usage["Transactions", default: 0] + usage["CleanupRecords", default: 0])
                }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            } else if model.usageFailed {
                Text(L(.libraryUnavailable)).foregroundStyle(.secondary)
                Button(L(.settingsRetry)) { Task { await model.refreshUsage() } }
            } else { ProgressView().controlSize(.small) }
            Text(L(.libraryHelp)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(4)
        }
        VStack(alignment: .leading, spacing: 12) {
            heading(.cleanupTitle, symbol: "trash")
            Text(L(.cleanupHelp)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(4)
            HStack(spacing: 12) {
                Button(L(model.cleanupBusy ? .cleanupWorking : .cleanupPreview)) { Task { await model.previewCleanup() } }
                    .disabled(!model.canOfferCleanup)
                if model.cleanupBusy { ProgressView().controlSize(.small) }
            }
            if let message = model.cleanupMessage {
                Label(message, systemImage: model.cleanupFailed ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.system(size: 12)).foregroundStyle(model.cleanupFailed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func heading(_ key: MessageKey, symbol: String) -> some View {
        Label(L(key), systemImage: symbol).font(.system(size: 13, weight: .semibold))
    }
    private func switchRow(_ key: MessageKey, value: Binding<Bool>) -> some View {
        HStack {
            Text(L(key)); Spacer(minLength: 16)
            Toggle(L(key), isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }.padding(16).font(.system(size: 13))
    }
    private func usageRow(_ key: MessageKey, bytes: Int64) -> some View {
        HStack { Text(L(key)); Spacer(); Text(size(bytes)).foregroundStyle(.secondary) }.font(.system(size: 13)).padding(16)
    }
    private func size(_ bytes: Int64) -> String {
        IntakeSettingsModel.size(bytes)
    }
}

private struct CleanupPreviewView: View {
    @ObservedObject var model: IntakeSettingsModel
    let plan: StorageCleanupPlan
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L(.cleanupPreviewTitle), systemImage: "trash").font(.system(size: 18, weight: .semibold))
            let selected = model.selectedCleanupPlan ?? plan
            Text(String(format: L(.cleanupSummary), selected.materialCount, selected.exportCount, selected.completedEditCount, IntakeSettingsModel.size(selected.byteCount)))
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Text(String(format: L(.stagingSummary), selected.stagingCount)).font(.system(size: 13)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(plan.targets, id: \.relativePath) { target in
                        HStack(spacing: 12) {
                            Toggle(L(.cleanupConfirm), isOn: Binding(get: { model.selectedCleanupPaths.contains(target.relativePath) }, set: { selected in
                                if selected { model.selectedCleanupPaths.insert(target.relativePath) } else { model.selectedCleanupPaths.remove(target.relativePath) }
                            })).labelsHidden().toggleStyle(.checkbox).disabled(model.cleanupBusy)
                            Image(systemName: target.kind == .material ? "doc" : "doc.on.doc").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(target.kind == .material ? target.title : L(target.kind == .completedEdit ? .cleanupCompletedEdits : target.kind == .unownedStaging ? .stagingTitle : .libraryExports)).lineLimit(2)
                                if target.kind == .unownedStaging { Text(target.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                            }
                            Spacer(minLength: 16)
                            Text(IntakeSettingsModel.size(target.byteCount)).foregroundStyle(.secondary)
                            if target.kind == .unownedStaging {
                                Button(L(.stagingExport)) { model.chooseStagingExport(target) }.disabled(model.cleanupBusy)
                            }
                        }.font(.system(size: 13)).padding(.vertical, 12)
                        Divider()
                    }
                    ForEach(plan.stagingInventory.filter { $0.disposition != .unowned }, id: \.relativePath) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L(item.disposition == .referenced ? .stagingReferenced : .stagingInspect)).font(.system(size: 13))
                            Text(item.relativePath).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                        Divider()
                    }
                }
            }.frame(maxHeight: 240)
            if let message = model.cleanupMessage { Text(message).font(.system(size: 12)).foregroundStyle(model.cleanupFailed ? Color.red : Color.secondary) }
            Text(L(.stagingHelp)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L(.cleanupTrashHelp)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(4)
            HStack {
                if model.cleanupBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button(L(.cancel), action: model.cancelCleanup).keyboardShortcut(.cancelAction).disabled(model.cleanupBusy)
                Button(L(model.cleanupBusy ? .cleanupWorking : .cleanupConfirm), role: .destructive) { Task { await model.confirmCleanup() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.cleanupBusy || selected.targets.isEmpty)
            }
        }.padding(28).frame(width: 500)
    }
}

struct ShortcutSettingsView: View {
    @ObservedObject var hotKey: HotKey
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L(.shortcutTitle), systemImage: "keyboard").font(.system(size: 14, weight: .semibold))
            Text(L(hotKey.status.message)).font(.system(size: 12)).foregroundStyle(hotKey.status == .registered ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            if hotKey.status != .registered { Button(L(.shortcutRetry)) { hotKey.retry() } }
        }
    }
}
