// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A mutable chess position: piece placement plus all state required to
/// generate moves and detect game-end conditions.
///
/// The board stores pieces in a flat 64-entry ``Int`` array using the
/// ``PieceCode`` compact encoding so the Kotlin transpilation keeps the
/// inner loops free of heap allocations.
///
/// `Board` provides incremental ``makeMove(_:)`` / ``unmakeMove(_:)`` along
/// with full legal-move generation. Game-level concerns (repetition counts,
/// fifty-move rule trigger thresholds, draw declarations) are handled by
/// ``Game``.
public final class Board {

    // MARK: - State

    /// Flat 64-entry array of piece codes. Index = `rank * 8 + file`.
    public internal(set) var squares: [Int]
    /// Whose turn it is to move.
    public internal(set) var sideToMove: PieceColor
    /// Bitmask of castling rights. See ``CastlingRight``.
    public internal(set) var castlingRights: Int
    /// The square a pawn could capture to en passant (`-1` if none).
    public internal(set) var enPassantSquare: Int
    /// Halfmove clock used for the fifty-move rule. Reset on captures and
    /// pawn moves.
    public internal(set) var halfmoveClock: Int
    /// Full move number, incremented after Black moves.
    public internal(set) var fullmoveNumber: Int
    /// Incrementally maintained Zobrist hash key for the position.
    public internal(set) var zobristKey: Int64

    // Cached king positions so check-detection is O(1).
    private var whiteKingSquare: Int
    private var blackKingSquare: Int

    // MARK: - Init

    /// Creates an empty board with white to move. Use
    /// ``standardStartingPosition()`` for the conventional opening setup.
    public init() {
        squares = [Int](repeating: 0, count: 64)
        sideToMove = .white
        castlingRights = 0
        enPassantSquare = -1
        halfmoveClock = 0
        fullmoveNumber = 1
        zobristKey = 0
        whiteKingSquare = -1
        blackKingSquare = -1
    }

    /// Internal copy initializer (used by ``clone()``).
    fileprivate init(copyOf other: Board) {
        self.squares = other.squares
        self.sideToMove = other.sideToMove
        self.castlingRights = other.castlingRights
        self.enPassantSquare = other.enPassantSquare
        self.halfmoveClock = other.halfmoveClock
        self.fullmoveNumber = other.fullmoveNumber
        self.zobristKey = other.zobristKey
        self.whiteKingSquare = other.whiteKingSquare
        self.blackKingSquare = other.blackKingSquare
    }

    /// Returns an independent copy of this board.
    public func clone() -> Board {
        return Board(copyOf: self)
    }

    /// Returns a fresh board configured to the standard starting position.
    public static func standardStartingPosition() -> Board {
        // Use FEN to avoid duplicating the initial layout logic.
        return FEN.parse(FEN.startingPositionFEN) ?? Board()
    }

    // MARK: - Piece Access

    /// Returns the piece code at a square (`0` if empty).
    @inlinable
    public func pieceCode(at square: Int) -> Int {
        return squares[square]
    }

    /// Returns the high-level piece value at a square (`nil` if empty).
    public func piece(at square: Int) -> Piece? {
        return PieceCode.piece(squares[square])
    }

    /// Replaces the piece at a square. Updates Zobrist key incrementally.
    /// Intended for setup (FEN loading); use ``makeMove(_:)`` to play moves.
    public func setPiece(_ code: Int, at square: Int) {
        let old = squares[square]
        if old != 0 {
            zobristKey = zobristKey ^ Zobrist.keyForPiece(old, square: square)
            if old == PieceCode.whiteKing {
                whiteKingSquare = -1
            } else if old == PieceCode.blackKing {
                blackKingSquare = -1
            }
        }
        squares[square] = code
        if code != 0 {
            zobristKey = zobristKey ^ Zobrist.keyForPiece(code, square: square)
            if code == PieceCode.whiteKing {
                whiteKingSquare = square
            } else if code == PieceCode.blackKing {
                blackKingSquare = square
            }
        }
    }

    /// Sets the side to move and maintains the hash key.
    public func setSideToMove(_ color: PieceColor) {
        if sideToMove != color {
            zobristKey = zobristKey ^ Zobrist.sideToMoveKey
            sideToMove = color
        }
    }

