// One-off seed for Replay mode (simulator/REPLAY.md): marks the four stories as recordings.
// Two of them come from the first store (data/stories.json, before 24 Oct) and are imported first.
// Run with the proxy stopped (it writes the same store files): node scripts/seed-recordings.ts
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { refreshDashboardToken } from "../src/auth.ts";
import { config } from "../src/config.ts";
import { importV1Story } from "../src/story.ts";
import { markRecording } from "../src/recordings.ts";

const busy = await new Promise<boolean>((ok) => {
  const s = net.connect(
    config.port,
    "127.0.0.1",
    () => (s.destroy(), ok(true)),
  );
  s.on("error", () => ok(false));
});
if (busy) {
  console.error(
    `seed-recordings: the proxy is running on :${config.port}; stop it first`,
  );
  process.exit(1);
}
await refreshDashboardToken();

const v1 = JSON.parse(
  fs.readFileSync(path.join(config.dataDir, "stories.json"), "utf8"),
) as any[];
const v1Story = (id: string) => {
  const s = v1.find((x) => x.storyId === id);
  if (!s) throw new Error(`${id} not in data/stories.json`);
  return s;
};

// Observations from the 23 Oct run log (the driver's poll lines); the first store did not keep them.
// st_403581a10106: "20:35:56 status=monitoring", then "20:36:03 status=scheduled
// next=2026-10-23T20:36:57.807Z pt=EXECUTE_WORKFLOW/new/Pending", then paid in the app.
// The booking is listed at 20:36:03.000Z so it sorts before the 20:36:03 Stripe call it came before.
const s1 = v1Story("st_403581a10106");
importV1Story(s1, {
  stageSeen: {
    Monitoring: "2026-10-23T20:35:56Z",
    Scheduled: "2026-10-23T20:36:03Z",
    Recovered: "2026-10-23T20:36:06Z",
  },
  bookings: [
    {
      at: "2026-10-23T20:36:03.000Z",
      processTracker: {
        id: `PASSIVE_RECOVERY_WORKFLOW_EXECUTE_WORKFLOW_${s1.recoveryId}`,
        name: "EXECUTE_WORKFLOW",
        schedule_time_for_payment: "2026-10-23T20:36:57.807Z",
        schedule_time_for_psync: null,
        status: "new",
        business_status: "Pending",
      },
    },
  ],
});
// st_179854639f59: "20:46:06 status=monitoring" after the refused copy.
importV1Story(v1Story("st_179854639f59"), {
  stageSeen: { Monitoring: "2026-10-23T20:46:06Z" },
  bookings: [],
});

const SEED: [string, string][] = [
  ["st_7bf8bc687160", "Temporary error, retry works (24 Oct)"],
  ["st_403581a10106", "Customer pays in the app"],
  ["st_179854639f59", "Duplicate report refused"],
  ["st_5e2776d00d4e", "Insufficient funds, then recovers"],
];
for (const [id, title] of SEED) {
  const r = await markRecording(id, title);
  console.log(`${id}  ${r.steps} steps  ${r.outcome}  "${r.title}"`);
}
process.exit(0);
