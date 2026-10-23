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
  // Scenario ids to allow although they are not runnable yet, for one-off probes. Example: "7".
  enabledScenarios: read("SIM_ENABLE_SCENARIOS")
    .split(",")
    .map((s) => Number(s.trim()))
    .filter(Number.isInteger),
  dataDir: read("SIM_DATA_DIR") || path.join(PROXY_ROOT, "data"),
};

// Every secret value we hold. Used to scrub any text before it leaves the proxy.
// auth.ts adds the switched dashboard tokens here too.
export const SECRET_VALUES: string[] = [
  config.hsApiKey,
  config.stripeKey,
  config.hsDashboardJwt,
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
