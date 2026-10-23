// Gets a dashboard token scoped to the Rev Rec merchant and profile.
// The token pasted from the browser is often scoped to another merchant (for example Orchestrator).
// The proxy exchanges it with the same switch calls the dashboard makes. The token is never shown.
import { config, jwtClaims, SECRET_VALUES } from "./config.ts";

type SwitchStep = {
  step: string;
  path: string;
  status: number | null;
  ms: number;
  error?: string;
};

const state = {
  token: "", // the scoped token in use; "" when none is ready
  merchantId: config.hsRevrecMerchantId,
  merchantSource: config.hsRevrecMerchantId
    ? "HS_REVREC_MERCHANT_ID"
    : "not known yet",
  steps: [] as SwitchStep[],
  attemptAt: 0,
  error: null as string | null,
};
let inflight: Promise<void> | null = null;
const RETRY_AFTER_MS = 60_000;

const expiresSoon = (token: string) => {
  const exp = jwtClaims(token).exp;
  return !exp || exp * 1000 < Date.now() + 60_000;
};

async function hsFetch(
  method: string,
  path: string,
  headers: Record<string, string>,
  body?: unknown,
) {
  const t0 = Date.now();
  const r = await fetch(`${config.hsBaseUrl}/${path}`, {
    method,
    headers: {
      Accept: "application/json",
      ...(body ? { "Content-Type": "application/json" } : {}),
      ...headers,
    },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(20_000),
  });
  let json: any = null;
  try {
    json = await r.json();
  } catch {
    // Not JSON. The status code is enough here.
  }
  return { status: r.status, json, ms: Date.now() - t0 };
}

// The API key belongs to the Rev Rec merchant, and its invoices carry the merchant id.
async function learnMerchantId(): Promise<string> {
  const r = await hsFetch("GET", "v2/payments/recovery-list?limit=1", {
    Authorization: `api-key=${config.hsApiKey}`,
    "X-Profile-Id": config.hsProfileId,
  });
  return r.status === 200 ? (r.json?.data?.[0]?.merchant_id ?? "") : "";
}

async function switchTo(
  kind: "merchant" | "profile",
  token: string,
  body: Record<string, string>,
): Promise<string | null> {
  const c = jwtClaims(token);
  const headers: Record<string, string> = { Authorization: `Bearer ${token}` };
  if (c.merchant_id) headers["X-Merchant-Id"] = c.merchant_id;
  if (c.profile_id) headers["X-Profile-Id"] = c.profile_id;
  // v2 merchants use the v2 path in the dashboard. Try the v1 spelling only if v2 does not exist.
  for (const path of [`v2/user/switch/${kind}`, `user/switch/${kind}`]) {
    const r = await hsFetch("POST", path, headers, body).catch((e: Error) => ({
      status: null,
      json: null,
      ms: 0,
      err: e.message,
    }));
    const error =
      r.status === 200
        ? undefined
        : (r.json?.error?.message ?? ("err" in r ? r.err : undefined));
    state.steps.push({
      step: `switch ${kind}`,
      path,
      status: r.status,
      ms: r.ms,
      ...(error ? { error } : {}),
    });
    if (r.status === 200 && typeof r.json?.token === "string")
      return r.json.token;
    if (r.status !== 404) break;
  }
  return null;
}

export function refreshDashboardToken(): Promise<void> {
  if (inflight) return inflight;
  inflight = (async () => {
    state.attemptAt = Date.now();
    state.steps = [];
    state.error = null;
    state.token = "";
    const pasted = config.hsDashboardJwt;
    if (!pasted) {
      state.error = "HS_DASHBOARD_JWT is not set.";
      return;
    }
    if (expiresSoon(pasted)) {
      state.error =
        "HS_DASHBOARD_JWT has expired. Re-grab it (bash simulator/scripts/grab-jwt.sh).";
      return;
    }
    if (!state.merchantId) {
      state.merchantId = await learnMerchantId().catch(() => "");
      state.merchantSource = state.merchantId
        ? "learned from the API key"
        : "not known";
    }
    if (!state.merchantId) {
      state.error =
        "Could not learn the Rev Rec merchant id. Set HS_REVREC_MERCHANT_ID.";
      return;
    }

    let token = pasted;
    if (jwtClaims(token).merchant_id !== state.merchantId) {
      const t = await switchTo("merchant", token, {
        merchant_id: state.merchantId,
      });
      if (!t) {
        state.error =
          "Switch to the Rev Rec merchant failed. Switch merchant in the browser, then re-grab the token.";
        return;
      }
      token = t;
    }
    if (jwtClaims(token).profile_id !== config.hsProfileId) {
      const t = await switchTo("profile", token, {
        profile_id: config.hsProfileId,
      });
      if (t) token = t;
      else
        state.error =
          "Switch to the Rev Rec profile failed. Using the merchant-scoped token.";
    }
    if (jwtClaims(token).merchant_id !== state.merchantId) {
      state.error =
        "The switched token is still for another merchant. Not using it.";
      return;
    }
    state.token = token;
    SECRET_VALUES.push(token);
  })().finally(() => {
    inflight = null;
  });
  return inflight;
}

// The token for dashboard-only reads, or "" when none is ready.
// Never returns a token scoped to another merchant.
export async function dashboardToken(): Promise<string> {
  if (state.token && !expiresSoon(state.token)) return state.token;
  if (config.hsDashboardJwt && Date.now() - state.attemptAt > RETRY_AFTER_MS)
    await refreshDashboardToken();
  return state.token;
}

// Call after the sandbox refused the token (401), so the next call switches again.
export function dropDashboardToken() {
  state.token = "";
  state.attemptAt = 0;
}

export const revrecMerchantId = () => state.merchantId;
export const hasDashboardToken = () => Boolean(state.token);

// For /healthz. Ids and expiry times only, never a token.
export function authStatus() {
  const pasted = jwtClaims(config.hsDashboardJwt);
  const scoped = jwtClaims(state.token);
  const iso = (exp?: number) =>
    exp ? new Date(exp * 1000).toISOString() : null;
  return {
    ok: Boolean(state.token),
    revrecMerchantId: state.merchantId || null,
    revrecMerchantIdSource: state.merchantSource,
    pasted: config.hsDashboardJwt
      ? {
          merchantId: pasted.merchant_id ?? null,
          profileId: pasted.profile_id ?? null,
          role: pasted.role_id ?? null,
          expiresAt: iso(pasted.exp),
        }
      : null,
    scoped: state.token
      ? {
          merchantId: scoped.merchant_id ?? null,
          profileId: scoped.profile_id ?? null,
          expiresAt: iso(scoped.exp),
        }
      : null,
    switchSteps: state.steps,
    error: state.error,
  };
}
