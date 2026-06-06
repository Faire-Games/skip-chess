// swift-tools-version: 6.1
// This is a Skip (https://skip.dev) package.
import PackageDescription

let package = Package(
    name: "skip-chess",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SkipChess", type: .dynamic, targets: ["SkipChess"]),
        .library(name: "SkipChessModel", type: .dynamic, targets: ["SkipChessModel"]),
        .library(name: "SkipChessEngine", type: .dynamic, targets: ["SkipChessEngine"]),
        .library(name: "SkipChessEngineAlphaBeta", type: .dynamic, targets: ["SkipChessEngineAlphaBeta"]),
    ],
    dependencies: [
        .package(url: "https://source.skip.tools/skip.git", from: "1.9.2"),
        .package(url: "https://source.skip.tools/skip-foundation.git", from: "1.0.0")
    ],
    targets: [
        .target(name: "SkipChess", dependencies: [
            "SkipChessModel"
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .testTarget(name: "SkipChessTests", dependencies: [
            "SkipChess",
            .product(name: "SkipTest", package: "skip")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .target(name: "SkipChessModel", dependencies: [
            "SkipChessEngine"
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .testTarget(name: "SkipChessModelTests", dependencies: [
            "SkipChessModel",
            .product(name: "SkipTest", package: "skip")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .target(name: "SkipChessEngine", dependencies: [
            "SkipChessEngineAlphaBeta"
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .testTarget(name: "SkipChessEngineTests", dependencies: [
            "SkipChessEngine",
            .product(name: "SkipTest", package: "skip")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .target(name: "SkipChessEngineAlphaBeta", dependencies: [
            .product(name: "SkipFoundation", package: "skip-foundation")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .testTarget(name: "SkipChessEngineAlphaBetaTests", dependencies: [
            "SkipChessEngineAlphaBeta",
            .product(name: "SkipTest", package: "skip")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
    ]
)
