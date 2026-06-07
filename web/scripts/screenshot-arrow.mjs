// One-off screenshot: play a move, enable Last Move Arrow, and capture
// the board so we can verify the arrow renders beneath the piece in
// the matching color.
import puppeteer from "puppeteer";

const URL = process.env.PAGE_URL || "http://localhost:4444/";

const browser = await puppeteer.launch({
  headless: true,
  executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  args: ["--no-sandbox"],
  defaultViewport: { width: 1400, height: 1000, deviceScaleFactor: 2 },
});

const page = await browser.newPage();
await page.emulateMediaFeatures([{ name: "prefers-color-scheme", value: "light" }]);
await page.goto(URL, { waitUntil: "domcontentloaded" });
await page.waitForFunction(
  () => document.querySelectorAll("#board .square .piece").length === 32,
  { timeout: 15000 },
);
// Force light theme so the screenshot is consistent.
await page.evaluate(() => document.getElementById("btn-theme-light").click());

// Turn on Last Move Arrow, then play a move so it has something to draw.
await page.evaluate(() => {
  const t = document.getElementById("opt-last-move-arrow");
  t.checked = true;
  t.dispatchEvent(new Event("change", { bubbles: true }));
});
await page.evaluate(() => window.__chess_ui.attemptHumanMove("e2e4"));
await page.waitForFunction(
  () => document.querySelectorAll("#move-list li").length >= 1,
  { timeout: 15000 },
);
// Let any animation settle.
await new Promise((r) => setTimeout(r, 500));

// Just capture the board area for a focused look.
const board = await page.$(".board-area");
await board.screenshot({ path: "screenshot-arrow.png" });
console.log("wrote screenshot-arrow.png");
await browser.close();
