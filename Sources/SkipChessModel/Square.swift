// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Algebraic notation for a single square on the chess board.
///
/// Squares are encoded as integers `0..<64` in rank-major order: `0 = a1`,
/// `7 = h1`, `56 = a8`, `63 = h8`. The compact integer layout avoids
/// allocation in the engine hot path.
public enum Square {
    /// File component of a square index (0 = a, 7 = h).
    @inlinable
    public static func file(_ square: Int) -> Int {
        return square & 7
    }

    /// Rank component of a square index (0 = rank 1, 7 = rank 8).
    @inlinable
    public static func rank(_ square: Int) -> Int {
        return square >> 3
    }

    /// Builds a square index from file (0..7) and rank (0..7).
    @inlinable
    public static func make(file: Int, rank: Int) -> Int {
        return rank * 8 + file
    }

    /// `true` if both file and rank are in `0..7`.
    @inlinable
    public static func isOnBoard(file: Int, rank: Int) -> Bool {
        return file >= 0 && file < 8 && rank >= 0 && rank < 8
    }

    private static let fileNames: [String] = ["a", "b", "c", "d", "e", "f", "g", "h"]
    private static let rankNames: [String] = ["1", "2", "3", "4", "5", "6", "7", "8"]

    /// Lower-case algebraic name like "e4".
    public static func name(_ square: Int) -> String {
        if square < 0 || square >= 64 {
            return "??"
        }
        let f = file(square)
        let r = rank(square)
        return fileNames[f] + rankNames[r]
    }

    private static let fileLookup: [String: Int] = [
        "a": 0, "b": 1, "c": 2, "d": 3,
        "e": 4, "f": 5, "g": 6, "h": 7
    ]

    private static let rankLookup: [String: Int] = [
        "1": 0, "2": 1, "3": 2, "4": 3,
        "5": 4, "6": 5, "7": 6, "8": 7
    ]

    /// Parses "e4"-style algebraic notation. Returns -1 if invalid.
    public static func parse(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower.count != 2 {
            return -1
        }
        var fileStr = ""
        var rankStr = ""
        var idx = 0
        for c in lower {
            let asString = String(c)
            if idx == 0 {
                fileStr = asString
            } else if idx == 1 {
                rankStr = asString
            }
            idx = idx + 1
        }
        let f = fileLookup[fileStr] ?? -1
        let r = rankLookup[rankStr] ?? -1
        if !isOnBoard(file: f, rank: r) {
            return -1
        }
        return make(file: f, rank: r)
    }

    // MARK: - Named Constants
    public static let a1: Int = 0
    public static let b1: Int = 1
    public static let c1: Int = 2
    public static let d1: Int = 3
    public static let e1: Int = 4
    public static let f1: Int = 5
    public static let g1: Int = 6
    public static let h1: Int = 7
    public static let a8: Int = 56
    public static let b8: Int = 57
    public static let c8: Int = 58
    public static let d8: Int = 59
    public static let e8: Int = 60
    public static let f8: Int = 61
    public static let g8: Int = 62
    public static let h8: Int = 63
}
