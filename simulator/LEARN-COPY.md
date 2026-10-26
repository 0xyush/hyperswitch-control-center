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

**Idea:** The start rule decides when Rev Rec steps in: after how many failed charges.

| Node | Title | Caption |
|---|---|---|
| charge | Billing system | Charges the customer's card |
| decline | Processor | Declines the charge |
| count | Rev Rec (highlighted) | Counts the failed charges and checks the start rule |
| retry | Rev Rec | Takes over and plans a retry |

| Edge | Label |
|---|---|
| charge → decline | payment |
| decline → count | failure reported |
| count → retry | rule met |

**Steps**
1. The billing system charges the card for this month's invoice.
2. The bank declines. The billing system reports the failure to Rev Rec.
3. Rev Rec counts the failures. Start rule 0 means: take over after the first failure.
4. The rule is met, so Rev Rec takes over and plans a retry.

**Check 2 question:** The start rule is 2. The billing system has reported one failed charge. What happens?
Choices: "Rev Rec retries now" · "Rev Rec waits. The billing system keeps trying first." · "The invoice is cancelled" (answer: 2nd).

## Level 2 · Static or smart retries

**Title:** Static or smart retries
**Idea:** Static retries use the same fixed timetable for every invoice. Smart retries choose the best time for each invoice.

| Node | Title | Caption |
|---|---|---|
| pick | Rev Rec | Must choose when to retry |
| static | Static | Follows a fixed timetable: 1 min, then 3 h, then 6 h |
| smart | Smart (highlighted) | Picks the hour most likely to work |
| retry | Rev Rec | Retries the card at that time |

| Edge | Label |
|---|---|
| pick → static | static mode |
| pick → smart | smart mode |
| static → retry | next time slot |
| smart → retry | best hour |

**Steps**
1. The card was declined. Rev Rec must choose when to try again.
2. Static mode: Rev Rec follows the same timetable for every invoice.
3. Smart mode: Rev Rec looks at the decline reason, the card, the day and the hour, and picks the best time.
4. At the chosen time, Rev Rec charges the saved card again.

**Number captions:** Static → "This demo uses the fixed timetable" · Smart → "This demo picks the best hour" · Monitoring → "This demo watches but does not retry".
**Check 2 question:** On the fixed timetable, how long is the wait before retry number 3?

## Level 3 · Max retries and grace period

**Title:** Max retries and grace period
**Idea:** Rev Rec stops after a set number of retries (max retries) or a set number of days (grace period), whichever comes first.

| Node | Title | Caption |
|---|---|---|
| retry | Rev Rec | Retries the card |
| decline | Processor | Declines again |
| check | Rev Rec (highlighted) | Retries left, and still inside the grace period? |
| again | Rev Rec | Plans the next retry |
| stop | Rev Rec | Stops retrying this invoice |

| Edge | Label |
|---|---|
| retry → decline | retry |
| decline → check | one retry used |
| check → again | yes |
| check → stop | no |

**Steps**
1. Rev Rec retries the saved card.
2. The card is declined again. One more retry is used up.
3. Rev Rec checks two limits: retries used against the maximum, and days passed against the grace period.
4. Both limits are fine: Rev Rec plans another retry.
5. One limit is reached: Rev Rec stops. The invoice ends as Terminated.

## Level 4 · Hard declines

**Idea:** Some declines can never succeed, like a stolen or closed card. Rev Rec stops on these at once.

| Node | Title | Caption |
|---|---|---|
| decline | Processor | Declines and gives a reason |
| catalogue | Rev Rec (highlighted) | Looks up the reason: can a retry still work? |
| later | Rev Rec | Soft decline: retries later |
| stop | Rev Rec | Hard decline: stops at once |

| Edge | Label |
|---|---|
| decline → catalogue | decline reason |
| catalogue → later | yes |
| catalogue → stop | no |

