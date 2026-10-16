import Foundation
import Testing
@testable import HiveCore

@Suite("Uso de contexto y límites")
struct UsageReaderTests {
    /// Lo que Claude Code 2.1.x le pasa a su statusLine (recortado).
    static let claudeStatus = #"{"hook_event_name":"Status","session_id":"c-1","transcript_path":"/c/c-1.jsonl","cwd":"/code/ecommerce","model":{"id":"claude-opus-4-1","display_name":"Opus"},"workspace":{"current_dir":"/code/ecommerce","project_dir":"/code/ecommerce"},"version":"2.1.30","cost":{"total_cost_usd":1.23,"total_duration_ms":45000},"context_window":{"total_input_tokens":15234,"total_output_tokens":4521,"context_window_size":200000,"used_percentage":72.4,"remaining_percentage":27.6,"current_usage":{"input_tokens":8500,"output_tokens":1200,"cache_creation_input_tokens":5000,"cache_read_input_tokens":2000}},"exceeds_200k_tokens":false,"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1790003600},"seven_day":{"used_percentage":41.2,"resets_at":1790500000}}}"#

    @Test("Codex: contexto del último token_count y límites con su reinicio")
    func codex() throws {
        let snapshot = try #require(UsageReader.codexSnapshot(fromLines: AHFixtures.codexRollout, fallbackDate: .reference))
        #expect(snapshot.agent == .codex)
        let context = try #require(snapshot.contextPercent)
        #expect(abs(context - 49_700.0 / 258_400.0 * 100) < 0.001)
        #expect(snapshot.limits == [UsageLimit(windowMinutes: 10080, usedPercent: 80, resetsAt: Date(timeIntervalSince1970: 1_792_512_104))])
        #expect(snapshot.limits.first?.label == "sem")
        #expect(snapshot.updatedAt == AgentTimestamp.parse("2026-10-12T13:00:21.000Z"))
        #expect(UsageReader.codexSnapshot(fromLines: "{\"type\":\"event_msg\"}", fallbackDate: .reference) == nil)
    }

    @Test("Codex: formato viejo con resets_in_seconds y el último dato de cada cosa")
    func codexOlderFormat() throws {
        let lines = """
        {"timestamp":"2026-10-12T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1000},"model_context_window":100000},"rate_limits":null}}
        {"timestamp":"2026-10-12T10:05:00Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300,"resets_in_seconds":3600},"secondary":{"used_percent":30,"window_minutes":10080,"resets_in_seconds":86400}}}}
        """
        let snapshot = try #require(UsageReader.codexSnapshot(fromLines: lines, fallbackDate: .reference))
        #expect(snapshot.contextPercent == 1)
        #expect(snapshot.limits.map(\.label) == ["5h", "sem"])
        #expect(snapshot.limits.first?.resetsAt == AgentTimestamp.parse("2026-10-12T11:05:00Z"))
        // Una ventana con un número fuera de rango no hace caer a Hive: queda sin duración.
        let huge = UsageReader.codexLimit(["used_percent": .number(5), "window_minutes": .number(1e300)], lineDate: .reference)
        #expect(huge == UsageLimit(windowMinutes: nil, usedPercent: 5, resetsAt: nil))
    }

