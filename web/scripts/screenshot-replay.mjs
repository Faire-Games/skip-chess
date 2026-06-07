// One-off visual check: capture the game-result banner (post-game) and
// then the replay panel after clicking "Replay". Used to confirm the
// new layout doesn't overlap the board.

import puppeteer from "puppeteer";

const URL = process.env.PAGE_URL || "http://localhost:4444/";

const browser = await puppeteer.launch({
  headless: true,
  executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  args: ["--no-sandbox"],
  defaultViewport: { width: 1400, height: 1100, deviceScaleFactor: 2 },
});

const page = await browser.newPage();
await page.goto(URL, { waitUntil: "domcontentloaded" });
await page.waitForFunction(
  () => document.querySelectorAll("#board .square .piece").length === 32,
  { timeout: 15000 },
);

// Play two moves so there's something to scrub through.
await page.evaluate(() => window.__chess_ui.attemptHumanMove("e2e4"));
await page.waitForFunction(
  () => document.querySelectorAll("#move-list li").length >= 2,
  { timeout: 10000 },
);
await page.evaluate(() => window.__chess_ui.attemptHumanMove("g1f3"));
await page.waitForFunction(
  () => document.querySelectorAll("#move-list li").length >= 4,
  { timeout: 10000 },
);

// Inject endData to put the UI into the game-over state.
await page.evaluate(() => {
  window.__chess_ui.socket._receive(JSON.stringify({
    t: "endData",
    d: { status: "mate", winner: "white" },
  }));
});
await page.waitForFunction(
  () => !document.getElementById("game-over-banner")?.hidden,
  { timeout: 5000 },
);
// Let the fade-in animation finish before capturing.
await new Promise((r) => setTimeout(r, 400));
await page.screenshot({ path: "screenshot-banner.png", fullPage: false });
console.log("wrote screenshot-banner.png");

// Click Replay and scrub to ply 1.
await page.click("#btn-game-over-replay");
await page.waitForFunction(
  () => !document.getElementById("replay-panel")?.hidden,
  { timeout: 5000 },
);
await page.evaluate(() => {
  const slider = document.getElementById("replay-slider");
  slider.value = "1";
  slider.dispatchEvent(new Event("input", { bubbles: true }));
});
await page.waitForFunction(
  () => document.getElementById("replay-counter")?.textContent === "1 / 4",
  { timeout: 5000 },
);
await page.screenshot({ path: "screenshot-replay.png", fullPage: false });
console.log("wrote screenshot-replay.png");

await browser.close();
