// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0


/// Pseudo- and fully-legal move generation. Stateless: every method receives
/// a ``Board`` and writes into a caller-supplied buffer to avoid allocating
/// move lists in the engine hot path.
public enum MoveGenerator {

    // MARK: - Movement Vectors

    /// Knight relative file/rank offsets.
    private static let knightOffsets: [(Int, Int)] = [
        (1, 2), (2, 1), (-1, 2), (-2, 1),
        (1, -2), (2, -1), (-1, -2), (-2, -1)
    ]

    /// King relative file/rank offsets.
    private static let kingOffsets: [(Int, Int)] = [
        (1, 0), (-1, 0), (0, 1), (0, -1),
        (1, 1), (1, -1), (-1, 1), (-1, -1)
    ]

    /// Bishop / queen diagonal directions.
    private static let bishopDirs: [(Int, Int)] = [
        (1, 1), (1, -1), (-1, 1), (-1, -1)
    ]

    /// Rook / queen orthogonal directions.
    private static let rookDirs: [(Int, Int)] = [
        (1, 0), (-1, 0), (0, 1), (0, -1)
    ]

    // MARK: - Public API

    /// Generates all legal moves for the side to move and appends them to
    /// `moves`. The caller is responsible for clearing the buffer first if
    /// desired.
    public static func generateLegalMoves(board: Board, into moves: inout [Move]) {
        var pseudo: [Move] = []
        pseudo.reserveCapacity(64)
        generatePseudoLegalMoves(board: board, into: &pseudo)

        for move in pseudo {
            let undo = board.makeMove(move)
            // After making the move, the side that just moved must not have
            // left its king in check. `board.sideToMove` has flipped, so
            // its opponent is the side that just moved.
            let mover = board.sideToMove.opponent
            let kingSq = board.kingSquare(of: mover)
            var inCheck = false
            if kingSq >= 0 {
                inCheck = isSquareAttacked(board: board, square: kingSq, by: board.sideToMove)
            }
            board.unmakeMove(undo)
            if !inCheck {
                moves.append(move)
            }
        }
    }

    /// Generates pseudo-legal moves (does not filter moves that leave the
    /// king in check). Useful for engines that prefer to do legality
    /// checking inline.
    public static func generatePseudoLegalMoves(board: Board, into moves: inout [Move]) {
        let color = board.sideToMove

        for sq in 0..<64 {
            let piece = board.squares[sq]
            if piece == 0 {
                continue
            }
            if PieceCode.isWhite(piece) != (color == .white) {
                continue
            }
            let kind = PieceCode.kind(piece)
            switch kind {
            case 1:  // pawn
                generatePawnMoves(board: board, from: sq, color: color, into: &moves)
            case 2:  // knight
                generateLeaperMoves(board: board, from: sq, color: color, offsets: knightOffsets, into: &moves)
            case 3:  // bishop
                generateSliderMoves(board: board, from: sq, color: color, dirs: bishopDirs, into: &moves)
            case 4:  // rook
                generateSliderMoves(board: board, from: sq, color: color, dirs: rookDirs, into: &moves)
            case 5:  // queen
                generateSliderMoves(board: board, from: sq, color: color, dirs: bishopDirs, into: &moves)
                generateSliderMoves(board: board, from: sq, color: color, dirs: rookDirs, into: &moves)
            case 6:  // king
                generateLeaperMoves(board: board, from: sq, color: color, offsets: kingOffsets, into: &moves)
                generateCastlingMoves(board: board, from: sq, color: color, into: &moves)
            default:
                break
            }
        }
    }

    // MARK: - Attack Detection

