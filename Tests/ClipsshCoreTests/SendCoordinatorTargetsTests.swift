import Foundation
import Testing
@testable import ClipsshCore

// Covers SendCoordinator's target CRUD (add/remove/update/setDefault),
// persistence of those edits across a reload, and importing ssh aliases.

@Test func addTargetMakesTheFirstTargetTheDefault() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory).coordinator
    let first = coordinator.addTarget(destination: "one.example.com")
    let second = coordinator.addTarget(destination: "two.example.com")

    #expect(coordinator.config.defaultTargetID == first.id)
    #expect(coordinator.config.targets.map(\.id) == [first.id, second.id])
}

@Test func setDefaultChangesTheDefaultTarget() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory).coordinator
    _ = coordinator.addTarget(destination: "one.example.com")
    let second = coordinator.addTarget(destination: "two.example.com")

    coordinator.setDefault(second)

    #expect(coordinator.config.defaultTargetID == second.id)
}

@Test func removingTheDefaultTargetPromotesAnother() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory).coordinator
    let first = coordinator.addTarget(destination: "one.example.com")
    let second = coordinator.addTarget(destination: "two.example.com")

    coordinator.removeTarget(first)

    #expect(coordinator.config.targets.map(\.id) == [second.id])
    #expect(coordinator.config.defaultTargetID == second.id)
}

@Test func removingTheLastTargetLeavesNoDefault() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory).coordinator
    let only = coordinator.addTarget(destination: "one.example.com")

    coordinator.removeTarget(only)

    #expect(coordinator.config.targets.isEmpty)
    #expect(coordinator.config.defaultTargetID == nil)
}

@Test func updateTargetPersistsTheEdit() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory).coordinator
    var target = coordinator.addTarget(destination: "one.example.com")
    target.label = "renamed"
    target.port = 2222

    coordinator.updateTarget(target)

    #expect(coordinator.config.targets.first?.label == "renamed")
    #expect(coordinator.config.targets.first?.port == 2222)
}

@Test func changesSurviveAReload() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory).coordinator
    let target = coordinator.addTarget(destination: "one.example.com")
    coordinator.setHotkey("cmd+shift+2")

    let reopened = makeCoordinator(directory: directory).coordinator

    #expect(reopened.config.targets.map(\.id) == [target.id])
    #expect(reopened.config.hotkey == "cmd+shift+2")
}

@Test func aliasesAreImportedOnFirstRunOnly() throws {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("box=admin@box.example.com".utf8)
        .write(to: directory.appendingPathComponent("aliases"))

    let first = makeCoordinator(directory: directory).coordinator
    #expect(first.config.targets.map(\.label) == ["box"])

    first.removeTarget(first.config.targets[0])

    // Reopening must not resurrect a target the user deleted.
    let second = makeCoordinator(directory: directory).coordinator
    #expect(second.config.targets.isEmpty)
}
