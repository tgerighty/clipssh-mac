import AppKit
import ClipsshCore

/// Turns a MenuModel into an NSMenu. All decisions were made in MenuModel; this
/// type only draws them.
final class MenuRenderer: NSObject {
    var onSelectTarget: ((UUID) -> Void)?
    var onAddDiscovered: ((String) -> Void)?
    var onCopyLastPath: (() -> Void)?
    var onOpenTargets: (() -> Void)?

    private let coordinator: SendCoordinator

    init(coordinator: SendCoordinator) {
        self.coordinator = coordinator
    }

    deinit {}

    func render() -> NSMenu {
        let model = MenuModel.build(MenuModel.Input(
            config: coordinator.config,
            lastOutcome: coordinator.lastOutcome,
            configIsCorrupt: coordinator.configIsCorrupt,
            lastSaveError: coordinator.lastSaveError,
            lastLoadWarning: coordinator.lastLoadWarning,
            sshConfig: Self.readSSHConfig()
        ))

        let menu = NSMenu()
        addHeader(model.header, to: menu)
        addTargets(model.targets, to: menu)
        addDiscovery(model, to: menu)
        menu.addItem(withTitle: "Targets…", action: #selector(openTargets), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        let launch = menu.addItem(
            withTitle: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: ""
        )
        launch.target = self
        launch.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "About clipssh-mac", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func addHeader(_ header: MenuModel.Header, to menu: NSMenu) {
        switch header {
        case .none:
            return
        case .corruptConfig:
            menu.addItem(withTitle: "Config file unreadable — it has not been changed", action: nil, keyEquivalent: "")
        case .saveFailed(let message):
            menu.addItem(withTitle: "Could not save settings — \(message)", action: nil, keyEquivalent: "")
        case .permissionWarning(let message):
            menu.addItem(withTitle: message, action: nil, keyEquivalent: "")
        case .lastError(let message):
            menu.addItem(withTitle: message, action: nil, keyEquivalent: "")
        case .lastPath(let path):
            let item = menu.addItem(withTitle: "✓ \(path)", action: #selector(copyLastPath), keyEquivalent: "")
            item.target = self
            item.toolTip = "Copy this path again"
        }
        menu.addItem(.separator())
    }

    private func addTargets(_ targets: [MenuModel.TargetItem], to menu: NSMenu) {
        guard !targets.isEmpty else { return }
        let parent = menu.addItem(withTitle: "Target", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for target in targets {
            let item = NSMenuItem(title: target.label, action: #selector(selectTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.id
            // Selecting a target only changes the default. It does not send.
            item.state = target.isDefault ? .on : .off
            submenu.addItem(item)
        }
        menu.setSubmenu(submenu, for: parent)
        menu.addItem(.separator())
    }

    private func addDiscovery(_ model: MenuModel, to menu: NSMenu) {
        guard !model.discoverable.isEmpty || model.showsIncludeNote else { return }
        let parent = menu.addItem(withTitle: "Add from ~/.ssh/config", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for host in model.discoverable {
            let item = NSMenuItem(title: host, action: #selector(addDiscovered(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = host
            submenu.addItem(item)
        }
        if model.showsIncludeNote {
            if !model.discoverable.isEmpty { submenu.addItem(.separator()) }
            let note = NSMenuItem(title: "Some hosts hidden (Include not supported)", action: nil, keyEquivalent: "")
            note.isEnabled = false
            submenu.addItem(note)
        }
        menu.setSubmenu(submenu, for: parent)
    }

    private static func readSSHConfig() -> SSHConfigParser.Result? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        return SSHConfigParser.parse(text)
    }

    @objc private func selectTarget(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onSelectTarget?(id)
    }

    @objc private func addDiscovered(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else { return }
        onAddDiscovered?(host)
    }

    @objc private func copyLastPath() { onCopyLastPath?() }

    @objc private func openTargets() { onOpenTargets?() }

    @objc private func toggleLaunchAtLogin() {
        if case .failure(let error) = LaunchAtLogin.toggle() {
            let alert = NSAlert()
            alert.messageText = "Could not change launch at login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
