import Foundation
import Testing
@testable import HiveCore

@Suite("Sitios de Herd (raíz falsa)")
struct HerdSitesTests {
    /// Arma una configuración de Herd falsa: config.json, links y certificados.
    func fakeHerd(_ dir: TempDir, parked: String, tld: String = "test") throws -> URL {
        let root = dir.subdir("Herd")
        let valet = root.appendingPathComponent("config/valet")
        let sites = valet.appendingPathComponent("Sites").path
        try FileManager.default.createDirectory(atPath: sites, withIntermediateDirectories: true)
        let config = """
        {"paths": ["\(sites)", "\(sites)/", "\(parked)/"], "share-tool": "expose", "loopback": "127.0.0.1", "tld": "\(tld)"}
        """
        try config.write(toFile: valet.appendingPathComponent("config.json").path, atomically: true, encoding: .utf8)
        let linked = dir.subdir("otros/emplag-reporte-512").path
        try FileManager.default.createSymbolicLink(atPath: sites + "/emplag-512", withDestinationPath: linked)
        try FileManager.default.createSymbolicLink(atPath: sites + "/relativo", withDestinationPath: "../../../../otros/relativo")
        let certs = valet.appendingPathComponent("Certificates").path
        try FileManager.default.createDirectory(atPath: certs, withIntermediateDirectories: true)
        for name in ["ecommerce.test.crt", "ecommerce.test.key", "emplag-512.test.crt"] {
            FileManager.default.createFile(atPath: certs + "/" + name, contents: Data())
        }
        return root
    }

    @Test("Lee dominio, carpetas parked, links y certificados")
    func parse() throws {
        let dir = TempDir()
        let parked = dir.subdir("Herd-sitios").path
        let herd = try #require(HerdSites.parse(configRoot: try fakeHerd(dir, parked: parked)))
        #expect(herd.tld == "test")
        #expect(herd.parkedPaths.count == 1 && samePath(herd.parkedPaths[0], parked))
        #expect(Set(herd.links.keys) == ["emplag-512", "relativo"])
        #expect(samePath(try #require(herd.links["emplag-512"]), dir.path + "/otros/emplag-reporte-512"))
        #expect(herd.securedHosts == ["ecommerce.test", "emplag-512.test"])
    }

    @Test("Sin Herd instalado devuelve nil")
    func missing() {
        #expect(HerdSites.parse(configRoot: TempDir().url) == nil)
        #expect(HerdSites.defaultRoot(home: URL(fileURLWithPath: "/Users/x")).path == "/Users/x/Library/Application Support/Herd")
    }

    @Test("URL de una carpeta: link primero, después parked; https si tiene certificado")
    func urls() throws {
        let dir = TempDir()
        let parked = dir.subdir("Herd-sitios").path
        let herd = try #require(HerdSites.parse(configRoot: try fakeHerd(dir, parked: parked, tld: "test")))
        #expect(herd.url(for: parked + "/ecommerce") == "https://ecommerce.test")
        #expect(herd.url(for: parked + "/Ecommerce-Checkout") == "http://ecommerce-checkout.test")
        #expect(herd.url(for: dir.path + "/otros/emplag-reporte-512") == "https://emplag-512.test")
        #expect(herd.url(for: dir.path + "/fuera/de/herd") == nil)
        #expect(herd.servesParent(of: parked + "/ecommerce"))
        #expect(!herd.servesParent(of: dir.path + "/otros/emplag-reporte-512"))
    }

    @Test("Valores en memoria: tld propio y hosts por carpeta")
    func inMemory() {
        let herd = HerdSites(tld: "local", parkedPaths: ["/Users/x/Herd"], links: [:], securedHosts: ["app.local"])
        #expect(herd.url(for: "/Users/x/Herd/app") == "https://app.local")
        #expect(herd.url(for: "/Users/x/Herd/app-x") == "http://app-x.local")
        #expect(herd.host(forFolder: "App-X") == "app-x.local")
        #expect(herd.isSecured("app.local") && !herd.isSecured("app-x.local"))
    }
}
