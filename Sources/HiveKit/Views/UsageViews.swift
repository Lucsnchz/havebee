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

    /// El color con el que se destaca un porcentaje: nil (va en gris) hasta 80 %, después el de la barra.
    static func highlight(_ percent: Double) -> Color? {
        percent >= highPercent ? color(percent) : nil
    }

    /// Color del número: gris hasta 80 %, después el de la barra.
    static func textStyle(_ percent: Double) -> AnyShapeStyle {
        highlight(percent).map { AnyShapeStyle($0) } ?? AnyShapeStyle(Theme.secondaryText)
    }
}

/// Una porción de torta que empieza a las 12 y crece en el sentido de las agujas del reloj.
struct ContextPie: Shape {
    /// De 0 a 1 (lo de afuera se acota).
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        let fraction = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        if fraction >= 1 {
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        } else if fraction > 0 {
            path.move(to: center)
            path.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction),
                        clockwise: false)
            path.closeSubpath()
        }
        return path
    }
}

/// Cuánto contexto ocupa la conversación: una tortita que se llena y «72%». En gris hasta 80 %, en
/// miel desde 80 % (con la ayuda «Conviene usar /compact») y en rojo desde 95 %. Es una torta y no un
/// arco porque el arco miel es el de «trabajando», que va justo al lado en la barra. Sin datos no
/// dibuja nada: quien lo pone en la barra lo pone solo si hay datos, para no dejar una cápsula vacía.
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
                    Circle().fill(Color.primary.opacity(0.12))
                    ContextPie(fraction: percent / 100)
                        .fill(UsageMonitor.highlight(percent) ?? Theme.secondaryText)
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

/// Barritas con los límites de las cuentas («Claude 5h 23% · sem 87%») y, abajo, cuándo se reinicia el
/// más usado («El límite semanal se reinicia el jueves 14:00»).
/// Un clic abre las IAs instaladas y el detalle de uso. Sin porcentajes queda el acceso «IAs».
/// `compact`: para el riel angosto, un logo con el límite más usado de cada cuenta.
struct UsageSummary: View {
    @Environment(AppStore.self) private var store
    var monitor: UsageMonitor = .shared
    var now: () -> Date = Date.init
    var compact = false
    var insets = EdgeInsets()
    @State private var showsAgents = false
    @State private var hovering = false

