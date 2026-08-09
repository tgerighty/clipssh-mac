import AppKit
import ClipsshCore

/// Adds threading and icon updates to SendCoordinator. Holds the in-flight flag,
/// because a second click during an upload must be ignored.
final class SendController {
    private let coordinator: SendCoordinator
    private weak var menuBar: MenuBarController?
    private var isSending = false

    init(coordinator: SendCoordinator, menuBar: MenuBarController) {
        self.coordinator = coordinator
        self.menuBar = menuBar
    }

    func send() {
        guard !isSending else { return }
        isSending = true
        menuBar?.setState(.sending)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = self.coordinator.performSend()
            DispatchQueue.main.async {
                self.isSending = false
                switch outcome {
                case .sent: self.menuBar?.setState(.success)
                case .failed: self.menuBar?.setState(.error)
                }
            }
        }
    }
}
