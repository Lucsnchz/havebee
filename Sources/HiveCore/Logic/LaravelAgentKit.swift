import Foundation

/// «Preparar para agentes»: lo que le falta a un proyecto Laravel para que Claude, Codex y Gemini
/// trabajen bien en él. Lee composer.json, composer.lock y .mcp.json; no ejecuta nada. Lo que hay que
/// instalar va a un script que corre a la vista; los MCP y los comandos los guarda Havebee.
public struct LaravelAgentKit: Equatable, Sendable {
    public enum Step: String, CaseIterable, Identifiable, Sendable {
        /// laravel/boost y `boost:install`: guías, skills y el MCP de Laravel.
        case boost
        /// `boost:update`: las guías se rehacen con las versiones que tenés instaladas.
        case guidelines
        /// `boost:update` en el post-update-cmd de composer.json, como recomienda Laravel.
        case autoUpdate
        /// laravel/pao: salida corta de Pest, PHPStan y Artisan cuando los corre un agente.
        case pao
        /// El MCP de Nightwatch con conexión directa.
        case nightwatch
        /// El MCP de Herd para este proyecto.
        case herd
        /// El comando «Tests afectados» (Pest 5, TIA).
        case fastTests

        public var id: String { rawValue }
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public var step: Step
        public var title: String
        public var detail: String
        /// Ya está: se muestra con una tilde y no se puede elegir.
        public var done: Bool
        public var id: Step { step }
    }

    public var items: [Item]
    /// Un MCP que hay que reemplazar (Nightwatch por `npx mcp-remote`).
    public var replacingNightwatch: String?
    /// El comando de los tests afectados, con o sin Herd.
    public var fastTestsCommand: String?
    var herdServer: MCPServer?
    var hasBoost: Bool

    public var pending: [Item] { items.filter { !$0.done } }

    /// Archivos del proyecto que se leen. Se inyecta en los tests.
    public struct Files: Sendable {
        public var read: @Sendable (String) -> String?
        /// Fecha de modificación (nil si no existe).
        public var modified: @Sendable (String) -> Date?

        public init(read: @escaping @Sendable (String) -> String?, modified: @escaping @Sendable (String) -> Date?) {
            self.read = read
            self.modified = modified
        }

        public static let live = Files(
            read: { try? String(contentsOfFile: $0, encoding: .utf8) },
            modified: { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date })
    }

    /// Nil si el proyecto no es Laravel.
    public static func inspect(projectPath: String, home: URL, servers: [MCPServer], commands: [ProjectCommand],
                               herdInstalled: Bool, files: Files = .live) -> LaravelAgentKit? {
        func path(_ name: String) -> String { (projectPath as NSString).appendingPathComponent(name) }
        guard files.read(path("artisan")) != nil, let composer = files.read(path("composer.json")).flatMap(JSONValue.parse) else { return nil }
        func requires(_ name: String) -> Bool { composer["require"]?[name] != nil || composer["require-dev"]?[name] != nil }
        var items: [Item] = []
        let hasBoost = requires("laravel/boost")

        items.append(Item(step: .boost, title: "Laravel Boost",
                          detail: hasBoost ? "Guías, skills y el MCP de Laravel para tus agentes."
                              : "Instala laravel/boost y corre boost:install: elegís los agentes y las skills.",
                          done: hasBoost))
        if hasBoost {
            // Las guías salen de las versiones instaladas: si composer.lock cambió después, quedaron viejas.
            let lock = files.modified(path("composer.lock"))
            let guides = ["boost.json", "CLAUDE.md", "AGENTS.md"].compactMap { files.modified(path($0)) }.max()
            let stale = lock != nil && guides != nil && lock! > guides!.addingTimeInterval(1)
            items.append(Item(step: .guidelines, title: "Guías de Boost al día",
                              detail: stale ? "composer.lock cambió después de las guías: boost:update las rehace con tus versiones."
                                  : "Son posteriores al último cambio de composer.lock.",
                              done: !stale))
        }
        // Sin Boost, un boost:update en el post-update-cmd haría fallar cada composer update.
        if hasBoost {
            let postUpdate = composer["scripts"]?["post-update-cmd"]
            let autoUpdates = (postUpdate?.string.map { [$0] } ?? postUpdate?.stringArray ?? []).contains { $0.contains("boost:update") }
            items.append(Item(step: .autoUpdate, title: "Guías al día solas",
                              detail: autoUpdates ? "Cada composer update corre boost:update."
                                  : "Suma boost:update al post-update-cmd de composer.json, como recomienda Laravel.",
                              done: autoUpdates))
        }
        let hasPAO = requires("laravel/pao")
        items.append(Item(step: .pao, title: "PAO",
                          detail: hasPAO ? "Pest, PHPStan y Artisan le responden al agente en JSON corto."
                              : "Pest, PHPStan y Artisan le responden al agente en JSON corto: muchos menos tokens. Vos ves la salida de siempre. Pide PHP 8.3.",
                          done: hasPAO))

        var replacing: String?
        if requires("laravel/nightwatch") {
            let direct = servers.contains { $0.url == MCPCatalog.nightwatchURL }
            replacing = direct ? nil : servers.first { $0.name == "nightwatch" || $0.args.contains(MCPCatalog.nightwatchURL) }?.name
            items.append(Item(step: .nightwatch, title: "MCP de Nightwatch",
                              detail: direct ? "Errores y rendimiento de producción, con conexión directa."
                                  : replacing != nil ? "Hoy pasa por npx mcp-remote: lo cambio a conexión directa, sin Node de por medio."
                                  : "Errores y rendimiento de producción. La primera vez te pide entrar con tu cuenta.",
                              done: direct))
        }
        var herdServer: MCPServer?
        if herdInstalled, let item = MCPCatalog.herdMCP(projectPath: projectPath, home: home) {
            let present = servers.contains { $0.name == "herd" || $0.args.contains { $0.hasSuffix("herd-mcp.phar") } }
            herdServer = MCPServer(name: item.name, config: item.config)
            items.append(Item(step: .herd, title: "MCP de Herd",
                              detail: "Sitios, PHP, servicios y logs de Herd para el agente.", done: present))
        }
        var fastTests: String?
        let lock = files.read(path("composer.lock")).flatMap(JSONValue.parse)
        if let pest = CommandSuggestions.lockedMajor("pestphp/pest", lock: lock), pest >= 5 {
            let command = herdInstalled ? "herd coverage vendor/bin/pest --tia" : "vendor/bin/pest --tia"
            fastTests = command
            let present = commands.contains { $0.command.contains("pest") && $0.command.contains("--tia") }
            items.append(Item(step: .fastTests, title: "Tests afectados",
                              detail: present ? "Pest 5 corre solo los tests que tocó el cambio."
                                  : herdInstalled ? "Suma «\(command)»: corre solo los tests que tocó el cambio, con el Xdebug de Herd."
                                  : "Suma «\(command)»: corre solo los tests que tocó el cambio. Necesita Xdebug o PCOV.",
                              done: present))
        }
        return LaravelAgentKit(items: items, replacingNightwatch: replacing, fastTestsCommand: fastTests,
                               herdServer: herdServer, hasBoost: hasBoost)
    }

