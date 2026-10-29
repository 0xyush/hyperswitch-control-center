// Seeded retry stats for the engine's own smart-retry model (MODEL.md). SEEDED COUNTS, NOT
// JUSPAY'S PRODUCTION DATA: the rates are made up for the demo, shaped like published retry
// patterns, and turned into counters the engine reads from revenue_recovery_retry_stats.
//
// The engine keys a cluster by its standardised error code ("v1|<code>/UNK/UNK") and reads, per
// slot, n tries and k successes (crates/hyperswitch_domain_models/src/revenue_recovery/
// retry_stats_document.rs). Slot indexing matches the engine (workflows/revenue_recovery.rs:1611):
//   dow: 0 = Monday .. 6 = Sunday · dom: 0 = the 1st .. 30 = the 31st · hod: 0 .. 23 (UTC)
//
// Usage: node retry-stats.mjs > retry-stats.csv   (columns cluster_key,stats; the admin route
// POST /v2/recovery/data-backfill/retry-stats takes it as the multipart field "file")

// Seeded tries per cluster, the same in every family and spread evenly: 744 per weekday, 168 per
// day of month, 217 per hour. 5,208 is the smallest total that 7, 31 and 24 all divide; uneven
// tries would make equal rates look unequal.
export const TOTAL_TRIES = 5208;

const range = (n) => Array.from({ length: n }, (_, i) => i);
const sum = (values) => values.reduce((s, v) => s + v, 0);

// Days since the last payday, for semi-monthly pay on the 1st and the 15th. dom is 0-based.
const daysSincePayday = (dom) => (dom < 14 ? dom : dom - 14);

// Success rate per slot, per cluster and family. Each function returns a rate in (0, 1).
// "Ours" marks a choice we made where a published pattern gives only a direction.
export const PATTERNS = {
  insufficient_funds: {
    // Pay cycle: success is highest right after payday and decays towards a floor before the
    // next one; paydays on the 1st and the 15th. Peak 0.60, floor 0.05,
    // decay 0.25 per day: ours.
    dom: (d) => 0.05 + 0.55 * Math.exp(-0.25 * daysSincePayday(d)),
    // Success peaks near Friday. The shape is ours.
    dow: (w) => [0.27, 0.25, 0.24, 0.3, 0.4, 0.36, 0.3][w],
    // Evening hours (18-22 UTC) best: from the brief, NOT a published pattern (those only say
    // hour-of-day patterns exist). Daytime middle, night lowest.
    hod: (h) => (h >= 18 && h <= 22 ? 0.42 : h >= 9 && h <= 17 ? 0.3 : 0.18),
  },
  do_not_honor: {
    // A flat issuer chance on each try: no day-of-month effect.
    dom: () => 0.3,
    // Business days better than the weekend: from the brief.
    dow: (w) => (w <= 4 ? 0.32 : 0.2),
    // Avoid late-night UTC hours for this decline: 0-5 UTC low.
    // Business hours 9-17 UTC best: from the brief.
    hod: (h) => (h <= 5 ? 0.08 : h >= 9 && h <= 17 ? 0.38 : 0.25),
  },
  velocity_limit_exceeded: {
    // A daily spending limit: it resets at midnight, so any later day works as well as another,
    // with no day-of-month or weekday effect. The engine's window starts tomorrow and it acts on
    // the soonest day it draws, so with all days tied it retries the next day or soon after.
    // Base 0.45: ours.
    dom: () => 0.45,
    dow: () => 0.45,
    // Any hour of the next day works; the hours right after the reset (0-5 UTC) a little better,
    // before the new day's limit is spent: ours.
    hod: (h) => (h <= 5 ? 0.5 : 0.4),
  },
  downstream_technical_issue: {
    // A temporary processing error that a later retry usually clears.
    // High and flat everywhere: the bank uses it, but the cluster gets no document (SEEDED).
    dom: () => 0.85,
    dow: () => 0.85,
    hod: () => 0.85,
  },
};

// Clusters that get a stats document. Not the processing error: the engine only ranks days, so a
// flat document would spread its retries at random over the grace window. Without a document the
// engine uses its ladder, which retries soon, as a temporary error needs.
export const SEEDED = [
  "insufficient_funds",
  "do_not_honor",
  "velocity_limit_exceeded",
];

