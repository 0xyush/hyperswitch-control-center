# Rev Rec Simulator · 10-minute demo script

For a salesperson on a call. You show one real failed invoice recovered by Rev Rec on the sandbox, the feature tour, and a finished portfolio run. Read the two honesty notes at the end before every call.

Start page (local): http://localhost:9000/dashboard/v2/recovery/home

## Before the call (2 minutes, not on screen)

1. Open `/dashboard/v2/recovery/simulator/health`. Every check must say OK.
2. Check the scoped dashboard token. It must expire in more than 2 hours.
3. Open the last finished portfolio run in a tab, so you do not start one on the call (a run takes 20 minutes or more, and the proxy allows one per hour). Today: `/dashboard/v2/recovery/simulator/portfolio/pf_5f2dcd18`.

## Minute 0–1 · Home

1. Show the Rev Rec Home.
2. Say: "When a subscription payment fails, Revenue Recovery retries it for the merchant. It picks a time, charges the saved card again, and stops when the invoice is paid or a retry can no longer help."
3. Click **Try It Out**.

## Minute 1–5 · One invoice, live

1. In **Preset**, pick **Temporary error, retry works**. It ends in about 1.5 to 2 minutes.
2. Say: "On the left is the merchant's billing system. We play it. On the right is the real product on the sandbox."
3. Click **Charge customer**. Rows appear in **What happened**. Say one line per arrow:

| Arrow                                  | What to say                                                                                                            |
| -------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| new invoice $65.40                     | The billing system has a monthly invoice.                                                                              |
| save card ••4242                       | The customer's card is on file.                                                                                        |
| charge $65.40 → declined (red)         | The billing system's own charge fails.                                                                                 |
| report failure (1 of 3) → 200 recorded | It tells Rev Rec. This profile waits for more than 2 failures (start rule 2), so the billing system tries three times. |
| pick retry time → hh:mm                | Rev Rec takes over and books a retry. This profile uses static retries, a fixed ladder of times.                       |
| dashed row with a countdown            | The booked retry. The countdown is the real booked time.                                                               |
| charge saved card ••4242 → approved    | Rev Rec charges the card by itself, with no customer present.                                                          |
| invoice recovered → mark paid          | Rev Rec tells the billing system the invoice is paid.                                                                  |

4. Click the **pick retry time** row. Show the side drawer: **Why**, with a source label on each line, and the real request and response. Say: "Keys are hidden by our proxy; the rest is the real call."
5. Scroll down. Show the real invoice page: **Fully recovered** and **Attempts History**. Say: "This is the same page the merchant sees under Invoices."
6. Click **Invoice states**. Show when each state was first seen.

Other verified presets: **Customer pays in the app** (wait for the dashed retry row, then click **Customer pays in app**; it ends as "paid outside Rev Rec"), **Duplicate report** (the sandbox refuses the second report) and **Insufficient funds, then recovers** (longer; practise it before a call). Presets whose name ends with a status in brackets, such as "(Warm invoice)" or "(Blocked on ask 7)", are not verified: do not use them on a call.

## Minute 5–7 · Feature tour

1. Open **Feature Tour** in the sidebar.
2. Show **Start rule**, **Max retries and grace period** and **Static vs smart retries**. Say: "These values are read live from the demo profile. That is what 'From the sandbox' means."
3. Show **Hard-decline stop** and **Card network limits**. Say: "Read-only: the engine has these rules; we show them, we do not change them."
4. Click an underlined term, for example **hard decline**. Show the glossary drawer.

## Minute 7–9 · Portfolio run

1. Open the finished run tab from "Before the call".
2. Show the four cards, then **Recovered by decline reason** with the bank rules under it ("Bank: scripted").
3. In **Invoices**, click a status. It opens that invoice's own story.
4. Say the noise note below before anything else on this screen.

## Minute 9–10 · Close

1. Go back to Home. Click **Explore Revenue Recovery** to show the guided drawer they can use alone later.
2. Take questions.

## Honesty notes (say these)

1. **Same profile, so no uplift claim.** Both sides of the portfolio run use the same static-retries profile until the smart profile exists. Equal cards are expected, and any difference is sandbox timing noise. The screen says so. Never quote a portfolio difference as Rev Rec's uplift.
2. **"Rule-based" is not the model.** Each explanation line has a source label. "From the sandbox" is real. "Re-computed" is worked out from sandbox data. "Rule-based" is the simulator's stand-in rule, not the real Rev Rec model. In the portfolio, the customer's bank is scripted ("Bank: scripted").

Also good to know: sandbox time is compressed (minutes, where production waits hours), and hard declines are not stopped yet on the sandbox (a stolen card is retried), so avoid the stolen-card preset.

## If something goes wrong

- A page is blank or shows "Oops": refresh. A story resumes from its URL.
- Still broken: open the health page and read the failing check.
