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
        // El sufijo de defaultConfig vale para todas las variantes: la app instalada es com.dizeg.whatsapp.debug.
        #expect(all.map(\.command) == [
            "./gradlew assembleDebug", "./gradlew installDebug", "./gradlew testDebugUnitTest", "./gradlew lint",
            "adb logcat --pid=$(adb shell pidof -s com.dizeg.whatsapp.debug)",
        ])
        #expect(all.map(\.name) == ["Compilar debug", "Instalar en el teléfono", "Tests", "Lint", "Logcat de la app"])
        #expect(CommandSuggestions.androidApplicationId(projectPath: dir.path) == "com.dizeg.whatsapp")
    }

    /// Como los proyectos reales del usuario: sabores con sufijo, cadenas con `${…}` y llaves en comentarios.
    static let flavoredKotlin = #"""
    android {
        namespace = "com.dizeg.mobile"
        defaultConfig {
            applicationId = "com.dizeg.mobile"
            buildConfigField("String", "WEB_BASE_URL", "\"https://dizeg.com\"")
        }
        // Una llave suelta en un comentario: }
        flavorDimensions += "environment"
        productFlavors {
            create("demo") {
                dimension = "environment"
                applicationIdSuffix = ".demo"
                buildConfigField("String", "DEV_EMAIL", "\"${devPropEscaped("dev.email")}\"")
            }
            create("local") {
                dimension = "environment"
                applicationIdSuffix = ".local"
                buildConfigField("String", "X", "\"{\"")
            }
            create("prod") {
                dimension = "environment"
            }
        }
        productFlavors.configureEach {
            buildConfigField("boolean", "FIREBASE_ENABLED", "true")
        }
        buildTypes {
            debug {
                enableUnitTestCoverage = true
            }
            release {
                isDebuggable = false
            }
        }
    }
    """#

    @Test("Android con sabores: las tareas y el id llevan el sabor del día a día («local»)")
    func androidFlavors() throws {
        let dir = TempDir()
        dir.write("gradlew")
        dir.write("app/build.gradle.kts", Self.flavoredKotlin)
        let app = try #require(AndroidApp.read(projectPath: dir.path))
        #expect(app.applicationId == "com.dizeg.mobile")
        #expect(app.flavors.map(\.name) == ["demo", "local", "prod"])
        #expect(app.flavors.map(\.suffix) == [".demo", ".local", ""])
        #expect(app.debugVariant == AndroidApp.Variant(flavor: "local", applicationId: "com.dizeg.mobile.local"))
        let all = CommandSuggestions.detect(projectPath: dir.path)
        #expect(all.map(\.command) == [
            "./gradlew assembleDebug", "./gradlew installLocalDebug", "./gradlew testLocalDebugUnitTest", "./gradlew lint",
            "adb logcat --pid=$(adb shell pidof -s com.dizeg.mobile.local)",
        ])
        #expect(all.map(\.name) == ["Compilar debug", "Instalar en el teléfono (local)", "Tests (local)", "Lint", "Logcat de la app (local)"])
    }

    @Test("Groovy: sin «local» usa el primer sabor y suma el sufijo de debug (con o sin punto)")
    func androidGroovyFlavorsAndDebugSuffix() {
        let app = AndroidApp.parse("""
        android {
            defaultConfig {
                applicationId 'ar.emplag.app'
            }
            buildTypes {
                release { minifyEnabled true }
                debug {
                    applicationIdSuffix 'debug'
                }
            }
            productFlavors {
                gratis {
                    dimension 'plan'
                    applicationIdSuffix '.gratis'
                }
                pago {
                    dimension 'plan'
                    applicationId 'ar.emplag.pago'
                }
            }
        }
        """)
        #expect(app.debugSuffix == "debug")
        #expect(app.debugVariant == AndroidApp.Variant(flavor: "gratis", applicationId: "ar.emplag.app.gratis.debug"))
        let pago = AndroidApp(applicationId: app.applicationId, debugSuffix: app.debugSuffix, flavors: Array(app.flavors.reversed()))
        #expect(pago.debugVariant?.applicationId == "ar.emplag.pago.debug") // el sabor puede tener su propio id
    }

    @Test("Sin sabores, el sufijo de debug también va en el logcat")
    func androidDebugSuffix() {
        let app = AndroidApp.parse("""
        android {
            namespace = "com.app"
            defaultConfig { applicationId = "com.app.id" }
            buildTypes { getByName("debug") { applicationIdSuffix = ".dev" } }
        }
        """)
        #expect(CommandSuggestions.gradleSuggestions(app).map(\.command) == [
            "./gradlew assembleDebug", "./gradlew installDebug", "./gradlew testDebugUnitTest", "./gradlew lint",
            "adb logcat --pid=$(adb shell pidof -s com.app.id.dev)",
        ])
    }

    @Test("Sabores de varias dimensiones: no adivina la variante y sugiere solo compilar y lint")
    func androidMultipleDimensions() {
        let app = AndroidApp.parse("""
        android {
            defaultConfig { applicationId = "com.app" }
            productFlavors {
                create("free") { dimension = "plan" }
                create("arm") { dimension = "abi" }
            }
        }
        """)
        #expect(app.debugVariant == nil)
        #expect(CommandSuggestions.gradleSuggestions(app).map(\.command) == ["./gradlew assembleDebug", "./gradlew lint"])
    }

    @Test("Los comentarios y las cadenas no cuentan como llaves")
    func gradleMasking() {
        let text = GradleText(#"a { "}" /* } */ b("${x { "}" }}") // }"# + "\n}")
        #expect(text.blocks(named: "a").count == 1)
        #expect(text.closing(2) == text.bytes.count - 1)
        #expect(GradleText.childName("\n  // comentario\n  create(\"local\") ") == "local")
        #expect(GradleText.childName("debug") == "debug")
        #expect(GradleText.childName("all") == nil)
        #expect(GradleText.childName("if (x)") == nil)
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
        #expect(commands(dir) == ["php artisan serve", "php artisan queue:listen --tries=1", "php artisan test", "php artisan pail"])
    }

    @Test("Laravel sin pail no sugiere los logs")
    func laravelWithoutPail() {
        let dir = TempDir()
        dir.write("artisan")
        dir.write("composer.json", #"{"require": {"laravel/framework": "^12.0"}}"#)
        #expect(commands(dir) == ["php artisan serve", "php artisan queue:listen --tries=1", "php artisan test"])
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
        #expect(left == ["php artisan serve", "php artisan queue:listen --tries=1", "./gradlew assembleDebug", "./gradlew testDebugUnitTest", "./gradlew lint"])
    }
}
