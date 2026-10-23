- 2026-10-23 13:15 plan written; fork cloned from 0xyush/hyperswitch-control-center at 75ba7c1e7

## Contract (proxy <-> dashboard) — Builder A writes, Builder B reads; both may append questions
- Base URL: http://localhost:8787
- GET  /healthz -> {ok, sandbox, stripe, config}
- POST /sim/story/start {scenario: 1..8} -> {storyId, invoiceId, recoveryId, startedAt}
- GET  /sim/story/:storyId -> {status, invoice, attempts[], nextRetryAt, explain:[{text, source:"sandbox"|"recomputed"|"rule"}], requests:[{step, request, response}]}
- POST /sim/story/:storyId/paid-in-app, /report-again -> same shape as GET
- /api/* -> allow-listed pass-through to the sandbox with auth headers added

## Builder B (front end) log
- 2026-10-23 13:19 [B] Step 1 done. Node v24.21.0, npm 11.19.0. `npm install` 12 s, `npm run re:build` 38 s (4313 files, no errors), `npm run start` serves http://localhost:9000 (webpack compiles in ~10 s).
  - Quirk: npm 11 `allowScripts` skips the postinstall of rescript, core-js-pure and fsevents ("install scripts not yet covered by allowScripts"). The build still works, because the rescript binary ships in the package. No action needed.
  - Quirk: no AGENTS.md in the repo root. `.clinerules` is the repo's agent guide (ReScript rules: PageLoaderWrapper around API calls, `useGetMethod`, typed state).
  - Quirk: the commit-msg hook (installed by `npm install`) runs Prettier on staged JS/JSON and `rescript format` on staged .res. Conventional commit prefixes only.
  - The dev server already falls back to index.html for `/dashboard/*` and `/v2/*` (checked with curl, Accept text/html). Webpack `publicPath` is "/", so nested paths load the bundle.
  - Refresh bug root cause (from review-opus-prd-v0.1 F55): the hosted sandbox sends `/dashboard/v2/...` page paths to the API router (`IR_02`). It is a hosting rule, not app code. Our fork must keep a single-page-app fallback on every page path, and the proxy must never forward non-`/api` page paths to the sandbox.

## Contract · B proposals (2026-10-23 13:40) — A, please confirm or edit inline under "A reply"
1. CORS. The dashboard runs on http://localhost:9000 and calls http://localhost:8787 directly, so every route needs CORS. No cookies are sent (`credentials: omit`), so `Access-Control-Allow-Origin: *` works. Answer preflight `OPTIONS` with 204, `Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS`, and echo `Access-Control-Request-Headers` (the app sends `authorization`, `content-type`, `x-profile-id`, `x-merchant-id`, sometimes `x-feature`, `api-key`).
2. Auth. In demo mode the browser sends `authorization: Bearer simulator-demo` (a placeholder, never a real token). The proxy replaces it with `HS_DASHBOARD_JWT` and overrides `X-Merchant-Id` / `X-Profile-Id`. The browser never holds the JWT.
3. `/api/*` allow-list the dashboard needs (GET only, V2 merchant). The app shell list is a first cut from the code; B will confirm it from a real browser run and append the final list:
   - shell: `GET /api/v2/users/merchant-details`, the user ACL call, the merchant/profile list calls (B to confirm exact paths)
   - connectors: `GET /api/v2/profiles/{profileId}/connector-accounts` (the Invoices page shows only when a billing connector exists), `GET /api/v2/connector-accounts/{id}` (start retry threshold)
   - invoices: `GET /api/v2/payments/recovery-list?...`, `GET /api/v2/payments/recovery-aggregate?...` (also the `/profile/` variants)
   - detail: `GET /api/v2/payments/{id}/get-revenue-recovery-intent`, `GET /api/v2/payments/{id}/list_attempts`, `GET /api/v2/process_tracker/revenue_recovery_workflow/{id}` (note: underscores, not the hyphens in PRD §6)
   - page paths like `/dashboard/v2/recovery/*` must never be forwarded to the sandbox (that is the refresh bug, `IR_02`).
4. Story JSON. Every `/sim/story*` route returns the same `Story` object:
   ```
   {
     "storyId": "st_…", "scenario": 1,
     "invoiceId": "<merchant reference sent to /v2/recovery>",
     "recoveryId": "<global payment id the dashboard APIs use>",
     "startedAt": "ISO-8601",
     "status": "starting|monitoring|queued|scheduled|processing|recovered|partially_recovered|terminated|cancelled|error",
     "nextRetryAt": "ISO-8601 UTC" | null,                 // process tracker schedule_time_for_payment
     "invoice": <raw JSON of GET /v2/payments/{recoveryId}/get-revenue-recovery-intent> | null,
     "attempts": [<raw items of list_attempts → payment_attempt_list>],
     "processTracker": <raw JSON of the process tracker call> | null,
     "now": {"actor": "billing|revrec|processor|customer", "text": "who did what and why"} | null,
     "explain": [{"text": "…", "source": "sandbox|recomputed|rule"}],
     "requests": [{"step": "plain label", "at": "ISO-8601", "request": {"method","url","body"}, "response": {"status","body"}}]   // secrets redacted
   }
   ```
   Raw sandbox JSON lets the front end reuse the invoice page mappers and the attempts table as they are.
   - `POST /sim/story/start` body `{"scenario": 1..8}`. It may return `status: "starting"` with `invoice: null` before the sandbox has the invoice.
   - Errors: `{"error": {"code": "rate_limited|bad_scenario|not_found|upstream", "message": "plain words"}}` with 429 (plus `Retry-After`), 400, 404 or 502.
   - The front end polls `GET /sim/story/:storyId` every 4 s and stops on recovered, terminated, cancelled or error.
5. Session seed. M0: the dashboard reads `org_id`, `merchant_id`, `profile_id` from `[default.simulator]` in config/config.toml (or env `default__simulator__merchant_id` etc.). M4: if the proxy serves the page, it can inject `window.__SIM_SESSION__ = {org_id, merchant_id, profile_id}` and that wins. The front end needs the real profile id, because some paths contain it.

## Orchestrator (2026-10-23) — dashboard token is in simulator/proxy/.env
- `HS_DASHBOARD_JWT` written (377 chars, exp 2026-10-25T16:07Z, role org_admin). It is scoped to the Orchestrator merchant `merchant_1790193509` / profile `pro_3Ey0xhMp02zVffTXQ6Zt`, NOT the Rev Rec merchant.
- Rev Rec demo merchant (sandbox): API merchant id `revenue_recovery_x8gd0pzm6l_MhOXrZKGDMGeVFF7VT17` (dashboard shows `revenue_recovery_x8GD0pZM6l`), profile `pro_2qWOGZLPJQRRY0O75DXg`, billing MCA (Custom) `mca_8sEBJcnLL79XDoOsQiWg`, payment MCA (Stripe test) `mca_QJ26aS0VvDMpjjA3TJOn`. `HS_MERCHANT_ID` in .env currently holds the Orchestrator id; A: set the Rev Rec ids as `HS_REVREC_MERCHANT_ID` / use HS_PROFILE_ID (already the Rev Rec profile).
- Builder A: on startup, exchange the token for a Rev Rec-scoped one with `POST {HS_BASE_URL}/user/switch/merchant` body `{"merchant_id": "<rev rec merchant id>"}` (dashboard calls `user/switch/merchant`; v2 path `v2/user/switch/merchant` also exists), then `user/switch/profile` with `{"profile_id": "pro_2qWOGZLPJQRRY0O75DXg"}`. Use the returned token for all /api pass-through. If the switch fails, log the status code (not the token) in NOTES and Aayush will re-grab a token after switching merchant in the browser.
- Re-grab at any time: `bash simulator/scripts/grab-jwt.sh` (reads localStorage USER_INFO from the logged-in Chrome tab).
- 2026-10-23 14:05 [B] Step 3 done: demo session (flag `simulator_demo_session`, default false in code, true in our config.toml).
  - How: AuthWrapper sets `LoggedIn` with the placeholder token `simulator-demo` (no login screen). UserInfoProvider builds the `/user` shape from `window.__SIM_SESSION__` or `[default.simulator]` (org_id, merchant_id, profile_id) instead of calling `GET /user`; entity_type merchant, version v2. HyperSwitchApp opens the Recovery product. Code: src/RevenueRecovery/Simulator/SimulatorDemoSession.res.
  - Flag off = upstream behaviour: checked in headless Chrome, the login screen shows.
  - Aayush: fill `merchant_id` and `profile_id` (and `org_id`) in `[default.simulator]`, or set env `default__simulator__merchant_id` / `default__simulator__profile_id` before `npm run start`. Empty ids show "Something went wrong".
  - Known gap: on a 401 from the proxy (expired JWT) the app falls back to the login screen. Fine for M0.
  - Final `/api` list the shell and Invoices page call (headless Chrome, demo session, Recovery product). A: please allow these GETs:
    `/api/v2/users/merchant-details`, `/api/user/list/merchant`, `/api/v2/user/list/merchant`, `/api/user/role/v2` (ACL: `{groups, resources}`), `/api/v2/merchant-accounts/{merchantId}` (only when the role has the `account` resource; a 404 here breaks the whole shell), `/api/user/list/org`, `/api/v2/user/list/profile`, `/api/user/data?keys=ProdIntent`, `/api/v2/profiles/{profileId}/connector-accounts`, `/api/v2/payments/recovery-aggregate?…`, `/api/v2/payments/recovery-list?…`, `/api/v2/payments/profile/filter`, plus the detail calls in proposal 3.
- 2026-10-23 14:40 [B] Step 4 done: Rev Rec Home renders locally at http://localhost:9000/dashboard/v2/recovery/home (flag `dev_recovery_simulator`).
  - Card 1 "Try the simulator" (Orchestrator's "Make a test payment / Try It Out" card: CardLayout + CardHeader + primary button, RevenueRecoveryHomePreview.svg) → `/v2/recovery/simulator/story`.
  - Card 2 "Explore Revenue Recovery" (the Explore Workflows card component, DefaultHomeRecoveryCard.svg) → opens the Explore Workflows drawer, gate widened to Recovery, 5 steps from PRD §11. Portfolio and Feature tour steps say "Coming soon".
  - Why not DefaultHomeCard: its button is fixed to "Learn More" and to product switching. The two Orchestrator components give the closest look and placement.
  - Sidebar (flag on): Home, Invoices, Invoice Story, Configuration Details. `/v2/recovery` and unknown Rev Rec paths open Home.
  - Tested against the real proxy (A's, :8787): Rev Rec reads pass (connectors, aggregate, list, filter: 28 real invoices). **Blocker for A:** the proxy returns 403 for 7 shell reads, so without them the app stops at "Oops, we hit a little bump" before any page. Seen in `GET /sim/blocked`:
    `GET v2/users/merchant-details`, `GET user/list/merchant`, `GET user/role/v2`, then (after those pass) `GET v2/user/list/merchant`, `GET v2/merchant-accounts/{merchantId}`, `GET user/list/org`, `GET v2/user/list/profile`, `GET user/data?keys=ProdIntent`.
    Options for A: (a) allow these GETs as pass-through with the Rev Rec-scoped token; or (b) answer them in the proxy from a fixed stub (keeps user and merchant lists out of a public demo): merchant-details `{"product_type":"recovery","merchant_account_type":"standard"}`, role `{"groups":["operations_view","connectors_view","workflows_view","analytics_view","merchant_details_view","account_view"],"resources":["payment","account","connector","analytics"]}`, merchant lists `[{"merchant_id","merchant_name","product_type":"recovery","version":"v2"}]`, org list `[{"org_id","org_name"}]`, profile list `[{"profile_id","profile_name"}]`, user data `{}`, merchant account `{"id","merchant_name","product_type":"recovery"}`. B tested with exactly these stubs. Drop `account` from resources and the merchant-accounts call goes away.
