// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0
//
// Chess game UI driver. Renders the board, handles user input (click +
// drag), and asks the WASM engine for replies.

import { ChessEngine, pieceImageName } from "./chess-engine";
import {
  Socket, wasmTransport, initRound, resumeRound, pumpEngine,
} from "./socket";
import type {
  ClockState, EndDataPayload, Envelope, MovePayload, SideColor,
} from "./types";

const FILES = ["a", "b", "c", "d", "e", "f", "g", "h"];
const RANKS = ["1", "2", "3", "4", "5", "6", "7", "8"];

/** localStorage key. Bumped if the saved-state schema ever breaks. */
const STORAGE_KEY = "skip-chess.game-state.v1";

export interface DifficultyPreset {
  id: string;
  label: string;
  elo: number;
  depth: number;
  timeMs: number;
}

export interface TimeControlPreset {
  id: string;
  label: string;
  initialSeconds: number;
  incrementSeconds: number;
}

/**
 * Difficulty presets — each maps to (depth, time) search budgets and an
 * approximate ELO estimate. Numbers are rough self-play observations
 * against fixed-depth opponents, not strict ELO calibration.
 */
export const DIFFICULTIES: DifficultyPreset[] = [
  { id: "easy",   label: "Easy",   elo: 800,  depth: 1, timeMs: 100 },
  { id: "medium", label: "Medium", elo: 1100, depth: 2, timeMs: 250 },
  { id: "hard",   label: "Hard",   elo: 1500, depth: 4, timeMs: 750 },
  { id: "expert", label: "Expert", elo: 1800, depth: 6, timeMs: 2500 },
  { id: "master", label: "Master", elo: 2100, depth: 8, timeMs: 5000 },
];

/** Time controls offered by the menu. */
export const TIME_CONTROLS: TimeControlPreset[] = [
  { id: "untimed",   label: "Untimed",          initialSeconds: -1,   incrementSeconds: 0 },
  { id: "blitz3",    label: "Blitz 3+2",        initialSeconds: 180,  incrementSeconds: 2 },
  { id: "blitz5",    label: "Blitz 5+0",        initialSeconds: 300,  incrementSeconds: 0 },
  { id: "rapid10",   label: "Rapid 10+0",       initialSeconds: 600,  incrementSeconds: 0 },
  { id: "classical", label: "Classical 30+30",  initialSeconds: 1800, incrementSeconds: 30 },
];

export interface ChessGameUIOptions {
  boardEl: HTMLElement;
  statusEl: HTMLElement;
  moveListEl: HTMLElement;
  whiteClockEl: HTMLElement;
  blackClockEl: HTMLElement;
  /** Tray for the black pieces White has captured. */
  whiteCapturesEl?: HTMLElement | null;
  /** Tray for the white pieces Black has captured. */
  blackCapturesEl?: HTMLElement | null;
  evalEl: HTMLElement;
  undoBtn: HTMLButtonElement;
  resignBtn: HTMLButtonElement;
  // Game-result banner surfaces (shown below the board on game end).
  gameOverOverlayEl?: HTMLElement | null;
  gameOverResultEl?: HTMLElement | null;
  gameOverReasonEl?: HTMLElement | null;
  gameOverIconEl?: HTMLElement | null;
  /** "Replay" button on the result banner. */
  gameOverReplayBtn?: HTMLButtonElement | null;
  // Replay-panel surfaces (shown when the user enters replay mode).
  replayPanelEl?: HTMLElement | null;
  replaySliderEl?: HTMLInputElement | null;
  replayCounterEl?: HTMLElement | null;
  replayMoveLabelEl?: HTMLElement | null;
  replayFirstBtn?: HTMLButtonElement | null;
  replayPrevBtn?: HTMLButtonElement | null;
  replayNextBtn?: HTMLButtonElement | null;
  replayLastBtn?: HTMLButtonElement | null;
  replayExitBtn?: HTMLButtonElement | null;
}

export interface StartNewGameOptions {
  humanColor: "white" | "black" | "random";
  difficultyId: string;
  timeControlId: string;
}

export interface MoveHistoryEntry {
  san: string;
  fen: string;
}

interface LastMove {
  from: number;
  to: number;
}

interface SavedGameState {
  version: number;
  fen: string;
  initialFen?: string;
  humanColor: SideColor;
  difficultyId: string;
  timeControlId: string;
  whiteSecondsLeft: number;
  blackSecondsLeft: number;
  moveHistory: MoveHistoryEntry[];
  lastMove: LastMove | null;
  gameOver: boolean;
  endData: EndDataPayload | null;
}

const STARTING_FEN =
  "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

interface SearchInfo {
  mate: number;
  score: number;
  depth: number;
  nodes: number;
  ms: number;
}

interface CaptureMap { [pieceKind: number]: number }

interface CaptureResult {
  whiteCaptured: CaptureMap;
  blackCaptured: CaptureMap;
  materialDiff: number;
}

export class ChessGameUI {
  private readonly boardEl: HTMLElement;
  private readonly statusEl: HTMLElement;
  private readonly moveListEl: HTMLElement;
  private readonly whiteClockEl: HTMLElement;
  private readonly blackClockEl: HTMLElement;
  private readonly whiteCapturesEl: HTMLElement | null;
  private readonly blackCapturesEl: HTMLElement | null;
  private readonly evalEl: HTMLElement;
  private readonly undoBtn: HTMLButtonElement;
  private readonly resignBtn: HTMLButtonElement;
  private readonly gameOverOverlayEl: HTMLElement | null;
  private readonly gameOverResultEl: HTMLElement | null;
  private readonly gameOverReasonEl: HTMLElement | null;
  private readonly gameOverIconEl: HTMLElement | null;
  private readonly gameOverReplayBtn: HTMLButtonElement | null;

  // Replay panel surfaces
  private readonly replayPanelEl: HTMLElement | null;
  private readonly replaySliderEl: HTMLInputElement | null;
  private readonly replayCounterEl: HTMLElement | null;
  private readonly replayMoveLabelEl: HTMLElement | null;
  private readonly replayFirstBtn: HTMLButtonElement | null;
  private readonly replayPrevBtn: HTMLButtonElement | null;
  private readonly replayNextBtn: HTMLButtonElement | null;
  private readonly replayLastBtn: HTMLButtonElement | null;
  private readonly replayExitBtn: HTMLButtonElement | null;

  /** Last endData payload (kept so we can re-show the overlay on resume). */
  private _lastEndData: EndDataPayload | null = null;

  /** FEN of the position at ply 0 of the current game — required so the
   *  replay slider can rewind to "before any move was played". */
  private initialFEN: string = STARTING_FEN;

