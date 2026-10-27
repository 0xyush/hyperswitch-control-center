// The portfolio run (M2): one batch of invoices goes through Rev Rec twice, once per profile.
// Design: simulator/PORTFOLIO.md. Each copy is an ordinary story with its own Stripe customer and
// saved card, so a click on a copy opens its story view. The bank is scripted: at an invoice's flip
// time the billing system reports a new failure that carries the good 4242 card, for both copies.
// Off unless SIM_PORTFOLIO=1. Until the smart profile exists, both copies use the same profile.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {
  config,
  PROFILES,
  portfolioConfig,
  type ProfileRef,
} from "./config.ts";
import { scrubText } from "./redact.ts";
import type { FirstChargeId } from "./scenarios.ts";
import {
  cancelStory,
  getStory,
  HttpError,
  isFinalStatus,
  normalizeStatus,
  readRevRecConfig,
  reportAgain,
  startStory,
  storyView,
  type Story,
} from "./story.ts";
import { hsApiKey } from "./upstream.ts";

const REASONS = [
  "insufficient_funds",
  "generic_decline",
  "processing_error",
  "stolen_card",
  "expired_card",
] as const;
type Reason = (typeof REASONS)[number];

// The scripted bank (PORTFOLIO.md §3): the first-charge card per reason, and when "the money is
// back" after the invoice starts, drawn per invoice from the range. null = never.
// flip: minutes, at sandbox pace (Rev Rec retries minutes apart).
// fastFlipSec: seconds, for the self-hosted engine (SIM_FAST_ENGINE=1; retries about 5 s apart),
// so a 1 min run still sees each bank change and the next retry after it.
type Bank = {
  card: FirstChargeId;
  flip: [number, number] | null;
  fastFlipSec: [number, number] | null;
  rule: (span: string) => string;
};
const BANK: Record<Reason, Bank> = {
  insufficient_funds: {
    card: "9995",
    flip: [4, 12],
    fastFlipSec: [15, 45],
    rule: (s) => `No money until the payday, ${s} after the first failure.`,
  },
  generic_decline: {
    card: "0002",
    flip: [2, 6],
    fastFlipSec: [10, 30],
    rule: (s) => `Works again after a quiet window of ${s}.`,
  },
  processing_error: {
    card: "0119",
    flip: [1, 1],
    fastFlipSec: [5, 5],
    rule: (s) => `A temporary error: works again after ${s}.`,
  },
  stolen_card: {
    card: "9979",
    flip: null,
    fastFlipSec: null,
    rule: () => "Never works again (hard decline).",
  },
  expired_card: {
    card: "0069",
    flip: null,
    fastFlipSec: null,
    rule: () =>
      "Never works again in V1 (the account updater is display only).",
  },
};

// The bank rule in words, at the run's pace.
export function bankRule(reason: Reason, fast: boolean) {
  const b = BANK[reason];
  const r = fast ? b.fastFlipSec : b.flip;
  if (!r) return b.rule("");
  const [lo, hi] = r;
  const span = fast
    ? lo === hi
      ? `${lo} s`
      : `${lo} to ${hi} s`
    : lo === hi
      ? `${lo} minute${lo === 1 ? "" : "s"}`
      : `${lo} to ${hi} minutes`;
  return b.rule(span);
}

// When the money is back, in minutes after the invoice starts: half minutes at sandbox pace,
// whole seconds at fast pace. One draw per invoice that flips, as before, so a seed repeats.
export function drawFlip(reason: Reason, fast: boolean, rng: () => number) {
  const b = BANK[reason];
  if (fast) {
    const f = b.fastFlipSec;
    return f
      ? Math.round(((f[0] + Math.round(rng() * (f[1] - f[0]))) / 60) * 1000) /
          1000
      : null;
  }
  const f = b.flip;
  return f ? f[0] + Math.round(rng() * (f[1] - f[0]) * 2) / 2 : null;
}

// The two sides of a run: a copy of each invoice runs on each.
type Side = "static" | "smart";
const SIDES: Side[] = ["static", "smart"];
const TICK_MS = 30_000;
const PAUSE_MS = 3 * TICK_MS;

