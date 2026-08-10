import Foundation
import Testing
@testable import ClipsshCore

private let alpha = Target(label: "alpha", destination: "alpha")
private let beta = Target(label: "beta", destination: "beta")

private func build(
    config: Config = .empty,
    lastOutcome: SendOutcome? = nil,
    configIsCorrupt: Bool = false,
    lastSaveError: String? = nil,
    lastLoadWarning: String? = nil,
    sshConfig: SSHConfigParser.Result? = nil
) -> MenuModel {
    MenuModel.build(MenuModel.Input(
        config: config,
        lastOutcome: lastOutcome,
        configIsCorrupt: configIsCorrupt,
        lastSaveError: lastSaveError,
        lastLoadWarning: lastLoadWarning,
        sshConfig: sshConfig
    ))
}

@Test func headerIsEmptyBeforeAnySend() {
    #expect(build().header == .none)
}

@Test func headerShowsThePathAfterASuccessfulSend() {
    let model = build(lastOutcome: .sent("/tmp/clipboard-1-ab12.png"))
    #expect(model.header == .lastPath("/tmp/clipboard-1-ab12.png"))
}

@Test func headerShowsTheMessageAfterAFailure() {
    let model = build(lastOutcome: .failed(.hostKeyNotTrusted))
    #expect(model.header == .lastError(UploadError.hostKeyNotTrusted.message))
}

@Test func corruptConfigOverridesTheHeader() {
    let model = build(lastOutcome: .sent("/tmp/x.png"), configIsCorrupt: true)
    // An unreadable config is more important than the last result.
    #expect(model.header == .corruptConfig)
}

@Test func headerShowsASaveFailure() {
    let model = build(lastOutcome: .sent("/tmp/x.png"), lastSaveError: "disk full")
    // A silent save failure would let the user believe a change persisted.
    #expect(model.header == .saveFailed("disk full"))
}

@Test func corruptConfigOutranksASaveFailure() {
    let model = build(configIsCorrupt: true, lastSaveError: "disk full")
    #expect(model.header == .corruptConfig)
}

@Test func headerShowsAPermissionWarning() {
    let model = build(lastOutcome: .sent("/tmp/x.png"), lastLoadWarning: "could not tighten permissions")
    // A world-readable config file must not be hidden behind the last result.
    #expect(model.header == .permissionWarning("could not tighten permissions"))
}

@Test func corruptConfigOutranksAPermissionWarning() {
    let model = build(configIsCorrupt: true, lastLoadWarning: "could not tighten permissions")
    #expect(model.header == .corruptConfig)
}

@Test func saveFailureOutranksAPermissionWarning() {
    let model = build(lastSaveError: "disk full", lastLoadWarning: "could not tighten permissions")
    // The save failure is about the change the user just made; more urgent
    // than a warning about a pre-existing, still-being-read config file.
    #expect(model.header == .saveFailed("disk full"))
}

@Test func targetsCarryTheDefaultMark() {
    let config = Config(defaultTargetID: beta.id, targets: [alpha, beta])
    let model = build(config: config)

    #expect(model.targets.map(\.label) == ["alpha", "beta"])
    #expect(model.targets.map(\.isDefault) == [false, true])
}

@Test func targetsAreEmptyWhenNoneAreConfigured() {
    #expect(build().targets.isEmpty)
}

@Test func discoveryIsEmptyWithoutAnSSHConfig() {
    let model = build(sshConfig: nil)
    #expect(model.discoverable.isEmpty)
    #expect(model.showsIncludeNote == false)
}

@Test func discoveryExcludesHostsAlreadyAddedAndSortsTheRest() {
    let config = Config(targets: [alpha])
    let parsed = SSHConfigParser.Result(hosts: ["zulu", "alpha", "mike"], hasUnsupportedInclude: false)

    let model = build(config: config, sshConfig: parsed)

    #expect(model.discoverable == ["mike", "zulu"])
}

@Test func discoveryMatchesOnDestinationNotLabel() {
    let renamed = Target(label: "My Box", destination: "alpha")
    let config = Config(targets: [renamed])
    let parsed = SSHConfigParser.Result(hosts: ["alpha", "bravo"], hasUnsupportedInclude: false)

    // "alpha" is already a target even though its label differs.
    #expect(build(config: config, sshConfig: parsed).discoverable == ["bravo"])
}

@Test func includeNoteIsShownWhenTheParserFoundOne() {
    let parsed = SSHConfigParser.Result(hosts: ["alpha"], hasUnsupportedInclude: true)
    #expect(build(sshConfig: parsed).showsIncludeNote)
}

@Test func includeNoteIsShownEvenWhenNoHostsRemain() {
    let config = Config(targets: [alpha])
    let parsed = SSHConfigParser.Result(hosts: ["alpha"], hasUnsupportedInclude: true)

    let model = build(config: config, sshConfig: parsed)

    #expect(model.discoverable.isEmpty)
    // The note must survive an empty list, or the user never learns why.
    #expect(model.showsIncludeNote)
}
