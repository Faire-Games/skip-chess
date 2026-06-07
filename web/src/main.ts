// Licensed under the Mozilla Public License 2.0
// SPDX-License-Identifier: MPL-2.0
//
// Page entry point — wires DOM elements to the ChessGameUI driver and
// resumes the most recent game from localStorage if one is present.

import { ChessGameUI } from "./chess-ui";

const $ = <T extends HTMLElement = HTMLElement>(id: string): T => {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Missing required element: #${id}`);
  return el as T;
};

/** Same as `$`, but for SVG nodes — needed because TS distinguishes
 *  `HTMLElement` from `SVGElement` and the hint overlay is a real SVG. */
const $svg = (id: string): SVGElement => {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Missing required SVG element: #${id}`);
  return el as unknown as SVGElement;
};

const colorSelect = $<HTMLSelectElement>("opt-color");
const difficultySelect = $<HTMLSelectElement>("opt-difficulty");
const timeSelect = $<HTMLSelectElement>("opt-time");
const startGameBtn = $<HTMLButtonElement>("btn-start-game");
const loadingIndicator = $("loading-indicator");

const ui = new ChessGameUI({
  boardEl: $("board"),
  statusEl: $("status"),
  moveListEl: $("move-list"),
  whiteClockEl: $("white-clock"),
  blackClockEl: $("black-clock"),
  whiteCapturesEl: $("captures-white"),
  blackCapturesEl: $("captures-black"),
  evalEl: $("eval"),
  fenValueEl: $("fen-value"),
  copyFENBtn: $<HTMLButtonElement>("btn-copy-fen"),
  undoBtn: $<HTMLButtonElement>("btn-undo"),
  resignBtn: $<HTMLButtonElement>("btn-resign"),
  hintBtn: $<HTMLButtonElement>("btn-hint"),
  hintOverlayEl: $svg("hint-overlay"),
  hintArrowEl: $svg("hint-arrow"),
  lastMoveOverlayEl: $svg("last-move-overlay"),
  lastMoveArrowEl: $svg("last-move-arrow"),
  lastMoveArrowToggle: $<HTMLInputElement>("opt-last-move-arrow"),
  newGameSectionEl: $("new-game-section"),
  colorSelect,
  difficultySelect,
  timeSelect,
  startGameBtn,
  statusLiveEl: $("status-live"),
  statusGameOverEl: $("status-game-over"),
  inGameActionsEl: $("actions-in-game"),
  gameOverActionsEl: $("actions-game-over"),
  gameOverResultEl: $("game-over-result"),
  gameOverReasonEl: $("game-over-reason"),
  gameOverIconEl: $("game-over-icon"),
  gameOverReplayBtn: $<HTMLButtonElement>("btn-game-over-replay"),
  replayPanelEl: $("replay-panel"),
  replaySliderEl: $<HTMLInputElement>("replay-slider"),
  replayCounterEl: $("replay-counter"),
  replayMoveLabelEl: $("replay-move-label"),
  replayPrevBtn: $<HTMLButtonElement>("btn-replay-prev"),
  replayNextBtn: $<HTMLButtonElement>("btn-replay-next"),
  replayExitBtn: $<HTMLButtonElement>("btn-replay-exit"),
  replayResumeBtn: $<HTMLButtonElement>("btn-replay-resume"),
});

// Expose for in-browser testing convenience.
(window as unknown as { __chess_ui: ChessGameUI }).__chess_ui = ui;

// ─────────────────────────────────────────────────  Theme picker
//
// Light / System / Dark segmented control. The user's choice persists
// in localStorage; when set to "system", the page follows the OS
// `prefers-color-scheme`. We toggle `body.theme-{light|system|dark}`
// so the CSS variable overrides kick in.

type ThemeChoice = "light" | "system" | "dark";
const THEME_KEY = "skip-chess.theme.v1";

const themeButtons: Record<ThemeChoice, HTMLButtonElement> = {
  light: $<HTMLButtonElement>("btn-theme-light"),
  system: $<HTMLButtonElement>("btn-theme-system"),
  dark: $<HTMLButtonElement>("btn-theme-dark"),
};

function readSavedTheme(): ThemeChoice {
  try {
    const v = window.localStorage.getItem(THEME_KEY);
    if (v === "light" || v === "system" || v === "dark") return v;
  } catch { /* private mode etc. — fall through */ }
  return "system";
}

function applyTheme(choice: ThemeChoice): void {
  const body = document.body;
  body.classList.toggle("theme-light", choice === "light");
  body.classList.toggle("theme-system", choice === "system");
  body.classList.toggle("theme-dark", choice === "dark");
  for (const key of ["light", "system", "dark"] as ThemeChoice[]) {
    themeButtons[key].setAttribute("aria-checked",
      key === choice ? "true" : "false");
  }
  try { window.localStorage.setItem(THEME_KEY, choice); } catch { /* ignore */ }
}

for (const key of ["light", "system", "dark"] as ThemeChoice[]) {
  themeButtons[key].addEventListener("click", () => applyTheme(key));
}
applyTheme(readSavedTheme());

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
  // Recompute clock positioning + the JS-driven `--fullscreen-board-size`
  // after the layout shift, so the board fits whatever space is left
  // beside the banner / replay panel.
  if (ui && ui.engine) {
    ui.renderClocks();
    ui._updateFullscreenBoardSize();
  }
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

/** Reflects the current ui settings in the form controls. */
function syncMenuFromUI(): void {
  colorSelect.value = ui.humanColor;
  difficultySelect.value = ui.difficulty.id;
  timeSelect.value = ui.timeControl.id;
}

startGameBtn.addEventListener("click", () => {
  void ui.startNewGame({
    humanColor: colorSelect.value as "white" | "black" | "random",
    difficultyId: difficultySelect.value,
    timeControlId: timeSelect.value,
  });
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
  // A game is now in progress (either resumed or just started). The
  // button restarts the round when clicked, so re-label it accordingly.
  startGameBtn.textContent = "New game";
} catch (err) {
  loadingIndicator.textContent = "Failed to load engine: " + String(err);
  console.error(err);
}
