// Rev Rec's smart-retry model, re-computed for display (MODEL.md, "What runs"). A port of the
// engine's formulas in crates/router/src/workflows/revenue_recovery.rs (tag 2026.10.26.0); the
// engine itself makes every decision. This file only explains one in plain numbers.

import { DAY_MS, slotOf } from "./calendar.mjs";

const CLIP = 1e-4; // CLIP, :1620
export const EXPLORATION_FLOOR = 0.1; // revenue_recovery.exploration_floor
const TIE_TOLERANCE = 1e-4; // revenue_recovery.tie_tolerance
const MAX_GRACE_DAYS = 31;

// p̂ = (k+1)/(n+2) and SE = √(p̂(1−p̂)/(n+3)) (:1636-1646)
export const pHat = (c) => (c.k + 1) / (c.n + 2);
export const se = (c) => Math.sqrt((pHat(c) * (1 - pHat(c))) / (c.n + 3));

// erf by Abramowitz and Stegun 7.1.26 (error below 1.5e-7): enough to show a score
function erf(x) {
  const t = 1 / (1 + 0.3275911 * Math.abs(x));
  const y =
    1 -
    ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) *
      t +
      0.254829592) *
      t *
      Math.exp(-x * x);
  return x >= 0 ? y : -y;
}
export const normalCdf = (x) => 0.5 * (1 + erf(x / Math.SQRT2));
const logit = (c) => {
  const p = Math.min(1 - CLIP, Math.max(CLIP, c));
  return Math.log(p / (1 - p));
};

// slot index -> score: the average over the other scored slots of logit(Φ(gap / combined SE)).
// Slots with n = 0 (no data) or k > n are not scored (slot_scores, :1679).
export function slotScores(slots) {
  const scored = slots
    .map((c, i) => ({ i, p: pHat(c), s: se(c), ok: c.n > 0 && c.k <= c.n }))
    .filter((x) => x.ok);
  const out = new Map();
  for (const a of scored) {
    const others = scored.filter((b) => b.i !== a.i);
    const sum = others.reduce(
      (s, b) =>
        s + logit(normalCdf((a.p - b.p) / Math.sqrt(a.s ** 2 + b.s ** 2))),
      0,
    );
    out.set(a.i, others.length ? sum / others.length : 0);
  }
  return out;
}

export function softmax(xs) {
  const m = Math.max(...xs);
  const e = xs.map((x) => Math.exp(x - m));
  const z = e.reduce((a, b) => a + b, 0);
  return e.map((x) => x / z);
}

// Each day's chance to be in the k-day schedule: floor every day at ε (at most k/n), raise the best
// days to 1 in value order until k is spent, then split each tied group's share equally
// (inclusion_probabilities, :2058)
export function inclusionProbabilities(values, budget, epsilon, tieTolerance) {
  const n = values.length;
  if (!n) return [];
  const k = Math.min(budget, n);
  const eps = Math.min(Math.max(epsilon, 0), k / n);
  const pi = Array(n).fill(eps);
  let remaining = k - eps * n;
  const ranked = values.map((v, i) => [i, v]).sort((a, b) => b[1] - a[1]);
  for (const [day] of ranked) {
    if (remaining <= 1e-12) break;
    const take = Math.min(1 - eps, remaining);
    pi[day] += take;
    remaining -= take;
  }
  for (let start = 0; start < ranked.length; ) {
    let end = start + 1;
    while (
      end < ranked.length &&
      Math.abs(ranked[end][1] - ranked[end - 1][1]) <= tieTolerance
    )
      end += 1;
    if (end - start > 1) {
      const group = ranked.slice(start, end);
      const share = group.reduce((s, [day]) => s + pi[day], 0) / group.length;
      for (const [day] of group) pi[day] = share;
    }
    start = end;
  }
  return pi;
}

const DAY_LABEL = new Intl.DateTimeFormat("en-US", {
  weekday: "short",
  day: "numeric",
  month: "short",
  timeZone: "UTC",
});
const hourLabel = (h) => `${h % 12 || 12} ${h < 12 ? "AM" : "PM"}`;

// The engine's candidate days for a decision made at decidedAtMs: tomorrow up to the grace end,
// at most 31 days (:2269-2311), each valued by the larger of its weekday and day-of-month scores
// (MaxAtScore, combine_day_weight :1991). Every day starts before the grace end.
function candidateDays(doc, decidedAtMs, graceEndMs) {
  const today = Math.floor(decidedAtMs / DAY_MS) * DAY_MS;
  const graceDays = Math.max(
    0,
    Math.floor((graceEndMs - decidedAtMs) / DAY_MS),
  );
  const windowLen = Math.min(Math.max(graceDays - 1, 0), MAX_GRACE_DAYS);
  const dowScores = slotScores(doc.dow);
  const domScores = slotScores(doc.dom);
  const days = Array.from({ length: windowLen }, (_, d) => {
    const ms = today + (d + 1) * DAY_MS;
    const { dow, dom } = slotOf(ms);
    const byWeekday = dowScores.get(dow) ?? 0;
    const byMonthDay = domScores.get(dom) ?? 0;
    // MaxAtScore: the larger raw score is the day's value (combine_day_weight, :1991)
    const driver = byMonthDay > byWeekday ? "dom" : "dow";
    const c = driver === "dom" ? doc.dom[dom] : doc.dow[dow];
    return {
      ms,
      driver,
      value: Math.max(byWeekday, byMonthDay),
      n: c.n,
      k: c.k,
    };
  });
  return { days, windowLen };
}

