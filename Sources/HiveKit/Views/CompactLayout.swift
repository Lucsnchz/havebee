import AppKit
import HiveCore
import SwiftUI
import UniformTypeIdentifiers

/// Vista compacta: barra angosta con los proyectos y las sesiones del proyecto como pestañas.
struct CompactLayout: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            ProjectRail()
            Divider()
            if let id = store.currentProjectId, let project = store.project(id) {
                VStack(spacing: 0) {
                    ProjectTabBar(project: project)
                    Divider()
                    DetailView()
                }
            } else {
                EmptyDetailView()
            }
        }
    }
}

// MARK: - Barra de proyectos

private struct ProjectRail: View {
    @Environment(AppStore.self) private var store
    @State private var dropTargeted = false
    /// El proyecto que se está arrastrando para reordenar el riel.
    @State private var dragging: UUID?

    var body: some View {
        // El mismo orden que el árbol y que ⌃⌘1…⌃⌘9: fijados, activos de hoy, apagados y «Terminales».
        let items = store.visibleProjects
        let pinnedCount = items.filter { $0.group == .pinned }.count
        VStack(spacing: 0) {
            HomeRailItem()
                .padding(.top, 12)
            Divider()
                .padding(.horizontal, 16)
                .padding(.top, 10)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if item.group != .scratch {
                            // Un divisor fino entre los fijados y el resto.
                            if index == pinnedCount && pinnedCount > 0 {
                                RailDivider()
                            }
                            RailItem(project: item.project, isActive: item.isActive, shortcut: HiveCommands.Shortcut.project(index))
                                // Arrastrar para reordenar, dentro de su grupo (fijar es con el menú).
                                .onDrag {
                                    dragging = item.id
                                    return RailReorderDelegate.provider(for: item.id)
                                }
                                .onDrop(of: [RailReorderDelegate.type], delegate: RailReorderDelegate(target: item.id, dragging: $dragging, store: store))
                        }
                    }
                }
                .padding(.vertical, 14)
                .animation(.snappy, value: items.map(\.id))
            }
            Divider().padding(.horizontal, 16)
            if let index = items.firstIndex(where: { $0.group == .scratch }) {
                RailItem(project: items[index].project, isActive: items[index].isActive,
                         shortcut: HiveCommands.Shortcut.project(index))
                    .padding(.top, 10)
            }
            // Los límites de las cuentas, en chiquito (nada mientras no haya datos).
            UsageSummary(compact: true, insets: EdgeInsets(top: 12, leading: 0, bottom: 0, trailing: 0))
            Button {
                store.addProjectInteractive()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Agregar proyecto (⌘O); también podés soltar carpetas acá")
            .accessibilityLabel("Agregar proyecto")
            .padding(.vertical, 12)
        }
        .frame(width: 72)
        .background(VisualEffectBackground(material: .sidebar))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        // Soltar carpetas de repos agrega cada una como proyecto.
        .dropDestination(for: URL.self) { urls, _ in
            let folders = CompactLayout.droppedFolders(urls)
            guard !folders.isEmpty else { return false }
            Task {
                for path in folders { await store.addProject(at: path) }
            }
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}

extension CompactLayout {
    /// Las carpetas entre lo que se soltó en el riel, como rutas. Se mira el disco y no la barra
    /// final de la URL: Finder a veces manda referencias (file:///.file/id=…) o rutas sin la barra.
    static func droppedFolders(_ urls: [URL]) -> [String] {
        urls.compactMap { url in
            guard url.isFileURL else { return nil }
            let path = ((url as NSURL).filePathURL ?? url).path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return path
        }
    }
}

/// «Inicio» arriba del riel: lo que te espera en todos los proyectos.
private struct HomeRailItem: View {
    @Environment(AppStore.self) private var store
    @State private var hovering = false

