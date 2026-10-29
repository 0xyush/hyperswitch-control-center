# Smart retries on our engine: Rev Rec's own model, with seeded counts

> **Seeded counts, not Juspay's production data.** The success counters below are made up from published
> retry patterns, so the engine's real model has something to read. They are not measurements.

## What runs

Our engine (Hyperswitch v2, tag 2026.10.26.0, commit `bc36cd0`) already contains Rev Rec's smart-retry
model. We run that code unchanged. File and line references are to `~/work/hyperswitch-main`.

- **Mode:** the smart profile has retry mode `smart`, and the per-profile A/B flag
  `revenue_recovery_ab_enabled_{profile_id}` is on (`core/configs/dimension_config.rs:792-806`).
  - The invoice is assigned the default arm `SystematicKMaxAtScore` (`dimension_config.rs:813-815`, `REVENUE_RECOVERY_AB_ALGORITHM`).
  - That arm scores days by `max` of raw scores, draws a schedule with systematic sampling, and lets the model's time stand: the static ladder is on standby (`workflows/revenue_recovery.rs:1807`).
  - We do **not** use the merchant-wide `adaptive_retry_enabled` flag. Its default pairing puts the ladder in the "ceiling" role: the earlier calendar day wins, ties to the ladder (`core/revenue_recovery/schedule.rs:47`, `workflows/revenue_recovery.rs:923-976`). Our fast ladder is always "today", so it would win every time and the model would never decide.
- **Inputs:** the cluster is the failed attempt's standardised error code (from its GSM row, `core/revenue_recovery/types.rs:362`).
  - The key is `v1|<code>/UNK/UNK`.
  - The engine reads the cluster's document from table `revenue_recovery_retry_stats` (`workflows/revenue_recovery.rs:2412`).
  - No document means no opinion, and the engine falls back to the cascading ladder (`:2429`, `:2479`).
- **The model** (`compute_predicted_retry_time`, `:2260`):
  - **Per slot:** p̂ = (k+1)/(n+2) and its standard error √(p̂(1−p̂)/(n+3)) (`:1636-1646`).
  - **Slot score:** the average over the other slots of logit(Φ(gap / combined SE)), meaning "how confidently this slot beats that one" (`:1679`).
  - **Days:** candidate days are tomorrow up to the end of the grace period, at most 31 (`:2311`, never the failure day).
    - Weekday and day-of-month scores are combined per day.
    - Systematic-k draws a schedule of k = retries-left days, with every day kept at least at the exploration floor 0.10 and ties within 1e-4 split. The engine acts on the soonest day (`inclusion_probabilities` `:2058`, `systematic_sample` `:2147`, `select_systematic_k_day` `:2202`; config `exploration_floor`, `tie_tolerance`).
  - **Hour:** sampled in proportion to exp(hour score) (`:1944`). With no hour data it is 12 UTC (`default_retry_hour_utc`).
- **Learning:** each outcome is added to its cluster's counters (`core/revenue_recovery/retry_stats/events.rs`, on by default: `revrec_retry_stats_enabled`, `dimension_config.rs:1174-1182`).
  - The counters belong to the cluster, not to a profile. So the static side's outcomes also teach the model the smart side reads.
  - A failure with no standardised code goes to `v1|UNK/UNK/UNK`. The model never reads that cluster: it needs a code to look up.
- **Proof in the log:** `retry model: stats fetched — running the model` (`:2454`, debug level; the VM logs at DEBUG). Seen on 27 Oct, two invoices on the smart profile:
  - Insufficient funds: code `InsufficientFunds`, 29 grace days, 14 retries left. Retry on Friday 30 Oct at 22:00 UTC (driver: weekday).
  - Generic decline: code `DoNotHonor`. Retry on Wednesday 28 Oct at 11:00 UTC (a weekday, inclusion probability 0.575: the weekdays tie).

## The model view

The story's model view (`SimulatorModelView.res`) shows each decision in plain numbers: the best days and hours as "worked k of n times", each with its chance, the picked ones marked, and the 1-in-10 floor. The numbers come from the sim service, which re-computes the engine's decision from the counts the engine read (`sim/model.mjs`, a port of the engine's formulas, tested against the engine's own unit test). The formulas sit behind "Show the math".

The view's content (retry chance is not recovery chance; explore versus use the evidence) is adapted from Balakrishna's Adaptive Retry Lab, used with permission. It is rebuilt in the dashboard's design, and its numbers are our engine's.

## Clusters and the patterns behind them

The rates are made up for the demo, shaped like published retry patterns. "Ours" marks a choice we made where a pattern gives only a direction.

### Counters

