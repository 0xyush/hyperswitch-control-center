// The billing system form (left panel). Amount is kept as typed text, in major units.
type billingForm = {
  preset: int,
  amount: string,
  currency: string,
  // The visitor's own card (start field card, last four): a Stripe test card that pays. It is saved
  // for the customer; the story makes the failure.
  card: string,
  // The card on file, which Rev Rec retries (4242 or 0341): the older start, other processors
  savedCard: string,
  // The card of the billing system's own first charge; the story picks it
  firstCharge: string,
  customer: string,
  // Rev Rec stops after this many retries (1 to 15, 15 by default; sent with the start when not 15)
  maxRetries: int,
  // "static" or "smart": the retry mode the story starts in (POST /sim/story/start mode)
  retryMode: string,
  // The payment processor the story charges through (the dashboard's connector name, "stripe")
  processor: string,
}

// One preset from GET /sim/presets: it fills the billing system form
// A real-world story's ending on the fixed timetable: the retry that recovers it, never (the money
// comes back after Rev Rec stops), or it depends on the date (payday)
type recoversOn = RecoversOnRetry(int) | NotRecovered | Varies

type preset = {
  id: int,
  title: string,
  summary: string,
  // "real-world" for the scripted-bank stories, else empty
  group: string,
  recoversOn: recoversOn,
  v1Status: string,
  // True when the preset was run end to end on the sandbox
  verified: bool,
  hint: string,
  // Runs on Stripe only (GET /sim/presets stripeOnly): every story but Temporary error
  stripeOnly: bool,
  fields: billingForm,
}

// GET /sim/presets: presets plus the card and currency choices for the form
// What a processor can run (GET /sim/presets limits.processors): every story (Stripe), or these
// presets; whether the scripted bank works there, and whether its declines carry no reason
type processorRule = {
  id: string,
  name: string,
  allPresets: bool,
  presets: array<int>,
  bankReady: bool,
  genericOnly: bool,
}

type formOptions = {
  presets: array<preset>,
  cards: array<SelectBox.dropdownOption>,
  currencies: array<SelectBox.dropdownOption>,
  processorRules: array<processorRule>,
}

// The invoice states, with the dashboard's names
type stage =
  | Starting
  | Monitoring
  | Queued
  | Scheduled
  | Processing
  | Recovered
  | PartiallyRecovered
  | Terminated
  | Cancelled
  | StoryError

// The four lifelines of the sequence diagram
type actor = Billing | RevRec | Processor | Customer

// Where an explanation line comes from
// Computed: the proxy worked it out from the story's own numbers (the fixed timetable's tries)
type source = Sandbox | Recomputed | Rule | Computed

type explainLine = {text: string, source: source}

// How a diagram arrow ended
type stepStatus = StepOk | StepDeclined | StepFailed | StepPending | StepInfo

// One message arrow in the sequence diagram
// When a retry would run in real life, on Hyperswitch's default timetable. The demo runs the same
// steps in seconds; `at` is shown in the viewer's time zone.
// source: "calendar" (Rev Rec's model picked it) or "ladder" (the model gave no time, so the fixed
// timetable did); "" on static stories
type realLifeSlot = {retry: int, offsetSec: int, at: string, dayText: string, source: string}

type realLifePlan = {
  maxRetries: int,
  // "about 6 days"
  spanText: string,
  // "This demo runs the same steps in about 80 s"
  demoText: string,
  slots: array<realLifeSlot>,
}

// A card the customer has on file, as the proxy sums it up for the story
type savedCardInfo = {
  last4: string,
  // "main" or "second"
  role: string,
  hardDecline: bool,
  approved: bool,
}

// Rev Rec's retry budget: a failure the billing system reports does not use a retry
type retryBudget = {
  max: int,
  retriesLeft: int,
  billingFailuresDuringRecovery: int,
  note: explainLine,
}

type diagramRow = {
  stepId: string,
  at: string,
  from: actor,
  to: actor,
  label: string,
  // One sentence for the side drawer
  text: string,
  status: stepStatus,
  why: array<explainLine>,
  attemptId: option<string>,
  // Phase 1..5 of the story: billing charge, report, pick a time, Rev Rec retries, outcome
  phase: int,
  // A retry's (or the end's) real-life time
  realLife: option<realLifeSlot>,
  // A decline's plain meaning
  meaning: option<explainLine>,
}

type requestLog = {
  stepId: string,
  step: string,
  at: string,
  method: string,
  url: string,
  status: int,
  request: JSON.t,
  response: JSON.t,
}

