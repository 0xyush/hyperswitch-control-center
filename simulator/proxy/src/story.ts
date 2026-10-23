// The billing simulator for one invoice story.
// It plays the merchant's billing system: it creates a Stripe test customer with a saved card,
// makes a real failed charge, reports it to Rev Rec on the sandbox, and reads the status back.
// Rev Rec's decisions are real. Every explain line says where it comes from.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { hasDashboardToken } from "./auth.ts";
import { config } from "./config.ts";
import { redact, scrubText } from "./redact.ts";
import {
  CARD_DECLINES,
  CARD_WORKS,
  scenarioById,
  type Card,
  type ReportAgainMode,
  type Scenario,
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

type RequestLog = {
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
  ms: number;
};

// One arrow in the four-box flow: who acted, towards whom, and what happened.
type StoryEvent = {
  at: string;
  from: Actor;
  to: Actor;
  text: string;
  source: "simulator" | "sandbox";
};

export type Story = {
  storyId: string;
  scenarioId: number;
  invoiceId: string; // merchant_reference_id: the invoice id in the billing system
  recoveryId: string | null; // the Hyperswitch payment id Rev Rec gave the invoice
  startedAt: string;
  amount: number;
  currency: string;
  stripeCustomerId: string;
  tokenPm: string; // the saved card Rev Rec retries
  tokenCard: Card;
  lastFailureBody: unknown | null; // re-sent as-is for a duplicate report
  reportsSent: number;
  startRule: number | null; // billing_connector_retry_threshold when the story started, if known
  paidInAppAt: string | null;
  error: string | null;
  events: StoryEvent[];
  requests: RequestLog[];
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
const money = (minor: number, currency: string) =>
  `${(minor / 100).toFixed(2)} ${currency}`;

// ---------- store (in memory, saved to data/stories.json so a restart keeps the stories) ----------

const STORE_FILE = path.join(config.dataDir, "stories.json");
const stories = new Map<string, Story>();
const MAX_STORIES = 300;

try {
  const saved = JSON.parse(fs.readFileSync(STORE_FILE, "utf8")) as Story[];
  for (const s of saved) stories.set(s.storyId, s);
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
      scenarioId: s.scenarioId,
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

// ---------- logged calls (these feed the "Show requests" panel) ----------

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
  story.requests.push({
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
  return r;
}

async function sandboxStep(story: Story, step: string, body: unknown) {
  const r = await hsApiKey("POST", config.hsRecoveryPath, body);
  story.requests.push({
    step,
    at: nowIso(),
    system: "sandbox",
    request: {
      method: "POST",
      url: `${config.hsBaseUrl}/${config.hsRecoveryPath}`,
      headers: shownHsHeaders("api-key"),
      body: redact(body),
    },
    response: { status: r.status, body: redact(r.json) },
    ms: r.ms,
  });
  return r;
}

function event(
  story: Story,
  from: Actor,
  to: Actor,
  text: string,
  source: StoryEvent["source"] = "simulator",
) {
  story.events.push({ at: nowIso(), from, to, text, source });
}

const stripeError = (r: Upstream) =>
  r.json?.error?.message ?? `HTTP ${r.status}`;

async function attachCard(
  story: Story,
  card: Card,
  step: string,
): Promise<string> {
  const r = await stripeStep(story, step, `payment_methods/${card.pm}/attach`, {
    customer: story.stripeCustomerId,
  });
  if (!r.json?.id)
    throw new HttpError(
      502,
      `Stripe could not save card ${card.last4}: ${stripeError(r)}`,
      story.storyId,
    );
  return r.json.id;
}

// A real off-session charge that Stripe declines: what the billing system's own monthly charge looks like.
async function failedCharge(story: Story, step: string): Promise<string> {
  const pm =
    story.tokenCard.last4 === CARD_DECLINES.last4
      ? story.tokenPm
      : await attachCard(
          story,
          CARD_DECLINES,
          "Save the failing card for the billing system's own charge",
        );
  const r = await stripeStep(story, step, "payment_intents", {
    amount: String(story.amount),
    currency: story.currency.toLowerCase(),
    customer: story.stripeCustomerId,
    payment_method: pm,
    off_session: "true",
    confirm: "true",
    description: "Rev Rec simulator: monthly charge (MIT)",
    "metadata[sim_story]": story.storyId,
  });
  const id = r.json?.error?.payment_intent?.id ?? r.json?.id;
  if (!id)
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
  return id;
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
    card: Card;
    error?: object;
  },
) {
  const paid = o.status === "charged";
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
        card_network: o.card.network,
        card_type: "credit",
        card_isin: o.card.isin,
        card_issuing_country: "US",
        last4: o.card.last4,
      },
    },
    ...(o.error ? { error: o.error } : {}),
  };
}

