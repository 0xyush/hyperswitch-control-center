// The billing simulator for one invoice story.
// It plays the merchant's billing system: it creates a Stripe test customer with a saved card,
// makes real failed charges, reports them to Rev Rec on the sandbox, and reads the status back.
// Rev Rec's decisions are real. Each timeline step links to its raw request (stepId), and each
// explain line says where it comes from: sandbox, recomputed or rule.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { hasDashboardToken } from "./auth.ts";
import { config } from "./config.ts";
import { redact, scrubText } from "./redact.ts";
import {
  CARDS,
  CURRENCIES,
  DECLINES,
  FIRST_CHARGE_CARDS,
  presetById,
  resolveCards,
  SAVED_CARDS,
  type CardId,
  type FirstChargeId,
  type Preset,
  type ReportAgainMode,
  type SavedCardId,
} from "./scenarios.ts";
import {
  hsApiKey,
  hsDashboard,
  shownHsHeaders,
  stripe,
  type Upstream,
} from "./upstream.ts";

export type Actor = "billing" | "revrec" | "processor" | "customer";
export type Source = "sandbox" | "recomputed" | "rule";
type Why = { text: string; source: Source };

// ok = done; declined = the processor said no; refused = the sandbox said no;
// pending = booked but not run yet; info = a note on one lifeline.
type StepStatus = "ok" | "declined" | "refused" | "pending" | "info";

// One message arrow in the sequence diagram. stepId links it to its raw call in requests[].
type StoryEvent = {
  stepId: string;
  at: string;
  from: Actor;
  to: Actor;
  label: string; // short text on the arrow
  text: string; // what happened, in a sentence, for the side drawer
  status: StepStatus;
  source: "simulator" | "sandbox";
  why: Why[];
  txnId?: string; // Stripe payment id of a charge; the view turns it into the sandbox attemptId
};

type RequestLog = {
  stepId: string;
  step: string;
  at: string;
  system: "stripe" | "sandbox";
  request: {
    method: string;
    url: string;
    headers?: Record<string, string>;
    body?: unknown;
  };
  response: { status: number; body: unknown };
  ms: number | null;
};

export type StartOptions = {
  presetId: number | null;
  amount: number; // minor units: 6540 = 65.40
  currency: string;
  savedCard: SavedCardId;
  firstCharge: FirstChargeId;
  customer: "new" | "same";
  sendDuplicateOnStart: boolean;
  reportAgainMode: ReportAgainMode;
};

export type Story = StartOptions & {
  storyId: string;
  owner: string; // hash of the visitor's IP: "same customer" means the same visitor's last customer
  invoiceId: string; // merchant_reference_id: the invoice id in the billing system
  recoveryId: string | null; // the Hyperswitch payment id Rev Rec gave the invoice
  startedAt: string;
  stripeCustomerId: string;
  savedPm: string; // the saved card's Stripe payment method, which Rev Rec retries
  started: boolean; // the billing system's start steps have finished
  lastFailureBody: unknown | null; // re-sent as-is for a duplicate report
  reportsSent: number;
  startRule: number | null; // billing_connector_retry_threshold when the story started, if known
  paidInAppAt: string | null;
  error: string | null;
  stepSeq: number;
  events: StoryEvent[];
  requests: RequestLog[];
  seenSchedules: string[]; // retry times already shown as "pick retry time" steps
  stageSeen: Record<string, string>; // first time the proxy saw each stage
  finalNoted: boolean;
};

const ERROR_CODES: Record<number, string> = {
  400: "bad_request",
  404: "not_found",
  409: "not_available",
  413: "bad_request",
  429: "rate_limited",
  502: "upstream",
};

// An error with the HTTP status and a short code for the dashboard: {error: {code, message}}.
export class HttpError extends Error {
  status: number;
  code: string;
  storyId?: string;
  constructor(
    status: number,
    message: string,
    storyId?: string,
    code?: string,
  ) {
    super(message);
    this.status = status;
    this.code = code ?? ERROR_CODES[status] ?? "internal";
    this.storyId = storyId;
  }
}

// Safety cap on the billing system's own failed charges at start (start rule + 1).
const MAX_START_FAILURES = 4;

const nowIso = () => new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
const hms = (iso: string) => iso.slice(11, 19);
const SYMBOLS: Record<string, string> = { USD: "$", EUR: "€", GBP: "£" };
const money = (minor: number, currency: string) =>
  `${SYMBOLS[currency] ?? ""}${(minor / 100).toFixed(2)}${SYMBOLS[currency] ? "" : ` ${currency}`}`;

// ---------- store (in memory, saved to data/stories-v2.json so a restart keeps the stories) ----------

const STORE_FILE = path.join(config.dataDir, "stories-v2.json");
const stories = new Map<string, Story>();
const MAX_STORIES = 300;

try {
  const saved = JSON.parse(fs.readFileSync(STORE_FILE, "utf8")) as Story[];
  for (const s of saved) {
    // A restart in the middle of a start stops its background steps for good.
    if (!s.started && !s.error)
      s.error = "The proxy restarted while this story was starting.";
    stories.set(s.storyId, s);
  }
} catch {
  // No saved stories yet.
}

function save() {
  const all = [...stories.values()].slice(-MAX_STORIES);
  fs.mkdirSync(config.dataDir, { recursive: true });
  const tmp = `${STORE_FILE}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(all, null, 2));
  fs.renameSync(tmp, STORE_FILE);
}

export function getStory(storyId: string): Story {
  const s = stories.get(storyId);
  if (!s) throw new HttpError(404, `story ${storyId} not found`);
  return s;
}

export function listStories() {
  return [...stories.values()]
    .reverse()
    .slice(0, 50)
    .map((s) => ({
      storyId: s.storyId,
      preset: s.presetId,
      invoiceId: s.invoiceId,
      recoveryId: s.recoveryId,
      startedAt: s.startedAt,
      error: s.error,
    }));
}

// One action at a time per story, so a double click cannot make two real charges.
const locks = new Map<string, Promise<unknown>>();
function withLock<T>(storyId: string, fn: () => Promise<T>): Promise<T> {
  const prev = locks.get(storyId) ?? Promise.resolve();
  const next = prev.catch(() => {}).then(fn);
  locks.set(storyId, next);
  next
    .finally(() => locks.get(storyId) === next && locks.delete(storyId))
    .catch(() => {});
  return next;
}

// ---------- logged calls (each one is a step the dashboard can open) ----------

function newStepId(story: Story) {
  story.stepSeq += 1;
  return `s${story.stepSeq}`;
}

function summarizeStripe(json: any): unknown {
  if (!json || typeof json !== "object") return json;
  if (json.error) {
    const e = json.error;
    return {
      error: {
        type: e.type,
        code: e.code,
        decline_code: e.decline_code,
        message: e.message,
        payment_intent: e.payment_intent
          ? { id: e.payment_intent.id, status: e.payment_intent.status }
          : undefined,
      },
    };
  }
  if (json.object === "customer")
    return { id: json.id, object: json.object, name: json.name };
  if (json.object === "payment_method")
    return {
      id: json.id,
      object: json.object,
      customer: json.customer,
      card: { brand: json.card?.brand, last4: json.card?.last4 },
    };
  if (json.object === "payment_intent")
    return {
      id: json.id,
      object: json.object,
      status: json.status,
      amount: json.amount,
      currency: json.currency,
    };
  return { id: json.id, object: json.object };
}

async function stripeStep(
  story: Story,
  step: string,
  pathname: string,
  params: Record<string, string>,
) {
  const r = await stripe("POST", pathname, params);
  const stepId = newStepId(story);
  story.requests.push({
    stepId,
    step,
    at: nowIso(),
    system: "stripe",
    request: {
      method: "POST",
      url: `https://api.stripe.com/v1/${pathname}`,
      headers: { Authorization: "Bearer <hidden by proxy>" },
      body: params,
    },
    response: { status: r.status, body: summarizeStripe(r.json) },
    ms: r.ms,
  });
  return { r, stepId };
}

