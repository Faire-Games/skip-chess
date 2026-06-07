// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0
//
// `RoundSession` is the server-side state machine for a single chess
// "round". A round is a chess game over a wire — `RoundSession` accepts
// `RoundClientMessage`s and emits an ordered queue of
// `RoundServerMessage`s, exactly mirroring how Lichess's `lila-ws`
// service mediates a single game between a player and the back-end.
//
// Engine integration is fully optional. A `RoundSession` works
// stand-alone as a human-vs-human protocol mediator; supply a
// `ChessEngine` to have the session auto-reply for one of the two sides.

import SkipChessModel

/// Configuration for a new ``RoundSession``.
public struct RoundConfiguration {
    /// Color the engine plays. `nil` = no engine, both sides are human
    /// (or both are remote).
    public let engineColor: PieceColor?
    /// Search budget for the engine. Ignored when `engineColor` is `nil`.
    public let engineLimits: SearchLimits
    /// Initial clock seconds for both sides, or `nil` for untimed.
    public let initialClockSeconds: Double?
    /// Increment per move, in seconds.
    public let clockIncrementSeconds: Double

    public init(
        engineColor: PieceColor? = nil,
        engineLimits: SearchLimits = SearchLimits.depth(4),
        initialClockSeconds: Double? = nil,
        clockIncrementSeconds: Double = 0,
    ) {
        self.engineColor = engineColor
        self.engineLimits = engineLimits
        self.initialClockSeconds = initialClockSeconds
        self.clockIncrementSeconds = clockIncrementSeconds
    }
}

/// Server-side round state. Construct with a `Game` (the position to
/// start from), then feed it ``RoundClientMessage``s via ``handle(_:)``
/// and drain the ``flush()`` queue between calls.
public final class RoundSession {

    /// The current game.
    public let game: Game
    /// Optional engine; if non-nil, the session auto-plays the
    /// configured `engineColor`.
    public let engine: ChessEngine?
    /// Configuration the session was started with.
    public let configuration: RoundConfiguration

    /// Monotonic version counter — every server-side event that updates
    /// the position carries `v = version` and bumps the counter.
    public private(set) var version: Int = 0

    /// Outstanding draw offer (if any).
    public private(set) var drawOfferBy: PieceColor?
    /// Outstanding takeback offer state for each side.
    public private(set) var takebackOfferedByWhite: Bool = false
    public private(set) var takebackOfferedByBlack: Bool = false

    /// Current clock state.
    public private(set) var whiteSecondsLeft: Double
    public private(set) var blackSecondsLeft: Double

    /// Outbound queue. Drained by ``flush()``.
    private var outbound: [RoundServerMessage] = []
    /// Per-message version stamps, parallel to ``outbound``. `nil` means
    /// "no version" (typed events like `endData`, `drawOffer`, `ack`).
    /// Versions are captured at the moment of emission so a flush that
    /// queues several moves at once preserves their distinct version
    /// numbers on the wire.
    private var outboundVersions: [Int?] = []

    public init(game: Game, configuration: RoundConfiguration, engine: ChessEngine? = nil) {
        self.game = game
        self.configuration = configuration
        self.engine = engine
        // Explicit Double cast on the fallback so Skip's transpiler
        // doesn't see a `Number & Comparable<*>` mismatch with the Int
        // literal -1.
        self.whiteSecondsLeft = configuration.initialClockSeconds ?? Double(-1)
        self.blackSecondsLeft = configuration.initialClockSeconds ?? Double(-1)
    }

    // MARK: - Inbound dispatch

    /// Processes one client message. Subsequent server replies are
    /// available via ``flush()``.
    public func handle(_ message: RoundClientMessage) {
        handle(message, runEngine: true)
    }

