// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dsh-cua",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dsh-cua", targets: ["dsh-cua"]),
        .library(name: "DshCuaCore", targets: ["DshCuaCore"]),
    ],
    targets: [
        // The library holds everything testable. It is deliberately separate from the
        // executable so `swift test` can import it without executable-target quirks.
        .target(
            name: "DshCuaCore",
            path: "Sources/DshCuaCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "dsh-cua",
            dependencies: ["DshCuaCore"],
            path: "Sources/dsh-cua",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // NOTE: there is deliberately no XCTest target. This package must build on a
        // Command Line Tools-only machine, where the `XCTest` module does not exist and
        // `swift test` cannot compile. The same assertions live in DshCuaCore/SelfTest.swift
        // and run via `dsh-cua selftest` (see Makefile `test`).
    ]
)
