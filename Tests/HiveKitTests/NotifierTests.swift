import Foundation
import Testing
import UserNotifications
@testable import HiveKit

/// Solo se prueban los constructores: el centro de notificaciones no funciona fuera de un .app.
@MainActor
@Suite("Avisos del sistema")
struct NotifierTests {
    let session = UUID()

    func request(_ kind: NotificationKind = .turn, sound: Bool = true) -> UNNotificationRequest {
        SystemNotifier.request(sessionId: session, title: "ecommerce › main", subtitle: "Claude 1 · Tu turno",
                               body: "Listo: agregué la validación.", kind: kind, sound: sound)
    }

    @Test("El identificador es el id de la sesión (un aviso nuevo reemplaza al anterior)")
    func identifier() {
        let request = request()
        #expect(request.identifier == session.uuidString)
        #expect(request.content.title == "ecommerce › main")
        #expect(request.content.subtitle == "Claude 1 · Tu turno")
        #expect(request.content.body == "Listo: agregué la validación.")
        #expect(request.trigger == nil)
    }

    @Test("La sesión viaja en userInfo y se recupera; si está rota, nil")
    func userInfo() {
        #expect(SystemNotifier.sessionId(from: request().content.userInfo) == session)
        #expect(SystemNotifier.sessionId(from: [:]) == nil)
        #expect(SystemNotifier.sessionId(from: ["session": "no-es-un-uuid"]) == nil)
        #expect(SystemNotifier.sessionId(from: ["session": 42]) == nil)
    }

    @Test("La categoría depende del tipo de aviso")
    func categoryByKind() {
        #expect(request(.turn).content.categoryIdentifier == "turno")
        #expect(request(.permission).content.categoryIdentifier == "permiso")
        #expect(request(.info).content.categoryIdentifier == "")
    }

    @Test("«turno» se responde escribiendo; «permiso» solo se abre")
    func categories() throws {
        let categories = SystemNotifier.categories()
        let turn = try #require(categories.first { $0.identifier == "turno" })
        #expect(turn.actions.map(\.title) == ["Responder", "Abrir"])
        let reply = try #require(turn.actions.first as? UNTextInputNotificationAction)
        #expect(reply.textInputPlaceholder == "Escribí tu respuesta…")
        let permission = try #require(categories.first { $0.identifier == "permiso" })
        #expect(permission.actions.map(\.title) == ["Abrir"])
        #expect(!(permission.actions.first is UNTextInputNotificationAction))
    }

    @Test("Sonido según el ajuste (activado si nunca se tocó)")
    func sound() {
        let suite = "hive-notifier-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SystemNotifier.soundEnabled(defaults))
        defaults.set(false, forKey: "notificationSound")
        #expect(!SystemNotifier.soundEnabled(defaults))
        defaults.set(true, forKey: "notificationSound")
        #expect(SystemNotifier.soundEnabled(defaults))
        #expect(request(sound: true).content.sound != nil)
        #expect(request(sound: false).content.sound == nil)
    }

    @Test("Tocar el aviso abre la sesión, responder la escribe y descartarlo no hace nada")
    func responses() {
        let info: [AnyHashable: Any] = ["session": session.uuidString]
        #expect(SystemNotifier.response(action: UNNotificationDefaultActionIdentifier, userInfo: info, text: nil) == .open(session))
        #expect(SystemNotifier.response(action: "abrir", userInfo: info, text: nil) == .open(session))
        #expect(SystemNotifier.response(action: "responder", userInfo: info, text: "  dale, seguí \n") == .reply(session, "dale, seguí"))
        #expect(SystemNotifier.response(action: "responder", userInfo: info, text: "   ") == .open(session))
        #expect(SystemNotifier.response(action: UNNotificationDismissActionIdentifier, userInfo: info, text: nil) == .ignore)
        #expect(SystemNotifier.response(action: "responder", userInfo: [:], text: "hola") == .ignore)
    }

    @Test("Los avisos falsos de los tests siguen funcionando con el tipo (implementación por defecto)")
    func defaultImplementation() {
        let notifier = KindlessNotifier()
        notifier.post(sessionId: session, title: "t", subtitle: "s", body: "b", kind: .permission)
        #expect(notifier.posts == ["t|s|b"])
    }
}

/// Un aviso que no implementa el `post` con tipo: usa el de la extensión.
@MainActor
private final class KindlessNotifier: SessionNotifying {
    var onOpen: ((UUID) -> Void)?
    var posts: [String] = []
    func setup() {}
    func post(sessionId: UUID, title: String, subtitle: String, body: String) { posts.append("\(title)|\(subtitle)|\(body)") }
    func clear(_ sessionId: UUID) {}
}
