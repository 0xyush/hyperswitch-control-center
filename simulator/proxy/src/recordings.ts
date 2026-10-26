// Replay mode (simulator/REPLAY.md): recorded stories that a presenter can walk step by step,
// even when the sandbox is stalled. Marking a finished story freezes its whole story view
// (sandbox parts included) in data/recordings.json. A replay slices that snapshot to its first
// n timeline rows; it makes no sandbox call.
import fs from "node:fs";
import path from "node:path";
import { config } from "./config.ts";
import { HttpError, stageInfo, storyView } from "./story.ts";

type Row = {
  stepId: string;
  at: string;
  from: string;
  to: string;
  label: string;
  status: string;
  [k: string]: unknown;
};

type Recording = {
  id: string; // the story id
  title: string;
  preset: number | null;
  recordedAt: string; // when the story ran
  markedAt: string;
  outcome: string;
  steps: number;
  view: any; // the full story view at marking time
};

const STORE_FILE = path.join(config.dataDir, "recordings.json");
const recordings = new Map<string, Recording>();
try {
  for (const r of JSON.parse(
    fs.readFileSync(STORE_FILE, "utf8"),
  ) as Recording[])
    recordings.set(r.id, r);
} catch {
  // No recordings yet.
}

function save() {
  fs.mkdirSync(config.dataDir, { recursive: true });
  fs.writeFileSync(
    `${STORE_FILE}.tmp`,
    JSON.stringify([...recordings.values()], null, 2),
  );
  fs.renameSync(`${STORE_FILE}.tmp`, STORE_FILE);
}

// Rows the presenter steps through: the story's own steps, not the live "pending" row.
const rowsOf = (view: any): Row[] =>
  (view.timeline as Row[]).filter((r) => r.status !== "pending");

export function listRecordings() {
  return [...recordings.values()]
    .sort((a, b) => a.recordedAt.localeCompare(b.recordedAt))
    .map(({ id, title, preset, recordedAt, outcome, steps }) => ({
      id,
      title,
      preset,
      recordedAt,
      outcome,
      steps,
    }));
}

// Marks a finished story as a recording. Its view is read once, live, and kept as it is.
export async function markRecording(storyId: string, title: string) {
  if (!title || title.length > 120)
    throw new HttpError(400, "send a title of 1 to 120 characters");
  const view: any = await storyView(storyId);
  if (!view.done)
    throw new HttpError(
      409,
      `story ${storyId} has not finished (status ${view.status}); only a finished story can be a recording`,
    );
  const end = replaySlice(view, rowsOf(view).length);
  const rec: Recording = {
    id: storyId,
    title,
    preset: view.preset ?? null,
    recordedAt: view.startedAt,
    markedAt: new Date().toISOString(),
    outcome: end.recoveredBy
      ? `${end.status} (by ${end.recoveredBy === "revrec" ? "Rev Rec" : "the customer, outside Rev Rec"})`
      : end.status,
    steps: rowsOf(view).length,
    view,
  };
  recordings.set(storyId, rec);
  save();
  return listRecordings().find((r) => r.id === storyId)!;
}

// Explain lines that do not depend on the moment (settings, cards, rules). The others describe
// the final state, so they show only at the last step.
const TIMELESS = new Set([
  "recorded-reason",
  "reason",
  "cards",
  "start-rule",
  "retry-mode",
  "max-retries",
  "grace-period",
]);

