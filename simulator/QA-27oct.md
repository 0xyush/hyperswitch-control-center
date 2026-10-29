# QA pass of the local stack, 27 Oct 2026 (A)

**Result:** all 27 stories and both portfolio runs ended as their tiles promise. There were 0 unexpected 5xx or 409 answers and no stuck engine task. One leak was found and fixed: a pool profile stayed leased after a story stopped polling. Every wording issue was in A's texts. They are fixed and rechecked.

Setup: the local stack (:8787, the VM engine through the tunnel, C's sim service and bank), 27 Oct 20:10–20:26 UTC. Static retries unless noted. At most 3 stories at once; the portfolio runs ran alone with 8 invoices each. Runner: a script that uses the API as the dashboard does. The dashboard UI itself was not clicked; that is B's pass.

## Results

Wording issues = lines over 12 words or with a WORDING.md banned word in the rows, why lines, explain lines and caption (labels B parses not counted). These counts are from the run, before the fixes below.

| Run                            | Story             | Ended                             | Rev Rec retries | Promise (tile) and actions                                                                                                                                                                                                 | As promised | Unexpected errors | Stuck?                                            | Wording issues |
| ------------------------------ | ----------------- | --------------------------------- | --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ----------------- | ------------------------------------------------- | -------------- |
| P1 customer pays in app        | `st_6d331477d4f9` | recovered                         | 1               | recovered, paid outside Rev Rec — paid-in-app -> 200                                                                                                                                                                       | yes         | 0                 | no                                                | 2              |
| P2 temporary error             | `st_f0a3f3debd86` | recovered (recovered on 1)        | 1               | recovered on retry 1                                                                                                                                                                                                       | yes         | 0                 | no                                                | 0              |
| P3 duplicate report            | `st_17a1f9e024ac` | queued                            | 1               | duplicate refused, one kept                                                                                                                                                                                                | yes         | 0                 | lease kept until the invoice ended (fixed: sweep) | 1              |
| P4 keeps declining             | `st_027a88a4ea3e` | terminated                        | 15              | terminated after 15                                                                                                                                                                                                        | yes         | 0                 | no                                                | 0              |
| P5 network limit               | `st_691f554aab1c` | terminated                        | 15              | terminated after 15                                                                                                                                                                                                        | yes         | 0                 | no                                                | 0              |
| P6 insufficient then swap      | `st_066fd89e60b2` | recovered (recovered on 2)        | 2               | recovered after the swap — charge fails again (swap) -> 200                                                                                                                                                                | yes         | 0                 | no                                                | 2              |
| P7 hard decline                | `st_5bc26f48cce8` | terminated                        | 0               | terminated after 0                                                                                                                                                                                                         | yes         | 0                 | no                                                | 0              |
| P8 second invoice (queue)      | `st_ee808267db31` | terminated                        | 15              | queue: The two invoices took turns. Rev Rec charged one at a time.                                                                                                                                                         | yes         | 0                 | no                                                | 3              |
| P9 second saved card           | `st_04cd79a05b3f` | recovered (recovered on 1)        | 1               | recovered on 4242                                                                                                                                                                                                          | yes         | 0                 | no                                                | 1              |
| P10 go-live                    | `st_e9a56ef33ab1` | recovered (recovered on 1)        | 1               | backlog Recovered,Recovered,Recovered — monitoring retries before go-live: 0,0,0; go-live -> 200                                                                                                                           | yes         | 0                 | no                                                | 1              |
| P11 Bank hiccup                | `st_ed68d07c08c2` | recovered (recovered on 2)        | 2               | recovered on retry 2                                                                                                                                                                                                       | yes         | 0                 | no                                                | 0              |
| P12 Daily limit                | `st_e8bf352d31fc` | recovered (recovered on 5)        | 5               | recovered on retry 5                                                                                                                                                                                                       | yes         | 0                 | no                                                | 5              |
| P13 Fraud check                | `st_ac6b2bbe825f` | recovered (recovered on 6)        | 6               | recovered on retry 6                                                                                                                                                                                                       | yes         | 0                 | no                                                | 0              |
| P14 Weekend low balance        | `st_4c02823d48ec` | recovered (recovered on 7)        | 7               | recovered on retry 7                                                                                                                                                                                                       | yes         | 0                 | no                                                | 7              |
| P15 Payday                     | `st_364c2fdeea98` | recovered (recovered on 14)       | 14              | recovered on retry 14 (next payday, this date)                                                                                                                                                                             | yes         | 0                 | no                                                | 14             |
| P16 Travel block               | `st_2966e07730dd` | recovered (recovered on 9)        | 9               | recovered on retry 9                                                                                                                                                                                                       | yes         | 0                 | no                                                | 0              |
| P17 Over credit limit          | `st_21b0b6f44c26` | recovered (recovered on 11)       | 11              | recovered on retry 11                                                                                                                                                                                                      | yes         | 0                 | no                                                | 11             |
| P18 Second-last chance         | `st_dc35d0dba910` | recovered (recovered on 14)       | 14              | recovered on retry 14                                                                                                                                                                                                      | yes         | 0                 | no                                                | 14             |
| P19 Last chance                | `st_4287ba517358` | recovered (recovered on 15)       | 15              | recovered on retry 15                                                                                                                                                                                                      | yes         | 0                 | no                                                | 15             |
| P20 Too late                   | `st_73d94924627c` | terminated                        | 15              | terminated after 15                                                                                                                                                                                                        | yes         | 0                 | no                                                | 16             |
| E1 money back (preset 4)       | `st_26de2015865a` | recovered (recovered on 3)        | 3               | recovered on retry 3 — event money_back after retry 2 -> 200                                                                                                                                                               | yes         | 0                 | no                                                | 0              |
| E2 new card (preset 13)        | `st_c37f67a0ef33` | recovered (recovered on 3)        | 3               | recovered on 4242 at retry 3 — event new_card after retry 2 -> 200                                                                                                                                                         | yes         | 0                 | no                                                | 0              |
| E3 stolen (preset 17)          | `st_3572c3888a30` | terminated                        | 3               | terminated after 3 — event stolen after retry 2 -> 200                                                                                                                                                                     | yes         | 0                 | no                                                | 3              |
| E4 outage (preset 12)          | `st_a461aa66f9ce` | recovered (recovered on 5)        | 5               | retry 3 processing_error, recovered on 5 — event outage after retry 2 -> 200                                                                                                                                               | yes         | 0                 | no                                                | 4              |
| S1 max tries 6 (preset 4)      | `st_8a653794568b` | terminated                        | 6               | stops at 6 with the reaction — settings {"maxRetries":6} after retry 2 -> 200                                                                                                                                              | yes         | 0                 | no                                                | 0              |
| S2 smart (preset 18)           | `st_40487ecdc1d1` | recovered (recovered on 5)        | 5               | recovered (static would be retry 14); got 5 — settings {"mode":"smart"} after retry 2 -> 200                                                                                                                               | yes         | 0                 | no                                                | 5              |
| S3 smart + grace 5 (preset 16) | `st_6d5d0acd7046` | recovered (recovered on 5)        | 5               | ended recovered; no fallback — settings {"graceDays":5} after retry 2 -> 409; settings {"mode":"smart"} after retry 2 -> 200; settings {"graceDays":5} after retry 2 -> 200; settings {"paused":true} after retry 2 -> 409 | yes         | 0                 | no                                                | 0              |
| portfolio 1 min                | `pf_11c95969`     | ended at the time cap after 85 s  | –               | ends at its cap; no errors                                                                                                                                                                                                 | yes         | 0                 | no                                                | –              |
| portfolio 3 min                | `pf_05f82f71`     | ended at the time cap after 205 s | –               | ends at its cap; no errors                                                                                                                                                                                                 | yes         | 0                 | no                                                | –              |

Events and settings: E1–E4 sent the event after Rev Rec's 2nd retry. S1–S3 changed settings after the 2nd retry. S3 also sent grace on static and pause on purpose; both got the expected 409 with the plain reason, so they are not counted as errors.

## Stuck-state checks

- **Engine tasks:** after the run, every task in the engine's process tracker had status `finish`. Nothing was left processing.
- **Pool leases:** all returned. P3 (the duplicate preset) is "done" once the copy is refused, but its invoice goes on retrying. Nobody polls the story after that, so its profile came back only when a view saw the invoice end. **Fixed** (c54c38a8b): the sweep refreshes leased stories every minute. Rechecked: the P3 rerun `st_6cc7f4dc6893` got its profile back about a minute after the invoice ended.
- **Invoices stuck in Scheduled:** none. Every story reached `done` within its time limit.

## Fixes made (A, commit c54c38a8b; :8787 restarted)

- Rows quoted Stripe's decline message word for word ("Your card has insufficient funds. Use a different payment method to complete this purchase."): too long, with banned words. This caused most of the counts (bank stories 12, 14, 15, 17–20; E3, E4). Rows now say "The bank said no: no money on the card right now." The raw call keeps Stripe's message.
- Rows carried Stripe and engine ids (the saved-card row, new invoice, report, paid in the app). Removed; the raw calls keep them. B also noticed this.
- Shortened to 12 words or fewer: the mode why on the booking row ("Mode: ..."), "Rev Rec is on now. This report starts the invoice's retries." (P10), preset 8's two why lines, "Rev Rec refused the copy: it already has this charge." (P3), and P1's paid-in-app texts.
- A grace of 2 days or less in smart mode: "Grace is too short for Rev Rec's model. It uses the fixed timetable." (C's explanation of the engine's V1 window).
- **Recheck** after the fixes: P1 `st_e203156f2b46`, P3 `st_6cc7f4dc6893`, P12 `st_98bce9e80613` and P14 `st_6aecd6048fb6` each ended as promised with **0** wording issues.

## For B

- The API side has no open issue for B. The UI was not covered by this pass; please click through presets 1–20, the settings group and the event buttons once.
- Done on my side: the new-card row text no longer carries the Stripe id.

## For C

- Portfolio: at the time cap, invoices still trying end as Cancelled on the engine. **Resolved, intended (C):** the proxy cancels open copies so nothing keeps retrying; they carry `stillTrying: true`, show as "Still trying", and are left out of the recovery rate (dbfd5a4bf, 0ec7ab697).
- Nothing else found.

## Notes

- S2 (preset 18, money back 5 days after the failure): switched to smart after retry 2 and **recovered on retry 5**; the fixed timetable needs retry 14.
- S3 (preset 16): smart with grace 5 days: the model kept deciding (no fallback) and recovered on retry 5.
- P8 (queue): the two invoices took turns, one charge at a time.

## UI (B, 27 Oct, dashboard in a real browser)

Runner: headless Chrome against :9000 and :8787, as a first-time visitor. Scripts in B's scratchpad (qa-ui.mjs, qa-pages.mjs). At most 3 stories at once.

**Story click-through, presets 1–20 (static).** Every end row matched the expected result; no page errors; no Stripe or engine ids on screen.

| Preset | Action | End row |
|---|---|---|
| 1 Pays in app | Customer pays in the app after the first booking | Paid outside Rev Rec |
| 2 Temporary error | none | Recovered on retry 1 |
| 3 Duplicate report | none | Story complete: the invoice is still Monitoring |
| 4 Card keeps declining | none | Stopped after 15 retries |
| 5 Card network limit | none | Stopped after 15 retries |
| 6 Insufficient funds | Charge fails again after retry 1 | Recovered on retry 2 |
| 7 Stolen card | none | Stopped at once · hard decline (stolen card) |
| 8 Second invoice, same customer | none | Stopped after 15 retries (Queued, then turns) |
| 9 Second saved card | none | Recovered on retry 1 |
| 10 Go live with a backlog | Turn Rev Rec on | 3 of 3 old invoices recovered |
| 11–19 Real-world | none | Recovered on retry 2, 5, 6, 7, 14 (Payday), 9, 11, 14, 15 = as listed |
| 20 Too late | none | Stopped after 15 retries |

**Settings and events (live).** Max tries 15 → 5 stopped at 5 (`st_7596e641ac9a`); Smart + grace 5 days, model view shown (`st_2b7ee16749f2`); money back → recovered on retry 3 (`st_c8bd927e0fa3`); new card → retry 3 on 4242 recovered (`st_0ec3b9c350a5`); outage then stolen → stopped after 5 (`st_d61038aad292`).

**Pages at 1440 and 900** (Home, Setup, Invoice story hero and a finished story, Learn page, a Learn level, Glossary, Portfolio form, Health): no horizontal overflow, no button label on two lines, no sentence over 12 words in the main area, no console errors at 1440. At 900 one React warning on every page, `enableVirtualization` on a DOM element, from the dashboard's Blend select (also on the upstream Invoices page): not simulator code.

**One window at 1440×900:** hero, pre-handover, running and finished stories all fit (document 900/900); only the story column scrolls.

**Found and fixed in this pass (B):** the handover button disappeared when a setting changed first (fec57d2c7); before the handover the page said "picking a time" and drew planned dots (fec57d2c7); rows before the first retry showed the end time (0841888c7); the footer buttons had different widths, and the page scrolled when a story was opened by link (38c9fd363).

**For C:** nothing failing in Home, Setup, Learn or Portfolio in this pass. The Portfolio 1-minute run was not started here (C's run was on :8787).
