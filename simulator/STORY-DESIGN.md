# Invoice story · design pass (26 Oct, third review by Aayush)

The step list works but reads as a log: eight equal grey cards, API labels, no flow. Make it a story. This replaces the
card list in STORY-STEPS.md sections 2 and 6; keep sections 1 (instant feedback), 3 (phase strip) and the pacing.

## 1. Group into phases, not a flat list
Render the steps under phase headings. Each phase is a block with a title, a one-line plain-words summary and its steps.
Phases (only those that happened are shown):
1. **The charge fails** — billing system charges the saved card, the bank declines.
2. **Rev Rec is told** — the billing system reports it; Rev Rec records the invoice and takes over.
3. **Rev Rec plans a retry** — picks a time; the booked retry with a countdown.
4. **Rev Rec retries** — charges the saved card by itself; approved or declined.
5. **The customer acts** (if it happened) — pays in the app / adds a card.
6. **Outcome** — Recovered by Rev Rec / Paid outside Rev Rec / Rev Rec stopped / Cancelled.

## 2. Fold the plumbing
Steps nobody needs to see by default are collapsed into their parent as a grey "details" line, not their own card:
- "save card ••0341" → folded into "The charge fails" as a detail: "card ••0341 on file".
- "report failure → 200 recorded" → the phase-2 headline says "Billing system reported the failure. Rev Rec recorded it." with the 200 as a small chip.
- "new invoice $65.40" → becomes the story header, not a step: "Invoice $65.40 · customer cus_… · card ••0341".
- "report paid outside Rev Rec → 200" + "invoice paid outside Rev Rec" → one outcome card.
A "Show all N events" link at the bottom expands every raw event (the current flat list) for engineers.

## 3. Plain-words titles, one per step, with the actor as a chip
Write titles as sentences a non-technical person reads, with the actor as a coloured chip on the left (Billing · Rev Rec · Bank/Processor · Customer), not "Billing system → Processor":
- "Billing system charged $65.40 on ••0002" + status chip **Declined · generic decline**
- "Rev Rec picked a retry time: 11:19:04" + "in 0:28" countdown chip while pending
- "Rev Rec charged the saved card ••4242" + **Approved**
- "Customer paid $65.40 in the app with ••4242" + **Approved**
- "Invoice recovered by Rev Rec" (green outcome card) / "Invoice paid outside Rev Rec" (grey) / "Rev Rec stopped: hard decline" (red)
Keep the raw label in the drawer. Keep "Why" as a small link on the right of the title, not on its own line.

## 4. Visual flow
- One vertical rail on the left (the dashboard's timeline style, like Attempts History): a dot per step, coloured by status (grey pending, green ok, red declined, blue Rev Rec action), joined by a line. Phase headings sit on the rail with a larger dot.
- Step cards are flat (no border box each): title row + one muted detail line. Only the outcome card is a filled card.
- The newest step glows (blue left border) until the next arrives. The pending retry is a dashed dot with the countdown.
- Times are right-aligned, muted, relative under hover ("+1 min 12 s since charge").
- Spacing: 12 px between steps, 24 px between phases. Max width 760 px.

## 5. Pacing (unchanged)
Pause after phase 2 with "Next: let Rev Rec retry →" on the rail. Auto-play switch. "Waiting for Rev Rec… countdown"
when the next step has not arrived. Phase strip above stays as the summary and jumps to a phase.

## 6. Acceptance
- Preset 2 reads top to bottom as: header → The charge fails (1 step + detail) → Rev Rec is told (1) → Rev Rec plans a retry (1, countdown) → Rev Rec retries (1, Approved) → Outcome card (green). Five things, not eleven.
- "Show all events" reveals the raw list. Drawer still opens from any step. Refresh renders all known steps at once.
