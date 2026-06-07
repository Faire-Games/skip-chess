// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0
//
// Web Worker that owns the WASM chess engine. Moving the engine off the
// main thread means a multi-second alpha-beta search no longer blocks the
// page — clocks keep counting down, the UI keeps rendering, and the user
// can still interact with menu items while the engine is thinking.

/// <reference lib="webworker" />

import { WASI, OpenFile, File, ConsoleStdout } from "@bjorn3/browser_wasi_shim";
import type { BoardSnapshot, WorkerRequest } from "./types";

const enc = new TextEncoder();
const dec = new TextDecoder("utf-8");

/**
 * The set of `@_cdecl` exports we use from the WASM binary. Defining the
 * shape here gives us autocomplete and type-checking against accidental
 * typos in the import names.
 */
interface ChessWasmExports {
  memory: WebAssembly.Memory;

  chess_input_ptr: () => number;
  chess_input_capacity: () => number;
  chess_output_ptr: () => number;
  chess_output_capacity: () => number;

  chess_new_game: () => number;
  chess_load_fen: (length: number) => number;
  chess_current_fen: () => number;
  chess_legal_moves: () => number;
  chess_legal_moves_from: (square: number) => number;
  chess_play_move: (length: number) => number;
  chess_undo_move: () => number;
  chess_side_to_move: () => number;
  chess_is_check: () => number;
  chess_king_square: (color: number) => number;
  chess_piece_at: (square: number) => number;
  chess_game_result: () => number;

  chess_protocol_init: (
    humanColorInt: number,
    depth: number,
    timeMs: number,
    initialClockMs: number,
    incrementMs: number,
  ) => number;
  chess_protocol_initial_snapshot: () => number;
  chess_protocol_send: (length: number) => number;
  chess_protocol_pump_engine: () => number;
}

let instance: WebAssembly.Instance | null = null;
let exportsRef: ChessWasmExports | null = null;
let inputPtr = 0;
let inputCapacity = 0;
let outputPtr = 0;
let outputCapacity = 0;

function getExports(): ChessWasmExports {
  if (!exportsRef) throw new Error("WASM not initialized");
  return exportsRef;
}

async function bootstrap(wasmUrl: string): Promise<void> {
  const wasi = new WASI(
    [],
    [],
    [
      new OpenFile(new File([])),
      ConsoleStdout.lineBuffered((m: string) => console.log(`[wasm:stdout] ${m}`)),
      ConsoleStdout.lineBuffered((m: string) => console.warn(`[wasm:stderr] ${m}`)),
    ],
  );
  const wasm = await WebAssembly.instantiateStreaming(fetch(wasmUrl), {
    wasi_snapshot_preview1: wasi.wasiImport,
  });
  try {
    // browser_wasi_shim's start() narrows the instance type to one that
    // exports `memory` + `_start`. We've exported both in the Swift WASM
    // module; the cast just satisfies the static type.
    wasi.start(wasm.instance as Parameters<typeof wasi.start>[0]);
  } catch {
    // WASI's proc_exit always throws; that's expected.
  }
  instance = wasm.instance;
  exportsRef = wasm.instance.exports as unknown as ChessWasmExports;
  inputPtr = exportsRef.chess_input_ptr();
  inputCapacity = exportsRef.chess_input_capacity();
  outputPtr = exportsRef.chess_output_ptr();
  outputCapacity = exportsRef.chess_output_capacity();
  void instance;  // referenced for lifetime; otherwise unused
  void outputCapacity;
}

function writeInput(string: string): number {
  const bytes = enc.encode(string);
  if (bytes.length > inputCapacity) {
    throw new Error(
      `input too long for WASM buffer (${bytes.length} > ${inputCapacity})`,
    );
  }
  new Uint8Array(getExports().memory.buffer, inputPtr, bytes.length).set(bytes);
  return bytes.length;
}

function readOutput(byteLength: number): string {
  if (byteLength <= 0) return "";
  return dec.decode(
    new Uint8Array(getExports().memory.buffer, outputPtr, byteLength),
  );
}

function splitWireReplies(byteLength: number): string[] {
  if (byteLength <= 0) return [];
  return readOutput(byteLength).split("\n");
}

/**
 * Returns a snapshot of the current position. The UI uses this to
 * render the board and detect legal targets without round-tripping to
 * the worker for each square.
 */
function takeSnapshot(): BoardSnapshot {
  const ex = getExports();
  const fen = readOutput(ex.chess_current_fen());
  const sideToMove = ex.chess_side_to_move() === 0 ? "white" : "black";
  const isCheck = ex.chess_is_check() === 1;
  const kingW = ex.chess_king_square(0);
  const kingB = ex.chess_king_square(1);

  const pieces = new Int8Array(64);
  for (let sq = 0; sq < 64; sq++) {
    pieces[sq] = ex.chess_piece_at(sq);
  }

  const legal = readOutput(ex.chess_legal_moves());
  const dests: Record<string, string[]> = {};
  if (legal.length > 0) {
    for (const uci of legal.split(" ")) {
      if (uci.length < 4) continue;
      const from = uci.slice(0, 2);
      const to = uci.slice(2, 4);
      const existing = dests[from];
      if (existing) {
        if (!existing.includes(to)) existing.push(to);
      } else {
        dests[from] = [to];
      }
    }
  }

  return {
    fen,
    sideToMove,
    isCheck,
    kingW,
    kingB,
    pieces,
    dests,
    gameResult: ex.chess_game_result(),
  };
}

self.addEventListener("message", async (ev: MessageEvent<WorkerRequest>) => {
  const data = ev.data;
  if (!data || typeof data.id !== "number") return;
  try {
    let result: unknown;
    switch (data.type) {
      case "init":
        await bootstrap(data.wasmUrl);
        result = takeSnapshot();
        break;

      case "newGame":
        getExports().chess_new_game();
        result = takeSnapshot();
        break;

      case "loadFEN": {
        const len = writeInput(data.fen);
        const ok = getExports().chess_load_fen(len) === 0;
        result = { ok, snapshot: ok ? takeSnapshot() : null };
        break;
      }

      case "currentFEN":
        result = readOutput(getExports().chess_current_fen());
        break;

      case "snapshot":
        result = takeSnapshot();
        break;

      case "undoMove": {
        const ok = getExports().chess_undo_move() === 0;
        result = { ok, snapshot: ok ? takeSnapshot() : null };
        break;
      }

      case "playMove": {
        const len = writeInput(data.uci);
        const ok = getExports().chess_play_move(len) === 0;
        result = { ok, snapshot: ok ? takeSnapshot() : null };
        break;
      }

      case "protocolInit": {
        const code = getExports().chess_protocol_init(
          data.humanColor === "white" ? 0 : 1,
          data.depth,
          data.timeMs,
          data.initialClockMs,
          data.incrementMs,
        );
        result = { ok: code === 0 };
        break;
      }

      case "protocolInitialSnapshot": {
        const len = getExports().chess_protocol_initial_snapshot();
        result = { replies: splitWireReplies(len), snapshot: takeSnapshot() };
        break;
      }

      case "protocolSend": {
        const len = writeInput(data.wire);
        const replyLen = getExports().chess_protocol_send(len);
        result = { replies: splitWireReplies(replyLen), snapshot: takeSnapshot() };
        break;
      }

      case "protocolPumpEngine": {
        const replyLen = getExports().chess_protocol_pump_engine();
        result = { replies: splitWireReplies(replyLen), snapshot: takeSnapshot() };
        break;
      }
    }
    self.postMessage({ id: data.id, ok: true, result });
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    self.postMessage({ id: data.id, ok: false, error: message });
  }
});
