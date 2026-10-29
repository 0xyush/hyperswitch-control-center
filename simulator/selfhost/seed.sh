#!/usr/bin/env bash
# Seeds the self-hosted Hyperswitch for the simulator (simulator/selfhost/README.md). Idempotent:
# ids go to $STATE_DIR/seed.env, and a second run keeps what still exists and makes only what is
# missing. Runs as the compose service "seed" (alpine + bash curl jq openssl), or anywhere with
# those tools and HS_BASE_URL pointing at the router.
#
# It makes, with the admin API key (v2 admin APIs):
#   organization -> merchant (product type recovery) -> profile
#   Stripe test payment connector (STRIPE_TEST_KEY) -> Custom billing connector
#     (start rule 0, max retries 15, grace 30 days; billing_account_reference -> the Stripe connector)
#   retry mode (cascading), set after the connectors: creating a billing connector puts the profile
#     back into monitoring (upstream core/admin.rs, seen on the sandbox on 24 Oct)
#   v2 API key for the proxy
#   fast retry ladder in the DB configs table (pt_mapping_pcr_retries, pt_mapping_adaptive_retries)
#   GSM rows that mark Stripe hard declines for Rev Rec
#   a dashboard token (JWT) for the proxy's JWT-only reads, signed with HS_JWT_SECRET
#   a smart profile (own connectors, retry mode smart) with Rev Rec's model on (A/B flag),
#     GSM soft-decline rows with standardised codes and the seeded retry stats (MODEL.md)
#   a decider profile (own connectors, retry mode smart, model flag off) for preset 9
#   a pool of profiles (own connectors, cascading, model flag on) for stories with live settings
# A v2-only router has no /user/signin or /user/signup (those are v1 routes), so no dashboard user
# can sign in. The router checks a JWT's signature, expiry, role and merchant/profile only, and
# merchant_admin is a built-in role, so a signed token works without a user row.
#
# Secrets are never printed. The proxy's .env lines go to $STATE_DIR/proxy.env (mode 600).
set -euo pipefail
umask 077

BASE="${HS_BASE_URL:-http://router:8080}"
BASE="${BASE%/}"
STATE_DIR="${STATE_DIR:-/state}"
STATE="$STATE_DIR/seed.env"
RETRY_MODE="${RETRY_MODE:-cascading}"
JWT_DAYS="${JWT_DAYS:-30}"
# start_after: seconds before Rev Rec's first charge; [gap, count]: seconds between later retries.
# Default: first charge after 3 s, then every 1 s, 15 times. With the 1 s reopen buffer in
# config.toml, a retry cycle is about 5 s, so 15 retries take about 75 s (27 Oct; it was [[5,15]]).
DEFAULT_LADDER='{"default_mapping":{"start_after":3,"frequencies":[[1,15]]}}'
LADDER_JSON="${LADDER_JSON:-$DEFAULT_LADDER}"

die() {
  echo "seed: $*" >&2
  exit 1
}
say() { echo "seed: $*"; }

for v in HS_ADMIN_API_KEY HS_JWT_SECRET STRIPE_TEST_KEY; do
  [ -n "${!v:-}" ] || die "set $v"
done
case "$STRIPE_TEST_KEY" in
sk_test_*) ;;
*) die "STRIPE_TEST_KEY must be a Stripe test key (sk_test_...)" ;;
esac
jq -e '.default_mapping.start_after and .default_mapping.frequencies' <<<"$LADDER_JSON" >/dev/null ||
  die "LADDER_JSON must look like {\"default_mapping\":{\"start_after\":3,\"frequencies\":[[5,15]]}}"

mkdir -p "$STATE_DIR"
# shellcheck disable=SC1090
[ -f "$STATE" ] && . "$STATE"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Secrets go to curl in header files, not on the command line.
printf 'Authorization: admin-api-key=%s\n' "$HS_ADMIN_API_KEY" >"$TMP/admin.h"

save() {
  local key=$1 val=$2
  printf -v "$key" '%s' "$val"
  touch "$STATE"
  grep -v "^$key=" "$STATE" >"$TMP/state" || true
  printf '%s=%s\n' "$key" "$val" >>"$TMP/state"
  cat "$TMP/state" >"$STATE"
}