type Copy = {
  storyId: string;
  recoveryId: string | null;
  status: string | null;
  revrecAttempts: number;
  recoveredAt: string | null;
  error: string | null;
  // The bank's swap report for this copy (runs from 27 Oct; see flipDue).
  swapTries?: number;
  swappedAt?: string | null;
};

type PfInvoice = {
  i: number;
  reason: Reason;
  amount: number;
  flipAfterMin: number | null;
  startedAt: string | null;
  flipAt: string | null;
  flippedAt: string | null;
  copies: Partial<Record<Side, Copy>>;
};

export type Dials = {
  invoices: number;
  amount: number;
  mix: Partial<Record<Reason, number>>;
  maxMinutes: number;
  seed: number;
};

type Run = {
  runId: string;
  owner: string;
  status: "setting_up" | "running" | "done" | "error";
  startedAt: string;
  setupDoneAt: string | null;
  endedAt: string | null;
  endReason: string | null;
  dials: Dials;
  invoices: PfInvoice[];
  trend: { minute: number; static: number; smart: number }[];
  error: string | null;
  // The pair the run used. Runs before 24 Oct have none: both sides ran on the story profile.
  profiles?: Record<Side, ProfileRef>;
  // Gaps of more than 90 s between ticks: the proxy did not run (on a laptop: sleep).
  lastTickAt?: string;
  // The pace of the run's scripted bank, fixed at start (SIM_FAST_ENGINE). Older runs: sandbox.
  fast?: boolean;
  // Swaps tracked per copy (from 27 Oct). Older runs swapped both copies once, at flippedAt.
  perCopySwap?: boolean;
  pauses?: { from: string; to: string; minutes: number }[];
};

const pairOf = (run: Run): Record<Side, ProfileRef> =>
  run.profiles ?? { static: PROFILES.story, smart: PROFILES.story };

// ---------- store (data/portfolio.json) ----------

const STORE_FILE = path.join(config.dataDir, "portfolio.json");
const runs = new Map<string, Run>();

function save() {
  const all = [...runs.values()].slice(-50);
  fs.mkdirSync(config.dataDir, { recursive: true });
  fs.writeFileSync(`${STORE_FILE}.tmp`, JSON.stringify(all, null, 2));
  fs.renameSync(`${STORE_FILE}.tmp`, STORE_FILE);
}

function getRun(runId: string): Run {
  const r = runs.get(runId);
  if (!r) throw new HttpError(404, `portfolio run ${runId} not found`);
  return r;
}

// ---------- the run spec ----------

