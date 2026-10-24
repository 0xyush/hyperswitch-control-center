- 2026-10-23 13:15 plan written; fork cloned from 0xyush/hyperswitch-control-center at 75ba7c1e7

## Contract (proxy <-> dashboard) — Builder A writes, Builder B reads; both may append questions

- Base URL: http://localhost:8787
- GET /healthz -> {ok, sandbox, stripe, config}
- POST /sim/story/start {scenario: 1..8} -> {storyId, invoiceId, recoveryId, startedAt}
- GET /sim/story/:storyId -> {status, invoice, attempts[], nextRetryAt, explain:[{text, source:"sandbox"|"recomputed"|"rule"}], requests:[{step, request, response}]}
- POST /sim/story/:storyId/paid-in-app, /report-again -> same shape as GET
- /api/\* -> allow-listed pass-through to the sandbox with auth headers added
- **Header `x-sim-session`** (added 2026-10-23 by A, commit 5ccdf3486): the dashboard sends it on every `/sim/*` call. Value = a random id, 8 to 64 characters of `A-Z a-z 0-9 _ -`, made once and kept in the browser's localStorage. It identifies the visitor for `customer: "same"` and for the start limit (5 per hour per session; plus 30 per hour per IP). Missing or malformed: the proxy uses the IP. CORS allows it.

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
  - Scenario 3 (duplicate): story `st_179854639f59`, payment `0a_pay_01a16a8370a07a83bca1009ba4c934c1`. **Changed behaviour:** the sandbox now answers the copy with **400 "The transaction pi\_… is already recorded against the invoice SIM-3-…"**. On 14 Oct it answered 200 and silently ignored it. One attempt kept, retry count 1. The story treats the 400 as the expected outcome.
  - With start rule 2, scenario 3 stays in Monitoring (one failure). New field `done: boolean` in the story view: true at a final stage, on error, or once scenario 3 has shown the refused copy. **B: stop polling on `done`**, not only on final statuses.
  - `npm test` passes: 28 offline unit tests, plus 1 live scenario-1 run on the sandbox (about 54 s; skips without .env). README at `simulator/proxy/README.md`.
  - The proxy is running on :8787 with the default limit (5 starts per hour per IP). For heavy local testing, start it with `RATE_LIMIT_STARTS_PER_HOUR=30 npm start`.
- 2026-10-23 13:51 [B] Step 5 done: Invoice story screen at `/v2/recovery/simulator/story` (and `/story/{storyId}`, so a refresh or a shared link resumes the story).
  - Reads A's story view as built (superset of my proposal): `stage`, `stageCaption`, `now {actor,text,why}`, `explain [{text,source}]`, `timeline [{from,to,text}]`, `requests`, `actions`, `warnings`, raw `invoice` / `attempts` / `processTracker`. Scenario list from `GET /sim/scenarios`.
  - Layout per PRD §7: scenario picker (8 cards, V1 status tag; not-runnable ones dimmed), left state stepper, centre flow (Billing system, Rev Rec, Processor, Customer) with an animated arrow for the latest event, right Now card (countdown to the booked retry) + Why panel (source label per line), bottom the invoice page's AttemptsHistory, optional Requests panel. Controls: Play, Pause/Resume polling, Paid in app, Report another failure, Reset, Show requests. Polls every 4 s; stops at Recovered, Terminated, Cancelled or Error.
  - Honesty: at an end state the stepper marks a step done only if the data shows it (process tracker present → Queued/Scheduled; a Rev Rec attempt → Processing). Otherwise "Skipped". Example: scenario 1 paid outside before any retry shows Processing as skipped.
  - Tested in headless Chrome against the real proxy: opened A's story st_403581a10106 (scenario 1, Recovered, paid outside), and played one real scenario 2 story (st_7124b5a25025): start 200, Recovered by Rev Rec's own retry on 4242 in about 1 min. One of the 5 starts/hour used.
  - A: `now.why` and the explain lines read well. Small asks: (1) a `stageHistory` (stage + first-seen time) would let the stepper show times per step; (2) `/sim/story/start` took ~19 s for scenario 2 (3 Stripe charges + 3 reports); fine, the Play button shows a spinner.
- 2026-10-23 13:53 [B] Step 6 done: refresh on `/dashboard/v2/recovery/*` renders the app.
  - Cause (review F55, `IR_02`): the hosted sandbox sends page paths to the API router. Locally the webpack dev server already falls back to index.html for `/dashboard/*` (and any other HTML request), so no webpack change was needed. The app side is now covered: every simulator page is a registered route, unknown Rev Rec paths open Home or the story screen, and the story id is in the URL, so a refresh resumes the story.
  - Check: `node simulator/scripts/check-refresh.mjs --browser [--story st_xxx]` (dev server must run). It asks each path like a browser refresh (must be HTML, not JSON), then opens it in headless Chrome, reloads, and expects the page text. Result now: 12 of 12 ok.
  - For A / M4: the same check against :8787 fails (`{"error":{"code":"not_found"…}}` for `/dashboard/v2/recovery/*`). If the proxy ever serves the dashboard, it must return index.html for every page path that is not `/api/*`, `/sim/*` or `/healthz`. Run the script with `--base <url>` against the deployed host.

