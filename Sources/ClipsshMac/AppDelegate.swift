import AppKit
import ClipsshCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var coordinator: SendCoordinator?
    private var sendController: SendController?
    private var renderer: MenuRenderer?
    private var targetsWindow: TargetsWindowController?
    private var hotkeys: HotkeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = SendCoordinator(
            store: TargetStore(directory: TargetStore.defaultDirectory),
            pasteboard: ClipboardReader(),
            uploader: Uploader(runner: SubprocessRunner())
        )
        let menuBar = MenuBarController()
        let sendController = SendController(coordinator: coordinator, menuBar: menuBar)

        let renderer = MenuRenderer(coordinator: coordinator)
        renderer.onSelectTarget = { id in
            guard let target = coordinator.config.targets.first(where: { $0.id == id }) else { return }
            coordinator.setDefault(target)
        }
        renderer.onAddDiscovered = { coordinator.addTarget(destination: $0) }
        renderer.onCopyLastPath = { coordinator.copyLastPath() }

        let targetsWindow = TargetsWindowController(coordinator: coordinator)
        renderer.onOpenTargets = { targetsWindow.show() }
        self.targetsWindow = targetsWindow

        menuBar.onSend = {
            // With no target at all there is nothing to send to, so open the
            // window instead of reporting an error the user cannot act on.
            guard coordinator.config.defaultTarget != nil else {
                targetsWindow.show()
                return
            }
            sendController.send()
        }
        menuBar.menuProvider = { renderer.render() }

        let hotkeys = HotkeyManager()
        hotkeys.onFire = { menuBar.onSend?() }
        if let savedHotkey = coordinator.config.hotkey, !hotkeys.register(savedHotkey) {
            NSLog("clipssh-mac: failed to register saved hotkey \(savedHotkey)")
            // The hotkey stays in the config (never silently deleted) but the
            // Targets window must not show it as active when it is not.
            targetsWindow.launchHotkeyFailureMessage =
                "Saved hotkey could not be registered — it may be in use by another app."
        }
        targetsWindow.onHotkeyChange = { [weak hotkeys] spec in hotkeys?.register(spec) ?? false }

        self.coordinator = coordinator
        self.menuBar = menuBar
        self.sendController = sendController
        self.renderer = renderer
        self.hotkeys = hotkeys
    }
}
