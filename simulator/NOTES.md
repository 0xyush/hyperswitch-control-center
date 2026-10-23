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
