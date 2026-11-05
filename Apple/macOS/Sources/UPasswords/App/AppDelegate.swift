import AppKit
import UPasswordsCore

/// 管理程序坞重新打开窗口及应用退出行为。
/// 菜单栏常驻入口由 StatusItemController 承担。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController()
    private var didHandleInitialActivation = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        Log.bootstrap()
        Log.info("app", "application will finish launching")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.install()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 点程序坞图标时若无窗口则重新拉起;返回 false 阻止系统重复处理
        if !flag {
            StatusItemController.showMainWindow()
            StatusItemController.requestTouchIDUnlockAfterActivation()
            return false
        }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Log.debug("app", "last window closed → keeping app in dock (lock_if_window_closed)")
        return false // main window may be closed while app stays in dock (lock_if_window_closed)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        Log.debug("app", "app active")
        guard !didHandleInitialActivation else { return }
        didHandleInitialActivation = true

        guard AppContext.shared.phase == .locked else { return }
        Log.info("keychain", "initial app activation while locked; waiting for the lock window")
        StatusItemController.requestTouchIDUnlockAfterActivation()
    }
    func applicationWillTerminate(_ notification: Notification) {
        Log.info("app", "application will terminate → flushing session save")
        AppContext.shared.save()
        Log.flush()
    }
}
