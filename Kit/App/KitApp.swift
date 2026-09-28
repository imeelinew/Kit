import AppKit

@main
enum KitApp {
    @MainActor private static let delegate = AppDelegate()

    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.delegate = delegate
        application.run()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let applicationMenu = ApplicationMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        applicationMenu.install()
        AppCore.shared.start()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        AppCore.shared.handleReopen()
        return true
    }
}
