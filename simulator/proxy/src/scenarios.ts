// Cards and presets for the invoice story (redesign brief, simulator/REDESIGN-story.md).
// A story uses two cards: the card the billing system's own charge fails on, and the saved card
// that Rev Rec retries. Since 23 Oct the sandbox checks each reported charge with Stripe and
// records Stripe's real decline, so the decline reason comes from the card that failed.
import { config, PROFILES } from "./config.ts";

export type CardId =
  | "4242"
  | "4444"
  | "5556"
  | "8210"
  | "0005"
  | "1117"
  | "0341"
  | "0002"
  | "9995"
  | "9979"
  | "0119"
  | "0069"
  | "6975";
// A card the visitor can give (it approves) and 0341 (saves, then declines every charge)
export type VisitorCardId = "4242" | "4444" | "5556" | "8210" | "0005" | "1117";
export type SavedCardId = VisitorCardId | "0341";
export type FirstChargeId =
  | "0341"
  | "0002"
  | "9995"
  | "9979"
  | "0119"
  | "0069"
  | "6975";

export type Card = {
  last4: CardId;
  pm: string; // Stripe test payment method token
  isin: string;
  network: "Visa" | "Mastercard" | "American Express" | "Discover";
  number?: string; // the full test number, for a card the visitor can type
  declineCode: string | null; // what Stripe answers on a charge; null = approves
  label: string; // for the form dropdown, in plain words (the card number is in behaviour)
  behaviour: string;
};

export const CARDS: Record<CardId, Card> = {
  "4242": {
    last4: "4242",
    pm: "pm_card_visa",
    isin: "424242",
    network: "Visa",
    number: "4242424242424242",
    declineCode: null,
    label: "It works",
    behaviour: "Stripe test card 4242 approves every charge.",
  },
  // More cards that approve: the visitor's one card (start field card, 28 Oct)
  "4444": {
    last4: "4444",
    pm: "pm_card_mastercard",
    isin: "555555",
    network: "Mastercard",
    number: "5555555555554444",
    declineCode: null,
    label: "It works",
    behaviour: "Stripe test card 4444 (Mastercard) approves every charge.",
  },
  "5556": {
    last4: "5556",
    pm: "pm_card_visa_debit",
    isin: "400005",
    network: "Visa",
    number: "4000056655665556",
    declineCode: null,
    label: "It works",
    behaviour: "Stripe test card 5556 (Visa debit) approves every charge.",
  },
  "8210": {
    last4: "8210",
    pm: "pm_card_mastercard_debit",
    isin: "520082",
    network: "Mastercard",
    number: "5200828282828210",
    declineCode: null,
    label: "It works",
    behaviour:
      "Stripe test card 8210 (Mastercard debit) approves every charge.",
  },
  "0005": {
    last4: "0005",
    pm: "pm_card_amex",
    isin: "378282",
    network: "American Express",
    number: "378282246310005",
    declineCode: null,
    label: "It works",
    behaviour:
      "Stripe test card 0005 (American Express) approves every charge.",
  },
  "1117": {
    last4: "1117",
    pm: "pm_card_discover",
    isin: "601111",
    network: "Discover",
    number: "6011111111111117",
    declineCode: null,
    label: "It works",
    behaviour: "Stripe test card 1117 (Discover) approves every charge.",
  },
  "0341": {
    last4: "0341",
    pm: "pm_card_chargeCustomerFail",
    isin: "400000",
    network: "Visa",
    declineCode: "generic_decline",
    label: "Declined, no reason given",
    behaviour:
      "Stripe test card 0341 can be saved, then declines every charge (generic_decline).",
  },
  "0002": {
    last4: "0002",
    pm: "pm_card_chargeDeclined",
    isin: "400000",
    network: "Visa",
    declineCode: "generic_decline",
    label: "Bank says no",
    behaviour: "Stripe test card 0002 declines with generic_decline.",
  },
  "9995": {
    last4: "9995",
    pm: "pm_card_chargeDeclinedInsufficientFunds",
    isin: "400000",
    network: "Visa",
    declineCode: "insufficient_funds",
    label: "Not enough money",
    behaviour: "Stripe test card 9995 declines with insufficient_funds.",
  },
  "9979": {
    last4: "9979",
    pm: "pm_card_chargeDeclinedStolenCard",
    isin: "400000",
    network: "Visa",
    declineCode: "stolen_card",
    label: "Card reported stolen",
    behaviour:
      "Stripe test card 9979 declines with stolen_card. Stripe will not save it.",
  },
  // Used by the portfolio run's bank rules; not in the story form.
  "0119": {
    last4: "0119",
    pm: "pm_card_chargeDeclinedProcessingError",
    isin: "400000",
    network: "Visa",
    declineCode: "processing_error",
    label: "Bank system error",
    behaviour: "Stripe test card 0119 declines with processing_error.",
  },
  "0069": {
    last4: "0069",
    pm: "pm_card_chargeDeclinedExpiredCard",
    isin: "400000",
    network: "Visa",
    declineCode: "expired_card",
    label: "Card expired",
    behaviour: "Stripe test card 0069 declines with expired_card.",
  },
  // The real-world stories' daily limit (preset 12).
  "6975": {
    last4: "6975",
    pm: "pm_card_chargeDeclinedVelocityLimitExceeded",
    isin: "400000",
    network: "Visa",
    declineCode: "card_velocity_exceeded",
    label: "Spending limit reached",
    behaviour: "Stripe test card 6975 declines with card_velocity_exceeded.",
  },
};

