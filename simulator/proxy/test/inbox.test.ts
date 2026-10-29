// Offline test of the VM's webhook inbox (simulator/selfhost/inbox/inbox.mjs): signature check,
// storage per payment, the read token, and a retried delivery kept once.
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import type { AddressInfo } from "node:net";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";

const KEY = "test-hash-key";
const TOKEN = "test-read-token";
process.env.INBOX_HASH_KEY = KEY;
process.env.INBOX_READ_TOKEN = TOKEN;
process.env.INBOX_STORE = path.join(
  fs.mkdtempSync(path.join(os.tmpdir(), "sim-inbox-")),
  "inbox.json",
);

// @ts-expect-error: a plain .mjs module without types
const { createInbox } = await import("../../selfhost/inbox/inbox.mjs");
const server = createInbox();
let base = "";
before(async () => {
  await new Promise<void>((ok) => server.listen(0, "127.0.0.1", ok));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});
after(() => server.close());

const webhook = (eventId: string, status: string) =>
  JSON.stringify({
    merchant_id: "m",
    event_id: eventId,
    event_type: status === "succeeded" ? "payment_succeeded" : "payment_failed",
    content: {
      type: "payment_details",
      object: {
        id: "0a_pay_1",
        status,
        amount: { order_amount: 6540, currency: "USD" },
      },
    },
    timestamp: "2026-10-27T19:00:00Z",
  });
const post = (body: string, signature?: string) =>
  fetch(`${base}/webhooks`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(signature ? { "x-webhook-signature-512": signature } : {}),
    },
    body,
  });
const sign = (body: string, key = KEY) =>
  crypto.createHmac("sha512", key).update(body).digest("hex");
const read = (token = TOKEN) =>
  fetch(`${base}/events?payment_id=0a_pay_1`, {
    headers: { authorization: `Bearer ${token}` },
  });

test("events are kept per payment, with the signature check", async () => {
  const a = webhook("evt_1", "failed");
  assert.equal((await post(a, sign(a))).status, 200);
  const b = webhook("evt_2", "succeeded");
  assert.equal((await post(b, sign(b, "wrong-key"))).status, 200);
  // The engine retries a delivery with the same event id: kept once.
  assert.equal((await post(a, sign(a))).status, 200);
  const r = await read();
  assert.equal(r.status, 200);
  const { events } = await r.json();
  assert.deepEqual(
    events.map((e: any) => [
      e.eventId,
      e.eventType,
      e.signature,
      e.payment.status,
    ]),
    [
      ["evt_1", "payment_failed", "verified", "failed"],
      ["evt_2", "payment_succeeded", "mismatch", "succeeded"],
    ],
  );
  assert.equal(events[0].payment.amount, 6540);
});

test("reads need the token; a body that is not JSON is refused", async () => {
  assert.equal((await read("wrong")).status, 401);
  assert.equal((await fetch(`${base}/events?payment_id=x`)).status, 401);
  assert.equal((await post("not json")).status, 400);
  assert.equal((await fetch(`${base}/health`)).status, 200);
});
