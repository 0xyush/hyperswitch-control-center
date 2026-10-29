# Wording rules for every screen

_The goal: anyone understands Rev Rec in a few seconds, without being buried in text. Get the core idea right, say it simply, say it once._

## The rules

1. **One idea per line.** A line is about 12 words or fewer. A box has 3 lines at most.
2. **Everyday words.** Say "card declined", not "authorization failure". Say "tries again", not "re-attempts".
3. **Say who does what.** "Rev Rec tries the card again", not "A retry is performed".
4. **Show, then explain.** The screen shows what happened. Text adds only the "why", in one line.
5. **Details go behind "?" or "Show more".** The main screen never shows request bodies or ids.
6. **Show the math in plain numbers.** Use counts and chances people can picture ("worked 42 of 100 times", "1 in 10 chance"). Symbols and formulas (p̂, logit, softmax) go behind "?".
7. **Numbers carry a unit and a meaning.** "Tries again in 3 h", not "10800".
8. **The same word for the same thing, everywhere:**

| Use | Never |
|---|---|
| retry, tries again | re-attempt, reprocess, MIT |
| billing system | billing connector, BC, merchant system |
| Rev Rec | the engine, PCR, recovery service (on screen) |
| declined | failed authorization, rejected |
| recovered | succeeded, collected |
| stopped | terminated (except the state pill) |
| saved card | payment method, token, PSP token |
| informs Rev Rec, informed | tells, told (for Rev Rec, either way) |

9. **Honest labels stay, and stay short.** "Simulated", "Seeded counts" and "Planned" are one-word chips. The explanation goes behind "?".
10. **No jargon without a plain word beside it.** For example, "Monitoring (records failures, does not retry yet)".
11. **Cut before you add.** If a line does not help someone understand the next step, delete it.

## Before and after

| Before | After |
|---|---|
| The billing system tells Rev Rec about every failed charge: POST /v2/recovery with transaction_status failure and the saved card's token. | The billing system informs Rev Rec the charge failed. |
| Rev Rec's plan: up to 15 retries over about 6 days (Hyperswitch's default timetable). This demo runs the same steps in about 80 s. | Up to 15 tries over 6 days. Here: about 80 seconds. |
| A failure the billing system reports does not use one of Rev Rec's retries. | Billing failures do not use up Rev Rec's tries. |
| Systematic-k sampling with an exploration floor of 0.10. | Fri 6 PM worked 42 of 100 times before, so Rev Rec picked it. Every day keeps at least a 1 in 10 chance. ("?" shows the full formula.) |
