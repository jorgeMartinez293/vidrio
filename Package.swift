// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Vidrio",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
         .package(path: "Vendor/SwiftTerm"),
         // Sparkle: in-app auto-updates. The Makefile embeds Sparkle.framework
         // into the .app bundle (swift build alone doesn't).
         .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Vidrio",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
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
            name: "VidrioTests",
            dependencies: ["Vidrio"],
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
