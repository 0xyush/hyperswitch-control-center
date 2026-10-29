# Rev Rec Simulator · how we built it

_Key steps and decisions, 22 to 27 Oct 2026. Plain words, newest state at the end._

## 1. What it is

- A copy of the Hyperswitch dashboard with a simulator inside its Revenue Recovery (Rev Rec) module. You play the billing system; a real Rev Rec engine retries; Stripe test mode is the bank.
- Code: GitHub `0xyush/hyperswitch-control-center`, folder `simulator/`.

## 2. Decisions, in order

| Date | Decision | Why |
|---|---|---|
| 22 Oct | Research first: the code, the model, the pilots, the workshop notes | Know what Rev Rec really does before building |
| 23 Oct | Fork the real dashboard, keep only the Rev Rec module | People already know these screens |
| 23 Oct | Use a real engine, never a fake one | The demo must show what Rev Rec really does |
| 23 Oct | A small proxy server holds every key and plays the billing system | No key in the browser; visitors need no setup |
| 23 Oct | Stripe test mode takes the real charges | Real declines with real reasons |
| 23 Oct | Script only the customer's bank, and say so on screen | A test card answers the same at every hour |
| 23 Oct | Label every "why" line: from Rev Rec, re-computed, or rule-based | Nobody mistakes a guess for a fact |
| 23 Oct | Three AI builders: proxy, story screens, learn and portfolio screens | Work in parallel; one orchestrator reviews and pushes |
| 24 Oct | Demo settings: start rule 0, max retries 15, grace period 30 days | Rev Rec takes over on the first failure |
| 26 Oct | Put it on Google Cloud Run behind one shared password | A link to share, not open to everyone |
| 26 Oct | **Run our own Hyperswitch engine** instead of the shared sandbox | The sandbox stopped retrying, cannot be tuned, and has no stop for stolen cards |
| 27 Oct | Retries every 5 s on our engine | A full story fits in a call; 15 retries take 80 s |
| 27 Oct | One tap starts Rev Rec; retries then play by themselves | No "Next" presses; one clean row per retry |
| 27 Oct | Learn Rev Rec as 8 short levels with animated diagrams | Teach one rule at a time, in plain words |

## 3. How we built our own engine

- **No ready image existed.** Hyperswitch publishes no v2 engine image, so we built it from source on Google Cloud Build.
- **Two failed builds.** One missed a Redis feature. One ran out of memory at the last step. The fix: Hyperswitch's lighter "release-fast" build setting. Same code and features.
- **One server (VM)** `revrec-hs` on Google Cloud: database, Redis, the engine (router) and its scheduler, all in Docker.
- **A seed script** creates the demo merchant, the Stripe test connection, the billing connection, the retry timing and the stop rules.
- **Our retry logic settings:** first retry 3 s after takeover, then about every 5 s, up to 15 retries. A stolen or expired card stops at once.
- **Stolen-card fix.** The billing simulator now reports Stripe's real reason code, so the engine's stop rule can match it.
- **Safe by design.** The engine has no public address. Only our proxy reaches it, over Google's private network.

## 4. Where things run

| Piece | Where |
|---|---|
| Dashboard and proxy (shareable link) | Cloud Run, password-gated |
| Rev Rec engine | VM `revrec-hs`, private network only |
| Engine images | Built on Cloud Build, stored in Artifact Registry |
| Keys and password | Secret Manager, never in code or chat |
| Local testing | Your laptop, port 9000, through a tunnel to the VM |

## 5. Results on our engine (27 Oct)

| Scenario | Result |
|---|---|
| Temporary error | Recovered in 8 s |
| Insufficient funds, then recovers | Recovered in 14 s |
| Stolen card | Stopped in 4 s, no retry |
| Card keeps declining | 15 retries, stopped at 80 s |
| Portfolio run, 10 temporary errors | All recovered in 50 s |

## 6. Rules we kept

- Fix locally first, you test, deploy only on your go. Builders never push; the orchestrator reviews and pushes.
- Never print or commit a secret; you run the secret script yourself. Plain words on screen, no raw ids.

## 7. Still open

- **Smart retries** need Rev Rec's trained model and decider service. Ask the Rev Rec engine team.
- **Approved pilot numbers** before any number goes in the app. Ask the Rev Rec engine team.
- **Cost:** the VM costs about $3 a day while it runs. Stop it when not in use.
