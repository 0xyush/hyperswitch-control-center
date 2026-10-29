// node --test simulator/selfhost/sim/sim.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";
import { SEEDED, statsDocument } from "../model/retry-stats.mjs";
import {
  DEFAULT_SECONDS_PER_DAY,
  demoTime,
  ladderOffsets,
  ladderSlot,
  plannedSlot,
  slotOf,
} from "./calendar.mjs";
import {
  clusterKey,
  documentChanges,
  documentsCsv,
  emptyDocument,
  expectedDocuments,
} from "./refile.mjs";

const at = (text) => Date.parse(text);
const totals = (doc) =>
  ["dow", "dom", "hod"].map((family) => [
    doc[family].reduce((s, slot) => s + slot.n, 0),
    doc[family].reduce((s, slot) => s + slot.k, 0),
  ]);

test("the ladder: 15 retries over 507,660 s, so 13.6 demo seconds per real day", () => {
  assert.equal(ladderOffsets().length, 15);
  assert.equal(ladderOffsets().at(-1), 507_660);
  assert.equal(DEFAULT_SECONDS_PER_DAY.toFixed(2), "13.62");
  assert.equal(ladderSlot(0, 1), 60_000);
  assert.equal(ladderSlot(0, 2), 10_860_000);
});

test("slots are the engine's: Monday = 0, the 1st = 0, UTC hours", () => {
  // Friday 30 Oct 2026, 22:00 UTC
  assert.deepEqual(slotOf(at("2026-10-30T22:00:01Z")), {
    dow: 4,
    dom: 29,
    hod: 22,
  });
  // Monday 2 Nov 2026, 00:30 UTC
  assert.deepEqual(slotOf(at("2026-11-02T00:30:00Z")), {
    dow: 0,
    dom: 1,
    hod: 0,
  });
});

test("decision 1 is exactly the engine's pick", () => {
  const enginePickMs = at("2026-10-30T22:00:01Z");
  assert.equal(
    plannedSlot({
      enginePickMs,
      decidedAtMs: at("2026-10-27T18:20:37Z"),
      lastSlotMs: null,
    }),
    enginePickMs,
  );
});

test("a later pick keeps the model's day offset and time, after the last tried slot", () => {
  // Decided on 27 Oct for 1 Nov 19:00: 5 days ahead. The last retry was on 30 Oct.
  const slot = plannedSlot({
    enginePickMs: at("2026-11-01T19:00:01Z"),
    decidedAtMs: at("2026-10-27T18:21:10Z"),
    lastSlotMs: at("2026-10-30T22:00:01Z"),
  });
  assert.equal(new Date(slot).toISOString(), "2026-11-04T19:00:01.000Z");
});

test("demo time: one real day takes secondsPerDay seconds after the failure", () => {
  const failure = at("2026-10-27T18:20:35Z");
  assert.equal(demoTime(failure, failure + 86_400_000, 13.6) - failure, 13_600);
  // The model's first pick for insufficient funds, 3 days 3.7 h ahead: about 43 s into the demo
  const t = demoTime(
    failure,
    at("2026-10-30T22:00:01Z"),
    DEFAULT_SECONDS_PER_DAY,
  );
  assert.equal(Math.round((t - failure) / 1000), 43);
});

test("the seeded documents pass the engine's checks (equal totals, k <= n)", () => {
  for (const code of SEEDED) {
    const doc = statsDocument(code);
    const [dow, dom, hod] = totals(doc);
    assert.deepEqual(dow, dom, code);
    assert.deepEqual(dom, hod, code);
    for (const family of ["dow", "dom", "hod"])
      assert.ok(
        doc[family].every((slot) => slot.k <= slot.n),
        code,
      );
  }
});

