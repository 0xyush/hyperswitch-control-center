// Rev Rec Simulator proxy. The dashboard talks only to this server.
// It holds the keys, plays the billing system (/sim/*), and passes allow-listed reads to the sandbox (/api/*).
// Run: npm start   (reads simulator/proxy/.env)
import http, { type IncomingMessage, type ServerResponse } from "node:http";
import { authStatus, refreshDashboardToken } from "./auth.ts";
import { config, configStatus, portfolioConfig } from "./config.ts";
import { lastContract, scheduleContractTest } from "./contract.ts";
import { passThrough, recentBlocked } from "./passthrough.ts";
import { listRecordings, markRecording, replayView } from "./recordings.ts";
import {
  listPortfolios,
  parsePortfolio,
  portfolioView,
  startPortfolio,
  stopPortfolio,
} from "./portfolio.ts";
import { scrubText } from "./redact.ts";
import { publicPresets } from "./scenarios.ts";
import {
  cancelStory,
  HttpError,
  listStories,
  lastCustomerStory,
  ownerOf,
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
        "content-type, authorization, x-profile-id, x-merchant-id, x-sim-session",
    )
      .replace(/[^A-Za-z0-9,\- ]/g, "")
      .slice(0, 500),
  );
  res.setHeader("Access-Control-Expose-Headers", "x-sim-auth");
  res.setHeader("Access-Control-Max-Age", "600");
}

// The visitor: the browser's x-sim-session id (a random id the dashboard keeps in localStorage),
// or the IP when the header is missing. Used for "same customer" and for the start limit.
const SESSION = /^[A-Za-z0-9_-]{8,64}$/;
function visitor(req: IncomingMessage) {
  const forwarded = String(req.headers["x-forwarded-for"] ?? "")
    .split(",")[0]
    .trim();
  const ip =
    (config.trustProxy && forwarded) || req.socket.remoteAddress || "unknown";
  const header = req.headers["x-sim-session"];
  const session =
    typeof header === "string" && SESSION.test(header) ? header : null;
  return { ip, owner: ownerOf(session ? `session:${session}` : `ip:${ip}`) };
}

// Operator calls: with SIM_OPERATOR_KEY set, the x-sim-operator header must match it. Without
// it, only a direct local call counts (no X-Forwarded-For, so not through Cloud Run's front end).
function isOperator(req: IncomingMessage) {
  const key = process.env.SIM_OPERATOR_KEY;
  if (key) return req.headers["x-sim-operator"] === key;
  const ip = req.socket.remoteAddress ?? "";
  return (
    !req.headers["x-forwarded-for"] &&
    (ip === "127.0.0.1" || ip === "::1" || ip === "::ffff:127.0.0.1")
  );
}

// Story starts make real Stripe charges, so they are limited per visitor, with a looser cap
// per IP (in memory for now).
const starts = new Map<string, number[]>();
function allowStart(
  key: string,
  limit: number,
): { ok: true } | { ok: false; retryAfterSec: number } {
  const hour = 3_600_000;
  const now = Date.now();
  const recent = (starts.get(key) ?? []).filter((t) => now - t < hour);
  starts.set(key, recent);
  if (recent.length >= limit)
    return {
      ok: false,
      retryAfterSec: Math.ceil((recent[0] + hour - now) / 1000),
    };
  return { ok: true };
}
const noteStart = (...keys: string[]) => {
  for (const k of keys) starts.get(k)?.push(Date.now());
};

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
  // The hourly contract test: field drift between the sandbox and what the proxy sends and reads.
  const contract = lastContract();
  const body = {
    ok: sandbox.ok && stripeCheck.ok && cfg.ok && contract?.ok !== false,
    sandbox,
    stripe: stripeCheck,
    config: cfg,
    dashboard: authStatus(),
    // For the operator page, which lists every key here.
    limits: {
      storyStartsPerHour: config.startsPerHour,
      storyStartsPerIpHour: config.startsPerIpHour,
      portfolioEnabled: portfolioConfig.enabled,
      portfolioRunsPerHour: portfolioConfig.runsPerHour,
      portfolioMaxInvoices: portfolioConfig.maxInvoices,
      portfolioRunsAtOnce: 1,
    },
    contract: contract ?? {
      ok: null,
      note: "first run 20 s after start, then every hour",
    },
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
    const { ip, owner } = visitor(req);
    if (opts.customer === "same" && !lastCustomerStory(owner))
      throw new HttpError(
        409,
        'There is no earlier customer to reuse. Start a story with customer "new" first.',
      );
    const ipKey = `ip:${ip}`;
    for (const [key, limit] of [
      [owner, config.startsPerHour],
      [ipKey, config.startsPerIpHour],
    ] as const) {
      const gate = allowStart(key, limit);
      if (!gate.ok) {
        res.setHeader("Retry-After", String(gate.retryAfterSec));
        throw new HttpError(
          429,
          `limit is ${limit} story starts per hour${key === ipKey ? " from one network address" : ""}; try again in ${gate.retryAfterSec} s`,
        );
      }
    }
    noteStart(owner, ipKey);
    // Returns at once with status "starting"; the billing system's steps appear as the dashboard polls.
    const { story: s } = startStory(opts, owner);
    return send(res, 200, await storyView(s.storyId));
  }

  // Replay mode (simulator/REPLAY.md): recorded stories, walked without the sandbox.
  if (method === "GET" && p === "/sim/recordings")
    return send(res, 200, { recordings: listRecordings() });
  const rec = p.match(/^\/sim\/recordings\/(st_[a-f0-9]{12})$/);
  if (method === "POST" && rec) {
    if (!isOperator(req))
      throw new HttpError(403, "marking a recording is for operators");
    const body = await readJson(req);
    return send(
      res,
      200,
      await markRecording(rec[1], String(body.title ?? "").trim()),
    );
  }
  const rp = p.match(/^\/sim\/replay\/(st_[a-f0-9]{12})$/);
  if (method === "GET" && rp) {
    const upTo = url.searchParams.get("upTo");
    return send(
      res,
      200,
      replayView(rp[1], upTo === null ? undefined : Number(upTo)),
    );
  }

  // The portfolio run (M2), off unless SIM_PORTFOLIO=1.
  if (p === "/sim/portfolio" || p.startsWith("/sim/portfolio/")) {
    if (!portfolioConfig.enabled)
      throw new HttpError(
        404,
        "the portfolio run is off; start the proxy with SIM_PORTFOLIO=1",
      );
    if (method === "POST" && p === "/sim/portfolio/start") {
      const dials = parsePortfolio(await readJson(req));
      const run = startPortfolio(dials, visitor(req).owner);
      return send(res, 200, await portfolioView(run.runId));
    }
    if (method === "GET" && p === "/sim/portfolio")
      return send(res, 200, { runs: listPortfolios() });
    const pm = p.match(/^\/sim\/portfolio\/(pf_[a-f0-9]{8})(\/stop)?$/);
    if (pm && method === "GET" && !pm[2])
      return send(res, 200, await portfolioView(pm[1]));
    if (pm && method === "POST" && pm[2]) {
      await stopPortfolio(pm[1]);
      return send(res, 200, await portfolioView(pm[1]));
    }
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
  if (config.contractTest) scheduleContractTest();
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
