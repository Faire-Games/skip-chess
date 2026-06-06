// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import SkipChessModel

/// Perft (PERformance Test) counts the leaf nodes of the move generation
/// tree to a fixed depth. These are the canonical test positions used to
/// validate chess move generators; getting the exact published counts means
/// our move generator handles every legal/illegal move case correctly.
@Suite struct PerftTests {

    /// Walks the full move tree to `depth` and returns the number of leaf
    /// positions reached.
    static func perft(board: Board, depth: Int) -> Int64 {
        if depth == 0 {
            return 1
        }
        var nodes: Int64 = 0
        var moves: [Move] = []
        moves.reserveCapacity(64)
        MoveGenerator.generateLegalMoves(board: board, into: &moves)
        if depth == 1 {
            return Int64(moves.count)
        }
        for m in moves {
            let undo = board.makeMove(m)
            nodes = nodes + perft(board: board, depth: depth - 1)
            board.unmakeMove(undo)
        }
        return nodes
    }

    @Test func perftStartingPositionDepth1() throws {
        let board = Board.standardStartingPosition()
        #expect(PerftTests.perft(board: board, depth: 1) == 20)
    }

    @Test func perftStartingPositionDepth2() throws {
        let board = Board.standardStartingPosition()
        #expect(PerftTests.perft(board: board, depth: 2) == 400)
    }

    @Test func perftStartingPositionDepth3() throws {
        let board = Board.standardStartingPosition()
        #expect(PerftTests.perft(board: board, depth: 3) == 8902)
    }

    @Test func perftStartingPositionDepth4() throws {
        // Canonical perft value: 197,281 nodes at depth 4 from start.
        let board = Board.standardStartingPosition()
        #expect(PerftTests.perft(board: board, depth: 4) == 197281)
    }

    @Test func perftKiwipeteDepth1() throws {
        let board = try #require(FEN.parse("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"))
        #expect(PerftTests.perft(board: board, depth: 1) == 48)
    }

    @Test func perftKiwipeteDepth2() throws {
        let board = try #require(FEN.parse("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"))
        #expect(PerftTests.perft(board: board, depth: 2) == 2039)
    }

    @Test func perftEndgamePosition3Depth4() throws {
        // Position 3 (endgame): 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1
        let board = try #require(FEN.parse("8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1"))
        #expect(PerftTests.perft(board: board, depth: 1) == 14)
        #expect(PerftTests.perft(board: board, depth: 2) == 191)
        #expect(PerftTests.perft(board: board, depth: 3) == 2812)
        #expect(PerftTests.perft(board: board, depth: 4) == 43238)
    }

    @Test func perftPosition4Depth3() throws {
        // Position 4: r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1
        let board = try #require(FEN.parse("r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1"))
        #expect(PerftTests.perft(board: board, depth: 1) == 6)
        #expect(PerftTests.perft(board: board, depth: 2) == 264)
        #expect(PerftTests.perft(board: board, depth: 3) == 9467)
    }

    @Test func perftPosition5Depth3() throws {
        let board = try #require(FEN.parse("rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8"))
        #expect(PerftTests.perft(board: board, depth: 1) == 44)
        #expect(PerftTests.perft(board: board, depth: 2) == 1486)
        #expect(PerftTests.perft(board: board, depth: 3) == 62379)
    }
}
