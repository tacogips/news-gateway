// Sample Playwright fetch script for the `playwright` backend.
// Usage: node scripts/playwright-fetch.mjs <url>
// Prints the fully rendered HTML of the page to stdout.
// Requires: npm install playwright && npx playwright install chromium

import { chromium } from "playwright";

const url = process.argv[2];
if (!url) {
  console.error("usage: node playwright-fetch.mjs <url>");
  process.exit(2);
}

const browser = await chromium.launch();
try {
  const page = await browser.newPage();
  await page.goto(url, { waitUntil: "networkidle", timeout: 60000 });
  process.stdout.write(await page.content());
} finally {
  await browser.close();
}
