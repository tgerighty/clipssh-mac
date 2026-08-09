import Foundation
import ServiceManagement

/// SMAppService is the supported API from macOS 13. Off after installation:
/// adding a login item without being asked is not acceptable behaviour.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func toggle() -> Result<Void, Error> {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            return .success(())
        } catch {
            NSLog("clipssh-mac: launch at login failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }
}
