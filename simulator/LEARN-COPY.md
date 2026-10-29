# Learn Rev Rec · diagram and lesson copy (exact text)

Written 26 Oct 2026 by the orchestrator from user feedback: the words inside the diagrams must be easy for a
first-time learner. Use this text word for word in `SimulatorTourUtils.res`. Do not shorten it into labels.

## Rules

- **Node title** (badge) says WHO: Billing system, Processor, Rev Rec, Customer, Merchant app.
- **Node caption** says WHAT that actor does, as a short sentence. Two lines at most. Make nodes wide enough
  (about 240 px) so no caption wraps to three lines.
- **Edge label** says what passes between the boxes, or the answer to a yes/no box. Three words at most.
- **Step captions** are the plain-words line under the diagram for the animated walk. One per step, in order.
- No jargon without a plain word next to it. Gone: "cap", "ladder", "rung", "window", "error catalogue",
  "count + 1", "vs".
- Rev Rec does its own retries, so a retry node is **Rev Rec**, not Processor. Processor nodes only approve
  or decline.

---

## Level 1 · The start rule

**Idea:** Rev Rec steps in after this many failed charges.

| Node    | Title                 | Caption                                             |
| ------- | --------------------- | --------------------------------------------------- |
| charge  | Billing system        | Charges the customer's card                         |
| decline | Processor             | Declines the charge                                 |
| count   | Rev Rec (highlighted) | Counts the failed charges and checks the start rule |
| retry   | Rev Rec               | Takes over and plans a retry                        |

| Edge             | Label            |
| ---------------- | ---------------- |
| charge → decline | payment          |
| decline → count  | failure reported |
| count → retry    | rule met         |

**Steps**

1. The billing system charges the card for this month's invoice.
2. The bank declines. The billing system reports the failure to Rev Rec.
3. Rev Rec counts the failures. Start rule 0 means: take over after the first failure.
4. The rule is met. Rev Rec takes over and plans a retry.

**Check 2 question:** The start rule is 2. The billing system has reported one failed charge. What happens?
Choices: "Rev Rec retries now" · "Rev Rec waits. The billing system keeps trying first." · "The invoice is cancelled" (answer: 2nd).

## Level 2 · From a fixed timetable to smart retries

**Title:** From a fixed timetable to smart retries
**Idea:** A fixed timetable retries every invoice the same way. Smart retries pick the best time.

| Node   | Title                       | Caption                                      |
| ------ | --------------------------- | -------------------------------------------- |
| pick   | Rev Rec                     | Must choose when to retry                    |
| static | Fixed timetable             | 1 min, then 3 h, then 6 h, for every invoice |
| smart  | Smart retries (highlighted) | Picks the hour most likely to work           |
| retry  | Rev Rec                     | Retries the card at that time                |

| Edge           | Label          |
| -------------- | -------------- |
| pick → static  | today          |
| pick → smart   | with Rev Rec   |
| static → retry | next time slot |
| smart → retry  | best hour      |

**Steps**

1. The card was declined. Rev Rec must choose when to try again.
2. A fixed timetable waits the same times for every invoice.
3. Smart retries look at the decline reason, the day and the hour.
4. At the chosen time, Rev Rec charges the saved card again.

**Number captions:** Fixed timetable → "This demo uses the fixed timetable" · Smart → "This demo picks the best hour" · Monitoring → "This demo watches but does not retry".
**Check 2 question:** On the fixed timetable, how long before retry 3?

## Level 3 · Max retries and grace period

**Title:** Max retries and grace period
**Idea:** Rev Rec stops after a set number of retries (max retries) or a set number of days (grace period), whichever comes first.

| Node    | Title                 | Caption                                          |
| ------- | --------------------- | ------------------------------------------------ |
| retry   | Rev Rec               | Retries the card                                 |
| decline | Processor             | Declines again                                   |
| check   | Rev Rec (highlighted) | Retries left, and still inside the grace period? |
| again   | Rev Rec               | Plans the next retry                             |
| stop    | Rev Rec               | Stops retrying this invoice                      |

| Edge            | Label          |
| --------------- | -------------- |
| retry → decline | retry          |
| decline → check | one retry used |
| check → again   | yes            |
| check → stop    | no             |

**Steps**

1. Rev Rec retries the saved card.
2. The card is declined again. One more retry is used up.
3. Rev Rec checks two limits: retries used against the maximum, and days passed against the grace period.
4. Both limits are fine: Rev Rec plans another retry.
5. One limit is reached: Rev Rec stops. The invoice ends as Terminated.

