// HTTP clients for the two real systems the proxy talks to: the Hyperswitch sandbox and Stripe test mode.
import {
  dashboardToken,
  dropDashboardToken,
  revrecMerchantId,
} from "./auth.ts";
import { config } from "./config.ts";

export type Upstream = { status: number; json: any; ms: number };

const TIMEOUT_MS = 20_000;

async function call(url: string, init: RequestInit): Promise<Upstream> {
  const t0 = Date.now();
  const r = await fetch(url, {
    ...init,
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  const text = await r.text();
  let json: unknown;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = { raw: text.slice(0, 2000) };
  }
  return { status: r.status, json, ms: Date.now() - t0 };
}

// Headers we show in the "Show requests" panel. The real auth value never leaves the proxy.
export function shownHsHeaders(auth: "api-key" | "jwt") {
  return {
    Authorization:
      auth === "api-key"
        ? "api-key=<hidden by proxy>"
        : "Bearer <hidden by proxy>",
    "X-Profile-Id": config.hsProfileId,
    ...(auth === "jwt" && revrecMerchantId()
      ? { "X-Merchant-Id": revrecMerchantId() }
      : {}),
    "Content-Type": "application/json",
  };
}

// Sandbox call with the merchant API key (billing simulator writes, and the reads that accept it).
export function hsApiKey(
  method: string,
  pathAndQuery: string,
  body?: unknown,
): Promise<Upstream> {
  return call(`${config.hsBaseUrl}/${pathAndQuery.replace(/^\/+/, "")}`, {
    method,
    headers: {
      Authorization: `api-key=${config.hsApiKey}`,
      "X-Profile-Id": config.hsProfileId,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

// Sandbox call as the demo dashboard user (process tracker, config reads).
// Returns null when no token scoped to the Rev Rec merchant is ready.
export async function hsDashboard(
  method: string,
  pathAndQuery: string,
  opts: { profileId?: string } = {},
): Promise<Upstream | null> {
  const token = await dashboardToken();
  if (!token) return null;
  const r = await call(
    `${config.hsBaseUrl}/${pathAndQuery.replace(/^\/+/, "")}`,
    {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        "X-Merchant-Id": revrecMerchantId(),
        "X-Profile-Id": opts.profileId || config.hsProfileId,
        Accept: "application/json",
      },
    },
  );
  if (r.status === 401) dropDashboardToken();
  return r;
}

// Stripe test mode. Params are form-encoded, as the Stripe API expects.
export function stripe(
  method: "GET" | "POST",
  pathname: string,
  params?: Record<string, string>,
): Promise<Upstream> {
  return call(`https://api.stripe.com/v1/${pathname}`, {
    method,
    headers: {
      Authorization: `Bearer ${config.stripeKey}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: params ? new URLSearchParams(params) : undefined,
  });
}
