import puppeteer from "puppeteer";

const URL = process.env.PAGE_URL || "http://localhost:4444/";

const browser = await puppeteer.launch({
  headless: true,
  executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  args: ["--no-sandbox"],
  defaultViewport: { width: 1400, height: 900, deviceScaleFactor: 2 },
});

const page = await browser.newPage();
await page.goto(URL, { waitUntil: "domcontentloaded" });
await page.waitForFunction(
  () => document.querySelectorAll("#board .square .piece").length === 32,
  { timeout: 15000 },
);
// Play a couple of moves so the screenshot shows engine activity.
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

await page.screenshot({ path: "screenshot.png", fullPage: false });
console.log("wrote screenshot.png");
await browser.close();
