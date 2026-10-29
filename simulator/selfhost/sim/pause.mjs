// Pause for one invoice (A, 28 Oct): while paused, Rev Rec's next retry waits; resume continues where
// it stopped.
// - Hold: the invoice's waiting retry tasks (EXECUTE_WORKFLOW, and CALCULATE_WORKFLOW that books the next
//   one) keep their status but move about 10 years ahead. The engine's producer runs only tasks that are
//   due (a smart pick days ahead is normal for it). The database's task status has no 'review' value, so a
//   status change is not an option. The calendar tick does not move a paused invoice's planned retry (sim.mjs). The time left to
//   each task is kept; a task the engine adds while paused is held the same way (the loop runs every second).
// - Resume: each held task gets schedule_time = now + the time it had left.
//   With the static ladder the next retries follow from that one, so the whole timeline shifts.
// - The demo clock: the smart calendar's demo times move by the paused time (state.pausedMs, read by the
//   calendar tick), so the real-life days stay right. The bank decides by a retry's real-life slot
//   (by its number), so its timers ('money back from Sun 1:00 AM') stay right without a change.
// - Safety: a pause ends by itself after 15 minutes, and the sim's reset resumes every pause first.
const AUTO_RESUME_MS = 15 * 60_000;
const HOLD = ["EXECUTE_WORKFLOW", "CALCULATE_WORKFLOW"];
// Where a held task waits, and the line that tells a held task from a booked one
const PARKED = "interval '3650 days'";
const PARKED_FROM = "interval '3000 days'";
// Only a retry due within the hour is held: a smart pick days ahead is the engine's raw pick, which the
// calendar first moves to its demo time (it keeps planning while paused); the next second holds it.
const DUE_SOON = "interval '1 hour'";

export function createPause({ db, state, save }) {
  // paymentId -> { at, autoResumeAt, held: { [taskId]: { name, remainingMs } } }
  state.pauses ??= {};
  // paymentId -> total paused ms, for the calendar tick's demo times
  state.pausedMs ??= {};

  // Holds the invoice's waiting tasks that are not held yet; keeps each one's status and time left
  async function hold(paymentId) {
    const p = state.pauses[paymentId];
    if (!p) return;
    const { rows } = await db.query(
      `with waiting as (
         select id, schedule_time from process_tracker
         where tracking_data->>'global_payment_id' = $1 and name = any($2::text[])
           and status in ('new', 'pending')
           and schedule_time < (now() at time zone 'utc') + ${DUE_SOON}
         for update)
       update process_tracker pt set schedule_time = (now() at time zone 'utc') + ${PARKED}
       from waiting w where pt.id = w.id
       returning pt.id, pt.name,
         greatest(0, extract(epoch from (w.schedule_time - (now() at time zone 'utc'))) * 1000)::bigint as remaining_ms`,
      [paymentId, HOLD],
    );
    for (const r of rows)
      p.held[r.id] = { name: r.name, remainingMs: Number(r.remaining_ms) };
    if (rows.length) save();
  }

  // The calendar planned a paused invoice's retry (sim.mjs calendarTick): hold it there instead of
  // booking it; its time left counts from the pause, since the demo clock stopped then
  async function holdPlanned(paymentId, taskId, scheduleText, demoAtMs) {
    const p = state.pauses[paymentId];
    if (!p) return false;
    const { rowCount } = await db.query(
      `update process_tracker set schedule_time = (now() at time zone 'utc') + ${PARKED}
       where id = $1 and schedule_time = $2::timestamp and status in ('new', 'pending')`,
      [taskId, scheduleText],
    );
    if (rowCount) {
      p.held[taskId] = {
        name: "EXECUTE_WORKFLOW",
        remainingMs: Math.max(0, Math.round(demoAtMs - p.at)),
      };
      save();
    }
    return rowCount > 0;
  }

  async function pause(paymentId) {
    if (!paymentId) throw new Error("paymentId is required");
    if (!state.pauses[paymentId]) {
      const at = Date.now();
      state.pauses[paymentId] = {
        at,
        autoResumeAt: at + AUTO_RESUME_MS,
        held: {},
      };
      save();
    }
    await hold(paymentId);
    return view(paymentId);
  }

  async function resume(paymentId) {
    const p = state.pauses[paymentId];
    if (!p) return view(paymentId);
    for (const [id, t] of Object.entries(p.held))
      await db.query(
        `update process_tracker
         set schedule_time = (now() at time zone 'utc') + make_interval(secs => $2::double precision / 1000)
         where id = $1 and schedule_time > (now() at time zone 'utc') + ${PARKED_FROM}`,
        [id, t.remainingMs],
      );
    const pausedFor = Date.now() - p.at;
    state.pausedMs[paymentId] = (state.pausedMs[paymentId] ?? 0) + pausedFor;
    // Smart plans booked before the pause run later by the paused time
    for (const d of state.calendar?.[paymentId] ?? [])
      if (d.demoAt && Date.parse(d.demoAt) > p.at)
        d.demoAt = new Date(Date.parse(d.demoAt) + pausedFor).toISOString();
    delete state.pauses[paymentId];
    save();
    return { ...view(paymentId), resumedAfterMs: pausedFor };
  }

  function view(paymentId) {
    const p = state.pauses[paymentId];
    const next =
      p &&
      Object.values(p.held)
        .filter((t) => t.name === "EXECUTE_WORKFLOW")
        .sort((a, b) => a.remainingMs - b.remainingMs)[0];
    return {
      paymentId,
      paused: Boolean(p),
      at: p ? new Date(p.at).toISOString() : null,
      autoResumeAt: p ? new Date(p.autoResumeAt).toISOString() : null,
      // Time left to Rev Rec's next retry when it was held (null: none booked yet)
      remainingMs: next ? next.remainingMs : null,
      held: p
        ? Object.values(p.held).map((t) => ({
            name: t.name,
            remainingMs: t.remainingMs,
          }))
        : [],
      pausedMs: state.pausedMs[paymentId] ?? 0,
    };
  }

  // Every second: hold what the engine adds meanwhile; end pauses older than 15 minutes
  async function tick() {
    for (const [paymentId, p] of Object.entries(state.pauses)) {
      if (Date.now() >= p.autoResumeAt) await resume(paymentId);
      else await hold(paymentId);
    }
  }

  async function resumeAll() {
    for (const paymentId of Object.keys(state.pauses)) await resume(paymentId);
  }

  return {
    holdPlanned,
    pause,
    resume,
    view,
    tick,
    resumeAll,
    isPaused: (paymentId) => Boolean(state.pauses[paymentId]),
  };
}
