// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
import Foundation
@testable import SkipChessModel

@Suite struct MoveGenerationTests {

    @Test func startingPositionTwentyMoves() throws {
        let board = Board.standardStartingPosition()
        let moves = board.legalMoves()
        // Standard starting position has 20 legal moves for white:
        // 16 pawn moves (8 single, 8 double) + 4 knight moves.
        #expect(moves.count == 20)
    }

    @Test func startingPositionAfterE4() throws {
        let board = Board.standardStartingPosition()
        let actualE2 = Square.parse("e2")
        let actualE4 = Square.parse("e4")
        let move = Move(from: actualE2, to: actualE4)
        #expect(board.isLegalMove(move))
        _ = board.makeMove(move)
        #expect(board.sideToMove == .black)
        #expect(board.pieceCode(at: actualE4) == PieceCode.whitePawn)
        #expect(board.pieceCode(at: actualE2) == 0)
        #expect(board.enPassantSquare == Square.parse("e3"))
        let blackMoves = board.legalMoves()
        #expect(blackMoves.count == 20)
    }

    @Test func knightCannotMoveOffBoard() throws {
        let board = try #require(FEN.parse("4k3/8/8/8/8/8/8/N3K3 w - - 0 1"))
        // Knight on a1 has 2 legal moves: b3 (Square.parse("b3")=17) and c2 (Square.parse("c2")=10).
        var knightMoves: [Move] = []
        for m in board.legalMoves() {
            if m.from == Square.a1 {
                knightMoves.append(m)
            }
        }
        #expect(knightMoves.count == 2)
        var dests: Set<Int> = []
        for m in knightMoves {
            dests.insert(m.to)
        }
        #expect(dests.contains(Square.parse("b3")))
        #expect(dests.contains(Square.parse("c2")))
    }

    @Test func sliderBlocked() throws {
        // Rook on a1, own pawn on a4. Should only reach a2, a3.
        let board = try #require(FEN.parse("4k3/8/8/8/P7/8/8/R3K3 w - - 0 1"))
        var rookMoves: [Move] = []
        for m in board.legalMoves() {
            if m.from == Square.a1 {
                rookMoves.append(m)
            }
        }
        var destinations: Set<Int> = []
        for m in rookMoves {
            destinations.insert(m.to)
        }
        #expect(destinations.contains(Square.parse("a2")))
        #expect(destinations.contains(Square.parse("a3")))
        #expect(!destinations.contains(Square.parse("a4")))
        #expect(!destinations.contains(Square.parse("a5")))
    }

    @Test func sliderCaptures() throws {
        // Rook on a1, enemy pawn on a4. Should reach a2, a3, a4 (capture).
        let board = try #require(FEN.parse("4k3/8/8/8/p7/8/8/R3K3 w - - 0 1"))
        var dests: Set<Int> = []
        for m in board.legalMoves() {
            if m.from == Square.a1 {
                dests.insert(m.to)
            }
        }
        #expect(dests.contains(Square.parse("a2")))
        #expect(dests.contains(Square.parse("a3")))
        #expect(dests.contains(Square.parse("a4")))
        #expect(!dests.contains(Square.parse("a5")))
    }

    @Test func pinnedPieceCannotMoveOffPin() throws {
        // White bishop on d2 is pinned by black rook on d8; cannot move off
        // the d-file.
        let board = try #require(FEN.parse("3rk3/8/8/8/8/8/3B4/3K4 w - - 0 1"))
        var bishopMoves: [Move] = []
        for m in board.legalMoves() {
            if m.from == Square.parse("d2") {
                bishopMoves.append(m)
            }
        }
        // Bishop cannot legally move because any move exposes the king to
        // the rook on d8.
        #expect(bishopMoves.isEmpty)
    }

    @Test func kingCannotMoveIntoCheck() throws {
        // White king on e1; black rook on e8 attacks the e-file. King may
        // not move within the e-file (besides itself), and may not stay in
        // a square attacked by the rook.
        let board = try #require(FEN.parse("4r3/8/8/8/8/8/8/4K3 w - - 0 1"))
        let moves = board.legalMoves()
        for m in moves {
            // King cannot move to e2 because rook still attacks it.
            #expect(m.to != Square.parse("e2"))
        }
        // But king can move to d1, f1, d2, f2.
        var dests: Set<Int> = []
        for m in moves {
            dests.insert(m.to)
        }
        #expect(dests.contains(Square.parse("d1")))
        #expect(dests.contains(Square.parse("f1")))
        #expect(dests.contains(Square.parse("d2")))
        #expect(dests.contains(Square.parse("f2")))
    }

    @Test func mustGetOutOfCheck() throws {
        // White king on e1 in check from black rook on e5. Must move, block,
        // or capture.
        let board = try #require(FEN.parse("8/8/8/4r3/8/8/8/4K3 w - - 0 1"))
        #expect(board.isCheck())
        let moves = board.legalMoves()
        // Every legal move must resolve check.
        for m in moves {
            let undo = board.makeMove(m)
            // After the move the opponent is on move, so check is on white,
            // who is the opponent of the side to move.
            let stillInCheck = board.isInCheck(.white)
            board.unmakeMove(undo)
            #expect(!stillInCheck)
        }
    }

    @Test func zobristKeyChangesAndRestores() throws {
        let board = Board.standardStartingPosition()
        let originalKey = board.zobristKey
        let move = Move(from: Square.parse("e2"), to: Square.parse("e4"))
        let undo = board.makeMove(move)
        #expect(board.zobristKey != originalKey)
        board.unmakeMove(undo)
        #expect(board.zobristKey == originalKey)
    }

    @Test func unmakeRestoresExactState() throws {
        let board = try #require(FEN.parse("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"))
        let originalFEN = FEN.serialize(board)
        let originalKey = board.zobristKey
        let moves = board.legalMoves()
        for m in moves {
            let undo = board.makeMove(m)
            board.unmakeMove(undo)
            #expect(FEN.serialize(board) == originalFEN)
            #expect(board.zobristKey == originalKey)
        }
    }
}
