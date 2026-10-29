// The billing simulator for one invoice story.
// It plays the merchant's billing system: it creates a Stripe test customer with a saved card,
// makes real failed charges, reports them to Rev Rec on the sandbox, and reads the status back.
// Rev Rec's decisions are real. Each timeline step links to its raw request (stepId), and each
// explain line says where it comes from: sandbox, recomputed or rule.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { hasDashboardToken, revrecMerchantId } from "./auth.ts";
import {
  config,
  PROFILES,
  type ProfileKey,
  type SharedProfileKey,
  type ProfileRef,
} from "./config.ts";
import {
  dayText,
  declineMeaning,
  realLife,
  realLifeFromCalendar,
  rowRealLife,
  slotLabel,
  SMART_NOTE,
} from "./reallife.ts";
import { redact, scrubText } from "./redact.ts";
import {
  CARDS,
  CURRENCIES,
  DECLINES,
  FIRST_CHARGE_CARDS,
  presetById,
  PRESETS,
  presetText,
  resolveCards,
  SAVED_CARDS,
  type BankStory,
  type CardId,
  type FirstChargeId,
  type Preset,
  type ReportAgainMode,
  type SavedCardId,
  presetOn,
  type VisitorCardId,
  visitorCardOf,
} from "./scenarios.ts";
import {
  hsApiKey,
  hsDashboard,
  shownHsHeaders,
  stripe,
  type Upstream,
} from "./upstream.ts";
import {
  DEFAULTS as POOL_DEFAULTS,
  LEASE_MAX_MS,
  lease,
  leaseOf,
  leases_,
  poolOn,
  release,
  setBilling,
  setMode,
} from "./pool.ts";
import {
  adapterOf,
  ADAPTERS,
  BANK_ROUTES,
  type BankReasonX,
  configured as processorConfigured,
  processorOn,
  type ProcCard,
  type ProcessorId,
  processorProfile,
  type Replacement,
} from "./processors.ts";
import {
  readCalendar,
  readPause,
  realLifeNow,
  simOn,
  simPause,
} from "./simcal.ts";

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
  backupCard?: SavedCardId; // preset 9: a second saved card, reported at the handover
  goLivePreset?: boolean; // preset 10: go-live with a backlog
  queuePreset?: boolean; // preset 8: the same customer's invoice 1 is in recovery first
  bank?: BankStory; // presets 11-20: the scripted bank's rule for Rev Rec's retries
  startMode?: "static" | "smart"; // smart: the leased profile is in smart mode before the handover
  processor?: ProcessorId; // not Stripe: the processor's real test answers on its own profile
  // The visitor's one card (start field card, 28 Oct): saved for the customer; the story makes the
  // failure (Preset.failure). declines: the scripted bank declines Rev Rec's charges on it with this
  // reason until an event changes it.
  visitorCard?: VisitorCardId;
  declines?: string;
  // The visitor's max tries from the story form (1-15): set on the leased profile at the start
  maxRetries?: number;
};

// The scripted bank's rule on a Stripe customer (selfhost/sim/bank.mjs): events are applied in this
// order: stolenFrom, outages, then worksFrom.
export type BankRule = {
  v: 1;
  reason: string;
  worksFrom: Record<string, unknown>;
  // The saved card the rule is about (last 4; the sim's default 0341) and the one a win charges
  // (the sim's default: the customer's 4242). A visitor-card story names its own card for both.
  card?: string;
  goodCard?: string;
  stolenFrom?: string;
  outages?: { from: string; until: string }[];
};

// A change the visitor made to Rev Rec or to the world, at its real-life moment, for the calendar.
export type WorldEvent = {
  type:
    | "money_back"
    | "new_card"
    | "stolen"
    | "outage"
    | "setting"
    | "paused"
    | "resumed";
  at: string | null; // real life (the simulated calendar)
  until?: string | null; // an outage's end, real life
  text: string;
  madeAt: string; // when the visitor made it
};

export type Story = StartOptions & {
  // Live settings (pool.ts): why they are off for this story (null = on), the last values the
  // visitor set, the world events, and when the leased profile went back.
  settingsOff?: string | null;
  settingsSet?: {
    mode?: "static" | "smart";
    maxRetries?: number;
    graceDays?: number;
  };
  worldEvents?: WorldEvent[];
  poolReleasedAt?: string | null;
  // The scripted bank's rule now on the customer (sim_bank), once the story or an event set it.
  bankRule?: BankRule | null;
  // Paused by the visitor (selfhost/sim/pause.mjs holds Rev Rec's next retry); null when running
  pause?: {
    at: string;
    autoResumeAt: string;
    remainingMs: number | null;
  } | null;
  // A story at another processor: the card it stored (stripeCustomerId then holds its customer id),
  // and, for a bank story there, the replacements the sim's pass-through applies to decline.
  procCard?: ProcCard;
  bankReplacements?: Partial<Record<BankReasonX, Replacement[]>>;
  // Preset 8: the same customer's earlier invoice, and when the view first saw it end.
  earlier?: BacklogInvoice;
  earlierEndedAt?: string | null;
  storyId: string;
  owner: string; // hash of the visitor's IP: "same customer" means the same visitor's last customer
  invoiceId: string; // merchant_reference_id: the invoice id in the billing system
  recoveryId: string | null; // the Hyperswitch payment id Rev Rec gave the invoice
  startedAt: string;
  stripeCustomerId: string;
  savedPm: string; // the saved card's Stripe payment method, which Rev Rec retries
  started: boolean; // the billing system's start steps have finished: Rev Rec has been informed
  // A story from the story screen waits after the billing system's first failed charge, until the
  // visitor hands the invoice over (handover). Portfolio copies report at once.
  waitForHandover?: boolean;
  awaitingHandover?: boolean;
  firstFailure?: { txnId: string; error: object } | null; // the charge to report at handover
  handoverAt?: string | null;
  backupPm?: string; // the second saved card's Stripe payment method (preset 9)
  goLive?: GoLive; // preset 10: the go-live profile and the backlog invoices
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
  profile: ProfileKey; // "story" unless the portfolio run says static or smart
  // The profile and connectors the story ran on, kept so a later .env change does not move it.
  // Stories saved before 24 Oct have none: they all ran on the story profile.
  profileRef?: ProfileRef;
  paced?: boolean; // portfolio stories share the 5-calls-per-second queue
  portfolioRunId?: string;
};

const prof = (s: Story): ProfileRef => s.profileRef ?? PROFILES.story;

// Portfolio stories share one queue: at most 5 Stripe or sandbox calls per second.
let nextSlot = 0;
const PACE_MS = 200;
async function pace() {
  const now = Date.now();
  const at = Math.max(now, nextSlot);
  nextSlot = at + PACE_MS;
  if (at > now) await new Promise((ok) => setTimeout(ok, at - now));
}

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

// Who answers, in text a visitor reads: the shared sandbox, or Rev Rec on the self-hosted engine
// (HS_ENGINE). The source key "sandbox" on explain and why lines stays as it is.
const isSandbox = () => config.engine === "sandbox";
const Answerer = () => (isSandbox() ? "The sandbox" : "Rev Rec");

// Minutes in Monitoring, with the start rule met and no retry task, before the story says so.
// The fast self-hosted engine books a retry within about 10 s, so it waits 15 s there.
const WAITING_NOTE_MIN = config.fastEngine ? 0.25 : 1;

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
    if (!s.started && !s.error && !s.awaitingHandover)
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

// ---------- import of stories saved before 24 Oct (data/stories.json) ----------

// What a story of the first store looked like (commit 42aecb877 to f94d43aca).
type V1Story = {
  storyId: string;
  scenarioId: number;
  invoiceId: string;
  recoveryId: string | null;
  startedAt: string;
  amount: number;
  currency: string;
  stripeCustomerId: string;
  tokenPm: string;
  tokenCard: { last4: string };
  lastFailureBody: unknown;
  reportsSent: number;
  startRule: number | null;
  paidInAppAt: string | null;
  error: string | null;
  requests: Omit<RequestLog, "stepId">[];
};

// Facts the first store did not keep, taken from the run log of the day (cited where used).
export type V1Observations = {
  stageSeen: Record<string, string>;
  bookings: { at: string; processTracker: Record<string, unknown> }[];
};

// Turns a first-store story into a current one: each recorded request becomes a step with the
// same label a live story gets today. Used once, to make recordings of the 23 Oct stories.
export function importV1Story(v1: V1Story, seen: V1Observations): Story {
  if (stories.has(v1.storyId)) return stories.get(v1.storyId)!;
  const preset = presetById(v1.scenarioId);
  const card = v1.tokenCard.last4 as SavedCardId;
  const story: Story = {
    presetId: v1.scenarioId,
    amount: v1.amount,
    currency: v1.currency,
    savedCard: card,
    firstCharge: card === "0341" ? "0341" : "0002",
    customer: "new",
    sendDuplicateOnStart: Boolean(preset?.sendDuplicateOnStart),
    reportAgainMode: preset?.reportAgainMode ?? "new",
    storyId: v1.storyId,
    owner: "imported",
    invoiceId: v1.invoiceId,
    recoveryId: v1.recoveryId,
    startedAt: v1.startedAt,
    stripeCustomerId: v1.stripeCustomerId,
    savedPm: v1.tokenPm,
    started: true,
    lastFailureBody: v1.lastFailureBody,
    reportsSent: v1.reportsSent,
    startRule: v1.startRule,
    paidInAppAt: v1.paidInAppAt,
    error: v1.error,
    stepSeq: 0,
    events: [],
    requests: [],
    seenSchedules: seen.bookings.map((b) =>
      String(b.processTracker.schedule_time_for_payment),
    ),
    stageSeen: seen.stageSeen,
    finalNoted: false,
    profile: "story",
    profileRef: PROFILES.story,
  };
  const amount = money(story.amount, story.currency);
  for (const r of v1.requests) {
    const stepId = newStepId(story);
    story.requests.push({ ...r, stepId });
    const body: any = r.response.body;
    const ok = r.response.status === 200;
    const of = r.step.match(/\((\d+) of (\d+)\)/);
    const base = { stepId, at: r.at, why: [] as Why[] };
    if (r.step === "Create the test customer")
      story.events.push({
        ...base,
        from: "billing",
        to: "billing",
        label: `new invoice ${amount}`,
        text: `Invoice ${story.invoiceId} for ${amount} is due for a new test customer.`,
        status: "info",
        source: "simulator",
      });
    else if (r.step.startsWith("Save card"))
      story.events.push({
        ...base,
        from: "billing",
        to: "processor",
        label: `save card ••${card}`,
        text: `Card ending ${card} is saved for the customer at Stripe. Rev Rec retries the saved card.`,
        status: "ok",
        source: "simulator",
        why: [{ source: "rule", text: CARDS[card].behaviour }],
      });
    else if (r.step.startsWith("Billing system"))
      story.events.push({
        ...base,
        from: "billing",
        to: "processor",
        label: `charge ${amount}${of && of[1] !== "1" ? ` again (${of[1]} of ${of[2]})` : ""} on ••${card} → declined (${body?.error?.decline_code ?? "generic_decline"})`,
        text: `The billing system charged the card. Stripe declined it: "${body?.error?.message ?? "declined"}".`,
        status: "declined",
        source: "sandbox",
        txnId: body?.error?.payment_intent?.id,
      });
    else if (r.step.startsWith("Report the failed payment"))
      story.events.push({
        ...base,
        from: "billing",
        to: "revrec",
        label: `report failure${of ? ` (${of[1]} of ${of[2]})` : ""} → ${r.response.status}${ok ? " recorded" : ""}`,
        text: ok
          ? `The billing system reported the failed charge. Rev Rec recorded it on invoice ${body?.id}.`
          : `${Answerer()} refused the report.`,
        status: ok ? "ok" : "refused",
        source: "sandbox",
      });
    else if (r.step.startsWith("Report the same failure again"))
      story.events.push({
        ...base,
        from: "billing",
        to: "revrec",
        label: `report same failure again → ${r.response.status}${ok ? "" : " already recorded"}`,
        text: ok
          ? "The billing system sent the same failure report again. Rev Rec kept one attempt."
          : `The billing system sent the same failure report again. Rev Rec refused the copy: ${body?.error?.message ?? ""}`,
        status: ok ? "ok" : "refused",
        source: "sandbox",
        why: [
          {
            source: "rule",
            text: "Rev Rec records each transaction once. A copy with the same transaction id does not count again.",
          },
        ],
      });
    else if (r.step.startsWith("Customer adds a new card"))
      story.events.push({
        ...base,
        from: "customer",
        to: "processor",
        label: "add card ••4242 in the app",
        text: "The customer adds a new card ending 4242 in the merchant's app.",
        status: "ok",
        source: "simulator",
      });
    else if (r.step === "Customer pays in the app")
      story.events.push({
        ...base,
        from: "customer",
        to: "processor",
        label: `pay ${amount} in the app → approved`,
        text: `The customer paid ${amount} in the merchant's app. Stripe approved it (${body?.id}).`,
        status: "ok",
        source: "sandbox",
        txnId: body?.id,
      });
    else if (
      r.step.startsWith("Inform Rev Rec that the invoice was paid") ||
      r.step.startsWith("Tell Rev Rec the invoice was paid") // before 28 Oct
    )
      story.events.push({
        ...base,
        from: "billing",
        to: "revrec",
        label: `report paid outside Rev Rec → ${r.response.status}`,
        text: "The billing system informed Rev Rec that the invoice is paid.",
        status: ok ? "ok" : "refused",
        source: "sandbox",
        why: [
          {
            source: "rule",
            text: "The billing system says the invoice is paid. Rev Rec stops.",
          },
        ],
      });
  }
  // Retry bookings the first store did not keep, with the process-tracker answer seen at the time.
  for (const b of seen.bookings) {
    const stepId = newStepId(story);
    const bookedFor = String(b.processTracker.schedule_time_for_payment);
    story.requests.push({
      stepId,
      step: "Rev Rec books a retry (read from the process tracker; reconstructed from the run log)",
      at: b.at,
      system: "sandbox",
      request: {
        method: "GET",
        url: `${config.hsBaseUrl}/v2/process-trackers/revenue-recovery-workflow/${story.recoveryId}`,
        headers: shownHsHeaders("jwt", PROFILES.story.profileId),
      },
      response: { status: 200, body: b.processTracker },
      ms: null,
    });
    story.events.push({
      stepId,
      at: b.at,
      from: "revrec",
      to: "revrec",
      label: `pick retry time → ${hms(bookedFor)}`,
      text: `Rev Rec will try the saved card at ${hms(bookedFor)} UTC.`,
      status: "ok",
      source: "sandbox",
      why: [
        {
          source: "sandbox",
          text: `Booked time: ${hms(bookedFor)} UTC (from that day's run log).`,
        },
      ],
    });
  }
  story.events.sort((x, y) => x.at.localeCompare(y.at));
  stories.set(story.storyId, story);
  save();
  return story;
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

// Invoices for the contract test's read-back: the newest one, and the newest one where the
// proxy saw Rev Rec book a retry (so it has a process-tracker task).
export function contractTargets() {
  // Only stories on the story profile: the contract test reads with that profile's id.
  const newest = [...stories.values()]
    .reverse()
    .filter((s) => prof(s).profileId === PROFILES.story.profileId);
  return {
    any: newest.find((s) => s.recoveryId)?.recoveryId ?? null,
    withTask:
      newest.find((s) => s.recoveryId && s.seenSchedules?.length)?.recoveryId ??
      null,
  };
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
  if (story.paced) await pace();
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
  if (story.paced) await pace();
  const r = await hsApiKey("POST", path, body, prof(story).profileId);
  const stepId = newStepId(story);
  story.requests.push({
    stepId,
    step,
    at: nowIso(),
    system: "sandbox",
    request: {
      method: "POST",
      url: `${config.hsBaseUrl}/${path}`,
      headers: shownHsHeaders("api-key", prof(story).profileId),
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

async function saveCard(
  story: Story,
  card: SavedCardId,
  who: Actor,
  label?: string,
) {
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
      label ??
      (who === "customer"
        ? `add card ••${c.last4} in the app`
        : `save card ••${c.last4}`),
    text: `Card ending ${c.last4} is saved for the customer at Stripe. Rev Rec retries the saved card.`,
    status: "ok",
    source: "simulator",
    why: [{ source: "rule", text: c.behaviour }],
  });
  return r.json.id as string;
}

// A real off-session charge that Stripe declines: the billing system's own monthly charge (MIT).
// suffix goes after the amount on the arrow: "" for the first charge, " again (2 of 3)" for a retry.
async function failingCharge(
  story: Story,
  step: string,
  suffix: string,
  shownLast4?: string, // the card the row names, when not the saved card (a new card was added)
) {
  const first = CARDS[story.firstCharge];
  const reportsCard = story.savedCard;
  // One main card everywhere: the saved card. A one-off test card's name stays in the why lines.
  const reportsCardLast4 = shownLast4 ?? CARDS[reportsCard].last4;
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
    label: `charge ${money(story.amount, story.currency)}${suffix} on ••${reportsCardLast4} → declined (${declineCode})`,
    text: `The billing system charged card ${reportsCardLast4}. The bank said no: ${d?.plain ?? "declined"}.`,
    status: "declined",
    source: "sandbox",
    why: [
      {
        source: "sandbox",
        text: `Stripe test mode answered ${err.code ?? "card_declined"} / ${declineCode}.`,
      },
      // The sandbox keeps the card details from the report and takes only the decline from Stripe.
      ...(story.firstCharge !== story.savedCard
        ? [
            {
              source: "rule" as const,
              text: oneOffWhy(first.last4, reportsCardLast4),
            },
          ]
        : []),
      ...(d
        ? [
            {
              source: "rule" as const,
              text: `${declineCode}: ${d.plain}. ${verdict(story, d.soft)}`,
            },
          ]
        : []),
    ],
  });
  return { txnId, error: reportedError(err, declineCode, d?.ndc) };
}

// Why a story shows the saved card although Stripe declined a one-off test card.
const oneOffWhy = (testCard: string, savedCard: string) =>
  `The story used Stripe's test card ${testCard} for this decline. Stripe cannot save it, so the row shows card ${savedCard}.`;

// A new working card for the customer: 4242, or 4444 when the bank's rule is about 4242 already.
const freshCard = (story: Story): VisitorCardId =>
  story.visitorCard && CARDS[story.savedCard].last4 === "4242"
    ? "4444"
    : "4242";

// What the billing system tells Rev Rec: what its processor said. The message carries Stripe's
// decline code in the form Hyperswitch's Stripe connector gives its error reason
// ("message - <message>, decline_code - <code>", connectors/stripe.rs). Rev Rec marks the reported
// card as a hard decline from a GSM row matched on the reported code and message only
// (core/webhooks/recovery_incoming.rs, store_payment_processor_tokens_in_redis), and Stripe's
// plain message is the same for a stolen card and a generic decline. In this form, one GSM row
// matches both the reported failure and Rev Rec's own Stripe retries (check_hard_decline reads
// the reason for Stripe), and a plain card_declined stays a soft decline.
export function reportedError(
  err: { code?: string; message?: string; decline_code?: string },
  declineCode: string,
  ndc: string | undefined,
) {
  const message = err.message ?? "Your card was declined.";
  return {
    code: err.code ?? "card_declined",
    message: err.decline_code
      ? `message - ${message}, decline_code - ${err.decline_code}`
      : message,
    reason: `decline_code - ${declineCode}`,
    network_decline_code: ndc ?? "05",
  };
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
    invoiceId?: string; // another invoice of the same customer (preset 9)
    customerId?: string; // another customer (a backlog invoice of preset 10)
  },
) {
  const paid = o.status === "charged";
  const c = story.procCard ?? CARDS[o.card];
  return {
    amount_details: { order_amount: story.amount, currency: story.currency },
    merchant_reference_id: o.invoiceId ?? story.invoiceId,
    billing_merchant_connector_id: prof(story).billingMcaId,
    payment_merchant_connector_id: prof(story).paymentMcaId,
    transaction_status: o.status,
    // Sent only for a charge, and it must equal the order amount.
    ...(paid ? { amount_captured: story.amount } : {}),
    // Failures are the billing system's own off-session charges (MIT). Paying in the app is customer-present.
    customer_present: paid,
    payment_method_type: "card",
    payment_method_sub_type: "credit",
    transaction_created_at: nowIso(),
    billing_started_at: `${story.startedAt.slice(0, 10)}T00:00:00Z`,
    connector_customer_id: o.customerId ?? story.stripeCustomerId,
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
    // Another processor: some need a billing country and the customer on Rev Rec's retry (Global
    // Payments asks for the country; NOTES 27 Oct).
    ...(story.processor
      ? {
          billing: {
            address: {
              line1: "1 Main St",
              city: "San Francisco",
              state: "CA",
              zip: "94105",
              country: "US",
              first_name: "Sim",
              last_name: "Customer",
            },
            email: "sim@example.com",
          },
          customer_details: {
            id: (o.customerId ?? story.stripeCustomerId)
              .replace(/[^A-Za-z0-9_-]/g, "")
              .slice(0, 60),
            name: "Sim Customer",
            email: "sim@example.com",
          },
        }
      : {}),
  };
}