The generator is `model/retry-stats.mjs`; `model/retry-stats.csv` is its output.

- **Tries:** 5,208 per cluster, spread evenly: n = 744 per weekday, 168 per day of month, 217 per hour. 5,208 is the smallest total that 7, 31 and 24 all divide. Uneven tries would make equal rates look unequal.
- **Equal totals:** the engine rejects a document unless the tries and the successes add up to the same totals in all three families. They are three views of the same outcomes (`validate_invariants` in `hyperswitch_domain_models/src/revenue_recovery/retry_stats_document.rs`).
- **Successes:** the day-of-month rates are the base rates and set the cluster's total. Weekday and hour rates keep their shape (the ratios between slots) and are scaled to that total. So the stored weekday and hour rates are lower or higher than the pattern, by one factor per family.
- **Exact ties:** the engine ranks candidate days only by their order (`inclusion_probabilities`, `:2058`). One success more would make a day win, so slots with equal rates hold exactly equal counts.
  - Weekday and day of month: k = round(n × rate × scale), with the scale that gives both families the same total.
  - Hour: the same rule. Any odd count (at most a few) goes on the least likely hours, which the model almost never picks.

### Insufficient funds · `v1|insufficient_funds/UNK/UNK` · GSM code InsufficientFunds

| Slot             | Pattern                                                                                                                    | Stored k/n                                           | Source                                                                                                                            |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Day of month     | 0.05 + 0.55 × e^(−0.25 × days since payday); paydays the 1st and the 15th. So 0.60 on the 1st and 15th, 0.48 the day after | the same (0.60 down to 0.06)                         | Pattern: success is highest right after payday and decays before the next one; the 1st and the 15th are paydays. Decay rate: ours |
| Weekday Mon..Sun | 0.27, 0.25, 0.24, 0.30, **0.40**, 0.36, 0.30                                                                               | × 0.68: 0.18, 0.17, 0.16, 0.21, **0.27**, 0.25, 0.21 | Pattern: success peaks near Friday. Shape: ours                                                                                   |
| Hour (UTC)       | 18–22: **0.42**; 9–17: 0.30; 23–8: 0.18                                                                                    | × 0.75: 18–22 **0.32**; 9–17 0.23; 23–8 0.13–0.14    | Evening peak: from the brief, **not a published pattern** (those say only that hour-of-day patterns exist)                        |

Total: 5,208 tries, 1,078 successes (20.7%).

### Generic decline · `v1|do_not_honor/UNK/UNK` · GSM code DoNotHonor

| Slot         | Pattern                                    | Stored k/n                                  | Source                                                                               |
| ------------ | ------------------------------------------ | ------------------------------------------- | ------------------------------------------------------------------------------------ |
| Day of month | 0.30 flat                                  | 0.30 flat (50 of 168)                       | Pattern: a flat issuer chance on each try, no day-of-month effect                    |
| Weekday      | Mon–Fri 0.32; Sat–Sun 0.20                 | × 1.04: Mon–Fri 0.33; Sat–Sun 0.21          | Business days: from the brief                                                        |
| Hour (UTC)   | 0–5: **0.08**; 9–17: **0.38**; other: 0.25 | × 1.16: 0–5 0.09; 9–17 **0.44**; other 0.29 | Pattern: avoid late-night UTC hours for this decline. Business hours: from the brief |

Total: 5,208 tries, 1,550 successes (29.8%).

### Velocity limit · `v1|velocity_limit_exceeded/UNK/UNK` · GSM code VelocityLimitExceeded

