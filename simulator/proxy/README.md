# Rev Rec Simulator proxy

The dashboard talks only to this server. It holds the keys, plays the merchant's billing system, and passes an allow-list of Rev Rec reads to the Hyperswitch sandbox. Rev Rec's decisions stay real: every story makes real Stripe test-mode charges and real `/v2/recovery` reports.

## Run

1. Use Node 24 or later (`node --version`). TypeScript runs directly, with no build step.
2. Copy `.env.example` to `.env` and fill it in. `.env` is git-ignored. Never commit or print its values.
3. Install the dev tools: `npm install`.
4. Start the proxy: `npm start`. It listens on http://127.0.0.1:8787.
5. Check it: `curl -s localhost:8787/healthz`. Expect `"ok": true`, and `"dashboard": {"ok": true}` when the dashboard token works.

At start, the proxy switches the pasted dashboard token (`HS_DASHBOARD_JWT`) to the Rev Rec merchant with `POST v2/user/switch/merchant`. It never uses a token that is scoped to another merchant. If the token expires, re-grab it (`bash simulator/scripts/grab-jwt.sh`) and restart.

## Test

- `npm test` runs the offline unit tests and one live scenario-1 story on the sandbox (about 1 minute). The live test skips when `.env` is missing a required key, or when `SIM_LIVE=0`.
- `npm run test:unit` runs only the offline tests.
- `npm run typecheck` runs `tsc --noEmit`.

## Endpoints

| Route                                                                 | What it does                                                                                                           |
| --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `GET /healthz`                                                        | Sandbox and Stripe reachable, config present, dashboard token status (ids and expiry only)                             |
| `GET /sim/presets`                                                    | The 8 presets from PRD section 7 with the form values they fill, the 5 test cards, the currencies                      |
| `POST /sim/story/start` `{amount, currency, card, customer, preset?}` | Starts a story and returns the story view at once (status `starting`). Limit: 5 starts per hour per IP                 |
| `GET /sim/story/:id`                                                  | The story view: status, raw invoice, attempts and process tracker, explain lines, timeline, requests                   |
| `POST /sim/story/:id/paid-in-app`                                     | Real 4242 charge, then a `charged` report: "paid outside Rev Rec"                                                      |
| `POST /sim/story/:id/report-again` `{mode?}`                          | `duplicate` (same transaction), `new` (new failed charge) or `swap` (new failure with the 4242 card)                   |
| `POST /sim/story/:id/cancel`                                          | Cancels the invoice's recovery on the sandbox (`POST /v2/recovery/{merchant_reference_id}/cancel`)                     |
| `GET /sim/stories`                                                    | The last 50 stories                                                                                                    |
| `GET /sim/blocked`                                                    | `/api` calls the allow-list refused (for the dashboard builder)                                                        |
| `GET /api/*`                                                          | Allow-listed sandbox reads (`src/passthrough.ts`); shell reads answered by stubs (`src/shell.ts`); everything else 403 |

The full story JSON contract is in `simulator/NOTES.md` ("A reply to B proposals").

## How a story runs

1. The dashboard form plays the merchant's billing system: amount (minor units, 6540 = 65.40), currency, card, customer (new or same as last). A preset only fills these fields; explicit fields win.
2. A story uses two cards. The **saved card** is the one Rev Rec retries: 4242 approves every charge, 0341 declines every charge. The **first-charge card** is the one the billing system's own charge fails on: 0341 itself, or the one-off Stripe decline cards 0002 (generic_decline), 9995 (insufficient_funds) or 9979 (stolen_card), which Stripe will not save. The form's single `card` field picks both: 4242 = saved 4242 with a first charge on 0002; 0341 = 0341 for both; 0002, 9995 or 9979 = that first charge with saved card 0341. `savedCard` and `firstCharge` can also be sent on their own.
3. The billing simulator makes (start rule + 1) real failed charges, which are its own retries, and reports each one to `POST /v2/recovery` with `transaction_status: failure`. The start rule is read from the billing connector. Since 23 Oct the sandbox checks each charge with Stripe and records Stripe's own decline, so the decline reason comes from the first-charge card.
4. Rev Rec takes over on the sandbox: Monitoring, then Queued, Scheduled, Processing, and Recovered or Terminated.
5. The proxy reads the status back: the invoice list row, the invoice, its attempts and the process tracker. Rev Rec's retry bookings, its own charges and the final status become timeline steps too.
6. Every timeline step (one arrow in the sequence diagram) has a `stepId`; the `requests` entry with the same `stepId` is its raw call. Each explain line says where it comes from: `sandbox`, `recomputed` or `rule`.

## Portfolio run (M2, behind a flag)

1. Start the proxy with `SIM_PORTFOLIO=1`.
2. `POST /sim/portfolio/start` with `{invoices (1 to 10), amount, mix: {insufficient_funds, generic_decline, processing_error, stolen_card, expired_card}, maxMinutes (5 to 45), seed}`. All fields are optional.
3. Poll `GET /sim/portfolio/:runId` every 30 s. `POST /sim/portfolio/:runId/stop` ends the run and cancels open invoices.
4. Each invoice runs twice, once on the static profile and once on the smart profile, each copy with its own Stripe customer. Until `scripts/setup-profiles.ts` has created the smart profile, both copies use the existing profile, and the view says so.
5. Design and the bank rules: `simulator/PORTFOLIO.md`.

**Operator only:** `npm run setup:profiles` prints the plan for the two demo profiles. `npm run setup:profiles -- --apply` creates them; it writes shared sandbox config, so run it only with the owner's approval.

## Files

- `src/server.ts`: routes, CORS, rate limit, health
- `src/story.ts`: the billing simulator, the story view and the explain lines
- `src/scenarios.ts`: the scenario table
- `src/passthrough.ts`: the `/api` allow-list
- `src/shell.ts`: fixed answers for the dashboard shell's user and merchant reads
- `src/auth.ts`: the dashboard token switch
- `src/portfolio.ts`: the portfolio run (M2)
- `scripts/setup-profiles.ts`: operator script for the two demo profiles
- `src/redact.ts`: hides secrets in everything that leaves the proxy
- `data/stories.json`: saved stories (git-ignored)
