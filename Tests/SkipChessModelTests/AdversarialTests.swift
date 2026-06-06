// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import SkipChessModel

/// Adversarial tests that probe for crashes, corner cases, and behaviors
/// that aren't explicitly required by chess rules but should still degrade
/// gracefully under unusual input.
@Suite struct AdversarialTests {

    // MARK: - Square / coordinate edge cases

    @Test func squareNameForOutOfRangeIndex() throws {
        // Out-of-range square indices should produce the "??" sentinel rather
        // than crashing the way an unchecked Unicode conversion would.
        #expect(Square.name(-1) == "??")
        #expect(Square.name(64) == "??")
        #expect(Square.name(100) == "??")
    }

    @Test func squareParseWhitespaceAndNoise() throws {
        #expect(Square.parse(" e4") == -1)
        #expect(Square.parse("e4 ") == -1)
        #expect(Square.parse("e 4") == -1)
        #expect(Square.parse("\n") == -1)
        #expect(Square.parse("e") == -1)
    }

    @Test func squareParseEmoji() throws {
        // Pasting a multibyte glyph should not crash; it should return -1.
        #expect(Square.parse("♟︎4") == -1)
        #expect(Square.parse("4♟︎") == -1)
    }

    // MARK: - PieceCode edge cases

    @Test func pieceCodeForIllegalEncodingReturnsNil() throws {
        // Code 7 has bit 3 clear (white-ish) but kind 7 doesn't correspond
        // to a valid PieceKind raw value (1..6). Should yield nil rather
        // than a misleading "white pawn"-like piece.
        #expect(PieceCode.piece(7) == nil)
        // Code 15 has bit 3 set (black) and kind 7 — also invalid.
        #expect(PieceCode.piece(15) == nil)
    }

    // MARK: - Move struct edge cases

    @Test func moveFromUCIWithSameSquareReturnsCoordinate() throws {
        // "a1a1" is a syntactically valid UCI string (both squares parse)
        // but represents a non-move. Move.fromUCI should not crash; the
        // resulting move just won't be legal in any position.
        let m = try #require(Move.fromUCI("a1a1"))
        #expect(m.from == 0)
        #expect(m.to == 0)
    }

    @Test func moveFromUCIRejectsKingPromotion() throws {
        // 'k' isn't a valid promotion piece — fromUCI must reject it.
        #expect(Move.fromUCI("a7a8k") == nil)
        #expect(Move.fromUCI("a7a8p") == nil)
    }

    @Test func moveFromUCIRejectsRankZeroAndNine() throws {
        #expect(Move.fromUCI("e0e4") == nil)
        #expect(Move.fromUCI("e9e4") == nil)
        #expect(Move.fromUCI("e2e9") == nil)
    }

    @Test func moveWithLargePromotionValueDoesNotCrashEncoding() throws {
        // Move struct doesn't validate the promotion field. Even with an
        // out-of-range value, construction and uci serialization should not
        // crash, and the resulting move is just non-canonical.
        let m = Move(from: 0, to: 0, promotion: 99)
        #expect(m.promotion == 99)
        // uci will append a lowercase letter only if promotionKind succeeds.
        // promotionKind for 99 should be nil.
        #expect(m.promotionKind == nil)
        #expect(m.uci == "a1a1")
    }

    // MARK: - FEN edge cases

    @Test func fenForEmptyBoardParses() throws {
        let board = try #require(FEN.parse("8/8/8/8/8/8/8/8 w - - 0 1"))
        #expect(board.legalMoves().isEmpty)
        #expect(!board.isCheck())
        #expect(!board.isCheckmate())
        #expect(board.isStalemate())  // no legal moves, not in check
        #expect(board.hasInsufficientMaterial())
    }

    @Test func fenWithOnlyKingsParses() throws {
        let board = try #require(FEN.parse("k7/8/8/8/8/8/8/K7 w - - 0 1"))
        #expect(board.hasInsufficientMaterial())
        let moves = board.legalMoves()
        // White king on a1 has 3 legal moves (a2, b1, b2).
        #expect(moves.count == 3)
    }

    @Test func fenWithTwoKingsOfSameColorParsesLeniently() throws {
        // Two white kings is invalid chess but we shouldn't crash.
        let fen = "k7/8/8/8/8/8/8/K6K w - - 0 1"
        let board = FEN.parse(fen)
        // We accept the lenient parse for now; the cached king square will
        // point at the latest king placed, so downstream operations still
        // function, just on an unusual board.
        #expect(board != nil)
        if let b = board {
            // No crash on move generation.
            _ = b.legalMoves()
        }
    }

