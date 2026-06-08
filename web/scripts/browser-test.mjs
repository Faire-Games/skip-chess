// Headless browser test of the live Astro dev page.
// Loads the page, waits for the engine to boot, then asserts that the
// chess board has 32 pieces rendered and the engine has played at least
// one move when the human is black.

import puppeteer from "puppeteer";

const URL = process.env.PAGE_URL || "http://localhost:4444/";

const browser = await puppeteer.launch({
  headless: true,
  executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  args: ["--no-sandbox"],
});

let failed = 0;
function check(cond, label) {
  if (!cond) {
    console.error(`✗ ${label}`);
    failed++;
  } else {
    console.log(`✓ ${label}`);
  }
}

try {
  const page = await browser.newPage();
  const consoleLines = [];
  page.on("console", (msg) => consoleLines.push(`[console:${msg.type()}] ${msg.text()}`));
  page.on("pageerror", (err) => consoleLines.push(`[pageerror] ${err.message}`));
  page.on("requestfailed", (req) => consoleLines.push(`[requestfailed] ${req.url()} ${req.failure()?.errorText}`));

  await page.goto(URL, { waitUntil: "domcontentloaded", timeout: 15000 });

  // Wait for the loading indicator to flip into "Engine ready" or a startNewGame call.
  try {
    await page.waitForFunction(
      () => document.querySelectorAll("#board .square .piece").length === 32,
      { timeout: 20000 },
    );
  } catch (e) {
    console.error("\n--- Browser console transcript ---");
    for (const line of consoleLines) console.error("  " + line);
    const loadingText = await page.$eval("#loading-indicator", (el) => el.textContent).catch(() => "(missing)");
    const statusText = await page.$eval("#status", (el) => el.textContent).catch(() => "(missing)");
    console.error(`loading-indicator: "${loadingText}"`);
    console.error(`status:            "${statusText}"`);
    throw e;
  }

  const pieceCount = await page.$$eval("#board .square .piece", (els) => els.length);
  check(pieceCount === 32, `board renders 32 pieces (got ${pieceCount})`);

  const status = await page.$eval("#status", (el) => el.textContent);
  check(status.includes("White") || status.includes("Black"), `status shows a side-to-move (${status})`);

  // Verify menu options.
  const difficulties = await page.$$eval("#opt-difficulty option", (els) => els.map((e) => e.value));
  check(difficulties.length === 5, `5 difficulty options (got ${difficulties.length})`);

  const timeControls = await page.$$eval("#opt-time option", (els) => els.map((e) => e.value));
  // Lichess-style brackets: untimed + bullet/blitz/rapid/classical variants.
  check(timeControls.length >= 11,
        `at least 11 time-control options (got ${timeControls.length})`);
  check(timeControls.includes("bullet1") && timeControls.includes("rapid15"),
        `time controls include Bullet 1+0 and Rapid 15+10`);

  // Drive the human-vs-engine flow through the UI's public path: play
  // e2-e4 as white and wait for the engine to reply.
  await page.evaluate(() => window.__chess_ui.attemptHumanMove("e2e4"));
  await page.waitForFunction(
    () => document.querySelectorAll("#move-list li").length >= 2,
    { timeout: 10000 },
  );
  const moveCount = await page.$$eval("#move-list li", (els) => els.length);
  check(moveCount === 2, `move list has 2 plies after human + engine move (got ${moveCount})`);

  const moves = await page.$$eval("#move-list li", (els) => els.map((e) => e.textContent));
  check(moves[0] === "e2e4", `human move recorded as e2e4 (got "${moves[0]}")`);
  check(moves[1].length >= 4, `engine move recorded (got "${moves[1]}")`);
  console.log(`info: engine played ${moves[1]}`);

  // The Lichess-style wire doesn't carry engine search stats, so the
  // eval line just needs to be empty (no leftover "Thinking…" caption).
  const evalText = await page.$eval("#eval", (el) => el.textContent);
  check(!evalText.includes("Thinking"), `eval line cleared after engine move (got "${evalText}")`);

  // Socket lifecycle: every accepted versioned event bumps `lastVersion`,
  // so after init snapshot + human + engine moves we should be at v ≥ 3.
  const socketVersion = await page.evaluate(
    () => window.__chess_ui.socket?.lastVersion ?? -1,
  );
  check(socketVersion >= 3, `socket lastVersion ≥ 3 after move (got ${socketVersion})`);

  // Flicker regression: selecting a piece must NOT recreate the 64
  // square <div>s. We tag every square with a unique data attribute, click
  // a piece to trigger selection, and assert the tags are still there.
  const undisturbed = await page.evaluate(() => {
    const squares = document.querySelectorAll("#board .square");
    squares.forEach((sq, i) => (sq.dataset.flickerToken = String(i)));
    // Pick up the white pawn on g2.
    window.__chess_ui.handlePointerDown(
      { clientX: 0, clientY: 0 },
      14, // g2 = file 6 rank 1 = 14
    );
    const after = document.querySelectorAll("#board .square");
    let ok = after.length === squares.length;
    for (let i = 0; i < after.length && ok; i++) {
      if (after[i].dataset.flickerToken !== String(i)) ok = false;
    }
    return ok;
  });
  check(undisturbed, "selecting a piece preserves the existing square DOM nodes (no flicker)");

  // Persistence regression: localStorage was written after a move, and
  // it contains the current position.
  const storage = await page.evaluate(() => {
    const raw = window.localStorage.getItem("skip-chess.game-state.v1");
    if (!raw) return null;
    try {
      return JSON.parse(raw);
    } catch {
      return null;
    }
  });
  check(storage !== null, "localStorage holds saved game state");
  check(
    typeof storage?.fen === "string" && storage.fen.includes(" "),
    `saved fen looks like a real FEN (${storage?.fen})`,
  );
  check(
    Array.isArray(storage?.moveHistory) && storage.moveHistory.length === 2,
    `saved move history has 2 plies (got ${storage?.moveHistory?.length})`,
  );
  check(storage?.humanColor === "white", "saved humanColor is white");

  // Simulate a reload by reloading the page and re-checking state.
  await page.reload({ waitUntil: "domcontentloaded" });
  await page.waitForFunction(
    () => document.querySelectorAll("#board .square .piece").length === 32,
    { timeout: 20000 },
  );
  const resumedMoves = await page.$$eval("#move-list li", (els) =>
    els.map((e) => e.textContent),
  );
  check(
    resumedMoves.length === 2 && resumedMoves[0] === "e2e4",
    `move list survives reload (got ${JSON.stringify(resumedMoves)})`,
  );
  const resumedLoading = await page.$eval(
    "#loading-indicator",
    (el) => el.textContent,
  );
  check(
    resumedLoading.includes("Resumed previous game"),
    `loading indicator notes the resumed game ("${resumedLoading}")`,
  );

  // ─────────────────────────────────  Game-over banner + replay panel
  //
  // The banner now sits BELOW the board (no longer overlaid) and the
  // user can click "Replay" to scrub through the move history. We
  // simulate a game-over by injecting an `endData` envelope into the
  // socket, which is the same path the engine uses for real checkmates.
  //
  // Two plies have been played (e2e4 + engine reply) so the slider
  // should range from 0..2.

  await page.evaluate(() => {
    window.__chess_ui.socket._receive(JSON.stringify({
      t: "endData",
      d: { status: "mate", winner: "white" },
    }));
  });

  // Game-over indicator now lives INSIDE the right-column status panel
  // (the freestanding banner above the board is gone). After endData the
  // status-game-over div should be visible AND inside .sidebar-card.
  const indicator = await page.evaluate(() => {
    const el = document.getElementById("status-game-over");
    if (!el) return null;
    const inSidebar = !!el.closest(".sidebar-card");
    return {
      hidden: el.hidden,
      title: document.getElementById("game-over-result")?.textContent,
      reason: document.getElementById("game-over-reason")?.textContent,
      inSidebar,
      liveHidden: !!document.getElementById("status-live")?.hidden,
      gameOverActionsVisible: !document.getElementById("actions-game-over")?.hidden,
      inGameActionsHidden: !!document.getElementById("actions-in-game")?.hidden,
    };
  });
  check(indicator && !indicator.hidden, `game-over indicator visible after endData`);
  check(indicator?.title === "Checkmate", `indicator title is "Checkmate" (got "${indicator?.title}")`);
  check(/White wins/.test(indicator?.reason || ""), `indicator reason mentions winner (got "${indicator?.reason}")`);
  check(indicator?.inSidebar, `indicator lives inside the right-column status panel`);
  check(indicator?.liveHidden, `live status hidden once the game ends`);
  check(indicator?.gameOverActionsVisible, `Replay/New Game actions visible after game ends`);
  check(indicator?.inGameActionsHidden, `Hint/Undo/Resign actions hidden after game ends`);

  // Click the "Replay" button.
  await page.click("#btn-game-over-replay");

  const replayInit = await page.evaluate(() => {
    const panel = document.getElementById("replay-panel");
    const slider = document.getElementById("replay-slider");
    const indicator = document.getElementById("status-game-over");
    return {
      panelVisible: panel && !panel.hidden,
      // The indicator is persistent — it stays visible during replay.
      indicatorVisible: indicator && !indicator.hidden,
      replayMode: window.__chess_ui.isReplayMode(),
      // The game-over action buttons (Replay/New Game) should be hidden
      // during replay because the replay panel has its own controls.
      gameOverActionsHidden: !!document.getElementById("actions-game-over")?.hidden,
      sliderMin: slider?.min,
      sliderMax: slider?.max,
      sliderValue: slider?.value,
      counter: document.getElementById("replay-counter")?.textContent,
    };
  });
  check(replayInit.replayMode, `replay mode active after clicking Replay`);
  check(replayInit.panelVisible, `replay panel visible`);
  check(replayInit.indicatorVisible, `game-over indicator persistent during replay`);
  check(replayInit.gameOverActionsHidden, `Replay/New Game actions hidden during replay`);
  check(replayInit.sliderMin === "0" && replayInit.sliderMax === "2",
        `slider range 0..2 (got ${replayInit.sliderMin}..${replayInit.sliderMax})`);
  check(replayInit.sliderValue === "2", `slider starts at the final ply (got ${replayInit.sliderValue})`);
  check(replayInit.counter === "2 / 2", `counter shows 2 / 2 (got "${replayInit.counter}")`);

  // Scrub to ply 0 (initial position).
  await page.evaluate(() => {
    const slider = document.getElementById("replay-slider");
    slider.value = "0";
    slider.dispatchEvent(new Event("input", { bubbles: true }));
  });
  // Allow the worker round-trip to complete.
  await page.waitForFunction(
    () => document.getElementById("replay-counter")?.textContent === "0 / 2",
    { timeout: 5000 },
  );
  // Initial position: a white pawn should be on e2 again.
  const initialPieceCount = await page.$$eval("#board .square .piece", (els) => els.length);
  check(initialPieceCount === 32, `replay @ ply 0 shows all 32 pieces (got ${initialPieceCount})`);
  const e2Piece = await page.evaluate(() => {
    // square 12 = e2 (file 4, rank 1, → 1*8+4=12)
    const cell = document.querySelector('[data-square="12"]');
    const piece = cell?.querySelector(".piece");
    return piece?.dataset.code ?? null;
  });
  check(e2Piece === "1", `e2 has a white pawn at ply 0 (got piece code ${e2Piece})`);

  // Scrub forward to ply 1: white pawn should now be on e4.
  await page.evaluate(() => {
    const slider = document.getElementById("replay-slider");
    slider.value = "1";
    slider.dispatchEvent(new Event("input", { bubbles: true }));
  });
  await page.waitForFunction(
    () => document.getElementById("replay-counter")?.textContent === "1 / 2",
    { timeout: 5000 },
  );
  const e4Piece = await page.evaluate(() => {
    // square 28 = e4 (3*8+4)
    const cell = document.querySelector('[data-square="28"]');
    const piece = cell?.querySelector(".piece");
    return piece?.dataset.code ?? null;
  });
  check(e4Piece === "1", `e4 has the white pawn at ply 1 (got piece code ${e4Piece})`);

  // Exit replay → game-over action buttons reappear, replay panel hides.
  await page.click("#btn-replay-exit");
  // Wait for the async loadFEN + re-show to land.
  await page.waitForFunction(
    () => !window.__chess_ui.isReplayMode()
       && !document.getElementById("actions-game-over")?.hidden,
    { timeout: 5000 },
  );
  const exitState = await page.evaluate(() => {
    const panel = document.getElementById("replay-panel");
    const indicator = document.getElementById("status-game-over");
    return {
      panelHidden: panel && panel.hidden,
      indicatorVisible: indicator && !indicator.hidden,
      gameOverActionsVisible: !document.getElementById("actions-game-over")?.hidden,
      replayMode: window.__chess_ui.isReplayMode(),
    };
  });
  check(!exitState.replayMode, `replay mode inactive after Exit replay`);
  check(exitState.panelHidden, `replay panel hidden on exit`);
  check(exitState.indicatorVisible, `game-over indicator still visible after exit`);
  check(exitState.gameOverActionsVisible, `Replay/New Game actions visible again after exit`);

  // ─────────────────────────────────  FEN section + Load FEN regression
  //
  // The Status sidebar shows the current FEN with a copy button. We
  // also verify the regression where `loadFENAndReset` left the protocol
  // session pointed at the previous game's state — the symptom was that
  // moves after a FEN load looked frozen because socket.send was being
  // gated on stale RoundSession state.

  // The FEN element should be populated with a real FEN string.
  const fenInitial = await page.$eval("#fen-value", (el) => el.textContent);
  check(
    typeof fenInitial === "string" && fenInitial.includes(" "),
    `FEN element shows a real FEN (${fenInitial?.slice(0, 40)}...)`,
  );

  // Load a known mid-game position with white to move.
  const loadedOK = await page.evaluate(async () => {
    const fen = "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3";
    return await window.__chess_ui.loadFENAndReset(fen);
  });
  check(loadedOK, "loadFENAndReset returns true for a valid FEN");
  await page.waitForFunction(
    () => document.getElementById("fen-value")?.textContent?.startsWith("r1bqkbnr"),
    { timeout: 5000 },
  );
  const fenAfterLoad = await page.$eval("#fen-value", (el) => el.textContent);
  check(
    fenAfterLoad?.startsWith("r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R"),
    `FEN display updated to loaded position (${fenAfterLoad?.slice(0, 40)}...)`,
  );

  // Move history should be empty after the load (fresh round).
  const movesAfterLoad = await page.$$eval("#move-list li", (els) => els.length);
  check(movesAfterLoad === 0, `move list cleared after Load FEN (got ${movesAfterLoad})`);

  // CRITICAL: a human move should still work. This is the bug — before
  // the fix, the protocol was still tracking the old game so the move
  // would be silently rejected (resync) and the UI would look frozen.
  await page.evaluate(() => window.__chess_ui.attemptHumanMove("f1c4"));
  await page.waitForFunction(
    () => document.querySelectorAll("#move-list li").length >= 2,
    { timeout: 10000 },
  );
  const movesAfterPlay = await page.$$eval("#move-list li", (els) =>
    els.map((e) => e.textContent),
  );
  check(
    movesAfterPlay.length >= 2 && movesAfterPlay[0] === "f1c4",
    `human move played after Load FEN (got ${JSON.stringify(movesAfterPlay)})`,
  );

  // Hint button: should compute a best move via the engine and draw an
  // arrow overlay on the board. We're now in the post-Load-FEN game with
  // it being white to move (engine just replied with g8f6).
  await page.click("#btn-hint");
  await page.waitForFunction(
    () => document.getElementById("hint-overlay")?.style.display !== "none",
    { timeout: 15000 },
  );
  const hint = await page.evaluate(() => {
    const arrow = document.getElementById("hint-arrow");
    return {
      x1: arrow?.getAttribute("x1"),
      y1: arrow?.getAttribute("y1"),
      x2: arrow?.getAttribute("x2"),
      y2: arrow?.getAttribute("y2"),
    };
  });
  // Any real arrow has non-equal x1/x2 OR non-equal y1/y2 (no zero-len line).
  const isReal = hint.x1 !== hint.x2 || hint.y1 !== hint.y2;
  check(isReal, `Hint button drew a real arrow (${hint.x1},${hint.y1} → ${hint.x2},${hint.y2})`);

  // Copy-FEN button: verify clipboard write fires and the "copied" CSS
  // class toggles on. Puppeteer needs explicit clipboard permission.
  await page.browserContext().overridePermissions(URL, ["clipboard-read", "clipboard-write"]);
  await page.click("#btn-copy-fen");
  // The handler awaits clipboard.writeText before adding the class.
  await page.waitForFunction(
    () => document.getElementById("btn-copy-fen")?.classList.contains("copied"),
    { timeout: 3000 },
  );
  check(true, "copy button shows 'copied' state after click");
  const clipboardText = await page.evaluate(() => navigator.clipboard.readText());
  check(
    typeof clipboardText === "string" && clipboardText.includes(" "),
    `clipboard holds the FEN (${clipboardText?.slice(0, 40)}...)`,
  );

  // ─────────────────────────────────  Editable FEN field + load mode
  //
  // The FEN element is contenteditable. Typing/pasting a new FEN should
  // flip the icon button into "load mode"; clicking it then applies the
  // new position to the engine.
  const editableFen = await page.evaluate(() => {
    const el = document.getElementById("fen-value");
    return el?.getAttribute("contenteditable");
  });
  check(editableFen === "plaintext-only",
        `FEN field is contenteditable (got "${editableFen}")`);

  // Type a different FEN into the field and dispatch input event.
  // (Italian-game position so a subsequent move has many engine
  // replies and doesn't end the game.)
  const targetFen = "r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4";
  await page.evaluate((fen) => {
    const el = document.getElementById("fen-value");
    el.textContent = fen;
    el.dispatchEvent(new InputEvent("input", { bubbles: true }));
  }, targetFen);

  const loadMode = await page.evaluate(() => {
    const btn = document.getElementById("btn-copy-fen");
    const loadIcon = btn?.querySelector(".icon-load");
    return {
      hasLoadClass: btn?.classList.contains("load-mode"),
      loadIconVisible: loadIcon && getComputedStyle(loadIcon).display !== "none",
      title: btn?.title,
    };
  });
  check(loadMode.hasLoadClass, `button shows load-mode class after edit`);
  check(loadMode.loadIconVisible, `load icon visible after edit`);
  check(loadMode.title === "Load this FEN",
        `button tooltip flipped to load (got "${loadMode.title}")`);

  // Click the button → engine adopts the edited FEN.
  await page.click("#btn-copy-fen");
  await page.waitForFunction(
    () => !document.getElementById("btn-copy-fen")?.classList.contains("load-mode"),
    { timeout: 5000 },
  );
  const afterLoad = await page.evaluate(() => ({
    fen: document.getElementById("fen-value")?.textContent,
    btnTitle: document.getElementById("btn-copy-fen")?.title,
  }));
  check(
    afterLoad.fen?.startsWith("r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2"),
    `engine loaded the typed FEN (got "${afterLoad.fen?.slice(0, 40)}...")`,
  );
  check(afterLoad.btnTitle === "Copy FEN",
        `button reverts to copy mode after load`);

  // Play a move so the move list isn't empty for the next test (which
  // expects Undo to be enabled). b1c3 is a normal knight development.
  await page.evaluate(() => window.__chess_ui.attemptHumanMove("b1c3"));
  await page.waitForFunction(
    () => document.querySelectorAll("#move-list li").length >= 2,
    { timeout: 15000 },
  );

  // ─────────────────────────────────  Disabled action buttons
  //
  // After Load FEN + a single human move + an engine reply, all three
  // status-area buttons should be back to enabled (game is live, it's
  // the human's turn, history has plies).
  const liveStates = await page.evaluate(() => ({
    hint: document.getElementById("btn-hint").disabled,
    undo: document.getElementById("btn-undo").disabled,
    resign: document.getElementById("btn-resign").disabled,
  }));
  check(!liveStates.hint, `Hint enabled mid-game`);
  check(!liveStates.undo, `Undo enabled mid-game`);
  check(!liveStates.resign, `Resign enabled mid-game`);

  // ─────────────────────────────────  Engine-detected game end re-enables New Game
  //
  // Load a stalemate FEN (W: K c2 vs B: K a1 + Q b1 — actually use a
  // simpler "K vs K" insufficient-material draw; the WASM detects it
  // from the board state alone, so no endData envelope arrives). The
  // status-bar's New Game button must re-enable so the user can start
  // a fresh round.
  const drawLoaded = await page.evaluate(async () => {
    return await window.__chess_ui.loadFENAndReset(
      "4k3/8/8/8/8/8/8/4K3 w - - 0 1",  // K vs K — insufficient material
    );
  });
  check(drawLoaded, `loaded K-vs-K draw position`);
  await page.waitForFunction(
    () => !document.getElementById("btn-start-game").disabled,
    { timeout: 5000 },
  );
  const drawState = await page.evaluate(() => ({
    gameOver: window.__chess_ui.gameOver,
    startBtnEnabled: !document.getElementById("btn-start-game").disabled,
    statusText: document.getElementById("status")?.textContent,
  }));
  check(drawState.startBtnEnabled,
        `New Game button enabled on engine-detected draw (status="${drawState.statusText}")`);

  // Restart a real game for the rest of the test.
  await page.evaluate(async () => {
    await window.__chess_ui.startNewGame({
      humanColor: "white",
      difficultyId: "easy",
      timeControlId: "blitz5",
    });
    await window.__chess_ui.attemptHumanMove("e2e4");
  });
  await page.waitForFunction(
    () => document.querySelectorAll("#move-list li").length >= 2,
    { timeout: 15000 },
  );

  // Inject endData to flip to game-over and verify Hint/Undo/Resign go disabled.
  await page.evaluate(() => {
    window.__chess_ui.socket._receive(JSON.stringify({
      t: "endData",
      d: { status: "mate", winner: "white" },
    }));
  });
  // The in-game actions block is hidden in game-over mode, but the
  // buttons themselves should also be marked disabled.
  const overStates = await page.evaluate(() => ({
    hint: document.getElementById("btn-hint").disabled,
    undo: document.getElementById("btn-undo").disabled,
    resign: document.getElementById("btn-resign").disabled,
  }));
  check(overStates.hint, `Hint disabled after game over`);
  check(overStates.resign, `Resign disabled after game over`);

  // ─────────────────────────────────  No horizontal scroll
  //
  // Even with the replay panel open, the page must never scroll
  // horizontally — neither at the 3-column wide layout nor at the
  // single-column responsive layout. We check both sizes after opening
  // the replay panel (which is the worst-case width inside the sidebar).
  await page.click("#btn-game-over-replay");
  await page.waitForFunction(
    () => !document.getElementById("replay-panel")?.hidden,
    { timeout: 5000 },
  );
  for (const viewport of [
    { width: 1400, height: 900, label: "3-column (1400×900)" },
    { width: 800,  height: 900, label: "1-column (800×900)" },
  ]) {
    await page.setViewport({ width: viewport.width, height: viewport.height });
    // Let layout settle.
    await new Promise((r) => setTimeout(r, 100));
    const sizes = await page.evaluate(() => ({
      scrollWidth: document.documentElement.scrollWidth,
      clientWidth: document.documentElement.clientWidth,
    }));
    check(
      sizes.scrollWidth <= sizes.clientWidth,
      `no horizontal scroll @ ${viewport.label} ` +
      `(scrollWidth=${sizes.scrollWidth}, clientWidth=${sizes.clientWidth})`,
    );
  }

  // Exit replay so subsequent tests run with the live UI.
  await page.click("#btn-replay-exit");
  await page.waitForFunction(
    () => !window.__chess_ui.isReplayMode(),
    { timeout: 5000 },
  );

  // ─────────────────────────────────  Top-right toolbar
  // The theme picker and fullscreen button live inside the same fixed
  // container `.top-right-controls`. Previously they were separate.
  const toolbar = await page.evaluate(() => {
    const widget = document.querySelector(".top-right-controls");
    return {
      hasPicker: !!widget?.querySelector(".theme-picker"),
      hasFsBtn: !!widget?.querySelector("#btn-fullscreen"),
    };
  });
  check(toolbar.hasPicker && toolbar.hasFsBtn,
        `theme picker + fullscreen toggle share the top-right toolbar`);

  // ─────────────────────────────────  Theme picker
  const themeBefore = await page.evaluate(() => ({
    bodyClasses: Array.from(document.body.classList),
    systemActive: document.getElementById("btn-theme-system").getAttribute("aria-checked"),
  }));
  // Initial default is "system" since nothing was saved this run.
  check(
    themeBefore.bodyClasses.includes("theme-system"),
    `default theme is system (body classes: ${themeBefore.bodyClasses.join(",")})`,
  );
  check(themeBefore.systemActive === "true", `system segment marked active`);

  // Click "Dark" and verify the body class + aria-checked attrs flip.
  await page.click("#btn-theme-dark");
  const themeAfter = await page.evaluate(() => ({
    isDark: document.body.classList.contains("theme-dark"),
    isSystem: document.body.classList.contains("theme-system"),
    darkActive: document.getElementById("btn-theme-dark").getAttribute("aria-checked"),
    saved: window.localStorage.getItem("skip-chess.theme.v1"),
  }));
  check(themeAfter.isDark && !themeAfter.isSystem,
        `body class flipped to theme-dark`);
  check(themeAfter.darkActive === "true", `dark segment marked active`);
  check(themeAfter.saved === "dark", `theme choice persisted to localStorage`);

  // ─────────────────────────────────  Undo restores clocks
  //
  // Start a timed game, play a move, wait for engine reply, undo, and
  // verify both clock readings revert to what they were before the move.
  await page.evaluate(async () => {
    await window.__chess_ui.startNewGame({
      humanColor: "white",
      difficultyId: "easy",
      timeControlId: "blitz5",
    });
  });
  await page.waitForFunction(
    () => document.querySelectorAll("#move-list li").length === 0
       && document.getElementById("white-clock").textContent !== "—",
    { timeout: 10000 },
  );
  const startClocks = await page.evaluate(() => ({
    white: document.getElementById("white-clock").textContent,
    black: document.getElementById("black-clock").textContent,
  }));
  // Play a move + wait for engine reply.
  await page.evaluate(() => window.__chess_ui.attemptHumanMove("e2e4"));
  await page.waitForFunction(
    () => document.querySelectorAll("#move-list li").length >= 2,
    { timeout: 15000 },
  );
  // Capture clocks AFTER the engine reply landed.
  const midClocks = await page.evaluate(() => ({
    white: document.getElementById("white-clock").textContent,
    black: document.getElementById("black-clock").textContent,
  }));
  // Undo and verify the clocks rolled back.
  await page.evaluate(() => window.__chess_ui.undoUserMove());
  await page.waitForFunction(
    () => document.querySelectorAll("#move-list li").length === 0,
    { timeout: 5000 },
  );
  const afterUndoClocks = await page.evaluate(() => ({
    white: document.getElementById("white-clock").textContent,
    black: document.getElementById("black-clock").textContent,
  }));
  check(
    afterUndoClocks.white === startClocks.white
      && afterUndoClocks.black === startClocks.black,
    `clocks restored on undo (start=${startClocks.white}/${startClocks.black} → mid=${midClocks.white}/${midClocks.black} → after undo=${afterUndoClocks.white}/${afterUndoClocks.black})`,
  );

  // ─────────────────────────────────  Last Move Arrow toggle
  //
  // Toggling on should show the arrow over the last move. With no last
  // move on the board (fresh undo above), it's hidden; play a move and
  // toggle on — the arrow should render.
  await page.evaluate(() => window.__chess_ui.attemptHumanMove("d2d4"));
  await page.waitForFunction(
    () => document.querySelectorAll("#move-list li").length >= 2,
    { timeout: 15000 },
  );
  await page.evaluate(() => {
    const t = document.getElementById("opt-last-move-arrow");
    t.checked = true;
    t.dispatchEvent(new Event("change", { bubbles: true }));
  });
  const lmArrowOn = await page.evaluate(() => {
    const ov = document.getElementById("last-move-overlay");
    const ln = document.getElementById("last-move-arrow");
    return {
      visible: ov.style.display !== "none",
      // The arrow is now drawn as a single filled <path>, not a <line>.
      // A real arrow's `d` attribute begins with M (moveto) and contains
      // at least seven points (the 7-vertex polygon).
      d: ln.getAttribute("d"),
    };
  });
  check(lmArrowOn.visible, `last-move arrow visible when toggle is on`);
  // 7 vertices + closing Z = at least 7 commas in coords.
  const vertexCount = (lmArrowOn.d?.match(/,/g) || []).length;
  check(vertexCount >= 7,
        `last-move arrow is a polygon path with ≥7 vertices (got ${vertexCount} commas in d="${lmArrowOn.d?.slice(0, 60)}...")`);
  // Persisted to localStorage so the choice survives reloads.
  const lmSaved = await page.evaluate(
    () => window.localStorage.getItem("skip-chess.last-move-arrow.v1"));
  check(lmSaved === "1", `last-move-arrow choice persisted ("${lmSaved}")`);

  // Toggling off hides it again.
  await page.evaluate(() => {
    const t = document.getElementById("opt-last-move-arrow");
    t.checked = false;
    t.dispatchEvent(new Event("change", { bubbles: true }));
  });
  const lmArrowOff = await page.evaluate(
    () => document.getElementById("last-move-overlay").style.display);
  check(lmArrowOff === "none", `last-move arrow hidden when toggle is off`);

  // ─────────────────────────────────  New Game options disabled while in game
  //
  // We currently have a live game in progress (after the d2d4 move).
  // The New Game selects/buttons should be disabled.
  const liveDisabled = await page.evaluate(() => ({
    color: document.getElementById("opt-color").disabled,
    difficulty: document.getElementById("opt-difficulty").disabled,
    time: document.getElementById("opt-time").disabled,
    start: document.getElementById("btn-start-game").disabled,
  }));
  check(liveDisabled.color, `Color select disabled mid-game`);
  check(liveDisabled.difficulty, `Difficulty select disabled mid-game`);
  check(liveDisabled.time, `Time control select disabled mid-game`);
  check(liveDisabled.start, `Start button disabled mid-game`);

  // Resign → game over → controls re-enabled.
  await page.evaluate(() => window.__chess_ui.resign());
  await page.waitForFunction(
    () => !document.getElementById("opt-color").disabled,
    { timeout: 3000 },
  );
  const overEnabled = await page.evaluate(() => ({
    color: document.getElementById("opt-color").disabled,
    start: document.getElementById("btn-start-game").disabled,
  }));
  check(!overEnabled.color && !overEnabled.start,
        `New Game options re-enabled after resign`);

  // Clean up localStorage so subsequent runs of the test start fresh.
  await page.evaluate(() => window.localStorage.clear());

  if (failed === 0) {
    console.log("\nALL BROWSER CHECKS PASSED");
  } else {
    console.log("\nConsole log from page:");
    for (const line of consoleLines) console.log("  " + line);
  }
} catch (err) {
  console.error("Browser test crashed:", err);
  failed++;
} finally {
  await browser.close();
}

process.exit(failed === 0 ? 0 : 1);