test("outcomes add a try to one slot per family, and a success when it worked", () => {
  const key = clusterKey("do_not_honor");
  const seed = new Map([[key, statsDocument("do_not_honor")]]);
  const docs = expectedDocuments(seed, [
    { cluster: key, success: true, slotMs: at("2026-10-30T22:00:01Z") },
    { cluster: key, success: false, slotMs: at("2026-11-02T00:30:00Z") },
    {
      cluster: clusterKey(null),
      success: false,
      slotMs: at("2026-11-02T00:30:00Z"),
    },
  ]);
  const doc = docs.get(key);
  const before = statsDocument("do_not_honor");
  assert.equal(doc.dow[4].n, before.dow[4].n + 1);
  assert.equal(doc.dow[4].k, before.dow[4].k + 1);
  assert.equal(doc.dom[1].n, before.dom[1].n + 1);
  assert.equal(doc.dom[1].k, before.dom[1].k);
  assert.deepEqual(totals(doc)[0], [5210, 1551]);
  assert.deepEqual(totals(doc)[0], totals(doc)[2]);
  // The seed is not changed in place
  assert.deepEqual(seed.get(key), before);
  // A failure with no standardised code starts the UNK cluster
  assert.deepEqual(totals(docs.get("v1|UNK/UNK/UNK"))[1], [1, 0]);
});

test("changes: write what differs, remove clusters the seed and outcomes do not have", () => {
  const key = clusterKey("insufficient_funds");
  const expected = new Map([[key, statsDocument("insufficient_funds")]]);
  const same = new Map([
    [key, JSON.parse(JSON.stringify(statsDocument("insufficient_funds")))],
    ["v1|downstream_technical_issue/UNK/UNK", emptyDocument()],
  ]);
  assert.deepEqual(documentChanges(expected, same), {
    write: [],
    remove: ["v1|downstream_technical_issue/UNK/UNK"],
  });
  const changed = new Map([[key, emptyDocument()]]);
  assert.deepEqual(
    documentChanges(expected, changed).write.map(([k]) => k),
    [key],
  );
});

test("the CSV quotes the JSON as the admin route reads it", () => {
  const csv = documentsCsv([
    [clusterKey("do_not_honor"), { dow: [{ n: 1, k: 0 }] }],
  ]);
  assert.equal(
    csv,
    'cluster_key,stats\nv1|do_not_honor/UNK/UNK,"{""dow"":[{""n"":1,""k"":0}]}"\n',
  );
});

// ---- The bank

import {
  DECLINE_CARD,
  decide,
  firstWorkingRetry,
  parseRule,
  rewriteCharge,
  worksFromMs,
} from "./bank.mjs";
import { slotChance } from "../model/retry-stats.mjs";

test("rules: only v1 rules with a known reason and a draw or worksFrom", () => {
  assert.equal(parseRule(undefined), null);
  assert.equal(parseRule("not json"), null);
  assert.equal(parseRule('{"v":1,"reason":"stolen_card","draw":0.2}'), null);
  assert.equal(parseRule('{"v":1,"reason":"insufficient_funds"}'), null);
  assert.deepEqual(
    parseRule('{"v":1,"reason":"insufficient_funds","draw":0.2}'),
    {
      v: 1,
      reason: "insufficient_funds",
      draw: 0.2,
    },
  );
});

test("worksFrom moments, in UTC from the failure", () => {
  const failure = at("2026-10-27T09:00:00Z"); // a Tuesday
  const when = (worksFrom) =>
    new Date(worksFromMs(worksFrom, failure)).toISOString();
  assert.equal(when({ afterHours: 2 }), "2026-10-27T11:00:00.000Z");
  assert.equal(when({ dayOffset: 1, hour: 10 }), "2026-10-28T10:00:00.000Z");
  assert.equal(when({ weekday: 0, hour: 8 }), "2026-11-02T08:00:00.000Z");
  assert.equal(when({ payday: true, hour: 9 }), "2026-11-01T09:00:00.000Z");
  // On payday itself, before 9 AM: that same day
  assert.equal(
    new Date(
      worksFromMs({ payday: true, hour: 9 }, at("2026-11-15T06:00:00Z")),
    ).toISOString(),
    "2026-11-15T09:00:00.000Z",
  );
});

