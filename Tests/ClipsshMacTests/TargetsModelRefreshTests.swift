import Foundation
import Testing
import ClipsshCore
@testable import ClipsshMac

/// Regression coverage for CodeRabbit's "the reused window shows a stale
/// target list" finding against `TargetsWindowController.show()`. The reuse
/// path already calls `model?.refresh()`, and `refresh()` already reloads
/// targets, repairs a dangling selection, and re-syncs the draft text
/// fields — these tests pin that behavior so it cannot silently regress.
/// The scenario each test simulates is the menu bar mutating the coordinator
/// (adding a target, changing the default) while the Targets window is
/// closed, then the window being reopened.

@MainActor
@Test func refreshPicksUpATargetAddedWhileTheWindowWasClosed() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory)
    _ = coordinator.addTarget(destination: "one.example.com", label: "one")
    let model = TargetsModel(coordinator: coordinator)

    // Simulates MenuRenderer.onAddDiscovered adding a target while closed.
    let second = coordinator.addTarget(destination: "two.example.com", label: "two")

    model.refresh()

    #expect(model.targets.map(\.id).contains(second.id))
    #expect(model.targets.count == 2)
}

@MainActor
@Test func refreshPicksUpADefaultChangeMadeWhileTheWindowWasClosed() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory)
    let first = coordinator.addTarget(destination: "one.example.com", label: "one")
    let second = coordinator.addTarget(destination: "two.example.com", label: "two")
    let model = TargetsModel(coordinator: coordinator)
    #expect(model.defaultID == first.id)

    // Simulates MenuRenderer.onSelectTarget changing the default while closed.
    coordinator.setDefault(second)
    model.refresh()

    #expect(model.defaultID == second.id)
}

/// If the selected target vanishes from the coordinator while the window is
/// closed, `refresh()` must not leave `selection` pointing at a ghost — it
/// must repair to the coordinator's default, or the first remaining target.
@MainActor
@Test func refreshRepairsTheSelectionWhenItsTargetWasRemoved() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory)
    let first = coordinator.addTarget(destination: "one.example.com", label: "one")
    let second = coordinator.addTarget(destination: "two.example.com", label: "two")
    let model = TargetsModel(coordinator: coordinator)
    model.selection = second.id

    // Removed directly on the coordinator, not via model.remove(), to
    // simulate a mutation made while this window was closed.
    coordinator.removeTarget(second)
    model.refresh()

    #expect(model.selection != second.id)
    #expect(model.selection == coordinator.config.defaultTargetID)
    #expect(model.selection == first.id)
}

/// `refresh()` calls `syncFields()` unconditionally, not only when repairing
/// `selection`. This matters because `selection`'s `didSet` (which also
/// calls `syncFields()`) never fires when the id does not change — so if the
/// selected target's own data changed underneath the model while the window
/// was closed, only the explicit `syncFields()` call in `refresh()` picks it
/// up.
@MainActor
@Test func refreshResyncsDraftFieldsForAnUnchangedSelectionWithEditedData() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory)
    var target = coordinator.addTarget(destination: "one.example.com", label: "old label")
    target.port = 22
    coordinator.updateTarget(target)
    let model = TargetsModel(coordinator: coordinator)
    #expect(model.labelText == "old label")
    #expect(model.destinationText == "one.example.com")
    #expect(model.portText == "22")

    // Edited directly on the coordinator, not via the model's own setters,
    // to simulate a mutation made while this window was closed. Selection
    // stays pointed at the same id throughout.
    target.label = "new label"
    target.destination = "two.example.com"
    target.port = 2222
    coordinator.updateTarget(target)
    model.refresh()

    #expect(model.labelText == "new label")
    #expect(model.destinationText == "two.example.com")
    #expect(model.portText == "2222")
}

@MainActor
@Test func refreshLeavesEverythingEmptyWhenNoTargetsRemain() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory)
    let target = coordinator.addTarget(destination: "one.example.com", label: "one")
    let model = TargetsModel(coordinator: coordinator)

    coordinator.removeTarget(target)
    model.refresh()

    #expect(model.targets.isEmpty)
    #expect(model.selection == nil)
    #expect(model.labelText == "")
    #expect(model.destinationText == "")
    #expect(model.portText == "")
}