## Level 4 · Hard declines

**Idea:** Some declines can never succeed, like a stolen or closed card. Rev Rec stops on these at once.

| Node      | Title                 | Caption                                      |
| --------- | --------------------- | -------------------------------------------- |
| decline   | Processor             | Declines and gives a reason                  |
| catalogue | Rev Rec (highlighted) | Looks up the reason: can a retry still work? |
| later     | Rev Rec               | Soft decline: retries later                  |
| stop      | Rev Rec               | Hard decline: stops at once                  |

| Edge                | Label          |
| ------------------- | -------------- |
| decline → catalogue | decline reason |
| catalogue → later   | yes            |
| catalogue → stop    | no             |

**Steps**

1. The bank declines and gives a reason, for example insufficient funds or stolen card.
2. Rev Rec looks up the reason in its list of decline codes.
3. Soft decline, like insufficient funds: the money may come back, so Rev Rec retries later.
4. Hard decline, like a stolen card: a retry can never work, so Rev Rec stops.

**Number caption:** "Retries after a hard decline"

## Level 5 · Card network limits

**Idea:** Visa and Mastercard limit how often a merchant may retry the same card. Rev Rec stays inside these limits.

| Node  | Title                 | Caption                                             |
| ----- | --------------------- | --------------------------------------------------- |
| want  | Rev Rec               | Is ready to retry the card                          |
| cap   | Rev Rec (highlighted) | Has this card reached the Visa or Mastercard limit? |
| retry | Rev Rec               | Not yet: retries now                                |
| wait  | Rev Rec               | Limit reached: waits for it to reset                |

| Edge        | Label       |
| ----------- | ----------- |
| want → cap  | check limit |
| cap → retry | no          |
| cap → wait  | yes         |

**Steps**

1. Rev Rec is ready to retry the card.
2. First it counts this card's retries today and in the last 30 days.
3. Under the limit: Rev Rec retries now.
4. Limit reached: Rev Rec waits until the count resets, then retries.

**Number:** "20" · caption "Retries per Visa card per day. Mastercard allows 10."
**Check 2 choices:** "Waits until the limit resets" · "Switches to another card" · "Gives up" (answer: 1st).

## Level 6 · Invoice queuing

(Aligned 27 Oct with A's proof on the engine, decider profile: smart retries without the model. Rev Rec
takes one invoice per customer at a time and frees the customer after every retry. In one run invoice 2
waited for all 15 of invoice 1's retries; in another the two took turns. Two charges for one customer
never ran together. The lock is on that smart path only, per the engine code. Try it: preset 8.)

**Idea:** When one customer has several unpaid invoices, Rev Rec charges them one at a time.

| Node  | Title                 | Caption                           |
| ----- | --------------------- | --------------------------------- |
| open  | Customer              | Has 2 unpaid invoices on one card |
| first | Rev Rec (highlighted) | Retries one invoice               |
| wait  | Invoice 2             | Shows Queued while it waits       |
| next  | Rev Rec               | Gives the next invoice its turn   |

| Edge         | Label         |
| ------------ | ------------- |
| open → first | one at a time |
| first → wait | busy          |
| wait → next  | next turn     |

**Steps**

1. One customer has two unpaid invoices on the same card.
2. Rev Rec takes the customer for one invoice and retries it.
3. The other invoice waits. Its status shows Queued.
4. After each retry, the next invoice can take its turn.

**Number caption:** "Invoice per customer at a time"
**Check 2 choices:** "The processor requires it" · "It is faster" · "Every retry hits the same card. One at a time wastes fewer retries and avoids fraud alerts." (answer: 3rd).

## Level 7 · Paid outside Rev Rec

**Idea:** If the customer pays another way, for example in the app, the billing system tells Rev Rec. Rev Rec stops retrying.

| Node   | Title                 | Caption                                    |
| ------ | --------------------- | ------------------------------------------ |
| pay    | Customer              | Pays the invoice in the app                |
| report | Billing system        | Tells Rev Rec the invoice is paid          |
| stop   | Rev Rec (highlighted) | Cancels its planned retries                |
| closed | Rev Rec               | Closes the invoice as paid outside Rev Rec |

| Edge          | Label        |
| ------------- | ------------ |
| pay → report  | payment      |
| report → stop | invoice paid |
| stop → closed | close        |

**Steps**

