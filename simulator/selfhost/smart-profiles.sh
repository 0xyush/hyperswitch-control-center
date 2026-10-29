#!/usr/bin/env bash
# Smart retries with Rev Rec's model for profiles that seed.sh does not make (A, 28 Oct): the
# processor profiles (sim-proc-*) and the go-live profile (sim-golive). For each profile id: the model
# flag on (revenue_recovery_ab_enabled_<id>, as seed.sh 8b), then retry mode smart. Ids after
# --flag-only get the flag only: the go-live story turns Rev Rec on itself. Idempotent.
# The sim service's calendar follows every invoice on the model's A/B arm, so it needs no list.
# Run on the VM, in the seed's container (it has the admin key and the state):
#   docker compose --profile seed run --rm -v "$PWD/smart-profiles.sh:/smart-profiles.sh:ro" \
#     --entrypoint sh seed -c 'apk add --no-cache bash curl jq >/dev/null && bash /smart-profiles.sh \
#     pro_a pro_b --flag-only pro_c'
set -euo pipefail
umask 077

BASE="${HS_BASE_URL:-http://router:8080}"
BASE="${BASE%/}"
STATE="${STATE_DIR:-/state}/seed.env"

die() {
  echo "smart-profiles: $*" >&2
  exit 1
}
say() { echo "smart-profiles: $*"; }

[ -n "${HS_ADMIN_API_KEY:-}" ] || die "set HS_ADMIN_API_KEY"
[ -f "$STATE" ] || die "no $STATE: run seed.sh first"
# shellcheck disable=SC1090
. "$STATE"
[ -n "${MERCHANT_ID:-}" ] || die "no MERCHANT_ID in $STATE"
[ $# -gt 0 ] || die "give profile ids"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Secrets go to curl in header files, not on the command line.
printf 'Authorization: admin-api-key=%s\n' "$HS_ADMIN_API_KEY" >"$TMP/admin.h"

# api METHOD PATH [BODY] [HEADER...]: sets CODE and BODY (as seed.sh)
api() {
  local method=$1 path=$2 body=${3:-}
  shift 2
  [ $# -gt 0 ] && shift
  local args=(-sS -o "$TMP/out" -w '%{http_code}' -X "$method" "$BASE/$path"
    -H "@$TMP/admin.h" -H 'Content-Type: application/json')
  local h
  for h in "$@"; do args+=(-H "$h"); done
  [ -n "$body" ] && args+=(--data-binary "$body")
  CODE=$(curl "${args[@]}") || CODE=000
  BODY=$(cat "$TMP/out" 2>/dev/null || true)
}
expect() { # expect STEP: stops unless the last call answered 200
  [ "$CODE" = 200 ] || die "$1 failed: HTTP $CODE $(head -c 400 <<<"$BODY")"
}
config_set() { # config_set KEY VALUE: writes a DB config and reads it back (as seed.sh)
  api POST v2/configs/ "$(jq -cn --arg k "$1" --arg v "$2" '{key: $k, value: $v}')"
  if [ "$CODE" != 200 ]; then
    api POST "v2/configs/$1" "$(jq -cn --arg v "$2" '{value: $v}')"
    expect "update config $1"
  fi
  api GET "v2/configs/$1"
  expect "read config $1"
  [ "$(jq -r '.value' <<<"$BODY")" = "$2" ] || die "config $1 reads back as $(jq -c '.value' <<<"$BODY")"
}

mode=smart
for pid in "$@"; do
  if [ "$pid" = --flag-only ]; then
    mode=""
    continue
  fi
  case "$pid" in pro_*) ;; *) die "not a profile id: $pid" ;; esac
  ph="X-Profile-Id: $pid"
  api GET "v2/profiles/$pid" "" "X-Merchant-Id: $MERCHANT_ID" "$ph"
  expect "read profile $pid"
  name=$(jq -r '.profile_name' <<<"$BODY")
  config_set "revenue_recovery_ab_enabled_$pid" true
  if [ -n "$mode" ]; then
    api PUT "v2/profiles/$pid" "$(jq -cn '{revenue_recovery_retry_algorithm_type: "smart"}')" \
      "X-Merchant-Id: $MERCHANT_ID" "$ph"
    expect "set $name's retry mode"
    [ "$(jq -r '.revenue_recovery_retry_algorithm_type' <<<"$BODY")" = smart ] ||
      die "$name's retry mode reads back as $(jq -r '.revenue_recovery_retry_algorithm_type' <<<"$BODY")"
    say "$name ($pid): model flag on, retry mode smart"
  else
    say "$name ($pid): model flag on (retry mode kept: $(jq -r '.revenue_recovery_retry_algorithm_type' <<<"$BODY"))"
  fi
done
