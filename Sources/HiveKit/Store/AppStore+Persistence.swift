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
        case .empty:
            break
        case .corrupted(let backup):
            alert = AppAlert(title: "Tu estado anterior estaba dañado",
                             message: "Quedó una copia en \(backup.path). Hive arrancó de cero.",
                             actionTitle: "Mostrar en Finder", cancelTitle: "OK",
                             action: { NSWorkspace.shared.activateFileViewerSelecting([backup]) })
        case .unreadable(let reason):
            // Mejor no guardar nada que pisar un estado que quizás está bien.
            persistenceBlocked = true
            let file = stateStore.file
            alert = AppAlert(title: "No pude leer tu estado",
                             message: "\(reason)\n\nPara no pisarlo, Hive no va a guardar cambios hasta que lo vuelvas a abrir. El archivo es \(file.path).",
                             actionTitle: "Mostrar en Finder", cancelTitle: "OK",
                             action: { NSWorkspace.shared.activateFileViewerSelecting([file]) })
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
        guard !persistenceBlocked else { return }
        let state = HiveState(projects: projects, selection: selection, expanded: Array(expanded), lastSessions: lastSessionByProject,
                              mainHeads: mainHeads)
        do {
            try stateStore.save(state)
            saveFailed = false
        } catch {
            // Se avisa una vez; si vuelve a andar y después falla de nuevo, se avisa otra vez.
            guard !saveFailed else { return }
            saveFailed = true
            alert = AppAlert(title: "No pude guardar tu estado",
                             message: "\(error.localizedDescription)\n\nLo que cambies ahora se puede perder al cerrar Hive.")
        }
    }

    public func shutdown() {
        saveNow()
        for rt in runtimes.values { rt.terminal?.terminate() }
        for run in commandRuns where run.running { run.terminal?.terminate() }
        watcher?.stop()
        timers.forEach { $0.invalidate() }
    }
}
