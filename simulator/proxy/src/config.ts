// Reads the proxy settings from simulator/proxy/.env (git-ignored) once at start.
// Secret values are never logged or returned. Health checks only say "present" or "missing".
import fs from "node:fs";
import path from "node:path";

export const PROXY_ROOT = path.resolve(import.meta.dirname, "..");

const envFile = process.env.SIM_ENV_FILE || path.join(PROXY_ROOT, ".env");
// loadEnvFile does not override variables that are already set, so tests can override.
if (fs.existsSync(envFile)) process.loadEnvFile(envFile);

const read = (key: string): string => (process.env[key] ?? "").trim();

// The billing simulator cannot run without these.
export const REQUIRED_KEYS = [
  "HS_BASE_URL",
  "HS_API_KEY",
  "HS_PROFILE_ID",
  "HS_BILLING_MCA_ID",
  "HS_PAYMENT_MCA_ID",
  "STRIPE_TEST_KEY",
] as const;

// Nice to have. Without the JWT, the process tracker and profile config reads are not available.
// HS_REVREC_MERCHANT_ID is learned from the API key when empty.
export const OPTIONAL_KEYS = [
  "HS_DASHBOARD_JWT",
  "HS_REVREC_MERCHANT_ID",
] as const;

export type JwtClaims = {
  exp?: number;
  merchant_id?: string;
  profile_id?: string;
  org_id?: string;
  role_id?: string;
};

// Reads the claims part of a JWT without checking the signature. We only use it to see
// the expiry time and which merchant and profile the token is for.
export function jwtClaims(token: string): JwtClaims {
  try {
    const part = token.split(".")[1];
    if (!part) return {};
    return JSON.parse(
      Buffer.from(part, "base64url").toString("utf8"),
    ) as JwtClaims;
  } catch {
    return {};
  }
}

// Which Hyperswitch the proxy talks to. "sandbox": the shared sandbox (a Juspay build).
// "selfhost": upstream main on our VM (simulator/selfhost), whose responses differ in places (the
// contract test expects each engine's own fields). HS_ENGINE sets it; by default a base URL other
// than sandbox.hyperswitch.io is "selfhost", and no base URL is "sandbox" (the strict choice).
export type Engine = "sandbox" | "selfhost";
export function engineOf(baseUrl: string, override: string): Engine {
  if (override === "sandbox" || override === "selfhost") return override;
  if (!baseUrl) return "sandbox";
  try {
    return new URL(baseUrl).hostname === "sandbox.hyperswitch.io"
      ? "sandbox"
      : "selfhost";
  } catch {
    return "sandbox";
  }
}