// The bodies the billing simulator sends, for a made-up invoice. The contract test (contract.ts)
// sends them with one unknown field added, so the sandbox refuses them before creating anything.
export function sampleRecoveryBodies() {
  const story = {
    invoiceId: "SIM-contract-probe",
    amount: 6540,
    currency: "USD",
    startedAt: nowIso(),
    stripeCustomerId: "cus_contract_probe",
    profile: "static",
  } as Story;
  const failure = recoveryBody(story, {
    status: "failure",
    txnId: "pi_contract_probe_failure",
    token: "pm_contract_probe",
    card: "0341",
    error: reportedError(
      {
        code: "card_declined",
        message: "Your card was declined.",
        decline_code: "generic_decline",
      },
      "generic_decline",
      "05",
    ),
  });
  const charged = recoveryBody(story, {
    status: "charged",
    txnId: "pi_contract_probe_charged",
    token: "pm_contract_probe",
    card: "4242",
  });
  return { failure, charged };
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
  o: {
    step: string;
    suffix: string;
    of: string;
    n: number;
    total: number;
    finished?: string | null;
    shownLast4?: string;
  },
) {
  const { txnId, error } = await failingCharge(
    story,
    o.step,
    o.suffix,
    o.shownLast4,
  );
  await reportFailure(story, txnId, error, o);
}

// Rev Rec's retry budget, from the engine's own numbers: max retries on the billing connector, Rev
// Rec's own retries (the attempts list) and the invoice's total_retry_count. On upstream main
// (self-hosted engine, tag 2026.10.26.0) the ceiling counts the first failure and Rev Rec's own
// retries only: a failure the billing system reports during recovery raises total_retry_count but
// leaves the budget alone (core/revenue_recovery/types.rs reopen: retry_count + 1 per Rev Rec
// retry; proven 27 Oct, st_7811abf4804f: 15 Rev Rec retries with 2 billing failures).
export function budgetOf(
  max: number | null,
  internal: { at: string }[],
  external: { at: string; status: string }[],
  fm: { total_retry_count?: number },
) {
  const firstRetryAt = internal[0]?.at;
  const billingDuringRecovery = firstRetryAt
    ? external.filter((a) => a.status !== "charged" && a.at > firstRetryAt)
        .length
    : 0;
  const used = internal.length;
  const left = max === null ? null : Math.max(0, max - used);
  const countsBilling = config.engine === "selfhost" ? false : null;
  return {
    max,
    retriesUsed: used,
    retriesLeft: left,
    invoiceTotal: fm.total_retry_count ?? null,
    billingFailuresDuringRecovery: billingDuringRecovery,
    billingFailuresUseBudget: countsBilling,
    text:
      max === null
        ? `Rev Rec retries so far: ${used}.`
        : `${left} of ${max} tries left.${
            countsBilling === false
              ? " Billing failures do not use up Rev Rec's tries."
              : ""
          }`,
    source: "recomputed" as const,
  };
}

// One event in the VM's webhook inbox (simulator/selfhost/inbox/inbox.mjs summarize()).
export type InboxEvent = {
  eventId: string;
  eventType: string;
  receivedAt: string;
  signature: "verified" | "mismatch" | "unsigned" | "no key";
  payment: { id: string | null; status: string | null; [k: string]: unknown };
};

// The engine's webhooks for one payment, from the inbox. null = no inbox, or it did not answer.
async function readWebhooks(paymentId: string): Promise<InboxEvent[] | null> {
  if (!config.inboxUrl || !config.inboxToken) return null;
  try {
    const r = await fetch(
      `${config.inboxUrl}/events?payment_id=${encodeURIComponent(paymentId)}`,
      {
        headers: { authorization: `Bearer ${config.inboxToken}` },
        signal: AbortSignal.timeout(3000),
      },
    );
    if (!r.ok) return null;
    return ((await r.json()).events ?? []) as InboxEvent[];
  } catch {
    return null;
  }
}

// One call the engine made to the stand-in decider (simulator/selfhost/decider/decider.mjs).
export type DeciderCall = {
  at: string;
  paymentId: string | null;
  cardNetwork: string | null;
  pgErrorCode: string | null;
  answer: { retryFlag: boolean; retryTime: string; decisionThreshold: number };
};

// The decider's calls for one payment. null = no decider URL, or it did not answer.
async function readDeciderCalls(
  paymentId: string,
): Promise<DeciderCall[] | null> {
  if (!config.deciderUrl) return null;
  try {
    const r = await fetch(
      `${config.deciderUrl}/calls?payment_id=${encodeURIComponent(paymentId)}`,
      { signal: AbortSignal.timeout(3000) },
    );
    if (!r.ok) return null;
    return ((await r.json()).calls ?? []) as DeciderCall[];
  } catch {
    return null;
  }
}

// After a decline: try again, or stop. On the decider profile with a second saved card, a hard
// decline stops only that card.
const verdict = (s: Story, soft: boolean) =>
  soft
    ? "Worth another try."
    : prof(s).key === "decider" && s.backupCard
      ? "Rev Rec stops using this card."
      : "Rev Rec stops.";

// The decider profile is smart without Rev Rec's model: the engine picks the card.
const modeText = (s: Story, mode: string) =>
  prof(s).key === "decider" && mode === "smart"
    ? "smart retries, no model (Rev Rec picks the card)"
    : (RETRY_MODES[mode] ?? mode);

export const DECIDER_LABEL =
  "Retry time from a stand-in decider; card choice by Rev Rec.";

// Where a booked retry time came from, on the decider profile. The engine asks the decider only for
// a saved card whose last charge failed; a card with no failed charge is booked at +1 min without a
// call (workflows/revenue_recovery.rs, call_decider_for_payment_processor_tokens_select_closest_time).
export function deciderWhy(
  calls: DeciderCall[] | null,
  bookedAt: string,
): { asked: boolean | null; why: { source: Source; text: string }[] } {
  if (calls === null)
    return {
      asked: null,
      why: [{ source: "recomputed", text: "The decider's log was not read." }],
    };
  // The engine adds up to 1 s of random delay to the decider's time.
  const booked = Date.parse(bookedAt);
  const match = calls.find(
    (c) => Math.abs(Date.parse(c.answer.retryTime) - booked) <= 2000,
  );
  if (match)
    return {
      asked: true,
      why: [
        { source: "sandbox", text: DECIDER_LABEL },
        {
          source: "sandbox",
          text: `The decider said: retry at ${hms(match.answer.retryTime)} UTC.`,
        },
      ],
    };
  return {
    asked: false,
    why: [
      { source: "sandbox", text: "No decider call for this retry." },
      {
        source: "rule",
        text: "A card with no failed charge is tried after 1 min.",
      },
    ],
  };
}

const SIGNATURE_WHY: Record<InboxEvent["signature"], string> = {
  verified:
    "The signature matches the profile's key: the webhook came from Rev Rec.",
  mismatch: "The signature does not match the profile's key.",
  unsigned: "The webhook had no signature.",
  "no key": "The inbox has no key to check the signature with.",
};

// The payment status in a webhook, in plain words. Rev Rec sends one when the invoice ends.
const WEBHOOK_PLAIN: Record<string, string> = {
  succeeded: "the invoice is recovered",
  failed: "Rev Rec stopped trying",
  processing: "a retry is running",
};

// A row for one webhook: Rev Rec tells the billing system what happened.
export function webhookRow(e: InboxEvent, i: number): StoryEvent {
  return {
    stepId: `wh_${e.eventId || i}`,
    at: e.receivedAt,
    from: "revrec",
    to: "billing",
    label: `webhook ${e.eventType}`,
    text: `Webhook to the billing system: ${WEBHOOK_PLAIN[e.payment.status ?? ""] ?? `status ${e.payment.status ?? "not given"}`}.`,
    status: "info",
    source: "sandbox",
    why: [
      {
        source: "rule",
        text: "Rev Rec sends one webhook when the invoice ends.",
      },
      {
        source: "recomputed",
        text: SIGNATURE_WHY[e.signature] ?? SIGNATURE_WHY.unsigned,
      },
    ],
  };
}

// Why lines for a report on a finished invoice: what Rev Rec did with it, in plain words.
export function closedWhy(finished: string | null | undefined, r: Upstream) {
  if (!finished) return [];
  const stage = finished === "Terminated" ? "stopped" : finished.toLowerCase();
  const msg: string = r.json?.error?.message ?? "";
  return [
    {
      source: "rule" as const,
      text:
        r.status === 200
          ? `The invoice was already ${stage}. Rev Rec still recorded this failure.`
          : `The invoice is ${stage}, so Rev Rec refuses a new failure report.`,
    },
    ...(/Failed to load recovery attempt/i.test(msg)
      ? [
          {
            source: "rule" as const,
            text: 'Rev Rec answers 404 "Failed to load recovery attempt". The invoice is closed.',
          },
        ]
      : []),
  ];
}

// The billing system tells Rev Rec about one failed charge.
async function reportFailure(
  story: Story,
  txnId: string,
  error: object,
  o: {
    of: string;
    n: number;
    total: number;
    finished?: string | null;
  },
) {
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
  const pn = story.processor ? adapterOf(story.processor)!.name : "Stripe";
  event(story, {
    stepId,
    from: "billing",
    to: "revrec",
    label: `report failure${o.of} → ${r.status}${r.status === 200 ? " recorded" : ""}`,
    text:
      r.status === 200
        ? "The billing system reported the failed charge. Rev Rec recorded it."
        : `The billing system reported the failed charge. ${Answerer()} refused it.`,
    status: r.status === 200 ? "ok" : "refused",
    source: "sandbox",
    why: [
      {
        source: "rule",
        text: "The billing system informs Rev Rec that the charge failed.",
      },
      {
        source: "rule",
        text: `${Answerer()} checks the charge with ${pn} and records ${pn}'s own decline.`,
      },
      ...(sr !== null && o.total > 1
        ? [
            {
              source: "sandbox" as const,
              text: `Start rule: ${sr}. This is failure ${o.n} of ${o.total}.`,
            },
          ]
        : []),
      ...closedWhy(o.finished, r),
      // A failure reported while Rev Rec retries (after the handover): its effect on the budget.
      ...(!o.finished &&
      config.engine === "selfhost" &&
      r.status === 200 &&
      story.started
        ? [
            {
              source: "rule" as const,
              text: "Billing failures do not use up Rev Rec's tries.",
            },
          ]
        : []),
    ],
  });
  if (r.status !== 200) {
    // A finished invoice's refusal is the answer the visitor asked for, not an error.
    if (o.finished) return;
    throw rejected(story, r, `POST /${config.hsRecoveryPath}`);
  }
  story.reportsSent += 1;
  story.recoveryId = r.json.id;
  story.lastFailureBody = body;
}

