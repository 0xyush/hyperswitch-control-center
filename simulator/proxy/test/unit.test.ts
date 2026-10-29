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
function handoverStory(storyId: string, over: object) {
  return {
    storyId,
    owner: "o",
    presetId: 4,
    amount: 6540,
    currency: "USD",
    card: "0341",
    savedCard: "0341",
    firstCharge: "0341",
    customer: "new",
    sendDuplicateOnStart: false,
    reportAgainMode: "new",
    profile: "story",
    invoiceId: `SIM-4-${storyId}`,
    recoveryId: null,
    startedAt: "2026-10-27T18:00:00.000Z",
    stripeCustomerId: "cus_test",
    savedPm: "pm_test",
    started: false,
    waitForHandover: true,
    firstFailure: {
      txnId: "pi_test",
      error: { code: "card_declined", message: "Your card was declined." },
    },
    handoverAt: null,
    lastFailureBody: null,
    reportsSent: 0,
    startRule: 0,
    paidInAppAt: null,
    error: null,
    stepSeq: 3,
    events: [
      {
        ...ev("billing", "processor", "pi_test"),
        stepId: "s3",
        at: "2026-10-27T18:00:02.000Z",
        label: "charge $65.40 on ••0341 → declined (generic_decline)",
        status: "declined",
      },
    ],
    requests: [],
    seenSchedules: [],
    stageSeen: {},
    finalNoted: false,
    ...over,
  };
}
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
    // A story-screen story after its first failed charge, waiting for the visitor's handover.
    handoverStory("st_aaaa0000bbbb", { awaitingHandover: true }),
    // The same story after the handover: Rev Rec has its invoice.
    handoverStory("st_0123456789ab", {
      awaitingHandover: false,
      started: true,
      recoveryId: "0a_pay_2",
      firstFailure: null,
    }),
    // A story on a leased pool profile: live settings on.
    handoverStory("st_cccc0000dddd", {
      profile: "pool",
      settingsOff: null,
      awaitingHandover: false,
      started: true,
      recoveryId: "0a_pay_3",
      firstFailure: null,
    }),
  ]),
);

const { matchRule } = await import("../src/passthrough.ts");
const { redact } = await import("../src/redact.ts");
const { shellStub } = await import("../src/shell.ts");
const { PRESETS, presetText, resolveCards } =
  await import("../src/scenarios.ts");
