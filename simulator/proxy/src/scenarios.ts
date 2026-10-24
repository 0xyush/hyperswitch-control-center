// Cards and presets for the invoice story (redesign brief, simulator/REDESIGN-story.md).
// A story uses two cards: the card the billing system's own charge fails on, and the saved card
// that Rev Rec retries. Since 23 Oct the sandbox checks each reported charge with Stripe and
// records Stripe's real decline, so the decline reason comes from the card that failed.

export type CardId = "4242" | "0341" | "0002" | "9995" | "9979";
export type SavedCardId = "4242" | "0341";
export type FirstChargeId = "0341" | "0002" | "9995" | "9979";

export type Card = {
  last4: CardId;
  pm: string; // Stripe test payment method token
  isin: string;
  network: "Visa";
  declineCode: string | null; // what Stripe answers on a charge; null = approves
  label: string; // for the form dropdown
  behaviour: string;
};

export const CARDS: Record<CardId, Card> = {
  "4242": {
    last4: "4242",
    pm: "pm_card_visa",
    isin: "424242",
    network: "Visa",
    declineCode: null,
    label: "Good card 4242",
    behaviour: "Stripe test card 4242 approves every charge.",
  },
  "0341": {
    last4: "0341",
    pm: "pm_card_chargeCustomerFail",
    isin: "400000",
    network: "Visa",
    declineCode: "generic_decline",
    label: "Declining card 0341",
    behaviour:
      "Stripe test card 0341 can be saved, then declines every charge (generic_decline).",
  },
  "0002": {
    last4: "0002",
    pm: "pm_card_chargeDeclined",
    isin: "400000",
    network: "Visa",
    declineCode: "generic_decline",
    label: "Generic decline 0002 (first charge)",
    behaviour: "Stripe test card 0002 declines with generic_decline.",
  },
  "9995": {
    last4: "9995",
    pm: "pm_card_chargeDeclinedInsufficientFunds",
    isin: "400000",
    network: "Visa",
    declineCode: "insufficient_funds",
    label: "Insufficient funds 9995 (first charge)",
    behaviour: "Stripe test card 9995 declines with insufficient_funds.",
  },
  "9979": {
    last4: "9979",
    pm: "pm_card_chargeDeclinedStolenCard",
    isin: "400000",
    network: "Visa",
    declineCode: "stolen_card",
    label: "Stolen card 9979 (first charge)",
    behaviour:
      "Stripe test card 9979 declines with stolen_card. Stripe will not save it.",
  },
};

export const SAVED_CARDS: SavedCardId[] = ["4242", "0341"];
export const FIRST_CHARGE_CARDS: FirstChargeId[] = [
  "0341",
  "0002",
  "9995",
  "9979",
];
export const CURRENCIES = ["USD", "EUR", "GBP"];

// Decline codes in plain words. soft = worth retrying; ndc = the Visa network decline code.
export const DECLINES: Record<
  string,
  { soft: boolean; ndc: string; plain: string }
> = {
  generic_decline: {
    soft: true,
    ndc: "05",
    plain: "the bank declined without a reason",
  },
  insufficient_funds: {
    soft: true,
    ndc: "51",
    plain: "no money on the card right now",
  },
  try_again_later: {
    soft: true,
    ndc: "19",
    plain: "a temporary problem at the bank",
  },
  stolen_card: { soft: false, ndc: "43", plain: "the card is reported stolen" },
};

// The brief's single "card" field, mapped to the two cards a story needs.
// 4242 or 0341 = the saved card; the first charge fails on 0341 itself, or on 0002 for 4242.
// 0002, 9995 or 9979 = the first-charge card (Stripe will not save these); the saved card is 0341.
export function resolveCards(o: {
  card?: CardId;
  savedCard?: SavedCardId;
  firstCharge?: FirstChargeId;
}): { savedCard: SavedCardId; firstCharge: FirstChargeId } {
  let saved = o.savedCard;
  let first = o.firstCharge;
  if (o.card && (SAVED_CARDS as string[]).includes(o.card))
    saved ??= o.card as SavedCardId;
  else if (o.card) first ??= o.card as FirstChargeId;
  saved ??= "0341";
  first ??= saved === "0341" ? "0341" : "0002";
  return { savedCard: saved, firstCharge: first };
}

// What "Report another failure" does by default.
// duplicate = same transaction again; new = a new failed charge; swap = new failure carrying the 4242 card.
export type ReportAgainMode = "duplicate" | "new" | "swap";

export type Preset = {
  id: number;
  title: string;
  summary: string;
  card: CardId; // the brief's single form field
  customer: "new" | "same";
  expected: string;
  liveTime: string;
  v1Status: string;
  // True when this preset was run end to end on the sandbox.
  verified: boolean;
  reportAgainMode: ReportAgainMode;
  // Preset 3: the billing system sends the same failure twice as part of the start.
  sendDuplicateOnStart?: boolean;
  hint: string;
};