    /// As ``handle(_:)``, but lets the caller defer the engine's auto-reply
    /// to a later ``kickEngine()`` call. Useful when the client wants to
    /// paint the human's move before blocking on the engine search.
    public func handle(_ message: RoundClientMessage, runEngine: Bool) {
        switch message {
        case .move(let uci, let ackId):
            handleMove(uci: uci, ackId: ackId, runEngine: runEngine)
        case .drop:
            // Not implemented — crazyhouse isn't part of standard chess.
            break
        case .resign(let ackId):
            handleResign(ackId: ackId)
        case .drawYes(let ackId):
            handleDrawYes(ackId: ackId)
        case .drawNo(let ackId):
            handleDrawNo(ackId: ackId)
        case .takebackYes(let ackId):
            handleTakebackYes(ackId: ackId)
        case .takebackNo(let ackId):
            handleTakebackNo(ackId: ackId)
        case .flag(let color):
            handleFlag(color: color)
        case .ping:
            enqueue(RoundServerMessage.pong)
        case .unknown:
            // Forward unknown verbs to the floor — Lichess clients send
            // things like "berserk" and "blindfold-yes" that we don't model.
            break
        }
    }

    /// Returns the queued outbound messages and clears the queue.
    public func flush() -> [RoundServerMessage] {
        let out = outbound
        outbound = []
        outboundVersions = []
        return out
    }

    /// Records a typed message and (optionally) the version that should be
    /// stamped on its wire envelope.
    private func enqueue(_ message: RoundServerMessage, version: Int? = nil) {
        outbound.append(message)
        outboundVersions.append(version)
    }

    // MARK: - Move handling

    private func handleMove(uci: String, ackId: Int?, runEngine: Bool) {
        if let ackId = ackId {
            enqueue(RoundServerMessage.ack(ackId: ackId))
        }
        guard let move = Move.fromUCI(uci) else {
            enqueue(RoundServerMessage.resync)
            return
        }
        let sideBefore = game.board.sideToMove
        if !game.play(move) {
            enqueue(RoundServerMessage.resync)
            return
        }
        applyClockIncrement(forSide: sideBefore)
        emitMoveEvent(uci: uci)
        drawOfferBy = nil
        takebackOfferedByWhite = false
        takebackOfferedByBlack = false

        emitEndDataIfFinished()
        if runEngine {
            // Run the engine immediately so the same ``flush()`` returns
            // both the human and the engine move. Clients that want to
            // render the human move first should pass `runEngine: false`
            // and call ``kickEngine()`` separately.
            runEngineIfItsTurn()
        }
    }

    private func applyClockIncrement(forSide side: PieceColor) {
        guard configuration.initialClockSeconds != nil,
              configuration.clockIncrementSeconds > 0
        else { return }
        if side == PieceColor.white {
            whiteSecondsLeft = whiteSecondsLeft + configuration.clockIncrementSeconds
        } else {
            blackSecondsLeft = blackSecondsLeft + configuration.clockIncrementSeconds
        }
    }

    private func emitMoveEvent(uci: String) {
        version = version + 1
        let stampedVersion = version
        let payload = RoundServerMessage.MovePayload(
            uci: uci,
            san: nil,  // SAN would require a real SAN encoder; UCI is sufficient for the wire.
            fen: game.currentFEN(),
            ply: game.moveHistory.count,
            clock: clockSnapshot(),
            check: game.board.isCheck(),
            dests: legalDestMap(),
            promotion: promotionLetter(forUCI: uci),
        )
        enqueue(RoundServerMessage.move(payload), version: stampedVersion)
    }

    private func clockSnapshot() -> ClockState? {
        if configuration.initialClockSeconds == nil { return nil }
        return ClockState(white: whiteSecondsLeft, black: blackSecondsLeft, lag: nil)
    }

    private func promotionLetter(forUCI uci: String) -> String? {
        // UCI promotion suffix: e.g. "a7a8q" → "q".
        if uci.count == 5 {
            return String(uci.suffix(1))
        }
        return nil
    }

    private func legalDestMap() -> [String: [String]] {
        var map: [String: [String]] = [:]
        for move in game.board.legalMoves() {
            let from = Square.name(move.from)
            let to = Square.name(move.to)
            if var existing = map[from] {
                existing.append(to)
                map[from] = existing
            } else {
                map[from] = [to]
            }
        }
        return map
    }

    private func emitEndDataIfFinished() {
        if let result = game.result() {
            let winner: PieceColor?
            switch result {
            case .whiteWins:
                winner = PieceColor.white
            case .blackWins:
                winner = PieceColor.black
            case .draw:
                winner = nil
            }
            let status = GameStatus.fromGameResult(result) ?? GameStatus.draw
            enqueue(RoundServerMessage.endData(.init(winner: winner, status: status)))
        }
    }