    @Test("Codex con una API key (sin rate_limits): con el contexto alcanza, no recorre todo el rollout")
    func codexWithoutLimits() throws {
        func tokenCount(_ total: Int, limits: String = "null") -> String {
            #"{"timestamp":"2026-10-12T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":\#(total)},"model_context_window":100000},"rate_limits":\#(limits)}}"#
        }
        // Un límite muy viejo y después muchos turnos sin límites.
        let old = tokenCount(1, limits: #"{"primary":{"used_percent":50,"window_minutes":300}}"#)
        let recent = (1...UsageReader.CodexUsage.limitsLookback).map { tokenCount($0 * 1000) }
        let snapshot = try #require(UsageReader.codexSnapshot(fromLines: ([old] + recent).joined(separator: "\n"), fallbackDate: .reference))
        #expect(snapshot.contextPercent == 20) // el último: 20.000 de 100.000
        #expect(snapshot.limits.isEmpty)
        // Con menos turnos de por medio, el límite se sigue encontrando.
        let near = try #require(UsageReader.codexSnapshot(fromLines: ([old] + recent.suffix(3)).joined(separator: "\n"), fallbackDate: .reference))
        #expect(near.limits.map(\.usedPercent) == [50])
        #expect(near.contextPercent == 20)

        // En disco: un rollout grande sin límites se resuelve leyendo solo el final.
        let dir = TempDir("hive-usage")
        let filler = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c","output":""# + String(repeating: "x", count: 2 << 20) + "\"}}\n"
        let file = dir.write("rollout.jsonl", filler + filler + recent.joined(separator: "\n") + "\n")
        var visited = 0
        let handle = try FileHandle(forReadingFrom: file)
        var usage = UsageReader.CodexUsage(fallbackDate: .reference)
        ReverseLines.scan(handle, maxBytes: 64 << 20) { line in
            visited += 1
            if line.range(of: Data(#""token_count""#.utf8)) != nil { usage.add(line) }
            return usage.isComplete
        }
        try handle.close()
        #expect(visited == UsageReader.CodexUsage.limitsLookback) // nunca llegó a las salidas de 2 MB
        #expect(UsageReader.codex(rolloutURL: file)?.contextPercent == 20)
    }

    @Test("Codex: lee solo el final de un rollout largo")
    func codexTail() throws {
        let dir = TempDir("hive-usage")
        let filler = String(repeating: #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"relleno"}]}}"# + "\n", count: 1500)
        let file = dir.write("rollout.jsonl", filler + AHFixtures.codexRollout + "\n")
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! Int > 65_536 * 2)
        let snapshot = try #require(UsageReader.codex(rolloutURL: file))
        #expect(snapshot.limits.first?.usedPercent == 80)
        #expect(UsageReader.codex(rolloutURL: dir.url.appendingPathComponent("no-existe.jsonl")) == nil)
    }

    @Test("Codex: encuentra el token_count aunque después haya MB de salida de un comando")
    func codexFarBack() throws {
        let dir = TempDir("hive-usage")
        // Un comando con mucha salida después del último token_count (en los rollouts reales llegan a ser decenas de MB).
        let output = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c","output":""# + String(repeating: "x", count: 3 << 20) + "\"}}\n"
        let file = dir.write("rollout.jsonl", AHFixtures.codexRollout + "\n" + output + output)
        let snapshot = try #require(UsageReader.codex(rolloutURL: file))
        #expect(snapshot.limits.first?.usedPercent == 80)
        #expect(snapshot.contextPercent != nil)
        // Con un tope menor que la distancia, no lo encuentra (y no recorre todo el archivo).
        #expect(UsageReader.codex(rolloutURL: file, maxScan: 1 << 20) == nil)
    }

    @Test("Recorre las líneas de atrás hacia adelante aunque crucen los pedazos")
    func reverseLines() throws {
        let dir = TempDir("hive-usage")
        let lines = (1...40).map { "línea \($0) " + String(repeating: "·", count: $0 * 3) }
        let file = dir.write("lineas.txt", lines.joined(separator: "\n") + "\n")
        for chunk in [7, 64, 1 << 20] {
            let handle = try FileHandle(forReadingFrom: file)
            var seen: [String] = []
            ReverseLines.scan(handle, maxBytes: 1 << 20, chunk: chunk) { line in
                seen.append(String(decoding: line, as: UTF8.self))
                return false
            }
            try handle.close()
            #expect(seen == lines.reversed(), "pedazos de \(chunk) bytes")
        }
        // Para cuando se le pide.
        let handle = try FileHandle(forReadingFrom: file)
        var count = 0
        ReverseLines.scan(handle, maxBytes: 1 << 20, chunk: 16) { _ in
            count += 1
            return count == 3
        }
        try handle.close()
        #expect(count == 3)
    }

    @Test("Claude: contexto y límites de 5 horas y semanal del statusLine")
    func claude() throws {
        let json = try #require(JSONValue.parse(Self.claudeStatus))
        let snapshot = try #require(UsageReader.claudeSnapshot(json, updatedAt: .reference))
        #expect(snapshot.agent == .claude)
        #expect(snapshot.contextPercent == 72.4)
        #expect(snapshot.limits.map(\.label) == ["5h", "sem"])
        #expect(snapshot.limits.map(\.usedPercent) == [23.5, 41.2])
        #expect(snapshot.limits.first?.resetsAt == Date(timeIntervalSince1970: 1_790_003_600))
        // Sin used_percentage se calcula con los tokens; sin límites (API key) quedan vacíos.
        let computed = try #require(UsageReader.claudeSnapshot(
            ["context_window": ["context_window_size": .number(200_000), "current_usage": ["input_tokens": .number(10_000), "cache_read_input_tokens": .number(30_000)]]],
            updatedAt: .reference))
        #expect(computed.contextPercent == 20)
        #expect(computed.limits.isEmpty)
        #expect(UsageReader.claudeSnapshot(["model": ["id": "x"]], updatedAt: .reference) == nil)
        // Los límites que ya se reiniciaron no cuentan.
        #expect(snapshot.activeLimits(now: Date(timeIntervalSince1970: 1_790_100_000)).map(\.label) == ["sem"])
    }

    @Test("Claude: el script del statusLine guarda el archivo que lee Hive, aunque encadene el tuyo")
    func claudeEndToEnd() throws {
        let dir = TempDir("hive-usage")
        let paths = HivePaths(root: dir.url.appendingPathComponent("Application Support/Hive"))
        try EventBridge.install(paths: paths)
        let id = UUID()
        let fake = dir.write("mi-statusline.sh", "#!/bin/sh\ncat > /dev/null\nprintf 'Opus · mi barra'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let r = ProcessCommandRunner().run("/bin/sh", ["-c", "printf '%s' \(shellQuote(Self.claudeStatus)) | \(shellQuote(paths.eventBin.path)) claude-status"],
                                           cwd: nil, environment: ["HIVE_EVENTS_DIR": paths.eventsDir.path, "HIVE_SESSION_ID": id.uuidString,
                                                                   "HIVE_USER_STATUSLINE": shellQuote(fake.path)])
        #expect(r.ok)
        #expect(r.stdout == "Opus · mi barra")
        let snapshot = try #require(UsageReader.claude(usageFile: paths.usageDir.appendingPathComponent("\(id.uuidString).json")))
        #expect(snapshot.contextPercent == 72.4)
        #expect(snapshot.limits.count == 2)
    }

    @Test("Porcentajes raros (NaN, inf, 1e20) quedan acotados y no hacen caer a Hive")
    func weirdPercents() throws {
        let claude = try #require(UsageReader.claudeSnapshot(
            ["context_window": ["used_percentage": "NaN"],
             "rate_limits": ["five_hour": ["used_percentage": .number(1e20)], "seven_day": ["used_percentage": "inf"]]],
            updatedAt: .reference))
        #expect(claude.contextPercent == nil)
        #expect(claude.limits.map(\.usedPercent) == [100])
        let negative = try #require(UsageReader.claudeSnapshot(["context_window": ["used_percentage": .number(-5)]], updatedAt: .reference))
        #expect(negative.contextPercent == 0)