  /** True while the user is scrubbing through past moves. While set, the
   *  engine is showing a historical position and accepting no input. */
  private replayMode = false;
  /** Ply index currently shown in replay mode (0 = initial position). */
  private replayPly = 0;
  /** Snapshot of `engine.currentFEN` at the moment replay was entered.
   *  Restored when the user exits replay so play resumes correctly. */
  private replayFinalFEN: string | null = null;

  engine: ChessEngine | null = null;
  private socket: Socket | null = null;

  // Game configuration (set via configure())
  humanColor: SideColor = "white";
  difficulty: DifficultyPreset = DIFFICULTIES[2]!;
  timeControl: TimeControlPreset = TIME_CONTROLS[0]!;

  // Clock state
  private whiteSecondsLeft = -1;
  private blackSecondsLeft = -1;
  private clockTimerId: number | null = null;
  private lastClockTickMs: number | null = null;
  /** Player whose clock is currently running */
  private runningClockSide: SideColor | null = null;
  private gameOver = false;

  // UI state for piece selection
  private selectedSquare: number | null = null;
  private highlightedSquares = new Set<number>();
  private lastMove: LastMove | null = null;

  // Drag state
  private draggingPiece: HTMLElement | null = null;
  private dragFromSquare: number | null = null;
  private dragOffsetX = 0;
  private dragOffsetY = 0;

  moveHistory: MoveHistoryEntry[] = [];

  private boardSquares: HTMLElement[] = [];
  private _scaffoldOrientation: SideColor | null = null;
  private _globalPointerHandlersInstalled = false;

