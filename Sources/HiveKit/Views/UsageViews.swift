import HiveCore
import Observation
import SwiftUI

/// Uso de contexto de cada sesión y límites de las cuentas de Claude y Codex. Lee los archivos cada
/// 30 segundos fuera del hilo principal (UsageReader) y lo publica para las vistas.
@Observable @MainActor
final class UsageMonitor {
    static let shared = UsageMonitor()

    /// Lo último de cada sesión de Claude o Codex.
    private(set) var sessions: [UUID: UsageSnapshot] = [:]
    /// Los límites más recientes de cada cuenta (de la sesión que informó último).
    private(set) var claude: UsageSnapshot?
    private(set) var codex: UsageSnapshot?

    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored let interval: TimeInterval

    init(interval: TimeInterval = 30) {
        self.interval = interval
    }

    /// Empieza a refrescar con los datos de este store (llamarlo varias veces no suma timers).
    func attach(_ store: AppStore) {
        guard self.store !== store || timer == nil else { return }
        self.store = store
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        guard let store, !refreshing else { return }
        var targets: [UsageTarget] = []
        for project in store.projects {
            for branch in project.branches {
                for session in branch.activeSessions where session.kind == .claude || session.kind == .codex {
                    targets.append(UsageTarget(sessionId: session.id, kind: session.kind, agentSessionId: session.agentSessionId))
                }
            }
        }
        let usageDir = store.environment.paths.usageDir
        let agents = store.environment.agents
        refreshing = true
        let frozen = targets
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { UsageMonitor.read(frozen, usageDir: usageDir, agents: agents) }.value
            self?.apply(result)
            self?.refreshing = false
        }
    }

    struct UsageTarget: Sendable {
        let sessionId: UUID
        let kind: SessionKind
        let agentSessionId: String?
    }

    nonisolated static func read(_ targets: [UsageTarget], usageDir: URL, agents: AgentStorage) -> [UUID: UsageSnapshot] {
        var result: [UUID: UsageSnapshot] = [:]
        for target in targets {
            switch target.kind {
            case .claude:
                let file = usageDir.appendingPathComponent("\(target.sessionId.uuidString).json")
                result[target.sessionId] = UsageReader.claude(usageFile: file)
            case .codex:
                guard let thread = target.agentSessionId, let rollout = agents.codexRolloutURL(thread) else { continue }
                result[target.sessionId] = UsageReader.codex(rolloutURL: rollout)
            default:
                continue
            }
        }
        return result
    }

    /// Publica lo leído (también lo usan los tests para mostrar datos fijos).
    func apply(_ snapshots: [UUID: UsageSnapshot]) {
        if sessions != snapshots { sessions = snapshots }
        let latestClaude = Self.latest(.claude, in: snapshots)
        let latestCodex = Self.latest(.codex, in: snapshots)
        if claude != latestClaude { claude = latestClaude }
        if codex != latestCodex { codex = latestCodex }
    }

    static func latest(_ kind: SessionKind, in snapshots: [UUID: UsageSnapshot]) -> UsageSnapshot? {
        snapshots.values.filter { $0.agent == kind && !$0.limits.isEmpty }.max { $0.updatedAt < $1.updatedAt }
    }

    /// Miel y rojo desde 95 %. (El naranja es de «necesita permiso»: un «87%» naranja en el riel
    /// parecía un pedido de permiso.)
    static func color(_ percent: Double) -> Color {
        percent >= 95 ? Theme.danger : Theme.accent
    }

    /// Desde acá el número se destaca: en miel, y en rojo desde 95 %.
    static let highPercent: Double = 80

    /// Color del número: gris hasta 80 %, después el de la barra.
    static func textStyle(_ percent: Double) -> AnyShapeStyle {
        percent >= highPercent ? AnyShapeStyle(color(percent)) : AnyShapeStyle(Theme.secondaryText)
    }
}

/// Cuánto contexto ocupa la conversación: un anillito que se llena y «72%». En miel desde 80 % (con
/// la ayuda «Conviene usar /compact») y en rojo desde 95 %. Sin datos no dibuja nada: quien lo pone
/// en la barra lo pone solo si hay datos, para no dejar una cápsula vacía.
struct UsageBadge: View {
    @Environment(AppStore.self) private var store
    let sessionId: UUID
    var monitor: UsageMonitor = .shared

    var body: some View {
        content.task { monitor.attach(store) }
    }

    @ViewBuilder private var content: some View {
        if let percent = monitor.sessions[sessionId]?.contextPercent {
            let value = Int(percent.rounded())
            HStack(spacing: 4) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: min(max(percent, 0), 100) / 100)
                        .stroke(UsageMonitor.color(percent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 10, height: 10)
                Text("\(value)%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(UsageMonitor.textStyle(percent))
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)
            .help(Self.helpText(percent))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(value) % del contexto ocupado")
        }
    }

    /// «72 % del contexto ocupado», y desde 80 % «… Conviene usar /compact.».
    static func helpText(_ percent: Double) -> String {
        let value = Int(percent.rounded())
        return percent >= UsageMonitor.highPercent
            ? "\(value) % del contexto ocupado. Conviene usar /compact."
            : "\(value) % del contexto ocupado"
    }
}

