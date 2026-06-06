// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The outcome of a chess game (or `nil` if it is still in progress).
public enum GameResult: Hashable, Sendable {
    /// White won by checkmate.
    case whiteWins(reason: WinReason)
    /// Black won by checkmate.
    case blackWins(reason: WinReason)
    /// The game ended in a draw.
    case draw(reason: DrawReason)

    public enum WinReason: Hashable, Sendable {
        case checkmate
        case resignation
        case timeout
    }

    public enum DrawReason: Hashable, Sendable {
        case stalemate
        case insufficientMaterial
        case fiftyMoveRule
        case threefoldRepetition
        case fivefoldRepetition
        case seventyFiveMoveRule
        case agreement
    }
}

/// A high-level wrapper over a ``Board`` that also tracks move history and
/// position repetitions so the threefold-repetition and fifty-move draw
/// claim rules can be detected.
public final class Game {

    /// The current position.
    public let board: Board

    /// Move history (most recent last).
    public private(set) var moveHistory: [Move]

    /// Per-move undo state, parallel to ``moveHistory``.
    public private(set) var undoHistory: [UndoState]

    /// Position repetition counts, keyed by Zobrist hash. Used for
    /// threefold-repetition detection.
    public private(set) var positionCounts: [Int64: Int]

    /// FEN string of the position at which this game started (typically the
    /// standard starting position).
    public let initialFEN: String

    /// Convenience initializer that creates a new game from the standard
    /// chess starting position.
    public convenience init() {
        self.init(board: Board.standardStartingPosition(), initialFEN: FEN.startingPositionFEN)
    }

    /// Creates a game from an existing board (the board is copied). The
    /// `initialFEN` is captured for replay purposes; if `nil`, it is
    /// generated from the supplied board.
    public init(board: Board, initialFEN: String? = nil) {
        let copy = board.clone()
        self.board = copy
        self.initialFEN = initialFEN ?? FEN.serialize(copy)
        self.moveHistory = []
        self.undoHistory = []
        self.positionCounts = [:]
        self.positionCounts[copy.zobristKey] = 1
    }

    /// Plays a move. Returns `true` if the move was legal and applied,
    /// `false` if rejected.
    @discardableResult
    public func play(_ move: Move) -> Bool {
        if !board.isLegalMove(move) {
            return false
        }
        let undo = board.makeMove(move)
        moveHistory.append(move)
        undoHistory.append(undo)
        let key = board.zobristKey
        let current = positionCounts[key] ?? 0
        positionCounts[key] = current + 1
        return true
    }

    /// Reverts the most recent move played. Returns `false` if there is no
    /// move to revert.
    @discardableResult
    public func undoLastMove() -> Bool {
        if undoHistory.isEmpty {
            return false
        }
        let key = board.zobristKey
        let current = positionCounts[key] ?? 0
        if current <= 1 {
            positionCounts.removeValue(forKey: key)
        } else {
            positionCounts[key] = current - 1
        }
        let undo = undoHistory.removeLast()
        moveHistory.removeLast()
        board.unmakeMove(undo)
        return true
    }

    /// Returns the number of times the current position has occurred during
    /// the game (always at least 1 once a move history exists, or 1 for the
    /// initial position).
    public func currentPositionRepetitionCount() -> Int {
        return positionCounts[board.zobristKey] ?? 0
    }

    /// Returns the current game result, or `nil` if the game is still
    /// in progress.
    public func result() -> GameResult? {
        // Forced terminations first.
        if board.isCheckmate() {
            return board.sideToMove == .white
                ? GameResult.blackWins(reason: .checkmate)
                : GameResult.whiteWins(reason: .checkmate)
        }
        if board.isStalemate() {
            return GameResult.draw(reason: .stalemate)
        }
        if board.hasInsufficientMaterial() {
            return GameResult.draw(reason: .insufficientMaterial)
        }
        // Mandatory draws (75-move rule, fivefold repetition).
        if board.halfmoveClock >= 150 {
            return GameResult.draw(reason: .seventyFiveMoveRule)
        }
        if currentPositionRepetitionCount() >= 5 {
            return GameResult.draw(reason: .fivefoldRepetition)
        }
        return nil
    }

    /// Returns `true` if the side to move can claim a draw under the FIDE
    /// fifty-move or threefold-repetition rules. These are not automatic —
    /// callers should expose them as a "claim draw" option in the UI.
    public func canClaimDraw() -> Bool {
        if board.halfmoveClock >= 100 {
            return true
        }
        if currentPositionRepetitionCount() >= 3 {
            return true
        }
        return false
    }
}