    @Test func fenWithNoWhiteKingParsesLeniently() throws {
        // Missing king is invalid chess but the model should still parse it
        // and report sensible state queries without crashing.
        let fen = "k7/8/8/8/8/8/8/8 w - - 0 1"
        let board = try #require(FEN.parse(fen))
        // White has no pieces — no legal moves.
        #expect(board.legalMoves().isEmpty)
        // isCheck for a side with no king returns false (no king to check).
        #expect(!board.isInCheck(.white))
        // No crash on isCheckmate either.
        #expect(!board.isCheckmate())
    }

    @Test func fenWithMissingHalfmoveAndFullmoveDefaultsCleanly() throws {
        // FEN's 5th and 6th fields are optional in some dialects.
        let board = try #require(FEN.parse("4k3/8/8/8/8/8/8/4K3 w - -"))
        #expect(board.halfmoveClock == 0)
        #expect(board.fullmoveNumber == 1)
    }

    @Test func fenWithBogusEnPassantSquareLenient() throws {
        // En passant claim of "e5" (rank 5) is non-canonical (en passant
        // targets are always on rank 3 or 6). We parse it because the FEN
        // is otherwise valid, but the en-passant capture won't be generated
        // unless the geometry lines up.
        let board = try #require(FEN.parse("4k3/8/8/4Pp2/8/8/8/4K3 w - e5 0 1"))
        // En passant target loaded; a pseudo-EP capture would expect a
        // pawn-diagonal landing, which "e5" is not for any pawn here.
        #expect(board.enPassantSquare == Square.parse("e5"))
        // We don't crash; specific move generation is best-effort.
        _ = board.legalMoves()
    }

    @Test func fenRejectsInvalidCastlingCharacter() throws {
        #expect(FEN.parse("4k3/8/8/8/8/8/8/4K3 w Z - 0 1") == nil)
    }

    @Test func fenRejectsTooFewFields() throws {
        #expect(FEN.parse("4k3/8/8/8/8/8/8/4K3 w") == nil)
        #expect(FEN.parse("4k3 w - - 0 1") == nil)
    }

    @Test func fenRejectsExtraSlashes() throws {
        #expect(FEN.parse("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR/extra w - - 0 1") == nil)
    }

    // MARK: - Board state edge cases

    @Test func setPieceReplacingKingClearsKingSquareCache() throws {
        // Putting an empty square where the king was should clear the cache
        // so subsequent isCheck queries don't reference a stale square.
        let board = Board.standardStartingPosition()
        #expect(board.kingSquare(of: .white) == Square.e1)
        board.setPiece(0, at: Square.e1)
        #expect(board.kingSquare(of: .white) == -1)
        #expect(!board.isInCheck(.white))
    }

    @Test func cloneIsIndependentOfOriginal() throws {
        let original = Board.standardStartingPosition()
        let copy = original.clone()
        _ = original.makeMove(Move(from: Square.parse("e2"), to: Square.parse("e4")))
        // Copy must remain at the starting position.
        #expect(copy.sideToMove == .white)
        #expect(copy.pieceCode(at: Square.parse("e2")) == PieceCode.whitePawn)
        #expect(copy.pieceCode(at: Square.parse("e4")) == 0)
    }

    @Test func zobristEquivalenceUnderHistoryFreeRoute() throws {
        // Setting an empty board then loading via setPiece + setSideToMove +
        // setCastlingRights + setEnPassantSquare should produce the same
        // Zobrist key as parsing the FEN directly.
        let viaFEN = try #require(FEN.parse("4k3/8/8/8/8/8/8/4K3 w - - 0 1"))
        let manual = Board()
        manual.setPiece(PieceCode.whiteKing, at: Square.e1)
        manual.setPiece(PieceCode.blackKing, at: Square.e8)
        manual.setSideToMove(.white)
        manual.setCastlingRights(0)
        manual.setEnPassantSquare(-1)
        #expect(viaFEN.zobristKey == manual.zobristKey)
    }

    @Test func sameSideToMoveSetterIsNoOp() throws {
        let board = Board.standardStartingPosition()
        let before = board.zobristKey
        board.setSideToMove(.white)  // already white
        #expect(board.zobristKey == before)
    }

    // MARK: - Game-level repetition tracking

    @Test func gameWithCustomBoardCountsInitialPosition() throws {
        let board = try #require(FEN.parse("4k3/8/8/8/8/8/8/4K3 w - - 0 1"))
        let game = Game(board: board)
        #expect(game.currentPositionRepetitionCount() == 1)
    }