export const config = {
  port: Number(read("PORT") || 8787),
  host: read("HOST") || "127.0.0.1",
  allowedOrigins: (
    read("ALLOWED_ORIGINS") || "http://localhost:9000,http://127.0.0.1:9000"
  )
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean),
  hsBaseUrl: read("HS_BASE_URL").replace(/\/+$/, ""),
  engine: engineOf(read("HS_BASE_URL"), read("HS_ENGINE")),
  hsApiKey: read("HS_API_KEY"),
  hsProfileId: read("HS_PROFILE_ID"),
  hsBillingMcaId: read("HS_BILLING_MCA_ID"),
  hsPaymentMcaId: read("HS_PAYMENT_MCA_ID"),
  // The sandbox moved from v2/payments/recovery to v2/recovery on 14 Oct 2026.
  hsRecoveryPath: (read("HS_RECOVERY_PATH") || "v2/recovery").replace(
    /^\/+/,
    "",
  ),
  // The token pasted from the browser. It may be scoped to another merchant; auth.ts switches it.
  hsDashboardJwt: read("HS_DASHBOARD_JWT").replace(/^Bearer\s+/i, ""),
  hsRevrecMerchantId: read("HS_REVREC_MERCHANT_ID"),
  stripeKey: read("STRIPE_TEST_KEY"),
  startsPerHour: Number(read("RATE_LIMIT_STARTS_PER_HOUR") || 5),
  // Behind Cloud Run the socket address is Google's front end: take the client IP from
  // X-Forwarded-For instead. Only set this behind a proxy you trust.
  trustProxy: read("TRUST_PROXY") === "1",
  contractTest: read("SIM_CONTRACT_TEST") !== "0",
  // One shared password for the public link (src/gate.ts). Empty = no gate (local dev).
  password: read("SIM_PASSWORD"),
  // The dashboard build to serve on the same origin (src/dashboard.ts). Empty = API only.
  dashboardDist: read("DASHBOARD_DIST"),
  dashboardServerDir:
    read("DASHBOARD_SERVER_DIR") ||
    path.join(PROXY_ROOT, "..", "..", "src", "server"),
  // Looser cap per IP, because a browser chooses its own x-sim-session id and could change it.
  startsPerIpHour: Number(
    read("RATE_LIMIT_STARTS_PER_IP_HOUR") ||
      Number(read("RATE_LIMIT_STARTS_PER_HOUR") || 5) * 6,
  ),
  dataDir: read("SIM_DATA_DIR") || path.join(PROXY_ROOT, "data"),
  // The self-hosted engine retries within seconds (simulator/selfhost). SIM_FAST_ENGINE=1 puts the
  // simulator's own waits on that pace: the scripted bank, the waiting note and the preset texts.
  // Unset = sandbox pace (minutes).
  fastEngine: read("SIM_FAST_ENGINE") === "1",
  // The webhook inbox on the VM (simulator/selfhost/inbox): the engine's outgoing webhooks to the
  // billing system, read back for the story. Empty = no webhook rows.
  inboxUrl: read("INBOX_URL").replace(/\/+$/, ""),
  inboxToken: read("INBOX_READ_TOKEN"),
  // The sim service on the VM (simulator/selfhost/sim): the simulated calendar, the model's
  // decisions in plain numbers and the bank. Empty = none.
  simUrl: read("SIM_URL").replace(/\/+$/, ""),
  simToken: read("SIM_TOKEN"),
  // Proof runs only (a private proxy copy): processors to treat as bank-ready before the sim lists
  // them, so the public proxy unlocks a processor only after its proof. Comma list of ids.
  bankProof: read("SIM_BANK_PROOF")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean),
  // The stand-in decider's call log on the VM (simulator/selfhost/decider): whether the engine asked
  // it for a retry time. Empty = not read.
  deciderUrl: read("DECIDER_URL").replace(/\/+$/, ""),
  // Profiles a story with live settings leases (selfhost/seed.sh 8d): profile:billing:payment, comma
  // separated. Empty = no live settings.
  pool: read("HS_POOL"),
  // Smart on a pool profile runs Rev Rec's model, whose retries plan days ahead; it needs the sim
  // service's calendar to cover the pool profiles. POOL_SMART=1 once it does.
  poolSmart: read("POOL_SMART") === "1",
  // Stories that charge a card other than the one the customer gave for this invoice: the "New
  // card" event, the "swap" report and preset 9 (the second saved card). Off since 28 Oct (the
  // user's policy); SIM_OTHER_CARDS=1 turns them back on. The code paths stay.
  otherCards: read("SIM_OTHER_CARDS") === "1",
};

