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

## Contract · B proposals (2026-10-23 13:22) — A, please confirm or edit inline under "A reply"
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
- 2026-10-23 13:28 [B] Step 3 done: demo session (flag `simulator_demo_session`, default false in code, true in our config.toml).
  - How: AuthWrapper sets `LoggedIn` with the placeholder token `simulator-demo` (no login screen). UserInfoProvider builds the `/user` shape from `window.__SIM_SESSION__` or `[default.simulator]` (org_id, merchant_id, profile_id) instead of calling `GET /user`; entity_type merchant, version v2. HyperSwitchApp opens the Recovery product. Code: src/RevenueRecovery/Simulator/SimulatorDemoSession.res.
  - Flag off = upstream behaviour: checked in headless Chrome, the login screen shows.
  - Aayush: fill `merchant_id` and `profile_id` (and `org_id`) in `[default.simulator]`, or set env `default__simulator__merchant_id` / `default__simulator__profile_id` before `npm run start`. Empty ids show "Something went wrong".
  - Known gap: on a 401 from the proxy (expired JWT) the app falls back to the login screen. Fine for M0.
  - Final `/api` list the shell and Invoices page call (headless Chrome, demo session, Recovery product). A: please allow these GETs:
    `/api/v2/users/merchant-details`, `/api/user/list/merchant`, `/api/v2/user/list/merchant`, `/api/user/role/v2` (ACL: `{groups, resources}`), `/api/v2/merchant-accounts/{merchantId}` (only when the role has the `account` resource; a 404 here breaks the whole shell), `/api/user/list/org`, `/api/v2/user/list/profile`, `/api/user/data?keys=ProdIntent`, `/api/v2/profiles/{profileId}/connector-accounts`, `/api/v2/payments/recovery-aggregate?…`, `/api/v2/payments/recovery-list?…`, `/api/v2/payments/profile/filter`, plus the detail calls in proposal 3.
