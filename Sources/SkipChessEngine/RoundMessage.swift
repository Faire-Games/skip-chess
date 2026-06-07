// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0
//
// Typed round-protocol messages. The names mirror Lichess's wire vocabulary
// (`move`, `resign`, `draw-yes`, …) so a client written against a real
// Lichess server can drive this implementation unchanged, and vice versa.

import SkipChessModel

// MARK: - Clock state on the wire

/// Clock snapshot included in every server-side `move` event.
public struct ClockState: Equatable {
    /// Seconds remaining on White's clock.
    public let white: Double
    /// Seconds remaining on Black's clock.
    public let black: Double
    /// Server's estimate of the moving player's lag in tenths of a second.
    /// `nil` means "unknown".
    public let lag: Int?

    public init(white: Double, black: Double, lag: Int? = nil) {
        self.white = white
        self.black = black
        self.lag = lag
    }

    public func toJSON() -> JSONValue {
        var entries: [(String, JSONValue)] = [
            ("white", .double(white)),
            ("black", .double(black)),
        ]
        if let lag = lag {
            entries.append(("lag", .integer(Int64(lag))))
        }
        return .object(entries)
    }

    public static func fromJSON(_ value: JSONValue) -> ClockState? {
        guard let white = value["white"]?.doubleValue,
              let black = value["black"]?.doubleValue
        else { return nil }
        return ClockState(white: white, black: black, lag: value["lag"]?.intValue)
    }
}

// MARK: - Game end reasons

/// Game-end reason as a Lichess-style status string. Strings (not enum
/// names) cross the wire so the client can extend without re-compiling.
public enum GameStatus: String, Equatable, Sendable {
    case checkmate = "mate"
    case resign = "resign"
    case stalemate = "stalemate"
    case draw = "draw"
    case insufficientMaterial = "insufficientMaterial"
    case fiftyMoves = "fiftyMoves"
    case threefoldRepetition = "threefoldRepetition"
    case outoftime = "outoftime"

    public static func fromGameResult(_ result: GameResult?) -> GameStatus? {
        guard let r = result else { return nil }
        switch r {
        case .whiteWins, .blackWins:
            return GameStatus.checkmate
        case .draw(let reason):
            switch reason {
            case GameResult.DrawReason.stalemate:
                return GameStatus.stalemate
            case GameResult.DrawReason.insufficientMaterial:
                return GameStatus.insufficientMaterial
            case GameResult.DrawReason.fiftyMoveRule, GameResult.DrawReason.seventyFiveMoveRule:
                return GameStatus.fiftyMoves
            case GameResult.DrawReason.threefoldRepetition, GameResult.DrawReason.fivefoldRepetition:
                return GameStatus.threefoldRepetition
            case GameResult.DrawReason.agreement:
                return GameStatus.draw
            }
        }
    }
}

// MARK: - Client → Server messages

/// A message the client sends to the server. Names match Lichess's
/// `ctrl.ts` `socket.send(t, d, opts?)` calls.
public enum RoundClientMessage: Equatable {
    /// `"move"` — a UCI string in `d.u` (with an optional promotion suffix).
    case move(uci: String, ackId: Int? = nil)
    /// `"drop"` — crazyhouse drop. Not implemented by this engine but the
    /// envelope is recognized so a client can be tested against us.
    case drop(role: String, square: Int, ackId: Int? = nil)
    /// `"resign"` — the current side resigns.
    case resign(ackId: Int? = nil)
    /// `"draw-yes"` — offer / accept a draw.
    case drawYes(ackId: Int? = nil)
    /// `"draw-no"` — decline an outstanding draw offer.
    case drawNo(ackId: Int? = nil)
    /// `"takeback-yes"` — offer / accept a takeback.
    case takebackYes(ackId: Int? = nil)
    /// `"takeback-no"` — decline an outstanding takeback offer.
    case takebackNo(ackId: Int? = nil)
    /// `"flag"` — claim the opponent's clock has run out.
    case flag(color: PieceColor)
    /// `"p"` — keep-alive ping. May carry a lag estimate.
    case ping(lag: Int?)
    /// Anything else that round upstream might add later.
    case unknown(type: String, data: JSONValue)

    /// Renders this client message to a wire envelope ready for the server.
    public func toEnvelope() -> WireEnvelope {
        switch self {
        case .move(let uci, let ackId):
            return WireEnvelope(
                type: "move",
                data: .object([("u", .string(uci))]),
                ackId: ackId,
            )
        case .drop(let role, let square, let ackId):
            return WireEnvelope(
                type: "drop",
                data: .object([
                    ("role", .string(role)),
                    ("pos", .integer(Int64(square))),
                ]),
                ackId: ackId,
            )
        case .resign(let ackId):
            return WireEnvelope(type: "resign", ackId: ackId)
        case .drawYes(let ackId):
            return WireEnvelope(type: "draw-yes", ackId: ackId)
        case .drawNo(let ackId):
            return WireEnvelope(type: "draw-no", ackId: ackId)
        case .takebackYes(let ackId):
            return WireEnvelope(type: "takeback-yes", ackId: ackId)
        case .takebackNo(let ackId):
            return WireEnvelope(type: "takeback-no", ackId: ackId)
        case .flag(let color):
            return WireEnvelope(
                type: "flag",
                data: .string(color == PieceColor.white ? "white" : "black"),
            )
        case .ping(let lag):
            if let lag = lag {
                return WireEnvelope(type: "p", lag: lag)
            }
            // The optimized common case is the bare "p" token; callers
            // serialize this via WireCodec.pingToken directly.
            return WireEnvelope(type: "p")
        case .unknown(let type, let data):
            return WireEnvelope(type: type, data: data)
        }
    }