async function sandboxStep(
  story: Story,
  step: string,
  body: unknown,
  path = config.hsRecoveryPath,
) {
  const r = await hsApiKey("POST", path, body);
  const stepId = newStepId(story);
  story.requests.push({
    stepId,
    step,
    at: nowIso(),
    system: "sandbox",
    request: {
      method: "POST",
      url: `${config.hsBaseUrl}/${path}`,
      headers: shownHsHeaders("api-key"),
      body: redact(body),
    },
    response: { status: r.status, body: redact(r.json) },
    ms: r.ms,
  });
  return { r, stepId };
}

function event(story: Story, e: Omit<StoryEvent, "at"> & { at?: string }) {
  story.events.push({ at: nowIso(), ...e });
}

const stripeError = (r: Upstream) =>
  r.json?.error?.message ?? `HTTP ${r.status}`;

// ---------- the billing system's actions ----------

async function saveCard(story: Story, card: SavedCardId, who: Actor) {
  const c = CARDS[card];
  const { r, stepId } = await stripeStep(
    story,
    `Save card ${c.last4} at Stripe`,
    `payment_methods/${c.pm}/attach`,
    { customer: story.stripeCustomerId },
  );
  if (!r.json?.id)
    throw new HttpError(
      502,
      `Stripe could not save card ${c.last4}: ${stripeError(r)}`,
      story.storyId,
    );
  event(story, {
    stepId,
    from: who,
    to: "processor",
    label:
      who === "customer"
        ? `add card ••${c.last4} in the app`
        : `save card ••${c.last4}`,
    text: `Card ending ${c.last4} is saved for the customer at Stripe (${r.json.id}). Rev Rec retries the saved card.`,
    status: "ok",
    source: "simulator",
    why: [{ source: "rule", text: c.behaviour }],
  });
  return r.json.id as string;
}

// A real off-session charge that Stripe declines: the billing system's own monthly charge (MIT).
// suffix goes after the amount on the arrow: "" for the first charge, " again (2 of 3)" for a retry.
async function failingCharge(story: Story, step: string, suffix: string) {
  const first = CARDS[story.firstCharge];
  // 0341 as both cards: charge the saved card itself. The other first-charge cards are charged
  // one-off from their test token, because Stripe will not save them.
  const pm = story.firstCharge === story.savedCard ? story.savedPm : first.pm;
  const { r, stepId } = await stripeStep(story, step, "payment_intents", {
    amount: String(story.amount),
    currency: story.currency.toLowerCase(),
    customer: story.stripeCustomerId,
    payment_method: pm,
    off_session: "true",
    confirm: "true",
    description: "Rev Rec simulator: monthly charge (MIT)",
    "metadata[sim_story]": story.storyId,
  });
  const txnId: string | undefined =
    r.json?.error?.payment_intent?.id ?? r.json?.id;
  if (!txnId)
    throw new HttpError(
      502,
      `Stripe charge did not run: ${stripeError(r)}`,
      story.storyId,
    );
  if (r.json?.status === "succeeded")
    throw new HttpError(
      502,
      "Stripe approved a charge that should have failed",
      story.storyId,
    );
  const err = r.json?.error ?? {};
  const declineCode: string =
    err.decline_code ?? first.declineCode ?? "generic_decline";
  const d = DECLINES[declineCode];
  event(story, {
    stepId,
    txnId,
    from: "billing",
    to: "processor",
    label: `charge ${money(story.amount, story.currency)}${suffix} → declined (${declineCode})`,
    text: `The billing system charged card ending ${first.last4} off-session. Stripe declined it: "${err.message ?? "declined"}" (${txnId}).`,
    status: "declined",
    source: "sandbox",
    why: [
      {
        source: "sandbox",
        text: `Stripe test mode answered ${err.code ?? "card_declined"} / ${declineCode}.`,
      },
      ...(d
        ? [
            {
              source: "rule" as const,
              text: `${declineCode} means ${d.plain}: a ${d.soft ? "soft decline, worth retrying" : "hard decline, Rev Rec should stop"}.`,
            },
          ]
        : []),
    ],
  });
  // What the billing system tells Rev Rec: what its processor said.
  const error = {
    code: err.code ?? "card_declined",
    message: err.message ?? "Your card was declined.",
    reason: `decline_code - ${declineCode}`,
    network_decline_code: d?.ndc ?? "05",
  };
  return { txnId, error };
}

// The POST /v2/recovery body, as the sandbox accepts it on 23 Oct 2026.
// There is no "action" field any more: the sandbox syncs the transaction with Stripe and
// picks the action from its status (failure = schedule retries, charged = paid outside Rev Rec).
function recoveryBody(
  story: Story,
  o: {
    status: "failure" | "charged";
    txnId: string;
    token: string;
    card: CardId;
    error?: object;
  },
) {
  const paid = o.status === "charged";
  const c = CARDS[o.card];
  return {
    amount_details: { order_amount: story.amount, currency: story.currency },
    merchant_reference_id: story.invoiceId,
    billing_merchant_connector_id: config.hsBillingMcaId,
    payment_merchant_connector_id: config.hsPaymentMcaId,
    transaction_status: o.status,
    // Sent only for a charge, and it must equal the order amount.
    ...(paid ? { amount_captured: story.amount } : {}),
    // Failures are the billing system's own off-session charges (MIT). Paying in the app is customer-present.
    customer_present: paid,
    payment_method_type: "card",
    payment_method_sub_type: "credit",
    transaction_created_at: nowIso(),
    billing_started_at: `${story.startedAt.slice(0, 10)}T00:00:00Z`,
    connector_customer_id: story.stripeCustomerId,
    connector_transaction_id: o.txnId,
    payment_method_data: {
      primary_processor_payment_method_token: o.token,
      payment_method_metadata: {
        card_network: c.network,
        card_type: "credit",
        card_isin: c.isin,
        card_issuing_country: "US",
        last4: c.last4,
      },
    },
    ...(o.error ? { error: o.error } : {}),
  };
}

const rejected = (story: Story, r: Upstream, what: string) =>
  new HttpError(
    502,
    `${what} returned ${r.status}: ${r.json?.error?.message ?? "no message"}`,
    story.storyId,
  );