// A small seeded random generator, so a run can be repeated with the same invoices and bank rules.
function mulberry32(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const DEFAULT_MIX: Partial<Record<Reason, number>> = {
  insufficient_funds: 4,
  generic_decline: 3,
  processing_error: 2,
  stolen_card: 1,
};

export function parsePortfolio(body: any): Dials {
  const bad = (m: string) => new HttpError(400, m);
  const int = (
    v: unknown,
    def: number,
    lo: number,
    hi: number,
    name: string,
  ) => {
    const n = v === undefined ? def : Number(v);
    if (!Number.isInteger(n) || n < lo || n > hi)
      throw bad(`${name} must be an integer from ${lo} to ${hi}`);
    return n;
  };
  const mix: Partial<Record<Reason, number>> = {};
  for (const [k, v] of Object.entries(body.mix ?? DEFAULT_MIX)) {
    if (!(REASONS as readonly string[]).includes(k))
      throw bad(`mix keys must be among ${REASONS.join(", ")}`);
    const w = Number(v);
    if (!(w >= 0)) throw bad("mix weights must be 0 or more");
    if (w > 0) mix[k as Reason] = w;
  }
  if (!Object.keys(mix).length)
    throw bad("mix needs at least one weight above 0");
  // One of the form's stop-after choices (PORTFOLIO_STOP_AFTER_MINUTES, default 10, 20, 45;
  // floats such as 0.5 on the self-hosted stack). The default is the largest choice.
  const choices = portfolioConfig.stopAfterMinutes;
  const maxMinutes =
    body.maxMinutes === undefined ? choices.at(-1)! : Number(body.maxMinutes);
  if (!choices.includes(maxMinutes))
    throw bad(`maxMinutes must be one of ${choices.join(", ")}`);
  return {
    invoices: int(
      body.invoices,
      portfolioConfig.maxInvoices,
      1,
      portfolioConfig.maxInvoices,
      "invoices",
    ),
    amount: int(body.amount, 6540, 50, 1_000_000, "amount (minor units)"),
    mix,
    maxMinutes,
    seed: int(
      body.seed,
      Math.floor(Math.random() * 1_000_000),
      0,
      2 ** 31 - 1,
      "seed",
    ),
  };
}

// Splits n invoices over the reasons by weight (largest remainder), then shuffles with the seed.
function buildInvoices(d: Dials, fast: boolean): PfInvoice[] {
  const rng = mulberry32(d.seed);
  const entries = Object.entries(d.mix) as [Reason, number][];
  const total = entries.reduce((s, [, w]) => s + w, 0);
  const exact = entries.map(([r, w]) => ({ r, x: (w / total) * d.invoices }));
  const counts = exact.map((e) => ({
    r: e.r,
    n: Math.floor(e.x),
    rest: e.x % 1,
  }));
  let left = d.invoices - counts.reduce((s, c) => s + c.n, 0);
  for (const c of [...counts].sort((a, b) => b.rest - a.rest)) {
    if (left-- <= 0) break;
    c.n += 1;
  }
  const reasons = counts.flatMap((c) => Array<Reason>(c.n).fill(c.r));
  for (let k = reasons.length - 1; k > 0; k--) {
    const j = Math.floor(rng() * (k + 1));
    [reasons[k], reasons[j]] = [reasons[j], reasons[k]];
  }
  return reasons.map((reason, idx) => {
    return {
      i: idx + 1,
      reason,
      amount: d.amount,
      flipAfterMin: drawFlip(reason, fast, rng),
      startedAt: null,
      flipAt: null,
      flippedAt: null,
      copies: {},
    };
  });
}

// ---------- the run ----------

export function startPortfolio(dials: Dials, owner: string): Run {
  const active = [...runs.values()].find(
    (r) => r.status === "setting_up" || r.status === "running",
  );
  if (active)
    throw new HttpError(
      409,
      `portfolio run ${active.runId} is still going; one run at a time`,
    );
  const hourAgo = Date.now() - 3_600_000;
  const mine = [...runs.values()].filter(
    (r) => r.owner === owner && Date.parse(r.startedAt) > hourAgo,
  );
  if (mine.length >= portfolioConfig.runsPerHour)
    throw new HttpError(
      429,
      `limit is ${portfolioConfig.runsPerHour} portfolio run per hour`,
    );

  const run: Run = {
    runId: `pf_${crypto.randomBytes(4).toString("hex")}`,
    owner,
    status: "setting_up",
    startedAt: new Date().toISOString(),
    setupDoneAt: null,
    endedAt: null,
    endReason: null,
    dials,
    invoices: buildInvoices(dials, config.fastEngine),
    trend: [],
    error: null,
    profiles: { static: PROFILES.static, smart: PROFILES.smart },
    fast: config.fastEngine,
    perCopySwap: true,
  };
  runs.set(run.runId, run);
  save();
  schedule(run);
  setup(run).catch((e) => {
    run.status = "error";
    run.error = scrubText(String((e as Error).message ?? e));
    stopTimer(run);
    save();
  });
  return run;
}

// Creates both copies of each invoice, one invoice at a time. The two copies of an invoice start
// together, so their clocks match; the shared queue keeps calls under 5 per second.
async function setup(run: Run) {
  for (const inv of run.invoices) {
    inv.startedAt = new Date().toISOString();
    if (inv.flipAfterMin !== null)
      inv.flipAt = new Date(
        Date.parse(inv.startedAt) + inv.flipAfterMin * 60_000,
      ).toISOString();
    const started = SIDES.map((side) => {
      const { story, done } = startStory(
        {
          presetId: null,
          amount: inv.amount,
          currency: "USD",
          savedCard: "0341",
          firstCharge: BANK[inv.reason].card,
          customer: "new",
          sendDuplicateOnStart: false,
          reportAgainMode: "swap",
        },
        run.owner,
        {
          profile: side,
          invoiceId: `PF-${run.runId.slice(3)}-${inv.i}-${side === "static" ? "S" : "R"}`,
          portfolioRunId: run.runId,
          paced: true,
        },
      );
      inv.copies[side] = {
        storyId: story.storyId,
        recoveryId: null,
        status: null,
        revrecAttempts: 0,
        recoveredAt: null,
        error: null,
      };
      return done.then(() => {
        const c = inv.copies[side]!;
        c.recoveryId = story.recoveryId;
        c.error = story.error;
      });
    });
    save();
    await Promise.all(started);
    save();
  }
  run.setupDoneAt = new Date().toISOString();
  if (run.status === "setting_up") run.status = "running";
  save();
}

// A short run reads more often: about 6 reads per minute of cap, from every 5 s to every 30 s.
// Runs of 3 min or more (all sandbox runs) keep the 30 s tick.
const tickMs = (run: Run) =>
  Math.min(TICK_MS, Math.max(5_000, run.dials.maxMinutes * 10_000));

// The time cap counts from the end of setup, so the last invoice gets about as long as the first
// (setup alone can take longer than a 0.5 min cap). It never ends a run during setup.
const capReached = (run: Run) =>
  run.status === "running" &&
  run.setupDoneAt !== null &&
  (Date.now() - Date.parse(run.setupDoneAt)) / 60_000 >= run.dials.maxMinutes;

const timers = new Map<string, NodeJS.Timeout>();
const ticking = new Set<string>();
// A fast run checks its bank flips every 2 s, apart from the status tick: a flip a whole tick late
// is a large share of a 1 min run.
const FAST_FLIP_MS = 2_000;
const flipTimers = new Map<string, NodeJS.Timeout>();
const flipping = new Set<string>();
function schedule(run: Run) {
  if (timers.has(run.runId)) return;
  timers.set(
    run.runId,
    setInterval(() => void tick(run), tickMs(run)),
  );
  if (run.fast)
    flipTimers.set(
      run.runId,
      setInterval(() => void flipLoop(run), FAST_FLIP_MS),
    );
}
function stopTimer(run: Run) {
  clearInterval(timers.get(run.runId));
  timers.delete(run.runId);
  clearInterval(flipTimers.get(run.runId));
  flipTimers.delete(run.runId);
}
async function flipLoop(run: Run) {
  if (flipping.has(run.runId)) return;
  if (run.status !== "setting_up" && run.status !== "running") return;
  flipping.add(run.runId);
  try {
    await flipDue(run);
  } catch (e) {
    console.log(
      `portfolio ${run.runId} flip failed: ${scrubText(String((e as Error).message))}`,
    );
  } finally {
    flipping.delete(run.runId);
    save();
  }
}

async function tick(run: Run) {
  if (ticking.has(run.runId)) return;
  if (run.status !== "setting_up" && run.status !== "running")
    return stopTimer(run);
  ticking.add(run.runId);
  try {
    // On 23 and 24 Oct the laptop went into idle sleep during runs; timers do not run then.
    const now = new Date().toISOString();
    if (
      run.lastTickAt &&
      Date.parse(now) - Date.parse(run.lastTickAt) > PAUSE_MS
    ) {
      const minutes =
        Math.round((Date.parse(now) - Date.parse(run.lastTickAt)) / 6_000) / 10;
      (run.pauses ??= []).push({ from: run.lastTickAt, to: now, minutes });
    }
    run.lastTickAt = now;
    // A late tick (a slow sandbox, a sleeping machine) still ends the run at the cap.
    if (capReached(run)) {
      await poll(run);
      return await end(run, `time cap of ${run.dials.maxMinutes} min`);
    }
    if (!run.fast) await flipDue(run);
    await poll(run);
    // One point per tick, in steps of the tick (half minutes for a 30 s tick).
    const step = tickMs(run) / 60_000;
    const minute =
      Math.round(
        Math.round((Date.now() - Date.parse(run.startedAt)) / 60_000 / step) *
          step *
          1000,
      ) / 1000;
    const recovered = (side: Side) =>
      run.invoices.filter((inv) => inv.copies[side]?.status === "recovered")
        .length;
    run.trend.push({
      minute,
      static: recovered("static"),
      smart: recovered("smart"),
    });
    await maybeEnd(run);
  } catch (e) {
    console.log(
      `portfolio ${run.runId} tick failed: ${scrubText(String((e as Error).message))}`,
    );
  } finally {
    ticking.delete(run.runId);
    save();
  }
}

// Rev Rec is charging the copy now, or its booked charge is from 3 s ahead to 3 s past. A swap
// takes 1 to 2 s to reach the engine (a Stripe charge first), and a charge about as long.
async function charging(c: Copy) {
  const v: any = await storyView(c.storyId).catch(() => null);
  if (!v) return false;
  if (/processing/.test(String(v.sandboxStatus))) return true;
  const t = v.nextRetryAt ? Date.parse(v.nextRetryAt) : Number.NaN;
  return Number.isFinite(t) && Math.abs(Date.now() - t) <= 3_000;
}

// The bank: when an invoice's flip time has passed, each copy gets the swap report.
// A swap that lands while Rev Rec charges the copy collides with that charge: the engine refused
// it (404) or recorded it and then never retried (pf_df48a281 invoice 2, fast engine, 27 Oct).
// So a copy's swap waits while Rev Rec charges it or is about to, and a refused swap is sent again
// at the next tick, up to 3 tries. flippedAt is when the last copy got its swap.
const SWAP_TRIES = 3;
async function flipDue(run: Run) {
  for (const inv of run.invoices) {
    if (!inv.flipAt || Date.now() < Date.parse(inv.flipAt)) continue;
    if (!run.perCopySwap && inv.flippedAt) continue;
    const copies = SIDES.map((s) => inv.copies[s]).filter(
      (c) => c !== undefined,
    );
    // Wait until both copies have finished their start.
    if (
      copies.length < SIDES.length ||
      copies.some((c) => !getStory(c.storyId).started && !c.error)
    )
      continue;
    const open = copies.filter(
      (c) => c.recoveryId && !isFinalStatus(c.status) && !c.swappedAt,
    );
    const todo = open.filter((c) => (c.swapTries ?? 0) < SWAP_TRIES);
    await Promise.all(
      todo.map(async (c) => {
        if (await charging(c)) return;
        c.swapTries = (c.swapTries ?? 0) + 1;
        try {
          await reportAgain(c.storyId, "swap");
          c.swappedAt = new Date().toISOString();
          c.error = null;
        } catch (e) {
          c.error = scrubText(String((e as Error).message));
        }
      }),
    );
    const left = copies.filter(
      (c) =>
        c.recoveryId &&
        !isFinalStatus(c.status) &&
        !c.swappedAt &&
        (c.swapTries ?? 0) < SWAP_TRIES,
    );
    if (!inv.flippedAt && !left.length) {
      const times = copies
        .map((c) => c.swappedAt)
        .filter((x): x is string => Boolean(x))
        .sort();
      inv.flippedAt = times.at(-1) ?? new Date().toISOString();
    }
  }
}

// Runs fn over the items with at most `limit` calls at a time.
async function eachLimited<T>(
  items: T[],
  limit: number,
  fn: (t: T) => Promise<void>,
) {
  let next = 0;
  const worker = async () => {
    while (next < items.length) await fn(items[next++]);
  };
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, worker),
  );
}