/// Barritas con los límites de las cuentas: «Claude 5h · sem» y «Codex sem 80% · se reinicia el jue 14:00».
/// No muestra nada mientras no haya datos. `compact`: para el riel angosto de la vista compacta, un logo
/// con el límite más usado de cada cuenta. `insets` solo se suman si hay algo que mostrar.
struct UsageSummary: View {
    @Environment(AppStore.self) private var store
    var monitor: UsageMonitor = .shared
    var now: () -> Date = Date.init
    var compact = false
    var insets = EdgeInsets()

    var body: some View {
        let date = now()
        let rows = [monitor.claude, monitor.codex].compactMap { $0 }.filter { !$0.activeLimits(now: date).isEmpty }
        VStack(alignment: compact ? .center : .leading, spacing: compact ? 8 : 7) {
            ForEach(rows, id: \.agent) { snapshot in
                if compact {
                    UsageRailRow(snapshot: snapshot, now: date)
                } else {
                    UsageAccountRow(snapshot: snapshot, now: date)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
        .padding(rows.isEmpty ? EdgeInsets() : insets)
        .task { monitor.attach(store) }
    }
}

/// En el riel: el logo de la cuenta, su límite más usado y una barrita. El detalle va en la ayuda.
struct UsageRailRow: View {
    let snapshot: UsageSnapshot
    let now: Date

    var body: some View {
        let limits = snapshot.activeLimits(now: now)
        let top = limits.max { $0.usedPercent < $1.usedPercent }
        let percent = min(max(top?.usedPercent ?? 0, 0), 100)
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                AgentLogo(kind: snapshot.agent, size: 11)
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(UsageMonitor.textStyle(percent))
                    .fixedSize()
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(UsageMonitor.color(percent))
                    .frame(width: max(36 * percent / 100, percent > 0 ? 2 : 0))
            }
            .frame(width: 36, height: 3)
        }
        .help(UsageRailRow.helpText(snapshot.agent, limits: limits, now: now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UsageRailRow.helpText(snapshot.agent, limits: limits, now: now))
    }

    /// «Claude · 5 horas: 23 % usado · semana: 41 % usado, se reinicia el jue 14:00».
    static func helpText(_ agent: SessionKind, limits: [UsageLimit], now: Date) -> String {
        let parts = limits.map { limit in
            var text = "\(limit.longLabel): \(Int(min(max(limit.usedPercent, 0), 100).rounded())) % usado"
            if let resets = limit.resetsAt { text += ", " + UsageReader.resetText(resets, now: now) }
            return text
        }
        return ([agent.defaultName] + parts).joined(separator: " · ")
    }
}

struct UsageAccountRow: View {
    let snapshot: UsageSnapshot
    let now: Date

    var body: some View {
        let limits = snapshot.activeLimits(now: now)
        let top = limits.max { $0.usedPercent < $1.usedPercent }
        VStack(alignment: .leading, spacing: 3) {
            // En el sidebar angosto, si no entra el nombre queda solo el logo.
            ViewThatFits(in: .horizontal) {
                line(limits, showName: true)
                line(limits, showName: false)
            }
            // El porcentaje ya está arriba: abajo solo cuándo se reinicia el límite más usado.
            if let top, top.usedPercent >= 50, let resets = top.resetsAt {
                Text(Self.resetLine(top, resets: resets, now: now))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.leading, 20)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// «La semanal se reinicia el dom 21:11», «La de 5 horas se reinicia hoy 14:13».
    static func resetLine(_ limit: UsageLimit, resets: Date, now: Date) -> String {
        let name = switch limit.windowMinutes {
        case 10080?: "La semanal"
        case 60?: "La de una hora"
        case let minutes? where minutes > 60 && minutes % 60 == 0: "La de \(minutes / 60) horas"
        default: "El límite de \(limit.longLabel)"
        }
        return "\(name) \(UsageReader.resetText(resets, now: now))"
    }

    private func line(_ limits: [UsageLimit], showName: Bool) -> some View {
        HStack(spacing: 6) {
            AgentLogo(kind: snapshot.agent, size: 12)
                .help(snapshot.agent.label)
            if showName {
                Text(snapshot.agent.defaultName)
                    .font(.system(size: 11, weight: .semibold))
                    .fixedSize()
            }
            Spacer(minLength: 2)
            ForEach(Array(limits.enumerated()), id: \.offset) { _, limit in
                UsageLimitBar(agent: snapshot.agent, limit: limit, now: now)
            }
        }
    }
}

private struct UsageLimitBar: View {
    let agent: SessionKind
    let limit: UsageLimit
    let now: Date

    var body: some View {
        let percent = min(max(limit.usedPercent, 0), 100)
        HStack(spacing: 3) {
            Text(limit.label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize()
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(UsageMonitor.color(percent))
                    .frame(width: max(22 * percent / 100, percent > 0 ? 2 : 0))
            }
            .frame(width: 22, height: 4)
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(UsageMonitor.textStyle(percent))
                .fixedSize()
        }
        .help(helpText(percent))
        .accessibilityLabel(helpText(percent))
    }

    private func helpText(_ percent: Double) -> String {
        var text = "\(agent.defaultName) · \(limit.longLabel): \(Int(percent.rounded())) % usado"
        if let resets = limit.resetsAt { text += " · " + UsageReader.resetText(resets, now: now) }
        return text
    }
}
