import Foundation
import Testing
@testable import HiveCore

@Suite("Comandos sugeridos para Android y Laravel")
struct StackSuggestionsTests {
    func commands(_ dir: TempDir, existing: [ProjectCommand] = []) -> [String] {
        CommandSuggestions.detect(projectPath: dir.path, existing: existing).map(\.command)
    }

    @Test("Android con build.gradle.kts: Gradle y el logcat con el applicationId")
    func androidKotlinDSL() {
        let dir = TempDir()
        dir.write("gradlew", "#!/bin/sh\n")
        dir.write("settings.gradle.kts", "include(\":app\")\n")
        dir.write("app/build.gradle.kts", """
        android {
            namespace = "com.dizeg.app"
            defaultConfig {
                // applicationId = "com.comentado.mal"
                applicationId = "com.dizeg.whatsapp"
                applicationIdSuffix = ".debug"
                minSdk = 26
            }
        }
        """)
        let all = CommandSuggestions.detect(projectPath: dir.path)
        #expect(all.map(\.command) == [
            "./gradlew assembleDebug", "./gradlew installDebug", "./gradlew testDebugUnitTest", "./gradlew lint",
            "adb logcat --pid=$(adb shell pidof -s com.dizeg.whatsapp)",
        ])
        #expect(all.map(\.name) == ["Compilar debug", "Instalar en el teléfono", "Tests", "Lint", "Logcat de la app"])
    }

    @Test("applicationId en Groovy, con paréntesis o tomado del namespace", arguments: [
        ("app/build.gradle", "android {\n  defaultConfig {\n    applicationId 'ar.emplag.app'\n  }\n}", "ar.emplag.app"),
        ("app/build.gradle", "android {\n    namespace \"ar.solo.namespace\"\n}\n", "ar.solo.namespace"),
        ("app/build.gradle.kts", "android {\n  defaultConfig {\n    applicationId(\"com.paren.app\")\n  }\n}", "com.paren.app"),
        ("app/build.gradle.kts", "android {\n  namespace = \"com.ns.app\"\n}", "com.ns.app"),
        ("app/build.gradle.kts", "android {\n  defaultConfig {\n    applicationId = libs.versions.id.get()\n  }\n}", nil),
        ("app/build.gradle.kts", "android {\n  defaultConfig {\n    applicationId = \"com.x; rm -rf ~\"\n  }\n}", nil),
    ] as [(String, String, String?)])
    func applicationId(file: String, content: String, expected: String?) {
        let dir = TempDir()
        dir.write(file, content)
        #expect(CommandSuggestions.androidApplicationId(projectPath: dir.path) == expected)
    }

    @Test("Sin applicationId no sugiere el logcat, pero sí Gradle")
    func androidWithoutId() {
        let dir = TempDir()
        dir.write("gradlew")
        #expect(commands(dir) == ["./gradlew assembleDebug", "./gradlew installDebug", "./gradlew testDebugUnitTest", "./gradlew lint"])
        #expect(CommandSuggestions.androidApplicationId(projectPath: dir.path) == nil)
    }

    @Test("Laravel con pail en require o en require-dev suma «Logs»", arguments: ["require", "require-dev"])
    func laravelPail(section: String) {
        let dir = TempDir()
        dir.write("artisan")
        dir.write("composer.json", #"{"\#(section)": {"laravel/pail": "^1.2", "php": "^8.3"}}"#)
        #expect(commands(dir) == ["php artisan serve", "php artisan queue:work", "php artisan test", "php artisan pail"])
    }

    @Test("Laravel sin pail no sugiere los logs")
    func laravelWithoutPail() {
        let dir = TempDir()
        dir.write("artisan")
        dir.write("composer.json", #"{"require": {"laravel/framework": "^12.0"}}"#)
        #expect(commands(dir) == ["php artisan serve", "php artisan queue:work", "php artisan test"])
        #expect(CommandSuggestions.detect(projectPath: dir.path).first { $0.command == "php artisan test" }?.name == "Tests")
    }

    @Test("No repite los comandos que el proyecto ya tiene")
    func skipsExisting() {
        let dir = TempDir()
        dir.write("artisan")
        dir.write("composer.json", #"{"require-dev": {"laravel/pail": "1"}}"#)
        dir.write("gradlew")
        dir.write("app/build.gradle.kts", "android { defaultConfig {\n applicationId = \"com.a.b\"\n} }")
        let existing = [
            ProjectCommand(name: "Tests PHP", command: "php artisan test"),
            ProjectCommand(name: "Logs", command: "php artisan pail"),
            ProjectCommand(name: "Instalar", command: "./gradlew installDebug"),
            ProjectCommand(name: "Logcat", command: "adb logcat --pid=$(adb shell pidof -s com.a.b)"),
        ]
        let left = commands(dir, existing: existing)
        #expect(left == ["php artisan serve", "php artisan queue:work", "./gradlew assembleDebug", "./gradlew testDebugUnitTest", "./gradlew lint"])
    }
}
