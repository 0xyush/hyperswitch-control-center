// Settings from the [default.simulator] table in config/config.toml
type simulatorConfig = {
  simUrl: string,
  orgId: string,
  merchantId: string,
  profileId: string,
}

// One row of GET /sim/scenarios (PRD section 7)
type scenario = {
  id: int,
  title: string,
  summary: string,
  reportedReason: string,
  savedCard: string,
  expected: string,
  liveTime: string,
  v1Status: string,
  runnable: bool,
  hint: string,
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

// Who acts in the flow diagram
type actor = Billing | RevRec | Processor | Customer

// Where an explain line comes from
type source = Sandbox | Recomputed | Rule

type explainLine = {text: string, source: source}

type nowCard = {actor: actor, text: string, why: string}

type flowEvent = {at: string, from: actor, to: actor, text: string}

type requestLog = {
  step: string,
  at: string,
  method: string,
  url: string,
  status: int,
  request: JSON.t,
  response: JSON.t,
}

type storyActions = {paidInApp: bool, reportAgain: bool}

// GET /sim/story/:storyId (contract in simulator/NOTES.md). invoice, attempts and
// processTracker are the raw sandbox JSON, so the invoice page mappers read them as they are.
type story = {
  storyId: string,
  scenarioId: int,
  scenarioTitle: string,
  hint: string,
  invoiceId: string,
  recoveryId: string,
  startedAt: string,
  stage: stage,
  stageCaption: string,
  // The proxy says the story has made its point, so polling can stop
  done: bool,
  nextRetryAt: option<string>,
  invoice: Dict.t<JSON.t>,
  attempts: JSON.t,
  processTracker: Dict.t<JSON.t>,
  now: option<nowCard>,
  explain: array<explainLine>,
  timeline: array<flowEvent>,
  requests: array<requestLog>,
  actions: storyActions,
  warnings: array<string>,
  startError: string,
}
