import Foundation
import Testing
@testable import ClipsshMac

@MainActor
@Test(.enabled(if: hasWindowServer)) func deinitInvalidatesThePulseTimer() {
    var controller: MenuBarController? = MenuBarController()
    controller?.setState(.sending)
    let timer = controller?.pulseTimer
    #expect(timer?.isValid == true)

    controller = nil

    // Nothing retains MenuBarController just because a timer is scheduled —
    // its pulse closure captures the button, not self — so without a deinit
    // the timer would keep firing against a detached button forever.
    #expect(timer?.isValid == false)
}

@MainActor
@Test(.enabled(if: hasWindowServer)) func errorIconIsNotATemplateImageSoItRendersRed() {
    let controller = MenuBarController()
    controller.setState(.error)

    // A template image is recoloured by the system to match the menu bar
    // appearance, which discards the red tint. The error icon must be a
    // real, non-template image so it stays visibly red.
    #expect(controller.iconImage?.isTemplate == false)
}

@MainActor
@Test(.enabled(if: hasWindowServer)) func idleSendingAndSuccessIconsRemainTemplateImages() {
    let controller = MenuBarController()

    controller.setState(.idle)
    #expect(controller.iconImage?.isTemplate == true)

    controller.setState(.sending)
    #expect(controller.iconImage?.isTemplate == true)

    controller.setState(.success)
    #expect(controller.iconImage?.isTemplate == true)
}

@MainActor
@Test(.enabled(if: hasWindowServer)) func errorIconUsesADifferentSymbolThanIdle() {
    let controller = MenuBarController()

    controller.setState(.idle)
    let idleDescription = controller.iconImage?.accessibilityDescription

    controller.setState(.error)
    let errorDescription = controller.iconImage?.accessibilityDescription

    #expect(idleDescription != errorDescription)
}