export const PRESETS: Preset[] = [
  {
    id: 1,
    title: "Customer pays in the app",
    summary:
      "The card fails. Rev Rec starts retrying. Then the customer pays in the app with another card.",
    card: "0341",
    customer: "new",
    expected: 'Recovered, labelled "paid outside Rev Rec"',
    liveTime: "2 to 5 min",
    v1Status: "Ready",
    verified: true,
    reportAgainMode: "new",
    hint: "Wait for Rev Rec to book a retry, then press Customer pays in app.",
  },
  {
    id: 2,
    title: "Temporary error, retry works",
    summary:
      "The first charge fails. The saved card works now, so one Rev Rec retry collects the money.",
    card: "4242",
    customer: "new",
    expected: "One Rev Rec retry, Recovered",
    liveTime: "2 to 3 min",
    v1Status: "Ready",
    verified: true,
    reportAgainMode: "duplicate",
    hint: "Wait for the Rev Rec retry. No action needed.",
  },
  {
    id: 3,
    title: "Duplicate report",
    summary:
      "The billing system reports the same failure twice. Rev Rec keeps one attempt and refuses the copy.",
    card: "0341",
    customer: "new",
    expected: "Second report refused as a duplicate, one attempt kept",
    liveTime: "1 min",
    v1Status: "Ready",
    verified: true,
    reportAgainMode: "duplicate",
    sendDuplicateOnStart: true,
    hint: "Click the second report: Rev Rec refused it.",
  },
  {
    id: 4,
    title: "Card keeps declining",
    summary:
      "A card that never works. Rev Rec retries every few minutes on the sandbox.",
    card: "0341",
    customer: "new",
    expected: "A retry every ~2 min; the end state is not yet verified",
    liveTime: "30 to 45 min",
    v1Status: "Warm invoice",
    verified: false,
    reportAgainMode: "new",
    hint: "Long. Cancel the invoice when you have seen enough.",
  },
  {
    id: 5,
    title: "Card network limit",
    summary:
      "Visa allows about 20 retries per card. After that Rev Rec goes quiet and waits.",
    card: "0341",
    customer: "new",
    expected: 'Goes quiet after ~20 tries; "network limit reached, waiting"',
    liveTime: "~40 min",
    v1Status: "Warm invoice",
    verified: false,
    reportAgainMode: "new",
    hint: "Long. Cancel the invoice when you have seen enough.",
  },
  {
    id: 6,
    title: "Insufficient funds, then recovers",
    summary:
      "No money on the card. Later the billing system reports a new failure that carries a working card.",
    card: "9995",
    customer: "new",
    expected: "Recovered after the swap",
    liveTime: "depends on the swap",
    v1Status: "Spike before M1",
    verified: false,
    reportAgainMode: "swap",
    hint: "After a Rev Rec retry fails, press Report another failure to send the working card.",
  },
  {
    id: 7,
    title: "Hard decline (stolen card)",
    summary:
      "The charge is declined as a stolen card. Rev Rec should stop at once.",
    card: "9979",
    customer: "new",
    expected: "Terminated at once (on 23 Oct the sandbox kept retrying)",
    liveTime: "~1 min",
    v1Status: "Blocked on ask 7",
    verified: false,
    reportAgainMode: "duplicate",
    hint: "On 23 Oct the sandbox still retried. Cancel the invoice when done.",
  },
  {
    id: 8,
    title: "Second invoice, same customer",
    summary:
      "A second invoice for a customer already in recovery waits for the first one.",
    card: "0341",
    customer: "same",
    expected: "Second invoice waits for the first (smart retries only)",
    liveTime: "varies",
    v1Status: "Blocked on ask 2",
    verified: false,
    reportAgainMode: "new",
    hint: "Needs the smart-retries profile with the decider set up.",
  },
];

export const presetById = (id: number) => PRESETS.find((p) => p.id === id);

// Form data for the dashboard: presets with the field values they fill, and the card options.
export function publicPresets() {
  return {
    presets: PRESETS.map((p) => ({
      id: p.id,
      title: p.title,
      summary: p.summary,
      fields: {
        amount: 6540,
        currency: "USD",
        card: p.card,
        customer: p.customer,
        ...resolveCards({ card: p.card }),
      },
      expected: p.expected,
      liveTime: p.liveTime,
      v1Status: p.v1Status,
      verified: p.verified,
      reportAgainMode: p.reportAgainMode,
      hint: p.hint,
    })),
    cards: Object.values(CARDS).map((c) => ({
      id: c.last4,
      label: c.label,
      behaviour: c.behaviour,
      savable: (SAVED_CARDS as string[]).includes(c.last4),
      declineCode: c.declineCode,
    })),
    currencies: CURRENCIES,
  };
}