type storyActions = {paidInApp: bool, reportAgain: bool, cancel: bool}

// When the invoice was first seen in a state. Sandbox times are exact; the others are when the
// proxy noticed the change, up to one poll late.
type stageVisit = {stage: stage, firstSeenAt: string, fromSandbox: bool}

// What the side drawer shows: one diagram step, the invoice's states over time, or why Rev Rec
// has not booked a retry yet
type drawerContent =
  | StepDetails(diagramRow)
  | StateHistory
  | WaitingDetails
  // One Rev Rec retry: its booking, its charge (none while it waits) and its number
  | RetryDetails(option<diagramRow>, option<diagramRow>, int)

// Set by the proxy after 3 min in Monitoring with the start rule met and no retry booked
// (sandbox incident of 26 Oct, simulator/NOTES.md)
type waitingNote = {minutes: int, text: string, why: string, source: source}

// Preset 10: the go-live profile. Rev Rec only records failures (monitoring) until the merchant
// turns it on.
type goLive = {
  mode: string,
  // Empty until "Turn Rev Rec on"
  revRecOnAt: string,
  cleanedUp: bool,
}

// One old invoice of the go-live backlog
type backlogInvoice = {
  n: int,
  invoiceId: string,
  stage: stage,
  revrecRetries: int,
  // When Rev Rec recorded it in monitoring (empty before the handover)
  recordedInMonitoringAt: string,
  reportedAgainAt: string,
  // Rev Rec is on, but the billing system has not reported this invoice again yet
  waitingForReport: bool,
  // When Rev Rec recovered it (real-life ISO), "" if it has not (A, if the proxy sends it)
  recoveredAt: string,
}

// One live Rev Rec setting: may the visitor change it now, and if not, why
type settingRule = {allowed: bool, reason: string}

// Live Rev Rec settings for a story on its own leased profile: what may change now, and the values
// in force. A change applies from Rev Rec's next decision.
type liveSettings = {
  mode: settingRule,
  maxRetries: settingRule,
  graceDays: settingRule,
  paused: settingRule,
  // "static" or "smart"
  currentMode: string,
  currentMaxRetries: option<int>,
  currentGraceDays: option<int>,
  // The visitor paused Rev Rec for this invoice: the next retry waits until they resume
  currentPaused: bool,
}

// Something the visitor changed, at its real-life moment: a setting, money back, an outage until
// a time. The week calendar draws these as markers and bands.
type worldEvent = {eventType: string, at: string, until: string, text: string}

// The booked next retry (A's nextRetry): when it runs here, and its real-life moment. Pending for
// a few seconds while a smart pick moves to the demo clock.
type nextRetryInfo = {
  number: int,
  runsAt: string,
  realLife: string,
  day: int,
  pending: bool,
}

// A real-world story's scripted bank: the charges decline until worksFromAt (real-life time), then
// the saved card works
// One side of a real-world story's result: did it recover, after how many tries, how many days
// after the failure, and when (real-life ISO, "" if never). Rev Rec's side comes from the engine,
// the fixed timetable's is computed by the proxy.
type resultSide = {recovered: bool, tries: option<int>, days: option<float>, recoveredAt: string}

type bankPlan = {
  text: string,
  // The decline the bank gives until then ("insufficient_funds", "card_velocity_exceeded", …)
  reason: string,
  // "The fixed timetable would have needed 14 tries." (computed by the proxy), if there is a
  // money-back time
  fixedTimetableText: option<string>,
  // The number in it; None when the fixed timetable stops before the money is back
  fixedTimetableTries: option<int>,
  // The fixed timetable's side, and how the proxy worked it out, one line each ("Money back: Mon
  // 7:36 PM", "Try 14: Mon 10:37 PM, first after it")
  fixedSide: option<resultSide>,
  fixedMath: array<string>,
  // With Rev Rec's number of tries, did the fixed timetable recover? (A's sameTries, if sent)
  fixedSameTries: option<bool>,
  // Rev Rec's side, from the engine
  revRecSide: option<resultSide>,
  // Both sides' tries on one time axis, for the result card's chart (A's SimulatorResultChart);
  // None for an older story without the lanes
  resultChart: option<SimulatorResultChart.data>,
  worksFromAt: string,
  staticRetry: option<int>,
  source: source,
}

