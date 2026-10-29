// Stand-in for Rev Rec's retry-time decider (simulator/selfhost/README.md, "Decider"). A narrow test
// double, not a model: every Decide call gets "retry", a time DECIDER_RETRY_AFTER_SEC ahead and
// decision threshold DECIDER_THRESHOLD. The engine still picks the card; this only gives the time.
// The engine calls it only for a smart profile without the model flag (seed.sh 6c), and only for a
// saved card whose last charge failed: a card with no error code is booked at +1 min without a call
// (workflows/revenue_recovery.rs, call_decider_for_payment_processor_tokens_select_closest_time).
//   gRPC  decider.Decider/Decide   on DECIDER_GRPC_PORT, plain HTTP/2 (the engine's client is
//                                  http2-only, no TLS). proto/recovery_decider.proto, hand-coded.
//   GET   /calls?payment_id=       the calls for one payment, oldest first; /calls alone gives the
//   GET   /health                  last 20 calls. HTTP/1 on DECIDER_HTTP_PORT, for the proxy.
// It keeps the last 50 calls per payment (2000 payments at most) in DECIDER_STORE. A call holds ids,
// card network, error code and counts only; the billing address in the request is not kept.
import fs from "node:fs";
import http from "node:http";
import http2 from "node:http2";

const GRPC_PORT = Number(process.env.DECIDER_GRPC_PORT || 50051);
const HTTP_PORT = Number(process.env.DECIDER_HTTP_PORT || 8094);
const RETRY_AFTER_SEC = Number(process.env.DECIDER_RETRY_AFTER_SEC || 5);
const THRESHOLD = Number(process.env.DECIDER_THRESHOLD || 0.5);
const STORE = process.env.DECIDER_STORE || "/data/decider.json";
const PER_PAYMENT = 50;
const MAX_PAYMENTS = 2000;
const MAX_BODY = 1_000_000;
const DECIDE_PATH = "/decider.Decider/Decide";

// payment id -> calls, oldest first. A Map keeps insertion order, so the oldest payment is first.
const calls = new Map();
try {
  for (const [id, list] of JSON.parse(fs.readFileSync(STORE, "utf8")))
    calls.set(id, list);
} catch {
  // No calls yet.
}

let saveTimer = null;
function saveSoon() {
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    try {
      fs.writeFileSync(`${STORE}.tmp`, JSON.stringify([...calls]));
      fs.renameSync(`${STORE}.tmp`, STORE);
    } catch (e) {
      console.error(`decider: could not save: ${e.code ?? e.message}`);
    }
  }, 500);
}

// --- protobuf, only what DeciderRequest and DeciderResponse use ---

function readVarint(buf, pos) {
  let n = 0n;
  let shift = 0n;
  for (;;) {
    if (pos >= buf.length) throw new Error("truncated varint");
    const b = buf[pos++];
    n |= BigInt(b & 0x7f) << shift;
    if (!(b & 0x80)) return [n, pos];
    shift += 7n;
  }
}

// field number -> raw values (BigInt for varints, Buffer for the rest), in order.
export function decodeFields(buf) {
  const out = new Map();
  let pos = 0;
  while (pos < buf.length) {
    let key;
    [key, pos] = readVarint(buf, pos);
    const field = Number(key >> 3n);
    const wire = Number(key & 7n);
    let value;
    if (wire === 0) [value, pos] = readVarint(buf, pos);
    else if (wire === 1 || wire === 5) {
      const size = wire === 1 ? 8 : 4;
      value = buf.subarray(pos, pos + size);
      pos += size;
    } else if (wire === 2) {
      let len;
      [len, pos] = readVarint(buf, pos);
      value = buf.subarray(pos, pos + Number(len));
      pos += Number(len);
    } else throw new Error(`wire type ${wire} is not used by this proto`);
    if (pos > buf.length) throw new Error("truncated field");
    if (!out.has(field)) out.set(field, []);
    out.get(field).push(value);
  }
  return out;
}

const str = (f, n) => (f.get(n) ? f.get(n)[0].toString("utf8") : null);
const int = (f, n) => (f.get(n) ? Number(BigInt.asIntN(64, f.get(n)[0])) : null);
const dbl = (f, n) => (f.get(n) ? f.get(n)[0].readDoubleLE(0) : null);
function time(f, n) {
  if (!f.get(n)) return null;
  const t = decodeFields(f.get(n)[0]);
  const ms = (int(t, 1) ?? 0) * 1000 + Math.floor((int(t, 2) ?? 0) / 1e6);
  return new Date(ms).toISOString();
}

// The fields a call row needs. Billing address fields (2, 12, 13) are skipped on purpose.
export function readRequest(buf) {
  const f = decodeFields(buf);
  return {
    paymentId: str(f, 30),
    merchantId: str(f, 8),
    cardNetwork: str(f, 4),
    cardIssuer: str(f, 5),
    pgErrorCode: str(f, 17),
    firstPgErrorCode: str(f, 20),
    retryCount: int(f, 7),
    retryCountLeft: int(f, 26),
    totalRetryCountWithinNetwork: int(f, 27),
    invoiceAmount: int(f, 9),
    invoiceCurrency: str(f, 10),
    invoiceStartTime: time(f, 6),
    waitTime: time(f, 29),
    previousThreshold: dbl(f, 32),
    hourlyRetryHistoryEntries: f.get(31)?.length ?? 0,
  };
}