// The billing system sends the same failure again (same transaction id).
// On 14 Oct the sandbox answered 200 and kept one attempt. Since 23 Oct it answers
// 400 "already recorded against the invoice". Both mean Rev Rec did not record the copy.
async function reportDuplicate(story: Story, finished: string | null = null) {
  const { r, stepId } = await sandboxStep(
    story,
    "Report the same failure again (duplicate)",
    story.lastFailureBody,
  );
  const msg: string = r.json?.error?.message ?? "";
  const refused = r.status === 400 && /already recorded/i.test(msg);
  if (r.status !== 200 && !refused) {
    if (!finished) throw rejected(story, r, `POST /${config.hsRecoveryPath}`);
    event(story, {
      stepId,
      from: "billing",
      to: "revrec",
      label: `report same failure again → ${r.status}`,
      text: `The billing system sent the same failure report again. ${Answerer()} refused it.`,
      status: "refused",
      source: "sandbox",
      why: closedWhy(finished, r),
    });
    return;
  }
  story.reportsSent += 1;
  event(story, {
    stepId,
    from: "billing",
    to: "revrec",
    label: `report same failure again → ${r.status}${refused ? " already recorded" : ""}`,
    text: refused
      ? "The billing system sent the same failure report again. Rev Rec refused the copy: it already has this charge."
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
  if (body.processor !== undefined && body.processor !== "stripe") {
    const a = adapterOf(String(body.processor));
    if (a && !processorOn(a))
      throw new HttpError(409, "Only Stripe is on in this demo for now.");
    if (!a || !processorConfigured(a))
      throw new HttpError(
        400,
        `processor must be "stripe" or one of: ${ADAPTERS.filter(
          processorConfigured,
        )
          .map((x) => x.id)
          .join(", ")}`,
      );
    const presetAsked = body.preset ?? body.scenario;
    const p =
      presetAsked !== undefined ? presetById(Number(presetAsked)) : null;
    if (presetAsked !== undefined && Number(presetAsked) !== 2 && !p?.bank)
      throw new HttpError(
        400,
        `${a.name} runs the Temporary error and real-world stories only.`,
      );
  }
  if (
    body.mode !== undefined &&
    body.mode !== "static" &&
    body.mode !== "smart"
  )
    throw new HttpError(400, 'mode must be "static" or "smart"');
  const bad = (m: string, code = "bad_request") =>
    new HttpError(400, m, undefined, code);
  const presetRaw = body.preset ?? body.scenario;
  let preset: Preset | null = null;
  if (presetRaw !== undefined && presetRaw !== null) {
    preset = presetById(Number(presetRaw)) ?? null;
    if (!preset)
      throw bad(
        `unknown preset ${presetRaw}; use 1 to ${PRESETS.length}`,
        "bad_scenario",
      );
    if (!presetOn(preset))
      throw new HttpError(409, "This story is off in this demo.");
  }
  const amount = body.amount === undefined ? 6540 : Number(body.amount);
  if (!Number.isInteger(amount) || amount < 50 || amount > 1_000_000)
    throw bad(
      "amount is in minor units: an integer from 50 to 1000000 (6540 = 65.40)",
    );
  const currency = String(body.currency ?? "USD").toUpperCase();
  if (!CURRENCIES.includes(currency))
    throw bad(`currency must be one of ${CURRENCIES.join(", ")}`);
  const maxRetries = body.maxRetries;
  if (
    maxRetries !== undefined &&
    !(Number.isInteger(maxRetries) && maxRetries >= 1 && maxRetries <= 15)
  )
    throw bad("maxRetries must be a whole number from 1 to 15");
  const max =
    maxRetries !== undefined ? { maxRetries: maxRetries as number } : {};
  // The visitor's one card (28 Oct): an approving test card, by its last 4 or its full number. Then
  // the story makes the failure. The older fields (savedCard, firstCharge, or a declining card as
  // card) keep their meaning. Stripe stories only.
  const visitor =
    body.processor === undefined || body.processor === "stripe"
      ? body.card === undefined
        ? body.savedCard === undefined && body.firstCharge === undefined
          ? ("4242" as const)
          : null
        : visitorCardOf(body.card)
      : null;
  if (visitor) {
    const f = preset?.failure ?? {
      firstCharge: (preset?.bank ? preset.card : "0002") as FirstChargeId,
    };
    const customer = body.customer ?? preset?.customer ?? "new";
    if (customer !== "new" && customer !== "same")
      throw bad('customer must be "new" or "same"');
    return {
      presetId: preset?.id ?? null,
      amount,
      currency,
      savedCard: f.firstSaved ?? visitor,
      firstCharge: f.firstCharge,
      customer,
      sendDuplicateOnStart: Boolean(
        body.duplicate ?? preset?.sendDuplicateOnStart,
      ),
      reportAgainMode: preset?.reportAgainMode ?? "new",
      ...(f.firstSaved ? { backupCard: visitor } : {}),
      ...(preset?.goLive ? { goLivePreset: true } : {}),
      ...(preset?.queue ? { queuePreset: true } : {}),
      ...(preset?.bank ? { bank: preset.bank } : {}),
      ...(body.mode === "smart" ? { startMode: "smart" as const } : {}),
      visitorCard: visitor,
      ...(f.declines ? { declines: f.declines } : {}),
      ...max,
    };
  }
  const card = card4(body.card) ?? preset?.card;
  const savedCard = card4(body.savedCard);
  const firstCharge = card4(body.firstCharge);
  if (card && !(card in CARDS))
    throw bad(
      "card must be a Stripe test card that approves, for example 4242 or 5555 5555 5555 4444",
    );
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
    ...(preset?.backupCard ? { backupCard: preset.backupCard } : {}),
    ...(preset?.goLive ? { goLivePreset: true } : {}),
    ...(preset?.queue ? { queuePreset: true } : {}),
    ...(preset?.bank ? { bank: preset.bank } : {}),
    ...(body.mode === "smart" ? { startMode: "smart" as const } : {}),
    ...(body.processor && body.processor !== "stripe"
      ? { processor: body.processor as ProcessorId }
      : {}),
    ...max,
  };
}

// Creates the story and returns at once. The billing system's steps run in the background,
// so the dashboard sees each step appear while it polls. `done` settles when the start ends.
export function startStory(
  opts: StartOptions,
  owner: string,
  extra: {
    profile?: SharedProfileKey;
    // A profile of its own (a leased one), instead of PROFILES[profile].
    profileRef?: ProfileRef;
    // Lease a pool profile, so the visitor can change Rev Rec's settings mid-run (pool.ts).
    leasePool?: boolean;
    invoiceId?: string;
    portfolioRunId?: string;
    paced?: boolean;
    waitForHandover?: boolean;
  } = {},
): { story: Story; done: Promise<void> } {
  const storyId = `st_${crypto.randomBytes(6).toString("hex")}`;
  const leased =
    extra.leasePool && poolOn() && !opts.processor ? lease(storyId) : null;
  const procRef = opts.processor ? processorProfile(opts.processor) : null;
  const story: Story = {
    ...opts,
    storyId,
    owner,
    settingsOff: leased
      ? null
      : procRef
        ? `This story runs on ${adapterOf(opts.processor!)!.name}'s own profile, so its settings stay fixed.`
        : !extra.leasePool
          ? SETTINGS_OFF.shared
          : poolOn()
            ? SETTINGS_OFF.busy
            : SETTINGS_OFF.none,
    worldEvents: [],
    profile: leased
      ? "pool"
      : (extra.profileRef?.key ?? extra.profile ?? "story"),
    profileRef:
      leased ??
      procRef ??
      extra.profileRef ??
      PROFILES[extra.profile ?? "story"],
    paced: extra.paced,
    waitForHandover: extra.waitForHandover,
    portfolioRunId: extra.portfolioRunId,
    // "SIM-" prefix lets later sessions hide old demo invoices (the sandbox has no delete).
    invoiceId:
      extra.invoiceId ??
      `SIM-${opts.presetId ?? 0}-${Date.now().toString(36)}-${crypto.randomBytes(2).toString("hex")}`,
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
  const done = withLock(storyId, () => runStart(story)).catch((e) => {
    story.error = scrubText(String((e as Error).message ?? e));
    console.log(`story ${storyId} start failed: ${story.error}`);
    viewCache.delete(storyId);
    save();
    if (leased && !story.recoveryId) void release(storyId).catch(() => {});
  });
  return { story, done };
}

// ---------- live settings (pool.ts) ----------

// A story started in smart mode: its leased profile goes to smart before the first charge, so Rev
// Rec's first decision is already the model's.
async function startInSmart(story: Story) {
  if (story.profile !== "pool") return; // no lease: the server refuses a smart start then
  const r = await setMode(prof(story), "smart");
  if (r?.status !== 200)
    throw new HttpError(
      502,
      `smart mode not set (${r?.status})`,
      story.storyId,
    );
  revrecConfigs.delete(prof(story).profileId + prof(story).billingMcaId);
  (story.settingsSet ??= {}).mode = "smart";
  event(story, {
    stepId: newStepId(story),
    from: "billing",
    to: "revrec",
    label: "setting: retry mode → smart",
    text: "This story starts with smart retries.",
    status: "info",
    source: "simulator",
    why: [
      {
        source: "rule",
        text: "Rev Rec's model picks the time from its first decision.",
      },
    ],
  });
  (story.worldEvents ??= []).push({
    type: "setting",
    at: null,
    text: "You set the retry mode to smart.",
    madeAt: nowIso(),
  });
}

// The visitor's max tries from the story form: set on the leased profile before the handover, as
// POST /settings does mid-run (the server refuses it for a story with no lease)
async function startMaxRetries(story: Story, n: number) {
  const off = settingsOffOf(story);
  if (off) throw new HttpError(409, off, story.storyId);
  const ref = prof(story);
  revrecConfigs.delete(ref.profileId + ref.billingMcaId);
  const cur = await readRevRecConfig(ref);
  if (cur.maxRetries !== n) {
    const r = await setBilling(ref, {
      maxRetries: n,
      graceDays: cur.gracePeriodDays ?? POOL_DEFAULTS.graceDays,
    });
    if (r?.status !== 200)
      throw new HttpError(
        502,
        `max tries not set (${r?.status})`,
        story.storyId,
      );
  }
  revrecConfigs.delete(ref.profileId + ref.billingMcaId);
  (story.settingsSet ??= {}).maxRetries = n;
  event(story, {
    stepId: newStepId(story),
    from: "billing",
    to: "revrec",
    label: `setting: max tries → ${n}`,
    text: `This story starts with max tries ${n}.`,
    status: "info",
    source: "simulator",
    why: [{ source: "rule", text: `Rev Rec stops after ${n} tries.` }],
  });
  (story.worldEvents ??= []).push({
    type: "setting",
    at: null,
    text: `You set max tries to ${n}.`,
    madeAt: nowIso(),
  });
}

// A smart start on a profile the story does not lease (28 Oct: the dashboard starts smart only). The
// processor profiles are smart with Rev Rec's model (selfhost/smart-profiles.sh); the decider profile
// (presets 8 and 9) is smart without it (seed.sh 6c); the story runs as its profile does. The go-live
// story turns Rev Rec on in smart itself. null = allowed; undefined = no such profile (the pool decides).
export async function fixedSmartOff(
  opts: StartOptions,
  shared?: SharedProfileKey,
): Promise<string | null | undefined> {
  if (opts.goLivePreset) return null;
  const ref = opts.processor
    ? processorProfile(opts.processor)
    : shared
      ? PROFILES[shared]
      : null;
  if (!ref) return undefined;
  const mode = (await readRevRecConfig(ref).catch(() => null))?.retryMode;
  if (mode === "smart") return null;
  return opts.processor
    ? `${adapterOf(opts.processor)!.name} runs static retries on this engine.`
    : "This story's profile runs static retries on this engine.";
}

// Why the settings are off for a story, in plain words.
export const SETTINGS_OFF = {
  shared: "This story runs on a shared profile, so its settings stay fixed.",
  busy: "All demo profiles are busy, so settings are off for this story.",
  none: "Live settings are not set up on this engine.",
};
// Controls the engine does not honour on an invoice it already has (NOTES 27 Oct 19:30Z).
export const PAUSE_OFF = "Pause needs the sim service on our engine.";
// Why the visitor cannot pause now (null = they can)
function pauseOff(s: Story): string | null {
  if (!simOn()) return PAUSE_OFF;
  if (s.goLive) return "The go-live story has its own steps.";
  if (!s.recoveryId || !s.started || closedStage(s) || s.poolReleasedAt)
    return "Rev Rec is not retrying this invoice now.";
  return null;
}

// Pause (28 Oct): the sim service holds Rev Rec's next retry for this invoice; the demo clock stops.
async function pauseInner(story: Story) {
  if (story.pause) return;
  const off = pauseOff(story);
  if (off) throw new HttpError(409, off);
  const p = await simPause(story.recoveryId!, "pause");
  if (!p?.paused)
    throw new HttpError(502, "The sim service did not pause the invoice.");
  const realNow = await realLifeNowOf(story).catch(() => null);
  (story.worldEvents ??= []).push({
    type: "paused",
    at: realNow,
    text: "Paused.",
    madeAt: nowIso(),
  });
  story.pause = {
    at: p.at!,
    autoResumeAt: p.autoResumeAt!,
    remainingMs: p.remainingMs,
  };
  event(story, {
    stepId: newStepId(story),
    from: "billing",
    to: "revrec",
    label: "Paused",
    text: "You paused Rev Rec. The next retry waits.",
    status: "info",
    source: "simulator",
    why: [
      ...(p.remainingMs !== null
        ? [
            {
              source: "rule" as const,
              text: `The next retry had ${Math.round(p.remainingMs / 1000)} s left. It gets them back.`,
            },
          ]
        : []),
      {
        source: "rule",
        text: "The demo clock stops. Real-life days stay right.",
      },
      { source: "rule", text: "A pause ends by itself after 15 minutes." },
    ],
  });
  viewCache.delete(story.storyId);
  save();
}

async function resumeInner(
  story: Story,
  why: "visitor" | "auto" | "end" = "visitor",
) {
  if (!story.pause) return;
  const p = await simPause(story.recoveryId!, "resume");
  if (!p || p.paused)
    throw new HttpError(502, "The sim service did not resume the invoice.");
  const held = story.pause.remainingMs;
  const realNow = await realLifeNowOf(story).catch(() => null);
  (story.worldEvents ??= []).push({
    type: "resumed",
    at: realNow,
    text: why === "auto" ? "Resumed by itself." : "Resumed.",
    madeAt: nowIso(),
  });
  story.pause = null;
  if (why !== "end")
    event(story, {
      stepId: newStepId(story),
      from: "billing",
      to: "revrec",
      label: "Resumed",
      text:
        why === "auto"
          ? "Rev Rec resumed by itself after 15 minutes."
          : "You resumed Rev Rec.",
      status: "info",
      source: "simulator",
      why:
        held !== null
          ? [
              {
                source: "rule",
                text: `The next retry runs in ${Math.round(held / 1000)} s.`,
              },
            ]
          : [],
    });
  viewCache.delete(story.storyId);
  save();
}

export const pauseStory = (storyId: string) => {
  const story = getStory(storyId);
  return withLock(storyId, () => pauseInner(story));
};
export const resumeStory = (storyId: string) => {
  const story = getStory(storyId);
  return withLock(storyId, () => resumeInner(story));
};
export const GRACE_OFF =
  "The engine counts real days; this demo runs in minutes.";
const SMART_OFF = "Smart on these profiles is being set up.";
// Settings are on only for a story on a leased pool profile (older stories have no reason stored).
const settingsOffOf = (s: Story) =>
  s.profile === "pool" && !s.settingsOff
    ? null
    : (s.settingsOff ?? SETTINGS_OFF.shared);
const ENDED_OFF = "The invoice has ended, so its settings stay fixed.";
const engineMode = (m: "static" | "smart") =>
  m === "static" ? "cascading" : "smart";
const shownMode = (m: string | null) =>
  m === "cascading" ? "static" : m === "smart" ? "smart" : m;

// The real-life moment "now" for a story: the sim calendar's, else the fixed timetable's slot of
// Rev Rec's latest retry (or the failure when there is none).
async function realLifeNowOf(story: Story): Promise<string | null> {
  if (story.recoveryId && simOn()) {
    const cal = await readCalendar(story.recoveryId);
    if (cal) return realLifeNow(cal);
  }
  const v: any = await storyView(story.storyId);
  const n: number = v.counts?.revrecRetries ?? 0;
  return n
    ? (v.realLife?.slots?.[n - 1]?.at ?? null)
    : (v.realLife?.failureAt ?? null);
}

// POST /sim/story/:id/settings {mode?, maxRetries?, graceDays?, paused?}: the visitor changes
// Rev Rec's settings for this invoice. Max tries and the mode take effect at Rev Rec's next
// decision (proven 27 Oct). Grace works in smart mode only: the model plans inside the grace period
// (a short one makes it give no time, and the engine falls back to the fixed timetable; proven 27
// Oct), and the sim calendar reads it at each pick; on static the engine counts real days. Pause is
// refused with the reason.
export function changeSettings(storyId: string, body: any) {
  const story = getStory(storyId);
  return withLock(storyId, async () => {
    const off = settingsOffOf(story);
    if (off) throw new HttpError(409, off);
    if (closedStage(story) || story.poolReleasedAt)
      throw new HttpError(409, ENDED_OFF);
    if (body.paused === true) await pauseInner(story);
    if (body.paused === false) await resumeInner(story);
    const mode = body.mode;
    if (mode !== undefined && mode !== "static" && mode !== "smart")
      throw new HttpError(400, 'mode must be "static" or "smart"');
    if (mode === "smart" && !config.poolSmart)
      throw new HttpError(409, SMART_OFF);
    const max = body.maxRetries;
    if (max !== undefined && !(Number.isInteger(max) && max >= 1 && max <= 15))
      throw new HttpError(
        400,
        "maxRetries must be a whole number from 1 to 15",
      );
    const grace = body.graceDays;
    if (
      grace !== undefined &&
      !(Number.isInteger(grace) && grace >= 1 && grace <= 30)
    )
      throw new HttpError(400, "graceDays must be a whole number from 1 to 30");
    if (mode === undefined && max === undefined && grace === undefined) {
      // {paused} alone: done above (POST /pause and /resume never come here)
      if (body.paused === true || body.paused === false) return;
      throw new HttpError(400, "Nothing to change in the settings.");
    }
    // A pool profile starts static; only this endpoint changes its mode.
    const modeAfter = mode ?? story.settingsSet?.mode ?? "static";
    if (grace !== undefined && modeAfter !== "smart")
      throw new HttpError(409, GRACE_OFF);
    const ref = prof(story);
    revrecConfigs.delete(ref.profileId + ref.billingMcaId);
    const cur = await readRevRecConfig(ref);
    const at = await realLifeNowOf(story).catch(() => null);
    const note = (label: string, text: string, why: string) => {
      event(story, {
        stepId: newStepId(story),
        from: "billing",
        to: "revrec",
        label,
        text,
        status: "info",
        source: "simulator",
        why: [{ source: "rule", text: why }],
      });
      (story.worldEvents ??= []).push({
        type: "setting",
        at,
        text,
        madeAt: nowIso(),
      });
    };
    if (mode !== undefined && shownMode(cur.retryMode) !== mode) {
      const r = await setMode(ref, engineMode(mode));
      if (r?.status !== 200)
        throw new HttpError(
          502,
          `the retry mode did not change (${r?.status})`,
        );
      (story.settingsSet ??= {}).mode = mode;
      note(
        `setting: retry mode → ${mode}`,
        `You set the retry mode to ${mode}.`,
        mode === "smart"
          ? "From its next decision, Rev Rec's model picks the time."
          : "From its next decision, Rev Rec follows the fixed timetable.",
      );
    }
    const maxChanged = max !== undefined && cur.maxRetries !== max;
    const graceChanged = grace !== undefined && cur.gracePeriodDays !== grace;
    if (maxChanged || graceChanged) {
      const r = await setBilling(ref, {
        maxRetries: max ?? cur.maxRetries ?? POOL_DEFAULTS.maxRetries,
        graceDays: grace ?? cur.gracePeriodDays ?? POOL_DEFAULTS.graceDays,
      });
      if (r?.status !== 200)
        throw new HttpError(502, `the setting did not change (${r?.status})`);
    }
    if (maxChanged) {
      (story.settingsSet ??= {}).maxRetries = max;
      note(
        `setting: max tries → ${max}`,
        `You set max tries to ${max}.`,
        "Rev Rec reads the new value at its next decision.",
      );
    }
    if (graceChanged) {
      (story.settingsSet ??= {}).graceDays = grace;
      note(
        `setting: grace period → ${grace} days`,
        `You set the grace period to ${grace} days.`,
        "Rev Rec's model plans only inside the grace period.",
      );
    }
    revrecConfigs.delete(ref.profileId + ref.billingMcaId);
    viewCache.delete(storyId);
    save();
  });
}

// ---------- what happens next: the visitor changes the world ----------

export type WorldEventType = "money_back" | "new_card" | "stolen" | "outage";
const OUTAGE_HOURS = 6;
// The bank's reason for a story's decline (null = a hard decline: the bank cannot script it).
const BANK_REASONS = new Set([
  "generic_decline",
  "insufficient_funds",
  "processing_error",
  "card_velocity_exceeded",
  "do_not_honor",
]);
const bankReasonOf = (s: Story) =>
  s.bank?.reason ??
  (BANK_REASONS.has(CARDS[s.firstCharge].declineCode ?? "")
    ? CARDS[s.firstCharge].declineCode!
    : null);

// Why an event is not possible now (null = it is). `now` is the real-life moment.
function eventOff(
  s: Story,
  type: WorldEventType,
  now: string | null,
): string | null {
  const route = s.processor ? BANK_ROUTES[s.processor] : undefined;
  if (s.pause) return "Resume first. Events wait while the story is paused.";
  // Policy (28 Oct): no charge on a card the customer did not give for this invoice
  if (type === "new_card" && !config.otherCards)
    return "A new card is not part of this demo.";
  if (s.processor && !s.bankRule)
    return "Events work in real-world stories and Stripe stories only.";
  if (s.processor && type === "new_card")
    return "New card added works in Stripe stories only.";
  if (!s.recoveryId || !s.started || closedStage(s))
    return "Rev Rec is not retrying this invoice now.";
  if (s.goLive) return "The go-live story has its own steps.";
  if (type === "new_card")
    return (
      s.visitorCard ? s.savedCard !== s.visitorCard : s.savedCard === "4242"
    )
      ? "The customer already has a working card."
      : reportCount(s) >= MAX_REPORTS
        ? "This story has sent all its reports."
        : null;
  if (route && type === "stolen" && !route.says.stolen_card)
    return `${adapterOf(s.processor!)!.name}'s test mode has no stolen-card answer.`;
  if (route && type === "outage" && !route.says.processing_error)
    return `${adapterOf(s.processor!)!.name}'s test mode has no bank-outage answer.`;
  // The bank decides Rev Rec's charges on the saved card 0341 only (Stripe).
  if (!s.processor && s.savedCard !== "0341" && s.savedCard !== s.visitorCard)
    return "This story's saved card already works, so the bank cannot change it.";
  const rule = s.bankRule;
  if (type === "money_back") {
    if (!bankReasonOf(s))
      return "The card is reported stolen. Money cannot fix that.";
    if (rule?.stolenFrom)
      return "The card is reported stolen. Money cannot fix that.";
    if (rule && "at" in rule.worksFrom) return "The money is already back.";
    return null;
  }
  if (type === "stolen")
    return rule?.stolenFrom ? "The card is already reported stolen." : null;
  // outage
  return now &&
    (rule?.outages ?? []).some((o) => o.from <= now && now < o.until)
    ? "The bank is already down."
    : null;
}

// Writes the bank's rule on the customer (and, the first time, saves the card the bank charges when
// a charge works). A story without a bank rule gets one that never works by itself: the same as
// its saved card 0341, which Stripe always declines.
async function writeBankRule(story: Story, rule: BankRule, step: string) {
  if (story.processor) {
    await registerBank(story, rule);
    return newStepId(story);
  }
  if (!story.bankRule && !rule.goodCard) {
    const card = await stripe("POST", "payment_methods/pm_card_visa/attach", {
      customer: story.stripeCustomerId,
    });
    if (!card.json?.id)
      throw new HttpError(
        502,
        `bank card not saved: ${stripeError(card)}`,
        story.storyId,
      );
  }
  const { r, stepId } = await stripeStep(
    story,
    step,
    `customers/${story.stripeCustomerId}`,
    { "metadata[sim_bank]": JSON.stringify(rule) },
  );
  if (r.status !== 200)
    throw new HttpError(
      502,
      `bank rule not saved: ${stripeError(r)}`,
      story.storyId,
    );
  story.bankRule = rule;
  return stepId;
}

// The sim service's registry for a bank story at another processor: its good token, the
// replacements that make the processor decline, and the rule (selfhost/sim, C's pass-through).
async function registerBank(story: Story, rule: BankRule) {
  const r = await fetch(`${config.simUrl}/bank/stories`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${config.simToken}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      v: 1,
      processor: story.processor,
      storyId: story.storyId,
      invoiceId: story.invoiceId,
      goodToken: story.savedPm,
      match: BANK_ROUTES[story.processor!]?.match?.(story.savedPm ?? ""),
      replacements: story.bankReplacements ?? {},
      rule,
    }),
    signal: AbortSignal.timeout(10_000),
  }).catch(() => null);
  if (!r?.ok)
    throw new HttpError(
      502,
      `the bank did not take the story's rule (${r?.status ?? "no answer"})`,
      story.storyId,
    );
  story.bankRule = rule;
}

// The sim keeps bank rules in memory only. Open processor bank stories post theirs again every
// 15 s (server.ts), so a sim restart leaves at most 15 s undecided (a repeat post replaces it).
export async function repostBanks() {
  for (const s of stories.values())
    if (
      s.processor &&
      processorOn(adapterOf(s.processor)!) &&
      s.bankRule &&
      !s.error &&
      !closedStage(s) &&
      Date.now() - Date.parse(s.startedAt) < 2 * 3600_000
    )
      await registerBank(s, s.bankRule).catch(() => {});
}

// Which processors the sim's pass-through handles now (GET /bank/processors), for a minute.
let bankCache: { at: number; ids: Set<string> } | null = null;
export async function bankProcessors(): Promise<Set<string>> {
  if (bankCache && Date.now() - bankCache.at < 60_000) return bankCache.ids;
  let ids = new Set<string>();
  if (simOn()) {
    const r = await fetch(`${config.simUrl}/bank/processors`, {
      headers: { authorization: `Bearer ${config.simToken}` },
      signal: AbortSignal.timeout(5_000),
    }).catch(() => null);
    const j: any = r?.ok ? await r.json().catch(() => null) : null;
    ids = new Set([
      ...(Array.isArray(j?.processors) ? j.processors : []),
      ...config.bankProof,
    ]);
  }
  bankCache = { at: Date.now(), ids };
  return ids;
}

// POST /sim/story/:id/event {type}: money back, a new card, the card stolen, a bank outage. Each
// applies from the current real-life moment of the story's calendar, so Rev Rec's next retry sees it.
export function worldEvent(storyId: string, type: WorldEventType) {
  const story = getStory(storyId);
  return withLock(storyId, async () => {
    const now = await realLifeNowOf(story).catch(() => null);
    const off = eventOff(story, type, now);
    if (off) throw new HttpError(409, off);
    if (!now) throw new HttpError(409, "The story has no real-life time yet.");
    const base: BankRule = story.bankRule ?? {
      v: 1,
      reason: bankReasonOf(story) ?? "generic_decline",
      worksFrom: { afterHours: 100_000 },
      ...visitorRule(story),
    };
    const add = (e: Omit<WorldEvent, "madeAt">) =>
      (story.worldEvents ??= []).push({ ...e, madeAt: nowIso() });
    if (type === "new_card") {
      const old = CARDS[story.savedCard].last4;
      const fresh = freshCard(story);
      story.savedPm = await saveCard(
        story,
        fresh,
        "customer",
        `customer: saved a new card ••${fresh}`,
      );
      story.savedCard = fresh;
      // The billing system's next charge on the old card fails; its report names the new card.
      await chargeAndReport(story, {
        step: "Billing system charges again and reports the new card",
        suffix: " again",
        of: " with the new card",
        n: 1,
        total: 1,
        shownLast4: old,
      });
      add({ type, at: now, text: `The customer saved a new card ••${fresh}.` });
    } else if (type === "money_back") {
      const stepId = await writeBankRule(
        story,
        { ...base, worksFrom: { at: now } },
        "The customer's money is back: the bank approves from now",
      );
      event(story, {
        stepId,
        from: "customer",
        to: "processor",
        label: "customer: money is back",
        text: "The customer's account has money again.",
        status: "info",
        source: "simulator",
        why: [
          { source: "rule", text: "Rev Rec's next try works." },
          { source: "rule", text: "The bank approves charges from now on." },
        ],
      });
      add({ type, at: now, text: "The money is back." });
    } else if (type === "stolen") {
      const stepId = await writeBankRule(
        story,
        { ...base, stolenFrom: now },
        "The customer reports the card stolen",
      );
      event(story, {
        stepId,
        from: "customer",
        to: "processor",
        label: "customer: card reported stolen",
        text: `The customer reports card ${CARDS[story.savedCard].last4} stolen.`,
        status: "info",
        source: "simulator",
        why: [
          {
            source: "rule",
            text: "From now on, a charge on it is a hard decline.",
          },
        ],
      });
      add({ type, at: now, text: "The card is reported stolen." });
    } else {
      const until = new Date(
        Date.parse(now) + OUTAGE_HOURS * 3_600_000,
      ).toISOString();
      const stepId = await writeBankRule(
        story,
        { ...base, outages: [...(base.outages ?? []), { from: now, until }] },
        "The bank goes down for 6 hours",
      );
      event(story, {
        stepId,
        from: "processor",
        to: "processor",
        label: `bank outage: ${OUTAGE_HOURS} hours`,
        text: `The bank is down for ${OUTAGE_HOURS} hours (real life).`,
        status: "info",
        source: "simulator",
        why: [
          {
            source: "rule",
            text: "Charges fail with a processing error until then.",
          },
        ],
      });
      add({ type, at: now, until, text: "The bank is down for 6 hours." });
    }
    viewCache.delete(storyId);
    save();
  });
}