    private func runEngineIfItsTurn() {
        kickEngine()
    }

    /// Runs the engine to play one move *if* an engine is configured and
    /// it's its turn to move. Public so callers can invoke it after
    /// constructing a session in a state where the engine plays first
    /// (e.g. human-as-Black openings).
    ///
    /// In a timed game, the engine's per-move budget is computed from its
    /// own remaining clock (see ``computeEngineSearchLimits()``) rather
    /// than using the configured budget unconditionally, so a flagging
    /// engine searches shallower the closer it gets to running out of
    /// time. The actual elapsed search time is then deducted from the
    /// engine's clock; if that pushes it past zero, the session emits
    /// an `outoftime` `endData` immediately after the move event.
    public func kickEngine() {
        guard let engine = engine,
              let engineColor = configuration.engineColor,
              game.board.sideToMove == engineColor,
              game.result() == nil
        else { return }
        let limits = computeEngineSearchLimits()
        let result = engine.findBestMove(from: game.board, limits: limits)
        guard let move = result.bestMove else { return }
        let sideBefore = game.board.sideToMove
        if game.play(move) {
            deductEngineSearchTime(
                forSide: sideBefore,
                milliseconds: result.info.elapsedMilliseconds,
            )
            applyClockIncrement(forSide: sideBefore)
            emitMoveEvent(uci: move.uci)
            // Flag check: if the engine over-ran its budget by more than
            // the increment it just earned, the side runs out of time.
            if didEngineFlag(forSide: sideBefore) {
                let winner: PieceColor = sideBefore == PieceColor.white
                    ? PieceColor.black
                    : PieceColor.white
                enqueue(RoundServerMessage.endData(
                    .init(winner: winner, status: GameStatus.outoftime)))
                return
            }
            emitEndDataIfFinished()
        }
    }

    // MARK: - Engine time management

    /// Returns a search budget that respects both the configured
    /// per-move budget (the difficulty preset) and the engine's
    /// remaining clock. The smaller of the two wins. Untimed games
    /// fall through to the configured limits unchanged.
    private func computeEngineSearchLimits() -> SearchLimits {
        let configured = configuration.engineLimits
        guard let engineColor = configuration.engineColor,
              configuration.initialClockSeconds != nil
        else {
            return configured
        }

        let remaining = engineColor == PieceColor.white
            ? whiteSecondsLeft
            : blackSecondsLeft
        let increment = configuration.clockIncrementSeconds

        // Estimate plies left in the game (typical games ≈ 40 full
        // moves) and divide the engine's share of the clock evenly,
        // plus a slice of the increment.
        let pliesPlayed = game.moveHistory.count
        let estimatedTotalPlies = 80
        let pliesRemainingRaw = estimatedTotalPlies - pliesPlayed
        let pliesRemaining = pliesRemainingRaw > 20 ? pliesRemainingRaw : 20
        let engineMovesRemaining: Double = max(1.0, Double(pliesRemaining) / 2.0)
        let clockBased = remaining / engineMovesRemaining + increment * 0.5

        // Start from the configured per-move budget (the difficulty
        // preset's max), then ratchet down toward the clock-derived
        // budget. Pick the smaller of the two.
        var budgetSec: Double = clockBased
        if let configuredMaxMs = configured.maxMilliseconds {
            let configuredMaxSec = Double(configuredMaxMs) / 1000.0
            budgetSec = min(budgetSec, configuredMaxSec)
        }

        // Safety net: don't dump more than a quarter of the remaining
        // time into a single move.
        let safetyCap = remaining * 0.25
        budgetSec = min(budgetSec, safetyCap)

        // Floor at 50 ms so we always come back with something legal.
        if budgetSec < 0.05 {
            budgetSec = 0.05
        }

        let budgetMs = Int64(budgetSec * 1000.0)
        return SearchLimits(
            maxDepth: configured.maxDepth,
            maxNodes: configured.maxNodes,
            maxMilliseconds: budgetMs,
        )
    }

