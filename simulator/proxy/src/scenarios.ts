// The invoice-story scenarios from PRD section 7.
// The saved card decides what Stripe answers on a Rev Rec retry.
// The reported reason is data that the billing simulator sends; the screen says so.

export type Card = {
  pm: string;
  last4: string;
  isin: string;
  network: "Visa";
  behaviour: string;
};

// Stripe test payment methods. 0341 saves fine, then declines every charge. 4242 always succeeds.
export const CARD_DECLINES: Card = {
  pm: "pm_card_chargeCustomerFail",
  last4: "0341",
  isin: "400000",
  network: "Visa",
  behaviour: "Stripe test card 0341 declines every charge.",
};
// Declines as a stolen card. Stripe refuses to save it, so it is only charged one-off.
export const CARD_STOLEN: Card = {
  pm: "pm_card_chargeDeclinedStolenCard",
  last4: "9979",
  isin: "400000",
  network: "Visa",
  behaviour: "Stripe test card 9979 declines every charge as a stolen card.",
};
export const CARD_WORKS: Card = {
  pm: "pm_card_visa",
  last4: "4242",
  isin: "424242",
  network: "Visa",
  behaviour: "Stripe test card 4242 approves every charge.",
};

export type Reason = {
  key: string;
  soft: boolean;
  error: {
    code: string;
    message: string;
    reason: string;
    network_decline_code: string;
  };
};

const reason = (
  key: string,
  message: string,
  ndc: string,
  soft = true,
): Reason => ({
  key,
  soft,
  error: {
    code: "card_declined",
    message,
    reason: `decline_code - ${key}`,
    network_decline_code: ndc,
  },
});

export const REASONS = {
  generic_decline: reason("generic_decline", "Your card was declined.", "05"),
  try_again_later: reason("try_again_later", "Your card was declined.", "19"),
  insufficient_funds: reason(
    "insufficient_funds",
    "Your card has insufficient funds.",
    "51",
  ),
  stolen_card: reason("stolen_card", "Your card was declined.", "43", false),
};

// What "Report another failure" does by default for the scenario.
// duplicate = same transaction again; new = a new real failed charge; swap = new failure carrying the 4242 card.
export type ReportAgainMode = "duplicate" | "new" | "swap";

export type Scenario = {
  id: number;
  title: string;
  summary: string;
  reason: Reason;
  retryCard: Card;
  // The card the billing system's own charges fail on, when it is not the saved card.
  // Since 23 Oct the sandbox records Stripe's real decline, not the reported reason.
  failCard?: Card;
  expected: string;
  liveTime: string;
  v1Status: string;
  // False = shown in the picker, but start returns 409 until it is verified on the sandbox.
  runnable: boolean;
  reportAgainMode: ReportAgainMode;
  // Scenario 3: the billing system sends the same failure twice as part of the start.
  sendDuplicateOnStart?: boolean;
  // What the visitor should do next, shown on the "now" card.
  hint: string;
};

export const SCENARIOS: Scenario[] = [
  {
    id: 1,
    title: "Customer pays in the app",
    summary:
      "The card fails. Rev Rec starts retrying. Then the customer pays in the app with another card.",
    reason: REASONS.generic_decline,
    retryCard: CARD_DECLINES,
    expected: 'Recovered, labelled "paid outside Rev Rec"',
    liveTime: "2 to 5 min",
    v1Status: "Ready",
    runnable: true,
    reportAgainMode: "new",
    hint: "Watch Rev Rec queue a retry, then press Paid in app.",
  },
  {
    id: 2,
    title: "Temporary error, retry works",
    summary:
      "The first charge fails with try_again_later. The saved card works now, so one Rev Rec retry collects it.",
    reason: REASONS.try_again_later,
    retryCard: CARD_WORKS,
    expected: "One Rev Rec retry, Recovered",
    liveTime: "2 to 3 min",
    v1Status: "Ready",
    runnable: true,
    reportAgainMode: "duplicate",
    hint: "Wait for the Rev Rec retry. No action needed.",
  },
  {
    id: 3,
    title: "Duplicate report",
    summary:
      "The billing system reports the same failure twice. Rev Rec keeps one attempt and ignores the copy.",
    reason: REASONS.generic_decline,
    retryCard: CARD_DECLINES,
    expected: "Second report refused as a duplicate, one attempt kept",
    liveTime: "1 min",
    v1Status: "Ready",
    runnable: true,
    reportAgainMode: "duplicate",
    sendDuplicateOnStart: true,
    hint: "Check the attempts: the billing system sent two reports, Rev Rec kept one.",
  },
  {
    id: 4,
    title: "Card keeps declining",
    summary:
      "Generic decline on a card that never works. Rev Rec retries about every 2 minutes on the sandbox.",
    reason: REASONS.generic_decline,
    retryCard: CARD_DECLINES,
    expected: "A retry every ~2 min; the end state is not yet verified",
    liveTime: "30 to 45 min",
    v1Status: "Warm invoice",
    runnable: false,
    reportAgainMode: "new",
    hint: "Long scenario. Open a warm invoice instead of waiting.",
  },
  {
    id: 5,
    title: "Card network limit",
    summary:
      "Visa allows about 20 retries per card. After that Rev Rec goes quiet and waits.",
    reason: REASONS.generic_decline,
    retryCard: CARD_DECLINES,
    expected: 'Goes quiet after ~20 tries; "network limit reached, waiting"',
    liveTime: "~40 min",
    v1Status: "Warm invoice",
    runnable: false,
    reportAgainMode: "new",
    hint: "Long scenario. Open a warm invoice instead of waiting.",
  },
  {
    id: 6,
    title: "Insufficient funds, then recovers",
    summary:
      "No money on the card. Later the billing system reports a new failure that carries a working card.",
    reason: REASONS.insufficient_funds,
    retryCard: CARD_DECLINES,
    expected: "Recovered after the swap",
    liveTime: "depends on the swap",
    v1Status: "Spike before M1",
    runnable: false,
    reportAgainMode: "swap",
    hint: "Press Report another failure to send the working card.",
  },
  {
    id: 7,
    title: "Hard decline (stolen card)",
    summary:
      "The billing system's charge is declined as a stolen card. Rev Rec should stop at once.",
    reason: REASONS.stolen_card,
    retryCard: CARD_DECLINES,
    failCard: CARD_STOLEN,
    expected: "Terminated at once",
    liveTime: "~1 min",
    v1Status: "Blocked on ask 7",
    runnable: false,
    reportAgainMode: "duplicate",
    hint: "Needs a hard-decline row in the sandbox error catalogue.",
  },
  {
    id: 8,
    title: "Second invoice, same customer",
    summary:
      "A second invoice for a customer already in recovery waits for the first one.",
    reason: REASONS.generic_decline,
    retryCard: CARD_DECLINES,
    expected: "Second invoice waits for the first",
    liveTime: "varies",
    v1Status: "Blocked on ask 2",
    runnable: false,
    reportAgainMode: "new",
    hint: "Needs the smart-retries profile with the decider set up.",
  },
];

export const scenarioById = (id: number) => SCENARIOS.find((s) => s.id === id);

// The picker data for the dashboard (no internals such as Stripe test payment method ids).
export function publicScenarios() {
  return SCENARIOS.map((s) => ({
    id: s.id,
    title: s.title,
    summary: s.summary,
    reportedReason: s.reason.key,
    savedCard: s.retryCard.last4,
    expected: s.expected,
    liveTime: s.liveTime,
    v1Status: s.v1Status,
    runnable: s.runnable,
    reportAgainMode: s.reportAgainMode,
    hint: s.hint,
  }));
}
