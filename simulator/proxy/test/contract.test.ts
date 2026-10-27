// Offline test of the contract test's drift detection, with a fake sandbox in place of fetch.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";

process.env.SIM_DATA_DIR = fs.mkdtempSync(
  path.join(os.tmpdir(), "sim-contract-"),
);
const { runContractTest } = await import("../src/contract.ts");
const { config, engineOf } = await import("../src/config.ts");
const { sampleRecoveryBodies } = await import("../src/story.ts");

const reply = (status: number, json: unknown) =>
  new Response(JSON.stringify(json), {
    status,
    headers: { "content-type": "application/json" },
  });

const DETAIL = {
  id: "p1",
  status: "failed",
  amount_details: { order_amount: 6540, currency: "USD" },
  card_attached: 1,
  created_at: "2026-10-23T00:00:00Z",
  feature_metadata: {
    revenue_recovery: {
      total_retry_count: 1,
      first_payment_attempt_pg_error_code: "card_declined",
    },
  },
};

// Runs the contract test against a fake engine that accepts `accepted` request fields and answers
// the invoice detail with `detail`.
async function against(accepted: string[], detail: unknown) {
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (
    input: string | URL | Request,
    init?: RequestInit,
  ) => {
    const url = String(input);
    if (init?.method === "POST" && url.endsWith("/v2/recovery"))
      return reply(400, {
        error: {
          message: `Json deserialize error: unknown field \`__sim_contract_probe\`, expected one of ${accepted.map((f) => `\`${f}\``).join(", ")} at line 1 column 900`,
        },
      });
    if (url.includes("recovery-list"))
      return reply(200, {
        total_count: 1,
        data: [
          {
            id: "p1",
            status: "monitoring",
            merchant_reference_id: "x",
            merchant_id: "m",
          },
        ],
      });
    if (url.includes("get-revenue-recovery-intent")) return reply(200, detail);
    if (url.includes("list_attempts"))
      return reply(200, {
        payment_attempt_list: [
          {
            id: "a1",
            status: "failure",
            created_at: "2026-10-23T00:00:00Z",
            error: null,
            connector_payment_id: null,
            payment_method_data: { card: { last4: "0341" } },
          },
        ],
      });
    return reply(401, { error: { message: "no token in this test" } });
  }) as typeof fetch;
  try {
    return await runContractTest();
  } finally {
    globalThis.fetch = realFetch;
  }
}

test("field drift is reported: a field gone, a new field, a response field missing", async () => {
  const sent = Object.keys(sampleRecoveryBodies().failure);
  const r = await against(
    [
      ...sent.filter((f) => f !== "customer_present"),
      "amount_captured",
      "loyalty_points",
    ],
    DETAIL,
  );
  assert.equal(r.ok, false);
  assert.deepEqual(r.drift.requestFieldsGone, ["customer_present"]);
  assert.deepEqual(r.drift.requestFieldsNew, ["loyalty_points"]);
  assert.ok(
    r.drift.responseFieldsMissing.includes(
      "attempts: payment_attempt_list[].feature_metadata.revenue_recovery.attempt_triggered_by",
    ),
    JSON.stringify(r.drift.responseFieldsMissing),
  );
  assert.ok(r.checks.find((c) => c.name === "invoice detail")?.ok);
});

test("an invoice detail without created_at: drift on the sandbox, known absent on the self-hosted engine", async () => {
  const sent = Object.keys(sampleRecoveryBodies().failure);
  const { created_at: _, ...noCreatedAt } = DETAIL;
  const saved = config.engine;
  try {
    config.engine = "sandbox";
    const sandbox = await against(sent, noCreatedAt);
    assert.equal(sandbox.engine, "sandbox");
    assert.equal(
      sandbox.checks.find((c) => c.name === "invoice detail")?.ok,
      false,
    );
    assert.ok(
      sandbox.drift.responseFieldsMissing.includes(
        "invoice detail: created_at",
      ),
    );
    assert.deepEqual(sandbox.knownAbsent, []);

    config.engine = "selfhost";
    const selfhost = await against(sent, noCreatedAt);
    const detail = selfhost.checks.find((c) => c.name === "invoice detail")!;
    assert.equal(detail.ok, true, detail.detail);
    assert.match(detail.detail, /created_at: not returned by the selfhost/);
    assert.deepEqual(selfhost.knownAbsent, ["invoice detail: created_at"]);
    assert.ok(
      !selfhost.drift.responseFieldsMissing.includes(
        "invoice detail: created_at",
      ),
    );
    // Any other field gone is still drift on the self-hosted engine.
    const { card_attached: __, ...alsoNoCards } = noCreatedAt;
    const worse = await against(sent, alsoNoCards);
    assert.ok(
      worse.drift.responseFieldsMissing.includes(
        "invoice detail: card_attached",
      ),
    );
  } finally {
    config.engine = saved;
  }
});

test("the engine follows the base URL unless HS_ENGINE sets it", () => {
  assert.equal(engineOf("https://sandbox.hyperswitch.io", ""), "sandbox");
  assert.equal(engineOf("http://localhost:8090", ""), "selfhost");
  assert.equal(engineOf("", ""), "sandbox");
  assert.equal(engineOf("http://localhost:8090", "sandbox"), "sandbox");
  assert.equal(
    engineOf("https://sandbox.hyperswitch.io", "selfhost"),
    "selfhost",
  );
});
