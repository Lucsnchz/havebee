import Foundation
import Testing
@testable import HiveCore

@Suite("Scripts de preparación y cierre")
struct ProjectScriptsTests {
    /// Archivos en memoria, como los lee ProjectScripts.
    func reader(_ files: [String: String]) -> (String) -> String? {
        { path in files[(path as NSString).lastPathComponent] }
    }

    @Test("polyscope.json: listas unidas con && y sin sumar herd secure si ya está")
    func polyscope() {
        let files = ["polyscope.json": """
        {"scripts": {"setup": ["herd link", "herd secure", "herd isolate 8.4"], "archive": ["herd unsecure", "herd unlink"]},
         "preview": {"url": "https://{{folder}}.test"}}
        """]
        let r = ProjectScripts.resolve(projectPath: "/p", folder: "app-x", mainHasCert: true, read: reader(files))
        #expect(r.setup == .init(command: "herd link && herd secure && herd isolate 8.4", origin: .polyscope))
        #expect(r.archive == .init(command: "herd unsecure && herd unlink", origin: .polyscope))
        #expect(ProjectScripts.Origin.polyscope.label == "Tomado de polyscope.json")
    }

    @Test("conductor.json con textos; polyscope gana si están los dos")
    func conductor() {
        let conductor = ["conductor.json": #"{"scripts": {"setup": "npm ci", "run": "npm run dev", "archive": " "}}"#]
        let r = ProjectScripts.resolve(projectPath: "/p", folder: "x", mainHasCert: false, read: reader(conductor))
        #expect(r.setup == .init(command: "npm ci", origin: .conductor))
        #expect(r.archive == nil)
        var both = conductor
        both["polyscope.json"] = #"{"scripts": {"setup": "composer install"}}"#
        let mixed = ProjectScripts.resolve(projectPath: "/p", folder: "x", mainHasCert: false, read: reader(both))
        #expect(mixed.setup?.origin == .polyscope)
    }

    @Test("Sugerencias por stack", arguments: [
        (["composer.json": "{}", "package.json": #"{"scripts": {"build": "vite build"}}"#], "composer install && npm install && npm run build"),
        (["composer.json": "{}", "package.json": #"{"scripts": {"dev": "vite"}}"#], "composer install && npm install"),
        (["composer.json": "{}"], "composer install"),
        (["package.json": "{}"], "npm install"),
        (["package.json": "{}", "pnpm-lock.yaml": ""], "pnpm install"),
        (["package.json": "{}", "yarn.lock": ""], "yarn install"),
        (["package.json": "{}", "bun.lock": ""], "bun install"),
    ] as [([String: String], String)])
    func suggestions(files: [String: String], expected: String) {
        let r = ProjectScripts.resolve(projectPath: "/p", folder: "x", mainHasCert: false, read: reader(files))
        #expect(r.setup == .init(command: expected, origin: .suggested))
        #expect(r.archive == nil)
    }

    @Test("Android: nada que instalar")
    func android() {
        let r = ProjectScripts.resolve(projectPath: "/p", folder: "x", mainHasCert: false,
                                       read: reader(["build.gradle.kts": "", "settings.gradle.kts": ""]))
        #expect(r == ProjectScripts.Resolved())
    }

    @Test("herd secure solo si el principal tiene certificado, sin duplicarlo y con comillas si hacen falta")
    func herdSecure() {
        let laravel = ["composer.json": "{}"]
        let secure = ProjectScripts.resolve(projectPath: "/p", folder: "app-checkout", mainHasCert: true, read: reader(laravel))
        #expect(secure.setup?.command == "composer install && herd secure app-checkout")
        let plain = ProjectScripts.resolve(projectPath: "/p", folder: "app-checkout", mainHasCert: false, read: reader(laravel))
        #expect(plain.setup?.command == "composer install")
        let alone = ProjectScripts.resolve(projectPath: "/p", folder: "con espacio", mainHasCert: true, read: reader([:]))
        #expect(alone.setup == .init(command: "herd secure 'con espacio'", origin: .suggested))
    }

    @Test("herd secure solo para la carpeta hermana que Herd sirve, si el principal tiene HTTPS")
    func securesOnlyServedWorktrees() {
        #expect(ProjectScripts.securesWorktree(location: .sibling, herdServesParent: true, mainHasCert: true))
        #expect(!ProjectScripts.securesWorktree(location: .nested, herdServesParent: true, mainHasCert: true))
        #expect(!ProjectScripts.securesWorktree(location: .sibling, herdServesParent: false, mainHasCert: true))
        #expect(!ProjectScripts.securesWorktree(location: .sibling, herdServesParent: true, mainHasCert: false))
    }

    @Test("Variables para los scripts, con los alias de Conductor")
    func environment() {
        let env = ProjectScripts.environment(rootPath: "/Herd/app", worktreePath: "/Herd/app-x", branch: "feature/x")
        #expect(env == [
            "HIVE_ROOT_PATH": "/Herd/app", "HIVE_WORKTREE_PATH": "/Herd/app-x", "HIVE_BRANCH": "feature/x", "HIVE_FOLDER": "app-x",
            "CONDUCTOR_ROOT_PATH": "/Herd/app", "CONDUCTOR_WORKSPACE_NAME": "app-x",
        ])
    }

    @Test("Lee del disco por defecto")
    func readsDisk() {
        let dir = TempDir()
        dir.write("package.json", "{}")
        #expect(ProjectScripts.resolve(projectPath: dir.path, folder: "x", mainHasCert: false).setup?.command == "npm install")
    }
}