// One invoice-list read per profile gives every status. Attempts are read for every copy that
// was still open, at most 5 reads at a time: the status can look the same at two ticks with a
// Rev Rec retry in between (run pf_5f2dcd18 counted 3 retries where the sandbox had 7).
async function poll(run: Run) {
  const status = new Map<string, string>();
  const pair = pairOf(run);
  for (const profileId of new Set(SIDES.map((s) => pair[s].profileId))) {
    for (let offset = 0; offset < 500; offset += 100) {
      const q = `profile_id=${profileId}&created.gte=${encodeURIComponent(run.startedAt)}&limit=100&offset=${offset}`;
      const r = await hsApiKey(
        "GET",
        `v2/payments/recovery-list?${q}`,
        undefined,
        profileId,
      );
      const rows: any[] = r.status === 200 ? (r.json?.data ?? []) : [];
      for (const row of rows) status.set(row.id, row.status);
      if (rows.length < 100) break;
    }
  }
  const toRead: { c: Copy; side: Side }[] = [];
  for (const inv of run.invoices)
    for (const side of SIDES) {
      const c = inv.copies[side];
      if (!c?.recoveryId) continue;
      const next = normalizeStatus(status.get(c.recoveryId));
      if (!next) continue;
      // Open copies, copies that just became final, and a recovered copy whose paying
      // attempt has not shown up yet.
      const read =
        !isFinalStatus(c.status) || (next === "recovered" && !c.recoveredAt);
      c.status = next;
      if (read) toRead.push({ c, side });
    }
  await eachLimited(toRead, 5, async ({ c, side }) => {
    const r = await hsApiKey(
      "GET",
      `v2/payments/${c.recoveryId}/list_attempts`,
      undefined,
      pairOf(run)[side].profileId,
    ).catch(() => null);
    if (r?.status !== 200) return;
    const own = (r.json?.payment_attempt_list ?? []).filter(
      (a: any) =>
        a.feature_metadata?.revenue_recovery?.attempt_triggered_by ===
        "internal",
    );
    c.revrecAttempts = own.length;
    const paid = own.find((a: any) => a.status === "charged");
    c.recoveredAt = paid ? (paid.modified_at ?? paid.created_at) : null;
  });
}

