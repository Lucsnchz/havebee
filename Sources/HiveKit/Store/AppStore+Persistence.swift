import AppKit
import HiveCore

/// Cargar y guardar el estado, y cerrar todo al salir.
extension AppStore {
    // MARK: - Persistencia

    func load() {
        switch stateStore.load(now: environment.now()) {
        case .loaded(let state):
            projects = state.projects
            selection = state.selection
            lastSessionByProject = state.lastSessions ?? [:]
            expanded = Set(state.expanded)
            // La rama de cada carpeta principal se guarda para no leer git al arrancar; la primera
            // revisión de `start()` la corrige si cambió.
            mainHeads = state.mainHeads ?? [:]
        case .empty, .corrupted:
            break
        }
        for i in projects.indices {
            var project = projects[i]
            AppearanceDefaults.apply(to: &project, others: projects, logos: environment.logos)
            projects[i] = project
        }
        projects.ensureScratch(home: environment.home.path)
        mainHeads = mainHeads.filter { id, _ in projects.contains { $0.id == id && !$0.isScratch } }
        for p in projects {
            for s in p.allSessions { runtimes[s.id] = SessionRuntime(sessionId: s.id, kind: s.kind) }
        }
    }

    func scheduleSave() {
        saveWork?.cancel()
        guard environment.saveDelay > 0 else {
            saveNow()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + environment.saveDelay, execute: work)
    }

    public func saveNow() {
        saveWork?.cancel()
        let state = HiveState(projects: projects, selection: selection, expanded: Array(expanded), lastSessions: lastSessionByProject,
                              mainHeads: mainHeads)
        try? stateStore.save(state)
    }

    public func shutdown() {
        saveNow()
        for rt in runtimes.values { rt.terminal?.terminate() }
        for run in commandRuns where run.running { run.terminal?.terminate() }
        watcher?.stop()
        timers.forEach { $0.invalidate() }
    }
}
