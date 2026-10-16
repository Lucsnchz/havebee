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
        .overlay(alignment: .bottomTrailing) {
            // En una sesión los comandos van en su barra de abajo: la esquinita taparía el prompt.
            if !showsSession { CommandsDock() }
        }
        .overlay(alignment: .bottom) {
            UndoToastView()
                .padding(.bottom, 18)
        }
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
        .tint(Theme.accent)
        .modifier(StoreDialogs())
    }

    private var showsSession: Bool {
        if case .session? = store.selection { return true }
        return false
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

/// Sin nada elegido: el Inicio si ya hay proyectos, la bienvenida si no.
struct EmptyDetailView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.repoProjects.isEmpty {
            WelcomeView()
        } else {
            HomeView()
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
            .alert(store.alert?.title ?? "", isPresented: alertPresence, presenting: store.alert) { alert in
                if let title = alert.actionTitle {
                    // Si la acción abre otra alerta, se encola y aparece cuando se cierra esta.
                    Button(title, role: alert.isDestructive ? .destructive : nil) { alert.action?() }
                    Button(alert.cancelTitle ?? "Cancelar", role: .cancel) {}
                } else {
                    Button(alert.cancelTitle ?? "OK", role: .cancel) {}
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
                Text(pending.message)
            }
            .confirmationDialog(store.pendingRemoval?.title ?? "", isPresented: presence(\.pendingRemoval),
                                titleVisibility: .visible, presenting: store.pendingRemoval) { removal in
                switch removal.item {
                case .branch:
                    Button("Quitar de Hive") { store.remove(removal.item) }
                    if removal.isWorktree {
                        Button("Quitar y borrar el worktree", role: .destructive) { store.remove(removal.item, deleteWorktree: true) }
                    }
                case .session(let id):
                    if removal.offersArchive {
                        Button("Archivar en su lugar") { store.archive(id) }
                    }
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

    /// Al cerrarse, saca de la cola justo la alerta que se mostró (y no la siguiente).
    private var alertPresence: Binding<Bool> {
        let shown = store.alert?.id
        return Binding(get: { store.alert != nil },
                       set: { if !$0, let shown { store.dismissAlert(shown) } })
    }
}