A daily spending limit (Stripe's `card_velocity_exceeded`, the Daily limit story). It resets at midnight, so the next day works as well as any later one.

| Slot         | Pattern                    | Stored k/n                                    | Source                                                                 |
| ------------ | -------------------------- | --------------------------------------------- | ---------------------------------------------------------------------- |
| Day of month | 0.45 flat                  | × 1.02: 0.46 flat (77 of 168)                 | Pattern: the limit resets each day, no day-of-month effect. Base: ours |
| Weekday      | 0.45 flat                  | × 1.02: 0.46 flat (341 of 744)                | Pattern: no weekday effect. Base: ours                                 |
| Hour (UTC)   | 0–5: **0.50**; other: 0.40 | × 1.08: 0–5 **0.54** (117 of 217); other 0.43 | Right after the reset, before the new day's limit is spent: ours       |

Total: 5,208 tries, 2,387 successes (45.8%).

All days tie, which here is what a daily limit needs: the engine's window starts tomorrow and it acts on the soonest day it draws, so it retries the next day or soon after.

### Processing error · no document · GSM code DownstreamTechnicalIssue

A temporary processing error that a later retry usually clears. The bank gives it a flat 0.85 everywhere.

It gets **no document**, on purpose. The engine ranks days only by order, so a flat document makes every day tie, and the engine spreads its retries at random over the grace window. Without a document the engine uses its ladder, which retries soon, as a temporary error needs (`:2429`, `:2479`).

**But learning starts one** (decided 27 Oct: keep the engine's real behaviour). Rev Rec's retries after a processing error are outcomes of this cluster, so the engine soon has a document for it, and from then on the model decides. The model never retries the same day (the window starts tomorrow), so a smart processing error waits at least a day, where the fixed timetable retries after 1 minute. The model view says: "Rev Rec's model never retries the same day." / "For a short bank outage, the fixed timetable is faster." A reset to the seed removes the document again.

Hard declines (stolen, expired) have no cluster: GSM marks them hard and the engine stops.

## What the model prefers with these counts

Computed with the engine's scoring formulas (p̂, SE, Φ, logit, softmax) on the seeded documents:

| Cluster            | Hour it picks                                   | Days it ranks first                                                                      |
| ------------------ | ----------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Insufficient funds | 18–22 UTC, about 98% of picks (19.5% each hour) | the 1st and the 15th, then the 2nd and the 16th, then Fridays, then the 3rd and the 17th |
| Generic decline    | 9–17 UTC, about 99.8% of picks (11.1% each)     | weekdays, all tied; the weekend last                                                     |
| Velocity limit     | 0–5 UTC, about 97% of picks (16.2% each hour)   | every day tied; the engine acts on the soonest it draws, so tomorrow or soon after       |
| Processing error   | no document: the ladder decides                 | no document: the ladder decides                                                          |

How a day is chosen (`SystematicKMaxAtScore`):

- A day's value is the larger of its weekday score and its day-of-month score, then a softmax over the window (`combine_day_weight`, `:1991`).
- The days are ranked by value. With k retries left, the k best days get almost all the chance, and every other day keeps the floor 0.10. Tied days share their chance.
- The engine draws a schedule of k days and acts on the soonest one.

## The bank (same pattern, one draw per invoice)

`slotChance(code, slot)` in `model/retry-stats.mjs`:

- The base is the day-of-month rate.
- The weekday rate and the hour rate are applied as factors around their averages.
- The result is capped at 0.95.

A retry at a real-life slot succeeds when the invoice's fixed random draw (one per invoice, from the run's seed, the same for both sides) is below that chance. The bank never knows which side is asking.

## Limits on our engine, and how the demo handles them (decided 27 Oct)

- **Error codes come from GSM.** Without a matching GSM row the code is empty and the engine falls back to the ladder. seed.sh adds the rows.
  - **The billing system's report:** the webhook resolves the reported failure's code from GSM when it arrives (`resolve_standardised_error_code`, `core/revenue_recovery/retry_stats/events.rs:98`, called from `core/webhooks/recovery_incoming.rs:777`). So the first retry is already the model's.
  - **Rev Rec's own failed charge:** the payments core looks up connector `stripe`, flow `Payment`, the operation name, Stripe's code and message (`core/payments/operations/payment_response.rs:2696-2714`).
- **Stripe test mode saves only one declining card.** Attaching the insufficient-funds or processing-error test cards is refused (402). Only `0341` attaches, and it declines as a generic decline. **Handled by the bank** (below): it decides at charge time, so a losing charge can fail with the invoice's own reason.
- **The model plans from the wall clock.** Candidate days start tomorrow (`:2311`), and the grace window is measured from now. Moving booked tasks to compressed demo times changes when they run, not the engine's "today". **Handled by a simulated calendar:**
  - Decision 1 for an invoice is exactly the engine's pick (weekday, day of month and hour as it scored them).
  - Each later pick is **re-computed** the way the engine would make it on that day (decided 27 Oct): today = the day of the last try, window = tomorrow to the grace end, the same counts, the engine's formulas (`sim/model.mjs` `pickDay`: day values, inclusion probabilities, a systematic-k draw, the soonest day), at the hour the engine drew. The bank judges that slot. A test checks that no re-computed pick lands past the grace end.
  - Grace and budget run down on the simulated calendar, and the invoice stops at either, as the engine would.
  - **Limit:** later picks are re-computed, not the engine's own. The model view marks them "Re-computed".
  - **How:** the `sim` service (`sim/sim.mjs`, README) watches the smart profile's `EXECUTE_WORKFLOW` tasks. A task planned more than 1 hour ahead is the model's (the demo ladder plans seconds ahead). The service fixes its real-life slot and moves the task to its demo time: 13.6 s per real day after the failure. The engine runs a task when its time comes, with no check of the planned time (`perform_execute_payment`).
  - A slot past the grace window (the invoice's billing start plus the billing connector's `grace_period_days`) ends the invoice: business status `SIM_GRACE_OVER`.
  - Retries the ladder plans (the static side, and the processing error without a document) take the default ladder's real-life slots, by retry number (the proxy's `REAL_LADDER`).