        #expect(UsageReader.codexLimit(["used_percent": "nan"], lineDate: .reference) == nil)
        let codex = try #require(UsageReader.codexLimit(["used_percent": .number(1e20), "resets_in_seconds": "inf"], lineDate: .reference))
        #expect(codex.usedPercent == 100)
        #expect(codex.resetsAt == nil)
        let lines = #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":"1e400"},"model_context_window":100},"rate_limits":null}}"#
        #expect(UsageReader.codexSnapshot(fromLines: lines, fallbackDate: .reference)?.contextPercent == nil)

        // Ni armándolo a mano: lo que llega a las vistas siempre es seguro para Int(_:).
        #expect(UsageLimit(windowMinutes: nil, usedPercent: .nan, resetsAt: nil).usedPercent == 0)
        #expect(UsageSnapshot(agent: .claude, contextPercent: .infinity, limits: [], updatedAt: .reference).contextPercent == nil)
        #expect(UsageReader.date(.number(.nan)) == nil)
        #expect(UsageReader.date("inf") == nil)
    }

    @Test("Fechas de reinicio: números, milisegundos y texto")
    func dates() {
        #expect(UsageReader.date(.number(1_790_000_000)) == .reference)
        #expect(UsageReader.date(.number(1_790_000_000_000)) == .reference)
        #expect(UsageReader.date("1790000000") == .reference)
        #expect(UsageReader.date("2026-09-21T14:13:20Z") == .reference)
        #expect(UsageReader.date(nil) == nil)
    }

    @Test("Textos: «5h», «sem» y cuándo se reinicia")
    func texts() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Argentina/Buenos_Aires")!
        let now = Date.reference // lunes 21 de septiembre, 11:13
        let locale = Locale(identifier: "es_ES")
        #expect(UsageReader.resetText(now.addingTimeInterval(3 * 3600), now: now, calendar: calendar, locale: locale) == "se reinicia hoy 14:13")
        #expect(UsageReader.resetText(now.addingTimeInterval(86_400), now: now, calendar: calendar, locale: locale) == "se reinicia mañana 11:13")
        #expect(UsageReader.resetText(now.addingTimeInterval(3 * 86_400), now: now, calendar: calendar, locale: locale) == "se reinicia el jue 11:13")
        #expect(UsageLimit(windowMinutes: 300, usedPercent: 1, resetsAt: nil).longLabel == "5 horas")
        #expect(UsageLimit(windowMinutes: 1440, usedPercent: 1, resetsAt: nil).label == "1d")
        #expect(UsageLimit(windowMinutes: 120, usedPercent: 1, resetsAt: nil).label == "2h")
        #expect(UsageLimit(windowMinutes: nil, usedPercent: 1, resetsAt: nil).label == "límite")
    }
}
