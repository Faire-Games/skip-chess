// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0
//
// Lichess-style socket layer. The wire shape is a tiny JSON envelope
//
//     { "t": "<type>", "d": <payload?>, "v": <version?>,
//       "a": <ackId?>, "l": <lag?> }
//
// plus the bare-string ping/pong pair `"p"` / `"0"`.
//
// `Socket` is transport-agnostic — it takes a `send(msg)` function and
// pushes any returned wire strings back through `_receive`. The bundled
// `wasmTransport()` adapts the WASM `chess_protocol_send` export into
// that interface, but the same Socket can drive a real
// `wss://socket.lichess.ovh/...` WebSocket by swapping the transport.
//
// Behavior mirrors `lichess-org/lila/ui/lib/src/socket.ts`:
//   - keep-alive pings every `pingDelay` ms; every 10th ping carries a
//     `{t:"p", l: lag}` lag estimate.
//   - exponential moving-average lag tracker (first 4 pongs equal-weight,
//     then α = 0.1).
//   - version-gap detector: if `m.v > lastVersion + 1` the event is
//     parked until the missing one(s) arrive; a `{t:"resync"}` from the
//     server clears local state.
//   - ack queue with timer-based resends for `send(..., {ackable:true})`
//     messages; the server's `{t:"ack", d:<id>}` removes the entry.

import type { ChessEngine } from "./chess-engine";
import type { Envelope } from "./types";

const PING_DELAY_MS = 2500;
const RESEND_DELAY_MS = 1200;
const ACK_TIMEOUT_MS = 2500;

export type SocketSend = (wire: string) => Promise<string[] | undefined>;
export type SocketSubscribe = (
  handler: (wire: string) => void,
) => () => void;

export type SocketMessageHandler = (
  type: string,
  payload: unknown,
  env: Envelope,
) => void;

export interface SocketOptions {
  send: SocketSend;
  subscribe?: SocketSubscribe;
  onMessage: SocketMessageHandler;
  onResync?: (reason: string) => void;
  onLagChanged?: () => void;
}

interface AckEntry {
  wire: string;
  lastSentMs: number;
  resolve: () => void;
}

export class Socket {
  private readonly _send: SocketSend;
  private readonly _onMessage: SocketMessageHandler;
  private readonly _onResync: (reason: string) => void;
  private readonly _onLagChanged: () => void;
  private _version = 0;
  private readonly _pendingByVersion = new Map<number, Envelope>();
  private readonly _ackQueue = new Map<number, AckEntry>();
  private _nextAckId = 1;
  private _lagMs = 0;
  private _lagSamples = 0;
  private _pingsSent = 0;
  private _pendingPingSentAtMs: number | null = null;
  private _pingTimer: ReturnType<typeof setTimeout> | null = null;
  private _ackTimer: ReturnType<typeof setTimeout> | null = null;
  private _unsubscribe: (() => void) | null = null;

  constructor(options: SocketOptions) {
    this._send = options.send;
    this._onMessage = options.onMessage;
    this._onResync = options.onResync ?? (() => {});
    this._onLagChanged = options.onLagChanged ?? (() => {});
    if (options.subscribe) {
      this._unsubscribe = options.subscribe((wire) => this._receive(wire));
    }
  }

  /**
   * Sends a typed envelope. Resolves when the server acknowledges (for
   * `{ackable: true}`) or immediately otherwise.
   */
  async send(
    type: string,
    payload?: unknown,
    options: { ackable?: boolean } = {},
  ): Promise<void> {
    const env: Envelope = { t: type };
    if (payload !== undefined) env.d = payload;
    const ackable = !!options.ackable;
    if (ackable) {
      env.a = this._nextAckId++;
    }
    const wire = JSON.stringify(env);
    await this._dispatchWire(wire);

    if (!ackable) return;
    return new Promise<void>((resolve) => {
      this._ackQueue.set(env.a as number, {
        wire,
        lastSentMs: this._now(),
        resolve,
      });
      this._ensureAckTimer();
    });
  }

  /** Sends a raw wire string. */
  private async _dispatchWire(wire: string): Promise<void> {
    const replies = (await this._send(wire)) ?? [];
    for (const reply of replies) {
      this._receive(reply);
    }
  }

  /** Starts the ping / ack loops. Must be called once after construction. */
  start(): void {
    this._schedulePing();
  }

  /** Stops timers and unsubscribes from the transport. */
  stop(): void {
    if (this._pingTimer) clearTimeout(this._pingTimer);
    if (this._ackTimer) clearTimeout(this._ackTimer);
    this._pingTimer = null;
    this._ackTimer = null;
    this._unsubscribe?.();
  }

  get currentLag(): number { return this._lagMs; }
  get lastVersion(): number { return this._version; }
  get pendingAckCount(): number { return this._ackQueue.size; }

  // ──────────────────────────────────────────────────── Ping / pong

  private _schedulePing(): void {
    this._pingTimer = setTimeout(() => { void this._sendPing(); }, PING_DELAY_MS);
  }

  private async _sendPing(): Promise<void> {
    this._pingsSent++;
    this._pendingPingSentAtMs = this._now();
    if (this._pingsSent % 10 === 0 && this._lagSamples > 0) {
      await this._dispatchWire(
        JSON.stringify({ t: "p", l: Math.round(this._lagMs / 100) }),
      );
    } else {
      await this._dispatchWire("p");
    }
    this._schedulePing();
  }

