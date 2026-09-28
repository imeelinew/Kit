// swift-tools-version:5.9
import PackageDescription

// Scratch CLI that links the REAL production rule classifier
// (Kit/Core/ClipboardTextClassifier.swift, copied verbatim) so its verdicts
// can be compared against the TypeSafe API on identical samples.
let package = Package(
    name: "rules-cli",
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "rules-cli",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")]
        )
    ]
)
