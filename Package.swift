// swift-tools-version:5.9
import PackageDescription

// The GitHub organization of the suite's repositories: the one name to change should it be renamed (the
// suite repository's scripts/rename-organization.sh does it in every repository).
let organization = "love-suite"

// Viewer: the picture and PDF viewer of the suite, as an app of its own. Explorer hands it pictures and
// PDFs; ViewerCore (no UI, unit-tested) knows the pictures of a folder in Explorer's order.
let package = Package(
    name: "Viewer",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/\(organization)/suite-core", .upToNextMinor(from: "27.1.0-dev.1")),
        .package(url: "https://github.com/\(organization)/suite-files", .upToNextMinor(from: "27.1.0-dev.1")),
    ],
    targets: [
        .target(name: "ViewerCore", dependencies: [.product(name: "SuiteCore", package: "suite-core"), .product(name: "SuiteFilesCore", package: "suite-files")]),
        .testTarget(name: "ViewerCoreTests",
                    dependencies: ["ViewerCore", .product(name: "SuiteCore", package: "suite-core"), .product(name: "SuiteFilesCore", package: "suite-files")]),
        .target(
            name: "ViewerUI",
            dependencies: ["ViewerCore", .product(name: "SuiteCore", package: "suite-core"), .product(name: "SuiteFilesCore", package: "suite-files"), .product(name: "SuiteFilesUI", package: "suite-files")],
            resources: [.process("Resources")],
            linkerSettings: [.linkedFramework("Quartz")]
        ),
        .executableTarget(
            name: "Viewer",
            dependencies: ["ViewerUI", .product(name: "SuiteCore", package: "suite-core"), .product(name: "SuiteFilesCore", package: "suite-files")]
        ),
    ]
)
