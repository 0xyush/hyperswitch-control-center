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