    /// Parses an incoming envelope into a typed client message.
    public static func fromEnvelope(_ envelope: WireEnvelope) -> RoundClientMessage {
        switch envelope.type {
        case "move":
            let uci = envelope.data["u"]?.stringValue ?? ""
            return .move(uci: uci, ackId: envelope.ackId)
        case "drop":
            let role = envelope.data["role"]?.stringValue ?? "p"
            let pos = envelope.data["pos"]?.intValue ?? -1
            return .drop(role: role, square: pos, ackId: envelope.ackId)
        case "resign":
            return .resign(ackId: envelope.ackId)
        case "draw-yes":
            return .drawYes(ackId: envelope.ackId)
        case "draw-no":
            return .drawNo(ackId: envelope.ackId)
        case "takeback-yes":
            return .takebackYes(ackId: envelope.ackId)
        case "takeback-no":
            return .takebackNo(ackId: envelope.ackId)
        case "flag":
            let raw = envelope.data.stringValue ?? "white"
            let color: PieceColor = raw == "black" ? PieceColor.black : PieceColor.white
            return .flag(color: color)
        case "p":
            return .ping(lag: envelope.lag)
        default:
            return .unknown(type: envelope.type, data: envelope.data)
        }
    }
}

// MARK: - Server → Client messages

/// A message the server sends to the client. Matches Lichess's `ClientIn`
/// vocabulary.
public enum RoundServerMessage: Equatable {
    /// `"move"` — a versioned move (or position update) for the client.
    case move(MovePayload)
    /// `"endData"` — the game has just ended.
    case endData(EndDataPayload)
    /// `"drawOffer"` — somebody just offered / declined a draw.
    case drawOffer(by: PieceColor?)
    /// `"takebackOffers"` — current takeback-offer state for both sides.
    case takebackOffers(white: Bool, black: Bool)
    /// `"crowd"` — spectator counts. Always `(0, 0)` from this engine, but
    /// part of the wire vocabulary.
    case crowd(white: Bool, black: Bool, watchers: Int)
    /// `"ack"` — server acknowledging a previously-ack'ed client message.
    case ack(ackId: Int)
    /// `"resync"` — client should re-fetch full state from the server.
    case resync
    /// `"pong"` — the bare `"0"` reply to a `"p"` ping.
    case pong
    /// Anything else.
    case unknown(type: String, data: JSONValue, version: Int?)

    public struct MovePayload: Equatable {
        public let uci: String
        public let san: String?
        public let fen: String
        public let ply: Int
        public let clock: ClockState?
        public let check: Bool
        public let dests: [String: [String]]?
        public let promotion: String?
        public let status: GameStatus?
        public let winner: PieceColor?

        public init(
            uci: String,
            san: String? = nil,
            fen: String,
            ply: Int,
            clock: ClockState? = nil,
            check: Bool = false,
            dests: [String: [String]]? = nil,
            promotion: String? = nil,
            status: GameStatus? = nil,
            winner: PieceColor? = nil,
        ) {
            self.uci = uci
            self.san = san
            self.fen = fen
            self.ply = ply
            self.clock = clock
            self.check = check
            self.dests = dests
            self.promotion = promotion
            self.status = status
            self.winner = winner
        }

        public func toJSON() -> JSONValue {
            var entries: [(String, JSONValue)] = []
            entries.append(("uci", .string(uci)))
            if let san = san {
                entries.append(("san", .string(san)))
            }
            entries.append(("fen", .string(fen)))
            entries.append(("ply", .integer(Int64(ply))))
            if let clock = clock {
                entries.append(("clock", clock.toJSON()))
            }
            if check {
                entries.append(("check", .bool(true)))
            }
            if let dests = dests {
                var destEntries: [(String, JSONValue)] = []
                // Sort keys for stable wire output (helpful in tests).
                let sortedKeys = dests.keys.sorted()
                for from in sortedKeys {
                    let tos = dests[from] ?? []
                    destEntries.append((from, .array(tos.map { s in JSONValue.string(s) })))
                }
                entries.append(("dests", .object(destEntries)))
            }
            if let promotion = promotion {
                entries.append(("promotion", .string(promotion)))
            }
            if let status = status {
                entries.append(("status", .string(status.rawValue)))
            }
            if let winner = winner {
                entries.append(("winner", .string(winner == PieceColor.white ? "white" : "black")))
            }
            return .object(entries)
        }

