import AppKit
import HiveCore
import SwiftUI

/// Panel lateral con todo lo que se habló en la sesión, también lo anterior a cada /clear.
/// «Todo» muestra la conversación completa (la copia de Hive de los transcripts más el transcript
/// vivo); «Solo respuestas finales», lo que avisaron los hooks: tu pedido y la respuesta de cada turno.
struct HistoryPanel: View {
    @Environment(AppStore.self) private var store
    let session: Session
    /// Dentro de «Buscar en todas las sesiones» (leyendo una archivada) no se ofrece abrir otra búsqueda
    /// encima: al elegir un resultado se cerraría solo la de adentro y la de afuera taparía la sesión.
    var showsGlobalSearch = true
    @AppStorage("historyShowEverything") private var showEverything = true
    @State private var everything: [HistoryEntry] = []
    @State private var finals: [HistoryEntry] = []
    @State private var loaded = false
    @State private var query = ""
    @State private var matchIndex = 0
    @State private var showGlobalSearch = false
    @State private var note: String?
    @State private var scrollTarget: UUID?
    /// Entrada a la que hay que saltar cuando se aplique la búsqueda (viene de «Buscar en todas las sesiones»).
    @State private var jumpTarget: UUID?
    @FocusState private var searchFocused: Bool

    private var reportsConversation: Bool { session.kind.reportsConversation }
    private var entries: [HistoryEntry] { showEverything && reportsConversation ? everything : finals }
    private var matches: [UUID] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return entries.filter { $0.role != .marker && HistoryExport.matches($0.text, query: q) }.map(\.id)
    }
    private var currentMatch: UUID? { matches.isEmpty ? nil : matches[min(matchIndex, matches.count - 1)] }

    var body: some View {
        let shown = entries
        let found = matches
        VStack(spacing: 0) {
            header(shown)
            if reportsConversation && (!shown.isEmpty || !query.isEmpty) {
                controls(found)
            }
            Divider()
            if shown.isEmpty {
                emptyState
            } else {
                timeline(shown, found: found)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: reloadKey) { await keepLoaded() }
        .onChange(of: query) { focusMatch() }
        .onChange(of: HistoryJumpRequest.shared.pending?.entryId) { applyJumpIfNeeded() }
        .sheet(isPresented: $showGlobalSearch) {
            HistorySearchView(initialQuery: query).environment(store)
        }
    }

    // MARK: - Partes

    private func header(_ shown: [HistoryEntry]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text("Historial")
                .font(.system(size: 13, weight: .semibold))
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Spacer()
            if showsGlobalSearch {
                HistoryIconButton(symbol: "text.magnifyingglass", label: "Buscar en todas las sesiones") {
                    showGlobalSearch = true
                }
            }
            HistoryIconButton(symbol: "doc.on.doc", label: "Copiar todo el historial") {
                ExternalApps.copyToPasteboard(HistoryExport.plainText(shown, agent: session.kind.label))
                flash("Copiado")
            }
            .disabled(shown.isEmpty)
            HistoryIconButton(symbol: "arrow.up.forward.square", label: "Abrir el archivo (es el mismo que puede leer la IA)") {
                NSWorkspace.shared.open(store.history.markdownURL(session.id))
            }
            .disabled(shown.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func controls(_ found: [UUID]) -> some View {
        VStack(spacing: 8) {
            Picker("Qué mostrar", selection: $showEverything) {
                Text("Todo").tag(true)
                Text("Solo respuestas finales").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("«Todo» incluye lo que la IA fue contando mientras trabajaba; «Solo respuestas finales», tu pedido y la respuesta de cada turno.")

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("Buscar en el historial", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($searchFocused)
                    .onSubmit { step(+1) }
                    .onExitCommand { query = "" }
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(found.isEmpty ? "Sin resultados" : "\(min(matchIndex, found.count - 1) + 1) de \(found.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    HistoryIconButton(symbol: "chevron.up", label: "Coincidencia anterior", size: 10) { step(-1) }
                        .disabled(found.isEmpty)
                    HistoryIconButton(symbol: "chevron.down", label: "Coincidencia siguiente", size: 10) { step(+1) }
                        .disabled(found.isEmpty)
                    HistoryIconButton(symbol: "xmark.circle.fill", label: "Borrar la búsqueda", size: 11) { query = "" }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func timeline(_ shown: [HistoryEntry], found: [UUID]) -> some View {
        let items = HistoryTimelineItem.build(shown)
        let matchSet = Set(found)
        // Una sola vez: `currentMatch` vuelve a buscar en todas las entradas y acá se usa en cada fila.
        let current = found.isEmpty ? nil : found[min(matchIndex, found.count - 1)]
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { item in
                        switch item {
                        case .day(let label, _):
                            HistoryDaySeparator(label: label)
                        case .entry(let entry):
                            HistoryRow(entry: entry, agent: session.kind, query: matchSet.contains(entry.id) ? query : "",
                                       isCurrentMatch: entry.id == current)
                                .id(entry.id)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
            .onAppear { if query.isEmpty, let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            .onChange(of: shown.last?.id) { if query.isEmpty, let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            .onChange(of: scrollTarget) {
                guard let target = scrollTarget else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 12) {
            if !loaded && reportsConversation {
                ProgressView().controlSize(.small)
            } else {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !reportsConversation {
                    let terminal = store.runtimes[session.id]?.terminal
                    Button {
                        guard let text = terminal?.fullText() else { return }
                        ExternalApps.copyToPasteboard(text)
                        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
                        flash(lines == 1 ? "Copiado (1 línea)" : "Copiado (\(lines) líneas)")
                    } label: {
                        Label("Copiar el scroll de la terminal", systemImage: "doc.on.doc")
                    }
                    .disabled(terminal == nil)
                    .help(terminal == nil ? "La terminal no está abierta" : "Copia todo el texto de la terminal, con el scroll incluido")
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyText: String {
        switch session.kind {
        case .claude, .codex:
            "Todavía no hay mensajes. Lo que hables con \(session.kind.label) se guarda acá, también lo anterior a cada /clear."
        case .gemini:
            "Gemini no avisa sus mensajes a Hive, así que no hay historial acá. Todo queda en el scroll de la terminal."
        case .shell:
            "Las terminales no tienen historial de chat. Todo queda en el scroll de la terminal."
        }
    }

    // MARK: - Carga

    private var reloadKey: String {
        "\(session.id)-\(store.historyVersions[session.id] ?? 0)-\(session.agentSessionId ?? "")"
    }

    /// Carga en segundo plano y, mientras el agente trabaja, vuelve a leer su transcript cada tanto
    /// (la caché por fecha de modificación hace que no cueste nada si no cambió).
    private func keepLoaded() async {
        await reload()
        applyJumpIfNeeded()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            if store.runtimes[session.id]?.status == .working { await reload() }
        }
    }

    private func reload() async {
        let id = session.id
        let kind = session.kind
        let agentId = session.agentSessionId
        let history = store.history
        let agents = store.environment.agents
        let result = await Task.detached(priority: .userInitiated) { () -> (finals: [HistoryEntry], everything: [HistoryEntry]) in
            let log = history.load(id)
            guard kind.reportsConversation else { return (log, log) }
            var live = history.transcriptSegments(id).map { URL(fileURLWithPath: $0.path) }
            if let agentId, let current = kind == .claude ? agents.claudeTranscriptURL(agentId) : agents.codexRolloutURL(agentId),
               !live.contains(where: { $0.standardizedFileURL == current.standardizedFileURL }) {
                live.append(current)
            }
            live = live.filter { FileManager.default.fileExists(atPath: $0.path) }
            return (log, history.fullTimeline(id, agent: kind, live: live))
        }.value
        guard !Task.isCancelled else { return }
        if finals != result.finals { finals = result.finals }
        if everything != result.everything { everything = result.everything }
        loaded = true
    }

    // MARK: - Búsqueda

    private func step(_ delta: Int) {
        let count = matches.count
        guard count > 0 else { return }
        matchIndex = (min(matchIndex, count - 1) + delta + count) % count
        scrollToMatch()
    }

    private func scrollToMatch() {
        scrollTarget = currentMatch
    }

    /// Con una búsqueda nueva va a la primera coincidencia (o a la entrada pedida, si viene de un salto).
    private func focusMatch() {
        let found = matches
        if let target = jumpTarget {
            jumpTarget = nil
            // En «Todo», el mensaje del registro puede verse como su copia del transcript (otro ID).
            let foundSet = Set(found)
            let candidates = entries.filter { foundSet.contains($0.id) }
            let original = finals.first { $0.id == target } ?? everything.first { $0.id == target }
            if let resolved = original.flatMap({ HistoryExport.counterpart(of: $0, in: candidates) }),
               let index = found.firstIndex(of: resolved) {
                matchIndex = index
                scrollTarget = resolved
                return
            }
        }
        matchIndex = 0
        scrollToMatch()
    }

    /// Si se llegó desde «Buscar en todas las sesiones», muestra la búsqueda y salta a esa entrada.
    private func applyJumpIfNeeded() {
        guard let jump = HistoryJumpRequest.shared.pending, jump.sessionId == session.id, loaded else { return }
        HistoryJumpRequest.shared.pending = nil
        if reportsConversation && !finals.contains(where: { $0.id == jump.entryId }) { showEverything = true }
        jumpTarget = jump.entryId
        if query == jump.query { focusMatch() } else { query = jump.query }
    }

    private func flash(_ text: String) {
        withAnimation { note = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation { if note == text { note = nil } }
        }
    }
}

/// Un elemento de la línea de tiempo: un separador de día o una entrada.
enum HistoryTimelineItem: Identifiable {
    case day(String, Date)
    case entry(HistoryEntry)

    var id: String {
        switch self {
        case .day(let label, let date): "day-\(label)-\(date.timeIntervalSince1970)"
        case .entry(let entry): entry.id.uuidString
        }
    }

    static func build(_ entries: [HistoryEntry], now: Date = Date(), calendar: Calendar = .current) -> [HistoryTimelineItem] {
        var items: [HistoryTimelineItem] = []
        var lastDay: Date?
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            if day != lastDay {
                items.append(.day(HistoryExport.dayLabel(entry.date, now: now, calendar: calendar), day))
                lastDay = day
            }
            items.append(.entry(entry))
        }
        return items
    }
}

private struct HistoryDaySeparator: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
        .padding(.top, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Botón chico con un símbolo, siempre con su etiqueta para VoiceOver y su ayuda.
struct HistoryIconButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 12
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let agent: SessionKind
    /// La búsqueda, si esta entrada coincide (para resaltarla).
    let query: String
    let isCurrentMatch: Bool

    var body: some View {
        Group {
            switch entry.role {
            case .marker: marker
            case .system: system
            case .user: user
            case .assistant: assistant
            }
        }
        .overlay {
            if isCurrentMatch {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
                    .padding(-4)
            }
        }
    }

    private var time: String { entry.date.formatted(date: .omitted, time: .shortened) }

    private var marker: some View {
        let failed = entry.text.hasPrefix(AgentEventInterpreter.stopFailureMarker)
        return HStack(spacing: 8) {
            Rectangle().fill((failed ? Theme.attention : Color.primary).opacity(0.2)).frame(height: 1)
            Text("\(entry.text) · \(time)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(failed ? AnyShapeStyle(Theme.attention) : AnyShapeStyle(.secondary))
                .fixedSize()
            Rectangle().fill((failed ? Theme.attention : Color.primary).opacity(0.2)).frame(height: 1)
        }
        .padding(.vertical, 4)
        .help(HistoryStore.markerMeaning(entry.text))
        .accessibilityElement(children: .combine)
    }

    private var system: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .font(.system(size: 10))
                Text("Aviso automático")
                    .font(.system(size: 11, weight: .semibold))
                Text(time)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                HistoryCopyButton(text: entry.text)
            }
            .foregroundStyle(.secondary)
            Text(highlighted(HistoryRow.withoutTags(entry.text)))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var user: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Vos")
                    .font(.system(size: 11, weight: .semibold))
                Text(time)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                HistoryCopyButton(text: entry.text)
            }
            .foregroundStyle(.secondary)
            Text(highlighted(entry.text))
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accentFill.opacity(0.16)))
        .padding(.leading, 24)
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AgentLogo(kind: agent, size: 14)
                Text(agent.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(time)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                HistoryCopyButton(text: entry.text)
            }
            ForEach(Array(HistoryExport.blocks(entry.text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let text):
                    Text(HistoryMarkdown.attributed(text, highlight: query))
                        .font(.system(size: 12.5))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let language, let code):
                    HistoryCodeBlock(language: language, code: code)
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        HistoryMarkdown.highlight(&result, query: query)
        return result
    }

    /// Los avisos automáticos vienen envueltos en etiquetas (<task-notification>…): se leen mejor sin ellas.
    static func withoutTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>\n]{1,60}>", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Copiar, siempre visible (tenue hasta que pasás el mouse) y con un tilde al copiar.
private struct HistoryCopyButton: View {
    let text: String
    var label = "Copiar"
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button {
            ExternalApps.copyToPasteboard(text)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .opacity(hovering || copied ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(copied ? "Copiado" : label)
        .accessibilityLabel(label)
    }
}

/// Un bloque ``` aparte, en monoespaciada, con su propio botón de copiar.
private struct HistoryCodeBlock: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language ?? "código")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                HistoryCopyButton(text: code, label: "Copiar el código")
            }
            .padding(.horizontal, 10)
            .padding(.top, 5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                    .padding(.bottom, 9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

/// Markdown en línea (negrita, cursiva, `código`, links) más títulos y viñetas línea por línea.
enum HistoryMarkdown {
    static func attributed(_ prose: String, highlight query: String = "") -> AttributedString {
        var result = AttributedString()
        let lines = prose.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var piece: AttributedString
            if let heading = heading(trimmed) {
                piece = inline(heading)
                piece.font = .system(size: 13, weight: .semibold)
            } else if let item = bullet(line) {
                piece = AttributedString(item.indent + "•  ") + inline(item.text)
            } else if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) && trimmed.count >= 3 {
                piece = AttributedString("———")
                piece.foregroundColor = .secondary
            } else {
                piece = inline(line)
            }
            result += piece
            if index < lines.count - 1 { result += AttributedString("\n") }
        }
        highlight(&result, query: query)
        return result
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static func heading(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count), line.dropFirst(hashes.count).first == " " else { return nil }
        return String(line.dropFirst(hashes.count + 1))
    }

    static func bullet(_ line: String) -> (indent: String, text: String)? {
        let indent = line.prefix { $0 == " " }
        let rest = line.dropFirst(indent.count)
        guard rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") else { return nil }
        return (String(indent), String(rest.dropFirst(2)))
    }

    /// Pinta de miel las coincidencias de la búsqueda (sin distinguir tildes ni mayúsculas).
    static func highlight(_ text: inout AttributedString, query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let plain = String(text.characters)
        var searchStart = plain.startIndex
        while searchStart < plain.endIndex,
              let found = plain.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<plain.endIndex) {
            let lower = plain.distance(from: plain.startIndex, to: found.lowerBound)
            let length = plain.distance(from: found.lowerBound, to: found.upperBound)
            let start = text.characters.index(text.startIndex, offsetBy: lower)
            let end = text.characters.index(start, offsetBy: length)
            text[start..<end].backgroundColor = Theme.accentFill.opacity(0.4)
            searchStart = found.upperBound
        }
    }
}
