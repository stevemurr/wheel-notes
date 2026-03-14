// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WheelNotes",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(path: "../fabric"),
    ],
    targets: [
        .target(
            name: "WheelSupport",
            dependencies: [],
            path: "Sources/WheelSupport",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "WheelNotesCore",
            dependencies: [
                "WheelSupport",
                .product(name: "Fabric", package: "fabric"),
            ],
            path: "Sources/WheelNotesCore",
            resources: [
                .copy("Resources/NoteEditor"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "WheelNotes",
            dependencies: [
                "WheelSupport",
                "WheelNotesCore",
                .product(name: "Fabric", package: "fabric"),
            ],
            path: "Sources/WheelNotes",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "WheelNotesTests",
            dependencies: [
                "WheelNotes",
                "WheelNotesCore",
                "WheelSupport",
                .product(name: "Fabric", package: "fabric"),
            ],
            path: "Tests/WheelNotesTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
