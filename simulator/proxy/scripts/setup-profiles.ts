// Operator script: creates the two demo profiles for the portfolio run (simulator/PORTFOLIO.md §2).
// It writes shared sandbox config, so it runs only by hand, never from the public page.
//   node scripts/setup-profiles.ts           plan only: reads the existing connectors, prints the calls
//   node scripts/setup-profiles.ts --apply   creates the profiles and connectors
// For each profile it makes: a profile, its retry mode, a Stripe test payment connector and a
// Custom billing connector (start rule 0, max retries 15, grace 30 days), cloned from the existing
// pair. It prints the .env lines to add; it writes no file and never prints a secret.
// A profile whose HS_STATIC_PROFILE_ID or HS_SMART_PROFILE_ID is already set is skipped.
import { authStatus, refreshDashboardToken } from "../src/auth.ts";
import { config, PROFILES } from "../src/config.ts";
import { redact } from "../src/redact.ts";
import { hsDashboard } from "../src/upstream.ts";

const apply = process.argv.includes("--apply");

const TARGETS = [
  { key: "static", name: "sim-static", mode: "cascading", env: "HS_STATIC" },
  { key: "smart", name: "sim-smart", mode: "smart", env: "HS_SMART" },
] as const;

// The fields POST /v2/connector-accounts accepts that are worth copying. Webhook details, wallet
// details and additional merchant data are left out: they may hold masked secrets.
const COPY_FIELDS = [
  "connector_type",
  "connector_name",
  "payment_methods_enabled",
  "metadata",
  "status",
] as const;

function fail(message: string): never {
  console.error(`setup-profiles: ${message}`);
  process.exit(1);
}

async function call(
  step: string,
  method: string,
  path: string,
  profileId: string,
  body?: unknown,
) {
  console.log(
    `\n${apply ? "→" : "plan"} ${step}: ${method} /${path} (X-Profile-Id ${profileId})`,
  );
  if (body !== undefined) console.log(JSON.stringify(redact(body), null, 2));
  if (!apply) return null;
  const r = await hsDashboard(method, path, { profileId, body });
  if (!r) fail("no dashboard token for the Rev Rec merchant");
  console.log(
    `  ← ${r.status}${r.status >= 300 ? ` ${JSON.stringify(redact(r.json)).slice(0, 300)}` : ""}`,
  );
  if (r.status >= 300)
    fail(
      `${step} failed; stopping. Fix it and run again: finished profiles are skipped once their ids are in .env.`,
    );
  return r.json;
}

const pick = (src: any) =>
  Object.fromEntries(
    COPY_FIELDS.filter((f) => src[f] !== undefined).map((f) => [f, src[f]]),
  );

async function main() {
  await refreshDashboardToken();
  const auth = authStatus();
  if (!auth.ok) fail(`no dashboard token: ${auth.error}`);
  if (!config.stripeKey.startsWith("sk_test_"))
    fail("STRIPE_TEST_KEY must be a Stripe test key");
  console.log(
    `Merchant ${auth.revrecMerchantId}. Mode: ${apply ? "APPLY (writes sandbox config)" : "plan only"}.`,
  );

  // The existing pair is the template.
  const [billing, payment] = await Promise.all([
    hsDashboard("GET", `v2/connector-accounts/${config.hsBillingMcaId}`),
    hsDashboard("GET", `v2/connector-accounts/${config.hsPaymentMcaId}`),
  ]);
  if (billing?.status !== 200 || payment?.status !== 200)
    fail(
      `could not read the existing connectors (${billing?.status}, ${payment?.status})`,
    );
  const rrTemplate = billing.json.feature_metadata?.revenue_recovery ?? {};

  const envLines: string[] = [];
  for (const t of TARGETS) {
    if (process.env[`${t.env}_PROFILE_ID`]) {
      console.log(
        `\n${t.name}: ${t.env}_PROFILE_ID is set (${PROFILES[t.key].profileId}); skipped.`,
      );
      continue;
    }
    const profile = await call(
      `create profile ${t.name}`,
      "POST",
      "v2/profiles",
      config.hsProfileId,
      {
        profile_name: t.name,
      },
    );
    const profileId: string = profile?.id ?? `<new ${t.name} profile id>`;

    const pay = await call(
      `add Stripe payment connector to ${t.name}`,
      "POST",
      "v2/connector-accounts",
      profileId,
      {
        ...pick(payment.json),
        connector_label: `stripe_${t.name}`,
        profile_id: profileId,
        connector_account_details: {
          auth_type:
            payment.json.connector_account_details?.auth_type ?? "HeaderKey",
          api_key: config.stripeKey,
        },
      },
    );
    const payId: string = pay?.id ?? `<new ${t.name} payment connector id>`;

    const bill = await call(
      `add Custom billing connector to ${t.name}`,
      "POST",
      "v2/connector-accounts",
      profileId,
      {
        ...pick(billing.json),
        connector_label: `custom_billing_${t.name}`,
        profile_id: profileId,
        connector_account_details: { auth_type: "NoKey" },
        feature_metadata: {
          revenue_recovery: {
            ...rrTemplate,
            billing_connector_retry_threshold: 0,
            max_retry_count: 15,
            grace_period_days: 30,
            billing_account_reference: { [payId]: payId },
          },
        },
      },
    );
    const billId: string = bill?.id ?? `<new ${t.name} billing connector id>`;

    // The retry mode goes last: creating a billing connector puts its profile back into
    // monitoring (upstream core/admin.rs connector_create), which undid this step on 24 Oct.
    await call(
      `set retry mode ${t.mode}`,
      "PUT",
      `v2/profiles/${profileId}`,
      profileId,
      {
        revenue_recovery_retry_algorithm_type: t.mode,
      },
    );

    envLines.push(
      `${t.env}_PROFILE_ID=${profileId}`,
      `${t.env}_BILLING_MCA_ID=${billId}`,
      `${t.env}_PAYMENT_MCA_ID=${payId}`,
    );
  }

  if (envLines.length)
    console.log(
      `\n${apply ? "Add these lines" : "After --apply, add lines like these"} to simulator/proxy/.env, then restart the proxy:\n${envLines.join("\n")}`,
    );
}

await main();
