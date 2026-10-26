# UX pass 2 (26 Oct, Aayush's review of every screen) — less text, cleaner, seamless, gamified

Principle for every screen: a non-technical visitor should understand it in 5 seconds. Fewer words, bigger ideas,
one action at a time. Use the dashboard's components and spacing. No new copy longer than one sentence.

## A. Invoice story (B)

### A1. Billing form: no dropdown wall
- **Amount:** a plain number field with a $ prefix and three quick chips under it (25 · 65.40 · 120). Currency becomes a small suffix toggle (USD/EUR/GBP), not its own field.
- **Preset → "Scenario":** a row of 4 big selectable tiles with an icon and 3-word title: "Temporary error", "Pays in app", "Insufficient funds", "Stolen card". Hover shows one sentence. Not-runnable ones are greyed with a tiny tag.
- **Saved card:** two visual card tiles (a mini card graphic): "Good card ••4242" and "Declining card ••0341". The first-charge card is chosen by the scenario, not the user (keep it in "Advanced" collapsed).
- **Customer:** a single toggle chip "New customer / Same customer".
- One primary button **Charge customer**. Nothing else below it until a story exists.
- The description paragraph under "Billing system" → one line: "You are the merchant's billing system."

### A2. Header strip: remove the control clutter
- Remove the "Auto-play" switch, "Invoice states" and "Show sequence diagram" buttons from the header. Put them in a single "⋯" menu top-right of the panel. Auto-play stays off.
- "What happened" + its subtitle → just the phase strip. The phase strip IS the header. Under it one status line: **live invoice status badge** (Monitoring / Scheduled / Processing / Recovered / Terminated, same badge component as the Invoices list) + amount recovered "$0.00 of $65.40" + "N Rev Rec attempts". This is the "I don't have to switch tabs" ask.

### A3. Step rows: fewer words
- Step title ≤ 8 words. Drop "Billing system" from titles when the actor chip already says Billing. E.g. "Charged $65.40 on ••0341" · chip Declined. "Reported the failure to Rev Rec" · chip 200 → replace the 200 chip with a green check.
- Detail line only when it adds something ("3 tries, last one declined"). Remove "reported after each of the 3 tries".
- The "Why" link becomes a small "?" icon button at the row end. Time stays muted right.

### A4. Actions row: one clear next action
- After the billing phase, show ONE primary button on the last row: **Let Rev Rec retry →** (or, when the sandbox has not booked within 60 s: a quiet amber pill "Rev Rec hasn't booked a retry yet · sandbox" with a "?" that opens the why; keep polling).
- "Customer pays in app" becomes a secondary ghost button to the right. "Report another failure" moves to the "⋯" menu as "Billing retries once more (fails)".
- Buttons: dashboard primary/ghost styles, 36px height, same radius; the spinner pill is replaced by the amber pill above.

### A5. Below the story: no second page
- Remove the full "Invoice Recovery Details" + "Attempts History" from under the story. Replace with one compact card: status badge, recovered bar, attempts count by who (Billing 3 · Rev Rec 0), and a link **Open invoice page →** (goes to the real Invoices › detail). Attempts History is already represented by the steps.

## B. Feature tour → "Learn Rev Rec" (C)
- Rename to **Learn Rev Rec**. Replace the wall of panels with a **level path**: 8 levels as a vertical path of circles (Duolingo-style; use the dashboard's stepper look). Each level = one feature. Title ≤ 4 words, one-line hook.
  1 The start rule · 2 Static vs smart retries · 3 Max retries & grace period · 4 Hard declines · 5 Card network limits · 6 Invoice queuing · 7 Paid outside Rev Rec · 8 Record back & webhooks.
  Display-only extras (multi-card, account updater, partial auth, dunning, integration models, processor choice) become a 9th level "More features" with expandable one-liners.
- Clicking a level opens a **card modal** with 3 panes you step through with Next: (1) one sentence + one icon, (2) the real value from the sandbox in big type with its "From the sandbox" chip, (3) a one-question check ("With start rule 0, when does Rev Rec take over?" 3 choices). Correct → confetti-free green check and the level circle turns green; progress saved in localStorage; a progress bar "3 of 8 learned" at the top.
- Each level has "Try it in the story →" that opens the story with the matching scenario preselected.
- Remove the "Live / Read-only / Display only" tags from the main view (keep them inside pane 2 as a small chip).

## C. Portfolio run (C)
- Left form: same simplification as A1. "Number of invoices" → two tiles (10 · 25). "Stop after" → tiles (10 · 20 · 45 min). Amount as in A1. **Decline mix** → one stacked bar you drag the boundaries of, with 5 colored segments and % labels (or, if too costly, keep sliders but half the height and inline labels). Remove the "Card mix" block entirely (put "Visa only" as a footnote).
- Right: while setting up, show a **big progress ring** "Creating 10 invoices twice…" with the count; after that the four cards. Shorten every title: "Recovery rate", "Recovered", "Attempts per recovery", "Minutes to recover". Subtitles go.
- When one side has zero attempts (smart today): a single amber banner on that card column, one sentence, with "?" for the why. No long text.
- Remove the paragraph under "Portfolio run" title; one line: "Same invoices, two strategies, real sandbox."

## D. Everywhere
- Replace all "Why" text links with the "?" icon button. All source labels become tiny chips. No sentence over 15 words in UI copy.
- Sandbox-stall note: after **60 s** (not 3 min) in Monitoring with no task.

## Acceptance
- Story: form has 1 number field, 4 scenario tiles, 2 card tiles, 1 toggle, 1 button. Header = phase strip + status line. One primary action at a time. No second page below.
- Learn: 8 levels on a path, each a 3-pane modal with a check question, progress bar.
- Portfolio: tiles instead of dropdowns, progress ring, four short cards.
