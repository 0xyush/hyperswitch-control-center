// Data for the "Setup Recovery" walkthrough (GET /sim/connectors, GET /sim/setup/summary): the
// connectors this demo really uses, each live-checked, with masked values only (never a secret:
// the last 4 characters at most), and the demo profile's retry settings in plain words.
import { config, PROFILES } from "./config.ts";
import { bankProcessors, readRevRecConfig } from "./story.ts";
import { hsDashboard, stripe } from "./upstream.ts";
import { ADAPTERS, configured, processorProfile } from "./processors.ts";
import { DEFAULTS, poolOn } from "./pool.ts";

const TTL_MS = 10 * 60_000;
const DOTS = "••••••••";

// A secret shown as its prefix (sk_test_) and its last 4 characters.
export function masked(secret: string, prefix = "") {
  if (!secret) return null;
  const head = prefix && secret.startsWith(prefix) ? prefix : "";
  return `${head}${DOTS}${secret.length > 8 ? secret.slice(-4) : ""}`;
}

let cached: { at: number; body: unknown } | null = null;

export async function connectors() {
  if (cached && Date.now() - cached.at < TTL_MS) return cached.body;
  const ref = PROFILES.story;
  const [s, pay, bill] = await Promise.all([
    stripe("GET", "balance").catch(() => null),
    hsDashboard("GET", `v2/connector-accounts/${ref.paymentMcaId}`, {
      profileId: ref.profileId,
    }).catch(() => null),
    hsDashboard("GET", `v2/connector-accounts/${ref.billingMcaId}`, {
      profileId: ref.profileId,
    }).catch(() => null),
  ]);
  const active = (r: { status: number; json: any } | null) =>
    r?.status === 200 && r.json?.status === "active" && !r.json?.disabled;
  const stripeTest = s?.status === 200 && s.json?.livemode === false;
  const checkedAt = new Date().toISOString();
  const body = {
    connectors: [
      {
        id: "stripe",
        name: "Stripe",
        kind: "processor",
        logoKey: "stripe",
        mode: "test",
        working: stripeTest && active(pay),
        checks: [
          { what: "Stripe answers in test mode", ok: stripeTest },
          { what: "Connected to Rev Rec's demo profile", ok: active(pay) },
        ],
        maskedFields: [
          { label: "Secret key", value: masked(config.stripeKey, "sk_test_") },
        ],
        checkedAt,
      },
      {
        id: "custombilling",
        name: "Custom billing system (this simulator)",
        kind: "billing",
        logoKey: "custombilling",
        mode: "test",
        working: active(bill),
        checks: [
          { what: "Connected to Rev Rec's demo profile", ok: active(bill) },
        ],
        maskedFields: [
          { label: "Rev Rec API key", value: masked(config.hsApiKey) },
          // The webhook signing key lives on the engine only; the proxy never holds it.
          ...(config.inboxUrl
            ? [{ label: "Webhook signing key", value: DOTS }]
            : []),
        ],
        checkedAt,
      },
    ],
  };
  // The other processors that work end to end (processors.ts), each checked live: its own test API
  // answers, and its connector on its own engine profile is active.
  const bank = await bankProcessors();
  const others = await Promise.all(
    ADAPTERS.filter(configured).map(async (a) => {
      const ref = processorProfile(a.id)!;
      const [api, mca] = await Promise.all([
        a.check().catch(() => false),
        hsDashboard("GET", `v2/connector-accounts/${ref.paymentMcaId}`, {
          profileId: ref.profileId,
        }).catch(() => null),
      ]);
      return {
        id: a.id,
        name: a.name,
        kind: "processor",
        logoKey: a.logoKey,
        mode: "test",
        working: api && active(mca),
        checks: [
          { what: `${a.name} answers in test mode`, ok: api },
          { what: "Connected to its own Rev Rec profile", ok: active(mca) },
        ],
        maskedFields: a.masked(),
        // Its real test answers; the real-world stories once the sim's bank reaches it.
        stories: bank.has(a.id)
          ? "Temporary error and real-world stories, with the scripted bank."
          : "Temporary error story only; real-world stories use Stripe.",
        checkedAt,
      };
    }),
  );
  (body.connectors as unknown[]).splice(1, 0, ...others);
  // A failed check (e.g. the engine restarting) is not kept: the next read checks again.
  if ((body.connectors as { working: boolean }[]).every((c) => c.working))
    cached = { at: Date.now(), body };
  return body;
}

const MODES: Record<string, { value: string; text: string }> = {
  cascading: { value: "static", text: "Static retries: a fixed timetable." },
  smart: {
    value: "smart",
    text: "Smart retries: Rev Rec's model picks the day and hour.",
  },
  monitoring: {
    value: "monitoring",
    text: "Monitoring: records failures, no retries yet.",
  },
};

export async function setupSummary() {
  // Every story starts smart (28 Oct) on a pool profile reset to the seed's values: those are the
  // settings a visitor's story starts with. Without the pool, the story profile's own settings.
  const pooled = poolOn() && config.poolSmart;
  const rrc = pooled
    ? {
        retryMode: "smart",
        maxRetries: DEFAULTS.maxRetries,
        startRule: DEFAULTS.startRule,
        gracePeriodDays: DEFAULTS.graceDays,
      }
    : await readRevRecConfig(PROFILES.story).catch(() => null);
  const mode = rrc?.retryMode ? MODES[rrc.retryMode] : undefined;
  const sr = rrc?.startRule ?? null;
  return {
    processor: { id: "stripe", text: "Stripe (test mode)" },
    platform: {
      id: "custombilling",
      text: "Custom billing system (this simulator)",
    },
    settings: [
      {
        id: "retryMode",
        label: "Retry mode",
        value: mode?.value ?? rrc?.retryMode ?? null,
        text: mode?.text ?? "Not read.",
      },
      {
        id: "maxRetries",
        label: "Max tries",
        value: rrc?.maxRetries ?? null,
        text:
          rrc?.maxRetries != null
            ? `${rrc.maxRetries} tries, then Rev Rec stops.`
            : "Not read.",
      },
      {
        id: "startRule",
        label: "Start rule",
        value: sr,
        text:
          sr === null
            ? "Not read."
            : sr === 0
              ? "Rev Rec takes over once informed of the first failed charge."
              : `Rev Rec takes over once informed of ${sr + 1} failed charges.`,
      },
      {
        id: "graceDays",
        label: "Grace period",
        value: rrc?.gracePeriodDays ?? null,
        text:
          rrc?.gracePeriodDays != null
            ? `Rev Rec tries for up to ${rrc.gracePeriodDays} days.`
            : "Not read.",
      },
    ],
    note: "You can change these during a story.",
    source: pooled ? "simulator" : rrc?.retryMode ? "sandbox" : "unknown",
    checkedAt: new Date().toISOString(),
  };
}
