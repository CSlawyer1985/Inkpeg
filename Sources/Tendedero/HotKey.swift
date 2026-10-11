import AppKit
import Carbon
import Combine
import InkpegCore

/// Own both Carbon registrations. Failed attempts release the handler before
/// retrying, so one shortcut never accumulates handlers or stale callbacks.
final class HotKey: ObservableObject {
    enum Status: Equatable {
        case registered, conflict, failed
        var message: MessageKey {
            switch self { case .registered: return .shortcutActive; case .conflict: return .shortcutConflict; case .failed: return .shortcutFailed }
        }
    }
    struct Backend {
        var install: (@escaping () -> Void) -> (OSStatus, (() -> Void)?)
        var register: (Int, Int) -> (OSStatus, (() -> Void)?)
        static let carbon = Backend(install: { action in
            let box = Unmanaged.passRetained(Callback(action))
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            var handler: EventHandlerRef?
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard read == noErr, id.signature == HotKey.signature, id.id == 1 else { return OSStatus(eventNotHandledErr) }
                let action = Unmanaged<Callback>.fromOpaque(context).takeUnretainedValue().action
                DispatchQueue.main.async(execute: action)
                return noErr
            }, 1, &spec, box.toOpaque(), &handler)
            guard status == noErr, let handler else { box.release(); return (status == noErr ? OSStatus(paramErr) : status, nil) }
            return (noErr, { RemoveEventHandler(handler); box.release() })
        }, register: { key, modifiers in
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: HotKey.signature, id: 1)
            let status = RegisterEventHotKey(UInt32(key), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, let ref else { return (status == noErr ? OSStatus(paramErr) : status, nil) }
            return (noErr, { UnregisterEventHotKey(ref) })
        })
    }
    private final class Callback {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
    }
    private static let signature: OSType = 0x5445_4E44
    @Published private(set) var status: Status = .failed
    private let keyCode: Int, modifiers: Int
    private let backend: Backend
    private let action: () -> Void
    private var removeHandler: (() -> Void)?
    private var unregister: (() -> Void)?

    init(keyCode: Int, modifiers: Int, backend: Backend = .carbon, action: @escaping () -> Void) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.backend = backend; self.action = action
        retry()
    }
    func retry() {
        guard status != .registered else { return }
        let handler = backend.install { [weak self] in
            guard let self, self.status == .registered else { return }
            self.action()
        }
        guard handler.0 == noErr else { handler.1?(); status = .failed; return }
        let registration = backend.register(keyCode, modifiers)
        guard registration.0 == noErr else {
            registration.1?(); handler.1?()
            status = registration.0 == eventHotKeyExistsErr ? .conflict : .failed
            return
        }
        removeHandler = handler.1; unregister = registration.1; status = .registered
    }
    deinit { unregister?(); removeHandler?() }
}

/// The menu action remains available even while global registration fails.
@MainActor enum ShortcutMenu {
    static func append(to menu: NSMenu, hotKey: HotKey?, title: String, action: @escaping () -> Void) {
        let open = ClosureMenuItem(title, handler: action)
        if hotKey?.status == .registered { open.keyEquivalent = "t"; open.keyEquivalentModifierMask = [.control, .option] }
        menu.addItem(open)
        let status = NSMenuItem(title: L(hotKey?.status.message ?? .shortcutFailed), action: nil, keyEquivalent: "")
        status.isEnabled = false; menu.addItem(status)
        if let hotKey, hotKey.status != .registered { menu.addItem(ClosureMenuItem(L(.shortcutRetry)) { hotKey.retry() }) }
    }
}