async function report(story: Story, step: string, body: unknown) {
  const r = await sandboxStep(story, step, body);
  if (r.status !== 200) {
    const msg = r.json?.error?.message ?? `HTTP ${r.status}`;
    throw new HttpError(
      502,
      `POST /${config.hsRecoveryPath} returned ${r.status}: ${msg}`,
      story.storyId,
    );
  }
  story.reportsSent += 1;
  return r;
}

// ---------- actions ----------

export async function startStory(scenarioId: number): Promise<Story> {
  const sc = scenarioById(scenarioId);
  if (!sc)
    throw new HttpError(
      400,
      `unknown scenario ${scenarioId}; use 1 to 8`,
      undefined,
      "bad_scenario",
    );
  if (!sc.runnable)
    throw new HttpError(
      409,
      `scenario ${sc.id} "${sc.title}" is not available yet (${sc.v1Status})`,
    );

  const storyId = `st_${crypto.randomBytes(6).toString("hex")}`;
  const story: Story = {
    storyId,
    scenarioId,
    // "SIM-" prefix lets later sessions hide old demo invoices (the sandbox has no delete).
    invoiceId: `SIM-${scenarioId}-${Date.now().toString(36)}-${crypto.randomBytes(2).toString("hex")}`,
    recoveryId: null,
    startedAt: nowIso(),
    amount: 6540,
    currency: "USD",
    stripeCustomerId: "",
    tokenPm: "",
    tokenCard: sc.retryCard,
    lastFailureBody: null,
    reportsSent: 0,
    startRule: null,
    paidInAppAt: null,
    error: null,
    events: [],
    requests: [],
  };
  stories.set(storyId, story);

  try {
    const cus = await stripeStep(
      story,
      "Create the test customer",
      "customers",
      {
        name: `Sim customer ${storyId.slice(3, 9)}`,
        description: "Rev Rec simulator (test)",
        "metadata[sim_story]": storyId,
        "metadata[invoice]": story.invoiceId,
      },
    );
    if (!cus.json?.id)
      throw new HttpError(
        502,
        `Stripe customer not created: ${stripeError(cus)}`,
        storyId,
      );
    story.stripeCustomerId = cus.json.id;
    story.tokenPm = await attachCard(
      story,
      sc.retryCard,
      `Save card ${sc.retryCard.last4} for the customer`,
    );
    event(
      story,
      "billing",
      "billing",
      `Invoice ${story.invoiceId} for ${money(story.amount, story.currency)} is due. The customer's saved card ends ${sc.retryCard.last4}.`,
    );

    // Start rule N = Rev Rec takes over after more than N failures. The /v2/recovery API has no retry
    // count field, so the billing system makes its own N retries first, each a real failed charge.
    story.startRule = await readStartRule();
    const failures = sc.sendDuplicateOnStart
      ? 1
      : Math.min((story.startRule ?? 0) + 1, MAX_START_FAILURES);
    for (let n = 1; n <= failures; n++) {
      const of = failures > 1 ? ` (${n} of ${failures})` : "";
      const txnId = await failedCharge(
        story,
        n === 1
          ? "Billing system charges the card (it fails)"
          : `Billing system retries the charge itself${of}`,
      );
      event(
        story,
        "billing",
        "processor",
        n === 1
          ? `The billing system charged the card. Stripe declined it (${txnId}).`
          : `The billing system retried the charge itself${of}. Stripe declined it again (${txnId}).`,
      );
      const body = recoveryBody(story, {
        status: "failure",
        txnId,
        token: story.tokenPm,
        card: sc.retryCard,
        error: sc.reason.error,
      });
      const r = await report(
        story,
        `Report the failed payment to Rev Rec${of}`,
        body,
      );
      story.recoveryId = r.json.id;
      story.lastFailureBody = body;
      event(
        story,
        "billing",
        "revrec",
        `The billing system reported the failure${of} to Rev Rec with reason "${sc.reason.key}" (reason chosen by the simulator).`,
      );
      event(
        story,
        "revrec",
        "billing",
        `Rev Rec recorded it on invoice ${r.json.id} (payment status ${r.json.intent_status}).`,
        "sandbox",
      );
    }

    if (sc.sendDuplicateOnStart) {
      const dup = await report(
        story,
        "Report the same failure again (duplicate)",
        story.lastFailureBody,
      );
      event(
        story,
        "billing",
        "revrec",
        "The billing system sent the same failure report again (same transaction id).",
      );
      event(
        story,
        "revrec",
        "billing",
        `Rev Rec answered ${dup.status} for the copy (payment status ${dup.json.intent_status}).`,
        "sandbox",
      );
    }
    save();
    return story;
  } catch (e) {
    story.error = scrubText(String((e as Error).message));
    save();
    if (e instanceof HttpError) throw e;
    throw new HttpError(502, story.error, storyId);
  }
}

