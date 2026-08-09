import Foundation
import Testing
import ClipsshCore
@testable import ClipsshMac

@MainActor
@Test func portTextIsPopulatedFromTheDefaultTargetWhenTheWindowOpens() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory)
    coordinator.addTarget(destination: "box.example.com")
    var target = coordinator.config.targets[0]
    target.port = 2222
    coordinator.updateTarget(target)

    // didSet on `selection` is not run for the assignment inside init() —
    // Swift never calls a property observer for a self-assignment made
    // within the initializer of the same class. Before the fix, portText
    // stayed "" here even though the default target has a stored port.
    let model = TargetsModel(coordinator: coordinator)

    #expect(model.portText == "2222")
}
