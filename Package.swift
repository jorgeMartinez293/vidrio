// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LiquidTerminal",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
         .package(path: "Vendor/SwiftTerm"),
    ],
    targets: [
        .executableTarget(
            name: "LiquidTerminal",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        // NOTE: This machine has Command Line Tools only (no Xcode), so the
        // Swift Testing framework isn't on the default search path. These
        // unsafeFlags point the test target at the CLT-bundled Testing
        // framework; without them `import Testing` fails to resolve
        // ("no such module 'Testing'"). If this is ever built on a machine
        // with Xcode (or consumed as a library dependency), these flags must
        // be removed/adjusted.
        .testTarget(
            name: "LiquidTerminalTests",
            dependencies: ["LiquidTerminal"],
            swiftSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        ),
    ]
)
