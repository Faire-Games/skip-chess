// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Testing
@testable import SkipChessEngineAlphaBeta
import SkipChessModel

@Suite struct TranspositionTableTests {

    @Test func sizeIsRoundedDownToPowerOfTwo() throws {
        let tt = TranspositionTable(numberOfEntries: 5000)
        // The largest power of 2 ≤ 5000 is 4096.
        #expect(tt.size == 4096)
    }

    @Test func sizeFloorIsApplied() throws {
        let tt = TranspositionTable(numberOfEntries: 100)
        // Floor at 1024.
        #expect(tt.size == 1024)
    }

    @Test func storeAndProbeRoundTrip() throws {
        let tt = TranspositionTable(numberOfEntries: 1024)
        let key: Int64 = 0x123456789ABCDEF
        let move = Move(from: Square.parse("e2"), to: Square.parse("e4"))
        let encoded = CompactMove.encode(move)
        tt.store(key: key, score: 42, depth: 5, bound: TTBound.exact, move: encoded)
        let probe = tt.probe(key: key)
        #expect(probe.found)
        #expect(probe.score == 42)
        #expect(probe.depth == 5)
        #expect(probe.bound == TTBound.exact)
        let decoded = CompactMove.decode(probe.move)
        #expect(decoded == move)
    }

    @Test func probeUnknownKeyReturnsNotFound() throws {
        let tt = TranspositionTable(numberOfEntries: 1024)
        let probe = tt.probe(key: Int64(0xDEADBEEF))
        #expect(!probe.found)
    }

    @Test func clearRemovesEntries() throws {
        let tt = TranspositionTable(numberOfEntries: 1024)
        let key: Int64 = 0x42
        tt.store(key: key, score: 1, depth: 1, bound: TTBound.exact, move: 0)
        #expect(tt.probe(key: key).found)
        tt.clear()
        #expect(!tt.probe(key: key).found)
    }

    @Test func compactMoveRoundTrip() throws {
        let moves = [
            Move(from: 0, to: 63, promotion: 0),
            Move(from: 63, to: 0, promotion: 0),
            Move(from: Square.parse("e2"), to: Square.parse("e4"), promotion: 0),
            Move(from: Square.parse("a7"), to: Square.parse("a8"), promotion: PieceKind.queen.rawValue),
            Move(from: Square.parse("h2"), to: Square.parse("h1"), promotion: PieceKind.knight.rawValue),
        ]
        for m in moves {
            let encoded = CompactMove.encode(m)
            let decoded = CompactMove.decode(encoded)
            #expect(decoded == m)
        }
    }
}
