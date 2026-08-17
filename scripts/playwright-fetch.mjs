// Render one URL with Playwright and write the final HTML to stdout.
// Usage: node scripts/playwright-fetch.mjs <url> [headers-json]

import { realpathSync } from "node:fs";
import { delimiter, join } from "node:path";
import { createRequire } from "node:module";

const url = process.argv[2];
if (!url) {
  console.error("usage: node scripts/playwright-fetch.mjs <url> [headers-json]");
  process.exit(2);
}

const headers = process.argv[3] ? JSON.parse(process.argv[3]) : {};
const { chromium } = loadPlaywright();
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ extraHTTPHeaders: headers });
  await page.goto(url, { waitUntil: "networkidle", timeout: 60000 });
  process.stdout.write(await page.content());
} finally {
  await browser.close();
}

function loadPlaywright() {
  const localRequire = createRequire(import.meta.url);
  try {
    return localRequire("playwright");
  } catch (localError) {
    const executable = findOnPath("playwright");
    if (!executable) throw localError;
    const executableRequire = createRequire(realpathSync(executable));
    return executableRequire("playwright");
  }
}

function findOnPath(name) {
  for (const directory of (process.env.PATH ?? "").split(delimiter)) {
    const candidate = join(directory, name);
    try {
      return realpathSync(candidate);
    } catch {
      // Continue searching PATH.
    }
  }
  return null;
}
