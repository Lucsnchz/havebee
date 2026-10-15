import Foundation

/// Archivos que Hive instala para enterarse de lo que hacen los agentes.
public enum EventBridge {
    /// Puente de eventos. Lo invocan los hooks de Claude Code (payload por stdin) y el `notify`
    /// de Codex (payload como último argumento). Escribe un archivo `.evt` que Hive lee.
    /// Con `claude-status` hace de statusLine de Claude: guarda lo que manda Claude (contexto y límites)
    /// en usage/<sesión>.json y muestra un resumen, o el statusLine que ya tenías.
    public static let script = #"""
    #!/bin/sh
    # Hive: puente de eventos entre los agentes y la app. Generado automáticamente.
    dir="$HIVE_EVENTS_DIR"
    sid="$HIVE_SESSION_ID"
    src="$1"
    [ $# -gt 0 ] && shift
    if [ "$src" = "claude-status" ]; then
      input=$(cat)
      file=""
      if [ -n "$dir" ] && [ -n "$sid" ] && [ -d "$dir" ]; then
        udir="$dir/../usage"
        mkdir -p "$udir" 2>/dev/null
        tmp="$udir/.$sid.$$.tmp"
        if printf '%s' "$input" > "$tmp" 2>/dev/null && mv -f "$tmp" "$udir/$sid.json"; then file="$udir/$sid.json"; fi
      fi
      # Si ya tenías un statusLine, recibe lo mismo y se muestra el tuyo.
      if [ -n "$HIVE_USER_STATUSLINE" ]; then
        printf '%s' "$input" | /bin/sh -c "$HIVE_USER_STATUSLINE"
        exit 0
      fi
      [ -n "$file" ] || exit 0
      # Porcentaje redondeado sin printf %f (el de /bin/sh depende del idioma: 34.4 no es un número en es_AR).
      pct() {
        v=$(/usr/bin/plutil -extract "$1" raw -o - "$file" 2>/dev/null) || return 1
        case "$v" in ''|*[!0-9.]*) return 1 ;; esac
        i=${v%%.*}
        [ -n "$i" ] || i=0
        case "$v" in *.[5-9]*) i=$((i + 1)) ;; esac
        printf '%s' "$i"
      }
      line=""
      if v=$(pct context_window.used_percentage); then line="ctx $v%"; fi
      if v=$(pct rate_limits.five_hour.used_percentage); then line="${line:+$line · }5h $v%"; fi
      if v=$(pct rate_limits.seven_day.used_percentage); then line="${line:+$line · }sem $v%"; fi
      printf '%s' "$line"
      exit 0
    fi
    if [ -z "$dir" ] || [ -z "$sid" ] || [ ! -d "$dir" ]; then exit 0; fi
    tmp=$(mktemp "$dir/tmp.XXXXXX") || exit 0
    case "$src" in
      claude)
        { printf '%s\t%s\t%s\n' "$sid" claude "$1"; cat; } > "$tmp"
        ;;
      codex)
        payload=""
        for a in "$@"; do payload="$a"; done
        { printf '%s\t%s\t%s\n' "$sid" codex notify; printf '%s' "$payload"; } > "$tmp"
        # Si el usuario ya tenía un notify configurado, lo seguimos llamando igual que antes.
        if [ $# -gt 1 ]; then ( "$@" >/dev/null 2>&1 & ); fi
        ;;
      *)
        rm -f "$tmp"; exit 0
        ;;
    esac
    mv "$tmp" "$tmp.evt"
    exit 0
    """#

    public static let claudeHookEvents = ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "StopFailure"]
    /// Eventos de herramientas: llevan `matcher: "*"` para que corran con todas.
    /// PermissionRequest avisa del permiso apenas aparece el diálogo (el Notification llega 6 s tarde).
    public static let claudeToolEvents = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"]

    /// Ajustes que se le pasan a Claude con `--settings`: hooks que llaman al puente.
    public static var claudeSettings: JSONValue {
        func hook(_ event: String) -> JSONValue {
            .object(["type": "command", "command": .string("\"${HIVE_EVENT_BIN:-true}\" claude \(event)"), "timeout": .number(10)])
        }
        var hooks: [String: JSONValue] = [:]
        for event in claudeHookEvents { hooks[event] = [.object(["hooks": [hook(event)]])] }
        for event in claudeToolEvents { hooks[event] = [.object(["matcher": "*", "hooks": [hook(event)]])] }
        return .object(["hooks": .object(hooks)])
    }

    /// Los mismos ajustes más el statusLine de Hive (uso de contexto y límites de Claude).
    public static var claudeSettingsWithUsage: JSONValue {
        guard case .object(var settings) = claudeSettings else { return claudeSettings }
        settings["statusLine"] = ["type": "command", "command": .string(#""${HIVE_EVENT_BIN:-true}" claude-status"#)]
        return .object(settings)
    }

    /// Escribe el script y los dos ajustes de Claude (con y sin statusLine) en la carpeta de datos.
    public static func install(paths: HivePaths) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.eventsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.binDir, withIntermediateDirectories: true)
        try script.write(to: paths.eventBin, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.eventBin.path)
        for (settings, url) in [(claudeSettings, paths.claudeSettings), (claudeSettingsWithUsage, paths.claudeSettingsWithUsage)] {
            let data = try JSONSerialization.data(withJSONObject: settings.anyValue, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
        }
    }
}

/// Lee los eventos que deja el puente, en orden, y los borra.
public final class EventWatcher: @unchecked Sendable {
    private let directory: URL
    private let queue: DispatchQueue
    private let handler: @Sendable ([HiveEvent]) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?

    public init(directory: URL, queue: DispatchQueue = .main, handler: @escaping @Sendable ([HiveEvent]) -> Void) {
        self.directory = directory
        self.queue = queue
        self.handler = handler
    }

    deinit { stop() }

    public func start() {
        purge()
        let fd = open(directory.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }
        // Red de seguridad por si se pierde alguna notificación del sistema de archivos.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        source?.cancel()
        source = nil
        timer?.cancel()
        timer = nil
    }

    /// Los eventos de una ejecución anterior ya no significan nada.
    public func purge() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// Lee y borra los `.evt` pendientes. Devuelve los eventos entregados (útil para los tests).
    @discardableResult
    public func drain() -> [HiveEvent] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        let files = urls.filter { $0.pathExtension == "evt" }
            .sorted { (modified($0), $0.lastPathComponent) < (modified($1), $1.lastPathComponent) }
        guard !files.isEmpty else { return [] }
        var events: [HiveEvent] = []
        for file in files {
            defer { try? fm.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file), let event = HiveEvent.parse(String(decoding: data, as: UTF8.self)) else { continue }
            events.append(event)
        }
        if !events.isEmpty { handler(events) }
        return events
    }
}
