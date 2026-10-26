# Replay mode (26 Oct) — demos that do not depend on the sandbox being alive

Goal: a presenter can open a recorded story and walk it step by step with the same screen, pacing and drawers as a
live story, even when the sandbox scheduler is stalled.

## Proxy (A)
- `GET /sim/recordings` → list of saved stories flagged as recordings: `{id, title, preset, recordedAt, outcome, steps}`.
- `POST /sim/recordings/:storyId` (operator) → marks an existing finished story as a recording with a title.
  Seed today with: st_7bf8bc687160 "Temporary error, retry works (24 Oct)", st_403581a10106 "Customer pays in the app",
  st_179854639f59 "Duplicate report refused", st_5e2776d00d4e "Insufficient funds, then recovers".
- `GET /sim/replay/:storyId?upTo=<n>` → the story view as it looked after the first n timeline rows (rows sliced by `at`,
  stageHistory/explain/requests sliced to match, `replay: {total, upTo, recordedAt}`). No sandbox calls.
- Recordings persist in data/recordings.json (git-ignored) and survive restarts.

## Dashboard (B)
- Story page: a "Replay a recorded story" link next to the preset dropdown opens a small list from `/sim/recordings`.
  Picking one loads `/v2/recovery/simulator/story/replay/{storyId}` with a grey "Replay · recorded <date>" ribbon
  under the phase strip and the form locked.
- Pacing: identical to live (Next reveals one step; Auto-play reveals one every 1.5 s). The countdown shows the
  recorded times, not a live clock.
- Drawers, Show all events, Invoice states and the sequence diagram toggle all work from the sliced view.
- Home card "Try It Out" keeps starting a live story; add a second small link under it: "Watch a recorded story".
- DEMO.md: add a line "If the sandbox is stalled, use Replay (Temporary error, retry works)".

## Acceptance
- With the proxy's sandbox calls blocked (set HS_BASE_URL to an unreachable host), replay of st_7bf8bc687160 walks
  all 5 phases to the green outcome card with no errors.
