// The sim service on the VM (simulator/selfhost/sim/sim.mjs): one invoice's simulated calendar,
// the bank's answers and the model's decisions in plain numbers. Read only.
import { config } from "./config.ts";

// One of the model's decisions, re-computed for display (sim/model.mjs explainDecision)
export type ModelDay = {
  date: string;
  label: string;
  by: "weekday" | "day of month";
  worked: number;
  of: number;
  chance: number;
  chosen: boolean;
  score: number;
};
export type ModelHour = {
  hour: number;
  label: string;
  worked: number;
  of: number;
  noData: boolean;
  chance: number;
  chosen: boolean;
  score: number;
};
export type ModelExplained = {
  source: "re-computed";
  windowDays: number;
  budget: number;
  explorationFloor: number;
  days: ModelDay[];
  hours: ModelHour[];
};

// A retry the model planned: the engine's pick, its real-life slot and its demo time
export type CalendarPlan = {
  n: number;
  // "engine": the engine's own pick (decision 1); "re-computed": re-made on the simulated calendar
  source?: "engine" | "re-computed";
  cluster: string;
  enginePick: string;
  decidedAt: string;
  slot: string;
  demoAt: string | null;
  stopped: "grace" | null;
  model: ModelExplained | null;
};

export type CalendarRetry = {
  n: number;
  attemptId: string;
  status: string;
  demoAt: string;
  cluster: string;
  realLife: string;
  source: "calendar" | "ladder";
};

export type SimCalendar = {
  paymentId: string;
  failureAt: string;
  realLifeFailureAt: string;
  secondsPerDay: number;
  plans: CalendarPlan[];
  retries: CalendarRetry[];
  bank: {
    reason: string;
    worksFrom: object | null;
    draw: number | null;
    answers: {
      n: number;
      slot: string;
      works: boolean;
      decline: string | null;
    }[];
  } | null;
};

export const simOn = () => Boolean(config.simUrl && config.simToken);

// The model's counts for one decline cluster (the sim's GET /stats, the documents the engine reads
// now: the seeded counts plus the demo's own outcomes since the reset). Each slot: worked k of n.
// dow: Monday = 0; dom: day of month - 1; hod: the UTC hour.
export type SlotCount = { k: number; n: number };
export type ClusterStats = {
  dow: SlotCount[];
  dom: SlotCount[];
  hod: SlotCount[];
};
let statsCache: { at: number; docs: Map<string, ClusterStats> } | null = null;
export async function readStats(): Promise<Map<string, ClusterStats> | null> {
  if (!simOn()) return null;
  if (statsCache && Date.now() - statsCache.at < 30_000) return statsCache.docs;
  try {
    const r = await fetch(`${config.simUrl}/stats`, {
      headers: { authorization: `Bearer ${config.simToken}` },
      signal: AbortSignal.timeout(5000),
    });
    if (!r.ok) return null;
    const j = (await r.json()) as {
      current?: { cluster_key: string; stats: ClusterStats }[];
    };
    const docs = new Map(
      (j.current ?? []).map((d) => [d.cluster_key, d.stats]),
    );
    statsCache = { at: Date.now(), docs };
    return docs;
  } catch {
    return null;
  }
}

// One invoice's calendar. null = no sim service, the invoice is unknown, or it did not answer.
export async function readCalendar(
  paymentId: string,
): Promise<SimCalendar | null> {
  if (!simOn()) return null;
  try {
    const r = await fetch(
      `${config.simUrl}/calendar?payment_id=${encodeURIComponent(paymentId)}`,
      {
        headers: { authorization: `Bearer ${config.simToken}` },
        signal: AbortSignal.timeout(3000),
      },
    );
    if (!r.ok) return null;
    return (await r.json()) as SimCalendar;
  } catch {
    return null;
  }
}

// The real-life moment "now" on an invoice's simulated calendar: its latest retry's slot, or the
// failure when Rev Rec has not tried yet. For the story's "money is back" and other events.
export const realLifeNow = (cal: SimCalendar) =>
  cal.retries.at(-1)?.realLife ?? cal.realLifeFailureAt;

// Real-life days from the failure to the retry that recovered, or null
export function realDaysToRecover(cal: SimCalendar): number | null {
  const won = cal.retries.find((r) => r.status === "charged");
  if (!won) return null;
  return (
    (Date.parse(won.realLife) - Date.parse(cal.realLifeFailureAt)) / 86_400_000
  );
}

// Pause for one invoice (selfhost/sim/pause.mjs): the sim holds Rev Rec's next retry until resume.
export type SimPause = {
  paymentId: string;
  paused: boolean;
  at: string | null;
  autoResumeAt: string | null;
  // Time left to Rev Rec's next retry when it was held (null: none booked yet)
  remainingMs: number | null;
  held: { name: string; remainingMs: number }[];
  pausedMs: number;
  resumedAfterMs?: number;
};

// POST /pause or /resume {paymentId}; null = no sim service or it did not answer
export async function simPause(
  paymentId: string,
  action: "pause" | "resume",
): Promise<SimPause | null> {
  if (!simOn()) return null;
  try {
    const r = await fetch(`${config.simUrl}/${action}`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${config.simToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ paymentId }),
      signal: AbortSignal.timeout(8000),
    });
    return r.ok ? ((await r.json()) as SimPause) : null;
  } catch {
    return null;
  }
}

export async function readPause(paymentId: string): Promise<SimPause | null> {
  if (!simOn()) return null;
  try {
    const r = await fetch(
      `${config.simUrl}/pause?payment_id=${encodeURIComponent(paymentId)}`,
      {
        headers: { authorization: `Bearer ${config.simToken}` },
        signal: AbortSignal.timeout(3000),
      },
    );
    return r.ok ? ((await r.json()) as SimPause) : null;
  } catch {
    return null;
  }
}
