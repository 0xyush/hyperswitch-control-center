// /api/* pass-through for the dashboard. Only allow-listed Rev Rec reads reach the sandbox.
// Connector writes, API-key, user and every other endpoint get 403.
import type { IncomingMessage, ServerResponse } from "node:http";
import { config } from "./config.ts";
import { redact, scrubText } from "./redact.ts";
import { shellStub } from "./shell.ts";
import { hsApiKey, hsDashboard } from "./upstream.ts";

export type Rule = {
  name: string;
  method: "GET";
  pattern: RegExp;
  // True when the sandbox also accepts the merchant API key for this read.
  // Then the pass-through works before HS_DASHBOARD_JWT is set, or after it expires.
  apiKeyOk: boolean;
};

const ID = "[A-Za-z0-9_-]{1,80}";
const rx = (p: string) => new RegExp(`^${p.replaceAll("{id}", ID)}$`);

// Paths are matched without the leading "/api/". Method is GET only: the dashboard never writes.
export const RULES: Rule[] = [
  {
    name: "invoice list (merchant)",
    method: "GET",
    pattern: rx("v2/payments/recovery-list"),
    apiKeyOk: true,
  },
  {
    name: "invoice list (profile)",
    method: "GET",
    pattern: rx("v2/payments/profile/recovery-list"),
    apiKeyOk: false,
  },
  {
    name: "status counts (merchant)",
    method: "GET",
    pattern: rx("v2/payments/recovery-aggregate"),
    apiKeyOk: true,
  },
  {
    name: "status counts (profile)",
    method: "GET",
    pattern: rx("v2/payments/profile/recovery-aggregate"),
    apiKeyOk: false,
  },
  {
    name: "invoice filters",
    method: "GET",
    pattern: rx("v2/payments/profile/filter"),
    apiKeyOk: false,
  },
  {
    name: "invoice detail",
    method: "GET",
    pattern: rx("v2/payments/{id}/get-revenue-recovery-intent"),
    apiKeyOk: true,
  },
  {
    name: "invoice attempts",
    method: "GET",
    pattern: rx("v2/payments/{id}/list[_-]attempts"),
    apiKeyOk: true,
  },
  // The dashboard uses the underscore spelling; the API reference uses the hyphen one. Both exist.
  {
    name: "process tracker",
    method: "GET",
    pattern: rx("v2/process_tracker/revenue_recovery_workflow/{id}"),
    apiKeyOk: false,
  },
  {
    name: "process tracker",
    method: "GET",
    pattern: rx("v2/process-trackers/revenue-recovery-workflow/{id}"),
    apiKeyOk: false,
  },
  {
    name: "profile config",
    method: "GET",
    pattern: rx("v2/profiles/{id}"),
    apiKeyOk: false,
  },
  {
    name: "profile connectors",
    method: "GET",
    pattern: rx("v2/profiles/{id}/connector-accounts"),
    apiKeyOk: false,
  },
  {
    name: "connector config",
    method: "GET",
    pattern: rx("v2/connector-accounts/{id}"),
    apiKeyOk: false,
  },
];

// Encoded dots, slashes or backslashes could walk out of the allow-listed path.
const UNSAFE = /%2e|%2f|%5c|\\|\/\/|(^|\/)\.\.?(\/|$)/i;

export function matchRule(method: string, path: string): Rule | null {
  const clean = path.replace(/^\/+/, "");
  if (UNSAFE.test(clean)) return null;
  return (
    RULES.find((r) => r.method === method && r.pattern.test(clean)) ?? null
  );
}

// Recently blocked paths, so the dashboard builder can see what to ask for. Ids are masked.
const blocked = new Map<string, { count: number; last: string }>();
export function recentBlocked() {
  return [...blocked.entries()].map(([key, v]) => ({ request: key, ...v }));
}
function noteBlocked(method: string, path: string) {
  const key = `${method} ${path.replace(/[A-Za-z0-9]*_[A-Za-z0-9_]{12,}/g, "{id}")}`;
  const prev = blocked.get(key);
  blocked.set(key, {
    count: (prev?.count ?? 0) + 1,
    last: new Date().toISOString(),
  });
  if (blocked.size > 200) blocked.delete(blocked.keys().next().value!);
}

function sendJson(
  res: ServerResponse,
  status: number,
  body: unknown,
  extra: Record<string, string> = {},
) {
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    ...extra,
  });
  res.end(JSON.stringify(body));
}

export async function passThrough(
  req: IncomingMessage,
  res: ServerResponse,
  url: URL,
) {
  const path = url.pathname.replace(/^\/api\/?/, "");
  const method = req.method ?? "GET";
  const stub = UNSAFE.test(path) ? null : shellStub(method, path);
  if (stub !== null) return sendJson(res, 200, stub, { "x-sim-auth": "stub" });
  const rule = matchRule(method, path);
  if (!rule) {
    noteBlocked(method, path);
    // Same error shape as the sandbox, so the dashboard's fetch code reads it as usual.
    return sendJson(res, 403, {
      error: {
        type: "invalid_request",
        code: "SIM_BLOCKED",
        message: `The simulator proxy does not allow ${method} /${path}. Add it to simulator/proxy/src/passthrough.ts if the Rev Rec module needs it.`,
      },
    });
  }
  if (url.search.length > 2048)
    return sendJson(res, 414, {
      error: {
        type: "invalid_request",
        code: "SIM_QUERY",
        message: "query string too long",
      },
    });
  const target = path + url.search;

  try {
    let auth: "jwt" | "api-key" = "jwt";
    let r = await hsDashboard("GET", target);
    // Fall back to the API key when there is no JWT, or the JWT was refused, and the sandbox allows it.
    if ((!r || r.status === 401) && rule.apiKeyOk) {
      auth = "api-key";
      r = await hsApiKey("GET", target);
    }
    if (!r) {
      return sendJson(res, 503, {
        error: {
          type: "invalid_request",
          code: "SIM_NO_TOKEN",
          message: `"${rule.name}" needs a dashboard token for the Rev Rec merchant. See /healthz "dashboard".`,
        },
      });
    }
    return sendJson(res, r.status, redact(r.json), { "x-sim-auth": auth });
  } catch (e) {
    return sendJson(res, 502, {
      error: {
        type: "api",
        code: "SIM_UPSTREAM",
        message: `${config.engine === "sandbox" ? "sandbox" : "Rev Rec engine"} unreachable: ${scrubText(String((e as Error).message))}`,
      },
    });
  }
}