const openCopies = (run: Run) =>
  run.invoices.flatMap((inv) =>
    SIDES.map((s) => inv.copies[s]).filter(
      (c): c is Copy =>
        c !== undefined && Boolean(c.recoveryId) && !isFinalStatus(c.status),
    ),
  );

// The run ends when every copy is final, or at the time cap. Open copies are cancelled, so
// nothing keeps retrying on the sandbox.
async function maybeEnd(run: Run) {
  if (run.status === "running" && openCopies(run).length === 0)
    return end(run, "every invoice reached a final status");
  if (capReached(run))
    return end(run, `time cap of ${run.dials.maxMinutes} min`);
}

// A copy Rev Rec is charging cannot be cancelled ("payment is in processing state"). On the fast
// engine a charge lasts about a second, so wait and try again, up to 3 times; a copy left open
// would keep retrying after the run ends (pf_df48a281, 27 Oct).
async function cancelCopy(c: Copy) {
  for (let k = 0; ; k++) {
    try {
      await cancelStory(c.storyId);
      c.status = "cancelled";
      return;
    } catch (e) {
      const msg = scrubText(String((e as Error).message));
      if (k < 2 && /processing state/i.test(msg)) {
        await new Promise((ok) => setTimeout(ok, 2_000));
        continue;
      }
      c.error = msg;
      return;
    }
  }
}

