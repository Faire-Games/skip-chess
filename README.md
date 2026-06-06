# SkipChess

A complete cross-platform chess library for [Skip](https://skip.dev) projects:
chess model, generic engine protocols, and a bundled alpha-beta engine using
PeSTO evaluation. Builds natively for Swift on iOS/macOS and transpiles
losslessly to Kotlin for Android.

The package is organized as four modules:

| Module                       | Purpose |
|------------------------------|---------|
| `SkipChessModel`             | Chess rules, board state, move generation, FEN, game model. |
| `SkipChessEngine`            | Generic engine protocols (`ChessEngine`, `PositionEvaluator`, …) and reference utilities. |
| `SkipChessEngineAlphaBeta`   | Alpha-beta search with PeSTO evaluation, iterative deepening, TT, killer moves, quiescence. |
| `SkipChess`                  | Umbrella module re-exporting all of the above (use `import SkipChess` to get everything). |

## Installation

Add the package to your `Package.swift` and pick the modules you need:

```swift
dependencies: [
    .package(url: "https://github.com/Faire-Games/skip-chess.git", "0.0.0"..<"2.0.0"),
],
targets: [
    .target(name: "MyChessApp", dependencies: [
        .product(name: "SkipChess", package: "skip-chess"),  // everything in one import
        // or, à la carte:
        // .product(name: "SkipChessModel", package: "skip-chess"),
        // .product(name: "SkipChessEngineAlphaBeta", package: "skip-chess"),
    ]),
]
```

## Quick Start

```swift
import SkipChess

// Create a game from the standard starting position.
let game = Game()

// Play 1. e4 by parsing UCI notation.
let move = Move.fromUCI("e2e4")!
game.play(move)

// Ask the bundled engine for Black's best reply.
let engine = AlphaBetaEngine()
let result = engine.findBestMove(from: game.board, depth: 5)
if let bestMove = result.bestMove {
    print("Engine recommends: \(bestMove.uci) (eval: \(result.evaluation))")
    game.play(bestMove)
}

// Inspect game state.
print(FEN.serialize(game.board))
if let outcome = game.result() {
    print("Game over: \(outcome)")
}
```

## The Chess Model (`SkipChessModel`)

`SkipChessModel` is the foundation: a complete, mutable chess position with
every rule of standard chess enforced.

### Board, Moves, and Game State

```swift
let board = Board.standardStartingPosition()
print(board.sideToMove)             // .white
print(board.legalMoves().count)     // 20

let e4 = Move(from: Square.parse("e2"), to: Square.parse("e4"))
let undo = board.makeMove(e4)
print(board.sideToMove)             // .black
board.unmakeMove(undo)              // restore previous position
```

`Board` supports incremental Zobrist hashing (`board.zobristKey`) so it
plugs directly into a transposition table.

### FEN Parsing

```swift
let board = FEN.parse("r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3")!
print(FEN.serialize(board))         // round-trip
```

### Every rule is supported

The model implements all the rules a real chess client needs, including the
"esoteric" ones that simpler implementations get wrong:

* **Castling**: kingside / queenside for both colors, with full check on
  rights, intervening pieces, king-in-check, and king-through-check.
* **En passant**: only on the immediately following half-move, with the
  full pin-detection check so an en-passant capture that would expose your
  own king is rejected.
* **Pawn promotion**: four-way (queen / rook / bishop / knight) for forward
  and capture promotions.
* **Threefold and fivefold repetition**: tracked by `Game` via Zobrist hash
  counts.
* **Fifty-move and seventy-five-move rules**: tracked via the half-move
  clock; `Game.canClaimDraw()` returns the FIDE claim status, while
  `Game.result()` enforces the automatic 75-move and fivefold rules.
* **Insufficient material**: K vs K, K+B vs K, K+N vs K, K+B vs K+B with
  same-color bishops — all recognized.

### Game-Level Tracking

```swift
let game = Game()
game.play(Move.fromUCI("e2e4")!)
game.play(Move.fromUCI("e7e5")!)

print(game.moveHistory.count)            // 2
game.undoLastMove()
print(game.moveHistory.count)            // 1

if game.canClaimDraw() {
    // Surface a "Claim draw" button in the UI.
}
```

## Generic Engine Protocols (`SkipChessEngine`)

`SkipChessEngine` is the integration point a chess application uses to
obtain best-move recommendations. Concrete engines plug in by conforming to
`ChessEngine`:

```swift
public protocol ChessEngine {
    var name: String { get }
    var version: String { get }

    func findBestMove(
        from board: Board,
        limits: SearchLimits,
        control: SearchControl?,
        listener: SearchProgressListener?
    ) -> SearchResult
}
```

Convenience extensions provide short-hand overloads:

```swift
let result = engine.findBestMove(from: board, depth: 6)
let result = engine.findBestMove(from: board, limits: .time(milliseconds: 500))
```

### Search Limits

```swift
SearchLimits.unlimited                            // search until external stop
SearchLimits.depth(6)                             // fixed depth
SearchLimits.time(milliseconds: 1000)             // 1-second clock
SearchLimits.nodes(1_000_000)                     // node budget
SearchLimits(maxDepth: 10, maxMilliseconds: 250)  // any combination
```

### Cancellation

```swift
let control = SearchControl()
DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
    control.requestStop()  // pollable flag the engine checks periodically
}
let result = engine.findBestMove(
    from: board,
    limits: .depth(20),
    control: control,
    listener: nil
)
```

### Progress Listener

```swift
final class ConsoleLogger: SearchProgressListener {
    func didCompleteIteration(result: SearchResult) {
        print("depth=\(result.info.depth) " +
              "nodes=\(result.info.nodesSearched) " +
              "score=\(result.evaluation) " +
              "best=\(result.bestMove?.uci ?? "-")")
    }
}

_ = engine.findBestMove(
    from: board,
    limits: .depth(8),
    control: nil,
    listener: ConsoleLogger()
)
```

### Search Result

```swift
public struct SearchResult {
    public let bestMove: Move?
    public let evaluation: SearchEvaluation     // .score / .mateForCurrentSide / .mateAgainstCurrentSide
    public let principalVariation: [Move]
    public let info: SearchInfo                  // depth, nodes, time, nps
}
```

## The Bundled Engine (`SkipChessEngineAlphaBeta`)

`AlphaBetaEngine` is a production-grade chess engine:

* Negamax alpha-beta search with iterative deepening.
* PeSTO tapered evaluation using the integer piece-square tables published at
  [chessprogramming.org](https://www.chessprogramming.org/PeSTO%27s_Evaluation_Function).
* Transposition table with depth/bound entries and TT-move ordering.
* MVV-LVA capture ordering, killer move slots, and a history heuristic.
* Quiescence search to neutralize the horizon effect.
* Cooperative cancellation and per-depth progress callbacks.

```swift
let engine = AlphaBetaEngine()
let result = engine.findBestMove(from: board, depth: 6)

print(result.bestMove!.uci)                       // e.g. "g1f3"
print(result.evaluation)                          // e.g. .score(centipawns: 18)
print(result.principalVariation.map(\.uci))       // e.g. ["g1f3", "g8f6", "d2d4"]
print(result.info.nodesPerSecond)                 // e.g. 850_000
```

You can swap in a different evaluator:

```swift
let engine = AlphaBetaEngine(
    evaluator: MaterialOnlyEvaluator(),
    transpositionTableEntries: 1 << 18
)
```

## Implementing a Custom Engine

Adding your own engine — for example to integrate a neural network, an
opening book, or a different search strategy — is straightforward. Just
conform to `ChessEngine`:

```swift
import SkipChessModel
import SkipChessEngine

/// A toy engine that always grabs the highest-value capture if one exists,
/// otherwise picks the first legal move.
public final class GreedyEngine: ChessEngine {

    public let name: String = "Greedy"
    public let version: String = "1.0.0"

    public init() {}

    public func findBestMove(
        from board: Board,
        limits: SearchLimits,
        control: SearchControl?,
        listener: SearchProgressListener?
    ) -> SearchResult {
        let moves = board.legalMoves()
        if moves.isEmpty {
            let eval: SearchEvaluation = board.isCheck()
                ? .mateAgainstCurrentSide(inMoves: 0)
                : .score(centipawns: 0)
            return SearchResult(
                bestMove: nil,
                evaluation: eval,
                principalVariation: [],
                info: SearchInfo(depth: 0, selectiveDepth: 0, nodesSearched: 0, elapsedMilliseconds: 0)
            )
        }

        var bestMove = moves[0]
        var bestVictimValue = -1
        for move in moves {
            let victim = board.pieceCode(at: move.to)
            let value = pieceValue(of: victim)
            if value > bestVictimValue {
                bestVictimValue = value
                bestMove = move
            }
        }

        let result = SearchResult(
            bestMove: bestMove,
            evaluation: .score(centipawns: 0),
            principalVariation: [bestMove],
            info: SearchInfo(depth: 1, selectiveDepth: 1, nodesSearched: Int64(moves.count), elapsedMilliseconds: 0)
        )
        listener?.didCompleteIteration(result: result)
        return result
    }

    private func pieceValue(of code: Int) -> Int {
        switch PieceCode.kind(code) {
        case 1: return 100     // pawn
        case 2: return 320     // knight
        case 3: return 330     // bishop
        case 4: return 500     // rook
        case 5: return 900     // queen
        case 6: return 20000   // king
        default: return 0
        }
    }
}
```

That's the entire integration. Your engine slots into the same call sites
as `AlphaBetaEngine`:

```swift
let game = Game()
let engine: ChessEngine = GreedyEngine()
if let move = engine.findBestMove(from: game.board, depth: 1).bestMove {
    game.play(move)
}
```

### Reusing the Evaluator Protocol

`PositionEvaluator` is a separate protocol so search and evaluation can
evolve independently. A custom evaluator just needs to return a centipawn
score from the side-to-move perspective:

```swift
public final class MyHeuristicEvaluator: PositionEvaluator {
    public init() {}
    public func evaluate(board: Board) -> Int {
        // ... your scoring logic ...
        return 0
    }
}
```

You can then pair it with the bundled alpha-beta search:

```swift
let engine = AlphaBetaEngine(evaluator: MyHeuristicEvaluator())
```

## Building

This project is a Swift Package Manager module that uses the
[Skip](https://skip.dev) plugin to build the package for both iOS and Android.

```bash
swift build         # compiles Swift and transpiles to Kotlin
swift test          # runs Swift Testing suites + Robolectric-hosted Kotlin tests
```

The test suites cover:

* **Model** (93 tests) — piece encoding, FEN parsing, every move-generation
  rule, including pinned pieces, castling restrictions, en-passant pin
  detection, promotion (forward and capture, including underpromotion),
  perft tables for the standard test positions verified to depth 4 (197,281
  nodes from the starting position), insufficient-material draws,
  repetition / fifty-move rule, UCI round-tripping.
* **Engine protocols** (24 tests) — `SearchLimits`, `SearchControl`,
  `SearchResult` semantics, material baseline evaluator, the `RandomEngine`
  reference implementation.
* **Alpha-beta engine** (42 tests) — PeSTO table values verified against
  the published tables, transposition table store/probe and compact move
  encoding, end-to-end tactical positions (mate in one, back-rank mate,
  K+Q vs K endgame doesn't stalemate, hanging-piece capture, doesn't-hang-
  own-piece, blunder-resistance in the opening, underpromotion legality),
  time/depth/node limits, external abort, progress listener invocation,
  principal-variation legality, engine-vs-itself game that verifies no
  illegal move is ever proposed across many half-moves.
* **Umbrella module** (6 tests) — re-exports work, end-to-end engine game.

Parity testing can be performed with `skip test`, which will output a
table of the test results for both platforms.

## Genesis

This skip.dev project was created with the command:

```
skip init --transpiled-model --free skip-chess SkipChess SkipChessModel SkipChessEngine SkipChessEngineAlphaBeta
```

Then it was implemented by Claude Code with the following prompt:

> This is a skip.dev SwiftPM project. Implement a chess model in the
  SkipChessModel module that can be plugged into a real chess game and models
  the pieces and ALL the rules of the game (including all the esoteric rules).
  Implement generic support for a chess engine in the SkipChessEngine module
  that depends on SkipChessModel and provides generic protocols that can be
  implemented by a variety of different chess engine strategies. And in the
  SkipChessEngineAlphaBeta module that depends on SkipChessEngine, implement
  an Alpha-Beta Engine with PeSTO Evaluation with the integer tables from
  https://www.chessprogramming.org/PeSTO's_Evaluation_Function. For each
  module, implement comprehensive test cases and ensure that they pass with
  `swift test`. Be mindful that as a transpiled skip.dev project, the code
  will all be transpiled into Kotlin, and so you should be careful to not use
  any Swift features (like macros) that are not supported by skip.dev. Also be
  mindful of efficiency, since the Kotlin side will be running on Android in
  a JVM, and so will suffer from garbage collection and high memory
  watermarks, so make the chess engine implementation as performant as
  possible. Make the test cases comprehensive and try to cover all the bases,
  like ensuring that illegal moves are not permitted and that the
  SkipChessEngineAlphaBeta does not ever propose illegal moves and doesn't do
  anything especially foolish. The SkipChess module itself should be an
  umbrella module that includes the other modules. Update the README.md with
  API examples of how to use the engine, and how a separate package might
  implement their own SkipChessEngine and plug it into a game. Every step of
  the way, run `swift test`, as that will exercise the test cases both on the
  native Swift and transpiled Kotlin side and will identify any compile and
  logic errors along the way. Take as long as you need to implement the
  project in a deep and sophisiticated way. Do not pause to ask questions or
  take breaks, but continue working until you have a complete,
  well-documented, throroughly researched implementation and an elegant API
  that can be imported and used by an actual chess app.
  
## License

This software is licensed under the
[Mozilla Public License 2.0](https://www.mozilla.org/MPL/).
