#!/usr/bin/env bash
# Writes the simulator's secrets from simulator/proxy/.env into Secret Manager, plus the shared password.
# Values are never printed. Run it yourself:
#   bash simulator/deploy/put-secrets.sh                                  (reads simulator/proxy/.env)
#   bash simulator/deploy/put-secrets.sh simulator/proxy/.env.vm          (the self-hosted engine's values)
#   SIM_PASSWORD='something' bash simulator/deploy/put-secrets.sh ...     (also sets a new password)
# The password is asked only when the secret does not exist yet, or when SIM_PASSWORD is given.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${1:-$ROOT/simulator/proxy/.env}"
[ -f "$ENV_FILE" ] || { echo "no env file at $ENV_FILE"; exit 1; }
PROJECT=hs-selfhost-0928-x825
SA="revrec-sim-proxy@$PROJECT.iam.gserviceaccount.com"
gcloud config set project "$PROJECT" >/dev/null

put() { # name, value-from-stdin
  local name=$1
  if gcloud secrets describe "$name" >/dev/null 2>&1; then
    gcloud secrets versions add "$name" --data-file=- >/dev/null && echo "$name: new version"
  else
    gcloud secrets create "$name" --replication-policy=automatic --data-file=- >/dev/null && echo "$name: created"
  fi
  gcloud secrets add-iam-policy-binding "$name" --member="serviceAccount:$SA" --role=roles/secretmanager.secretAccessor >/dev/null
}

for pair in HS_API_KEY:revrec-sim-hs-api-key STRIPE_TEST_KEY:revrec-sim-stripe-test-key HS_DASHBOARD_JWT:revrec-sim-hs-dashboard-jwt; do
  key=${pair%%:*}; name=${pair#*:}
  val=$(grep "^$key=" "$ENV_FILE" | cut -d= -f2- | tr -d '\n')
  [ -n "$val" ] || { echo "missing $key in .env"; exit 1; }
  printf '%s' "$val" | put "$name"
done

# Optional: the webhook inbox's read token (simulator/selfhost/inbox), in .env.vm once webhooks are on.
val=$(grep "^INBOX_READ_TOKEN=" "$ENV_FILE" | cut -d= -f2- | tr -d '\n' || true)
if [ -n "$val" ]; then
  printf '%s' "$val" | put revrec-sim-inbox-read-token
else
  echo "revrec-sim-inbox-read-token: skipped (no INBOX_READ_TOKEN in $ENV_FILE)"
fi

# Optional: the sim service's token (simulator/selfhost/sim), in .env.vm once the sim service runs.
val=$(grep "^SIM_TOKEN=" "$ENV_FILE" | cut -d= -f2- | tr -d '\n' || true)
if [ -n "$val" ]; then
  printf '%s' "$val" | put revrec-sim-sim-token
else
  echo "revrec-sim-sim-token: skipped (no SIM_TOKEN in $ENV_FILE)"
fi

# Optional, for later: the six processors' test keys (processors.ts), in .env.vm. Stripe only since 28 Oct
# (PROCESSORS_ENABLED unset), so they are written only with WITH_PROCESSORS=1. Each becomes
# revrec-sim-<key in lower case, dashes>; a missing key is skipped and that processor stays off.
if [ "${WITH_PROCESSORS:-0}" != 1 ]; then
  echo "processor keys: skipped (Stripe only; WITH_PROCESSORS=1 writes them)"
else
  for key in ADYEN_API_KEY ADYEN_MERCHANT_ACCOUNT CYBERSOURCE_API_KEY CYBERSOURCE_API_SECRET CYBERSOURCE_MERCHANT_ID \
             AUTHORIZEDOTNET_LOGIN_ID AUTHORIZEDOTNET_TRANSACTION_KEY WORLDPAY_CREDS_KEY1 WORLDPAY_CREDS_API_KEY \
             WORLDPAY_CREDS_API_SECRET NMI_SECURITY_KEY NMI_PUBLIC_KEY GLOBALPAY_APP_KEY GLOBALPAY_APP_ID; do
    name="revrec-sim-$(printf '%s' "$key" | tr 'A-Z_' 'a-z-')"
    val=$(grep "^$key=" "$ENV_FILE" | cut -d= -f2- | tr -d '\n' || true)
    if [ -n "$val" ]; then printf '%s' "$val" | put "$name"; else echo "$name: skipped (no $key in $ENV_FILE)"; fi
  done
fi

if [ -z "${SIM_PASSWORD:-}" ] && gcloud secrets describe revrec-sim-password >/dev/null 2>&1; then
  echo "revrec-sim-password: kept (set SIM_PASSWORD to change it)"
else
  if [ -z "${SIM_PASSWORD:-}" ]; then
    read -r -s -p "Shared password for the public link: " SIM_PASSWORD; echo
  fi
  [ ${#SIM_PASSWORD} -ge 8 ] || { echo "password must be at least 8 characters"; exit 1; }
  printf '%s' "$SIM_PASSWORD" | put revrec-sim-password
fi
echo "done: secrets in Secret Manager from $ENV_FILE, readable by $SA"
