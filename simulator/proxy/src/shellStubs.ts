// Fixed answers for the dashboard "shell" reads (user, role, org, merchant and profile lists).
// The demo never exposes real user or merchant lists, so these come from the proxy, not the sandbox.
// Shapes follow what the control center reads (see simulator/NOTES.md, Builder B 14:40 entry).
import type { IncomingMessage, ServerResponse } from "node:http";
import { config } from "./config.ts";
import { revrecMerchantId } from "./auth.ts";

const ORG_ID = process.env.HS_ORG_ID || "org_zS11mfgp7UAPtCdunDYj";
const MERCHANT_NAME = "Revenue Recovery demo";
const PROFILE_NAME = "default";

function merchantId() {
  return revrecMerchantId() || config.hsRevrecMerchantId || "";
}

function stubFor(path: string): unknown | null {
  const p = path.replace(/^\/+/, "").split("?")[0];
  switch (p) {
    case "v2/users/merchant-details":
      return {
        merchant_id: merchantId(),
        merchant_name: MERCHANT_NAME,
        product_type: "recovery",
        merchant_account_type: "standard",
        version: "v2",
      };
    case "user/role/v2":
      return {
        groups: [
          "operations_view",
          "connectors_view",
          "workflows_view",
          "analytics_view",
          "merchant_details_view",
          "account_view",
          "users_view",
        ],
        resources: [
          "payment",
          "account",
          "connector",
          "analytics",
          "merchant_account",
          "revenue_recovery",
        ],
      };
    case "user/list/merchant":
    case "v2/user/list/merchant":
      return [
        {
          merchant_id: merchantId(),
          merchant_name: MERCHANT_NAME,
          product_type: "recovery",
          org_id: ORG_ID,
          version: "v2",
        },
      ];
    case "user/list/org":
      return [{ org_id: ORG_ID, org_name: "Rev Rec Simulator", org_type: "standard" }];
    case "v2/user/list/profile":
    case "user/list/profile":
      return [
        {
          profile_id: config.hsProfileId,
          profile_name: PROFILE_NAME,
          merchant_id: merchantId(),
          version: "v2",
        },
      ];
    case "user/data":
      return [];
    default:
      return null;
  }
}

/** Answers a shell read from a stub. Returns false when the path is not a shell read. */
export function serveShellStub(
  req: IncomingMessage,
  res: ServerResponse,
  url: URL,
): boolean {
  if ((req.method ?? "GET") !== "GET") return false;
  const path = url.pathname.replace(/^\/api\/?/, "");
  const body = stubFor(path);
  if (body === null) return false;
  res.writeHead(200, {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "X-Sim-Source": "stub",
  });
  res.end(JSON.stringify(body));
  return true;
}