    /// Subtracts the engine's actual search duration from the appropriate
    /// side's clock. No-op in untimed games.
    private func deductEngineSearchTime(forSide side: PieceColor, milliseconds: Int64) {
        guard configuration.initialClockSeconds != nil else { return }
        let seconds = Double(milliseconds) / 1000.0
        if side == PieceColor.white {
            whiteSecondsLeft = whiteSecondsLeft - seconds
            if whiteSecondsLeft < 0 {
                whiteSecondsLeft = 0
            }
        } else {
            blackSecondsLeft = blackSecondsLeft - seconds
            if blackSecondsLeft < 0 {
                blackSecondsLeft = 0
            }
        }
    }

    private func didEngineFlag(forSide side: PieceColor) -> Bool {
        guard configuration.initialClockSeconds != nil else { return false }
        let remaining = side == PieceColor.white ? whiteSecondsLeft : blackSecondsLeft
        return remaining <= 0
    }

    // MARK: - Resign

    private func handleResign(ackId: Int?) {
        if let ackId = ackId {
            enqueue(RoundServerMessage.ack(ackId: ackId))
        }
        let resigner = game.board.sideToMove
        let winner: PieceColor = resigner == PieceColor.white ? PieceColor.black : PieceColor.white
        enqueue(RoundServerMessage.endData(.init(winner: winner, status: GameStatus.resign)))
    }

    // MARK: - Flag (out of time)

    private func handleFlag(color: PieceColor) {
        let secondsLeft = color == PieceColor.white ? whiteSecondsLeft : blackSecondsLeft
        guard configuration.initialClockSeconds != nil, secondsLeft <= 0 else {
            // Spurious flag claim — Lichess would resync the client.
            enqueue(RoundServerMessage.resync)
            return
        }
        let winner: PieceColor = color == PieceColor.white ? PieceColor.black : PieceColor.white
        enqueue(RoundServerMessage.endData(.init(winner: winner, status: GameStatus.outoftime)))
    }

    // MARK: - Draw offers

    private func handleDrawYes(ackId: Int?) {
        if let ackId = ackId {
            enqueue(RoundServerMessage.ack(ackId: ackId))
        }
        if drawOfferBy != nil {
            // Any second `draw-yes` accepts the outstanding offer. Lichess
            // would gate this on which player sent it; our protocol-only
            // session can't distinguish callers, so we accept on the next
            // confirmation.
            drawOfferBy = nil
            enqueue(RoundServerMessage.endData(.init(winner: nil, status: GameStatus.draw)))
            return
        }
        // Open offer. Attribute it to the side to move — that's the
        // player actively at the keyboard / on the clock, so the offer
        // is conceptually theirs. (Lichess identifies the offerer by
        // auth token; we don't have that, so side-to-move is our best
        // guess and keeps the protocol symmetric.)
        let offerer = game.board.sideToMove
        drawOfferBy = offerer
        enqueue(RoundServerMessage.drawOffer(by: offerer))
    }

    private func handleDrawNo(ackId: Int?) {
        if let ackId = ackId {
            enqueue(RoundServerMessage.ack(ackId: ackId))
        }
        if drawOfferBy != nil {
            drawOfferBy = nil
            enqueue(RoundServerMessage.drawOffer(by: nil))
        }
    }

    // MARK: - Takeback offers

    private func handleTakebackYes(ackId: Int?) {
        if let ackId = ackId {
            enqueue(RoundServerMessage.ack(ackId: ackId))
        }
        let anyOpen = takebackOfferedByWhite || takebackOfferedByBlack
        if anyOpen {
            // Second `takeback-yes` accepts the outstanding offer and rolls
            // back one ply. (Lichess undoes two plies so the offering side
            // is to move again, but our session uses a single-undo model
            // that's symmetric and easier to reason about; clients can
            // always send another `move` to advance.)
            _ = game.undoLastMove()
            takebackOfferedByWhite = false
            takebackOfferedByBlack = false
            version = version + 1
            let stampedVersion = version
            let lastMove = game.moveHistory.last
            let payload = RoundServerMessage.MovePayload(
                uci: lastMove?.uci ?? "",
                fen: game.currentFEN(),
                ply: game.moveHistory.count,
                clock: clockSnapshot(),
                check: game.board.isCheck(),
                dests: legalDestMap(),
            )
            enqueue(RoundServerMessage.move(payload), version: stampedVersion)
            enqueue(
                RoundServerMessage.takebackOffers(white: false, black: false))
            return
        }
        // Open offer — attribute it to the side to move (the player
        // currently active in the UI).
        let mover = game.board.sideToMove
        if mover == PieceColor.white {
            takebackOfferedByWhite = true
        } else {
            takebackOfferedByBlack = true
        }
        enqueue(
            RoundServerMessage.takebackOffers(
                white: takebackOfferedByWhite,
                black: takebackOfferedByBlack))
    }