// Preset 8: the same customer's earlier invoice. Rev Rec charges one invoice per customer at a
// time, so this one waits (Queued) while the earlier one has its turn.
type queueInfo = {
  earlierStage: stage,
  earlierRetries: int,
  // This invoice is Queued behind the earlier one now
  waiting: bool,
  // The shortest gap between two charges for this customer: they never ran together
  minGapSec: option<float>,
  // "The two invoices took turns. …" and the rule behind it (explain ids queue, queue-rule)
  result: option<explainLine>,
  rule: option<explainLine>,
}

// GET /sim/story/:storyId (contract in simulator/NOTES.md). invoice, attempts and
// processTracker are the raw sandbox JSON, so the invoice page components read them as they are.
type story = {
  storyId: string,
  scenarioId: int,
  scenarioTitle: string,
  invoiceId: string,
  recoveryId: string,
  // The processor the story charges through (GET /sim/story/:id processor), "" when not given
  processorId: string,
  processorName: string,
  startedAt: string,
  stage: stage,
  // "revrec" when Rev Rec's own retry was paid, "billing" when paid outside Rev Rec
  recoveredBy: string,
  // The proxy says the story has made its point, so polling can stop
  done: bool,
  stageHistory: array<stageVisit>,
  nextRetryAt: option<string>,
  waiting: option<waitingNote>,
  invoice: Dict.t<JSON.t>,
  attempts: JSON.t,
  // Who made each sandbox attempt, from the proxy's attemptSummary: "billing" or "revrec"
  attemptBy: array<string>,
  // Stripe's charge id (pi_…) of each sandbox attempt, by attempt id
  attemptTxn: Dict.t<string>,
  processTracker: Dict.t<JSON.t>,
  explain: array<explainLine>,
  timeline: array<diagramRow>,
  requests: array<requestLog>,
  actions: storyActions,
  warnings: array<string>,
  startError: string,
  // The billing system form values this story was started with
  form: option<billingForm>,
  // Last four digits of the card the billing system's own charge used (it can differ from the saved card)
  firstChargeCard: string,
  // Rev Rec's retry plan on the real timetable
  realLife: option<realLifePlan>,
  savedCards: array<savedCardInfo>,
  retryBudget: option<retryBudget>,
  // Set once the invoice has ended ("Recovered", "Terminated", "Cancelled"): another reported
  // failure gets the engine's answer for a closed invoice
  reportAgainClosed: option<string>,
  // How smart retries would differ
  smartNote: option<explainLine>,
  // The billing system has charged but not informed Rev Rec yet; Rev Rec acts only after the handover
  awaitingHandover: bool,
  // The proxy accepts the handover now (POST /sim/story/:id/handover)
  canHandover: bool,
  // The proxy's own counts: the engine adds no attempt for a billing failure reported during
  // recovery, so billingFailures counts the billing system's failed charges itself
  billingFailures: option<int>,
  revrecRetries: option<int>,
  bank: option<bankPlan>,
  settings: option<liveSettings>,
  nextRetry: option<nextRetryInfo>,
  // "Your settings apply once Rev Rec has the invoice." when a setting changed before the handover
  handoverNote: option<explainLine>,
  // What the visitor can make happen now (money_back, new_card, stolen, outage), and why not
  eventRules: option<Dict.t<settingRule>>,
  worldEvents: array<worldEvent>,
  queue: option<queueInfo>,
  goLive: option<goLive>,
  backlog: array<backlogInvoice>,
  // The proxy accepts "Turn Rev Rec on" now (POST /sim/story/:id/go-live)
  canGoLive: bool,
}

// Feature tour (PRD section 9)
type featureTag = Live | LiveToConfirm | LiveSmartOnly | ReadOnly | DisplayOnly

// Rev Rec settings read from the sandbox through the proxy
type configKey = StartRule | MaxRetries | GracePeriod | RetryMode | PartialAuth

type revRecConfig = {
  startRule: option<int>,
  maxRetries: option<int>,
  gracePeriodDays: option<int>,
  retryMode: option<string>,
  partialAuth: option<bool>,
}

type configState = ConfigLoading | ConfigLoaded(revRecConfig) | ConfigFailed

// A line on a feature panel: a live setting, or a fixed fact with its source
type featureFact = Config(configKey) | Fact(string, string, source)

type feature = {
  title: string,
  tag: featureTag,
  description: string,
  facts: array<featureFact>,
  // Invoice story preset that shows the feature, if any
  preset: option<int>,
  // A caveat shown on the panel, for example a missing sandbox service
  note?: string,
}
