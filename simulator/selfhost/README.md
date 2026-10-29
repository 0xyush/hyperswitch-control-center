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
| `smart-profiles.sh`        | Run by hand, idempotent, in the seed's container (command in its header). Model flag on and retry mode smart for the `sim-proc-*` profiles; flag only for `sim-golive`.                                                                                                                                                        |
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

- Set it for the next seed run: `LADDER_JSON='{"default_mapping":{"start_after":3,"frequencies":[[1,15]]}}'` (the default) in `.env`, then run the seed again.
- `start_after` is the wait in seconds before Rev Rec's first charge. Each `[gap, count]` pair is `count` retries, `gap` seconds apart.
- Why the DB: Hyperswitch reads Superposition first, then the DB. The upstream Superposition seed holds a slow ladder (60 s, then hours apart). `prepare.sh` removes the ladder keys from the copy the router reads, so the DB value applies.

## Webhooks to the billing system (optional)

The engine posts its outgoing webhooks to a small inbox on the VM (`inbox/inbox.mjs`), as it would to a billing system. The proxy reads them back and shows one "webhook" row per event.

1. The engine refuses webhook URLs on private addresses (its SSRF guard), so it posts to the VM's external IP. Allow port 8092 from that IP only:
   `gcloud compute firewall-rules create revrec-hs-webhook-inbox --network default --direction INGRESS --allow tcp:8092 --source-ranges EXTERNAL_IP/32 --target-tags revrec-hs` (the VM's own tag). Make the external IP static first (done 27 Oct: `revrec-hs-ip`, <VM_EXTERNAL_IP>).
2. In `.env`, set `HS_WEBHOOK_URL=http://EXTERNAL_IP:8092/webhooks`, `HS_WEBHOOK_HASH_KEY` and `INBOX_READ_TOKEN` (commands in `.env.example`).
3. Start the inbox: `docker compose --profile webhooks up -d webhook-inbox`.
4. Run the seed again. It turns on the profile's webhooks with the signing key, and adds `INBOX_URL` and `INBOX_READ_TOKEN` to `state/proxy.env`.
5. Locally, add `-L 8092:127.0.0.1:8092` to the tunnel. On Cloud Run, `INBOX_URL=http://PRIVATE_IP:8092`.

The inbox checks each webhook's signature (`X-Webhook-Signature-512`, HMAC-SHA512 with the profile's key), keeps the last 50 events per payment, and logs one line per event without bodies or headers.

## Rev Rec's model in demo time (sim service)

The smart profile runs Rev Rec's own model (`MODEL.md`). The model plans retries days ahead, and it learns at each attempt's time. The `sim` service (`sim/sim.mjs`) makes both work in a short demo:

- **Simulated calendar:** it moves each retry the model planned to its demo time, 13.6 s per real day after the failure.
  - Decision 1 is the engine's pick. Later picks keep the model's day gap and hour, after the last retry.
  - A retry past the grace window ends the invoice (task business status `SIM_GRACE_OVER`).
  - It follows every invoice the engine put on the model's A/B arm (`revenue_recovery_ab_routing` on the payment), on any profile.
  - A story can set its own grace on the simulated calendar: Stripe customer metadata `sim_grace_days` (whole days, 1 to 60).
- **Learning re-file:** it keeps the retry stats at the seed plus each outcome since the last reset, at its real-life slot. It writes through the engine's admin route, which takes the engine's lock.
- **The bank:** the engine's Stripe calls go through it (`config.toml`: `stripe.base_url = "http://sim:8095/"`). It decides Rev Rec's charges for invoices the proxy marks, by the charge's real-life slot, and passes everything else on byte for byte (`MODEL.md`, "The bank, at charge time"). `SIM_BANK=off` passes everything. The engine needs the sim service up for any Stripe call; to go around it, set `stripe.base_url` back to `https://api.stripe.com/` and recreate the router, producer and consumer.

1. In `.env`, set `SIM_TOKEN` (command in `.env.example`).
2. Start it: `docker compose --profile sim up -d --build sim`. On its first start, it resets the stats to the seed.
3. Locally, add `-L 8093:127.0.0.1:8093` to the tunnel. On Cloud Run, use `http://PRIVATE_IP:8093`.

Routes (all but `/health` need `Authorization: Bearer $SIM_TOKEN`): `GET /health`, `GET /calendar?payment_id=`, `GET /stats`, `GET /check`, `POST /reset`.

**Tests:**

- `curl -H "Authorization: Bearer $SIM_TOKEN" localhost:8093/check` must answer `"ok":true`: the stats equal the seed plus each outcome at its real-life slot.
- With `SIM_REFILE=off`, the engine's own filing stays. Then `/check?slots=demo` must answer `"ok":true`. This proves the service reads the outcomes as the engine records them.
- Unit tests: `node --test simulator/selfhost/sim/sim.test.mjs`.

## Stand-in decider (preset 9)

Preset 9 needs Rev Rec to choose among the customer's saved cards. The engine does that only in smart mode without the model flag. In that mode it asks a decider service for the retry time. The `decider` service (`decider/decider.mjs`) is a narrow stand-in for it, not a model: every call gets "retry in 5 s" (`DECIDER_RETRY_AFTER_SEC`) and threshold 0.5. The engine still picks the card.

- `config.toml` `[grpc_client.recovery_decider_client]` sends the schedulers to `decider:50051` (plain HTTP/2, compose network only). Only the scheduler consumer calls it, so a config change needs `docker compose up -d --no-deps --force-recreate producer consumer`.
- `seed.sh` 6c makes the profile `sim-smart-decider` (own Stripe and Custom billing connectors, smart, model flag off) and adds `HS_DECIDER_*` and `DECIDER_URL` to `state/proxy.env`.
- The engine asks the decider only for a saved card whose last charge failed. A card with no failed charge (preset 9's 4242, which paid last month) is booked at +1 min with no call. The story shows "Retry time from a stand-in decider; card choice by Rev Rec." only when the decider's log has a call for that time.
- Its call log is on port 8094 (`GET /calls?payment_id=`, `GET /health`). Locally, add `-L 8094:127.0.0.1:8094` to the tunnel. On Cloud Run, `DECIDER_URL=http://PRIVATE_IP:8094`.
- Test: `node --test simulator/proxy/test/decider.test.ts` (a real gRPC call with a hand-coded request).

## Known gaps

- **No dashboard sign-in.** A v2-only router has no `/user/signin` or `/user/signup` (they are v1 routes). `seed.sh` signs a token for the proxy instead (role `merchant_admin`, 30 days). The proxy already answers the dashboard's user calls itself (`proxy/src/shell.ts`).
- **No `recovery-aggregate` route.** Upstream 2026.10.26.0 has `GET /v2/payments/aggregate`, not `/v2/payments/recovery-aggregate`. The dashboard's invoice status counts call the second, so they fail on this instance.
- **Smart mode runs Rev Rec's own model, not the decider.** The smart profile turns on the per-profile A/B flag (`MODEL.md`). Without that flag, smart mode calls the decider service. Here that is the stand-in above, for the decider profile only.
- **No Superposition server.** The router and the schedulers read the seed file only. A change to it needs `docker compose run --rm prepare` and then `docker compose restart router producer consumer`.
- **The portfolio pair:** the static side runs on the default profile (cascading), the smart side on the smart profile (Rev Rec's model). `state/proxy.env` has both (`HS_STATIC_*`, `HS_SMART_*`).
