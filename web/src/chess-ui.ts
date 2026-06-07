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

/** Time controls offered by the menu — matches Lichess's standard
 *  bullet / blitz / rapid / classical brackets. Pre-existing IDs
 *  (`blitz3`, `blitz5`, `rapid10`, `classical`) are preserved so saved
 *  games from earlier versions resume on the same setting. */
export const TIME_CONTROLS: TimeControlPreset[] = [
  { id: "untimed",     label: "Untimed",          initialSeconds: -1,   incrementSeconds: 0 },
  { id: "bullet1",     label: "Bullet 1+0",       initialSeconds: 60,   incrementSeconds: 0 },
  { id: "bullet2",     label: "Bullet 2+1",       initialSeconds: 120,  incrementSeconds: 1 },
  { id: "blitz3-0",    label: "Blitz 3+0",        initialSeconds: 180,  incrementSeconds: 0 },
  { id: "blitz3",      label: "Blitz 3+2",        initialSeconds: 180,  incrementSeconds: 2 },
  { id: "blitz5",      label: "Blitz 5+0",        initialSeconds: 300,  incrementSeconds: 0 },
  { id: "blitz5-3",    label: "Blitz 5+3",        initialSeconds: 300,  incrementSeconds: 3 },
  { id: "rapid10",     label: "Rapid 10+0",       initialSeconds: 600,  incrementSeconds: 0 },
  { id: "rapid10-5",   label: "Rapid 10+5",       initialSeconds: 600,  incrementSeconds: 5 },
  { id: "rapid15",     label: "Rapid 15+10",      initialSeconds: 900,  incrementSeconds: 10 },
  { id: "classical30", label: "Classical 30+0",   initialSeconds: 1800, incrementSeconds: 0 },
  { id: "classical30-20", label: "Classical 30+20", initialSeconds: 1800, incrementSeconds: 20 },
  { id: "classical",   label: "Classical 30+30",  initialSeconds: 1800, incrementSeconds: 30 },
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
  /** Read-only display of the current FEN. */
  fenValueEl?: HTMLElement | null;
  /** Copy-to-clipboard button next to the FEN display. */
  copyFENBtn?: HTMLButtonElement | null;
  undoBtn: HTMLButtonElement;
  resignBtn: HTMLButtonElement;
  /** "Hint" button — asks the engine for the best move + draws an
   *  arrow over the board. */
  hintBtn?: HTMLButtonElement | null;
  /** SVG overlay element (`<svg>`) that hosts the hint arrow. */
  hintOverlayEl?: SVGElement | null;
  /** The actual `<line>` whose x1/y1/x2/y2 the hint code updates. */
  hintArrowEl?: SVGElement | null;
  /** SVG overlay that hosts the "last move" arrow (different colour). */
  lastMoveOverlayEl?: SVGElement | null;
  lastMoveArrowEl?: SVGElement | null;
  /** Checkbox that toggles the last-move arrow. */
  lastMoveArrowToggle?: HTMLInputElement | null;
  // New-Game section controls. The class disables these while a game
  // is in progress and re-enables them once a result lands.
  newGameSectionEl?: HTMLElement | null;
  colorSelect?: HTMLSelectElement | null;
  difficultySelect?: HTMLSelectElement | null;
  timeSelect?: HTMLSelectElement | null;
  startGameBtn?: HTMLButtonElement | null;
  // Status-panel children. The status panel swaps content + actions
  // between "live game" and "game over" states.
  statusLiveEl?: HTMLElement | null;
  statusGameOverEl?: HTMLElement | null;
  inGameActionsEl?: HTMLElement | null;
  gameOverActionsEl?: HTMLElement | null;
  // Game-over indicator surfaces — used to be a freestanding banner;
  // they're now children of `statusGameOverEl` inside the sidebar.
  gameOverResultEl?: HTMLElement | null;
  gameOverReasonEl?: HTMLElement | null;
  gameOverIconEl?: HTMLElement | null;
  /** "Replay" button in the game-over actions row. */
  gameOverReplayBtn?: HTMLButtonElement | null;
  // Replay-panel surfaces (shown when the user enters replay mode).
  replayPanelEl?: HTMLElement | null;
  replaySliderEl?: HTMLInputElement | null;
  replayCounterEl?: HTMLElement | null;
  replayMoveLabelEl?: HTMLElement | null;
  replayPrevBtn?: HTMLButtonElement | null;
  replayNextBtn?: HTMLButtonElement | null;
  replayExitBtn?: HTMLButtonElement | null;
  /** "Resume" button in the replay panel — pick up the game from the
   *  chosen ply rather than restoring the original final state. */
  replayResumeBtn?: HTMLButtonElement | null;
}

export interface StartNewGameOptions {
  humanColor: "white" | "black" | "random";
  difficultyId: string;
  timeControlId: string;
}