// The cards the story form offers (redesign brief).
export const FORM_CARDS: CardId[] = ["4242", "0341", "0002", "9995", "9979"];

export const SAVED_CARDS: SavedCardId[] = ["4242", "0341"];
// The cards the visitor can give as the one card (start field card): they approve; the story makes
// the failures.
export const VISITOR_CARDS: VisitorCardId[] = [
  "4242",
  "4444",
  "5556",
  "8210",
  "0005",
  "1117",
];
// A visitor card from its last 4 digits or its full number (spaces and dashes allowed), else null
export function visitorCardOf(v: unknown): VisitorCardId | null {
  const digits = String(v ?? "").replace(/[\s-]/g, "");
  if (!/^\d{4,19}$/.test(digits)) return null;
  return (
    VISITOR_CARDS.find((id) =>
      digits.length === 4 ? id === digits : CARDS[id].number === digits,
    ) ?? null
  );
}
export const FIRST_CHARGE_CARDS: FirstChargeId[] = [
  "0341",
  "0002",
  "9995",
  "9979",
  "0119",
  "0069",
  "6975",
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
  processing_error: {
    soft: true,
    ndc: "96",
    plain: "an error at the bank while processing",
  },
  card_velocity_exceeded: {
    soft: true,
    ndc: "61",
    plain: "the card hit its spending limit",
  },
  stolen_card: { soft: false, ndc: "43", plain: "the card is reported stolen" },
  expired_card: { soft: false, ndc: "54", plain: "the card has expired" },
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
  // Preset 9: the customer's second saved card (it paid last month's invoice).
  backupCard?: SavedCardId;
  // Preset 10: go-live with a backlog (one reused profile in monitoring, 3 invoices, one story at a time).
  goLive?: boolean;
  // Preset 8: the same customer's invoice 1 goes into recovery first, so this invoice queues.
  queue?: boolean;
  // The Learn level whose "Try it" button opens this preset (LEARN-COPY.md).
  learnLevel?: number;
  // With the visitor's one card (start field card, 28 Oct), the story makes its own failure:
  // firstCharge = the one-off test card the billing system's first charge fails on (Stripe will not
  // save most of them, so the report names the visitor's card); declines = the scripted bank declines
  // Rev Rec's charges on the visitor's card with this reason until an event changes it; firstSaved =
  // the customer's first saved card, picked by the story (preset 9: the visitor's card is the second).
  // Presets 11-20 fail on their own card with their bank rule.
  failure?: {
    firstCharge: FirstChargeId;
    declines?: string;
    firstSaved?: "0341";
  };
  // Presets 11-20: a real-world story. The scripted bank (selfhost/sim/bank.mjs) declines Rev Rec's
  // retries with the reason until worksFrom (real life, from the failure), then approves.
  bank?: BankStory;
  // The retry the fixed timetable recovers on (null = Rev Rec stops first, undefined = it varies).
  recoversOn?: number | null;
  // Preset 9 runs on the decider profile when one is set up (HS_DECIDER_PROFILE_ID), with these texts.
  deciderProfile?: boolean;
  decider?: Partial<Pick<Preset, "summary" | "expected" | "liveTime" | "hint">>;
  hint: string;
  // The texts at the pace of the self-hosted engine (SIM_FAST_ENGINE=1): a retry booked within
  // about 10 s and Rev Rec retries about 5 s apart (measured 27 Oct). Unset fields keep the above.
  fast?: Partial<Pick<Preset, "summary" | "expected" | "liveTime" | "hint">>;
  // Texts without the word "sandbox", for the self-hosted engine (HS_ENGINE=selfhost) at any pace.
  selfhost?: Partial<Pick<Preset, "summary" | "expected" | "hint">>;
};

