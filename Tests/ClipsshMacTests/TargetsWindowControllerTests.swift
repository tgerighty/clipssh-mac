import AppKit
import Foundation
import Testing
import ClipsshCore
@testable import ClipsshMac

@MainActor
@Test(.enabled(if: hasWindowServer)) func windowIsNotReleasedWhenClosedSoItCanBeSafelyReused() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = TargetsWindowController(coordinator: makeCoordinator(directory: directory))

    controller.show()
    defer { controller.window?.close() }

    // NSWindow.isReleasedWhenClosed defaults to true. The controller keeps a
    // strong reference to this window and reuses it on the next show(), so a
    // window AppKit is free to release on close is a dangling-reference bug.
    #expect(controller.window?.isReleasedWhenClosed == false)
}

@MainActor
@Test(.enabled(if: hasWindowServer)) func closingTheWindowCommitsAnUnsubmittedLabelEdit() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory)
    let target = coordinator.addTarget(destination: "box.example.com", label: "original")
    let controller = TargetsWindowController(coordinator: coordinator)
    controller.show()
    controller.model?.selection = target.id
    controller.model?.setLabelText("typed then closed")

    // AppKit calls the delegate's windowWillClose(_:) when the real close
    // button is clicked; this test drives the same real close path rather
    // than calling the delegate method directly.
    controller.window?.close()

    #expect(coordinator.config.targets.first(where: { $0.id == target.id })?.label == "typed then closed")
}

/// Regression test: `show()`'s reuse path calls `model.refresh()`, which
/// re-syncs the draft Label/Destination fields from stored state. If the
/// user typed into Label without committing (no Return, no focus loss) and
/// the window is reopened while still on-screen (e.g. two calls to `show()`
/// in a row), that text must not be discarded.
@MainActor
@Test(.enabled(if: hasWindowServer)) func reopeningTheWindowCommitsAnUncommittedLabelEditBeforeRefreshing() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory)
    let target = coordinator.addTarget(destination: "box.example.com", label: "original")
    let controller = TargetsWindowController(coordinator: coordinator)
    controller.show()
    controller.model?.selection = target.id
    controller.model?.setLabelText("typed but not submitted")

    // Reopening via the reuse path (window still exists), not via close/show.
    controller.show()
    defer { controller.window?.close() }

    #expect(coordinator.config.targets.first(where: { $0.id == target.id })?.label == "typed but not submitted")
    #expect(controller.model?.labelText == "typed but not submitted")
}

@MainActor
@Test(.enabled(if: hasWindowServer)) func showAfterCloseReusesTheWindowWithoutCrashing() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = TargetsWindowController(coordinator: makeCoordinator(directory: directory))

    controller.show()
    controller.window?.close()
    controller.show()
    defer { controller.window?.close() }

    #expect(controller.window != nil)
    #expect(controller.window?.isVisible == true)
}

/// Regression test for the audit finding that a hotkey re-registration
/// failure at launch (e.g. another app now owns the combination) was only
/// `NSLog`-ed, leaving the Targets window showing the saved hotkey as if it
/// were active. The app delegate reports the failure to the controller
/// before the window/model exist yet; this pins that the message still
/// reaches the model once it is created, and that the persisted hotkey
/// itself is left untouched.
@MainActor
@Test(.enabled(if: hasWindowServer)) func launchHotkeyFailureMessageSurfacesOnceTheWindowIsShown() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory)
    coordinator.setHotkey("cmd+shift+key1")
    let controller = TargetsWindowController(coordinator: coordinator)

    controller.launchHotkeyFailureMessage = "Saved hotkey could not be registered — it may be in use by another app."
    controller.show()
    defer { controller.window?.close() }

    #expect(
        controller.model?.hotkeyMessage
            == "Saved hotkey could not be registered — it may be in use by another app."
    )
    // The persisted hotkey is not silently deleted just because it failed to
    // register.
    #expect(controller.model?.hotkey == "cmd+shift+key1")
}

/// The menu can add a target (MenuRenderer.onAddDiscovered) or change the
/// default (onSelectTarget) while the Targets window is closed. Because the
/// window is reused rather than recreated, reopening it must show that
/// change instead of the TargetsModel snapshot taken when it was first shown.
@MainActor
@Test(.enabled(if: hasWindowServer)) func showAfterCloseRefreshesTargetsChangedWhileTheWindowWasClosed() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory)
    let controller = TargetsWindowController(coordinator: coordinator)

    controller.show()
    controller.window?.close()
    let added = coordinator.addTarget(destination: "new.example.com", label: "new")
    controller.show()
    defer { controller.window?.close() }

    #expect(controller.model?.targets.contains(where: { $0.id == added.id }) == true)
    #expect(controller.model?.defaultID == coordinator.config.defaultTargetID)
}