export interface MoveHistoryEntry {
  san: string;
  fen: string;
  /** White's clock (seconds) immediately AFTER this move was played.
   *  `undefined` for moves saved before the field was added (replay
   *  falls back to the time control's initial value). */
  whiteClock?: number;
  /** Black's clock (seconds) immediately AFTER this move was played. */
  blackClock?: number;
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

/** localStorage key for the "Last Move Arrow" toggle. */
const LAST_MOVE_ARROW_KEY = "skip-chess.last-move-arrow.v1";

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
  private readonly fenValueEl: HTMLElement | null;
  private readonly copyFENBtn: HTMLButtonElement | null;
  private readonly undoBtn: HTMLButtonElement;
  private readonly resignBtn: HTMLButtonElement;
  private readonly hintBtn: HTMLButtonElement | null;
  private readonly hintOverlayEl: SVGElement | null;
  private readonly hintArrowEl: SVGElement | null;
  private readonly lastMoveOverlayEl: SVGElement | null;
  private readonly lastMoveArrowEl: SVGElement | null;
  private readonly lastMoveArrowToggle: HTMLInputElement | null;
  private readonly colorSelect: HTMLSelectElement | null;
  private readonly difficultySelect: HTMLSelectElement | null;
  private readonly timeSelect: HTMLSelectElement | null;
  private readonly startGameBtn: HTMLButtonElement | null;
  /** True while the user has typed/pasted a FEN into the field that
   *  differs from the engine's current FEN. The icon button morphs
   *  into a "load" button while this is set. */
  private fenDirty = false;
  /** Whether the user has toggled "Last Move Arrow" on. Persisted in
   *  localStorage under `LAST_MOVE_ARROW_KEY`. */
  private lastMoveArrowEnabled = false;
  private readonly statusLiveEl: HTMLElement | null;
  private readonly statusGameOverEl: HTMLElement | null;
  private readonly inGameActionsEl: HTMLElement | null;
  private readonly gameOverActionsEl: HTMLElement | null;
  private readonly gameOverResultEl: HTMLElement | null;
  private readonly gameOverReasonEl: HTMLElement | null;
  private readonly gameOverIconEl: HTMLElement | null;
  private readonly gameOverReplayBtn: HTMLButtonElement | null;

  // Replay panel surfaces
  private readonly replayPanelEl: HTMLElement | null;
  private readonly replaySliderEl: HTMLInputElement | null;
  private readonly replayCounterEl: HTMLElement | null;
  private readonly replayMoveLabelEl: HTMLElement | null;
  private readonly replayPrevBtn: HTMLButtonElement | null;
  private readonly replayNextBtn: HTMLButtonElement | null;
  private readonly replayExitBtn: HTMLButtonElement | null;
  private readonly replayResumeBtn: HTMLButtonElement | null;

  /** Last endData payload (kept so we can re-show the overlay on resume). */
  private _lastEndData: EndDataPayload | null = null;

  /** FEN of the position at ply 0 of the current game — required so the
   *  replay slider can rewind to "before any move was played". */
  private initialFEN: string = STARTING_FEN;

  /** True while the user is scrubbing through past moves. While set, the
   *  engine is showing a historical position and accepting no input. */
  /** True while an engine search is in flight (move pump or Hint). Read
   *  by `_renderActionButtonStates` to disable Hint mid-search. */
  private _engineSearching = false;
  private replayMode = false;
  /** Ply index currently shown in replay mode (0 = initial position). */
  private replayPly = 0;
  /** Snapshot of `engine.currentFEN` at the moment replay was entered.
   *  Restored when the user exits replay so play resumes correctly. */
  private replayFinalFEN: string | null = null;
  /** Live white clock at the moment replay was entered (restored on exit). */
  private replayLiveWhiteClock: number = -1;
  /** Live black clock at the moment replay was entered (restored on exit). */
  private replayLiveBlackClock: number = -1;

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
    this.fenValueEl = options.fenValueEl ?? null;
    this.copyFENBtn = options.copyFENBtn ?? null;
    this.undoBtn = options.undoBtn;
    this.resignBtn = options.resignBtn;
    this.hintBtn = options.hintBtn ?? null;
    this.hintOverlayEl = options.hintOverlayEl ?? null;
    this.hintArrowEl = options.hintArrowEl ?? null;
    this.lastMoveOverlayEl = options.lastMoveOverlayEl ?? null;
    this.lastMoveArrowEl = options.lastMoveArrowEl ?? null;
    this.lastMoveArrowToggle = options.lastMoveArrowToggle ?? null;
    this.colorSelect = options.colorSelect ?? null;
    this.difficultySelect = options.difficultySelect ?? null;
    this.timeSelect = options.timeSelect ?? null;
    this.startGameBtn = options.startGameBtn ?? null;

    // Restore the user's Last Move Arrow preference.
    try {
      this.lastMoveArrowEnabled =
        window.localStorage.getItem(LAST_MOVE_ARROW_KEY) === "1";
    } catch { /* private mode etc. */ }
    if (this.lastMoveArrowToggle) {
      this.lastMoveArrowToggle.checked = this.lastMoveArrowEnabled;
      this.lastMoveArrowToggle.addEventListener("change", () => {
        this.lastMoveArrowEnabled = this.lastMoveArrowToggle!.checked;
        try {
          window.localStorage.setItem(
            LAST_MOVE_ARROW_KEY,
            this.lastMoveArrowEnabled ? "1" : "0",
          );
        } catch { /* ignore */ }
        this._renderLastMoveArrow();
      });
    }
    this.statusLiveEl = options.statusLiveEl ?? null;
    this.statusGameOverEl = options.statusGameOverEl ?? null;
    this.inGameActionsEl = options.inGameActionsEl ?? null;
    this.gameOverActionsEl = options.gameOverActionsEl ?? null;

