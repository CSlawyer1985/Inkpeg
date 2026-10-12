import Foundation
import Darwin
import ImageIO
import CoreGraphics

/// Install only the reviewed product examples, never replace an existing library.
public enum StarterWorkspaceBootstrap {
    @discardableResult
    public static func installIfAbsent(from template: URL, at root: URL) throws -> Bool {
        let fm = FileManager.default
        try OwnedPaths(root).verifyRoot()
        if fm.fileExists(atPath: root.path) { return false }
        let snapshot = try validate(template)
        let parent = root.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try OwnedPaths(root).verifyRoot()
        let stage = parent.appendingPathComponent(".inkpeg-starter-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        let paths = ["state.json", "clipboard-settings.json"] + snapshot.materials.flatMap { $0.versions.map(\.relativePath) }
        for path in paths {
            let target = stage.appendingPathComponent(path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: template.appendingPathComponent(path), to: target)
        }
        _ = try validate(stage)
        // RENAME_EXCL is atomic: another process creating the root wins untouched.
        let result = stage.path.withCString { source in root.path.withCString { destination in renamex_np(source, destination, UInt32(RENAME_EXCL)) } }
        if result != 0 {
            if errno == EEXIST { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return true
    }

    public static func validate(_ template: URL) throws -> WorkspaceSnapshot {
        let fm = FileManager.default, paths = OwnedPaths(template)
        try paths.verifyRoot()
        let stateURL = try paths.url("state.json")
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: stateURL))
        guard snapshot.schemaVersion == 1, snapshot.generation == 0,
              snapshot.materials.count == 3, Set(snapshot.materials.map(\.id)).count == 3,
              Set(snapshot.materials.map { $0.kind.rawValue }) == ["text", "image", "pdf"],
              Set(snapshot.materials.map(\.order)) == [0, 1, 2],
              snapshot.matters.count == 1, snapshot.matters[0].id == MatterGroup.ungroupedID,
              snapshot.selectedMatterID == MatterGroup.ungroupedID,
              !snapshot.privacyHidden, snapshot.captureFolder == nil else { throw StoreError.invalidSnapshot }
        let settingsURL = try paths.url("clipboard-settings.json")
        let settingsData = try Data(contentsOf: settingsURL)
        guard settingsData.count <= 4096 else { throw StoreError.invalidSnapshot }
        let settings = try JSONDecoder().decode(ClipboardPreference.self, from: settingsData)
        guard settings.version == 2, !settings.enabled, !settings.includeExisting else { throw StoreError.invalidSnapshot }
        var expected: Set<String> = ["state.json", "clipboard-settings.json"]
        for record in snapshot.materials {
            guard record.status == .hanging, !record.pinned, record.matterID == MatterGroup.ungroupedID,
                  record.source.filePath == nil, record.source.fileBookmark == nil,
                  record.versions.count == 1, let version = record.activeVersion,
                  record.originalVersionID == version.id, version.kind == .original,
                  version.relativePath.hasPrefix("Materials/" + record.id.uuidString + "/"),
                  URL(fileURLWithPath: version.relativePath).lastPathComponent.hasPrefix(version.id.uuidString + ".") else { throw StoreError.invalidSnapshot }
            let payload = try Data(contentsOf: paths.url(version.relativePath))
            guard payload.count <= 64 * 1024 * 1024, payload.count == version.byteCount,
                  ContentStore.digest(payload) == version.sha256 else { throw StoreError.recoveryRequired }
            switch record.kind {
            case .text:
                guard record.source.origin == .note, let text = String(data: payload, encoding: .utf8), !text.isEmpty else { throw StoreError.invalidSnapshot }
            case .image:
                try ImageAdmission.validate(payload)
                guard let source = CGImageSourceCreateWithData(payload as CFData, nil), CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw StoreError.invalidSource }
            case .pdf:
                guard let provider = CGDataProvider(data: payload as CFData), let pdf = CGPDFDocument(provider), pdf.numberOfPages > 0 else { throw StoreError.invalidSource }
            case .file: throw StoreError.invalidSnapshot
            }
            expected.insert(version.relativePath)
        }
        // Relative names are assembled structurally. NSURL may return /private/var
        // for children of a /var URL, so slicing absolute path strings is unsafe.
        var actual = Set<String>()
        func visit(_ folder: URL, prefix: String) throws {
            for url in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]) {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
                guard values.isSymbolicLink != true else { throw StoreError.invalidPath }
                let relative = prefix + url.lastPathComponent
                if values.isDirectory == true { try visit(url, prefix: relative + "/") }
                else if values.isRegularFile == true {
                    if url.lastPathComponent != ".DS_Store" { actual.insert(relative) }
                } else { throw StoreError.invalidPath }
            }
        }
        try visit(template, prefix: "")
        guard actual == expected else { throw StoreError.invalidSnapshot }
        return snapshot
    }
}