  private _onPongReceived(): void {
    if (this._pendingPingSentAtMs == null) return;
    const sample = this._now() - this._pendingPingSentAtMs;
    this._pendingPingSentAtMs = null;
    if (this._lagSamples < 4) {
      this._lagMs = (this._lagMs * this._lagSamples + sample) / (this._lagSamples + 1);
    } else {
      this._lagMs = this._lagMs + 0.1 * (sample - this._lagMs);
    }
    this._lagSamples++;
    this._onLagChanged();
  }

  // ──────────────────────────────────────────────────── Acks

  private _ensureAckTimer(): void {
    if (this._ackTimer) return;
    this._ackTimer = setTimeout(() => {
      this._resendStaleAcks();
      this._ackTimer = null;
      if (this._ackQueue.size > 0) this._ensureAckTimer();
    }, RESEND_DELAY_MS);
  }

  private _resendStaleAcks(): void {
    const now = this._now();
    for (const entry of this._ackQueue.values()) {
      if (now - entry.lastSentMs >= ACK_TIMEOUT_MS) {
        // Fire-and-forget — the next pass will retry if it failed.
        void this._dispatchWire(entry.wire);
        entry.lastSentMs = now;
      }
    }
  }

  // ──────────────────────────────────────────────────── Inbound

  _receive(wire: string): void {
    if (wire === "0") {
      this._onPongReceived();
      return;
    }
    if (wire === "p") {
      // Server-initiated ping (Lichess does this on some channels).
      void this._dispatchWire("0");
      return;
    }
    let env: Envelope;
    try {
      env = JSON.parse(wire) as Envelope;
    } catch (e) {
      console.warn("socket: malformed envelope", wire, e);
      return;
    }
    if (!env || typeof env.t !== "string") return;

    if (env.t === "ack" && typeof env.d === "number") {
      const entry = this._ackQueue.get(env.d);
      if (entry) {
        this._ackQueue.delete(env.d);
        entry.resolve();
      }
      return;
    }

    if (env.t === "resync") {
      this._version = 0;
      this._pendingByVersion.clear();
      this._onResync("server requested resync");
      return;
    }

    if (typeof env.v === "number") {
      if (env.v <= this._version) return;  // duplicate / stale
      if (env.v > this._version + 1) {
        this._pendingByVersion.set(env.v, env);
        return;
      }
      this._version = env.v;
      this._onMessage(env.t, env.d, env);
      this._drainPending();
      return;
    }

    this._onMessage(env.t, env.d, env);
  }

  private _drainPending(): void {
    for (;;) {
      const next = this._pendingByVersion.get(this._version + 1);
      if (!next) return;
      this._pendingByVersion.delete(next.v as number);
      this._version = next.v as number;
      this._onMessage(next.t, next.d, next);
    }
  }

  private _now(): number {
    return performance.now();
  }
}

// ─────────────────────────────────────────────────────  Transport

/**
 * Returns a transport function that forwards `Socket.send` to the
 * ChessEngine's worker proxy. The transport is async — every call
 * resolves with the array of wire-string replies the worker produced.
 */
export function wasmTransport(engine: ChessEngine): SocketSend {
  return async (wire: string) => engine.protocolSend(wire);
}

/**
 * Initializes a fresh round at the standard starting position and
 * returns the initial snapshot envelope(s). When the engine plays
 * first, its first move comes back on the same line.
 */
export async function initRound(
  engine: ChessEngine,
  humanColor: "white" | "black",
  depth: number,
  timeMs: number,
  initialClockSeconds = -1,
  incrementSeconds = 0,
): Promise<Envelope[]> {
  await engine.newGame();
  return _initWithSnapshot(
    engine, humanColor, depth, timeMs,
    initialClockSeconds, incrementSeconds,
  );
}

/**
 * Like `initRound` but starts from a saved FEN. Resolves with `null` if
 * the FEN was rejected.
 */
export async function resumeRound(
  engine: ChessEngine,
  fen: string,
  humanColor: "white" | "black",
  depth: number,
  timeMs: number,
  initialClockSeconds = -1,
  incrementSeconds = 0,
): Promise<Envelope[] | null> {
  if (!(await engine.loadFEN(fen))) return null;
  return _initWithSnapshot(
    engine, humanColor, depth, timeMs,
    initialClockSeconds, incrementSeconds,
  );
}

async function _initWithSnapshot(
  engine: ChessEngine,
  humanColor: "white" | "black",
  depth: number,
  timeMs: number,
  initialClockSeconds: number,
  incrementSeconds: number,
): Promise<Envelope[]> {
  const initialMs = initialClockSeconds >= 0
    ? Math.round(initialClockSeconds * 1000)
    : -1;
  const incMs = Math.round(Math.max(0, incrementSeconds) * 1000);
  await engine.protocolInit({
    humanColor,
    depth,
    timeMs,
    initialClockMs: initialMs,
    incrementMs: incMs,
  });
  return engine.protocolInitialSnapshot();
}

/**
 * Asks the worker to run the engine. The search happens off the main
 * thread — clocks tick, UI repaints — and the returned Promise resolves
 * after every envelope has been routed into the socket.
 */
export async function pumpEngine(
  engine: ChessEngine,
  socket: Socket,
): Promise<boolean> {
  const replies = await engine.protocolPumpEngine();
  if (!replies || replies.length === 0) return false;
  for (const reply of replies) {
    socket._receive(reply);
  }
  return true;
}