// The story view as it looked after the first n rows.
function replaySlice(view: any, n: number) {
  const rows = rowsOf(view);
  const total = rows.length;
  const upTo = Math.max(0, Math.min(total, n));
  const shown = rows.slice(0, upTo);
  const cut = upTo
    ? Date.parse(shown[upTo - 1].at)
    : Date.parse(view.startedAt);
  const seen = (iso: string | null | undefined) =>
    Boolean(iso) && Date.parse(iso!) <= cut;
  const last = upTo === total;
  // The snapshot's final state can be later than the story's last step (st_179854639f59 was
  // cancelled outside the story), so the final explain and tracker apply only when they match.
  const atFinal = (stage: string) => last && stage === view.stage;

  const stageHistory = (view.stageHistory as any[]).filter((h) =>
    seen(h.firstSeenAt),
  );
  // The stage at this step: the latest of the first-seen stage times and the stage a row implies.
  // Stage history keeps only the first time of each stage, so a second booking (Scheduled again)
  // or a payment report comes from the rows.
  const implied = (r: Row): string | null =>
    r.label.startsWith("pick retry time")
      ? "Scheduled"
      : r.from === "revrec" && r.to === "processor"
        ? r.status === "ok"
          ? "Processing"
          : "Queued"
        : r.from === "revrec" && r.to === "billing"
          ? view.stage
          : r.label.startsWith("report paid outside") && r.status === "ok"
            ? "Recovered"
            : r.label.startsWith("cancel invoice") && r.status === "ok"
              ? "Cancelled"
              : null;
  const marks = [
    ...stageHistory.map((h, i) => ({
      t: Date.parse(h.firstSeenAt),
      rank: 0,
      i,
      stage: h.stage as string,
    })),
    ...shown.map((r, i) => ({
      t: Date.parse(r.at),
      rank: 1,
      i,
      stage: implied(r),
    })),
  ].filter((m): m is { t: number; rank: number; i: number; stage: string } =>
    Boolean(m.stage),
  );
  marks.sort((x, y) => x.t - y.t || x.rank - y.rank || x.i - y.i);
  const stage: string = marks.at(-1)?.stage ?? "Starting";
  const recoveredBy = stage === "Recovered" ? view.recoveredBy : null;
  const { status, caption } = stageInfo(stage, recoveredBy);

  // A booked retry that has not run yet at this step: the pending row and its time, as live.
  const booking = [...shown]
    .reverse()
    .find((r) => r.label.startsWith("pick retry time"));
  const ranAfter =
    booking &&
    shown.some(
      (r) => r.from === "revrec" && r.to === "processor" && r.at > booking.at,
    );
  const bookingRead = booking
    ? view.requests.find((q: any) => q.stepId === booking.stepId)
    : null;
  const processTracker = bookingRead?.response?.body ?? null;
  const nextRetryAt: string | null =
    booking &&
    !ranAfter &&
    !["Recovered", "Terminated", "Cancelled"].includes(stage)
      ? (processTracker?.schedule_time_for_payment ?? null)
      : null;
  const pending = nextRetryAt
    ? [
        {
          ...booking,
          at: nextRetryAt,
          status: "pending",
          label: `charge saved card at ${nextRetryAt.slice(11, 19)}`,
          attemptId: null,
        },
      ]
    : [];

  const stepIds = new Set(shown.map((r) => r.stepId));
  const invoice = view.invoice
    ? {
        ...view.invoice,
        // The invoice page shows paid only from the step where it was paid.
        ...(stage === "Recovered"
          ? {}
          : {
              status: "failed",
              amount_details: {
                ...view.invoice.amount_details,
                amount_captured: 0,
              },
            }),
      }
    : null;

  return {
    ...view,
    status,
    sandboxStatus: status,
    stage,
    stageCaption: caption,
    stageHistory,
    recoveredBy,
    done: last,
    nextRetryAt,
    invoice,
    attempts: (view.attempts as any[]).filter((a) => seen(a.created_at)),
    attemptSummary: (view.attemptSummary as any[]).filter((a) => seen(a.at)),
    processTracker: atFinal(stage) ? view.processTracker : processTracker,
    timeline: [...shown, ...pending],
    requests: (view.requests as any[]).filter((q) => stepIds.has(q.stepId)),
    explain: atFinal(stage)
      ? view.explain
      : [
          {
            id: "status",
            source: "sandbox",
            text: `Rev Rec status at this step (recorded): ${status} (${caption}).`,
          },
          ...(view.explain as any[]).filter((e) => TIMELESS.has(e.id)),
        ],
    lastReads: [],
    warnings: [],
    waiting: null,
    actions: {
      paidInApp: false,
      reportAgain: false,
      cancel: false,
      reportAgainMode: view.actions?.reportAgainMode ?? null,
    },
  };
}

export function replayView(storyId: string, upTo?: number) {
  const rec = recordings.get(storyId);
  if (!rec) throw new HttpError(404, `no recording for story ${storyId}`);
  const total = rec.steps;
  const n = upTo === undefined || Number.isNaN(upTo) ? total : upTo;
  return {
    ...replaySlice(rec.view, n),
    replay: {
      total,
      upTo: Math.max(0, Math.min(total, n)),
      recordedAt: rec.recordedAt,
      markedAt: rec.markedAt,
      title: rec.title,
    },
  };
}