export type BankReason =
  | "insufficient_funds"
  | "generic_decline"
  | "do_not_honor"
  | "processing_error"
  | "card_velocity_exceeded";
export type BankStory = {
  reason: BankReason;
  worksFrom: { afterHours: number } | { payday: true; hour: number };
  text: string; // when the money comes back, in plain words
};

// True when the decider profile is set up (else PROFILES.decider falls back to the story one).
export const deciderProfileReady = () =>
  PROFILES.decider.profileId !== PROFILES.story.profileId;

// The profile a preset's story runs on: the decider one for preset 9 when it is set up. The smart
// profile does not fit: with the model flag on, the engine retries only the invoice's own card.
// Preset 9 charges the customer's second saved card: off unless SIM_OTHER_CARDS=1 (config.otherCards)
export const presetOn = (p: Preset) => p.id !== 9 || config.otherCards;

export const presetProfile = (p: Preset | null | undefined) =>
  p?.deciderProfile && deciderProfileReady() ? ("decider" as const) : undefined;

// A preset's texts for the engine in use: the base texts, then the self-hosted ones, then the
// fast-pace ones, then the decider-profile ones when the preset runs there.
export const presetText = (p: Preset): Preset => ({
  ...p,
  ...(config.engine === "selfhost" ? p.selfhost : {}),
  ...(config.fastEngine ? p.fast : {}),
  ...(presetProfile(p) ? p.decider : {}),
});

