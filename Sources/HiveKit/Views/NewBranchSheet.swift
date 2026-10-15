import HiveCore
import SwiftUI

struct NewBranchSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let projectId: UUID

    @State private var isNew = true
    @State private var name = ""
    @State private var base = ""
    @State private var existing = ""
    @State private var mode: BranchMode = .worktree
    @State private var firstSession: SessionKind? = .claude
    @State private var localBranches: [String] = []
    @State private var remoteBranches: [String] = []
    @State private var worktrees: [GitWorktree] = []
    @State private var loading = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let project = store.project(projectId)
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Origen", selection: $isNew) {
                        Text("Nueva rama").tag(true)
                        Text("Rama existente").tag(false)
                    }
                    .pickerStyle(.segmented)

                    if isNew {
                        TextField("Nombre", text: $name, prompt: Text("feature/mi-cambio"))
                        Picker("Desde", selection: $base) {
                            ForEach(localBranches, id: \.self) { Text($0).tag($0) }
                        }
                    } else if availableExisting.isEmpty && availableRemote.isEmpty {
                        Text(loading ? "Cargando ramas…" : "No hay otras ramas para agregar.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Rama", selection: $existing) {
                            ForEach(availableExisting, id: \.self) { Text($0).tag($0) }
                            if !availableRemote.isEmpty {
                                Section("Remotas") {
                                    ForEach(availableRemote, id: \.self) { Text($0).tag($0) }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Nueva rama en \(project?.name ?? "")")
                }

                Section("Dónde trabajar") {
                    if let adopted = adoptedWorktree, let project {
                        Label(samePath(adopted.path, project.path)
                              ? "Esta rama ya está en la carpeta principal."
                              : "Esta rama ya tiene un worktree en \(adopted.path). Se usa ese.",
                              systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Modo", selection: $mode) {
                            Text("Worktree (carpeta propia)").tag(BranchMode.worktree)
                            Text("Carpeta principal (checkout)").tag(BranchMode.main)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        Text(modeDescription(project))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    Picker("Primera sesión", selection: $firstSession) {
                        Text("Ninguna").tag(SessionKind?.none)
                        ForEach(SessionKind.allCases) { kind in
                            Text(kind.label).tag(Optional(kind))
                        }
                    }
                }

                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Crear rama" : "Agregar rama") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || busy)
            }
            .padding([.horizontal, .bottom], 20)
            .padding(.top, 4)
        }
        .frame(width: 500)
        .task { await load() }
    }

    private var branchName: String {
        isNew ? name.trimmingCharacters(in: .whitespaces) : existing
    }

    private var inHive: Set<String> {
        Set(store.project(projectId)?.branches.map(\.name) ?? [])
    }

    private var availableExisting: [String] {
        localBranches.filter { !inHive.contains($0) }
    }

    /// Ramas remotas sin copia local, sin el prefijo del remoto (git las crea al hacer checkout).
    private var availableRemote: [String] {
        let local = Set(localBranches)
        var seen = Set<String>()
        return remoteBranches.compactMap { ref in
            guard let slash = ref.firstIndex(of: "/") else { return nil }
            let short = String(ref[ref.index(after: slash)...])
            guard !local.contains(short), !inHive.contains(short), seen.insert(short).inserted else { return nil }
            return short
        }
    }

    private var adoptedWorktree: GitWorktree? {
        guard !isNew, !existing.isEmpty else { return nil }
        return worktrees.first { $0.branch == existing }
    }

    private var canSubmit: Bool {
        !branchName.isEmpty && !(isNew && base.isEmpty)
    }

    private func modeDescription(_ project: Project?) -> String {
        switch mode {
        case .worktree:
            let path = project.map { GitParsing.worktreePath(for: branchName.isEmpty ? "rama" : branchName, projectPath: $0.path) } ?? ""
            return "Se crea en \(path). Varias sesiones pueden trabajar acá y en otras ramas al mismo tiempo sin pisarse."
        case .main:
            return "Usa la carpeta del proyecto. Para trabajar en esta rama Hive hace git checkout, y la carpeta principal solo tiene una rama activa a la vez."
        }
    }

    private func load() async {
        guard let project = store.project(projectId) else { return }
        let path = project.path
        let git = store.git
        let (local, remote, trees) = await Task.detached {
            (git.localBranches(path), git.remoteBranches(path), git.worktrees(path))
        }.value
        localBranches = local
        remoteBranches = remote
        worktrees = trees
        let head = store.mainHeads[projectId] ?? ""
        base = local.contains(head) ? head : (local.first ?? "")
        existing = availableExisting.first ?? availableRemote.first ?? ""
        loading = false
    }

    private func submit() {
        error = nil
        busy = true
        let request = NewBranchRequest(projectId: projectId, name: branchName, isNew: isNew, base: base,
                                       mode: mode, firstSession: firstSession)
        Task {
            let failure = await store.createBranch(request)
            busy = false
            if let failure { error = failure } else { dismiss() }
        }
    }
}