test("stories 1, 4 and 9 recover on the static retry the catalog lists", () => {
  // 1 Bank hiccup: back after 2 h -> retry 2 (3 h)
  assert.equal(
    firstWorkingRetry({ afterHours: 2 }, at("2026-10-27T09:00:00Z")),
    2,
  );
  // 4 Weekend low balance: failed Saturday 20:00, back Monday 8 AM (36 h) -> retry 8 (42 h)
  assert.equal(
    firstWorkingRetry({ weekday: 0, hour: 8 }, at("2026-10-31T20:00:00Z")),
    8,
  );
  // 9 Last chance: failed 9 AM, back day 6 at 10 PM (133 h) -> retry 15 (141 h)
  assert.equal(
    firstWorkingRetry({ dayOffset: 5, hour: 22 }, at("2026-10-27T09:00:00Z")),
    15,
  );
  // 10 Too late: back day 7 at 9 AM (144 h): after the last retry (141 h)
  assert.equal(
    firstWorkingRetry({ dayOffset: 6, hour: 9 }, at("2026-10-27T09:00:00Z")),
    null,
  );
});

test("a story charge works from its moment on; a portfolio charge by its draw", () => {
  const failureMs = at("2026-10-27T09:00:00Z");
  const story = {
    v: 1,
    reason: "insufficient_funds",
    worksFrom: { afterHours: 2 },
  };
  assert.equal(
    decide(story, { slotMs: failureMs + 3600_000, failureMs }).works,
    false,
  );
  assert.equal(
    decide(story, { slotMs: failureMs + 7200_000, failureMs }).works,
    true,
  );
  const chance = (reason, slot) => slotChance("insufficient_funds", slot);
  // The 1st at 8 PM on a Friday is the pattern's best slot; a draw of 0.5 works there
  const best = { slotMs: at("2027-01-01T20:00:00Z"), failureMs };
  assert.equal(
    decide({ v: 1, reason: "insufficient_funds", draw: 0.5 }, best, chance)
      .works,
    true,
  );
  assert.equal(
    decide({ v: 1, reason: "insufficient_funds", draw: 0.97 }, best, chance)
      .works,
    false,
  );
});

test("a win charges the good card; a loss a one-off declining card with no customer", () => {
  const engine = new URLSearchParams(
    "amount=6540&currency=usd&customer=cus_1&payment_method=pm_0341&confirm=true&off_session=true&metadata[order_id]=PF-1-S&setup_future_usage=off_session",
  );
  const win = rewriteCharge(engine, {
    works: true,
    goodCard: "pm_4242",
    decline: "insufficient_funds",
  });
  assert.equal(win.get("payment_method"), "pm_4242");
  assert.equal(win.get("customer"), "cus_1");
  const loss = rewriteCharge(engine, {
    works: false,
    decline: "insufficient_funds",
  });
  assert.equal(loss.get("payment_method"), DECLINE_CARD.insufficient_funds);
  assert.equal(loss.has("customer"), false);
  assert.equal(loss.has("setup_future_usage"), false);
  assert.equal(loss.get("metadata[order_id]"), "PF-1-S");
  assert.equal(loss.get("amount"), "6540");
  // The engine's own parameters are not changed in place
  assert.equal(engine.get("payment_method"), "pm_0341");
});

// ---- The model, re-computed for display

import {
  explainDecision,
  inclusionProbabilities,
  slotScores,
} from "./model.mjs";

test("slot scores match the engine's hand-math test (scores_match_hand_math)", () => {
  const dow = Array.from({ length: 7 }, () => ({ n: 0, k: 0 }));
  dow[0] = { n: 1843, k: 512 };
  dow[4] = { n: 1998, k: 671 };
  dow[6] = { n: 987, k: 240 };
  const sc = slotScores(dow);
  assert.ok(Math.abs(sc.get(4) - 9.2103) <= 0.1, `score 4 = ${sc.get(4)}`);
  assert.ok(Math.abs(sc.get(0) - -2.73) <= 0.1, `score 0 = ${sc.get(0)}`);
  assert.ok(Math.abs(sc.get(6) - -6.48) <= 0.1, `score 6 = ${sc.get(6)}`);
  // Slots with no data are not scored
  assert.equal(sc.has(1), false);
});