1. While Rev Rec is still retrying, the customer pays in the app.
2. The billing system sees the payment and tells Rev Rec.
3. Rev Rec cancels the retries it had planned, so the customer is never charged twice.
4. The invoice closes as paid, but Rev Rec does not count it as its own recovery.

**Number caption:** "Retries after the customer pays another way"
**Check 2 question:** Who gets credit for that payment? Choices: "Rev Rec" · "The billing system, not Rev Rec" · "Nobody" (answer: 2nd).

## Level 8 · Record back and webhooks

**Title:** Record back and webhooks
**Idea:** When Rev Rec recovers an invoice, the merchant must learn it was paid. Rev Rec can update the billing platform directly (record back) or send a message (webhook).

| Node     | Title                        | Caption                                  |
| -------- | ---------------------------- | ---------------------------------------- |
| approved | Processor                    | Approves the retry                       |
| recovers | Rev Rec                      | Marks the invoice recovered              |
| paid     | Billing system (highlighted) | Shows the invoice as paid                |
| updates  | Merchant app                 | Gets the message and unlocks the account |

| Edge                | Label       |
| ------------------- | ----------- |
| approved → recovers | approved    |
| recovers → paid     | record back |
| recovers → updates  | webhook     |

**Steps**

1. The bank approves Rev Rec's retry.
2. Rev Rec marks the invoice recovered.
3. Record back: Rev Rec writes "paid" straight into the billing platform, for example Chargebee or Recurly.
4. Webhook: Rev Rec also sends a message to the merchant's server, so the app can unlock the account.

**Number:** "Webhook" · caption "This demo's billing system has no record back. It learns the result by webhook."
**Check 2 question:** This demo's billing system has no record back. How does the merchant learn the result?
Choices: "By webhook" · "By email" · "It never learns" (answer: 1st).

---

# Levels 9 to 14 · workshop flows (draft by Builder C, 27 Oct 2026, for review)

Same rules as above. Node captions are short sentences (two lines at most), edge labels three words at
most, one step caption per animated step. Each level's "Try it" opens the matching story preset once A/B
land it: the preset carries `learnLevel: <level>` in GET /sim/presets, and the button stays hidden until then.
Level 13 replaces the "More features" one-liner Partial auth recovery. The path subtitle is "Fourteen
short levels."

Dropped on 28 Oct 2026: the level "Smart retries try another saved card" (preset 9). The simulator does
not promote charging a card the customer did not authorize for this invoice, so preset 9 is hidden and
no level teaches the card switch. "How smart picks a day" moved from level 15 to level 14.

## Level 9 · One webhook at the end

(Confirmed 27 Oct by A on the demo engine, with signed webhooks: preset 4 made 15 declined retries and
sent ONE webhook, payment_failed, when Rev Rec stopped (st_83444ccc7c29). Preset 2 sent one
payment_succeeded when the retry worked (st_dfe6b4577133). A retry that fails sends no webhook. This
matches the Oct 14 notes: webhooks on final outcomes only.)

**Hook:** The billing system learns the final result
**Idea:** Rev Rec sends the billing system one webhook when the invoice ends.

| Node   | Title                 | Caption                             |
| ------ | --------------------- | ----------------------------------- |
| retry  | Rev Rec               | Retries the saved card              |
| bank   | Processor             | Declines, or approves at last       |
| send   | Rev Rec (highlighted) | Sends one message at the end        |
| update | Billing system        | Updates the invoice with the result |

| Edge          | Label        |
| ------------- | ------------ |
| retry → bank  | retry        |
| bank → send   | final result |
| send → update | webhook      |

**Steps**

1. Rev Rec retries the saved card.
2. A declined retry sends no message. Rev Rec tries again.
3. The invoice ends: recovered, or Rev Rec stops.
4. Rev Rec sends the billing system one webhook with the result.

**Number:** "1 webhook" · caption "15 declined retries, then one webhook: payment failed."
**Check 1:** When does Rev Rec send the webhook?
Choices: "When the invoice ends" · "After every retry" · "Never" (answer: 1st).
**Check 2:** Why does the billing system need the webhook?
Choices: "To show the invoice's final result" · "To charge the card again" · "To tell the bank" (answer: 1st).

## Level 10 · Billing failures keep the budget

(Aligned 27 Oct with A's flow 2 finding: on this engine a failure the billing system reports during
recovery does NOT use Rev Rec's retry budget; it raises the invoice's total count only, and Rev Rec still
makes all 15 retries.)