    /// `true` if `square` is attacked by any piece of color `by`.
    public static func isSquareAttacked(board: Board, square: Int, by color: PieceColor) -> Bool {
        let targetFile = Square.file(square)
        let targetRank = Square.rank(square)

        // Pawn attackers
        if color == .white {
            // White pawns attack diagonally upward; for `square` to be
            // attacked by a white pawn, look at the squares one rank below.
            if targetRank >= 1 {
                if targetFile >= 1 {
                    let attackerSq = square - 9
                    if board.squares[attackerSq] == PieceCode.whitePawn {
                        return true
                    }
                }
                if targetFile <= 6 {
                    let attackerSq = square - 7
                    if board.squares[attackerSq] == PieceCode.whitePawn {
                        return true
                    }
                }
            }
        } else {
            if targetRank <= 6 {
                if targetFile >= 1 {
                    let attackerSq = square + 7
                    if board.squares[attackerSq] == PieceCode.blackPawn {
                        return true
                    }
                }
                if targetFile <= 6 {
                    let attackerSq = square + 9
                    if board.squares[attackerSq] == PieceCode.blackPawn {
                        return true
                    }
                }
            }
        }

        // Knight attackers
        let knightCode = (color == .white) ? PieceCode.whiteKnight : PieceCode.blackKnight
        for off in knightOffsets {
            let nf = targetFile + off.0
            let nr = targetRank + off.1
            if Square.isOnBoard(file: nf, rank: nr) {
                if board.squares[Square.make(file: nf, rank: nr)] == knightCode {
                    return true
                }
            }
        }

        // King attackers
        let kingCode = (color == .white) ? PieceCode.whiteKing : PieceCode.blackKing
        for off in kingOffsets {
            let nf = targetFile + off.0
            let nr = targetRank + off.1
            if Square.isOnBoard(file: nf, rank: nr) {
                if board.squares[Square.make(file: nf, rank: nr)] == kingCode {
                    return true
                }
            }
        }

        // Diagonal sliders: bishop and queen
        let bishopCode = (color == .white) ? PieceCode.whiteBishop : PieceCode.blackBishop
        let queenCode = (color == .white) ? PieceCode.whiteQueen : PieceCode.blackQueen
        for dir in bishopDirs {
            var f = targetFile + dir.0
            var r = targetRank + dir.1
            while Square.isOnBoard(file: f, rank: r) {
                let s = Square.make(file: f, rank: r)
                let p = board.squares[s]
                if p != 0 {
                    if p == bishopCode || p == queenCode {
                        return true
                    }
                    break
                }
                f = f + dir.0
                r = r + dir.1
            }
        }

        // Orthogonal sliders: rook and queen
        let rookCode = (color == .white) ? PieceCode.whiteRook : PieceCode.blackRook
        for dir in rookDirs {
            var f = targetFile + dir.0
            var r = targetRank + dir.1
            while Square.isOnBoard(file: f, rank: r) {
                let s = Square.make(file: f, rank: r)
                let p = board.squares[s]
                if p != 0 {
                    if p == rookCode || p == queenCode {
                        return true
                    }
                    break
                }
                f = f + dir.0
                r = r + dir.1
            }
        }

        return false
    }

    // MARK: - Piece-Specific Generators

    private static func generatePawnMoves(board: Board, from: Int, color: PieceColor, into moves: inout [Move]) {
        let file = Square.file(from)
        let rank = Square.rank(from)
        let dir = (color == .white) ? 1 : -1
        let startRank = (color == .white) ? 1 : 6
        let promoRank = (color == .white) ? 7 : 0

        // Forward one
        let forwardRank = rank + dir
        if Square.isOnBoard(file: file, rank: forwardRank) {
            let forwardSq = Square.make(file: file, rank: forwardRank)
            if board.squares[forwardSq] == 0 {
                if forwardRank == promoRank {
                    appendPromotions(from: from, to: forwardSq, into: &moves)
                } else {
                    moves.append(Move(from: from, to: forwardSq))
                }
                // Forward two from starting rank
                if rank == startRank {
                    let twoRank = rank + 2 * dir
                    let twoSq = Square.make(file: file, rank: twoRank)
                    if board.squares[twoSq] == 0 {
                        moves.append(Move(from: from, to: twoSq))
                    }
                }
            }
        }

        // Captures
        let captureFiles = [file - 1, file + 1]
        for cf in captureFiles {
            if !Square.isOnBoard(file: cf, rank: forwardRank) {
                continue
            }
            let captureSq = Square.make(file: cf, rank: forwardRank)
            let target = board.squares[captureSq]
            let isEPTarget = captureSq == board.enPassantSquare && board.enPassantSquare >= 0
            if target != 0 {
                // Must be enemy piece.
                if PieceCode.isWhite(target) == (color == .white) {
                    continue
                }
                if forwardRank == promoRank {
                    appendPromotions(from: from, to: captureSq, into: &moves)
                } else {
                    moves.append(Move(from: from, to: captureSq))
                }
            } else if isEPTarget {
                moves.append(Move(from: from, to: captureSq))
            }
        }
    }

