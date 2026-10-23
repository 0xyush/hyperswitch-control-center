- 2026-10-23 13:15 plan written; fork cloned from 0xyush/hyperswitch-control-center at 75ba7c1e7

## Contract (proxy <-> dashboard) — Builder A writes, Builder B reads; both may append questions
- Base URL: http://localhost:8787
- GET  /healthz -> {ok, sandbox, stripe, config}
- POST /sim/story/start {scenario: 1..8} -> {storyId, invoiceId, recoveryId, startedAt}
- GET  /sim/story/:storyId -> {status, invoice, attempts[], nextRetryAt, explain:[{text, source:"sandbox"|"recomputed"|"rule"}], requests:[{step, request, response}]}
- POST /sim/story/:storyId/paid-in-app, /report-again -> same shape as GET
- /api/* -> allow-listed pass-through to the sandbox with auth headers added
