// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IntegrityMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "raid-integrity-monitor", targets: ["IntegrityMonitorCLI"]),
    ],
    targets: [
        // Vendored BLAKE3 C reference implementation (CC0 / Apache 2.0)
        .target(
            name: "CBLAKE3",
            path: "Sources/CBLAKE3",
            publicHeadersPath: "include",
            cSettings: [
                .define("BLAKE3_USE_NEON", to: "1")
            ]
        ),
        // All business logic — library so the test target can import it
        .target(
            name: "IntegrityMonitor",
            dependencies: ["CBLAKE3"],
            path: "Sources/IntegrityMonitor",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        // Thin entry point — just main.swift
        .executableTarget(
            name: "IntegrityMonitorCLI",
            dependencies: ["IntegrityMonitor"],
            path: "Sources/IntegrityMonitorCLI"
        ),
        // Notification helper app bundle binary
        .executableTarget(
            name: "NotifyHelper",
            path: "NotifyHelper",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .testTarget(
            name: "IntegrityMonitorTests",
            dependencies: ["IntegrityMonitor"],
            path: "Tests/IntegrityMonitorTests",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
