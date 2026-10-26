# Self-hosted Hyperswitch for the simulator

One VM runs Hyperswitch v2 (router, scheduler producer and consumer, Postgres, Redis) with docker
compose. We hold the admin key, so the retry ladder, the timings and the GSM rows are ours to set.
The plan and the acceptance checks are in `../SELF-HOST.md`.

## Files

| File                       | What it does                                                                                                                                                                                                                                                                                                                   |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `docker-compose.yml`       | All services. The router listens on `127.0.0.1:8080` only.                                                                                                                                                                                                                                                                     |
| `config.toml`              | Router and scheduler config: upstream `config/docker_compose.toml` at tag 2026.10.26.0, with each change marked `# selfhost:` (fast Rev Rec timings, scheduler polls every 1 s, all six `recovery_timestamp` fields that v2 needs, no OTel, no mail, Superposition from a file). Secrets come from `.env`, not from this file. |
| `prepare.sh`               | One-shot. Fetches the tag's migrations and Superposition seed file, and removes the two Rev Rec ladder keys from the seed file.                                                                                                                                                                                                |
| `migrate.sh`               | One-shot. Runs the v2 migrations as upstream's `just migrate_v2` does.                                                                                                                                                                                                                                                         |
| `seed.sh`                  | Run by hand, idempotent. Makes the org, merchant, profile, Stripe test connector, Custom billing connector (start rule 0, max 15, grace 30), retry mode, v2 API key, fast ladder, GSM hard-decline rows and the proxy's dashboard token.                                                                                       |
| `.env.example`             | Image names, tag and secrets for compose.                                                                                                                                                                                                                                                                                      |
| `../proxy/.env.vm.example` | The proxy's `.env` for this instance.                                                                                                                                                                                                                                                                                          |

## Start it on the VM

1. Install Docker Engine and the compose plugin. Log Docker in to Artifact Registry:
   `gcloud auth configure-docker us-central1-docker.pkg.dev`.
2. Copy this folder to the VM (or clone the repo there) and `cd` into it.
3. Copy `.env.example` to `.env`. Fill every value. Make each secret with the command shown above it.
4. Start the stack: `docker compose up -d`.
   - `prepare` and `migrate` run once and exit. The first `migrate` takes a few minutes.
   - The router starts after the migrations. The schedulers start after the router is healthy.
5. Check: `docker compose ps` shows router, producer and consumer as running, and the router as healthy.
   `curl -s localhost:8080/health` answers.
6. Seed it: `docker compose --profile seed run --rm seed`.
   - It prints the ids. It writes `state/seed.env` and `state/proxy.env` (mode 600, with secrets).
   - Run it again at any time. It keeps what exists and makes only what is missing.

## Connect the proxy

1. Open the tunnel from the machine that runs the proxy, and keep it open:
   `gcloud compute ssh VM_NAME --zone ZONE -- -N -L 8090:127.0.0.1:8080`.
2. Copy `../proxy/.env.vm.example` to `../proxy/.env`. Fill the `HS_*` lines from the VM's
   `state/proxy.env`. Keep the `STRIPE_*` lines from the old `.env`.
3. Start the proxy. `GET /healthz` must show the token as valid and the base URL as `http://localhost:8090`.

## Change the retry ladder

The ladder is in the DB configs table, so a change needs no restart.

- Set it for the next seed run: `LADDER_JSON='{"default_mapping":{"start_after":3,"frequencies":[[5,15]]}}'` in `.env`, then run the seed again.
- `start_after` is the wait in seconds before Rev Rec's first charge. Each `[gap, count]` pair is `count` retries, `gap` seconds apart.
- Why the DB: Hyperswitch reads Superposition first, then the DB. The upstream Superposition seed holds a slow ladder (60 s, then hours apart). `prepare.sh` removes the ladder keys from the copy the router reads, so the DB value applies.

## Known gaps

- **No dashboard sign-in.** A v2-only router has no `/user/signin` or `/user/signup` (they are v1 routes). `seed.sh` signs a token for the proxy instead (role `merchant_admin`, 30 days). The proxy already answers the dashboard's user calls itself (`proxy/src/shell.ts`).
- **No `recovery-aggregate` route.** Upstream 2026.10.26.0 has `GET /v2/payments/aggregate`, not `/v2/payments/recovery-aggregate`. The dashboard's invoice status counts call the second, so they fail on this instance.
- **Smart mode is not set up.** It needs the decider service (`[grpc_client.recovery_decider_client]`). Use cascading.
- **No Superposition server.** The router and the schedulers read the seed file only. A change to it needs `docker compose run --rm prepare` and then `docker compose restart router producer consumer`.
- **No portfolio pair.** Only one profile is seeded, so both portfolio runs use it.