- **Learning uses the attempt's actual time.** Outcomes are filed under the attempt's `created_at` (`retry_stats/events.rs`), the demo's real clock. **Handled by re-filing:** each outcome is moved from its demo slot to its real-life slot, so the model learns what it would in real life. A "reset to seed" action restores these counts for demos (and removes any document the engine started for an unseeded cluster, such as the processing error), and a test checks that after a run the stats equal the seed plus the real-slot outcomes.
  - **How:** the `sim` service keeps each document at the seed plus every outcome since the reset. It writes whole documents through the admin CSV route, which takes the same per-cluster lock as the engine's own writes.
  - **Which outcomes:** one per finished Rev Rec retry, on every profile (`core/revenue_recovery/types.rs`, six `record` calls). The cluster is the engine's `prev_attempt_error_code`: the code of the report that started Rev Rec, then the code of each of Rev Rec's own failures. A later report from the billing system does not change it (`upsert_calculate_pcr_task` leaves an existing task alone).
  - **Proof, 27 Oct:** with re-filing off, a 3-invoice run gave 34 outcomes, and the service's list matched the engine's own counters exactly (`/check?slots=demo`). With re-filing on, `/check` matched too.

## The bank, at charge time

The `sim` service's bank (`sim/bank.mjs`, port 8095 on the compose network) sits between the engine and Stripe: `stripe.base_url = "http://sim:8095/"` in `config.toml`.

- **Which charges:** only Rev Rec's charges (the engine's `POST /v1/payment_intents`) for invoices the proxy marks. The mark is the Stripe customer metadata `sim_bank`, a JSON rule. Everything else passes through byte for byte, both ways, so other stories keep Stripe's real answers.
- **The rule (v1):** `{v: 1, reason, worksFrom}` for a story, or `{v: 1, reason, draw}` for a portfolio invoice. `failureAt` (optional) is the story's real-life failure moment; the whole real-life calendar then starts there.
  - Reasons: `insufficient_funds`, `generic_decline`, `processing_error`, `card_velocity_exceeded`.
  - `worksFrom`, in UTC from the failure: `{at}` (a real-life moment, for "money is back"), `{afterHours}`, `{dayOffset, hour}` (0 = the failure day), `{weekday, hour}` (Monday = 0, the next one), `{payday: true, hour}` (the next 1st or 15th).
  - Events: `stolenFrom` (a moment: from then on the charge hard-declines as a stolen card) and `outages` (`[{from, until}]`: charges in between fail with a processing error). Events come before the rule.
  - `card` (default `"0341"`): the saved card the rule is about. A card the customer adds later is another card, so Stripe answers for it.
  - The bank reads the rule again for every charge, so a changed rule applies to the very next retry.
- **The decision:** the bank finds the charge's invoice (`metadata[order_id]` is the invoice id) and its retry number n, then the retry's real-life slot (the simulated calendar or the ladder).
  - Story: the charge works from the `worksFrom` moment on.
  - Portfolio: the charge works when the invoice's draw is below `slotChance` at that slot.
- **Win:** it charges the customer's saved good card (4242). **Loss:** it charges a one-off test card that declines with the invoice's own reason, with no customer. Stripe test mode does not let those cards be saved, so the swap happens at charge time. Each decline message has a GSM row, so the engine files it under the reason's cluster.

| Reason                 | One-off card                                   | Stripe code and message                                    | Cluster                    |
| ---------------------- | ---------------------------------------------- | ---------------------------------------------------------- | -------------------------- |
| insufficient_funds     | `pm_card_visa_chargeDeclinedInsufficientFunds` | `card_declined`, "Your card has insufficient funds. …"     | insufficient_funds         |
| generic_decline        | `pm_card_chargeDeclined`                       | `card_declined`, "Your card was declined."                 | do_not_honor               |
| processing_error       | `pm_card_chargeDeclinedProcessingError`        | `processing_error`, "The card couldn't be processed. …"    | downstream_technical_issue |
| card_velocity_exceeded | `pm_card_chargeDeclinedVelocityLimitExceeded`  | `card_declined`, "Your card's balance, credit limit, or …" | velocity_limit_exceeded    |

