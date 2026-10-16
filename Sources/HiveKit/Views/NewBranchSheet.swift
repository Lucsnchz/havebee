import HiveCore
import SwiftUI

struct NewBranchSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let projectId: UUID

    /// Lo último que elegiste (contratos de UserDefaults: newBranchMode y newBranchFirstSession).
    @AppStorage("newBranchMode") private var storedMode = BranchMode.worktree.rawValue
    /// rawValue de SessionKind, o "" para ninguna.
    @AppStorage("newBranchFirstSession") private var storedFirstSession = SessionKind.claude.rawValue
    @FocusState private var nameFocused: Bool

    @State private var isNew = true
    @State private var name = ""
    @State private var base = ""
    /// Cambiaste «Desde» a mano: el fetch en segundo plano ya no lo toca.
    @State private var baseTouched = false
    @State private var existing = ""
    @State private var localBranches: [String] = []
    @State private var remoteBranches: [String] = []
    @State private var worktrees: [GitWorktree] = []
    @State private var defaultRemote: String?
    @State private var loading = true
    @State private var fetching = false
    @State private var noCommits = false
    @State private var busy = false
    @State private var error: String?
    @State private var nameError: String?

    // Carpeta, Herd y preparación.
    @State private var herd: HerdSites?
    /// Herd sirve la carpeta padre del proyecto (se calcula al cargar, fuera del hilo principal).
    @State private var herdServesParent = false
    /// El sitio de la carpeta principal tiene HTTPS en Herd.
    @State private var mainHasCert = false
    /// Nombre y carpeta con los que se calcularon la validación, las rutas y el comando de preparación.
    @State private var derivedKey = ""
    @State private var location: WorktreeLocation = .nested
    @State private var locationTouched = false
    @State private var siblingPath = ""
    @State private var nestedPath = ""
    @State private var copyIgnored = true
    @State private var includeFiles: [String]?
    @State private var runSetup = true
    @State private var setupCommand = ""
    @State private var setupEdited = false
    @State private var setupOrigin: ProjectScripts.Origin?

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

                    if noCommits {
                        noCommitsRow
                    } else if isNew {
                        newBranchRows
                    } else {
                        existingBranchRows
                    }
                } header: {
                    Text("Nueva rama en \(project?.name ?? "")")
                }

                if !noCommits {
                    Section("Dónde trabajar") { whereRows(project) }
                    Section("Primera sesión") { firstSessionChips }
                }

                if let error {
                    Text(error)
                        .foregroundStyle(Theme.danger)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)

            HStack(spacing: 10) {
                if busy { ProgressView().controlSize(.small) }
                if !noCommits { preview(project) }
                Spacer(minLength: 8)
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
        .defaultFocus($nameFocused, true)
        .task { await load() }
        // Validación, carpeta y comando de preparación, con una pausa corta mientras escribís.
        .task(id: refreshKey) { await refreshDerived() }
        .onChange(of: name) { _, value in
            // Los espacios no van en un nombre de rama: pasan a guiones mientras escribís.
            if value.contains(" ") { name = value.replacingOccurrences(of: " ", with: "-") }
        }
        .onChange(of: isNew) { _, value in
            error = nil
            if value { nameFocused = true }
        }
    }

    // MARK: - Filas

    @ViewBuilder private var newBranchRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Nombre", text: $name, prompt: Text("ej. feature/checkout"))
                .focused($nameFocused)
            if let nameError {
                Text(nameError)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        Picker(selection: Binding(get: { base }, set: { base = $0; baseTouched = true })) {
            Section("Locales") {
                ForEach(localBranches, id: \.self) { Text($0).tag($0) }
            }
            if !remoteBranches.isEmpty {
                Section("Remotas") {
                    ForEach(remoteBranches, id: \.self) { Text($0).tag($0) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Desde")
                if fetching {
                    ProgressView().controlSize(.mini)
                        .help("Trayendo las ramas remotas…")
                }
            }
        }
    }

    @ViewBuilder private var existingBranchRows: some View {
        if availableExisting.isEmpty && availableRemote.isEmpty {
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
    }

    @ViewBuilder private var noCommitsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Este repo todavía no tiene commits", systemImage: "info.circle.fill")
                .foregroundStyle(Theme.info)
                .font(.callout.weight(.semibold))
            Text("Git necesita un primer commit para crear ramas. Podés crear uno vacío y seguir.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Crear primer commit") { createFirstCommit() }
                .disabled(busy)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func whereRows(_ project: Project?) -> some View {
        if let adopted = adoptedWorktree, let project {
            Label(samePath(adopted.path, project.path)
                  ? "Esta rama ya está en la carpeta principal."
                  : "Esta rama ya tiene un worktree en \((adopted.path as NSString).abbreviatingWithTildeInPath). Se usa ese.",
                  systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else {
            Picker("Modo", selection: Binding(get: { mode }, set: { storedMode = $0.rawValue })) {
                Text("Worktree (carpeta propia)").tag(BranchMode.worktree)
                Text("Carpeta principal (checkout)").tag(BranchMode.main)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if mode == .worktree {
                Picker("Carpeta", selection: Binding(get: { location }, set: { location = $0; locationTouched = true })) {
                    Text(siblingLabel).tag(WorktreeLocation.sibling)
                    Text("En \(nestedFolderName)").tag(WorktreeLocation.nested)
                }
                .pickerStyle(.radioGroup)
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Copiar .env, auth.json y permisos de Claude", isOn: $copyIgnored)
                    Text(includesCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Toggle("Preparar al crear", isOn: $runSetup)
                    TextField("Comando de preparación", text: Binding(get: { setupCommand }, set: { setupCommand = $0; setupEdited = true }),
                              prompt: Text("ej. composer install && npm install"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .disabled(!runSetup)
                        .padding(.leading, 20)
                    if let setupOrigin, !setupEdited {
                        Text(setupOrigin.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                }
            } else {
                Text("Usa la carpeta del proyecto. Para trabajar en esta rama Hive hace git switch, y la carpeta principal tiene una sola rama activa a la vez.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var firstSessionChips: some View {
        HStack(spacing: 8) {
            SessionChoiceChip(kind: nil, selected: firstSession == nil) { storedFirstSession = "" }
            ForEach(SessionKind.allCases) { kind in
                SessionChoiceChip(kind: kind, selected: firstSession == kind) { storedFirstSession = kind.rawValue }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Nombre final y carpeta, en gris, para ver qué se va a crear antes de crearlo.
    @ViewBuilder private func preview(_ project: Project?) -> some View {
        if !branchName.isEmpty, project != nil {
            let place: String = {
                if adoptedWorktree != nil { return "" }
                if mode == .main { return " · carpeta principal" }
                let path = location == .sibling ? siblingPath : nestedPath
                return path.isEmpty ? "" : " · " + (path as NSString).abbreviatingWithTildeInPath
            }()
            Text("\(branchName)\(place)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("\(branchName)\(place)")
        }
    }

    // MARK: - Datos derivados

    private var mode: BranchMode { BranchMode(rawValue: storedMode) ?? .worktree }

    private var firstSession: SessionKind? { SessionKind(rawValue: storedFirstSession) }

    private var branchName: String {
        isNew ? name.trimmingCharacters(in: .whitespaces) : existingShortName
    }

    /// Si elegiste una remota ("upstream/docs"), el nombre de la rama local ("docs").
    private var existingShortName: String {
        guard remoteBranches.contains(existing), let slash = existing.firstIndex(of: "/") else { return existing }
        return String(existing[existing.index(after: slash)...])
    }

    private var inHive: Set<String> {
        Set(store.project(projectId)?.branches.map(\.name) ?? [])
    }

    private var availableExisting: [String] {
        localBranches.filter { !inHive.contains($0) }
    }

    /// Ramas remotas sin copia local, con su remoto: con dos remotos se ven las dos y se usa la elegida.
    private var availableRemote: [String] {
        let local = Set(localBranches)
        return remoteBranches.filter { ref in
            guard let slash = ref.firstIndex(of: "/") else { return false }
            let short = String(ref[ref.index(after: slash)...])
            return !local.contains(short) && !inHive.contains(short)
        }
    }

    private var adoptedWorktree: GitWorktree? {
        guard !isNew, !existing.isEmpty, !remoteBranches.contains(existing) else { return nil }
        return worktrees.first { $0.branch == existing && !$0.isPrunable }
    }

    private var canSubmit: Bool {
        !noCommits && !branchName.isEmpty && !(isNew && base.isEmpty) && !(isNew && nameError != nil)
    }

    private var refreshKey: String {
        "\(isNew)|\(name)|\(existing)|\(storedMode)|\(location.rawValue)|\(runSetup)|\(herd != nil)"
    }

    /// Lo que cambia la validación, las rutas y el comando de preparación.
    private var derivationKey: String { "\(isNew)|\(branchName)|\(location.rawValue)" }

    /// «ecommerce.worktrees», la carpeta de los worktrees anidados.
    private var nestedFolderName: String {
        let path = nestedPath.isEmpty ? store.project(projectId)?.path ?? "" : (nestedPath as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".worktrees") ? name : name + ".worktrees"
    }

    /// URL con la que Herd va a servir el worktree hermano. https solo si la preparación corre `herd secure`.
    private var siblingURL: String? {
        guard herdServesParent, let herd, !siblingPath.isEmpty else { return nil }
        let host = herd.host(forFolder: (siblingPath as NSString).lastPathComponent)
        let secure = mainHasCert && runSetup && setupCommand.contains("herd secure")
        return "\(secure ? "https" : "http")://\(host)"
    }

    private var siblingLabel: String {
        if let siblingURL { return "Junto al proyecto (Herd la sirve en \(siblingURL))" }
        return "Junto al proyecto"
    }

    private var includesCaption: String {
        guard let includeFiles else { return "Buscando archivos ignorados…" }
        if includeFiles.isEmpty { return "No hay archivos ignorados para copiar." }
        let found = WorktreeIncludes.summary(includeFiles, shown: 3)
        return copyIgnored ? "Se copian: " + found : "No se copian (encontré " + found + ")."
    }

    // MARK: - Carga

    private func load() async {
        guard let project = store.project(projectId) else { return }
        let path = project.path
        let git = store.git
        let home = store.environment.home
        let loaded = await Task.detached(priority: .userInitiated) {
            let herd = HerdSites.parse(configRoot: HerdSites.defaultRoot(home: home))
            return (local: git.localBranches(path), remote: git.remoteBranches(path), trees: git.worktrees(path),
                    defaultRemote: git.defaultRemoteBranch(path), unborn: git.status(path)?.isUnborn == true, herd: herd,
                    servesParent: herd?.servesParent(of: path) == true,
                    mainHasCert: herd?.url(for: path)?.hasPrefix("https://") == true)
        }.value
        localBranches = loaded.local
        remoteBranches = loaded.remote
        worktrees = loaded.trees
        defaultRemote = loaded.defaultRemote
        noCommits = loaded.unborn
        herd = loaded.herd
        herdServesParent = loaded.servesParent
        mainHasCert = loaded.mainHasCert
        if !locationTouched, loaded.servesParent { location = .sibling }
        base = defaultBase
        existing = availableExisting.first ?? availableRemote.first ?? ""
        loading = false
        nameFocused = isNew

        // Archivos a copiar y fetch, en segundo plano: la hoja ya se puede usar.
        Task {
            includeFiles = await Task.detached(priority: .utility) { WorktreeIncludes.files(in: path, git: git) }.value
        }
        guard !loaded.unborn else { return }
        fetching = true
        let fetched = await Task.detached(priority: .utility) { () -> (remote: [String], defaultRemote: String?)? in
            guard git.fetch(path, timeout: 10).ok else { return nil }
            return (git.remoteBranches(path), git.defaultRemoteBranch(path))
        }.value
        fetching = false
        if let fetched {
            remoteBranches = fetched.remote
            defaultRemote = fetched.defaultRemote
            if !baseTouched { base = defaultBase }
            if existing.isEmpty { existing = availableExisting.first ?? availableRemote.first ?? "" }
        }
    }

    /// origin/<rama por defecto> si existe; si no, la rama de la carpeta principal.
    private var defaultBase: String {
        if let defaultRemote, remoteBranches.contains(defaultRemote) { return defaultRemote }
        let head = store.mainHeads[projectId] ?? ""
        return localBranches.contains(head) ? head : (localBranches.first ?? "")
    }

    /// Valida el nombre y calcula las carpetas y el comando de preparación (fuera del hilo principal).
    private func refreshDerived(debounce: Bool = true) async {
        if debounce { try? await Task.sleep(nanoseconds: 250_000_000) }
        guard !Task.isCancelled, let project = store.project(projectId) else { return }
        let key = derivationKey
        let candidate = branchName
        let git = store.git
        let projectPath = project.path
        let localSet = Set(localBranches)
        let hive = inHive
        let checkName = isNew && !candidate.isEmpty
        let currentLocation = location
        let hasCert = ProjectScripts.securesWorktree(location: currentLocation, herdServesParent: herdServesParent, mainHasCert: mainHasCert)
        let derived = await Task.detached(priority: .userInitiated) { () -> (error: String?, sibling: String, nested: String, setup: ProjectScripts.Script?) in
            var error: String?
            if checkName {
                if hive.contains(candidate) {
                    error = BranchError.alreadyInHive(candidate).errorDescription
                } else if localSet.contains(candidate) {
                    error = BranchError.alreadyExists(candidate).errorDescription
                } else if !git.isValidBranchName(candidate, in: projectPath) {
                    error = BranchError.invalidName(candidate).errorDescription
                }
            }
            let forPath = candidate.isEmpty ? "rama" : candidate
            let sibling = GitParsing.worktreePath(for: forPath, projectPath: projectPath, style: .sibling)
            let nested = GitParsing.worktreePath(for: forPath, projectPath: projectPath, style: .nested)
            let folder = ((currentLocation == .sibling ? sibling : nested) as NSString).lastPathComponent
            let setup = ProjectScripts.resolve(projectPath: projectPath, folder: folder, mainHasCert: hasCert).setup
            return (error, sibling, nested, setup)
        }.value
        guard !Task.isCancelled else { return }
        nameError = derived.error
        siblingPath = derived.sibling
        nestedPath = derived.nested
        if !setupEdited {
            setupCommand = derived.setup?.command ?? ""
            setupOrigin = derived.setup?.origin
        }
        derivedKey = key
    }

    // MARK: - Acciones

    private func submit() {
        guard canSubmit, !busy else { return }
        error = nil
        busy = true
        Task {
            // Enter apenas después de escribir: la carpeta, APP_URL y el `herd secure <carpeta>` todavía
            // eran los del nombre anterior. Se recalculan con el nombre final antes de crear nada.
            if derivedKey != derivationKey {
                await refreshDerived(debounce: false)
                if isNew && nameError != nil {
                    busy = false
                    return
                }
            }
            let remoteRef = !isNew && remoteBranches.contains(existing) ? existing : nil
            let setup = setupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            let worktree = mode == .worktree && adoptedWorktree == nil
            let request = NewBranchRequest(
                projectId: projectId, name: branchName, isNew: isNew, base: base, mode: mode, firstSession: firstSession,
                remoteRef: remoteRef, location: location, copyIgnored: worktree && copyIgnored,
                envAppURL: worktree && location == .sibling ? siblingURL : nil,
                setupCommand: worktree && runSetup && !setup.isEmpty ? setup : nil)
            let failure = await store.createBranch(request)
            busy = false
            if let failure { error = failure } else { dismiss() }
        }
    }

    private func createFirstCommit() {
        guard let project = store.project(projectId) else { return }
        let git = store.git
        let path = project.path
        busy = true
        error = nil
        Task {
            let r = await Task.detached { git.commitAllowEmpty(message: "Primer commit", in: path) }.value
            busy = false
            if r.ok {
                store.refreshGit()
                await load()
            } else {
                error = r.errorMessage
            }
        }
    }
}

/// Chip para elegir la primera sesión, con el logo original del agente.
private struct SessionChoiceChip: View {
    let kind: SessionKind?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let kind {
                    AgentLogo(kind: kind, size: 14)
                } else {
                    Image(systemName: "nosign")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                }
                Text(kind?.defaultName ?? "Ninguna")
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(selected ? Theme.accentFill.opacity(0.25) : Color.primary.opacity(hovering ? 0.08 : 0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Theme.accent.opacity(0.8) : Color.primary.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(kind.map { "Abrir una sesión de \($0.label) al crear la rama" } ?? "Sin sesión: solo crear la rama")
    }
}