## How to run locally (for Aayush) — B, 2026-10-23

Use two terminals. Terminal 1 (proxy): `cd simulator/proxy && npm install && npm start`. It needs `simulator/proxy/.env` filled in, listens on http://localhost:8787, and `curl -s localhost:8787/healthz` should say `"ok": true`. Terminal 2 (dashboard): from the repo root, `npm install`, then `npm run re:build`, then `npm run start` (add `npm run re:start` in a third terminal only if you edit `.res` files). Open http://localhost:9000/dashboard/v2/recovery/home: no login, the demo session opens the Rev Rec module. The Invoice story is at http://localhost:9000/dashboard/v2/recovery/simulator/story, and the Invoices list at http://localhost:9000/dashboard/v2/recovery/invoices. If a page shows "Oops", check the proxy terminal and `curl -s localhost:8787/sim/blocked` for blocked calls. To check that a refresh works, run `node simulator/scripts/check-refresh.mjs --browser` while the dashboard is up.

- 2026-10-23 13:58 [A] Probes asked by the orchestrator. Commit abdf55be4.
  - **Cancel works on the sandbox.** `POST /v2/recovery/{merchant_reference_id}/cancel` (API key, no body) returned **200** `{"intent_status":"cancelled"}` on a Monitoring invoice (`SIM-3-mvlfwbfj-8539`) and on an invoice in active retries (`SIM-7-mvlg6850-0ea4`). The invoice list then shows `cancelled`. New proxy action: `POST /sim/story/:id/cancel` (story view gets `actions.cancel`). It can back the Cancelled state and a Reset that stops stale demo invoices. PRD §15 "Cancel API returns 404" is out of date.
  - **The sandbox now records Stripe's real decline, not the reported reason.** Scenario 2 reported `try_again_later` (code 19); the attempt shows `generic_decline` (code 01), which is what card 0341 really returns. The decline reason is no longer data the simulator can choose (PRD §7 and the scripted bank in §8 assume it is). To get a given reason, the charge must really fail that way at Stripe (test cards: 9979 stolen, 9995 insufficient funds, and so on). The explain panel now shows the recorded decline (source `sandbox`) next to the reported one; `summary.recordedReason` is new.
  - **Hard-decline probe (scenario 7): no stop.** Story `st_e15f47dac3f1`, payment `0a_pay_01a16a8a7e867243a3ce872873193c20`. The billing system's 3 charges failed at Stripe as stolen cards (card 9979, charged one-off because Stripe refuses to save it). The sandbox recorded `card_declined / stolen_card / network code 43`. Rev Rec still took over and retried the saved card 0341 at 20:54:30Z and 20:57:00Z (`FAILED_EXECUTE_TASK`, then booked again). Then I cancelled it. **Ask 7 is still open:** no hard-decline row in the error catalogue matches Stripe's stolen card. A row likely needs to match on Stripe's `decline_code`, because Stripe's `code` is `card_declined` for every decline. Scenario 7 stays not runnable; start the proxy with `SIM_ENABLE_SCENARIOS=7` to repeat the probe.

## Contract · B asks for the story redesign (REDESIGN-story.md §4) — 2026-10-23 18:15

A, the redesigned story screen will read these. Until they land, B falls back to today's fields.

1. `POST /sim/story/start` body: `{preset: 1..8, amount: 65.40, currency: "USD", card: "4242"|"0341"|"9995"|"9979"|"0002", customer: "new"|"same"}`. `amount` is in major units (B can send minor units instead if you prefer; say which). Preset fills defaults; explicit fields win. B also sends `scenario` = `preset` so today's proxy keeps working.
   - `customer: "same"` = reuse the Stripe customer of the visitor's last story. If there is none, please answer 409 `not_available` with a plain message.
2. `timeline[]` entries: `{stepId, at, from, to, label, status, why?}`.
   - `from` / `to`: billing | revrec | processor | customer. `from == to` is fine for a self-step (for example Rev Rec "pick retry time").
   - `label`: short, for the arrow ("charge $65.40 → declined (generic_decline)", "report failure → 200 recorded", "pick retry time → 20:44:38", "charge saved card → approved", "mark invoice paid").
   - `status`: ok | declined | error | info. B colours the arrow by it.
   - `why` (optional): `[{text, source}]` for that step only. If absent, the drawer shows the story-level `explain`.
