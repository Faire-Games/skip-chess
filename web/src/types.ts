// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0
//
// Shared TypeScript types used across the chess web modules.

// ─────────────────────────────────────────────────────  Wire protocol

/**
 * Lichess-style envelope: `{ "t": <type>, "d": <payload?>, "v": <version?>,
 * "a": <ackId?>, "l": <lag?> }`. The payload `d` can be any JSON value;
 * downstream consumers narrow on `t` and then index `d` as the typed
 * payload for that message.
 */
export interface Envelope {
  t: string;
  d?: unknown;
  v?: number;
  a?: number;
  l?: number;
}

/** Server-side `move` payload (Lichess `ClientIn.Move` shape). */
export interface MovePayload {
  uci: string;
  san?: string;
  fen: string;
  ply: number;
  clock?: ClockState;
  check?: boolean;
  dests?: Record<string, string[]>;
  promotion?: string;
  status?: GameStatus;
  winner?: SideColor;
}

export interface ClockState {
  white: number;
  black: number;
  lag?: number;
}

export interface EndDataPayload {
  winner?: SideColor;
  status: GameStatus;
}

/** Lichess `status` strings. We don't try to be exhaustive. */
export type GameStatus =
  | "mate"
  | "resign"
  | "stalemate"
  | "draw"
  | "insufficientMaterial"
  | "fiftyMoves"
  | "threefoldRepetition"
  | "outoftime"
  | string;

export type SideColor = "white" | "black";

// ─────────────────────────────────────────────────────  Engine snapshot

/**
 * Board state pulled from the worker after every state-mutating call.
 * The UI reads from this synchronously (no worker round-trip per square)
 * to keep rendering snappy.
 */
export interface BoardSnapshot {
  fen: string;
  sideToMove: SideColor;
  isCheck: boolean;
  kingW: number;
  kingB: number;
  pieces: Int8Array;
  /** `from` algebraic square → list of `to` algebraic squares. */
  dests: Record<string, string[]>;
  gameResult: number;
}

// ─────────────────────────────────────────────────────  Worker protocol

/** Tagged union of request types posted to the worker. */
export type WorkerRequest =
  | { id: number; type: "init"; wasmUrl: string }
  | { id: number; type: "newGame" }
  | { id: number; type: "loadFEN"; fen: string }
  | { id: number; type: "currentFEN" }
  | { id: number; type: "snapshot" }
  | { id: number; type: "undoMove" }
  | { id: number; type: "playMove"; uci: string }
  | {
      id: number;
      type: "protocolInit";
      humanColor: SideColor;
      depth: number;
      timeMs: number;
      initialClockMs: number;
      incrementMs: number;
    }
  | { id: number; type: "protocolInitialSnapshot" }
  | { id: number; type: "protocolSend"; wire: string }
  | { id: number; type: "protocolPumpEngine" };

/** Discriminated worker response. `id` correlates with `WorkerRequest`. */
export type WorkerResponse =
  | { id: number; ok: true; result: unknown }
  | { id: number; ok: false; error: string };

/**
 * The result shape returned for actions that produce a possibly-new
 * board state and possibly some wire replies.
 */
export interface WorkerStateMutationResult {
  ok: boolean;
  snapshot: BoardSnapshot | null;
}

/** Result of `protocolSend` / `protocolPumpEngine`. */
export interface WorkerProtocolResult {
  replies: string[];
  snapshot: BoardSnapshot;
}

// ─────────────────────────────────────────────────────  Pieces

/** Compact piece-code values matching the WASM-side encoding. */
export const PieceCode = {
  empty: 0,
  whitePawn: 1, whiteKnight: 2, whiteBishop: 3,
  whiteRook: 4, whiteQueen: 5, whiteKing: 6,
  blackPawn: 9, blackKnight: 10, blackBishop: 11,
  blackRook: 12, blackQueen: 13, blackKing: 14,
} as const;

export type PieceCodeValue = (typeof PieceCode)[keyof typeof PieceCode];

const PIECE_NAMES: Record<number, string> = {
  1: "wP", 2: "wN", 3: "wB", 4: "wR", 5: "wQ", 6: "wK",
  9: "bP", 10: "bN", 11: "bB", 12: "bR", 13: "bQ", 14: "bK",
};

/** Lichess piece-set SVG basename for the given piece code (or `null`). */
export function pieceImageName(code: number): string | null {
  return PIECE_NAMES[code] ?? null;
}