    /// El script para los pasos que se instalan con Composer y Artisan. Nil si no hay ninguno.
    public func script(_ steps: Set<Step>) -> String? {
        var lines: [String] = []
        let packages = (steps.contains(.boost) && !hasBoost ? ["laravel/boost"] : []) + (steps.contains(.pao) ? ["laravel/pao"] : [])
        if !packages.isEmpty { lines.append("composer require \(packages.joined(separator: " ")) --dev --no-interaction") }
        // boost:install pregunta qué agentes y skills querés: corre en la terminal y contestás ahí.
        if steps.contains(.boost) && !hasBoost { lines.append("php artisan boost:install") }
        else if steps.contains(.guidelines) && hasBoost { lines.append("php artisan boost:update") }
        if steps.contains(.autoUpdate) {
            let php = "$f = 'composer.json'; $j = json_decode(file_get_contents($f)); "
                + "if (!is_object($j)) { fwrite(STDERR, \"composer.json no es un JSON válido.\\n\"); exit(1); } "
                + "if (!isset($j->scripts)) { $j->scripts = new stdClass; } "
                + "$c = $j->scripts->{'post-update-cmd'} ?? []; if (!is_array($c)) { $c = [$c]; } "
                + "foreach ($c as $x) { if (is_string($x) && str_contains($x, 'boost:update')) { exit(0); } } "
                + "$c[] = '@php artisan boost:update --ansi'; $j->scripts->{'post-update-cmd'} = $c; "
                + "file_put_contents($f, json_encode($j, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . \"\\n\");"
            lines.append("php -r \(shellQuote(php))")
        }
        guard !lines.isEmpty else { return nil }
        return (["set -e"] + lines + ["printf '%s\\n' \(shellQuote("Listo. Revisá los cambios de composer.json antes de hacer commit."))"])
            .joined(separator: "\n")
    }

    /// Los MCP para guardar en .mcp.json, con el nombre al que reemplazan.
    public func servers(_ steps: Set<Step>) -> [(server: MCPServer, replacing: String?)] {
        var result: [(server: MCPServer, replacing: String?)] = []
        if steps.contains(.nightwatch), items.contains(where: { $0.step == .nightwatch && !$0.done }) {
            result.append((MCPServer(name: "nightwatch", config: ["type": "http", "url": .string(MCPCatalog.nightwatchURL)]), replacingNightwatch))
        }
        if steps.contains(.herd), let herdServer, items.contains(where: { $0.step == .herd && !$0.done }) {
            result.append((herdServer, nil))
        }
        return result
    }
}