    /// Replaces castling rights and maintains the hash key.
    public func setCastlingRights(_ rights: Int) {
        if castlingRights != (rights & 0xF) {
            zobristKey = zobristKey ^ Zobrist.keyForCastlingRights(castlingRights)
            castlingRights = rights & 0xF
            zobristKey = zobristKey ^ Zobrist.keyForCastlingRights(castlingRights)
        }
    }

    /// Replaces the en passant square and maintains the hash key.
    public func setEnPassantSquare(_ square: Int) {
        if enPassantSquare != square {
            if enPassantSquare >= 0 {
                zobristKey = zobristKey ^ Zobrist.keyForEnPassantSquare(enPassantSquare)
            }
            enPassantSquare = square
            if square >= 0 {
                zobristKey = zobristKey ^ Zobrist.keyForEnPassantSquare(square)
            }
        }
    }

    /// Returns the square of the king of the given color, or `-1` if missing.
    public func kingSquare(of color: PieceColor) -> Int {
        return color == .white ? whiteKingSquare : blackKingSquare
    }

    // MARK: - Move Application

    /// Applies `move` to the board, returning information that can be passed
    /// to ``unmakeMove(_:)`` to restore the previous state.
    ///
    /// The caller is expected to provide a legal move. Move legality can be
    /// verified up-front via ``isLegalMove(_:)`` or by selecting from the
    /// list returned by ``legalMoves()``.
    public func makeMove(_ move: Move) -> UndoState {
        let from = move.from
        let to = move.to
        let movingPiece = squares[from]
        let movingKind = PieceCode.kind(movingPiece)
        let movingColor: PieceColor = PieceCode.isWhite(movingPiece) ? .white : .black

        var captured = squares[to]
        let oldCastling = castlingRights
        let oldEnPassant = enPassantSquare
        let oldHalfmove = halfmoveClock
        let oldKey = zobristKey

        // Detect en passant: a pawn moving diagonally to the en-passant
        // square captures the pawn on the same file as `to` but on the
        // pawn's starting rank.
        var enPassantCaptureSquare = -1
        if movingKind == PieceKind.pawn.rawValue && to == enPassantSquare && enPassantSquare >= 0 {
            let dir = (movingColor == .white) ? -8 : 8
            enPassantCaptureSquare = to + dir
            captured = squares[enPassantCaptureSquare]
        }

        // ---- Mutate hash: remove pieces that will move/be captured.
        if oldEnPassant >= 0 {
            zobristKey = zobristKey ^ Zobrist.keyForEnPassantSquare(oldEnPassant)
        }
        zobristKey = zobristKey ^ Zobrist.keyForPiece(movingPiece, square: from)
        if enPassantCaptureSquare >= 0 {
            zobristKey = zobristKey ^ Zobrist.keyForPiece(captured, square: enPassantCaptureSquare)
        } else if captured != 0 {
            zobristKey = zobristKey ^ Zobrist.keyForPiece(captured, square: to)
        }

        // ---- Mutate board.
        squares[from] = 0
        if enPassantCaptureSquare >= 0 {
            squares[enPassantCaptureSquare] = 0
        }

        // Determine the piece landing on `to` (handle promotion).
        var placedPiece = movingPiece
        if move.promotion != 0 {
            placedPiece = PieceCode.make(color: movingColor, kind: PieceKind(rawValue: move.promotion) ?? .queen)
        }
        squares[to] = placedPiece
        zobristKey = zobristKey ^ Zobrist.keyForPiece(placedPiece, square: to)

        // King tracking & castling rook movement
        if movingKind == PieceKind.king.rawValue {
            if movingColor == .white {
                whiteKingSquare = to
            } else {
                blackKingSquare = to
            }
            // Kingside / queenside castle is detected by 2-square king move.
            let delta = to - from
            if delta == 2 || delta == -2 {
                // Castling: move the rook.
                let rookFrom: Int
                let rookTo: Int
                if delta == 2 {
                    rookFrom = from + 3
                    rookTo = from + 1
                } else {
                    rookFrom = from - 4
                    rookTo = from - 1
                }
                let rookPiece = squares[rookFrom]
                zobristKey = zobristKey ^ Zobrist.keyForPiece(rookPiece, square: rookFrom)
                squares[rookFrom] = 0
                squares[rookTo] = rookPiece
                zobristKey = zobristKey ^ Zobrist.keyForPiece(rookPiece, square: rookTo)
            }
        }

        // Update castling rights — losing rights when king or rooks move,
        // or when a rook is captured on its home square.
        var newCastling = oldCastling
        if movingKind == PieceKind.king.rawValue {
            if movingColor == .white {
                newCastling = newCastling & ~(CastlingRight.whiteKingside | CastlingRight.whiteQueenside)
            } else {
                newCastling = newCastling & ~(CastlingRight.blackKingside | CastlingRight.blackQueenside)
            }
        }
        if from == Square.a1 || to == Square.a1 {
            newCastling = newCastling & ~CastlingRight.whiteQueenside
        }
        if from == Square.h1 || to == Square.h1 {
            newCastling = newCastling & ~CastlingRight.whiteKingside
        }
        if from == Square.a8 || to == Square.a8 {
            newCastling = newCastling & ~CastlingRight.blackQueenside
        }
        if from == Square.h8 || to == Square.h8 {
            newCastling = newCastling & ~CastlingRight.blackKingside
        }
        if newCastling != oldCastling {
            zobristKey = zobristKey ^ Zobrist.keyForCastlingRights(oldCastling)
            zobristKey = zobristKey ^ Zobrist.keyForCastlingRights(newCastling)
            castlingRights = newCastling
        }

        // Update en passant target — set only on a double pawn push.
        var newEnPassant = -1
        if movingKind == PieceKind.pawn.rawValue {
            let delta = to - from
            if delta == 16 || delta == -16 {
                newEnPassant = (from + to) / 2
            }
        }
        if newEnPassant >= 0 {
            zobristKey = zobristKey ^ Zobrist.keyForEnPassantSquare(newEnPassant)
        }
        enPassantSquare = newEnPassant

        // Update halfmove clock.
        if movingKind == PieceKind.pawn.rawValue || captured != 0 {
            halfmoveClock = 0
        } else {
            halfmoveClock = halfmoveClock + 1
        }

        // Update fullmove number.
        if sideToMove == .black {
            fullmoveNumber = fullmoveNumber + 1
        }

        // Switch side to move.
        zobristKey = zobristKey ^ Zobrist.sideToMoveKey
        sideToMove = sideToMove.opponent

        return UndoState(
            move: move,
            captured: captured,
            castlingRights: oldCastling,
            enPassantSquare: oldEnPassant,
            halfmoveClock: oldHalfmove,
            zobristKey: oldKey
        )
    }