test("inclusion probabilities: floor, pour, and tied days share", () => {
  assert.deepEqual(
    inclusionProbabilities([3, 2, 1, 1], 2, 0.1, 1e-4).map(
      (p) => +p.toFixed(6),
    ),
    [1, 0.8, 0.1, 0.1],
  );
  assert.deepEqual(
    inclusionProbabilities([2, 2, 1], 1, 0.1, 1e-4).map((p) => +p.toFixed(6)),
    [0.45, 0.45, 0.1],
  );
});

test("the insufficient-funds decision of 27 Oct, in plain numbers", () => {
  const view = explainDecision(statsDocument("insufficient_funds"), {
    decidedAtMs: at("2026-10-27T18:20:37Z"),
    graceEndMs: at("2026-11-26T00:00:00Z"),
    budget: 14,
    pickMs: at("2026-10-30T22:00:01Z"),
  });
  // The engine logged window_len 28 and an inclusion probability of 1.0 for Fri 30 Oct
  assert.equal(view.windowDays, 28);
  const chosen = view.days.find((d) => d.chosen);
  assert.equal(chosen.label, "Fri, Oct 30");
  assert.equal(chosen.by, "weekday");
  assert.deepEqual([chosen.worked, chosen.of], [203, 744]);
  assert.equal(+chosen.chance.toFixed(6), 1);
  // The best days: the 1st and the 15th of the month, by day of month
  assert.deepEqual(
    view.days.slice(0, 2).map((d) => d.label),
    ["Sun, Nov 1", "Sun, Nov 15"],
  );
  // 10 PM: 69 of 217 before, picked about 1 time in 5
  const hour = view.hours.find((h) => h.chosen);
  assert.deepEqual([hour.label, hour.worked, hour.of], ["10 PM", 69, 217]);
  assert.equal(hour.chance.toFixed(3), "0.195");
});

test("events: a stolen card and an outage come before the rule; money back works from a moment", () => {
  const failureMs = at("2026-10-27T09:00:00Z");
  const rule = {
    v: 1,
    reason: "insufficient_funds",
    worksFrom: { at: "2026-10-28T09:00:00Z" },
    outages: [{ from: "2026-10-27T12:00:00Z", until: "2026-10-27T18:00:00Z" }],
  };
  const at_ = (iso) => decide(rule, { slotMs: at(iso), failureMs });
  assert.deepEqual(
    [
      at_("2026-10-27T10:00:00Z"),
      at_("2026-10-27T13:00:00Z"),
      at_("2026-10-28T09:00:00Z"),
    ].map((d) => [d.works, d.decline]),
    [
      [false, "insufficient_funds"],
      [false, "processing_error"],
      [true, "insufficient_funds"],
    ],
  );
  const stolen = { ...rule, stolenFrom: "2026-10-28T00:00:00Z" };
  assert.deepEqual(
    (({ works, decline }) => [works, decline])(
      decide(stolen, { slotMs: at("2026-10-28T09:00:00Z"), failureMs }),
    ),
    [false, "stolen_card"],
  );
  assert.equal(
    rewriteCharge(
      new URLSearchParams("customer=cus_1&payment_method=pm_0341"),
      {
        works: false,
        decline: "stolen_card",
      },
    ).get("payment_method"),
    DECLINE_CARD.stolen_card,
  );
  // stolen_card is an event, not a story reason
  assert.equal(parseRule('{"v":1,"reason":"stolen_card","draw":0.2}'), null);
});

// ---- Later picks, re-computed inside the remaining window

import { pickDay, systematicSample } from "./model.mjs";

test("the systematic draw hits exactly k distinct days, in calendar order", () => {
  const pi = [1, 0.5, 0.5, 0, 1];
  const picked = systematicSample(pi, 0.25, [4, 2, 0, 1, 3], 3);
  assert.equal(picked.length, 3);
  assert.deepEqual(
    picked,
    [...picked].sort((a, b) => a - b),
  );
  assert.ok(picked.includes(0) && picked.includes(4));
});