**Hook:** Rev Rec keeps all its retries
**Idea:** While Rev Rec is retrying, the billing system may also charge the card. If that charge fails, Rev Rec still keeps all its retries.

| Node    | Title                 | Caption                                 |
| ------- | --------------------- | --------------------------------------- |
| charge  | Billing system        | Charges the card itself during recovery |
| decline | Processor             | Declines the charge                     |
| count   | Rev Rec (highlighted) | Adds it to the invoice's failure count  |
| left    | Rev Rec               | Still has all its retries               |

| Edge             | Label            |
| ---------------- | ---------------- |
| charge → decline | payment          |
| decline → count  | failure reported |
| count → left     | budget unchanged |

**Steps**

1. Rev Rec is recovering the invoice. The billing system also charges the card.
2. The bank declines the billing system's charge.
3. The billing system reports the failure. Rev Rec adds it to the invoice's failure count.
4. Rev Rec's own retry budget does not change: it still makes all its retries.

**Number:** the demo profile's max retries, e.g. "15" · caption "Retries Rev Rec still makes after a billing failure"
**Planned line** (grey "Planned" chip, under the number): "The workshop plan says such failures should use the budget; the engine does not do that yet."
**Check 1:** Who can charge the card while Rev Rec is recovering an invoice?
Choices: "Only Rev Rec" · "The billing system can too" · "Only the bank" (answer: 2nd).
**Check 2:** The billing system's charge fails during recovery. What happens to Rev Rec's retries?
Choices: "One is used up" · "None is used: Rev Rec keeps all its retries" · "They reset to zero" (answer: 2nd).

## Level 11 · Finished invoices stay closed

(Aligned 27 Oct with A's flow 3 finding: a Recovered or Cancelled invoice refuses a late failure report
(404, record not allowed); an invoice Terminated by a hard decline accepts it (200) but stays terminated
and no retry starts.)

**Hook:** No new retries after the end
**Idea:** A paid or cancelled invoice refuses new reports. A stopped invoice records them but never restarts.

| Node   | Title                 | Caption                                    |
| ------ | --------------------- | ------------------------------------------ |
| report | Billing system        | Reports a new failure for an ended invoice |
| check  | Rev Rec (highlighted) | Checks: how did this invoice end?          |
| refuse | Rev Rec               | Paid or cancelled: refuses the report      |
| record | Rev Rec               | Stopped: records it, never restarts        |
| told   | Billing system        | Gets a "not allowed" answer                |

Layout: report, check in a row; refuse above, record below, told right of refuse.

| Edge           | Label             |
| -------------- | ----------------- |
| report → check | failure report    |
| check → refuse | paid or cancelled |
| check → record | stopped           |
| refuse → told  | not allowed       |

**Steps**

1. The billing system reports a new failure for an invoice that has ended.
2. Rev Rec checks how the invoice ended: paid, cancelled or stopped.
3. Paid or cancelled: Rev Rec refuses the report, so the invoice is never reopened.
4. The billing system gets a "not allowed" answer, and nothing changes.
5. Stopped after a hard decline: Rev Rec records the report, but no retry starts.

**Number:** "0" · caption "Retries after a report on an ended invoice"
**Check 1:** An invoice is already recovered. The billing system reports a new failure. What does Rev Rec do?
Choices: "Starts retrying again" · "Refuses the report" · "Refunds the customer" (answer: 2nd).
**Check 2:** An invoice was stopped by a hard decline. A new failure report arrives. What happens?
Choices: "Rev Rec records it, but no retry starts" · "Rev Rec starts retrying again" · "The invoice is deleted" (answer: 1st).

## Level 12 · Go live: watch first

**Hook:** Old failed invoices, then retries
**Idea:** A new merchant may already have many failed invoices. Rev Rec first only records them (monitoring). Then the merchant switches retries on.

| Node    | Title                 | Caption                                  |
| ------- | --------------------- | ---------------------------------------- |
| backlog | Billing system        | Sends the invoices that already failed   |
| watch   | Rev Rec (highlighted) | Monitoring: records them, no retries yet |
| switch  | Merchant              | Checks the numbers, switches retries on  |
| retry   | Rev Rec               | Retries the invoices on its timetable    |

| Edge            | Label        |
| --------------- | ------------ |
| backlog → watch | old failures |
| watch → switch  | numbers      |
| switch → retry  | retries on   |

**Steps**

