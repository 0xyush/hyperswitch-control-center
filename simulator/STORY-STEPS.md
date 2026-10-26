# Invoice story · step-by-step rendering (brief, 26 Oct, after Aayush's review)

Aayush pressed Charge customer and saw nothing for several seconds, then all rows at once. He wants the story to
feel alive and to read as numbered steps: step 1, step 2, step 3… each appearing in turn.

## 1. Immediate feedback on Charge customer
- The instant the button is pressed: button goes to a loading state ("Charging…"), the form locks, and the diagram
  panel shows a pending first row at once: "Step 1 · Billing system creates invoice $65.40" with a spinner, before any
  response arrives. The proxy already returns `status: starting` in ~30 ms; use that response to confirm, but do not
  wait for it to show the row.
- While `status == starting`, poll every 1 s (not 4 s). A thin progress bar or pulsing dot under the diagram header says
  "Working… the billing system is charging the card" / "…reporting to Rev Rec" / "Rev Rec is picking a retry time",
  driven by the latest row's `from`/`to`.
- Never show the "Press Charge customer…" empty text once a story exists.

## 2. Steps, not just arrows
- Every timeline row gets a step number badge on the left: 1, 2, 3… in order of `at`. The sequence diagram stays
  (lifelines + arrow), but each row is a step card: badge, one-line title (the label), the lifeline arrow, the time.
- Rows **appear one at a time** with a short reveal (fade + slide, 250 ms, CSS only, the dashboard's easing). When one
  poll brings several new rows, stagger them 400 ms apart so the eye can follow. Nothing moves after it has landed.
- The newest step is highlighted (left border in the dashboard's primary blue) until the next one arrives.
- A pending retry (the `pending` row) is the last step, dashed, with the countdown; when it fires it turns into a
  normal step in place.
- At the end add a final step card: "Done · Invoice recovered by Rev Rec" (green) or "Done · Rev Rec stopped" (red)
  or "Done · Paid outside Rev Rec" (grey).

## 3. A step strip above the diagram (the "flow steps")
- A horizontal stepper under the "What happened" header with the 5 phases:
  1 Billing charge → 2 Report to Rev Rec → 3 Rev Rec picks a time → 4 Rev Rec retries → 5 Outcome.
  Each phase lights up (filled circle + check) as its first row lands; the current phase pulses. Use the dashboard's
  VerticalStepIndicator / step components turned horizontal, same colors as Intelligent Routing's wizard.
- Clicking a phase scrolls to its first step card.

## 4. Keep
- Click on a step opens the same drawer (why + raw request/response). Keep the invoice page below.
- No fake delays: reveal timing is only for rows that have already arrived; real waits show the real countdown.

## 5. Acceptance
- Press Charge customer: a step card and a loading state appear within 100 ms.
- Preset 2 end to end: steps 1..N appear one by one, the phase strip advances 1→5, final "Done" card is green.
- Refresh mid-story: all steps already known render at once (no replay animation), phase strip correct.
