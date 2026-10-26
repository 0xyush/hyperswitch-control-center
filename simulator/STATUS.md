# Rev Rec Simulator · status, 26 Oct 2026

For Aayush and reviewers. Everything below runs against the real Hyperswitch sandbox and Stripe test mode, locally and on Cloud Run (revision 00002, password gate). Nothing is pushed. Details and ids are in `NOTES.md`.

## Open sandbox incident (26 Oct): Rev Rec takes over no invoice

- **Since at least 26 Oct 18:04 UTC, every new invoice stays in Monitoring.** Rev Rec never books a retry, although the failure report is accepted (200) and the start rule (0) is met.
  - 7 invoices are stuck on the story profile, among them a timed test at 18:50:56 UTC that was still waiting 12 min later.
  - On 24 Oct the same profile booked a retry in about 30 s.
- **Settings are unchanged:** the profile is cascading; start rule 0, max retries 15, grace 30.
- **The sandbox looks redeployed:** the invoice status field now says "monitoring", a value that upstream Hyperswitch does not have.
- **Aayush to raise with Kirthi.** Ids and questions are in `NOTES.md` ("Sandbox incident · 26 Oct 2026").
- Meanwhile the story screen says "Rev Rec has not booked a retry yet (sandbox scheduler)" after 3 min, instead of a plain "waiting".
- Everything below was true before the incident. Until it is fixed, stories that need Rev Rec's own retry (presets 2, 6) and the portfolio run cannot finish. "Paid in the app" (preset 1) and the duplicate refusal (preset 3) still work.

## Self-hosted Hyperswitch (26 Oct, in progress)

- **Why:** we cannot tune the shared sandbox (ladder, timings, GSM rows), and it has stalled since 18:04 UTC. Plan: `SELF-HOST.md`.
- **Ready to run (A):** `selfhost/` holds the compose stack, config, migrations step and an idempotent seed script. Steps: `selfhost/README.md`.
  - The v2 migrations ran clean on a local Postgres (593 applied; a second run applied none).
  - `seed.sh` ran twice against a mock router: the second run kept every object.
- **Next (orchestrator):** v2 router and scheduler images on Cloud Build, one e2-standard-4 VM, `docker compose up -d`, then the seed. The proxy reaches it through an SSH tunnel (`proxy/.env.vm.example`).
- **Gaps on the self-hosted router:**
  - No dashboard sign-in: v2 has no sign-in route, so `seed.sh` signs the proxy's token.
  - No `recovery-aggregate` route, so the invoice status counts fail.
  - No smart mode: there is no decider.

## What works on the sandbox today

- **Invoice story** (form + sequence diagram + the real invoice page). Every arrow is a real call, and a click shows its raw request and response.
  - Preset 1, customer pays in the app: Recovered, labelled "paid outside Rev Rec".
  - Preset 2, temporary error: since the start rule became 0 (24 Oct), there is **one** failed charge. Rev Rec takes over at once and recovers the invoice with the good card in about 1 min.
  - Preset 3, duplicate report: the sandbox refuses the copy (400 "already recorded").
  - Preset 6, insufficient funds then a new card: after the swap report, Rev Rec's next retry charges 4242 and recovers it.
  - Cancel: `POST /v2/recovery/{invoice}/cancel` answers 200; the invoice becomes Cancelled.
- **Portfolio run on two profiles** (behind a flag): `sim-static` (cascading) and `sim-smart` (smart). Each invoice runs once on each, with its own Stripe customer and a scripted bank.
  - **Run `pf_4744661b`** (10 invoices, 20-min cap):
    - **Static: 8/10 recovered**, with 55 Rev Rec attempts (3.1 per recovery, median 6 min).
    - **Smart: 0/10, with zero retries booked.** All 10 smart invoices stayed "Queued" for the whole run.
  - **Why smart does nothing:** see the next section. In short, the sandbox has no decider for smart mode.
- **Proxy:** allow-listed reads, secrets hidden, rate limits, a per-browser session, and an hourly contract test of the fields we send and read.
- **Dashboard (B):** Rev Rec Home with the two cards, Invoice story, Portfolio run, Feature tour with real settings, Glossary, and an operator health page. Page refresh works.

## Smart mode stalls: no decider on the sandbox (PRD gap, ask 2)

- **What we saw:**
  - All 10 smart invoices stayed "Queued" for 20+ minutes. Rev Rec made no retry, and no retry task was created (the process tracker answers 404).
  - The same invoices on the static profile were booked within about 30 s.
- **Why:** in Hyperswitch, smart mode asks an external service, the decider, for the retry time. If the decider is not set up, or does not answer, Rev Rec gets no time and keeps the invoice in Queued (upstream `workflows/revenue_recovery.rs`, the decider call returns "no decision").
- So the sandbox has **no working decider for smart mode**. We cannot see the sandbox's logs, so Kirthi's team should confirm it.
- **Until Kirthi sets up the decider for the demo merchant (ask 2), there is no real Static vs Rev Rec comparison.** The portfolio screen can show only the static side. This is the case PRD §16 names under "Risks".

