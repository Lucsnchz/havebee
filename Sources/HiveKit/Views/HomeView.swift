import HiveCore
import SwiftUI

/// Sesiones de todos los proyectos agrupadas por lo que necesitan de vos (para el Inicio).
struct HomeSessionGroups {
    struct Item: Identifiable {
        let project: Project
        let branch: Branch
        let session: Session
        var id: UUID { session.id }
    }

    struct Group: Identifiable {
        let title: String
        /// El estado que junta al grupo, dibujado como en el sidebar y las tarjetas (`.none` en
        /// «Recientes», que lleva un reloj).
        let ring: Activity.Ring
        let items: [Item]
        var id: String { title }
    }

    static let recentLimit = 6

    /// «Necesitan permiso», «Tu turno», «Trabajando» y las 6 más recientes del resto. Los grupos
    /// vacíos no se incluyen. Dentro de cada grupo, primero lo más reciente.
    static func build(projects: [Project], status: (UUID) -> SessionStatus?) -> [Group] {
        var all: [Item] = []
        for project in projects {
            for branch in project.branches {
                for session in branch.activeSessions { all.append(Item(project: project, branch: branch, session: session)) }
            }
        }
        all.sort { $0.session.recency > $1.session.recency }
        let attention = all.filter { status($0.id) == .attention }
        let waiting = all.filter { status($0.id) == .waiting }
        let working = all.filter { status($0.id) == .working }
        let shown = Set((attention + waiting + working).map(\.id))
        let recent = Array(all.filter { !shown.contains($0.id) }.prefix(recentLimit))
        return [
            Group(title: "Necesitan permiso", ring: .attention, items: attention),
            Group(title: "Tu turno", ring: .pending, items: waiting),
            Group(title: "Trabajando", ring: .working, items: working),
            Group(title: "Recientes", ring: .none, items: recent),
        ].filter { !$0.items.isEmpty }
    }

    /// Ancho mínimo de una tarjeta y espacio entre ellas: como mucho tres por fila.
    static let cardMinWidth: CGFloat = 270
    static let spacing: CGFloat = 16
    static let maxColumns = 3

    /// Cuántas tarjetas entran por fila en `width`.
    static func columns(for width: CGFloat) -> Int {
        max(1, min(maxColumns, Int((width + spacing) / (cardMinWidth + spacing))))
    }

    /// Un grupo en su fila, con cuántas columnas ocupa.
    struct Placement: Identifiable {
        let group: Group
        let span: Int
        var id: String { group.id }
    }

    struct Row: Identifiable {
        let placements: [Placement]
        var id: String { placements.map(\.id).joined(separator: "+") }
    }

    /// Los grupos van uno al lado del otro: cada uno ocupa tantas columnas como tarjetas tenga
    /// (hasta el ancho entero) y, si no entra en lo que queda de la fila, pasa a la siguiente. Con una
    /// sesión en cada grupo, «Necesitan permiso», «Tu turno» y «Trabajando» quedan en una sola fila
    /// en vez de una debajo de la otra. «Recientes» siempre usa todo el ancho, en su propia fila.
    static func rows(_ groups: [Group], columns: Int) -> [Row] {
        var rows: [[Placement]] = []
        var used = columns
        for group in groups {
            let span = group.ring == .none ? columns : min(max(group.items.count, 1), columns)
            if used + span > columns {
                rows.append([])
                used = 0
            }
            rows[rows.count - 1].append(Placement(group: group, span: span))
            used += span
        }
        return rows.map(Row.init)
    }

    /// La línea de arriba del Inicio: «2 sesiones te esperan y una está trabajando.»
    static func summary(waiting: Int, working: Int) -> String {
        switch (waiting, working) {
        case (0, 0): return "Nada te espera por ahora."
        case (_, 0): return waiting == 1 ? "Una sesión te espera." : "\(waiting) sesiones te esperan."
        case (0, _): return working == 1 ? "Una sesión está trabajando." : "\(working) sesiones están trabajando."
        default:
            let first = waiting == 1 ? "Una sesión te espera" : "\(waiting) sesiones te esperan"
            return first + (working == 1 ? " y una está trabajando." : " y \(working) están trabajando.")
        }
    }
}

/// Inicio: lo que te espera en todos tus proyectos, sin tener que recorrer el árbol.
struct HomeView: View {
    @Environment(AppStore.self) private var store
    /// El ancho del contenido, para saber cuántas tarjetas entran por fila.
    @State private var width: CGFloat = 0

    var body: some View {
        let groups = HomeSessionGroups.build(projects: store.projects, status: { store.runtimes[$0]?.status })
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header(groups)
                if groups.isEmpty {
                    emptyState
                } else {
                    let columns = HomeSessionGroups.columns(for: width)
                    ForEach(HomeSessionGroups.rows(groups, columns: columns)) { row in
                        HStack(alignment: .top, spacing: HomeSessionGroups.spacing) {
                            ForEach(row.placements) { placement in
                                HomeGroupSection(group: placement.group, columns: placement.span)
                                    .frame(width: blockWidth(placement.span, of: columns))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Inicio")
    }

    /// El ancho de un grupo que ocupa `span` columnas: todas las tarjetas miden lo mismo, estén en
    /// la fila que estén. Antes de medir, cada grupo usa el ancho que le den.
    private func blockWidth(_ span: Int, of columns: Int) -> CGFloat? {
        guard width > 0 else { return nil }
        let spacing = HomeSessionGroups.spacing
        let column = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return column * CGFloat(span) + spacing * CGFloat(span - 1)
    }

    private func header(_ groups: [HomeSessionGroups.Group]) -> some View {
        let waiting = groups.filter { $0.title == "Necesitan permiso" || $0.title == "Tu turno" }.map(\.items.count).reduce(0, +)
        let working = groups.first { $0.title == "Trabajando" }?.items.count ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            Text("Inicio")
                .font(.system(size: 26, weight: .bold))
            Text(HomeSessionGroups.summary(waiting: waiting, working: working))
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Todavía no abriste ninguna sesión.")
                .font(.headline)
            Text("Elegí un proyecto o una rama en la barra lateral y abrí Claude, Codex, Gemini, Grok o una terminal.")
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct HomeGroupSection: View {
    let group: HomeSessionGroups.Group
    /// Cuántas tarjetas por fila: las columnas que ocupa el grupo.
    let columns: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Group {
                    if group.ring == .none {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                    } else {
                        RingIndicator(ring: group.ring, size: 12)
                    }
                }
                .frame(width: 18)
                .accessibilityHidden(true)
                Text(group.title)
                    .font(.headline)
                Text("\(group.items.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            // La misma altura con cualquier ícono: los grupos van uno al lado del otro y las tarjetas
            // tienen que empezar a la misma altura.
            .frame(height: 22)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: HomeSessionGroups.spacing, alignment: .top), count: columns),
                      alignment: .leading, spacing: HomeSessionGroups.spacing) {
                ForEach(group.items) { item in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            ProjectTile(project: item.project, size: 16)
                            Text(item.project.isScratch ? item.project.name : "\(item.project.name) › \(item.branch.name)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.leading, 2)
                        SessionCard(project: item.project, branch: item.branch, session: item.session)
                    }
                }
            }
        }
    }
}