**Steps**
1. The bank declines and gives a reason, for example insufficient funds or stolen card.
2. Rev Rec looks up the reason in its list of decline codes.
3. Soft decline, like insufficient funds: the money may come back, so Rev Rec retries later.
4. Hard decline, like a stolen card: a retry can never work, so Rev Rec stops.

**Number caption:** "Retries after a hard decline"

## Level 5 · Card network limits

**Idea:** Visa and Mastercard limit how often a merchant may retry the same card. Rev Rec stays inside these limits.

| Node | Title | Caption |
|---|---|---|
| want | Rev Rec | Is ready to retry the card |
| cap | Rev Rec (highlighted) | Has this card reached the Visa or Mastercard limit? |
| retry | Rev Rec | Not yet: retries now |
| wait | Rev Rec | Limit reached: waits for it to reset |

| Edge | Label |
|---|---|
| want → cap | check limit |
| cap → retry | no |
| cap → wait | yes |

**Steps**
1. Rev Rec is ready to retry the card.
2. First it counts this card's retries today and in the last 30 days.
3. Under the limit: Rev Rec retries now.
4. Limit reached: Rev Rec waits until the count resets, then retries.

**Number:** "20" · caption "Retries per Visa card per day. Mastercard allows 10."
**Check 2 choices:** "Waits until the limit resets" · "Switches to another card" · "Gives up" (answer: 1st).

## Level 6 · Invoice queuing

**Idea:** When one customer has several unpaid invoices, smart retries work on them one at a time.

| Node | Title | Caption |
|---|---|---|
| open | Customer | Has 2 unpaid invoices on one card |
| first | Rev Rec (highlighted) | Retries invoice 1 only |
| recovered | Processor | Approves: invoice 1 is paid |
| next | Rev Rec | Moves on to invoice 2 |

| Edge | Label |
|---|---|
| open → first | wait in line |
| first → recovered | retry |
| recovered → next | next in line |

**Steps**
1. One customer has two unpaid invoices on the same card.
2. Rev Rec puts them in line and retries invoice 1 only.
3. The bank approves. Invoice 1 is paid.
4. Now Rev Rec starts on invoice 2.

**Number caption:** "Invoice per customer at a time"
**Check 2 choices:** "The processor requires it" · "It is faster" · "Every retry hits the same card. One at a time wastes fewer retries and avoids fraud alerts." (answer: 3rd).

## Level 7 · Paid outside Rev Rec

**Idea:** If the customer pays another way, for example in the app, the billing system tells Rev Rec. Rev Rec stops retrying.

| Node | Title | Caption |
|---|---|---|
| pay | Customer | Pays the invoice in the app |
| report | Billing system | Tells Rev Rec the invoice is paid |
| stop | Rev Rec (highlighted) | Cancels its planned retries |
| closed | Rev Rec | Closes the invoice as paid outside Rev Rec |

| Edge | Label |
|---|---|
| pay → report | payment |
| report → stop | invoice paid |
| stop → closed | close |

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

| Node | Title | Caption |
|---|---|---|
| approved | Processor | Approves the retry |
| recovers | Rev Rec | Marks the invoice recovered |
| paid | Billing system (highlighted) | Shows the invoice as paid |
| updates | Merchant app | Gets the message and unlocks the account |

| Edge | Label |
|---|---|
| approved → recovers | approved |
| recovers → paid | record back |
| recovers → updates | webhook |

**Steps**
1. The bank approves Rev Rec's retry.
2. Rev Rec marks the invoice recovered.
3. Record back: Rev Rec writes "paid" straight into the billing platform, for example Chargebee or Recurly.
4. Webhook: Rev Rec also sends a message to the merchant's server, so the app can unlock the account.

**Number:** "Webhook" · caption "This demo's billing system has no record back. It learns the result by webhook."
**Check 2 question:** This demo's billing system has no record back. How does the merchant learn the result?
Choices: "By webhook" · "By email" · "It never learns" (answer: 1st).
