// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0
//
// SkipChessWeb exposes a minimal C-compatible WASM API that JavaScript
// uses to drive a chess game and the bundled alpha-beta engine.
//
// String passing convention: the module owns two static byte buffers in
// WASM linear memory.
//
//   - The *input* buffer is written by JavaScript before calling any
//     function that takes a string argument; the function receives the
//     used byte count.
//   - The *output* buffer is written by Swift; functions that return a
//     string return the number of bytes written, and JavaScript reads
//     them back from the buffer pointer.
//
// JS obtains the buffer base pointers once with `chess_input_ptr()` and
// `chess_output_ptr()` (they are stable for the lifetime of the module).

import SkipChessModel
import SkipChessEngine
import SkipChessEngineAlphaBeta

// MARK: - Buffer plumbing

private let inputBufferSize: Int = 4096
private let outputBufferSize: Int = 32768

// WASM is single-threaded; `nonisolated(unsafe)` lets `@_cdecl` entry
// points reach these globals without participating in Swift 6's strict
// concurrency model.
nonisolated(unsafe) private let inputBuffer: UnsafeMutablePointer<UInt8> = {
    let p = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferSize)
    p.initialize(repeating: 0, count: inputBufferSize)
    return p
}()

nonisolated(unsafe) private let outputBuffer: UnsafeMutablePointer<UInt8> = {
    let p = UnsafeMutablePointer<UInt8>.allocate(capacity: outputBufferSize)
    p.initialize(repeating: 0, count: outputBufferSize)
    return p
}()

private func readInput(_ length: Int32) -> String {
    let n = max(0, min(Int(length), inputBufferSize))
    let buffer = UnsafeBufferPointer(start: inputBuffer, count: n)
    return String(decoding: buffer, as: UTF8.self)
}

private func writeOutput(_ string: String) -> Int32 {
    var written = 0
    for byte in string.utf8 {
        if written >= outputBufferSize {
            break
        }
        outputBuffer[written] = byte
        written = written + 1
    }
    return Int32(written)
}

// MARK: - Engine state (singleton per WASM instance)

private final class Session {
    var game: Game = Game()
    let engine: AlphaBetaEngine = AlphaBetaEngine()

    // Configurable engine parameters chosen via `chess_configure_engine`.
    var depthLimit: Int = 4
    var timeLimitMs: Int64 = -1
    var nodeLimit: Int64 = -1

    // Lichess-style round-protocol session. Lazily rebuilt whenever the
    // game is reset so the version counter starts fresh.
    var round: RoundSession = RoundSession(
        game: Game(),
        configuration: RoundConfiguration(),
    )

    /// Replaces the underlying game and rebuilds the round session.
    /// `initialClockSeconds` of `nil` means an untimed game; positive
    /// values switch the session into timed mode and the engine's
    /// per-move budget will scale against the engine's remaining clock.
    func resetRound(
        humanColor: PieceColor,
        depth: Int,
        timeMs: Int,
        initialClockSeconds: Double?,
        clockIncrementSeconds: Double,
    ) {
        // Both colours are configured to whatever the JS UI picks; we
        // attach the engine for the *opposite* of the human's colour so
        // the round session auto-replies for the engine.
        let engineColor: PieceColor = humanColor == PieceColor.white ? PieceColor.black : PieceColor.white
        let limits = SearchLimits(
            maxDepth: depth, maxNodes: nil,
            maxMilliseconds: timeMs > 0 ? Int64(timeMs) : nil)
        round = RoundSession(
            game: game,
            configuration: RoundConfiguration(
                engineColor: engineColor,
                engineLimits: limits,
                initialClockSeconds: initialClockSeconds,
                clockIncrementSeconds: clockIncrementSeconds,
            ),
            engine: engine,
        )
    }
}

nonisolated(unsafe) private let session = Session()

// MARK: - Buffer accessors

@_cdecl("chess_input_ptr")
public func chess_input_ptr() -> Int32 {
    return Int32(Int(bitPattern: inputBuffer))
}

@_cdecl("chess_input_capacity")
public func chess_input_capacity() -> Int32 {
    return Int32(inputBufferSize)
}

@_cdecl("chess_output_ptr")
public func chess_output_ptr() -> Int32 {
    return Int32(Int(bitPattern: outputBuffer))
}