const HANDOVER_WAIT_MS = 10 * 60_000;

// Takes back pool profiles: a failed reset (tried again), a lease whose story is gone or failed to
// start, a lease whose invoice has ended (a fresh view sees it), and a lease older than LEASE_MAX_MS
// (its invoice is cancelled first if still open).
export async function sweepPool() {
  for (const l of leases_()) {
    const s = stories.get(l.storyId);
    const old = Date.now() - Date.parse(l.leasedAt) > LEASE_MAX_MS;
    // A story still waiting for its handover after 10 minutes gives its profile back (the visitor
    // left); its handover is refused from then on.
    if (
      s?.awaitingHandover &&
      Date.now() - Date.parse(s.startedAt) > HANDOVER_WAIT_MS
    ) {
      s.awaitingHandover = false;
      s.error =
        "This story waited too long for the handover. Start a new story.";
      s.poolReleasedAt = nowIso();
      viewCache.delete(s.storyId);
      await release(l.storyId);
      save();
      continue;
    }
    if (!s || (s.error && !s.recoveryId)) await release(l.storyId);
    // A story the dashboard stopped polling (its point made, e.g. the duplicate preset) still has
    // an invoice that ends later: a fresh view sees the end and gives the profile back.
    else if (s.recoveryId && !s.poolReleasedAt && !old) {
      viewCache.delete(s.storyId);
      await storyView(s.storyId).catch(() => null);
    } else if (old) {
      // Only a lease that ends takes its pause with it (a paused story keeps its lease)
      if (s.pause) await resumeInner(s, "end").catch(() => {});
      if (s.recoveryId && !closedStage(s))
        await cancelStory(s.storyId).catch(() => {});
      s.poolReleasedAt = nowIso();
      await release(l.storyId);
      save();
    }
  }
}

// The visitor's last story that has a Stripe customer.
export const lastCustomerStory = (owner: string, exceptId = "") =>
  [...stories.values()]
    .reverse()
    .find(
      (s) => s.owner === owner && s.storyId !== exceptId && s.stripeCustomerId,
    );

// Whether any story's invoice for this customer is still open: Rev Rec charges one invoice per
// customer at a time, so a returning customer's new invoice would wait behind it (Queued). An
// invoice not yet with Rev Rec, or a status the sandbox does not give, counts as open.
async function customerBusy(customerId: string, exceptId: string) {
  for (const s of stories.values()) {
    if (s.storyId === exceptId) continue;
    const invoices = [
      ...(s.stripeCustomerId === customerId ? [s.recoveryId ?? null] : []),
      ...[s.earlier, ...(s.goLive?.invoices ?? [])]
        .filter((inv) => inv?.stripeCustomerId === customerId)
        .map((inv) => inv!.recoveryId),
    ];
    for (const id of invoices) {
      if (!id) {
        if (!s.error) return true;
        continue;
      }
      const r = await settle(
        hsApiKey(
          "GET",
          `v2/payments/recovery-list?payment_id=${id}`,
          undefined,
          prof(s).profileId,
        ),
      );
      const raw: string | undefined = r?.json?.data?.[0]?.status;
      if (!raw || !FINAL_STAGES.has(STAGES[raw]?.stage ?? raw)) return true;
    }
  }
  return false;
}

export const ownerOf = (ip: string) =>
  crypto.createHash("sha256").update(ip).digest("hex").slice(0, 16);