1. The merchant goes live with many invoices that already failed.
2. Rev Rec starts in monitoring: it records each invoice but does not retry yet.
3. The merchant checks the numbers, then switches retries on in the dashboard.
4. Now Rev Rec retries the invoices on its normal timetable.

**Number:** the demo profile's mode · Monitoring → "Monitoring" / "The demo profile records failures but does not retry yet"; static or smart → "Retries on" / "The demo profile is past monitoring: it retries".
**Check 1:** What does Rev Rec do in monitoring?
Choices: "Retries every invoice" · "Records the invoices but does not retry" · "Cancels old invoices" (answer: 2nd).
**Check 2:** Why start a backlog in monitoring?
Choices: "To see the numbers before any customer is charged again" · "Because retries cost nothing" · "To delete old invoices" (answer: 1st).

## Level 13 · Partly paid invoices

**Hook:** The paid part closes, the rest is retried
**Idea:** Sometimes only part of an invoice gets paid. That part is done, and Rev Rec keeps retrying the rest.

| Node    | Title                 | Caption                          |
| ------- | --------------------- | -------------------------------- |
| retry   | Rev Rec               | Retries the full amount          |
| partial | Processor             | Approves only part of it         |
| split   | Rev Rec (highlighted) | Marks the paid part as recovered |
| rest    | Rev Rec               | Retries the amount still owed    |

| Edge            | Label     |
| --------------- | --------- |
| retry → partial | retry     |
| partial → split | part paid |
| split → rest    | rest owed |

**Steps**

1. Rev Rec retries the full invoice amount.
2. The bank approves only part of it, for example $40 of $65.40.
3. Rev Rec marks the paid part as recovered. The invoice shows as partly recovered.
4. Rev Rec keeps retrying the amount still owed, until it is paid or Rev Rec stops.

**Number:** "Being checked" · caption "We are testing how the demo engine handles a partial payment." (The workshop flow is the billing system reporting a partial payment, not partial authorization; align steps to A's item 5 when it lands.)
**Check 1:** The bank approves $40 of a $65.40 invoice. What does Rev Rec retry next?
Choices: "$65.40 again" · "The $25.40 still owed" · "Nothing, it stops" (answer: 2nd).
**Check 2:** What happens to the $40 already paid?
Choices: "It is refunded" · "It counts as recovered" · "It is charged again" (answer: 2nd).

## Level 14 · How smart picks a day

(New, 27 Oct, from the model view and the engine's model: `simulator/selfhost/MODEL.md`. The words
match the model view: "worked k of n times", "chance in the plan", "Every day keeps at least a 1 in
10 chance", "Seeded counts", "Re-computed". Content adapted from Balakrishna's Adaptive Retry Lab,
used with permission: retry chance is not recovery chance; explore versus use the evidence.)

**Hook:** Why Friday at 9 PM?
**Idea:** Rev Rec's model tries when the same decline worked most often before.

| Node   | Title                 | Caption                                            |
| ------ | --------------------- | -------------------------------------------------- |
| fail   | Billing system        | Reports the failed charge and its decline          |
| counts | Rev Rec               | Looks up past tries for this decline               |
| days   | Rev Rec (highlighted) | Ranks the next days by how often they worked       |
| floor  | Rev Rec               | Every day keeps at least a 1 in 10 chance          |
| pick   | Rev Rec               | Tries on the soonest planned day, at a likely hour |

| Edge          | Label         |
| ------------- | ------------- |
| fail → counts | decline       |
| counts → days | worked k of n |
| days → floor  | plan          |
| floor → pick  | soonest day   |

**Steps**

1. The billing system reports a failed charge and its decline.
2. Rev Rec looks up how often each day and hour worked before.
3. It ranks the next days. The best ones get a place in the plan.
4. Every other day keeps at least a 1 in 10 chance, so Rev Rec keeps learning.
5. Rev Rec tries on the soonest planned day, at a likely hour.

**Number:** "1 in 10" · caption "The smallest chance any day keeps"
**Note line** (grey chip "On this engine", under the number): "The model never retries the same day."
**Check 1:** Fridays worked 204 of 745 times before. What does that tell Rev Rec?
Choices: "Friday is a good day to try" · "The next try on Friday will work" · "Never try on a Friday" (answer: 1st).
**Check 2:** Why does every day keep a small chance?
Choices: "So Rev Rec keeps learning about every day" · "To slow Rev Rec down" · "Because the bank asks" (answer: 1st).
**Try it:** the portfolio run (its smart side), then open a smart invoice to see its model view.
