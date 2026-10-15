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
        let symbol: String
        let tint: Color
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
            Group(title: "Necesitan permiso", symbol: "hand.raised.fill", tint: Theme.attention, items: attention),
            Group(title: "Tu turno", symbol: "arrowshape.turn.up.left.fill", tint: Theme.pending, items: waiting),
            Group(title: "Trabajando", symbol: "sparkles", tint: Theme.accent, items: working),
            Group(title: "Recientes", symbol: "clock", tint: .secondary, items: recent),
        ].filter { !$0.items.isEmpty }
    }
}

/// Inicio: lo que te espera en todos tus proyectos, sin tener que recorrer el árbol.
struct HomeView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let groups = HomeSessionGroups.build(projects: store.projects, status: { store.runtimes[$0]?.status })
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header(groups)
                if groups.isEmpty {
                    emptyState
                } else {
                    ForEach(groups) { group in
                        HomeGroupSection(group: group)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Inicio")
    }

    private func header(_ groups: [HomeSessionGroups.Group]) -> some View {
        let waiting = groups.filter { $0.title == "Necesitan permiso" || $0.title == "Tu turno" }.map(\.items.count).reduce(0, +)
        let working = groups.first { $0.title == "Trabajando" }?.items.count ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            Text("Inicio")
                .font(.system(size: 26, weight: .bold))
            Text(summary(waiting: waiting, working: working))
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private func summary(waiting: Int, working: Int) -> String {
        var parts: [String] = []
        if waiting > 0 { parts.append(waiting == 1 ? "Una sesión te espera" : "\(waiting) sesiones te esperan") }
        if working > 0 { parts.append(working == 1 ? "una está trabajando" : "\(working) están trabajando") }
        if parts.isEmpty { return "Nada te espera por ahora." }
        return parts.joined(separator: " y ") + "."
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Todavía no abriste ninguna sesión.")
                .font(.headline)
            Text("Elegí un proyecto o una rama en la barra lateral y abrí Claude, Codex, Gemini o una terminal.")
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct HomeGroupSection: View {
    let group: HomeSessionGroups.Group

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: group.symbol)
                    .foregroundStyle(group.tint)
                Text(group.title)
                    .font(.headline)
                Text("\(group.items.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 420), spacing: 16, alignment: .top)],
                      alignment: .leading, spacing: 16) {
                ForEach(group.items) { item in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            ProjectTile(project: item.project, size: 16)
                            Text(item.project.isScratch ? item.project.name : "\(item.project.name) › \(item.branch.name)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
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