    // Optional game-over overlay surfaces. When present, an end-of-game
    // event (`endData`) populates them and unhides the overlay; starting
    // a new game hides it again.
    this.gameOverResultEl = options.gameOverResultEl ?? null;
    this.gameOverReasonEl = options.gameOverReasonEl ?? null;
    this.gameOverIconEl = options.gameOverIconEl ?? null;
    this.gameOverReplayBtn = options.gameOverReplayBtn ?? null;
    this.replayPanelEl = options.replayPanelEl ?? null;
    this.replaySliderEl = options.replaySliderEl ?? null;
    this.replayCounterEl = options.replayCounterEl ?? null;
    this.replayMoveLabelEl = options.replayMoveLabelEl ?? null;
    this.replayPrevBtn = options.replayPrevBtn ?? null;
    this.replayNextBtn = options.replayNextBtn ?? null;
    this.replayExitBtn = options.replayExitBtn ?? null;
    this.replayResumeBtn = options.replayResumeBtn ?? null;

    this.undoBtn.addEventListener("click", () => { void this.undoUserMove(); });
    this.resignBtn.addEventListener("click", () => this.resign());
    this.hintBtn?.addEventListener("click", () => { void this.showHint(); });

    this.copyFENBtn?.addEventListener("click", () => { void this._copyOrLoadFEN(); });

    // The FEN field is contenteditable. Watch for user edits so we can
    // morph the adjacent icon button from "copy" into "load" once the
    // contents drift from the engine's current FEN.
    if (this.fenValueEl) {
      this.fenValueEl.addEventListener("input", () => {
        this.fenDirty = this._isFenFieldDirty();
        this._renderFenButtonMode();
      });
      // contenteditable's default `paste` keeps formatting; force plain
      // text and collapse whitespace so a multi-line clipboard paste
      // becomes a single-line FEN.
      this.fenValueEl.addEventListener("paste", (ev) => {
        ev.preventDefault();
        const ce = ev as ClipboardEvent;
        const text = ce.clipboardData?.getData("text/plain") ?? "";
        const cleaned = text.replace(/\s+/g, " ").trim();
        // execCommand is deprecated but still the most reliable way to
        // insert text at the caret inside contenteditable across
        // browsers. The deprecation hint is acknowledged.
        document.execCommand("insertText", false, cleaned);
      });
      // Escape reverts the field back to the engine's current FEN.
      this.fenValueEl.addEventListener("keydown", (ev) => {
        if (ev.key === "Escape") {
          ev.preventDefault();
          this.fenDirty = false;
          this.renderFEN();
          (this.fenValueEl as HTMLElement).blur();
        }
      });
    }

    this._installReplayHandlers();

