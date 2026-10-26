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
// back" (minutes after the invoice starts, drawn per invoice from the range). null = never.
const BANK: Record<
  Reason,
  { card: FirstChargeId; flip: [number, number] | null; rule: string }
> = {
  insufficient_funds: {
    card: "9995",
    flip: [4, 12],
    rule: "No money until the payday, 4 to 12 minutes after the first failure.",
  },
  generic_decline: {
    card: "0002",
    flip: [2, 6],
    rule: "Works again after a quiet window of 2 to 6 minutes.",
  },
  processing_error: {
    card: "0119",
    flip: [1, 1],
    rule: "A temporary error: works again after 1 minute.",
  },
  stolen_card: {
    card: "9979",
    flip: null,
    rule: "Never works again (hard decline).",
  },
  expired_card: {
    card: "0069",
    flip: null,
    rule: "Never works again in V1 (the account updater is display only).",
  },
};

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
    maxMinutes: int(body.maxMinutes, 45, 5, 45, "maxMinutes"),
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
function buildInvoices(d: Dials): PfInvoice[] {
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
    const f = BANK[reason].flip;
    return {
      i: idx + 1,
      reason,
      amount: d.amount,
      // Half-minute steps inside the reason's range.
      flipAfterMin: f ? f[0] + Math.round(rng() * (f[1] - f[0]) * 2) / 2 : null,
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
    invoices: buildInvoices(dials),
    trend: [],
    error: null,
    profiles: { static: PROFILES.static, smart: PROFILES.smart },
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

const timers = new Map<string, NodeJS.Timeout>();
const ticking = new Set<string>();
function schedule(run: Run) {
  if (timers.has(run.runId)) return;
  timers.set(
    run.runId,
    setInterval(() => void tick(run), TICK_MS),
  );
}
function stopTimer(run: Run) {
  clearInterval(timers.get(run.runId));
  timers.delete(run.runId);
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
    const elapsedMin = (Date.now() - Date.parse(run.startedAt)) / 60_000;
    if (run.status === "running" && elapsedMin >= run.dials.maxMinutes) {
      await poll(run);
      return await end(run, `time cap of ${run.dials.maxMinutes} min`);
    }
    await flipDue(run);
    await poll(run);
    // Half-minute steps: one point per 30 s tick.
    const minute =
      Math.round(((Date.now() - Date.parse(run.startedAt)) / 60_000) * 2) / 2;
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

// The bank: when an invoice's flip time has passed, both copies get the swap report.
async function flipDue(run: Run) {
  for (const inv of run.invoices) {
    if (!inv.flipAt || inv.flippedAt || Date.now() < Date.parse(inv.flipAt))
      continue;
    const copies = SIDES.map((s) => inv.copies[s]).filter(
      (c) => c !== undefined,
    );
    // Wait until both copies have finished their start.
    if (
      copies.length < SIDES.length ||
      copies.some((c) => !getStory(c.storyId).started && !c.error)
    )
      continue;
    inv.flippedAt = new Date().toISOString();
    await Promise.all(
      copies.map(async (c) => {
        if (!c.recoveryId || isFinalStatus(c.status)) return;
        await reportAgain(c.storyId, "swap").catch((e) => {
          c.error = scrubText(String((e as Error).message));
        });
      }),
    );
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
  const elapsedMin = (Date.now() - Date.parse(run.startedAt)) / 60_000;
  if (run.status === "running" && openCopies(run).length === 0)
    return end(run, "every invoice reached a final status");
  if (elapsedMin >= run.dials.maxMinutes)
    return end(run, `time cap of ${run.dials.maxMinutes} min`);
}

async function end(run: Run, reason: string) {
  for (const c of openCopies(run))
    await cancelStory(c.storyId)
      .then(() => {
        c.status = "cancelled";
      })
      .catch((e) => {
        c.error = scrubText(String((e as Error).message));
      });
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

const LATE_FLIP_SEC = 90;

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
      rule: BANK[reason].rule,
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
      static: inv.copies.static ?? null,
      smart: inv.copies.smart ?? null,
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
            `Both runs use the same profile (${pair.static.profileId}, ${modes[0] ?? "mode unknown"}) until the smart profile exists. A difference between the two cards is noise, not strategy.`,
          ]
        : []),
      ...pausesOf(run).map(
        (p) =>
          `The proxy did not run from ${p.from.slice(11, 19)} to ${p.to.slice(11, 19)} UTC (${p.minutes} min; on a laptop, sleep). Bank flips and status reads in that window were late.`,
      ),
      // The scripted bank must be on time to be a fair test. A late flip comes from the proxy
      // (a slow sandbox or a busy machine), not from Rev Rec.
      ...run.invoices
        .filter((inv) => (lateSec(inv) ?? 0) > LATE_FLIP_SEC)
        .map(
          (inv) =>
            `Invoice ${inv.i}: the bank flip came ${Math.round(lateSec(inv)! / 60)} min late, so its result is not a fair data point.`,
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