export function paidInApp(storyId: string) {
  const story = getStory(storyId);
  return withLock(storyId, async () => {
    if (!story.recoveryId)
      throw new HttpError(
        409,
        "the story did not start, so there is nothing to pay",
      );
    if (story.paidInAppAt)
      throw new HttpError(409, "the customer already paid in the app");
    const pm = await attachCard(
      story,
      CARD_WORKS,
      "Customer adds a new card (4242) in the app",
    );
    const pi = await stripeStep(
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
    event(
      story,
      "customer",
      "processor",
      `The customer paid ${money(story.amount, story.currency)} in the app with a new card ending 4242. Stripe approved it.`,
    );

    const body = recoveryBody(story, {
      status: "charged",
      txnId: pi.json.id,
      token: pm,
      card: CARD_WORKS,
    });
    const r = await report(
      story,
      "Tell Rev Rec the invoice was paid outside Rev Rec",
      body,
    );
    story.paidInAppAt = nowIso();
    event(
      story,
      "billing",
      "revrec",
      "The billing system told Rev Rec the invoice is paid (transaction_status charged).",
    );
    event(
      story,
      "revrec",
      "billing",
      `Rev Rec answered: payment status ${r.json.intent_status}.`,
      "sandbox",
    );
    viewCache.delete(storyId);
    save();
  });
}

export function reportAgain(storyId: string, requested?: ReportAgainMode) {
  const story = getStory(storyId);
  const sc = scenarioById(story.scenarioId)!;
  const mode = requested ?? sc.reportAgainMode;
  return withLock(storyId, async () => {
    if (!story.recoveryId || !story.lastFailureBody)
      throw new HttpError(
        409,
        "the story did not start, so there is nothing to report again",
      );
    if (story.reportsSent >= 8)
      throw new HttpError(429, "this story already sent 8 reports");

    if (mode === "duplicate") {
      const r = await report(
        story,
        "Report the same failure again (duplicate)",
        story.lastFailureBody,
      );
      event(
        story,
        "billing",
        "revrec",
        "The billing system sent the same failure report again (same transaction id).",
      );
      event(
        story,
        "revrec",
        "billing",
        `Rev Rec answered ${r.status} for the copy (payment status ${r.json.intent_status}).`,
        "sandbox",
      );
    } else {
      // swap: the customer's bank works again, and the billing system now holds a working card.
      if (mode === "swap" && story.tokenCard.last4 !== CARD_WORKS.last4) {
        story.tokenPm = await attachCard(
          story,
          CARD_WORKS,
          "Customer's new working card (4242) is saved",
        );
        story.tokenCard = CARD_WORKS;
      }
      const txnId = await failedCharge(
        story,
        "Billing system charges the card again (it fails)",
      );
      event(
        story,
        "billing",
        "processor",
        `The billing system charged the card again. Stripe declined it (${txnId}).`,
      );
      const body = recoveryBody(story, {
        status: "failure",
        txnId,
        token: story.tokenPm,
        card: story.tokenCard,
        error: sc.reason.error,
      });
      const r = await report(
        story,
        mode === "swap"
          ? "Report a new failure that carries the working card"
          : "Report a new failed charge",
        body,
      );
      story.lastFailureBody = body;
      event(
        story,
        "billing",
        "revrec",
        mode === "swap"
          ? "The billing system reported a new failure. It carries the customer's working card ending 4242."
          : `The billing system reported a new failed charge with reason "${sc.reason.key}".`,
      );
      event(
        story,
        "revrec",
        "billing",
        `Rev Rec answered: payment status ${r.json.intent_status}.`,
        "sandbox",
      );
    }
    viewCache.delete(storyId);
    save();
  });
}

// ---------- merged status (what the dashboard polls) ----------

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
  connectorTxnId: string | null;
  last4: string | null;
  network: string | null;
};

