// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0


/// A single chess move. Captures are implied by the destination square's
/// occupancy on the position the move is applied to.
public struct Move: Hashable, Sendable {
    /// Source square index (0..63).
    public let from: Int
    /// Destination square index (0..63).
    public let to: Int
    /// Piece kind to promote a pawn to, or 0 for non-promotion moves.
    /// Valid values are ``PieceKind.knight``, ``PieceKind.bishop``,
    /// ``PieceKind.rook``, or ``PieceKind.queen`` raw values.
    public let promotion: Int

    public init(from: Int, to: Int, promotion: Int = 0) {
        self.from = from
        self.to = to
        self.promotion = promotion
    }

    public init(from: Int, to: Int, promotion: PieceKind) {
        self.from = from
        self.to = to
        self.promotion = promotion.rawValue
    }

    /// `true` if this move promotes a pawn.
    public var isPromotion: Bool {
        return promotion != 0
    }

    /// The promotion piece kind, or `nil` for non-promotion moves.
    public var promotionKind: PieceKind? {
        return PieceKind(rawValue: promotion)
    }

    /// UCI/long algebraic notation like "e2e4" or "e7e8q".
    public var uci: String {
        var s = Square.name(from) + Square.name(to)
        if let k = promotionKind {
            s += k.letter.lowercased()
        }
        return s
    }

    /// Parses UCI notation. Returns `nil` if the string is invalid (note:
    /// validity here means well-formed coordinates, not necessarily a legal
    /// move in any particular position).
    public static func fromUCI(_ uci: String) -> Move? {
        let lower = uci.lowercased()
        let count = lower.count
        if count != 4 && count != 5 {
            return nil
        }
        var pieces: [String] = []
        for c in lower {
            pieces.append(String(c))
        }
        let fromName = pieces[0] + pieces[1]
        let toName = pieces[2] + pieces[3]
        let from = Square.parse(fromName)
        let to = Square.parse(toName)
        if from < 0 || to < 0 {
            return nil
        }
        var promotion = 0
        if count == 5 {
            let promoChar = pieces[4]
            switch promoChar {
            case "n": promotion = PieceKind.knight.rawValue
            case "b": promotion = PieceKind.bishop.rawValue
            case "r": promotion = PieceKind.rook.rawValue
            case "q": promotion = PieceKind.queen.rawValue
            default: return nil
            }
        }
        return Move(from: from, to: to, promotion: promotion)
    }
}

/// State needed to undo a move: previous board state plus the piece that was
/// (potentially) captured.
public struct UndoState: Sendable {
    /// The move that was applied.
    public let move: Move
    /// The captured piece code (0 if none). For en-passant captures, this is
    /// the pawn that was captured.
    public let captured: Int
    /// Castling rights before the move (bit mask).
    public let castlingRights: Int
    /// En passant target square before the move (-1 if none).
    public let enPassantSquare: Int
    /// Halfmove clock value before the move.
    public let halfmoveClock: Int
    /// Zobrist key before the move.
    public let zobristKey: Int64
}

// MARK: - Castling Right Flags

/// Bit-flag constants for castling rights.
public enum CastlingRight {
    public static let whiteKingside: Int = 1 << 0
    public static let whiteQueenside: Int = 1 << 1
    public static let blackKingside: Int = 1 << 2
    public static let blackQueenside: Int = 1 << 3
    public static let all: Int = 0xF
}
