// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// FEN (Forsyth–Edwards Notation) parsing and serialization.
///
/// FEN strings have six space-separated fields:
/// 1. Piece placement (ranks 8→1, files a→h, digits collapse empty squares)
/// 2. Side to move ("w" or "b")
/// 3. Castling rights ("KQkq", or "-")
/// 4. En passant target square (e.g. "e3", or "-")
/// 5. Halfmove clock
/// 6. Fullmove number
public enum FEN {

    /// The standard chess starting position.
    public static let startingPositionFEN: String =
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    private static let digitMap: [String: Int] = [
        "1": 1, "2": 2, "3": 3, "4": 4,
        "5": 5, "6": 6, "7": 7, "8": 8
    ]

    /// Parses a FEN string into a ``Board``. Returns `nil` if the string is
    /// malformed.
    public static func parse(_ fen: String) -> Board? {
        let trimmed = fen.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map { String($0) }
        if parts.count < 4 {
            return nil
        }

        let board = Board()

        // 1. Piece placement.
        let ranks = parts[0].split(separator: "/", omittingEmptySubsequences: false).map { String($0) }
        if ranks.count != 8 {
            return nil
        }
        for rankIndex in 0..<8 {
            // FEN ranks are listed from 8 down to 1.
            let actualRank = 7 - rankIndex
            var file = 0
            let rankString = ranks[rankIndex]
            for c in rankString {
                let cstr = String(c)
                if let n = digitMap[cstr] {
                    file = file + n
                } else {
                    if file >= 8 {
                        return nil
                    }
                    let code = PieceCode.fromFenCharacter(c)
                    if code == 0 {
                        return nil
                    }
                    let sq = Square.make(file: file, rank: actualRank)
                    board.setPiece(code, at: sq)
                    file = file + 1
                }
            }
            if file != 8 {
                return nil
            }
        }

        // 2. Side to move.
        if parts[1] == "w" {
            board.setSideToMove(.white)
        } else if parts[1] == "b" {
            board.setSideToMove(.black)
        } else {
            return nil
        }

        // 3. Castling rights.
        var rights = 0
        if parts[2] != "-" {
            for c in parts[2] {
                switch c {
                case "K": rights = rights | CastlingRight.whiteKingside
                case "Q": rights = rights | CastlingRight.whiteQueenside
                case "k": rights = rights | CastlingRight.blackKingside
                case "q": rights = rights | CastlingRight.blackQueenside
                default: return nil
                }
            }
        }
        board.setCastlingRights(rights)

        // 4. En passant target square.
        if parts[3] == "-" {
            board.setEnPassantSquare(-1)
        } else {
            let sq = Square.parse(parts[3])
            if sq < 0 {
                return nil
            }
            board.setEnPassantSquare(sq)
        }

        // 5. Halfmove clock (optional).
        if parts.count > 4 {
            board.halfmoveClock = Int(parts[4]) ?? 0
        }
        // 6. Fullmove number (optional).
        if parts.count > 5 {
            board.fullmoveNumber = Int(parts[5]) ?? 1
        } else {
            board.fullmoveNumber = 1
        }

        return board
    }

    /// Serializes a ``Board`` to a FEN string.
    public static func serialize(_ board: Board) -> String {
        var fen = ""

        for rankIndex in 0..<8 {
            let actualRank = 7 - rankIndex
            var emptyCount = 0
            for file in 0..<8 {
                let sq = Square.make(file: file, rank: actualRank)
                let code = board.squares[sq]
                if code == 0 {
                    emptyCount = emptyCount + 1
                } else {
                    if emptyCount > 0 {
                        fen += String(emptyCount)
                        emptyCount = 0
                    }
                    fen += PieceCode.fenCharacter(code)
                }
            }
            if emptyCount > 0 {
                fen += String(emptyCount)
            }
            if rankIndex != 7 {
                fen += "/"
            }
        }

        fen += " "
        fen += board.sideToMove.fenLetter

        fen += " "
        if board.castlingRights == 0 {
            fen += "-"
        } else {
            var rights = ""
            if (board.castlingRights & CastlingRight.whiteKingside) != 0 {
                rights += "K"
            }
            if (board.castlingRights & CastlingRight.whiteQueenside) != 0 {
                rights += "Q"
            }
            if (board.castlingRights & CastlingRight.blackKingside) != 0 {
                rights += "k"
            }
            if (board.castlingRights & CastlingRight.blackQueenside) != 0 {
                rights += "q"
            }
            fen += rights
        }

        fen += " "
        if board.enPassantSquare < 0 {
            fen += "-"
        } else {
            fen += Square.name(board.enPassantSquare)
        }

        fen += " "
        fen += String(board.halfmoveClock)

        fen += " "
        fen += String(board.fullmoveNumber)

        return fen
    }
}
