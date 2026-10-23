// Fixed answers for the dashboard shell's user and merchant reads.
// These are user endpoints. Passed through, they would show the real dashboard user and every
// merchant and profile in the org to a public visitor. The demo needs none of that, so the proxy
// answers with the demo merchant only. Shapes as tested by Builder B (simulator/NOTES.md, 14:40).
import { revrecMerchantId, revrecOrgId } from "./auth.ts";
import { config } from "./config.ts";

const MERCHANT_NAME = "Rev Rec demo";

const merchant = () => ({
  merchant_id: revrecMerchantId(),
  merchant_name: MERCHANT_NAME,
  product_type: "recovery",
  version: "v2",
});

type Stub = {
  name: string;
  pattern: RegExp;
  body: (path: string) => unknown | null;
};

export const SHELL_STUBS: Stub[] = [
  {
    name: "merchant details",
    pattern: /^v2\/users\/merchant-details$/,
    body: () => ({
      merchant_id: revrecMerchantId(),
      merchant_name: MERCHANT_NAME,
      product_type: "recovery",
      merchant_account_type: "standard",
    }),
  },
  {
    name: "merchant list",
    pattern: /^(v2\/)?user\/list\/merchant$/,
    body: () => [merchant()],
  },
  {
    // View-only groups: the demo can read Rev Rec pages but not change connectors or settings.
    name: "role and permissions",
    pattern: /^user\/role\/v2$/,
    body: () => ({
      groups: [
        "operations_view",
        "connectors_view",
        "workflows_view",
        "analytics_view",
        "merchant_details_view",
        "account_view",
      ],
      resources: ["payment", "account", "connector", "analytics"],
    }),
  },
  {
    name: "merchant account",
    pattern: /^v2\/merchant-accounts\/[A-Za-z0-9_-]{1,80}$/,
    // Only the demo merchant. Any other id falls through to the allow-list and gets 403.
    body: (path) =>
      path.endsWith(`/${revrecMerchantId()}`)
        ? {
            id: revrecMerchantId(),
            merchant_name: MERCHANT_NAME,
            product_type: "recovery",
          }
        : null,
  },
  {
    name: "org list",
    pattern: /^user\/list\/org$/,
    body: () => [{ org_id: revrecOrgId(), org_name: "Rev Rec simulator" }],
  },
  {
    name: "profile list",
    pattern: /^v2\/user\/list\/profile$/,
    body: () => [
      { profile_id: config.hsProfileId, profile_name: "Demo profile" },
    ],
  },
  {
    name: "user data",
    pattern: /^user\/data$/,
    body: () => ({}),
  },
];

// The fixed answer for a shell read, or null when the path is not a shell read.
export function shellStub(method: string, path: string): unknown | null {
  if (method !== "GET") return null;
  const clean = path.replace(/^\/+/, "");
  for (const s of SHELL_STUBS) {
    if (s.pattern.test(clean)) return s.body(clean);
  }
  return null;
}
