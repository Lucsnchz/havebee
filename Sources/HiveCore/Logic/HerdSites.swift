import Foundation

/// Lo que sirve Laravel Herd, leído de su configuración sin ejecutar `herd`: el dominio (.test),
/// las carpetas «parked» (cada subcarpeta es un sitio), los links y los sitios con HTTPS.
public struct HerdSites: Equatable, Sendable {
    public var tld: String
    /// Carpetas cuyas subcarpetas Herd sirve solas (`herd park`), como ~/Herd.
    public var parkedPaths: [String]
    /// Sitio → carpeta (`herd link`).
    public var links: [String: String]
    /// Hosts con certificado (`herd secure`), como "ecommerce.test".
    public var securedHosts: Set<String>

    public init(tld: String = "test", parkedPaths: [String] = [], links: [String: String] = [:], securedHosts: Set<String> = []) {
        self.tld = tld
        self.parkedPaths = parkedPaths
        self.links = links
        self.securedHosts = securedHosts
    }

    /// Carpeta de datos de Herd: ~/Library/Application Support/Herd.
    public static func defaultRoot(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Herd", isDirectory: true)
    }

    /// Lee `config/valet/config.json`, los links de `config/valet/Sites` y los certificados de
    /// `config/valet/Certificates`. Devuelve nil si Herd no está instalado.
    public static func parse(configRoot: URL) -> HerdSites? {
        let valet = configRoot.appendingPathComponent("config/valet", isDirectory: true)
        guard let data = FileManager.default.contents(atPath: valet.appendingPathComponent("config.json").path),
              let config = JSONValue.parse(data) else { return nil }
        let sitesDir = valet.appendingPathComponent("Sites", isDirectory: true).path
        let tld = config["tld"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "test"
        // La carpeta de links también figura en paths: no es una carpeta «parked» de verdad.
        let parked = (config["paths"]?.stringArray ?? []).filter { !samePath($0, sitesDir) }

        var links: [String: String] = [:]
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: sitesDir)) ?? [] {
            let link = (sitesDir as NSString).appendingPathComponent(name)
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: link) else { continue }
            links[name] = destination.hasPrefix("/") ? destination
                : ((sitesDir as NSString).appendingPathComponent(destination) as NSString).standardizingPath
        }

        let certificates = valet.appendingPathComponent("Certificates", isDirectory: true).path
        let secured = ((try? fm.contentsOfDirectory(atPath: certificates)) ?? [])
            .filter { $0.hasSuffix(".crt") }
            .map { String($0.dropLast(".crt".count)) }
        return HerdSites(tld: tld, parkedPaths: parked, links: links, securedHosts: Set(secured))
    }

    /// Host con el que Herd sirve una carpeta: primero un link que apunte a ella y, si no, el
    /// nombre de la carpeta cuando su padre es una carpeta «parked».
    public func host(for dir: String) -> String? {
        if let name = links.keys.sorted().first(where: { samePath(links[$0] ?? "", dir) }) {
            return "\(name.lowercased()).\(tld)"
        }
        guard servesParent(of: dir) else { return nil }
        return host(forFolder: (dir as NSString).lastPathComponent)
    }

    /// Host de una subcarpeta de una carpeta «parked» ("Ecommerce-Checkout" → "ecommerce-checkout.test").
    public func host(forFolder folder: String) -> String {
        "\(folder.lowercased()).\(tld)"
    }

    public func isSecured(_ host: String) -> Bool { securedHosts.contains(host) }

    /// URL completa de una carpeta, con https si tiene certificado.
    public func url(for dir: String) -> String? {
        host(for: dir).map { "\(isSecured($0) ? "https" : "http")://\($0)" }
    }

    /// Si Herd sirve sola cualquier carpeta que se cree al lado de `projectPath`.
    public func servesParent(of projectPath: String) -> Bool {
        let parent = (projectPath as NSString).deletingLastPathComponent
        return parkedPaths.contains { samePath($0, parent) }
    }
}
