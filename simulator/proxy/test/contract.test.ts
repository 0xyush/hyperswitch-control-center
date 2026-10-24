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
const { sampleRecoveryBodies } = await import("../src/story.ts");

test("field drift is reported: a field gone, a new field, a response field missing", async () => {
  const sent = Object.keys(sampleRecoveryBodies().failure);
  const accepted = [
    ...sent.filter((f) => f !== "customer_present"),
    "amount_captured",
    "loyalty_points",
  ];
  const reply = (status: number, json: unknown) =>
    new Response(JSON.stringify(json), {
      status,
      headers: { "content-type": "application/json" },
    });
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
    if (url.includes("get-revenue-recovery-intent"))
      return reply(200, {
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
      });
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
    const r = await runContractTest();
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
  } finally {
    globalThis.fetch = realFetch;
  }
});