    @Test func gameUndoReducesRepetitionCount() throws {
        let game = Game()
        let n1 = Move(from: Square.parse("g1"), to: Square.parse("f3"))
        let n2 = Move(from: Square.parse("g8"), to: Square.parse("f6"))
        let n3 = Move(from: Square.parse("f3"), to: Square.parse("g1"))
        let n4 = Move(from: Square.parse("f6"), to: Square.parse("g8"))
        #expect(game.play(n1))
        #expect(game.play(n2))
        #expect(game.play(n3))
        #expect(game.play(n4))
        // We're back at starting position: count should be 2.
        #expect(game.currentPositionRepetitionCount() == 2)
        // Undoing should decrement.
        #expect(game.undoLastMove())
        // After undoing n4, we're no longer at the starting position.
        #expect(game.currentPositionRepetitionCount() == 1)
    }

    @Test func gamePlayRejectsIllegalAndDoesNotMutate() throws {
        let game = Game()
        let illegal = Move(from: Square.parse("e2"), to: Square.parse("e5"))
        let fenBefore = FEN.serialize(game.board)
        let keyBefore = game.board.zobristKey
        let historyBefore = game.moveHistory.count
        let countsBefore = game.currentPositionRepetitionCount()
        #expect(!game.play(illegal))
        #expect(FEN.serialize(game.board) == fenBefore)
        #expect(game.board.zobristKey == keyBefore)
        #expect(game.moveHistory.count == historyBefore)
        #expect(game.currentPositionRepetitionCount() == countsBefore)
    }

    @Test func gameUndoWhenEmptyReturnsFalse() throws {
        let game = Game()
        #expect(!game.undoLastMove())
    }

    @Test func fivefoldRepetitionEndsGameAutomatically() throws {
        let game = Game()
        let n1 = Move(from: Square.parse("g1"), to: Square.parse("f3"))
        let n2 = Move(from: Square.parse("g8"), to: Square.parse("f6"))
        let n3 = Move(from: Square.parse("f3"), to: Square.parse("g1"))
        let n4 = Move(from: Square.parse("f6"), to: Square.parse("g8"))
        // Each loop iteration returns to the starting position once.
        // Initial position is already counted, so loop 4 times → count = 5.
        for _ in 0..<4 {
            #expect(game.play(n1))
            #expect(game.play(n2))
            #expect(game.play(n3))
            #expect(game.play(n4))
        }
        #expect(game.currentPositionRepetitionCount() >= 5)
        let result = game.result()
        switch result {
        case .draw(let reason):
            #expect(reason == GameResult.DrawReason.fivefoldRepetition)
        default:
            #expect(false, "expected fivefold-repetition draw, got \(String(describing: result))")
        }
    }

    // MARK: - Convenience initializers

    @Test func boardFromFENShorthand() throws {
        let board = try #require(Board.fromFEN("4k3/8/8/8/8/8/8/4K3 w - - 0 1"))
        #expect(board.pieceCode(at: Square.e1) == PieceCode.whiteKing)
        #expect(board.pieceCode(at: Square.e8) == PieceCode.blackKing)
        #expect(board.toFEN() == "4k3/8/8/8/8/8/8/4K3 w - - 0 1")
    }

    @Test func boardFromFENReturnsNilOnInvalid() throws {
        #expect(Board.fromFEN("bogus") == nil)
    }

    @Test func gameFromFENShorthand() throws {
        let game = try #require(Game.fromFEN("4k3/8/8/8/8/8/8/4K3 w - - 0 1"))
        #expect(game.currentFEN() == "4k3/8/8/8/8/8/8/4K3 w - - 0 1")
        #expect(game.initialFEN == "4k3/8/8/8/8/8/8/4K3 w - - 0 1")
    }

    @Test func gameFromFENReturnsNilOnInvalid() throws {
        #expect(Game.fromFEN("definitely not a fen") == nil)
    }

    @Test func seventyFiveMoveRuleEndsGameAutomatically() throws {
        // Use a position with sufficient material (so insufficient-material
        // doesn't pre-empt the 75-move check) and a halfmove clock past
        // the 75-move threshold.
        let board = try #require(FEN.parse("4k3/8/8/8/8/8/Q7/4K3 w - - 150 100"))
        let game = Game(board: board)
        let result = game.result()
        switch result {
        case .draw(let reason):
            #expect(reason == GameResult.DrawReason.seventyFiveMoveRule)
        default:
            #expect(false, "expected 75-move-rule draw, got \(String(describing: result))")
        }
    }
}
