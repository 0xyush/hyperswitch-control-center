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

| Route                                        | What it does                                                                                                           |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `GET /healthz`                               | Sandbox and Stripe reachable, config present, dashboard token status (ids and expiry only)                             |
| `GET /sim/scenarios`                         | The 8 scenarios from PRD section 7, with V1 status and `runnable`                                                      |
| `POST /sim/story/start` `{scenario}`         | Starts a story. Returns the story view. Limit: 5 starts per hour per IP                                                |
| `GET /sim/story/:id`                         | The story view: status, raw invoice, attempts and process tracker, explain lines, timeline, requests                   |
| `POST /sim/story/:id/paid-in-app`            | Real 4242 charge, then a `charged` report: "paid outside Rev Rec"                                                      |
| `POST /sim/story/:id/report-again` `{mode?}` | `duplicate` (same transaction), `new` (new failed charge) or `swap` (new failure with the 4242 card)                   |
| `GET /sim/stories`                           | The last 50 stories                                                                                                    |
| `GET /sim/blocked`                           | `/api` calls the allow-list refused (for the dashboard builder)                                                        |
| `GET /api/*`                                 | Allow-listed sandbox reads (`src/passthrough.ts`); shell reads answered by stubs (`src/shell.ts`); everything else 403 |

The full story JSON contract is in `simulator/NOTES.md` ("A reply to B proposals").

## How a story runs

1. The billing simulator creates a Stripe test customer and saves the scenario's card: 0341 declines every charge, 4242 approves every charge.
2. It makes (start rule + 1) real failed charges, which are the billing system's own retries, and reports each one to `POST /v2/recovery` with `transaction_status: failure` and the scenario's decline reason. The start rule is read from the billing connector.
3. Rev Rec takes over on the sandbox: Monitoring, then Queued, Scheduled, Processing, and Recovered or Terminated.
4. The proxy reads the status back: the invoice list row, the invoice, its attempts and the process tracker. Each explain line says where it comes from: `sandbox`, `recomputed` or `rule`.

## Files

- `src/server.ts`: routes, CORS, rate limit, health
- `src/story.ts`: the billing simulator, the story view and the explain lines
- `src/scenarios.ts`: the scenario table
- `src/passthrough.ts`: the `/api` allow-list
- `src/shell.ts`: fixed answers for the dashboard shell's user and merchant reads
- `src/auth.ts`: the dashboard token switch
- `src/redact.ts`: hides secrets in everything that leaves the proxy
- `data/stories.json`: saved stories (git-ignored)
