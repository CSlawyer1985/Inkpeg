import Foundation
import InkpegCore

/// Only controlled text reaches the UI; NSError descriptions can contain
/// source paths or content and must not be used as user-facing feedback.
struct InteractionFeedback {
    enum Action { case storage, chooseFiles, settings, wait, recovery }
    let message: MessageKey
    let action: Action
    init(_ error: Error) {
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(cocoa.code) {
            message = .feedbackPermission; action = .settings
            return
        }
        switch error as? StoreError {
        case .budgetExceeded, .unavailableSpace: message = .feedbackCapacity; action = .storage
        case .sourceChanged, .invalidSource, .notFound: message = .feedbackSourceChanged; action = .chooseFiles
        case .invalidPath: message = .feedbackPath; action = .settings
        case .operationInProgress: message = .feedbackBusy; action = .wait
        default:
            if cocoa.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoa.code) {
                message = .feedbackPath; action = .settings
            } else { message = .feedbackRecovery; action = .recovery }
        }
    }
    var button: MessageKey {
        switch action {
        case .storage: return .settingsStorage
        case .chooseFiles: return .importFiles
        case .settings: return .intakeSettings
        case .wait: return .retryLater
        case .recovery: return .reviewPendingTitle
        }
    }
}