async function end(run: Run, reason: string) {
  for (const c of openCopies(run)) await cancelCopy(c);
  run.status = "done";
  run.endReason = reason;
  run.endedAt = new Date().toISOString();
  stopTimer(run);
  save();
}

export async function stopPortfolio(runId: string) {
  const run = getRun(runId);
  if (run.status === "done" || run.status === "error")
    throw new HttpError(409, `run ${runId} has already ended`);
  if (run.status === "setting_up")
    throw new HttpError(
      409,
      "the run is still creating invoices; stop it when setup ends",
    );
  await end(run, "stopped by the visitor");
}

// Load saved runs. A run caught by a restart during setup cannot resume; a running one can.
try {
  for (const r of JSON.parse(fs.readFileSync(STORE_FILE, "utf8")) as Run[]) {
    if (r.status === "setting_up") {
      r.status = "error";
      r.error = "The proxy restarted while the run was creating invoices.";
    }
    runs.set(r.runId, r);
    if (r.status === "running") schedule(r);
  }
} catch {
  // No saved runs yet.
}

// ---------- the result view (GET /sim/portfolio/:runId) ----------

// A bank flip later than this is not a fair data point. A fast run reads every 5 to 20 s.
const lateFlipSec = (run: Run) => (run.fast ? 20 : 90);

