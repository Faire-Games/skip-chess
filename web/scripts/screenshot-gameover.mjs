// Inject endData to simulate game-over, then screenshot the sidebar
// to verify the status-game-over block reads cleanly without the
// chess-king glyph.
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
await page.evaluate(() => document.getElementById("btn-theme-light").click());

// Inject endData → status panel swaps to game-over view.
await page.evaluate(() => {
  window.__chess_ui.socket._receive(JSON.stringify({
    t: "endData",
    d: { status: "mate", winner: "black" },
  }));
});
await page.waitForFunction(
  () => !document.getElementById("status-game-over")?.hidden,
  { timeout: 5000 },
);
await new Promise((r) => setTimeout(r, 250));

await page.screenshot({ path: "screenshot-gameover.png", fullPage: false });
console.log("wrote screenshot-gameover.png");
await browser.close();
