// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import SkipChessModel

/// Type of node-evaluation bound stored in a transposition table entry.
public enum TTBound {
    /// Stored score is the exact PV value.
    public static let exact: Int = 0
    /// Stored score is an upper bound (i.e. an alpha-cutoff: real value ≤ score).
    public static let upper: Int = 1
    /// Stored score is a lower bound (i.e. a beta-cutoff: real value ≥ score).
    public static let lower: Int = 2
}

/// Result of a transposition-table probe.
public struct TTProbe {
    /// `true` if a matching entry was found.
    public let found: Bool
    /// Stored score (only valid when `found` is true).
    public let score: Int
    /// Stored depth (only valid when `found` is true).
    public let depth: Int
    /// One of ``TTBound`` constants (only valid when `found` is true).
    public let bound: Int
    /// Compact move encoding (from | to<<6 | promotion<<12); 0 if none.
    public let move: Int
}

/// A small, fast, replacement-by-depth transposition table.
///
/// The table uses a power-of-two size so indexing is a single mask
/// operation. Parallel `Int64` / `Int` arrays keep the per-entry footprint
/// JVM-friendly: no boxed objects, just primitives. Older entries are
/// overwritten unconditionally — the engine's search order keeps the most
/// useful (deepest, most recent) entries near the top of the iterative
/// deepening cycle.
public final class TranspositionTable {

    private let mask: Int
    /// Zobrist key for each slot (0 if empty).
    private var keys: [Int64]
    /// Packed entry: score, depth, bound, move.
    private var scores: [Int]
    private var depths: [Int]
    private var bounds: [Int]
    private var moves: [Int]

    /// Creates a table containing approximately `numberOfEntries` entries.
    /// The actual size is rounded down to the nearest power of two so that
    /// indexing is a single bitmask.
    public init(numberOfEntries: Int) {
        var size = 1
        while size * 2 <= numberOfEntries {
            size = size * 2
        }
        if size < 1024 {
            size = 1024  // floor at 1k entries
        }
        mask = size - 1
        keys = [Int64](repeating: 0, count: size)
        scores = [Int](repeating: 0, count: size)
        depths = [Int](repeating: -1, count: size)
        bounds = [Int](repeating: 0, count: size)
        moves = [Int](repeating: 0, count: size)
    }

    /// Removes all entries from the table.
    public func clear() {
        for i in 0..<keys.count {
            keys[i] = 0
            depths[i] = -1
        }
    }

    /// The number of slots in the table.
    public var size: Int {
        return keys.count
    }

    /// Stores a position entry. If a previous entry occupies the slot it is
    /// replaced unconditionally.
    public func store(key: Int64, score: Int, depth: Int, bound: Int, move: Int) {
        let idx = Int(key & Int64(mask))
        keys[idx] = key
        scores[idx] = score
        depths[idx] = depth
        bounds[idx] = bound
        moves[idx] = move
    }

    /// Looks up a position by Zobrist key. The `found` flag indicates
    /// whether the slot contained a matching key — callers should always
    /// check it before using the other fields.
    public func probe(key: Int64) -> TTProbe {
        let idx = Int(key & Int64(mask))
        if keys[idx] == key {
            return TTProbe(found: true, score: scores[idx], depth: depths[idx], bound: bounds[idx], move: moves[idx])
        }
        return TTProbe(found: false, score: 0, depth: 0, bound: 0, move: 0)
    }
}

// MARK: - Compact move encoding helpers

/// Helpers for packing/unpacking a ``Move`` into a 16-bit integer.
public enum CompactMove {
    /// Pack a ``Move`` into an ``Int``.
    @inlinable
    public static func encode(_ move: Move) -> Int {
        return move.from | (move.to << 6) | (move.promotion << 12)
    }

    /// Unpack to a ``Move``. Returns a move with `from == to == 0` when
    /// `encoded` is 0 (sentinel for "no move").
    @inlinable
    public static func decode(_ encoded: Int) -> Move {
        return Move(
            from: encoded & 0x3F,
            to: (encoded >> 6) & 0x3F,
            promotion: (encoded >> 12) & 0x7
        )
    }
}
