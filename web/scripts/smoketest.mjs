// Headless smoke test for the WASM chess engine. Loads the module via the
// browser_wasi_shim polyfill (same one used in the browser), runs a few
// engine queries, and exits 0 on success.

import { readFile } from "node:fs/promises";
import { WASI, OpenFile, File, ConsoleStdout } from "@bjorn3/browser_wasi_shim";

const wasmBytes = await readFile(
  new URL("../public/skip-chess-web.wasm", import.meta.url),
);

const wasi = new WASI(
  [],
  [],
  [
    new OpenFile(new File([])),
    ConsoleStdout.lineBuffered((msg) => console.log(`[wasm:stdout] ${msg}`)),
    ConsoleStdout.lineBuffered((msg) => console.warn(`[wasm:stderr] ${msg}`)),
  ],
);

const { instance } = await WebAssembly.instantiate(wasmBytes, {
  wasi_snapshot_preview1: wasi.wasiImport,
});

try {
  wasi.start(instance);
} catch (e) {
  // Expected: WASI's proc_exit throws.
}

const ex = instance.exports;
const mem = ex.memory;
const enc = new TextEncoder();
const dec = new TextDecoder();

const inputPtr = ex.chess_input_ptr();
const outputPtr = ex.chess_output_ptr();

function writeIn(s) {
  const b = enc.encode(s);
  new Uint8Array(mem.buffer, inputPtr, b.length).set(b);
  return b.length;
}
function readOut(n) {
  if (n <= 0) return "";
  return dec.decode(new Uint8Array(mem.buffer, outputPtr, n));
}

let failures = 0;
function check(cond, label) {
  if (!cond) {
    console.error(`✗ ${label}`);
    failures++;
  } else {
    console.log(`✓ ${label}`);
  }
}

// 1. New game has the start position.
ex.chess_new_game();
const startFen = readOut(ex.chess_current_fen());
check(
  startFen === "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
  "current_fen returns starting position",
);

// 2. Twenty legal moves from start.
const legal = readOut(ex.chess_legal_moves()).split(" ");
check(legal.length === 20, `start has 20 legal moves (got ${legal.length})`);
check(legal.includes("e2e4"), "e2e4 is in legal moves");

// 3. Playing e2e4 updates side to move.
const e2e4Len = writeIn("e2e4");
check(ex.chess_play_move(e2e4Len) === 0, "play_move e2e4 succeeded");
check(ex.chess_side_to_move() === 1, "side to move is now black");

// 4. Illegal move rejected.
const illegalLen = writeIn("e1e5");
check(ex.chess_play_move(illegalLen) === -1, "play_move e1e5 rejected");

// 5. Undo restores white to move.
check(ex.chess_undo_move() === 0, "undo succeeded");
check(ex.chess_side_to_move() === 0, "side to move is white again");

// 6. Engine returns a legal best move.
ex.chess_configure_engine(3, 1000, -1);
const bestLen = ex.chess_engine_best_move();
const best = readOut(bestLen);
check(best.length >= 4, `engine returned a best move (got "${best}")`);
const legalAfter = readOut(ex.chess_legal_moves()).split(" ");
check(legalAfter.includes(best), `engine's move "${best}" is legal`);

// 7. Search summary returns parseable JSON.
const sumLen = ex.chess_engine_search_summary();
const sum = readOut(sumLen);
const parsed = JSON.parse(sum);
check(typeof parsed.depth === "number", "summary.depth is numeric");
check(typeof parsed.nodes === "number", "summary.nodes is numeric");
check(typeof parsed.best === "string" && parsed.best.length >= 4, "summary.best is a UCI string");

// 8. Lichess-style round protocol: initial snapshot.
// human=white, depth 3, 500ms/move budget, untimed (initialClockMs=-1).
ex.chess_protocol_init(0, 3, 500, -1, 0);
const snapshotLen = ex.chess_protocol_initial_snapshot();
const snapshot = readOut(snapshotLen);
const snapshotEnv = JSON.parse(snapshot);
check(snapshotEnv.t === "move", `initial snapshot is a 'move' envelope (${snapshotEnv.t})`);
check(snapshotEnv.v === 1, `initial snapshot version is 1 (got ${snapshotEnv.v})`);
check(snapshotEnv.d.fen.startsWith("rnbqkbnr"), `snapshot fen starts with rnbqkbnr`);
check(snapshotEnv.d.dests && snapshotEnv.d.dests.e2 && snapshotEnv.d.dests.e2.includes("e4"),
  `snapshot dests has e2 → e4`);

// 9. Round protocol: a `send` returns only the human's move; the
//    engine's reply is fetched via `pump_engine`. This split lets the
//    JS UI paint the human move before the synchronous WASM call
//    blocks for the engine search.
const moveLen = writeIn('{"t":"move","d":{"u":"e2e4"}}');
const replyLen = ex.chess_protocol_send(moveLen);
const replies = readOut(replyLen).split("\n").map((r) => JSON.parse(r));
check(replies.length === 1, `protocol_send replies with human move only (got ${replies.length})`);
check(replies[0].t === "move" && replies[0].d.uci === "e2e4", `human's move is e2e4`);
check(replies[0].v === 2, `human's move is v=2 (got ${replies[0].v})`);

const pumpLen = ex.chess_protocol_pump_engine();
const pumpReplies = readOut(pumpLen).split("\n").map((r) => JSON.parse(r));
check(pumpReplies.length === 1, `pump_engine returns one envelope (got ${pumpReplies.length})`);
check(pumpReplies[0].t === "move" && pumpReplies[0].d.uci.length >= 4,
  `engine's move (${pumpReplies[0].d.uci})`);
check(pumpReplies[0].v === 3, `engine's move is v=3 (got ${pumpReplies[0].v})`);

// pump again with no engine work to do → returns 0
const idlePump = ex.chess_protocol_pump_engine();
check(idlePump === 0, `pump_engine returns 0 when engine has nothing to do (got ${idlePump})`);

// 10. Round protocol: illegal move triggers resync.
const illegalRoundLen = writeIn('{"t":"move","d":{"u":"a1a3"}}');
const illegalReplyLen = ex.chess_protocol_send(illegalRoundLen);
const illegalReplies = readOut(illegalReplyLen).split("\n").map((r) => JSON.parse(r));
check(illegalReplies[0].t === "resync", `illegal move triggers resync (got ${illegalReplies[0].t})`);

// 11. Round protocol: bare ping → bare pong.
const pingLen = writeIn("p");
const pongLen = ex.chess_protocol_send(pingLen);
const pongStr = readOut(pongLen);
check(pongStr === "0", `bare ping → pong (got "${pongStr}")`);

console.log("");
console.log(failures === 0 ? "ALL CHECKS PASSED" : `${failures} CHECKS FAILED`);
process.exit(failures === 0 ? 0 : 1);
