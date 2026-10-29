# Rev Rec Simulator · status, 28 Oct 2026

For Aayush and reviewers. The simulator runs on our own self-hosted Hyperswitch engine. Since 28 Oct every story runs in smart mode, on Stripe only, with one card from the visitor. Nothing is pushed. Details, ids and proofs are in `NOTES.md`; the QA pass of 27 Oct is in `QA-27oct.md`.

## What changed on 28 Oct

- **One card, the story decides the bank.** The visitor gives one card (default 4242; any Stripe test card that approves, for example 5555 5555 5555 4444). It is the customer's saved card.
  - The story makes the failure. The first charge fails on a test card the story picks (for example 9995 for "not enough money").
  - Where retries must fail, the scripted bank declines Rev Rec's charges on the visitor's card until an event changes it (money back, a payment in the app).
  - The timeline says each card the story picks, in plain words.
  - Proven with 4242 and 5555 5555 5555 4444 on stories 2, 4, 6 and 7.
- **Only the card the customer gave.** By the user's policy, the simulator never charges a card the customer did not give for this invoice.
  - The "New card" event and story 9 (Rev Rec moves to the customer's second saved card) are hidden behind one flag, `SIM_OTHER_CARDS`, off. Their code stays.
  - Story 6 recovers when the money comes back on the same card ("Money is back"), with no card swap.
  - The checkout's saved-card tiles stay: the customer picks the card when paying.
- **Returning customer on a first visit.** With no earlier customer in the browser, the story makes one: a saved Visa ••4242 that paid last month's invoice. The rows say "made for this demo".
- **Smart only.** Every story starts in smart mode. Rev Rec's model picks the days; the sim's calendar turns them into demo seconds and shows the real-life times.
- **Pause.** The visitor can pause a running story. Rev Rec's next retry waits, and the demo clock stops. Resume continues where it stopped. A pause ends by itself after 15 minutes.
  - Proven in both modes: held 2 minutes, no retry ran, and the next retry came less than 1 second from its expected time.
- **The fixed timetable, computed.** Stories 11-20 now state the bank's fact ("The money comes back 5 days after the failure."). Next to the result, a "computed" line says how many tries the fixed timetable would have needed.
  - Example, story 18: smart recovered on retry 4; the fixed timetable would have needed 14 tries.
- **Story 8 (two invoices, one customer).** The engine charges one invoice at a time, and the two take turns. The story now ends only when both invoices have ended.
- **Stripe only.** The six other processors are hidden, not deleted. One flag, `PROCESSORS_ENABLED`, brings them back. Their engine profiles, keys and scripts stay ready.

## What runs today

- **Self-hosted engine.** Hyperswitch v2 (tag 2026.10.26.0) on one GCP VM (`revrec-hs`, us-central1-a).
  - The compose stack: router, retry scheduler, Postgres, Redis, a stand-in decider, a webhook inbox and the sim service (calendar, model numbers, scripted bank, pause).
  - `selfhost/seed.sh` builds the merchant, profiles, connectors, GSM rows and seeded retry stats. `selfhost/smart-profiles.sh` turns on smart mode with the model for the processor profiles.
- **20 stories.** 10 classic ones and 10 real-world ones.
- **Live settings** in a running story: max tries, grace period (smart), pause. Six pooled profiles, one per story.
- **Events** in a running story: money back, card stolen, bank outage.
- **Cloud Run:** one service, `revrec-sim`, behind the shared password. Its image is from 27 Oct; the next deploy needs a new image.

## What is simulated (and labelled so on screen)

- **The bank is scripted.** The sim decides each retry by the story's rule and the real-life time. The decline itself is real: Stripe answers with its own code.
- **Time is compressed.** Retries run seconds apart. Each row also shows its real-life time.
- **Seeded model stats.** The model's success counts are made up (`selfhost/MODEL.md`), so the engine's real model has numbers to read.
- **Stand-in decider** for story 8 (and the hidden story 9), not the real decider service.

## Engine limits we know of

- **Story 8 is smart without Rev Rec's model** (so is the hidden story 9). With the model on, the engine charges only the invoice's own card and never asks the decider.
- **The first retry at four processors uses the fixed timetable** (Adyen, NMI, Cybersource, Worldpay; hidden now). The engine checks the reported failure with the processor and keeps that answer. These checks fail, so the decline reason is lost and the model has nothing to read. From the second retry, the model picks.
- **A cancel during a retry is refused** ("try again shortly"). The simulator tries again after 2 seconds, up to 3 times.
- **Static grace** is still refused mid-story: the engine counts real days.
- Earlier gaps at Worldpay and the processors that do not work at all (Nuvei, Payeezy, Worldpay Vantiv, Deutsche Bank) are in `NOTES.md`.

## Deploy (prepared, not done)

- Recipe: `deploy/README.md` sections 5 and 5b (one image, `Dockerfile.all`, built on Cloud Build).
- Before the next deploy:
  1. Write the inbox and sim tokens to Secret Manager with `put-secrets.sh`. The 14 processor keys are optional now (`WITH_PROCESSORS=1`).
  2. Add a fresh dashboard token (it expires about every 2 days).
  3. Build a new image and run the deploy line in 5b.

## Waiting on Aayush

- **Push go-ahead.** The local commits are squashed into one before the first push. The scan of 27 Oct found no keys, tokens or people's names.
- **Deploy go-ahead** and the secret writes above.
- A low-rights dashboard user before a public link (the proxy uses a switched token today).
- Done on 28 Oct: SSH to the VM now works only through IAP, and the RDP rule is deleted.

## Run it locally

1. **Proxy:** `cd simulator/proxy`, fill in `.env.vm` (the VM engine through the SSH tunnel; see `selfhost/README.md`), `npm install`, then `PORT=8787 SIM_ENV_FILE=.env.vm npm run start:awake`. Check `curl localhost:8787/healthz`.
2. **Dashboard:** in the repo root, `npm install`, `npm run re:build`, `npm run start`. Open http://localhost:9000/dashboard/v2/recovery/home.
3. **Tests:** `cd simulator/proxy && npm test` (offline tests and one live story).
