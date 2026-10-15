import Foundation
import UserNotifications

/// Para qué es un aviso: define qué botones tiene.
public enum NotificationKind: Sendable {
    /// El agente terminó su turno: se le puede responder desde el aviso.
    case turn
    /// El agente pide permiso: hay que verlo en la terminal.
    case permission
    /// Un aviso informativo, sin botones.
    case info
}

/// Avisos del sistema cuando una sesión termina o pide algo. Es un protocolo para los tests.
@MainActor
public protocol SessionNotifying: AnyObject {
    /// Se llama cuando tocás un aviso (con la sesión a abrir).
    var onOpen: ((UUID) -> Void)? { get set }
    func setup()
    func post(sessionId: UUID, title: String, subtitle: String, body: String)
    /// Igual que `post`, pero eligiendo los botones según el tipo de aviso.
    func post(sessionId: UUID, title: String, subtitle: String, body: String, kind: NotificationKind)
    func clear(_ sessionId: UUID)
}

extension SessionNotifying {
    /// Quien no distingue tipos de aviso los muestra todos igual.
    public func post(sessionId: UUID, title: String, subtitle: String, body: String, kind: NotificationKind) {
        post(sessionId: sessionId, title: title, subtitle: subtitle, body: body)
    }
}

/// Implementación con el centro de notificaciones de macOS.
@MainActor
public final class SystemNotifier: NSObject, SessionNotifying, UNUserNotificationCenterDelegate {
    /// Identificadores de las categorías y de sus botones.
    enum Identifier {
        static let turnCategory = "turno"
        static let permissionCategory = "permiso"
        static let reply = "responder"
        static let open = "abrir"
        static let sessionKey = "session"
    }

    public var onOpen: ((UUID) -> Void)?
    /// Se llama cuando respondés desde el aviso (sesión y texto). No es parte del protocolo:
    /// solo los avisos del sistema permiten escribir.
    public var onReply: ((UUID, String) -> Void)?

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Las notificaciones solo funcionan dentro de un .app (con bundle identifier).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    public func setup() {
        guard let center else { return }
        center.delegate = self
        center.setNotificationCategories(Self.categories())
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    public func post(sessionId: UUID, title: String, subtitle: String, body: String) {
        // Compatibilidad con quien todavía no pasa el tipo: el subtítulo dice si pide permiso.
        post(sessionId: sessionId, title: title, subtitle: subtitle, body: body,
             kind: subtitle.hasSuffix("Necesita permiso") ? .permission : .turn)
    }

    public func post(sessionId: UUID, title: String, subtitle: String, body: String, kind: NotificationKind) {
        guard let center else { return }
        center.add(Self.request(sessionId: sessionId, title: title, subtitle: subtitle, body: body, kind: kind,
                                sound: Self.soundEnabled(defaults)))
    }

    public func clear(_ sessionId: UUID) {
        center?.removeDeliveredNotifications(withIdentifiers: [sessionId.uuidString])
    }

    // MARK: Construcción (sin tocar el centro de notificaciones, para poder probarla)

    /// Las categorías: «turno» se puede responder escribiendo; «permiso» solo se abre.
    nonisolated static func categories() -> Set<UNNotificationCategory> {
        let reply = UNTextInputNotificationAction(identifier: Identifier.reply, title: "Responder", options: [],
                                                  textInputButtonTitle: "Enviar", textInputPlaceholder: "Escribí tu respuesta…")
        let open = UNNotificationAction(identifier: Identifier.open, title: "Abrir", options: [.foreground])
        return [
            UNNotificationCategory(identifier: Identifier.turnCategory, actions: [reply, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Identifier.permissionCategory, actions: [open], intentIdentifiers: []),
        ]
    }

    nonisolated static func categoryIdentifier(for kind: NotificationKind) -> String {
        switch kind {
        case .turn: Identifier.turnCategory
        case .permission: Identifier.permissionCategory
        case .info: ""
        }
    }

    /// El pedido de aviso. Usa el id de la sesión como identificador: un aviso nuevo reemplaza al anterior.
    nonisolated static func request(sessionId: UUID, title: String, subtitle: String, body: String, kind: NotificationKind,
                        sound: Bool) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = sound ? .default : nil
        content.userInfo = [Identifier.sessionKey: sessionId.uuidString]
        content.categoryIdentifier = categoryIdentifier(for: kind)
        content.threadIdentifier = sessionId.uuidString
        return UNNotificationRequest(identifier: sessionId.uuidString, content: content, trigger: nil)
    }

    /// La sesión de un aviso, o nil si el aviso no es de Hive o está roto.
    nonisolated static func sessionId(from userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo[Identifier.sessionKey] as? String).flatMap(UUID.init(uuidString:))
    }

    /// Ajuste «Sonido en los avisos» (activado si nunca se tocó).
    nonisolated static func soundEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: "notificationSound") as? Bool ?? true
    }

    /// Qué hacer con la respuesta a un aviso: abrir la sesión, responderle o nada (si lo descartaste).
    enum Response: Equatable {
        case open(UUID)
        case reply(UUID, String)
        case ignore
    }

    nonisolated static func response(action: String, userInfo: [AnyHashable: Any], text: String?) -> Response {
        guard let id = sessionId(from: userInfo) else { return .ignore }
        switch action {
        case Identifier.reply:
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? .open(id) : .reply(id, trimmed)
        case UNNotificationDismissActionIdentifier:
            return .ignore
        default:
            return .open(id)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                                   withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                                   withCompletionHandler completionHandler: @escaping () -> Void) {
        let decision = Self.response(action: response.actionIdentifier,
                                     userInfo: response.notification.request.content.userInfo,
                                     text: (response as? UNTextInputNotificationResponse)?.userText)
        completionHandler()
        Task { @MainActor in
            switch decision {
            case .open(let id): self.onOpen?(id)
            case .reply(let id, let text): self.onReply?(id, text)
            case .ignore: break
            }
        }
    }
}
