// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hive",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hive", targets: ["Hive"]),
        .library(name: "HiveCore", targets: ["HiveCore"]),
        .library(name: "HiveKit", targets: ["HiveKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        // Actualizaciones automáticas (solo el ejecutable: HiveKit y los tests no la cargan).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        // Dominio, lógica pura e infraestructura sin UI. Concurrencia estricta de Swift 6.
        .target(
            name: "HiveCore",
            path: "Sources/HiveCore"
        ),
        // Estado de la app, terminal, servicios del sistema y vistas (SwiftUI/AppKit). También Swift 6 estricto.
        .target(
            name: "HiveKit",
            dependencies: [
                "HiveCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/HiveKit"
        ),
        // Punto de entrada de la app.
        .executableTarget(
            name: "Hive",
            dependencies: [
                "HiveKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Hive",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle.framework va en Havebee.app/Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "HiveCoreTests",
            dependencies: ["HiveCore"],
            path: "Tests/HiveCoreTests"
        ),
        .testTarget(
            name: "HiveKitTests",
            dependencies: ["HiveKit", "HiveCore"],
            path: "Tests/HiveKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