// One failed charge by the billing system, then its report to Rev Rec.
async function chargeAndReport(
  story: Story,
  o: { step: string; suffix: string; of: string; n: number; total: number },
) {
  const { txnId, error } = await failingCharge(story, o.step, o.suffix);
  const body = recoveryBody(story, {
    status: "failure",
    txnId,
    token: story.savedPm,
    card: story.savedCard,
    error,
  });
  const { r, stepId } = await sandboxStep(
    story,
    `Report the failed charge to Rev Rec${o.of}`,
    body,
  );
  const sr = story.startRule;
  event(story, {
    stepId,
    from: "billing",
    to: "revrec",
    label: `report failure${o.of} → ${r.status}${r.status === 200 ? " recorded" : ""}`,
    text:
      r.status === 200
        ? `The billing system reported the failed charge ${txnId} to Rev Rec. Rev Rec recorded it on invoice ${r.json.id} (payment status ${r.json.intent_status}).`
        : `The billing system reported the failed charge ${txnId}. The sandbox refused it: ${r.json?.error?.message ?? r.status}.`,
    status: r.status === 200 ? "ok" : "refused",
    source: "sandbox",
    why: [
      {
        source: "rule",
        text: "The billing system tells Rev Rec about every failed charge: POST /v2/recovery with transaction_status failure and the saved card's token.",
      },
      {
        source: "rule",
        text: "The sandbox checks the charge with Stripe and records Stripe's own decline.",
      },
      ...(sr !== null && o.total > 1
        ? [
            {
              source: "sandbox" as const,
              text: `Start rule on this profile: ${sr}. Rev Rec takes over after more than ${sr} failed charges. This is failure ${o.n} of ${o.total}.`,
            },
          ]
        : []),
    ],
  });
  if (r.status !== 200)
    throw rejected(story, r, `POST /${config.hsRecoveryPath}`);
  story.reportsSent += 1;
  story.recoveryId = r.json.id;
  story.lastFailureBody = body;
}

// The billing system sends the same failure again (same transaction id).
// On 14 Oct the sandbox answered 200 and kept one attempt. Since 23 Oct it answers
// 400 "already recorded against the invoice". Both mean Rev Rec did not record the copy.
async function reportDuplicate(story: Story) {
  const { r, stepId } = await sandboxStep(
    story,
    "Report the same failure again (duplicate)",
    story.lastFailureBody,
  );
  const msg: string = r.json?.error?.message ?? "";
  const refused = r.status === 400 && /already recorded/i.test(msg);
  if (r.status !== 200 && !refused)
    throw rejected(story, r, `POST /${config.hsRecoveryPath}`);
  story.reportsSent += 1;
  event(story, {
    stepId,
    from: "billing",
    to: "revrec",
    label: `report same failure again → ${r.status}${refused ? " already recorded" : ""}`,
    text: refused
      ? `The billing system sent the same failure report again. Rev Rec refused the copy: ${msg}`
      : `The billing system sent the same failure report again. Rev Rec answered ${r.status} and kept one attempt.`,
    status: refused ? "refused" : "ok",
    source: "sandbox",
    why: [
      {
        source: "rule",
        text: "Rev Rec records each transaction once. A copy with the same transaction id does not count again.",
      },
      ...(msg ? [{ source: "sandbox" as const, text: msg }] : []),
    ],
  });
}

// ---------- start ----------

const card4 = (v: unknown) =>
  v === undefined || v === null ? undefined : String(v).padStart(4, "0");

// Reads the start body. A preset fills defaults; explicit fields win. Throws 400 on bad input.
export function parseStart(body: any): StartOptions {
  const bad = (m: string, code = "bad_request") =>
    new HttpError(400, m, undefined, code);
  const presetRaw = body.preset ?? body.scenario;
  let preset: Preset | null = null;
  if (presetRaw !== undefined && presetRaw !== null) {
    preset = presetById(Number(presetRaw)) ?? null;
    if (!preset)
      throw bad(`unknown preset ${presetRaw}; use 1 to 8`, "bad_scenario");
  }
  const amount = body.amount === undefined ? 6540 : Number(body.amount);
  if (!Number.isInteger(amount) || amount < 50 || amount > 1_000_000)
    throw bad(
      "amount is in minor units: an integer from 50 to 1000000 (6540 = 65.40)",
    );
  const currency = String(body.currency ?? "USD").toUpperCase();
  if (!CURRENCIES.includes(currency))
    throw bad(`currency must be one of ${CURRENCIES.join(", ")}`);
  const card = card4(body.card) ?? preset?.card;
  const savedCard = card4(body.savedCard);
  const firstCharge = card4(body.firstCharge);
  if (card && !(card in CARDS))
    throw bad(`card must be one of ${Object.keys(CARDS).join(", ")}`);
  if (savedCard && !(SAVED_CARDS as string[]).includes(savedCard))
    throw bad(`savedCard must be one of ${SAVED_CARDS.join(", ")}`);
  if (firstCharge && !(FIRST_CHARGE_CARDS as string[]).includes(firstCharge))
    throw bad(`firstCharge must be one of ${FIRST_CHARGE_CARDS.join(", ")}`);
  const customer = body.customer ?? preset?.customer ?? "new";
  if (customer !== "new" && customer !== "same")
    throw bad('customer must be "new" or "same"');
  return {
    presetId: preset?.id ?? null,
    amount,
    currency,
    ...resolveCards({
      card: card as CardId | undefined,
      savedCard: savedCard as SavedCardId | undefined,
      firstCharge: firstCharge as FirstChargeId | undefined,
    }),
    customer,
    sendDuplicateOnStart: Boolean(
      body.duplicate ?? preset?.sendDuplicateOnStart,
    ),
    reportAgainMode: preset?.reportAgainMode ?? "new",
  };
}

// Creates the story and returns at once. The billing system's steps run in the background,
// so the dashboard sees each step appear while it polls.
export function startStory(opts: StartOptions, owner: string): Story {
  const storyId = `st_${crypto.randomBytes(6).toString("hex")}`;
  const story: Story = {
    ...opts,
    storyId,
    owner,
    // "SIM-" prefix lets later sessions hide old demo invoices (the sandbox has no delete).
    invoiceId: `SIM-${opts.presetId ?? 0}-${Date.now().toString(36)}-${crypto.randomBytes(2).toString("hex")}`,
    recoveryId: null,
    startedAt: nowIso(),
    stripeCustomerId: "",
    savedPm: "",
    started: false,
    lastFailureBody: null,
    reportsSent: 0,
    startRule: null,
    paidInAppAt: null,
    error: null,
    stepSeq: 0,
    events: [],
    requests: [],
    seenSchedules: [],
    stageSeen: {},
    finalNoted: false,
  };
  stories.set(storyId, story);
  save();
  withLock(storyId, () => runStart(story)).catch((e) => {
    story.error = scrubText(String((e as Error).message ?? e));
    console.log(`story ${storyId} start failed: ${story.error}`);
    viewCache.delete(storyId);
    save();
  });
  return story;
}

// The visitor's last story that has a Stripe customer.
export const lastCustomerStory = (owner: string, exceptId = "") =>
  [...stories.values()]
    .reverse()
    .find(
      (s) => s.owner === owner && s.storyId !== exceptId && s.stripeCustomerId,
    );