function toAttempts(json: any): Attempt[] {
  const list: any[] = json?.payment_attempt_list ?? [];
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
const readStartRule = async () => (await readRevRecConfig()).startRule;

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

export async function storyView(storyId: string) {
  const story = getStory(storyId);
  const cached = viewCache.get(storyId);
  if (cached && Date.now() - cached.at < VIEW_TTL_MS) return cached.view;

  const sc = scenarioById(story.scenarioId)!;
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
  let attempts: Attempt[] = [];
  let pt: any = null;
  let rrc: RevRecConfig = {
    startRule: null,
    maxRetries: null,
    gracePeriodDays: null,
    retryMode: null,
  };

  if (story.recoveryId) {
    const id = story.recoveryId;
    const reads = {
      "invoice list row": `v2/payments/recovery-list?payment_id=${id}`,
      "invoice detail": `v2/payments/${id}/get-revenue-recovery-intent`,
      attempts: `v2/payments/${id}/list-attempts`,
    };
    const [list, det, att, ptr, sr] = await Promise.all([
      settle(hsApiKey("GET", reads["invoice list row"])),
      settle(hsApiKey("GET", reads["invoice detail"])),
      settle(hsApiKey("GET", reads.attempts)),
      settle(readProcessTracker(id)),
      settle(readRevRecConfig()),
    ]);
    const note = (name: string, p: string, r: Upstream | null) =>
      lastReads.push({
        name,
        path: p,
        status: r?.status ?? null,
        ms: r?.ms ?? null,
      });
    note("invoice list row", reads["invoice list row"], list);
    note("invoice detail", reads["invoice detail"], det);
    note("attempts", reads.attempts, att);
    if (ptr) note("process tracker", `${processTrackerPath}/${id}`, ptr);

    row = list?.status === 200 ? ((list.json?.data ?? [])[0] ?? null) : null;
    intent = det?.status === 200 ? redact(det.json) : null;
    rawAttempts =
      att?.status === 200 ? redact(att.json?.payment_attempt_list ?? []) : [];
    attempts = toAttempts({ payment_attempt_list: rawAttempts });
    pt = ptr?.status === 200 ? ptr.json : null;
    if (sr) rrc = sr;

    if (!list || !det || !att)
      warnings.push(
        "The sandbox did not answer one of the status reads. Showing what arrived.",
      );
    if (!row)
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

  // The sandbox says "succeeded" for a paid invoice; the dashboard stepper calls it Recovered.
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
      : { stage: "Starting", caption: "Waiting for the sandbox" });
  const caption =
    stageInfo.stage === "Recovered"
      ? recoveredBy === "revrec"
        ? "Paid: Rev Rec's retry worked"
        : "Paid outside Rev Rec"
      : stageInfo.caption;

  const ptActive =
    Boolean(pt) &&
    !["finish", "review"].includes(String(pt.status).toLowerCase());
  const isFinal = FINAL_STAGES.has(stageInfo.stage);
  // A paid invoice can still have a booked task: the sandbox does not cancel it. That is not a "next retry".
  const nextRetryAt: string | null =
    ptActive && !isFinal ? (pt.schedule_time_for_payment ?? null) : null;
  const staleTaskAt: string | null =
    ptActive && isFinal ? (pt.schedule_time_for_payment ?? null) : null;

  const fm = intent?.feature_metadata?.revenue_recovery ?? {};
  const external = attempts.filter((a) => a.by === "billing");
  const internal = attempts.filter((a) => a.by === "revrec");

  // Rev Rec's own retries become arrows in the flow (from the sandbox attempts list).
  const derived: StoryEvent[] = internal.map((a) => ({
    at: a.at,
    from: "revrec",
    to: "processor",
    text:
      a.status === "charged"
        ? `Rev Rec retried the saved card ending ${a.last4 ?? "?"}. Stripe approved it.`
        : `Rev Rec retried the saved card ending ${a.last4 ?? "?"}. Stripe answered ${a.status}${a.errorCode ? ` (${a.errorCode})` : ""}.`,
    source: "sandbox",
  }));
  const timeline = [...story.events, ...derived].sort((x, y) =>
    String(x.at).localeCompare(String(y.at)),
  );

  const explain: { id: string; text: string; source: Source }[] = [];
  const add = (id: string, source: Source, text: string) =>
    explain.push({ id, text, source });

  if (story.recoveryId) {
    add(
      "status",
      "sandbox",
      `Rev Rec status from the sandbox: ${sandboxStatus ?? "not listed yet"} (${caption}).`,
    );
    const utc = (iso: string) =>
      `${iso.replace("T", " ").replace(/\.\d+Z?$|Z$/, "")} UTC`;
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
    if (sc.sendDuplicateOnStart || story.reportsSent > external.length)
      add(
        "duplicates",
        "recomputed",
        `Reports sent by the billing system: ${story.reportsSent}. Attempts Rev Rec kept from them: ${external.length}.` +
          (story.reportsSent > external.length
            ? " The copy was ignored as a duplicate."
            : ""),
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
  add(
    "reason",
    "rule",
    `Reported reason "${sc.reason.key}" is a ${sc.reason.soft ? "soft decline: the bank said not now, so it is worth retrying" : "hard decline: the bank said never, so Rev Rec should stop"}. The simulator chose this reason.`,
  );
  add(
    "card",
    "rule",
    `Saved card ends ${story.tokenCard.last4}. ${story.tokenCard.behaviour}`,
  );
  const sr = story.startRule ?? rrc.startRule;
  if (sr !== null)
    add(
      "start-rule",
      "sandbox",
      `Start rule on this profile: ${sr}. Rev Rec takes over after more than ${sr} failed charge${sr === 1 ? "" : "s"} by the billing system` +
        (sc.sendDuplicateOnStart
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
  add(
    "ladder",
    "rule",
    "Static retries in production wait 1 min, then 3 h, 6 h, 9 h, 12 h and 18 h steps. The sandbox retries every few minutes.",
  );

  const stage = stageInfo.stage;
  const open = Boolean(story.recoveryId) && !FINAL_STAGES.has(stage);
  const hhmm = (iso: string) => iso.slice(11, 16);
  const latest = timeline.at(-1);
  // The "now" card: who acts at this moment, what, and why.
  const now: { actor: Actor; text: string; why: string } | null =
    status === "error"
      ? {
          actor: "billing",
          text: "The simulator could not start this story.",
          why: story.error ?? "",
        }
      : status === "starting"
        ? {
            actor: "billing",
            text: "The billing system reported the failed charge.",
            why: "Waiting for the invoice to appear in the sandbox.",
          }
        : stage === "Recovered" && recoveredBy === "revrec"
          ? {
              actor: "processor",
              text: "Stripe approved Rev Rec's retry. The invoice is paid.",
              why: `The saved card ends ${story.tokenCard.last4}. ${story.tokenCard.behaviour}`,
            }
          : stage === "Recovered"
            ? {
                actor: "customer",
                text: "The invoice was paid outside Rev Rec.",
                why: "The billing system reported a successful payment, so Rev Rec stops.",
              }
            : stage === "Terminated"
              ? {
                  actor: "revrec",
                  text: "Rev Rec stopped retrying this invoice.",
                  why: "See the explain panel for the stop rule.",
                }
              : stage === "Scheduled" && nextRetryAt
                ? {
                    actor: "revrec",
                    text: `Rev Rec booked the next retry for ${hhmm(nextRetryAt)} UTC.`,
                    why: "Static retries: the next step of the sandbox's retry ladder.",
                  }
                : stage === "Processing"
                  ? {
                      actor: "revrec",
                      text: "Rev Rec is charging the saved card now.",
                      why: "The booked retry time has come.",
                    }
                  : stage === "Queued"
                    ? {
                        actor: "revrec",
                        text: "Rev Rec is picking a retry time.",
                        why: "The start rule is met, so Rev Rec takes over from the billing system.",
                      }
                    : stage === "Monitoring"
                      ? {
                          actor: "revrec",
                          text: "Rev Rec recorded the failure and is watching.",
                          why: "Rev Rec waits until the start rule is met.",
                        }
                      : latest
                        ? { actor: latest.from, text: latest.text, why: "" }
                        : null;

  const view = {
    storyId: story.storyId,
    scenario: sc.id,
    scenarioInfo: {
      id: sc.id,
      title: sc.title,
      v1Status: sc.v1Status,
      expected: sc.expected,
      hint: sc.hint,
    },
    invoiceId: story.invoiceId,
    recoveryId: story.recoveryId,
    startedAt: story.startedAt,
    updatedAt: new Date().toISOString(),
    status,
    sandboxStatus,
    stage,
    stageCaption: caption,
    recoveredBy,
    nextRetryAt,
    // Raw sandbox JSON (secrets hidden), so the dashboard can reuse its invoice page mappers.
    invoice: intent,
    attempts: rawAttempts,
    processTracker: pt,
    // The same facts, flattened for the story screen.
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
      savedCard: story.tokenCard.last4,
      reportedReason: sc.reason.key,
      reportsSent: story.reportsSent,
      createdAt: intent?.created_at ?? null,
    },
    attemptSummary: attempts,
    now,
    explain,
    timeline,
    requests: story.requests,
    lastReads,
    actions: {
      paidInApp: open && !story.paidInAppAt,
      reportAgain: open && story.reportsSent < 8,
      reportAgainMode: sc.reportAgainMode,
    },
    warnings,
    startError: story.error,
  };
  viewCache.set(storyId, { at: Date.now(), view });
  return view;
}