3. `requests[]` entries carry the same `stepId`, so a click on a diagram row shows its raw request and response. One step can have several requests.
4. Attempts: if a timeline row is a charge, please add `attemptId` (the sandbox attempt id), so a click on an attempt row opens the same step.
5. `actions.cancel`: seen, thanks. B shows Cancel invoice in the form's kebab menu.

## A reply to B asks for the story redesign (18:15) — 2026-10-23 18:28, live on :8787 (commits f94d43aca, 0f015dc49)

1. **Start body**: `{preset?, amount, currency, card, customer}`. A preset fills defaults; explicit fields win. `scenario` is still read as `preset`.
   - **`amount` is in minor units** (6540 = 65.40), an integer from 50 to 1000000. 65.40 gets 400, so send minor units. `currency`: USD, EUR or GBP (only USD tested).
   - A story needs two cards. The single `card` field picks both. 4242 = saved card 4242, first charge fails on 0002. 0341 = 0341 for both. 0002, 9995 or 9979 = that card for the first charge, saved card 0341. Optional `savedCard` (4242 | 0341) and `firstCharge` (0341 | 0002 | 9995 | 9979) set each card on its own. The story view echoes them in `form`.
   - `customer: "same"` = the visitor's last Stripe customer (visitor = hash of the IP). If there is none: **409 `not_available`**. On localhost every visitor has the same IP, so "same" can reuse another tester's customer.
   - **Start returns at once** with `status: "starting"` (about 30 ms). The billing system's steps then run in the background, and each one shows up in `timeline` as you poll. Poll every 1 to 2 s while `starting`, then every 4 s.
   - `GET /sim/presets` → `{presets: [{id, title, summary, fields: {amount, currency, card, customer, savedCard, firstCharge}, v1Status, verified, hint, …}], cards: [{id, label, behaviour, savable, declineCode}], currencies}`. Use it to fill the form and the card dropdown. `/sim/scenarios` answers the same.
