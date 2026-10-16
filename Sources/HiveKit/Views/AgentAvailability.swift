import AppKit
import HiveCore
import Observation
import SwiftUI

/// Qué agentes (claude, codex, gemini) están instalados, para no ofrecer crear una sesión que
/// no va a arrancar. Mientras no se sabe, se los da por instalados.
@Observable @MainActor
final class AgentAvailability {
    /// Agentes que no se encontraron en el PATH.
    private(set) var missing: Set<SessionKind> = []
    /// Ya se revisó al menos una vez.
    private(set) var checked = false

    @ObservationIgnored private let processes: ProcessStarting
    @ObservationIgnored private let path: String
    /// El PATH del shell de login, cuando todavía no había uno guardado (la primera vez que se abre
    /// Hive). El de respaldo no ve nvm, volta ni asdf: sin esto, un codex instalado con npm
    /// aparecería como «No instalado». Se pide una sola vez y cada revisión lo espera.
    @ObservationIgnored private let loginPATH: Task<String?, Never>?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    /// Cuándo arrancó la última revisión (para no repetirla cada vez que se arma un menú).
    @ObservationIgnored private var lastRefresh: Date?

    init(processes: ProcessStarting, path: String, resolveLoginPATH: (@Sendable () -> String?)? = nil) {
        self.processes = processes
        self.path = path
        loginPATH = resolveLoginPATH.map { resolve in Task.detached(priority: .utility) { resolve() } }
    }

    /// Con el PATH de la última vez; si todavía no hay ninguno, uno razonable mientras se le
    /// pregunta al shell de login.
    convenience init(environment: AppEnvironment) {
        if let cached = environment.cachedLoginPATH {
            self.init(processes: environment.processes, path: cached)
        } else {
            let fallback = LoginShell.fallbackPATH(home: environment.home.path, inherited: environment.inheritedEnvironment["PATH"])
            self.init(processes: environment.processes, path: fallback, resolveLoginPATH: environment.resolveLoginPATH)
        }
    }

    func isInstalled(_ kind: SessionKind) -> Bool { !missing.contains(kind) }

    /// Vuelve a buscar los binarios. Con el lanzador real, la búsqueda en disco corre fuera del
    /// hilo principal; con uno de prueba se le pregunta a él.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        refreshing?.cancel()
        lastRefresh = Date()
        let kinds = SessionKind.allCases.filter { $0.binary != nil }
        let fallback = self.path
        let loginPATH = self.loginPATH
        let processes = self.processes
        let task = Task { [weak self] in
            var path = fallback
            if let loginPATH, let resolved = await loginPATH.value { path = resolved }
            let missing = await Self.findMissing(kinds, path: path, processes: processes)
            guard !Task.isCancelled, let self else { return }
            if self.missing != missing { self.missing = missing }
            if !self.checked { self.checked = true }
        }
        refreshing = task
        return task
    }

    /// Vuelve a revisar si la última revisión arrancó hace más de `maxAge` segundos. La usan los
    /// menús de «Nueva sesión»: sus ítems de un agente sin instalar están deshabilitados y no hay
    /// clic que vuelva a revisar, así que sin esto un agente que instalaste con Hive abierto
    /// seguía «(no instalado)» hasta pasar por la vista de una rama.
    @discardableResult
    func refreshIfStale(maxAge: TimeInterval = 10, now: Date = Date()) -> Task<Void, Never>? {
        if let lastRefresh, now.timeIntervalSince(lastRefresh) < maxAge { return nil }
        return refresh()
    }

    /// Vuelve a revisar antes de decir que falta (quizás lo acabás de instalar). Si mientras
    /// tanto arranca otra revisión (al volver a Hive, o desde otra vista), la nuestra se cancela
    /// sin actualizar nada: se espera a la última para no contestar con lo de antes.
    func recheck(_ kind: SessionKind) async -> Bool {
        var task = refresh()
        await task.value
        while let latest = refreshing, latest != task {
            task = latest
            await task.value
        }
        return isInstalled(kind)
    }

    private static func findMissing(_ kinds: [SessionKind], path: String, processes: ProcessStarting) async -> Set<SessionKind> {
        if processes is TerminalProcessStarter {
            return await Task.detached(priority: .utility) {
                Set(kinds.filter { kind in kind.binary.flatMap { which($0, path: path) } == nil })
            }.value
        }
        return Set(kinds.filter { kind in kind.binary.flatMap { processes.resolve($0, path: path) } == nil })
    }

    // MARK: - Una por store

    private struct Entry {
        weak var store: AppStore?
        let availability: AgentAvailability
    }

    private static var registry: [ObjectIdentifier: Entry] = [:]

    /// La de este store (se crea y se revisa la primera vez que se pide).
    static func shared(for store: AppStore) -> AgentAvailability {
        let key = ObjectIdentifier(store)
        if let entry = registry[key], entry.store === store { return entry.availability }
        registry = registry.filter { $0.value.store != nil }
        let availability = AgentAvailability(environment: store.environment)
        registry[key] = Entry(store: store, availability: availability)
        availability.refresh()
        return availability
    }
}

/// «No instalado» + cómo instalarlo, con un botón para copiar el comando.
struct InstallHintPopover: View {
    let kind: SessionKind
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AgentLogo(kind: kind, size: 18)
                Text("\(kind.label) no está instalado")
                    .font(HiveFont.heading)
            }
            Text("Instalalo desde la terminal y volvé a intentar:")
                .font(HiveFont.secondary)
                .foregroundStyle(.secondary)
            Text(kind.installHint)
                .font(HiveFont.mono)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack {
                Spacer()
                Button {
                    ExternalApps.copyToPasteboard(kind.installHint)
                    copied = true
                } label: {
                    Label(copied ? "Copiado" : "Copiar comando", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.hiveProminent)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
