# Invoice story · redesign brief (orchestrator, 23 Oct, after Aayush's review)

Aayush rejected the current story screen: the scenario cards, the "who does what" boxes and the arrow animation.
He wants two things instead. Build this; do not patch the old screen.

## 1. Entry = Orchestrator's "Try It Out" pattern
Copy the SDKPayment page layout (src/screens/SDKPayment: FormSection left, PreviewSection right).
- **Left panel ("Billing system")** is the form. It plays the merchant's billing system, like the checkout form plays the merchant's checkout:
  amount, currency, saved card (dropdown: "Good card 4242", "Declining card 0341", and the Stripe one-off decline cards 9995 insufficient funds, 9979 stolen, 0002 generic, for the first charge), customer (new / same as last), and one button **Charge customer** (the billing system's own MIT). A second small button **Customer pays in app** appears once an invoice exists. Cancel invoice in a kebab menu.
  No scenario cards. Scenarios become **presets** in a small dropdown at the top of the form ("Presets: temporary error, insufficient funds, paid in app, duplicate, hard decline…") that just fills the form fields.
- **Right panel** is the product itself (see 2).

## 2. The story is the product itself, with a sequence diagram on top
- **Top of the right panel: a sequence diagram** (UML style, the dashboard's fonts and colors, drawn with plain SVG/divs, no cartoon animation). Four lifelines: Billing system · Rev Rec · Processor · Customer. Each real event becomes one horizontal message arrow with a short label and a timestamp, appended as it happens (from the story's `timeline` and `requests`): "charge $65.40 → declined (generic_decline)", "report failure → 200 recorded", "pick retry time → 20:44:38", "charge saved card → approved", "mark invoice paid". Pending future retry shown as a dashed arrow with the countdown. Nothing moves; new rows appear.
- **Below the diagram: the real invoice detail page**, reused as-is (ShowRevenueRecovery / RecoveryInvoicesHelper / AttemptsHistory): status alert, order details, attempts table. It polls and updates live. This is the "simulation of the app itself".
- **Explain on click only.** Click any arrow in the diagram, or any attempt row, to open a right side drawer (the dashboard's side drawer component) with: what happened, who did it, why (the explain lines with source labels: sandbox / recomputed / rule), and the raw request + response for that step. No always-open Why panel, no Now card.
- Keep the stepper of states out. The invoice status alert already shows the state. If a compact state is needed, use the invoice list's status badge only.

## 3. Behaviour
- Pressing **Charge customer** starts the story (POST /sim/story/start with the form values; A adds form fields to the start body, see Contract). The diagram's first rows appear at once (the billing system's charges and reports), then the page polls.
- URL stays /v2/recovery/simulator/story/{storyId} so refresh resumes.
- Remove the scenario picker screen, the 4 boxes, the moving arrow, the Now card and the always-on Why panel.

## 4. Contract additions (A)
- `POST /sim/story/start` accepts `{amount, currency, card: "4242"|"0341"|"9995"|"9979"|"0002", customer: "new"|"same", preset?: 1..8}`. Preset fills defaults; explicit fields win.
- Story view adds `timeline[]` entries with `{at, from, to, label, status, stepId}` suitable for the diagram, and `requests[]` entries carry the same `stepId` so a click can show the raw call.
- `POST /sim/story/:id/cancel` already exists; expose it in `actions`.
