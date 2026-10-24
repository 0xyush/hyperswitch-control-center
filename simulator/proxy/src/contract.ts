// Hourly contract test (PRD §13). It checks that the sandbox still accepts the fields the billing
// simulator sends, and still returns the fields the proxy reads. It writes nothing: the
// POST /v2/recovery probe carries one unknown field, so the sandbox refuses it while parsing.
// The last result and any field drift show in /healthz under "contract".
import { config, PROFILES } from "./config.ts";
import { scrubText } from "./redact.ts";
import { contractTargets, sampleRecoveryBodies } from "./story.ts";
import { hsApiKey, hsDashboard, type Upstream } from "./upstream.ts";

const PROBE = "__sim_contract_probe";

// Request fields the sandbox accepts that the simulator does not send today. A new name outside
// this list is reported as drift (information, not a failure).
const KNOWN_UNSENT = [
  "billing",
  "customer_details",
  "enable_partial_authorization",
  "metadata",
];

// Response fields the proxy and the dashboard screens read. "[]" = the first item of a list.
const READ_FIELDS: Record<string, string[]> = {
  "invoice list": [
    "total_count",
    "data[].id",
    "data[].status",
    "data[].merchant_reference_id",
    "data[].merchant_id",
  ],
  "invoice detail": [
    "id",
    "status",
    "amount_details.order_amount",
    "amount_details.currency",
    "card_attached",
    "created_at",
    "feature_metadata.revenue_recovery.total_retry_count",
    "feature_metadata.revenue_recovery.first_payment_attempt_pg_error_code",
  ],
  attempts: [
    "payment_attempt_list[].id",
    "payment_attempt_list[].status",
    "payment_attempt_list[].created_at",
    "payment_attempt_list[].error",
    "payment_attempt_list[].connector_payment_id",
    "payment_attempt_list[].feature_metadata.revenue_recovery.attempt_triggered_by",
    "payment_attempt_list[].payment_method_data.card.last4",
  ],
  "process tracker": [
    "name",
    "status",
    "business_status",
    "schedule_time_for_payment",
  ],
  "billing connector": [
    "feature_metadata.revenue_recovery.billing_connector_retry_threshold",
    "feature_metadata.revenue_recovery.max_retry_count",
  ],
};

type Check = { name: string; ok: boolean; detail: string };
export type ContractResult = {
  ok: boolean;
  at: string;
  ms: number;
  checks: Check[];
  drift: {
    requestFieldsGone: string[]; // we send them; the sandbox no longer accepts them
    requestFieldsNew: string[]; // the sandbox accepts them; we do not know them
    requestFieldsNowRequired: string[]; // a nested field the sandbox now requires
    responseFieldsMissing: string[]; // we read them; the sandbox no longer returns them
  };
};

// True when the key at the path exists (its value may be null).
function hasPath(json: unknown, path: string): boolean | "empty list" {
  let cur: any = json;
  for (const part of path.split(".")) {
    const list = part.endsWith("[]");
    const key = list ? part.slice(0, -2) : part;
    if (cur === null || typeof cur !== "object" || !(key in cur)) return false;
    cur = cur[key];
    if (list) {
      if (!Array.isArray(cur)) return false;
      if (cur.length === 0) return "empty list";
      cur = cur[0];
    }
  }
  return true;
}

let last: ContractResult | null = null;
export const lastContract = () => last;

