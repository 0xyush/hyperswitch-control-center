// Offline test of the VM's stand-in decider (simulator/selfhost/decider/decider.mjs): a real gRPC
// call over plain HTTP/2 with a hand-encoded DeciderRequest, the answer, and the call log.
import assert from "node:assert/strict";
import fs from "node:fs";
import http2 from "node:http2";
import type { AddressInfo } from "node:net";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";

process.env.DECIDER_RETRY_AFTER_SEC = "5";
process.env.DECIDER_THRESHOLD = "0.5";
process.env.DECIDER_STORE = path.join(
  fs.mkdtempSync(path.join(os.tmpdir(), "sim-decider-")),
  "decider.json",
);

// @ts-expect-error: a plain .mjs module without types
const mod = await import("../../selfhost/decider/decider.mjs");
const grpc = mod.createGrpcServer();
const read = mod.createReadServer();
let grpcUrl = "";
let readUrl = "";
before(async () => {
  await new Promise<void>((ok) => grpc.listen(0, "127.0.0.1", ok));
  await new Promise<void>((ok) => read.listen(0, "127.0.0.1", ok));
  grpcUrl = `http://127.0.0.1:${(grpc.address() as AddressInfo).port}`;
  readUrl = `http://127.0.0.1:${(read.address() as AddressInfo).port}`;
});
after(() => {
  grpc.close();
  read.close();
});

// Just enough protobuf to write a request.
const varint = (n: number | bigint) => {
  let v = BigInt(n);
  const out: number[] = [];
  while (v > 127n) {
    out.push(Number(v & 0x7fn) | 0x80);
    v >>= 7n;
  }
  out.push(Number(v));
  return Buffer.from(out);
};
const tag = (field: number, wire: number) => varint((field << 3) | wire);
const bytes = (field: number, b: Buffer) =>
  Buffer.concat([tag(field, 2), varint(b.length), b]);
const text = (field: number, s: string) => bytes(field, Buffer.from(s));
const num = (field: number, n: number) =>
  Buffer.concat([tag(field, 0), varint(n)]);
const double = (field: number, d: number) => {
  const b = Buffer.alloc(8);
  b.writeDoubleLE(d);
  return Buffer.concat([tag(field, 1), b]);
};
const stamp = (field: number, seconds: number) => bytes(field, num(1, seconds));

const request = Buffer.concat([
  text(1, "None"),
  text(4, "Visa"),
  stamp(6, 1_793_000_000),
  num(7, 2),
  text(13, "Springfield"), // billing city: not kept
  text(17, "card_declined"),
  num(26, 18),
  num(27, 20),
  stamp(29, 1_793_000_100),
  text(30, "0a_pay_test"),
  bytes(31, Buffer.concat([text(1, "2026-10-27 18:00:00.0"), num(2, 1)])),
  double(32, 0.25),
]);

function call(pathName: string, message: Buffer) {
  return new Promise<{ status: string; body: Buffer }>((resolve, reject) => {
    const client = http2.connect(grpcUrl);
    client.on("error", reject);
    const head = Buffer.alloc(5);
    head.writeUInt32BE(message.length, 1);
    const req = client.request({
      ":method": "POST",
      ":path": pathName,
      "content-type": "application/grpc",
      te: "trailers",
    });
    const chunks: Buffer[] = [];
    let status = "";
    req.on("response", (h) => {
      if (h["grpc-status"]) status = String(h["grpc-status"]);
    });
    req.on("trailers", (t) => (status = String(t["grpc-status"])));
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      client.close();
      resolve({ status, body: Buffer.concat(chunks) });
    });
    req.end(Buffer.concat([head, message]));
  });
}

test("Decide answers retry, a time 5 s ahead and threshold 0.5", async () => {
  const t0 = Date.now();
  const r = await call("/decider.Decider/Decide", request);
  assert.equal(r.status, "0");
  assert.equal(r.body[0], 0);
  const f = mod.decodeFields(r.body.subarray(5, 5 + r.body.readUInt32BE(1)));
  assert.equal(f.get(1)[0], 1n);
  const ts = mod.decodeFields(f.get(2)[0]);
  const retryAt = Number(ts.get(1)[0]) * 1000;
  assert.ok(retryAt >= Math.floor(t0 / 1000) * 1000 + 4000);
  assert.ok(retryAt <= Date.now() + 5000);
  assert.equal(f.get(3)[0].readDoubleLE(0), 0.5);
});

test("the call log keeps the request's ids and counts, not the address", async () => {
  const r = await fetch(`${readUrl}/calls?payment_id=0a_pay_test`);
  const { calls } = await r.json();
  assert.equal(calls.length, 1);
  const c = calls[0];
  assert.equal(c.paymentId, "0a_pay_test");
  assert.equal(c.cardNetwork, "Visa");
  assert.equal(c.pgErrorCode, "card_declined");
  assert.equal(c.retryCount, 2);
  assert.equal(c.retryCountLeft, 18);
  assert.equal(c.totalRetryCountWithinNetwork, 20);
  assert.equal(c.previousThreshold, 0.25);
  assert.equal(c.hourlyRetryHistoryEntries, 1);
  assert.equal(c.waitTime, new Date(1_793_000_100_000).toISOString());
  assert.equal(c.answer.retryFlag, true);
  assert.equal(c.answer.decisionThreshold, 0.5);
  assert.equal(JSON.stringify(c).includes("Springfield"), false);
});

test("other paths and bad bodies get a gRPC error", async () => {
  assert.equal((await call("/decider.Decider/Other", request)).status, "12");
  assert.equal(
    (await call("/decider.Decider/Decide", Buffer.from([0xff]))).status,
    "3",
  );
  assert.equal((await fetch(`${readUrl}/health`)).status, 200);
});

test("the story says where a booked time came from", async () => {
  const { deciderWhy, DECIDER_LABEL } = await import("../src/story.ts");
  const call = {
    at: "2026-10-27T19:00:00.000Z",
    paymentId: "0a_pay_test",
    cardNetwork: "Visa",
    pgErrorCode: "card_declined",
    answer: {
      retryFlag: true,
      retryTime: "2026-10-27T19:00:05.000Z",
      decisionThreshold: 0.5,
    },
  };
  // The engine adds up to 1 s of random delay to the decider's time.
  const asked = deciderWhy([call], "2026-10-27T19:00:05.800Z");
  assert.equal(asked.asked, true);
  assert.equal(asked.why[0].text, DECIDER_LABEL);
  assert.equal(asked.why[1].text, "The decider said: retry at 19:00:05 UTC.");
  const notAsked = deciderWhy([], "2026-10-27T19:01:00.000Z");
  assert.equal(notAsked.asked, false);
  assert.equal(notAsked.why[0].text, "No decider call for this retry.");
  assert.equal(deciderWhy(null, "2026-10-27T19:01:00.000Z").asked, null);
});
