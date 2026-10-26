// Offline test of Replay mode: a fixed recording, sliced step by step. No sandbox, no Stripe.
import assert from "node:assert/strict";
import fs from "node:fs";
import type { AddressInfo } from "node:net";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sim-replay-"));
process.env.SIM_DATA_DIR = dir;
process.env.SIM_CONTRACT_TEST = "0";

// A recovered preset-2 story: charge, report, booking, Rev Rec's charge, outcome.
const row = (
  stepId: string,
  at: string,
  from: string,
  to: string,
  label: string,
  status: string,
) => ({
  stepId,
  at,
  from,
  to,
  label,
  status,
  text: label,
  source: "sandbox",
  why: [],
  attemptId: null,
});
const req = (stepId: string, at: string, body: unknown = {}) => ({
  stepId,
  at,
  step: stepId,
  system: "sandbox",
  request: { method: "GET", url: "x" },
  response: { status: 200, body },
  ms: null,
});
const view = {
  storyId: "st_aaaaaaaaaaaa",
  preset: 2,
  startedAt: "2026-10-24T01:00:00Z",
  status: "recovered",
  stage: "Recovered",
  recoveredBy: "revrec",
  done: true,
  invoice: {
    status: "succeeded",
    amount_details: { order_amount: 6540, amount_captured: 6540 },
  },
  processTracker: { name: "EXECUTE_WORKFLOW", status: "finish" },
  stageHistory: [
    {
      stage: "Monitoring",
      firstSeenAt: "2026-10-24T01:00:02Z",
      source: "sandbox",
    },
    {
      stage: "Scheduled",
      firstSeenAt: "2026-10-24T01:00:30Z",
      source: "observed",
    },
    {
      stage: "Processing",
      firstSeenAt: "2026-10-24T01:01:00Z",
      source: "sandbox",
    },
    {
      stage: "Recovered",
      firstSeenAt: "2026-10-24T01:01:01Z",
      source: "sandbox",
    },
  ],
  timeline: [
    row(
      "s1",
      "2026-10-24T01:00:00Z",
      "billing",
      "billing",
      "new invoice $65.40",
      "info",
    ),
    row(
      "s2",
      "2026-10-24T01:00:02Z",
      "billing",
      "processor",
      "charge $65.40 on ••0002 → declined (generic_decline)",
      "declined",
    ),
    row(
      "s3",
      "2026-10-24T01:00:03Z",
      "billing",
      "revrec",
      "report failure → 200 recorded",
      "ok",
    ),
    row(
      "s4",
      "2026-10-24T01:00:30Z",
      "revrec",
      "revrec",
      "pick retry time → 01:00:58",
      "ok",
    ),
    row(
      "att_a2",
      "2026-10-24T01:01:00Z",
      "revrec",
      "processor",
      "charge saved card ••4242 → approved",
      "ok",
    ),
    row(
      "s5",
      "2026-10-24T01:01:05Z",
      "revrec",
      "billing",
      "invoice recovered → mark paid",
      "ok",
    ),
  ],
  requests: [
    req("s1", "2026-10-24T01:00:00Z"),
    req("s2", "2026-10-24T01:00:02Z"),
    req("s3", "2026-10-24T01:00:03Z"),
    req("s4", "2026-10-24T01:00:30Z", {
      name: "EXECUTE_WORKFLOW",
      status: "new",
      schedule_time_for_payment: "2026-10-24T01:00:58.000Z",
    }),
    req("att_a2", "2026-10-24T01:01:00Z"),
    req("s5", "2026-10-24T01:01:05Z"),
  ],
  attempts: [
    { id: "a1", created_at: "2026-10-24T01:00:02Z" },
    { id: "a2", created_at: "2026-10-24T01:01:00Z" },
  ],
  attemptSummary: [
    { id: "a1", at: "2026-10-24T01:00:02Z", by: "billing", status: "failure" },
    { id: "a2", at: "2026-10-24T01:01:00Z", by: "revrec", status: "charged" },
  ],
  explain: [
    { id: "status", source: "sandbox", text: "final status" },
    { id: "reason", source: "rule", text: "generic_decline means ..." },
  ],
  actions: {
    paidInApp: false,
    reportAgain: false,
    cancel: false,
    reportAgainMode: "duplicate",
  },
};
fs.writeFileSync(
  path.join(dir, "recordings.json"),
  JSON.stringify([
    {
      id: view.storyId,
      title: "Fixture",
      preset: 2,
      recordedAt: view.startedAt,
      markedAt: view.startedAt,
      outcome: "recovered (by Rev Rec)",
      steps: 6,
      view,
    },
  ]),
);

const { createServer } = await import("../src/server.ts");
const server = createServer();
let base = "";
before(async () => {
  await new Promise<void>((ok) => server.listen(0, "127.0.0.1", ok));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});
after(() => server.close());

const replay = async (upTo?: number) =>
  (
    await fetch(
      `${base}/sim/replay/${view.storyId}${upTo === undefined ? "" : `?upTo=${upTo}`}`,
    )
  ).json();

test("the recordings list shows the fixture", async () => {
  const r = await (await fetch(`${base}/sim/recordings`)).json();
  assert.deepEqual(
    r.recordings.map((x: any) => [x.id, x.steps]),
    [[view.storyId, 6]],
  );
});

test("a replay is sliced step by step", async () => {
  const v0 = await replay(0);
  assert.equal(v0.stage, "Starting");
  assert.equal(v0.timeline.length, 0);
  assert.equal(v0.done, false);

  const v3 = await replay(3);
  assert.equal(v3.stage, "Monitoring");
  assert.equal(v3.requests.length, 3);
  assert.equal(v3.attemptSummary.length, 1);
  assert.equal(v3.invoice.status, "failed");

  const v4 = await replay(4); // the booking: Scheduled, with the pending row and its time
  assert.equal(v4.stage, "Scheduled");
  assert.equal(v4.nextRetryAt, "2026-10-24T01:00:58.000Z");
  assert.equal(v4.timeline.at(-1).status, "pending");
  assert.deepEqual(
    [v4.timeline.at(-1).from, v4.timeline.at(-1).to],
    ["revrec", "processor"],
  );
  assert.equal(v4.processTracker.status, "new");

  const v5 = await replay(5); // Rev Rec charged: no pending row any more
  assert.equal(v5.stage, "Processing");
  assert.equal(v5.nextRetryAt, null);
  assert.equal(v5.timeline.length, 5);

  const end = await replay();
  assert.equal(end.stage, "Recovered");
  assert.equal(end.done, true);
  assert.equal(end.invoice.status, "succeeded");
  assert.equal(end.explain[0].text, "final status");
  assert.deepEqual(end.replay, {
    total: 6,
    upTo: 6,
    recordedAt: view.startedAt,
    markedAt: view.startedAt,
    title: "Fixture",
  });
  assert.equal(end.actions.paidInApp, false);
});

test("unknown story 404; marking through a forwarded call 403", async () => {
  assert.equal((await fetch(`${base}/sim/replay/st_000000000000`)).status, 404);
  const r = await fetch(`${base}/sim/recordings/${view.storyId}`, {
    method: "POST",
    headers: { "x-forwarded-for": "1.2.3.4" },
    body: JSON.stringify({ title: "x" }),
  });
  assert.equal(r.status, 403);
});
