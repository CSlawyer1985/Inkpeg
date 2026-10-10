import InkpegCore

extension ClipboardIntakeState {
    var messageKey: MessageKey {
        switch self {
        case .active: return .clipboardActive
        case .paused: return .clipboardPaused
        case .hidden: return .clipboardHidden
        case .pending: return .clipboardPending
        case .changedFile: return .clipboardChangedFile
        case .unavailable: return .clipboardUnavailable
        case .rejected: return .clipboardRejected
        }
    }
}