// Runs before 26 Oct did not record pauses; their trend points (one per 30 s tick) show them.
function pausesOf(run: Run) {
  if (run.pauses) return run.pauses;
  const at = (minute: number) =>
    new Date(Date.parse(run.startedAt) + minute * 60_000).toISOString();
  const out: { from: string; to: string; minutes: number }[] = [];
  // The end of the run counts as a last point: its final tick adds no trend point.
  const points = run.trend.map((t) => t.minute);
  if (run.endedAt)
    points.push((Date.parse(run.endedAt) - Date.parse(run.startedAt)) / 60_000);
  for (let k = 1; k < points.length; k++) {
    const gap = Math.round((points[k] - points[k - 1]) * 2) / 2;
    if (gap * 60_000 > PAUSE_MS)
      out.push({ from: at(points[k - 1]), to: at(points[k]), minutes: gap });
  }
  return out;
}
const lateSec = (inv: PfInvoice) =>
  inv.flipAt && inv.flippedAt
    ? Math.max(
        0,
        Math.round((Date.parse(inv.flippedAt) - Date.parse(inv.flipAt)) / 1000),
      )
    : null;

// Where a copy is in setup, so the form's rows can fill while the run is setting up:
// pending   not created yet, or its first charge has not failed yet
// charged   the billing system's charge failed (a Stripe payment id on the story)
// reported  Rev Rec recorded the failure (the copy has its invoice id)
type SetupStage = "pending" | "charged" | "reported";
export function setupStage(c: Copy | undefined): SetupStage {
  if (!c) return "pending";
  let story: Story | null = null;
  try {
    story = getStory(c.storyId);
  } catch {
    // A story the store no longer holds: go by the copy alone.
  }
  if (c.recoveryId || story?.recoveryId) return "reported";
  if (
    story?.events.some(
      (e) => e.from === "billing" && e.to === "processor" && e.txnId,
    )
  )
    return "charged";
  return "pending";
}

const NO_COPY = {
  storyId: null,
  recoveryId: null,
  status: null,
  revrecAttempts: 0,
  recoveredAt: null,
  error: null,
};
const copyView = (c: Copy | undefined) => ({
  ...(c ?? NO_COPY),
  setupStage: setupStage(c),
});

function quantile(sorted: number[], q: number) {
  if (!sorted.length) return null;
  const idx = Math.min(sorted.length - 1, Math.ceil(q * sorted.length) - 1);
  return Math.round(sorted[Math.max(0, idx)] * 10) / 10;
}

function card(run: Run, side: Side) {
  const rows = run.invoices
    .map((inv) => ({ inv, c: inv.copies[side] }))
    .filter((x): x is { inv: PfInvoice; c: Copy } => x.c !== undefined);
  const recovered = rows.filter((x) => x.c.status === "recovered");
  const minutes = recovered
    .filter((x) => x.c.recoveredAt && x.inv.startedAt)
    .map(
      (x) =>
        (Date.parse(x.c.recoveredAt!) - Date.parse(x.inv.startedAt!)) / 60_000,
    )
    .sort((a, b) => a - b);
  const count = (s: string) => rows.filter((x) => x.c.status === s).length;
  const attempts = rows.reduce((s, x) => s + x.c.revrecAttempts, 0);
  return {
    invoices: rows.length,
    recovered: recovered.length,
    recoveryRate: rows.length
      ? Math.round((recovered.length / rows.length) * 1000) / 1000
      : null,
    recoveredAmount: recovered.reduce((s, x) => s + x.inv.amount, 0),
    revrecAttempts: attempts,
    attemptsPerRecovery: recovered.length
      ? Math.round(
          (recovered.reduce((s, x) => s + x.c.revrecAttempts, 0) /
            recovered.length) *
            10,
        ) / 10
      : null,
    minutesToRecovery: {
      median: quantile(minutes, 0.5),
      p90: quantile(minutes, 0.9),
    },
    terminated: count("terminated"),
    cancelled: count("cancelled"),
    open:
      rows.length - recovered.length - count("terminated") - count("cancelled"),
  };
}

