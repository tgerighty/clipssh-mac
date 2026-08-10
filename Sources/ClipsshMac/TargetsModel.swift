import SwiftUI
import ClipsshCore

@MainActor
final class TargetsModel: ObservableObject {
    @Published var targets: [Target] = []
    @Published var defaultID: UUID?
    @Published var selection: UUID? {
        didSet {
            // A target switch (via the list, add, or remove) must not silently
            // drop whatever the user was typing for the target they are
            // leaving.
            commitTextFields(for: oldValue)
            syncFields()
        }
    }
    @Published var hotkey: String?
    /// Shown next to the hotkey recorder, e.g. when a combination is already
    /// owned by another app. Empty when there is nothing to report.
    @Published var hotkeyMessage = ""
    @Published var testMessage = ""
    @Published var isTesting = false
    /// What the user has typed in the Label field. Kept separate from
    /// `Target.label` so it is not persisted (and `targets` not reassigned)
    /// on every keystroke — see `commitPendingTextEdits`.
    @Published var labelText = ""
    /// Same as `labelText`, for the Destination field.
    @Published var destinationText = ""
    /// What the user has typed in the Port field. Kept separate from
    /// `Target.port` so a stray keystroke (e.g. "2222x") never destroys a
    /// working stored value — see `setPortText`.
    @Published var portText = ""

    /// Set by the window controller so a hotkey edit takes effect at once.
    /// Returns whether registration succeeded, so a failed attempt (e.g. the
    /// combination is already owned by another app) can be reported instead
    /// of silently persisted.
    var onHotkeyChange: ((String?) -> Bool)?

    private let coordinator: SendCoordinator

    init(coordinator: SendCoordinator) {
        self.coordinator = coordinator
        reload()
        selection = coordinator.config.defaultTargetID
        hotkey = coordinator.config.hotkey
    }

    deinit {}

    var selected: Target? {
        targets.first { $0.id == selection }
    }

    func add() {
        let target = coordinator.addTarget(destination: "host.example.com", label: "New target")
        reload()
        selection = target.id
    }

    func remove() {
        guard let target = selected else { return }
        coordinator.removeTarget(target)
        reload()
        selection = targets.first?.id
    }

    func makeDefault() {
        guard let target = selected else { return }
        coordinator.setDefault(target)
        reload()
    }

    func setLabelText(_ text: String) {
        labelText = text
    }

    func setDestinationText(_ text: String) {
        destinationText = text
    }

    /// Persists `labelText`/`destinationText` for the currently selected
    /// target, if either differs from the stored value. Called on submit and
    /// on focus loss, never per keystroke — see the property comments above.
    func commitPendingTextEdits() {
        commitTextFields(for: selection)
    }

    private func commitTextFields(for id: UUID?) {
        guard let id, let target = targets.first(where: { $0.id == id }) else { return }
        var updated = target
        var changed = false
        if updated.label != labelText { updated.label = labelText; changed = true }
        // A destination ssh could misread (empty, or beginning with "-", which
        // ssh parses as an OPTION rather than a host) is never committed; the
        // field keeps showing the draft until it is valid. Matches the
        // rejection Uploader itself applies before ever sending.
        let trimmedDestination = destinationText.trimmingCharacters(in: .whitespaces)
        if Uploader.isValidDestination(trimmedDestination), updated.destination != trimmedDestination {
            updated.destination = trimmedDestination
            changed = true
        }
        guard changed else { return }
        coordinator.updateTarget(updated)
        reload()
    }

    /// True when the destination field holds text that cannot be committed:
    /// empty, beginning with "-", or containing whitespace/NUL. Mirrors
    /// `Uploader.isValidDestination`, the same check applied before a send.
    var destinationIsInvalid: Bool {
        !Uploader.isValidDestination(destinationText.trimmingCharacters(in: .whitespaces))
    }

    /// True when the field holds text that cannot be committed: non-empty and
    /// not an integer in 1...65535. Empty text is valid — it commits `nil`.
    var portIsInvalid: Bool {
        guard !portText.isEmpty else { return false }
        guard let value = Int(portText) else { return true }
        return !(1...65535).contains(value)
    }

    /// Only commits when the text is unambiguous (empty, or 1...65535).
    /// Anything else — including a single bad keystroke in otherwise valid
    /// text — leaves the previously stored port untouched, so nothing is
    /// destroyed while the field merely looks invalid.
    func setPortText(_ text: String) {
        portText = text
        guard let target = selected else { return }
        if text.isEmpty {
            commitPort(nil, for: target)
        } else if let value = Int(text), (1...65535).contains(value) {
            commitPort(value, for: target)
        }
    }

    private func commitPort(_ port: Int?, for target: Target) {
        guard target.port != port else { return }
        var updated = target
        updated.port = port
        coordinator.updateTarget(updated)
        reload()
    }

    private func syncFields() {
        labelText = selected?.label ?? ""
        destinationText = selected?.destination ?? ""
        portText = selected?.port.map(String.init) ?? ""
    }

    /// Clearing (`spec == nil`) always succeeds. Setting a combination only
    /// persists if it actually registers; on failure the previous hotkey is
    /// restored (and re-registered, so a working combination is never lost)
    /// and `hotkeyMessage` explains why.
    func setHotkey(_ spec: String?) {
        guard let spec else {
            coordinator.setHotkey(nil)
            hotkey = nil
            hotkeyMessage = ""
            _ = onHotkeyChange?(nil)
            return
        }
        guard onHotkeyChange?(spec) == true else {
            hotkeyMessage = "That combination is already in use by another app."
            _ = onHotkeyChange?(hotkey)
            return
        }
        coordinator.setHotkey(spec)
        hotkey = spec
        hotkeyMessage = ""
    }

    func test() {
        guard let target = selected else { return }
        isTesting = true
        testMessage = "Testing…"
        // ssh can block for the full connect timeout, so never on the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self, coordinator] in
            let message = coordinator.testConnection(target)
            DispatchQueue.main.async {
                guard let self else { return }
                self.testMessage = message
                self.isTesting = false
            }
        }
    }

    /// Re-reads the coordinator state. Called when the window is shown again,
    /// because the menu can add a target or change the default while the
    /// window is closed.
    func refresh() {
        reload()
        if selection == nil || !targets.contains(where: { $0.id == selection }) {
            selection = coordinator.config.defaultTargetID ?? targets.first?.id
        }
        syncFields()
    }

    private func reload() {
        targets = coordinator.config.targets
        defaultID = coordinator.config.defaultTargetID
    }
}
