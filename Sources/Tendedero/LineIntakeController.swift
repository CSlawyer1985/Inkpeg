import InkpegCore

/// Feedback for explicit paste/drop actions, separate from automatic intake.
@MainActor final class LineIntakeController {
    private let line: Line
    private let service: ClipboardImportService
    private var awaitingCompletion = false
    private var savedInput = false
    init(line: Line, service: ClipboardImportService) {
        self.line = line; self.service = service
        line.onPasteInput = { [weak self] in Task { await self?.paste() } }
        line.onReceiveInput = { [weak self] in self?.enqueue($0) ?? false }
    }
    func paste() async {
        guard begin() else { return }
        await service.pasteCurrent()
        refresh()
    }
    func enqueue(_ requests: [ImportRequest]) -> Bool {
        guard !requests.isEmpty, requests.count <= ClipboardLimits.items, begin() else { return false }
        guard service.enqueueManual(requests) else {
            awaitingCompletion = false; line.inputFeedback = L(.inputNothingNew)
            return false
        }
        return true
    }
    /// Called only from the service's successful new-material callback.
    func imported() { if awaitingCompletion { savedInput = true } }
    func refresh() {
        line.canReceiveInput = service.canReceiveManual
        guard awaitingCompletion else { return }
        if service.pendingCount > 0 {
            line.inputFeedback = L(service.state.messageKey)
            return // Keep tracking this input through retry or explicit discard.
        }
        guard !service.hasUnsavedInput else { return }
        awaitingCompletion = false
        if [.hidden, .unavailable, .rejected].contains(service.state) {
            line.inputFeedback = L(service.state.messageKey)
        } else {
            line.inputFeedback = L(savedInput ? .inputSaved : .inputNothingNew)
        }
    }
    private func begin() -> Bool {
        guard !awaitingCompletion, service.canReceiveManual else { return false }
        awaitingCompletion = true; savedInput = false
        line.inputFeedback = L(.inputReceiving)
        return true
    }
}