    /// Reverses the effect of a prior ``makeMove(_:)`` call.
    public func unmakeMove(_ undo: UndoState) {
        let move = undo.move
        let from = move.from
        let to = move.to
        let placedPiece = squares[to]
        var originalPiece = placedPiece
        let movedColor: PieceColor = PieceCode.isWhite(placedPiece) ? .white : .black

        // Restore promoted pawn to its original pawn form.
        if move.promotion != 0 {
            originalPiece = PieceCode.make(color: movedColor, kind: .pawn)
        }

        squares[from] = originalPiece
        squares[to] = 0

        let kind = PieceCode.kind(originalPiece)

        if kind == PieceKind.king.rawValue {
            if movedColor == .white {
                whiteKingSquare = from
            } else {
                blackKingSquare = from
            }
            // Undo castling rook movement.
            let delta = to - from
            if delta == 2 || delta == -2 {
                let rookFrom: Int
                let rookTo: Int
                if delta == 2 {
                    rookFrom = from + 3
                    rookTo = from + 1
                } else {
                    rookFrom = from - 4
                    rookTo = from - 1
                }
                let rookPiece = squares[rookTo]
                squares[rookTo] = 0
                squares[rookFrom] = rookPiece
            }
        }

        // Restore captured piece (handling en passant).
        if undo.captured != 0 {
            // Was this an en passant capture?
            if kind == PieceKind.pawn.rawValue && to == undo.enPassantSquare && undo.enPassantSquare >= 0 {
                let dir = (movedColor == .white) ? -8 : 8
                let epSquare = to + dir
                squares[epSquare] = undo.captured
            } else {
                squares[to] = undo.captured
            }
        }

        castlingRights = undo.castlingRights
        enPassantSquare = undo.enPassantSquare
        halfmoveClock = undo.halfmoveClock
        zobristKey = undo.zobristKey

        if sideToMove == .white {
            fullmoveNumber = fullmoveNumber - 1
        }
        sideToMove = sideToMove.opponent
    }

    // MARK: - Convenience helpers used by the move generator