## What is stubbed, scripted or rule-based (and labelled so on screen)

- **"Why this slot":** rule-based text (decline class, card behaviour, the production ladder as text). There is no model answer yet.
- **The bank in the portfolio run is scripted:** at a set time, the billing system reports a new failure that carries the good card.
- **User and merchant lists in the dashboard** are fixed demo answers from the proxy; they never show real users.
- **Card network limit:** recomputed from the attempt count against "about 20". The limit values are still to confirm.
- **Status times:** "first seen" times are observed when the page polls, except where an attempt has its own timestamp.

## A correction: why two runs had late bank flips

- Runs `pf_5f2dcd18` (23 Oct) and `pf_4744661b` (24 Oct) both had bank flips that came late, and both ran past their 20-min cap.
- I first blamed a local Docker build. **That was wrong.**
- The Mac's power log shows the laptop went into **idle sleep on battery** during both runs: 23 Oct 02:09–02:50 UTC, and 24 Oct 17:24–17:32 and 17:36–18:08 UTC. Timers do not run while the Mac sleeps, so the proxy's 30-s loop, its bank flips and its cap check all waited for the next wake.
- **Fixes:**
  - `npm run start:awake` runs the proxy under `caffeinate -i`, so the Mac does not idle-sleep.
  - A run now records any pause longer than 90 s and marks results in that window as not fair.
  - Cloud Run has no such sleep.

## Sandbox facts found on 23–26 Oct (the PRD needs these changes)

- `POST /v2/recovery` no longer takes `action`. The sandbox checks each charge with Stripe and records **Stripe's real decline**, not the reported reason. So a reason must come from a real Stripe test card: 9995, 0002, 0119, 9979, 0069.
- Duplicate reports now get 400. The cancel API exists. The sandbox keeps the card details we report.
- **Rev Rec stops an invoice when it reaches max retries.**
  - With max retries 8, it stopped after about 7 of its own retries.
  - With 15, invoices that never recovered stopped after exactly 15.
  - So max retries is enforced (this answers part of ask 4).
- **CloudFront blocks `v2/payments/{id}/list-attempts`** (hyphen) since 24 Oct; `list_attempts` (underscore) works. The proxy uses the underscore spelling.
- **Creating a billing connector puts its profile back into monitoring.** Set the retry mode after the connectors exist. `setup-profiles.ts` now does this.
- Start rule 0 and max retries 15 have been on the demo billing connector since 24 Oct (Aayush approved; the old values were 2 and 8).

## Waiting on Kirthi (PRD §14)

1. Model access (decider, Predictor, contract): needed for a real "why this slot".
2. **Decider for smart mode on the sandbox: needed for any Static vs Rev Rec comparison.** Smart mode books no retries today (see above).
3. Outgoing webhooks: the simulator polls instead. The profile's webhook URL still points to an old tunnel.
4. Grace period enforcement is still to confirm. Max retries is enforced (seen on 24 Oct).
5. Ladder values (`pt_mapping_pcr_retries`): the production ladder is shown as text only.
6. Pilot numbers: none are shown.
7. **Hard-decline row for Stripe's stolen card:** Rev Rec still retries a real `stolen_card` until max retries (15 times on 24 Oct). The row must match Stripe's decline code, because Stripe's `code` is `card_declined` for every decline.
8. **A dedicated demo dashboard user:** today the proxy uses Aayush's pasted token (role org_admin), switched to the Rev Rec merchant. Before a public deploy this must be a low-rights demo user.
9. Decision-log access: not wired.
10. Card network limit values: shown as "to confirm".

## Waiting on Aayush

- **Re-grab the dashboard token now** (`bash simulator/scripts/grab-jwt.sh`), then restart the proxy. The pasted token expired on 25 Oct. On 26 Oct a proxy restart dropped the switched token that was still valid, so the next-retry times, the process tracker and the config reads are off until then. The proxy now keeps a switched token across restarts.
- **GCP deploy go-ahead.** Commands, secret names and the recommendation (two Cloud Run services) are in `deploy/README.md`.
- Optional: rotate the profile's webhook signing key. It showed once in a local terminal before the proxy began hiding it.
- Push the fork (all commits are local on `main`).

## Run it locally

1. **Proxy:** `cd simulator/proxy`, copy `.env.example` to `.env` and fill it in, run `npm install`, then `npm run start:awake` (port 8787; on a Mac it keeps the laptop from idle sleep). Check `curl localhost:8787/healthz`. For the portfolio run, add `SIM_PORTFOLIO=1`.
2. **Dashboard:** in the repo root, run `npm install`, `npm run re:build`, then `npm run start`. Open http://localhost:9000/dashboard/v2/recovery/home.
3. **Tests:** `cd simulator/proxy && npm test` runs the offline tests and one live story (about 1 min).
