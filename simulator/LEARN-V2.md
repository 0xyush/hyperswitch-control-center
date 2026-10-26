# Learn Rev Rec v2 (26 Oct, Aayush's review): real lessons, flow diagrams, two questions, no disclaimers

## Shape of a level
Each level is a 5-pane lesson stepped with Next (same modal, same measured layout, pane slot height fixed):
1. **Idea** — one sentence + icon (as today).
2. **How it works** — a FLOW DIAGRAM: 3 to 5 nodes left-to-right with labelled arrows, drawn with React Flow
   (`reactflow`, read-only, fitView, no minimap, dashboard colours, nodes are the actors: Billing system, Rev Rec,
   Processor, Customer, Bank). One highlighted node/arrow per level that this feature is about. Static layout, no
   dragging; animate only the highlighted edge (dashed flow) on open.
3. **In numbers** — the real value for this demo profile in big type (start rule 0, max retries 15, …), with ONE line
   of context ("Rev Rec takes over on the first failure"). No chips, no "From the sandbox", no "Live/Read-only".
4. **Check 1** — a question with 3 choices.
5. **Check 2** — a second question, different angle (a scenario: "A card is declined as stolen. What does Rev Rec do?").
   Level turns green only when both are right (one retry allowed per question, then show the answer).

## Remove
- The chips "From the sandbox", "Live", "Read-only", "Rule-based" inside the lessons.
- The amber warning "The sandbox has no smart decider yet…" in level 2 (keep a plain sentence in pane 3 only if needed:
  "In this demo, smart retries use the static ladder").
- The subtitle "Eight short levels. Each ends with one question." → "Eight short levels."

## Content per level (titles ≤ 4 words; each question with its 3 choices and the right one marked)
1 The start rule — flow: Billing charges → declined → Billing reports → Rev Rec counts failures vs start rule → takes over.
  Q1 "With start rule 0, when does Rev Rec take over?" (After the first failure ✓ / After three / Never)
  Q2 "Start rule is 2 and the billing system reported one failure. What happens?" (Rev Rec waits for more failures ✓ / Rev Rec retries now / The invoice is cancelled)
2 Static vs smart retries — flow: Rev Rec picks a time → static: fixed ladder (1 min, 3 h, 6 h…) | smart: model scores each hour → books the best.
  Q1 "What does smart mode add?" (It picks the hour with the best chance ✓ / It retries more often / It skips hard declines)
  Q2 "Static retry number 3 waits how long on the production ladder?" (6 hours ✓ / 1 minute / 1 day)
3 Max retries & grace period — flow: retry → declined → count +1 → under max and inside grace? → retry again | else stop.
  Q1 "Max retries is 15. After the 15th decline Rev Rec…" (stops ✓ / keeps going / asks the customer)
  Q2 "The grace period ends before the next retry. Rev Rec…" (stops retrying ✓ / retries once more / extends the period)
4 Hard declines — flow: Processor decline → error catalogue: soft or hard? → soft: retry later | hard: stop at once.
  Q1 "A stolen card is a…" (hard decline ✓ / soft decline / temporary error)
  Q2 "Why stop on a hard decline?" (More retries cannot succeed and can cost fees ✓ / The customer asked / The card is expired)
5 Card network limits — flow: Rev Rec wants to retry → count retries on this card today/this month → under the cap? → retry | wait.
  Q1 "Who sets the cap on retries per card?" (The card networks, Visa and Mastercard ✓ / The merchant / Stripe)
  Q2 "The cap is reached. Rev Rec…" (waits until the window resets ✓ / switches card / gives up)
6 Invoice queuing — flow: customer has 2 open invoices → Rev Rec works on one → recovered → next.
  Q1 "Two invoices, one customer. Rev Rec retries…" (one at a time ✓ / both at once / the newest only)
  Q2 "Why one at a time?" (Spend the retry budget wisely and avoid fraud flags ✓ / The processor requires it / It is faster)
7 Paid outside Rev Rec — flow: customer pays in the app → Billing reports success → Rev Rec stops → invoice recovered (paid outside).
  Q1 "The customer pays in the app mid-recovery. Rev Rec…" (stops and marks it paid outside ✓ / retries anyway / refunds)
  Q2 "Who counts that recovery?" (The billing system, not Rev Rec ✓ / Rev Rec / Nobody)
8 Record back & webhooks — flow: Rev Rec recovers → tells the billing platform (record back) → sends a webhook → merchant's system updates.
  Q1 "Record back means…" (Rev Rec tells the billing platform the invoice is paid ✓ / The customer gets a receipt / The card is saved)
  Q2 "Custom billing has no record back. The merchant learns the result from…" (the webhook ✓ / an email / nothing)

## Also
- "Try it in the story" stays on the last pane.
- Progress bar and localStorage as today; a level is learned only when both checks pass.
- React Flow: add `reactflow` (pinned, MIT) to package.json; one shared `LessonFlow` component; nodes/edges per level
  live in SimulatorTourUtils; keep bundle impact small (import once, lazy).
