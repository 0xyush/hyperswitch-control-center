// Offline test of the password gate and of serving the dashboard build from the proxy.
// A small fake build; the dashboard's real /config/* handlers (repo src/server). No sandbox.
import assert from "node:assert/strict";
import fs from "node:fs";
import type { AddressInfo } from "node:net";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";

const dist = fs.mkdtempSync(path.join(os.tmpdir(), "sim-dist-"));
fs.mkdirSync(path.join(dist, "hyperswitch", "assets", "Dark"), {
  recursive: true,
});
fs.mkdirSync(path.join(dist, "server", "config"), { recursive: true });
fs.writeFileSync(
  path.join(dist, "hyperswitch", "index.html"),
  "<!doctype html><title>dashboard index</title>",
);
fs.writeFileSync(
  path.join(dist, "hyperswitch", "app.js"),
  "console.log('app')",
);
fs.writeFileSync(
  path.join(
    dist,
    "hyperswitch",
    "assets",
    "Dark",
    "hyperswitchLogoIconWithText.svg",
  ),
  "<svg id='logo'></svg>",
);
fs.writeFileSync(
  path.join(dist, "server", "config", "config.toml"),
  '[default.endpoints]\napi_url="http://localhost:8787/api"\n[default.simulator]\nsim_url="http://localhost:8787"\n',
);
fs.writeFileSync(path.join(dist, "server", "config", "theme.json"), "{}");

process.env.SIM_DATA_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "sim-gate-"));
process.env.SIM_CONTRACT_TEST = "0";
process.env.SIM_PASSWORD = "correct-horse-1";
process.env.DASHBOARD_DIST = dist;
process.env.default__endpoints__api_url = "/api";
process.env.default__simulator__sim_url = "";

const { createServer } = await import("../src/server.ts");
const server = createServer();
let base = "";
before(async () => {
  await new Promise<void>((ok) => server.listen(0, "127.0.0.1", ok));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});
after(() => server.close());

const login = (password: string) =>
  fetch(`${base}/gate`, {
    method: "POST",
    redirect: "manual",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      password,
      next: "/dashboard/v2/recovery/home",
    }),
  });

test("without the cookie: the password page, and 401 JSON for the APIs", async () => {
  const page = await fetch(`${base}/dashboard/v2/recovery/home`);
  assert.equal(page.status, 401);
  const html = await page.text();
  assert.match(html, /type="password"/);
  assert.match(html, /<svg id='logo'>/);
  for (const p of ["/api/v2/payments/recovery-list", "/sim/recordings"]) {
    const r = await fetch(base + p);
    assert.equal(r.status, 401, p);
    assert.equal((await r.json()).error.code, "password_required");
  }
});

test("a wrong password is refused; the right one sets the cookie and goes to next", async () => {
  assert.equal((await login("wrong")).status, 401);
  const ok = await login("correct-horse-1");
  assert.equal(ok.status, 303);
  assert.equal(ok.headers.get("location"), "/dashboard/v2/recovery/home");
  const cookie = ok.headers.get("set-cookie") ?? "";
  assert.match(
    cookie,
    /^sim_gate=\d{4}-\d{2}-\d{2}\.[\w-]+; Path=\/; Max-Age=604800; HttpOnly; SameSite=Lax/,
  );
  const jar = { cookie: cookie.split(";")[0] };

  const home = await fetch(`${base}/dashboard/v2/recovery/home`, {
    headers: jar,
  });
  assert.equal(home.status, 200);
  assert.match(await home.text(), /dashboard index/);
  const js = await fetch(`${base}/app.js`, { headers: jar });
  assert.match(js.headers.get("content-type") ?? "", /javascript/);
  const escape = await fetch(`${base}/%2e%2e/%2e%2e/etc/passwd`, {
    headers: jar,
  });
  assert.match(await escape.text(), /dashboard index/);

  const cfg = await (
    await fetch(`${base}/config/feature`, { headers: jar })
  ).json();
  assert.equal(cfg.endpoints.api_url, "/api");
  assert.equal(cfg.simulator.sim_url, "");
  const recs = await fetch(`${base}/sim/recordings`, { headers: jar });
  assert.equal(recs.status, 200);
  const forged = await fetch(`${base}/sim/recordings`, {
    headers: { cookie: "sim_gate=2026-10-26.forged" },
  });
  assert.equal(forged.status, 401);
});

test("more than 10 tries a minute are refused", async () => {
  let last = 0;
  for (let i = 0; i < 11; i++) last = (await login("wrong")).status;
  assert.equal(last, 429);
});
