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
# Default: first charge after 3 s, then every 5 s, 15 times (simulator/SELF-HOST.md).
DEFAULT_LADDER='{"default_mapping":{"start_after":3,"frequencies":[[5,15]]}}'
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

# 9. GSM rows: Stripe hard declines stop Rev Rec at once.
# check_hard_decline (crates/router/src/workflows/revenue_recovery.rs) looks up connector, flow
# "revenue_recovery", sub_flow "sub_flow", the error code, and for Stripe the error reason
# ("message - <message>, decline_code - <code>", connectors/stripe.rs). The retry scheduler
# (core/revenue_recovery/types.rs) looks up the plain message, so expired_card has both forms.
# Stripe's plain message for stolen_card is the generic "Your card was declined.", so it has one.
gsm_row() { # code message description
  jq -cn --arg code "$1" --arg message "$2" --arg description "$3" '
    {connector: "stripe", flow: "revenue_recovery", sub_flow: "sub_flow", code: $code,
     message: $message, status: "failure", decision: "do_default", step_up_possible: false,
     clear_pan_possible: false, error_category: "hard_decline", description: $description}'
}
while IFS='|' read -r code message description; do
  row=$(gsm_row "$code" "$message" "$description")
  api POST v2/gsm "$row"
  if [ "$CODE" != 200 ]; then
    api POST v2/gsm/update "$row"
    expect "update GSM row $code / $message"
  fi
  say "GSM hard decline: stripe $code / $message"
done <<'ROWS'
card_declined|message - Your card was declined., decline_code - stolen_card|Stripe stolen card: Rev Rec stops (selfhost)
expired_card|message - Your card has expired., decline_code - expired_card|Stripe expired card: Rev Rec stops (selfhost)
expired_card|Your card has expired.|Stripe expired card: Rev Rec stops (selfhost)
ROWS

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
EOF
say "done. Proxy lines (with secrets) are in $STATE_DIR/proxy.env. Ids:"
say "  org $ORG_ID, merchant $MERCHANT_ID, profile $PROFILE_ID"
say "  payment connector $PAYMENT_MCA_ID, billing connector $BILLING_MCA_ID, API key $API_KEY_ID"