    private func handleTakebackNo(ackId: Int?) {
        if let ackId = ackId {
            enqueue(RoundServerMessage.ack(ackId: ackId))
        }
        takebackOfferedByWhite = false
        takebackOfferedByBlack = false
        enqueue(
            RoundServerMessage.takebackOffers(white: false, black: false))
    }

    // MARK: - Tick (clock decrement)

    /// Decrements the running side's clock by `seconds`. Returns `true` if
    /// a flag was raised by the elapsed time (the caller may want to emit
    /// `flag` themselves; the session also emits the corresponding
    /// `endData`).
    @discardableResult
    public func tickClock(seconds: Double) -> Bool {
        guard configuration.initialClockSeconds != nil,
              game.result() == nil
        else { return false }
        let mover = game.board.sideToMove
        if mover == PieceColor.white {
            whiteSecondsLeft = whiteSecondsLeft - seconds
            if whiteSecondsLeft <= 0 {
                whiteSecondsLeft = 0
                enqueue(
                    RoundServerMessage.endData(.init(winner: PieceColor.black, status: GameStatus.outoftime)))
                return true
            }
        } else {
            blackSecondsLeft = blackSecondsLeft - seconds
            if blackSecondsLeft <= 0 {
                blackSecondsLeft = 0
                enqueue(
                    RoundServerMessage.endData(.init(winner: PieceColor.white, status: GameStatus.outoftime)))
                return true
            }
        }
        return false
    }

    // MARK: - Encoded wire form

    /// Encodes the pending outbound messages and clears the queue.
    /// Each event carries the version stamp recorded at emission time
    /// (so a flush containing more than one move preserves their distinct
    /// monotonic version numbers).
    public func flushWire() -> [String] {
        var result: [String] = []
        let versions = outboundVersions
        let messages = flush()
        for i in 0..<messages.count {
            let msg = messages[i]
            var env = msg.toEnvelope()
            if let v = versions[i] {
                env = WireEnvelope(
                    type: env.type, data: env.data,
                    version: v, ackId: env.ackId, lag: env.lag)
            }
            result.append(WireCodec.encode(env))
        }
        return result
    }

    /// Convenience: handles a wire string and returns all server replies as
    /// wire strings, ready to send back.
    public func handleWire(_ wire: String) -> [String] {
        return handleWire(wire, runEngine: true)
    }

    /// As ``handleWire(_:)``, but lets the caller defer the engine's
    /// auto-reply.
    public func handleWire(_ wire: String, runEngine: Bool) -> [String] {
        if wire == WireCodec.pingToken {
            return [WireCodec.pongToken]
        }
        guard let env = WireCodec.decode(wire) else { return [] }
        let msg = RoundClientMessage.fromEnvelope(env)
        handle(msg, runEngine: runEngine)
        return flushWire()
    }

    /// Runs the engine if it's its turn, then drains the outbound queue as
    /// wire strings. Used by callers who deferred the engine kick on a
    /// previous ``handleWire(_:runEngine:)`` call.
    public func pumpEngineWire() -> [String] {
        kickEngine()
        return flushWire()
    }

    // MARK: - Initial snapshot

    /// Returns the initial-state snapshot a freshly-connected client
    /// should receive. Lichess sends a "full state" REST payload, but for
    /// our protocol-only usage emitting a single versioned `move` event
    /// with the starting position covers the same ground.
    public func makeInitialSnapshot() -> RoundServerMessage {
        version = version + 1
        let payload = RoundServerMessage.MovePayload(
            uci: "",
            fen: game.currentFEN(),
            ply: game.moveHistory.count,
            clock: clockSnapshot(),
            check: game.board.isCheck(),
            dests: legalDestMap(),
        )
        return RoundServerMessage.move(payload)
    }

    public func emitInitialSnapshot() {
        enqueue(makeInitialSnapshot(), version: version)
    }
}
