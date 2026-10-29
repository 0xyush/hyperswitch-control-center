// Profiles for stories with live settings (simulator/selfhost/seed.sh 8d, HS_POOL). Rev Rec's
// settings live on the profile (retry mode) and its billing connector (max tries, grace), so a story
// that changes them mid-run gets a profile of its own: a change never reaches another visitor's
// invoice. A lease is kept in <dataDir>/pool.json. The profile goes back, reset to the defaults,
// when its story ends; story.ts also takes back leases older than LEASE_MAX_MS.
import fs from "node:fs";
import path from "node:path";
import { revrecMerchantId } from "./auth.ts";
import { config, type ProfileRef } from "./config.ts";
import { hsDashboard } from "./upstream.ts";

export const POOL: ProfileRef[] = config.pool
  .split(",")
  .map((s) => s.trim().split(":"))
  .filter((p) => p.length === 3 && p.every(Boolean))
  .map(([profileId, billingMcaId, paymentMcaId]) => ({
    key: "pool" as const,
    profileId,
    billingMcaId,
    paymentMcaId,
  }));
export const poolOn = () => POOL.length > 0;

// What a profile is reset to: the seed's values.
export const DEFAULTS = {
  mode: "cascading",
  maxRetries: 15,
  graceDays: 30,
  startRule: 0,
} as const;
export const LEASE_MAX_MS = 30 * 60_000;

export type Lease = { profileId: string; storyId: string; leasedAt: string };
const FILE = path.join(config.dataDir, "pool.json");
let leases: Lease[] = [];
try {
  leases = JSON.parse(fs.readFileSync(FILE, "utf8"));
} catch {
  // No leases yet.
}
const save = () => {
  fs.mkdirSync(config.dataDir, { recursive: true });
  fs.writeFileSync(`${FILE}.tmp`, JSON.stringify(leases));
  fs.renameSync(`${FILE}.tmp`, FILE);
};

export const leases_ = () => [...leases];
// True when a profile is free now.
export const poolFree = () => {
  const busy = new Set([...leases.map((l) => l.profileId), ...resetting]);
  return POOL.some((p) => !busy.has(p.profileId));
};
export const leaseOf = (storyId: string) =>
  leases.find((l) => l.storyId === storyId) ?? null;
// Profiles being reset are not free yet.
const resetting = new Set<string>();

// A free profile for this story, or null when all are leased.
export function lease(storyId: string): ProfileRef | null {
  const busy = new Set([...leases.map((l) => l.profileId), ...resetting]);
  const ref = POOL.find((p) => !busy.has(p.profileId));
  if (!ref) return null;
  leases.push({
    profileId: ref.profileId,
    storyId,
    leasedAt: new Date().toISOString(),
  });
  save();
  return ref;
}

// The billing connector's Rev Rec settings, the rest kept as the seed made them.
export function setBilling(
  ref: ProfileRef,
  rr: { maxRetries: number; graceDays: number },
) {
  return hsDashboard("PUT", `v2/connector-accounts/${ref.billingMcaId}`, {
    profileId: ref.profileId,
    body: {
      connector_type: "billing_processor",
      merchant_id: revrecMerchantId() || config.hsRevrecMerchantId,
      feature_metadata: {
        revenue_recovery: {
          billing_connector_retry_threshold: DEFAULTS.startRule,
          max_retry_count: rr.maxRetries,
          grace_period_days: rr.graceDays,
          billing_account_reference: { [ref.paymentMcaId]: ref.paymentMcaId },
        },
      },
    },
  });
}

export const setMode = (ref: ProfileRef, mode: string) =>
  hsDashboard("PUT", `v2/profiles/${ref.profileId}`, {
    profileId: ref.profileId,
    body: { revenue_recovery_retry_algorithm_type: mode },
  });

// Reset to the defaults, then free. A failed reset keeps the profile out of the pool until the
// next try, so a visitor never gets a profile with someone else's settings.
export async function release(storyId: string) {
  const l = leaseOf(storyId);
  if (!l || resetting.has(l.profileId)) return;
  const ref = POOL.find((p) => p.profileId === l.profileId);
  resetting.add(l.profileId);
  leases = leases.filter((x) => x !== l);
  save();
  try {
    if (!ref) return;
    const [m, b] = await Promise.all([
      setMode(ref, DEFAULTS.mode),
      setBilling(ref, {
        maxRetries: DEFAULTS.maxRetries,
        graceDays: DEFAULTS.graceDays,
      }),
    ]);
    if (m?.status !== 200 || b?.status !== 200) {
      leases.push({ ...l, storyId: `reset-failed:${l.storyId}` });
      save();
    }
  } finally {
    resetting.delete(l.profileId);
  }
}
