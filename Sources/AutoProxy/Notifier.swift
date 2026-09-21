import AppKit
import UserNotifications

/// 系统通知。菜单栏那个图标换个颜色是不够的 —— 手机上不了网这件事得主动撞到人眼前，
/// 不能等他哪天想起来去点菜单。
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// 点开通知时做什么
    var onOpen: (() -> Void)?
    /// 系统通知这条路走不通时的退路。宁可弹个窗打扰人，也好过让他对着一台上不了网的手机猜原因。
    var fallback: ((String, String) -> Void)?

    /// UNUserNotificationCenter.current() 在没有 bundle 身份的进程里会直接崩，
    /// `swift run` 起的开发构建正是这种。拿不到 bundle id 就整条路都不碰。
    private let available = Bundle.main.bundleIdentifier != nil

    func start() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String) {
        guard available else {
            fallback?(title, body)
            return
        }

        // 每次现查，不吃启动时那一次的结果：用户随时可能在系统设置里改，
        // 而第一次提醒也完全可能赶在授权回调之前
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self else { return }
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                DispatchQueue.main.async { self.fallback?(title, body) }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                guard error != nil else { return }
                DispatchQueue.main.async { self.fallback?(title, body) }
            }
        }
    }

    // 本体是菜单栏程序，从不算"在前台"，但横幅该出还是要出
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in self?.onOpen?() }
        handler()
    }
}
