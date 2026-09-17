// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Shortcut",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Shortcut", targets: ["AnswerCircle"])
    ],
    targets: [
        .executableTarget(
            name: "AnswerCircle",
            path: "Sources/AnswerCircle",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AnswerCircleTests",
            dependencies: ["AnswerCircle"],
            path: "Tests/AnswerCircleTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
