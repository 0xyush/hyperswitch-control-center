// Offline tests: allow-list, redaction, shell stubs, CORS and error shapes. No sandbox or Stripe calls.
import assert from "node:assert/strict";
import fs from "node:fs";
import type { AddressInfo } from "node:net";
import os from "node:os";
import path from "node:path";
import { after, before, describe, test } from "node:test";

process.env.SIM_DATA_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "sim-unit-"));

// Three stored stories for the portfolio setup stages: card saved only, first charge failed, reported.
const ev = (from: string, to: string, txnId?: string) => ({
  stepId: "s1",
  at: "2026-10-26T21:00:00Z",
  from,
  to,
  label: "x",
  text: "x",
  status: "info",
  source: "simulator",
  why: [],
  ...(txnId ? { txnId } : {}),
});
fs.writeFileSync(
  path.join(process.env.SIM_DATA_DIR, "stories-v2.json"),
  JSON.stringify([
    {
      storyId: "st_pending0000",
      recoveryId: null,
      started: false,
      error: null,
      events: [ev("billing", "billing"), ev("billing", "processor")],
    },
    {
      storyId: "st_charged0000",
      recoveryId: null,
      started: false,
      error: null,
      events: [ev("billing", "processor", "pi_1")],
    },
    {
      storyId: "st_reported000",
      recoveryId: "0a_pay_1",
      started: true,
      error: null,
      events: [ev("billing", "processor", "pi_2"), ev("billing", "revrec")],
    },
  ]),
);

const { matchRule } = await import("../src/passthrough.ts");
const { redact } = await import("../src/redact.ts");
const { shellStub } = await import("../src/shell.ts");
const { PRESETS, presetText, resolveCards } =
  await import("../src/scenarios.ts");
const { parseStart, reportedError, revrecChargeWhy } =
  await import("../src/story.ts");
const { bankRule, drawFlip, parsePortfolio, setupStage } =
  await import("../src/portfolio.ts");
const { config, parseStopAfter, portfolioConfig } =
  await import("../src/config.ts");
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

describe("presets and start body", () => {
  test("has the 8 PRD presets, 1, 2, 3 and 6 verified", () => {
    assert.deepEqual(
      PRESETS.map((p) => p.id),
      [1, 2, 3, 4, 5, 6, 7, 8],
    );
    assert.deepEqual(
      PRESETS.filter((p) => p.verified).map((p) => p.id),
      [1, 2, 3, 6],
    );
  });

  test("the single card field maps to a saved card and a first-charge card", () => {
    assert.deepEqual(resolveCards({ card: "0341" }), {
      savedCard: "0341",
      firstCharge: "0341",
    });
    assert.deepEqual(resolveCards({ card: "4242" }), {
      savedCard: "4242",
      firstCharge: "0002",
    });
    assert.deepEqual(resolveCards({ card: "9995" }), {
      savedCard: "0341",
      firstCharge: "9995",
    });
    assert.deepEqual(resolveCards({ card: "9979", savedCard: "4242" }), {
      savedCard: "4242",
      firstCharge: "9979",
    });
  });

  test("a preset fills defaults and explicit fields win", () => {
    const p2 = parseStart({ preset: 2 });
    assert.equal(p2.savedCard, "4242");
    assert.equal(p2.firstCharge, "0002");
    assert.equal(p2.amount, 6540);
    const own = parseStart({
      preset: 2,
      card: "9995",
      amount: 1999,
      currency: "eur",
    });
    assert.deepEqual(
      [own.savedCard, own.firstCharge, own.amount, own.currency],
      ["0341", "9995", 1999, "EUR"],
    );
    assert.equal(parseStart({ preset: 3 }).sendDuplicateOnStart, true);
    assert.equal(parseStart({ card: 341 }).savedCard, "0341");
  });

  test("bad start bodies are refused", () => {
    for (const body of [
      { preset: 9 },
      { amount: 65.4 },
      { amount: 10 },
      { currency: "JPY" },
      { card: "1234" },
      { savedCard: "9979" },
      { customer: "old" },
    ])
      assert.throws(
        () => parseStart(body),
        { status: 400 },
        JSON.stringify(body),
      );
  });
});

