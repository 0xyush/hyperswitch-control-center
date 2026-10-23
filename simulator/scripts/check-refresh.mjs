// Refresh check for the Rev Rec pages (PRD §15: a refresh on /dashboard/v2/recovery/* showed raw JSON).
// 1. Server check: each page path, asked for like a browser refresh, must return the app's HTML.
// 2. Browser check (--browser): headless Chrome opens each path, reloads it, and expects the page text.
// Usage: node simulator/scripts/check-refresh.mjs [--base http://localhost:9000] [--browser] [--story st_xxx]
import { createRequire } from "node:module";

const args = process.argv.slice(2);
const arg = (name, fallback) =>
  args.includes(name) ? args[args.indexOf(name) + 1] : fallback;
const base = arg("--base", "http://localhost:9000");
const storyId = arg("--story", null);

// Path, and text the rendered page must show
const pages = [
  ["/dashboard/v2/recovery", "Try the simulator"],
  ["/dashboard/v2/recovery/home", "Try the simulator"],
  ["/dashboard/v2/recovery/invoices", "List of Invoices"],
  ["/dashboard/v2/recovery/simulator/story", "Invoice story"],
  ["/dashboard/v2/recovery/simulator/unknown-page", "Invoice story"],
  ...(storyId
    ? [[`/dashboard/v2/recovery/simulator/story/${storyId}`, "Scenario"]]
    : []),
];

const browserAccept =
  "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8";
let failed = 0;

for (const [path] of pages) {
  const res = await fetch(base + path, { headers: { Accept: browserAccept } });
  const body = await res.text();
  const ok =
    res.status === 200 &&
    (res.headers.get("content-type") ?? "").includes("text/html") &&
    body.includes('id="app"');
  if (!ok) failed++;
  console.log(
    `${ok ? "ok  " : "FAIL"} server  ${path} -> ${res.status} ${res.headers.get("content-type")}${ok ? "" : ` body: ${body.slice(0, 80)}`}`,
  );
}

if (args.includes("--browser")) {
  const require = createRequire(import.meta.url);
  const { chromium } = require("playwright-core");
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  for (const [path, text] of pages) {
    const page = await (await browser.newContext()).newPage();
    await page.goto(base + path, { waitUntil: "domcontentloaded" });
    await page
      .getByText(text)
      .first()
      .waitFor({ timeout: 20000 })
      .catch(() => {});
    await page.reload({ waitUntil: "domcontentloaded" });
    const shown = await page
      .getByText(text)
      .first()
      .waitFor({ timeout: 20000 })
      .then(
        () => true,
        () => false,
      );
    const raw = (await page.locator("body").innerText()).trim().startsWith("{");
    const ok = shown && !raw;
    if (!ok) failed++;
    console.log(
      `${ok ? "ok  " : "FAIL"} browser ${path} -> after reload ${page.url().replace(base, "")} shows "${text}": ${shown}${raw ? " (raw JSON)" : ""}`,
    );
    await page.close();
  }
  await browser.close();
}

process.exit(failed ? 1 : 0);
