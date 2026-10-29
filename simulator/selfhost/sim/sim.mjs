// The "sim" service for the self-hosted engine (MODEL.md, "Limits on our engine"). It runs next to
// the engine and reads its tables:
//   - Simulated calendar: each retry Rev Rec's model plans (days ahead) for an invoice on the
//     model's A/B arm, on any profile, is moved to its demo time after its real-life slot is fixed
//     (calendar.mjs). A slot past the grace window ends the invoice there. The grace is the billing
//     connector's, or the story's own: Stripe customer metadata "sim_grace_days".
//   - Learning re-file: the engine files each outcome under the attempt's demo time. This service
//     keeps every stats document at the seed plus each outcome since the last reset, at its
//     real-life slot (refile.mjs), written through the engine's admin route (the engine's lock).
//   GET  /health                    open.
//   GET  /calendar?payment_id=      the invoice's retries: engine pick, real-life slot, demo time.
//   GET  /stats                     the seed and the current documents.
//   GET  /check[?slots=demo]        do the documents equal the seed plus the outcomes? slots=demo
//                                   files outcomes at their demo time, as the engine does: with
//                                   SIM_REFILE=off it checks that this service reads outcomes right.
//   POST /reset                     back to the seed: clears outcomes and unseeded clusters.
// All but /health need "Authorization: Bearer <SIM_TOKEN>".
//   - The bank (bank.mjs), on SIM_BANK_PORT (8095, compose network only): the engine's Stripe calls
//     come here (config.toml stripe.base_url) and go on to Stripe byte for byte. Only Rev Rec's
//     charges for invoices the proxy marks (Stripe customer metadata "sim_bank") are decided here,
//     by the charge's real-life slot. SIM_BANK=off passes everything through.
// The log has one line per action, never a secret, body or header.
import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import pg from "pg";
import crypto from "node:crypto";
import {
  applyReplacements,
  cybersourceHeaders,
  decide,
  parseRule,
  parseStory,
  PROCESSOR_UPSTREAMS,
  replacementsFor,
  rewriteCharge,
  storyMatches,
  withOwnReference,
  withoutDuplicateCheck,
} from "./bank.mjs";
import { explainDecision, pickDay } from "./model.mjs";
import { createPause } from "./pause.mjs";
import {
  DAY_MS,
  DEFAULT_SECONDS_PER_DAY,
  demoTime,
  ladderSlot,
  ladderSlotAfter,
  plannedSlot,
} from "./calendar.mjs";
import {
  clusterKey,
  documentChanges,
  documentsCsv,
  expectedDocuments,
} from "./refile.mjs";

const PORT = Number(process.env.SIM_PORT || 8093);
const TOKEN = process.env.SIM_TOKEN || "";
const STORE = process.env.SIM_STORE || "/data/sim.json";
const SEED_ENV = process.env.SIM_SEED_ENV || "/state/seed.env";
const MODEL = process.env.SIM_MODEL || "/model/retry-stats.mjs";
const HS_BASE_URL = process.env.HS_BASE_URL || "http://router:8080";
const ADMIN_KEY = process.env.HS_ADMIN_API_KEY || "";
const SECONDS_PER_DAY = Number(
  process.env.SIM_SECONDS_PER_DAY || DEFAULT_SECONDS_PER_DAY,
);
// off: observe only (the engine's own filing stays), for /check?slots=demo
const REFILE = process.env.SIM_REFILE !== "off";
// A planned retry further ahead than this is the model's (the demo ladder is seconds apart)
const MODEL_AHEAD = "1 hour";
const BANK = process.env.SIM_BANK !== "off";
const BANK_PORT = Number(process.env.SIM_BANK_PORT || 8095);
// Reads the bank rules from Stripe customer metadata (test mode)
const STRIPE_KEY = process.env.STRIPE_TEST_KEY || "";
const STRIPE_HOST = "api.stripe.com";

if (!TOKEN || !ADMIN_KEY) {
  console.error("sim: set SIM_TOKEN and HS_ADMIN_API_KEY");
  process.exit(1);
}

