# Portfolio run (M2) · design

Builder A, 2026-10-23. Design only, no code yet. It builds on the sandbox findings of 23 Oct in `NOTES.md`. Code references are to upstream `juspay/hyperswitch` main.

## 1. Goal

One batch of 10 or 25 invoices runs through Rev Rec twice: once on a static-retries profile, once on a smart-retries profile. The same invoices, the same bank rules, real sandbox runs. The screen shows the two results side by side.

## 2. Two profiles on the demo merchant

- **Today:** one profile, `pro_2qWO…`, mode `cascading`. Its Custom billing connector has start rule 2, max retries 8, grace 30 days.
- **API** (upstream `routes/profiles.rs`, `routes/app.rs`):
  - `POST /v2/profiles` creates a profile. It needs an admin API key or a dashboard token with `MerchantAccountWrite`; our switched org_admin token has it.
  - `PUT /v2/profiles/{id}` sets `revenue_recovery_retry_algorithm_type` (`cascading` | `smart` | `monitoring`). Create cannot set it, and a new profile starts in `monitoring`, so the setup sets it.
  - `POST /v2/connector-accounts` with `X-Profile-Id` adds the Custom billing connector (`feature_metadata.revenue_recovery`: start rule 0, max retries 15, grace 30, `billing_account_reference` → the payment connector) and the Stripe test payment connector (the proxy holds the key). The dashboard's Rev Rec onboarding makes the same calls.
- **Plan:** an operator-run setup script, never from the public page, creates `sim-static` (cascading) and `sim-smart` (smart) and saves their ids in `.env`. The pool of 5 pairs comes in M4.
- Smart mode needs the decider (ask 2). Without it, smart picks no retry time, and the run shows that stall.

## 3. The scripted bank: one rule per decline reason, with real Stripe cards

The sandbox records Stripe's real decline, so the first charge for each reason uses the Stripe test card that really fails that way. A Stripe test card never changes its answer. So "the money is back" can only be one thing: the billing simulator reports a new failed charge that carries the customer's good card (4242). This is the scenario-6 swap. Rev Rec's next retry then charges 4242. Every copy of an invoice gets the same rule and the same flip time, drawn from the run's seed.

| Decline reason       | First-charge card | Saved card | Bank rule: when the swap to 4242 happens               | Hard? |
| -------------------- | ----------------- | ---------- | ------------------------------------------------------ | ----- |
| `insufficient_funds` | 9995              | 0341       | at the "payday": run start + P min (P drawn from 4–12) | no    |
| `generic_decline`    | 0002              | 0341       | after a quiet window: run start + Q min (Q from 2–6)   | no    |
| `processing_error`   | 0119 (to try)     | 0341       | at once: run start + 1 min                             | no    |
| `stolen_card`        | 9979              | 0341       | never                                                  | yes   |
| `expired_card`       | 0069 (to try)     | 0341       | never in V1 (the account updater is display only)      | yes   |

- The flip is on the clock, not after a number of attempts. Retrying soon after the flip wins; retries spent before it are wasted and use up the network limit.
- Every bank line on the screen says "bank: scripted". The sandbox retries every 1 to 2.5 min, so minutes stand in for production hours and days; the screen says "compressed time".

## 4. Creating the invoices twice

- **Spec:** the dials plus a seed give each invoice a reason (from the mix), an amount and a flip time.
- **Copies:** one copy per profile. Each copy has its own Stripe customer and saved 0341 card, because Rev Rec keeps history and limits per customer and card (PRD §8). Ids: `PF-<run>-<i>-S` and `PF-<run>-<i>-R`.
- **Setup:** with start rule 0, a copy takes 4 calls (customer, save card, first charge, report). 25 × 2 copies ≈ 200 calls, queued at 5 calls/s (Stripe test allows 25/s), so about 40 s. Both copies of an invoice go back to back.
- **Every 30 s:**
  - Bank loop: a copy past its flip time and not final gets one new failed charge, reported with the 4242 token.
  - Reads: one `recovery-list` per profile (`profile_id`, `created.gte` = run start) for all statuses, and `list-attempts` only for copies whose status changed.
- **End:** when every copy is final, or at 45 min. Then the run cancels the rest (`POST /v2/recovery/{ref}/cancel`, 200 on the sandbox).
- **Limits:** 1 run per session per hour, and 1 run at a time for the proxy (PRD §13).

## 5. Result shape: `GET /sim/portfolio/:runId`

```
{ runId, seed, startedAt, status: "setting_up"|"running"|"done", dials,
  profiles: { static: {profileId, mode: "cascading"}, smart: {profileId, mode: "smart"} },
  cards: { static: Card, smart: Card },          // Card = {invoices, recovered, recoveryRate,
                                                 //   recoveredAmount, attemptsPerRecovery,
                                                 //   minutesToRecovery: {median, p90}, terminated, open}
  byReason: [{ reason, invoices, static: {recovered}, smart: {recovered} }],
  trend:    [{ minute, static: recoveredSoFar, smart: recoveredSoFar }],
  invoices: [{ i, reason, amount, bank: {rule, flipAt},
               static: {recoveryId, status, attempts, recoveredAt}, smart: {...} }],
  sources:  { status: "sandbox", counts: "recomputed", bank: "scripted", flipAt: "scripted" } }
```

All counts are recomputed from the sandbox's statuses and attempts. A click on an invoice opens the existing story view for that copy.

## 6. Open questions

1. **Setup approval:** may we create the two profiles and their connectors on the demo merchant? This writes shared sandbox config. Or should `pro_2qWO…` stay as the static profile?
2. **Ask 2:** is the decider set up for smart mode on the sandbox? If not, M2 can show only the static side.
3. **Start rule and max retries:** 0 and 15 on both profiles? This is Aayush's open decision.
4. **Swap spike (scenario 6): passed on 23 Oct.** After a swap report carrying the 4242 token, Rev Rec's next retry charged 4242 and recovered the invoice (cascading profile, story `st_5e2776d00d4e`, 3.6 min). Still to check on a smart profile, where Rev Rec picks among the customer's tokens.
5. **Card network:** partly answered. The sandbox keeps the reported card details (`last4`) and takes only the decline from Stripe, so the reported `card_network` is likely kept too. To confirm with one Mastercard report.
6. **Ask 11:** what batch size is safe? The plan is 10 or 25 per profile at 5 calls/s.
7. **Fair comparison:** at the sandbox's 1-to-2.5-min cadence, both modes may retry at about the same speed. If the two cards come out equal, the screen says so. It then shows attempts used and slots chosen instead (PRD §8 honesty rule).
