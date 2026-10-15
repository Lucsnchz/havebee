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
    @ObservationIgnored private var refreshing: Task<Void, Never>?

    init(processes: ProcessStarting, path: String) {
        self.processes = processes
        self.path = path
    }

    /// Con el PATH de la última vez, o uno razonable si todavía no se resolvió.
    convenience init(environment: AppEnvironment) {
        let path = environment.cachedLoginPATH
            ?? LoginShell.fallbackPATH(home: environment.home.path, inherited: environment.inheritedEnvironment["PATH"])
        self.init(processes: environment.processes, path: path)
    }

    func isInstalled(_ kind: SessionKind) -> Bool { !missing.contains(kind) }

    /// Vuelve a buscar los binarios. Con el lanzador real, la búsqueda en disco corre fuera del
    /// hilo principal; con uno de prueba se le pregunta a él.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        refreshing?.cancel()
        let kinds = SessionKind.allCases.filter { $0.binary != nil }
        let path = self.path
        let processes = self.processes
        let task = Task { [weak self] in
            let missing: Set<SessionKind>
            if processes is TerminalProcessStarter {
                missing = await Task.detached(priority: .utility) {
                    Set(kinds.filter { kind in kind.binary.flatMap { which($0, path: path) } == nil })
                }.value
            } else {
                missing = Set(kinds.filter { kind in kind.binary.flatMap { processes.resolve($0, path: path) } == nil })
            }
            guard !Task.isCancelled, let self else { return }
            if self.missing != missing { self.missing = missing }
            self.checked = true
        }
        refreshing = task
        return task
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
