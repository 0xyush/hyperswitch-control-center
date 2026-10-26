#!/usr/bin/env bash
# One-shot step (docker-compose.yml service "migrate", debian:trixie-slim): runs the v2 migrations the
# way upstream's `just migrate_v2` does (justfile, tag 2026.10.26.0):
#   migrations/*  +  v2_compatible_migrations/* prefixed "8"  +  v2_migrations/* prefixed "9"
#   -> one folder -> diesel migration run
# Diesel records what it ran, so a second run applies only new migrations.
# Upstream passes --config-file diesel_v2.toml, which only regenerates schema_v2.rs in the source tree
# after the run. The VM has no use for that, so this uses a config file without [print_schema].
set -euo pipefail

: "${DATABASE_URL:?set DATABASE_URL}"
REPO=/src/repo
[ -d "$REPO/v2_migrations" ] || {
  echo "migrate: $REPO has no v2_migrations; run the prepare step first" >&2
  exit 1
}

apt-get update -qq
apt-get install -y -qq curl xz-utils ca-certificates >/dev/null
curl --proto '=https' --tlsv1.2 -LsSf \
  https://github.com/diesel-rs/diesel/releases/download/v2.3.5/diesel_cli-installer.sh | bash >/dev/null
export PATH="$PATH:$HOME/.cargo/bin"

WORK=$(mktemp -d)
cp -r "$REPO/migrations/." "$WORK/"
for d in "$REPO"/v2_compatible_migrations/*/; do cp -r "$d" "$WORK/8$(basename "$d")"; done
for d in "$REPO"/v2_migrations/*/; do cp -r "$d" "$WORK/9$(basename "$d")"; done
echo "# no [print_schema] on the VM" >"$WORK.toml"

echo "migrate: $(find "$WORK" -mindepth 1 -maxdepth 1 -type d | wc -l) migration folders"
diesel migration run --migration-dir "$WORK" --config-file "$WORK.toml" --database-url "$DATABASE_URL"
echo "migrate: done"