const {
  budgetOf,
  closedWhy,
  parseStart,
  reportedError,
  revrecChargeWhy,
  webhookRow,
} = await import("../src/story.ts");
const {
  declineMeaning,
  ladderOffsets,
  REAL_LADDER,
  realLife,
  rowRealLife,
  SMART_NOTE,
} = await import("../src/reallife.ts");
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
  test("has the 8 PRD presets, workshop presets 9 and 10, real-world stories 11-20; 1, 2, 3 and 6 verified", () => {
    assert.deepEqual(
      PRESETS.map((p) => p.id),
      [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20],
    );
    // The visitor's one card (default 4242) is saved; the story's own card makes the first failure
    const p12 = parseStart({ preset: 12 });
    assert.deepEqual(
      [p12.savedCard, p12.firstCharge, p12.visitorCard],
      ["4242", "6975", "4242"],
    );
    const p4 = parseStart({ preset: 4, card: "5555 5555 5555 4444" });
    assert.deepEqual(
      [p4.savedCard, p4.firstCharge, p4.declines],
      ["4444", "0002", "generic_decline"],
    );
    // Preset 9 (the second saved card) is off unless SIM_OTHER_CARDS=1 (the user's policy, 28 Oct)
    assert.throws(
      () => parseStart({ preset: 9, card: "4444" }),
      /This story is off in this demo\./,
    );
    // Preset 6 recovers on the same card: no card swap
    assert.equal(parseStart({ preset: 6 }).reportAgainMode, "new");
    // Max tries from the story form: 1-15, only when sent
    assert.equal(parseStart({ preset: 15, maxRetries: 4 }).maxRetries, 4);
    assert.equal("maxRetries" in parseStart({ preset: 15 }), false);
    for (const bad of [0, 16, 2.5, "4"])
      assert.throws(
        () => parseStart({ preset: 15, maxRetries: bad }),
        /maxRetries must be a whole number from 1 to 15/,
      );
    // The older fields keep their meaning
    const old12 = parseStart({ preset: 12, savedCard: "0341" });
    assert.deepEqual(
      [old12.savedCard, old12.firstCharge, old12.visitorCard],
      ["0341", "6975", undefined],
    );
    assert.equal(p12.bank?.reason, "card_velocity_exceeded");
    const p10 = parseStart({ preset: 10 });
    assert.equal(p10.goLivePreset, true);
    assert.deepEqual([p10.savedCard, p10.firstCharge], ["4242", "0002"]);
    assert.equal(parseStart({ preset: 2 }).goLivePreset, undefined);
    const p9 = PRESETS.find((p: any) => p.id === 9)!;
    assert.equal(p9.backupCard, "4242");
    assert.equal(parseStart({ preset: 7 }).backupCard, undefined);
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
      { preset: 99 },
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

describe("webhook rows", () => {
  test("one row per webhook, Rev Rec to the billing system, with the signature check", () => {
    const row = webhookRow(
      {
        eventId: "evt_1",
        eventType: "payment_failed",
        receivedAt: "2026-10-27T19:00:01Z",
        signature: "verified",
        payment: { id: "0a_pay_1", status: "failed" },
      },
      0,
    );
    assert.equal(row.stepId, "wh_evt_1");
    assert.deepEqual(
      [row.from, row.to, row.label],
      ["revrec", "billing", "webhook payment_failed"],
    );
    assert.equal(
      row.text,
      "Webhook to the billing system: Rev Rec stopped trying.",
    );
    assert.match(row.why[1].text, /matches the profile's key/);
    assert.doesNotMatch(JSON.stringify(row), /0a_att_|pi_/);
  });
});

describe("retry budget", () => {
  const internal = [
    { at: "2026-10-27T18:00:05Z" },
    { at: "2026-10-27T18:00:10Z" },
    { at: "2026-10-27T18:00:15Z" },
  ];
  const external = [
    { at: "2026-10-27T18:00:00Z", status: "failure" }, // the first failure
    { at: "2026-10-27T18:00:12Z", status: "failure" }, // reported during recovery
  ];
  test("self-hosted engine: only Rev Rec's own retries use the budget", () => {
    const saved = config.engine;
    try {
      config.engine = "selfhost";
      const b = budgetOf(15, internal, external, { total_retry_count: 5 });
      assert.equal(b.retriesUsed, 3);
      assert.equal(b.retriesLeft, 12);
      assert.equal(b.invoiceTotal, 5);
      assert.equal(b.billingFailuresDuringRecovery, 1);
      assert.equal(b.billingFailuresUseBudget, false);
      assert.equal(
        b.text,
        "12 of 15 tries left. Billing failures do not use up Rev Rec's tries.",
      );
      config.engine = "sandbox";
      const s = budgetOf(15, internal, external, {});
      assert.equal(s.billingFailuresUseBudget, null);
      assert.equal(s.text, "12 of 15 tries left.");
      assert.equal(
        budgetOf(null, internal, [], {}).text,
        "Rev Rec retries so far: 3.",
      );
    } finally {
      config.engine = saved;
    }
  });
});

describe("a report on a finished invoice", () => {
  test("the why lines say what Rev Rec did with it", () => {
    const refused = closedWhy("Recovered", {
      status: 404,
      json: {
        error: {
          message:
            'Failed to load recovery attempt for merchant reference id : PaymentReferenceId("x")',
        },
      },
    } as any);
    assert.equal(
      refused[0].text,
      "The invoice is recovered, so Rev Rec refuses a new failure report.",
    );
    assert.match(refused[1].text, /404 "Failed to load recovery attempt"/);
    const kept = closedWhy("Terminated", { status: 200, json: {} } as any);
    assert.deepEqual(kept, [
      {
        source: "rule",
        text: "The invoice was already stopped. Rev Rec still recorded this failure.",
      },
    ]);
    assert.deepEqual(closedWhy(null, { status: 404, json: {} } as any), []);
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
      assert.match(presetText(p7).expected, /stops at once/);
      // A preset without fast texts keeps its own.
      const p8 = PRESETS.find((p: any) => p.id === 8)!;
      assert.equal(presetText(p8).liveTime, p8.liveTime);
    } finally {
      config.fastEngine = false;
    }
  });
});

describe("real-life timetable (Hyperswitch default static ladder)", () => {
  test("offsets: retry 1 at +60 s, retry 3 at +6 h 1 min, retry 15 at +141 h 1 min", () => {
    const o = ladderOffsets(REAL_LADDER.startAfterSec, REAL_LADDER.frequencies);
    assert.equal(o.length, 15);
    assert.equal(o[0], 60);
    assert.equal(o[1], 3 * 3600 + 60);
    assert.equal(o[2], 6 * 3600 + 60);
    assert.equal(o[5], 24 * 3600 + 60);
    assert.equal(o[14], 141 * 3600 + 60);
    assert.equal(ladderOffsets(60, REAL_LADDER.frequencies, 5).length, 5);
  });
  test("slots: time, label (UTC) and day text from the first failure", () => {
    const r = realLife("2026-10-27T15:00:00.000Z", 15);
    assert.equal(r.maxRetries, 15);
    assert.equal(r.spanText, "about 6 days");
    assert.equal(r.timeZone, "UTC");
    assert.deepEqual(r.slots[0], {
      retry: 1,
      offsetSec: 60,
      at: "2026-10-27T15:01:00.000Z",
      label: "Tue 3:01 PM",
      dayText: "day 1, 1 min after the failure",
    });
    assert.equal(r.slots[2].at, "2026-10-27T21:01:00.000Z");
    assert.equal(r.slots[2].dayText, "day 1, 6 h after the failure");
    assert.equal(r.slots[5].dayText, "day 2, 24 h after the failure");
    assert.equal(r.slots[14].at, "2026-11-02T12:01:00.000Z");
    assert.equal(r.slots[14].label, "Mon 12:01 PM");
    assert.equal(r.slots[14].dayText, "day 6, 5 days 21 h after the failure");
    // A profile with fewer max retries cuts the timetable.
    const short = realLife("2026-10-27T15:00:00.000Z", 5);
    assert.equal(short.slots.length, 5);
    assert.equal(short.spanText, "about 18 h");
    assert.deepEqual(rowRealLife(r.slots, 3), {
      retry: 3,
      at: "2026-10-27T21:01:00.000Z",
      label: "Tue 9:01 PM",
      dayText: "day 1, 6 h after the failure",
    });
    assert.equal(rowRealLife(r.slots, 16), null);
  });
  test("decline meanings: two short sentences at most, a fallback for other codes", () => {
    for (const code of [
      "generic_decline",
      "insufficient_funds",
      "processing_error",
      "stolen_card",
      "expired_card",
      "something_new",
      null,
    ]) {
      const m = declineMeaning(code);
      assert.equal(m.source, "rule");
      assert.ok(m.text.split(". ").length <= 2, `${code}: ${m.text}`);
    }
    assert.equal(
      declineMeaning("stolen_card").text,
      "This card can never work again. Rev Rec stops.",
    );
    assert.match(declineMeaning("insufficient_funds").text, /payday/);
    assert.equal(SMART_NOTE.source, "rule");
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

  test("a story waits for the handover: Rev Rec is not told until the visitor taps", async () => {
    const v = await (await fetch(`${base}/sim/story/st_aaaa0000bbbb`)).json();
    assert.equal(v.status, "awaiting_handover");
    assert.equal(v.recoveryId, null);
    assert.deepEqual(v.handover, { awaiting: true, at: null });
    assert.equal(v.actions.handover, true);
    assert.equal(v.actions.reportAgain, false);
    assert.equal(v.done, false);
    assert.equal(v.explain[0].id, "handover");
    assert.match(
      v.explain[0].text,
      /^The billing system has not informed Rev Rec yet\./,
    );
    assert.equal(
      v.stageCaption,
      "The billing system has not informed Rev Rec yet",
    );
    // The failed charge is there; no report to Rev Rec, no Rev Rec retry.
    assert.ok(
      v.timeline.some(
        (r: any) =>
          r.from === "billing" &&
          r.to === "processor" &&
          r.status === "declined",
      ),
    );
    assert.ok(
      !v.timeline.some((r: any) => r.to === "revrec" || r.from === "revrec"),
    );
    // A restart keeps a waiting story (it has no background step to lose).
    assert.equal(v.startError ?? null, null);
    // After the handover, a second one is refused.
    const again = await fetch(`${base}/sim/story/st_0123456789ab/handover`, {
      method: "POST",
    });
    assert.equal(again.status, 409);
    assert.match(
      (await again.json()).error.message,
      /already has this invoice/,
    );
  });

  test("live settings: refused with a plain reason before any engine call", async () => {
    const set = async (id: string, body: object) => {
      const r = await fetch(`${base}/sim/story/${id}/settings`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      });
      return { status: r.status, message: (await r.json()).error?.message };
    };
    // A story on a shared profile.
    assert.deepEqual(await set("st_0123456789ab", { maxRetries: 5 }), {
      status: 409,
      message:
        "This story runs on a shared profile, so its settings stay fixed.",
    });
    const pool = "st_cccc0000dddd";
    assert.deepEqual(await set(pool, { paused: true }), {
      status: 409,
      message: "Pause needs the sim service on our engine.",
    });
    assert.deepEqual(await set(pool, { graceDays: 3 }), {
      status: 409,
      message: "The engine counts real days; this demo runs in minutes.",
    });
    assert.equal((await set(pool, { mode: "fast" })).status, 400);
    assert.equal((await set(pool, { maxRetries: 0 })).status, 400);
    assert.equal((await set(pool, { maxRetries: 2.5 })).status, 400);
    assert.equal((await set(pool, { graceDays: 0 })).status, 400);
    assert.deepEqual(await set(pool, {}), {
      status: 400,
      message: "Nothing to change in the settings.",
    });
    // Smart needs the sim calendar to cover the pool (POOL_SMART=1).
    assert.deepEqual(await set(pool, { mode: "smart" }), {
      status: 409,
      message: "Smart on these profiles is being set up.",
    });
  });

  test("world events: a bad type is 400; a story Rev Rec is not retrying is 409", async () => {
    const send = (id: string, body: object) =>
      fetch(`${base}/sim/story/${id}/event`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      });
    assert.equal((await send("st_0123456789ab", { type: "rain" })).status, 400);
    const r = await send("st_aaaa0000bbbb", { type: "money_back" });
    assert.equal(r.status, 409);
    assert.equal(
      (await r.json()).error.message,
      "Rev Rec is not retrying this invoice now.",
    );
    // A new card is off (the user's policy, 28 Oct): refused before any other check
    const nc = await send("st_aaaa0000bbbb", { type: "new_card" });
    assert.equal(nc.status, 409);
    assert.equal(
      (await nc.json()).error.message,
      "A new card is not part of this demo.",
    );
    const v = await (await fetch(`${base}/sim/story/st_aaaa0000bbbb`)).json();
    assert.equal(v.actions.moneyBack, false);
    assert.equal(v.actions.newCard, false);
    assert.equal(
      v.actions.events.reasons.outage,
      "Rev Rec is not retrying this invoice now.",
    );
  });

  test("setup walkthrough: connectors carry masked values only", async () => {
    const { masked } = await import("../src/setup.ts");
    assert.equal(
      masked("sk_test_51ABCDEFGHIJ3f9a", "sk_test_"),
      "sk_test_••••••••3f9a",
    );
    assert.equal(masked("snd_abcdefghijk1234"), "••••••••1234");
    assert.equal(masked("short"), "••••••••");
    assert.equal(masked(""), null);
    const r = await fetch(`${base}/sim/connectors`);
    assert.equal(r.status, 200);
    const text = await r.text();
    const { config } = await import("../src/config.ts");
    for (const secret of [config.stripeKey, config.hsApiKey].filter(
      (s) => s && s.length > 8,
    ))
      assert.equal(text.includes(secret), false);
    const body = JSON.parse(text);
    assert.deepEqual(
      body.connectors.map((c: any) => [c.id, c.kind, c.logoKey]),
      [
        ["stripe", "processor", "stripe"],
        ["custombilling", "billing", "custombilling"],
      ],
    );
    const s = await (await fetch(`${base}/sim/setup/summary`)).json();
    assert.deepEqual(
      s.settings.map((x: any) => x.id),
      ["retryMode", "maxRetries", "startRule", "graceDays"],
    );
    assert.equal(s.note, "You can change these during a story.");
  });

  test("start mode: smart is refused with a plain reason when it cannot run", async () => {
    const start = (body: object) =>
      fetch(`${base}/sim/story/start`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      });
    assert.equal((await start({ preset: 4, mode: "fast" })).status, 400);
    // Preset 8 runs on the decider profile, which tests do not set up
    const shared = await start({ preset: 8, mode: "smart" });
    assert.equal(shared.status, 409);
    assert.equal(
      (await shared.json()).error.message,
      "This story needs the decider profile, which is not set up here.",
    );
    const off = await start({ preset: 4, mode: "smart" });
    assert.equal(off.status, 409);
    assert.equal(
      (await off.json()).error.message,
      "Smart start is not set up on this engine.",
    );
    const p = await (await fetch(`${base}/sim/presets`)).json();
    assert.deepEqual(p.limits, {
      startModes: ["static"],
      defaultStartMode: "static",
      // No other processor is configured in tests.
      processors: [
        {
          id: "stripe",
          name: "Stripe",
          presets: "all",
          startModes: ["static"],
        },
      ],
    });
    // Stripe only (PROCESSORS_ENABLED unset): another processor is refused in plain words
    const adyen = await start({ preset: 2, processor: "adyen" });
    assert.equal(adyen.status, 409);
    assert.equal(
      (await adyen.json()).error.message,
      "Only Stripe is on in this demo for now.",
    );
  });

  test("bad start bodies get 400 before any Stripe call", async () => {
    const post = (body: unknown) =>
      fetch(`${base}/sim/story/start`, {
        method: "POST",
        body: JSON.stringify(body),
      });
    const r9 = await post({ preset: 99 });
    assert.equal(r9.status, 400);
    assert.equal((await r9.json()).error.code, "bad_scenario");
    // customer "same" with no earlier customer now makes one (story.ts makeReturningHistory)
    const who = await post({ customer: "returning" });
    assert.equal(who.status, 400);
    assert.equal((await who.json()).error.code, "bad_request");
    const rc = await post({ card: "1111" });
    assert.equal(rc.status, 400);
    assert.equal((await rc.json()).error.code, "bad_request");
  });

  test("x-sim-session: allowed by CORS", async () => {
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
    // Preset 9 is hidden while SIM_OTHER_CARDS is off
    assert.equal(s.presets.length, 19);
    assert.equal(
      s.presets.some((p: any) => p.id === 9),
      false,
    );
    const p20 = s.presets.find((p: any) => p.id === 20);
    assert.deepEqual(
      [p20.group, p20.recoversOn, p20.bank.source],
      ["real-world", null, "scripted"],
    );
    assert.equal(s.cards.length, 5);
    assert.equal(JSON.stringify(s).includes("pm_card_"), false);
    const r = await fetch(`${base}/sim/story/st_000000000000`);
    assert.equal(r.status, 404);
    assert.equal((await r.json()).error.code, "not_found");
  });
});

describe("real-world stories (presets 11-20)", () => {
  test("each recovers on the retry the fixed timetable gives", async () => {
    const { PRESETS } = await import("../src/scenarios.ts");
    const { bankWorksFrom } = await import("../src/story.ts");
    const failureAt = "2026-10-27T09:00:00.000Z";
    const r = realLife(failureAt, 15);
    const stories = PRESETS.filter((p) => p.bank);
    assert.deepEqual(
      stories.map((p) => p.id),
      [11, 12, 13, 14, 15, 16, 17, 18, 19, 20],
    );
    for (const p of stories) {
      if (p.recoversOn === undefined) continue; // payday: depends on the date
      const from = bankWorksFrom(p.bank!, failureAt)!;
      const slot = r.slots.find((s) => s.at >= from);
      assert.equal(slot?.retry ?? null, p.recoversOn, `preset ${p.id}`);
      for (const s of p.expected.split(". "))
        assert.ok(s.split(" ").length <= 12, `preset ${p.id}: ${s}`);
    }
    // Payday: the next 1st or 15th at 9 AM after the failure.
    assert.equal(
      bankWorksFrom(PRESETS.find((p) => p.id === 15)!.bank!, failureAt),
      "2026-11-01T09:00:00.000Z",
    );
  });
});
