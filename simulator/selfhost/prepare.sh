#!/bin/sh
# One-shot step before the migrations (docker-compose.yml service "prepare", alpine).
# The VM has no Hyperswitch source, so this fetches the files it needs at the image's tag into the
# hs_src volume:
#   repo/migrations, repo/v2_compatible_migrations, repo/v2_migrations   (for migrate.sh)
#   selfhost/superposition_seed.toml   upstream config/superposition_seed.toml without the two Rev Rec
#                                      ladder keys, so the ladder in the DB configs table applies
# Superposition is read first, then the DB (crates/router/src/core/configs.rs fetch_db_config), and the
# upstream seed holds the slow default ladder (60 s, then hours apart). seed.sh writes the fast ladder.
set -eu

TAG="${HS_TAG:?set HS_TAG, the Hyperswitch tag of the images}"
SRC=/src
REPO="$SRC/repo"
SEED_IN="$REPO/config/superposition_seed.toml"
SEED_OUT="$SRC/selfhost/superposition_seed.toml"

if [ "$(cat "$SRC/.tag" 2>/dev/null || true)" != "$TAG" ]; then
  echo "prepare: fetching juspay/hyperswitch $TAG (migrations and config only)"
  apk add --no-cache git >/dev/null
  rm -rf "$REPO"
  git clone --quiet --depth 1 --branch "$TAG" --filter=blob:none --sparse \
    https://github.com/juspay/hyperswitch.git "$REPO"
  git -C "$REPO" sparse-checkout set migrations v2_compatible_migrations v2_migrations config
  echo "$TAG" >"$SRC/.tag"
else
  echo "prepare: $TAG is already fetched"
fi

# Each ladder entry spans several lines: from its key line to the line with
# "start_after = <n> } }, schema = ". Drop those lines.
mkdir -p "$SRC/selfhost"
awk '
  /^"process_tracker\.pt_mapping_(pcr|adaptive)_retries" = / { skip = 1 }
  skip { if ($0 ~ /start_after = [0-9]+ \} \}, schema = /) skip = 0; next }
  { print }
' "$SEED_IN" >"$SEED_OUT.tmp"

removed=$(($(wc -l <"$SEED_IN") - $(wc -l <"$SEED_OUT.tmp")))
if grep -q 'pt_mapping_pcr_retries\|pt_mapping_adaptive_retries' "$SEED_OUT.tmp" ||
  [ "$removed" -lt 2 ] || [ "$removed" -gt 80 ] ||
  [ "$(tail -n 1 "$SEED_IN")" != "$(tail -n 1 "$SEED_OUT.tmp")" ]; then
  echo "prepare: the seed file has a new shape ($removed lines removed); check the awk rule" >&2
  exit 1
fi
mv "$SEED_OUT.tmp" "$SEED_OUT"
echo "prepare: wrote $SEED_OUT ($removed ladder lines removed)"
