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
        .executable(name: "SkipChessWeb", targets: ["SkipChessWeb"]),
    ],
    dependencies: [
        .package(url: "https://source.skip.dev/skip.git", from: "1.9.2"),
        .package(url: "https://source.skip.dev/skip-lib.git", from: "1.0.0")
    ],
    targets: [
        .target(name: "SkipChessModel", dependencies: [
            .product(name: "SkipLib", package: "skip-lib")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .testTarget(name: "SkipChessModelTests", dependencies: [
            "SkipChessModel",
            .product(name: "SkipTest", package: "skip")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .target(name: "SkipChessEngine", dependencies: [
            "SkipChessModel"
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .testTarget(name: "SkipChessEngineTests", dependencies: [
            "SkipChessEngine",
            .product(name: "SkipTest", package: "skip")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .target(name: "SkipChessEngineAlphaBeta", dependencies: [
            "SkipChessEngine"
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .testTarget(name: "SkipChessEngineAlphaBetaTests", dependencies: [
            "SkipChessEngineAlphaBeta",
            .product(name: "SkipTest", package: "skip")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .target(name: "SkipChess", dependencies: [
            "SkipChessModel",
            "SkipChessEngine",
            "SkipChessEngineAlphaBeta"
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        .testTarget(name: "SkipChessTests", dependencies: [
            "SkipChess",
            .product(name: "SkipTest", package: "skip")
        ], resources: [.process("Resources")], plugins: [.plugin(name: "skipstone", package: "skip")]),
        // SkipChessWeb is an executable that exposes the engine to JavaScript
        // via a C-compatible WASM ABI. It deliberately depends on its sibling
        // targets directly (not via library products), so SwiftPM links them
        // statically and the WASM toolchain — which can't consume the
        // `type: .dynamic` library products published for iOS/Android — has
        // no trouble producing a single .wasm binary.
        //
        // Build with:
        //     export TOOLCHAINS=org.swift.631202604131a
        //     swift build -c release --swift-sdk swift-6.3.1-RELEASE_wasm \
        //                 --product SkipChessWeb
        .executableTarget(name: "SkipChessWeb", dependencies: [
            "SkipChessModel",
            "SkipChessEngine",
            "SkipChessEngineAlphaBeta"
        ], linkerSettings: [
            // Every @_cdecl entry point must be explicitly exported to the
            // WASM module's exports table — otherwise wasm-ld dead-strips
            // them. Verified empirically: removing these flags builds
            // cleanly but the JS-side smoketest fails immediately with
            // `ex.chess_input_ptr is not a function`. These flags are only
            // consumed by the WASM toolchain; they're harmless when building
            // for macOS/iOS because the link is delegated to a different
            // linker that ignores --export.
            .unsafeFlags([
                "-Xlinker", "--export=chess_input_ptr",
                "-Xlinker", "--export=chess_input_capacity",
                "-Xlinker", "--export=chess_output_ptr",
                "-Xlinker", "--export=chess_output_capacity",
                "-Xlinker", "--export=chess_new_game",
                "-Xlinker", "--export=chess_load_fen",
                "-Xlinker", "--export=chess_current_fen",
                "-Xlinker", "--export=chess_legal_moves",
                "-Xlinker", "--export=chess_legal_moves_from",
                "-Xlinker", "--export=chess_play_move",
                "-Xlinker", "--export=chess_undo_move",
                "-Xlinker", "--export=chess_side_to_move",
                "-Xlinker", "--export=chess_is_check",
                "-Xlinker", "--export=chess_is_checkmate",
                "-Xlinker", "--export=chess_is_stalemate",
                "-Xlinker", "--export=chess_king_square",
                "-Xlinker", "--export=chess_piece_at",
                "-Xlinker", "--export=chess_game_result",
                "-Xlinker", "--export=chess_configure_engine",
                "-Xlinker", "--export=chess_engine_best_move",
                "-Xlinker", "--export=chess_engine_search_summary",
                "-Xlinker", "--export=chess_protocol_init",
                "-Xlinker", "--export=chess_protocol_send",
                "-Xlinker", "--export=chess_protocol_initial_snapshot",
                "-Xlinker", "--export=chess_protocol_pump_engine",
            ], .when(platforms: [.wasi]))
        ]),
    ]
)