    var body: some View {
        let selected = store.selection == nil
        let activity = store.activity(of: store.projects.flatMap(\.activeSessions))
        Button {
            store.select(nil)
        } label: {
            ZStack(alignment: .leading) {
                RailIndicator(selected: selected, hovering: hovering)
                Image(nsImage: NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
                    .frame(width: 40, height: 40)
                    .background(Color.primary.opacity(selected ? 0.12 : (hovering ? 0.08 : 0.05)),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        ActivityBadge(activity: activity, outlined: true)
                            .offset(x: 7, y: -7)
                    }
                    .frame(maxWidth: .infinity)
            }
            .frame(width: 72, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Inicio: lo que te espera en todos los proyectos (\(HiveCommands.Shortcut.home.description))")
        .accessibilityLabel(ActivityBadge.accessibilityText(activity).map { "Inicio, \($0)" } ?? "Inicio")
    }
}

/// Indicador del elemento activo del riel, como en Discord.
private struct RailIndicator: View {
    let selected: Bool
    let hovering: Bool

    var body: some View {
        Capsule()
            .fill(Color.primary)
            .frame(width: 4, height: selected ? 30 : (hovering ? 12 : 0))
            .offset(x: -2)
            .animation(.easeOut(duration: 0.15), value: selected)
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct RailItem: View {
    @Environment(AppStore.self) private var store
    let project: Project
    /// Tiene algo prendido o se usó hoy. Si no, se ve atenuado (sin aro: no hay nada que mostrar).
    var isActive = true
    /// ⌃⌘N para ir a este proyecto (los nueve primeros).
    var shortcut: HiveCommands.Shortcut?
    @State private var hovering = false

    var body: some View {
        let selected = store.currentProjectId == project.id
        let activity = store.activity(of: project)
        Button {
            store.openProject(project.id)
        } label: {
            ZStack(alignment: .leading) {
                RailIndicator(selected: selected, hovering: hovering)
                ProjectTile(project: project, size: 40, activity: activity, showsBadge: true)
                    .dimmedProject(!isActive && !selected && !hovering)
                    .scaleEffect(hovering && !selected ? 1.04 : 1)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: 72, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(shortcut.map { "\(project.name) (\($0))" } ?? project.name)
        .accessibilityLabel(Self.accessibilityText(project: project, activity: activity, isActive: isActive))
        .contextMenu {
            if project.isScratch, let branch = project.branches.first {
                ScratchMenu(project: project, branch: branch)
            } else {
                ProjectMenu(project: project)
            }
        }
    }

    /// «ecommerce, fijado, 2 sesiones te esperan» o «bevo, sin actividad hoy».
    static func accessibilityText(project: Project, activity: Activity, isActive: Bool = true) -> String {
        var parts = [project.name]
        if project.pinned { parts.append("fijado") }
        if activity.waitingForYou > 0 {
            parts.append(activity.waitingForYou == 1 ? "una sesión te espera" : "\(activity.waitingForYou) sesiones te esperan")
        } else if !isActive {
            parts.append("sin actividad hoy")
        }
        return parts.joined(separator: ", ")
    }
}

/// Reordena el riel mientras arrastrás: al pasar sobre otro proyecto del mismo grupo, el arrastrado
/// toma su lugar (lo que se guarda es el orden que se ve). Solo acepta arrastres que empezaron en el
/// riel: las carpetas que soltás para agregar proyectos las sigue tomando el riel entero.
struct RailReorderDelegate: DropDelegate {
    /// Tipo propio del arrastre, que no sale de Hive: si fuera texto, al soltarlo sobre una terminal
    /// se escribiría el id del proyecto.
    static let type = UTType(filenameExtension: "hive-proyecto-del-riel", conformingTo: .data) ?? .data

    static func provider(for id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    let target: UUID
    @Binding var dragging: UUID?
    let store: AppStore

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.snappy) { _ = store.moveProject(dragging, onto: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragging == nil ? nil : DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let handled = dragging != nil
        dragging = nil
        return handled
    }
}

/// Divisor fino entre los proyectos fijados y el resto.
private struct RailDivider: View {
    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.18))
            .frame(width: 28, height: 1)
            .accessibilityHidden(true)
    }
}

// MARK: - Pestañas

private struct ProjectTabBar: View {
    @Environment(AppStore.self) private var store
    let project: Project
    /// El subrayado se desliza de una pestaña a otra.
    @Namespace private var underline

    var body: some View {
        let (tabs, showBranch) = ProjectTabs.make(project)
        HStack(spacing: 0) {
            OverviewTab(project: project, namespace: underline)
            Divider().frame(height: 18)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                            SessionTab(project: project, branch: tab.branch, session: tab.session, showBranch: showBranch,
                                       shortcut: HiveCommands.Shortcut.tab(index), namespace: underline)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .onChange(of: store.selection) { _, selection in
                    // La pestaña elegida con el teclado (⌘1…⌘9, ⇧⌘]) siempre queda a la vista.
                    if case .session(let id)? = selection, tabs.contains(where: { $0.id == id }) {
                        withAnimation(.snappy) { proxy.scrollTo(id) }
                    }
                }
            }
            NewSessionButton(project: project)
                .padding(.horizontal, 6)
        }
        .frame(height: 40)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Subrayado del color del proyecto bajo la pestaña abierta.
private struct TabUnderline: View {
    let color: Color
    let namespace: Namespace.ID

    var body: some View {
        Capsule()
            .fill(color)
            .frame(height: 2)
            .padding(.horizontal, 8)
            .matchedGeometryEffect(id: "subrayado", in: namespace)
    }
}

struct OverviewTab: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let namespace: Namespace.ID
    @State private var hovering = false

    var body: some View {
        let selected: Bool = {
            switch store.selection {
            case .project(let id)?: id == project.id
            case .branch(let id)?: project.branches.contains { $0.id == id }
            default: false
            }
        }()
        Button {
            withAnimation(.snappy) { store.select(.project(project.id)) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                Text("Resumen")
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .background(selected ? Color.primary.opacity(0.08) : (hovering ? Color.primary.opacity(0.04) : .clear))
            .overlay(alignment: .bottom) {
                if selected { TabUnderline(color: project.tint.color, namespace: namespace) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Resumen del proyecto: ramas, comandos y MCP")
        .accessibilityLabel("Resumen de \(project.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SessionTab: View {
    @Environment(AppStore.self) private var store
    let project: Project
    let branch: Branch
    let session: Session
    let showBranch: Bool
    /// ⌘N para ir a esta pestaña (las nueve primeras).
    var shortcut: HiveCommands.Shortcut?
    let namespace: Namespace.ID
    @State private var hovering = false

    var body: some View {
        let selected = store.selection == .session(session.id)
        let rt = store.runtimes[session.id]
        let dormant = (rt?.status ?? .dormant) == .dormant
        Button {
            withAnimation(.snappy) { store.select(.session(session.id)) }
        } label: {
            HStack(spacing: 6) {
                AgentLogo(kind: session.kind, size: 14)
                Text(session.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                if showBranch {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle((branch.color ?? project.tint).color)
                        // Acortada por el medio: el principio y el final son lo que distingue a una rama.
                        Text(branch.name.middleTruncated(max: 24))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10.5))
                    // La misma prioridad que el nombre: con un nombre largo (el automático, del
                    // primer pedido) los dos se acortan, y una rama corta como «main» se ve entera.
                    .layoutPriority(1)
                }
                Spacer(minLength: 0)
                // El lugar del estado no ocupa nada si la sesión duerme (salvo con el puntero encima).
                statusSlot(rt: rt)
                    .frame(width: dormant && !hovering ? 0 : 16)
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.leading, 12)
            .padding(.trailing, dormant && !hovering ? 12 : 8)
            .frame(minWidth: 96, maxWidth: 220, minHeight: 30)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.09) : (hovering ? Color.primary.opacity(0.05) : .clear))
            }
            .overlay(alignment: .bottom) {
                if selected { TabUnderline(color: project.tint.color, namespace: namespace) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { store.beginRename(.session(session.id)) })
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(accessibilityText(rt: rt))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Archivar") { store.requestArchive(session.id) }
        .accessibilityAction(named: "Renombrar") { store.beginRename(.session(session.id)) }
        .contextMenu { SessionMenu(project: project, branch: branch, session: session) }
    }

    @ViewBuilder private func statusSlot(rt: SessionRuntime?) -> some View {
        ZStack {
            if let rt, !hovering {
                StatusIndicator(status: rt.status, unseen: rt.unseen, kind: session.kind)
            }
            if hovering {
                Button {
                    store.requestArchive(session.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(Color.primary.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Cerrar pestaña (\(HiveCommands.Shortcut.archive.description)): archiva la sesión; la podés restaurar desde la rama o con ⌘K")
            }
        }
    }

    private var helpText: String {
        let place = project.isScratch ? session.name : "\(session.name) · \(branch.name)"
        return shortcut.map { "\(place) (\($0)) · doble clic para renombrar" } ?? "\(place) · doble clic para renombrar"
    }

    /// «Claude 1, rama main, Tu turno».
    private func accessibilityText(rt: SessionRuntime?) -> String {
        var parts = [session.name]
        if !project.isScratch { parts.append("rama \(branch.name)") }
        if let rt, rt.status != .dormant { parts.append(rt.status.label(for: session.kind)) }
        return parts.joined(separator: ", ")
    }
}

/// "+" de la barra de pestañas: nueva sesión en la rama actual u otra.
private struct NewSessionButton: View {
    @Environment(AppStore.self) private var store
    let project: Project

    var body: some View {
        let current = store.defaultBranch(for: project)
        Menu {
            if let current {
                Section(project.isScratch ? "En tu carpeta personal" : "En \(current.name)") {
                    NewSessionItems(branchId: current.id)
                }
            }
            let others = project.branches.filter { $0.id != current?.id }
            if !others.isEmpty && !project.isScratch {
                Menu("En otra rama") {
                    ForEach(others) { branch in
                        Menu(branch.name) { NewSessionItems(branchId: branch.id) }
                    }
                }
            }
            if !project.isScratch {
                Divider()
                Button("Nueva rama…") { store.newBranchTarget = NewBranchTarget(id: project.id) }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Nueva sesión (\(HiveCommands.Shortcut.newSession.description) crea una del mismo agente en esta rama)")
        .accessibilityLabel("Nueva sesión")
    }
}

/// Fondo translúcido nativo (el mismo material que la barra lateral de macOS).
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
