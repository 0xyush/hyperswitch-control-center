// The simulated calendar (MODEL.md, "Limits on our engine"): where each of Rev Rec's retries falls
// in real life, and when it runs in the demo. Pure functions; sim.mjs reads the engine's tables.
//   - A retry the model planned: decision 1 is exactly the engine's pick. The engine always plans
//     from the real today, so a later pick is re-computed with the engine's formulas from the day
//     of the last try, inside the remaining grace window (model.mjs pickDay), at the engine's hour.
//     plannedSlot (keep the model's day offset) is the fallback when the counts are missing.
//   - Any other retry (the ladder): Hyperswitch's default static ladder, by retry number.
// Demo time: from the failure on, the demo runs secondsPerDay seconds for each real day.

export const DAY_MS = 86_400_000;

// Hyperswitch's default static ladder (config/superposition_seed.toml, process_tracker.
// pt_mapping_pcr_retries, tag 2026.10.26.0): retry 1 after 60 s, then [gap in s, retries].
// The same timetable as REAL_LADDER in simulator/proxy/src/reallife.ts.
export const REAL_LADDER = {
  startAfterSec: 60,
  frequencies: [
    [10800, 2],
    [21600, 3],
    [32400, 3],
    [43200, 3],
    [64800, 3],
  ],
};

// Seconds after the failure of each ladder retry (15 retries, the last at 507,660 s)
export function ladderOffsets() {
  const out = [REAL_LADDER.startAfterSec];
  for (const [gap, count] of REAL_LADDER.frequencies)
    for (let i = 0; i < count; i++) out.push(out.at(-1) + gap);
  return out;
}

// The demo runs the ladder's 507,660 s in about 80 s (the proxy's realLife): 13.6 s per real day
export const DEFAULT_SECONDS_PER_DAY = (80 / ladderOffsets().at(-1)) * 86_400;

const dayStart = (ms) => Math.floor(ms / DAY_MS) * DAY_MS;

// The slot the engine files an outcome under, in UTC: Monday = 0, the 1st = 0, hour 0..23
// (EventSlots::from_utc; workflows/revenue_recovery.rs:1611)
export function slotOf(ms) {
  const d = new Date(ms);
  return {
    dow: (d.getUTCDay() + 6) % 7,
    dom: d.getUTCDate() - 1,
    hod: d.getUTCHours(),
  };
}

// Where a model-planned retry falls in real life. lastSlotMs is the real-life slot of the
// previous retry, or null for the invoice's first retry.
export function plannedSlot({ enginePickMs, decidedAtMs, lastSlotMs }) {
  if (lastSlotMs === null) return enginePickMs;
  const dayOffset = Math.round(
    (dayStart(enginePickMs) - dayStart(decidedAtMs)) / DAY_MS,
  );
  const timeOfDay = enginePickMs - dayStart(enginePickMs);
  return dayStart(lastSlotMs) + dayOffset * DAY_MS + timeOfDay;
}

// Where ladder retry number `retry` (1-based) falls in real life
export function ladderSlot(failureMs, retry) {
  const offsets = ladderOffsets();
  return failureMs + offsets[Math.min(retry, offsets.length) - 1] * 1000;
}

// Where ladder retry number `retry` falls when it follows earlier retries: the model's picks can
// be days later than the ladder's own slots, so it is never before the previous retry plus the
// ladder's gap for this step (prevSlotMs null: the ladder's own slot)
export function ladderSlotAfter(failureMs, retry, prevSlotMs) {
  const own = ladderSlot(failureMs, retry);
  if (prevSlotMs === null || prevSlotMs === undefined || retry < 2) return own;
  return Math.max(own, prevSlotMs + (own - ladderSlot(failureMs, retry - 1)));
}

// When a real-life slot runs in the demo
export const demoTime = (failureMs, slotMs, secondsPerDay) =>
  failureMs + ((slotMs - failureMs) / DAY_MS) * secondsPerDay * 1000;