  constructor(options: ChessGameUIOptions) {
    this.boardEl = options.boardEl;
    this.statusEl = options.statusEl;
    this.moveListEl = options.moveListEl;
    this.whiteClockEl = options.whiteClockEl;
    this.blackClockEl = options.blackClockEl;
    this.whiteCapturesEl = options.whiteCapturesEl ?? null;
    this.blackCapturesEl = options.blackCapturesEl ?? null;
    this.evalEl = options.evalEl;
    this.undoBtn = options.undoBtn;
    this.resignBtn = options.resignBtn;

    // Optional game-over overlay surfaces. When present, an end-of-game
    // event (`endData`) populates them and unhides the overlay; starting
    // a new game hides it again.
    this.gameOverOverlayEl = options.gameOverOverlayEl ?? null;
    this.gameOverResultEl = options.gameOverResultEl ?? null;
    this.gameOverReasonEl = options.gameOverReasonEl ?? null;
    this.gameOverIconEl = options.gameOverIconEl ?? null;
    this.gameOverReplayBtn = options.gameOverReplayBtn ?? null;
    this.replayPanelEl = options.replayPanelEl ?? null;
    this.replaySliderEl = options.replaySliderEl ?? null;
    this.replayCounterEl = options.replayCounterEl ?? null;
    this.replayMoveLabelEl = options.replayMoveLabelEl ?? null;
    this.replayFirstBtn = options.replayFirstBtn ?? null;
    this.replayPrevBtn = options.replayPrevBtn ?? null;
    this.replayNextBtn = options.replayNextBtn ?? null;
    this.replayLastBtn = options.replayLastBtn ?? null;
    this.replayExitBtn = options.replayExitBtn ?? null;

    this.undoBtn.addEventListener("click", () => { void this.undoUserMove(); });
    this.resignBtn.addEventListener("click", () => this.resign());

    this._installReplayHandlers();

    // Persist current state when the user navigates away. `beforeunload`
    // catches refreshes and tab closes; `visibilitychange` catches
    // backgrounding on mobile, where `beforeunload` is unreliable.
    window.addEventListener("beforeunload", () => this._saveState());
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "hidden") this._saveState();
    });
  }

  // MARK: - Initialization

  async start(wasmUrl: string): Promise<void> {
    this.engine = await ChessEngine.load(wasmUrl);
    this.renderBoardScaffold();
  }

  /** Reconfigures and starts a new game. */
  async startNewGame({ humanColor, difficultyId, timeControlId }: StartNewGameOptions): Promise<void> {
    if (!this.engine) return;
    this.humanColor = resolveHumanColor(humanColor);
    this.difficulty =
      DIFFICULTIES.find((d) => d.id === difficultyId) ?? DIFFICULTIES[2]!;
    this.timeControl =
      TIME_CONTROLS.find((t) => t.id === timeControlId) ?? TIME_CONTROLS[0]!;

    // Hide any leftover game-over banner from a previous game.
    this._hideGameOverOverlay();
    if (this.replayMode) this._exitReplayImmediate();
    this.initialFEN = STARTING_FEN;

    // Reset and bootstrap the round protocol session inside the WASM.
    this._installSocket();
    const envelopes = await initRound(
      this.engine,
      this.humanColor,
      this.difficulty.depth,
      this.difficulty.timeMs,
      this.timeControl.initialSeconds,
      this.timeControl.incrementSeconds,
    );
    // Snapshot may include the engine's first move when the engine plays
    // first; route every envelope through the socket so version tracking
    // and message dispatch stay consistent.
    for (const env of envelopes) {
      this.socket?._receive(JSON.stringify(env));
    }

    this.whiteSecondsLeft = this.timeControl.initialSeconds;
    this.blackSecondsLeft = this.timeControl.initialSeconds;
    this.moveHistory = [];
    this.lastMove = null;
    this.selectedSquare = null;
    this.highlightedSquares.clear();
    this.gameOver = false;
    this.stopClock();

    this.renderBoard();
    this.renderClocks();
    this.renderMoves();
    this.updateStatus();
    this._saveState();

    // The initial snapshot already includes the engine's reply when
    // the engine plays first, so no extra kick is needed here.
    this.maybeStartClock();
  }

  // MARK: - Socket transport
  //
  // The UI talks to the WASM module through the lichess-shape Socket
  // wrapper rather than calling the low-level chess_* functions
  // directly. This means the same UI code could later swap the
  // `wasmTransport` for a real `wss://socket.lichess.ovh/...` connection
  // without rewriting the move / resign / draw flows.

  private _installSocket(): void {
    if (this.socket) this.socket.stop();
    if (!this.engine) return;
    this.socket = new Socket({
      send: wasmTransport(this.engine),
      onMessage: (type, data, env) => this._handleSocketMessage(type, data, env),
      onResync: () => {
        // The engine asked us to refresh — our local UI is the source of
        // truth in this single-tab demo, so we just log it. A real
        // Lichess client would refetch the round REST payload.
        console.warn("socket: server requested resync");
      },
    });
    this.socket.start();
  }

  /**
   * Dispatch incoming server-side envelopes. The Lichess client splits
   * this up into many small handler functions; we keep it inline because
   * we only model a handful of message types.
   */
  private _handleSocketMessage(type: string, data: unknown, env: Envelope): void {
    switch (type) {
      case "move":
        this._applyServerMove(data as MovePayload, env);
        break;
      case "endData":
        this._applyEndData(data as EndDataPayload);
        break;
      case "drawOffer":
        // `data` is "white" / "black" or absent. Could surface a UI banner.
        break;
      case "takebackOffers":
      case "ack":
      case "crowd":
        break;
      default:
        // Ignore unknown messages — Lichess clients are forward-compatible.
        break;
    }
  }

  private _applyServerMove(d: MovePayload, _env: Envelope): void {
    if (!this.engine) return;
    // The server is authoritative; the worker has already advanced its
    // internal position and refreshed our cached snapshot before this
    // event handler fires, so we don't need a separate loadFEN call.

    // After the worker's snapshot, `sideToMove` is whoever is about to
    // move; the side that just moved is therefore the OPPOSITE colour.
    // (For the boot snapshot — `uci === ""` — nobody moved, so we treat
    // it as "neither" and let the clock sync run for both sides.)
    const sideToMove = this.engine.sideToMove();
    const sideThatMoved: SideColor = sideToMove === "white" ? "black" : "white";
    const isRealMove = !!(d.uci && d.uci.length >= 4);
    const isEngineMove = isRealMove && sideThatMoved !== this.humanColor;
    const isHumanMove = isRealMove && sideThatMoved === this.humanColor;

    if (isRealMove) {
      this.lastMove = {
        from: parseSquare(d.uci.slice(0, 2)),
        to: parseSquare(d.uci.slice(2, 4)),
      };
      this.moveHistory.push({ san: d.uci, fen: d.fen });
    }

    // Clock synchronization. The server only authoritatively tracks the
    // engine's clock (because its search blocks the JS thread, so JS-side
    // tick can't subtract that time); the human's clock is tracked
    // locally via `tickClock`. So:
    //  - on a boot snapshot: take both clocks from the server (initial
    //    values).
    //  - on an engine move: sync ONLY the engine-side clock from the
    //    server's just-computed deduction.
    //  - on a human move: don't touch clocks (already accurate locally),
    //    but apply the increment we just earned.
    if (d.clock) {
      const clock: ClockState = d.clock;
      if (!isRealMove) {
        this.whiteSecondsLeft = clock.white;
        this.blackSecondsLeft = clock.black;
      } else if (isEngineMove) {
        if (sideThatMoved === "white") {
          this.whiteSecondsLeft = clock.white;
        } else {
          this.blackSecondsLeft = clock.black;
        }
      }
    }
    if (isHumanMove && this.timeControl.incrementSeconds > 0) {
      if (this.humanColor === "white") {
        this.whiteSecondsLeft += this.timeControl.incrementSeconds;
      } else {
        this.blackSecondsLeft += this.timeControl.incrementSeconds;
      }
    }

    this.clearSelection();
    this.renderBoard();
    this.renderMoves();
    this.renderClocks();
    this.updateStatus();
    // Clear any "Thinking…" caption set by `attemptHumanMove`. The
    // Lichess wire doesn't carry engine search stats, so the eval line
    // stays empty during normal play.
    this.evalEl.textContent = "";
    this.maybeStartClock();
    this._saveState();
  }

  private _applyEndData(d: EndDataPayload): void {
    this.gameOver = true;
    this.stopClock();
    this._lastEndData = d;
    document.body.classList.add("game-ended");

    const reasonMap: Record<string, string> = {
      mate: "checkmate",
      resign: "resignation",
      stalemate: "stalemate",
      draw: "agreement",
      insufficientMaterial: "insufficient material",
      fiftyMoves: "the fifty-move rule",
      threefoldRepetition: "threefold repetition",
      outoftime: "time",
    };
    const reasonNoun = reasonMap[d.status] ?? d.status ?? "the rules";
    const isCheckmate = d.status === "mate";

    let title: string;
    let reasonLine: string;
    let iconGlyph: string;
    let resultKey: "white" | "black" | "draw";
    if (d.winner === "white") {
      title = isCheckmate ? "Checkmate" : "White wins";
      reasonLine = `White wins by ${reasonNoun}`;
      iconGlyph = "♚";
      resultKey = "white";
    } else if (d.winner === "black") {
      title = isCheckmate ? "Checkmate" : "Black wins";
      reasonLine = `Black wins by ${reasonNoun}`;
      iconGlyph = "♔";
      resultKey = "black";
    } else {
      title = "Draw";
      reasonLine = `Drawn by ${reasonNoun}`;
      iconGlyph = "½";
      resultKey = "draw";
    }

    // The sidebar status still shows a concise sentence (matters for
    // accessibility / non-overlay surfaces).
    this.statusEl.textContent = `${reasonLine}.`;

    this._showGameOverOverlay({
      title,
      reason: `${reasonLine}.`,
      icon: iconGlyph,
      resultKey,
    });
    this._saveState();
  }

  private _showGameOverOverlay(args: {
    title: string; reason: string; icon: string;
    resultKey: "white" | "black" | "draw";
  }): void {
    if (!this.gameOverOverlayEl) return;
    if (this.gameOverResultEl) this.gameOverResultEl.textContent = args.title;
    if (this.gameOverReasonEl) this.gameOverReasonEl.textContent = args.reason;
    if (this.gameOverIconEl) this.gameOverIconEl.textContent = args.icon;
    this.gameOverOverlayEl.dataset.result = args.resultKey;
    this.gameOverOverlayEl.hidden = false;
  }

  private _hideGameOverOverlay(): void {
    document.body.classList.remove("game-ended");
    if (!this.gameOverOverlayEl) return;
    this.gameOverOverlayEl.hidden = true;
    delete this.gameOverOverlayEl.dataset.result;
  }

  // MARK: - localStorage persistence
  //
  // We round-trip the entire UI-visible game state through one JSON blob
  // keyed by `STORAGE_KEY`. Persistence is triggered after every move,
  // after every undo / resign, when the document is hidden, and on
  // page-exit so a refresh restores the position, settings, and clocks.
  // The clocks pause while the page is closed (we don't extrapolate real
  // time during the gap).

  private _saveState(): void {
    if (!this.engine) return;
    try {
      // In replay mode `engine.currentFEN` is a historical position; we
      // must persist the FINAL game state, which we stashed when entering
      // replay.
      const liveFEN = this.replayMode && this.replayFinalFEN
        ? this.replayFinalFEN
        : this.engine.currentFEN;
      const state: SavedGameState = {
        version: 1,
        fen: liveFEN,
        initialFen: this.initialFEN,
        humanColor: this.humanColor,
        difficultyId: this.difficulty.id,
        timeControlId: this.timeControl.id,
        whiteSecondsLeft: this.whiteSecondsLeft,
        blackSecondsLeft: this.blackSecondsLeft,
        moveHistory: this.moveHistory,
        lastMove: this.lastMove,
        gameOver: this.gameOver,
        endData: this._lastEndData ?? null,
      };
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
    } catch (err) {
      // Storage may be unavailable (private browsing, quota exceeded);
      // persistence failures shouldn't break gameplay.
      console.warn("Failed to save game state:", err);
    }
  }

  /**
   * Loads previously-persisted state from localStorage. Returns the
   * parsed state object, or `null` if there's nothing valid to resume.
   */
  static loadSavedState(): SavedGameState | null {
    try {
      const raw = window.localStorage.getItem(STORAGE_KEY);
      if (!raw) return null;
      const parsed = JSON.parse(raw) as Partial<SavedGameState>;
      if (!parsed || parsed.version !== 1) return null;
      if (typeof parsed.fen !== "string" || parsed.fen.length === 0) return null;
      return parsed as SavedGameState;
    } catch (err) {
      console.warn("Failed to read saved game state:", err);
      return null;
    }
  }

  static clearSavedState(): void {
    try {
      window.localStorage.removeItem(STORAGE_KEY);
    } catch {
      // Ignore — non-critical.
    }
  }

  /**
   * Re-hydrates the UI from a previously saved game state. Returns true
   * if the state was applied, false if it was rejected (e.g. the engine
   * refused to load the saved FEN).
   */
  async resumeSavedGame(state: SavedGameState): Promise<boolean> {
    if (!this.engine) return false;

    const difficulty =
      DIFFICULTIES.find((d) => d.id === state.difficultyId) ?? DIFFICULTIES[2]!;
    const timeControl =
      TIME_CONTROLS.find((t) => t.id === state.timeControlId) ?? TIME_CONTROLS[0]!;

    this.humanColor = state.humanColor === "black" ? "black" : "white";
    this.difficulty = difficulty;
    this.timeControl = timeControl;
    this.initialFEN = state.initialFen ?? STARTING_FEN;

    // Re-install the socket and resume the round at the saved FEN. If
    // the FEN is bad we bail and the caller falls back to a fresh game.
    this._installSocket();
    const envelopes = await resumeRound(
      this.engine,
      state.fen,
      this.humanColor,
      this.difficulty.depth,
      this.difficulty.timeMs,
      this.timeControl.initialSeconds,
      this.timeControl.incrementSeconds,
    );
    if (!envelopes) return false;
    for (const env of envelopes) {
      this.socket?._receive(JSON.stringify(env));
    }

    this.moveHistory = Array.isArray(state.moveHistory) ? state.moveHistory : [];
    this.lastMove = state.lastMove ?? null;
    this.whiteSecondsLeft = typeof state.whiteSecondsLeft === "number"
      ? state.whiteSecondsLeft
      : this.timeControl.initialSeconds;
    this.blackSecondsLeft = typeof state.blackSecondsLeft === "number"
      ? state.blackSecondsLeft
      : this.timeControl.initialSeconds;
    this.gameOver = !!state.gameOver;
    this.selectedSquare = null;
    this.highlightedSquares.clear();

    this.renderBoard();
    this.renderClocks();
    this.renderMoves();
    this.updateStatus();

    if (this.gameOver) {
      if (state.endData) {
        // Replay the original end-of-game banner with full attribution
        // (winner, reason). Doing it via _applyEndData also re-renders the
        // sidebar text and re-saves state, so we suppress save by reading
        // back the same value.
        this._applyEndData(state.endData);
      }
    } else if (this.isHumanToMove()) {
      this.maybeStartClock();
    }
    // If it's the engine's turn on resume, the initial snapshot path
    // already triggered (and queued) its first move via
    // `chess_protocol_initial_snapshot` → `kickEngine`.
    return true;
  }

  // MARK: - Board rendering
  //
  // The board is built ONCE per orientation. Subsequent renderBoard()
  // calls update piece images and CSS classes in place — they never
  // touch the parent's children list. Safari (and to a lesser extent
  // every browser) repaints the entire grid when innerHTML is cleared
  // and reconstructed on every click, which is the flicker the user
  // would otherwise see when selecting a piece.

  /**
   * Builds the 64-square grid once. If called again with the same
   * orientation it's a no-op; if the orientation flipped (human played
   * Black) it rebuilds.
   */
  renderBoardScaffold(): void {
    const orientation: SideColor = this.humanColor !== "black" ? "white" : "black";
    if (this._scaffoldOrientation === orientation && this.boardSquares.length === 64) {
      return;
    }
    this._scaffoldOrientation = orientation;

    this.boardEl.replaceChildren();
    this.boardSquares = new Array<HTMLElement>(64);
    for (let rankRow = 0; rankRow < 8; rankRow++) {
      for (let fileCol = 0; fileCol < 8; fileCol++) {
        const isWhitePerspective = orientation === "white";
        const file = isWhitePerspective ? fileCol : 7 - fileCol;
        const rank = isWhitePerspective ? 7 - rankRow : rankRow;
        const sq = rank * 8 + file;
        const cell = document.createElement("div");
        cell.className = "square";
        cell.dataset.square = String(sq);
        cell.dataset.algebraic = FILES[file]! + RANKS[rank]!;
        cell.classList.add((file + rank) % 2 === 0 ? "dark" : "light");
        if (fileCol === 0) {
          const rankLabel = document.createElement("span");
          rankLabel.className = "coord-label rank-label";
          rankLabel.textContent = RANKS[rank]!;
          cell.appendChild(rankLabel);
        }
        if (rankRow === 7) {
          const fileLabel = document.createElement("span");
          fileLabel.className = "coord-label file-label";
          fileLabel.textContent = FILES[file]!;
          cell.appendChild(fileLabel);
        }
        cell.addEventListener("pointerdown", (ev) => this.handlePointerDown(ev, sq));
        this.boardEl.appendChild(cell);
        this.boardSquares[sq] = cell;
      }
    }

    // Global pointer move/up listeners drive dragging. They must be
    // registered only once, otherwise a fresh listener is added on each
    // scaffold rebuild and they pile up.
    if (!this._globalPointerHandlersInstalled) {
      document.addEventListener("pointermove", (ev) => this.handlePointerMove(ev));
      document.addEventListener("pointerup", (ev) => this.handlePointerUp(ev));
      this._globalPointerHandlersInstalled = true;
    }
  }

  /**
   * Updates piece backgrounds and highlight classes in place. Existing
   * DOM nodes are reused; nothing is removed or recreated unless the
   * board's piece-at-square contents actually changed.
   */
  renderBoard(): void {
    if (!this.engine) return;
    this.renderBoardScaffold();

    const HIGHLIGHT_CLASSES = ["highlight", "selected", "last-from", "last-to", "in-check"];

    for (let sq = 0; sq < 64; sq++) {
      const cell = this.boardSquares[sq]!;
      const code = this.engine.pieceAt(sq);
      const pieceName = pieceImageName(code);
      let pieceEl = cell.querySelector<HTMLElement>(".piece");

      if (pieceName) {
        const desiredImage = `url(/pieces/${pieceName}.svg)`;
        if (!pieceEl) {
          pieceEl = document.createElement("div");
          pieceEl.className = "piece";
          pieceEl.dataset.square = String(sq);
          pieceEl.style.backgroundImage = desiredImage;
          cell.appendChild(pieceEl);
        } else if (pieceEl.dataset.code !== String(code)) {
          // Only touch the style when the piece has actually changed.
          pieceEl.style.backgroundImage = desiredImage;
        }
        pieceEl.dataset.code = String(code);
      } else if (pieceEl) {
        pieceEl.remove();
      }

      // Diff highlight classes so we don't churn the className when
      // nothing changed (a no-op classList.add doesn't repaint, but a
      // unilateral remove-then-readd briefly can).
      const desired = this._desiredClassesFor(sq);
      for (const cls of HIGHLIGHT_CLASSES) {
        const has = cell.classList.contains(cls);
        const want = desired.has(cls);
        if (has && !want) cell.classList.remove(cls);
        else if (!has && want) cell.classList.add(cls);
      }
    }
    this.renderCaptures();
  }

  // MARK: - Captured-piece tray
  //
  // We compute captures by comparing the live board against the standard
  // starting material. This is robust to promotions (a missing pawn shows
  // as "captured" even though the side actually has an extra queen) and
  // doesn't require us to track move-by-move history of captures.

  renderCaptures(): void {
    if (!this.engine) return;
    if (!this.whiteCapturesEl || !this.blackCapturesEl) return;
    const captures = computeCaptures(this.engine);
    this._fillCaptureTray(
      this.whiteCapturesEl,
      captures.whiteCaptured,
      "black",
      captures.materialDiff > 0 ? captures.materialDiff : 0,
    );
    this._fillCaptureTray(
      this.blackCapturesEl,
      captures.blackCaptured,
      "white",
      captures.materialDiff < 0 ? -captures.materialDiff : 0,
    );
  }

  /**
   * Renders one capture tray.
   *
   * @param el          The DOM element to fill.
   * @param captured    Map of pieceKind → count.
   * @param capturedColor Color of the captured pieces (i.e. opposite of
   *                      the side that did the capturing).
   * @param advantage   Positive material differential to display as a
   *                    "+N" badge. `0` hides the badge.
   */
  private _fillCaptureTray(
    el: HTMLElement,
    captured: CaptureMap,
    capturedColor: SideColor,
    advantage: number,
  ): void {
    el.replaceChildren();
    // Render lightest pieces first so it reads left-to-right like a
    // typical chess UI (pawns → queen).
    for (const kind of [1, 2, 3, 4, 5]) {
      const count = captured[kind] || 0;
      for (let i = 0; i < count; i++) {
        const piece = document.createElement("span");
        piece.className = "capture-piece";
        const code = capturedColor === "white" ? kind : (kind | 0x8);
        const name = pieceImageName(code);
        if (name) piece.style.backgroundImage = `url(/pieces/${name}.svg)`;
        el.appendChild(piece);
      }
    }
    if (advantage > 0) {
      const badge = document.createElement("span");
      badge.className = "material-advantage";
      badge.textContent = `+${advantage}`;
      el.appendChild(badge);
    }
  }

  /** Returns the set of highlight class names that should be on `sq`. */
  private _desiredClassesFor(sq: number): Set<string> {
    const result = new Set<string>();
    if (this.selectedSquare === sq) result.add("selected");
    if (this.highlightedSquares.has(sq)) result.add("highlight");
    if (this.lastMove) {
      if (this.lastMove.from === sq) result.add("last-from");
      if (this.lastMove.to === sq) result.add("last-to");
    }
    if (this.engine && this.engine.isCheck()) {
      const kingSq = this.engine.kingSquare(this.engine.sideToMove());
      if (kingSq === sq) result.add("in-check");
    }
    return result;
  }

  // MARK: - User input

  handlePointerDown(ev: PointerEvent, sq: number): void {
    if (this.gameOver || !this.engine) return;
    if (!this.isHumanToMove()) return;
    const code = this.engine.pieceAt(sq);
    const isWhitePiece = code >= 1 && code <= 6;
    const isBlackPiece = code >= 9;
    if (this.selectedSquare == null) {
      // Pick up a piece.
      if (
        (this.humanColor === "white" && !isWhitePiece) ||
        (this.humanColor === "black" && !isBlackPiece)
      ) {
        return;
      }
      const moves = this.engine.legalMovesFrom(sq);
      if (moves.length === 0) return;
      this.selectedSquare = sq;
      this.highlightedSquares = new Set(
        moves.map((uci) => parseSquare(uci.slice(2, 4))),
      );
      this.renderBoard();
      this.beginDrag(ev, sq);
    } else {
      // Possible target: try to play. If clicking own piece, reselect.
      if (sq === this.selectedSquare) {
        this.clearSelection();
        this.renderBoard();
        return;
      }
      const candidate = this.findLegalMoveTo(this.selectedSquare, sq);
      if (candidate) {
        void this.attemptHumanMove(candidate);
      } else if (
        (this.humanColor === "white" && isWhitePiece) ||
        (this.humanColor === "black" && isBlackPiece)
      ) {
        // Reselect another of own pieces.
        this.selectedSquare = null;
        this.highlightedSquares.clear();
        this.handlePointerDown(ev, sq);
      } else {
        this.clearSelection();
        this.renderBoard();
      }
    }
  }

  findLegalMoveTo(from: number, to: number): string | null {
    if (!this.engine) return null;
    const moves = this.engine.legalMovesFrom(from);
    const matches = moves.filter(
      (uci) => parseSquare(uci.slice(2, 4)) === to,
    );
    if (matches.length === 0) return null;
    if (matches.length === 1) return matches[0]!;
    // Promotion: ask the user to pick a piece.
    const piece = promptPromotionPiece();
    return matches.find((uci) => uci.endsWith(piece)) ?? matches[0]!;
  }

  beginDrag(ev: PointerEvent, fromSquare: number): void {
    const cell = this.boardSquares[fromSquare];
    if (!cell) return;
    const piece = cell.querySelector<HTMLElement>(".piece");
    if (!piece) return;
    const rect = piece.getBoundingClientRect();
    this.draggingPiece = piece;
    this.dragFromSquare = fromSquare;
    this.dragOffsetX = ev.clientX - rect.left - rect.width / 2;
    this.dragOffsetY = ev.clientY - rect.top - rect.height / 2;
    piece.classList.add("dragging");
    piece.style.width = rect.width + "px";
    piece.style.height = rect.height + "px";
    piece.style.position = "fixed";
    piece.style.zIndex = "1000";
    piece.style.pointerEvents = "none";
    this.positionDraggedPiece(ev);
  }

  handlePointerMove(ev: PointerEvent): void {
    if (!this.draggingPiece) return;
    this.positionDraggedPiece(ev);
  }

  positionDraggedPiece(ev: PointerEvent): void {
    const piece = this.draggingPiece;
    if (!piece) return;
    const w = parseFloat(piece.style.width);
    const h = parseFloat(piece.style.height);
    piece.style.left = (ev.clientX - w / 2 - this.dragOffsetX) + "px";
    piece.style.top = (ev.clientY - h / 2 - this.dragOffsetY) + "px";
  }

  handlePointerUp(ev: PointerEvent): void {
    if (!this.draggingPiece) return;
    const target = document.elementFromPoint(ev.clientX, ev.clientY);
    const targetSquareCell = target instanceof Element
      ? target.closest<HTMLElement>(".square")
      : null;
    const targetSquare = targetSquareCell?.dataset.square;
    const piece = this.draggingPiece;
    piece.classList.remove("dragging");
    piece.style.position = "";
    piece.style.zIndex = "";
    piece.style.pointerEvents = "";
    piece.style.left = "";
    piece.style.top = "";
    piece.style.width = "";
    piece.style.height = "";
    this.draggingPiece = null;
    if (targetSquare != null && this.dragFromSquare != null) {
      const to = parseInt(targetSquare, 10);
      if (to === this.dragFromSquare) {
        // Released back on the same square — leave selected.
        this.renderBoard();
        return;
      }
      const uci = this.findLegalMoveTo(this.dragFromSquare, to);
      if (uci) {
        void this.attemptHumanMove(uci);
        return;
      }
    }
    this.clearSelection();
    this.renderBoard();
  }

  // MARK: - Move application

  /**
   * Submits a human move and arranges for the engine to follow.
   *
   * The submission happens in stages so the user always sees their own
   * move paint *before* the engine search blocks the worker:
   *
   *   1. `socket.send("move", …)` returns the human's move envelope. The
   *      WASM intentionally does NOT auto-run the engine here.
   *   2. `_applyServerMove` paints the new position.
   *   3. We flip on the "engine thinking" indicator.
   *   4. `pumpEngine` runs the search on the worker and delivers the
   *      engine's move envelope, which `_applyServerMove` paints. The
   *      indicator is cleared afterwards.
   */
  async attemptHumanMove(uci: string): Promise<void> {
    if (!this.socket || !this.engine) {
      this.clearSelection();
      this.renderBoard();
      return;
    }
    await this.socket.send("move", { u: uci });

    // If the move was rejected, the server replied with `resync` and
    // nothing else changed. Don't kick the engine.
    if (this.gameOver || this.isHumanToMove()) return;

    this._setEngineThinking(true);
    try {
      await pumpEngine(this.engine, this.socket);
    } finally {
      this._setEngineThinking(false);
    }
  }

  private _setEngineThinking(thinking: boolean): void {
    document.body.classList.toggle("engine-thinking", thinking);
    if (thinking) {
      this.evalEl.textContent = "Engine is thinking…";
    } else if (this.evalEl.textContent === "Engine is thinking…") {
      this.evalEl.textContent = "";
    }
  }

  clearSelection(): void {
    this.selectedSquare = null;
    this.highlightedSquares.clear();
    this.dragFromSquare = null;
  }

  async undoUserMove(): Promise<void> {
    if (!this.engine || this.moveHistory.length === 0) return;
    // Undo two plies so the human can retry their move.
    await this.engine.undoMove();
    this.moveHistory.pop();
    if (this.moveHistory.length > 0 && !this.isHumanToMove()) {
      await this.engine.undoMove();
      this.moveHistory.pop();
    }
    this.gameOver = false;
    this.lastMove = null;
    this.evalEl.textContent = "";
    this.renderBoard();
    this.renderMoves();
    this.updateStatus();
    this.maybeStartClock();
    this._saveState();
  }

  resign(): void {
    if (this.gameOver) return;
    this.gameOver = true;
    this.stopClock();
    const winner = this.humanColor === "white" ? "Black" : "White";
    this.statusEl.textContent = `${winner} wins by resignation.`;
    this._saveState();
  }

  /**
   * Loads a position from a FEN string and resets the move history,
   * highlights, and game-over flag. Returns `false` if the FEN was
   * rejected by the engine.
   */
  async loadFENAndReset(fen: string): Promise<boolean> {
    if (!this.engine) return false;
    if (this.replayMode) this._exitReplayImmediate();
    if (!(await this.engine.loadFEN(fen))) return false;
    this.initialFEN = fen;
    this.moveHistory = [];
    this.lastMove = null;
    this.gameOver = false;
    this.renderBoard();
    this.renderMoves();
    this.updateStatus();
    this._saveState();
    return true;
  }

  // MARK: - Replay mode
  //
  // After the game ends (or the user otherwise wants to scrub through
  // the history) the player can step through every position via the
  // replay panel. The engine is reused as a pure FEN-renderer in this
  // mode: each ply has a saved FEN in `moveHistory`, plus `initialFEN`
  // for ply 0. On entering replay we stash the live FEN; on exit we
  // restore it so play can continue afterwards.

  private _installReplayHandlers(): void {
    if (this.gameOverReplayBtn) {
      this.gameOverReplayBtn.addEventListener("click", () => {
        void this.enterReplay();
      });
    }
    if (this.replaySliderEl) {
      this.replaySliderEl.addEventListener("input", () => {
        void this._setReplayPly(parseInt(this.replaySliderEl!.value, 10));
      });
    }
    this.replayFirstBtn?.addEventListener("click", () => {
      void this._setReplayPly(0);
    });
    this.replayPrevBtn?.addEventListener("click", () => {
      void this._setReplayPly(this.replayPly - 1);
    });
    this.replayNextBtn?.addEventListener("click", () => {
      void this._setReplayPly(this.replayPly + 1);
    });
    this.replayLastBtn?.addEventListener("click", () => {
      void this._setReplayPly(this.moveHistory.length);
    });
    this.replayExitBtn?.addEventListener("click", () => {
      void this.exitReplay();
    });

    // Keyboard shortcuts while in replay mode: ← / → step, Home/End jump.
    document.addEventListener("keydown", (ev) => {
      if (!this.replayMode) return;
      const active = document.activeElement as HTMLElement | null;
      if (active && /input|select|textarea/i.test(active.tagName)
          && active !== this.replaySliderEl) {
        return;
      }
      switch (ev.key) {
        case "ArrowLeft":
          void this._setReplayPly(this.replayPly - 1); ev.preventDefault(); break;
        case "ArrowRight":
          void this._setReplayPly(this.replayPly + 1); ev.preventDefault(); break;
        case "Home":
          void this._setReplayPly(0); ev.preventDefault(); break;
        case "End":
          void this._setReplayPly(this.moveHistory.length); ev.preventDefault(); break;
        case "Escape":
          void this.exitReplay(); ev.preventDefault(); break;
      }
    });
  }

  /** Returns true if the UI is currently in replay (scrub) mode. */
  isReplayMode(): boolean { return this.replayMode; }

  async enterReplay(): Promise<void> {
    if (!this.engine) return;
    if (this.replayMode) return;
    if (this.moveHistory.length === 0 && this.initialFEN === this.engine.currentFEN) {
      // Nothing to scrub through.
      return;
    }
    this.replayFinalFEN = this.engine.currentFEN;
    this.replayMode = true;
    this.replayPly = this.moveHistory.length;  // start at the final position
    document.body.classList.add("replay-mode");
    // Hide the result banner so the panel has the column to itself.
    if (this.gameOverOverlayEl && !this.gameOverOverlayEl.hidden) {
      this.gameOverOverlayEl.hidden = true;
    }
    if (this.replayPanelEl) this.replayPanelEl.hidden = false;
    if (this.replaySliderEl) {
      this.replaySliderEl.min = "0";
      this.replaySliderEl.max = String(this.moveHistory.length);
      this.replaySliderEl.value = String(this.replayPly);
    }
    this._renderReplayMeta();
    // We're already showing the final position — no engine load needed.
  }

  async exitReplay(): Promise<void> {
    if (!this.replayMode) return;
    await this._exitReplayInternal(true);
  }

  /** Synchronous cleanup, e.g. when starting a new game during replay. */
  private _exitReplayImmediate(): void {
    if (!this.replayMode) return;
    this.replayMode = false;
    this.replayPly = 0;
    this.replayFinalFEN = null;
    document.body.classList.remove("replay-mode");
    if (this.replayPanelEl) this.replayPanelEl.hidden = true;
    this._clearReplayHighlights();
  }

  private async _exitReplayInternal(restoreFinal: boolean): Promise<void> {
    const finalFEN = this.replayFinalFEN;
    this.replayMode = false;
    this.replayPly = 0;
    this.replayFinalFEN = null;
    document.body.classList.remove("replay-mode");
    if (this.replayPanelEl) this.replayPanelEl.hidden = true;
    if (restoreFinal && finalFEN && this.engine) {
      // Restore the live position. `loadFEN` is a non-destructive call
      // (no protocol mutation) — perfect for view-restoration.
      await this.engine.loadFEN(finalFEN);
    }
    this._clearReplayHighlights();
    this.renderBoard();
    this.updateStatus();
    // Re-show the result banner if the game is still over.
    if (this.gameOver && this.gameOverOverlayEl && this._lastEndData) {
      this._applyEndData(this._lastEndData);
    }
  }

  private async _setReplayPly(ply: number): Promise<void> {
    if (!this.engine || !this.replayMode) return;
    const clamped = Math.max(0, Math.min(this.moveHistory.length, ply));
    this.replayPly = clamped;
    if (this.replaySliderEl) this.replaySliderEl.value = String(clamped);

    const fen = clamped === 0
      ? this.initialFEN
      : (this.moveHistory[clamped - 1]?.fen ?? this.initialFEN);
    await this.engine.loadFEN(fen);

    // lastMove highlighting for the move that just landed at this ply.
    if (clamped > 0) {
      const uci = this.moveHistory[clamped - 1]!.san;
      if (uci.length >= 4) {
        this.lastMove = {
          from: parseSquare(uci.slice(0, 2)),
          to: parseSquare(uci.slice(2, 4)),
        };
      } else {
        this.lastMove = null;
      }
    } else {
      this.lastMove = null;
    }
    this.renderBoard();
    this._renderReplayMeta();
    this.updateStatus();
  }

  private _renderReplayMeta(): void {
    const n = this.moveHistory.length;
    const p = this.replayPly;
    if (this.replayCounterEl) {
      this.replayCounterEl.textContent = `${p} / ${n}`;
    }
    if (this.replayMoveLabelEl) {
      this.replayMoveLabelEl.textContent = p === 0
        ? "Initial position"
        : (this.moveHistory[p - 1]?.san ?? "");
    }
    if (this.replayPrevBtn) this.replayPrevBtn.disabled = p <= 0;
    if (this.replayFirstBtn) this.replayFirstBtn.disabled = p <= 0;
    if (this.replayNextBtn) this.replayNextBtn.disabled = p >= n;
    if (this.replayLastBtn) this.replayLastBtn.disabled = p >= n;
    // Re-highlight the move list.
    const items = this.moveListEl.querySelectorAll<HTMLElement>("li");
    items.forEach((li, i) => {
      li.classList.toggle("replay-current", i === p - 1);
      li.classList.toggle("replay-future", i >= p);
    });
  }

  private _clearReplayHighlights(): void {
    const items = this.moveListEl.querySelectorAll<HTMLElement>("li");
    items.forEach((li) => {
      li.classList.remove("replay-current");
      li.classList.remove("replay-future");
    });
  }

  // MARK: - Helpers

  isHumanToMove(): boolean {
    if (!this.engine) return false;
    return this.engine.sideToMove() === this.humanColor;
  }

  updateStatus(searchInfo: SearchInfo | null = null): void {
    if (!this.engine) return;
    const result = this.engine.gameResult();
    if (result.code !== 0) {
      this.gameOver = true;
      this.stopClock();
      this.statusEl.textContent = result.label;
    } else {
      const side = this.engine.sideToMove();
      const check = this.engine.isCheck() ? " — check!" : "";
      this.statusEl.textContent = `${capitalize(side)} to move${check}`;
    }
    if (searchInfo) {
      const score = formatScore(searchInfo);
      this.evalEl.textContent =
        `${score}  ·  depth ${searchInfo.depth}, ${searchInfo.nodes} nodes, ${searchInfo.ms} ms`;
    }
  }

  renderMoves(): void {
    this.moveListEl.innerHTML = "";
    for (let i = 0; i < this.moveHistory.length; i++) {
      const item = document.createElement("li");
      if (i % 2 === 0) {
        item.dataset.fullmove = String(i / 2 + 1);
      }
      item.textContent = this.moveHistory[i]!.san;
      this.moveListEl.appendChild(item);
    }
    this.moveListEl.scrollTop = this.moveListEl.scrollHeight;
  }

  // MARK: - Clock

  maybeStartClock(): void {
    if (!this.engine) return;
    if (this.timeControl.initialSeconds < 0) return;  // untimed
    if (this.gameOver) return;
    this.runningClockSide = this.engine.sideToMove();
    this.lastClockTickMs = performance.now();
    if (this.clockTimerId == null) {
      this.clockTimerId = window.setInterval(() => this.tickClock(), 200);
    }
    this.renderClocks();
  }

  stopClock(): void {
    if (this.clockTimerId != null) {
      window.clearInterval(this.clockTimerId);
      this.clockTimerId = null;
    }
    this.runningClockSide = null;
  }

  tickClock(): void {
    if (!this.runningClockSide) return;
    const now = performance.now();
    const elapsedMs = now - (this.lastClockTickMs ?? now);
    this.lastClockTickMs = now;
    const seconds = elapsedMs / 1000;
    if (this.runningClockSide === "white") {
      this.whiteSecondsLeft -= seconds;
    } else {
      this.blackSecondsLeft -= seconds;
    }
    this.renderClocks();
    if (this.whiteSecondsLeft <= 0 || this.blackSecondsLeft <= 0) {
      const loser = this.whiteSecondsLeft <= 0 ? "White" : "Black";
      const winner = this.whiteSecondsLeft <= 0 ? "Black" : "White";
      this.statusEl.textContent = `${loser} flagged. ${winner} wins on time.`;
      this.gameOver = true;
      this.stopClock();
      this._saveState();
    }
  }

  renderClocks(): void {
    const whiteUntimed = this.whiteSecondsLeft < 0;
    const blackUntimed = this.blackSecondsLeft < 0;
    this.whiteClockEl.textContent = whiteUntimed ? "—" : formatClock(this.whiteSecondsLeft);
    this.blackClockEl.textContent = blackUntimed ? "—" : formatClock(this.blackSecondsLeft);
    this.whiteClockEl.classList.toggle("running", this.runningClockSide === "white");
    this.blackClockEl.classList.toggle("running", this.runningClockSide === "black");
    // Used by the fullscreen mode to hide non-applicable clocks entirely.
    this.whiteClockEl.classList.toggle("untimed", whiteUntimed);
    this.blackClockEl.classList.toggle("untimed", blackUntimed);
  }
}

