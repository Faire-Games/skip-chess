# SkipChess web front-end

An [Astro](https://astro.build) page that loads the parent Swift package's
WebAssembly-compiled chess engine and renders a playable board in the
browser.

```
web/
├── public/
│   ├── pieces/                # lichess SVG piece set
│   └── skip-chess-web.wasm    # built by `npm run build:wasm`
├── src/
│   ├── chess-engine.js        # WASM bridge (browser_wasi_shim)
│   ├── chess-ui.js            # board / interaction / persistence
│   ├── main.js                # page entry point
│   ├── styles.css
│   └── pages/index.astro
└── scripts/
    ├── smoketest.mjs          # Node-level WASM smoke test
    ├── browser-test.mjs       # headless Chrome end-to-end test
    └── screenshot.mjs
```

The Swift side — including the `SkipChessWeb` executable target that
produces the `.wasm` — lives one directory up, alongside the iOS/Android
chess library targets.

## Prerequisites

* Swift 6.3.1 toolchain (installed via [swiftly](https://swiftlang.github.io/swiftly/)
  or from swift.org), with bundle id `org.swift.631202604131a`.
* The `swift-6.3.1-RELEASE_wasm` Swift SDK installed via `swift sdk install`.
* Node.js 22+ and npm.

## Build & run

```sh
npm install              # one-time
npm run build:wasm       # compile the Swift → WASM, copy into public/
npm run dev              # http://localhost:4321/
```

`build:wasm` runs

```sh
TOOLCHAINS=org.swift.631202604131a \
  swift build -c release \
              --swift-sdk swift-6.3.1-RELEASE_wasm \
              --package-path .. \
              --product SkipChessWeb
cp ../.build/wasm32-unknown-wasip1/release/SkipChessWeb.wasm \
   public/skip-chess-web.wasm
```

For a production build:

```sh
npm run build            # → dist/
npm run preview          # → http://localhost:4321/
```

## Tests

```sh
npm run test:wasm        # Node smoketest of the WASM ABI
npm run dev -- --port 4444 &
npm run test:browser     # headless Chrome end-to-end
```

## WASM ABI

The `SkipChessWeb` target exposes 21 `@_cdecl` functions over a shared
input/output byte-buffer protocol:

| Export | Signature | Purpose |
|---|---|---|
| `chess_input_ptr()` / `chess_input_capacity()` | `() → i32` | Address and size of the input byte buffer. |
| `chess_output_ptr()` / `chess_output_capacity()` | `() → i32` | Address and size of the output buffer. |
| `chess_new_game()` | `() → i32` | Reset to the standard starting position. |
| `chess_load_fen(len)` | `(i32) → i32` | Load FEN previously written into the input buffer. 0/-1. |
| `chess_current_fen()` | `() → i32` | Write FEN of current position to output buffer; returns byte length. |
| `chess_legal_moves()` | `() → i32` | Space-separated UCI list of legal moves. |
| `chess_legal_moves_from(square)` | `(i32) → i32` | Legal moves whose source square is `square`. |
| `chess_play_move(len)` | `(i32) → i32` | Play UCI from input buffer. 0 success, -1 illegal. |
| `chess_undo_move()` | `() → i32` | Revert the last applied move. 0/-1. |
| `chess_side_to_move()` | `() → i32` | 0 = white, 1 = black. |
| `chess_is_check()` / `chess_is_checkmate()` / `chess_is_stalemate()` | `() → i32` | Boolean (0/1). |
| `chess_king_square(color)` | `(i32) → i32` | 0..63 or -1. |
| `chess_piece_at(square)` | `(i32) → i32` | `PieceCode` integer at square (0 = empty). |
| `chess_game_result()` | `() → i32` | 0 = in progress, 1/2 = checkmate, 3..6 = draw kinds. |
| `chess_configure_engine(depth, timeMs, nodes)` | `(i32, i32, i32) → i32` | Set search budget. Negative values disable that bound. |
| `chess_engine_best_move()` | `() → i32` | Search and write best UCI move to output. |
| `chess_engine_search_summary()` | `() → i32` | Write JSON `{depth, nodes, ms, score, mate, best}` to output. |

The JavaScript wrapper in `src/chess-engine.js` hides this raw ABI behind
a `ChessEngine` class with friendly method names.

## Persistence

The UI auto-saves the current game (FEN + move history + menu settings +
clock state) to `localStorage` after every move and on page-exit, and
restores it on next page load. Storage key:
`skip-chess.game-state.v1`. Clearing site data starts a fresh game.

## Pieces

The board uses a piece set from
[lichess.org/lila](https://github.com/lichess-org/lila/tree/master/public/piece),
fetched into `public/pieces/` during initial setup.

## License

Mozilla Public License 2.0 (matches the parent `skip-chess` package).
The lichess piece SVGs are GPLv3 from the lila project.