// Which reason (as the simulator names it) maps to which engine cluster (GSM standardised code)
export const REASON_CLUSTER = {
  insufficient_funds: "insufficient_funds",
  generic_decline: "do_not_honor",
  processing_error: "downstream_technical_issue",
  card_velocity_exceeded: "velocity_limit_exceeded",
};

export const clusterKey = (code) => `v1|${code}/UNK/UNK`;

const SIZES = { dow: 7, dom: 31, hod: 24 };

// Successes per slot for a scale: k = round(n × rate × scale), so equal rates keep equal counts
const successes = (n, rates, scale) =>
  rates.map((rate) => Math.round(n * rate * scale));

// Every success total a family reaches by scaling its rates, each with its counts. The total only
// steps up as the scale grows, so each total has one set of counts.
function reachable(n, rates) {
  const steps = rates.flatMap((rate) =>
    range(n).map((j) => (j + 0.5) / (n * rate) + 1e-9),
  );
  const totals = new Map();
  for (const scale of steps.sort((a, b) => a - b)) {
    const k = successes(n, rates, scale);
    if (k.every((count) => count <= n)) totals.set(sum(k), k);
  }
  return totals;
}

// Hour successes for a total: the nearest total the hour rates reach exactly, then the difference
// one count at a time on the lowest-rate hours, which the model almost never picks. A count more
// on a likely hour would shift its pick chance by about 2 points.
function hourSuccesses(n, rates, total) {
  const reach = reachable(n, rates);
  const [near] = [...reach.keys()].sort(
    (a, b) => Math.abs(a - total) - Math.abs(b - total),
  );
  const k = [...reach.get(near)];
  range(rates.length)
    .sort((a, b) => rates[a] - rates[b] || a - b)
    .slice(0, Math.abs(total - near))
    .forEach((hour) => (k[hour] += Math.sign(total - near)));
  return k;
}

// The three families are views of the same outcomes, so the engine rejects a document unless Σn
// and Σk are equal across them (validate_invariants). The day-of-month rates are the base rates
// (as in slotChance) and set the target successes; weekday and hour keep their shape (rate
// ratios) at that total.
//   - Days are ranked by order only (inclusion_probabilities), so one count more would make a day
//     win. Weekday and day of month scale their rates to the nearest total both reach exactly.
//   - The hour is drawn in proportion to exp(score) (pick_hour). The hour family takes the same
//     total, any odd counts on its least likely hours (hourSuccesses).
export function statsDocument(code) {
  const p = PATTERNS[code];
  const n = (name) => TOTAL_TRIES / SIZES[name];
  const rates = (name) => range(SIZES[name]).map(p[name]);
  const target = sum(rates("dom")) * n("dom");
  const [dow, dom] = ["dow", "dom"].map((name) =>
    reachable(n(name), rates(name)),
  );
  const [total] = [...dom.keys()]
    .filter((t) => dow.has(t))
    .sort((a, b) => Math.abs(a - target) - Math.abs(b - target));
  if (total === undefined)
    throw new Error(`no common success total for ${code}`);
  const slots = (name, k) => k.map((count) => ({ n: n(name), k: count }));
  return {
    dow: slots("dow", dow.get(total)),
    dom: slots("dom", dom.get(total)),
    hod: slots("hod", hourSuccesses(n("hod"), rates("hod"), total)),
  };
}

// The bank's chance that a retry at this real-life slot succeeds: the same published pattern,
// day of month as the base rate, weekday and hour as factors around their averages. Capped at 0.95.
// A retry succeeds when the invoice's fixed draw is below this.
export function slotChance(code, { dom, dow, hod }) {
  const p = PATTERNS[code];
  const mean = (f, size) => sum(range(size).map(f)) / size;
  const chance =
    p.dom(dom) * (p.dow(dow) / mean(p.dow, 7)) * (p.hod(hod) / mean(p.hod, 24));
  return Math.min(0.95, Math.max(0, chance));
}

const csvField = (text) => `"${text.replaceAll('"', '""')}"`;

export function statsCsv() {
  const rows = SEEDED.map(
    (code) =>
      `${clusterKey(code)},${csvField(JSON.stringify(statsDocument(code)))}`,
  );
  return ["cluster_key,stats", ...rows].join("\n") + "\n";
}

if (import.meta.url === `file://${process.argv[1]}`)
  process.stdout.write(statsCsv());
