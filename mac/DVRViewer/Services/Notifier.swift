import AppKit
import UserNotifications

/// macOS 通知（下載完成／失敗）。第一次下載時才詢問通知權限。
/// App 在前景時也顯示橫幅；點通知會在 Finder 中顯示檔案。
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()

    private var center: UNUserNotificationCenter { .current() }

    /// App 啟動時呼叫：讓點擊通知（包含 App 未開啟時）能在 Finder 顯示檔案
    func activate() { center.delegate = self }

    /// 開始下載時呼叫：尚未決定時詢問權限
    func requestAuthorizationIfNeeded() {
        center.delegate = self
        center.getNotificationSettings { s in
            guard s.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func downloadFinished(file: URL, detail: String) {
        post(title: "下載完成", body: "\(file.lastPathComponent)\n\(detail)", file: file)
    }

    func downloadFailed(title: String, reason: String) {
        post(title: "下載失敗", body: "\(title)：\(reason)", file: nil)
    }

    private func post(title: String, body: String, file: URL?) {
        center.delegate = self
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        if let file { c.userInfo = ["path": file.path] }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // App 在前景時也顯示
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // 點通知：在 Finder 中顯示檔案
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        completionHandler()
    }
}