// MARK: - Pure helpers

function capitalize(s: string): string {
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : s;
}

function parseSquare(name: string): number {
  const file = name.charCodeAt(0) - 97;
  const rank = name.charCodeAt(1) - 49;
  return rank * 8 + file;
}

function formatClock(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const minutes = Math.floor(total / 60);
  const secs = total % 60;
  return `${minutes}:${String(secs).padStart(2, "0")}`;
}

function formatScore(info: SearchInfo): string {
  if (info.mate !== 0) {
    return info.mate > 0
      ? `Mate in ${info.mate}`
      : `Mated in ${-info.mate}`;
  }
  const sign = info.score >= 0 ? "+" : "−";
  return `${sign}${Math.abs(info.score / 100).toFixed(2)} pawns`;
}

function promptPromotionPiece(): string {
  const choice = window.prompt("Promote to (q / r / b / n)?", "q");
  if (!choice) return "q";
  const norm = choice.toLowerCase().trim();
  if (["q", "r", "b", "n"].includes(norm)) return norm;
  return "q";
}

function resolveHumanColor(choice: "white" | "black" | "random"): SideColor {
  if (choice === "random") {
    return Math.random() < 0.5 ? "white" : "black";
  }
  return choice;
}

// ─────────────────────────────────────────────  Captured-piece tally

