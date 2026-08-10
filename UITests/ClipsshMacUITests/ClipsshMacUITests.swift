import XCTest

/// End-to-end tests that drive the real app through the real menu bar.
///
/// These require a logged-in GUI session and Accessibility permission for the
/// test runner, so they are local-only (`make uitest`) and are deliberately not
/// run in CI — GitHub's macOS runners have no window server.
///
/// The status item is reached via `app.statusItems` on our OWN application.
/// Going through `com.apple.controlcenter` is not viable: its menu bar children
/// are almost all anonymous (empty identifier and label), so there is nothing
/// to match on.
final class ClipsshMacUITests: XCTestCase {
    private var app: XCUIApplication!
    private var configDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false

        // A scratch config directory keeps these tests away from the real
        // ~/.clipssh, so a test run can never touch the user's own targets.
        configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipssh-uitest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        app = XCUIApplication(bundleIdentifier: "com.tgerighty.clipssh-mac")
        app.launchEnvironment["CLIPSSH_MAC_CONFIG_DIR"] = configDirectory.path
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: configDirectory)
    }

    private var statusItem: XCUIElement { app.statusItems.firstMatch }

    /// A menu bar manager (Bartender, Ice, Hidden Bar…) parks hidden items at a
    /// negative x, where they exist in the accessibility tree but cannot be
    /// clicked. That is the manager working as intended, not an app fault, so
    /// skip rather than report a false failure. The global hotkey is the
    /// supported way to send when the icon is not reachable.
    private func requireHittableStatusItem() throws {
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        guard statusItem.isHittable else {
            throw XCTSkip("Status item is not hittable (frame \(statusItem.frame)) — it is most likely hidden by a menu bar manager. Reveal clipssh-mac in the menu bar to run the click-driven tests.")
        }
    }

    func testStatusItemAppearsInTheMenuBar() throws {
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        XCTAssertEqual(statusItem.label, "clipssh-mac")
    }

    func testTheAppRunsWithoutADockIcon() throws {
        // LSUIElement is what keeps this a menu-bar-only app.
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 0, "no window should be open at launch")
    }

    func testRightClickOpensTheMenu() throws {
        try requireHittableStatusItem()
        statusItem.rightClick()

        XCTAssertTrue(app.menuItems["Quit"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.menuItems["Targets…"].exists)
        XCTAssertTrue(app.menuItems["About clipssh-mac"].exists)
        XCTAssertTrue(app.menuItems["Launch at login"].exists)
    }

    func testLeftClickWithNoTargetOpensTheTargetsWindow() throws {
        // The scratch config has no targets, so a send has nowhere to go. The
        // app must open the Targets window rather than report an error the
        // user cannot act on.
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        XCTAssertTrue(app.windows["clipssh-mac Targets"].waitForExistence(timeout: 5))
    }

    func testAddingATargetPersistsItToTheConfigFile() throws {
        try requireHittableStatusItem()

        // No targets yet, so a left-click opens the Targets window.
        statusItem.click()
        let window = app.windows["clipssh-mac Targets"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        // accessibilityIdentifier does not propagate through `Button { Image }`
        // on macOS, but accessibilityLabel does — the button surfaces as "Add".
        let add = window.buttons["Add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.click()

        // Assert on the persisted state rather than chaining more UI steps:
        // the config file is the contract, and it is deterministic.
        let configURL = configDirectory.appendingPathComponent("clipssh-mac.json")
        var parsed: [String: Any]?
        for _ in 0..<20 {
            if let data = try? Data(contentsOf: configURL),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let targets = object["targets"] as? [[String: Any]], !targets.isEmpty {
                parsed = object
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        let targets = (parsed?["targets"] as? [[String: Any]]) ?? []
        XCTAssertEqual(targets.count, 1, "adding a target should write exactly one target")
        XCTAssertNotNil(parsed?["defaultTargetID"], "the first target should become the default")
    }

}
