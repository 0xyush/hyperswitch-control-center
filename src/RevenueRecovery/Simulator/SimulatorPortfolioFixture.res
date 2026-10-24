// FIXTURE, not a sandbox run: made-up numbers in the shape of GET /sim/portfolio/:runId.
// The screen no longer falls back to it; it is kept for tests and layout checks.
let fixtureText = `{
  "runId": "pf_fixture",
  "seed": 4242,
  "status": "done",
  "startedAt": "2026-10-23T20:00:00Z",
  "endReason": "every invoice reached an end state",
  "error": null,
  "profiles": {
    "static": {"profileId": "pro_fixture_static", "mode": "cascading"},
    "smart": {"profileId": "pro_fixture_smart", "mode": "smart"}
  },
  "cards": {
    "static": {"invoices": 10, "recovered": 6, "recoveryRate": 0.6, "recoveredAmount": 39240,
      "revrecAttempts": 21, "attemptsPerRecovery": 2.8,
      "minutesToRecovery": {"median": 9.5, "p90": 14.2}, "terminated": 1, "cancelled": 3, "open": 0},
    "smart": {"invoices": 10, "recovered": 8, "recoveryRate": 0.8, "recoveredAmount": 52320,
      "revrecAttempts": 15, "attemptsPerRecovery": 1.6,
      "minutesToRecovery": {"median": 7.1, "p90": 11.8}, "terminated": 1, "cancelled": 1, "open": 0}
  },
  "byReason": [
    {"reason": "insufficient_funds", "invoices": 4, "static": {"recovered": 2}, "smart": {"recovered": 3}},
    {"reason": "generic_decline", "invoices": 3, "static": {"recovered": 2}, "smart": {"recovered": 3}},
    {"reason": "processing_error", "invoices": 2, "static": {"recovered": 2}, "smart": {"recovered": 2}},
    {"reason": "stolen_card", "invoices": 1, "static": {"recovered": 0}, "smart": {"recovered": 0}}
  ],
  "bankRules": [
    {"reason": "insufficient_funds", "firstChargeCard": "9995", "rule": "No money until the payday, 4 to 12 minutes after the first failure."},
    {"reason": "generic_decline", "firstChargeCard": "0002", "rule": "Works again after a quiet window of 2 to 6 minutes."},
    {"reason": "processing_error", "firstChargeCard": "0119", "rule": "A temporary error: works again after 1 minute."},
    {"reason": "stolen_card", "firstChargeCard": "9979", "rule": "Never comes back: a hard decline."}
  ],
  "trend": [
    {"minute": 0, "static": 0, "smart": 0}, {"minute": 2, "static": 0, "smart": 1},
    {"minute": 4, "static": 1, "smart": 2}, {"minute": 6, "static": 2, "smart": 4},
    {"minute": 8, "static": 3, "smart": 5}, {"minute": 10, "static": 4, "smart": 6},
    {"minute": 12, "static": 5, "smart": 7}, {"minute": 14, "static": 5, "smart": 8},
    {"minute": 16, "static": 6, "smart": 8}, {"minute": 18, "static": 6, "smart": 8}
  ],
  "invoices": [
    {"i": 1, "reason": "insufficient_funds", "amount": 6540, "bank": {"flipAfterMin": 5},
      "static": {"storyId": "st_fixture01s", "status": "recovered", "revrecAttempts": 3},
      "smart": {"storyId": "st_fixture01r", "status": "recovered", "revrecAttempts": 2}},
    {"i": 2, "reason": "insufficient_funds", "amount": 6540, "bank": {"flipAfterMin": 9},
      "static": {"storyId": "st_fixture02s", "status": "cancelled", "revrecAttempts": 5},
      "smart": {"storyId": "st_fixture02r", "status": "recovered", "revrecAttempts": 2}},
    {"i": 3, "reason": "insufficient_funds", "amount": 6540, "bank": {"flipAfterMin": 11},
      "static": {"storyId": "st_fixture03s", "status": "cancelled", "revrecAttempts": 5},
      "smart": {"storyId": "st_fixture03r", "status": "cancelled", "revrecAttempts": 3}},
    {"i": 4, "reason": "insufficient_funds", "amount": 6540, "bank": {"flipAfterMin": 4},
      "static": {"storyId": "st_fixture04s", "status": "recovered", "revrecAttempts": 2},
      "smart": {"storyId": "st_fixture04r", "status": "recovered", "revrecAttempts": 1}},
    {"i": 5, "reason": "generic_decline", "amount": 6540, "bank": {"flipAfterMin": 3},
      "static": {"storyId": "st_fixture05s", "status": "recovered", "revrecAttempts": 2},
      "smart": {"storyId": "st_fixture05r", "status": "recovered", "revrecAttempts": 1}},
    {"i": 6, "reason": "generic_decline", "amount": 6540, "bank": {"flipAfterMin": 6},
      "static": {"storyId": "st_fixture06s", "status": "cancelled", "revrecAttempts": 4},
      "smart": {"storyId": "st_fixture06r", "status": "recovered", "revrecAttempts": 2}},
    {"i": 7, "reason": "generic_decline", "amount": 6540, "bank": {"flipAfterMin": 2},
      "static": {"storyId": "st_fixture07s", "status": "recovered", "revrecAttempts": 1},
      "smart": {"storyId": "st_fixture07r", "status": "recovered", "revrecAttempts": 1}},
    {"i": 8, "reason": "processing_error", "amount": 6540, "bank": {"flipAfterMin": 1},
      "static": {"storyId": "st_fixture08s", "status": "recovered", "revrecAttempts": 1},
      "smart": {"storyId": "st_fixture08r", "status": "recovered", "revrecAttempts": 1}},
    {"i": 9, "reason": "processing_error", "amount": 6540, "bank": {"flipAfterMin": 1},
      "static": {"storyId": "st_fixture09s", "status": "recovered", "revrecAttempts": 2},
      "smart": {"storyId": "st_fixture09r", "status": "recovered", "revrecAttempts": 1}},
    {"i": 10, "reason": "stolen_card", "amount": 6540, "bank": {"flipAfterMin": null},
      "static": {"storyId": "st_fixture10s", "status": "terminated", "revrecAttempts": 0},
      "smart": {"storyId": "st_fixture10r", "status": "terminated", "revrecAttempts": 0}}
  ],
  "warnings": []
}`

let fixtureRun = () =>
  fixtureText->JSON.parseExn->SimulatorPortfolioUtils.runMapper(~isFixture=true)
