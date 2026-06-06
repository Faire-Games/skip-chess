// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import SkipChessModel

@Suite struct PromotionTests {

    @Test func whitePawnPromotionGeneratesFourMoves() throws {
        let board = try #require(FEN.parse("4k3/P7/8/8/8/8/8/4K3 w - - 0 1"))
        var promotionMoves: [Move] = []
        for m in board.legalMoves() {
            if m.from == Square.parse("a7") {
                promotionMoves.append(m)
            }
        }
        // Forward to a8 with 4 promotion choices.
        #expect(promotionMoves.count == 4)
        var promoKinds: Set<Int> = []
        for m in promotionMoves {
            #expect(m.to == Square.parse("a8"))
            promoKinds.insert(m.promotion)
        }
        #expect(promoKinds.contains(PieceKind.queen.rawValue))
        #expect(promoKinds.contains(PieceKind.rook.rawValue))
        #expect(promoKinds.contains(PieceKind.bishop.rawValue))
        #expect(promoKinds.contains(PieceKind.knight.rawValue))
    }

    @Test func promoteToQueen() throws {
        let board = try #require(FEN.parse("4k3/P7/8/8/8/8/8/4K3 w - - 0 1"))
        let move = Move(from: Square.parse("a7"), to: Square.parse("a8"), promotion: PieceKind.queen)
        #expect(board.isLegalMove(move))
        _ = board.makeMove(move)
        #expect(board.pieceCode(at: Square.parse("a8")) == PieceCode.whiteQueen)
    }

    @Test func promoteToKnight() throws {
        let board = try #require(FEN.parse("4k3/P7/8/8/8/8/8/4K3 w - - 0 1"))
        let move = Move(from: Square.parse("a7"), to: Square.parse("a8"), promotion: PieceKind.knight)
        #expect(board.isLegalMove(move))
        _ = board.makeMove(move)
        #expect(board.pieceCode(at: Square.parse("a8")) == PieceCode.whiteKnight)
    }

    @Test func blackPawnPromotion() throws {
        let board = try #require(FEN.parse("4k3/8/8/8/8/8/p7/4K3 b - - 0 1"))
        var promotionMoves: [Move] = []
        for m in board.legalMoves() {
            if m.from == Square.parse("a2") {
                promotionMoves.append(m)
            }
        }
        #expect(promotionMoves.count == 4)
        for m in promotionMoves {
            #expect(m.to == Square.parse("a1"))
        }
    }

    @Test func capturePromotion() throws {
        // Pawn on a7, rook on b8. Pawn can promote going to a8 (forward) or
        // by capturing to b8. Each forward + capture path gets 4 promotion
        // choices, total 8 moves.
        let board = try #require(FEN.parse("1r2k3/P7/8/8/8/8/8/4K3 w - - 0 1"))
        var promotionMoves: [Move] = []
        for m in board.legalMoves() {
            if m.from == Square.parse("a7") {
                promotionMoves.append(m)
            }
        }
        #expect(promotionMoves.count == 8)
    }

    @Test func promotionUnmakeRestoresPawn() throws {
        let board = try #require(FEN.parse("4k3/P7/8/8/8/8/8/4K3 w - - 0 1"))
        let originalFEN = FEN.serialize(board)
        let originalKey = board.zobristKey
        let move = Move(from: Square.parse("a7"), to: Square.parse("a8"), promotion: PieceKind.queen)
        let undo = board.makeMove(move)
        board.unmakeMove(undo)
        #expect(FEN.serialize(board) == originalFEN)
        #expect(board.zobristKey == originalKey)
        #expect(board.pieceCode(at: Square.parse("a7")) == PieceCode.whitePawn)
    }

    @Test func capturePromotionUnmakeRestoresAllPieces() throws {
        let board = try #require(FEN.parse("1r2k3/P7/8/8/8/8/8/4K3 w - - 0 1"))
        let originalFEN = FEN.serialize(board)
        let originalKey = board.zobristKey
        let move = Move(from: Square.parse("a7"), to: Square.parse("b8"), promotion: PieceKind.queen)
        let undo = board.makeMove(move)
        board.unmakeMove(undo)
        #expect(FEN.serialize(board) == originalFEN)
        #expect(board.zobristKey == originalKey)
        #expect(board.pieceCode(at: Square.parse("b8")) == PieceCode.blackRook)
    }
}
