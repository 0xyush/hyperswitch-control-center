# Rev Rec Simulator · build plan (M0 → M1)

Source of truth: the PRD at ~/work/revrec-sandbox/prd/prd.md (sections 6, 7, 11, 12, 13).
Research with file:line refs: ~/work/revrec-sandbox/research/01..05\*.md.
Owner: Aayush Shrestha. Fork: github.com/0xyush/hyperswitch-control-center (this repo), upstream juspay/hyperswitch-control-center.

## Layout in this repo

- `simulator/proxy/` Node 24 + TypeScript. The proxy + billing simulator + explain service (PRD §6). Own package.json. Port 8787.
- `simulator/BUILD.md` this file. `simulator/NOTES.md` running notes from the builders (append, never rewrite).
- `src/RevenueRecovery/Simulator/` ReScript screens: Home (two entry cards), Invoice story, later Portfolio, Feature tour, Explain panel.
- Keep edits to shared dashboard files minimal (routing, sidebar, feature flag). Simulation code lives in the two folders above.

## Workstream A · proxy + billing simulator (M0, then M1 scenarios 1, 2, 3)

Goal: the dashboard talks only to the proxy; the proxy holds keys and plays the billing system.

1. `GET /healthz` → sandbox reachable (GET a recovery list), Stripe reachable (GET /v1/balance), config present.
2. Pass-through for dashboard calls under `/api/*` → `https://sandbox.hyperswitch.io/*` with an allow-list (recovery list, aggregate, invoice detail, process tracker, profile config reads). Adds `authorization: Bearer <HS_DASHBOARD_JWT>` and `X-Merchant-Id` / `X-Profile-Id` from env. Everything else → 403.
   For M0 the JWT comes from env (`HS_DASHBOARD_JWT`, pasted from the browser). Login/renew is M4.
3. Billing simulator endpoints:
   - `POST /sim/story/start {scenario}` → creates a Stripe test customer + saved card (0341 or 4242), makes one real failed charge where the scenario needs it, reports to `POST /v2/recovery` with `action: schedule_failed_payment` and the scenario's reason. Returns `{invoiceId, recoveryId, startedAt}`.
   - `POST /sim/story/:id/paid-in-app` → real 4242 charge + `success_payment_external` report.
   - `POST /sim/story/:id/report-again` → re-send the same failure (duplicate) or a new failure (scenario 6 swap).
   - `GET /sim/story/:id` → merged status: invoice, attempts, next retry time (process tracker), plus explain lines each with `source: sandbox | recomputed | rule`.
   - Rate limit: 5 story starts per hour per IP (in-memory is fine for now).
4. Scenario table and request shapes: PRD §7 and the working prototype at ~/work/starlink-revrec/prototype/server.mjs (it already does customers, charges, /v2/recovery reports, success_payment_external). The Oct 14 field names are the current ones (`transaction_status`, `payment_method_metadata`, path `/v2/recovery`). Check the OpenAPI subset at ~/work/starlink-revrec/context/api/revenue-recovery-openapi-v2.json.
5. Env: read from `simulator/proxy/.env` (git-ignored). Copy the values from ~/work/starlink-revrec/.env (HS_BASE_URL, HS_PROFILE_ID, HS_API_KEY, HS_BILLING_MCA_ID, HS_PAYMENT_MCA_ID, STRIPE_TEST_KEY, STRIPE_CUSTOMER_ID, STRIPE_PM_DECLINE, STRIPE_PM_OK). Never print secret values in logs, chat, or files that are committed. Add `HS_MERCHANT_ID` and `HS_DASHBOARD_JWT` (leave empty; Aayush fills).
6. Tests: a `npm test` that runs the scenario-1 flow against the real sandbox when env is present, otherwise skips. Keep a `simulator/proxy/README.md` with run steps.

## Workstream B · dashboard fork front end (M0, then M1 Home + Invoice story shell)

Goal: the fork runs locally, points at the proxy, shows the Rev Rec module, and has the Home page with two entry cards and an Invoice story screen that polls the proxy.

1. Read AGENTS.md and README.md in the repo root. Get `npm install`, `npm run re:build` and `npm run start` working (webpack dev on :9000). Record any env or node quirks in simulator/NOTES.md.
2. `config/config.toml`: `dev_recovery_v2_product=true`, `test_processors=true`, `api_url="http://localhost:8787/api"` (the proxy). Keep a diff small.
3. Demo session: a feature flag `simulator_demo_session=true` that skips the login screen and seeds the user info the Rev Rec module needs (merchant id, profile id, product type Recovery, transaction entity Merchant). Find how `UserInfoProvider` and `AuthHooks` build the session and seed the same shape from `window.__SIM_SESSION__` injected by the proxy (or from config for M0). Do not weaken auth for non-demo builds.
4. Home page: new route `/v2/recovery/home` with two cards built from the Default Home card component and the existing Rev Rec SVGs under `public/hyperswitch/assets/` (RevenueRecoveryHomePreview.svg, DefaultHomeRecoveryCard.svg). Card 1 "Try the simulator" → `/v2/recovery/simulator/story`. Card 2 "Explore Revenue Recovery" → opens the Explore Workflows side drawer; widen its product gate to Recovery (src/screens/ExploreWorkflows). Match Orchestrator's "Make a test payment, Try It Out" and "Explore Smart Retries" cards in look and placement.
5. Invoice story screen (shell for M1): scenario picker (8 scenarios from PRD §7, with V1 status tags), Play button → `POST /sim/story/start`, then poll `GET /sim/story/:id` every 4 s. Layout per PRD §7 "Screen": left vertical stepper of states (Monitoring, Queued, Scheduled, Processing, Recovered / Terminated) with plain captions; centre four boxes (Billing system, Rev Rec, Processor, Customer) with an animated arrow for the current step; right "now" card + explain panel (render the explain lines with their source label); bottom the existing attempts table component from the invoice detail page. Controls: Play, Pause polling, Paid in app, Report another failure, Reset, Show requests.
6. Fix the refresh bug: a hard refresh on `/dashboard/v2/recovery/*` must render the app, not raw JSON (dev server history fallback and route registration).
7. Use the dashboard's own components, Tailwind theme, InterDisplay font and icons. No new design system.

## Rules for both

- Branch: work on `main` of the fork, commit small with clear messages, do not push until Aayush says so.
- No secrets in commits. `.env` files are git-ignored (check `.gitignore`).
- Append findings and blockers to `simulator/NOTES.md` with a timestamp.
- Plain-words comments. Prefer existing components over new ones.
