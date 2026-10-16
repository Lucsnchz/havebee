import Foundation

/// Comandos típicos según lo que tenga el repo: scripts de package.json, Laravel, composer, Docker y Android (Gradle).
public enum CommandSuggestions {
    public struct Suggestion: Equatable, Sendable {
        public let name: String
        public let command: String
    }

    public static func detect(projectPath root: String, existing: [ProjectCommand] = []) -> [Suggestion] {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: (root as NSString).appendingPathComponent(name)) }
        func json(_ name: String) -> JSONValue? { fm.contents(atPath: (root as NSString).appendingPathComponent(name)).flatMap(JSONValue.parse) }
        var found: [Suggestion] = []

        if let scripts = json("package.json")?["scripts"]?.object {
            let runner: String
            if exists("pnpm-lock.yaml") { runner = "pnpm" }
            else if exists("yarn.lock") { runner = "yarn" }
            else if exists("bun.lockb") || exists("bun.lock") { runner = "bun run" }
            else { runner = "npm run" }
            for name in ["dev", "start", "serve", "watch", "build", "test", "lint", "preview"] where scripts[name] != nil {
                found.append(Suggestion(name: name.capitalized, command: "\(runner) \(name)"))
            }
        }
        let composer = json("composer.json")
        if exists("artisan") {
            found.append(Suggestion(name: "Servidor Laravel", command: "php artisan serve"))
            found.append(Suggestion(name: "Cola", command: "php artisan queue:work"))
            found.append(Suggestion(name: "Tests", command: "php artisan test"))
            if composer?["require"]?["laravel/pail"] != nil || composer?["require-dev"]?["laravel/pail"] != nil {
                found.append(Suggestion(name: "Logs", command: "php artisan pail"))
            }
        }
        if composer?["scripts"]?["dev"] != nil {
            found.append(Suggestion(name: "Composer dev", command: "composer run dev"))
        }
        if exists("gradlew") {
            found.append(contentsOf: gradleSuggestions(AndroidApp.read(projectPath: root)))
        }
        if ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"].contains(where: exists) {
            found.append(Suggestion(name: "Docker", command: "docker compose up"))
        }
        let taken = Set(existing.map(\.command))
        return found.filter { !taken.contains($0.command) }
    }

    /// Los comandos de Gradle que existen de verdad en el repo. Con sabores (`productFlavors`) no hay
    /// `installDebug` ni `testDebugUnitTest`: las tareas llevan el sabor (`installLocalDebug`), y el id
    /// instalado suma los `applicationIdSuffix` (`com.app.local`), así que se usa el sabor del día a día.
    static func gradleSuggestions(_ app: AndroidApp?) -> [Suggestion] {
        var found = [Suggestion(name: "Compilar debug", command: "./gradlew assembleDebug")]
        // Sin el build.gradle de la app (u otro nombre de módulo) quedan las tareas de siempre, sin logcat.
        let variant: AndroidApp.Variant?
        if let app { variant = app.debugVariant } else { variant = AndroidApp.Variant(flavor: nil, applicationId: nil) }
        if let variant {
            let task = (variant.flavor.map(AndroidApp.capitalizedFirst) ?? "") + "Debug"
            let label = variant.flavor.map { " (\($0))" } ?? ""
            found.append(Suggestion(name: "Instalar en el teléfono\(label)", command: "./gradlew install\(task)"))
            found.append(Suggestion(name: "Tests\(label)", command: "./gradlew test\(task)UnitTest"))
        }
        found.append(Suggestion(name: "Lint", command: "./gradlew lint"))
        if let variant, let id = variant.applicationId {
            let label = variant.flavor.map { " (\($0))" } ?? ""
            found.append(Suggestion(name: "Logcat de la app\(label)", command: "adb logcat --pid=$(adb shell pidof -s \(id))"))
        }
        return found
    }

    /// El applicationId de la app Android, leído de `app/build.gradle.kts` o `app/build.gradle`.
    /// Si no está, Gradle usa el `namespace`, así que ese es el respaldo.
    public static func androidApplicationId(projectPath root: String) -> String? {
        AndroidApp.read(projectPath: root)?.applicationId
    }

    /// El valor de `clave = "x"`, `clave "x"` o `clave("x")` al principio de una línea (no en un comentario).
    /// Solo acepta un nombre de paquete válido, así se puede usar sin comillas en un comando.
    static func gradleString(_ key: String, in text: String) -> String? {
        gradleValue(key, in: text, value: #"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+"#)
    }

    /// Como `gradleString`, pero con el patrón que tiene que cumplir el valor (siempre seguro para el shell).
    static func gradleValue(_ key: String, in text: String, value: String) -> String? {
        let pattern = #"(?m)^\s*"# + key + #"\s*(?:=\s*|\(\s*)?["'](\#(value))["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// Lo que importa de `app/build.gradle(.kts)` para sugerir comandos: el id, los sabores y los sufijos.
public struct AndroidApp: Equatable, Sendable {
    public struct Flavor: Equatable, Sendable {
        public var name: String
        public var applicationId: String?
        public var suffix: String
        public var dimension: String?

        public init(name: String, applicationId: String? = nil, suffix: String = "", dimension: String? = nil) {
            self.name = name
            self.applicationId = applicationId
            self.suffix = suffix
            self.dimension = dimension
        }
    }

    /// La variante debug para instalar y mirar el logcat.
    public struct Variant: Equatable, Sendable {
        public var flavor: String?
        /// El id con el que queda instalada (con los sufijos), si se conoce.
        public var applicationId: String?

        public init(flavor: String?, applicationId: String?) {
            self.flavor = flavor
            self.applicationId = applicationId
        }
    }

    /// El `applicationId` (o el `namespace`, que Gradle usa si no hay applicationId).
    public var applicationId: String?
    /// `applicationIdSuffix` de `defaultConfig`, que vale para todas las variantes.
    public var defaultSuffix = ""
    /// `applicationIdSuffix` del tipo `debug`.
    public var debugSuffix = ""
    /// Los sabores, en el orden del archivo.
    public var flavors: [Flavor] = []

    public init(applicationId: String? = nil, defaultSuffix: String = "", debugSuffix: String = "", flavors: [Flavor] = []) {
        self.applicationId = applicationId
        self.defaultSuffix = defaultSuffix
        self.debugSuffix = debugSuffix
        self.flavors = flavors
    }

    /// Los sabores que se suelen usar para desarrollar, en orden de preferencia.
    static let everydayFlavors = ["local", "dev", "develop", "development"]

    /// La variante debug a sugerir: sin sabores, `debug`; con sabores de una sola dimensión, el del día
    /// a día («local» o «dev») o el primero. Con varias dimensiones (las variantes combinan sabores) no
    /// hay una sola que adivinar: nil.
    public var debugVariant: Variant? {
        guard !flavors.isEmpty else {
            return Variant(flavor: nil, applicationId: applicationId.map { Self.applying([defaultSuffix, debugSuffix], to: $0) })
        }
        guard Set(flavors.compactMap(\.dimension)).count <= 1 else { return nil }
        let flavor = Self.everydayFlavors.lazy.compactMap { name in self.flavors.first { $0.name.lowercased() == name } }.first
            ?? flavors[0]
        let id = (flavor.applicationId ?? applicationId).map { Self.applying([defaultSuffix, flavor.suffix, debugSuffix], to: $0) }
        return Variant(flavor: flavor.name, applicationId: id)
    }

    /// Suma los sufijos como Gradle: cada uno con su punto adelante (`debug` → `.debug`).
    static func applying(_ suffixes: [String], to id: String) -> String {
        suffixes.filter { !$0.isEmpty }.reduce(id) { $0 + ($1.hasPrefix(".") ? $1 : "." + $1) }
    }

    static func capitalizedFirst(_ name: String) -> String {
        name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Lee `app/build.gradle.kts` o `app/build.gradle`; nil si no hay ninguno.
    public static func read(projectPath root: String) -> AndroidApp? {
        for file in ["app/build.gradle.kts", "app/build.gradle"] {
            let path = (root as NSString).appendingPathComponent(file)
            if let text = try? String(contentsOfFile: path, encoding: .utf8) { return parse(text) }
        }
        return nil
    }

    static let suffixPattern = #"[A-Za-z0-9_.]*"#
    static let namePattern = #"[A-Za-z_][A-Za-z0-9_]*"#

    /// Arma la app a partir del texto del build.gradle. Cuenta llaves sin mirar comentarios ni cadenas.
    public static func parse(_ text: String) -> AndroidApp {
        let code = GradleText(text)
        var app = AndroidApp()
        let defaultConfig = code.blocks(named: "defaultConfig").first.map(code.text)
        app.applicationId = defaultConfig.flatMap { CommandSuggestions.gradleString("applicationId", in: $0) }
            ?? CommandSuggestions.gradleString("applicationId", in: code.textOutside(code.blocks(named: "productFlavors")))
            ?? CommandSuggestions.gradleString("namespace", in: text)
        app.defaultSuffix = defaultConfig.flatMap { CommandSuggestions.gradleValue("applicationIdSuffix", in: $0, value: suffixPattern) } ?? ""
        if let buildTypes = code.blocks(named: "buildTypes").first,
           let debug = code.children(of: buildTypes).first(where: { $0.name == "debug" }) {
            app.debugSuffix = CommandSuggestions.gradleValue("applicationIdSuffix", in: code.text(debug.body), value: suffixPattern) ?? ""
        }
        if let flavors = code.blocks(named: "productFlavors").first {
            app.flavors = code.children(of: flavors).map { child in
                let body = code.text(child.body)
                return Flavor(name: child.name,
                              applicationId: CommandSuggestions.gradleString("applicationId", in: body),
                              suffix: CommandSuggestions.gradleValue("applicationIdSuffix", in: body, value: suffixPattern) ?? "",
                              dimension: CommandSuggestions.gradleValue("(?:dimension|setDimension)", in: body, value: namePattern))
            }
        }
        return app
    }
}

/// Un build.gradle(.kts) con los comentarios y el contenido de las cadenas tapados, para encontrar los
/// bloques `nombre { … }` sin que los confunda un `"{"`, un `${…}` o un `// }`.
/// Trabaja con los bytes UTF-8: todos los delimitadores son ASCII y un carácter de varios bytes nunca
/// contiene uno, así que las posiciones de llaves y comillas son exactas (y recorrer bytes es rápido).
struct GradleText {
    let bytes: [UInt8]
    /// Igual que `bytes`, con comentarios y cadenas en blanco (mismas posiciones).
    let code: [UInt8]

    init(_ text: String) {
        bytes = Array(text.utf8)
        code = Self.mask(bytes)
    }

    func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }

    /// El texto sin esos bloques (por ejemplo, sin los sabores, que pueden pisar el applicationId).
    func textOutside(_ ranges: [Range<Int>]) -> String {
        var result = bytes
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) { result.removeSubrange(range) }
        return String(decoding: result, as: UTF8.self)
    }

    /// El contenido (entre llaves) de cada `nombre {` del archivo, a cualquier profundidad.
    func blocks(named name: String) -> [Range<Int>] {
        let word = Array(name.utf8)
        guard let first = word.first else { return [] }
        var result: [Range<Int>] = []
        var index = 0
        while index + word.count <= code.count {
            defer { index += 1 }
            guard code[index] == first, index == 0 || !Self.isIdentifier(code[index - 1]),
                  (1..<word.count).allSatisfy({ code[index + $0] == word[$0] }) else { continue }
            var open = index + word.count
            while open < code.count, Self.isWhitespace(code[open]) { open += 1 }
            guard open < code.count, code[open] == Self.openBrace, let close = closing(open) else { continue }
            result.append(open + 1..<close)
        }
        return result
    }

    /// Los bloques hijos directos: `create("local") {`, `getByName("debug") {` o `local {` (Groovy).
    func children(of range: Range<Int>) -> [(name: String, body: Range<Int>)] {
        var result: [(name: String, body: Range<Int>)] = []
        var headerStart = range.lowerBound
        var index = range.lowerBound
        while index < range.upperBound {
            switch code[index] {
            case Self.openBrace:
                guard let close = closing(index) else { return result }
                if let name = Self.childName(text(headerStart..<index)) { result.append((name, index + 1..<close)) }
                index = close + 1
                headerStart = index
            case UInt8(ascii: ";"), Self.closeBrace:
                index += 1
                headerStart = index
            default:
                index += 1
            }
        }
        return result
    }

    /// La posición de la `}` que cierra la `{` de `open`.
    func closing(_ open: Int) -> Int? {
        var depth = 0
        for index in open..<code.count {
            if code[index] == Self.openBrace { depth += 1 }
            if code[index] == Self.closeBrace {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    /// El nombre del bloque según la última línea antes de la llave.
    static func childName(_ header: String) -> String? {
        guard let line = header.components(separatedBy: .newlines).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces) else { return nil }
        let call = #"^(?:create|register|maybeCreate|getByName|named)\s*\(\s*["']([A-Za-z_][A-Za-z0-9_]*)["']\s*\)$"#
        let plain = #"^([A-Za-z_][A-Za-z0-9_]*)$"#
        for pattern in [call, plain] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { continue }
            let name = String(line[range])
            // `all { }` o `configureEach { }` configuran todos los sabores: no son uno.
            return ["all", "configureEach", "each", "forEach", "matching", "withType"].contains(name) ? nil : name
        }
        return nil
    }

    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
    static let newline = UInt8(ascii: "\n")

    /// Letra, número o `_` (y cualquier byte de un carácter no ASCII, que en Kotlin puede ser parte de un nombre).
    static func isIdentifier(_ byte: UInt8) -> Bool {
        byte >= 0x80 || byte == UInt8(ascii: "_") || (byte >= 0x30 && byte <= 0x39)
            || (byte | 0x20 >= UInt8(ascii: "a") && byte | 0x20 <= UInt8(ascii: "z"))
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// Tapa con espacios los comentarios y el contenido de las cadenas (`"…"`, `'…'`), incluidas las
    /// plantillas `${…}` de Kotlin y Groovy, que pueden tener llaves y cadenas adentro.
    static func mask(_ bytes: [UInt8]) -> [UInt8] {
        enum Mode { case code(depth: Int), string(UInt8) }
        let slash = UInt8(ascii: "/"), star = UInt8(ascii: "*"), backslash = UInt8(ascii: "\\")
        let doubleQuote = UInt8(ascii: "\""), singleQuote = UInt8(ascii: "'"), dollar = UInt8(ascii: "$")
        var out = bytes
        var stack: [Mode] = [.code(depth: 0)]
        var index = 0
        func blank(_ position: Int) { if position < out.count, out[position] != newline { out[position] = 0x20 } }
        while index < bytes.count {
            let byte = bytes[index]
            let next: UInt8? = index + 1 < bytes.count ? bytes[index + 1] : nil
            let inTemplate = stack.count > 1
            switch stack[stack.count - 1] {
            case .code(let depth):
                if byte == slash, next == slash {
                    while index < bytes.count, bytes[index] != newline { blank(index); index += 1 }
                    continue
                }
                if byte == slash, next == star {
                    blank(index); blank(index + 1); index += 2
                    while index < bytes.count, !(bytes[index] == star && index + 1 < bytes.count && bytes[index + 1] == slash) {
                        blank(index); index += 1
                    }
                    blank(index); blank(index + 1); index += 2
                    continue
                }
                if byte == doubleQuote || byte == singleQuote {
                    stack.append(.string(byte))
                    if inTemplate { blank(index) }
                    index += 1
                    continue
                }
                if inTemplate {
                    if byte == openBrace { stack[stack.count - 1] = .code(depth: depth + 1) }
                    if byte == closeBrace {
                        if depth == 0 { stack.removeLast() } else { stack[stack.count - 1] = .code(depth: depth - 1) }
                    }
                    blank(index)
                }
                index += 1
            case .string(let quote):
                if byte == backslash {
                    blank(index); blank(index + 1); index += 2
                } else if byte == quote {
                    stack.removeLast()
                    if stack.count > 1 { blank(index) }
                    index += 1
                } else if quote == doubleQuote, byte == dollar, next == openBrace {
                    blank(index); blank(index + 1); index += 2
                    stack.append(.code(depth: 0))
                } else {
                    blank(index); index += 1
                }
            }
        }
        return out
    }
}

/// Busca un logo dentro del repo para usarlo como ícono del proyecto.
/// `isUsable` decide si un archivo es una imagen que sirve (la app lo hace con AppKit).
public struct LogoFinder: Sendable {
    /// En orden de preferencia: íconos cuadrados y grandes primero, favicons chicos al final.
    public static let candidates = [
        "public/apple-touch-icon.png", "public/brand/apple-touch-icon.png", "static/apple-touch-icon.png",
        "apple-touch-icon.png", "public/images/apple-touch-icon.png",
        "public/logo_icon.png", "public/logo-icon.png", "public/icon.png", "app/icon.png", "src/app/icon.png",
        "assets/icon.png", "assets/icon/icon.png", "assets/images/icon.png", "icon.png", "build/icon.png",
        "app/src/main/ic_launcher-playstore.png",
        "app/src/main/res/mipmap-xxxhdpi/ic_launcher.png", "app/src/main/res/mipmap-xxxhdpi/ic_launcher.webp",
        "app/src/main/res/mipmap-xxhdpi/ic_launcher.png", "app/src/main/res/mipmap-xxhdpi/ic_launcher.webp",
        "public/favicon.svg", "public/favicon.png", "static/favicon.png", "src/favicon.png", "public/favicon-32x32.png",
        "public/logo.png", "public/images/logo.png", "public/img/logo.png", "src/assets/logo.png", "assets/logo.png",
        "logo.png", "public/logo.svg", "src/assets/logo.svg", "logo.svg", ".github/logo.png", "docs/logo.png",
        "public/favicon.ico", "public/brand/favicon.ico", "static/favicon.ico", "app/favicon.ico", "src/app/favicon.ico",
        "favicon.ico",
    ]

    private let isUsable: @Sendable (String) -> Bool

    public init(isUsable: @escaping @Sendable (String) -> Bool) {
        self.isUsable = isUsable
    }

    /// Todos los logos válidos del repo, el mejor primero.
    public func find(in root: String) -> [String] {
        var found: [String] = []
        for relative in Self.candidates {
            let path = (root as NSString).appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: path), isUsable(path) { found.append(path) }
        }
        found.append(contentsOf: xcodeAppIcons(in: root))
        return found
    }

    /// El PNG más grande de un AppIcon.appiconset (proyectos de Xcode), hasta un nivel adentro.
    private func xcodeAppIcons(in root: String) -> [String] {
        let fm = FileManager.default
        var dirs = [root]
        for child in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !child.hasPrefix(".") {
            dirs.append((root as NSString).appendingPathComponent(child))
        }
        for dir in dirs {
            let set = (dir as NSString).appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
            guard let files = try? fm.contentsOfDirectory(atPath: set) else { continue }
            let pngs = files.filter { $0.lowercased().hasSuffix(".png") }.map { (set as NSString).appendingPathComponent($0) }
            func size(_ path: String) -> Int { (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0 }
            if let largest = pngs.max(by: { size($0) < size($1) }), isUsable(largest) { return [largest] }
        }
        return []
    }
}
