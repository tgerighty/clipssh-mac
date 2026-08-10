import AppKit
import SwiftUI
import ClipsshCore

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
