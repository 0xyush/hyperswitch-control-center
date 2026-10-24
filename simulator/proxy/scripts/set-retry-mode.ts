// Operator script: sets the retry mode of the portfolio profiles (HS_STATIC_PROFILE_ID,
// HS_SMART_PROFILE_ID): static -> cascading, smart -> smart. It writes shared sandbox config,
// so it runs only by hand.
//   node scripts/set-retry-mode.ts           plan only: prints each profile's mode now and after
//   node scripts/set-retry-mode.ts --apply   writes
// Needed after setup-profiles.ts of 24 Oct: creating a billing connector puts its profile back
// into monitoring, and monitoring later falls to the server default (cascading), never smart.
import { authStatus, refreshDashboardToken } from "../src/auth.ts";
import { PROFILES } from "../src/config.ts";
import { hsDashboard } from "../src/upstream.ts";

const apply = process.argv.includes("--apply");
const TARGETS = [
  { key: "static", mode: "cascading" },
  { key: "smart", mode: "smart" },
] as const;

function fail(message: string): never {
  console.error(`set-retry-mode: ${message}`);
  process.exit(1);
}

await refreshDashboardToken();
if (!authStatus().ok) fail(`no dashboard token: ${authStatus().error}`);
if (PROFILES.static.profileId === PROFILES.story.profileId)
  fail(
    "HS_STATIC_PROFILE_ID is not set; this script never changes the story profile",
  );

for (const t of TARGETS) {
  const id = PROFILES[t.key].profileId;
  const read = async () =>
    (await hsDashboard("GET", `v2/profiles/${id}`, { profileId: id }))?.json
      ?.revenue_recovery_retry_algorithm_type ?? "?";
  console.log(`${t.key} profile ${id}: now ${await read()}, wanted ${t.mode}`);
  if (!apply) continue;
  const r = await hsDashboard("PUT", `v2/profiles/${id}`, {
    profileId: id,
    body: { revenue_recovery_retry_algorithm_type: t.mode },
  });
  if (r?.status !== 200)
    fail(
      `update refused (${r?.status}): ${JSON.stringify(r?.json?.error ?? r?.json).slice(0, 300)}`,
    );
  console.log(`  saved: ${await read()}`);
}
if (!apply) console.log("Plan only. Add --apply to write it.");
