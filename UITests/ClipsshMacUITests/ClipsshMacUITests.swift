import XCTest

final class ClipsshMacUITests: XCTestCase {
    private var app: XCUIApplication!
    private var configDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false

        // A scratch config directory keeps the tests away from the real ~/.clipssh.
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

    /// Not an assertion — a discovery aid. Run it once, read the output, then
    /// write the real queries in the tests below and delete this.
    func testPrintElementTree() throws {
        print("=== APP TREE ===")
        print(app.debugDescription)
        let systemUI = XCUIApplication(bundleIdentifier: "com.apple.controlcenter")
        print("=== MENU BAR TREE ===")
        print(systemUI.menuBars.debugDescription)
    }
}
