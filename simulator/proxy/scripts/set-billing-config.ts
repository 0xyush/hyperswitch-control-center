// Operator script: sets the start rule and max retries on the story profile's billing connector
// (HS_BILLING_MCA_ID). It writes shared sandbox config, so it runs only by hand.
//   node scripts/set-billing-config.ts --start-rule 0 --max-retries 15           plan only
//   node scripts/set-billing-config.ts --start-rule 0 --max-retries 15 --apply  writes
// Every other Rev Rec setting on the connector (grace period, account references) is kept.
// It prints the old and new values, so the change can be undone with the old ones.
import {
  authStatus,
  refreshDashboardToken,
  revrecMerchantId,
} from "../src/auth.ts";
import { config } from "../src/config.ts";
import { hsDashboard } from "../src/upstream.ts";

const arg = (name: string) => {
  const i = process.argv.indexOf(name);
  return i > 0 ? Number(process.argv[i + 1]) : undefined;
};
const apply = process.argv.includes("--apply");
const startRule = arg("--start-rule");
const maxRetries = arg("--max-retries");

function fail(message: string): never {
  console.error(`set-billing-config: ${message}`);
  process.exit(1);
}

if (startRule === undefined && maxRetries === undefined)
  fail("give --start-rule N and/or --max-retries N");
for (const v of [startRule, maxRetries])
  if (v !== undefined && !(Number.isInteger(v) && v >= 0 && v <= 100))
    fail("values must be integers from 0 to 100");

await refreshDashboardToken();
if (!authStatus().ok) fail(`no dashboard token: ${authStatus().error}`);

const path = `v2/connector-accounts/${config.hsBillingMcaId}`;
const r = await hsDashboard("GET", path);
if (r?.status !== 200)
  fail(`could not read the billing connector (${r?.status})`);
const rr = r.json.feature_metadata?.revenue_recovery;
if (!rr) fail("the connector has no revenue_recovery settings");

const next = {
  ...rr,
  ...(startRule === undefined
    ? {}
    : { billing_connector_retry_threshold: startRule }),
  ...(maxRetries === undefined ? {} : { max_retry_count: maxRetries }),
};
const show = (x: any) =>
  `start rule ${x.billing_connector_retry_threshold}, max retries ${x.max_retry_count}, grace ${x.grace_period_days} days`;
console.log(
  `Billing connector ${config.hsBillingMcaId} (profile ${config.hsProfileId})`,
);
console.log(`  now:   ${show(rr)}`);
console.log(`  after: ${show(next)}`);
if (!apply) {
  console.log("Plan only. Add --apply to write it.");
  process.exit(0);
}
const u = await hsDashboard("PUT", path, {
  body: {
    connector_type: r.json.connector_type,
    merchant_id: revrecMerchantId(),
    feature_metadata: { revenue_recovery: next },
  },
});
if (u?.status !== 200)
  fail(
    `update refused (${u?.status}): ${JSON.stringify(u?.json?.error ?? u?.json).slice(0, 300)}`,
  );
const back = await hsDashboard("GET", path);
console.log(
  `  saved: ${show(back?.json?.feature_metadata?.revenue_recovery ?? {})}`,
);
