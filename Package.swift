// swift-tools-version: 5.9
//
// Tools version 5.9 (not 6.0) on purpose: GitHub's macos-14 runners ship Swift 5.10, and
// a 6.0 manifest is rejected outright there ("package is using Swift tools version 6.0.0
// but the installed version is 5.10.0"). 5.9 also means the default language mode is
// Swift 5, which is what this code wants — the Accessibility and CoreGraphics APIs are
// not annotated for Swift 6 strict concurrency. The package still builds fine on Swift 6
// toolchains; CI proves the 5.10 path.
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
        // executable so the assertion suite can run inside the binary.
        .target(
            name: "DshCuaCore",
            path: "Sources/DshCuaCore"
        ),
        .executableTarget(
            name: "dsh-cua",
            dependencies: ["DshCuaCore"],
            path: "Sources/dsh-cua"
        ),
        // NOTE: there is deliberately no XCTest target. This package must build on a
        // Command Line Tools-only machine, where the `XCTest` module does not exist and
        // `swift test` cannot compile. The same assertions live in DshCuaCore/SelfTest.swift
        // and run via `dsh-cua selftest` (see Makefile `test`).
    ]
)
