// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0

import SkipChessModel

/// Bounds on how long a chess engine is allowed to search.
///
/// Any combination of bounds may be set; the engine stops as soon as the
/// first one is exceeded. Pass ``SearchLimits/unlimited`` only when an
/// external mechanism (e.g. ``SearchControl/requestStop()``) will terminate
/// the search.
public struct SearchLimits: Sendable {

    /// Maximum search depth in plies. `nil` means no depth bound.
    public let maxDepth: Int?

    /// Maximum number of nodes (positions visited). `nil` means no node bound.
    public let maxNodes: Int64?

    /// Maximum wall-clock time in milliseconds. `nil` means no time bound.
    public let maxMilliseconds: Int64?

    public init(maxDepth: Int? = nil, maxNodes: Int64? = nil, maxMilliseconds: Int64? = nil) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.maxMilliseconds = maxMilliseconds
    }

    /// Search without limits — only stops on a checkmate, stalemate, or
    /// external abort signal.
    public static let unlimited: SearchLimits = SearchLimits()

    /// Search to a fixed depth, ignoring time and node limits.
    public static func depth(_ d: Int) -> SearchLimits {
        return SearchLimits(maxDepth: d)
    }

    /// Search for at most the given wall-clock time.
    public static func time(milliseconds: Int64) -> SearchLimits {
        return SearchLimits(maxMilliseconds: milliseconds)
    }

    /// Search for at most the given number of nodes.
    public static func nodes(_ n: Int64) -> SearchLimits {
        return SearchLimits(maxNodes: n)
    }
}

/// Shared, mutable cooperative cancellation flag. Engines should poll
/// ``isStopRequested`` periodically and abort cleanly when it becomes
/// `true`.
///
/// `SearchControl` is intentionally simple — the underlying flag is a
/// plain `Bool` rather than an atomic. In practice the cancellation signal
/// is set by the UI thread and read by the search thread; the JVM's memory
/// model guarantees that the write will eventually become visible, and an
/// extra few-millisecond delay on cancellation is acceptable for a chess
/// engine.
public final class SearchControl {

    private var stopFlag: Bool

    public init() {
        self.stopFlag = false
    }

    /// Requests that any running search be stopped at the next polling
    /// opportunity.
    public func requestStop() {
        self.stopFlag = true
    }

    /// Resets the control so it can be reused for the next search.
    public func reset() {
        self.stopFlag = false
    }

    /// `true` once ``requestStop()`` has been called.
    public var isStopRequested: Bool {
        return self.stopFlag
    }
}