    /// Returns `true` if the side to move is currently in check.
    public func isCheck() -> Bool {
        let sq = kingSquare(of: sideToMove)
        if sq < 0 {
            return false
        }
        return MoveGenerator.isSquareAttacked(board: self, square: sq, by: sideToMove.opponent)
    }

    /// `true` if the indicated color's king is in check.
    public func isInCheck(_ color: PieceColor) -> Bool {
        let sq = kingSquare(of: color)
        if sq < 0 {
            return false
        }
        return MoveGenerator.isSquareAttacked(board: self, square: sq, by: color.opponent)
    }

    /// Returns the list of all legal moves available to the side to move.
    public func legalMoves() -> [Move] {
        var moves: [Move] = []
        MoveGenerator.generateLegalMoves(board: self, into: &moves)
        return moves
    }

    /// Fills `moves` with the legal moves for the side to move (clears any
    /// existing entries first, preserving capacity).
    public func legalMoves(into moves: inout [Move]) {
        moves.removeAll(keepingCapacity: true)
        MoveGenerator.generateLegalMoves(board: self, into: &moves)
    }

    /// `true` if `move` is a legal move in the current position.
    public func isLegalMove(_ move: Move) -> Bool {
        let moves = legalMoves()
        for m in moves {
            if m == move {
                return true
            }
        }
        return false
    }

    /// `true` if the side to move has been checkmated.
    public func isCheckmate() -> Bool {
        if !isCheck() {
            return false
        }
        return legalMoves().isEmpty
    }

    /// `true` if the side to move has no legal moves and is not in check.
    public func isStalemate() -> Bool {
        if isCheck() {
            return false
        }
        return legalMoves().isEmpty
    }

    /// Returns `true` if neither side has sufficient material to deliver
    /// mate. Recognizes the FIDE simple cases: K vs K, K+B vs K, K+N vs K,
    /// and K+B vs K+B with bishops on same color.
    public func hasInsufficientMaterial() -> Bool {
        var whiteKnights = 0
        var whiteBishops = 0
        var blackKnights = 0
        var blackBishops = 0
        var whiteBishopSquareColors: Int = 0  // bitmask: 1=light, 2=dark
        var blackBishopSquareColors: Int = 0

        for sq in 0..<64 {
            let p = squares[sq]
            if p == 0 {
                continue
            }
            let kind = PieceCode.kind(p)
            // Any pawn, rook, or queen is always sufficient material.
            if kind == PieceKind.pawn.rawValue || kind == PieceKind.rook.rawValue || kind == PieceKind.queen.rawValue {
                return false
            }
            if kind == PieceKind.knight.rawValue {
                if PieceCode.isWhite(p) {
                    whiteKnights = whiteKnights + 1
                } else {
                    blackKnights = blackKnights + 1
                }
            } else if kind == PieceKind.bishop.rawValue {
                let isLight = ((Square.file(sq) + Square.rank(sq)) & 1) == 0
                let colorBit = isLight ? 1 : 2
                if PieceCode.isWhite(p) {
                    whiteBishops = whiteBishops + 1
                    whiteBishopSquareColors = whiteBishopSquareColors | colorBit
                } else {
                    blackBishops = blackBishops + 1
                    blackBishopSquareColors = blackBishopSquareColors | colorBit
                }
            }
        }

        // Two or more knights of the same color is technically a draw with
        // best play, but FIDE rules consider it sufficient material because
        // mate is possible. We don't treat it as insufficient.
        let whiteMinors = whiteKnights + whiteBishops
        let blackMinors = blackKnights + blackBishops

        if whiteMinors == 0 && blackMinors == 0 {
            return true  // K vs K
        }
        if whiteMinors == 1 && blackMinors == 0 {
            return true  // K+minor vs K
        }
        if whiteMinors == 0 && blackMinors == 1 {
            return true  // K vs K+minor
        }
        // K+B vs K+B with bishops on same color squares.
        if whiteKnights == 0 && blackKnights == 0 && whiteBishops == 1 && blackBishops == 1 {
            if whiteBishopSquareColors == blackBishopSquareColors {
                return true
            }
        }
        return false
    }

    /// `true` if the fifty-move rule has been reached (100 half-moves with
    /// no captures or pawn moves).
    public func isFiftyMoveRule() -> Bool {
        return halfmoveClock >= 100
    }
}
