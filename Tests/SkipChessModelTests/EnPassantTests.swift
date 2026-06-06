// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
import Foundation
@testable import SkipChessModel

@Suite struct EnPassantTests {

    @Test func enPassantSquareSetOnDoubleAdvance() throws {
        let board = Board.standardStartingPosition()
        let move = Move(from: Square.parse("e2"), to: Square.parse("e4"))
        _ = board.makeMove(move)
        #expect(board.enPassantSquare == Square.parse("e3"))
    }

    @Test func enPassantSquareNotSetOnSingleAdvance() throws {
        let board = Board.standardStartingPosition()
        let move = Move(from: Square.parse("e2"), to: Square.parse("e3"))
        _ = board.makeMove(move)
        #expect(board.enPassantSquare == -1)
    }

    @Test func whiteCapturesEnPassant() throws {
        // White pawn on e5, black pawn just played d7-d5.
        let fen = "rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3"
        let board = try #require(FEN.parse(fen))
        let move = Move(from: Square.parse("e5"), to: Square.parse("d6"))
        #expect(board.isLegalMove(move))
        _ = board.makeMove(move)
        // White pawn now on d6, captured pawn (was on d5) removed.
        #expect(board.pieceCode(at: Square.parse("d6")) == PieceCode.whitePawn)
        #expect(board.pieceCode(at: Square.parse("d5")) == 0)
        #expect(board.pieceCode(at: Square.parse("e5")) == 0)
    }

    @Test func blackCapturesEnPassant() throws {
        // Black pawn on d4, white just played e2-e4.
        let fen = "rnbqkbnr/ppp1pppp/8/8/3pP3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 3"
        let board = try #require(FEN.parse(fen))
        let move = Move(from: Square.parse("d4"), to: Square.parse("e3"))
        #expect(board.isLegalMove(move))
        _ = board.makeMove(move)
        #expect(board.pieceCode(at: Square.parse("e3")) == PieceCode.blackPawn)
        #expect(board.pieceCode(at: Square.parse("e4")) == 0)
        #expect(board.pieceCode(at: Square.parse("d4")) == 0)
    }

    @Test func enPassantOnlyAvailableImmediately() throws {
        // After one half-move passes, en passant is no longer available.
        let board = Board.standardStartingPosition()
        _ = board.makeMove(Move(from: Square.parse("e2"), to: Square.parse("e4")))
        _ = board.makeMove(Move(from: Square.parse("a7"), to: Square.parse("a6")))  // black makes any move
        // White's en passant chance has expired.
        let pseudoMove = Move(from: Square.parse("e4"), to: Square.parse("d5"))
        #expect(!board.isLegalMove(pseudoMove))
    }

    @Test func enPassantUnmakeRestoresCapturedPawn() throws {
        let fen = "rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3"
        let board = try #require(FEN.parse(fen))
        let originalFEN = FEN.serialize(board)
        let originalKey = board.zobristKey
        let move = Move(from: Square.parse("e5"), to: Square.parse("d6"))
        let undo = board.makeMove(move)
        board.unmakeMove(undo)
        #expect(FEN.serialize(board) == originalFEN)
        #expect(board.zobristKey == originalKey)
        #expect(board.pieceCode(at: Square.parse("d5")) == PieceCode.blackPawn)
    }

    @Test func enPassantWouldExposeKingIsIllegal() throws {
        // The "tricky" en-passant pin: capturing en-passant could expose a
        // discovered check along the rank. Position: white king on e1,
        // white pawn on e5, black pawn just moved to d5, black rook on a5.
        // En passant would clear the rank between rook and king.
        let fen = "8/8/8/r1pPK3/8/8/8/8 w - c6 0 1"
        let board = try #require(FEN.parse(fen))
        let move = Move(from: Square.parse("d5"), to: Square.parse("c6"))
        // Should be illegal because it exposes the king to the rook.
        #expect(!board.isLegalMove(move))
    }
}