export const ownerOf = (ip: string) =>
  crypto.createHash("sha256").update(ip).digest("hex").slice(0, 16);

async function runStart(story: Story) {
  const amount = money(story.amount, story.currency);
  const prev =
    story.customer === "same"
      ? lastCustomerStory(story.owner, story.storyId)
      : undefined;
  if (prev) {
    story.stripeCustomerId = prev.stripeCustomerId;
    if (prev.savedCard === story.savedCard) story.savedPm = prev.savedPm;
    event(story, {
      stepId: newStepId(story),
      from: "billing",
      to: "billing",
      label: `new invoice ${amount} (same customer)`,
      text: `Invoice ${story.invoiceId} for ${amount} is due. Same customer as the last story (${prev.stripeCustomerId}).`,
      status: "info",
      source: "simulator",
      why: [
        {
          source: "rule",
          text: "Rev Rec keeps retry history and limits per customer and card, so a second invoice shares them.",
        },
      ],
    });
  } else {
    const { r, stepId } = await stripeStep(
      story,
      "Create the test customer",
      "customers",
      {
        name: `Sim customer ${story.storyId.slice(3, 9)}`,
        description: "Rev Rec simulator (test)",
        "metadata[sim_story]": story.storyId,
        "metadata[invoice]": story.invoiceId,
      },
    );
    if (!r.json?.id)
      throw new HttpError(
        502,
        `Stripe customer not created: ${stripeError(r)}`,
        story.storyId,
      );
    story.stripeCustomerId = r.json.id;
    event(story, {
      stepId,
      from: "billing",
      to: "billing",
      label: `new invoice ${amount}`,
      text: `Invoice ${story.invoiceId} for ${amount} is due for a new test customer (${r.json.id}).`,
      status: "info",
      source: "simulator",
      why:
        story.customer === "same"
          ? [
              {
                source: "rule",
                text: "No earlier story had a customer, so this one uses a new customer.",
              },
            ]
          : [],
    });
  }
  if (!story.savedPm)
    story.savedPm = await saveCard(story, story.savedCard, "billing");

  // Start rule N = Rev Rec takes over after more than N failures. The /v2/recovery API has no retry
  // count field, so the billing system makes its own N retries first, each a real failed charge.
  story.startRule = await readStartRule();
  const total = story.sendDuplicateOnStart
    ? 1
    : Math.min((story.startRule ?? 0) + 1, MAX_START_FAILURES);
  for (let n = 1; n <= total; n++) {
    const of = total > 1 ? ` (${n} of ${total})` : "";
    await chargeAndReport(story, {
      step:
        n === 1
          ? "Billing system charges the card"
          : `Billing system retries the charge itself${of}`,
      suffix: n === 1 ? "" : ` again (${n} of ${total})`,
      of,
      n,
      total,
    });
    save();
  }
  if (story.sendDuplicateOnStart) await reportDuplicate(story);
  story.started = true;
  viewCache.delete(story.storyId);
  save();
}

// ---------- actions on a running story ----------

function requireRunning(story: Story, what: string) {
  if (!story.recoveryId)
    throw new HttpError(
      409,
      `the story has no invoice yet, so there is nothing to ${what}`,
    );
}

export function paidInApp(storyId: string) {
  const story = getStory(storyId);
  return withLock(storyId, async () => {
    requireRunning(story, "pay");
    if (story.paidInAppAt)
      throw new HttpError(409, "the customer already paid in the app");
    const pm = await saveCard(story, "4242", "customer");
    const amount = money(story.amount, story.currency);
    const { r: pi, stepId } = await stripeStep(
      story,
      "Customer pays in the app",
      "payment_intents",
      {
        amount: String(story.amount),
        currency: story.currency.toLowerCase(),
        customer: story.stripeCustomerId,
        payment_method: pm,
        off_session: "true",
        confirm: "true",
        description: "Rev Rec simulator: customer paid in the app",
        "metadata[sim_story]": story.storyId,
      },
    );
    if (pi.json?.status !== "succeeded")
      throw new HttpError(
        502,
        `Stripe payment did not succeed: ${stripeError(pi)}`,
        storyId,
      );
    event(story, {
      stepId,
      txnId: pi.json.id,
      from: "customer",
      to: "processor",
      label: `pay ${amount} in the app → approved`,
      text: `The customer paid ${amount} in the merchant's app with a new card ending 4242. Stripe approved it (${pi.json.id}).`,
      status: "ok",
      source: "sandbox",
      why: [{ source: "rule", text: CARDS["4242"].behaviour }],
    });

    const body = recoveryBody(story, {
      status: "charged",
      txnId: pi.json.id,
      token: pm,
      card: "4242",
    });
    const { r, stepId: reportStep } = await sandboxStep(
      story,
      "Tell Rev Rec the invoice was paid outside Rev Rec",
      body,
    );
    event(story, {
      stepId: reportStep,
      from: "billing",
      to: "revrec",
      label: `report paid outside Rev Rec → ${r.status}`,
      text:
        r.status === 200
          ? `The billing system told Rev Rec the invoice is paid. Rev Rec answered: payment status ${r.json.intent_status}.`
          : `The billing system told Rev Rec the invoice is paid. The sandbox refused it: ${r.json?.error?.message ?? r.status}.`,
      status: r.status === 200 ? "ok" : "refused",
      source: "sandbox",
      why: [
        {
          source: "rule",
          text: "A report with transaction_status charged tells Rev Rec the invoice was paid elsewhere, so Rev Rec stops retrying.",
        },
      ],
    });
    if (r.status !== 200)
      throw rejected(story, r, `POST /${config.hsRecoveryPath}`);
    story.reportsSent += 1;
    story.paidInAppAt = nowIso();
    viewCache.delete(storyId);
    save();
  });
}

// The merchant cancels the invoice: Rev Rec stops its retry work for it (live on the sandbox since 23 Oct).
export function cancelStory(storyId: string) {
  const story = getStory(storyId);
  return withLock(storyId, async () => {
    requireRunning(story, "cancel");
    const path = `${config.hsRecoveryPath}/${encodeURIComponent(story.invoiceId)}/cancel`;
    const { r, stepId } = await sandboxStep(
      story,
      "Cancel the invoice's recovery",
      undefined,
      path,
    );
    const msg: string = r.json?.error?.message ?? "";
    event(story, {
      stepId,
      from: "billing",
      to: "revrec",
      label: `cancel invoice → ${r.status}${r.status === 200 ? " cancelled" : ""}`,
      text:
        r.status === 200
          ? `The merchant cancelled the invoice. Rev Rec stopped work on it (payment status ${r.json?.intent_status}).`
          : `The merchant tried to cancel the invoice. The sandbox refused: ${msg || r.status}.`,
      status: r.status === 200 ? "ok" : "refused",
      source: "sandbox",
      why: [
        {
          source: "rule",
          text: "POST /v2/recovery/{invoice id}/cancel stops Rev Rec's retries for the invoice.",
        },
      ],
    });
    if (r.status !== 200)
      throw new HttpError(
        r.status === 412 ? 409 : 502,
        `cancel returned ${r.status}: ${msg || "no message"}`,
        storyId,
      );
    viewCache.delete(storyId);
    save();
  });
}

