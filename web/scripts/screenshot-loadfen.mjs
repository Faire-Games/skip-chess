// Visual check: paste a different FEN into the editable field and
// capture the sidebar so we can see the icon button morph into the
// green "load" button.
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

// Edit the FEN field to a different position.
await page.evaluate(() => {
  const el = document.getElementById("fen-value");
  el.textContent = "r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4";
  el.dispatchEvent(new InputEvent("input", { bubbles: true }));
});
await new Promise((r) => setTimeout(r, 300));

await page.screenshot({ path: "screenshot-loadfen.png", fullPage: false });
console.log("wrote screenshot-loadfen.png");
await browser.close();