- 2026-10-23 13:34 [B] Step 4 done: Rev Rec Home renders locally at http://localhost:9000/dashboard/v2/recovery/home (flag `dev_recovery_simulator`).
  - Card 1 "Try the simulator" (Orchestrator's "Make a test payment / Try It Out" card: CardLayout + CardHeader + primary button, RevenueRecoveryHomePreview.svg) → `/v2/recovery/simulator/story`.
  - Card 2 "Explore Revenue Recovery" (the Explore Workflows card component, DefaultHomeRecoveryCard.svg) → opens the Explore Workflows drawer, gate widened to Recovery, 5 steps from PRD §11. Portfolio and Feature tour steps say "Coming soon".
  - Why not DefaultHomeCard: its button is fixed to "Learn More" and to product switching. The two Orchestrator components give the closest look and placement.
  - Sidebar (flag on): Home, Invoices, Invoice Story, Configuration Details. `/v2/recovery` and unknown Rev Rec paths open Home.
  - Tested against the real proxy (A's, :8787): Rev Rec reads pass (connectors, aggregate, list, filter: 28 real invoices). **Blocker for A:** the proxy returns 403 for 7 shell reads, so without them the app stops at "Oops, we hit a little bump" before any page. Seen in `GET /sim/blocked`:
    `GET v2/users/merchant-details`, `GET user/list/merchant`, `GET user/role/v2`, then (after those pass) `GET v2/user/list/merchant`, `GET v2/merchant-accounts/{merchantId}`, `GET user/list/org`, `GET v2/user/list/profile`, `GET user/data?keys=ProdIntent`.
    Options for A: (a) allow these GETs as pass-through with the Rev Rec-scoped token; or (b) answer them in the proxy from a fixed stub (keeps user and merchant lists out of a public demo): merchant-details `{"product_type":"recovery","merchant_account_type":"standard"}`, role `{"groups":["operations_view","connectors_view","workflows_view","analytics_view","merchant_details_view","account_view"],"resources":["payment","account","connector","analytics"]}`, merchant lists `[{"merchant_id","merchant_name","product_type":"recovery","version":"v2"}]`, org list `[{"org_id","org_name"}]`, profile list `[{"profile_id","profile_name"}]`, user data `{}`, merchant account `{"id","merchant_name","product_type":"recovery"}`. B tested with exactly these stubs. Drop `account` from resources and the merchant-accounts call goes away.

## Builder A (proxy) log
- 2026-10-23 13:42 [A] **M0 runnable** on http://127.0.0.1:8787. Run: `cd simulator/proxy && npm install && npm start`. Commits 42aecb877, ef9516083, 6f42c647e.
  - `GET /healthz` is green: sandbox 200 (28 invoices), Stripe test mode, config complete, dashboard token switched.
  - Dashboard token: at startup the proxy sends the pasted Orchestrator token to `POST v2/user/switch/merchant` with the Rev Rec merchant id. Result: 200, and the new token is already scoped to profile `pro_2qWOGZLPJQRRY0O75DXg` (no profile switch needed). Org `org_zS11mfgp7UAPtCdunDYj`. The proxy never uses a token for another merchant. `HS_REVREC_MERCHANT_ID` is now in .env. `/healthz` → `dashboard` shows ids, expiry and switch status codes (never the token).
  - `/api/*` allow-list (GET only), all 200 with the switched token: recovery-list and recovery-aggregate (merchant and `/profile/`), `v2/payments/profile/filter`, `get-revenue-recovery-intent`, `list_attempts` / `list-attempts`, process tracker (both spellings), `v2/profiles/{id}`, `v2/profiles/{id}/connector-accounts`, `v2/connector-accounts/{id}`. Everything else: 403 `{error:{type:"invalid_request", code:"SIM_BLOCKED", message}}`. List of recent blocked calls: `GET /sim/blocked`.
  - Shell reads (B's list, 13:34) are answered by stubs in `src/shell.ts`, header `x-sim-auth: stub`, merged with the orchestrator's values. `v2/merchant-accounts/{id}` answers only for the demo merchant.
  - **Scenario 1 proven on the sandbox**: story `st_403581a10106`, invoice `SIM-1-mvlfjb6b-fea2`, payment `0a_pay_01a16a7a1e197f61bb926077b08aa64b`. Monitoring → Scheduled (EXECUTE task booked 20:36:57Z, about 1 min after start) → Paid in app → Recovered, `recoveredBy: "billing"` ("paid outside Rev Rec"). The booked task still ran at 20:36:57Z and finished `COMPLETED_EXECUTE_TASK_TO_TRIGGER_REVIEW` without a charge.
- Findings
  1. **The sandbox schema changed again.** `POST /v2/recovery` now refuses `action` (400 "unknown field action"). Upstream main (`crates/router/src/core/revenue_recovery/api.rs`) syncs the reported transaction with the payment connector and picks the action from that status: `failure` = schedule retries, `charged` = paid outside Rev Rec. New fields: `amount_captured` (charged only, must equal the order amount), `customer_present` (bool, default false), `customer_details`. `transaction_status` is now `charged | failure | partial_charged`. `/v2/recovery` and `/v2/payments/recovery` share the same schema. The prototype server.mjs fails today.
  2. **Start rule is 2, not 0.** Billing MCA `mca_8sEB…`: `billing_connector_retry_threshold` 2, `max_retry_count` 8, `grace_period_days` 30. Profile retry mode `cascading`. PRD §12 says 0 and 15. The proxy adapts: at start, the billing simulator makes (start rule + 1) real failed charges, its own retries, and reports each one. **Aayush to decide:** set start rule 0 and max retries 15 on the demo profile? I did not change the shared config.
  3. Upstream now has `POST /v2/recovery/{merchant_reference_id}/cancel`. Not tried on the sandbox yet. It could back the Cancelled state and Reset.
  4. **Security note:** the profile read returns `payment_response_hash_key` (the webhook signing key). The proxy now hides any field named like secret, password, hash_key or api_key. Before that fix, the value showed once in my own terminal output during a test. It was not committed or sent anywhere else. Rotating it on the sandbox profile is cheap if wanted.
  5. The profile `webhook_url` still points to the old trycloudflare tunnel from the prototype.

## A reply to B proposals (13:22)
1. CORS: done, with an origin allow-list instead of `*` (localhost:9000 and 127.0.0.1:9000; env `ALLOWED_ORIGINS`). Preflight 204, methods GET, POST, PUT, DELETE, OPTIONS, request headers echoed, `x-sim-auth` exposed.
2. Auth: yes. The proxy ignores every browser auth header, so `Bearer simulator-demo` is fine. It sets its own Authorization, X-Merchant-Id and X-Profile-Id.
3. Allow-list: done (see above). Shell reads are stubs, not pass-through.
4. Story JSON: adopted. Every `/sim/story*` route, `start` included, returns the same object:
   - Your fields: `storyId`, `scenario` (number), `invoiceId`, `recoveryId`, `startedAt`, `status`, `nextRetryAt`, `invoice` (raw intent), `attempts` (raw `payment_attempt_list`), `processTracker` (raw), `now` `{actor, text, why}`, `explain` `[{id, text, source}]`, `requests` `[{step, at, system:"stripe"|"sandbox", request:{method,url,headers,body}, response:{status,body}, ms}]`. Secrets are hidden.
   - `status`: starting | monitoring | queued | scheduled | processing | recovered | partially_recovered | terminated | cancelled | error. The sandbox word is in `sandboxStatus`; the sandbox says `succeeded` for paid.
   - Extra fields: `stage` and `stageCaption` (stepper name and plain caption), `recoveredBy` ("revrec" | "billing" | null), `summary` (flat invoice facts), `attemptSummary` (flat attempts, `by`: billing | revrec), `timeline` `[{at, from, to, text, source}]` (arrows for the four boxes), `actions` `{paidInApp, reportAgain, reportAgainMode}`, `warnings[]`, `lastReads[]`, `scenarioInfo`, `startError`.
   - `nextRetryAt` is null once the story is final, even if the sandbox still has a booked task.
   - `start` is synchronous, about 9 s for 3 failures. It returns status `monitoring` or later, not `starting`.
   - Errors: `{error:{code, message}, storyId?}` with codes `bad_scenario` (400), `not_found` (404), `not_available` (409: scenario not runnable yet, or already paid), `rate_limited` (429 + Retry-After), `upstream` (502).
   - Scenario picker data: `GET /sim/scenarios` (8 rows with `v1Status`, `runnable`, `hint`). Runnable today: 1, 2, 3.
   - `POST /sim/story/:id/report-again` takes optional `{mode: "duplicate" | "new" | "swap"}`; the default comes from the scenario.
5. Session seed: use org `org_zS11mfgp7UAPtCdunDYj`, merchant `revenue_recovery_x8gd0pzm6l_MhOXrZKGDMGeVFF7VT17`, profile `pro_2qWOGZLPJQRRY0O75DXg`. They are also in `/healthz` → `dashboard.scoped`.
- 2026-10-23 13:51 [A] **Scenarios 2 and 3 proven on the sandbox.** Commit daf391da5.
  - Scenario 2 (try_again_later, saved card 4242): story `st_1f843ddfdb8a`, payment `0a_pay_01a16a80b1197ca3958d3eb3bc92280b`. Monitoring (about 28 s) → Scheduled (retry booked 20:44:38Z) → Processing → **Recovered by Rev Rec** at 20:45:00Z, `recoveredBy: "revrec"`. About 2 min in total. Task `COMPLETED_EXECUTE_TASK`.
  - Scenario 3 (duplicate): story `st_179854639f59`, payment `0a_pay_01a16a8370a07a83bca1009ba4c934c1`. **Changed behaviour:** the sandbox now answers the copy with **400 "The transaction pi_… is already recorded against the invoice SIM-3-…"**. On 14 Oct it answered 200 and silently ignored it. One attempt kept, retry count 1. The story treats the 400 as the expected outcome.
  - With start rule 2, scenario 3 stays in Monitoring (one failure). New field `done: boolean` in the story view: true at a final stage, on error, or once scenario 3 has shown the refused copy. **B: stop polling on `done`**, not only on final statuses.
  - `npm test` passes: 28 offline unit tests, plus 1 live scenario-1 run on the sandbox (about 54 s; skips without .env). README at `simulator/proxy/README.md`.
  - The proxy is running on :8787 with the default limit (5 starts per hour per IP). For heavy local testing, start it with `RATE_LIMIT_STARTS_PER_HOUR=30 npm start`.
- 2026-10-23 13:51 [B] Step 5 done: Invoice story screen at `/v2/recovery/simulator/story` (and `/story/{storyId}`, so a refresh or a shared link resumes the story).
  - Reads A's story view as built (superset of my proposal): `stage`, `stageCaption`, `now {actor,text,why}`, `explain [{text,source}]`, `timeline [{from,to,text}]`, `requests`, `actions`, `warnings`, raw `invoice` / `attempts` / `processTracker`. Scenario list from `GET /sim/scenarios`.
  - Layout per PRD §7: scenario picker (8 cards, V1 status tag; not-runnable ones dimmed), left state stepper, centre flow (Billing system, Rev Rec, Processor, Customer) with an animated arrow for the latest event, right Now card (countdown to the booked retry) + Why panel (source label per line), bottom the invoice page's AttemptsHistory, optional Requests panel. Controls: Play, Pause/Resume polling, Paid in app, Report another failure, Reset, Show requests. Polls every 4 s; stops at Recovered, Terminated, Cancelled or Error.
  - Honesty: at an end state the stepper marks a step done only if the data shows it (process tracker present → Queued/Scheduled; a Rev Rec attempt → Processing). Otherwise "Skipped". Example: scenario 1 paid outside before any retry shows Processing as skipped.
  - Tested in headless Chrome against the real proxy: opened A's story st_403581a10106 (scenario 1, Recovered, paid outside), and played one real scenario 2 story (st_7124b5a25025): start 200, Recovered by Rev Rec's own retry on 4242 in about 1 min. One of the 5 starts/hour used.
  - A: `now.why` and the explain lines read well. Small asks: (1) a `stageHistory` (stage + first-seen time) would let the stepper show times per step; (2) `/sim/story/start` took ~19 s for scenario 2 (3 Stripe charges + 3 reports); fine, the Play button shows a spinner.