test("no later pick lands past the grace end, whatever the day and the draw", () => {
  let seed = 7;
  const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  for (const code of SEEDED) {
    const doc = statsDocument(code);
    for (let trial = 0; trial < 300; trial++) {
      const todayMs =
        at("2026-10-27T00:00:00Z") + Math.floor(random() * 40 * 86_400_000);
      const graceEndMs = at("2026-11-26T00:00:00Z");
      const budget = 1 + Math.floor(random() * 14);
      const picked = pickDay(doc, { todayMs, graceEndMs, budget, random });
      if (!picked) {
        // Only when no whole future day is left inside grace
        assert.ok(
          Math.floor((graceEndMs - todayMs) / 86_400_000) <= 1,
          `${code} ${trial}`,
        );
        continue;
      }
      // Never today, and the whole picked day (any hour) starts and ends inside grace
      assert.ok(
        picked.dayMs >=
          Math.floor(todayMs / 86_400_000) * 86_400_000 + 86_400_000,
      );
      assert.ok(
        picked.dayMs + 86_400_000 <= graceEndMs,
        `${code} ${trial}: past grace`,
      );
    }
  }
});

test("a re-computed pick favours the model's best days", () => {
  // Insufficient funds from Tue 27 Oct with 14 retries left: the 1st (a payday) is always planned
  let seed = 11;
  const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  const picks = Array.from({ length: 200 }, () =>
    pickDay(statsDocument("insufficient_funds"), {
      todayMs: at("2026-10-27T18:00:00Z"),
      graceEndMs: at("2026-11-26T00:00:00Z"),
      budget: 14,
      random,
    }),
  );
  // The soonest planned day is within the first week every time
  assert.ok(picks.every((p) => p.dayMs <= at("2026-11-03T00:00:00Z")));
});

// ---- The bank at other processors (A's replacements, 27 Oct)

import {
  applyReplacements,
  cybersourceHeaders,
  parseStory,
  replacementsFor,
  storyMatches,
  withOwnReference,
  withoutDuplicateCheck,
} from "./bank.mjs";

const adyenStory = {
  v: 1,
  processor: "adyen",
  invoiceId: "SIM-13-abc",
  goodToken: "TOKEN_GOOD",
  replacements: {
    insufficient_funds: [
      {
        path: "paymentMethod",
        value: { type: "scheme", holderName: "NOT_ENOUGH_BALANCE" },
      },
    ],
    generic_decline: [
      {
        path: "paymentMethod",
        value: { type: "scheme", holderName: "DECLINED" },
      },
    ],
  },
  rule: { reason: "generic_decline", worksFrom: { dayOffset: 1, hour: 10 } },
};

test("a story is registered only when complete; its rule becomes v1", () => {
  assert.equal(parseStory({ ...adyenStory, processor: "paypal" }), null);
  assert.equal(parseStory({ ...adyenStory, invoiceId: "" }), null);
  assert.equal(
    parseStory({ ...adyenStory, rule: { reason: "stolen_card", draw: 0.1 } }),
    null,
  );
  assert.equal(parseStory(adyenStory).rule.v, 1);
});

test("a charge matches its story by the good token, or by every match string, and the invoice id", () => {
  const body = JSON.stringify({
    reference: "SIM-13-abc",
    paymentMethod: { storedPaymentMethodId: "TOKEN_GOOD" },
  });
  assert.equal(storyMatches(body, adyenStory), true);
  assert.equal(
    storyMatches(body.replace("TOKEN_GOOD", "TOKEN_NEW"), adyenStory),
    false,
  );
  // Worldpay: one token for several stories; each charge carries its own invoice id
  for (const reference of ["SIM-20-abc", "SIM-13-abcd", "SIM-13-ab", ""])
    assert.equal(
      storyMatches(body.replace("SIM-13-abc", reference), adyenStory),
      false,
    );
  assert.equal(
    storyMatches("orderid=SIM-13-abc&customer_vault_id=TOKEN_GOOD", adyenStory),
    true,
  );
  assert.equal(
    storyMatches(body, { ...adyenStory, invoiceId: "SIM-13-a.c" }),
    false,
  );
  const anet = { ...adyenStory, match: ["915", "917"] };
  assert.equal(
    storyMatches(
      '{"customerProfileId":"915","paymentProfile":{"paymentProfileId":"917"},"order":{"description":"SIM-13-abc"}}',
      anet,
    ),
    true,
  );
  assert.equal(
    storyMatches(
      '{"customerProfileId":"915","paymentProfile":{"paymentProfileId":"999"},"order":{"description":"SIM-13-abc"}}',
      anet,
    ),
    false,
  );
});

