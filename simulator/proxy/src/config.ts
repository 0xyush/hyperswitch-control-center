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
};

// "story" is the existing demo profile (HS_PROFILE_ID): the invoice story runs there.
// "static" and "smart" are the portfolio run's pair (scripts/setup-profiles.ts). Until they
// exist, both fall back to the story profile, so both runs use the same retry mode.
export type ProfileKey = "story" | "static" | "smart";
export type ProfileRef = {
  key: ProfileKey;
  profileId: string;
  billingMcaId: string;
  paymentMcaId: string;
};
const profileRef = (key: ProfileKey, prefix: string): ProfileRef => ({
  key,
  profileId: read(`${prefix}_PROFILE_ID`) || config.hsProfileId,
  billingMcaId: read(`${prefix}_BILLING_MCA_ID`) || config.hsBillingMcaId,
  paymentMcaId: read(`${prefix}_PAYMENT_MCA_ID`) || config.hsPaymentMcaId,
});
export const PROFILES: Record<ProfileKey, ProfileRef> = {
  story: profileRef("story", "HS_STORY"),
  static: profileRef("static", "HS_STATIC"),
  smart: profileRef("smart", "HS_SMART"),
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

// The portfolio run is off unless SIM_PORTFOLIO=1.
export const portfolioConfig = {
  enabled: read("SIM_PORTFOLIO") === "1",
  maxInvoices: 10,
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
    profileId: config.hsProfileId || null,
  };
}