        public static func fromJSON(_ value: JSONValue) -> MovePayload? {
            guard let uci = value["uci"]?.stringValue,
                  let fen = value["fen"]?.stringValue,
                  let ply = value["ply"]?.intValue
            else { return nil }
            var dests: [String: [String]]? = nil
            if let destObj = value["dests"]?.objectEntries {
                var map: [String: [String]] = [:]
                for entry in destObj {
                    var tos: [String] = []
                    for v in entry.1.arrayValue ?? [] {
                        if let s = v.stringValue { tos.append(s) }
                    }
                    map[entry.0] = tos
                }
                dests = map
            }
            let statusRaw = value["status"]?.stringValue
            let status: GameStatus? = statusRaw.flatMap { GameStatus(rawValue: $0) }
            let winnerRaw = value["winner"]?.stringValue
            let winner: PieceColor? = winnerRaw == "white" ? PieceColor.white
                : (winnerRaw == "black" ? PieceColor.black : nil)
            return MovePayload(
                uci: uci,
                san: value["san"]?.stringValue,
                fen: fen,
                ply: Int(ply),
                clock: value["clock"].flatMap { ClockState.fromJSON($0) },
                check: value["check"]?.boolValue ?? false,
                dests: dests,
                promotion: value["promotion"]?.stringValue,
                status: status,
                winner: winner,
            )
        }
    }

    public struct EndDataPayload: Equatable {
        public let winner: PieceColor?  // nil = draw
        public let status: GameStatus

        public init(winner: PieceColor?, status: GameStatus) {
            self.winner = winner
            self.status = status
        }

        public func toJSON() -> JSONValue {
            var entries: [(String, JSONValue)] = []
            if let winner = winner {
                entries.append(("winner", .string(winner == PieceColor.white ? "white" : "black")))
            }
            entries.append(("status", .string(status.rawValue)))
            return .object(entries)
        }

        public static func fromJSON(_ value: JSONValue) -> EndDataPayload? {
            guard let statusRaw = value["status"]?.stringValue,
                  let status = GameStatus(rawValue: statusRaw)
            else { return nil }
            let winnerRaw = value["winner"]?.stringValue
            let winner: PieceColor? = winnerRaw == "white" ? PieceColor.white
                : (winnerRaw == "black" ? PieceColor.black : nil)
            return EndDataPayload(winner: winner, status: status)
        }
    }

    public func toEnvelope() -> WireEnvelope {
        switch self {
        case .move(let payload):
            return WireEnvelope(type: "move", data: payload.toJSON(), version: nil)
        case .endData(let payload):
            return WireEnvelope(type: "endData", data: payload.toJSON())
        case .drawOffer(let by):
            let payload: JSONValue
            if let by = by {
                payload = .string(by == PieceColor.white ? "white" : "black")
            } else {
                payload = .null
            }
            return WireEnvelope(type: "drawOffer", data: payload)
        case .takebackOffers(let w, let b):
            return WireEnvelope(
                type: "takebackOffers",
                data: .object([("white", .bool(w)), ("black", .bool(b))]),
            )
        case .crowd(let w, let b, let watchers):
            return WireEnvelope(
                type: "crowd",
                data: .object([
                    ("white", .bool(w)),
                    ("black", .bool(b)),
                    ("watchers", .integer(Int64(watchers))),
                ]),
            )
        case .ack(let ackId):
            return WireEnvelope(type: "ack", data: .integer(Int64(ackId)))
        case .resync:
            return WireEnvelope(type: "resync")
        case .pong:
            // Renders to the bare "0" token; callers usually emit
            // WireCodec.pongToken directly.
            return WireEnvelope(type: "0")
        case .unknown(let type, let data, _):
            return WireEnvelope(type: type, data: data)
        }
    }

    public static func fromEnvelope(_ envelope: WireEnvelope) -> RoundServerMessage {
        switch envelope.type {
        case "move":
            if let payload = MovePayload.fromJSON(envelope.data) {
                return .move(payload)
            }
            return .unknown(type: envelope.type, data: envelope.data, version: envelope.version)
        case "endData":
            if let payload = EndDataPayload.fromJSON(envelope.data) {
                return .endData(payload)
            }
            return .unknown(type: envelope.type, data: envelope.data, version: envelope.version)
        case "drawOffer":
            let raw = envelope.data.stringValue
            let by: PieceColor? = raw == "white" ? PieceColor.white : (raw == "black" ? PieceColor.black : nil)
            return .drawOffer(by: by)
        case "takebackOffers":
            let w = envelope.data["white"]?.boolValue ?? false
            let b = envelope.data["black"]?.boolValue ?? false
            return .takebackOffers(white: w, black: b)
        case "crowd":
            let w = envelope.data["white"]?.boolValue ?? false
            let b = envelope.data["black"]?.boolValue ?? false
            let watchers = envelope.data["watchers"]?.intValue ?? 0
            return .crowd(white: w, black: b, watchers: watchers)
        case "ack":
            return .ack(ackId: envelope.data.intValue ?? 0)
        case "resync":
            return .resync
        case "0":
            return .pong
        default:
            return .unknown(type: envelope.type, data: envelope.data, version: envelope.version)
        }
    }
}
