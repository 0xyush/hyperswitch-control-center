// Rev Rec Simulator proxy. The dashboard talks only to this server.
// It holds the keys, plays the billing system (/sim/*), and passes allow-listed reads to the sandbox (/api/*).
// Run: npm start   (reads simulator/proxy/.env)
import http, { type IncomingMessage, type ServerResponse } from "node:http";
import { authStatus, refreshDashboardToken } from "./auth.ts";
import { config, configStatus } from "./config.ts";
import { passThrough, recentBlocked } from "./passthrough.ts";
import { scrubText } from "./redact.ts";
import { publicPresets } from "./scenarios.ts";
import {
  cancelStory,
  HttpError,
  listStories,
  paidInApp,
  parseStart,
  reportAgain,
  startStory,
  storyView,
} from "./story.ts";
import { hsApiKey, stripe } from "./upstream.ts";

// ---------- helpers ----------

function send(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
  });
  res.end(JSON.stringify(body));
}

const MAX_BODY = 64 * 1024;
function readJson(req: IncomingMessage): Promise<any> {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => {
      size += c.length;
      if (size > MAX_BODY) {
        reject(new HttpError(413, "request body too large"));
        req.destroy();
      } else chunks.push(c);
    });
    req.on("end", () => {
      const text = Buffer.concat(chunks).toString("utf8").trim();
      if (!text) return resolve({});
      try {
        resolve(JSON.parse(text));
      } catch {
        reject(new HttpError(400, "body is not valid JSON"));
      }
    });
    req.on("error", reject);
  });
}

// The dashboard dev server (localhost:9000) calls this proxy from another origin.
function cors(req: IncomingMessage, res: ServerResponse) {
  const origin = req.headers.origin;
  if (!origin || !config.allowedOrigins.includes(origin)) return;
  res.setHeader("Access-Control-Allow-Origin", origin);
  res.setHeader("Vary", "Origin");
  // PUT and DELETE are listed so the browser can read the proxy's 403, not a CORS error.
  res.setHeader(
    "Access-Control-Allow-Methods",
    "GET, POST, PUT, DELETE, OPTIONS",
  );
  res.setHeader(
    "Access-Control-Allow-Headers",
    String(
      req.headers["access-control-request-headers"] ??
        "content-type, authorization, x-profile-id, x-merchant-id",
    )
      .replace(/[^A-Za-z0-9,\- ]/g, "")
      .slice(0, 500),
  );
  res.setHeader("Access-Control-Expose-Headers", "x-sim-auth");
  res.setHeader("Access-Control-Max-Age", "600");
}

// Story starts make real Stripe charges, so they are limited per client IP (in memory for now).
const starts = new Map<string, number[]>();
function allowStart(
  ip: string,
): { ok: true } | { ok: false; retryAfterSec: number } {
  const hour = 3_600_000;
  const now = Date.now();
  const recent = (starts.get(ip) ?? []).filter((t) => now - t < hour);
  if (recent.length >= config.startsPerHour) {
    starts.set(ip, recent);
    return {
      ok: false,
      retryAfterSec: Math.ceil((recent[0] + hour - now) / 1000),
    };
  }
  recent.push(now);
  starts.set(ip, recent);
  return { ok: true };
}

// ---------- health ----------

let health: { at: number; body: unknown } | null = null;
async function healthz() {
  if (health && Date.now() - health.at < 10_000) return health.body;
  const cfg = configStatus();
  const [sandbox, stripeCheck] = await Promise.all([
    hsApiKey("GET", "v2/payments/recovery-list?limit=1").then(
      (r) => ({
        ok: r.status === 200,
        status: r.status,
        ms: r.ms,
        invoices: r.json?.total_count ?? null,
      }),
      (e) => ({
        ok: false,
        status: null,
        ms: null,
        error: scrubText(String(e.message)),
      }),
    ),
    stripe("GET", "balance").then(
      (r) => ({
        ok: r.status === 200 && r.json?.livemode === false,
        status: r.status,
        ms: r.ms,
        livemode: r.json?.livemode ?? null,
      }),
      (e) => ({
        ok: false,
        status: null,
        ms: null,
        error: scrubText(String(e.message)),
      }),
    ),
  ]);
  // "dashboard" is not part of ok: the billing simulator works without it, only the next retry time is missing.
  const body = {
    ok: sandbox.ok && stripeCheck.ok && cfg.ok,
    sandbox,
    stripe: stripeCheck,
    config: cfg,
    dashboard: authStatus(),
    checkedAt: new Date().toISOString(),
  };
  health = { at: Date.now(), body };
  return body;
}

// ---------- routes ----------