async function runStart(story: Story) {
  if (story.goLivePreset) return runGoLiveStart(story);
  if (story.processor) return runProcessorStart(story);
  const amount = money(story.amount, story.currency);
  const last =
    story.customer === "same"
      ? lastCustomerStory(story.owner, story.storyId)
      : undefined;
  // The last customer still has an open invoice: this story makes a returning customer, as on a
  // first visit, so its invoice is not queued behind that one
  const busy = last
    ? await customerBusy(last.stripeCustomerId!, story.storyId)
    : false;
  const prev = busy ? undefined : last;
  if (prev) {
    story.stripeCustomerId = prev.stripeCustomerId;
    if (prev.savedCard === story.savedCard) story.savedPm = prev.savedPm;
    event(story, {
      stepId: newStepId(story),
      from: "billing",
      to: "billing",
      label: `new invoice ${amount} (same customer)`,
      text: `Invoice ${story.invoiceId} for ${amount} is due. Same customer as the last story.`,
      status: "info",
      source: "simulator",
      why: [
        {
          source: "rule",
          text: "Rev Rec keeps limits per customer and card. A second invoice shares them.",
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
    // Returning customer on a first visit: the demo makes the customer's history first
    const madeReturning = story.customer === "same";
    if (madeReturning) {
      const visa = await makeReturningHistory(story);
      if (story.savedCard === "4242") story.savedPm = visa;
    }
    event(story, {
      stepId,
      from: "billing",
      to: "billing",
      label: madeReturning
        ? `new invoice ${amount} (returning customer, made for this demo)`
        : `new invoice ${amount}`,
      text: madeReturning
        ? `Invoice ${story.invoiceId} for ${amount} is due. Returning customer (made for this demo).`
        : `Invoice ${story.invoiceId} for ${amount} is due for a new test customer.`,
      status: "info",
      source: "simulator",
      why: madeReturning
        ? [
            {
              source: "rule",
              text: busy
                ? "This browser's last customer still has an invoice in recovery. Rev Rec charges one invoice per customer at a time, so the demo made a new one."
                : "This browser had no earlier customer, so the demo made one.",
            },
          ]
        : [],
    });
  }
  if (!story.savedPm)
    story.savedPm = await saveCard(story, story.savedCard, "billing");
  if (story.backupCard && !story.backupPm)
    story.backupPm = await saveCard(story, story.backupCard, "billing");
  if (story.visitorCard && story.savedCard !== story.visitorCard)
    event(story, {
      stepId: newStepId(story),
      from: "billing",
      to: "billing",
      label: `story: first card ••${CARDS[story.savedCard].last4} picked`,
      text: `The story picked Stripe's test card ${CARDS[story.savedCard].last4} as the customer's first card. Your card ••${CARDS[story.visitorCard].last4} is the second.`,
      status: "info",
      source: "simulator",
      why: [{ source: "rule", text: CARDS[story.savedCard].behaviour }],
    });
  // A reused customer may carry an earlier story's bank rule: this story starts without one.
  if (
    story.visitorCard &&
    story.customer === "same" &&
    !story.declines &&
    !story.bank
  )
    await stripe("POST", `customers/${story.stripeCustomerId}`, {
      "metadata[sim_bank]": "",
    });
  if (story.queuePreset && !story.earlier) await startEarlierInvoice(story);
  if (story.bank) await markStoryBank(story, story.bank);
  if (story.declines) await scriptVisitorDeclines(story, story.declines);
  if (story.startMode === "smart") await startInSmart(story);
  if (story.maxRetries !== undefined)
    await startMaxRetries(story, story.maxRetries);

  // Start rule N = Rev Rec takes over after more than N failures. The /v2/recovery API has no retry
  // count field, so the billing system makes its own N retries first, each a real failed charge.
  story.startRule = await readStartRule(prof(story));
  if (story.waitForHandover) {
    // The billing system's first charge fails, and it tells Rev Rec only when the visitor hands
    // the invoice over (POST /sim/story/:id/handover). Until then Rev Rec has nothing to retry.
    const { txnId, error } = await failingCharge(
      story,
      "Billing system charges the card",
      "",
    );
    story.firstFailure = { txnId, error };
    story.awaitingHandover = true;
    viewCache.delete(story.storyId);
    save();
    return;
  }
  await reportStartFailures(story, null);
  story.started = true;
  viewCache.delete(story.storyId);
  save();
}

// The scripted bank (selfhost/sim/bank.mjs) decides Rev Rec's charges on the saved card 0341 for a
// Stripe customer marked with metadata "sim_bank" (a JSON rule, read again for every charge). On a
// win it charges the good card 4242, which must be saved for the same customer. `rule` is passed
// as-is (a story's {v, reason, worksFrom}, or a portfolio invoice's {v, reason, draw}).
export async function markBankCustomer(
  stripeCustomerId: string,
  rule: Record<string, unknown>,
) {
  const meta = await stripe("POST", `customers/${stripeCustomerId}`, {
    "metadata[sim_bank]": JSON.stringify(rule),
  });
  if (meta.status !== 200)
    throw new HttpError(502, `bank rule not saved: ${stripeError(meta)}`);
  const card = await stripe("POST", "payment_methods/pm_card_visa/attach", {
    customer: stripeCustomerId,
  });
  if (!card.json?.id)
    throw new HttpError(502, `bank card not saved: ${stripeError(card)}`);
  return card.json.id as string;
}

// A visitor-card story's bank rule is about the visitor's card, and a win charges that card.
const visitorRule = (story: Story): Pick<BankRule, "card" | "goodCard"> =>
  story.visitorCard && story.savedCard === story.visitorCard && story.savedPm
    ? { card: CARDS[story.visitorCard].last4, goodCard: story.savedPm }
    : {};

// Presets 1, 3-6, 8 with the visitor's card: the bank declines Rev Rec's charges on it until an event
// (money back, a new card, a payment in the app) changes the story.
async function scriptVisitorDeclines(story: Story, reason: string) {
  const rule: BankRule = {
    v: 1,
    reason,
    worksFrom: { afterHours: 100_000 },
    ...visitorRule(story),
  };
  const { stepId } = await stripeStep(
    story,
    "Script the bank for this story",
    `customers/${story.stripeCustomerId}`,
    { "metadata[sim_bank]": JSON.stringify(rule) },
  ).then(({ r, stepId }) => {
    if (r.status !== 200)
      throw new HttpError(
        502,
        `bank rule not saved: ${stripeError(r)}`,
        story.storyId,
      );
    return { stepId };
  });
  story.bankRule = rule;
  const last4 = CARDS[story.savedCard].last4;
  event(story, {
    stepId,
    from: "processor",
    to: "processor",
    label: "the bank's plan",
    text: `The bank declines Rev Rec's charges on ••${last4} (${reason}) until something changes.`,
    status: "info",
    source: "simulator",
    why: [
      {
        source: "rule",
        text: `Your card works at Stripe. In this story the bank says no to it.`,
      },
      {
        source: "rule",
        text: "The scripted bank turns each charge into a decline with the same reason.",
      },
    ],
  });
}

// Presets 11-20: the bank's rule for this story, as a row (the money-back moment is in the view).
async function markStoryBank(story: Story, bank: BankStory) {
  const rule: BankRule = {
    v: 1,
    reason: bank.reason,
    worksFrom: bank.worksFrom,
    ...visitorRule(story),
  };
  story.bankRule = rule;
  const { r, stepId } = await stripeStep(
    story,
    "Script the bank for this story",
    `customers/${story.stripeCustomerId}`,
    { "metadata[sim_bank]": JSON.stringify(rule) },
  );
  if (r.status !== 200)
    throw new HttpError(
      502,
      `bank rule not saved: ${stripeError(r)}`,
      story.storyId,
    );
  // The good card the bank charges when the money is back; not reported to Rev Rec. A visitor-card
  // story charges the visitor's own card then.
  if (!rule.goodCard) {
    const card = await stripe("POST", "payment_methods/pm_card_visa/attach", {
      customer: story.stripeCustomerId,
    });
    if (!card.json?.id)
      throw new HttpError(
        502,
        `bank card not saved: ${stripeError(card)}`,
        story.storyId,
      );
  }
  event(story, {
    stepId,
    from: "processor",
    to: "processor",
    label: "the bank's plan",
    text: bank.text,
    status: "info",
    source: "simulator",
    why: [
      {
        source: "rule",
        text: "The bank is scripted for this story. Retries fail until then.",
      },
      { source: "rule", text: "From then on, Rev Rec's next retry works." },
    ],
  });
}

// When the bank's money comes back, in real life (the bank's worksFromMs, selfhost/sim/bank.mjs).
export function bankWorksFrom(bank: BankStory, failureAt: string) {
  const failure = Date.parse(failureAt);
  const w = bank.worksFrom;
  if ("afterHours" in w)
    return new Date(failure + w.afterHours * 3_600_000).toISOString();
  const day = Math.floor(failure / 86_400_000) * 86_400_000;
  for (let d = 0; d <= 62; d++) {
    const at = day + d * 86_400_000 + w.hour * 3_600_000;
    if (at > failure && [1, 15].includes(new Date(at).getUTCDate()))
      return new Date(at).toISOString();
  }
  return null;
}

// A story at another processor (processors.ts): the billing system stores a card there and its first
// charge there is declined, both with the processor's own test answers. Then the same handover and
// report as a Stripe story; Rev Rec's retry goes to that processor through its own profile.
async function runProcessorStart(story: Story) {
  const a = adapterOf(story.processor!)!;
  const amount = money(story.amount, story.currency);
  const ref = `sim-${story.storyId.slice(3)}`;
  const step = async <T>(fn: () => Promise<T>) => {
    try {
      return await fn();
    } catch (e) {
      throw new HttpError(
        502,
        scrubText(String((e as Error).message)),
        story.storyId,
      );
    }
  };
  event(story, {
    stepId: newStepId(story),
    from: "billing",
    to: "billing",
    label: `new invoice ${amount}`,
    text: `Invoice ${story.invoiceId} for ${amount} is due. The billing system charges cards at ${a.name}.`,
    status: "info",
    source: "simulator",
    why: [],
  });
  const saved = await step(() => a.saveCard(ref));
  story.savedPm = saved.token;
  story.stripeCustomerId = saved.customerId;
  story.procCard = saved.card;
  event(story, {
    stepId: newStepId(story),
    from: "billing",
    to: "processor",
    label: `save card ••${saved.card.last4}`,
    text: `Card ending ${saved.card.last4} is saved for the customer at ${a.name}. Rev Rec retries the saved card.`,
    status: "ok",
    source: "sandbox",
    why: [
      {
        source: "rule",
        text: `${a.name} test mode: its real answers, no scripted bank.`,
      },
    ],
  });
  story.startRule = await readStartRule(prof(story));
  const route = BANK_ROUTES[a.id];
  if (story.bank && route) {
    story.bankReplacements = await step(() => route.replacements(ref, saved));
    const rule: BankRule = {
      v: 1,
      reason: story.bank.reason,
      worksFrom: story.bank.worksFrom,
    };
    await registerBank(story, rule);
    event(story, {
      stepId: newStepId(story),
      from: "processor",
      to: "processor",
      label: "the bank's plan",
      text: story.bank.text,
      status: "info",
      source: "simulator",
      why: [
        {
          source: "rule",
          text: "The bank is scripted for this story. Retries fail until then.",
        },
        {
          source: "rule",
          text: route.genericOnly
            ? `${a.name}'s test mode has one answer: ${route.says.generic_decline}.`
            : `${a.name} answers with its own test decline.`,
        },
      ],
    });
  }
  const reason = story.bank?.reason as BankReasonX | undefined;
  const f = await step(() =>
    reason && route?.failFirst
      ? route.failFirst(ref, story.amount, reason, saved)
      : a.failCharge(ref, story.amount),
  );
  event(story, {
    stepId: newStepId(story),
    txnId: f.txnId,
    from: "billing",
    to: "processor",
    label: `charge ${amount} on ••${saved.card.last4} → declined (${f.code})`,
    text: `The billing system charged card ${saved.card.last4}. ${a.name} said no: ${f.message}.`,
    status: "declined",
    source: "sandbox",
    why: [
      { source: "sandbox", text: `${a.name} test mode answered ${f.code}.` },
    ],
  });
  story.firstFailure = {
    txnId: f.txnId,
    error: { code: f.code, message: f.message },
  };
  if (story.waitForHandover) {
    story.awaitingHandover = true;
    viewCache.delete(story.storyId);
    save();
    return;
  }
  await reportStartFailures(story, story.firstFailure);
  story.started = true;
  viewCache.delete(story.storyId);
  save();
}

// Preset 8: the same customer's invoice 1 fails first and goes to Rev Rec at once, so it is in
// recovery when this invoice (invoice 2) is handed over. On a smart profile without the model flag,
// Rev Rec takes one invoice per customer at a time (a customer lock in
// get_best_psp_token_available_for_smart_retry, workflows/revenue_recovery.rs). The lock is freed
// after each retry, so the two take turns: on 28 Oct invoice 1's retry 1, then all 15 of invoice
// 2's, then invoice 1's other 14 (st_974dfbbcd3b1); on 27 Oct invoice 2 waited for invoice 1's end.
async function startEarlierInvoice(story: Story) {
  const inv: BacklogInvoice = {
    n: 1,
    invoiceId: `${story.invoiceId}-1`,
    recoveryId: null,
    stripeCustomerId: story.stripeCustomerId,
    savedPm: story.savedPm,
    firstFailure: null,
    reportedAt: null,
    reportedAgainAt: null,
  };
  story.earlier = inv;
  const f = await goLiveCharge(
    story,
    inv,
    "Invoice 1: the billing system charges the card",
    "",
  );
  inv.firstFailure = f;
  inv.recoveryId = await reportBacklogInvoice(
    story,
    inv,
    f,
    false,
    "Invoice 1 goes to Rev Rec now. It is in recovery first.",
  );
  inv.reportedAt = nowIso();
  save();
}

// How many failures the billing system reports at start: one, or its own retries up to the start
// rule (Rev Rec takes over after more than N failures), and one for the duplicate preset.
const startFailures = (story: Story) =>
  story.sendDuplicateOnStart
    ? 1
    : Math.min((story.startRule ?? 0) + 1, MAX_START_FAILURES);

// The billing system's reports at start. `first` is a failed charge already made (the handover);
// without it the first charge is made here. Then its own retries, then the duplicate (preset 3).
async function reportStartFailures(
  story: Story,
  first: { txnId: string; error: object } | null,
) {
  const total = startFailures(story);
  for (let n = 1; n <= total; n++) {
    const of = total > 1 ? ` (${n} of ${total})` : "";
    const o = {
      step:
        n === 1
          ? "Billing system charges the card"
          : `Billing system retries the charge itself${of}`,
      suffix: n === 1 ? "" : ` again (${n} of ${total})`,
      of,
      n,
      total,
    };
    if (n === 1 && first)
      await reportFailure(story, first.txnId, first.error, o);
    else await chargeAndReport(story, o);
    save();
  }
  if (story.sendDuplicateOnStart) await reportDuplicate(story);
}

// Preset 9: the customer paid last month's invoice with a second saved card, so Rev Rec holds that
// card's token for this customer before this invoice fails on the stolen card. Rev Rec keeps the
// tokens per customer (Redis). Static retries use only the invoice's own card, so the stolen card
// ends it; smart retries pick among the customer's cards and skip a hard-declined one
// (workflows/revenue_recovery.rs: get_token_availability_for_schedule_time vs
// get_best_psp_token_available_for_smart_retry). A second card reported on this same invoice
// instead would race Rev Rec's first decision, which runs right after the first report (27 Oct).
async function registerSecondCard(story: Story) {
  const card = story.backupCard!;
  const c = CARDS[card];
  const amount = money(story.amount, story.currency);
  const { r: pi, stepId: payStep } = await stripeStep(
    story,
    "Last month's invoice: the customer paid with the second card",
    "payment_intents",
    {
      amount: String(story.amount),
      currency: story.currency.toLowerCase(),
      customer: story.stripeCustomerId,
      payment_method: story.backupPm!,
      off_session: "true",
      confirm: "true",
      description: "Rev Rec simulator: last month's invoice (MIT)",
      "metadata[sim_story]": story.storyId,
    },
  );
  if (pi.json?.status !== "succeeded")
    throw new HttpError(
      502,
      `Stripe did not approve the second card: ${stripeError(pi)}`,
      story.storyId,
    );
  event(story, {
    stepId: payStep,
    txnId: pi.json.id,
    from: "billing",
    to: "processor",
    label: `last month's invoice: charge ${amount} on ••${c.last4} → approved`,
    text: `Last month's invoice: card ${c.last4} was charged. Stripe approved it.`,
    status: "ok",
    source: "sandbox",
    why: [{ source: "rule", text: c.behaviour }],
  });
  const body = recoveryBody(story, {
    status: "charged",
    txnId: pi.json.id,
    token: story.backupPm!,
    card,
    invoiceId: `${story.invoiceId}-PREV`,
  });
  const { r, stepId } = await sandboxStep(
    story,
    "Inform Rev Rec that last month's invoice was paid with the second card",
    body,
  );
  event(story, {
    stepId,
    from: "billing",
    to: "revrec",
    label: `report last month's invoice paid with ••${c.last4} → ${r.status}${r.status === 200 ? " recorded" : ""}`,
    text:
      r.status === 200
        ? `Last month's invoice was paid with card ${c.last4}. Rev Rec keeps that card.`
        : `The billing system reported last month's payment. ${Answerer()} refused it.`,
    status: r.status === 200 ? "ok" : "refused",
    source: "sandbox",
    why: [
      {
        source: "rule",
        text: "Rev Rec keeps each card a customer used, across invoices.",
      },
      {
        source: "rule",
        text: "Static retries use only the invoice's card. Smart retries can pick another.",
      },
    ],
  });
  if (r.status !== 200)
    throw rejected(story, r, `POST /${config.hsRecoveryPath}`);
}

// "Returning customer" with no earlier customer in this browser (28 Oct): the customer's history,
// made for the demo: a saved Visa ••4242 that paid last month's invoice. Returns its payment method.
async function makeReturningHistory(story: Story) {
  const amount = money(story.amount, story.currency);
  const pm = await saveCard(
    story,
    "4242",
    "billing",
    "save card ••4242 (made for this demo)",
  );
  const { r, stepId } = await stripeStep(
    story,
    "Last month's invoice: the billing system charges card 4242",
    "payment_intents",
    {
      amount: String(story.amount),
      currency: story.currency.toLowerCase(),
      customer: story.stripeCustomerId,
      payment_method: pm,
      off_session: "true",
      confirm: "true",
      description: "Rev Rec simulator: last month's invoice (paid)",
      "metadata[sim_story]": story.storyId,
    },
  );
  if (r.json?.status !== "succeeded")
    throw new HttpError(
      502,
      `last month's invoice was not paid: ${stripeError(r)}`,
      story.storyId,
    );
  event(story, {
    stepId,
    from: "billing",
    to: "processor",
    label: `last month's invoice ${amount} on ••4242 → paid`,
    text: "Last month, card 4242 paid this customer's invoice.",
    status: "info",
    source: "sandbox",
    why: [
      {
        source: "rule",
        text: "Made for this demo: a returning customer has paid before.",
      },
    ],
  });
  return pm;
}

// The visitor hands the failed invoice over: the billing system tells Rev Rec now (the reports it
// held back at start), and only then can Rev Rec retry.
const EARLIER_HEAD_START_MS = 8_000;

export function handover(storyId: string) {
  const story = getStory(storyId);
  return withLock(storyId, async () => {
    if (!story.awaitingHandover || !story.firstFailure)
      throw new HttpError(
        409,
        story.started || story.recoveryId
          ? "Rev Rec already has this invoice"
          : story.error
            ? "the story stopped with an error"
            : "the billing system's first charge has not failed yet; try again in a moment",
      );
    story.awaitingHandover = false;
    story.handoverAt = nowIso();
    try {
      if (story.goLive) await reportBacklog(story);
      else {
        if (story.backupCard && story.backupPm) await registerSecondCard(story);
        // Preset 8: Rev Rec takes the customer for invoice 1 at its first decision, about 3 s
        // after its report. Report invoice 2 only after that.
        const since = story.earlier?.reportedAt
          ? Date.now() - Date.parse(story.earlier.reportedAt)
          : Infinity;
        if (since < EARLIER_HEAD_START_MS)
          await new Promise((ok) =>
            setTimeout(ok, EARLIER_HEAD_START_MS - since),
          );
        await reportStartFailures(story, story.firstFailure);
      }
    } catch (e) {
      story.error = scrubText(String((e as Error).message ?? e));
      throw e;
    } finally {
      viewCache.delete(storyId);
      save();
    }
    story.firstFailure = null;
    story.started = true;
    save();
  });
}

// ---------- actions on a running story ----------

// Actions that make Stripe charges or use the scripted bank: Stripe stories only.
function stripeOnly(story: Story, what: string) {
  if (story.processor)
    throw new HttpError(
      409,
      `${what} works in Stripe stories only. This story runs on ${adapterOf(story.processor)!.name}.`,
    );
}

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
    stripeOnly(story, "Customer pays in the app");
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
      text: `The customer paid ${amount} in the app with card 4242. Stripe approved it.`,
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
      "Inform Rev Rec that the invoice was paid outside Rev Rec",
      body,
    );
    event(story, {
      stepId: reportStep,
      from: "billing",
      to: "revrec",
      label: `report paid outside Rev Rec → ${r.status}`,
      text:
        r.status === 200
          ? "The billing system informed Rev Rec that the invoice is paid. Rev Rec recorded it."
          : `The billing system informed Rev Rec that the invoice is paid. ${Answerer()} refused it.`,
      status: r.status === 200 ? "ok" : "refused",
      source: "sandbox",
      why: [
        {
          source: "rule",
          text: "The billing system says the invoice is paid. Rev Rec stops.",
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
// by: who ends it. "customer" (the event Customer cancels, 28 Oct): the customer cancels the
// subscription, then the billing system cancels the invoice at Rev Rec.
export function cancelStory(
  storyId: string,
  by: "merchant" | "customer" = "merchant",
) {
  const story = getStory(storyId);
  return withLock(storyId, async () => {
    requireRunning(story, "cancel");
    await resumeInner(story, "end").catch(() => {});
    if (by === "customer")
      event(story, {
        stepId: newStepId(story),
        from: "customer",
        to: "billing",
        label: "customer: cancels the subscription",
        text: "The customer cancelled the subscription. Rev Rec stops.",
        status: "info",
        source: "simulator",
        why: [
          {
            source: "rule",
            text: "The billing system cancels the invoice at Rev Rec. No more retries.",
          },
        ],
      });
    // Preset 8: invoice 2 ended first (the two take turns); only invoice 1 is left to cancel
    if (story.earlier && closedStage(story)) {
      const r1 = await cancelEarlier(story);
      viewCache.delete(storyId);
      save();
      if (r1 && r1.status !== 200)
        throw new HttpError(
          502,
          `cancel of invoice 1 returned ${r1.status}: ${r1.json?.error?.message ?? "no message"}`,
          storyId,
        );
      return;
    }
    const { r, stepId } = await cancelStep(
      story,
      "Cancel the invoice's recovery",
      story.invoiceId,
    );
    const msg: string = r.json?.error?.message ?? "";
    event(story, {
      stepId,
      from: "billing",
      to: "revrec",
      label: `cancel invoice → ${r.status}${r.status === 200 ? " cancelled" : ""}`,
      text:
        r.status === 200
          ? `${by === "customer" ? "The billing system" : "The merchant"} cancelled the invoice. Rev Rec stopped work on it (payment status ${r.json?.intent_status}).`
          : `${by === "customer" ? "The billing system" : "The merchant"} tried to cancel the invoice. ${Answerer()} refused.`,
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
    // Preset 10: the other backlog invoices too, then the story's billing connector comes off.
    if (story.goLive) {
      for (const inv of story.goLive.invoices) {
        if (!inv.recoveryId || inv.recoveryId === story.recoveryId) continue;
        const { r: r2, stepId: s2 } = await cancelStep(
          story,
          `Cancel invoice ${inv.n}'s recovery`,
          inv.invoiceId,
        );
        event(story, {
          stepId: s2,
          from: "billing",
          to: "revrec",
          label: `invoice ${inv.n}: cancel → ${r2.status}${r2.status === 200 ? " cancelled" : ""}`,
          text:
            r2.status === 200
              ? `The merchant cancelled invoice ${inv.n}.`
              : `The merchant tried to cancel invoice ${inv.n}. ${Answerer()} refused.`,
          status: r2.status === 200 ? "ok" : "refused",
          source: "sandbox",
          why: [],
        });
      }
      await cleanupGoLive(story);
    }
    // Preset 8: invoice 1 too, when it has not ended.
    await cancelEarlier(story);
    viewCache.delete(storyId);
    save();
  });
}

// Rev Rec refuses a cancel while it charges the card ("payment is in processing state"; our
// engine: "... while a retry is in progress", IR_16). On the fast engine a charge lasts about a
// second, so try again 2 s later, up to 3 times. Every try is in the request log; only the last
// answer is a row.
async function cancelStep(story: Story, name: string, invoiceId: string) {
  const path = `${config.hsRecoveryPath}/${encodeURIComponent(invoiceId)}/cancel`;
  let step = await sandboxStep(story, name, undefined, path);
  for (
    let k = 0;
    k < 2 &&
    step.r.status === 400 &&
    /processing state|retry is in progress/i.test(
      step.r.json?.error?.message ?? "",
    );
    k++
  ) {
    await new Promise((ok) => setTimeout(ok, 2_000));
    step = await sandboxStep(
      story,
      `${name} (again: Rev Rec was charging the card)`,
      undefined,
      path,
    );
  }
  return step;
}

// Preset 8: cancels the customer's invoice 1 when it has not ended; returns the answer (null: none sent).
async function cancelEarlier(story: Story) {
  const e = story.earlier;
  if (!e?.recoveryId || story.earlierEndedAt) return null;
  const { r: r3, stepId: s3 } = await cancelStep(
    story,
    "Cancel invoice 1's recovery",
    e.invoiceId,
  );
  event(story, {
    stepId: s3,
    from: "billing",
    to: "revrec",
    label: `invoice 1: cancel → ${r3.status}${r3.status === 200 ? " cancelled" : ""}`,
    text:
      r3.status === 200
        ? "The merchant cancelled invoice 1."
        : `The merchant tried to cancel invoice 1. ${Answerer()} refused.`,
    status: r3.status === 200 ? "ok" : "refused",
    source: "sandbox",
    why: [],
  });
  return r3;
}

// The stage of a finished invoice as last seen (Recovered, Cancelled or Terminated), or null.
const closedStage = (story: Story) =>
  (["Recovered", "Cancelled", "Terminated"] as const).find(
    (s) => story.stageSeen[s],
  ) ?? null;

// Reports the billing system sent to Rev Rec, refused ones included (each costs a Stripe charge).
const reportCount = (story: Story) =>
  story.events.filter(
    (e) =>
      e.from === "billing" &&
      e.to === "revrec" &&
      e.label.startsWith("report "),
  ).length;
const MAX_REPORTS = 8;

export function reportAgain(storyId: string, requested?: ReportAgainMode) {
  const story = getStory(storyId);
  return withLock(storyId, async () => {
    requireRunning(story, "report again");
    stripeOnly(story, "Charge fails again");
    if (reportCount(story) >= MAX_REPORTS)
      throw new HttpError(
        429,
        `this story already sent ${MAX_REPORTS} reports`,
      );
    // A finished invoice gets a new failure by default: the point is Rev Rec's answer to it.
    const finished = closedStage(story);
    const mode = requested ?? (finished ? "new" : story.reportAgainMode);
    if (mode === "swap" && !config.otherCards)
      throw new HttpError(409, "Another card is not part of this demo.");
    if (mode === "duplicate") {
      await reportDuplicate(story, finished);
    } else {
      // swap: the customer's bank works again, and the billing system now holds a working card.
      if (
        mode === "swap" &&
        (story.visitorCard
          ? story.savedCard === story.visitorCard
          : story.savedCard !== "4242")
      ) {
        const fresh = freshCard(story);
        story.savedPm = await saveCard(story, fresh, "billing");
        story.savedCard = fresh;
      }
      await chargeAndReport(story, {
        step: "Billing system charges the card again",
        suffix: " again",
        of: mode === "swap" ? " with the new card" : " again",
        n: 1,
        total: 1,
        finished,
      });
    }
    viewCache.delete(storyId);
    save();
  });
}

// ---------- go-live with a backlog (preset 10) ----------
// Monitoring first, then Rev Rec on. One reused profile "sim-golive", one go-live story at a time.
// Each story adds its own billing connector, which puts the profile into monitoring (and starts the
// engine's monitoring period, monitoring_threshold_in_seconds: 600 s on our engine); deleted at the
// end. The backlog is 3 invoices, each with its own customer (Rev Rec locks retries per customer).
// While in monitoring Rev Rec records each failure and does not retry. "Turn Rev Rec on" switches
// the profile to static retries, but invoices already in the backlog do not start by themselves:
// Rev Rec takes each one when the billing system reports it again (proven 27 Oct, NOTES).
export const GOLIVE_PROFILE_NAME = "sim-golive";
export const GOLIVE_INVOICES = 3;
const GOLIVE_STALE_MS = 20 * 60_000;

export type BacklogInvoice = {
  n: number;
  invoiceId: string;
  recoveryId: string | null;
  stripeCustomerId: string;
  savedPm: string;
  firstFailure: { txnId: string; error: object } | null;
  reportedAt: string | null; // recorded while the profile was in monitoring
  reportedAgainAt: string | null; // the billing system's next attempt, after go-live
};
export type GoLive = {
  profileId: string;
  paymentMcaId: string;
  billingMcaId: string; // this story's own billing connector, deleted at the end
  revRecOnAt: string | null;
  cleanedUpAt: string | null;
  invoices: BacklogInvoice[];
};

// A dashboard-token call of the story, in its request log.
async function dashStep(
  story: Story,
  step: string,
  method: string,
  path: string,
  body?: unknown,
) {
  const profileId = prof(story).profileId;
  const r = await hsDashboard(method, path, { profileId, body });
  const stepId = newStepId(story);
  story.requests.push({
    stepId,
    step,
    at: nowIso(),
    system: "sandbox",
    request: {
      method,
      url: `${config.hsBaseUrl}/${path}`,
      headers: shownHsHeaders("jwt", profileId),
      ...(body === undefined ? {} : { body: redact(body) }),
    },
    response: { status: r?.status ?? 0, body: redact(r?.json ?? null) },
    ms: r?.ms ?? null,
  });
  return { r, stepId };
}

// The go-live profile and its Stripe connector: found by name, made once.
let goLiveBase: { profileId: string; paymentMcaId: string } | null = null;
async function goLiveProfile() {
  if (goLiveBase) return goLiveBase;
  const list = await hsDashboard(
    "GET",
    `v2/merchant-accounts/${revrecMerchantId()}/profiles`,
  );
  if (!list || list.status !== 200)
    throw new HttpError(502, "could not list the merchant's profiles");
  let profile = (list.json ?? []).find(
    (p: any) => p.profile_name === GOLIVE_PROFILE_NAME,
  );
  if (!profile) {
    const r = await hsDashboard("POST", "v2/profiles", {
      body: { profile_name: GOLIVE_PROFILE_NAME },
    });
    if (r?.status !== 200)
      throw new HttpError(
        502,
        `could not make the go-live profile (${r?.status})`,
      );
    profile = r.json;
  }
  const conns = await hsDashboard(
    "GET",
    `v2/profiles/${profile.id}/connector-accounts`,
    { profileId: profile.id },
  );
  let pay = (conns?.json ?? []).find(
    (c: any) =>
      c.connector_type === "payment_processor" && c.connector_name === "stripe",
  );
  if (!pay) {
    const r = await hsDashboard("POST", "v2/connector-accounts", {
      profileId: profile.id,
      body: {
        connector_type: "payment_processor",
        connector_name: "stripe",
        connector_label: "stripe_golive",
        profile_id: profile.id,
        status: "active",
        connector_account_details: {
          auth_type: "HeaderKey",
          api_key: config.stripeKey,
        },
        payment_methods_enabled: [
          {
            payment_method_type: "card",
            payment_method_subtypes: ["credit", "debit"].map((sub) => ({
              payment_method_subtype: sub,
              card_networks: ["Visa", "Mastercard"],
              minimum_amount: 0,
              maximum_amount: 68607706,
              recurring_enabled: true,
              installment_payment_enabled: true,
            })),
          },
        ],
      },
    });
    if (r?.status !== 200)
      throw new HttpError(
        502,
        `could not add the go-live Stripe connector (${r?.status})`,
      );
    pay = r.json;
  }
  goLiveBase = { profileId: profile.id, paymentMcaId: pay.id };
  return goLiveBase;
}

const cleaning = new Set<string>();

// The go-live story that holds the profile now, if any. A story that ended, failed or is older
// than 20 min does not hold it.
export function goLiveHolder(): Story | null {
  const now = Date.now();
  return (
    [...stories.values()].find(
      (s) =>
        s.goLivePreset &&
        !s.error &&
        !s.goLive?.cleanedUpAt &&
        now - Date.parse(s.startedAt) < GOLIVE_STALE_MS,
    ) ?? null
  );
}

// Takes the story's billing connector off the profile (after the backlog has ended, or for a
// story that stopped or went stale).
async function cleanupGoLive(story: Story) {
  const gl = story.goLive;
  if (!gl || gl.cleanedUpAt || !gl.billingMcaId) return;
  const { r, stepId } = await dashStep(
    story,
    "Disconnect this story's billing connector",
    "DELETE",
    `v2/connector-accounts/${gl.billingMcaId}`,
  );
  if (r?.status === 200 || r?.status === 404) {
    gl.cleanedUpAt = nowIso();
    event(story, {
      stepId,
      from: "billing",
      to: "revrec",
      label: `disconnect this story's billing system → ${r.status}`,
      text: "The demo disconnected this story's billing system. The next go-live story starts in monitoring.",
      status: "info",
      source: "sandbox",
      why: [],
    });
    save();
  }
}

// Frees the profile from older go-live stories that stopped or went stale.
export async function freeStaleGoLive() {
  for (const s of stories.values())
    if (
      s.goLivePreset &&
      s.goLive &&
      !s.goLive.cleanedUpAt &&
      s !== goLiveHolder()
    )
      await cleanupGoLive(s).catch(() => undefined);
}

// One failed charge for a backlog invoice (its own customer), as failingCharge does for a story.
async function goLiveCharge(
  story: Story,
  inv: BacklogInvoice,
  step: string,
  suffix: string,
) {
  const first = CARDS[story.firstCharge];
  const amount = money(story.amount, story.currency);
  const { r, stepId } = await stripeStep(story, step, "payment_intents", {
    amount: String(story.amount),
    currency: story.currency.toLowerCase(),
    customer: inv.stripeCustomerId,
    payment_method: first.pm,
    off_session: "true",
    confirm: "true",
    description: "Rev Rec simulator: monthly charge (MIT)",
    "metadata[sim_story]": story.storyId,
  });
  const txnId: string | undefined =
    r.json?.error?.payment_intent?.id ?? r.json?.id;
  if (!txnId || r.json?.status === "succeeded")
    throw new HttpError(
      502,
      `invoice ${inv.n}: Stripe charge did not fail as planned: ${stripeError(r)}`,
      story.storyId,
    );
  const err = r.json?.error ?? {};
  const declineCode: string =
    err.decline_code ?? first.declineCode ?? "generic_decline";
  event(story, {
    stepId,
    txnId,
    from: "billing",
    to: "processor",
    label: `invoice ${inv.n}: charge ${amount}${suffix} on ••${CARDS[story.savedCard].last4} → declined (${declineCode})`,
    text: `The billing system charged invoice ${inv.n}'s card. The bank said no: ${DECLINES[declineCode]?.plain ?? "declined"}.`,
    status: "declined",
    source: "sandbox",
    why:
      story.firstCharge !== story.savedCard
        ? [
            {
              source: "rule",
              text: oneOffWhy(first.last4, CARDS[story.savedCard].last4),
            },
          ]
        : [],
  });
  return {
    txnId,
    error: reportedError(err, declineCode, DECLINES[declineCode]?.ndc),
  };
}

// The billing system reports one backlog invoice's failed charge.
async function reportBacklogInvoice(
  story: Story,
  inv: BacklogInvoice,
  failure: { txnId: string; error: object },
  again: boolean,
  why?: string,
) {
  const body = recoveryBody(story, {
    status: "failure",
    txnId: failure.txnId,
    token: inv.savedPm,
    card: story.savedCard,
    error: failure.error,
    invoiceId: inv.invoiceId,
    customerId: inv.stripeCustomerId,
  });
  const { r, stepId } = await sandboxStep(
    story,
    `Invoice ${inv.n}: report the failed charge to Rev Rec${again ? " (after go-live)" : ""}`,
    body,
  );
  event(story, {
    stepId,
    from: "billing",
    to: "revrec",
    label: `invoice ${inv.n}: report failure${again ? " again" : ""} → ${r.status}${r.status === 200 ? " recorded" : ""}`,
    text:
      r.status === 200
        ? `The billing system reported invoice ${inv.n}'s failed charge. Rev Rec recorded it (payment status ${r.json?.intent_status}).`
        : `The billing system reported invoice ${inv.n}'s failed charge. ${Answerer()} refused it.`,
    status: r.status === 200 ? "ok" : "refused",
    source: "sandbox",
    why: [
      {
        source: "rule",
        text:
          why ??
          (again
            ? "Rev Rec is on now. This report starts the invoice's retries."
            : "Monitoring: Rev Rec records the failure. No retry yet."),
      },
    ],
  });
  if (r.status !== 200)
    throw rejected(story, r, `POST /${config.hsRecoveryPath}`);
  story.reportsSent += 1;
  return r.json.id as string;
}

// Start: the profile goes into monitoring (a new billing connector), then the backlog's first
// failed charges. The story waits for the handover, which reports them.
async function runGoLiveStart(story: Story) {
  const base = await goLiveProfile();
  story.profileRef = {
    key: "story",
    profileId: base.profileId,
    billingMcaId: "",
    paymentMcaId: base.paymentMcaId,
  };
  const label = `custombilling_golive_${story.storyId.slice(3)}`;
  const { r, stepId } = await dashStep(
    story,
    "Connect the billing system: a billing connector for this story",
    "POST",
    "v2/connector-accounts",
    {
      connector_type: "billing_processor",
      connector_name: "custombilling",
      connector_label: label,
      profile_id: base.profileId,
      status: "active",
      connector_account_details: { auth_type: "NoKey" },
      feature_metadata: {
        revenue_recovery: {
          billing_connector_retry_threshold: 0,
          max_retry_count: 15,
          grace_period_days: 30,
          billing_account_reference: {
            [base.paymentMcaId]: base.paymentMcaId,
          },
        },
      },
    },
  );
  if (r?.status !== 200)
    throw new HttpError(
      502,
      `could not add the go-live billing connector (${r?.status ?? "no dashboard token"})`,
      story.storyId,
    );
  story.profileRef = { ...story.profileRef, billingMcaId: r.json.id };
  story.goLive = {
    profileId: base.profileId,
    paymentMcaId: base.paymentMcaId,
    billingMcaId: r.json.id,
    revRecOnAt: null,
    cleanedUpAt: null,
    invoices: [],
  };
  event(story, {
    stepId,
    from: "billing",
    to: "revrec",
    label: "connect the billing system → profile in monitoring",
    text: "The merchant connected the billing system to a new Rev Rec profile. A new connection starts in monitoring.",
    status: "ok",
    source: "sandbox",
    why: [
      {
        source: "rule",
        text: "In monitoring, Rev Rec records each failed invoice and does not retry. The merchant turns retries on when ready.",
      },
    ],
  });
  save();

  const amount = money(story.amount, story.currency);
  const base0 = story.invoiceId;
  for (let n = 1; n <= GOLIVE_INVOICES; n++) {
    const { r: cus, stepId: cusStep } = await stripeStep(
      story,
      `Invoice ${n}: create the test customer`,
      "customers",
      {
        name: `Sim customer ${story.storyId.slice(3, 9)}-${n}`,
        description: "Rev Rec simulator (test)",
        "metadata[sim_story]": story.storyId,
      },
    );
    if (!cus.json?.id)
      throw new HttpError(
        502,
        `Stripe customer not created: ${stripeError(cus)}`,
        story.storyId,
      );
    const { r: pm } = await stripeStep(
      story,
      `Invoice ${n}: save card ${CARDS[story.savedCard].last4} at Stripe`,
      `payment_methods/${CARDS[story.savedCard].pm}/attach`,
      { customer: cus.json.id },
    );
    if (!pm.json?.id)
      throw new HttpError(
        502,
        `Stripe card not saved: ${stripeError(pm)}`,
        story.storyId,
      );
    const inv: BacklogInvoice = {
      n,
      invoiceId: `${base0}-${n}`,
      recoveryId: null,
      stripeCustomerId: cus.json.id,
      savedPm: pm.json.id,
      firstFailure: null,
      reportedAt: null,
      reportedAgainAt: null,
    };
    event(story, {
      stepId: cusStep,
      from: "billing",
      to: "billing",
      label: `invoice ${n}: new invoice ${amount}, card ••${CARDS[story.savedCard].last4} saved`,
      text: `Invoice ${n} of the backlog is due, for its own test customer. The customer's saved card ends ${CARDS[story.savedCard].last4}.`,
      status: "info",
      source: "simulator",
      why: [],
    });
    inv.firstFailure = await goLiveCharge(
      story,
      inv,
      `Invoice ${n}: billing system charges the card`,
      "",
    );
    story.goLive.invoices.push(inv);
    save();
  }
  // The story's own invoice is invoice 1: the timeline's retries and status follow it.
  const first = story.goLive.invoices[0];
  story.invoiceId = first.invoiceId;
  story.stripeCustomerId = first.stripeCustomerId;
  story.savedPm = first.savedPm;
  story.firstFailure = first.firstFailure;
  story.awaitingHandover = true;
  viewCache.delete(story.storyId);
  save();
}

// The handover: the backlog's failures, recorded while the profile is in monitoring.
async function reportBacklog(story: Story) {
  const gl = story.goLive!;
  for (const inv of gl.invoices) {
    inv.recoveryId = await reportBacklogInvoice(
      story,
      inv,
      inv.firstFailure!,
      false,
    );
    inv.reportedAt = nowIso();
    save();
  }
  story.recoveryId = gl.invoices[0].recoveryId;
}

// "Turn Rev Rec on": the profile to static retries (smart for a story started in smart: the profile
// has Rev Rec's model flag, selfhost/smart-profiles.sh), then the billing system's next attempt for
// each backlog invoice. That report is what brings an invoice into retries.
export function turnRevRecOn(storyId: string) {
  const story = getStory(storyId);
  return withLock(storyId, async () => {
    const gl = story.goLive;
    if (!gl) throw new HttpError(409, "this story has no go-live step");
    if (!story.started)
      throw new HttpError(
        409,
        "hand the backlog over first: Rev Rec has not been informed yet",
      );
    if (gl.revRecOnAt) throw new HttpError(409, "Rev Rec is already on");
    const mode = story.startMode === "smart" ? "smart" : "static";
    const to = mode === "smart" ? "smart retries" : "the fixed timetable";
    const { r, stepId } = await dashStep(
      story,
      `Turn Rev Rec on: the profile to ${to}`,
      "PUT",
      `v2/profiles/${gl.profileId}`,
      { revenue_recovery_retry_algorithm_type: engineMode(mode) },
    );
    if (r?.status !== 200)
      throw new HttpError(
        502,
        `could not turn Rev Rec on (${r?.status ?? "no dashboard token"})`,
        storyId,
      );
    gl.revRecOnAt = nowIso();
    forgetRevRecConfig(prof(story));
    event(story, {
      stepId,
      from: "billing",
      to: "revrec",
      label: `turn Rev Rec on → ${to}`,
      text: `The merchant switched Rev Rec from monitoring to ${to}.`,
      status: "ok",
      source: "sandbox",
      why: [
        {
          source: "rule",
          text: "Invoices already in the backlog do not start by themselves. Rev Rec takes each one when the billing system reports it again.",
        },
      ],
    });
    save();
    for (const inv of gl.invoices) {
      const f = await goLiveCharge(
        story,
        inv,
        `Invoice ${inv.n}: billing system charges the card again`,
        " again",
      );
      await reportBacklogInvoice(story, inv, f, true);
      inv.reportedAgainAt = nowIso();
      save();
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
// The story status and the plain caption for a stage name (used by replay, recordings.ts).
export function stageInfo(stage: string, recoveredBy: string | null) {
  if (stage === "Recovered")
    return {
      status: "recovered",
      caption:
        recoveredBy === "revrec"
          ? "Paid: Rev Rec's retry worked"
          : "Paid outside Rev Rec",
    };
  const entry = Object.entries(STAGES).find(([, v]) => v.stage === stage);
  return entry
    ? {
        status: STATUS_ALIASES[entry[0]] ?? entry[0],
        caption: entry[1].caption,
      }
    : { status: "starting", caption: "The billing system is at work" };
}

export const normalizeStatus = (sandboxStatus: string | null | undefined) =>
  sandboxStatus ? (STATUS_ALIASES[sandboxStatus] ?? sandboxStatus) : null;
export const isFinalStatus = (status: string | null) =>
  status === "recovered" || status === "terminated" || status === "cancelled";

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
  profileId: string,
): Promise<Upstream | null> {
  let r = await hsDashboard("GET", `${processTrackerPath}/${recoveryId}`, {
    profileId,
  });
  // 404, or 403 from CloudFront (it blocked the hyphen spelling of list-attempts on 24 Oct).
  if (
    (r?.status === 404 || r?.status === 403) &&
    processTrackerPath.includes("-")
  ) {
    const alt = "v2/process_tracker/revenue_recovery_workflow";
    const r2 = await hsDashboard("GET", `${alt}/${recoveryId}`, { profileId });
    if (r2 && r2.status !== 404 && r2.status !== 403) {
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
const revrecConfigs = new Map<string, { value: RevRecConfig; at: number }>();
// The go-live profile's mode changes during its story, so its cached read is dropped then.
export const forgetRevRecConfig = (p: ProfileRef) =>
  revrecConfigs.delete(p.profileId + p.billingMcaId);

export async function readRevRecConfig(
  p: ProfileRef = PROFILES.story,
): Promise<RevRecConfig> {
  const cached = revrecConfigs.get(p.profileId + p.billingMcaId);
  if (cached && Date.now() - cached.at < 300_000) return cached.value;
  const [mca, profile] = await Promise.all([
    hsDashboard("GET", `v2/connector-accounts/${p.billingMcaId}`, {
      profileId: p.profileId,
    }).catch(() => null),
    hsDashboard("GET", `v2/profiles/${p.profileId}`, {
      profileId: p.profileId,
    }).catch(() => null),
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
      profile?.status === 200
        ? (profile.json?.revenue_recovery_retry_algorithm_type ?? null)
        : null,
  };
  // Do not cache a miss, so a token that arrives later is used at once.
  if (mca?.status === 200)
    revrecConfigs.set(p.profileId + p.billingMcaId, { value, at: Date.now() });
  return value;
}
const readStartRule = async (p: ProfileRef) =>
  (await readRevRecConfig(p).catch(() => null))?.startRule ?? null;

// Process-tracker business status codes in plain words (hyperswitch diesel_models/process_tracker.rs).
// Why and explain lines are plain words with no ids: the drawer's facts grid shows the ids.
export function revrecChargeWhy(status: string, name = "Stripe"): string {
  if (status === "charged")
    return `Rev Rec charged the saved card. ${name} approved.`;
  if (status === "failure")
    return `Rev Rec charged the saved card. ${name} declined.`;
  return `Rev Rec charged the saved card. ${name} has not given its final answer yet.`;
}

// Another processor's decline message as the bank reason it stands for (its route's says).
function procReason(processor: ProcessorId, message: string | null) {
  const route = BANK_ROUTES[processor];
  if (!route || !message) return null;
  // One message for every soft reason; another message (e.g. a duplicate) is not the bank's.
  if (route.genericOnly)
    return message === route.says.generic_decline ? "generic_decline" : null;
  return (
    (Object.keys(route.says) as BankReasonX[]).find(
      (k) => route.says[k] === message,
    ) ?? null
  );
}

const TASK_STATUS: Record<string, string> = {
  Pending: "waiting for its booked time",
  CALCULATE_WORKFLOW_SCHEDULED: "retry time chosen",
  COMPLETED_EXECUTE_TASK: "the retry charged the card",
  FAILED_EXECUTE_TASK: "the retry failed, so Rev Rec picks a new time",
  COMPLETED_EXECUTE_TASK_TO_TRIGGER_PSYNC: "waiting for Stripe's final answer",
  COMPLETED_EXECUTE_TASK_TO_TRIGGER_REVIEW:
    "the invoice was closed, so Rev Rec did not charge",
  FAILED_DUE_TO_HARD_DECLINE_ERROR:
    "every saved card is a hard decline. Rev Rec stops",
  TRIGGER_REQUEUE_FOR_EXECUTE_WORKFLOW:
    "the Stripe call failed, so Rev Rec tries again",
  COMPLETED_PSYNC_TASK: "Stripe's answer arrived",
  RETRIES_EXCEEDED: "status checks used up",
  GLOBAL_ERROR: "the task hit an error and stopped",
};

const RETRY_MODES: Record<string, string> = {
  cascading: "static retries (a fixed timetable)",
  smart: "smart retries (a model picks the hour)",
  monitoring: "monitoring (records failures, does not retry yet)",
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
  if (story.pause && story.recoveryId) {
    const p = await readPause(story.recoveryId);
    if (p && !p.paused)
      await withLock(storyId, () => resumeInner(story, "auto")).catch(() => {});
    // A smart retry the calendar plans after the pause is held then: its time left comes later
    else if (p && story.pause.remainingMs !== p.remainingMs) {
      story.pause.remainingMs = p.remainingMs;
      viewCache.delete(storyId);
      save();
    }
  }
  const cached = viewCache.get(storyId);
  if (cached && Date.now() - cached.at < VIEW_TTL_MS) return cached.view;

  const preset = story.presetId ? (presetById(story.presetId) ?? null) : null;
  const profileId = prof(story).profileId;
  const saved = CARDS[story.savedCard];
  const savedLast4 = story.procCard?.last4 ?? saved.last4;
  const procName = story.processor
    ? adapterOf(story.processor)!.name
    : "Stripe";
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
  let webhookEvents: InboxEvent[] | null = null;
  let deciderCalls: DeciderCall[] | null = null;
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
    // Underscore spelling: since 24 Oct CloudFront blocks list-attempts (403 HTML page).
    attempts: `v2/payments/${story.recoveryId}/list_attempts`,
    tracker: `${processTrackerPath}/${story.recoveryId}`,
  };
  let changed = false;

  if (story.recoveryId) {
    const id = story.recoveryId;
    const [list, det, att, ptr, sr, hooks, decided] = await Promise.all([
      settle(hsApiKey("GET", reads.list, undefined, profileId)),
      settle(hsApiKey("GET", reads.detail, undefined, profileId)),
      settle(hsApiKey("GET", reads.attempts, undefined, profileId)),
      settle(readProcessTracker(id, profileId)),
      settle(readRevRecConfig(prof(story))),
      settle(readWebhooks(id)),
      settle(
        prof(story).key === "decider"
          ? readDeciderCalls(id)
          : Promise.resolve(null),
      ),
    ]);
    webhookEvents = hooks;
    deciderCalls = decided;
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
        `${Answerer()} did not answer one of the status reads. Showing what arrived.`,
      );
    if (!row && story.started)
      warnings.push(
        `The invoice is not in ${isSandbox() ? "the sandbox" : "Rev Rec's"} invoice list yet.`,
      );
    if (!hasDashboardToken())
      warnings.push(
        "The next retry time needs the demo's login. It is missing.",
      );
    else if (ptr && ptr.status !== 200 && ptr.status !== 404)
      warnings.push(
        `The next-retry read failed (${ptr.status}). The demo's login may have expired.`,
      );
  } else if (story.profile === "pool") {
    // Live settings show their current values from the start, before the invoice exists.
    const sr = await settle(readRevRecConfig(prof(story)));
    if (sr) rrc = sr;
  }
  // A pool profile is reset when its story ends: show the story's own last settings instead.
  if (story.profile === "pool" && story.poolReleasedAt) {
    const set = story.settingsSet ?? {};
    rrc = {
      ...rrc,
      retryMode: set.mode ? engineMode(set.mode) : POOL_DEFAULTS.mode,
      maxRetries: set.maxRetries ?? POOL_DEFAULTS.maxRetries,
      gracePeriodDays: set.graceDays ?? POOL_DEFAULTS.graceDays,
    };
  }
  const attempts = toAttempts(rawAttempts);

  // Preset 10: the other backlog invoices' status and Rev Rec retries (invoice 1 is the story's own).
  const readOther = async (inv: BacklogInvoice) => {
    if (!inv.recoveryId || inv.recoveryId === story.recoveryId) return null;
    const [l, a] = await Promise.all([
      settle(
        hsApiKey(
          "GET",
          `v2/payments/recovery-list?payment_id=${inv.recoveryId}`,
          undefined,
          profileId,
        ),
      ),
      settle(
        hsApiKey(
          "GET",
          `v2/payments/${inv.recoveryId}/list_attempts`,
          undefined,
          profileId,
        ),
      ),
    ]);
    return {
      status: (l?.json?.data?.[0]?.status as string | undefined) ?? null,
      attempts:
        a?.status === 200
          ? toAttempts(redact(a.json?.payment_attempt_list ?? []) as any[])
          : [],
    };
  };
  const backlogReads = story.goLive
    ? await Promise.all(story.goLive.invoices.map(readOther))
    : [];
  // Preset 8: the same customer's invoice 1.
  const earlierRead = story.earlier ? await readOther(story.earlier) : null;
  const earlierRaw = earlierRead?.status ?? null;
  const earlierStage = earlierRaw
    ? (STAGES[earlierRaw]?.stage ?? earlierRaw)
    : null;
  const earlierOpen = earlierStage !== null && !FINAL_STAGES.has(earlierStage);
  const earlierAtts = earlierRead?.attempts ?? [];

  // The sandbox says "succeeded" for a paid invoice; the dashboard calls it Recovered.
  const sandboxStatus: string | null = row?.status ?? null;
  const status: string = story.awaitingHandover
    ? "awaiting_handover"
    : story.error && !story.recoveryId
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
      : status === "awaiting_handover"
        ? {
            stage: "Starting",
            caption: "The billing system has not informed Rev Rec yet",
          }
        : { stage: "Starting", caption: "The billing system is at work" });
  const stage = stageInfo.stage;
  const caption =
    stage === "Recovered"
      ? recoveredBy === "revrec"
        ? "Paid: Rev Rec's retry worked"
        : "Paid outside Rev Rec"
      : stage === "Queued" && earlierOpen
        ? "Waiting for the customer's invoice 1"
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
  // The booking as a demo run time, else null. A smart pick the sim calendar has not re-timed yet
  // is the model's raw real-clock pick, hours or days ahead (the calendar re-times picks more than
  // an hour ahead within seconds; demo times stay well under an hour; a paused retry is parked
  // years ahead). Rows, the countdown and the view show only demo times (28 Oct).
  const demoNextAt =
    nextRetryAt &&
    !(simOn() && Date.parse(nextRetryAt) > Date.now() + 3_600_000)
      ? nextRetryAt
      : null;

  const fm = intent?.feature_metadata?.revenue_recovery ?? {};
  const external = attempts.filter((a) => a.by === "billing");
  const internal = attempts.filter((a) => a.by === "revrec");

  // Sandbox incident of 26 Oct: invoices stayed in Monitoring with no retry task although the
  // start rule was met (on 24 Oct the same profile booked a retry in 30 s). After 1 min of that,
  // the story says so instead of showing a plain "waiting".
  const lastReport = [...story.requests]
    .reverse()
    .find(
      (r) =>
        r.system === "sandbox" &&
        r.request.method === "POST" &&
        r.response.status === 200,
    );
  const waitingMin = lastReport
    ? (Date.now() - Date.parse(lastReport.at)) / 60_000
    : 0;
  const failuresKept = external.filter((a) => a.status !== "charged").length;
  const startRuleMet = failuresKept > (story.startRule ?? rrc.startRule ?? 0);
  const waiting =
    story.started &&
    sandboxStatus === "monitoring" &&
    story.seenSchedules.length === 0 &&
    startRuleMet &&
    waitingMin >= WAITING_NOTE_MIN
      ? {
          minutes: Math.floor(waitingMin),
          seconds: Math.floor(waitingMin * 60),
          text: "Rev Rec has not booked a retry yet",
          why: `No retry booked for ${
            config.fastEngine
              ? `${Math.floor(waitingMin * 60)} s.`
              : `${Math.floor(waitingMin)} min.`
          }${
            isSandbox()
              ? " On 24 Oct it took about 30 s."
              : config.fastEngine
                ? " It usually takes about 10 s."
                : ""
          }`,
          source: "recomputed" as Source,
        }
      : null;
  if (waiting) warnings.push(`${waiting.text}: ${waiting.why}`);

  // A new retry time booked by Rev Rec becomes a step, once, with the process-tracker read as its raw call.
  const at = nowIso();
  if (demoNextAt && !story.seenSchedules.includes(demoNextAt)) {
    story.seenSchedules.push(demoNextAt);
    const stepId = newStepId(story);
    story.requests.push({
      stepId,
      step: "Rev Rec books a retry (read from the process tracker)",
      at,
      system: "sandbox",
      request: {
        method: "GET",
        url: `${config.hsBaseUrl}/${reads.tracker}`,
        headers: shownHsHeaders("jwt", profileId),
      },
      response: { status: 200, body: pt },
      ms: null,
    });
    event(story, {
      stepId,
      at,
      from: "revrec",
      to: "revrec",
      label: `pick retry time → ${hms(demoNextAt)}`,
      text: `Rev Rec will try the saved card at ${hms(demoNextAt)} UTC.`,
      status: "ok",
      source: "sandbox",
      why: [
        {
          source: "sandbox",
          text: `Booked time: ${hms(demoNextAt)} UTC.`,
        },
        ...(rrc.retryMode
          ? [
              {
                source: "sandbox" as const,
                text: `Mode: ${modeText(story, rrc.retryMode)}.`,
              },
            ]
          : []),
        ...(prof(story).key === "decider"
          ? deciderWhy(deciderCalls, demoNextAt).why
          : [
              {
                source: "rule" as const,
                text: `Real life: first try after 1 min, then hours apart. ${
                  isSandbox()
                    ? "The sandbox: minutes apart."
                    : config.fastEngine
                      ? "Here: seconds apart, a fast test timetable."
                      : "Here: a test timetable."
                }`,
              },
            ]),
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
        headers: shownHsHeaders("api-key", profileId),
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
      text: `Rev Rec's status: ${caption}. The billing system reads it.`,
      status: stage === "Recovered" ? "ok" : "info",
      source: "sandbox",
      why: [
        {
          source: "rule",
          text: "The billing system reads the status from Rev Rec.",
        },
        // The reaction to a max-tries change the visitor made.
        ...(status === "terminated" &&
        story.settingsSet?.maxRetries &&
        internal.length >= story.settingsSet.maxRetries
          ? [
              {
                source: "recomputed" as const,
                text: `Rev Rec stops: ${internal.length} of ${story.settingsSet.maxRetries} tries used.`,
              },
            ]
          : []),
      ],
    });
    changed = true;
  }
  // A leased profile goes back, reset, once the invoice has ended.
  if (story.profile === "pool" && isFinal && !story.poolReleasedAt) {
    story.poolReleasedAt = at;
    changed = true;
    void release(storyId).catch(() => {});
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
        headers: shownHsHeaders("api-key", profileId),
      },
      response: { status: 200, body: raw },
      ms: null,
    });
    // Stripe's decline_code is in network_error_message; other processors put the network's
    // advice there (Adyen: "Retry after 1 hour"), so their own code and message count.
    const code = story.processor ? a.errorCode : (a.declineCode ?? a.errorCode);
    const reason = story.processor
      ? procReason(story.processor, a.errorMessage)
      : a.declineCode;
    const plain =
      DECLINES[reason ?? ""]?.plain ??
      (story.processor && a.errorMessage
        ? a.errorMessage.toLowerCase().replace(/\.$/, "")
        : "declined");
    const result =
      a.status === "charged"
        ? "approved"
        : a.status === "failure"
          ? `declined (${code ?? "?"})`
          : a.status;
    attemptEvents.push({
      stepId,
      at: a.at,
      from: "revrec",
      to: "processor",
      label: `charge saved card ••${a.last4 ?? "?"} → ${result}`,
      text: `Rev Rec tried saved card ${a.last4 ?? "?"} (retry ${i + 1}). ${
        a.status === "charged"
          ? "The bank approved it."
          : a.status === "failure"
            ? `The bank said no: ${plain}.`
            : `Status: ${a.status}.`
      }`,
      status:
        a.status === "charged"
          ? "ok"
          : a.status === "failure"
            ? "declined"
            : "pending",
      source: "sandbox",
      why: [
        { source: "sandbox", text: revrecChargeWhy(a.status, procName) },
        // Not on a hard decline: Adyen test gives the same advice on every refusal.
        ...(story.processor &&
        a.status === "failure" &&
        a.declineCode &&
        DECLINES[reason ?? ""]?.soft !== false
          ? [
              {
                source: "sandbox" as const,
                text: `The card network says: ${a.declineCode.toLowerCase().replace(/\.$/, "")}.`,
              },
            ]
          : []),
        {
          source: "recomputed",
          text: `Visa allows about 20 tries in 30 days. Used: ${i + 1}.`,
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

  // Webhooks the engine sent the billing system for this invoice (the VM's inbox), one row each.
  const webhookEvents_ = webhookEvents ?? [];
  const webhookRows: StoryEvent[] = webhookEvents_.map((e, i) =>
    webhookRow(e, i),
  );
  const webhookRequests: RequestLog[] = webhookEvents_.map((e, i) => ({
    stepId: webhookRow(e, i).stepId,
    step: "Rev Rec's webhook to the billing system (read from the webhook inbox)",
    at: e.receivedAt,
    system: "sandbox",
    request: { method: "POST", url: "(the billing system's webhook URL)" },
    response: { status: 200, body: e },
    ms: null,
  }));

  // A booked retry that has not run yet: a dashed arrow with the countdown.
  const bookedStep = [...story.events]
    .reverse()
    .find((e) => e.label.startsWith("pick retry time"))?.stepId;
  const pendingEvents: StoryEvent[] = demoNextAt
    ? [
        {
          stepId: bookedStep ?? "next-retry",
          at: demoNextAt,
          from: "revrec",
          to: "processor",
          label: `charge saved card ••${savedLast4} at ${hms(demoNextAt)}`,
          text: `Rev Rec will charge the saved card ending ${savedLast4} at ${hms(demoNextAt)} UTC.`,
          status: "pending",
          source: "sandbox",
          why: [{ source: "rule", text: saved.behaviour }],
        },
      ]
    : [];

  // Real life: the same retries on Hyperswitch's default timetable, from the first failure.
  const failureAt =
    attempts.find((a) => a.by === "billing" && a.status !== "charged")?.at ??
    story.events.find(
      (e) => e.from === "billing" && e.to === "processor" && e.txnId,
    )?.at ??
    story.startedAt;
  // The fixed timetable; a smart story's real-life times come from the sim calendar instead (below)
  const ladder = realLife(failureAt, rrc.maxRetries);
  // A story switched to smart: retries the fixed timetable placed after the switch mean the model gave
  // no time (the engine falls back to the ladder; e.g. a grace period too short for its window). A
  // retry within 10 s of the switch was booked before it.
  // C's simulated calendar, for a story in smart mode: the model's real-life picks and when they
  // run here.
  const cal =
    story.recoveryId &&
    simOn() &&
    (rrc.retryMode === "smart" || story.settingsSet?.mode)
      ? await settle(readCalendar(story.recoveryId))
      : null;
  // Smart: the model's real-life times on C's calendar (B's calendar, row times and next retry read these)
  const real =
    cal && rrc.retryMode === "smart"
      ? realLifeFromCalendar(cal, ladder)
      : ladder;
  const switchedAt = story.worldEvents?.find(
    (e) =>
      e.type === "setting" && e.text === "You set the retry mode to smart.",
  )?.madeAt;
  const smartFallbacks =
    switchedAt && story.settingsSet?.mode === "smart"
      ? (cal?.retries ?? []).filter(
          (r) =>
            r.source === "ladder" &&
            Date.parse(r.demoAt) > Date.parse(switchedAt) + 10_000,
        ).length
      : 0;
  // The retry Rev Rec has booked, as soon as the engine books it: when it runs here, and its
  // real-life moment (the model's pick on C's calendar, else the fixed timetable's slot).
  // A booking at or before Rev Rec's latest attempt is the one just used: no next retry yet.
  const lastTry = internal.at(-1)?.at;
  const freshBooking =
    nextRetryAt &&
    !(lastTry && Date.parse(nextRetryAt) <= Date.parse(lastTry) + 1500);
  // Paused: the held retry sits years ahead in the engine; there is no next retry until resume
  const nextRetry =
    freshBooking && !story.pause
      ? (() => {
          const n = internal.length + 1;
          const plan = cal?.plans.find((x) => x.n === n);
          // The model's raw pick, days ahead, until C's calendar moves it to demo time.
          if (
            !plan &&
            rrc.retryMode === "smart" &&
            Date.parse(nextRetryAt) > Date.now() + 3_600_000
          )
            return {
              n,
              bookedAt: nextRetryAt,
              runsAt: null,
              inSec: null,
              realLife: null,
              realLifeLabel: null,
              day: null,
              dayText: null,
              source: "calendar" as const,
              pending: true,
              text: "Rev Rec's model picked a time. It moves to demo time in a moment.",
            };
          const realAt = plan?.slot ?? real.slots[n - 1]?.at ?? null;
          const runsAt = plan?.demoAt ?? nextRetryAt;
          const failure = cal?.realLifeFailureAt ?? failureAt;
          const sec = realAt
            ? Math.max(0, (Date.parse(realAt) - Date.parse(failure)) / 1000)
            : null;
          const day = sec === null ? null : Math.floor(sec / 86400) + 1;
          return {
            n,
            bookedAt: nextRetryAt, // the engine's task time
            runsAt, // when it runs in this demo
            inSec: Math.max(
              0,
              Math.round((Date.parse(runsAt) - Date.now()) / 1000),
            ),
            realLife: realAt,
            realLifeLabel: realAt ? slotLabel(realAt) : null,
            day,
            dayText: sec === null ? null : dayText(sec),
            source: plan ? ("calendar" as const) : ("ladder" as const),
            pending: false,
            text: realAt
              ? `Rev Rec picked ${slotLabel(realAt)} (day ${day}).`
              : `Rev Rec booked a retry at ${hms(runsAt)} UTC.`,
          };
        })()
      : null;
  // "Now" in real life on the fixed timetable: the slot of Rev Rec's latest retry, else the failure.
  const lastRealLife =
    real.slots[internal.length - 1]?.at ??
    (story.recoveryId ? failureAt : null);
  // Presets 11-20: the bank's money-back moment, and the first retry slot at or after it.
  // The moment the card works, which the comparison with the fixed timetable needs: the scripted
  // bank's (stories 11-20), the visitor's "Money is back" (any other story, story 6 most of all), or
  // story 2's next try (it works from the failure on). null: no such moment, no comparison.
  const works = ((): {
    text: string;
    reason: string | null;
    worksFrom: Record<string, unknown>;
    worksFromAt: string | null;
    // The chart's line and the math's first word for that moment
    name: string;
    mathName: string;
    source: "scripted" | "visitor" | "story";
  } | null => {
    if (story.bank)
      return {
        text: story.bank.text,
        reason: story.bank.reason,
        worksFrom: story.bank.worksFrom,
        worksFromAt: bankWorksFrom(story.bank, failureAt),
        name: "Money came back",
        mathName: "Money back",
        source: "scripted",
      };
    const rule = story.bankRule;
    if (rule && !rule.stolenFrom && "at" in rule.worksFrom) {
      const at = new Date(String(rule.worksFrom.at)).toISOString();
      return {
        text: `The money came back on ${slotLabel(at)}.`,
        reason: bankReasonOf(story),
        worksFrom: rule.worksFrom,
        worksFromAt: at,
        name: "Money came back",
        mathName: "Money back",
        source: "visitor",
      };
    }
    const changed = (story.worldEvents ?? []).some((e) => e.type !== "setting");
    if (story.presetId === 2 && !changed)
      return {
        text: "The bank says no once. The next try works.",
        reason: CARDS[story.firstCharge]?.declineCode ?? null,
        worksFrom: { nextTry: true },
        worksFromAt: new Date(failureAt).toISOString(),
        name: "Card works again",
        mathName: "Works again",
        source: "story",
      };
    return null;
  })();
  const bank = works
    ? (() => {
        const worksFromAt = works.worksFromAt;
        const slot = worksFromAt
          ? ladder.slots.find((s) => s.at >= worksFromAt)
          : undefined;
        // Smart: the model's retries so far and its booked one (the sim calendar)
        const smartSlot =
          worksFromAt && real.mode === "smart"
            ? real.slots.find((s) => s.at >= worksFromAt)
            : undefined;
        // Days from the failure, to one decimal
        const daysFrom = (from: string, to: string | null | undefined) =>
          to
            ? Math.round(
                ((Date.parse(to) - Date.parse(from)) / 86_400_000) * 10,
              ) / 10
            : null;
        // The fixed timetable's tries around the money-back time: the last one before it and the
        // first one after it (the result's math)
        const before = worksFromAt
          ? [...ladder.slots].reverse().find((s) => s.at < worksFromAt)
          : undefined;
        const math = worksFromAt
          ? [
              `${works.mathName}: ${slotLabel(worksFromAt)}`,
              ...(before
                ? [`Try ${before.retry}: ${before.label}, before the money`]
                : []),
              slot
                ? `Try ${slot.retry}: ${slot.label}, first after it`
                : `No try after it: the fixed timetable stops at try ${ladder.slots.length}`,
            ]
          : [];
        // Rev Rec: its retry that worked on the engine's attempts, at its real-life time (calendar)
        const wonAt = internal.findIndex((a) => a.status === "charged");
        const wonSlot =
          wonAt >= 0
            ? real.slots.find((s) => s.retry === wonAt + 1)
            : undefined;
        // The result chart's two lanes (28 Oct): every try the fixed timetable would make, up to the
        // one that recovers (it stops there), and Rev Rec's retries at their real-life times
        const fixedTimeline = worksFromAt
          ? ladder.slots
              .filter((s) => !slot || s.retry <= slot.retry)
              .map((s) => ({
                n: s.retry,
                at: s.at,
                label: s.label,
                result: s === slot ? "recovered" : "declined",
              }))
          : [];
        const revRecTimeline = internal.flatMap((a, i) => {
          const s = real.slots.find((x) => x.retry === i + 1);
          return s
            ? [
                {
                  n: i + 1,
                  at: s.at,
                  label: s.label,
                  result:
                    a.status === "charged"
                      ? "recovered"
                      : ["pending", "started", "authorizing"].includes(a.status)
                        ? "pending"
                        : "declined",
                },
              ]
            : [];
        });
        // Like for like: the fixed timetable with the same number of tries Rev Rec used
        const used = wonAt >= 0 ? wonAt + 1 : internal.length;
        const sameLast =
          used > 0
            ? (ladder.slots.find((s) => s.retry === used) ??
              ladder.slots.at(-1))
            : undefined;
        return {
          text: works.text,
          reason: works.reason,
          worksFrom: works.worksFrom,
          worksFromAt,
          worksFromLabel: worksFromAt ? slotLabel(worksFromAt) : null,
          worksFromName: works.name,
          // The first failure in real life: where the result chart's time axis starts
          failureAt: ladder.failureAt,
          // The retry of the fixed timetable that comes first after it (null = none: too late)
          staticRetry: slot?.retry ?? null,
          // Smart: the model's first retry at or after it so far (null = none yet, or not smart)
          smartRetry: smartSlot?.retry ?? null,
          // What the fixed timetable would have needed: its real-life offsets for this story's
          // failure and max tries, against the money-back time (computed, not run)
          fixedTimetable: {
            tries: slot?.retry ?? null,
            recoveredAt: slot?.at ?? null,
            daysToRecover: daysFrom(ladder.failureAt, slot?.at),
            // Would the fixed timetable have recovered within the tries Rev Rec used?
            sameTries: {
              tries: used,
              recovered: Boolean(slot && used > 0 && slot.retry <= used),
              lastTryAt: sameLast?.at ?? null,
            },
            math,
            // Each try in order, the recovering one last; stopsAfter: its last try when it stops
            // before the money is back (too late)
            timeline: fixedTimeline,
            stopsAfter: worksFromAt && !slot ? ladder.slots.length : null,
            text: !worksFromAt
              ? null
              : slot
                ? `The fixed timetable would have needed ${slot.retry} ${slot.retry === 1 ? "try" : "tries"}.`
                : `The fixed timetable would stop before the money is back.`,
            source: "computed" as const,
          },
          // What Rev Rec did, from the engine's attempts: retries used and, when one worked, its
          // real-life time and the days from the failure
          revRec: {
            retries: wonAt >= 0 ? wonAt + 1 : internal.length,
            recovered: wonAt >= 0,
            recoveredAt: wonSlot?.at ?? null,
            daysToRecover: daysFrom(real.failureAt, wonSlot?.at),
            timeline: revRecTimeline,
            source: "sandbox" as const,
          },
          // scripted: the bank's rule (11-20); visitor: "Money is back"; story: story 2's next try
          source: works.source,
        };
      })()
    : null;
  const retryBudget = budgetOf(rrc.maxRetries, internal, external, fm);
  // The billing system's failed charges, counted from the simulator's own charges: the engine adds
  // no attempt for a failure reported during recovery, so its attempts list undercounts them.
  const counts = {
    billingFailures: story.events.filter(
      (e) =>
        e.from === "billing" &&
        e.to === "processor" &&
        e.status === "declined" &&
        // Rows of the other invoices: go-live's invoices 2 and 3, preset 8's invoice 1.
        !(story.goLive ? /^invoice [2-9]/ : /^invoice \d+:/).test(e.label),
    ).length,
    failureReports: story.reportsSent - (story.paidInAppAt ? 1 : 0),
    revrecRetries: internal.length,
    source: "recomputed" as const,
  };
  // The customer's saved cards and what the engine's attempts say of each (preset 9 has two).
  const isHard = (code: string | null) =>
    Boolean(code && DECLINES[code] && !DECLINES[code].soft);
  const savedCards = [
    story.savedCard,
    ...(story.backupCard ? [story.backupCard] : []),
  ].map((card, k) => {
    const last4 =
      k === 0 && story.procCard ? story.procCard.last4 : CARDS[card].last4;
    const onCard = attempts.filter((a) => a.last4 === last4);
    return {
      last4,
      role: k === 0 ? "main" : "second",
      hardDecline: onCard.some((a) => isHard(a.declineCode)),
      revrecCharges: onCard.filter((a) => a.by === "revrec").length,
      approved: onCard.some((a) => a.by === "revrec" && a.status === "charged"),
      source: "recomputed" as const,
    };
  });
  // The n-th Rev Rec retry of a row: its own attempt, the booked next one, or (the end row) the last.
  const retryOf = (e: StoryEvent): number | null => {
    if (e.stepId.startsWith("att_")) {
      const k = internal.findIndex((a) => `att_${a.id}` === e.stepId);
      return k >= 0 ? k + 1 : null;
    }
    if (e.status === "pending" && e.from === "revrec" && e.to === "processor")
      return internal.length + 1;
    if (
      e.from === "revrec" &&
      e.to === "billing" &&
      e.label.startsWith("invoice ")
    )
      return internal.length || null;
    return null;
  };

  const byTime = <T extends { at: string }>(x: T, y: T) =>
    String(x.at).localeCompare(String(y.at));
  // attemptId links a charge row to its row in the attempts table.
  const timeline = [...story.events, ...attemptEvents, ...webhookRows]
    .sort(byTime)
    .concat(pendingEvents)
    .map(({ txnId, ...e }) => {
      const retry = retryOf(e);
      return {
        ...e,
        attemptId: e.stepId.startsWith("att_")
          ? e.stepId.slice(4)
          : txnId
            ? (attempts.find((a) => a.connectorTxnId === txnId)?.id ?? null)
            : null,
        realLife: retry ? rowRealLife(real.slots, retry) : null,
        // A declined charge: what its decline code means, from the code in the label.
        meaning:
          e.status === "declined"
            ? declineMeaning(/\(([a-z_]+)\)\s*$/.exec(e.label)?.[1])
            : null,
      };
    });
  const requests = [
    ...story.requests,
    ...attemptRequests,
    ...webhookRequests,
  ].sort(byTime);

  // Preset 10: each backlog invoice as the engine has it. When all have ended after go-live, the
  // story's billing connector comes off the profile (once).
  const gl = story.goLive;
  // The real-life moment Rev Rec recovered an invoice: its charged retry's slot on the sim calendar
  // (smart), else on the fixed timetable from that invoice's own failure. null when not recovered.
  const recoveredAtOf = async (recoveryId: string | null, atts: Attempt[]) => {
    const n =
      atts
        .filter((a) => a.by === "revrec")
        .findIndex((a) => a.status === "charged") + 1;
    const failedAt = atts.find(
      (a) => a.by === "billing" && a.status !== "charged",
    )?.at;
    if (!n || !recoveryId || !failedAt) return null;
    const fixed = realLife(failedAt, rrc.maxRetries);
    const c =
      simOn() && rrc.retryMode === "smart"
        ? await settle(readCalendar(recoveryId))
        : null;
    const slots = c ? realLifeFromCalendar(c, fixed).slots : fixed.slots;
    return slots.find((s) => s.retry === n)?.at ?? null;
  };
  const backlog = gl
    ? await Promise.all(
        gl.invoices.map(async (inv, k) => {
          const own =
            inv.recoveryId !== null && inv.recoveryId === story.recoveryId;
          const raw = own ? sandboxStatus : (backlogReads[k]?.status ?? null);
          const atts = own ? attempts : (backlogReads[k]?.attempts ?? []);
          return {
            n: inv.n,
            invoiceId: inv.invoiceId,
            recoveryId: inv.recoveryId,
            status: raw ? (STATUS_ALIASES[raw] ?? raw) : null,
            stage: raw
              ? (STAGES[raw]?.stage ?? raw)
              : inv.recoveryId
                ? "Monitoring"
                : "Starting",
            revrecRetries: atts.filter((a) => a.by === "revrec").length,
            recoveredAt: await recoveredAtOf(inv.recoveryId, atts),
            recordedInMonitoringAt: inv.reportedAt,
            reportedAgainAt: inv.reportedAgainAt,
            waitingForReport: Boolean(gl.revRecOnAt && !inv.reportedAgainAt),
          };
        }),
      )
    : null;
  const backlogDone =
    Boolean(gl?.revRecOnAt) &&
    (backlog ?? []).every((b) => FINAL_STAGES.has(b.stage));
  if (gl && backlogDone && !gl.cleanedUpAt && !cleaning.has(story.storyId)) {
    cleaning.add(story.storyId);
    await cleanupGoLive(story).finally(() => cleaning.delete(story.storyId));
  }

  // Preset 8: the first view that sees invoice 1 ended adds a row, once. Its end is its last Rev Rec
  // retry as the engine has it.
  if (
    story.earlier &&
    earlierStage &&
    FINAL_STAGES.has(earlierStage) &&
    !story.earlierEndedAt
  ) {
    story.earlierEndedAt =
      earlierAtts.filter((a) => a.by === "revrec").at(-1)?.at ?? nowIso();
    const word =
      earlierStage === "Recovered"
        ? "recovered"
        : earlierStage === "Cancelled"
          ? "cancelled"
          : "Rev Rec stopped";
    event(story, {
      stepId: newStepId(story),
      from: "revrec",
      to: "billing",
      label: `invoice 1 ended: ${word}`,
      text: `Invoice 1 ended: ${word}.`,
      status: "info",
      source: "sandbox",
      why: [
        {
          source: "rule",
          text: "Rev Rec takes one invoice per customer at a time here.",
        },
      ],
    });
    changed = true;
  }

  // ----- explain (invoice level, for the attempts rows and the status) -----
  const explain: { id: string; text: string; source: Source }[] = [];
  const add = (id: string, source: Source, text: string) =>
    explain.push({ id, text, source });
  if (story.awaitingHandover)
    add(
      "handover",
      "recomputed",
      "The billing system has not informed Rev Rec yet. Rev Rec retries only after the handover.",
    );
  if (story.awaitingHandover && story.settingsSet)
    add(
      "handover-settings",
      "rule",
      "Your settings apply once Rev Rec has the invoice. Hand it over to start.",
    );
  // Preset 8: the order the engine used. It frees the customer after every Rev Rec retry, failed or
  // not (core/revenue_recovery/types.rs, the execute step), so the next invoice to decide takes the
  // customer: invoice 2 may wait for all of invoice 1, or the two take turns.
  const turnsSeen = (() => {
    const merged = [
      ...internal.map((a) => ({ at: a.at, own: true })),
      ...earlierAtts
        .filter((a) => a.by === "revrec")
        .map((a) => ({ at: a.at, own: false })),
    ].sort((a, b) => a.at.localeCompare(b.at));
    const switches = merged.filter(
      (x, i) => i > 0 && x.own !== merged[i - 1].own,
    );
    const gaps = switches.map(
      (x) =>
        (Date.parse(x.at) - Date.parse(merged[merged.indexOf(x) - 1].at)) /
        1000,
    );
    return {
      turns: switches.length,
      minGapSec: gaps.length ? Math.min(...gaps) : null,
    };
  })();
  if (smartFallbacks)
    add(
      "smart-fallback",
      "recomputed",
      (story.settingsSet?.graceDays ?? 30) <= 2
        ? "Grace is too short for Rev Rec's model. It uses the fixed timetable."
        : `Rev Rec's model gave no time ${smartFallbacks === 1 ? "once" : `${smartFallbacks} times`}. Rev Rec used the fixed timetable.`,
    );
  if (bank)
    add(
      "bank",
      "rule",
      real.mode === "smart"
        ? bank.smartRetry
          ? `${bank.text} Rev Rec's model reaches it at retry ${bank.smartRetry}.`
          : `${bank.text} No retry of Rev Rec's has reached it yet.`
        : bank.staticRetry
          ? `${bank.text} On the fixed timetable that is retry ${bank.staticRetry}.`
          : `${bank.text} The fixed timetable has stopped by then.`,
    );
  // Smart: what the fixed timetable would have needed, worked out from its offsets (not run)
  if (bank && real.mode === "smart" && bank.fixedTimetable.text)
    add("bank-fixed", "recomputed", bank.fixedTimetable.text);
  if (story.earlier) {
    const firstRetry = internal[0]?.at ?? null;
    add(
      "queue",
      "recomputed",
      !story.started
        ? "This customer's invoice 1 is already in recovery."
        : stage === "Queued" && earlierOpen
          ? "Queued: Rev Rec is busy with this customer's invoice 1."
          : !firstRetry
            ? earlierOpen
              ? "Invoice 1 is in recovery too. Rev Rec charges one at a time."
              : "Invoice 1 has ended. Rev Rec takes this invoice next."
            : story.earlierEndedAt && firstRetry > story.earlierEndedAt
              ? "Invoice 1 ended first. Then Rev Rec started this invoice."
              : turnsSeen.minGapSec !== null && turnsSeen.minGapSec < 2
                ? "Rev Rec retried both invoices close together."
                : "The two invoices took turns. Rev Rec charged one at a time.",
    );
    add(
      "queue-rule",
      "rule",
      "Rev Rec frees the customer after each retry. Then the next invoice can go.",
    );
  }
  if (gl && story.started)
    add(
      "monitoring",
      "rule",
      gl.revRecOnAt
        ? "Rev Rec is on. Each backlog invoice starts when the billing system reports it again."
        : "Monitoring: Rev Rec records the failures and does not retry yet. Tap Turn Rev Rec on.",
    );
  const utc = (iso: string) =>
    `${iso.replace("T", " ").replace(/\.\d+Z?$|Z$/, "")} UTC`;

  if (story.recoveryId) {
    add(
      "status",
      "sandbox",
      `Status: ${sandboxStatus ? caption : "not listed yet"}.`,
    );
    if (demoNextAt)
      add("next-retry", "sandbox", `Next retry booked for ${utc(demoNextAt)}.`);
    else if (nextRetryAt)
      add(
        "next-retry",
        "sandbox",
        story.pause
          ? "Paused. The next retry waits until you resume."
          : "Rev Rec's model picked a time. It moves to demo time in a moment.",
      );
    else if (staleTaskAt)
      add(
        "stale-task",
        "sandbox",
        `A retry is still booked for ${utc(staleTaskAt)}. Paying does not cancel it.`,
      );
    else if (pt) {
      const plain = (
        TASK_STATUS[pt.business_status] ?? `its status is ${pt.status}`
      ).replace("Stripe's", `${procName}'s`);
      add("task", "sandbox", `Next step: ${plain}.`);
    }
    if (recoveredBy === "billing")
      add(
        "paid-outside",
        "sandbox",
        "Paid outside Rev Rec. Rev Rec stops trying.",
      );
    if (recoveredBy === "revrec")
      add(
        "recovered",
        "sandbox",
        "Recovered: Rev Rec's retry on the saved card worked.",
      );
    if (status === "terminated")
      add("terminated", "sandbox", "Rev Rec stopped trying this invoice.");
    const paidOutside = external.filter((a) => a.status === "charged").length;
    add(
      "counts",
      "recomputed",
      `Failed charges by the billing system: ${counts.billingFailures}.` +
        (paidOutside ? ` Payments outside Rev Rec: ${paidOutside}.` : "") +
        ` Rev Rec's own retries: ${internal.length}.`,
    );
    const failureReports = story.reportsSent - (story.paidInAppAt ? 1 : 0);
    if (failureReports > external.length - paidOutside)
      add(
        "duplicates",
        "recomputed",
        `Failure reports sent: ${failureReports}. Rev Rec kept ${external.length - paidOutside}. It did not count the copy.`,
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
        `Visa allows about 20 tries in 30 days. Used: ${internal.length}.`,
      );
    if (typeof fm.total_retry_count === "number")
      add(
        "retry-count",
        "sandbox",
        `Total retry count on the invoice: ${fm.total_retry_count}.`,
      );
  }
  // Only Stripe puts its decline_code in network_error_message (see the retry rows).
  const recorded = story.processor ? null : (firstFail?.declineCode ?? null);
  if (firstFail)
    add(
      "recorded-reason",
      "sandbox",
      `Decline ${isSandbox() ? "recorded by the sandbox" : "Rev Rec recorded"} from ${procName}: ${firstFail.errorCode ?? "?"}` +
        (recorded ? `, ${recorded}` : "") +
        (firstFail.networkDeclineCode
          ? ` (network code ${firstFail.networkDeclineCode})`
          : "") +
        ".",
    );
  const reason = story.processor
    ? (procReason(story.processor, firstFail?.errorMessage ?? null) ??
      // The reported failure carries the engine's own code: what the processor says for the
      // story's reason instead (do_not_honor is "Refused" at Adyen, a generic decline).
      procReason(
        story.processor,
        BANK_ROUTES[story.processor]?.says[story.bank?.reason as BankReasonX] ??
          null,
      ))
    : (recorded ?? first.declineCode);
  const d = reason ? DECLINES[reason] : undefined;
  if (reason && d)
    add("reason", "rule", `${reason}: ${d.plain}. ${verdict(story, d.soft)}`);
  const triedCards = savedCards
    .filter((c) => c.revrecCharges > 0)
    .map((c) => c.last4);
  add(
    "cards",
    "rule",
    prof(story).key === "decider" && story.backupCard
      ? `Card ${savedLast4} failed. ${
          triedCards.length
            ? `Rev Rec chose saved card ${triedCards.join(" and ")}.`
            : "Rev Rec picks among the saved cards."
        }`
      : `Card ${savedLast4} failed. Rev Rec retries that saved card.`,
  );
  const sr = story.startRule ?? rrc.startRule;
  if (sr !== null)
    add(
      "start-rule",
      "sandbox",
      `Start rule: ${sr}. Rev Rec steps in after ${sr + 1} failed charge${sr === 0 ? "" : "s"}.`,
    );
  else
    add(
      "start-rule",
      "rule",
      "Start rule not read (no login). Demo profiles use 0: Rev Rec steps in at once.",
    );
  if (rrc.retryMode)
    add("retry-mode", "sandbox", `Mode: ${modeText(story, rrc.retryMode)}.`);
  const lastBooked = story.seenSchedules.at(-1);
  if (prof(story).key === "decider" && lastBooked) {
    const d = deciderWhy(deciderCalls, lastBooked);
    add("decider", d.why[0].source, d.why[0].text);
  }
  if (rrc.maxRetries !== null)
    add(
      "max-retries",
      "sandbox",
      `Max tries: ${rrc.maxRetries}. Rev Rec stops there.`,
    );
  if (rrc.gracePeriodDays !== null)
    add(
      "grace-period",
      "sandbox",
      `Grace period: ${rrc.gracePeriodDays} days.`,
    );

  const open =
    Boolean(story.recoveryId) &&
    (story.started || Boolean(story.error)) &&
    !isFinal;
  // When the story has made its point, the dashboard can stop polling. The duplicate preset never
  // reaches a final stage on a profile with a start rule above 0, so its point is the refused copy.
  // Preset 8: not done while the customer's invoice 1 can still be retried (the two take turns, so
  // invoice 2 can end first).
  const earlierPending = Boolean(
    story.earlier?.recoveryId && !story.earlierEndedAt,
  );
  const done = gl
    ? status === "error" || backlogDone
    : status === "error" ||
      (isFinal && !earlierPending) ||
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
          expected: presetText(preset).expected,
          hint: presetText(preset).hint,
        }
      : null,
    form: {
      amount: story.amount,
      currency: story.currency,
      savedCard: story.savedCard,
      firstCharge: story.firstCharge,
      customer: story.customer,
      // The visitor's one card (null: an older start with savedCard/firstCharge)
      visitorCard: story.visitorCard ?? null,
      declines: story.declines ?? null,
    },
    invoiceId: story.invoiceId,
    recoveryId: story.recoveryId,
    startedAt: story.startedAt,
    updatedAt: new Date().toISOString(),
    status,
    sandboxStatus,
    stage,
    stageCaption: waiting ? waiting.text : caption,
    // Set after 1 min in Monitoring with the start rule met and no retry task (sandbox incident).
    waiting,
    stageHistory,
    recoveredBy,
    done,
    // Only a demo run time (null while a smart pick waits to be re-timed: "Picking a time")
    nextRetryAt: demoNextAt,
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
      // The sandbox's invoice detail has created_at; upstream main's v2 has none (self-hosted
      // engine, 27 Oct). The first failure report makes the invoice, so fall back to its first
      // recorded attempt, then to the time of the story's first accepted report.
      createdAt:
        intent?.created_at ??
        attempts[0]?.at ??
        story.requests.find(
          (q) =>
            q.system === "sandbox" &&
            q.request.method === "POST" &&
            q.response.status === 200,
        )?.at ??
        null,
    },
    attemptSummary: attempts,
    realLife: real,
    retryBudget,
    counts,
    // The next retry Rev Rec booked (null when none or paused): demo time, real-life time and a plain line
    nextRetry,
    // Paused by the visitor (null when running): Rev Rec's next retry waits; remainingSec is the time
    // it had left, which it gets back on resume
    paused: story.pause
      ? {
          at: story.pause.at,
          autoResumeAt: story.pause.autoResumeAt,
          remainingSec:
            story.pause.remainingMs === null
              ? null
              : Math.round(story.pause.remainingMs / 1000),
        }
      : null,
    // Presets 11-20: the scripted bank (null for other stories)
    bank,
    // Where the cards are charged: Stripe, or another processor's real test answers
    processor: story.processor
      ? { id: story.processor, name: adapterOf(story.processor)!.name }
      : { id: "stripe", name: "Stripe" },
    // Preset 8: the same customer's invoice 1, and whether this invoice waited for it.
    queue: story.earlier
      ? {
          earlier: {
            n: 1,
            invoiceId: story.earlier.invoiceId,
            recoveryId: story.earlier.recoveryId,
            status: earlierRaw
              ? (STATUS_ALIASES[earlierRaw] ?? earlierRaw)
              : null,
            stage: earlierStage,
            revrecRetries: earlierAtts.filter((a) => a.by === "revrec").length,
            endedAt: story.earlierEndedAt ?? null,
          },
          // Queued now while invoice 1 is open: waiting for its turn.
          waiting: story.started && stage === "Queued" && earlierOpen,
          turns: turnsSeen.turns,
          minGapSec: turnsSeen.minGapSec,
          startedAfterEarlier: internal[0]
            ? Boolean(
                story.earlierEndedAt && internal[0].at > story.earlierEndedAt,
              )
            : null,
          source: "recomputed" as const,
        }
      : null,
    savedCards,
    // The engine's outgoing webhooks: on when the proxy reads an inbox (INBOX_URL).
    webhooks: {
      on: Boolean(config.inboxUrl && config.inboxToken),
      read: webhookEvents !== null,
      count: webhookEvents_.length,
      lastAt: webhookEvents_.at(-1)?.receivedAt ?? null,
    },
    // The stand-in decider (DECIDER_URL), for a story on the decider profile: did the engine ask it?
    decider:
      prof(story).key === "decider"
        ? {
            on: Boolean(config.deciderUrl),
            read: deciderCalls !== null,
            asked: deciderCalls === null ? null : deciderCalls.length > 0,
            calls: (deciderCalls ?? []).map((c) => ({
              at: c.at,
              retryTime: c.answer.retryTime,
              decisionThreshold: c.answer.decisionThreshold,
              cardNetwork: c.cardNetwork,
              errorCode: c.pgErrorCode,
            })),
            text: deciderCalls?.length ? DECIDER_LABEL : null,
          }
        : null,
    smartNote: SMART_NOTE,
    explain,
    timeline,
    requests,
    lastReads,
    // Rev Rec is told only when the visitor hands the failed invoice over (story screen stories).
    handover: {
      awaiting: Boolean(story.awaitingHandover),
      at: story.handoverAt ?? null,
    },
    // Preset 10: the go-live profile and the backlog's invoices.
    goLive: gl
      ? {
          profileId: gl.profileId,
          mode: rrc.retryMode,
          revRecOnAt: gl.revRecOnAt,
          cleanedUp: Boolean(gl.cleanedUpAt),
        }
      : null,
    backlog,
    actions: {
      handover: Boolean(story.awaitingHandover),
      // Pause / resume this invoice (POST /sim/story/:id/pause or /resume)
      pause: (() => {
        const off = story.pause
          ? "The story is already paused."
          : pauseOff(story);
        return { allowed: !off, ...(off ? { reason: off } : {}) };
      })(),
      resume: Boolean(story.pause),
      goLive: Boolean(gl && story.started && !gl.revRecOnAt),
      paidInApp: open && !story.paidInAppAt,
      // Also on a finished invoice: the row then shows Rev Rec's answer to a late failure report.
      reportAgain:
        Boolean(story.recoveryId) &&
        (story.started || Boolean(story.error)) &&
        reportCount(story) < MAX_REPORTS,
      reportAgainClosed: isFinal ? stage : null,
      cancel: open || earlierPending,
      reportAgainMode: isFinal ? "new" : story.reportAgainMode,
      // What happens next: which events the visitor may send now, and why not.
      ...(() => {
        const now = lastRealLife;
        // "new_card" only with SIM_OTHER_CARDS=1 (off: the user's policy, 28 Oct)
        const types: WorldEventType[] = [
          "money_back",
          ...(config.otherCards ? (["new_card"] as const) : []),
          "stolen",
          "outage",
        ];
        const reasons = Object.fromEntries(
          types
            .map((k) => [k, eventOff(story, k, now)] as const)
            .filter(([, r]) => r),
        );
        return {
          moneyBack: !reasons.money_back,
          newCard: types.includes("new_card") && !reasons.new_card,
          events: {
            allowed: Object.fromEntries(types.map((k) => [k, !reasons[k]])),
            reasons,
          },
        };
      })(),
      // Live settings: what the visitor may change now, and why not.
      settings: (() => {
        const off =
          settingsOffOf(story) ??
          (isFinal || story.poolReleasedAt ? ENDED_OFF : null);
        return {
          allowed: {
            mode: !off && config.poolSmart,
            maxRetries: !off,
            graceDays: !off && rrc.retryMode === "smart",
            paused: !pauseOff(story),
          },
          reasons: {
            ...(off ? { mode: off, maxRetries: off } : {}),
            ...(!off && !config.poolSmart ? { mode: SMART_OFF } : {}),
            ...(off || rrc.retryMode !== "smart"
              ? { graceDays: off ?? GRACE_OFF }
              : {}),
            ...(pauseOff(story) ? { paused: pauseOff(story)! } : {}),
          },
          current: {
            paused: Boolean(story.pause),
            mode: shownMode(rrc.retryMode),
            maxRetries: rrc.maxRetries,
            graceDays: rrc.gracePeriodDays,
          },
          lease: (() => {
            const l = leaseOf(storyId);
            return l ? { profileId: l.profileId, leasedAt: l.leasedAt } : null;
          })(),
        };
      })(),
    },
    // Changes the visitor made, at their real-life moment (the calendar's bands and markers)
    worldEvents: story.worldEvents ?? [],
    warnings,
    startError: story.error,
  };
  viewCache.set(storyId, { at: Date.now(), view });
  return view;
}