export const PRESETS: Preset[] = [
  {
    id: 1,
    title: "Customer pays in the app",
    summary: "The card fails. Then the customer pays in the app.",
    card: "0341",
    failure: { firstCharge: "0002", declines: "generic_decline" },
    customer: "new",
    expected: 'Recovered, labelled "paid outside Rev Rec"',
    liveTime: "2 to 5 min",
    v1Status: "Ready",
    verified: true,
    reportAgainMode: "new",
    hint: "When Rev Rec books a retry, press Customer pays in the app.",
    fast: { liveTime: "about 30 s" },
  },
  {
    id: 2,
    title: "Temporary error, retry works",
    summary: "The bank says no once. The next try works.",
    card: "4242",
    failure: { firstCharge: "0002" },
    customer: "new",
    expected: "One Rev Rec retry, Recovered",
    liveTime: "2 to 3 min",
    v1Status: "Ready",
    verified: true,
    reportAgainMode: "duplicate",
    hint: "Wait for the Rev Rec retry. No action needed.",
    fast: { liveTime: "about 15 s" },
  },
  {
    id: 3,
    title: "Duplicate report",
    summary: "The same failure is reported twice. Rev Rec refuses the copy.",
    card: "0341",
    failure: { firstCharge: "0002", declines: "generic_decline" },
    customer: "new",
    expected: "Second report refused as a duplicate, one attempt kept",
    liveTime: "1 min",
    v1Status: "Ready",
    verified: true,
    reportAgainMode: "duplicate",
    sendDuplicateOnStart: true,
    hint: "Click the second report: Rev Rec refused it.",
    fast: { liveTime: "about 10 s" },
  },
  {
    id: 4,
    title: "Card keeps declining",
    summary: "The card never works. Rev Rec stops after 15 tries.",
    selfhost: {
      summary: "The card never works. Rev Rec stops after 15 tries.",
    },
    card: "0341",
    failure: { firstCharge: "0002", declines: "generic_decline" },
    customer: "new",
    expected: "A retry every ~2 min; the end state is not yet verified",
    liveTime: "30 to 45 min",
    v1Status: "Warm invoice",
    verified: false,
    reportAgainMode: "new",
    hint: "Long. Cancel the invoice when you have seen enough.",
    fast: {
      summary: "The card never works. Rev Rec stops after 15 tries.",
      expected: "15 Rev Rec retries, then Rev Rec stops (max tries 15)",
      liveTime: "about 80 s",
      hint: "About 80 s to reach max retries. No action needed.",
    },
  },
  {
    id: 5,
    title: "Card network limit",
    summary: "Visa allows about 20 tries per card. Then Rev Rec waits.",
    card: "0341",
    failure: { firstCharge: "0002", declines: "generic_decline" },
    customer: "new",
    expected: 'Goes quiet after ~20 tries; "network limit reached, waiting"',
    liveTime: "~40 min",
    v1Status: "Warm invoice",
    verified: false,
    reportAgainMode: "new",
    hint: "Long. Cancel the invoice when you have seen enough.",
    fast: {
      expected: "Rev Rec stops after 15 tries, before Visa's limit of about 20",
      liveTime: "about 80 s",
      hint: "About 80 s. No action needed.",
    },
  },
  {
    id: 6,
    title: "Insufficient funds, then recovers",
    summary: "No money now. It comes back later.",
    card: "9995",
    failure: { firstCharge: "9995", declines: "insufficient_funds" },
    customer: "new",
    expected:
      "Recovered by Rev Rec's next retry after the money is back, on the same card",
    liveTime: "depends on Money is back",
    v1Status: "Ready (spike passed 23 Oct)",
    verified: true,
    reportAgainMode: "new",
    hint: "After a retry fails, press Money is back.",
    fast: {
      expected:
        "Recovered by Rev Rec's next retry after the money is back (about 15 s)",
      liveTime: "about 15 s after Money is back",
    },
  },
  {
    id: 7,
    title: "Hard decline (stolen card)",
    summary: "The card is stolen. Rev Rec stops at once.",
    card: "9979",
    failure: { firstCharge: "9979" },
    customer: "new",
    expected: "Rev Rec stops at once (on 23 Oct the sandbox kept retrying)",
    liveTime: "~1 min",
    v1Status: "Blocked on ask 7",
    verified: false,
    reportAgainMode: "duplicate",
    hint: "On 23 Oct the sandbox still retried. Cancel the invoice when done.",
    selfhost: {
      expected: "Rev Rec stops at once. A stolen card is a hard decline",
      hint: "No action needed.",
    },
    fast: {
      expected: "Rev Rec stops at once. A stolen card is a hard decline",
      liveTime: "a few seconds",
      hint: "No action needed.",
    },
  },
  {
    id: 8,
    title: "Second invoice, same customer",
    summary:
      "The customer's invoice 1 is in recovery. Then invoice 2 fails too.",
    card: "0341",
    failure: { firstCharge: "0002", declines: "generic_decline" },
    customer: "new",
    queue: true,
    deciderProfile: true,
    expected: "Rev Rec charges one invoice at a time. The two take turns.",
    liveTime: "varies",
    v1Status: "Workshop flow",
    verified: false,
    reportAgainMode: "new",
    hint: "Needs the decider profile (smart, no model).",
    learnLevel: 6,
    decider: {
      expected: "Rev Rec charges one invoice at a time. The two take turns.",
      liveTime: "about 5 min",
      hint: "Watch the two invoices take turns. Each shows Queued while the other retries.",
    },
  },
  {
    id: 9,
    title: "Hard decline, then the second saved card",
    summary: "The main card is stolen. The customer has a second card.",
    card: "9979",
    failure: { firstCharge: "9979", firstSaved: "0341" },
    customer: "new",
    backupCard: "4242",
    deciderProfile: true,
    expected: "Static retries: Rev Rec stops. It retries only the stolen card",
    liveTime: "a few seconds",
    v1Status: "Workshop flow",
    verified: false,
    reportAgainMode: "new",
    hint: "No action needed after the handover.",
    decider: {
      expected: "Rev Rec skips the stolen card and recovers on saved card 4242",
      liveTime: "about 1 min",
    },
  },
  {
    id: 10,
    title: "Go-live with a backlog",
    summary: "Turn Rev Rec on with 3 old failed invoices.",
    card: "4242",
    failure: { firstCharge: "0002" },
    customer: "new",
    goLive: true,
    expected:
      "Old invoices restart when the billing system reports them again.",
    liveTime: "about 30 s after Turn Rev Rec on",
    v1Status: "Workshop flow",
    verified: false,
    reportAgainMode: "new",
    hint: "Hand the backlog over. Nothing retries. Then tap Turn Rev Rec on.",
  },
  {
    id: 11,
    title: "Bank hiccup",
    summary: "The bank's system was down for a bit.",
    card: "0119",
    customer: "new",
    bank: {
      reason: "processing_error",
      worksFrom: { afterHours: 2 },
      text: "The bank works again 2 hours after the failure.",
    },
    recoversOn: 2,
    expected: "The bank works again 2 hours after the failure.",
    liveTime: "about 15 s",
    v1Status: "Real-world story",
    verified: false,
    reportAgainMode: "new",
    hint: "No action needed after the handover.",
  },
  {
    id: 12,
    title: "Daily limit",
    summary: "The card hit its daily spending limit.",
    card: "6975",
    customer: "new",
    bank: {
      reason: "card_velocity_exceeded",
      worksFrom: { afterHours: 16 },
      text: "The limit resets 16 hours after the failure.",
    },
    recoversOn: 5,
    expected: "The limit resets 16 hours after the failure.",
    liveTime: "about 30 s",
    v1Status: "Real-world story",
    verified: false,
    reportAgainMode: "new",
    hint: "No action needed after the handover.",
  },
  {
    id: 13,
    title: "Fraud check",
    summary: "The bank paused the card until the customer confirmed.",
    card: "0002",
    customer: "new",
    bank: {
      reason: "do_not_honor",
      worksFrom: { afterHours: 23 },
      text: "The customer confirms 23 hours after the failure.",
    },
    recoversOn: 6,
    expected: "The customer confirms 23 hours after the failure.",
    liveTime: "about 40 s",
    v1Status: "Real-world story",
    verified: false,
    reportAgainMode: "new",
    hint: "No action needed after the handover.",
  },
  {
    id: 14,
    title: "Weekend low balance",
    summary: "No money on the card until the weekend is over.",
    card: "9995",
    customer: "new",
    bank: {
      reason: "insufficient_funds",
      worksFrom: { afterHours: 30 },
      text: "The money comes back 30 hours after the failure.",
    },
    recoversOn: 7,
    expected: "The money comes back 30 hours after the failure.",
    liveTime: "about 45 s",
    v1Status: "Real-world story",
    verified: false,
    reportAgainMode: "new",
    hint: "No action needed after the handover.",
  },
  {
    id: 15,
    title: "Payday",
    summary: "No money until the 1st or the 15th.",
    card: "9995",
    customer: "new",
    bank: {
      reason: "insufficient_funds",
      worksFrom: { payday: true, hour: 9 },
      text: "The money comes back on the next payday at 9 AM.",
    },
    expected: "The money comes back on the next payday at 9 AM.",
    liveTime: "up to 90 s",
    v1Status: "Real-world story",
    verified: false,
    reportAgainMode: "new",
    hint: "No action needed after the handover.",
  },
  {
    id: 16,
    title: "Travel block",
    summary: "The card is blocked abroad until the customer is home.",
    card: "0002",
    customer: "new",
    bank: {
      reason: "do_not_honor",
      worksFrom: { afterHours: 48 },
      text: "The card works again 2 days after the failure.",
    },
    recoversOn: 9,
    expected: "The card works again 2 days after the failure.",
    liveTime: "about 55 s",
    v1Status: "Real-world story",
    verified: false,
    reportAgainMode: "new",
    hint: "No action needed after the handover.",
  },
  {
    id: 17,
    title: "Over credit limit",
    summary: "Over the limit until the statement is paid.",
    card: "9995",
    customer: "new",
    bank: {
      reason: "insufficient_funds",
      worksFrom: { afterHours: 70 },
      text: "The money comes back 70 hours after the failure.",
    },
    recoversOn: 11,
    expected: "The money comes back 70 hours after the failure.",
    liveTime: "about 65 s",
    v1Status: "Real-world story",
    verified: false,
    reportAgainMode: "new",
    hint: "No action needed after the handover.",
  },
  {
    id: 18,
    title: "Second-last chance",
    summary: "The money arrives just before the end.",
    card: "9995",
    customer: "new",
    bank: {
      reason: "insufficient_funds",
      worksFrom: { afterHours: 120 },
      text: "The money comes back 5 days after the failure.",
    },
    recoversOn: 14,
    expected: "The money comes back 5 days after the failure.",
    liveTime: "about 85 s",
    v1Status: "Real-world story",
    verified: false,
    reportAgainMode: "new",
    hint: "No action needed after the handover.",
  },
  {
    id: 19,
    title: "Last chance",
    summary: "The money arrives right at the end.",
    card: "9995",
    customer: "new",
    bank: {
      reason: "insufficient_funds",
      worksFrom: { afterHours: 130 },
      text: "The money comes back 130 hours after the failure.",
    },
    recoversOn: 15,
    expected: "The money comes back 130 hours after the failure.",
    liveTime: "about 90 s",
    v1Status: "Real-world story",
    verified: false,
    reportAgainMode: "new",
    hint: "No action needed after the handover.",
  },
  {
    id: 20,
    title: "Too late",
    summary: "The money arrives after Rev Rec has stopped.",
    card: "9995",
    customer: "new",
    bank: {
      reason: "insufficient_funds",
      worksFrom: { afterHours: 150 },
      text: "The money comes back 150 hours after the failure.",
    },
    recoversOn: null,
    expected: "The money comes back 150 hours after the failure.",
    liveTime: "about 90 s",
    v1Status: "Real-world story",
    verified: false,
    reportAgainMode: "new",
    hint: "No action needed after the handover.",
  },
];

