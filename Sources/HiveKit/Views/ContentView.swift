import HiveCore
import SwiftUI

enum HiveLayout: String {
    /// Barra lateral con el árbol Proyectos → Ramas → Sesiones.
    case tree
    /// Barra angosta con los proyectos y las sesiones como pestañas.
    case compact
}

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("layout") private var layout: HiveLayout = .tree

    var body: some View {
        Group {
            switch layout {
            case .tree:
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 440)
                } detail: {
                    DetailView()
                }
            case .compact:
                CompactLayout()
            }
        }
        .overlay(alignment: .bottomTrailing) { CommandsDock() }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    store.showSwitcher = true
                } label: {
                    Label("Buscar", systemImage: "magnifyingglass")
                }
                .help("Ir a un proyecto, rama, sesión o comando (⌘K)")
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    layout = layout == .tree ? .compact : .tree
                } label: {
                    Label(layout == .tree ? "Vista compacta" : "Vista de árbol",
                          systemImage: layout == .tree ? "rectangle.split.3x1" : "list.bullet.indent")
                }
                .help(layout == .tree ? "Cambiar a la vista compacta (proyectos y pestañas)" : "Cambiar a la vista de árbol")
            }
        }
        .tint(.honey)
        .modifier(StoreDialogs())
    }
}

struct DetailView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        switch store.selection {
        case .session(let id)? where store.sessionContext(id) != nil:
            SessionDetailView(sessionId: id)
        case .branch(let id)? where store.branchContext(id) != nil:
            BranchDetailView(branchId: id)
        case .project(let id)? where store.project(id)?.isScratch == true:
            if let branch = store.project(id)?.branches.first { BranchDetailView(branchId: branch.id) }
        case .project(let id)? where store.project(id) != nil:
            ProjectDetailView(projectId: id)
        default:
            EmptyDetailView()
        }
    }
}

struct EmptyDetailView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label("Hive", systemImage: "hexagon")
        } description: {
            Text(store.repoProjects.isEmpty
                 ? "Agregá un repositorio para empezar. Después creá ramas y abrí sesiones de Claude Code, Codex o terminal."
                 : "Elegí un proyecto, una rama o una sesión en la barra lateral.")
        } actions: {
            if store.repoProjects.isEmpty {
                Button("Agregar proyecto…") { store.addProjectInteractive() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Alertas y diálogos que dispara el store desde cualquier lugar de la app.
private struct StoreDialogs: ViewModifier {
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        @Bindable var store = store
        content
            .sheet(item: $store.newBranchTarget) { target in
                NewBranchSheet(projectId: target.id)
            }
            .sheet(item: $store.customizeTarget) { target in
                CustomizeProjectSheet(projectId: target.id)
            }
            .sheet(item: $store.commandEditor) { target in
                CommandEditorSheet(target: target)
            }
            .sheet(item: $store.mcpEditor) { target in
                MCPEditorSheet(target: target)
            }
            .sheet(item: $store.diffTarget) { target in
                DiffSheet(target: target)
            }
            .sheet(isPresented: $store.showSwitcher) {
                QuickSwitcher()
            }
            .alert(store.alert?.title ?? "", isPresented: presence(\.alert), presenting: store.alert) { alert in
                if let title = alert.actionTitle {
                    Button(title, role: .destructive) {
                        // Esperamos a que se cierre esta alerta por si la acción abre otra.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { alert.action?() }
                    }
                    Button("Cancelar", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { alert in
                Text(alert.message)
            }
            .confirmationDialog("¿Hacer checkout de «\(store.pendingCheckout?.branchName ?? "")»?",
                                isPresented: presence(\.pendingCheckout), titleVisibility: .visible,
                                presenting: store.pendingCheckout) { pending in
                Button("Hacer checkout") { store.confirmCheckout(pending) }
                Button("Cancelar", role: .cancel) {}
            } message: { pending in
                Text(checkoutMessage(pending))
            }
            .confirmationDialog(store.pendingRemoval?.title ?? "", isPresented: presence(\.pendingRemoval),
                                titleVisibility: .visible, presenting: store.pendingRemoval) { removal in
                switch removal.item {
                case .branch:
                    Button("Quitar de Hive") { store.remove(removal.item) }
                    if removal.isWorktree {
                        Button("Quitar y borrar el worktree", role: .destructive) { store.remove(removal.item, deleteWorktree: true) }
                    }
                case .session:
                    Button("Eliminar sesión", role: .destructive) { store.remove(removal.item) }
                case .project:
                    Button("Quitar de Hive", role: .destructive) { store.remove(removal.item) }
                }
                Button("Cancelar", role: .cancel) {}
            } message: { removal in
                Text(removal.message)
            }
            .alert("Renombrar", isPresented: presence(\.rename), presenting: store.rename) { request in
                TextField("Nombre", text: $store.renameText)
                Button("Guardar") { store.commitRename(request) }
                Button("Cancelar", role: .cancel) {}
            }
    }

    private func presence<T>(_ keyPath: ReferenceWritableKeyPath<AppStore, T?>) -> Binding<Bool> {
        Binding(get: { store[keyPath: keyPath] != nil },
                set: { if !$0 { store[keyPath: keyPath] = nil } })
    }

    private func checkoutMessage(_ pending: PendingCheckout) -> String {
        let head = pending.currentHead.isEmpty ? "un commit suelto (HEAD desacoplado)" : "«\(pending.currentHead)»"
        var text = "La carpeta principal está en \(head). Esta rama no tiene worktree, así que para trabajar en ella hay que cambiar la carpeta principal."
        if pending.dirty {
            text += "\n\nHay cambios sin commitear: git los lleva a la nueva rama, o cancela el checkout si chocan."
        }
        if pending.runningElsewhere > 0 {
            text += "\n\n\(pending.runningElsewhere == 1 ? "Una sesión abierta" : "\(pending.runningElsewhere) sesiones abiertas") en otras ramas de la carpeta principal van a quedar viendo esta rama."
        }
        return text
    }
}
