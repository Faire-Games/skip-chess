// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import SkipChessModel

@Suite struct FENTests {

    @Test func parseStartingPosition() throws {
        let board = try #require(FEN.parse(FEN.startingPositionFEN))
        #expect(board.sideToMove == .white)
        #expect(board.castlingRights == CastlingRight.all)
        #expect(board.enPassantSquare == -1)
        #expect(board.halfmoveClock == 0)
        #expect(board.fullmoveNumber == 1)

        #expect(board.pieceCode(at: Square.a1) == PieceCode.whiteRook)
        #expect(board.pieceCode(at: Square.e1) == PieceCode.whiteKing)
        #expect(board.pieceCode(at: Square.d8) == PieceCode.blackQueen)
        #expect(board.pieceCode(at: Square.e8) == PieceCode.blackKing)
        for f in 0..<8 {
            #expect(board.pieceCode(at: Square.make(file: f, rank: 1)) == PieceCode.whitePawn)
            #expect(board.pieceCode(at: Square.make(file: f, rank: 6)) == PieceCode.blackPawn)
        }
    }

    @Test func serializeStartingPosition() throws {
        let board = Board.standardStartingPosition()
        let fen = FEN.serialize(board)
        #expect(fen == FEN.startingPositionFEN)
    }

    @Test func roundTripStartingPosition() throws {
        let original = try #require(FEN.parse(FEN.startingPositionFEN))
        let serialized = FEN.serialize(original)
        let reparsed = try #require(FEN.parse(serialized))
        #expect(FEN.serialize(reparsed) == FEN.startingPositionFEN)
    }

    @Test func parseKiwipetePosition() throws {
        // Kiwipete: famous perft testing position.
        let fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
        let board = try #require(FEN.parse(fen))
        #expect(board.sideToMove == .white)
        #expect(board.castlingRights == CastlingRight.all)
        #expect(board.pieceCode(at: Square.e1) == PieceCode.whiteKing)
        #expect(board.pieceCode(at: Square.e8) == PieceCode.blackKing)
        #expect(FEN.serialize(board) == fen)
    }

    @Test func parseEnPassantSquare() throws {
        let fen = "rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3"
        let board = try #require(FEN.parse(fen))
        #expect(board.enPassantSquare == Square.parse("d6"))
        #expect(FEN.serialize(board) == fen)
    }

    @Test func parseNoCastlingRights() throws {
        let fen = "4k3/8/8/8/8/8/8/4K3 w - - 0 1"
        let board = try #require(FEN.parse(fen))
        #expect(board.castlingRights == 0)
        #expect(board.enPassantSquare == -1)
        #expect(FEN.serialize(board) == fen)
    }

    @Test func parseHalfmoveAndFullmove() throws {
        let fen = "4k3/8/8/8/8/8/8/4K3 b - - 25 50"
        let board = try #require(FEN.parse(fen))
        #expect(board.halfmoveClock == 25)
        #expect(board.fullmoveNumber == 50)
        #expect(board.sideToMove == .black)
        #expect(FEN.serialize(board) == fen)
    }

    @Test func parsePartialCastlingRights() throws {
        let fen = "r3k2r/8/8/8/8/8/8/R3K2R w Kq - 0 1"
        let board = try #require(FEN.parse(fen))
        #expect((board.castlingRights & CastlingRight.whiteKingside) != 0)
        #expect((board.castlingRights & CastlingRight.whiteQueenside) == 0)
        #expect((board.castlingRights & CastlingRight.blackKingside) == 0)
        #expect((board.castlingRights & CastlingRight.blackQueenside) != 0)
        #expect(FEN.serialize(board) == fen)
    }

    @Test func rejectMalformedFEN() throws {
        #expect(FEN.parse("") == nil)
        #expect(FEN.parse("not a fen") == nil)
        // Too few ranks
        #expect(FEN.parse("rnbqkbnr/8 w - - 0 1") == nil)
        // Too many pieces on a rank
        #expect(FEN.parse("rnbqkbnrr/8/8/8/8/8/8/RNBQKBNR w - - 0 1") == nil)
        // Invalid piece character
        #expect(FEN.parse("rxxqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w - - 0 1") == nil)
        // Invalid side to move
        #expect(FEN.parse("4k3/8/8/8/8/8/8/4K3 z - - 0 1") == nil)
    }

    @Test func zobristKeyConsistency() throws {
        // Two boards parsed from the same FEN should have the same key.
        let f = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        let a = try #require(FEN.parse(f))
        let b = try #require(FEN.parse(f))
        #expect(a.zobristKey == b.zobristKey)

        // Different positions should differ.
        let other = try #require(FEN.parse("4k3/8/8/8/8/8/8/4K3 w - - 0 1"))
        #expect(a.zobristKey != other.zobristKey)
    }
}
