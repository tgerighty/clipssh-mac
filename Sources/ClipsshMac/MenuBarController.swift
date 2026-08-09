import AppKit

enum IconState {
    case idle, sending, success, error
}

final class MenuBarController: NSObject {
    /// Called on a left-click. Set by AppDelegate.
    var onSend: (() -> Void)?
    /// Supplies a freshly built menu on a right-click. Set by AppDelegate.
    var menuProvider: (() -> NSMenu)?

    private(set) var state: IconState = .idle

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    /// Exposes the current icon so tests can inspect its template/colour state.
    var iconImage: NSImage? { statusItem.button?.image }
    private(set) var pulseTimer: Timer?
    private var successTimer: Timer?

    override init() {
        super.init()
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick)
        // Ask for both click types so the action fires for either.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        setState(.idle)
    }

    deinit {
        pulseTimer?.invalidate()
        successTimer?.invalidate()
    }


    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let isMenuClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isMenuClick {
            showMenu()
        } else {
            onSend?()
        }
    }

    private func showMenu() {
        guard let menu = menuProvider?() else { return }
        // Attaching the menu then clicking it makes AppKit show it and detach
        // afterwards, which keeps a left-click free for the send action.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil

        // The error message is visible in the menu the user just opened, so the
        // red icon has done its job. This is the second of the two events that
        // clear it; a new send is the first.
        if state == .error {
            setState(.idle)
        }
    }

    func setState(_ newState: IconState) {
        pulseTimer?.invalidate()
        successTimer?.invalidate()
        state = newState

        guard let button = statusItem.button else { return }
        button.contentTintColor = nil
        button.alphaValue = 1

        switch newState {
        case .idle:
            button.image = Self.symbol("photo.on.rectangle")
        case .sending:
            button.image = Self.symbol("arrow.up.circle")
            startPulsing(button)
        case .success:
            button.image = Self.symbol("checkmark.circle")
            successTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                self?.setState(.idle)
            }
        case .error:
            button.image = Self.errorSymbol("exclamationmark.triangle.fill")
        }
    }

    private func startPulsing(_ button: NSStatusBarButton) {
        var dim = true
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            button.animator().alphaValue = dim ? 0.35 : 1.0
            dim.toggle()
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "clipssh-mac")
        // A template image follows the light and dark menu bar automatically.
        image?.isTemplate = true
        return image
    }

    /// A coloured, non-template icon for the error state. There is no
    /// notification for a failed send, so this icon is the only immediate
    /// signal — it stays red regardless of menu bar appearance, and uses a
    /// distinct silhouette (not just colour) so the failure is visible to
    /// colour-blind users too.
    private static func errorSymbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "clipssh-mac error")
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let colored = image?.withSymbolConfiguration(config)
        colored?.isTemplate = false
        return colored
    }
}