async function route(req: IncomingMessage, res: ServerResponse) {
  const url = new URL(req.url ?? "/", "http://localhost");
  const method = req.method ?? "GET";
  const p = url.pathname;

  if (method === "OPTIONS") {
    res.writeHead(204);
    return res.end();
  }
  if (p === "/api" || p.startsWith("/api/")) return passThrough(req, res, url);

  if (method === "GET" && p === "/healthz")
    return send(res, 200, await healthz());
  // Presets, card options and currencies for the billing-system form.
  if (method === "GET" && (p === "/sim/presets" || p === "/sim/scenarios"))
    return send(res, 200, publicPresets());
  if (method === "GET" && p === "/sim/stories")
    return send(res, 200, { stories: listStories() });
  if (method === "GET" && p === "/sim/blocked")
    return send(res, 200, { blocked: recentBlocked() });

  if (method === "POST" && p === "/sim/story/start") {
    // Bad input is refused before the rate limit, so it does not use up a start.
    const opts = parseStart(await readJson(req));
    const ip = req.socket.remoteAddress ?? "unknown";
    const gate = allowStart(ip);
    if (!gate.ok) {
      res.setHeader("Retry-After", String(gate.retryAfterSec));
      throw new HttpError(
        429,
        `limit is ${config.startsPerHour} story starts per hour; try again in ${gate.retryAfterSec} s`,
      );
    }
    // Returns at once with status "starting"; the billing system's steps appear as the dashboard polls.
    const s = startStory(opts);
    return send(res, 200, await storyView(s.storyId));
  }

  const m = p.match(
    /^\/sim\/story\/(st_[a-f0-9]{12})(?:\/(paid-in-app|report-again|cancel))?$/,
  );
  if (m) {
    const [, id, action] = m;
    if (method === "GET" && !action) return send(res, 200, await storyView(id));
    if (method === "POST" && action === "paid-in-app") {
      await paidInApp(id);
      return send(res, 200, await storyView(id));
    }
    if (method === "POST" && action === "cancel") {
      await cancelStory(id);
      return send(res, 200, await storyView(id));
    }
    if (method === "POST" && action === "report-again") {
      const body = await readJson(req);
      const mode = body.mode;
      if (mode !== undefined && !["duplicate", "new", "swap"].includes(mode))
        throw new HttpError(400, 'mode must be "duplicate", "new" or "swap"');
      await reportAgain(id, mode);
      return send(res, 200, await storyView(id));
    }
  }
  return send(res, 404, {
    error: { code: "not_found", message: `no route ${method} ${p}` },
  });
}

export function createServer() {
  return http.createServer(async (req, res) => {
    const t0 = Date.now();
    // One line per request. Never headers or bodies.
    res.on("finish", () =>
      console.log(
        `${new Date().toISOString()} ${req.method} ${(req.url ?? "").split("?")[0]} ${res.statusCode} ${Date.now() - t0}ms`,
      ),
    );
    cors(req, res);
    try {
      await route(req, res);
    } catch (e) {
      const status = e instanceof HttpError ? e.status : 500;
      const code = e instanceof HttpError ? e.code : "internal";
      const body: Record<string, unknown> = {
        error: { code, message: scrubText(String((e as Error).message ?? e)) },
      };
      if (e instanceof HttpError && e.storyId) body.storyId = e.storyId;
      if (!res.headersSent) send(res, status, body);
      else res.end();
    }
  });
}

if (import.meta.main) {
  const cfg = configStatus();
  if (cfg.missing.length)
    console.warn(
      `Missing in .env: ${cfg.missing.join(", ")}. /sim/* will fail until they are set.`,
    );
  if (config.stripeKey && !cfg.stripeTestMode) {
    console.error(
      "STRIPE_TEST_KEY must be a Stripe TEST key (sk_test_...). Stopping.",
    );
    process.exit(1);
  }
  await refreshDashboardToken();
  const auth = authStatus();
  createServer().listen(config.port, config.host, () => {
    console.log(
      `Rev Rec simulator proxy on http://${config.host}:${config.port}`,
    );
    console.log(
      `  sandbox ${config.hsBaseUrl || "(not set)"}, Rev Rec merchant ${auth.revrecMerchantId ?? "(unknown)"}`,
    );
    console.log(
      `  dashboard token: ${auth.ok ? `scoped to ${auth.scoped?.merchantId} / ${auth.scoped?.profileId}` : `none (${auth.error}); api-key reads only`}`,
    );
    for (const st of auth.switchSteps)
      console.log(
        `  ${st.step} via /${st.path}: ${st.status}${st.error ? ` (${st.error})` : ""}`,
      );
    console.log(`  CORS origins: ${config.allowedOrigins.join(", ")}`);
  });
}