describe("reported failure", () => {
  test("the message carries Stripe's decline code, as the GSM hard-decline rows expect", () => {
    const stolen = reportedError(
      {
        code: "card_declined",
        message: "Your card was declined.",
        decline_code: "stolen_card",
      },
      "stolen_card",
      "43",
    );
    assert.equal(stolen.code, "card_declined");
    assert.equal(
      stolen.message,
      "message - Your card was declined., decline_code - stolen_card",
    );
    assert.equal(stolen.network_decline_code, "43");
    const expired = reportedError(
      {
        code: "expired_card",
        message: "Your card has expired.",
        decline_code: "expired_card",
      },
      "expired_card",
      "54",
    );
    assert.equal(
      expired.message,
      "message - Your card has expired., decline_code - expired_card",
    );
    // A generic decline is not one of the hard-decline messages.
    const generic = reportedError(
      {
        code: "card_declined",
        message: "Your card was declined.",
        decline_code: "generic_decline",
      },
      "generic_decline",
      "01",
    );
    assert.notEqual(generic.message, stolen.message);
    // No decline code from Stripe: the plain message.
    assert.equal(
      reportedError(
        { code: "processing_error", message: "An error occurred." },
        "processing_error",
        "96",
      ).message,
      "An error occurred.",
    );
  });
});

describe("plain why lines", () => {
  test("Rev Rec's own charge is said in words, with no attempt id", () => {
    assert.equal(
      revrecChargeWhy("charged"),
      "Rev Rec charged the saved card. Stripe approved.",
    );
    assert.equal(
      revrecChargeWhy("failure"),
      "Rev Rec charged the saved card. Stripe declined.",
    );
    assert.match(revrecChargeWhy("pending"), /not given its final answer/);
  });
});

describe("fast engine pace (SIM_FAST_ENGINE)", () => {
  test("bank rules: the sandbox words are unchanged; fast runs say seconds", () => {
    assert.equal(
      bankRule("insufficient_funds", false),
      "No money until the payday, 4 to 12 minutes after the first failure.",
    );
    assert.equal(
      bankRule("processing_error", false),
      "A temporary error: works again after 1 minute.",
    );
    assert.equal(
      bankRule("insufficient_funds", true),
      "No money until the payday, 15 to 45 s after the first failure.",
    );
    assert.equal(
      bankRule("generic_decline", true),
      "Works again after a quiet window of 10 to 30 s.",
    );
    assert.equal(
      bankRule("processing_error", true),
      "A temporary error: works again after 5 s.",
    );
    assert.equal(
      bankRule("stolen_card", true),
      "Never works again (hard decline).",
    );
  });
  test("bank flips: half minutes at sandbox pace, whole seconds at fast pace", () => {
    const half = () => 0.5;
    assert.equal(drawFlip("insufficient_funds", false, half), 8);
    assert.equal(drawFlip("insufficient_funds", true, half), 0.5); // 30 s
    assert.equal(drawFlip("processing_error", true, half), 0.083); // 5 s
    assert.equal(drawFlip("stolen_card", true, half), null);
    for (let k = 0; k < 50; k++) {
      const m = drawFlip("generic_decline", true, Math.random)!;
      assert.ok(m * 60 >= 9.9 && m * 60 <= 30.1, String(m));
    }
  });
  test("no preset text says sandbox on the self-hosted engine, at either pace", () => {
    const saved = { engine: config.engine, fast: config.fastEngine };
    try {
      config.engine = "selfhost";
      for (const fast of [false, true]) {
        config.fastEngine = fast;
        for (const p of PRESETS) {
          const x = presetText(p);
          for (const f of ["title", "summary", "expected", "liveTime", "hint"])
            assert.doesNotMatch(
              String((x as any)[f]),
              /sandbox/i,
              `preset ${p.id} ${f} (fast ${fast})`,
            );
        }
      }
      // The sandbox keeps its own words.
      config.engine = "sandbox";
      config.fastEngine = false;
      assert.match(
        presetText(PRESETS.find((p: any) => p.id === 7)!).hint,
        /sandbox/,
      );
    } finally {
      config.engine = saved.engine;
      config.fastEngine = saved.fast;
    }
  });
  test("preset texts follow the engine", () => {
    const p7 = PRESETS.find((p: any) => p.id === 7)!;
    assert.equal(config.fastEngine, false);
    assert.equal(presetText(p7).liveTime, "~1 min");
    config.fastEngine = true;
    try {
      assert.equal(presetText(p7).liveTime, "a few seconds");
      assert.match(presetText(p7).expected, /no retry/);
      // A preset without fast texts keeps its own.
      const p8 = PRESETS.find((p: any) => p.id === 8)!;
      assert.equal(presetText(p8).liveTime, p8.liveTime);
    } finally {
      config.fastEngine = false;
    }
  });
});

