import AppKit
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

private enum DetailField: Hashable {
    case label, destination
}

struct TargetsView: View {
    @ObservedObject var model: TargetsModel
    @FocusState private var focusedField: DetailField?

    var body: some View {
        HSplitView {
            listPane
            detailPane
        }
        .frame(minWidth: 640, minHeight: 340)
        // Catches focus moving away from Label/Destination to any other
        // control (Port, the buttons, the target list) or leaving the window
        // entirely, so an edit is never lost just because the user did not
        // press Return.
        .onChange(of: focusedField) { _ in
            model.commitPendingTextEdits()
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            List(model.targets, selection: $model.selection) { target in
                HStack {
                    Text(target.label)
                    Spacer()
                    if target.id == model.defaultID {
                        Image(systemName: "largecircle.fill.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(target.id)
            }
            Divider()
            HStack(spacing: 4) {
                Button(action: model.add) { Image(systemName: "plus") }
                Button(action: model.remove) { Image(systemName: "minus") }
                    .disabled(model.selected == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
        .frame(minWidth: 200)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let target = model.selected {
            Form {
                TextField("Label", text: Binding(
                    get: { model.labelText },
                    set: { model.setLabelText($0) }
                ))
                .focused($focusedField, equals: .label)
                .onSubmit { model.commitPendingTextEdits() }
                TextField("Destination", text: Binding(
                    get: { model.destinationText },
                    set: { model.setDestinationText($0) }
                ))
                .focused($focusedField, equals: .destination)
                .onSubmit { model.commitPendingTextEdits() }
                if model.destinationIsInvalid {
                    Text("Invalid destination.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("A bare host name is resolved through ~/.ssh/config.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Port", text: Binding(
                    get: { model.portText },
                    set: { model.setPortText($0) }
                ))
                if model.portIsInvalid {
                    Text("Port must be a number between 1 and 65535.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Section {
                    HStack {
                        Button("Set as default", action: model.makeDefault)
                            .disabled(target.id == model.defaultID)
                        Button("Test connection", action: model.test)
                            .disabled(model.isTesting)
                    }
                    if !model.testMessage.isEmpty {
                        Text(model.testMessage).font(.callout)
                    }
                    HotkeyRecorder(
                        spec: model.hotkey,
                        onRecord: { model.setHotkey($0) },
                        onClear: { model.setHotkey(nil) }
                    )
                    if !model.hotkeyMessage.isEmpty {
                        Text(model.hotkeyMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
        } else {
            Text("Select a target").foregroundStyle(.secondary)
        }
    }
}

/// Captures the next key press and reports it as a hotkey spec.
struct HotkeyRecorder: View {
    let spec: String?
    let onRecord: (String) -> Void
    let onClear: () -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text("Hotkey")
            Spacer()
            Button(buttonTitle) { toggle() }
            if spec != nil {
                Button("Clear") {
                    stop()
                    onClear()
                }
            }
        }
        .onDisappear { stop() }
    }

    private var buttonTitle: String {
        if isRecording { return "Press keys…" }
        return spec ?? "None"
    }

    private func toggle() {
        isRecording ? stop() : start()
    }

    private func start() {
        isRecording = true
        // A local monitor is enough: the window is key while recording, so no
        // Accessibility permission is needed here either.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !modifiers.isEmpty else { return event }
            onRecord(HotkeyManager.spec(keyCode: UInt32(event.keyCode), modifiers: modifiers))
            stop()
            return nil
        }
    }

    /// Safe to call more than once (re-toggle, Clear, then a late
    /// `.onDisappear`): removing an already-removed monitor is a no-op
    /// because `monitor` is nilled out immediately after the first removal.
    private func stop() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

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
