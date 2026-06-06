// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import SkipChessModel

@Suite struct SquareTests {

    @Test func fileAndRank() throws {
        #expect(Square.file(0) == 0)
        #expect(Square.rank(0) == 0)
        #expect(Square.file(7) == 7)
        #expect(Square.rank(7) == 0)
        #expect(Square.file(8) == 0)
        #expect(Square.rank(8) == 1)
        #expect(Square.file(63) == 7)
        #expect(Square.rank(63) == 7)
        #expect(Square.file(28) == 4)  // e4
        #expect(Square.rank(28) == 3)
    }

    @Test func makeAndOnBoard() throws {
        #expect(Square.make(file: 0, rank: 0) == 0)
        #expect(Square.make(file: 7, rank: 7) == 63)
        #expect(Square.make(file: 4, rank: 3) == 28)
        #expect(Square.isOnBoard(file: 0, rank: 0))
        #expect(Square.isOnBoard(file: 7, rank: 7))
        #expect(!Square.isOnBoard(file: -1, rank: 0))
        #expect(!Square.isOnBoard(file: 0, rank: -1))
        #expect(!Square.isOnBoard(file: 8, rank: 0))
        #expect(!Square.isOnBoard(file: 0, rank: 8))
    }

    @Test func namedConstants() throws {
        #expect(Square.a1 == 0)
        #expect(Square.h1 == 7)
        #expect(Square.a8 == 56)
        #expect(Square.h8 == 63)
        #expect(Square.e1 == 4)
        #expect(Square.e8 == 60)
        #expect(Square.d1 == 3)
        #expect(Square.d8 == 59)
    }

    @Test func nameFormatting() throws {
        #expect(Square.name(Square.a1) == "a1")
        #expect(Square.name(Square.h1) == "h1")
        #expect(Square.name(Square.a8) == "a8")
        #expect(Square.name(Square.h8) == "h8")
        #expect(Square.name(28) == "e4")
        #expect(Square.name(35) == "d5")
        #expect(Square.name(60) == "e8")
    }

    @Test func parseSquareName() throws {
        #expect(Square.parse("a1") == 0)
        #expect(Square.parse("h1") == 7)
        #expect(Square.parse("a8") == 56)
        #expect(Square.parse("h8") == 63)
        #expect(Square.parse("e4") == 28)
        #expect(Square.parse("d5") == 35)
        // Case-insensitive
        #expect(Square.parse("E4") == 28)
        // Invalid
        #expect(Square.parse("i1") == -1)
        #expect(Square.parse("a9") == -1)
        #expect(Square.parse("") == -1)
        #expect(Square.parse("e44") == -1)
    }

    @Test func roundTripNames() throws {
        for sq in 0..<64 {
            let name = Square.name(sq)
            let parsed = Square.parse(name)
            #expect(parsed == sq)
        }
    }
}