export async function portfolioView(runId: string) {
  const run = getRun(runId);
  const pair = pairOf(run);
  const modes = await Promise.all(
    SIDES.map((s) =>
      readRevRecConfig(pair[s]).then(
        (c) => c.retryMode,
        () => null,
      ),
    ),
  );
  const sameProfile = pair.static.profileId === pair.smart.profileId;
  // Same strategy on both sides (one profile, or two profiles in the same mode): the two cards
  // can differ only by sandbox timing. The first run measured about 1.5 min and 2 attempts.
  const sameStrategy =
    sameProfile || (modes[0] !== null && modes[0] === modes[1]);
  const reasons = [...new Set(run.invoices.map((inv) => inv.reason))];
  return {
    runId: run.runId,
    seed: run.dials.seed,
    status: run.status,
    startedAt: run.startedAt,
    setupDoneAt: run.setupDoneAt,
    endedAt: run.endedAt,
    endReason: run.endReason,
    error: run.error,
    dials: run.dials,
    profiles: {
      static: { profileId: pair.static.profileId, mode: modes[0] },
      smart: { profileId: pair.smart.profileId, mode: modes[1] },
    },
    cards: { static: card(run, "static"), smart: card(run, "smart") },
    byReason: reasons.map((reason) => {
      const of = run.invoices.filter((inv) => inv.reason === reason);
      const rec = (s: Side) =>
        of.filter((inv) => inv.copies[s]?.status === "recovered").length;
      return {
        reason,
        invoices: of.length,
        static: { recovered: rec("static") },
        smart: { recovered: rec("smart") },
      };
    }),
    bankRules: reasons.map((reason) => ({
      reason,
      firstChargeCard: BANK[reason].card,
      rule: bankRule(reason, Boolean(run.fast)),
      source: "scripted",
    })),
    trend: run.trend,
    pauses: pausesOf(run),
    invoices: run.invoices.map((inv) => ({
      i: inv.i,
      reason: inv.reason,
      amount: inv.amount,
      bank: {
        flipAfterMin: inv.flipAfterMin,
        flipAt: inv.flipAt,
        flippedAt: inv.flippedAt,
        lateSec: lateSec(inv),
      },
      // Always an object, with setupStage; a copy not created yet has null ids.
      static: copyView(inv.copies.static),
      smart: copyView(inv.copies.smart),
    })),
    sources: {
      status: "sandbox",
      attempts: "sandbox",
      cards: "recomputed",
      bank: "scripted",
    },
    comparison: {
      sameStrategy,
      label: sameStrategy
        ? "Same strategy on both sides, differences are sandbox timing noise"
        : `${modes[0] ?? "static"} vs ${modes[1] ?? "smart"}`,
      source: "recomputed",
    },
    warnings: [
      ...(sameProfile
        ? [
            // No ids in notes: the profile ids are in `profiles` above.
            `Both runs use the same profile (retry mode ${modes[0] ?? "unknown"}) until the smart profile exists. A difference between the two cards is noise, not strategy.`,
          ]
        : []),
      ...pausesOf(run).map(
        (p) =>
          `The proxy did not run from ${p.from.slice(11, 19)} to ${p.to.slice(11, 19)} UTC (${p.minutes} min; on a laptop, sleep). Bank flips and status reads in that window were late.`,
      ),
      // The scripted bank must be on time to be a fair test. A late flip comes from the proxy
      // (a slow sandbox or a busy machine), not from Rev Rec.
      ...run.invoices
        .filter((inv) => (lateSec(inv) ?? 0) > lateFlipSec(run))
        .map(
          (inv) =>
            `Invoice ${inv.i}: the bank flip came ${run.fast ? `${lateSec(inv)} s` : `${Math.round(lateSec(inv)! / 60)} min`} late, so its result is not a fair data point.`,
        ),
    ],
  };
}

export function listPortfolios() {
  return [...runs.values()].reverse().map((r) => ({
    runId: r.runId,
    status: r.status,
    startedAt: r.startedAt,
    invoices: r.invoices.length,
  }));
}