@_cdecl("chess_output_capacity")
public func chess_output_capacity() -> Int32 {
    return Int32(outputBufferSize)
}

// MARK: - Game lifecycle

/// Resets the game state to the standard starting position.
@_cdecl("chess_new_game")
public func chess_new_game() -> Int32 {
    session.game = Game()
    session.engine.transpositionTable.clear()
    return 0
}

/// Loads a FEN string from the input buffer (length given) into the game.
/// Returns 0 on success, -1 if the FEN is malformed.
@_cdecl("chess_load_fen")
public func chess_load_fen(_ length: Int32) -> Int32 {
    let fen = readInput(length)
    guard let g = Game.fromFEN(fen) else {
        return -1
    }
    session.game = g
    session.engine.transpositionTable.clear()
    return 0
}

/// Writes the current position's FEN into the output buffer. Returns the
/// byte length.
@_cdecl("chess_current_fen")
public func chess_current_fen() -> Int32 {
    return writeOutput(session.game.currentFEN())
}

// MARK: - Move queries / playback

/// Writes a space-separated UCI list of legal moves into the output
/// buffer. Returns the byte length (0 if no legal moves).
@_cdecl("chess_legal_moves")
public func chess_legal_moves() -> Int32 {
    let moves = session.game.board.legalMoves()
    var out = ""
    for (i, m) in moves.enumerated() {
        if i > 0 {
            out += " "
        }
        out += m.uci
    }
    return writeOutput(out)
}

/// Writes a space-separated UCI list of legal moves whose source square
/// matches the given square index (0..63). Useful for highlighting valid
/// destination squares as a user selects a piece.
@_cdecl("chess_legal_moves_from")
public func chess_legal_moves_from(_ square: Int32) -> Int32 {
    let sq = Int(square)
    var out = ""
    var first = true
    for m in session.game.board.legalMoves() where m.from == sq {
        if !first {
            out += " "
        }
        out += m.uci
        first = false
    }
    return writeOutput(out)
}

/// Plays the UCI move sitting in the input buffer. Returns 0 if the move
/// was accepted, -1 if it was illegal in the current position.
@_cdecl("chess_play_move")
public func chess_play_move(_ length: Int32) -> Int32 {
    let uci = readInput(length)
    guard let move = Move.fromUCI(uci) else {
        return -1
    }
    return session.game.play(move) ? 0 : -1
}

/// Undoes the most recently played move. Returns 0 on success, -1 if
/// there's no move to undo.
@_cdecl("chess_undo_move")
public func chess_undo_move() -> Int32 {
    return session.game.undoLastMove() ? 0 : -1
}

// MARK: - Position state

/// Whose turn it is: 0 for white, 1 for black.
@_cdecl("chess_side_to_move")
public func chess_side_to_move() -> Int32 {
    return Int32(session.game.board.sideToMove.rawValue)
}

/// `1` if the side to move is in check, `0` otherwise.
@_cdecl("chess_is_check")
public func chess_is_check() -> Int32 {
    return session.game.board.isCheck() ? 1 : 0
}

/// `1` if the side to move has been checkmated, `0` otherwise.
@_cdecl("chess_is_checkmate")
public func chess_is_checkmate() -> Int32 {
    return session.game.board.isCheckmate() ? 1 : 0
}

/// `1` if the side to move has been stalemated, `0` otherwise.
@_cdecl("chess_is_stalemate")
public func chess_is_stalemate() -> Int32 {
    return session.game.board.isStalemate() ? 1 : 0
}

/// Returns the king's square (0..63) for the given color, or `-1` if
/// the board has no king of that color.
@_cdecl("chess_king_square")
public func chess_king_square(_ color: Int32) -> Int32 {
    let c: PieceColor = color == 0 ? .white : .black
    return Int32(session.game.board.kingSquare(of: c))
}

/// Returns the piece code (PieceCode encoding) at the given square,
/// or 0 if the square is empty.
@_cdecl("chess_piece_at")
public func chess_piece_at(_ square: Int32) -> Int32 {
    let sq = Int(square)
    if sq < 0 || sq >= 64 {
        return 0
    }
    return Int32(session.game.board.pieceCode(at: sq))
}

