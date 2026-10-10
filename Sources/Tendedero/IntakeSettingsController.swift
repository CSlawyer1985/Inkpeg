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
    @Published var showCleanup = false
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
        guard let cleanupStore, !cleanupBusy else { return }
        cleanupBusy = true; cleanupMessage = nil; cleanupFailed = false
        defer { cleanupBusy = false }
        do {
            guard canClean() else { throw StoreError.invalidSource }
            let plan = try await cleanupStore.previewStorageCleanup()
            guard canClean() else { throw StoreError.invalidSource }
            cleanupPlan = plan
            if plan.targets.isEmpty { cleanupMessage = L(.cleanupEmpty) }
            else { showCleanup = true }
        } catch { cleanupFailed = true; cleanupMessage = L(.cleanupUnavailable) }
    }
    func confirmCleanup() async {
        guard let cleanupStore, let plan = cleanupPlan, showCleanup, !cleanupBusy else { return }
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
    func cancelCleanup() { guard !cleanupBusy else { return }; showCleanup = false; cleanupPlan = nil }
    func hideCleanup() { showCleanup = false; cleanupPlan = nil }
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
    init(service: ClipboardImportService, capture: CaptureFolderCoordinator, libraryURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Inkpeg", isDirectory: true), store: MaterialStore? = nil, line: Line? = nil) {
        model = IntakeSettingsModel(service: service, capture: capture, libraryURL: libraryURL, store: store,
            canClean: { [weak line] in line?.snapshot.privacyHidden != true }, onCleanup: { [weak line] snapshot in
                guard let line else { return }
                var next = (try? await line.store.load()) ?? snapshot; next.privacyHidden = line.snapshot.privacyHidden
                await line.render(next)
            })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 576, height: 730), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L(.intakeSettings); window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 500, height: 480)
        window.contentView = NSHostingView(rootView: IntakeSettingsView(model: model))
        super.init(window: window)
        if let line {
            privacySubscription = line.$snapshot.map(\.privacyHidden).removeDuplicates().sink { [weak model] hidden in
                if hidden { model?.hideCleanup() }
            }
        }
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("Unavailable") }
    func present() {
        model.refresh(); showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        Task { await model.refreshUsage() }
    }
}

private struct IntakeSettingsView: View {
    @ObservedObject var model: IntakeSettingsModel
    @State private var page = 0
    private let spacing: CGFloat = 22
    var body: some View {
        VStack(spacing: 0) {
            Picker(L(.intakeSettings), selection: $page) {
                Text(L(.settingsIntake)).tag(0); Text(L(.settingsStorage)).tag(1)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 184).padding(.top, 16).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: spacing) {
                    if page == 0 { intake } else { storage }
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
        }.background(Color(nsColor: .windowBackgroundColor))
            .sheet(isPresented: $model.showCleanup) {
                if let plan = model.cleanupPlan { CleanupPreviewView(model: model, plan: plan) }
            }
    }
    @ViewBuilder private var intake: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "square.on.square").font(.system(size: 19)).foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
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
                    Image(systemName: "folder").font(.system(size: 22)).foregroundStyle(Color.accentColor)
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
            Image(systemName: "archivebox").font(.system(size: 22)).foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
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
            Text(String(format: L(.cleanupSummary), plan.materialCount, plan.exportCount, IntakeSettingsModel.size(plan.byteCount)))
                .font(.system(size: 13)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(plan.targets, id: \.relativePath) { target in
                        HStack(spacing: 12) {
                            Image(systemName: target.kind == .material ? "doc" : "doc.on.doc").foregroundStyle(.secondary)
                            Text(target.kind == .material ? target.title : L(.libraryExports)).lineLimit(2)
                            Spacer(minLength: 16)
                            Text(IntakeSettingsModel.size(target.byteCount)).foregroundStyle(.secondary)
                        }.font(.system(size: 13)).padding(.vertical, 12)
                        Divider()
                    }
                }
            }.frame(maxHeight: 240)
            Text(L(.cleanupTrashHelp)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(4)
            HStack {
                if model.cleanupBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button(L(.cancel), action: model.cancelCleanup).keyboardShortcut(.cancelAction).disabled(model.cleanupBusy)
                Button(L(model.cleanupBusy ? .cleanupWorking : .cleanupConfirm), role: .destructive) { Task { await model.confirmCleanup() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.cleanupBusy)
            }
        }.padding(28).frame(width: 500)
    }
}
