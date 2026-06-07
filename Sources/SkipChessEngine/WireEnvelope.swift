// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0
//
// Wire envelope used by the Lichess WebSocket protocol. Every message
// fits a tiny JSON shape:
//
//     { "t": "<type>", "d": <payload?>, "v": <version?>, "a": <ack?>, "l": <lag?> }
//
// with two raw-string special cases for ping/pong:
//
//     "p"      — client ping
//     "0"      — server pong
//
// The implementation is independent of any chess semantics so it can in
// principle drive a Lichess back-end unchanged.

/// A single message moving across the wire.
public struct WireEnvelope: Equatable {
    /// `"t"` — message type (e.g. `"move"`, `"ack"`, `"resync"`).
    public let type: String
    /// `"d"` — typed payload, or `.null` if absent.
    public let data: JSONValue
    /// `"v"` — monotonic version (server → client). `nil` if unversioned.
    public let version: Int?
    /// `"a"` — ack id. Set by the client on must-deliver messages, echoed
    /// by the server in the `"ack"` reply.
    public let ackId: Int?
    /// `"l"` — lag estimate in ms. Lichess clients attach this to every
    /// 10th ping; the server uses it for diagnostics only.
    public let lag: Int?

    public init(
        type: String,
        data: JSONValue = .null,
        version: Int? = nil,
        ackId: Int? = nil,
        lag: Int? = nil
    ) {
        self.type = type
        self.data = data
        self.version = version
        self.ackId = ackId
        self.lag = lag
    }
}

/// JSON ↔ ``WireEnvelope`` codec.
public enum WireCodec {

    /// Raw token a client sends to ask "are you still there?".
    public static let pingToken: String = "p"
    /// Raw token a server sends in response.
    public static let pongToken: String = "0"

    /// Encodes an envelope to a wire string. Pure-`.null` data is omitted
    /// from the output to keep messages compact, matching Lichess's
    /// behaviour.
    public static func encode(_ envelope: WireEnvelope) -> String {
        var entries: [(String, JSONValue)] = []
        entries.append(("t", .string(envelope.type)))
        if let v = envelope.version {
            entries.append(("v", .integer(Int64(v))))
        }
        if let a = envelope.ackId {
            entries.append(("a", .integer(Int64(a))))
        }
        if let l = envelope.lag {
            entries.append(("l", .integer(Int64(l))))
        }
        if envelope.data != .null {
            entries.append(("d", envelope.data))
        }
        return JSONValue.object(entries).encoded()
    }

    /// Decodes a wire string into an envelope. Returns `nil` if the input
    /// is not a recognized envelope shape.
    public static func decode(_ wire: String) -> WireEnvelope? {
        // Bare ping/pong tokens — Lichess sends/receives these without
        // JSON-quoting them at all.
        if wire == pingToken {
            return WireEnvelope(type: pingToken)
        }
        if wire == pongToken {
            return WireEnvelope(type: pongToken)
        }
        guard let value = JSONParser.parse(wire) else { return nil }
        guard case .object(_) = value else { return nil }
        guard let type = value["t"]?.stringValue else { return nil }
        let version = value["v"]?.intValue
        let ackId = value["a"]?.intValue
        let lag = value["l"]?.intValue
        let data = value["d"] ?? .null
        return WireEnvelope(
            type: type,
            data: data,
            version: version,
            ackId: ackId,
            lag: lag,
        )
    }
}
