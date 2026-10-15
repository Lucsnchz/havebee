import Foundation
import UserNotifications

/// Avisos del sistema cuando una sesión termina o pide algo. Es un protocolo para los tests.
@MainActor
public protocol SessionNotifying: AnyObject {
    /// Se llama cuando tocás un aviso (con la sesión a abrir).
    var onOpen: ((UUID) -> Void)? { get set }
    func setup()
    func post(sessionId: UUID, title: String, subtitle: String, body: String)
    func clear(_ sessionId: UUID)
}

/// Implementación con el centro de notificaciones de macOS.
@MainActor
public final class SystemNotifier: NSObject, SessionNotifying, UNUserNotificationCenterDelegate {
    public var onOpen: ((UUID) -> Void)?

    /// Las notificaciones solo funcionan dentro de un .app (con bundle identifier).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    public func setup() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    public func post(sessionId: UUID, title: String, subtitle: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.userInfo = ["session": sessionId.uuidString]
        // Mismo identificador por sesión: un aviso nuevo reemplaza al anterior.
        center.add(UNNotificationRequest(identifier: sessionId.uuidString, content: content, trigger: nil))
    }

    public func clear(_ sessionId: UUID) {
        center?.removeDeliveredNotifications(withIdentifiers: [sessionId.uuidString])
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                                   withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                                   withCompletionHandler completionHandler: @escaping () -> Void) {
        let value = response.notification.request.content.userInfo["session"] as? String
        completionHandler()
        guard let value, let id = UUID(uuidString: value) else { return }
        Task { @MainActor in self.onOpen?(id) }
    }
}