    private static func appendPromotions(from: Int, to: Int, into moves: inout [Move]) {
        moves.append(Move(from: from, to: to, promotion: PieceKind.queen.rawValue))
        moves.append(Move(from: from, to: to, promotion: PieceKind.rook.rawValue))
        moves.append(Move(from: from, to: to, promotion: PieceKind.bishop.rawValue))
        moves.append(Move(from: from, to: to, promotion: PieceKind.knight.rawValue))
    }

    private static func generateLeaperMoves(board: Board, from: Int, color: PieceColor, offsets: [(Int, Int)], into moves: inout [Move]) {
        let file = Square.file(from)
        let rank = Square.rank(from)
        for off in offsets {
            let nf = file + off.0
            let nr = rank + off.1
            if !Square.isOnBoard(file: nf, rank: nr) {
                continue
            }
            let to = Square.make(file: nf, rank: nr)
            let target = board.squares[to]
            if target == 0 {
                moves.append(Move(from: from, to: to))
            } else if PieceCode.isWhite(target) != (color == .white) {
                moves.append(Move(from: from, to: to))
            }
        }
    }

    private static func generateSliderMoves(board: Board, from: Int, color: PieceColor, dirs: [(Int, Int)], into moves: inout [Move]) {
        let file = Square.file(from)
        let rank = Square.rank(from)
        for dir in dirs {
            var nf = file + dir.0
            var nr = rank + dir.1
            while Square.isOnBoard(file: nf, rank: nr) {
                let to = Square.make(file: nf, rank: nr)
                let target = board.squares[to]
                if target == 0 {
                    moves.append(Move(from: from, to: to))
                } else {
                    if PieceCode.isWhite(target) != (color == .white) {
                        moves.append(Move(from: from, to: to))
                    }
                    break
                }
                nf = nf + dir.0
                nr = nr + dir.1
            }
        }
    }

    private static func generateCastlingMoves(board: Board, from: Int, color: PieceColor, into moves: inout [Move]) {
        // King must be on its starting square and no castling rights for the
        // side count if we're in check (but standard legality filtering will
        // catch that case as well — we still check explicitly here so we
        // don't emit a move that the legality filter would have to reject
        // for a path crossed by attack).
        if board.isInCheck(color) {
            return
        }
        let homeSquare = (color == .white) ? Square.e1 : Square.e8
        if from != homeSquare {
            return
        }

        let kingsideRight = (color == .white) ? CastlingRight.whiteKingside : CastlingRight.blackKingside
        let queensideRight = (color == .white) ? CastlingRight.whiteQueenside : CastlingRight.blackQueenside

        // Kingside: squares between king and h-rook must be empty and not
        // attacked.
        if (board.castlingRights & kingsideRight) != 0 {
            let f1 = from + 1
            let g1 = from + 2
            if board.squares[f1] == 0 && board.squares[g1] == 0 {
                let opponent = color.opponent
                if !isSquareAttacked(board: board, square: f1, by: opponent) &&
                   !isSquareAttacked(board: board, square: g1, by: opponent) {
                    moves.append(Move(from: from, to: g1))
                }
            }
        }
        // Queenside: d1, c1, b1 must be empty; d1 and c1 (squares the king
        // crosses or lands on) must not be attacked. b1 may be attacked.
        if (board.castlingRights & queensideRight) != 0 {
            let d1 = from - 1
            let c1 = from - 2
            let b1 = from - 3
            if board.squares[d1] == 0 && board.squares[c1] == 0 && board.squares[b1] == 0 {
                let opponent = color.opponent
                if !isSquareAttacked(board: board, square: d1, by: opponent) &&
                   !isSquareAttacked(board: board, square: c1, by: opponent) {
                    moves.append(Move(from: from, to: c1))
                }
            }
        }
    }
}