    var body: some View {
        let date = now()
        let rows = [monitor.claude, monitor.codex].compactMap { $0 }.filter { !$0.activeLimits(now: date).isEmpty }
        Button {
            showsAgents = true
        } label: {
            VStack(alignment: compact ? .center : .leading, spacing: compact ? 8 : 7) {
                if rows.isEmpty {
                    Label(compact ? "IAs" : "IAs y uso", systemImage: "chart.bar")
                        .font(HiveFont.meta)
                        .foregroundStyle(Theme.secondaryText)
                }
                ForEach(rows, id: \.agent) { snapshot in
                    if compact {
                        UsageRailRow(snapshot: snapshot, now: date)
                    } else {
                        UsageAccountRow(snapshot: snapshot, now: date)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 26, alignment: compact ? .center : .leading)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(hovering ? 0.07 : 0),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Ver todas las IAs disponibles y sus límites de uso")
        .accessibilityLabel("IAs y límites de uso")
        .accessibilityValue(rows.map { UsageRailRow.helpText($0.agent, limits: $0.activeLimits(now: date), now: date) }
            .joined(separator: ". "))
        .popover(isPresented: $showsAgents) {
            AgentUsagePopover(monitor: monitor, now: now)
                .environment(store)
        }
        .padding(insets)
        .task { monitor.attach(store) }
    }
}

/// Todas las IAs de Hive, aunque alguna no esté instalada o todavía no informe sus límites.
struct AgentUsagePopover: View {
    @Environment(AppStore.self) private var store
    var monitor: UsageMonitor = .shared
    var now: () -> Date = Date.init

    var body: some View {
        let availability = AgentAvailability.shared(for: store)
        let date = now()
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("IAs y uso")
                        .font(HiveFont.heading)
                    Text("Agentes instalados y límites de sus cuentas")
                        .font(HiveFont.meta)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 12)
                Button {
                    availability.refresh()
                    monitor.refresh()
                } label: {
                    Label("Actualizar", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Volver a consultar las IAs instaladas y sus datos de uso")
            }
            Divider()
            ForEach(SessionKind.allCases.filter(\.isAgent)) { kind in
                AgentUsageRow(kind: kind, installed: availability.checked ? availability.isInstalled(kind) : nil,
                              snapshot: UsageMonitor.latest(kind, in: monitor.sessions), now: date)
            }
        }
        .padding(16)
        .frame(width: 370)
        .task {
            availability.refreshIfStale()
            monitor.attach(store)
            monitor.refresh()
        }
    }
}

private struct AgentUsageRow: View {
    let kind: SessionKind
    let installed: Bool?
    let snapshot: UsageSnapshot?
    let now: Date

    var body: some View {
        let limits = snapshot?.activeLimits(now: now) ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentLogo(kind: kind, size: 20)
                    .accessibilityHidden(true)
                Text(kind.label)
                    .font(HiveFont.heading)
                Spacer()
                Text(installed.map { $0 ? "Instalado" : "No instalado" } ?? "Comprobando…")
                    .font(HiveFont.meta)
                    .foregroundStyle(Theme.secondaryText)
            }
            if limits.isEmpty {
                Text(kind == .claude || kind == .codex ? "Sin datos de uso recientes" : "Límites de uso aún no disponibles en Havebee")
                    .font(HiveFont.secondary)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                // Claude y Codex informan dos ventanas como máximo (principal y secundaria).
                // Mantiene cada barra en su lugar cuando cambian los porcentajes.
                if let first = limits.first { limitDetail(first) }
                if limits.count > 1, let second = limits.last { limitDetail(second) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func limitDetail(_ limit: UsageLimit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                // Solo la primera letra: `capitalized` daba «5 Horas».
                Text(limit.longLabel.prefix(1).uppercased() + limit.longLabel.dropFirst())
                Spacer()
                Text("\(Int(limit.usedPercent.rounded())) % usado")
                    .monospacedDigit()
            }
            .font(HiveFont.secondary)
            ProgressView(value: limit.usedPercent, total: 100)
                .tint(UsageMonitor.color(limit.usedPercent))
                .accessibilityLabel("\(kind.defaultName), \(limit.longLabel)")
                .accessibilityValue("\(Int(limit.usedPercent.rounded())) % usado")
            if let reset = limit.resetsAt {
                Text(UsageReader.resetText(reset, now: now))
                    .font(HiveFont.meta)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
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

    /// «Claude · 5 horas: 23 % usado · semana: 41 % usado, se reinicia el jueves 14:00».
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
            // En el sidebar angosto se van primero las barritas (el porcentaje ya tiene el color) y
            // después el nombre: queda el logo.
            ViewThatFits(in: .horizontal) {
                line(limits, showName: true, showBars: true)
                line(limits, showName: true, showBars: false)
                line(limits, showName: false, showBars: false)
            }
            // El porcentaje ya está arriba: abajo solo cuándo se reinicia el límite más usado.
            if let top, top.usedPercent >= 50, let resets = top.resetsAt {
                ViewThatFits(in: .horizontal) {
                    resetText(Self.resetLine(top, resets: resets, now: now)).fixedSize()
                    resetText(Self.shortResetLine(top, resets: resets, now: now)).fixedSize()
                    // Si ni así entra, en dos líneas en vez de cortarse.
                    resetText(Self.shortResetLine(top, resets: resets, now: now))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 18)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// «El límite semanal se reinicia el domingo 21:11», «El límite de 5 horas se reinicia hoy 14:13».
    static func resetLine(_ limit: UsageLimit, resets: Date, now: Date) -> String {
        "\(windowName(limit.windowMinutes)) \(UsageReader.resetText(resets, now: now))"
    }

    /// Lo mismo, más corto, para el sidebar angosto: «Semana: se reinicia el domingo 21:11».
    static func shortResetLine(_ limit: UsageLimit, resets: Date, now: Date) -> String {
        let name = limit.longLabel.prefix(1).uppercased() + limit.longLabel.dropFirst()
        return "\(name): \(UsageReader.resetText(resets, now: now))"
    }

    private func resetText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.secondaryText)
    }

    /// El nombre de un límite según su ventana: «El límite semanal», «El límite de 5 horas»… Sin
    /// ventana conocida (Codex no siempre la manda), «El límite». Antes era «La semanal», sin decir de qué.
    static func windowName(_ minutes: Int?) -> String {
        switch minutes {
        case 10080?: "El límite semanal"
        case 1440?: "El límite diario"
        case 60?: "El límite de una hora"
        case 1?: "El límite de un minuto"
        case let minutes? where minutes > 0 && minutes % 1440 == 0: "El límite de \(minutes / 1440) días"
        case let minutes? where minutes > 60 && minutes % 60 == 0: "El límite de \(minutes / 60) horas"
        case let minutes? where minutes > 0: "El límite de \(minutes) minutos"
        default: "El límite"
        }
    }

    private func line(_ limits: [UsageLimit], showName: Bool, showBars: Bool) -> some View {
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
                UsageLimitBar(agent: snapshot.agent, limit: limit, now: now, showsBar: showBars)
            }
        }
    }
}

private struct UsageLimitBar: View {
    let agent: SessionKind
    let limit: UsageLimit
    let now: Date
    var showsBar = true

    var body: some View {
        let percent = min(max(limit.usedPercent, 0), 100)
        HStack(spacing: 3) {
            Text(limit.label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize()
            if showsBar {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(UsageMonitor.color(percent))
                        .frame(width: max(22 * percent / 100, percent > 0 ? 2 : 0))
                }
                .frame(width: 22, height: 4)
            }
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