export function reportAgain(storyId: string, requested?: ReportAgainMode) {
  const story = getStory(storyId);
  const mode = requested ?? story.reportAgainMode;
  return withLock(storyId, async () => {
    requireRunning(story, "report again");
    if (story.reportsSent >= 8)
      throw new HttpError(429, "this story already sent 8 reports");
    if (mode === "duplicate") {
      await reportDuplicate(story);
    } else {
      // swap: the customer's bank works again, and the billing system now holds a working card.
      if (mode === "swap" && story.savedCard !== "4242") {
        story.savedPm = await saveCard(story, "4242", "billing");
        story.savedCard = "4242";
      }
      await chargeAndReport(story, {
        step: "Billing system charges the card again",
        suffix: " again",
        of: mode === "swap" ? " with the new card" : " again",
        n: 1,
        total: 1,
      });
    }
    viewCache.delete(storyId);
    save();
  });
}

// ---------- reading the sandbox ----------

const STAGES: Record<string, { stage: string; caption: string }> = {
  monitoring: { stage: "Monitoring", caption: "Waiting for the start rule" },
  no_picked: {
    stage: "Monitoring",
    caption: "Failure recorded, not picked for a retry",
  },
  queued: { stage: "Queued", caption: "Picking a retry time" },
  scheduled: { stage: "Scheduled", caption: "Retry booked for a time" },
  processing: { stage: "Processing", caption: "Charging the card now" },
  partially_captured_and_processing: {
    stage: "Processing",
    caption: "Charging the card now",
  },
  recovered: { stage: "Recovered", caption: "Paid" },
  succeeded: { stage: "Recovered", caption: "Paid" },
  partially_recovered: { stage: "Partially Recovered", caption: "Part paid" },
  terminated: { stage: "Terminated", caption: "Rev Rec stopped" },
  cancelled: { stage: "Cancelled", caption: "Cancelled by the merchant" },
};
const FINAL_STAGES = new Set(["Recovered", "Terminated", "Cancelled"]);
const STAGE_ORDER = [
  "Monitoring",
  "Queued",
  "Scheduled",
  "Processing",
  "Recovered",
  "Partially Recovered",
  "Terminated",
  "Cancelled",
];
const STATUS_ALIASES: Record<string, string> = {
  succeeded: "recovered",
  no_picked: "monitoring",
  partially_captured_and_processing: "processing",
};

type Attempt = {
  id: string;
  at: string;
  status: string;
  triggeredBy: "external" | "internal" | null;
  by: Actor;
  errorCode: string | null;
  errorMessage: string | null;
  declineCode: string | null; // e.g. generic_decline, stolen_card (Stripe's decline_code)
  networkDeclineCode: string | null;
  connectorTxnId: string | null;
  last4: string | null;
  network: string | null;
};

function toAttempts(list: any[]): Attempt[] {
  return list
    .map((a) => {
      const by =
        a.feature_metadata?.revenue_recovery?.attempt_triggered_by ?? null;
      return {
        id: a.id,
        at: a.created_at,
        status: a.status,
        triggeredBy: by,
        by: (by === "internal" ? "revrec" : "billing") as Actor,
        errorCode: a.error?.code ?? null,
        errorMessage: a.error?.message ?? null,
        declineCode: a.error?.network_error_message ?? null,
        networkDeclineCode: a.error?.network_decline_code ?? null,
        connectorTxnId:
          a.connector_payment_id?.TxnId ?? a.connector_reference_id ?? null,
        last4: a.payment_method_data?.card?.last4 ?? null,
        network: a.payment_method_data?.card?.card_network ?? null,
      };
    })
    .sort((x, y) => String(x.at).localeCompare(String(y.at)));
}

// The process tracker is dashboard-token only. Try the API-reference spelling first, then the dashboard one.
let processTrackerPath = "v2/process-trackers/revenue-recovery-workflow";
async function readProcessTracker(
  recoveryId: string,
): Promise<Upstream | null> {
  let r = await hsDashboard("GET", `${processTrackerPath}/${recoveryId}`);
  if (r?.status === 404 && processTrackerPath.includes("-")) {
    const alt = "v2/process_tracker/revenue_recovery_workflow";
    const r2 = await hsDashboard("GET", `${alt}/${recoveryId}`);
    if (r2 && r2.status !== 404) {
      processTrackerPath = alt;
      r = r2;
    }
  }
  return r;
}

// Rev Rec settings from the sandbox (dashboard token only), read at most every 5 min.
// Start rule, max retries and grace period live on the billing connector; the retry mode on the profile.
type RevRecConfig = {
  startRule: number | null;
  maxRetries: number | null;
  gracePeriodDays: number | null;
  retryMode: string | null;
};
let revrecConfig: { value: RevRecConfig; at: number } | null = null;
async function readRevRecConfig(): Promise<RevRecConfig> {
  if (revrecConfig && Date.now() - revrecConfig.at < 300_000)
    return revrecConfig.value;
  const [mca, prof] = await Promise.all([
    hsDashboard("GET", `v2/connector-accounts/${config.hsBillingMcaId}`).catch(
      () => null,
    ),
    hsDashboard("GET", `v2/profiles/${config.hsProfileId}`).catch(() => null),
  ]);
  const rr =
    mca?.status === 200
      ? (mca.json?.feature_metadata?.revenue_recovery ?? {})
      : {};
  const num = (v: unknown) => (typeof v === "number" ? v : null);
  const value = {
    startRule: num(rr.billing_connector_retry_threshold),
    maxRetries: num(rr.max_retry_count),
    gracePeriodDays: num(rr.grace_period_days),
    retryMode:
      prof?.status === 200
        ? (prof.json?.revenue_recovery_retry_algorithm_type ?? null)
        : null,
  };
  // Do not cache a miss, so a token that arrives later is used at once.
  if (mca?.status === 200) revrecConfig = { value, at: Date.now() };
  return value;
}
const readStartRule = async () =>
  (await readRevRecConfig().catch(() => null))?.startRule ?? null;

// Process-tracker business status codes in plain words (hyperswitch diesel_models/process_tracker.rs).
const TASK_STATUS: Record<string, string> = {
  Pending: "waiting for its booked time",
  CALCULATE_WORKFLOW_SCHEDULED: "retry time chosen",
  COMPLETED_EXECUTE_TASK: "the retry charged the card",
  FAILED_EXECUTE_TASK: "the retry failed, so Rev Rec picks a new time",
  COMPLETED_EXECUTE_TASK_TO_TRIGGER_PSYNC: "waiting for Stripe's final answer",
  COMPLETED_EXECUTE_TASK_TO_TRIGGER_REVIEW:
    "the invoice was already paid or closed, so Rev Rec did not charge",
  FAILED_DUE_TO_HARD_DECLINE_ERROR:
    "every saved card is a hard decline, so Rev Rec stops",
  TRIGGER_REQUEUE_FOR_EXECUTE_WORKFLOW:
    "the Stripe call failed, so Rev Rec tries again",
  COMPLETED_PSYNC_TASK: "Stripe's answer arrived",
  RETRIES_EXCEEDED: "status checks used up",
  GLOBAL_ERROR: "the task hit an error and stopped",
};