/** Standard starting material per side, keyed by `PieceKind` raw value. */
const INITIAL_PIECE_COUNTS: Record<number, number> = { 1: 8, 2: 2, 3: 2, 4: 2, 5: 1 };

/** Centipawn-ish piece values for the material differential. */
const PIECE_VALUES: Record<number, number> = { 1: 1, 2: 3, 3: 3, 4: 5, 5: 9 };

/**
 * Walks the current board and returns the pieces each side has
 * captured, derived from "starting material − live material" per
 * (color, kind). Promotions show up as captures of the originating pawn
 * — the promoted piece doesn't need any special handling because the
 * "missing pawn" still counts in the opponent's capture column.
 */
export function computeCaptures(engine: ChessEngine): CaptureResult {
  const live: { white: CaptureMap; black: CaptureMap } = {
    white: { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0 },
    black: { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0 },
  };
  for (let sq = 0; sq < 64; sq++) {
    const code = engine.pieceAt(sq);
    if (code === 0) continue;
    const kind = code & 0x7;
    if (kind < 1 || kind > 5) continue;  // ignore kings (kind 6)
    const isBlack = (code & 0x8) !== 0;
    live[isBlack ? "black" : "white"][kind]!++;
  }
  const whiteCaptured: CaptureMap = {};
  const blackCaptured: CaptureMap = {};
  let whiteScore = 0;
  let blackScore = 0;
  for (const kind of [1, 2, 3, 4, 5]) {
    const initial = INITIAL_PIECE_COUNTS[kind]!;
    const blackMissing = Math.max(0, initial - live.black[kind]!);
    if (blackMissing > 0) whiteCaptured[kind] = blackMissing;
    whiteScore += blackMissing * PIECE_VALUES[kind]!;

    const whiteMissing = Math.max(0, initial - live.white[kind]!);
    if (whiteMissing > 0) blackCaptured[kind] = whiteMissing;
    blackScore += whiteMissing * PIECE_VALUES[kind]!;
  }
  return {
    whiteCaptured,
    blackCaptured,
    materialDiff: whiteScore - blackScore,
  };
}

export type { SavedGameState };
