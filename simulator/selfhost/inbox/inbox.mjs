// Webhook inbox for the self-hosted engine (simulator/selfhost/README.md, "Webhooks").
// The engine posts its outgoing webhooks here, as it would to a billing system; the simulator
// proxy reads them back and shows a "Rev Rec → billing system: webhook" row per event.
//   POST /webhooks            the engine's webhook. The X-Webhook-Signature-512 header (hex
//                             HMAC-SHA512 of the body, keyed by the profile's
//                             payment_response_hash_key) is checked against INBOX_HASH_KEY.
//   GET  /events?payment_id=  the events of one payment, oldest first. Needs
//                             "Authorization: Bearer <INBOX_READ_TOKEN>".
//   GET  /health              open.
// It keeps the last 50 events per payment (2000 payments at most) in /data/inbox.json.
// Its log has one line per event (time, type, payment, signature check), never a body or header.
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";

const PORT = Number(process.env.INBOX_PORT || 8092);
const HASH_KEY = process.env.INBOX_HASH_KEY || "";
const READ_TOKEN = process.env.INBOX_READ_TOKEN || "";
const STORE = process.env.INBOX_STORE || "/data/inbox.json";
const PER_PAYMENT = 50;
const MAX_PAYMENTS = 2000;
const MAX_BODY = 1_000_000;

if (!READ_TOKEN) {
  console.error("inbox: set INBOX_READ_TOKEN");
  process.exit(1);
}

// payment id -> events, oldest first. A Map keeps insertion order, so the oldest payment is first.
const events = new Map();
try {
  for (const [id, list] of JSON.parse(fs.readFileSync(STORE, "utf8")))
    events.set(id, list);
} catch {
  // No events yet.
}

let saveTimer = null;
function saveSoon() {
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    try {
      fs.writeFileSync(`${STORE}.tmp`, JSON.stringify([...events]));
      fs.renameSync(`${STORE}.tmp`, STORE);
    } catch (e) {
      console.error(`inbox: could not save: ${e.code ?? e.message}`);
    }
  }, 500);
}

const same = (a, b) => {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && crypto.timingSafeEqual(x, y);
};

// "verified": the signature matches the key; "mismatch": it does not; "unsigned": no signature
// header; "no key": the inbox has no key to check with.
export function checkSignature(raw, header, key = HASH_KEY) {
  if (!key) return "no key";
  if (!header) return "unsigned";
  const want = crypto.createHmac("sha512", key).update(raw).digest("hex");
  return same(String(header).toLowerCase(), want) ? "verified" : "mismatch";
}

// What the proxy shows of an event. The payment object is cut to the fields a row needs.
export function summarize(body, signature, receivedAt) {
  const o = body?.content?.object ?? {};
  const attempts = Array.isArray(o.attempts) ? o.attempts : [];
  return {
    eventId: String(body?.event_id ?? ""),
    eventType: String(body?.event_type ?? "unknown"),
    contentType: String(body?.content?.type ?? ""),
    timestamp: body?.timestamp ?? null,
    receivedAt,
    signature,
    payment: {
      id: o.id ?? null,
      status: o.status ?? null,
      merchantReferenceId: o.merchant_reference_id ?? null,
      amount: o.amount?.order_amount ?? o.amount ?? null,
      amountCaptured: o.amount?.amount_captured ?? null,
      currency: o.amount?.currency ?? o.currency ?? null,
      attemptCount: attempts.length || null,
      error: o.error
        ? { code: o.error.code ?? null, message: o.error.message ?? null }
        : null,
    },
  };
}

function store(e) {
  const id = e.payment.id ?? "unknown";
  const list = events.get(id) ?? [];
  if (e.eventId && list.some((x) => x.eventId === e.eventId)) return; // a retried delivery
  list.push(e);
  events.delete(id);
  events.set(id, list.slice(-PER_PAYMENT));
  while (events.size > MAX_PAYMENTS) events.delete(events.keys().next().value);
  saveSoon();
}

const send = (res, status, body) => {
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
  });
  res.end(JSON.stringify(body));
};

export function createInbox() {
  return http.createServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://inbox");
    if (req.method === "GET" && url.pathname === "/health")
      return send(res, 200, { ok: true, payments: events.size });
    if (req.method === "POST" && url.pathname === "/webhooks") {
      const chunks = [];
      let size = 0;
      req.on("data", (c) => {
        size += c.length;
        if (size > MAX_BODY) req.destroy();
        else chunks.push(c);
      });
      req.on("end", () => {
        const raw = Buffer.concat(chunks).toString("utf8");
        let body;
        try {
          body = JSON.parse(raw);
        } catch {
          return send(res, 400, { error: "body is not JSON" });
        }
        const signature = checkSignature(
          raw,
          req.headers["x-webhook-signature-512"],
        );
        const e = summarize(body, signature, new Date().toISOString());
        store(e);
        console.log(
          `${e.receivedAt} ${e.eventType} ${e.payment.id ?? "-"} signature ${signature}`,
        );
        // 200 even for a bad signature: the engine would only retry, and the row says "mismatch".
        send(res, 200, { received: true });
      });
      return;
    }
    if (req.method === "GET" && url.pathname === "/events") {
      const auth = String(req.headers.authorization ?? "");
      if (!same(auth, `Bearer ${READ_TOKEN}`))
        return send(res, 401, { error: "a read token is needed" });
      const id = url.searchParams.get("payment_id") ?? "";
      return send(res, 200, { paymentId: id, events: events.get(id) ?? [] });
    }
    send(res, 404, { error: "not found" });
  });
}

if (import.meta.url === `file://${process.argv[1]}`)
  createInbox().listen(PORT, "0.0.0.0", () =>
    console.log(
      `inbox: listening on ${PORT}; signature check ${HASH_KEY ? "on" : "off (no INBOX_HASH_KEY)"}`,
    ),
  );
