import Foundation
import Testing
import ClipsshCore
@testable import ClipsshMac

/// Regression coverage for CodeRabbit's finding that `edit()` persisted the
/// Label/Destination fields on every keystroke (via `coordinator.updateTarget`
/// + `reload()`), which wrote the config file per character and reassigned
/// `targets`, which can disturb the text cursor while typing. `portText`
/// already avoided this by holding a draft value and only committing on a
/// validated value; these tests hold Label/Destination to the same standard.

@MainActor
@Test func editingLabelDoesNotPersistUntilCommitted() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory)
    let target = coordinator.addTarget(destination: "box.example.com", label: "original")
    let model = TargetsModel(coordinator: coordinator)
    model.selection = target.id

    model.setLabelText("typed but not committed")

    #expect(coordinator.config.targets.first?.label == "original")
}

/// An empty destination can never be used for a send, so it must never be
/// committed — matching the port field's existing rule that an unusable
/// value leaves the stored value untouched instead of destroying it.
@MainActor
@Test func commitPendingTextEditsRejectsAnEmptyDestination() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory)
    let target = coordinator.addTarget(destination: "box.example.com", label: "original")
    let model = TargetsModel(coordinator: coordinator)
    model.selection = target.id

    model.setDestinationText("   ")
    model.commitPendingTextEdits()

    #expect(coordinator.config.targets.first(where: { $0.id == target.id })?.destination == "box.example.com")
}

/// Mirrors UploaderTests's destination-validation coverage at the entry
/// point: a destination beginning with "-" (ssh reads it as an OPTION, e.g.
/// "-oProxyCommand=touch /tmp/pwned" runs an arbitrary LOCAL command) must
/// never be committed, matching the empty-destination rule above.
@MainActor
@Test func commitPendingTextEditsRejectsADestinationBeginningWithADash() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory)
    let target = coordinator.addTarget(destination: "box.example.com", label: "original")
    let model = TargetsModel(coordinator: coordinator)
    model.selection = target.id

    model.setDestinationText("-oProxyCommand=touch /tmp/pwned")
    model.commitPendingTextEdits()

    #expect(coordinator.config.targets.first(where: { $0.id == target.id })?.destination == "box.example.com")
}

@MainActor
@Test func commitPendingTextEditsRejectsADestinationWithAnEmbeddedSpace() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory)
    let target = coordinator.addTarget(destination: "box.example.com", label: "original")
    let model = TargetsModel(coordinator: coordinator)
    model.selection = target.id

    model.setDestinationText("ho st")
    model.commitPendingTextEdits()

    #expect(coordinator.config.targets.first(where: { $0.id == target.id })?.destination == "box.example.com")
}

@MainActor
@Test func commitPendingTextEditsPersistsTheDraft() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory)
    let target = coordinator.addTarget(destination: "box.example.com", label: "original")
    let model = TargetsModel(coordinator: coordinator)
    model.selection = target.id

    model.setLabelText("renamed")
    model.setDestinationText("new.example.com")
    model.commitPendingTextEdits()

    #expect(coordinator.config.targets.first?.label == "renamed")
    #expect(coordinator.config.targets.first?.destination == "new.example.com")
}

@MainActor
@Test func switchingSelectionCommitsThePreviousTargetsPendingEdit() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory)
    let first = coordinator.addTarget(destination: "one.example.com", label: "one")
    let second = coordinator.addTarget(destination: "two.example.com", label: "two")
    let model = TargetsModel(coordinator: coordinator)
    model.selection = first.id

    model.setLabelText("renamed one")
    model.selection = second.id

    #expect(coordinator.config.targets.first(where: { $0.id == first.id })?.label == "renamed one")
}

@MainActor
@Test func selectingATargetPopulatesTheDraftTextFields() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory)
    let first = coordinator.addTarget(destination: "one.example.com", label: "one")
    let model = TargetsModel(coordinator: coordinator)

    model.selection = first.id

    #expect(model.labelText == "one")
    #expect(model.destinationText == "one.example.com")
}

/// A CodeRabbit review twice claimed `init` leaves the draft fields empty
/// because Swift does not run `didSet` for assignments inside `init`. That
/// rule applies to plain stored properties, not `@Published` ones: assigning
/// `selection` goes through the property wrapper's setter, which does run
/// `didSet`. This test does not assign `selection` after construction (unlike
/// every other test in this file) so it exercises exactly the path the claim
/// was about, and pins the correct behavior against a third misdiagnosis.
@MainActor
@Test func initPopulatesTheDraftFieldsForTheDefaultTarget() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory)
    let target = coordinator.addTarget(destination: "box.example.com", label: "original")

    let model = TargetsModel(coordinator: coordinator)
    model.commitPendingTextEdits()

    #expect(model.labelText == "original")
    #expect(model.destinationText == "box.example.com")
    #expect(coordinator.config.targets.first(where: { $0.id == target.id })?.label == "original")
}