# api METHOD PATH [BODY] [HEADER...]: sets CODE and BODY. Uses the admin key unless AUTH_FILE is set.
api() {
  local method=$1 path=$2 body=${3:-}
  shift 2
  [ $# -gt 0 ] && shift
  local args=(-sS -o "$TMP/out" -w '%{http_code}' -X "$method" "$BASE/$path"
    -H "@${AUTH_FILE:-$TMP/admin.h}" -H 'Content-Type: application/json')
  local h
  for h in "$@"; do args+=(-H "$h"); done
  [ -n "$body" ] && args+=(--data-binary "$body")
  CODE=$(curl "${args[@]}") || CODE=000
  BODY=$(cat "$TMP/out" 2>/dev/null || true)
}

expect() { # expect STEP: stops unless the last call answered 200
  [ "$CODE" = 200 ] || die "$1 failed: HTTP $CODE $(head -c 400 <<<"$BODY")"
}

MH() { echo "X-Merchant-Id: $MERCHANT_ID"; }
PH() { echo "X-Profile-Id: $PROFILE_ID"; }

# 0. Wait for the router.
for _ in $(seq 1 60); do
  api GET v2/health
  [ "$CODE" = 200 ] && break
  sleep 2
done
[ "$CODE" = 200 ] || die "router at $BASE is not healthy (HTTP $CODE)"
say "router $BASE is up"

# 1. Organization.
api GET "v2/organizations/${ORG_ID:-none}"
if [ -n "${ORG_ID:-}" ] && [ "$CODE" = 200 ]; then
  say "organization $ORG_ID (kept)"
else
  api POST v2/organizations "$(jq -cn '{organization_name: "revrec-sim"}')"
  expect "create organization"
  save ORG_ID "$(jq -r '.id' <<<"$BODY")"
  say "organization $ORG_ID (new)"
fi

# 2. Merchant.
api GET "v2/merchant-accounts/${MERCHANT_ID:-none}"
if [ -n "${MERCHANT_ID:-}" ] && [ "$CODE" = 200 ]; then
  say "merchant $MERCHANT_ID (kept)"
else
  api POST v2/merchant-accounts \
    "$(jq -cn '{merchant_name: "revrec_sim", product_type: "recovery"}')" \
    "X-Organization-Id: $ORG_ID"
  expect "create merchant"
  save MERCHANT_ID "$(jq -r '.id' <<<"$BODY")"
  # A new merchant: the old profile and connectors belong to the old one.
  unset PROFILE_ID PAYMENT_MCA_ID BILLING_MCA_ID API_KEY_ID API_KEY
  say "merchant $MERCHANT_ID (new)"
fi

# 3. Profile.
api GET "v2/profiles/${PROFILE_ID:-none}" "" "$(MH)"
if [ -n "${PROFILE_ID:-}" ] && [ "$CODE" = 200 ]; then
  say "profile $PROFILE_ID (kept)"
else
  api POST v2/profiles "$(jq -cn '{profile_name: "default"}')" "$(MH)"
  expect "create profile"
  save PROFILE_ID "$(jq -r '.id' <<<"$BODY")"
  unset PAYMENT_MCA_ID BILLING_MCA_ID
  say "profile $PROFILE_ID (new)"
fi

# 4. Stripe test payment connector. Cards on every network, as the sandbox's stripe_revrec.
api GET "v2/connector-accounts/${PAYMENT_MCA_ID:-none}" "" "$(MH)" "$(PH)"
if [ -n "${PAYMENT_MCA_ID:-}" ] && [ "$CODE" = 200 ]; then
  say "Stripe payment connector $PAYMENT_MCA_ID (kept)"
else
  printf '%s' "$STRIPE_TEST_KEY" >"$TMP/stripe"
  body=$(jq -cn --arg profile "$PROFILE_ID" --rawfile key "$TMP/stripe" '
    def card(sub): {payment_method_subtype: sub, card_networks:
      ["Visa", "Mastercard", "AmericanExpress", "Discover", "JCB", "DinersClub", "Interac"],
      minimum_amount: 0, maximum_amount: 68607706, recurring_enabled: true,
      installment_payment_enabled: true};
    {connector_type: "payment_processor", connector_name: "stripe",
     connector_label: "stripe_revrec", profile_id: $profile, status: "active",
     connector_account_details: {auth_type: "HeaderKey", api_key: $key},
     payment_methods_enabled: [{payment_method_type: "card",
       payment_method_subtypes: [card("credit"), card("debit")]}]}')
  api POST v2/connector-accounts "$body" "$(MH)" "$(PH)"
  unset body
  expect "create Stripe payment connector"
  save PAYMENT_MCA_ID "$(jq -r '.id' <<<"$BODY")"
  unset BILLING_MCA_ID
  say "Stripe payment connector $PAYMENT_MCA_ID (new)"
fi

# 5. Custom billing connector: start rule 0, max retries 15, grace 30 days.
api GET "v2/connector-accounts/${BILLING_MCA_ID:-none}" "" "$(MH)" "$(PH)"
if [ -n "${BILLING_MCA_ID:-}" ] && [ "$CODE" = 200 ]; then
  say "Custom billing connector $BILLING_MCA_ID (kept)"
else
  api POST v2/connector-accounts "$(jq -cn --arg profile "$PROFILE_ID" --arg pay "$PAYMENT_MCA_ID" '
    {connector_type: "billing_processor", connector_name: "custombilling",
     connector_label: "custombilling_default", profile_id: $profile, status: "active",
     connector_account_details: {auth_type: "NoKey"},
     feature_metadata: {revenue_recovery: {billing_connector_retry_threshold: 0,
       max_retry_count: 15, grace_period_days: 30,
       billing_account_reference: {($pay): $pay}}}}')" "$(MH)" "$(PH)"
  expect "create Custom billing connector"
  save BILLING_MCA_ID "$(jq -r '.id' <<<"$BODY")"
  say "Custom billing connector $BILLING_MCA_ID (new)"
fi

# 6. Retry mode, after the connectors.
api PUT "v2/profiles/$PROFILE_ID" \
  "$(jq -cn --arg mode "$RETRY_MODE" '{revenue_recovery_retry_algorithm_type: $mode}')" "$(MH)" "$(PH)"
expect "set retry mode"
[ "$(jq -r '.revenue_recovery_retry_algorithm_type' <<<"$BODY")" = "$RETRY_MODE" ] ||
  die "retry mode reads back as $(jq -r '.revenue_recovery_retry_algorithm_type' <<<"$BODY")"
say "retry mode $RETRY_MODE"

# 6b. Smart profile for the portfolio's smart side (simulator/selfhost/MODEL.md): its own Stripe and
# Custom billing connectors with the default profile's rules, and retry mode smart. The retry time
# comes from Rev Rec's own model in the engine, turned on for this profile only (8b).
SPH() { echo "X-Profile-Id: $SMART_PROFILE_ID"; }
api GET "v2/profiles/${SMART_PROFILE_ID:-none}" "" "$(MH)"
if [ -n "${SMART_PROFILE_ID:-}" ] && [ "$CODE" = 200 ]; then
  say "smart profile $SMART_PROFILE_ID (kept)"
else
  api POST v2/profiles "$(jq -cn '{profile_name: "smart"}')" "$(MH)"
  expect "create smart profile"
  save SMART_PROFILE_ID "$(jq -r '.id' <<<"$BODY")"
  unset SMART_PAYMENT_MCA_ID SMART_BILLING_MCA_ID
  say "smart profile $SMART_PROFILE_ID (new)"
fi
api GET "v2/connector-accounts/${SMART_PAYMENT_MCA_ID:-none}" "" "$(MH)" "$(SPH)"
if [ -n "${SMART_PAYMENT_MCA_ID:-}" ] && [ "$CODE" = 200 ]; then
  say "smart Stripe payment connector $SMART_PAYMENT_MCA_ID (kept)"
else
  printf '%s' "$STRIPE_TEST_KEY" >"$TMP/stripe"
  body=$(jq -cn --arg profile "$SMART_PROFILE_ID" --rawfile key "$TMP/stripe" '
    def card(sub): {payment_method_subtype: sub, card_networks:
      ["Visa", "Mastercard", "AmericanExpress", "Discover", "JCB", "DinersClub", "Interac"],
      minimum_amount: 0, maximum_amount: 68607706, recurring_enabled: true,
      installment_payment_enabled: true};
    {connector_type: "payment_processor", connector_name: "stripe",
     connector_label: "stripe_revrec_smart", profile_id: $profile, status: "active",
     connector_account_details: {auth_type: "HeaderKey", api_key: $key},
     payment_methods_enabled: [{payment_method_type: "card",
       payment_method_subtypes: [card("credit"), card("debit")]}]}')
  api POST v2/connector-accounts "$body" "$(MH)" "$(SPH)"
  unset body
  expect "create smart Stripe payment connector"
  save SMART_PAYMENT_MCA_ID "$(jq -r '.id' <<<"$BODY")"
  unset SMART_BILLING_MCA_ID
  say "smart Stripe payment connector $SMART_PAYMENT_MCA_ID (new)"
fi
api GET "v2/connector-accounts/${SMART_BILLING_MCA_ID:-none}" "" "$(MH)" "$(SPH)"
if [ -n "${SMART_BILLING_MCA_ID:-}" ] && [ "$CODE" = 200 ]; then
  say "smart Custom billing connector $SMART_BILLING_MCA_ID (kept)"
else
  api POST v2/connector-accounts "$(jq -cn --arg profile "$SMART_PROFILE_ID" --arg pay "$SMART_PAYMENT_MCA_ID" '
    {connector_type: "billing_processor", connector_name: "custombilling",
     connector_label: "custombilling_smart", profile_id: $profile, status: "active",
     connector_account_details: {auth_type: "NoKey"},
     feature_metadata: {revenue_recovery: {billing_connector_retry_threshold: 0,
       max_retry_count: 15, grace_period_days: 30,
       billing_account_reference: {($pay): $pay}}}}')" "$(MH)" "$(SPH)"
  expect "create smart Custom billing connector"
  save SMART_BILLING_MCA_ID "$(jq -r '.id' <<<"$BODY")"
  say "smart Custom billing connector $SMART_BILLING_MCA_ID (new)"
fi
api PUT "v2/profiles/$SMART_PROFILE_ID" \
  "$(jq -cn '{revenue_recovery_retry_algorithm_type: "smart"}')" "$(MH)" "$(SPH)"
expect "set the smart profile's retry mode"
[ "$(jq -r '.revenue_recovery_retry_algorithm_type' <<<"$BODY")" = smart ] ||
  die "smart profile's retry mode reads back as $(jq -r '.revenue_recovery_retry_algorithm_type' <<<"$BODY")"
say "smart profile retry mode smart"

# 6c. Decider profile (sim-smart-decider) for preset 9, the customer's second saved card: its own
# Stripe and Custom billing connectors with the default profile's rules, and retry mode smart WITHOUT
# the model flag. Then the engine chooses among the customer's saved cards, and for a card whose last
# charge failed it asks the stand-in decider (docker-compose.yml "decider") for the retry time.
# Creating the billing connector puts the profile in monitoring (600 s), so the retry mode is set
# right after it, on every run.
DPH() { echo "X-Profile-Id: $DECIDER_PROFILE_ID"; }
api GET "v2/profiles/${DECIDER_PROFILE_ID:-none}" "" "$(MH)"
if [ -n "${DECIDER_PROFILE_ID:-}" ] && [ "$CODE" = 200 ]; then
  say "decider profile $DECIDER_PROFILE_ID (kept)"
else
  api POST v2/profiles "$(jq -cn '{profile_name: "sim-smart-decider"}')" "$(MH)"
  expect "create decider profile"
  save DECIDER_PROFILE_ID "$(jq -r '.id' <<<"$BODY")"
  unset DECIDER_PAYMENT_MCA_ID DECIDER_BILLING_MCA_ID
  say "decider profile $DECIDER_PROFILE_ID (new)"
fi
api GET "v2/connector-accounts/${DECIDER_PAYMENT_MCA_ID:-none}" "" "$(MH)" "$(DPH)"
if [ -n "${DECIDER_PAYMENT_MCA_ID:-}" ] && [ "$CODE" = 200 ]; then
  say "decider Stripe payment connector $DECIDER_PAYMENT_MCA_ID (kept)"
else
  printf '%s' "$STRIPE_TEST_KEY" >"$TMP/stripe"
  body=$(jq -cn --arg profile "$DECIDER_PROFILE_ID" --rawfile key "$TMP/stripe" '
    def card(sub): {payment_method_subtype: sub, card_networks:
      ["Visa", "Mastercard", "AmericanExpress", "Discover", "JCB", "DinersClub", "Interac"],
      minimum_amount: 0, maximum_amount: 68607706, recurring_enabled: true,
      installment_payment_enabled: true};
    {connector_type: "payment_processor", connector_name: "stripe",
     connector_label: "stripe_revrec_decider", profile_id: $profile, status: "active",
     connector_account_details: {auth_type: "HeaderKey", api_key: $key},
     payment_methods_enabled: [{payment_method_type: "card",
       payment_method_subtypes: [card("credit"), card("debit")]}]}')
  api POST v2/connector-accounts "$body" "$(MH)" "$(DPH)"
  unset body
  expect "create decider Stripe payment connector"
  save DECIDER_PAYMENT_MCA_ID "$(jq -r '.id' <<<"$BODY")"
  unset DECIDER_BILLING_MCA_ID
  say "decider Stripe payment connector $DECIDER_PAYMENT_MCA_ID (new)"
fi
api GET "v2/connector-accounts/${DECIDER_BILLING_MCA_ID:-none}" "" "$(MH)" "$(DPH)"
if [ -n "${DECIDER_BILLING_MCA_ID:-}" ] && [ "$CODE" = 200 ]; then
  say "decider Custom billing connector $DECIDER_BILLING_MCA_ID (kept)"
else
  api POST v2/connector-accounts "$(jq -cn --arg profile "$DECIDER_PROFILE_ID" --arg pay "$DECIDER_PAYMENT_MCA_ID" '
    {connector_type: "billing_processor", connector_name: "custombilling",
     connector_label: "custombilling_decider", profile_id: $profile, status: "active",
     connector_account_details: {auth_type: "NoKey"},
     feature_metadata: {revenue_recovery: {billing_connector_retry_threshold: 0,
       max_retry_count: 15, grace_period_days: 30,
       billing_account_reference: {($pay): $pay}}}}')" "$(MH)" "$(DPH)"
  expect "create decider Custom billing connector"
  save DECIDER_BILLING_MCA_ID "$(jq -r '.id' <<<"$BODY")"
  say "decider Custom billing connector $DECIDER_BILLING_MCA_ID (new)"
fi
api PUT "v2/profiles/$DECIDER_PROFILE_ID" \
  "$(jq -cn '{revenue_recovery_retry_algorithm_type: "smart"}')" "$(MH)" "$(DPH)"
expect "set the decider profile's retry mode"
[ "$(jq -r '.revenue_recovery_retry_algorithm_type' <<<"$BODY")" = smart ] ||
  die "decider profile's retry mode reads back as $(jq -r '.revenue_recovery_retry_algorithm_type' <<<"$BODY")"
# With the model flag (8b) or the merchant-wide adaptive flag on, the engine retries only the
# invoice's own card and never asks the decider. Both default to off; stop if either is on.
for key in "revenue_recovery_ab_enabled_$DECIDER_PROFILE_ID" "${MERCHANT_ID}_adaptive_retry_enabled"; do
  api GET "v2/configs/$key"
  [ "$CODE" != 200 ] || [ "$(jq -r '.value' <<<"$BODY")" != true ] ||
    die "config $key is on; the decider profile needs it off"
done
say "decider profile retry mode smart (model flag off)"

# 7. v2 API key for the proxy. Its value is shown once, so it is kept in the state file.
api GET "v2/api-keys/${API_KEY_ID:-none}" "" "$(MH)"
if [ -n "${API_KEY_ID:-}" ] && [ -n "${API_KEY:-}" ] && [ "$CODE" = 200 ]; then
  say "API key $API_KEY_ID (kept)"
else
  api POST v2/api-keys "$(jq -cn '{name: "revrec-sim-proxy", description: "simulator proxy", expiration: "never"}')" "$(MH)"
  expect "create API key"
  save API_KEY_ID "$(jq -r '.key_id' <<<"$BODY")"
  save API_KEY "$(jq -r '.api_key' <<<"$BODY")"
  BODY=""
  say "API key $API_KEY_ID (new)"
fi

# 8. Fast retry ladder in the DB configs table (prepare.sh took it out of the Superposition seed).
for key in pt_mapping_pcr_retries pt_mapping_adaptive_retries; do
  api POST v2/configs/ "$(jq -cn --arg k "$key" --arg v "$LADDER_JSON" '{key: $k, value: $v}')"
  if [ "$CODE" != 200 ]; then
    api POST "v2/configs/$key" "$(jq -cn --arg v "$LADDER_JSON" '{value: $v}')"
    expect "update config $key"
  fi
  api GET "v2/configs/$key"
  expect "read config $key"
  jq -e --argjson want "$LADDER_JSON" '(.value | fromjson) == $want' <<<"$BODY" >/dev/null ||
    die "config $key reads back as $(jq -c '.value' <<<"$BODY")"
done
say "retry ladder $(jq -c '.default_mapping' <<<"$LADDER_JSON")"

# 8b. Rev Rec's model for the smart profile only: the per-profile A/B flag (MODEL.md). The invoice
# gets the default arm SystematicKMaxAtScore, whose time stands (static ladder on standby). The
# merchant-wide adaptive_retry_enabled flag is not used: its ladder "ceiling" would always win.
config_set() { # config_set KEY VALUE: writes a DB config and reads it back
  api POST v2/configs/ "$(jq -cn --arg k "$1" --arg v "$2" '{key: $k, value: $v}')"
  if [ "$CODE" != 200 ]; then
    api POST "v2/configs/$1" "$(jq -cn --arg v "$2" '{value: $v}')"
    expect "update config $1"
  fi
  api GET "v2/configs/$1"
  expect "read config $1"
  [ "$(jq -r '.value' <<<"$BODY")" = "$2" ] || die "config $1 reads back as $(jq -c '.value' <<<"$BODY")"
}
config_set "revenue_recovery_ab_enabled_$SMART_PROFILE_ID" true
say "Rev Rec model on for the smart profile (revenue_recovery_ab_enabled_$SMART_PROFILE_ID)"

# 8c. Seeded retry stats (MODEL.md: seeded counts, not Juspay's production data), loaded once with the
# engine's admin route. A rerun keeps what the engine has learned since; RESEED_RETRY_STATS=1 loads
# the seed again.
STATS_CSV="${STATS_CSV:-/model/retry-stats.csv}"
if [ "${RETRY_STATS_SEEDED:-}" = 1 ] && [ "${RESEED_RETRY_STATS:-0}" != 1 ]; then
  say "retry stats (kept; RESEED_RETRY_STATS=1 loads the seed again)"
else
  [ -f "$STATS_CSV" ] || die "no $STATS_CSV (docker-compose.yml mounts ./model at /model)"
  CODE=$(curl -sS -o "$TMP/out" -w '%{http_code}' -X POST "$BASE/v2/recovery/data-backfill/retry-stats" \
    -H "@$TMP/admin.h" -F "file=@$STATS_CSV;type=text/csv") || CODE=000
  BODY=$(cat "$TMP/out" 2>/dev/null || true)
  expect "upload retry stats"
  ROWS=$(($(wc -l <"$STATS_CSV") - 1))
  jq -e --argjson rows "$ROWS" '.failed_records == 0 and .processed_records == $rows' <<<"$BODY" >/dev/null ||
    die "retry stats upload: $(head -c 400 <<<"$BODY")"
  save RETRY_STATS_SEEDED 1
  say "retry stats seeded: $ROWS clusters (insufficient funds, do not honor, velocity limit; processing errors use the ladder)"
fi

# 8d. Profile pool for stories with live settings: the proxy leases one profile per story and resets
# it after (proxy/src/pool.ts). POOL_SIZE profiles (default 6), each with its own Stripe and Custom
# billing connectors, retry mode cascading set right after the billing connector (a new billing
# connector puts the profile into monitoring), and the model flag on, so a switch to smart runs Rev
# Rec's model. The sim service plans model retries for them too (POOL_PROFILE_IDS in seed.env).
POOL_SIZE="${POOL_SIZE:-6}"
pool_profile() { # pool_profile K: makes or keeps pool profile K, then sets POOL_LINE
  local k=$1
  local pv="POOL_${k}_PROFILE_ID" payv="POOL_${k}_PAYMENT_MCA_ID" billv="POOL_${k}_BILLING_MCA_ID"
  local pid=${!pv:-} pay=${!payv:-} bill=${!billv:-}
  api GET "v2/profiles/${pid:-none}" "" "$(MH)"
  if [ -z "$pid" ] || [ "$CODE" != 200 ]; then
    api POST v2/profiles "$(jq -cn --arg n "sim-pool-$k" '{profile_name: $n}')" "$(MH)"
    expect "create pool profile $k"
    pid=$(jq -r '.id' <<<"$BODY")
    save "$pv" "$pid"
    pay="" bill=""
  fi
  local ph="X-Profile-Id: $pid"
  api GET "v2/connector-accounts/${pay:-none}" "" "$(MH)" "$ph"
  if [ -z "$pay" ] || [ "$CODE" != 200 ]; then
    printf '%s' "$STRIPE_TEST_KEY" >"$TMP/stripe"
    body=$(jq -cn --arg profile "$pid" --arg label "stripe_revrec_pool_$k" --rawfile key "$TMP/stripe" '
      def card(sub): {payment_method_subtype: sub, card_networks:
        ["Visa", "Mastercard", "AmericanExpress", "Discover", "JCB", "DinersClub", "Interac"],
        minimum_amount: 0, maximum_amount: 68607706, recurring_enabled: true,
        installment_payment_enabled: true};
      {connector_type: "payment_processor", connector_name: "stripe",
       connector_label: $label, profile_id: $profile, status: "active",
       connector_account_details: {auth_type: "HeaderKey", api_key: $key},
       payment_methods_enabled: [{payment_method_type: "card",
         payment_method_subtypes: [card("credit"), card("debit")]}]}')
    api POST v2/connector-accounts "$body" "$(MH)" "$ph"
    unset body
    expect "create pool $k Stripe payment connector"
    pay=$(jq -r '.id' <<<"$BODY")
    save "$payv" "$pay"
    bill=""
  fi
  api GET "v2/connector-accounts/${bill:-none}" "" "$(MH)" "$ph"
  if [ -z "$bill" ] || [ "$CODE" != 200 ]; then
    api POST v2/connector-accounts "$(jq -cn --arg profile "$pid" --arg pay "$pay" --arg label "custombilling_pool_$k" '
      {connector_type: "billing_processor", connector_name: "custombilling",
       connector_label: $label, profile_id: $profile, status: "active",
       connector_account_details: {auth_type: "NoKey"},
       feature_metadata: {revenue_recovery: {billing_connector_retry_threshold: 0,
         max_retry_count: 15, grace_period_days: 30,
         billing_account_reference: {($pay): $pay}}}}')" "$(MH)" "$ph"
    expect "create pool $k Custom billing connector"
    bill=$(jq -r '.id' <<<"$BODY")
    save "$billv" "$bill"
  fi
  api PUT "v2/profiles/$pid" "$(jq -cn '{revenue_recovery_retry_algorithm_type: "cascading"}')" "$(MH)" "$ph"
  expect "set pool profile $k's retry mode"
  config_set "revenue_recovery_ab_enabled_$pid" true
  POOL_LINE="$pid:$bill:$pay"
}
POOL="" POOL_IDS=""
for k in $(seq 1 "$POOL_SIZE"); do
  pool_profile "$k"
  POOL="$POOL${POOL:+,}$POOL_LINE"
  POOL_IDS="$POOL_IDS${POOL_IDS:+,}${POOL_LINE%%:*}"
done
save POOL_PROFILE_IDS "$POOL_IDS"
say "profile pool: $POOL_SIZE profiles ($POOL_IDS), cascading, model flag on"

# 9. GSM rows: hard declines stop Rev Rec at once (Stripe, and the stolen card of the scripted bank
# on Adyen and Worldpay). Every lookup matches the connector, flow "revenue_recovery", sub_flow
# "sub_flow", code and message exactly. Three lookups use them:
# - The reported failure (core/webhooks/recovery_incoming.rs, store_payment_processor_tokens_in_redis)
#   uses the code and message the billing system sent, and marks the reported card's token as a hard
#   decline. When every token of the customer is a hard decline, Rev Rec ends the retry work with no
#   charge. The simulator reports the message as "message - <message>, decline_code - <code>"
#   (proxy src/story.ts reportedError), because Stripe's plain message is the same for a stolen card
#   and a generic decline.
# - Rev Rec's own Stripe charge (workflows/revenue_recovery.rs check_hard_decline) uses the error
#   reason for Stripe, in the same form (connectors/stripe.rs). So the first two rows serve both.
# - The retry scheduler (core/revenue_recovery/types.rs) uses the plain message: the third row.
#   A stolen card has no plain-message row: "Your card was declined." would stop generic declines.
# - Adyen and Worldpay: every lookup uses the plain message, so one row serves all three.
gsm_row() { # connector code message description
  jq -cn --arg connector "$1" --arg code "$2" --arg message "$3" --arg description "$4" '
    {connector: $connector, flow: "revenue_recovery", sub_flow: "sub_flow", code: $code,
     message: $message, status: "failure", decision: "do_default", step_up_possible: false,
     clear_pan_possible: false, error_category: "hard_decline", description: $description}'
}
while IFS='|' read -r connector code message description; do
  row=$(gsm_row "$connector" "$code" "$message" "$description")
  api POST v2/gsm "$row"
  if [ "$CODE" != 200 ]; then
    api POST v2/gsm/update "$row"
    expect "update GSM row $connector $code / $message"
  fi
  say "GSM hard decline: $connector $code / $message"
done <<'ROWS'
stripe|card_declined|message - Your card was declined., decline_code - stolen_card|Stripe stolen card: Rev Rec stops (selfhost)
stripe|expired_card|message - Your card has expired., decline_code - expired_card|Stripe expired card: Rev Rec stops (selfhost)
stripe|expired_card|Your card has expired.|Stripe expired card: Rev Rec stops (selfhost)
adyen|5|Blocked Card|Adyen blocked card (the scripted bank's stolen card): Rev Rec stops (selfhost bank)
worldpay|43|STOLEN CARD, PICK UP|Worldpay stolen card (the scripted bank's): Rev Rec stops (selfhost bank)
ROWS

# 9b. GSM rows that give Rev Rec's own failed charge its standardised error code, which the model
# looks its stats up by (MODEL.md). The payments core matches the connector, flow "Payment", the
# operation ("Authorize"), and the processor's code and message exactly (core/payments/operations/
# payment_response.rs). Soft declines: Rev Rec keeps retrying. Adyen's code and message are its
# refusalReasonCode and refusalReason; the scripted bank picks them by holder name (sim/bank.mjs).
gsm_soft_row() { # connector code message standardised_code description
  jq -cn --arg connector "$1" --arg code "$2" --arg message "$3" --arg std "$4" --arg description "$5" '
    {connector: $connector, flow: "Payment", sub_flow: "Authorize", code: $code, message: $message,
     status: "failure", decision: "do_default", step_up_possible: false, clear_pan_possible: false,
     error_category: "soft_decline", standardised_code: $std, description: $description}'
}
while IFS='|' read -r connector code message std description; do
  row=$(gsm_soft_row "$connector" "$code" "$message" "$std" "$description")
  api POST v2/gsm "$row"
  if [ "$CODE" != 200 ]; then
    api POST v2/gsm/update "$row"
    expect "update GSM row $connector $code / $message"
  fi
  say "GSM soft decline: $connector $code / $message -> $std"
done <<'ROWS'
stripe|card_declined|Your card has insufficient funds. Use a different payment method to complete this purchase.|insufficient_funds|Stripe insufficient funds (selfhost model)
stripe|card_declined|Your card was declined.|do_not_honor|Stripe generic decline (selfhost model)
stripe|processing_error|The card couldn't be processed. Try the payment again. If it still fails, contact your card issuer.|downstream_technical_issue|Stripe processing error (selfhost model)
stripe|card_declined|Your card's balance, credit limit, or transaction amount limit was exceeded. Contact your card issuer.|velocity_limit_exceeded|Stripe card velocity exceeded (selfhost bank)
adyen|12|Not enough balance|insufficient_funds|Adyen not enough balance (selfhost bank)
adyen|2|Refused|do_not_honor|Adyen refused (selfhost bank)
adyen|9|Issuer Unavailable|downstream_technical_issue|Adyen issuer unavailable, as Stripe's processing error (selfhost bank)
adyen|29|Withdrawal count exceeded|velocity_limit_exceeded|Adyen withdrawal count exceeded (selfhost bank)
authorizedotnet|2|This transaction has been declined.|do_not_honor|Authorize.net decline, generic only (selfhost bank)
nmi|200|DECLINE|do_not_honor|NMI decline, generic only (selfhost bank)
globalpay|101|(101)[ test system ] Declined|do_not_honor|Global Payments decline, generic only (selfhost bank)
cybersource|EXPIRED_CARD|EXPIRED_CARD|do_not_honor|Cybersource expired card: its sandbox's only decline, used as a generic soft one; in real life it is hard (selfhost bank)
worldpay|5|REFUSED|do_not_honor|Worldpay refused (selfhost bank)
worldpay|51|LIMIT EXCEEDED|insufficient_funds|Worldpay limit exceeded, its insufficient funds and velocity (selfhost bank)
worldpay|91|CREDITCARD ISSUER TEMPORARILY NOT REACHABLE|downstream_technical_issue|Worldpay issuer not reachable, as Stripe's processing error (selfhost bank)
ROWS

# 9c. Outgoing webhooks to the inbox (docker-compose.yml webhook-inbox), when HS_WEBHOOK_URL is set.
# The engine signs each webhook with the profile's payment_response_hash_key (HMAC-SHA512, header
# X-Webhook-Signature-512); the inbox checks it with the same key.
if [ -n "${HS_WEBHOOK_URL:-}" ]; then
  [ -n "${HS_WEBHOOK_HASH_KEY:-}" ] || die "set HS_WEBHOOK_HASH_KEY with HS_WEBHOOK_URL"
  printf '%s' "$HS_WEBHOOK_HASH_KEY" >"$TMP/hook.key"
  api PUT "v2/profiles/$PROFILE_ID" "$(jq -cn --arg url "$HS_WEBHOOK_URL" --rawfile key "$TMP/hook.key" '
    {webhook_details: {webhook_url: $url, payment_created_enabled: true,
       payment_succeeded_enabled: true, payment_failed_enabled: true},
     enable_payment_response_hash: true, payment_response_hash_key: $key}')" "$(MH)" "$(PH)"
  expect "turn on webhooks"
  [ "$(jq -r '.webhook_details.webhook_url // empty' <<<"$BODY")" = "$HS_WEBHOOK_URL" ] ||
    die "the webhook URL reads back as $(jq -c '.webhook_details.webhook_url' <<<"$BODY")"
  BODY=""
  say "webhooks on: $HS_WEBHOOK_URL (signed)"
fi

# 10. Dashboard token for the proxy, signed with the router's JWT secret.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
exp=$(($(date +%s) + JWT_DAYS * 86400))
header=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)
payload=$(jq -cn --arg m "$MERCHANT_ID" --arg o "$ORG_ID" --arg p "$PROFILE_ID" --argjson exp "$exp" \
  '{user_id: "selfhost-sim-proxy", merchant_id: $m, role_id: "merchant_admin", exp: $exp,
    org_id: $o, profile_id: $p, tenant_id: "public"}' | b64url)
# openssl takes an HMAC key only as an argument (no key file), so the secret is in this one-shot
# container's process list for the moment the command runs.
sig=$(printf '%s' "$header.$payload" | openssl dgst -sha256 -hmac "$HS_JWT_SECRET" -binary | b64url)
JWT="$header.$payload.$sig"
printf 'Authorization: Bearer %s\n' "$JWT" >"$TMP/jwt.h"
AUTH_FILE="$TMP/jwt.h" api GET "v2/profiles/$PROFILE_ID" "" "$(MH)" "$(PH)"
expect "check the dashboard token"
expires=$(date -u -d "@$exp" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -r "$exp" +%Y-%m-%dT%H:%MZ)
say "dashboard token works; it expires $expires (run seed again to renew)"

# 11. The proxy's lines.
cat >"$STATE_DIR/proxy.env" <<EOF
# From simulator/selfhost/seed.sh, $(date -u +%Y-%m-%dT%H:%MZ). Put these into simulator/proxy/.env
# (template: simulator/proxy/.env.vm.example). HS_BASE_URL is the SSH tunnel, not this router's address.
HS_API_KEY=$API_KEY
HS_DASHBOARD_JWT=$JWT
HS_REVREC_MERCHANT_ID=$MERCHANT_ID
HS_MERCHANT_ID=$MERCHANT_ID
HS_ORG_ID=$ORG_ID
HS_PROFILE_ID=$PROFILE_ID
HS_BILLING_MCA_ID=$BILLING_MCA_ID
HS_PAYMENT_MCA_ID=$PAYMENT_MCA_ID
# The portfolio pair: static retries on the default profile, Rev Rec's model on the smart profile.
HS_STATIC_PROFILE_ID=$PROFILE_ID
HS_STATIC_BILLING_MCA_ID=$BILLING_MCA_ID
HS_STATIC_PAYMENT_MCA_ID=$PAYMENT_MCA_ID
HS_SMART_PROFILE_ID=$SMART_PROFILE_ID
HS_SMART_BILLING_MCA_ID=$SMART_BILLING_MCA_ID
HS_SMART_PAYMENT_MCA_ID=$SMART_PAYMENT_MCA_ID
# Stories with live settings lease one of these (profile:billing connector:payment connector).
HS_POOL=$POOL
# Preset 9 (second saved card): smart without the model flag; the stand-in decider's call log
# through the tunnel (-L 8094:127.0.0.1:8094), or http://<private IP>:8094 on Cloud Run.
HS_DECIDER_PROFILE_ID=$DECIDER_PROFILE_ID
HS_DECIDER_BILLING_MCA_ID=$DECIDER_BILLING_MCA_ID
HS_DECIDER_PAYMENT_MCA_ID=$DECIDER_PAYMENT_MCA_ID
DECIDER_URL=http://localhost:8094
EOF
if [ -n "${HS_WEBHOOK_URL:-}" ] && [ -n "${INBOX_READ_TOKEN:-}" ]; then
  cat >>"$STATE_DIR/proxy.env" <<EOF
# The webhook inbox: through the tunnel (-L 8092:127.0.0.1:8092), or http://<private IP>:8092 on Cloud Run.
INBOX_URL=http://localhost:8092
INBOX_READ_TOKEN=$INBOX_READ_TOKEN
EOF
fi
say "done. Proxy lines (with secrets) are in $STATE_DIR/proxy.env. Ids:"
say "  org $ORG_ID, merchant $MERCHANT_ID, profile $PROFILE_ID"
say "  payment connector $PAYMENT_MCA_ID, billing connector $BILLING_MCA_ID, API key $API_KEY_ID"