- The rule is the same for both sides, and it never sees which side is asking.
- It logs only the invoice id, retry number, slot and outcome: never request bodies, headers or keys. It reads the rules with `STRIPE_TEST_KEY`.
- `SIM_BANK=off` makes it a pure pass-through.
- **Checked 27 Oct:** a marked charge before its moment declined with Stripe's insufficient-funds code and message; a marked charge after it was charged on the 4242 card; an unmarked charge got Stripe's own answer.

### Other processors (Adyen first; decided 27 Oct)

- **Routing:** the processor's `base_url` in `config.toml` is `http://sim:8095/<connector>/<its path>`; the bank sends each call on to that processor's test API. All six go through it. `SIM_BANK_PROCESSORS` lists the processors whose stories are proven (`GET /bank/processors`); the proxy offers the real-world stories only there.
- **Stories:** the proxy registers each marked story (`POST /bank/stories`): the good token it reported, the invoice id, the rule, and per decline reason the **replacements** that make the processor itself decline. Kept in memory only (tokens are never stored or logged).
- **A charge** is a POST that carries the story's good token (or every `match` string). The decision is Stripe's (real-life slot, rule, events). A win goes as the engine sent it; a loss gets the reason's replacements, so the processor returns a real decline.
- **What each sandbox can say (A's tests):** Adyen all five reasons; Worldpay four; Authorize.net, NMI, Global Payments and Cybersource a generic decline only.
- **Adyen** declines a stored-card charge by the holder name (`paymentMethod.holderName`). The engine stores `refusalReasonCode` as the code and `refusalReason` as the message; each has a GSM row (`seed.sh` 9 and 9b):

| Holder name               | Code and message                | Cluster                     |
| ------------------------- | ------------------------------- | --------------------------- |
| NOT_ENOUGH_BALANCE        | 12, "Not enough balance"        | insufficient_funds          |
| DECLINED                  | 2, "Refused"                    | do_not_honor                |
| ISSUER_UNAVAILABLE        | 9, "Issuer Unavailable"         | downstream_technical_issue  |
| WITHDRAWAL_COUNT_EXCEEDED | 29, "Withdrawal count exceeded" | velocity_limit_exceeded     |
| BLOCK_CARD                | 5, "Blocked Card"               | hard decline: Rev Rec stops |

- **Cybersource** checks a signature over the host, path and body, so the bank signs every Cybersource request again with the merchant's keys (VM `.env`, never logged).
- **Authorize.net** calls a charge a duplicate (code 11) when the same card, amount and invoice came in the last 2 minutes. Every lost retry declines on the same profile, so the bank adds `duplicateWindow` 0 to the charges it declines, in the schema's field order.
- **Decline codes** (engine attempts, GSM rows in `seed.sh` 9b): Authorize.net `2`, "This transaction has been declined."; NMI `200`, "DECLINE"; Global Payments `101`, "(101)[ test system ] Declined". All three are generic only, so all go to do_not_honor, as Stripe's generic decline.
- **Cybersource**'s sandbox has one decline, an expired card (`EXPIRED_CARD`). The bank uses it as a generic decline, so its row is soft (do_not_honor) and Rev Rec keeps retrying. In real life an expired card is a hard decline.
- **Generic-only processors** (Authorize.net, NMI, Global Payments, Cybersource) decline every reason the same way. A stolen card there keeps Rev Rec retrying, as a generic decline; the story form says "Decline reasons may be generic on …".
- **Worldpay** declines by the holder name. Its codes: `5` "REFUSED" (do_not_honor); `51` "LIMIT EXCEEDED" (insufficient_funds, also its velocity decline); `91` "CREDITCARD ISSUER TEMPORARILY NOT REACHABLE" (downstream_technical_issue); `43` "STOLEN CARD, PICK UP" (hard decline). The engine sends the invoice id as `transactionReference` on every retry, and Worldpay refuses a decline when the last one under that reference had another code, so each declined charge goes as `<invoice>-r<n>`. Worldpay gives a card saved again the same token, so the proxy saves each story's card in its own namespace, and a charge matches its story by the token and the invoice id.
- **Proven 27 Oct (A, stories 13, 20 and 2):** Adyen and Worldpay, also their stolen, outage and money-back events; Authorize.net; NMI; Global Payments; Cybersource (re-signed). All six processors run the real-world stories.
- **Checked 27 Oct, without the engine:** the same request with no credentials, through the bank and straight to the sandbox, got the same status and body on Authorize.net, NMI, Worldpay, Global Payments and Cybersource. An engine-like Cybersource request with a wrong signature passed the check through the bank (GET 404, POST 400 for missing fields) and got 401 straight.