export async function runContractTest(): Promise<ContractResult> {
  const t0 = Date.now();
  const checks: Check[] = [];
  const drift: ContractResult["drift"] = {
    requestFieldsGone: [],
    requestFieldsNew: [],
    requestFieldsNowRequired: [],
    responseFieldsMissing: [],
  };
  const check = (name: string, ok: boolean, detail: string) =>
    checks.push({ name, ok, detail });
  const reads = (name: string, r: Upstream | null) => {
    if (!r || r.status !== 200) {
      check(name, false, r ? `HTTP ${r.status}` : "no dashboard token");
      return;
    }
    const missing: string[] = [];
    let empty = 0;
    for (const f of READ_FIELDS[name]) {
      const has = hasPath(r.json, f);
      if (has === "empty list") empty++;
      else if (!has) missing.push(f);
    }
    drift.responseFieldsMissing.push(...missing.map((f) => `${name}: ${f}`));
    check(
      name,
      missing.length === 0,
      missing.length
        ? `missing ${missing.join(", ")}`
        : `all ${READ_FIELDS[name].length - empty} fields present${empty ? ` (${empty} not checked: empty list)` : ""}`,
    );
  };

  // 1. The write path and its fields, without writing.
  const { failure, charged } = sampleRecoveryBodies();
  const sent = [...new Set([...Object.keys(failure), ...Object.keys(charged)])];
  for (const [kind, body] of [
    ["failure", failure],
    ["charged", charged],
  ] as const) {
    const r = await hsApiKey("POST", config.hsRecoveryPath, {
      ...body,
      [PROBE]: true,
    });
    const msg: string = r.json?.error?.message ?? "";
    const unknown = msg.match(
      /unknown field `[^`]+`, expected one of (.+?) at line/,
    );
    const missing = msg.match(/missing field `([^`]+)`/);
    if (r.status === 400 && unknown) {
      const accepted = [...unknown[1].matchAll(/`([^`]+)`/g)].map((m) => m[1]);
      const gone = sent.filter((f) => !accepted.includes(f));
      const fresh = accepted.filter(
        (f) => !sent.includes(f) && !KNOWN_UNSENT.includes(f),
      );
      drift.requestFieldsGone.push(
        ...gone.filter((f) => !drift.requestFieldsGone.includes(f)),
      );
      drift.requestFieldsNew.push(
        ...fresh.filter((f) => !drift.requestFieldsNew.includes(f)),
      );
      check(
        `POST /${config.hsRecoveryPath} (${kind} body)`,
        gone.length === 0,
        gone.length
          ? `no longer accepted: ${gone.join(", ")}`
          : `all ${Object.keys(body).length} fields accepted`,
      );
    } else if (r.status === 400 && missing) {
      drift.requestFieldsNowRequired.push(missing[1]);
      check(
        `POST /${config.hsRecoveryPath} (${kind} body)`,
        false,
        `the sandbox now requires ${missing[1]}`,
      );
    } else {
      check(
        `POST /${config.hsRecoveryPath} (${kind} body)`,
        false,
        `unexpected answer ${r.status}: ${msg.slice(0, 160) || "no message"}`,
      );
    }
  }

  // 2. The read paths, on the newest demo invoice.
  const profileId = PROFILES.story.profileId;
  const list = await hsApiKey(
    "GET",
    "v2/payments/recovery-list?limit=1",
    undefined,
    profileId,
  );
  reads("invoice list", list);
  const targets = contractTargets();
  const id: string | undefined = targets.any ?? list.json?.data?.[0]?.id;
  if (!id) {
    check("read-back invoice", false, "no invoice to read back");
  } else {
    const [detail, attempts] = await Promise.all([
      hsApiKey(
        "GET",
        `v2/payments/${id}/get-revenue-recovery-intent`,
        undefined,
        profileId,
      ),
      hsApiKey("GET", `v2/payments/${id}/list-attempts`, undefined, profileId),
    ]);
    reads("invoice detail", detail);
    reads("attempts", attempts);
    // An invoice in Monitoring has no task yet (404), so read the tracker of one with a booking.
    const taskId = targets.withTask ?? id;
    let pt = await hsDashboard(
      "GET",
      `v2/process-trackers/revenue-recovery-workflow/${taskId}`,
      { profileId },
    );
    if (pt?.status === 404)
      pt = await hsDashboard(
        "GET",
        `v2/process_tracker/revenue_recovery_workflow/${taskId}`,
        { profileId },
      );
    if (pt?.status === 404 && !targets.withTask)
      check(
        "process tracker",
        true,
        "not checked: no invoice with a booked retry yet",
      );
    else reads("process tracker", pt);
  }
  reads(
    "billing connector",
    await hsDashboard(
      "GET",
      `v2/connector-accounts/${PROFILES.story.billingMcaId}`,
      { profileId },
    ),
  );

  last = {
    ok: checks.every((c) => c.ok),
    at: new Date().toISOString(),
    ms: Date.now() - t0,
    checks,
    drift,
  };
  if (!last.ok)
    console.log(
      `contract test FAILED: ${checks
        .filter((c) => !c.ok)
        .map((c) => `${c.name}: ${c.detail}`)
        .join("; ")}`,
    );
  return last;
}

// First run shortly after start, then every hour.
export function scheduleContractTest(
  firstAfterMs = 20_000,
  everyMs = 3_600_000,
) {
  const run = () =>
    runContractTest().catch((e) => {
      last = {
        ok: false,
        at: new Date().toISOString(),
        ms: 0,
        checks: [
          {
            name: "contract test",
            ok: false,
            detail: scrubText(String((e as Error).message)),
          },
        ],
        drift: {
          requestFieldsGone: [],
          requestFieldsNew: [],
          requestFieldsNowRequired: [],
          responseFieldsMissing: [],
        },
      };
    });
  setTimeout(run, firstAfterMs).unref();
  setInterval(run, everyMs).unref();
}
