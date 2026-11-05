import AppKit
import SwiftUI

import UPasswordsCore

/// 管理剪贴板复制、定时清除和全窗口共享的提示消息。
@MainActor
final class ClipboardModel: ObservableObject {
    static let shared = ClipboardModel()

    /// 自动清空剪贴板的等待秒数；0 表示关闭。
    var clearSeconds: Int {
        UserDefaults.standard.integer(forKey: "clipboard.clearSeconds")
    }

    private var clearTask: Task<Void, Never>? = nil
    private var changeCountAtCopy = 0

    func copy(_ text: String, alert: Bool = true) {
        let pb = NSPasteboard.general
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
        changeCountAtCopy = pb.changeCount
        if alert {
            AppToast.shared.show(L10n.t("text_copied_message"))
        }
        clearTask?.cancel()
        let secs = clearSeconds
        guard secs > 0 else { return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let pb = NSPasteboard.general
            if pb.changeCount == self.changeCountAtCopy {
                pb.clearContents()
            }
        }
    }

    /// 锁定时清空本 App 写入的剪贴板内容(changeCount 比对避免误清他人复制);
    /// 自动清除被关掉或计时未走完时,密码不在系统剪贴板残留过锁。
    func clearIfOurs() {
        clearTask?.cancel()
        clearTask = nil
        let pb = NSPasteboard.general
        if changeCountAtCopy != 0, pb.changeCount == changeCountAtCopy {
            pb.clearContents()
            changeCountAtCopy = 0
            Log.debug("app", "clipboard cleared on lock")
        }
    }

    /// 复制一次性验证码，并显示专用的复制成功提示。
    func copyOTP(_ code: String) {
        copy(code, alert: false)
        AppToast.shared.show(L10n.t("otp_copied_message"))
    }
}

/// 供所有窗口共用的轻量提示状态。
@MainActor
final class AppToast: ObservableObject {
    static let shared = AppToast()
    @Published var message: String? = nil
    private var dismissTask: Task<Void, Never>? = nil

    func show(_ text: String) {
        message = text
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.message = nil
        }
    }
}
