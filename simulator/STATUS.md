# Rev Rec Simulator · status, 23 Oct 2026

For Aayush and reviewers. Everything below runs locally against the real Hyperswitch sandbox and Stripe test mode. Nothing is deployed and nothing is pushed. Details and ids are in `NOTES.md`.

## What works on the sandbox today

- **Invoice story** (form + sequence diagram + the real invoice page). Every arrow is a real call, and a click shows its raw request and response.
  - Preset 1, customer pays in the app: Recovered, labelled "paid outside Rev Rec".
  - Preset 2, temporary error: Rev Rec's own retry on the good card recovers it in about 1 min.
  - Preset 3, duplicate report: the sandbox refuses the copy (400 "already recorded").
  - Preset 6, insufficient funds then a new card: after the swap report, Rev Rec's next retry charges 4242 and recovers it (3.6 min).
  - Cancel: `POST /v2/recovery/{invoice}/cancel` answers 200; the invoice becomes Cancelled.
- **Portfolio run** (behind a flag): 10 invoices, each run twice with its own Stripe customer, a scripted bank, and Static vs Rev Rec cards. A 3-invoice run passed.
  - **B's 10-invoice run `pf_5f2dcd18`** (20-min cap, default mix): 7/10 recovered on both sides, with 39 Rev Rec attempts each (2.6 per recovery). The two sides are identical, as expected with the same strategy.
  - By reason: generic decline 3/3, processing error 2/2, stolen card 0/1 (Rev Rec retried 7 times, then stopped), insufficient funds 2/4.
  - **The 2 insufficient-funds misses were the proxy's fault, not Rev Rec's.** Their bank flips came 14 and 16 min late, after Rev Rec had used its 7 retries and stopped. The proxy's 30-s loop had stalled while a heavy local Docker build ran on the same laptop, so its calls hit their 20-s timeouts.
  - Now fixed: the loop ends at the cap, re-reads attempts every tick (one copy had shown 3 retries where the sandbox had 7, so the first count of 35 vs 39 was wrong), and flags any flip more than 90 s late as "not a fair data point".
- **Proxy:** allow-listed reads, secrets hidden, rate limits, and a per-browser session. An hourly contract test of the fields we send and read passed 7/7 with no drift.
- **Dashboard (B):** Rev Rec Home with the two cards, Invoice story, Portfolio run, Feature tour with real settings, Glossary, and an operator health page. Page refresh works.

## What is stubbed, scripted or rule-based (and labelled so on screen)

- **"Why this slot":** rule-based text (decline class, card behaviour, the production ladder as text). There is no model answer yet.
- **The bank in the portfolio run is scripted:** at a set time, the billing system reports a new failure that carries the good card.
- **Smart vs static:** both sides of the portfolio run use the same static-retries profile today. The screen says "Same strategy on both sides, differences are sandbox timing noise". The noise we measured is about 1.5 min and 2 attempts.
- **User and merchant lists in the dashboard** are fixed demo answers from the proxy; they never show real users.
- **Card network limit:** recomputed from the attempt count against "about 20". The limit values are still to confirm.
- **Status times:** "first seen" times are observed when the page polls, except where an attempt has its own timestamp.

## Sandbox facts found on 23 Oct (the PRD needs these changes)

- `POST /v2/recovery` no longer takes `action`. The sandbox checks each charge with Stripe and records **Stripe's real decline**, not the reported reason. So a reason must come from a real Stripe test card: 9995, 0002, 0119, 9979, 0069.
- Duplicate reports now get 400. The cancel API exists. The sandbox keeps the card details we report.
- **Rev Rec stops an invoice after about 7 of its own retries**, about 16 min at today's sandbox pace. A scripted-bank flip later than that cannot recover the invoice.
- The demo profile's start rule is **2** (the PRD says 0), and max retries is 8 (the PRD says 15). The simulator makes 3 real failed charges so that Rev Rec takes over.

## Waiting on Kirthi (PRD §14)

1. Model access (decider, Predictor, contract): needed for a real "why this slot".
2. Decider for smart mode on the sandbox: needed for a real Static vs Rev Rec comparison.
3. Outgoing webhooks: the simulator polls instead. The profile's webhook URL still points to an old tunnel.
4. Are max retries and grace period enforced? Shown as "to confirm".
5. Ladder values (`pt_mapping_pcr_retries`): the production ladder is shown as text only.
6. Pilot numbers: none are shown.
7. **Hard-decline row for Stripe's stolen card:** in the 23 Oct probe, the sandbox recorded a real `stolen_card` decline and Rev Rec kept retrying. The row must match Stripe's decline code, because Stripe's `code` is `card_declined` for every decline.
8. **A dedicated demo dashboard user:** today the proxy uses Aayush's pasted token (role org_admin), switched to the Rev Rec merchant. Before a public deploy this must be a low-rights demo user.
9. Decision-log access: not wired.
10. Card network limit values: shown as "to confirm".

## Waiting on Aayush

- **Start rule 0 and max retries 15** on the demo billing connector, or keep the workaround.
- **Run `npm run setup:profiles -- --apply`** to create the `sim-static` and `sim-smart` profiles. The script is written but not run.
- **GCP deploy go-ahead.** Commands, secret names and the recommendation (two Cloud Run services) are in `deploy/README.md`.
- **Re-grab the dashboard token before 25 Oct 16:07 UTC** (`bash simulator/scripts/grab-jwt.sh`). After that time, a proxy restart cannot switch to the Rev Rec merchant.
- Optional: rotate the profile's webhook signing key. It showed once in a local terminal before the proxy began hiding it.
- Push the fork (all commits are local on `main`).

## Run it locally

1. **Proxy:** `cd simulator/proxy`, copy `.env.example` to `.env` and fill it in, run `npm install`, then `npm start` (port 8787). Check `curl localhost:8787/healthz`. For the portfolio run, start with `SIM_PORTFOLIO=1`.
2. **Dashboard:** in the repo root, run `npm install`, `npm run re:build`, then `npm run start`. Open http://localhost:9000/dashboard/v2/recovery/home.
3. **Tests:** `cd simulator/proxy && npm test` runs the offline tests and one live story (about 1 min).
