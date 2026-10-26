// The billing system form (left panel). Amount is kept as typed text, in major units.
type billingForm = {
  preset: int,
  amount: string,
  currency: string,
  // The card on file, which Rev Rec retries (4242 or 0341)
  savedCard: string,
  // The card of the billing system's own first charge; the scenario picks it
  firstCharge: string,
  customer: string,
}

// One preset from GET /sim/presets: it fills the billing system form
type preset = {
  id: int,
  title: string,
  summary: string,
  v1Status: string,
  // True when the preset was run end to end on the sandbox
  verified: bool,
  hint: string,
  fields: billingForm,
}

// GET /sim/presets: presets plus the card and currency choices for the form
type formOptions = {
  presets: array<preset>,
  cards: array<SelectBox.dropdownOption>,
  currencies: array<SelectBox.dropdownOption>,
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
type source = Sandbox | Recomputed | Rule

type explainLine = {text: string, source: source}

// How a diagram arrow ended
type stepStatus = StepOk | StepDeclined | StepFailed | StepPending | StepInfo

// One message arrow in the sequence diagram
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
type drawerContent = StepDetails(diagramRow) | StateHistory | WaitingDetails

// Set by the proxy after 3 min in Monitoring with the start rule met and no retry booked
// (sandbox incident of 26 Oct, simulator/NOTES.md)
type waitingNote = {minutes: int, text: string, why: string, source: source}

// GET /sim/story/:storyId (contract in simulator/NOTES.md). invoice, attempts and
// processTracker are the raw sandbox JSON, so the invoice page components read them as they are.
type story = {
  storyId: string,
  scenarioId: int,
  scenarioTitle: string,
  invoiceId: string,
  recoveryId: string,
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