export const presetById = (id: number) => PRESETS.find((p) => p.id === id);

// Form data for the dashboard: presets with the field values they fill, and the card options.
export function publicPresets() {
  return {
    presets: PRESETS.filter(presetOn)
      .map(presetText)
      .map((p) => ({
        id: p.id,
        title: p.title,
        summary: p.summary,
        fields: {
          amount: 6540,
          currency: "USD",
          card: p.card,
          customer: p.customer,
          ...resolveCards({ card: p.card }),
          backupCard: p.backupCard ?? null,
        },
        expected: p.expected,
        liveTime: p.liveTime,
        v1Status: p.v1Status,
        verified: p.verified,
        reportAgainMode: p.reportAgainMode,
        hint: p.hint,
        ...(p.learnLevel ? { learnLevel: p.learnLevel } : {}),
        // With the visitor's one card (start field card): the failure the story makes itself
        storyFailure: {
          firstCharge: p.failure?.firstCharge ?? (p.bank ? p.card : "0002"),
          declines: p.failure?.declines ?? null,
          firstSaved: p.failure?.firstSaved ?? null,
        },
        // Only the Temporary error story runs at other processors (processors.ts); the rest use
        // Stripe test cards, the scripted bank or shared profiles.
        stripeOnly: p.id !== 2,
        // Presets 11-20: the "Real-world stories" group, what the bank does, and the retry the
        // fixed timetable recovers on (null = Rev Rec stops first; missing = it varies).
        ...(p.bank
          ? {
              group: "real-world",
              bank: { text: p.bank.text, source: "scripted" },
              ...(p.recoversOn !== undefined
                ? { recoversOn: p.recoversOn }
                : {}),
            }
          : {}),
      })),
    cards: FORM_CARDS.map((id) => CARDS[id]).map((c) => ({
      id: c.last4,
      label: c.label,
      behaviour: c.behaviour,
      savable: (SAVED_CARDS as string[]).includes(c.last4),
      declineCode: c.declineCode,
    })),
    // The start field card (28 Oct): the visitor's one card, by its last 4 or its full number. These
    // approve; the story makes the failures (storyFailure per preset).
    visitorCards: VISITOR_CARDS.map((id) => CARDS[id]).map((c) => ({
      id: c.last4,
      number: c.number,
      network: c.network,
      behaviour: c.behaviour,
    })),
    defaultVisitorCard: "4242",
    currencies: CURRENCIES,
  };
}