// The engine's draw (systematic_sample, :2147): the days' chances laid end to end in a random
// order, probes at u, u+1, ... u+k-1; the days hit, in calendar order
export function systematicSample(pi, u, order, probeCount) {
  let acc = 0;
  const edges = order.map((i) => (acc += pi[i] ?? 0));
  if (!edges.length) return [];
  const hit = new Set();
  for (let step = 0; step < probeCount; step++) {
    const at = edges.findIndex((edge) => edge > u + step);
    hit.add(order[at < 0 ? edges.length - 1 : at]);
  }
  return [...hit].sort((a, b) => a - b);
}

// A later pick on the simulated calendar, re-computed the way the engine would make it on that
// day (orchestrator's decision, 27 Oct): today = the day of the last try, window = tomorrow to the
// grace end, k = retries left, the same counts, the soonest day of a systematic-k draw
// (select_systematic_k_day :2202). null = no future day inside grace: the engine declines.
export function pickDay(
  doc,
  { todayMs, graceEndMs, budget, random = Math.random },
) {
  const { days } = candidateDays(doc, todayMs, graceEndMs);
  if (!days.length || budget < 1) return null;
  const pi = inclusionProbabilities(
    softmax(days.map((d) => d.value)),
    budget,
    EXPLORATION_FLOOR,
    TIE_TOLERANCE,
  );
  // A fresh random order per decision, as generate_random_permutation
  const order = days.map((_, i) => i);
  for (let i = order.length - 1; i > 0; i--) {
    const j = Math.floor(random() * (i + 1));
    [order[i], order[j]] = [order[j], order[i]];
  }
  const [chosen] = systematicSample(
    pi,
    random(),
    order,
    Math.min(budget, days.length),
  );
  return chosen === undefined
    ? null
    : { dayMs: days[chosen].ms, inclusion: pi[chosen] };
}

// One decision in plain numbers. decidedAtMs: when the engine planned it (or "today" on the
// simulated calendar); graceEndMs: the end of the grace window; budget: retries left; pick: the
// chosen moment.
export function explainDecision(
  doc,
  { decidedAtMs, graceEndMs, budget, pickMs },
) {
  const { days, windowLen } = candidateDays(doc, decidedAtMs, graceEndMs);
  const weights = softmax(days.map((d) => d.value));
  const pi = inclusionProbabilities(
    weights,
    budget,
    EXPLORATION_FLOOR,
    TIE_TOLERANCE,
  );
  const pickedDayMs = Math.floor(pickMs / DAY_MS) * DAY_MS;
  const dayRows = days
    .map((d, i) => ({
      date: new Date(d.ms).toISOString().slice(0, 10),
      label: DAY_LABEL.format(d.ms),
      by: d.driver === "dom" ? "day of month" : "weekday",
      worked: d.k,
      of: d.n,
      chance: pi[i],
      chosen: d.ms === pickedDayMs,
      score: d.value,
    }))
    // Best value first (the order the engine ranks days by), then the calendar
    .sort((a, b) => b.score - a.score || a.date.localeCompare(b.date));

  const hodScores = slotScores(doc.hod);
  const hourWeights = doc.hod.map((_, h) => Math.exp(hodScores.get(h) ?? 0));
  const z = hourWeights.reduce((a, b) => a + b, 0);
  const pickHour = slotOf(pickMs).hod;
  const hourRows = doc.hod
    .map((c, h) => ({
      hour: h,
      label: hourLabel(h),
      worked: c.k,
      of: c.n,
      noData: c.n === 0,
      chance: hourWeights[h] / z,
      chosen: h === pickHour,
      score: hodScores.get(h) ?? 0,
    }))
    .sort((a, b) => b.chance - a.chance || a.hour - b.hour);

  // The top 3, plus the chosen one when it is not among them
  const top = (rows) => [
    ...rows.slice(0, 3),
    ...rows.slice(3).filter((r) => r.chosen),
  ];
  return {
    source: "re-computed",
    windowDays: windowLen,
    budget,
    explorationFloor: EXPLORATION_FLOOR,
    days: top(dayRows),
    hours: top(hourRows),
  };
}
