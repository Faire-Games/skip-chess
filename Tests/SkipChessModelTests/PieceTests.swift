// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
import Foundation
@testable import SkipChessModel

@Suite struct PieceTests {

    @Test func pieceColorOpponent() throws {
        #expect(PieceColor.white.opponent == .black)
        #expect(PieceColor.black.opponent == .white)
        #expect(PieceColor.white.opponent.opponent == .white)
    }

    @Test func pieceColorFenLetter() throws {
        #expect(PieceColor.white.fenLetter == "w")
        #expect(PieceColor.black.fenLetter == "b")
    }

    @Test func pieceKindLetters() throws {
        #expect(PieceKind.pawn.letter == "P")
        #expect(PieceKind.knight.letter == "N")
        #expect(PieceKind.bishop.letter == "B")
        #expect(PieceKind.rook.letter == "R")
        #expect(PieceKind.queen.letter == "Q")
        #expect(PieceKind.king.letter == "K")
    }

    @Test func pieceCodeEncoding() throws {
        #expect(PieceCode.kind(PieceCode.whitePawn) == 1)
        #expect(PieceCode.kind(PieceCode.whiteKing) == 6)
        #expect(PieceCode.kind(PieceCode.blackPawn) == 1)
        #expect(PieceCode.kind(PieceCode.blackKing) == 6)
        #expect(PieceCode.kind(PieceCode.empty) == 0)

        #expect(PieceCode.isWhite(PieceCode.whiteKnight))
        #expect(!PieceCode.isWhite(PieceCode.blackKnight))
        #expect(!PieceCode.isWhite(PieceCode.empty))

        #expect(PieceCode.isBlack(PieceCode.blackBishop))
        #expect(!PieceCode.isBlack(PieceCode.whiteBishop))
        #expect(!PieceCode.isBlack(PieceCode.empty))

        #expect(PieceCode.isEmpty(PieceCode.empty))
        #expect(!PieceCode.isEmpty(PieceCode.whitePawn))
    }

    @Test func pieceCodeMake() throws {
        #expect(PieceCode.make(color: .white, kind: .pawn) == PieceCode.whitePawn)
        #expect(PieceCode.make(color: .white, kind: .knight) == PieceCode.whiteKnight)
        #expect(PieceCode.make(color: .white, kind: .bishop) == PieceCode.whiteBishop)
        #expect(PieceCode.make(color: .white, kind: .rook) == PieceCode.whiteRook)
        #expect(PieceCode.make(color: .white, kind: .queen) == PieceCode.whiteQueen)
        #expect(PieceCode.make(color: .white, kind: .king) == PieceCode.whiteKing)
        #expect(PieceCode.make(color: .black, kind: .pawn) == PieceCode.blackPawn)
        #expect(PieceCode.make(color: .black, kind: .king) == PieceCode.blackKing)
    }

    @Test func pieceCodeFenCharacters() throws {
        #expect(PieceCode.fromFenCharacter("P") == PieceCode.whitePawn)
        #expect(PieceCode.fromFenCharacter("N") == PieceCode.whiteKnight)
        #expect(PieceCode.fromFenCharacter("K") == PieceCode.whiteKing)
        #expect(PieceCode.fromFenCharacter("p") == PieceCode.blackPawn)
        #expect(PieceCode.fromFenCharacter("k") == PieceCode.blackKing)
        #expect(PieceCode.fromFenCharacter("x") == 0)
        #expect(PieceCode.fromFenCharacter(".") == 0)

        #expect(PieceCode.fenCharacter(PieceCode.whitePawn) == "P")
        #expect(PieceCode.fenCharacter(PieceCode.blackKing) == "k")
        #expect(PieceCode.fenCharacter(PieceCode.empty) == ".")
    }

    @Test func pieceCodeRoundTrip() throws {
        let whiteCodes = [PieceCode.whitePawn, PieceCode.whiteKnight, PieceCode.whiteBishop, PieceCode.whiteRook, PieceCode.whiteQueen, PieceCode.whiteKing]
        for code in whiteCodes {
            let char = PieceCode.fenCharacter(code)
            let parsed = PieceCode.fromFenCharacter(Character(char))
            #expect(parsed == code)
        }
        let blackCodes = [PieceCode.blackPawn, PieceCode.blackKnight, PieceCode.blackBishop, PieceCode.blackRook, PieceCode.blackQueen, PieceCode.blackKing]
        for code in blackCodes {
            let char = PieceCode.fenCharacter(code)
            let parsed = PieceCode.fromFenCharacter(Character(char))
            #expect(parsed == code)
        }
    }

    @Test func pieceValue() throws {
        let p = PieceCode.piece(PieceCode.whiteKing)
        #expect(p?.color == .white)
        #expect(p?.kind == .king)
        let q = PieceCode.piece(PieceCode.empty)
        #expect(q == nil)
    }
}