test("the replacements: the reason's own, else the generic decline's, else the first", () => {
  assert.equal(
    replacementsFor(adyenStory, "insufficient_funds")[0].value.holderName,
    "NOT_ENOUGH_BALANCE",
  );
  assert.equal(
    replacementsFor(adyenStory, "stolen_card")[0].value.holderName,
    "DECLINED",
  );
  const one = {
    replacements: { processing_error: [{ field: "amount", value: "0.50" }] },
  };
  assert.equal(replacementsFor(one, "insufficient_funds")[0].field, "amount");
});

test("replacements on JSON paths and form fields; the rest stays", () => {
  const worldpay = JSON.stringify({
    transactionReference: "SIM-1",
    instruction: {
      paymentInstrument: { type: "card/tokenized", href: "TOKEN" },
      customerAgreement: { type: "subscription" },
      value: { amount: 6540 },
    },
  });
  const out = JSON.parse(
    applyReplacements(worldpay, "application/json", [
      {
        path: "instruction.paymentInstrument",
        value: { type: "plain", cardHolderName: "REFUSED43" },
      },
      { path: "instruction.customerAgreement", delete: true },
    ]),
  );
  assert.deepEqual(out.instruction.paymentInstrument, {
    type: "plain",
    cardHolderName: "REFUSED43",
  });
  assert.equal(out.instruction.customerAgreement, undefined);
  assert.equal(out.instruction.value.amount, 6540);
  const adyen = (body) =>
    JSON.parse(
      applyReplacements(JSON.stringify(body), "application/json", [
        { path: "paymentMethod.holderName", value: "NOT_ENOUGH_BALANCE" },
      ]),
    ).paymentMethod;
  assert.deepEqual(adyen({ paymentMethod: { storedPaymentMethodId: "T" } }), {
    storedPaymentMethodId: "T",
    holderName: "NOT_ENOUGH_BALANCE",
  });
  assert.deepEqual(
    adyen({ paymentMethod: { storedPaymentMethodId: "T", holderName: "Jo" } }),
    { storedPaymentMethodId: "T", holderName: "NOT_ENOUGH_BALANCE" },
  );
  assert.deepEqual(adyen({ paymentMethod: "x" }), {
    holderName: "NOT_ENOUGH_BALANCE",
  });
  const nmi = applyReplacements(
    "security_key=K&type=sale&amount=65.40&customer_vault_id=V",
    "application/x-www-form-urlencoded",
    [{ field: "amount", value: "0.50" }],
  );
  assert.equal(new URLSearchParams(nmi).get("amount"), "0.50");
  assert.equal(new URLSearchParams(nmi).get("customer_vault_id"), "V");
});

test("Cybersource is signed again for its own host and path, over the new body", () => {
  const hash = {
    sha256: (b) => `D(${b})`,
    hmac: (key, text) => `H(${key}|${text})`,
  };
  const headers = {
    date: "Tue, 27 Oct 2026 21:00:00 GMT",
    "v-c-merchant-id": "merchant1",
    signature:
      'keyid="engine", algorithm="HmacSHA256", headers="host date (request-target) digest v-c-merchant-id", signature="old"',
  };
  const out = cybersourceHeaders(
    {
      method: "POST",
      path: "/pts/v2/payments",
      host: "apitest.cybersource.com",
      headers,
      body: "{}",
      keyId: "KEY",
      secret: "S",
    },
    hash,
  );
  assert.equal(out.digest, "SHA-256=D({})");
  assert.equal(
    out.signature,
    `keyid="KEY", algorithm="HmacSHA256", headers="host date (request-target) digest v-c-merchant-id", signature="H(S|host: apitest.cybersource.com\ndate: Tue, 27 Oct 2026 21:00:00 GMT\n(request-target): post /pts/v2/payments\ndigest: SHA-256=D({})\nv-c-merchant-id: merchant1)"`,
  );
  // A GET has no digest in its list
  const get = cybersourceHeaders(
    {
      method: "GET",
      path: "/pts/v2/payments/1",
      host: "apitest.cybersource.com",
      headers: {
        ...headers,
        signature: 'headers="host date (request-target) v-c-merchant-id"',
      },
      body: "",
      keyId: "KEY",
      secret: "S",
    },
    hash,
  );
  assert.equal(get.digest, undefined);
});

