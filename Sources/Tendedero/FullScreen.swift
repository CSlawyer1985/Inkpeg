import AppKit
import Darwin

enum FullScreen {
    enum State: Equatable { case desktop, fullScreen, unknown }

    /// Private WindowServer data is optional, not a launch-time dependency.
    /// Unknown symbols or data must never be interpreted as a safe desktop.
    struct Capability {
        private let readSpaces: (() -> Any?)?
        init(resolveSymbol: (String) -> UnsafeMutableRawPointer? = FullScreen.resolveSymbol) {
            guard let main = resolveSymbol("CGSMainConnectionID"),
                  let copy = resolveSymbol("CGSCopyManagedDisplaySpaces") else {
                readSpaces = nil
                return
            }
            let connection = unsafeBitCast(main, to: (@convention(c) () -> Int32).self)
            let spaces = unsafeBitCast(copy, to: (@convention(c) (Int32) -> Unmanaged<CFTypeRef>?).self)
            readSpaces = { spaces(connection())?.takeRetainedValue() }
        }

        func state(displayIdentifier: String?) -> State {
            FullScreen.parse(readSpaces?(), displayIdentifier: displayIdentifier)
        }
    }

    private static let capability = Capability()

    static func state(on screen: NSScreen) -> State {
        capability.state(displayIdentifier: uuidString(for: screen))
    }

    static func parse(_ data: Any?, displayIdentifier: String?) -> State {
        guard let displays = data as? [[String: Any]], !displays.isEmpty else { return .unknown }
        let entry: [String: Any]?
        // Separate Spaces disabled produces one entry shared by all displays.
        if displays.count == 1 {
            entry = displays.first
        } else {
            guard let displayIdentifier else { return .unknown }
            let matching = displays.filter { ($0["Display Identifier"] as? String) == displayIdentifier }
            guard matching.count == 1 else { return .unknown }
            entry = matching.first
        }
        guard let current = entry?["Current Space"] as? [String: Any],
              let type = current["type"] as? NSNumber,
              CFGetTypeID(type) != CFBooleanGetTypeID() else { return .unknown }
        switch type.doubleValue {
        case 0: return .desktop
        case 4: return .fullScreen
        default: return .unknown
        }
    }

    private static func resolveSymbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let process = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(process) }
        return dlsym(process, name)
    }

    private static func uuidString(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
