# Self-hosted Hyperswitch for the simulator (26 Oct, Aayush's decision)

Why: the shared sandbox cannot be tuned (retry ladder needs the admin key; scheduler stalled on 26 Oct; no decider for
smart mode; no hard-decline row). Hyperswitch is open source and we are the admin on our own instance.

## Target (phase 1, local)
- Run Hyperswitch from ~/work/hyperswitch with Docker Compose (Rancher Desktop, NOT OrbStack): router, scheduler
  producer + consumer, Postgres, Redis. Use the repo's docker-compose.yml. Ports: router 8080 (clashes with nothing we
  run; proxy is 8787), but check 5432/6379 are free (the decision-engine stack holds 5432/6379/8081 on this laptop:
  stop it or remap).
- Config (config/docker_compose.toml or env): `[revenue_recovery] retry_algorithm_type = "cascading"`,
  `monitoring_threshold_in_seconds = 5`, `job_schedule_buffer_time_in_seconds = 5`, `reopen_workflow_buffer_time_in_seconds = 5`,
  scheduler `loop_interval` small. Set the ladder via the admin configs API after boot:
  `POST /configs` key `pt_mapping_pcr_retries` value `{"start_after": 3, "frequencies": [[5, 15]]}` (3 s first, then every 5 s, 15 times).
- Seed: a merchant + profile for Rev Rec (v2), a Custom billing connector (start rule 0, max 15, grace 30), a Stripe
  **test** payment connector with STRIPE_TEST_KEY from .env, a v2 API key, a dashboard user. Script it:
  `simulator/selfhost/seed.sh` (idempotent), using the admin API key from the compose config.
- GSM row for Stripe hard declines: `POST /gsm` with connector stripe, flow revenue_recovery, code card_declined,
  message containing stolen_card -> error_category hard_decline (check the exact fields in crates/api_models/src/gsm.rs).
- Proxy: `HS_BASE_URL=http://localhost:8080`, new ids in .env. The dashboard token: sign in to the local control center
  (or use the user API to mint one) and let the proxy switch as today.
- Optional smart mode: run the decider from ~/work/revenue-recovery (grpc) and set `[grpc_client.recovery_decider_client] base_url`.
  If the Predictor has no trained model, keep smart off and note it.

## Acceptance
- Preset 2 on the local instance: first retry within ~5 s, Recovered within ~15 s, visible live in the story.
- Preset 7 (stolen card): Terminated at once (the GSM row works).
- A 10-invoice portfolio finishes in under 3 minutes.

## Phase 2 (cloud)
- One GCP VM (e2-standard-4) running the same compose stack, private network, the Cloud Run simulator pointed at it.
  Written up after phase 1 works.
