// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0
//
// Page entry point — wires DOM elements to the ChessGameUI driver and
// resumes the most recent game from localStorage if one is present.

import { ChessGameUI, DIFFICULTIES } from "./chess-ui";

const $ = <T extends HTMLElement = HTMLElement>(id: string): T => {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Missing required element: #${id}`);
  return el as T;
};

const ui = new ChessGameUI({
  boardEl: $("board"),
  statusEl: $("status"),
  moveListEl: $("move-list"),
  whiteClockEl: $("white-clock"),
  blackClockEl: $("black-clock"),
  whiteCapturesEl: $("captures-white"),
  blackCapturesEl: $("captures-black"),
  evalEl: $("eval"),
  undoBtn: $<HTMLButtonElement>("btn-undo"),
  resignBtn: $<HTMLButtonElement>("btn-resign"),
  gameOverOverlayEl: $("game-over-banner"),
  gameOverResultEl: $("game-over-result"),
  gameOverReasonEl: $("game-over-reason"),
  gameOverIconEl: $("game-over-icon"),
  gameOverReplayBtn: $<HTMLButtonElement>("btn-game-over-replay"),
  replayPanelEl: $("replay-panel"),
  replaySliderEl: $<HTMLInputElement>("replay-slider"),
  replayCounterEl: $("replay-counter"),
  replayMoveLabelEl: $("replay-move-label"),
  replayFirstBtn: $<HTMLButtonElement>("btn-replay-first"),
  replayPrevBtn: $<HTMLButtonElement>("btn-replay-prev"),
  replayNextBtn: $<HTMLButtonElement>("btn-replay-next"),
  replayLastBtn: $<HTMLButtonElement>("btn-replay-last"),
  replayExitBtn: $<HTMLButtonElement>("btn-replay-exit"),
});

const colorSelect = $<HTMLSelectElement>("opt-color");
const difficultySelect = $<HTMLSelectElement>("opt-difficulty");
const timeSelect = $<HTMLSelectElement>("opt-time");
const difficultyDetail = $("difficulty-detail");
const loadingIndicator = $("loading-indicator");

// "New Game" button on the overlay restarts with the user's current
// menu selections.
$<HTMLButtonElement>("btn-game-over-new").addEventListener("click", () => {
  void ui.startNewGame({
    humanColor: colorSelect.value as "white" | "black" | "random",
    difficultyId: difficultySelect.value,
    timeControlId: timeSelect.value,
  });
});

// Expose for in-browser testing convenience.
(window as unknown as { __chess_ui: ChessGameUI }).__chess_ui = ui;

// ─────────────────────────────────────────────────  Fullscreen toggle
//
// Uses the Fullscreen API on document.documentElement so the whole page
// (not just one element) goes immersive. The `body.fullscreen` class is
// toggled from the `fullscreenchange` event so it stays in sync if the
// user presses Esc / the browser exits FS for any other reason.

const fullscreenBtn = $<HTMLButtonElement>("btn-fullscreen");
const enterIcon = document.getElementById("icon-fullscreen-enter");
const exitIcon = document.getElementById("icon-fullscreen-exit");

interface VendorFullscreenDocument extends Document {
  webkitFullscreenElement?: Element | null;
  webkitExitFullscreen?: () => Promise<void>;
}
interface VendorFullscreenElement extends HTMLElement {
  webkitRequestFullscreen?: () => Promise<void>;
}

function isInFullscreen(): boolean {
  const doc = document as VendorFullscreenDocument;
  return !!(doc.fullscreenElement || doc.webkitFullscreenElement);
}

function updateFullscreenIcons(): void {
  const inFs = isInFullscreen();
  document.body.classList.toggle("fullscreen", inFs);
  if (enterIcon) (enterIcon as HTMLElement).style.display = inFs ? "none" : "";
  if (exitIcon) (exitIcon as HTMLElement).style.display = inFs ? "" : "none";
  fullscreenBtn.title = inFs ? "Exit fullscreen" : "Enter fullscreen";
  // Recompute clock positioning after the layout shift.
  if (ui && ui.engine) ui.renderClocks();
}

fullscreenBtn.addEventListener("click", () => {
  const doc = document as VendorFullscreenDocument;
  if (isInFullscreen()) {
    const exitFn = doc.exitFullscreen ?? doc.webkitExitFullscreen;
    if (exitFn) void exitFn.call(document);
  } else {
    const root = document.documentElement as VendorFullscreenElement;
    const req = root.requestFullscreen ?? root.webkitRequestFullscreen;
    if (req) {
      req.call(root).catch((err: unknown) => console.warn("fullscreen denied", err));
    }
  }
});

document.addEventListener("fullscreenchange", updateFullscreenIcons);
document.addEventListener("webkitfullscreenchange", updateFullscreenIcons);
// Press F (toggle) or Esc (exit) as keyboard shortcuts.
document.addEventListener("keydown", (ev) => {
  if (ev.key === "f" || ev.key === "F") {
    const active = document.activeElement as HTMLElement | null;
    if (active && /input|select|textarea/i.test(active.tagName)) return;
    fullscreenBtn.click();
  }
});

function updateDifficultyDetail(): void {
  const id = difficultySelect.value;
  const d = DIFFICULTIES.find((x) => x.id === id);
  if (d) {
    difficultyDetail.textContent =
      `≈ ${d.elo} ELO · depth ${d.depth} · ${d.timeMs} ms/move`;
  }
}

/** Reflects the current ui settings in the form controls. */
function syncMenuFromUI(): void {
  colorSelect.value = ui.humanColor;
  difficultySelect.value = ui.difficulty.id;
  timeSelect.value = ui.timeControl.id;
  updateDifficultyDetail();
}

difficultySelect.addEventListener("change", updateDifficultyDetail);
updateDifficultyDetail();

$<HTMLButtonElement>("btn-start-game").addEventListener("click", () => {
  void ui.startNewGame({
    humanColor: colorSelect.value as "white" | "black" | "random",
    difficultyId: difficultySelect.value,
    timeControlId: timeSelect.value,
  });
});

$<HTMLButtonElement>("btn-load-fen").addEventListener("click", () => {
  const fen = window.prompt(
    "Paste a FEN string to load:",
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
  );
  if (!fen) return;
  void (async () => {
    if (!(await ui.loadFENAndReset(fen))) {
      window.alert("That FEN was rejected by the parser.");
    }
  })();
});

try {
  await ui.start("/skip-chess-web.wasm");
  // Resume the most recent game if there is one; otherwise auto-start a
  // default game so visitors see something immediately.
  const saved = ChessGameUI.loadSavedState();
  if (saved && await ui.resumeSavedGame(saved)) {
    syncMenuFromUI();
    loadingIndicator.textContent =
      `Resumed previous game (${ui.moveHistory.length} ${
        ui.moveHistory.length === 1 ? "move" : "moves"
      } played).`;
  } else {
    await ui.startNewGame({
      humanColor: "white",
      difficultyId: "hard",
      timeControlId: "untimed",
    });
    syncMenuFromUI();
    loadingIndicator.textContent = "Engine ready. Click Start.";
  }
} catch (err) {
  loadingIndicator.textContent = "Failed to load engine: " + String(err);
  console.error(err);
}