// "story" is the existing demo profile (HS_PROFILE_ID): the invoice story runs there.
// "static" and "smart" are the portfolio run's pair (scripts/setup-profiles.ts). Until they
// exist, both fall back to the story profile, so both runs use the same retry mode.
// "decider" is smart without the model flag, for preset 9 (selfhost/seed.sh 6c): the engine picks
// among the customer's saved cards and asks the stand-in decider for the time.
// "pool" is a profile leased by one story for live settings (pool.ts).
export type ProfileKey = "story" | "static" | "smart" | "decider" | "pool";
export type SharedProfileKey = Exclude<ProfileKey, "pool">;
export type ProfileRef = {
  key: ProfileKey;
  profileId: string;
  billingMcaId: string;
  paymentMcaId: string;
};
const profileRef = (key: SharedProfileKey, prefix: string): ProfileRef => ({
  key,
  profileId: read(`${prefix}_PROFILE_ID`) || config.hsProfileId,
  billingMcaId: read(`${prefix}_BILLING_MCA_ID`) || config.hsBillingMcaId,
  paymentMcaId: read(`${prefix}_PAYMENT_MCA_ID`) || config.hsPaymentMcaId,
});
export const PROFILES: Record<SharedProfileKey, ProfileRef> = {
  story: profileRef("story", "HS_STORY"),
  static: profileRef("static", "HS_STATIC"),
  smart: profileRef("smart", "HS_SMART"),
  decider: profileRef("decider", "HS_DECIDER"),
};

// The portfolio form's "stop after" choices, in minutes. PORTFOLIO_STOP_AFTER_MINUTES is a comma
// list, for example 0.5,1,2 on the self-hosted stack, where Rev Rec retries within seconds.
// Values are half minutes from 0.5 to 45; others are dropped. None left = the default.
export const DEFAULT_STOP_AFTER_MINUTES = [10, 20, 45];
export function parseStopAfter(raw: string): number[] {
  const ok = raw
    .split(",")
    .filter((s) => s.trim() !== "")
    .map(Number)
    .filter((n) => n >= 0.5 && n <= 45 && Number.isInteger(n * 2));
  return ok.length
    ? [...new Set(ok)].sort((a, b) => a - b)
    : [...DEFAULT_STOP_AFTER_MINUTES];
}

// Invoices per portfolio run: PORTFOLIO_MAX_INVOICES (1 to 100, default 10). The shared sandbox
// capped a batch at 10; our own engine has no such cap.
function parseMaxInvoices(raw: string | undefined): number {
  const n = Number(raw);
  return Number.isInteger(n) && n >= 1 && n <= 100 ? n : 10;
}

// The portfolio run is off unless SIM_PORTFOLIO=1.
export const portfolioConfig = {
  enabled: read("SIM_PORTFOLIO") === "1",
  maxInvoices: parseMaxInvoices(read("PORTFOLIO_MAX_INVOICES")),
  runsPerHour: Number(read("RATE_LIMIT_PORTFOLIO_PER_HOUR") || 1),
  stopAfterMinutes: parseStopAfter(read("PORTFOLIO_STOP_AFTER_MINUTES")),
};

// Every secret value we hold. Used to scrub any text before it leaves the proxy.
// auth.ts adds the switched dashboard tokens here too.
export const SECRET_VALUES: string[] = [
  config.hsApiKey,
  config.stripeKey,
  config.hsDashboardJwt,
  config.password,
  config.inboxToken,
  config.simToken,
  // Processor test keys (processors.ts): every value under their env names.
  ...Object.entries(process.env)
    .filter(([k]) =>
      /^(ADYEN|CYBERSOURCE|AUTHORIZEDOTNET|WORLDPAY|NMI|GLOBALPAY|NUVEI|PAYEEZY|MULTISAFEPAY)_/.test(
        k,
      ),
    )
    .map(([, v]) => (v ?? "").trim()),
  // 8+ characters: a short password such as "test" would blank that word in every text.
].filter((v) => v.length >= 8);

export function missingKeys(): string[] {
  return REQUIRED_KEYS.filter((k) => !read(k));
}

export function configStatus() {
  const missing = missingKeys();
  const stripeTestMode = config.stripeKey.startsWith("sk_test_");
  return {
    ok: missing.length === 0 && stripeTestMode,
    missing,
    present: Object.fromEntries(
      [...REQUIRED_KEYS, ...OPTIONAL_KEYS].map((k) => [k, Boolean(read(k))]),
    ),
    stripeTestMode,
    recoveryPath: config.hsRecoveryPath,
    engine: config.engine,
    profileId: config.hsProfileId || null,
  };
}
