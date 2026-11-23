// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "peaktime",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PeakTimeCore"),
        .executableTarget(
            name: "peaktime",
            dependencies: ["PeakTimeCore"],
            // Catálogo de cadenas: la app habla el idioma del sistema (es/en).
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "PeakTimeCoreTests",
            dependencies: ["PeakTimeCore"]
        )
    ]
)
