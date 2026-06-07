// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0
//
// Main-thread proxy for the WASM chess engine. The actual WASM module
// is owned by a Web Worker (see `chess-worker.ts`); this class:
//
//   1. Forwards request/response pairs to the worker over `postMessage`
//      (every public method that needs WASM is async).
//   2. Caches the latest board snapshot locally — `pieces`, `dests`,
//      `sideToMove`, `isCheck`, etc. — so the UI keeps its synchronous
//      render and click-handling code without round-tripping per square.

import type {
  BoardSnapshot,
  Envelope,
  SideColor,
  WorkerProtocolResult,
  WorkerRequest,
  WorkerResponse,
  WorkerStateMutationResult,
} from "./types";

// Re-export pieceImageName and PieceCode for legacy callers — they used
// to live here before the TS split.
export { PieceCode, pieceImageName } from "./types";

const WORKER_URL = new URL("./chess-worker.ts", import.meta.url);

function emptySnapshot(): BoardSnapshot {
  return {
    fen: "",
    sideToMove: "white",
    isCheck: false,
    kingW: -1,
    kingB: -1,
    pieces: new Int8Array(64),
    dests: {},
    gameResult: 0,
  };
}

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
}

interface GameResultDescriptor {
  code: number;
  label: string;
}

const GAME_RESULT_LABELS: Record<number, string> = {
  0: "In progress",
  1: "White wins by checkmate",
  2: "Black wins by checkmate",
  3: "Draw by stalemate",
  4: "Draw by insufficient material",
  5: "Draw by 50/75-move rule",
  6: "Draw by repetition",
};

export class ChessEngine {
  /**
   * Spawns the worker, loads the WASM, and resolves with a ready
   * engine. The returned engine's `snapshot` field is already populated
   * with the post-`_start` board state.
   */
  static async load(wasmUrl: string): Promise<ChessEngine> {
    const worker = new Worker(WORKER_URL, {
      type: "module",
      name: "skip-chess-engine",
    });
    const engine = new ChessEngine(worker);
    engine._installMessagePump();
    const snapshot = (await engine._call("init", { wasmUrl })) as BoardSnapshot;
    engine._applySnapshot(snapshot);
    return engine;
  }

  readonly worker: Worker;
  private _nextId = 1;
  private readonly _pending = new Map<number, PendingRequest>();
  /** Latest board snapshot. UI reads this synchronously. */
  snapshot: BoardSnapshot = emptySnapshot();

  constructor(worker: Worker) {
    this.worker = worker;
  }

  private _installMessagePump(): void {
    this.worker.addEventListener("message", (ev: MessageEvent<WorkerResponse>) => {
      const data = ev.data;
      if (!data || typeof data.id !== "number") return;
      const pending = this._pending.get(data.id);
      if (!pending) return;
      this._pending.delete(data.id);
      if (data.ok) pending.resolve(data.result);
      else pending.reject(new Error(data.error));
    });
    this.worker.addEventListener("error", (ev) => {
      console.error("chess-worker error:", ev.message || ev);
    });
  }

  private _call<T = unknown>(
    type: WorkerRequest["type"],
    payload: Record<string, unknown> = {},
  ): Promise<T> {
    const id = this._nextId++;
    return new Promise<T>((resolve, reject) => {
      this._pending.set(id, {
        resolve: resolve as (value: unknown) => void,
        reject,
      });
      // We construct a plain message and let TS trust us — the worker
      // re-narrows on `type` and rejects unknowns.
      const message = { id, type, ...payload } as unknown as WorkerRequest;
      this.worker.postMessage(message);
    });
  }

  private _applySnapshot(snapshot: BoardSnapshot | null | undefined): void {
    if (snapshot) this.snapshot = snapshot;
  }

  // MARK: - State-mutating actions (async)

  async newGame(): Promise<void> {
    const snapshot = await this._call<BoardSnapshot>("newGame");
    this._applySnapshot(snapshot);
  }

  async loadFEN(fen: string): Promise<boolean> {
    const { ok, snapshot } = await this._call<WorkerStateMutationResult>(
      "loadFEN", { fen },
    );
    if (ok) this._applySnapshot(snapshot);
    return ok;
  }

  async undoMove(): Promise<boolean> {
    const { ok, snapshot } = await this._call<WorkerStateMutationResult>("undoMove");
    if (ok) this._applySnapshot(snapshot);
    return ok;
  }

  async refreshSnapshot(): Promise<void> {
    const snapshot = await this._call<BoardSnapshot>("snapshot");
    this._applySnapshot(snapshot);
  }

  async currentFENAsync(): Promise<string> {
    return this._call<string>("currentFEN");
  }

  // MARK: - Protocol bridge

  async protocolInit(args: {
    humanColor: SideColor;
    depth: number;
    timeMs: number;
    initialClockMs: number;
    incrementMs: number;
  }): Promise<void> {
    await this._call<{ ok: boolean }>("protocolInit", { ...args });
  }

  async protocolInitialSnapshot(): Promise<Envelope[]> {
    const { replies, snapshot } = await this._call<WorkerProtocolResult>(
      "protocolInitialSnapshot",
    );
    this._applySnapshot(snapshot);
    return parseEnvelopes(replies);
  }

  async protocolSend(wire: string): Promise<string[]> {
    const { replies, snapshot } = await this._call<WorkerProtocolResult>(
      "protocolSend", { wire },
    );
    this._applySnapshot(snapshot);
    return replies;
  }

  /**
   * Runs the engine on the worker thread. The main thread stays
   * responsive while this Promise pends — clocks tick, UI repaints.
   */
  async protocolPumpEngine(): Promise<string[]> {
    const { replies, snapshot } = await this._call<WorkerProtocolResult>(
      "protocolPumpEngine",
    );
    this._applySnapshot(snapshot);
    return replies;
  }

  // MARK: - Synchronous board queries (read from cache)

  get currentFEN(): string {
    return this.snapshot.fen;
  }

  sideToMove(): SideColor {
    return this.snapshot.sideToMove;
  }

  isCheck(): boolean {
    return this.snapshot.isCheck;
  }

  kingSquare(color: SideColor): number {
    return color === "white" ? this.snapshot.kingW : this.snapshot.kingB;
  }

  pieceAt(square: number): number {
    return this.snapshot.pieces[square] ?? 0;
  }

  legalMovesFrom(square: number): string[] {
    const fromName = squareName(square);
    const targets = this.snapshot.dests[fromName] || [];
    return targets.map((toName) => fromName + toName);
  }

  legalMoves(): string[] {
    const result: string[] = [];
    for (const [from, tos] of Object.entries(this.snapshot.dests)) {
      for (const to of tos) result.push(from + to);
    }
    return result;
  }

  gameResult(): GameResultDescriptor {
    const code = this.snapshot.gameResult;
    return { code, label: GAME_RESULT_LABELS[code] || "Unknown" };
  }
}

function squareName(square: number): string {
  const file = square & 7;
  const rank = square >> 3;
  return String.fromCharCode(97 + file) + String.fromCharCode(49 + rank);
}

function parseEnvelopes(raw: string[]): Envelope[] {
  const out: Envelope[] = [];
  for (const line of raw) {
    try {
      out.push(JSON.parse(line) as Envelope);
    } catch {
      /* ignore */
    }
  }
  return out;
}
