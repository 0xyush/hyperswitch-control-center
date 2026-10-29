// One shared password in front of everything (simulator/deploy/PASSWORD-GATE.md).
// On when SIM_PASSWORD is set. A right password sets the cookie sim_gate=<day>.<hmac of the day,
// keyed by the password>, valid 7 days. /healthz and /sim/health stay open; /api/* and /sim/* without the
// cookie answer 401 JSON; every other path shows the password page with 401.
import crypto from "node:crypto";
import type { IncomingMessage, ServerResponse } from "node:http";
import { config } from "./config.ts";
import { CONFIG_PATH } from "./dashboard.ts";

const COOKIE = "sim_gate";
const DAYS = 7;
const TRIES_PER_MINUTE = 10;

export const gateOn = () => Boolean(config.password);

const key = () =>
  crypto.createHash("sha256").update(`sim-gate|${config.password}`).digest();
const sign = (day: string) =>
  crypto.createHmac("sha256", key()).update(day).digest("base64url");
const today = () => new Date().toISOString().slice(0, 10);

function cookies(req: IncomingMessage): Record<string, string> {
  return Object.fromEntries(
    String(req.headers.cookie ?? "")
      .split(";")
      .map((c) => c.trim().split("="))
      .filter((kv) => kv.length >= 2)
      .map(([k, ...v]) => [k, v.join("=")]),
  );
}

const same = (a: string, b: string) => {
  const x = crypto.createHash("sha256").update(a).digest();
  const y = crypto.createHash("sha256").update(b).digest();
  return crypto.timingSafeEqual(x, y);
};

export function hasPass(req: IncomingMessage): boolean {
  const raw = cookies(req)[COOKIE];
  if (!raw) return false;
  const [day, mac] = raw.split(".");
  if (!day || !mac || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return false;
  const ageDays = (Date.parse(today()) - Date.parse(day)) / 86_400_000;
  if (!(ageDays >= 0 && ageDays < DAYS)) return false;
  return same(mac, sign(day));
}

// 10 tries per minute per IP.
const tries = new Map<string, number[]>();
function allowTry(ip: string) {
  const now = Date.now();
  const recent = (tries.get(ip) ?? []).filter((t) => now - t < 60_000);
  if (recent.length >= TRIES_PER_MINUTE) {
    tries.set(ip, recent);
    return false;
  }
  recent.push(now);
  tries.set(ip, recent);
  return true;
}

// Only a path on this site, so the form cannot send a visitor elsewhere.
const safeNext = (v: unknown) =>
  typeof v === "string" && v.startsWith("/") && !v.startsWith("//") ? v : "/";

const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

// The password page, in the dashboard's look: logo, one field, one button.
export function gatePage(logoSvg: string, message = "", next = "/") {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Rev Rec Simulator</title>
<style>
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#f6f7f9;
       font-family:"InterDisplay",Inter,system-ui,-apple-system,"Segoe UI",sans-serif;color:#151a1f}
  .card{background:#fff;border:1px solid #e6e8eb;border-radius:12px;padding:40px 36px;width:340px;
        box-shadow:0 8px 24px rgba(21,26,31,.06)}
  .logo{margin-bottom:28px}
  h1{font-size:20px;font-weight:600;margin:0 0 6px}
  p{font-size:14px;color:#5b6370;margin:0 0 24px;line-height:1.45}
  label{display:block;font-size:13px;font-weight:500;margin-bottom:6px}
  input{width:100%;box-sizing:border-box;height:40px;border:1px solid #cdd1d6;border-radius:8px;padding:0 12px;font-size:14px}
  input:focus{outline:none;border-color:#006df9;box-shadow:0 0 0 3px rgba(0,109,249,.15)}
  button{margin-top:16px;width:100%;height:40px;border:0;border-radius:8px;background:#006df9;color:#fff;font-size:14px;font-weight:600;cursor:pointer}
  button:hover{background:#0058c9}
  .err{color:#c62828;font-size:13px;margin-top:12px;min-height:16px}
</style></head>
<body><form class="card" method="post" action="/gate">
  <div class="logo">${logoSvg || "<strong>Hyperswitch</strong>"}</div>
  <h1>Revenue Recovery Simulator</h1>
  <p>Enter the shared password to open the demo.</p>
  <label for="password">Password</label>
  <input id="password" name="password" type="password" autocomplete="current-password" autofocus required>
  <input type="hidden" name="next" value="${esc(next)}">
  <button type="submit">Continue</button>
  <div class="err" role="alert">${esc(message)}</div>
</form></body></html>`;
}

function sendPage(res: ServerResponse, status: number, html: string) {
  res.writeHead(status, {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
  });
  res.end(html);
}

function readForm(req: IncomingMessage): Promise<Record<string, string>> {
  return new Promise((resolve) => {
    let body = "";
    req.on("data", (c: Buffer) => {
      body += c.toString("utf8");
      if (body.length > 4096) req.destroy();
    });
    req.on("end", () => {
      try {
        resolve(
          String(req.headers["content-type"]).includes("json")
            ? JSON.parse(body)
            : Object.fromEntries(new URLSearchParams(body)),
        );
      } catch {
        resolve({});
      }
    });
  });
}

// Handles /gate (the page and the form). Returns true when it answered the request.
export async function handleGate(
  req: IncomingMessage,
  res: ServerResponse,
  url: URL,
  ip: string,
  logoSvg: string,
): Promise<boolean> {
  if (url.pathname !== "/gate") return false;
  if (req.method !== "POST") {
    sendPage(
      res,
      200,
      gatePage(logoSvg, "", safeNext(url.searchParams.get("next"))),
    );
    return true;
  }
  if (!allowTry(ip)) {
    sendPage(
      res,
      429,
      gatePage(logoSvg, "Too many tries. Wait a minute, then try again."),
    );
    return true;
  }
  const form = await readForm(req);
  const next = safeNext(form.next);
  if (!same(String(form.password ?? ""), config.password)) {
    sendPage(res, 401, gatePage(logoSvg, "That password is not right.", next));
    return true;
  }
  const day = today();
  // Secure behind Cloud Run (HTTPS). Locally over http://localhost a Secure cookie would not stick.
  const secure = config.trustProxy ? "; Secure" : "";
  res.writeHead(303, {
    "Set-Cookie": `${COOKIE}=${day}.${sign(day)}; Path=/; Max-Age=${DAYS * 86_400}; HttpOnly; SameSite=Lax${secure}`,
    Location: next,
    "Cache-Control": "no-store",
  });
  res.end();
  return true;
}

// Without the cookie: 401 JSON for the APIs and the dashboard's config fetches, the password page
// for everything else.
export function refuse(res: ServerResponse, url: URL, logoSvg: string) {
  const p = url.pathname;
  if (
    p === "/api" ||
    p.startsWith("/api/") ||
    p.startsWith("/sim/") ||
    CONFIG_PATH.test(p)
  ) {
    res.writeHead(401, {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    });
    res.end(
      JSON.stringify({
        error: {
          code: "password_required",
          message: "Open the site and enter the shared password first.",
        },
      }),
    );
    return;
  }
  sendPage(res, 401, gatePage(logoSvg, "", safeNext(p + url.search)));
}