    // Persist current state when the user navigates away. `beforeunload`
    // catches refreshes and tab closes; `visibilitychange` catches
    // backgrounding on mobile, where `beforeunload` is unreliable.
    window.addEventListener("beforeunload", () => this._saveState());
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "hidden") this._saveState();
    });

    // Keep the fullscreen board sized to fit the viewport on resize /
    // orientation change. The handler is a no-op when not in fullscreen.
    window.addEventListener("resize", () => this._updateFullscreenBoardSize());
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
    this._lastEndData = null;
    this.stopClock();

    this.renderBoard();
    this.renderClocks();
    this.renderMoves();
    this.updateStatus();
    this._renderStatusPanelLayout();
    this._clearHintArrow();
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

    // Push the history entry AFTER clock sync so the entry captures the
    // clock state as of this ply — replay scrubbing relies on this to
    // restore the timer display to its value at each historical move.
    if (isRealMove) {
      this.moveHistory.push({
        san: d.uci,
        fen: d.fen,
        whiteClock: this.whiteSecondsLeft,
        blackClock: this.blackSecondsLeft,
      });
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
    if (this.gameOverResultEl) this.gameOverResultEl.textContent = args.title;
    if (this.gameOverReasonEl) this.gameOverReasonEl.textContent = args.reason;
    if (this.gameOverIconEl) this.gameOverIconEl.textContent = args.icon;
    if (this.statusGameOverEl) this.statusGameOverEl.dataset.result = args.resultKey;
    this._renderStatusPanelLayout();
    this._updateFullscreenBoardSize();
  }

  private _hideGameOverOverlay(): void {
    document.body.classList.remove("game-ended");
    if (this.statusGameOverEl) delete this.statusGameOverEl.dataset.result;
    this._renderStatusPanelLayout();
    this._updateFullscreenBoardSize();
  }

  /**
   * Swaps the status sidebar between its "live game" and "game over"
   * layouts. Driven by `this.gameOver` + `this.replayMode`:
   *   - live game: status text + Hint/Undo/Resign
   *   - game over (not replay): icon + title + reason + Replay/New Game
   *   - replay: icon + title + reason; action buttons hidden (the
   *     replay panel below the board has its own controls).
   *
   * The swap only fires when `_lastEndData` is populated — otherwise a
   * locally-detected mate (set by `updateStatus` from the engine's
   * `gameResult()`) could briefly flip the panel to an empty game-over
   * view before the `endData` envelope arrives with the actual info.
   */
  private _renderStatusPanelLayout(): void {
    const showGameOver = this.gameOver && this._lastEndData != null;
    const inReplay = this.replayMode;
    if (this.statusLiveEl) this.statusLiveEl.hidden = showGameOver;
    if (this.statusGameOverEl) this.statusGameOverEl.hidden = !showGameOver;
    if (this.inGameActionsEl) this.inGameActionsEl.hidden = showGameOver;
    if (this.gameOverActionsEl) {
      this.gameOverActionsEl.hidden = !showGameOver || inReplay;
    }
    this._renderActionButtonStates();
    this._renderNewGameSectionEnabled();
  }

  /** Greys out action buttons that can't be invoked in the current
   *  state. Hint needs an active game where the human is to move;
   *  Undo needs at least one ply on the history; Resign needs an
   *  active game. */
  private _renderActionButtonStates(): void {
    const live = !this.gameOver && !this.replayMode;
    const humansTurn = live && this.isHumanToMove() && !this._engineSearching;
    if (this.hintBtn) {
      this.hintBtn.disabled = !humansTurn;
    }
    if (this.undoBtn) {
      this.undoBtn.disabled = this.moveHistory.length === 0 || !live;
    }
    if (this.resignBtn) {
      this.resignBtn.disabled = !live;
    }
    if (this.gameOverReplayBtn) {
      // Replay needs at least one ply OR a non-default initial FEN to
      // scrub through.
      this.gameOverReplayBtn.disabled = this.moveHistory.length === 0
        && this.initialFEN === STARTING_FEN;
    }
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
        // Replay the original end-of-game panel with full attribution
        // (winner, reason). Doing it via _applyEndData also re-renders
        // the sidebar text and re-saves state.
        this._applyEndData(state.endData);
      } else {
        this._renderStatusPanelLayout();
      }
    } else if (this.isHumanToMove()) {
      this._renderStatusPanelLayout();
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
    this._renderLastMoveArrow();
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
    this._engineSearching = thinking;
    document.body.classList.toggle("engine-thinking", thinking);
    if (thinking) {
      this.evalEl.textContent = "Engine is thinking…";
    } else if (this.evalEl.textContent === "Engine is thinking…") {
      this.evalEl.textContent = "";
    }
    this._renderActionButtonStates();
  }

  clearSelection(): void {
    this.selectedSquare = null;
    this.highlightedSquares.clear();
    this.dragFromSquare = null;
    // Any user interaction that clears the selection also invalidates
    // a pending hint arrow — the position is about to change.
    this._clearHintArrow();
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
    this._lastEndData = null;

    // Restore last-move highlighting to whatever the new top-of-history
    // entry represents (or clear it if we undid back to the start).
    if (this.moveHistory.length > 0) {
      const last = this.moveHistory[this.moveHistory.length - 1]!;
      this.lastMove = this._lastMoveFromEntry(last);
    } else {
      this.lastMove = null;
    }

    // Undo the clocks too. Each MoveHistoryEntry stored the clock
    // readings as of its move; reverting to the new top of history
    // means reading its clocks (or falling back to the time control's
    // initial value if we undid back to the start, or for legacy
    // history entries that pre-date clock tracking).
    if (this.timeControl.initialSeconds >= 0) {
      if (this.moveHistory.length === 0) {
        this.whiteSecondsLeft = this.timeControl.initialSeconds;
        this.blackSecondsLeft = this.timeControl.initialSeconds;
      } else {
        const last = this.moveHistory[this.moveHistory.length - 1]!;
        this.whiteSecondsLeft = last.whiteClock ?? this.timeControl.initialSeconds;
        this.blackSecondsLeft = last.blackClock ?? this.timeControl.initialSeconds;
      }
    }
    this.evalEl.textContent = "";
    this._clearHintArrow();
    this.renderBoard();
    this.renderClocks();
    this.renderMoves();
    this.updateStatus();
    this._renderStatusPanelLayout();
    this.maybeStartClock();
    this._saveState();
  }

  resign(): void {
    if (this.gameOver) return;
    // Synthesise an endData payload and route through the standard
    // game-over path so the status panel swaps to its result layout.
    const winner: SideColor = this.humanColor === "white" ? "black" : "white";
    this._applyEndData({ status: "resign", winner });
  }

  /**
   * Loads a position from a FEN string and resets move history,
   * highlights, and game-over flag. Returns `false` if the FEN was
   * rejected by the engine.
   *
   * NOTE: bare `engine.loadFEN()` is insufficient here — it only mutates
   * the engine's board, leaving the protocol's RoundSession pointing at
   * the old game's state. Subsequent moves go through `socket.send`,
   * which is gated by the RoundSession's position, so the UI looks
   * frozen. We re-bootstrap the round via `resumeRound` so the protocol
   * and engine agree on the new starting position.
   */
  async loadFENAndReset(fen: string): Promise<boolean> {
    if (!this.engine) return false;
    if (this.replayMode) this._exitReplayImmediate();
    this._hideGameOverOverlay();

    this._installSocket();
    const envelopes = await resumeRound(
      this.engine,
      fen,
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

    this.initialFEN = fen;
    this.moveHistory = [];
    this.lastMove = null;
    this.gameOver = false;
    this._lastEndData = null;
    this.selectedSquare = null;
    this.highlightedSquares.clear();
    this.whiteSecondsLeft = this.timeControl.initialSeconds;
    this.blackSecondsLeft = this.timeControl.initialSeconds;
    this.stopClock();

    this.renderBoard();
    this.renderClocks();
    this.renderMoves();
    this.updateStatus();
    this._renderStatusPanelLayout();
    this._clearHintArrow();
    this._saveState();
    this.maybeStartClock();
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
    this.replayPrevBtn?.addEventListener("click", () => {
      void this._setReplayPly(this.replayPly - 1);
    });
    this.replayNextBtn?.addEventListener("click", () => {
      void this._setReplayPly(this.replayPly + 1);
    });
    this.replayExitBtn?.addEventListener("click", () => {
      void this.exitReplay();
    });
    this.replayResumeBtn?.addEventListener("click", () => {
      void this.resumeFromReplayPly();
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
    // Snapshot the LIVE clock readings so plain "Exit replay" can put
    // them back (scrubbing rewrites whiteSecondsLeft / blackSecondsLeft).
    this.replayLiveWhiteClock = this.whiteSecondsLeft;
    this.replayLiveBlackClock = this.blackSecondsLeft;
    this.replayMode = true;
    this.replayPly = this.moveHistory.length;  // start at the final position
    document.body.classList.add("replay-mode");
    // Game-over indicator stays visible in the status panel — it's
    // persistent. Action buttons (Replay/New Game) are hidden by the
    // status-panel layout helper while we're in replay.
    this._renderStatusPanelLayout();
    if (this.replayPanelEl) this.replayPanelEl.hidden = false;
    if (this.replaySliderEl) {
      this.replaySliderEl.min = "0";
      this.replaySliderEl.max = String(this.moveHistory.length);
      this.replaySliderEl.value = String(this.replayPly);
    }
    this._renderReplayMeta();
    this._updateFullscreenBoardSize();
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
    const liveWhite = this.replayLiveWhiteClock;
    const liveBlack = this.replayLiveBlackClock;
    this.replayMode = false;
    this.replayPly = 0;
    this.replayFinalFEN = null;
    document.body.classList.remove("replay-mode");
    if (this.replayPanelEl) this.replayPanelEl.hidden = true;
    if (restoreFinal && finalFEN && this.engine) {
      // Restore the live position. `loadFEN` is a non-destructive call
      // (no protocol mutation) — perfect for view-restoration.
      await this.engine.loadFEN(finalFEN);
      // Put the live clock readings back too — `_setReplayPly` rewrote
      // them while the user was scrubbing.
      if (liveWhite >= 0) this.whiteSecondsLeft = liveWhite;
      if (liveBlack >= 0) this.blackSecondsLeft = liveBlack;
    }
    this._clearReplayHighlights();
    this.renderBoard();
    this.renderClocks();
    this.updateStatus();
    this._updateFullscreenBoardSize();
    // Re-show the game-over action buttons if the game is still over —
    // _renderStatusPanelLayout() handles that automatically because
    // replayMode has just been cleared.
    this._renderStatusPanelLayout();
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

    // Historical clock display. Each MoveHistoryEntry stores the clock
    // readings AS OF its move; ply 0 (initial position) falls back to
    // the time control's starting value. Pre-clock-tracking history
    // entries (no whiteClock field) also fall back to initialSeconds.
    if (this.timeControl.initialSeconds >= 0) {
      if (clamped === 0) {
        this.whiteSecondsLeft = this.timeControl.initialSeconds;
        this.blackSecondsLeft = this.timeControl.initialSeconds;
      } else {
        const entry = this.moveHistory[clamped - 1]!;
        this.whiteSecondsLeft = entry.whiteClock ?? this.timeControl.initialSeconds;
        this.blackSecondsLeft = entry.blackClock ?? this.timeControl.initialSeconds;
      }
    }

    this.renderBoard();
    this.renderClocks();
    this._renderReplayMeta();
    this.updateStatus();
  }

  /**
   * Picks up the game from the currently-scrubbed ply: truncates the
   * move history, restores the historical clocks, re-bootstraps the
   * protocol session at this position, and exits replay mode. The
   * engine plays its move if it's their turn.
   */
  async resumeFromReplayPly(): Promise<void> {
    if (!this.engine || !this.replayMode) return;
    const ply = this.replayPly;
    const fen = ply === 0
      ? this.initialFEN
      : (this.moveHistory[ply - 1]?.fen ?? this.initialFEN);
    const newHistory = this.moveHistory.slice(0, ply);
    const lastEntry = newHistory[newHistory.length - 1];
    const fallbackClock = this.timeControl.initialSeconds;
    const whiteClock = lastEntry?.whiteClock ?? fallbackClock;
    const blackClock = lastEntry?.blackClock ?? fallbackClock;

    // Tear down replay state first so `_applyServerMove` events from the
    // upcoming bootstrap go through the normal (non-replay) code path.
    this.replayMode = false;
    this.replayPly = 0;
    this.replayFinalFEN = null;
    this.replayLiveWhiteClock = -1;
    this.replayLiveBlackClock = -1;
    document.body.classList.remove("replay-mode");
    if (this.replayPanelEl) this.replayPanelEl.hidden = true;
    this._clearReplayHighlights();
    this._hideGameOverOverlay();
    this.gameOver = false;
    this._lastEndData = null;

    // Set history + clock state BEFORE the bootstrap so the boot-snapshot
    // envelope sees the truncated history; any engine move included in
    // the boot snapshot will then append to the truncated history rather
    // than corrupting it.
    this.moveHistory = newHistory;
    this.lastMove = ply > 0 ? this._lastMoveFromEntry(newHistory[ply - 1]!) : null;
    this.selectedSquare = null;
    this.highlightedSquares.clear();
    this.stopClock();

    // Re-bootstrap the round at the resumed FEN. We pass the engine's
    // historical clock as `initialClockSeconds` so the WASM-side
    // RoundSession starts the engine at that value; the human's clock is
    // overridden JS-side after the bootstrap completes.
    const engineColor: SideColor = this.humanColor === "white" ? "black" : "white";
    const engineClock = engineColor === "white" ? whiteClock : blackClock;
    this._installSocket();
    const envelopes = await resumeRound(
      this.engine,
      fen,
      this.humanColor,
      this.difficulty.depth,
      this.difficulty.timeMs,
      // `<0` is the "untimed" sentinel; preserve that.
      fallbackClock < 0 ? -1 : engineClock,
      this.timeControl.incrementSeconds,
    );
    if (!envelopes) return;
    for (const env of envelopes) {
      this.socket?._receive(JSON.stringify(env));
    }

    // Override the boot snapshot's clock sync with the historical
    // readings (the bootstrap clamped both sides to engineClock; we want
    // the user to see exactly the values from the chosen ply).
    if (fallbackClock >= 0) {
      this.whiteSecondsLeft = whiteClock;
      this.blackSecondsLeft = blackClock;
    }

    this.renderBoard();
    this.renderClocks();
    this.renderMoves();
    this.updateStatus();
    this._renderStatusPanelLayout();
    this._clearHintArrow();
    this._updateFullscreenBoardSize();
    this._saveState();
    this.maybeStartClock();
  }

  private _lastMoveFromEntry(entry: MoveHistoryEntry): LastMove | null {
    const uci = entry.san;
    if (uci.length < 4) return null;
    return {
      from: parseSquare(uci.slice(0, 2)),
      to: parseSquare(uci.slice(2, 4)),
    };
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
    if (this.replayNextBtn) this.replayNextBtn.disabled = p >= n;
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
    this.renderFEN();
  }

  /**
   * Updates the FEN display element with the engine's current FEN. Safe
   * to call when the FEN element isn't wired (the constructor allows it
   * to be omitted).
   */
  renderFEN(): void {
    if (!this.fenValueEl || !this.engine) return;
    // Don't trample the user's in-progress edit — they're either about
    // to paste a new FEN or are mid-edit. The icon button stays in
    // "load" mode (per `_renderFenButtonMode`) until they click it or
    // press Escape.
    if (this.fenDirty) {
      this._renderFenButtonMode();
      return;
    }
    const fen = this.engine.currentFEN;
    this.fenValueEl.textContent = fen || "—";
    this._renderFenButtonMode();
  }

  private _isFenFieldDirty(): boolean {
    if (!this.fenValueEl || !this.engine) return false;
    const text = (this.fenValueEl.textContent ?? "").trim();
    return text.length > 0 && text !== this.engine.currentFEN;
  }

  /**
   * Toggles the icon button between "copy" mode (default) and "load"
   * mode (when the user has typed a new FEN). The CSS class controls
   * which inline SVG icon is visible.
   */
  private _renderFenButtonMode(): void {
    if (!this.copyFENBtn) return;
    const isLoad = this.fenDirty
      && (this.fenValueEl?.textContent ?? "").trim().length > 0;
    this.copyFENBtn.classList.toggle("load-mode", isLoad);
    if (isLoad) {
      this.copyFENBtn.title = "Load this FEN";
      this.copyFENBtn.setAttribute("aria-label", "Load the FEN you typed");
    } else {
      this.copyFENBtn.title = "Copy FEN";
      this.copyFENBtn.setAttribute("aria-label", "Copy FEN to clipboard");
    }
  }

  // MARK: - Hint
  //
  // The Hint button asks the engine for its current best move and draws
  // an arrow over the board from origin to destination. The arrow is
  // rendered into an absolutely-positioned `<svg>` overlay whose
  // `viewBox` matches the 8×8 grid of the board, so we can express
  // coordinates in "files / ranks" units.

  /**
   * Asks the engine for the best move at the current position and
   * draws an arrow on the board. Disables the Hint button while the
   * search is in flight and re-enables on completion.
   */
  async showHint(): Promise<void> {
    if (!this.engine) return;
    if (this.replayMode || this.gameOver) return;
    if (!this.isHumanToMove()) return;  // engine's turn, no point hinting
    if (this.hintBtn) this.hintBtn.disabled = true;
    this._setEngineThinking(true);
    try {
      const uci = await this.engine.bestMove();
      this._renderHintArrow(uci);
    } catch (err) {
      console.warn("hint failed:", err);
    } finally {
      this._setEngineThinking(false);
      if (this.hintBtn) this.hintBtn.disabled = false;
    }
  }

  private _renderHintArrow(uci: string | null): void {
    if (!this.hintOverlayEl || !this.hintArrowEl) return;
    if (!uci || uci.length < 4) {
      this.hintOverlayEl.style.display = "none";
      return;
    }
    const fromFile = uci.charCodeAt(0) - 97;
    const fromRank = uci.charCodeAt(1) - 49;
    const toFile = uci.charCodeAt(2) - 97;
    const toRank = uci.charCodeAt(3) - 49;
    const whitePerspective = this._scaffoldOrientation !== "black";
    const center = (file: number, rank: number): { x: number; y: number } => ({
      x: (whitePerspective ? file : 7 - file) + 0.5,
      y: (whitePerspective ? 7 - rank : rank) + 0.5,
    });
    const from = center(fromFile, fromRank);
    const to = center(toFile, toRank);

    // Shorten the line slightly so the arrowhead sits comfortably
    // inside the destination square instead of past the next gridline.
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const len = Math.hypot(dx, dy);
    const trim = 0.25;
    const scale = len > trim ? (len - trim) / len : 0;
    const endX = from.x + dx * scale;
    const endY = from.y + dy * scale;

    this.hintArrowEl.setAttribute("x1", String(from.x));
    this.hintArrowEl.setAttribute("y1", String(from.y));
    this.hintArrowEl.setAttribute("x2", String(endX));
    this.hintArrowEl.setAttribute("y2", String(endY));
    this.hintOverlayEl.style.display = "";
  }

  private _clearHintArrow(): void {
    if (this.hintOverlayEl) this.hintOverlayEl.style.display = "none";
  }

  /**
   * Renders (or clears) the last-move arrow over the board. Called any
   * time `lastMove` changes or the toggle flips. The arrow is drawn as
   * a SINGLE filled polygon (one continuous fill region) so that the
   * stem and arrowhead don't overlap when the fill is translucent —
   * the previous line + marker-end approach produced an obvious darker
   * patch at their meeting point at the colour's low opacity.
   *
   * The arrow:
   *  - paints BENEATH the pieces (z-index in CSS) so the piece silhouette
   *    stays fully visible;
   *  - is colored to match the side that just moved (light cream for
   *    white pieces, soft black for black pieces) at low opacity;
   *  - is trimmed at both ends so the head tip lands at the edge of
   *    the piece on the destination square rather than overlapping it.
   */
  private _renderLastMoveArrow(): void {
    if (!this.lastMoveOverlayEl || !this.lastMoveArrowEl) return;
    if (!this.lastMoveArrowEnabled || !this.lastMove || !this.engine) {
      this.lastMoveOverlayEl.style.display = "none";
      return;
    }
    const fromFile = this.lastMove.from & 7;
    const fromRank = this.lastMove.from >> 3;
    const toFile = this.lastMove.to & 7;
    const toRank = this.lastMove.to >> 3;
    const whitePerspective = this._scaffoldOrientation !== "black";
    const center = (file: number, rank: number): { x: number; y: number } => ({
      x: (whitePerspective ? file : 7 - file) + 0.5,
      y: (whitePerspective ? 7 - rank : rank) + 0.5,
    });
    const from = center(fromFile, fromRank);
    const to = center(toFile, toRank);
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const len = Math.hypot(dx, dy);
    if (len === 0) {
      this.lastMoveOverlayEl.style.display = "none";
      return;
    }

    // Asymmetric trim: small bite out of the start (the from-square is
    // empty post-move) and a bigger bite at the end so the head tip
    // lands at the edge of the destination piece.
    const TRIM_START = 0.18;
    const TRIM_END = 0.5;
    let startFrac = 0;
    let endFrac = 1;
    if (len > TRIM_START + TRIM_END) {
      startFrac = TRIM_START / len;
      endFrac = 1 - (TRIM_END / len);
    } else {
      // Very short moves: clip to a tiny middle segment rather than
      // vanishing entirely.
      startFrac = 0.3;
      endFrac = 0.7;
    }
    const startX = from.x + dx * startFrac;
    const startY = from.y + dy * startFrac;
    const tipX = from.x + dx * endFrac;
    const tipY = from.y + dy * endFrac;

    // Unit vector along the arrow + its perpendicular.
    const ax = tipX - startX;
    const ay = tipY - startY;
    const alen = Math.hypot(ax, ay);
    if (alen === 0) {
      this.lastMoveOverlayEl.style.display = "none";
      return;
    }
    const ux = ax / alen;
    const uy = ay / alen;
    const px = -uy;
    const py = ux;

    // Arrow geometry, all in SVG viewBox units (1 = one square).
    const STEM_W = 0.16;
    const HEAD_W = 0.42;
    // Clamp head length so the head doesn't eat the whole arrow on
    // short knight-style moves.
    const HEAD_LEN = Math.min(0.28, alen * 0.6);

    // Head base — where the stem meets the head.
    const baseX = tipX - ux * HEAD_LEN;
    const baseY = tipY - uy * HEAD_LEN;

    // Seven-vertex polygon (counter-clockwise around the arrow):
    //   p1 (stem-start +)   p2 (head-base +)   p3 (wing +)
    //                                                       p4 (tip)
    //   p7 (stem-start -)   p6 (head-base -)   p5 (wing -)
    const fmt = (x: number, y: number): string =>
      `${x.toFixed(3)},${y.toFixed(3)}`;
    const p1 = fmt(startX + px * STEM_W / 2, startY + py * STEM_W / 2);
    const p2 = fmt(baseX  + px * STEM_W / 2, baseY  + py * STEM_W / 2);
    const p3 = fmt(baseX  + px * HEAD_W / 2, baseY  + py * HEAD_W / 2);
    const p4 = fmt(tipX, tipY);
    const p5 = fmt(baseX  - px * HEAD_W / 2, baseY  - py * HEAD_W / 2);
    const p6 = fmt(baseX  - px * STEM_W / 2, baseY  - py * STEM_W / 2);
    const p7 = fmt(startX - px * STEM_W / 2, startY - py * STEM_W / 2);
    const d = `M${p1} L${p2} L${p3} L${p4} L${p5} L${p6} L${p7} Z`;
    this.lastMoveArrowEl.setAttribute("d", d);

    // Color to match the piece that just landed on `to`.
    const movedPiece = this.engine.pieceAt(this.lastMove.to);
    const isWhitePiece = movedPiece >= 1 && movedPiece <= 6;
    this.lastMoveOverlayEl.style.color = isWhitePiece
      ? "rgba(248, 245, 235, 0.65)"   // soft cream — matches the white piece fill
      : "rgba(30, 25, 18, 0.6)";       // soft black — matches the black piece fill
    this.lastMoveOverlayEl.style.display = "";
  }

  /** Greys out the New Game form controls while a game is in progress.
   *  Re-enables them once the game ends (any cause) or the page is in
   *  its pre-game initial state. */
  private _renderNewGameSectionEnabled(): void {
    // "In a game" means: a round has been bootstrapped (engine + socket
    // are both ready) and the result hasn't landed yet.
    const inProgress = this.engine != null
      && this.socket != null
      && !this.gameOver;
    const lock = inProgress && !this.replayMode;
    const controls: Array<HTMLSelectElement | HTMLButtonElement | null> = [
      this.colorSelect, this.difficultySelect, this.timeSelect,
      this.startGameBtn,
    ];
    for (const el of controls) {
      if (el) el.disabled = lock;
    }
  }

  /**
   * Click handler for the FEN icon button. Branches on the button's
   * current mode:
   *   - dirty (load mode): apply the typed/pasted FEN to the engine.
   *   - clean (copy mode): write the current FEN to the clipboard.
   */
  private async _copyOrLoadFEN(): Promise<void> {
    if (!this.engine) return;
    const text = (this.fenValueEl?.textContent ?? "").trim();

    // Load mode: user has edited the field.
    if (this.fenDirty && text.length > 0) {
      const ok = await this.loadFENAndReset(text);
      if (!ok) {
        window.alert("That FEN was rejected by the parser.");
        return;
      }
      // Clear dirty AFTER the load completes (loadFENAndReset itself
      // triggers renderFEN, but it short-circuits while fenDirty is
      // still true). Then re-render to sync the field text with the
      // engine's just-applied FEN and toggle the button back to copy.
      this.fenDirty = false;
      this.renderFEN();
      return;
    }

    // Copy mode: clipboard the engine's current FEN.
    const fen = this.engine.currentFEN;
    if (!fen) return;
    try {
      await navigator.clipboard.writeText(fen);
    } catch {
      // Older browsers / non-secure contexts fall back to a textarea
      // + execCommand. The selection is what most users will paste.
      const ta = document.createElement("textarea");
      ta.value = fen;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand("copy"); } catch { /* nothing else to try */ }
      document.body.removeChild(ta);
    }
    if (this.copyFENBtn) {
      this.copyFENBtn.classList.add("copied");
      window.setTimeout(() => {
        this.copyFENBtn?.classList.remove("copied");
      }, 1200);
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
      // Route the flagged result through the standard game-over path so
      // the status panel swaps to its result layout. Winner is whoever
      // still has time on their clock.
      const winner: SideColor = this.whiteSecondsLeft <= 0 ? "black" : "white";
      this._applyEndData({ status: "outoftime", winner });
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
    // Hiding an untimed clock can change the column's reserved height.
    this._updateFullscreenBoardSize();
  }

  /**
   * Recomputes `--fullscreen-board-size` so the square board fits in
   * the viewport alongside whatever non-board children are currently
   * visible (banner, replay panel, captures rows). Called whenever any
   * of those toggle visibility, plus on window resize. A no-op when
   * we're not in fullscreen.
   */
  _updateFullscreenBoardSize(): void {
    const root = document.documentElement;
    if (!document.body.classList.contains("fullscreen")) {
      root.style.removeProperty("--fullscreen-board-size");
      return;
    }
    const column = this.boardEl.closest(".board-column") as HTMLElement | null;
    if (!column) return;

    const style = getComputedStyle(column);
    const gap = parseFloat(style.gap || "0");
    const padTop = parseFloat(style.paddingTop || "0");
    const padBottom = parseFloat(style.paddingBottom || "0");
    const padLeft = parseFloat(style.paddingLeft || "0");
    const padRight = parseFloat(style.paddingRight || "0");

    let reserved = padTop + padBottom;
    let visibleNonBoard = 0;
    for (const node of Array.from(column.children) as HTMLElement[]) {
      if (node.classList.contains("board-area")) continue;
      // Element is rendered if not hidden AND has measurable height.
      if (node.hidden) continue;
      const cs = getComputedStyle(node);
      if (cs.display === "none") continue;
      // offsetHeight includes the element's border/padding but excludes
      // collapsed margins, which is what we want for flex children.
      reserved += node.offsetHeight;
      visibleNonBoard++;
    }
    if (visibleNonBoard > 0) reserved += gap * visibleNonBoard;

    const availableHeight = Math.max(0, window.innerHeight - reserved);
    const availableWidth = Math.max(0, window.innerWidth - padLeft - padRight);
    const size = Math.max(0, Math.min(availableHeight, availableWidth));
    root.style.setProperty("--fullscreen-board-size", `${size}px`);
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
