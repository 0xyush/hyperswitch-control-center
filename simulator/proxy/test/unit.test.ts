// Offline tests: allow-list, redaction, shell stubs, CORS and error shapes. No sandbox or Stripe calls.
import assert from "node:assert/strict";
import fs from "node:fs";
import type { AddressInfo } from "node:net";
import os from "node:os";
import path from "node:path";
import { after, before, describe, test } from "node:test";

process.env.SIM_DATA_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "sim-unit-"));

const { matchRule } = await import("../src/passthrough.ts");
const { redact } = await import("../src/redact.ts");
const { shellStub } = await import("../src/shell.ts");
const { SCENARIOS } = await import("../src/scenarios.ts");
const { createServer } = await import("../src/server.ts");

describe("allow-list", () => {
  const allowed = [
    "v2/payments/recovery-list",
    "v2/payments/profile/recovery-list",
    "v2/payments/recovery-aggregate",
    "v2/payments/0a_pay_01a16a7a1e197f61bb926077b08aa64b/get-revenue-recovery-intent",
    "v2/payments/0a_pay_01a16a7a1e197f61bb926077b08aa64b/list_attempts",
    "v2/payments/0a_pay_01a16a7a1e197f61bb926077b08aa64b/list-attempts",
    "v2/process_tracker/revenue_recovery_workflow/0a_pay_01a16a7a1e197f61bb926077b08aa64b",
    "v2/process-trackers/revenue-recovery-workflow/0a_pay_01a16a7a1e197f61bb926077b08aa64b",
    "v2/connector-accounts/mca_8sEBJcnLL79XDoOsQiWg",
    "v2/profiles/pro_2qWOGZLPJQRRY0O75DXg/connector-accounts",
  ];
  for (const p of allowed)
    test(`GET ${p} is allowed`, () => assert.ok(matchRule("GET", p)));

  const blocked: [string, string][] = [
    ["POST", "v2/payments/recovery-list"],
    ["PUT", "v2/connector-accounts/mca_8sEBJcnLL79XDoOsQiWg"],
    ["POST", "v2/recovery"],
    ["GET", "user"],
    ["GET", "v2/api-keys/list"],
    ["GET", "v2/payments/%2e%2e/recovery-list"],
    ["GET", "v2/payments/a/../recovery-list"],
    ["GET", "v2/payments//recovery-list"],
    ["GET", "v2/connector-accounts/"],
  ];
  for (const [m, p] of blocked)
    test(`${m} ${p} is blocked`, () => assert.equal(matchRule(m, p), null));
});

describe("redaction", () => {
  test("hides secret fields and key-like values, keeps ids", () => {
    const out = redact({
      payment_response_hash_key: "abc123",
      client_secret: "pay_x_secret_y",
      webhook_details: {
        webhook_password: "pw",
        webhook_url: "https://example.test/hook",
      },
      connector_account_details: {
        auth_type: "HeaderKey",
        api_key: "sk_test_123",
      },
      nested: [{ note: "sk_test_abcdef" }],
      payment_processor_token: "pm_1UQWh",
      id: "0a_pay_1",
    }) as any;
    assert.equal(out.payment_response_hash_key, "<hidden by proxy>");
    assert.equal(out.client_secret, "<hidden by proxy>");
    assert.equal(out.webhook_details.webhook_password, "<hidden by proxy>");
    assert.equal(out.webhook_details.webhook_url, "https://example.test/hook");
    assert.deepEqual(out.connector_account_details, {
      auth_type: "HeaderKey",
      api_key: "<hidden by proxy>",
    });
    assert.equal(out.nested[0].note, "<hidden by proxy>");
    assert.equal(out.payment_processor_token, "pm_1UQWh");
    assert.equal(out.id, "0a_pay_1");
  });
});

describe("shell stubs", () => {
  test("answers the shell reads B listed", () => {
    for (const p of [
      "v2/users/merchant-details",
      "user/list/merchant",
      "v2/user/list/merchant",
      "user/role/v2",
      "user/list/org",
      "v2/user/list/profile",
      "user/data",
    ])
      assert.notEqual(shellStub("GET", p), null, p);
  });
  test("user data is an array (the dashboard reads item 0)", () =>
    assert.deepEqual(shellStub("GET", "user/data"), []));
  test("no stub for writes or other merchants", () => {
    assert.equal(shellStub("POST", "user/list/merchant"), null);
    assert.equal(
      shellStub("GET", "v2/merchant-accounts/merchant_someone_else"),
      null,
    );
  });
});

describe("scenario table", () => {
  test("has the 8 PRD scenarios, 1 to 3 runnable", () => {
    assert.deepEqual(
      SCENARIOS.map((s) => s.id),
      [1, 2, 3, 4, 5, 6, 7, 8],
    );
    assert.deepEqual(
      SCENARIOS.filter((s) => s.runnable).map((s) => s.id),
      [1, 2, 3],
    );
  });
});

describe("server (in process, no upstream calls)", () => {
  let base = "";
  const server = createServer();
  before(async () => {
    await new Promise<void>((ok) => server.listen(0, "127.0.0.1", ok));
    base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });
  after(() => server.close());

  test("blocked /api path gets a sandbox-shaped 403", async () => {
    const r = await fetch(`${base}/api/user`);
    assert.equal(r.status, 403);
    const j = await r.json();
    assert.equal(j.error.code, "SIM_BLOCKED");
  });

  test("CORS preflight answers the dashboard origin only", async () => {
    const ok = await fetch(`${base}/api/v2/payments/recovery-list`, {
      method: "OPTIONS",
      headers: {
        Origin: "http://localhost:9000",
        "Access-Control-Request-Headers": "authorization, x-profile-id",
      },
    });
    assert.equal(ok.status, 204);
    assert.equal(
      ok.headers.get("access-control-allow-origin"),
      "http://localhost:9000",
    );
    assert.match(
      ok.headers.get("access-control-allow-headers") ?? "",
      /x-profile-id/,
    );
    const other = await fetch(`${base}/healthz`, {
      method: "OPTIONS",
      headers: { Origin: "https://evil.example" },
    });
    assert.equal(other.headers.get("access-control-allow-origin"), null);
  });

  test("unknown and not-yet-runnable scenarios", async () => {
    const post = (scenario: unknown) =>
      fetch(`${base}/sim/story/start`, {
        method: "POST",
        body: JSON.stringify({ scenario }),
      });
    const r9 = await post(9);
    assert.equal(r9.status, 400);
    assert.equal((await r9.json()).error.code, "bad_scenario");
    const r5 = await post(5);
    assert.equal(r5.status, 409);
    assert.equal((await r5.json()).error.code, "not_available");
  });

  test("scenarios endpoint and unknown story", async () => {
    const s = await (await fetch(`${base}/sim/scenarios`)).json();
    assert.equal(s.scenarios.length, 8);
    assert.equal("pm" in s.scenarios[0], false);
    const r = await fetch(`${base}/sim/story/st_000000000000`);
    assert.equal(r.status, 404);
    assert.equal((await r.json()).error.code, "not_found");
  });
});
