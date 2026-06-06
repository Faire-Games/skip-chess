// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0


/// The color of a chess piece (or the side to move).
public enum PieceColor: Int, Sendable, CaseIterable {
    case white = 0
    case black = 1

    /// The opposite color.
    public var opponent: PieceColor {
        return self == .white ? .black : .white
    }

    /// One-letter algebraic abbreviation: "w" or "b".
    public var fenLetter: String {
        return self == .white ? "w" : "b"
    }
}

/// The kind of chess piece, independent of color.
public enum PieceKind: Int, Sendable, CaseIterable {
    case pawn = 1
    case knight = 2
    case bishop = 3
    case rook = 4
    case queen = 5
    case king = 6

    /// The single-letter algebraic notation (upper case for white).
    public var letter: String {
        switch self {
        case .pawn: return "P"
        case .knight: return "N"
        case .bishop: return "B"
        case .rook: return "R"
        case .queen: return "Q"
        case .king: return "K"
        }
    }
}

/// A chess piece with both color and kind.
///
/// Wrapped over a single ``Int`` so that arrays of pieces remain primitive on
/// the Kotlin/JVM side (no boxing overhead during heavy engine work).
public struct Piece: Hashable, Sendable {
    public let color: PieceColor
    public let kind: PieceKind

    public init(color: PieceColor, kind: PieceKind) {
        self.color = color
        self.kind = kind
    }

    /// Upper-case for white, lower-case for black (standard FEN notation).
    public var fenCharacter: String {
        let letter = kind.letter
        return color == .white ? letter : letter.lowercased()
    }
}

// MARK: - Compact Integer Encoding

/// Compact piece encoding used by the board representation.
///
/// Layout (bits): `cccc-kkkk` — bits 0..2 are the ``PieceKind`` raw value
/// (1..6) and bit 3 is the color (0 = white, 1 = black). The special value
/// `0` represents an empty square.
///
/// Using a single ``Int`` allows the board to be a primitive array even after
/// transpilation to Kotlin, which avoids object allocations in the engine's
/// hot loops.
public enum PieceCode {
    public static let empty: Int = 0

    public static let whitePawn: Int = 1
    public static let whiteKnight: Int = 2
    public static let whiteBishop: Int = 3
    public static let whiteRook: Int = 4
    public static let whiteQueen: Int = 5
    public static let whiteKing: Int = 6

    public static let blackPawn: Int = 9
    public static let blackKnight: Int = 10
    public static let blackBishop: Int = 11
    public static let blackRook: Int = 12
    public static let blackQueen: Int = 13
    public static let blackKing: Int = 14

    /// Returns the kind (1..6) of the given encoded piece, or 0 if empty.
    @inlinable
    public static func kind(_ code: Int) -> Int {
        return code & 0x7
    }

    /// Returns the color flag (0 = white, 1 = black). Caller must ensure the
    /// square is non-empty before interpreting the result.
    @inlinable
    public static func colorFlag(_ code: Int) -> Int {
        return (code >> 3) & 0x1
    }

    @inlinable
    public static func isEmpty(_ code: Int) -> Bool {
        return code == 0
    }

    @inlinable
    public static func isWhite(_ code: Int) -> Bool {
        return code != 0 && (code & 0x8) == 0
    }

    @inlinable
    public static func isBlack(_ code: Int) -> Bool {
        return (code & 0x8) != 0
    }

    @inlinable
    public static func make(color: PieceColor, kind: PieceKind) -> Int {
        return (color.rawValue << 3) | kind.rawValue
    }

    /// Returns the ``Piece`` form for the encoded piece, or `nil` if empty
    /// or if `code` is an invalid encoding (kind bits 1..6 are reserved;
    /// `7` is an illegal kind and produces `nil` rather than a misleading
    /// fallback piece).
    public static func piece(_ code: Int) -> Piece? {
        if code == 0 {
            return nil
        }
        guard let k = PieceKind(rawValue: code & 0x7) else {
            return nil
        }
        let c: PieceColor = (code & 0x8) != 0 ? .black : .white
        return Piece(color: c, kind: k)
    }

    /// Converts a FEN character ("P", "n", etc.) to a piece code, or 0 if
    /// the character does not represent a piece.
    public static func fromFenCharacter(_ c: Character) -> Int {
        switch c {
        case "P": return whitePawn
        case "N": return whiteKnight
        case "B": return whiteBishop
        case "R": return whiteRook
        case "Q": return whiteQueen
        case "K": return whiteKing
        case "p": return blackPawn
        case "n": return blackKnight
        case "b": return blackBishop
        case "r": return blackRook
        case "q": return blackQueen
        case "k": return blackKing
        default: return 0
        }
    }

    /// The FEN character for the encoded piece (or "." for empty).
    public static func fenCharacter(_ code: Int) -> String {
        switch code {
        case whitePawn: return "P"
        case whiteKnight: return "N"
        case whiteBishop: return "B"
        case whiteRook: return "R"
        case whiteQueen: return "Q"
        case whiteKing: return "K"
        case blackPawn: return "p"
        case blackKnight: return "n"
        case blackBishop: return "b"
        case blackRook: return "r"
        case blackQueen: return "q"
        case blackKing: return "k"
        default: return "."
        }
    }
}