2. **Timeline entries**: `{stepId, at, from, to, label, text, status, source, why[], attemptId}`.
   - `status`: ok | declined (Stripe said no) | refused (the sandbox said no; your "error") | pending (a booked retry that has not run: draw it dashed, `at` = the booked time, always the last row) | info (a note on one lifeline, `from == to`).
   - `why` is always there (it may be empty): `[{text, source}]` for that step. `text` is one sentence for the drawer.
   - Steps from the sandbox: "pick retry time → 01:23:20" (revrec → revrec, when the process tracker shows a new booking), "charge saved card ••4242 → approved" (Rev Rec's own attempts, stepId `att_<attemptId>`), "invoice recovered → mark paid" or "invoice paid outside Rev Rec" (revrec → billing, once at the final status).
3. `requests[]` entries carry `stepId`. Every step has one, except the "same customer" note. Steps from the sandbox have their GET read as the request (`ms: null`).
4. **`attemptId`** is on every charge row: the billing system's charges, Rev Rec's charges and the in-app payment. Otherwise it is null.
5. `actions`: `{paidInApp, reportAgain, cancel, reportAgainMode}`. All false while `starting`.
6. Also new: `stageHistory: [{stage, firstSeenAt, source}]`. `source: "sandbox"` = from an attempt's own timestamp (Monitoring, Processing, Recovered). `"observed"` = when the proxy first saw it at a poll, so up to one poll late (Queued, Scheduled). Stages are recorded only while someone polls.
   - Removed: `now` and `scenarioInfo` (now `presetInfo`).
   - Stories started before f94d43aca are not in the new store, so old story URLs answer 404.

- Verified on the sandbox with the new flow: preset 2 (saved 4242, first charge 0002) Recovered by Rev Rec in 50 s; preset 1 paid outside Rev Rec; preset 3 refused copy and `done`; preset 8 reused the last customer (then cancelled). `npm test` passes (31 unit + live).
- 2026-10-23 18:29 [A] `x-sim-session` header live on :8787 (commit 5ccdf3486); see the Contract section at the top. B: send it on every `/sim/*` call. Also: a story caught by a proxy restart in the middle of its start now shows `status: "error"` with `startError` (it no longer stays `starting` forever).
- 2026-10-23 18:32 [B] Invoice story rebuilt to simulator/REDESIGN-story.md. The old screen (scenario cards, 4 boxes, moving arrow, Now card, always-on Why panel, stepper) is gone.
  - Left: "Billing system" form in the SDK "Try It Out" layout. Preset dropdown (fills the fields from `GET /sim/presets`), amount, currency, card (list from the proxy), customer, **Charge customer**; **Customer pays in app** once an invoice exists; kebab: Report another failure, Cancel invoice, Start over.
  - Right: "What happened" sequence diagram (4 lifelines, one thin arrow per `timeline` row, time right-aligned in muted grey, the proxy's `pending` row dashed with a countdown), then the real invoice page components (RecoveryAmountStatus, OrderDetailsCard, AttemptsHistory) fed by the story's raw sandbox JSON. They are stacked, because the panel is narrower than the invoice page.
  - Explain on click only: a diagram row or an attempt row opens the dashboard's side Modal with the step sentence, who → who, time, the row's `why` lines with source labels, and its raw calls (matched by `stepId`). Attempt rows find their step by attempt id (in `attemptId`, `text` or `why`).
  - Reads A's new contract as served now: `/sim/presets` (`presets[].fields`, `cards`, `currencies`), start body `{preset, amount (minor units), currency, card, customer}`, timeline `{stepId, at, from, to, label, text, status, why}`, `requests[].stepId`, `actions.cancel`, `form`. A reopened story fills the form from `form`.
  - Shared change: `RecoveryInvoicesHelper.AttemptsHistory` takes an optional `~onAttemptClick`; without it the invoice page is unchanged. `simulatorConfig` moved to `SimulatorConfigTypes` (dependency cycle).
  - Tested in headless Chrome on the real proxy: preset 2 story st_7bf8bc687160, Charge customer → 11 rows → Recovered by Rev Rec's retry in about 1.5 min; row and attempt drawers show the linked Stripe and sandbox calls. Refresh check 12/12.
  - Screenshots: simulator/screenshots/invoice-story-1-start.png, -2-recovered.png, -3-row-drawer.png, -4-attempt-drawer.png.
  - Feature tour, stageHistory reading and the glossary drawer are parked in `git stash` ("B WIP paused 23 Oct").
- 2026-10-23 18:38 [A] **Scenario 6 swap spike: PASSED.** The scripted bank can work. Commit 064a01819.
  - Story `st_5e2776d00d4e`, payment `0a_pay_01a16b8a24a17ff1a2d69f1865b59c16`, cascading profile `pro_2qWO…`. First charges on Stripe card 9995 (insufficient_funds), saved card 0341.
  - 01:32:57–01:33:01Z: 3 billing failures (insufficient_funds), reported with the 0341 token.
  - 01:34:30Z: Rev Rec retried 0341, declined.
  - 01:34:35Z: the swap: a new failed charge (9995), reported with the **4242** token.
  - 01:36:07Z: Rev Rec booked a retry for 01:36:26Z.
  - 01:36:30Z: **Rev Rec charged 4242, approved, Recovered** (`recoveredBy: "revrec"`). The story took 3.6 min. The invoice token is now the 4242 payment method; `card_attached` is 2.
  - So in cascading mode, Rev Rec retries the token of the latest report. Still to check on a smart profile, where Rev Rec picks among the customer's tokens.
  - Side finding: the attempts list shows card **0341** on the billing charges that really failed on 9995. The sandbox keeps the reported card details (`last4`) and takes only the decline from Stripe. Diagram labels now name the charged card ("charge $65.40 on ••9995 → declined (insufficient_funds)"), and the drawer explains the difference.
  - Preset 6 is now `verified: true` ("Ready (spike passed 23 Oct)"). `PORTFOLIO.md` open questions 4 and 5 are updated.
  - The proxy restart for these label changes waits until the browser is idle; until then, :8787 still serves the old labels.
- 2026-10-23 18:43 [B] Story polish, Feature tour, glossary.
  - Story form: amount shows two decimals (65.40; a text input, formatted on blur). The Billing system panel was already sticky at xl widths; it now keeps a top gap.
  - Feature tour at `/v2/recovery/simulator/tour` (sidebar: Feature Tour, under Invoice Story). 9 live / read-only panels and 7 display-only panels from PRD §9, each tagged. Real values via the proxy's `/api` pass-through (the same reads as Configuration Details): profile → retry mode; billing connector → start rule, max retries, grace period, partial authorization. Today: static retries (cascading), start rule 2, max retries 8, 30 days, partial authorization off. No writes. "See it in the invoice story" opens the story with `?preset=N`.
  - Glossary drawer (PRD §20 terms, plus webhook from §10): first mention of a term is underlined in tour panels, story drawer explanations and Explore drawer steps; a click opens the drawer at that term. Also a Glossary button on the tour.
  - Display-only panel texts are my plain-words summaries of the PRD feature names; please review the wording.
  - Checked in headless Chrome on the real proxy; refresh check 14/14. Screenshots: simulator/screenshots/feature-tour.png, glossary-drawer.png.
- 2026-10-23 18:54 [B] Portfolio run screen at `/v2/recovery/simulator/portfolio` (and `/portfolio/{runId}` so a refresh resumes; sidebar: Portfolio Run, under Invoice Story). Built to PORTFOLIO.md §5 and A's `portfolioView` in portfolio.ts.
  - Left (Try It Out layout): invoices 10 / 25, amount, decline-mix sliders (5 reasons, soft/hard, share in %), card mix shown as "Visa 100%" (disabled until PORTFOLIO.md Q5 is answered), Run; Stop run while running.
  - Right: progress (copies final, "compressed time"), four Intelligent Routing result cards (recovery rate, recovered amount, Rev Rec attempts per recovery, median minutes to recovery) with columns "Static retries" | "Rev Rec", a bar chart by decline reason (ColumnGraph) with the bank rules under it, a recovered-over-time line (LineGraph), and the invoice table (status + attempts per side; a status opens that copy's story).
  - Every value has a source chip: re-computed / sandbox / "Bank: scripted". In fixture mode they all read "Fixture".
  - **Fixture:** the running proxy has no portfolio routes yet (old build, or SIM_PORTFOLIO off). Run then shows a built-in fixture in the same shape (SimulatorPortfolioUtils.fixtureText) under a "Fixture data, not a sandbox run" banner; table links are off. Remove the fallback once A's endpoint is live.
  - Body sent to `POST /sim/portfolio/start`: `{invoices, amount (minor units), mix: {reason: weight>0}}`. A: 25 invoices needs `maxInvoices` ≥ 25 (default 10).
  - Shared change: `IntelligentRoutingAnalytics.Card` takes optional `baselineLabel`, `modelLabel`, `lowerIsBetter`, `titleAccessory`; the defaults keep Intelligent Routing unchanged.
  - Explore drawer: "Run a portfolio" and "Tour the features" now link to their pages (no "Coming soon" left).
  - Checked in headless Chrome against the real proxy (fixture path). Refresh check 16/16. Screenshots: simulator/screenshots/portfolio-start.png, portfolio-fixture.png.
- 2026-10-23 18:56 [A] **Portfolio engine (M2) built behind `SIM_PORTFOLIO=1`, and one live run passed.** Commits 7e5f82b7a, cbb8cd874, 063eece4a.
  - API: `POST /sim/portfolio/start {invoices ≤ 10, amount, mix, maxMinutes 5–45, seed}`, `GET /sim/portfolio/:runId`, `POST /sim/portfolio/:runId/stop`, `GET /sim/portfolio`. 1 run at a time for the proxy; 1 per session per hour. The result shape is as in PORTFOLIO.md §5, plus `bankRules` and `warnings`.
  - How it works: each copy is an ordinary story (`GET /sim/story/:id` opens it) with its own Stripe customer and `profile` static or smart. All copies share one queue (≤ 5 Stripe or sandbox calls per second). Every 30 s: the bank flips that are due (swap report with the 4242 token for both copies), one `recovery-list` read per profile, attempts only for copies that changed, and a trend point. At the end, open copies are cancelled.
  - Both sides use `pro_2qWO…` (cascading) until the smart profile exists. The view says: "A difference between the two cards is noise, not strategy."
  - **Live run `pf_3c2015dd`** (on a second instance, :8788, so :8787 was not touched): 3 invoices × 2 copies, seed 42, 10-min cap.
    - processing_error (Stripe card 0119): flip at 1 min; both copies Recovered by Rev Rec (median 1.6 min).
    - generic_decline (0002): flip at 5.5 min; Recovered at 6.2 min (static copy) and 7.7 min (smart copy).
    - expired_card (0069): never flips; both copies kept retrying and were cancelled at the cap.
    - Cards: static 2/3 recovered, 7 Rev Rec attempts; smart 2/3, 9 attempts. **Same strategy on both sides, so this is the sandbox's noise: about 1.5 min and 2 attempts.** Smaller differences mean nothing.
    - Stripe cards 0119 (processing_error) and 0069 (expired_card) work.
  - Setup with start rule 2 takes about 20 s per invoice (3 failed charges per copy). With start rule 0 it would be about 3 times faster.
  - **Operator setup script written, not run:** `npm run setup:profiles` (plan) / `-- --apply` (writes). It creates `sim-static` (cascading) and `sim-smart` (smart): profile → `PUT` retry mode → Stripe payment connector (key from .env) → Custom billing connector (start rule 0, max retries 15, grace 30, `billing_account_reference` to the new payment connector). It clones `payment_methods_enabled` and `metadata` from the existing pair and prints the `HS_STATIC_*` / `HS_SMART_*` lines for .env. It waits for Aayush's approval.
- 2026-10-23 18:57 [A] :8787 restarted with `SIM_PORTFOLIO=1` and `RATE_LIMIT_STARTS_PER_HOUR=30` (idle, nothing starting). B has the go for one real 10-invoice portfolio run (suggested `maxMinutes: 20`). New in the portfolio view: `comparison: {sameStrategy, label, source}`. The label reads "Same strategy on both sides, differences are sandbox timing noise" while both sides share a profile or a mode (commit de3395bde). `setup-profiles --apply` is on hold for Aayush.
- 2026-10-23 18:57 [B] Operator page at `/v2/recovery/simulator/health` (simulator flag; URL only, not in the sidebar). Plain tables: checks from `/healthz` (sandbox, Stripe test mode, config presence, dashboard token with expiry), both tokens, merchant switch steps, limits, `/sim/blocked`, `/sim/stories` (ids open the story), `/sim/portfolio` runs. Refreshes every 30 s; each read can fail on its own.
  - **Ask for A:** please add `limits` to `/healthz`, for example `{"storyStartsPerHour": 5, "portfolioRunsPerHour": 1, "portfolioMaxInvoices": 10, "portfolioEnabled": true}`. The page lists whatever keys are there.
  - Screenshot: simulator/screenshots/health.png.
- 2026-10-23 19:05 [A] **M4 prep done, nothing deployed.** Commits 2734dea92, 4fadb32a3.
  - **Hourly contract test** (`src/contract.ts`). It runs 20 s after start, then every hour (`SIM_CONTRACT_TEST=0` turns it off), and writes nothing.
    - `POST /v2/recovery` is sent the simulator's real failure and charged bodies plus one unknown field, so the sandbox refuses them while parsing. The "expected one of …" list shows request fields that are gone or new; a nested "missing field" shows a newly required field.
    - Read-back of the invoice list, invoice detail, attempts, process tracker (on an invoice with a booked retry) and billing connector, checking every field the proxy reads.
    - `/healthz` → `contract` shows the last result and `drift`; `ok` turns false on a failed contract.
    - First run on the sandbox: **7/7 checks passed in 2 s, no drift.** An offline test with a fake sandbox shows the drift detection fires.
  - `TRUST_PROXY=1`: the client IP comes from `X-Forwarded-For` (needed behind Cloud Run for the rate limits and the visitor fallback).
  - **Dockerfile** (`simulator/proxy/Dockerfile`): node 24 slim, no build step, runs as `node`, `.env` never in the image. Built and smoke-run locally: healthz green, blocked paths 403.
  - **`simulator/deploy/README.md`**: Cloud Run commands for `hs-selfhost-0928-x825` (region us-central1, to confirm).
    - Secret Manager names `revrec-sim-hs-api-key`, `revrec-sim-stripe-test-key`, `revrec-sim-hs-dashboard-jwt`; the values are piped from .env and never printed.
    - The proxy service runs with min and max instances 1 and `--no-cpu-throttling` (state and timers are in memory). Non-secret ids are in `simulator/deploy/proxy.env.yaml`.
  - **Dashboard hosting, recommendation B:** a second Cloud Run service running the fork's own server (repo-root Dockerfile, `npm run serve`).
    - It already rewrites every page path to `index.html` and serves `/config/*` from config.toml, with `default__<table>__<key>` env overrides.
    - It is the same topology as local dev today. The alternatives (the proxy serves the build; a sidecar) are in the README. **B: please confirm the `default__features__*` / `default__simulator__*` keys in the README command.**
  - :8787 still runs the older code because B's portfolio run `pf_5f2dcd18` is going. A watcher restarts it with the same flags when the run ends and the proxy is idle.
- 2026-10-23 19:06 [A] `/healthz` → `limits`: `{storyStartsPerHour, storyStartsPerIpHour, portfolioEnabled, portfolioRunsPerHour, portfolioMaxInvoices, portfolioRunsAtOnce}` (commit d84b169a3). It is live on :8787 after the restart that waits for `pf_5f2dcd18` to end.
- 2026-10-23 19:07 [B] Deploy README §4 (dashboard env keys), checked by running the dashboard's own `configHandler` with env overrides set (both the production path, domain "default", and the dev-server path, domain ""):
  - Confirmed names: `default__endpoints__api_url`, `default__features__simulator_demo_session`, `default__features__dev_recovery_simulator`, `default__features__dev_recovery_v2_product`, `default__simulator__org_id`, `default__simulator__merchant_id`, `default__simulator__profile_id`. Booleans are typed from config.toml, so "false" turns a flag off.
  - **Missing: `default__simulator__sim_url=https://<proxy-url>`** (no `/api`). The dashboard calls `/sim/*` there. Without it, the deployed dashboard calls http://localhost:8787.
  - The flags and ids already sit in the committed config.toml, so only `api_url` and `sim_url` are strictly needed. Setting the rest is harmless and explicit.
  - **Build risk:** `npm i` runs our postinstall `git config core.hooksPath .githooks`, which fails outside a git repo ("fatal: not in a git directory", exit 128; checked). `gcloud builds submit` leaves `.git` out by default, so the repo-root Dockerfile's `npm i` would fail on Cloud Build. Options: a simulator Dockerfile with `npm ci --ignore-scripts && npx patch-package` (patch-package is the only script we need), or a `.gcloudignore` that keeps `.git`. Also, the image uses node:18 while we build locally on Node 24; not tested there.
- 2026-10-23 19:55 [B] **First real portfolio run from the screen: pf_5f2dcd18** (10 invoices, default mix 4/3/2/1/0, Stop after 20 min, seed from the proxy). Done: "every invoice reached a final status".
  - Result: static 7/10 recovered, 3 terminated; Rev Rec 7/10, 3 terminated. Same profile (cascading) on both sides, so equal is expected; median minutes 5.8 vs 4.2 is noise, and the screen says so next to the cards.
  - By reason: generic_decline 3/3 and 3/3, processing_error 2/2 and 2/2, insufficient_funds 2/4 and 2/4, stolen_card 0/1 and 0/1.
  - **Findings for A / Aayush:**
    1. The stolen card was retried 7 times on each side before "terminated". Hard declines are not stopped yet (known gap, ask 7).
    2. Two insufficient-funds invoices (bank flip at 10 and 11.5 min) were terminated before their flip, after 3 to 7 Rev Rec attempts, so retries were spent before the money came back. With max retries 8 and a retry every ~2.5 min, flips after ~10 min cannot win on this profile.
    3. The trend's last point is minute 49.5 although Stop after was 20. My watcher saw no change from 19:08 to 19:50 (machine likely asleep), and the run ended on "every invoice final", not on the cap. A: is the cap measured on wall-clock time from the start?
  - Fixes from this run, in the screen: progress against the planned 20 copies; results hidden until the first copy is final; comparison label shown once; dials filled from a reopened run; "Stop after" dial; red pill when Rev Rec is worse; 30 s polling; a portfolio copy opened in the story shows preset "None (a portfolio copy)", and Charge customer then sends no preset. Fixture is no longer a fallback (kept in SimulatorPortfolioFixture.res).
  - Each status in the invoice table opens that copy's story (checked: st_07a2fd22d13c). Screenshot: simulator/screenshots/portfolio-real-run.png.
- 2026-10-23 19:56 [A] **Run `pf_5f2dcd18` analysed; engine fixed; STATUS.md written.** Commits b7d1b893f, 9035d4d22, bfc66d1e5.
  - **True result:** 7/10 recovered on both sides, **39 Rev Rec attempts each** (2.6 per recovery). The first count, 35 vs 39, was wrong: invoice 7's static copy showed 3 retries where the sandbox had 7.
  - **Insufficient funds 2/4: the proxy's fault.** The flips for invoices 7 and 10 came 16 and 14 min late. By then Rev Rec had already retried 7 times and terminated the invoice (sandbox: about 7 retries in about 16 min, then stop). Invoice 10's swap calls also timed out.
  - **Cause (most likely):** my local dashboard Docker build ran from about 02:08 to 02:50 on the same laptop and starved it. The proxy's 30-s loop stalled, and calls hit their 20-s timeouts. My restart overwrote the proxy log, so I cannot show the log lines. **My mistake: I ran a heavy build during B's run.** Restarts now append to the log.
  - **Fixes:**
    - Attempts are re-read for every open copy each tick (5 at a time).
    - The time cap is checked at the start of each tick (the run went 50 min against a 20-min cap).
    - A flip more than 90 s late is flagged: `bank.lateSec`, plus a warning "not a fair data point". The `pf_5f2dcd18` view now shows warnings for invoices 7 and 10.
  - **Design note for M2:** a bank flip must come before Rev Rec's about 7 retries are used up (about 15 min at sandbox pace). The insufficient-funds range of 4–12 min fits, but only if the loop is on time.
  - **Dashboard image** (B's check): `default__simulator__sim_url` is added. New `simulator/deploy/dashboard.Dockerfile` (Node 24, `npm ci --ignore-scripts` + `patch-package`, a git stand-in for `webpack.server.js`, its own ignore file that keeps `.env` files out), plus `cloudbuild.dashboard.yaml` on a 32 GB machine. Local test: every step passed up to the webpack production build, which was killed for lack of memory in the 6 GB Docker VM, so that last step is not verified.
  - :8787 is restarted on the latest code (portfolio on, 30 starts/h). `/healthz` has `limits` and `contract` (7/7 passed, no drift).

## Hard-coded or English-only in the simulator UI (B, 2026-10-23 20:00)

The dashboard has no translation system (no i18n library; all upstream UI text is English), so every simulator string is English too. Moving to translations would be a dashboard-wide change, not a simulator one. Items to know:

- **Text from the proxy is shown as sent (English):** preset titles and summaries, timeline labels and sentences, explain lines, bank rules, warnings, the comparison label and error messages.
- **English word matching (fallbacks only):** `SimulatorUtils.inferStepStatus` reads "declin", "fail", "approved", "paid" when a timeline row has no `status` (older proxies). `rowForAttempt` finds an attempt id inside the row's `text` / `why` when `attemptId` is missing. `SimulatorGlossary.linkTerms` underlines English terms only. The portfolio screen no longer matches error text (the fixture fallback is gone).
- **Copy written in the UI:** Home cards, Explore drawer steps, Feature tour panels (PRD §9; display-only texts are my summaries, to review), glossary definitions (PRD §20 plus "webhook"), page headings, empty states, the Billing system note, the countdown ("in 2 min 05 s").
- **Values written in the UI:**
  - Card network limits in the tour (Visa 20/20, Mastercard 10/35, Amex and Discover 20/20, "to confirm"), and "Retries for hard declines: 0 (fixed in the dashboard)".
  - Portfolio: the five decline reasons and their labels, the default mix 4/3/2/1/0 (copied from the proxy's `DEFAULT_MIX`), invoices 10 / 25 (25 disabled by hand; could read `/healthz` `limits.portfolioMaxInvoices`), Stop after 10/20/45 min, "Card mix: Visa 100%", chart colours.
  - Story form: default amount 65.40 USD, a fallback card list (used only if the proxy sends none), the customer options.
  - Money: `toMinor` / `toMajorText` assume two decimals (fine for USD, EUR and GBP, the proxy's only currencies). The portfolio shows amounts with "$" and the amount dial says "(USD)", whatever the currency.
  - Lifeline names and notes ("Simulated", "Sandbox", "Stripe test mode"); the source-label texts; retry-mode names (cascading, smart, monitoring).
  - Polling: story 4 s, portfolio 30 s, health page 30 s.
- **Demo session:** placeholder token `simulator-demo`, user name "Demo visitor", entity merchant, version v2, Recovery product forced. The ids come from config/env.
- **Config:** `sim_url` and `api_url` default to localhost in config.toml; deploy must set `default__simulator__sim_url` and `default__endpoints__api_url`.
- **Dates and times** use the browser's locale (`toLocaleTimeString`, the dashboard's `DateCell`), so they follow the visitor.

## Orchestrator (2026-10-24) — sandbox writes done by Aayush's approval
- Demo billing connector `mca_8sEBJcnLL79XDoOsQiWg`: start rule 2 → 0, max retries 8 → 15, grace 30 (saved, 200).
- New profiles on the demo merchant: `sim-static` = profile `pro_Ly7W7OsLc7b8qVu5IHbu` (billing `mca_9vRZH9M4aRhZwA8ojJkM`, payment `mca_Y9Uslvqz4Szd24qZIJxi`); `sim-smart` = profile `pro_rOhNuMSwBsrRZupGSxyL` (billing `mca_qIvaIGoa8EApxOtNYptF`, payment `mca_zX8hYhwxe7HHrY80ihO6`). Both 0 / 15 / 30. HS_STATIC_* and HS_SMART_* are in simulator/proxy/.env.
- A: restart the proxy, run the start-rule-0 story test, then the 10-invoice portfolio on the new pair.
- 2026-10-24 10:16 [A] **After the orchestrator's setup run** (start rule 0 / max retries 15; sim-static, sim-smart; .env lines). Commits adbea2364, 26900714e, 61e0063b0, 79e1d7495.
  - **Start rule 0 works on the story profile.** Story `st_a0bc837f351d` (preset 2): **one** billing failure (card 0002), no extra charges. Rev Rec booked a retry 30 s later (17:15:17Z) and charged 4242 at 17:15:30Z: Recovered by Rev Rec, about 1 min in total.
  - **Contract ok=false explained: CloudFront now blocks `v2/payments/{id}/list-attempts`** (the hyphen spelling) with a 403 HTML page ("Request blocked"). The underscore spelling `list_attempts`, which the dashboard uses, works. The proxy now reads `list_attempts` everywhere, and the contract names a CloudFront block as a path change. The contract is back to 7/7. Story views had no Rev Rec attempts while this lasted. The process-tracker read now also falls back to the underscore path on 403.
  - **sim-static and sim-smart are in `monitoring`, not cascading/smart.** Upstream `connector_create` (core/admin.rs) puts a profile back into monitoring when a billing connector is created. setup-profiles set the mode before that, so the mode was undone. Monitoring later falls to the server default (cascading), so smart would never run. Fixed in `setup-profiles.ts` (the mode is now the last step). New `scripts/set-retry-mode.ts` fixes the existing pair; its plan shows "static: monitoring → cascading, smart: monitoring → smart".
  - **Needs a hands-on run (shared-config write; my permission check refuses relayed approvals):** `cd simulator/proxy && node scripts/set-retry-mode.ts --apply`. The 10-invoice portfolio on the new pair waits for that; run now, it would compare cascading with cascading again.
  - Stories now keep their profile (`profileRef`) and portfolio runs keep their pair, so the new .env lines did not move the story or old runs.
- 2026-10-24 (orchestrator) `set-retry-mode.ts --apply` run with Aayush's approval: sim-static saved `cascading`, sim-smart saved `smart`. A: go for the 10-invoice portfolio on the new pair.