describe("portfolio dials", () => {
  test("defaults: 10 invoices, 45 min cap, a seed", () => {
    const d = parsePortfolio({});
    assert.equal(d.invoices, 10);
    assert.equal(d.maxMinutes, 45);
    assert.ok(Number.isInteger(d.seed));
  });
  test("bad dials are refused", () => {
    for (const body of [
      { invoices: 11 },
      { invoices: 0 },
      { maxMinutes: 60 },
      { mix: { lost_card: 1 } },
      { mix: { stolen_card: 0 } },
      { amount: 1.5 },
    ])
      assert.throws(
        () => parsePortfolio(body),
        { status: 400 },
        JSON.stringify(body),
      );
  });
  test("setup stage per copy: pending, charged, reported", () => {
    const copy = (storyId: string, recoveryId: string | null = null) => ({
      storyId,
      recoveryId,
      status: null,
      revrecAttempts: 0,
      recoveredAt: null,
      error: null,
    });
    assert.equal(setupStage(undefined), "pending");
    assert.equal(setupStage(copy("st_pending0000")), "pending");
    assert.equal(setupStage(copy("st_charged0000")), "charged");
    assert.equal(setupStage(copy("st_reported000")), "reported");
    assert.equal(setupStage(copy("st_gone0000000", "0a_pay_9")), "reported");
    assert.equal(setupStage(copy("st_gone0000000")), "pending");
  });
  test("stop-after: maxMinutes must be one of the choices (default 10/20/45; env 0.5,1,2)", () => {
    assert.deepEqual(portfolioConfig.stopAfterMinutes, [10, 20, 45]);
    assert.deepEqual(parseStopAfter(""), [10, 20, 45]);
    assert.deepEqual(parseStopAfter("2, 0.5,1,1,x,0.25,60"), [0.5, 1, 2]);
    assert.deepEqual(parseStopAfter("0.3,abc"), [10, 20, 45]);
    // Default list: one of 10, 20, 45 only.
    assert.equal(parsePortfolio({ maxMinutes: 20 }).maxMinutes, 20);
    for (const maxMinutes of [0.5, 5, 7.5, 30])
      assert.throws(
        () => parsePortfolio({ maxMinutes }),
        { status: 400 },
        String(maxMinutes),
      );
    const saved = portfolioConfig.stopAfterMinutes;
    portfolioConfig.stopAfterMinutes = [0.5, 1, 2];
    try {
      assert.equal(parsePortfolio({}).maxMinutes, 2);
      assert.equal(parsePortfolio({ maxMinutes: 0.5 }).maxMinutes, 0.5);
      assert.equal(parsePortfolio({ maxMinutes: "1" }).maxMinutes, 1);
      for (const maxMinutes of [0, 0.25, 1.5, 10, 46, null])
        assert.throws(
          () => parsePortfolio({ maxMinutes }),
          { status: 400 },
          String(maxMinutes),
        );
    } finally {
      portfolioConfig.stopAfterMinutes = saved;
    }
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

  test("bad start bodies get 400 before any Stripe call", async () => {
    const post = (body: unknown) =>
      fetch(`${base}/sim/story/start`, {
        method: "POST",
        body: JSON.stringify(body),
      });
    const r9 = await post({ preset: 9 });
    assert.equal(r9.status, 400);
    assert.equal((await r9.json()).error.code, "bad_scenario");
    const same = await post({ customer: "same" });
    assert.equal(same.status, 409);
    assert.equal((await same.json()).error.code, "not_available");
    const rc = await post({ card: "1111" });
    assert.equal(rc.status, 400);
    assert.equal((await rc.json()).error.code, "bad_request");
  });

  test("x-sim-session: allowed by CORS, and a new session has no customer to reuse", async () => {
    const pre = await fetch(`${base}/sim/story/start`, {
      method: "OPTIONS",
      headers: {
        Origin: "http://localhost:9000",
        "Access-Control-Request-Headers": "content-type, x-sim-session",
      },
    });
    assert.match(
      pre.headers.get("access-control-allow-headers") ?? "",
      /x-sim-session/,
    );
    const r = await fetch(`${base}/sim/story/start`, {
      method: "POST",
      headers: { "x-sim-session": "browser_abcdef123456" },
      body: JSON.stringify({ customer: "same" }),
    });
    assert.equal(r.status, 409);
  });

  test("the portfolio run is off by default", async () => {
    const r = await fetch(`${base}/sim/portfolio/start`, {
      method: "POST",
      body: "{}",
    });
    assert.equal(r.status, 404);
  });

  test("presets endpoint and unknown story", async () => {
    const s = await (await fetch(`${base}/sim/presets`)).json();
    assert.equal(s.presets.length, 8);
    assert.equal(s.cards.length, 5);
    assert.equal(JSON.stringify(s).includes("pm_card_"), false);
    const r = await fetch(`${base}/sim/story/st_000000000000`);
    assert.equal(r.status, 404);
    assert.equal((await r.json()).error.code, "not_found");
  });
});