function varint(n) {
  let v = BigInt(n);
  const out = [];
  while (v > 127n) {
    out.push(Number(v & 0x7fn) | 0x80);
    v >>= 7n;
  }
  out.push(Number(v));
  return Buffer.from(out);
}
const tag = (field, wire) => varint((field << 3) | wire);

// DeciderResponse {retry_flag = 1; retry_time = 2 (Timestamp); decision_threshold = 3}
export function encodeResponse({ retryFlag, retryAtMs, threshold }) {
  const seconds = Math.floor(retryAtMs / 1000);
  const nanos = (retryAtMs % 1000) * 1e6;
  const ts = Buffer.concat([
    tag(1, 0),
    varint(seconds),
    ...(nanos ? [tag(2, 0), varint(nanos)] : []),
  ]);
  const d = Buffer.alloc(8);
  d.writeDoubleLE(threshold);
  return Buffer.concat([
    tag(1, 0),
    varint(retryFlag ? 1 : 0),
    tag(2, 2),
    varint(ts.length),
    ts,
    tag(3, 1),
    d,
  ]);
}

// gRPC message framing: 1 byte "compressed" flag, 4 bytes big-endian length, the message.
const frame = (msg) => {
  const head = Buffer.alloc(5);
  head.writeUInt32BE(msg.length, 1);
  return Buffer.concat([head, msg]);
};

function store(call) {
  const id = call.paymentId ?? "unknown";
  const list = calls.get(id) ?? [];
  list.push(call);
  calls.delete(id);
  calls.set(id, list.slice(-PER_PAYMENT));
  while (calls.size > MAX_PAYMENTS) calls.delete(calls.keys().next().value);
  saveSoon();
}

// The one decision: retry soon, at the fixed threshold.
export function decide(req, now = Date.now()) {
  return {
    retryFlag: true,
    retryAtMs: now + RETRY_AFTER_SEC * 1000,
    threshold: THRESHOLD,
  };
}

const grpcError = (stream, code, message) =>
  stream.respond(
    {
      ":status": 200,
      "content-type": "application/grpc",
      "grpc-status": String(code),
      "grpc-message": encodeURIComponent(message),
    },
    { endStream: true },
  );

export function createGrpcServer() {
  const server = http2.createServer();
  server.on("stream", (stream, headers) => {
    if (headers[":method"] !== "POST" || headers[":path"] !== DECIDE_PATH)
      return grpcError(stream, 12, `not served: ${headers[":path"]}`); // UNIMPLEMENTED
    const chunks = [];
    let size = 0;
    stream.on("data", (c) => {
      size += c.length;
      if (size > MAX_BODY) stream.close(http2.constants.NGHTTP2_CANCEL);
      else chunks.push(c);
    });
    stream.on("end", () => {
      const body = Buffer.concat(chunks);
      let req;
      try {
        if (body.length < 5) throw new Error("no message");
        if (body[0] !== 0) throw new Error("compressed messages are not served");
        req = readRequest(body.subarray(5, 5 + body.readUInt32BE(1)));
      } catch (e) {
        return grpcError(stream, 3, e.message); // INVALID_ARGUMENT
      }
      const at = new Date();
      const answer = decide(req, at.getTime());
      store({
        at: at.toISOString(),
        ...req,
        answer: {
          retryFlag: answer.retryFlag,
          retryTime: new Date(answer.retryAtMs).toISOString(),
          decisionThreshold: answer.threshold,
        },
      });
      console.log(
        `${at.toISOString()} decide ${req.paymentId ?? "-"} card ${req.cardNetwork ?? "-"} error ${req.pgErrorCode ?? "-"} -> retry at ${new Date(answer.retryAtMs).toISOString()}`,
      );
      stream.respond(
        { ":status": 200, "content-type": "application/grpc" },
        { waitForTrailers: true },
      );
      stream.on("wantTrailers", () =>
        stream.sendTrailers({ "grpc-status": "0", "grpc-message": "" }),
      );
      stream.end(frame(encodeResponse(answer)));
    });
  });
  server.on("sessionError", (e) =>
    console.error(`decider: session error ${e.code ?? e.message}`),
  );
  return server;
}

const send = (res, status, body) => {
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
  });
  res.end(JSON.stringify(body));
};

export function createReadServer() {
  return http.createServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://decider");
    if (req.method !== "GET") return send(res, 405, { error: "GET only" });
    if (url.pathname === "/health")
      return send(res, 200, {
        ok: true,
        payments: calls.size,
        retryAfterSec: RETRY_AFTER_SEC,
        threshold: THRESHOLD,
      });
    if (url.pathname === "/calls") {
      const id = url.searchParams.get("payment_id");
      if (id) return send(res, 200, { paymentId: id, calls: calls.get(id) ?? [] });
      const recent = [...calls.values()]
        .flat()
        .sort((a, b) => a.at.localeCompare(b.at))
        .slice(-20);
      return send(res, 200, { recent });
    }
    send(res, 404, { error: "not found" });
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  createGrpcServer().listen(GRPC_PORT, "0.0.0.0", () =>
    console.log(
      `decider: gRPC on ${GRPC_PORT}; retry after ${RETRY_AFTER_SEC} s, threshold ${THRESHOLD}`,
    ),
  );
  createReadServer().listen(HTTP_PORT, "0.0.0.0", () =>
    console.log(`decider: call log on ${HTTP_PORT}`),
  );
}