test("a declined Authorize.net retry has no duplicate check, in the schema's field order", () => {
  const request = (fields) =>
    JSON.stringify({
      createTransactionRequest: {
        merchantAuthentication: { name: "N", transactionKey: "K" },
        transactionRequest: {
          transactionType: "authCaptureTransaction",
          amount: 65.4,
          currencyCode: "USD",
          profile: {
            customerProfileId: "C",
            paymentProfile: { paymentProfileId: "P" },
          },
          order: { invoiceNumber: "abc", description: "SIM-13" },
          customer: { id: "pay_1" },
          ...fields,
        },
      },
    });
  const out = (text) =>
    JSON.parse(withoutDuplicateCheck(text)).createTransactionRequest
      .transactionRequest;
  const window0 = { settingName: "duplicateWindow", settingValue: "0" };
  const keys = Object.keys(
    out(request({ processingOptions: { isSubsequentAuth: true } })),
  );
  assert.deepEqual(keys.slice(-2), [
    "transactionSettings",
    "processingOptions",
  ]);
  assert.deepEqual(Object.keys(out(request({}))).at(-1), "transactionSettings");
  const kept = out(
    request({
      transactionSettings: {
        setting: [
          { settingName: "duplicateWindow", settingValue: "120" },
          { settingName: "emailCustomer", settingValue: "false" },
        ],
      },
      userFields: { userField: [] },
    }),
  );
  assert.deepEqual(kept.transactionSettings.setting, [
    { settingName: "emailCustomer", settingValue: "false" },
    window0,
  ]);
  assert.deepEqual(Object.keys(kept).slice(-2), [
    "transactionSettings",
    "userFields",
  ]);
  assert.equal(kept.profile.paymentProfile.paymentProfileId, "P");
  assert.equal(withoutDuplicateCheck('{"other":1}'), '{"other":1}');
});

test("a declined Worldpay retry gets its own transaction reference", () => {
  const body = JSON.stringify({
    transactionReference: "SIM-20-abc",
    merchant: { entity: "default" },
    instruction: { value: { amount: 6540 } },
  });
  const out = JSON.parse(withOwnReference(body, "SIM-20-abc-r3"));
  assert.equal(out.transactionReference, "SIM-20-abc-r3");
  assert.deepEqual(Object.keys(out), [
    "transactionReference",
    "merchant",
    "instruction",
  ]);
  assert.equal(withOwnReference(body, "x".repeat(65)), body);
  assert.equal(withOwnReference('{"other":1}', "SIM-20-abc-r3"), '{"other":1}');
});

test("a ladder retry after model picks never goes back in time", async () => {
  const { ladderSlotAfter, ladderSlot, ladderOffsets } =
    await import("./calendar.mjs");
  const failure = Date.UTC(2026, 9, 27, 12);
  const offsets = ladderOffsets();
  // No earlier retry: the ladder's own slot
  assert.equal(ladderSlotAfter(failure, 1, null), ladderSlot(failure, 1));
  // Retry 14 was a model pick on day 27: retry 15 comes the ladder's last gap after it
  const pick14 = failure + 656 * 3600_000;
  assert.equal(
    ladderSlotAfter(failure, 15, pick14),
    pick14 + (offsets[14] - offsets[13]) * 1000,
  );
  // Earlier retries on the ladder: unchanged
  assert.equal(
    ladderSlotAfter(failure, 15, ladderSlot(failure, 14)),
    ladderSlot(failure, 15),
  );
});