// The demo profiles from the seed's state. The calendar follows every invoice on the model's A/B
// arm; these profiles are a fallback for invoices switched to smart mid-run: the smart profile and
// the per-story pool (POOL_PROFILE_IDS, seed.sh 8d). Read at start.
const seedEnv = Object.fromEntries(
  fs
    .readFileSync(SEED_ENV, "utf8")
    .split("\n")
    .map((line) =>
      line.match(/^(MERCHANT_ID|SMART_PROFILE_ID|POOL_PROFILE_IDS)=(.*)$/),
    )
    .filter(Boolean)
    .map(([, key, value]) => [key, value.replace(/^['"]|['"]$/g, "")]),
);
const MERCHANT_ID = seedEnv.MERCHANT_ID;
const CALENDAR_PROFILES = (
  process.env.SIM_CALENDAR_PROFILES ||
  [seedEnv.SMART_PROFILE_ID, seedEnv.POOL_PROFILE_IDS].filter(Boolean).join(",")
)
  .split(",")
  .filter(Boolean);
if (!MERCHANT_ID || !CALENDAR_PROFILES.length) {
  console.error(`sim: no MERCHANT_ID or SMART_PROFILE_ID in ${SEED_ENV}`);
  process.exit(1);
}

const { statsDocument, SEEDED, slotChance, REASON_CLUSTER } = await import(
  MODEL
);
const seedDocs = new Map(
  SEEDED.map((code) => [clusterKey(code), statsDocument(code)]),
);

// The engine stores UTC in "timestamp without time zone" columns
pg.types.setTypeParser(1114, (text) =>
  Date.parse(`${text.replace(" ", "T")}Z`),
);
const db = new pg.Pool({ max: 4 });
const sqlTime = (ms) =>
  new Date(ms).toISOString().replace("T", " ").slice(0, -1);
const iso = (ms) => new Date(ms).toISOString();

// resetAt (ms), the calendar: payment id -> [{ n, enginePick, decidedAt, slot, demoAt, stopped }],
// and the bank's answers: payment id -> [{ n, slot, works }]
let state = { resetAt: null, calendar: {}, bank: {}, rules: {} };
// The stories the proxy registered at processors other than Stripe: processor|invoice id ->
// { story, at } (a token can belong to several stories: Worldpay gives a card saved again its token).
// In memory only: a story holds processor tokens, which are never stored. After a restart the
// proxy registers the open ones again. Only each story's rule is saved (state.rules, by invoice
// id; no tokens), so an ended story keeps its real-life clock for the re-file.
const stories = new Map();
// The processors whose engine traffic comes through here now (config.toml base_url)
const BANK_PROCESSORS = (process.env.SIM_BANK_PROCESSORS || "")
  .split(",")
  .map((id) => id.trim())
  .filter((id) => PROCESSOR_UPSTREAMS[id] !== undefined);
// Cybersource's signing keys (the VM's .env; never logged)
const CYBERSOURCE = {
  keyId: process.env.CYBERSOURCE_API_KEY || "",
  secret: process.env.CYBERSOURCE_API_SECRET || "",
};
try {
  state = { ...state, ...JSON.parse(fs.readFileSync(STORE, "utf8")) };
} catch {
  // First start: reset below.
}
const save = () => fs.writeFileSync(STORE, JSON.stringify(state));
// Pause for one invoice (A, pause.mjs): Rev Rec's next retry waits; the calendar skips it meanwhile
const pauses = createPause({ db, state, save });

// ---- Reading the engine

// GSM rows of the payment flow: connector|code|message -> standardised code
async function gsmCodes() {
  const { rows } = await db.query(
    `select connector, code, message, standardised_code from gateway_status_map
     where flow = 'Payment' and sub_flow = 'Authorize' and standardised_code is not null`,
  );
  return new Map(
    rows.map((r) => [
      `${r.connector}|${r.code}|${r.message}`,
      r.standardised_code,
    ]),
  );
}

// An attempt's standardised code, as the engine resolves it. Rev Rec's own attempts store it; the
// billing system's reported attempt gets it from GSM when the webhook arrives: first by the card
// network and issuer code, then by Stripe's code and message (core/payments/helpers.rs get_gsm_record).
function attemptCode(a, gsm) {
  const stored = a.error_details?.unified_details?.standardised_code;
  if (a.triggered_by === "internal") return stored ?? null;
  const issuer = a.error_details?.issuer_details?.code;
  const byIssuer =
    a.card_network && issuer
      ? `Network:${a.card_network}|IssuerCode:${String(issuer).padStart(2, "0")}`
      : null;
  return (
    (byIssuer && gsm.get(`${a.connector}|${byIssuer}|${byIssuer}`)) ??
    gsm.get(`${a.connector}|${a.error_code}|${a.error_message}`) ??
    null
  );
}

const ATTEMPTS = `
  select pa.payment_id, pa.id, pa.status, pa.created_at, pa.connector, pa.error_code,
         pa.error_message, pa.error_details,
         pa.connector_request_reference_id as reference,
         pa.feature_metadata->'revenue_recovery'->>'attempt_triggered_by' as triggered_by,
         pi.feature_metadata->'payment_revenue_recovery_metadata'
           ->'billing_connector_payment_method_details'->'value'->>'card_network' as card_network,
         pi.feature_metadata->'payment_revenue_recovery_metadata'
           ->'billing_connector_payment_details'->>'connector_customer_id' as stripe_customer,
         (mca.feature_metadata->'revenue_recovery'->>'billing_connector_retry_threshold')::int
           as start_threshold
  from payment_attempt pa join payment_intent pi on pi.id = pa.payment_id
  left join merchant_connector_account mca
    on mca.id = pi.feature_metadata->'payment_revenue_recovery_metadata'->>'billing_connector_id'`;

// Rev Rec's retries of one payment, oldest first, each with the cluster it tried to beat. That is
// the engine's prev_attempt_error_code: the code of the report that started Rev Rec (the
// threshold-th report, at least the 1st; later reports leave the task as it is, core/
// revenue_recovery.rs upsert_calculate_pcr_task), then the code of each of Rev Rec's own failures.
function retriesOf(attempts, gsm) {
  const startReport = Math.max(1, attempts[0]?.start_threshold ?? 0);
  let reports = 0;
  let lastCode = null;
  const out = [];
  for (const a of attempts) {
    if (a.triggered_by === "internal") {
      out.push({
        n: out.length + 1,
        attempt: a,
        cluster: clusterKey(lastCode),
      });
      if (a.status === "failure") lastCode = attemptCode(a, gsm);
    } else if (++reports === startReport) lastCode = attemptCode(a, gsm);
  }
  // The cluster the next retry tries to beat, and the retries the engine counts as used
  out.next = { cluster: clusterKey(lastCode), used: startReport + out.length };
  return out;
}

// The invoice's demo clock starts at its first failure (the billing system's report)
const failureOf = (attempts) => attempts[0]?.created_at ?? null;
// The engine plans retry n right after retry n-1 failed (or after the report, for retry 1)
const decidedAt = (task, attempts) =>
  Math.max(task.updated_at ?? 0, attempts.at(-1)?.created_at ?? 0) ||
  Date.now();

// ---- Bank rules (bank.mjs): from the Stripe customer's metadata, read once per customer

const customerRules = new Map(); // customer id -> rule or null
const customerGrace = new Map(); // customer id -> grace days on the simulated calendar, or null
const goodCards = new Map(); // customer id -> the saved card that works (4242)
async function stripeGet(path) {
  const res = await fetch(`https://${STRIPE_HOST}/v1/${path}`, {
    headers: { Authorization: `Bearer ${STRIPE_KEY}` },
  });
  if (!res.ok)
    throw new Error(`Stripe ${path.split("/")[0]}: HTTP ${res.status}`);
  return res.json();
}
// fresh: read Stripe again (the bank does, for every charge, so a changed rule applies at once)
async function ruleOf(customerId, { fresh = false } = {}) {
  // Only Stripe's customers carry a rule; a story at another processor has its own customer id
  if (!STRIPE_KEY || !String(customerId ?? "").startsWith("cus_")) return null;
  if (fresh || !customerRules.has(customerId)) {
    const customer = await stripeGet(`customers/${customerId}`);
    customerRules.set(customerId, parseRule(customer.metadata?.sim_bank));
    const grace = Number.parseInt(customer.metadata?.sim_grace_days ?? "", 10);
    customerGrace.set(customerId, grace >= 1 && grace <= 60 ? grace : null);
  }
  return customerRules.get(customerId);
}
const cardDigits = new Map(); // payment method id -> last 4 digits (they never change)
async function cardLast4(paymentMethodId) {
  if (!paymentMethodId) return null;
  if (!cardDigits.has(paymentMethodId))
    cardDigits.set(
      paymentMethodId,
      (await stripeGet(`payment_methods/${paymentMethodId}`)).card?.last4 ??
        null,
    );
  return cardDigits.get(paymentMethodId);
}
async function goodCardOf(customerId) {
  if (!goodCards.has(customerId)) {
    const { data } = await stripeGet(
      `customers/${customerId}/payment_methods?type=card&limit=20`,
    );
    goodCards.set(customerId, data.find((pm) => pm.card?.last4 === "4242")?.id);
  }
  return goodCards.get(customerId);
}

// The rule of a story the proxy registered for an invoice (processors other than Stripe), or null
const storedRule = (invoiceId) =>
  [...stories.values()].find(({ story }) => story.invoiceId === invoiceId)
    ?.story.rule ??
  state.rules?.[invoiceId] ??
  null;

// The invoice's real-life clock: from the story's failure moment when its rule sets one, else
// from the real failure
async function originOf(attempts) {
  const rule =
    storedRule(attempts[0]?.reference) ??
    (await ruleOf(attempts[0]?.stripe_customer));
  return rule?.failureAt ? Date.parse(rule.failureAt) : failureOf(attempts);
}

// Real-life slot of Rev Rec's retry n of a payment: its calendar slot, or the ladder's
function realLifeSlot(paymentId, originMs, n) {
  const planned = state.calendar[paymentId]?.find((d) => d.n === n);
  if (planned) return planned.slot;
  // A ladder retry after model picks continues from the previous retry, not from the failure
  return ladderSlotAfter(
    originMs,
    n,
    n > 1 ? realLifeSlot(paymentId, originMs, n - 1) : null,
  );
}

// Each of Rev Rec's finished retries since the reset: the cluster it tried to beat (the code of
// the attempt before it), whether it worked, and its real-life and demo slots.
async function outcomes() {
  const gsm = await gsmCodes();
  const { rows } = await db.query(
    `${ATTEMPTS}
     where pa.payment_id in (
       select payment_id from payment_attempt
       where merchant_id = $1 and created_at >= $2::timestamp
         and feature_metadata->'revenue_recovery'->>'attempt_triggered_by' = 'internal')
     order by pa.payment_id, pa.created_at`,
    [MERCHANT_ID, sqlTime(state.resetAt)],
  );
  const out = [];
  for (const [paymentId, attempts] of Map.groupBy(rows, (r) => r.payment_id)) {
    const originMs = await originOf(attempts);
    for (const { n, attempt: a, cluster } of retriesOf(attempts, gsm)) {
      const success = ["charged", "partial_charged"].includes(a.status);
      if (a.created_at >= state.resetAt && (success || a.status === "failure"))
        out.push({
          paymentId,
          attemptId: a.id,
          n,
          cluster,
          success,
          demoMs: a.created_at,
          slotMs: realLifeSlot(paymentId, originMs, n),
        });
    }
  }
  return out;
}

async function currentDocuments() {
  const { rows } = await db.query(
    "select cluster_key, stats from revenue_recovery_retry_stats",
  );
  return new Map(rows.map((r) => [r.cluster_key, r.stats]));
}

// ---- Writing

// Whole documents through the engine's admin route, which takes the engine's per-cluster lock
async function writeDocuments(docs) {
  if (!docs.length) return;
  const form = new FormData();
  form.append(
    "file",
    new Blob([documentsCsv(docs)], { type: "text/csv" }),
    "retry-stats.csv",
  );
  const res = await fetch(
    `${HS_BASE_URL}/v2/recovery/data-backfill/retry-stats`,
    {
      method: "POST",
      headers: { Authorization: `admin-api-key=${ADMIN_KEY}` },
      body: form,
    },
  );
  const body = await res.json().catch(() => ({}));
  if (
    !res.ok ||
    body.failed_records !== 0 ||
    body.processed_records !== docs.length
  )
    throw new Error(
      `stats upload: HTTP ${res.status}, ${body.processed_records ?? "?"} written, ${body.failed_records ?? "?"} failed`,
    );
}

async function removeDocuments(keys) {
  if (!keys.length) return;
  await db.query(
    "delete from revenue_recovery_retry_stats where cluster_key = any($1::text[])",
    [keys],
  );
}

// ---- Simulated calendar

async function calendarTick() {
  const { rows: tasks } = await db.query(
    `select pt.id, pt.tracking_data->>'global_payment_id' as payment_id,
            pt.tracking_data->>'billing_mca_id' as billing_mca_id,
            pt.schedule_time, pt.schedule_time::text as schedule_text, pt.updated_at
     from process_tracker pt
     join payment_intent pi on pi.id = pt.tracking_data->>'global_payment_id'
     where pt.name = 'EXECUTE_WORKFLOW' and pt.status in ('new', 'pending')
       and pt.schedule_time > (now() at time zone 'utc') + interval '${MODEL_AHEAD}'
       and (pi.feature_metadata->'payment_revenue_recovery_metadata'
              ->>'revenue_recovery_ab_routing' is not null
            or pt.tracking_data->>'profile_id' = any($1::text[]))`,
    [CALENDAR_PROFILES],
  );
  for (const task of tasks) {
    const { rows: attempts } = await db.query(
      `${ATTEMPTS} where pa.payment_id = $1 order by pa.created_at`,
      [task.payment_id],
    );
    const { rows: limits } = await db.query(
      `select (mca.feature_metadata->'revenue_recovery'->>'grace_period_days')::int as grace_days,
              (mca.feature_metadata->'revenue_recovery'->>'max_retry_count')::int as max_retries,
              pi.feature_metadata->'payment_revenue_recovery_metadata'
                ->>'invoice_billing_started_at_time' as billing_start
       from merchant_connector_account mca, payment_intent pi
       where mca.id = $1 and pi.id = $2`,
      [task.billing_mca_id, task.payment_id],
    );
    const failureMs = failureOf(attempts);
    if (failureMs === null || !limits[0]) continue;
    // A story's own grace period (customer metadata sim_grace_days) beats the billing connector's
    const customer = attempts[0].stripe_customer;
    await ruleOf(customer, { fresh: true });
    const graceDays =
      storedRule(attempts[0].reference)?.graceDays ??
      customerGrace.get(customer) ??
      limits[0].grace_days;
    const originMs = await originOf(attempts);
    const n = attempts.filter((a) => a.triggered_by === "internal").length + 1;
    const plans = (state.calendar[task.payment_id] ??= []);
    const placed = plans.find((d) => d.n === n);
    if (placed) {
      // The engine planned the same retry again: keep its first slot and demo time (not while paused:
      // pause.mjs holds that retry years ahead until resume)
      if (!placed.stopped && !pauses.isPaused(task.payment_id))
        await db.query(
          `update process_tracker set schedule_time = $2::timestamp
           where id = $1 and schedule_time = $3::timestamp and status in ('new', 'pending')`,
          [
            task.id,
            sqlTime(Math.max(Date.now() + 1000, Date.parse(placed.demoAt))),
            task.schedule_text,
          ],
        );
      continue;
    }

    // A story's own failure moment shifts the whole calendar, its grace window too
    const shiftMs = originMs - failureMs;
    const decidedAtMs = decidedAt(task, attempts);
    const engineGraceEndMs =
      Date.parse(`${limits[0].billing_start.replace(" ", "T")}Z`) +
      limits[0].grace_days * DAY_MS;
    const graceEndMs =
      Date.parse(`${limits[0].billing_start.replace(" ", "T")}Z`) +
      shiftMs +
      graceDays * DAY_MS;
    const { next } = retriesOf(attempts, await gsmCodes());
    const doc = (await currentDocuments()).get(next.cluster);
    const budget = Math.max(0, limits[0].max_retries - next.used);
    // Decision 1 is the engine's exact pick. A later pick (and a story's shifted calendar) is
    // re-computed the way the engine would make it on the day of the last try: window = tomorrow
    // to the grace end, the same counts, the engine's hour (model.mjs pickDay; decided 27 Oct).
    const recomputed = n > 1 || shiftMs !== 0;
    const lastSlotMs =
      n > 1 ? realLifeSlot(task.payment_id, originMs, n - 1) : originMs;
    const timeOfDay =
      task.schedule_time - Math.floor(task.schedule_time / DAY_MS) * DAY_MS;
    let slot = task.schedule_time;
    if (recomputed && doc) {
      const picked = pickDay(doc, { todayMs: lastSlotMs, graceEndMs, budget });
      // No future day left inside grace: the engine would decline and stop at the grace end
      slot = picked ? picked.dayMs + timeOfDay : graceEndMs;
    } else if (recomputed)
      slot = plannedSlot({
        enginePickMs: task.schedule_time,
        decidedAtMs,
        lastSlotMs,
      });
    const stopped = slot >= graceEndMs ? "grace" : null;
    const demoRaw =
      demoTime(originMs, slot, SECONDS_PER_DAY) -
      shiftMs +
      (state.pausedMs?.[task.payment_id] ?? 0);
    const demoAt = Math.max(Date.now() + 1000, demoRaw);
    // Paused (pause.mjs): the planned retry waits years ahead, with the time it has from the pause on
    const { rowCount } =
      pauses.isPaused(task.payment_id) && !stopped
        ? {
            rowCount: (await pauses.holdPlanned(
              task.payment_id,
              task.id,
              task.schedule_text,
              demoRaw,
            ))
              ? 1
              : 0,
          }
        : stopped
          ? await db.query(
              `update process_tracker set status = 'finish', business_status = 'SIM_GRACE_OVER'
           where id = $1 and schedule_time = $2::timestamp and status in ('new', 'pending')`,
              [task.id, task.schedule_text],
            )
          : await db.query(
              `update process_tracker set schedule_time = $2::timestamp
           where id = $1 and schedule_time = $3::timestamp and status in ('new', 'pending')`,
              [task.id, sqlTime(demoAt), task.schedule_text],
            );
    if (!rowCount) continue; // the engine changed the task meanwhile: the next tick sees it again
    plans.push({
      n,
      // "engine": the engine's own pick; "re-computed": re-made on the simulated calendar
      source: recomputed ? "re-computed" : "engine",
      cluster: next.cluster,
      enginePick: iso(task.schedule_time),
      decidedAt: iso(decidedAtMs),
      slot,
      demoAt: stopped ? null : iso(demoAt),
      stopped,
      // The decision in plain numbers, from the same counts (model.mjs)
      model:
        doc && !stopped
          ? explainDecision(
              doc,
              recomputed
                ? { decidedAtMs: lastSlotMs, graceEndMs, budget, pickMs: slot }
                : {
                    decidedAtMs,
                    graceEndMs: engineGraceEndMs,
                    budget,
                    pickMs: task.schedule_time,
                  },
            )
          : null,
    });
    save();
    console.log(
      `calendar: ${task.payment_id} retry ${n}: engine ${iso(task.schedule_time)} -> ${recomputed ? "re-computed" : "real life"} ${iso(slot)} -> ${stopped ? "past the grace window, ended" : `demo ${iso(demoAt)}`}`,
    );
  }
}

// ---- Re-file

let lastSync = null;
async function sync({ slots = "real", write = REFILE } = {}) {
  const found = await outcomes();
  const expected = expectedDocuments(
    seedDocs,
    found.map((o) => ({
      ...o,
      slotMs: slots === "demo" ? o.demoMs : o.slotMs,
    })),
  );
  const changes = documentChanges(expected, await currentDocuments());
  if (write) {
    await writeDocuments(changes.write);
    await removeDocuments(changes.remove);
    if (changes.write.length || changes.remove.length)
      console.log(
        `re-file: ${found.length} outcomes since the reset; wrote ${changes.write.map(([k]) => k).join(" ") || "none"}; removed ${changes.remove.join(" ") || "none"}`,
      );
    lastSync = { at: iso(Date.now()), outcomes: found.length };
  }
  return { found, changes };
}

async function reset() {
  await pauses.resumeAll();
  state.resetAt = Date.now();
  save();
  const changes = documentChanges(seedDocs, await currentDocuments());
  await writeDocuments(changes.write);
  await removeDocuments(changes.remove);
  console.log(
    `reset: seed written (${changes.write.length} changed), removed ${changes.remove.join(" ") || "none"}`,
  );
}

// ---- Loops: the calendar and the re-file, every second

function every(ms, name, fn) {
  let running = false;
  let lastError = null; // logged once until it changes
  setInterval(async () => {
    if (running) return;
    running = true;
    try {
      await fn();
      lastError = null;
    } catch (e) {
      if (e.message !== lastError) console.error(`${name}: ${e.message}`);
      lastError = e.message;
    } finally {
      running = false;
    }
  }, ms);
}

// ---- The bank: the engine's Stripe calls come here and go on to Stripe

// Byte for byte, both ways (the response is piped raw, never decoded). target: the processor's
// URL to send to (Stripe: https://api.stripe.com + the request's path).
function forward(
  req,
  res,
  body,
  target = new URL(req.url, `https://${STRIPE_HOST}`),
) {
  const headers = { ...req.headers, host: target.host };
  delete headers.connection;
  delete headers["transfer-encoding"];
  if (req.method !== "GET" && req.method !== "HEAD")
    headers["content-length"] = String(body.length);
  const upstream = https.request(
    {
      host: target.hostname,
      port: target.port || 443,
      method: req.method,
      path: target.pathname + target.search,
      headers,
    },
    (up) => {
      res.writeHead(up.statusCode, up.headers);
      up.pipe(res);
    },
  );
  upstream.on("error", (e) => {
    console.error(
      `bank: ${target.hostname} unreachable (${e.code ?? e.message})`,
    );
    if (!res.headersSent) res.writeHead(502);
    res.end();
  });
  upstream.end(body);
}

// Rev Rec's charge for a marked invoice: the charge to send instead, or null to pass it through
async function bankCharge(params) {
  const customer = params.get("customer");
  const invoice = params.get("metadata[order_id]");
  if (!customer || !invoice) return null;
  const rule = await ruleOf(customer, { fresh: true });
  if (!rule) return null;
  // Only the saved card the rule is about (0341 unless the rule says): a card the customer adds
  // later is another card, and Stripe answers for it
  const card = await cardLast4(params.get("payment_method"));
  if (card !== (rule.card ?? "0341")) return null;
  const judged = await judge(invoice, rule);
  if (!judged) return null;
  const { works, decline } = judged;
  const goodCard = works
    ? (rule.goodCard ?? (await goodCardOf(customer)))
    : null;
  if (works && !goodCard)
    throw new Error(`${invoice}: no saved 4242 card on the customer`);
  return rewriteCharge(params, { works, goodCard, decline });
}

// The bank's answer for Rev Rec's charge on an invoice: its retry n, real-life slot and the
// decision, recorded; null when the charge is not one of Rev Rec's retries
async function judge(invoice, rule, where = "") {
  // The invoice's attempts; the newest internal one is this charge (the engine stores it first)
  const { rows } = await db.query(
    `${ATTEMPTS} where pa.connector_request_reference_id = $1 and pa.merchant_id = $2
     order by pa.created_at`,
    [invoice, MERCHANT_ID],
  );
  const paymentId = rows.at(-1)?.payment_id;
  const attempts = rows.filter((a) => a.payment_id === paymentId);
  const n = attempts.filter((a) => a.triggered_by === "internal").length;
  if (!n) return null;
  const originMs = await originOf(attempts);
  const slotMs = realLifeSlot(paymentId, originMs, n);
  const { works, decline } = decide(
    rule,
    { slotMs, failureMs: originMs },
    (reason, slot) => slotChance(REASON_CLUSTER[reason], slot),
  );
  (state.bank[paymentId] ??= []).push({
    n,
    slot: slotMs,
    works,
    decline: works ? null : decline,
  });
  save();
  console.log(
    `bank: ${invoice}${where} retry ${n} real life ${iso(slotMs)} -> ${works ? "works" : `declines (${decline})`}`,
  );
  return { works, decline, n };
}

// Rev Rec's charge at another processor for a story the proxy registered: the body to send
// instead, or null to pass it through. A charge is a POST that carries the story's good token; a
// card added later is another card, and the processor answers for it.
async function processorCharge(id, text, contentType) {
  const found = [...stories.values()].filter(
    ({ story }) => story.processor === id && storyMatches(text, story),
  );
  if (found.length > 1)
    console.error(
      `bank (${id}): ${found.length} stories match one charge; passed through`,
    );
  if (found.length !== 1) return null;
  const { story } = found[0];
  const judged = await judge(story.invoiceId, story.rule, ` (${id})`);
  if (!judged || judged.works) return null;
  const replacements = replacementsFor(story, judged.decline);
  if (!replacements) return null;
  const declining = applyReplacements(text, contentType, replacements);
  // Each lost retry declines on the same profile, so Authorize.net would call it a duplicate
  if (id === "authorizedotnet") return withoutDuplicateCheck(declining);
  // Worldpay refuses a decline under a reference whose last decline had another code
  if (id === "worldpay")
    return withOwnReference(declining, `${story.invoiceId}-r${judged.n}`);
  return declining;
}

const hash = {
  sha256: (body) => crypto.createHash("sha256").update(body).digest("base64"),
  hmac: (secret, text) =>
    crypto
      .createHmac("sha256", Buffer.from(secret, "base64"))
      .update(text)
      .digest("base64"),
};

// A processor's test API: SIM_UPSTREAM_<ID>, else the known one
const upstreamOf = (id) =>
  (
    process.env[`SIM_UPSTREAM_${id.toUpperCase()}`] || PROCESSOR_UPSTREAMS[id]
  ).replace(/\/+$/, "");

const CHARGE_PATH = /^\/v1\/payment_intents(\/[^/?]+\/confirm)?(\?|$)/;
async function bankRequest(req, res) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  let body = Buffer.concat(chunks);
  // Another processor: /<connector>/<its path> goes on to its test API
  const [, id, rest] = req.url.match(/^\/([a-z0-9]+)(\/.*)?$/) ?? [];
  if (id && PROCESSOR_UPSTREAMS[id]) {
    const target = new URL(upstreamOf(id) + (rest ?? "/"));
    if (BANK && req.method === "POST")
      try {
        const charge = await processorCharge(
          id,
          body.toString(),
          req.headers["content-type"] ?? "",
        );
        if (charge) body = Buffer.from(charge);
      } catch (e) {
        console.error(`bank (${id}): ${e.message}; passed through`);
      }
    // Cybersource checks a signature over the host, path and body: sign every request again
    if (id === "cybersource" && CYBERSOURCE.keyId && CYBERSOURCE.secret)
      Object.assign(
        req.headers,
        cybersourceHeaders(
          {
            method: req.method,
            path: target.pathname + target.search,
            host: target.host,
            headers: req.headers,
            body,
            ...CYBERSOURCE,
          },
          hash,
        ),
      );
    return forward(req, res, body, target);
  }
  if (
    BANK &&
    req.method === "POST" &&
    CHARGE_PATH.test(req.url) &&
    String(req.headers["content-type"] ?? "").startsWith(
      "application/x-www-form-urlencoded",
    )
  )
    try {
      const charge = await bankCharge(new URLSearchParams(body.toString()));
      if (charge) body = Buffer.from(charge.toString());
    } catch (e) {
      console.error(`bank: ${e.message}; passed through`);
    }
  forward(req, res, body);
}

// ---- HTTP

const send = (res, status, body) => {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
};
const docsOut = (docs) =>
  [...docs].map(([cluster_key, stats]) => ({ cluster_key, stats }));

async function calendarView(paymentId) {
  const { rows: attempts } = await db.query(
    `${ATTEMPTS} where pa.payment_id = $1 order by pa.created_at`,
    [paymentId],
  );
  if (!attempts.length) return null;
  const originMs = await originOf(attempts);
  const rule = await ruleOf(attempts[0].stripe_customer);
  const retries = retriesOf(attempts, await gsmCodes()).map(
    ({ n, attempt: a, cluster }) => ({
      n,
      attemptId: a.id,
      status: a.status,
      demoAt: iso(a.created_at),
      cluster,
      realLife: iso(realLifeSlot(paymentId, originMs, n)),
      source: state.calendar[paymentId]?.some((d) => d.n === n)
        ? "calendar"
        : "ladder",
    }),
  );
  return {
    paymentId,
    failureAt: iso(failureOf(attempts)),
    realLifeFailureAt: iso(originMs),
    bank: rule && {
      reason: rule.reason,
      worksFrom: rule.worksFrom ?? null,
      draw: rule.draw ?? null,
      answers: (state.bank[paymentId] ?? []).map((b) => ({
        ...b,
        slot: iso(b.slot),
      })),
    },
    secondsPerDay: SECONDS_PER_DAY,
    plans: (state.calendar[paymentId] ?? []).map((d) => ({
      ...d,
      slot: iso(d.slot),
    })),
    retries,
  };
}

http
  .createServer(async (req, res) => {
    const url = new URL(req.url, "http://sim");
    try {
      if (req.method === "GET" && url.pathname === "/health")
        return send(res, 200, {
          ok: true,
          profiles: CALENDAR_PROFILES,
          secondsPerDay: SECONDS_PER_DAY,
          refile: REFILE ? "on" : "off",
          bank: BANK
            ? STRIPE_KEY
              ? "on"
              : "on, no STRIPE_TEST_KEY: passes through"
            : "off",
          resetAt: state.resetAt && iso(state.resetAt),
          lastSync,
        });
      if (req.headers.authorization !== `Bearer ${TOKEN}`)
        return send(res, 401, { error: "unauthorized" });
      if (req.method === "GET" && url.pathname === "/calendar") {
        const view = await calendarView(
          url.searchParams.get("payment_id") ?? "",
        );
        return view
          ? send(res, 200, view)
          : send(res, 404, { error: "no such payment" });
      }
      if (req.method === "GET" && url.pathname === "/stats")
        return send(res, 200, {
          resetAt: iso(state.resetAt),
          seed: docsOut(seedDocs),
          current: docsOut(await currentDocuments()),
        });
      if (req.method === "GET" && url.pathname === "/check") {
        const slots =
          url.searchParams.get("slots") === "demo" ? "demo" : "real";
        const { found, changes } = await sync({ slots, write: false });
        const current = await currentDocuments();
        const sums = (doc) =>
          doc
            ? ["n", "k"].map((f) => doc.hod.reduce((s, slot) => s + slot[f], 0))
            : null;
        return send(res, 200, {
          ok: !changes.write.length && !changes.remove.length,
          slots,
          outcomes: found.length,
          // [tries, successes] the documents should hold, and what they hold
          differ: changes.write.map(([key, doc]) => ({
            key,
            expected: sums(doc),
            current: sums(current.get(key)),
          })),
          extra: changes.remove,
        });
      }
      // The proxy registers a story at another processor (the interface agreed with A, 27 Oct).
      // Registering the same invoice again replaces its story (money back, stolen, outage).
      if (req.method === "POST" && url.pathname === "/bank/stories") {
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const story = parseStory(
          JSON.parse(Buffer.concat(chunks).toString() || "{}"),
        );
        if (!story)
          return send(res, 400, {
            error:
              "need v 1, processor, invoiceId, goodToken, replacements and a rule",
          });
        stories.set(`${story.processor}|${story.invoiceId}`, {
          story,
          at: iso(Date.now()),
        });
        if (
          JSON.stringify(state.rules[story.invoiceId]) !==
          JSON.stringify(story.rule)
        ) {
          state.rules[story.invoiceId] = story.rule;
          save();
        }
        return send(res, 200, {
          ok: true,
          live: BANK_PROCESSORS.includes(story.processor),
        });
      }
      if (
        req.method === "POST" &&
        (url.pathname === "/pause" || url.pathname === "/resume")
      ) {
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const { paymentId } = JSON.parse(
          Buffer.concat(chunks).toString() || "{}",
        );
        if (!paymentId) return send(res, 400, { error: "need paymentId" });
        return send(
          res,
          200,
          url.pathname === "/pause"
            ? await pauses.pause(paymentId)
            : await pauses.resume(paymentId),
        );
      }
      if (req.method === "GET" && url.pathname === "/pause")
        return send(
          res,
          200,
          pauses.view(url.searchParams.get("payment_id") ?? ""),
        );
      if (req.method === "GET" && url.pathname === "/bank/processors")
        return send(res, 200, { processors: BANK_PROCESSORS });
      if (req.method === "POST" && url.pathname === "/reset") {
        await reset();
        return send(res, 200, { ok: true, resetAt: iso(state.resetAt) });
      }
      send(res, 404, { error: "not found" });
    } catch (e) {
      console.error(`${req.method} ${url.pathname}: ${e.message}`);
      send(res, 500, { error: e.message });
    }
  })
  .listen(PORT, () => {
    console.log(
      `sim: on ${PORT}; calendar for the model's invoices (and ${CALENDAR_PROFILES.join(", ")}); ${SECONDS_PER_DAY.toFixed(1)} s per real day; re-file ${REFILE ? "on" : "off"}`,
    );
  });

http
  .createServer((req, res) =>
    bankRequest(req, res).catch((e) => {
      console.error(`bank: ${e.message}`);
      if (!res.headersSent) res.writeHead(502);
      res.end();
    }),
  )
  .listen(BANK_PORT, () =>
    console.log(
      `bank: on ${BANK_PORT}, ${BANK ? "deciding marked invoices" : "pass-through only"}`,
    ),
  );

if (state.resetAt === null) await reset();
every(1000, "calendar", calendarTick);
every(1000, "pause", () => pauses.tick());
every(1000, "re-file", () => (REFILE ? sync() : Promise.resolve()));