const RETRY_MODES: Record<string, string> = {
  cascading: "static retries (a fixed ladder of retry times)",
  smart: "smart retries (the model picks the hour)",
  monitoring: "monitoring (Rev Rec records failures but does not retry yet)",
};

const viewCache = new Map<string, { at: number; view: unknown }>();
const VIEW_TTL_MS = 2000;

const settle = <T>(p: Promise<T>) =>
  p.then(
    (v) => v,
    () => null,
  );
const minutesBetween = (a: string, b: number) =>
  Math.max(0, Math.round((b - Date.parse(a)) / 60000));
const earlier = (a: string | undefined, b: string | undefined) =>
  !a ? b : !b ? a : a < b ? a : b;

// ---------- the story view (what the dashboard polls) ----------

export async function storyView(storyId: string) {
  const story = getStory(storyId);
  const cached = viewCache.get(storyId);
  if (cached && Date.now() - cached.at < VIEW_TTL_MS) return cached.view;

  const preset = story.presetId ? (presetById(story.presetId) ?? null) : null;
  const saved = CARDS[story.savedCard];
  const first = CARDS[story.firstCharge];
  const warnings: string[] = [];
  const lastReads: {
    name: string;
    path: string;
    status: number | null;
    ms: number | null;
  }[] = [];

  let row: any = null;
  let intent: any = null;
  let rawAttempts: any[] = [];
  let pt: any = null;
  let rrc: RevRecConfig = {
    startRule: null,
    maxRetries: null,
    gracePeriodDays: null,
    retryMode: null,
  };
  const reads = {
    list: `v2/payments/recovery-list?payment_id=${story.recoveryId}`,
    detail: `v2/payments/${story.recoveryId}/get-revenue-recovery-intent`,
    attempts: `v2/payments/${story.recoveryId}/list-attempts`,
    tracker: `${processTrackerPath}/${story.recoveryId}`,
  };
  let changed = false;

  if (story.recoveryId) {
    const id = story.recoveryId;
    const [list, det, att, ptr, sr] = await Promise.all([
      settle(hsApiKey("GET", reads.list)),
      settle(hsApiKey("GET", reads.detail)),
      settle(hsApiKey("GET", reads.attempts)),
      settle(readProcessTracker(id)),
      settle(readRevRecConfig()),
    ]);
    reads.tracker = `${processTrackerPath}/${id}`;
    const note = (name: string, p: string, r: Upstream | null) =>
      lastReads.push({
        name,
        path: p,
        status: r?.status ?? null,
        ms: r?.ms ?? null,
      });
    note("invoice list row", reads.list, list);
    note("invoice detail", reads.detail, det);
    note("attempts", reads.attempts, att);
    if (ptr) note("process tracker", reads.tracker, ptr);

    row = list?.status === 200 ? ((list.json?.data ?? [])[0] ?? null) : null;
    intent = det?.status === 200 ? redact(det.json) : null;
    rawAttempts =
      att?.status === 200 ? redact(att.json?.payment_attempt_list ?? []) : [];
    pt = ptr?.status === 200 ? ptr.json : null;
    if (sr) rrc = sr;

    if (!list || !det || !att)
      warnings.push(
        "The sandbox did not answer one of the status reads. Showing what arrived.",
      );
    if (!row && story.started)
      warnings.push("The invoice is not in the sandbox invoice list yet.");
    if (!hasDashboardToken())
      warnings.push(
        'Next retry time needs a dashboard token for the Rev Rec merchant. See /healthz "dashboard".',
      );
    else if (ptr && ptr.status !== 200 && ptr.status !== 404)
      warnings.push(
        `The process tracker read returned ${ptr.status}. The dashboard token may have expired.`,
      );
  }
  const attempts = toAttempts(rawAttempts);

  // The sandbox says "succeeded" for a paid invoice; the dashboard calls it Recovered.
  const sandboxStatus: string | null = row?.status ?? null;
  const status: string =
    story.error && !story.recoveryId
      ? "error"
      : !sandboxStatus
        ? "starting"
        : (STATUS_ALIASES[sandboxStatus] ?? sandboxStatus);
  const charged = [...attempts].reverse().find((a) => a.status === "charged");
  const isPaid = status === "recovered" || status === "partially_recovered";
  const recoveredBy: "revrec" | "billing" | null = isPaid
    ? charged?.by === "revrec"
      ? "revrec"
      : "billing"
    : null;
  const stageInfo =
    STAGES[sandboxStatus ?? ""] ??
    (status === "error"
      ? { stage: "Error", caption: "The simulator could not start this story" }
      : { stage: "Starting", caption: "The billing system is at work" });
  const stage = stageInfo.stage;
  const caption =
    stage === "Recovered"
      ? recoveredBy === "revrec"
        ? "Paid: Rev Rec's retry worked"
        : "Paid outside Rev Rec"
      : stageInfo.caption;
  const isFinal = FINAL_STAGES.has(stage);

  const ptActive =
    Boolean(pt) &&
    !["finish", "review"].includes(String(pt.status).toLowerCase());
  // A paid invoice can still have a booked task: the sandbox does not cancel it. That is not a "next retry".
  const nextRetryAt: string | null =
    ptActive && !isFinal ? (pt.schedule_time_for_payment ?? null) : null;
  const staleTaskAt: string | null =
    ptActive && isFinal ? (pt.schedule_time_for_payment ?? null) : null;

  const fm = intent?.feature_metadata?.revenue_recovery ?? {};
  const external = attempts.filter((a) => a.by === "billing");
  const internal = attempts.filter((a) => a.by === "revrec");

  // A new retry time booked by Rev Rec becomes a step, once, with the process-tracker read as its raw call.
  const at = nowIso();
  if (nextRetryAt && !story.seenSchedules.includes(nextRetryAt)) {
    story.seenSchedules.push(nextRetryAt);
    const stepId = newStepId(story);
    story.requests.push({
      stepId,
      step: "Rev Rec books a retry (read from the process tracker)",
      at,
      system: "sandbox",
      request: {
        method: "GET",
        url: `${config.hsBaseUrl}/${reads.tracker}`,
        headers: shownHsHeaders("jwt"),
      },
      response: { status: 200, body: pt },
      ms: null,
    });
    event(story, {
      stepId,
      at,
      from: "revrec",
      to: "revrec",
      label: `pick retry time → ${hms(nextRetryAt)}`,
      text: `Rev Rec booked a retry of the saved card for ${hms(nextRetryAt)} UTC (process tracker ${pt.name}, ${pt.status}).`,
      status: "ok",
      source: "sandbox",
      why: [
        {
          source: "sandbox",
          text: `Booked time from the process tracker: ${nextRetryAt}.`,
        },
        ...(rrc.retryMode
          ? [
              {
                source: "sandbox" as const,
                text: `Retry mode on this profile: ${RETRY_MODES[rrc.retryMode] ?? rrc.retryMode}.`,
              },
            ]
          : []),
        {
          source: "rule",
          text: "Static retries in production wait 1 min, then 3 h, 6 h, 9 h, 12 h and 18 h steps. The sandbox retries every few minutes.",
        },
      ],
    });
    changed = true;
  }

  // The first time a final status shows, the billing system learns it. Custom billing has no
  // record-back call, so the billing system reads the status.
  if (isFinal && !story.finalNoted && stage !== "Cancelled") {
    story.finalNoted = true;
    const stepId = newStepId(story);
    story.requests.push({
      stepId,
      step: "The billing system reads the invoice status",
      at,
      system: "sandbox",
      request: {
        method: "GET",
        url: `${config.hsBaseUrl}/${reads.list}`,
        headers: shownHsHeaders("api-key"),
      },
      response: { status: 200, body: redact(row) },
      ms: null,
    });
    event(story, {
      stepId,
      at,
      from: "revrec",
      to: "billing",
      label:
        stage === "Recovered"
          ? recoveredBy === "revrec"
            ? "invoice recovered → mark paid"
            : "invoice paid outside Rev Rec"
          : `invoice ${status}`,
      text: `Rev Rec's status for the invoice is ${sandboxStatus}. The billing system reads it and updates the invoice.`,
      status: stage === "Recovered" ? "ok" : "info",
      source: "sandbox",
      why: [
        {
          source: "rule",
          text: "A Custom billing connector gets no record-back call, so the billing system reads the status from Rev Rec.",
        },
      ],
    });
    changed = true;
  }

  // Stage history: the first time each stage was seen. An attempt's own timestamp wins when earlier.
  if (story.recoveryId && sandboxStatus && !story.stageSeen[stage]) {
    story.stageSeen[stage] = at;
    changed = true;
  }
  if (changed) save();
  const firstFail = external.find((a) => a.status !== "charged");
  const exact: Record<string, string | undefined> = {
    Monitoring: story.stageSeen.Monitoring ? firstFail?.at : undefined,
    Processing: internal[0]?.at,
    // The paying attempt's finish time, when the sandbox gives it.
    Recovered: isPaid
      ? (rawAttempts.find((x) => x.id === charged?.id)?.modified_at ??
        charged?.at)
      : undefined,
  };
  const stageHistory = [
    ...new Set([...Object.keys(story.stageSeen), ...Object.keys(exact)]),
  ]
    .map((s) => {
      const observed = story.stageSeen[s];
      const fromSandbox = exact[s];
      const firstSeenAt = earlier(observed, fromSandbox);
      return firstSeenAt
        ? {
            stage: s,
            firstSeenAt,
            source:
              fromSandbox && firstSeenAt === fromSandbox
                ? "sandbox"
                : "observed",
          }
        : null;
    })
    .filter((x) => x !== null)
    .sort(
      (a, b) =>
        a.firstSeenAt.localeCompare(b.firstSeenAt) ||
        STAGE_ORDER.indexOf(a.stage) - STAGE_ORDER.indexOf(b.stage),
    );

  // Rev Rec's own retries come from the attempts list: one step each, the attempt JSON as its raw read.
  const attemptEvents: StoryEvent[] = [];
  const attemptRequests: RequestLog[] = [];
  internal.forEach((a, i) => {
    const raw = rawAttempts.find((x) => x.id === a.id);
    const stepId = `att_${a.id}`;
    attemptRequests.push({
      stepId,
      step: "Rev Rec retries the saved card (read from the attempts list)",
      at: a.at,
      system: "sandbox",
      request: {
        method: "GET",
        url: `${config.hsBaseUrl}/${reads.attempts}`,
        headers: shownHsHeaders("api-key"),
      },
      response: { status: 200, body: raw },
      ms: null,
    });
    const result =
      a.status === "charged"
        ? "approved"
        : a.status === "failure"
          ? `declined (${a.declineCode ?? a.errorCode ?? "?"})`
          : a.status;
    attemptEvents.push({
      stepId,
      at: a.at,
      from: "revrec",
      to: "processor",
      label: `charge saved card ••${a.last4 ?? "?"} → ${result}`,
      text: `Rev Rec charged the saved card ending ${a.last4 ?? "?"} itself (retry ${i + 1}). Stripe answered ${a.status}${a.errorMessage ? `: "${a.errorMessage}"` : ""}.`,
      status:
        a.status === "charged"
          ? "ok"
          : a.status === "failure"
            ? "declined"
            : "pending",
      source: "sandbox",
      why: [
        {
          source: "sandbox",
          text: `Attempt ${a.id}, triggered by Rev Rec (internal), status ${a.status}.`,
        },
        {
          source: "recomputed",
          text: `Card network limit: ${i + 1} of about 20 Visa retries used on this card in 30 days (limit values to confirm).`,
        },
        ...(a.last4 && a.last4 in CARDS
          ? [
              {
                source: "rule" as const,
                text: CARDS[a.last4 as CardId].behaviour,
              },
            ]
          : []),
      ],
    });
  });

  // A booked retry that has not run yet: a dashed arrow with the countdown.
  const bookedStep = [...story.events]
    .reverse()
    .find((e) => e.label.startsWith("pick retry time"))?.stepId;
  const pendingEvents: StoryEvent[] = nextRetryAt
    ? [
        {
          stepId: bookedStep ?? "next-retry",
          at: nextRetryAt,
          from: "revrec",
          to: "processor",
          label: `charge saved card ••${saved.last4} at ${hms(nextRetryAt)}`,
          text: `Rev Rec will charge the saved card ending ${saved.last4} at ${hms(nextRetryAt)} UTC.`,
          status: "pending",
          source: "sandbox",
          why: [{ source: "rule", text: saved.behaviour }],
        },
      ]
    : [];

  const byTime = <T extends { at: string }>(x: T, y: T) =>
    String(x.at).localeCompare(String(y.at));
  // attemptId links a charge row to its row in the attempts table.
  const timeline = [...story.events, ...attemptEvents]
    .sort(byTime)
    .concat(pendingEvents)
    .map(({ txnId, ...e }) => ({
      ...e,
      attemptId: e.stepId.startsWith("att_")
        ? e.stepId.slice(4)
        : txnId
          ? (attempts.find((a) => a.connectorTxnId === txnId)?.id ?? null)
          : null,
    }));
  const requests = [...story.requests, ...attemptRequests].sort(byTime);

  // ----- explain (invoice level, for the attempts rows and the status) -----
  const explain: { id: string; text: string; source: Source }[] = [];
  const add = (id: string, source: Source, text: string) =>
    explain.push({ id, text, source });
  const utc = (iso: string) =>
    `${iso.replace("T", " ").replace(/\.\d+Z?$|Z$/, "")} UTC`;

  if (story.recoveryId) {
    add(
      "status",
      "sandbox",
      `Rev Rec status from the sandbox: ${sandboxStatus ?? "not listed yet"} (${caption}).`,
    );
    if (nextRetryAt)
      add(
        "next-retry",
        "sandbox",
        `Next retry booked for ${utc(nextRetryAt)}.`,
      );
    else if (staleTaskAt)
      add(
        "stale-task",
        "sandbox",
        `A retry task is still booked for ${utc(staleTaskAt)}. The sandbox does not cancel it when the invoice is paid.`,
      );
    else if (pt) {
      const plain = TASK_STATUS[pt.business_status] ?? pt.status;
      add(
        "task",
        "sandbox",
        `Rev Rec's retry task (${pt.name ?? "task"}) is ${pt.status}: ${plain} [${pt.business_status}].`,
      );
    }
    if (recoveredBy === "billing")
      add(
        "paid-outside",
        "sandbox",
        "Paid outside Rev Rec: the billing system reported a successful payment, so Rev Rec stops retrying.",
      );
    if (recoveredBy === "revrec")
      add(
        "recovered",
        "sandbox",
        "Recovered by Rev Rec: its own retry on the saved card was approved.",
      );
    if (status === "terminated")
      add(
        "terminated",
        "sandbox",
        "Rev Rec stopped retrying this invoice (terminated).",
      );
    const paidOutside = external.filter((a) => a.status === "charged").length;
    add(
      "counts",
      "recomputed",
      `Failed charges by the billing system: ${external.length - paidOutside}.` +
        (paidOutside ? ` Payments outside Rev Rec: ${paidOutside}.` : "") +
        ` Rev Rec's own retries: ${internal.length}.`,
    );
    const failureReports = story.reportsSent - (story.paidInAppAt ? 1 : 0);
    if (failureReports > external.length - paidOutside)
      add(
        "duplicates",
        "recomputed",
        `Failure reports sent by the billing system: ${failureReports}. Failed attempts Rev Rec kept: ${external.length - paidOutside}. Rev Rec did not record the copy.`,
      );
    if (attempts[0])
      add(
        "elapsed",
        "recomputed",
        `${minutesBetween(attempts[0].at, Date.now())} min since the first failure was recorded.`,
      );
    if (internal.length > 0)
      add(
        "network-limit",
        "recomputed",
        `Card network limit: ${internal.length} of about 20 Visa retries used on this card in 30 days (limit values to confirm).`,
      );
    if (typeof fm.total_retry_count === "number")
      add(
        "retry-count",
        "sandbox",
        `Total retry count on the invoice: ${fm.total_retry_count}.`,
      );
  }
  const recorded = firstFail?.declineCode ?? null;
  if (firstFail)
    add(
      "recorded-reason",
      "sandbox",
      `Decline recorded by the sandbox from Stripe: ${firstFail.errorCode ?? "?"}` +
        (recorded ? `, ${recorded}` : "") +
        (firstFail.networkDeclineCode
          ? ` (network code ${firstFail.networkDeclineCode})`
          : "") +
        ".",
    );
  const reason = recorded ?? first.declineCode;
  const d = reason ? DECLINES[reason] : undefined;
  if (reason && d)
    add(
      "reason",
      "rule",
      `${reason} means ${d.plain}: a ${d.soft ? "soft decline, worth retrying" : "hard decline, Rev Rec should stop"}.`,
    );
  add(
    "cards",
    "rule",
    `First charge on card ${first.last4}: ${first.behaviour} Saved card that Rev Rec retries: ${saved.behaviour}`,
  );
  const sr = story.startRule ?? rrc.startRule;
  if (sr !== null)
    add(
      "start-rule",
      "sandbox",
      `Start rule on this profile: ${sr}. Rev Rec takes over after more than ${sr} failed charge${sr === 1 ? "" : "s"} by the billing system` +
        (story.sendDuplicateOnStart
          ? "."
          : `, so the simulator made ${Math.min(sr + 1, MAX_START_FAILURES)} real failed charge${sr === 0 ? "" : "s"} first.`),
    );
  else
    add(
      "start-rule",
      "rule",
      "Start rule not read from the sandbox (no dashboard token). Demo profiles should use 0: Rev Rec takes over on the first failure.",
    );
  if (rrc.retryMode)
    add(
      "retry-mode",
      "sandbox",
      `Retry mode on this profile: ${RETRY_MODES[rrc.retryMode] ?? rrc.retryMode}.`,
    );
  if (rrc.maxRetries !== null)
    add(
      "max-retries",
      "sandbox",
      `Max retries on this profile: ${rrc.maxRetries}. Whether the engine enforces it is still to confirm.`,
    );
  if (rrc.gracePeriodDays !== null)
    add(
      "grace-period",
      "sandbox",
      `Grace period on this profile: ${rrc.gracePeriodDays} days.`,
    );

  const open =
    Boolean(story.recoveryId) &&
    (story.started || Boolean(story.error)) &&
    !isFinal;
  // When the story has made its point, the dashboard can stop polling. The duplicate preset never
  // reaches a final stage on a profile with a start rule above 0, so its point is the refused copy.
  const done =
    status === "error" ||
    isFinal ||
    (story.sendDuplicateOnStart &&
      story.started &&
      story.reportsSent > external.length);

  const view = {
    storyId: story.storyId,
    preset: story.presetId,
    scenario: story.presetId, // old name, kept for the first story screen
    presetInfo: preset
      ? {
          id: preset.id,
          title: preset.title,
          v1Status: preset.v1Status,
          expected: preset.expected,
          hint: preset.hint,
        }
      : null,
    form: {
      amount: story.amount,
      currency: story.currency,
      savedCard: story.savedCard,
      firstCharge: story.firstCharge,
      customer: story.customer,
    },
    invoiceId: story.invoiceId,
    recoveryId: story.recoveryId,
    startedAt: story.startedAt,
    updatedAt: new Date().toISOString(),
    status,
    sandboxStatus,
    stage,
    stageCaption: caption,
    stageHistory,
    recoveredBy,
    done,
    nextRetryAt,
    // Raw sandbox JSON (secrets hidden), so the dashboard can reuse its invoice page mappers.
    invoice: intent,
    attempts: rawAttempts,
    processTracker: pt,
    // The same facts, flattened.
    summary: {
      amount: intent?.amount_details?.order_amount ?? story.amount,
      currency: intent?.amount_details?.currency ?? story.currency,
      amountCaptured: intent?.amount_details?.amount_captured ?? null,
      paymentStatus: intent?.status ?? null,
      totalRetryCount: fm.total_retry_count ?? null,
      cardsAttached: intent?.card_attached ?? null,
      firstErrorCode: fm.first_payment_attempt_pg_error_code ?? null,
      firstNetworkDeclineCode:
        fm.first_payment_attempt_network_decline_code ?? null,
      connector: fm.connector ?? null,
      savedCard: story.savedCard,
      firstChargeCard: story.firstCharge,
      recordedReason: recorded,
      reportsSent: story.reportsSent,
      createdAt: intent?.created_at ?? null,
    },
    attemptSummary: attempts,
    explain,
    timeline,
    requests,
    lastReads,
    actions: {
      paidInApp: open && !story.paidInAppAt,
      reportAgain: open && story.reportsSent < 8,
      cancel: open,
      reportAgainMode: story.reportAgainMode,
    },
    warnings,
    startError: story.error,
  };
  viewCache.set(storyId, { at: Date.now(), view });
  return view;
}
