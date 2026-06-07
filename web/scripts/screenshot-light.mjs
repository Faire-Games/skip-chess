// One-off screenshot in light mode to confirm the new layout / theme.
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
// Force the light theme just in case.
await page.evaluate(() => {
  document.getElementById("btn-theme-light").click();
});
await new Promise((r) => setTimeout(r, 250));
await page.screenshot({ path: "screenshot-light.png", fullPage: false });
console.log("wrote screenshot-light.png");
await browser.close();
