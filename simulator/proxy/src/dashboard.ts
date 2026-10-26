// Serves the dashboard build from the proxy, so the public link is one origin with one cookie
// (simulator/deploy/PASSWORD-GATE.md). On when DASHBOARD_DIST is set.
// - /config/feature, /config/merchant, /config/theme: the dashboard's own handlers
//   (src/server/config.mjs, theme.mjs), imported as they are, so the config.toml reading and the
//   default__<table>__<key> env overrides match its server (src/server/Server.res).
// - Files from <DASHBOARD_DIST>/hyperswitch, with a .br or .gz copy when the browser takes it.
// - Every other page path: index.html (so a refresh on /dashboard/v2/recovery/... works).
import fs from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { config } from "./config.ts";

export const dashboardOn = () => Boolean(config.dashboardDist);

const publicDir = () => path.join(config.dashboardDist, "hyperswitch");
const configToml = () =>
  path.join(config.dashboardDist, "server", "config", "config.toml");
const themeJson = () =>
  path.join(config.dashboardDist, "server", "config", "theme.json");

type Handler = (...args: unknown[]) => Promise<void>;
let handlers: { config: Handler; merchant: Handler; theme: Handler } | null =
  null;
async function loadHandlers() {
  if (handlers) return handlers;
  const dir = config.dashboardServerDir;
  const cfg = await import(pathToFileURL(path.join(dir, "config.mjs")).href);
  const theme = await import(pathToFileURL(path.join(dir, "theme.mjs")).href);
  handlers = {
    config: cfg.configHandler,
    merchant: cfg.merchantConfigHandler,
    theme: theme.themeConfigHandler,
  };
  return handlers;
}

// The Hyperswitch logo for the password page (the gate cannot load files behind itself).
export function logoSvg(): string {
  for (const dir of [
    publicDir(),
    path.join(config.dashboardDist, "..", "public", "hyperswitch"),
  ]) {
    try {
      return fs.readFileSync(
        path.join(dir, "assets", "Dark", "hyperswitchLogoIconWithText.svg"),
        "utf8",
      );
    } catch {
      // Try the next place.
    }
  }
  return "";
}

const TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".map": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".txt": "text/plain; charset=utf-8",
  ".wasm": "application/wasm",
};

const isFile = (p: string) => {
  try {
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
};

function sendFile(req: IncomingMessage, res: ServerResponse, file: string) {
  const accept = String(req.headers["accept-encoding"] ?? "");
  const variants: [string, string | null][] = [
    ...(accept.includes("br")
      ? ([[`${file}.br`, "br"]] as [string, string][])
      : []),
    ...(accept.includes("gzip")
      ? ([[`${file}.gz`, "gzip"]] as [string, string][])
      : []),
    [file, null],
  ];
  const [chosen, encoding] = variants.find(([f]) => isFile(f))!;
  const ext = path.extname(file).toLowerCase();
  res.writeHead(200, {
    "Content-Type": TYPES[ext] ?? "application/octet-stream",
    // As the dashboard's server: SVGs cached an hour, everything else revalidated.
    "Cache-Control":
      ext === ".svg" ? "max-age=3600, must-revalidate" : "no-cache",
    Vary: "Accept-Encoding",
    ...(encoding ? { "Content-Encoding": encoding } : {}),
  });
  if (req.method === "HEAD") return res.end();
  fs.createReadStream(chosen).pipe(res);
}

// Answers a dashboard path. Returns false when the path is not the dashboard's.
export async function serveDashboard(
  req: IncomingMessage,
  res: ServerResponse,
  url: URL,
): Promise<boolean> {
  // The same path clean-up as the dashboard's server.
  const p = url.pathname.replace(/^\/\//, "/").replace(/^\/v4\//, "/");
  const method = req.method ?? "GET";
  // The dashboard's server reads the tenant from ?domain= or x-tenant-id ("public" = default).
  const tenant = String(req.headers["x-tenant-id"] ?? "public");
  const domain =
    url.searchParams.get("domain") ||
    (tenant === "public" ? "default" : tenant);

  if (p.includes("/config/feature") && method === "GET") {
    await (await loadHandlers()).config(req, res, true, domain, configToml());
    return true;
  }
  if (p.includes("/config/merchant") && method === "POST") {
    await (await loadHandlers()).merchant(req, res, true, domain, configToml());
    return true;
  }
  if (p.includes("/config/theme") && method === "GET") {
    await (await loadHandlers()).theme(req, res, true, themeJson());
    return true;
  }
  if (method !== "GET" && method !== "HEAD") return false;

  const root = publicDir();
  const file = path.normalize(path.join(root, decodeURIComponent(p)));
  if (file.startsWith(root + path.sep) && isFile(file)) {
    sendFile(req, res, file);
    return true;
  }
  sendFile(req, res, path.join(root, "index.html"));
  return true;
}