/// Encodes the current game result as an integer.
/// `0` — game in progress.
/// `1` — white wins by checkmate.
/// `2` — black wins by checkmate.
/// `3` — stalemate draw.
/// `4` — insufficient-material draw.
/// `5` — 50-move-rule claim available (and reached) or 75-move automatic.
/// `6` — threefold repetition claim available or fivefold automatic.
@_cdecl("chess_game_result")
public func chess_game_result() -> Int32 {
    switch session.game.result() {
    case .none:
        if session.game.canClaimDraw() {
            if session.game.board.halfmoveClock >= 100 {
                return 5
            }
            if session.game.currentPositionRepetitionCount() >= 3 {
                return 6
            }
        }
        return 0
    case .whiteWins:
        return 1
    case .blackWins:
        return 2
    case .draw(let reason):
        switch reason {
        case .stalemate: return 3
        case .insufficientMaterial: return 4
        case .fiftyMoveRule, .seventyFiveMoveRule: return 5
        case .threefoldRepetition, .fivefoldRepetition: return 6
        case .agreement: return 4
        }
    }
}

// MARK: - Engine search

/// Configures the engine's per-move search budget.
///  - `depth`: maximum search depth in plies (clamped to `>= 1`)
///  - `timeMs`: wall-clock budget in milliseconds (use a negative value
///    to disable the time bound)
///  - `nodes`: node budget (use a negative value to disable)
@_cdecl("chess_configure_engine")
public func chess_configure_engine(_ depth: Int32, _ timeMs: Int32, _ nodes: Int32) -> Int32 {
    session.depthLimit = max(1, Int(depth))
    session.timeLimitMs = timeMs < 0 ? -1 : Int64(timeMs)
    session.nodeLimit = nodes < 0 ? -1 : Int64(nodes)
    return 0
}

/// Runs the alpha-beta engine on the current position and writes the
/// best move's UCI notation into the output buffer. Returns the number of
/// bytes written, or 0 if no legal move exists (game over).
@_cdecl("chess_engine_best_move")
public func chess_engine_best_move() -> Int32 {
    let limits = SearchLimits(
        maxDepth: session.depthLimit,
        maxNodes: session.nodeLimit < 0 ? nil : session.nodeLimit,
        maxMilliseconds: session.timeLimitMs < 0 ? nil : session.timeLimitMs
    )
    let result = session.engine.findBestMove(from: session.game.board, limits: limits, control: nil, listener: nil)
    guard let move = result.bestMove else {
        return 0
    }
    return writeOutput(move.uci)
}

/// Writes a small JSON-ish summary of the most recent search into the
/// output buffer: depth, nodes, milliseconds, centipawn score, mate flag.
/// Format (UTF-8, no whitespace except after colons/commas):
///   `{"depth":N,"nodes":N,"ms":N,"score":N,"mate":N}`
/// where `mate` is `0` for a normal score, a positive count for "mate
/// in N for the side to move", or a negative count for "mate against the
/// side to move".
@_cdecl("chess_engine_search_summary")
public func chess_engine_search_summary() -> Int32 {
    let limits = SearchLimits(
        maxDepth: session.depthLimit,
        maxNodes: session.nodeLimit < 0 ? nil : session.nodeLimit,
        maxMilliseconds: session.timeLimitMs < 0 ? nil : session.timeLimitMs
    )
    let result = session.engine.findBestMove(from: session.game.board, limits: limits, control: nil, listener: nil)
    let mateField: Int
    let scoreField: Int
    switch result.evaluation {
    case .score(let cp):
        mateField = 0
        scoreField = cp
    case .mateForCurrentSide(let n):
        mateField = n
        scoreField = 30000
    case .mateAgainstCurrentSide(let n):
        mateField = -n
        scoreField = -30000
    }
    let bestMoveUCI = result.bestMove?.uci ?? ""
    let json = "{\"depth\":\(result.info.depth)," +
        "\"nodes\":\(result.info.nodesSearched)," +
        "\"ms\":\(result.info.elapsedMilliseconds)," +
        "\"score\":\(scoreField)," +
        "\"mate\":\(mateField)," +
        "\"best\":\"\(bestMoveUCI)\"}"
    return writeOutput(json)
}

// MARK: - Lichess-style round protocol
//
// The functions below expose a thin JSON-over-buffers transport for the
// ``RoundSession`` state machine. The same JS client can talk to a real
// Lichess back-end (where the wire is wrapped in a WebSocket) by swapping
// the WASM-backed `send` / `drain` calls for a `socket.send` / event
// listener; the on-the-wire format is identical.

