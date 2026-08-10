import AppKit
import SwiftUI
import ClipsshCore

@MainActor
final class TargetsWindowController: NSObject, NSWindowDelegate {
    /// Returns whether registering `spec` succeeded, so a failed attempt can
    /// be reported to the user instead of persisted silently.
    var onHotkeyChange: ((String?) -> Bool)?

    private(set) var window: NSWindow?
    private(set) var model: TargetsModel?
    private let coordinator: SendCoordinator

    /// Set by the app delegate when the saved hotkey could not be
    /// re-registered at launch (e.g. another app now owns the combination).
    /// Applied to the model's `hotkeyMessage` — immediately if the model
    /// already exists, otherwise as soon as `show()` creates it — so the
    /// Targets window is honest that the persisted combination is not
    /// currently active. The hotkey itself is left untouched.
    var launchHotkeyFailureMessage: String? {
        didSet {
            if let launchHotkeyFailureMessage {
                model?.hotkeyMessage = launchHotkeyFailureMessage
            }
        }
    }

    init(coordinator: SendCoordinator) {
        self.coordinator = coordinator
        super.init()
    }

    deinit {}

    /// The window is reused rather than recreated, so closing it (the red
    /// button, Cmd-W, or quitting the app) must flush any Label/Destination
    /// text the user typed but never submitted — otherwise it is silently
    /// lost, the same failure mode `commitPendingTextEdits` exists to avoid
    /// on a target switch.
    func windowWillClose(_ notification: Notification) {
        model?.commitPendingTextEdits()
    }

    func show() {
        if let window {
            // Reopening must not discard text the user typed into Label or
            // Destination but never submitted — refresh() re-syncs the draft
            // fields from stored state, so any pending edit has to land
            // first or it is silently lost.
            model?.commitPendingTextEdits()
            model?.refresh()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = TargetsModel(coordinator: coordinator)
        model.onHotkeyChange = { [weak self] spec in self?.onHotkeyChange?(spec) ?? true }
        if let launchHotkeyFailureMessage {
            model.hotkeyMessage = launchHotkeyFailureMessage
        }
        self.model = model

        let created = NSWindow(contentViewController: NSHostingController(rootView: TargetsView(model: model)))
        created.title = "clipssh-mac Targets"
        created.styleMask = [.titled, .closable, .resizable]
        // This controller keeps `created` and reuses it on the next show(), so
        // it must never be deallocated out from under that reference when the
        // user closes it. init(contentViewController:) already defaults this
        // to false; set it explicitly so the invariant survives a future
        // switch to a different NSWindow initializer.
        created.isReleasedWhenClosed = false
        created.setContentSize(NSSize(width: 700, height: 380))
        created.center()
        created.delegate = self
        window = created
        NSApp.activate(ignoringOtherApps: true)
        created.makeKeyAndOrderFront(nil)
    }
}
