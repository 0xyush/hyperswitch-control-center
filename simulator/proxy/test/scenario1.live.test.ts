// Live test: scenario 1 (customer pays in the app) against the real Hyperswitch sandbox and Stripe test mode.
// Skips when simulator/proxy/.env is missing a required key. Takes about 1 to 2 minutes.
// It makes real test-mode charges: one Stripe customer, (start rule + 1) declines, one 4242 payment.
import assert from "node:assert/strict";
import fs from "node:fs";
import type { AddressInfo } from "node:net";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";

process.env.SIM_DATA_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "sim-live-"));
process.env.RATE_LIMIT_STARTS_PER_HOUR ??= "100";

const { config, missingKeys, SECRET_VALUES } = await import("../src/config.ts");
const { refreshDashboardToken, hasDashboardToken } =
  await import("../src/auth.ts");
const { createServer } = await import("../src/server.ts");

const missing = missingKeys();
const skip = missing.length
  ? `missing in .env: ${missing.join(", ")}`
  : process.env.SIM_LIVE === "0"
    ? "SIM_LIVE=0"
    : false;

const sleep = (ms: number) => new Promise((ok) => setTimeout(ok, ms));
let base = "";
const server = createServer();

before(async () => {
  if (skip) return;
  await refreshDashboardToken();
  await new Promise<void>((ok) => server.listen(0, "127.0.0.1", ok));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});
after(() => server.close());

async function call(method: string, p: string, body?: unknown) {
  const r = await fetch(base + p, {
    method,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: r.status, json: await r.json() };
}

test(
  "scenario 1 on the sandbox: start, Rev Rec takes over, paid in app, recovered",
  { skip, timeout: 240_000 },
  async (t) => {
    const health = await call("GET", "/healthz");
    assert.equal(
      health.json.ok,
      true,
      `healthz not ok: ${JSON.stringify(health.json)}`,
    );

    const start = await call("POST", "/sim/story/start", { preset: 1 });
    assert.equal(start.status, 200, JSON.stringify(start.json));
    const id: string = start.json.storyId;
    assert.match(id, /^st_[a-f0-9]{12}$/);
    // Start returns at once; the billing system's steps run in the background.
    assert.equal(start.json.status, "starting");
    let first = start.json;
    for (let i = 0; i < 30 && first.status === "starting"; i++) {
      await sleep(2000);
      first = (await call("GET", `/sim/story/${id}`)).json;
    }
    assert.ok(
      first.recoveryId,
      `no recovery id from the sandbox: ${first.startError}`,
    );
    assert.ok(
      ["monitoring", "queued", "scheduled", "processing"].includes(
        first.status,
      ),
      first.status,
    );
    // Every diagram step links to a raw call, except notes with no call.
    for (const e of first.timeline)
      if (e.status !== "info")
        assert.ok(
          first.requests.some((r: { stepId: string }) => r.stepId === e.stepId),
          `no request for step ${e.stepId} (${e.label})`,
        );
    t.diagnostic(
      `story ${id}, invoice ${first.invoiceId}, payment ${first.recoveryId}`,
    );

    // With the dashboard token the simulator meets the start rule, so Rev Rec should take over.
    let view = first;
    if (hasDashboardToken()) {
      for (
        let i = 0;
        i < 20 && !["queued", "scheduled", "processing"].includes(view.status);
        i++
      ) {
        await sleep(5000);
        view = (await call("GET", `/sim/story/${id}`)).json;
      }
      assert.ok(
        ["queued", "scheduled", "processing"].includes(view.status),
        `Rev Rec did not take over: ${view.status}`,
      );
      t.diagnostic(
        `Rev Rec took over: ${view.status}, next retry ${view.nextRetryAt}`,
      );
    } else {
      t.diagnostic("no dashboard token: not checking the takeover");
    }

    const paid = await call("POST", `/sim/story/${id}/paid-in-app`);
    assert.equal(paid.status, 200, JSON.stringify(paid.json));
    view = paid.json;
    for (let i = 0; i < 12 && view.status !== "recovered"; i++) {
      await sleep(5000);
      view = (await call("GET", `/sim/story/${id}`)).json;
    }
    assert.equal(view.status, "recovered");
    assert.equal(view.recoveredBy, "billing");
    assert.equal(view.stageCaption, "Paid outside Rev Rec");
    assert.equal(view.done, true);
    assert.equal(view.actions.paidInApp, false);

    // Paying twice is refused, so a double click cannot make a second real charge.
    const again = await call("POST", `/sim/story/${id}/paid-in-app`);
    assert.equal(again.status, 409);

    // No secret we hold may appear anywhere in what the dashboard receives.
    const all = JSON.stringify(view);
    for (const secret of SECRET_VALUES)
      assert.equal(
        all.includes(secret),
        false,
        "a secret leaked into the story view",
      );
    assert.ok(
      view.explain.every((e: { source: string }) =>
        ["sandbox", "recomputed", "rule"].includes(e.source),
      ),
    );
    t.diagnostic(
      `recovered, ${view.attemptSummary.length} attempts, sandbox ${config.hsBaseUrl}`,
    );
  },
);
