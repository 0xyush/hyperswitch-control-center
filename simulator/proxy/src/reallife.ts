// The real Rev Rec timetable next to the demo's seconds (story view: realLife, smartNote and each
// declined row's meaning). Our engine runs a fast test ladder; Hyperswitch's default static
// ladder spreads the same retries over about 6 days.
import { config } from "./config.ts";
import type { SimCalendar } from "./simcal.ts";

export const REAL_LADDER = {
  source:
    "Hyperswitch default static timetable (config/superposition_seed.toml, process_tracker.pt_mapping_pcr_retries, tag 2026.10.26.0)",
  startAfterSec: 60,
  // [gap in seconds, how many retries]: 3 h x2, 6 h x3, 9 h x3, 12 h x3, 18 h x3.
  frequencies: [
    [10800, 2],
    [21600, 3],
    [32400, 3],
    [43200, 3],
    [64800, 3],
  ] as [number, number][],
};

// Seconds after the failure of each retry: retry 1 at start_after, then each gap added once per
// retry it covers. The default ladder gives 15 retries; `max` cuts it shorter.
export function ladderOffsets(
  startAfterSec: number,
  frequencies: [number, number][],
  max = Infinity,
): number[] {
  const out = [startAfterSec];
  for (const [gap, count] of frequencies)
    for (let k = 0; k < count; k++) out.push(out[out.length - 1] + gap);
  return out.slice(0, Math.max(0, max));
}

// "1 min", "6 h", "5 days 21 h" after the failure.
export function afterText(sec: number): string {
  if (sec < 3600) return `${Math.max(1, Math.round(sec / 60))} min`;
  const h = Math.floor(sec / 3600);
  if (sec < 2 * 86400) return `${h} h`;
  const d = Math.floor(h / 24);
  return h % 24 ? `${d} days ${h % 24} h` : `${d} days`;
}

export const dayText = (sec: number) =>
  `day ${Math.floor(sec / 86400) + 1}, ${afterText(sec)} after the failure`;

// "Tue 3:01 PM", in UTC (the proxy does not know the viewer's time zone; `at` is there to format).
const LABEL = new Intl.DateTimeFormat("en-US", {
  weekday: "short",
  hour: "numeric",
  minute: "2-digit",
  timeZone: "UTC",
});
export const slotLabel = (iso: string) => LABEL.format(new Date(iso));

export function spanText(sec: number): string {
  return sec < 2 * 86400
    ? `about ${Math.round(sec / 3600)} h`
    : `about ${Math.round(sec / 86400)} days`;
}

export type Slot = {
  retry: number;
  offsetSec: number;
  at: string;
  label: string;
  dayText: string;
  // Smart stories: where the time comes from ("calendar" = the model's pick, "ladder" = the fixed
  // timetable when the model gave no time) and whether the retry is still to come
  source?: "calendar" | "ladder";
  planned?: boolean;
};

// The real-life timetable for a story whose first failure was at failureAt.
export function realLife(failureAt: string, maxRetries: number | null) {
  const offsets = ladderOffsets(
    REAL_LADDER.startAfterSec,
    REAL_LADDER.frequencies,
    maxRetries ?? Infinity,
  );
  const t0 = Date.parse(failureAt);
  const slots: Slot[] = offsets.map((offsetSec, i) => {
    const at = new Date(t0 + offsetSec * 1000).toISOString();
    return {
      retry: i + 1,
      offsetSec,
      at,
      label: slotLabel(at),
      dayText: dayText(offsetSec),
    };
  });
  return {
    mode: "static" as "static" | "smart",
    source: REAL_LADDER.source,
    startAfterSec: REAL_LADDER.startAfterSec,
    frequencies: REAL_LADDER.frequencies,
    maxRetries: slots.length,
    spanText: spanText(offsets.at(-1) ?? 0),
    failureAt,
    timeZone: "UTC",
    slots,
    demoText:
      config.engine === "sandbox"
        ? "The sandbox: a few minutes apart"
        : config.fastEngine
          ? "Here: about 80 seconds"
          : "Here: a test timetable",
  };
}

// Smart mode: the real-life times come from the sim calendar (the model's picks), not the fixed
// timetable. One slot per retry Rev Rec made, then the next one once the model has picked it. The
// later retries are not decided yet, so they have no slot.
export function realLifeFromCalendar(
  cal: SimCalendar,
  ladder: ReturnType<typeof realLife>,
): ReturnType<typeof realLife> {
  const t0 = Date.parse(cal.realLifeFailureAt);
  const slot = (
    n: number,
    at: string,
    source: "calendar" | "ladder",
    planned: boolean,
  ): Slot => {
    const offsetSec = Math.max(0, Math.round((Date.parse(at) - t0) / 1000));
    return {
      retry: n,
      offsetSec,
      at,
      label: slotLabel(at),
      dayText: dayText(offsetSec),
      source,
      planned,
    };
  };
  const done = [...cal.retries]
    .sort((a, b) => a.n - b.n)
    .map((r) => slot(r.n, r.realLife, r.source, false));
  const next = cal.plans.find((p) => p.n === done.length + 1 && !p.stopped);
  const slots = next
    ? [...done, slot(next.n, next.slot, "calendar", true)]
    : done;
  return {
    ...ladder,
    mode: "smart",
    source: "Rev Rec's model on the simulated calendar (sim service)",
    startAfterSec: slots[0]?.offsetSec ?? 0,
    frequencies: [],
    spanText: spanText(Math.max(0, ...slots.map((x) => x.offsetSec))),
    failureAt: cal.realLifeFailureAt,
    slots,
  };
}

// A row's real-life time: the slot of the n-th Rev Rec retry, without the offset.
export const rowRealLife = (slots: Slot[], retry: number) => {
  const s = slots.find((x) => x.retry === retry);
  return s
    ? { retry: s.retry, at: s.at, label: s.label, dayText: s.dayText }
    : null;
};

// What a decline means, in at most two short sentences.
const MEANING: Record<string, string> = {
  generic_decline:
    "The bank gave no reason. Rev Rec treats it as temporary and tries again later.",
  card_declined:
    "The bank gave no reason. Rev Rec treats it as temporary and tries again later.",
  insufficient_funds:
    "No money on the card right now. It often works again after payday.",
  processing_error:
    "A short problem at the bank or network. A retry soon usually works.",
  card_velocity_exceeded:
    "The card hit its spending limit. It resets later, often the next day.",
  try_again_later:
    "The bank asks to try again later. A retry soon usually works.",
  stolen_card: "This card can never work again. Rev Rec stops.",
  lost_card: "This card can never work again. Rev Rec stops.",
  expired_card: "This card can never work again. Rev Rec stops.",
};
export function declineMeaning(code: string | null | undefined) {
  return {
    text:
      (code && MEANING[code]) ??
      "The bank declined the charge. Rev Rec uses the decline code to decide whether to try again.",
    source: "rule" as const,
  };
}

export const SMART_NOTE = {
  text: "Smart retries pick the hour most likely to work. For no money on the card, that is often near payday.",
  source: "rule" as const,
};