/// Configures (or reconfigures) the round session against the current
/// game state. The caller is expected to set up the position first via
/// ``chess_new_game()`` or ``chess_load_fen(_:)``.
///   - `humanColorInt`: 0 = white, 1 = black. The engine plays the other
///     colour and auto-replies in the same `flush`.
///   - `depth`: engine search depth (plies, must be ≥ 1).
///   - `timeMs`: engine wall-clock budget per move in milliseconds; pass
///     a negative value to disable the time bound.
///   - `initialClockMs`: starting clock for both sides in ms; negative
///     for an untimed game.
///   - `incrementMs`: per-move increment in ms.
@_cdecl("chess_protocol_init")
public func chess_protocol_init(
    _ humanColorInt: Int32,
    _ depth: Int32,
    _ timeMs: Int32,
    _ initialClockMs: Int32,
    _ incrementMs: Int32,
) -> Int32 {
    session.engine.transpositionTable.clear()
    let humanColor: PieceColor = humanColorInt == 0 ? PieceColor.white : PieceColor.black
    let initialClock: Double? = initialClockMs >= 0
        ? Double(initialClockMs) / 1000.0
        : nil
    let increment: Double = Double(max(Int32(0), incrementMs)) / 1000.0
    session.resetRound(
        humanColor: humanColor,
        depth: max(1, Int(depth)),
        timeMs: Int(timeMs),
        initialClockSeconds: initialClock,
        clockIncrementSeconds: increment,
    )
    return 0
}

/// Sends a wire string (already written into the input buffer with the
/// given byte length). Server-side replies are written into the output
/// buffer as `\n`-separated wire strings (the `\n` separator is safe
/// because every reply is a JSON object on a single line). Returns the
/// number of bytes written to the output buffer.
///
/// The engine's auto-reply is *not* run inline: instead the caller is
/// expected to make a follow-up `chess_protocol_pump_engine()` call once
/// it has rendered the user's move. That gives the JS UI a chance to
/// paint the human move before WASM blocks for the engine search, which
/// the WASM toolchain is otherwise unable to yield mid-call.
@_cdecl("chess_protocol_send")
public func chess_protocol_send(_ length: Int32) -> Int32 {
    let wire = readInput(length)
    let replies = session.round.handleWire(wire, runEngine: false)
    var combined = ""
    var first = true
    for reply in replies {
        if !first { combined += "\n" }
        combined += reply
        first = false
    }
    return writeOutput(combined)
}

/// Runs the engine if it's the engine's turn and drains the resulting
/// move (and possibly an `endData`) into the output buffer. Returns the
/// number of bytes written, or `0` if the engine had nothing to do
/// (e.g. it's the human's turn or the game is over).
@_cdecl("chess_protocol_pump_engine")
public func chess_protocol_pump_engine() -> Int32 {
    let replies = session.round.pumpEngineWire()
    if replies.isEmpty {
        return 0
    }
    var combined = ""
    var first = true
    for reply in replies {
        if !first { combined += "\n" }
        combined += reply
        first = false
    }
    return writeOutput(combined)
}

/// Emits the round's initial snapshot — `{"t":"move",...}` carrying the
/// current FEN, ply, dests, etc. — into the output buffer. If the engine
/// is configured to play the current side (i.e. the human chose Black),
/// the engine's first move is appended to the same response so a single
/// drain bootstraps the UI fully.
@_cdecl("chess_protocol_initial_snapshot")
public func chess_protocol_initial_snapshot() -> Int32 {
    session.round.emitInitialSnapshot()
    session.round.kickEngine()
    let replies = session.round.flushWire()
    var combined = ""
    var first = true
    for reply in replies {
        if !first { combined += "\n" }
        combined += reply
        first = false
    }
    return writeOutput(combined)
}

// MARK: - Initialization (WASI command entry point)

// The Swift WASM toolchain produces a WASI command module with a `_start`
// symbol. We perform any one-time setup here; JavaScript can call `_start`
// once before invoking any other exported function.
print("SkipChessWeb \(SkipChessModel.version) (engine \(SkipChessEngineAlphaBeta.version)) ready.")
