import Foundation

/// Dibuja el historial recuperado como mensajes, manteniendo el scroll de la terminal.
/// Solo emite nuestros estilos SGR y enlaces OSC 8; el texto original nunca aporta escapes.
public enum ConversationTerminalRenderer {
    public struct Output: Sendable {
        public let ansi: String
        public let lineCount: Int
    }

    private static let reset = "\u{1B}[0m"
    private static let blue = "\u{1B}[34m"
    // ANSI 7 tiene contraste legible en ambas paletas de Hive; el gris brillante queda muy
    // oscuro sobre el fondo oscuro para fechas, cambios de IA y etiquetas de código.
    private static let muted = "\u{1B}[37m"

    public static func render(_ entries: [HistoryEntry], agent: SessionKind, columns: Int) -> Output {
        let width = max(12, min(columns - 8, 92))
        let rule = String(repeating: "─", count: width)
        var lines: [String] = []
        var titleReply = false
        for entry in entries {
            // Los prompts auxiliares de titulación de Codex no forman parte de la charla.
            // Se omiten solo de la presentación: los archivos originales permanecen intactos.
            if entry.role == .user, CodexTitleGeneration.isRequest(entry.text) { titleReply = true; continue }
            if titleReply, entry.role == .assistant {
                titleReply = false
                if let object = JSONValue.parse(entry.text)?.object, object.count == 1, object["title"]?.string != nil { continue }
            } else {
                titleReply = false
            }
            let time = entry.date.formatted(date: .omitted, time: .shortened)
            if entry.role == .marker {
                let label = HistoryStore.markerTitle(entry.text)
                lines += ["", "  \(muted)── \(ConversationScrollback.displayText(label.title)) · \(time) ──\(reset)", ""]
                continue
            }
            let user = entry.role == .user
            let automatic = entry.role == .system
            let name = user ? "Vos" : (automatic ? "Aviso automático" : (entry.agent ?? agent).label)
            let color = user ? blue : (automatic ? muted : "\u{1B}[35m")
            let prefix = user ? "  \(blue)│\(reset)  " : "    "
            lines.append("")
            lines.append(user
                         ? "  \(blue)╭─ \u{1B}[1m\(name)\(reset)  \(muted)\(time)\(reset)"
                         : "  \(color)● \u{1B}[1m\(name)\(reset)  \(muted)\(time)\(reset)")
            lines.append(user ? "  \(blue)│\(reset)" : "")
            for block in HistoryExport.blocks(displayMessage(entry.text, role: entry.role)) {
                switch block {
                case .prose(let prose):
                    for line in prose.components(separatedBy: "\n") {
                        let content = proseLine(line)
                        for row in wrap(content, columns: width) { lines.append(prefix + row) }
                    }
                case .code(let language, let code):
                    lines.append(prefix + "\(muted)┌ \(ConversationScrollback.displayText(language ?? "código"))\(reset)")
                    for line in code.components(separatedBy: "\n") {
                        // En código no se interpreta Markdown: *, _, etiquetas y backticks son literales.
                        for row in wrap(AttributedString(line), columns: max(4, width - 2)) {
                            lines.append(prefix + "\(muted)│\(reset) " + row)
                        }
                    }
                    lines.append(prefix + "\(muted)└\(String(repeating: "─", count: min(width - 1, 32)))\(reset)")
                }
            }
            if user { lines.append("  \(blue)╰\(rule)\(reset)") }
            lines.append("")
        }
        return Output(ansi: lines.joined(separator: "\n"), lineCount: lines.count)
    }

    /// Limpia solo envoltorios conocidos de los agentes; no elimina HTML o XML escritos como código.
    static func displayMessage(_ text: String, role: HistoryEntry.Role) -> String {
        var text = ConversationScrollback.displayText(text)
        if role == .user {
            text = text.replacingOccurrences(of: #"(?s)<image\b[^>]*\bpath=[^>]*>\s*</image>\s*(?:\[Image #\d+\])?"#,
                                             with: "Imagen adjunta", options: .regularExpression)
                .replacingOccurrences(of: #"\[Image #\d+\]"#, with: "Imagen adjunta", options: .regularExpression)
        }
        if role == .system {
            text = text.replacingOccurrences(of: #"</?(?:task-notification|task-id|tool-use-id|output-file|status|summary)>"#,
                                             with: " ", options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func proseLine(_ line: String) -> AttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }
        let heading = (1...6).contains(hashes.count) && trimmed.dropFirst(hashes.count).first == " "
        var source = heading ? String(trimmed.dropFirst(hashes.count + 1)) : line
        if !heading {
            source = source.replacingOccurrences(of: #"^([ \t]*)[-*+] \[x\] "#, with: "$1☑ ", options: .regularExpression)
                .replacingOccurrences(of: #"^([ \t]*)[-*+] \[ \] "#, with: "$1☐ ", options: .regularExpression)
                .replacingOccurrences(of: #"^([ \t]*)[-*+] "#, with: "$1• ", options: .regularExpression)
                .replacingOccurrences(of: #"^([ \t]*)> ?"#, with: "$1│ ", options: .regularExpression)
            if trimmed.count >= 3 && trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) { source = "────────────" }
        }
        var result = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
        if heading {
            for run in result.runs {
                result[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
            }
        }
        return result
    }

    private struct Cell {
        let character: Character
        let style: String
        let link: String?
        // Conservador para Unicode: nunca corta un grafema ni deja que el texto pise el margen.
        var width: Int { character.isASCII ? 1 : min(2, character.utf8.count) }
    }

    /// Envuelve antes de agregar ANSI para que el formato no cuente como ancho ni aparezca escrito.
    private static func wrap(_ text: AttributedString, columns: Int) -> [String] {
        var cells: [Cell] = []
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var codes: [String] = []
            if intent.contains(.stronglyEmphasized) { codes.append("1") }
            if intent.contains(.emphasized) { codes.append("3") }
            if intent.contains(.strikethrough) { codes.append("9") }
            if intent.contains(.code) { codes.append("36") }
            if run.link != nil { codes += ["4", "34"] }
            let style = codes.isEmpty ? "" : "\u{1B}[" + codes.joined(separator: ";") + "m"
            let link = run.link.map { ConversationScrollback.displayText($0.absoluteString) }
            for character in text[run.range].characters { cells.append(Cell(character: character, style: style, link: link)) }
        }
        guard !cells.isEmpty else { return [""] }
        var rows: [String] = []
        var start = 0
        while start < cells.count {
            var end = start
            var width = 0
            var space: Int?
            while end < cells.count && width + cells[end].width <= columns {
                width += cells[end].width
                if cells[end].character == " " { space = end }
                end += 1
            }
            if end < cells.count, let space, space > start { end = space }
            end = max(start + 1, end)
            rows.append(ansi(cells[start..<end]))
            start = end
            // El espacio por el que cortamos no se imprime al comienzo de la continuación.
            if start < cells.count && cells[start].character == " " { start += 1 }
        }
        return rows
    }

    private static func ansi(_ cells: ArraySlice<Cell>) -> String {
        var result = ""
        var style = ""
        var link: String?
        for cell in cells {
            if cell.link != link {
                if link != nil { result += "\u{1B}]8;;\u{1B}\\" }
                if let target = cell.link { result += "\u{1B}]8;;\(target)\u{1B}\\" }
                link = cell.link
            }
            if cell.style != style {
                result += reset + cell.style
                style = cell.style
            }
            result.append(cell.character)
        }
        if link != nil { result += "\u{1B}]8;;\u{1B}\\" }
        if !style.isEmpty { result += reset }
        return result
    }
}
