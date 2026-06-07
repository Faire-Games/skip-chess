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
  check(timeControls.length === 5, `5 time-control options (got ${timeControls.length})`);

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

  // Banner should be visible and NOT overlapping the board (its position
  // should be inside .board-column, OUTSIDE .board-area).
  const banner = await page.evaluate(() => {
    const el = document.getElementById("game-over-banner");
    if (!el) return null;
    const overlapsBoard = !!el.closest(".board-area");
    return {
      hidden: el.hidden,
      title: document.getElementById("game-over-result")?.textContent,
      reason: document.getElementById("game-over-reason")?.textContent,
      overlapsBoard,
    };
  });
  check(banner && !banner.hidden, `result banner visible after endData`);
  check(banner?.title === "Checkmate", `banner title is "Checkmate" (got "${banner?.title}")`);
  check(/White wins/.test(banner?.reason || ""), `banner reason mentions winner (got "${banner?.reason}")`);
  check(!banner?.overlapsBoard, `banner is OUTSIDE the board area (no longer overlays the board)`);

  // Click the "Replay" button.
  await page.click("#btn-game-over-replay");

  const replayInit = await page.evaluate(() => {
    const panel = document.getElementById("replay-panel");
    const slider = document.getElementById("replay-slider");
    const banner = document.getElementById("game-over-banner");
    return {
      panelVisible: panel && !panel.hidden,
      bannerHidden: banner && banner.hidden,
      replayMode: window.__chess_ui.isReplayMode(),
      sliderMin: slider?.min,
      sliderMax: slider?.max,
      sliderValue: slider?.value,
      counter: document.getElementById("replay-counter")?.textContent,
    };
  });
  check(replayInit.replayMode, `replay mode active after clicking Replay`);
  check(replayInit.panelVisible, `replay panel visible`);
  check(replayInit.bannerHidden, `result banner hidden while in replay`);
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

  // Exit replay → banner re-appears, panel hides.
  await page.click("#btn-replay-exit");
  // Wait for the async loadFEN + re-show to land.
  await page.waitForFunction(
    () => !window.__chess_ui.isReplayMode()
       && !document.getElementById("game-over-banner")?.hidden,
    { timeout: 5000 },
  );
  const exitState = await page.evaluate(() => {
    const panel = document.getElementById("replay-panel");
    const banner = document.getElementById("game-over-banner");
    return {
      panelHidden: panel && panel.hidden,
      bannerVisible: banner && !banner.hidden,
      replayMode: window.__chess_ui.isReplayMode(),
    };
  });
  check(!exitState.replayMode, `replay mode inactive after Exit replay`);
  check(exitState.panelHidden, `replay panel hidden on exit`);
  check(exitState.bannerVisible, `result banner re-shown on exit`);

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
