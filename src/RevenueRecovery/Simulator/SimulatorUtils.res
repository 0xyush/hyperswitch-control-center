open SimulatorTypes
open LogicUtils

let getSimulatorConfig = (dict): simulatorConfig => {
  simUrl: dict->getString("sim_url", ""),
  orgId: dict->getString("org_id", ""),
  merchantId: dict->getString("merchant_id", ""),
  profileId: dict->getString("profile_id", ""),
}

let getConfig = () => Window.env.simulatorConfig->Option.getOr(Dict.make()->getSimulatorConfig)

// Simulator calls go to the proxy itself, not through api_url
let getSimUrl = path => `${getConfig().simUrl}${path}`

// PRD section 7: poll the story every 4 s
let pollIntervalMs = 4000

let scenarioMapper = (dict): scenario => {
  id: dict->getInt("id", 0),
  title: dict->getString("title", ""),
  summary: dict->getString("summary", ""),
  reportedReason: dict->getString("reportedReason", ""),
  savedCard: dict->getString("savedCard", ""),
  expected: dict->getString("expected", ""),
  liveTime: dict->getString("liveTime", ""),
  v1Status: dict->getString("v1Status", ""),
  runnable: dict->getBool("runnable", false),
  hint: dict->getString("hint", ""),
}

let getScenarios = json =>
  json
  ->getDictFromJsonObject
  ->getArrayFromDict("scenarios", [])
  ->Array.map(item => item->getDictFromJsonObject->scenarioMapper)

// Reads the dashboard names ("Partially Recovered") and the sandbox ones ("partially_recovered")
let stageMapper = str =>
  switch str->String.toLowerCase->String.replaceRegExp(%re("/[\s_]/g"), "") {
  | "monitoring" | "nopicked" => Monitoring
  | "queued" => Queued
  | "scheduled" => Scheduled
  | "processing" | "partiallycapturedandprocessing" => Processing
  | "recovered" | "succeeded" => Recovered
  | "partiallyrecovered" => PartiallyRecovered
  | "terminated" | "failed" => Terminated
  | "cancelled" => Cancelled
  | "error" => StoryError
  | _ => Starting
  }

let isFinalStage = stage =>
  switch stage {
  | Recovered | Terminated | Cancelled | StoryError => true
  | _ => false
  }

let stageName = stage =>
  switch stage {
  | Starting => "Starting"
  | Monitoring => "Monitoring"
  | Queued => "Queued"
  | Scheduled => "Scheduled"
  | Processing => "Processing"
  | Recovered => "Recovered"
  | PartiallyRecovered => "Partially Recovered"
  | Terminated => "Terminated"
  | Cancelled => "Cancelled"
  | StoryError => "Error"
  }

// Plain captions from PRD section 4
let stageCaption = stage =>
  switch stage {
  | Starting => "Waiting for the sandbox"
  | Monitoring => "Waiting for the start rule"
  | Queued => "Picking a retry time"
  | Scheduled => "Retry booked for a time"
  | Processing => "Charging the card now"
  | Recovered => "Paid"
  | PartiallyRecovered => "Part paid"
  | Terminated => "Rev Rec stopped"
  | Cancelled => "Cancelled by the merchant"
  | StoryError => "The simulator could not start this story"
  }

// Position on the stepper: Monitoring, Queued, Scheduled, Processing, then the end state
let stagePosition = stage =>
  switch stage {
  | Starting => -1
  | Monitoring => 0
  | Queued => 1
  | Scheduled => 2
  | Processing => 3
  | Recovered | PartiallyRecovered | Terminated | Cancelled | StoryError => 4
  }

// Status text the invoice page components understand (RevenueRecoveryOrderUtils.statusVariantMapper)
let toInvoiceStatus = (stage, ~default) =>
  switch stage {
  | PartiallyRecovered => "partially_recovered"
  | Starting | StoryError => default
  | _ => stage->stageName
  }

let actorMapper = str =>
  switch str {
  | "revrec" => RevRec
  | "processor" => Processor
  | "customer" => Customer
  | _ => Billing
  }

// Name and "is it real" line for each box in the flow
let actorLabel = actor =>
  switch actor {
  | Billing => ("Billing system", "Simulated by the proxy")
  | RevRec => ("Rev Rec", "Real, on the sandbox")
  | Processor => ("Processor", "Stripe test mode")
  | Customer => ("Customer", "Simulated")
  }

let sourceMapper = str =>
  switch str {
  | "sandbox" => Sandbox
  | "recomputed" => Recomputed
  | _ => Rule
  }

let sourceLabel = source =>
  switch source {
  | Sandbox => ("From the sandbox", "bg-nd_green-50 text-nd_green-600 border-nd_green-200")
  | Recomputed => (
      "Re-computed",
      "bg-nd_primary_blue-50 text-nd_primary_blue-600 border-nd_primary_blue-200",
    )
  | Rule => ("Rule-based", "bg-nd_orange-50 text-nd_orange-600 border-nd_orange-200")
  }

let requestLogMapper = (dict): requestLog => {
  let request = dict->getDictfromDict("request")
  let response = dict->getDictfromDict("response")
  {
    step: dict->getString("step", ""),
    at: dict->getString("at", ""),
    method: request->getString("method", ""),
    url: request->getString("url", ""),
    status: response->getInt("status", 0),
    request: request->JSON.Encode.object,
    response: response->JSON.Encode.object,
  }
}

let storyMapper = (json): story => {
  let dict = json->getDictFromJsonObject
  let scenarioInfo = dict->getDictfromDict("scenarioInfo")
  let actions = dict->getDictfromDict("actions")
  let nowDict = dict->getDictfromDict("now")
  let stageText = dict->getString("stage", "")
  {
    storyId: dict->getString("storyId", ""),
    scenarioId: dict->getInt("scenario", 0),
    scenarioTitle: scenarioInfo->getString("title", ""),
    hint: scenarioInfo->getString("hint", ""),
    invoiceId: dict->getString("invoiceId", ""),
    recoveryId: dict->getString("recoveryId", ""),
    startedAt: dict->getString("startedAt", ""),
    stage: (stageText->isNonEmptyString ? stageText : dict->getString("status", ""))->stageMapper,
    stageCaption: dict->getString("stageCaption", ""),
    done: dict->getBool("done", false),
    nextRetryAt: dict->getOptionString("nextRetryAt"),
    invoice: dict->getDictfromDict("invoice"),
    attempts: dict->getArrayFromDict("attempts", [])->JSON.Encode.array,
    processTracker: dict->getDictfromDict("processTracker"),
    now: nowDict->isEmptyDict
      ? None
      : Some({
          actor: nowDict->getString("actor", "")->actorMapper,
          text: nowDict->getString("text", ""),
          why: nowDict->getString("why", ""),
        }),
    explain: dict
    ->getArrayFromDict("explain", [])
    ->Array.map(item => {
      let line = item->getDictFromJsonObject
      {text: line->getString("text", ""), source: line->getString("source", "")->sourceMapper}
    }),
    timeline: dict
    ->getArrayFromDict("timeline", [])
    ->Array.map(item => {
      let event = item->getDictFromJsonObject
      {
        at: event->getString("at", ""),
        from: event->getString("from", "")->actorMapper,
        to: event->getString("to", "")->actorMapper,
        text: event->getString("text", ""),
      }
    }),
    requests: dict
    ->getArrayFromDict("requests", [])
    ->Array.map(item => item->getDictFromJsonObject->requestLogMapper),
    actions: {
      paidInApp: actions->getBool("paidInApp", false),
      reportAgain: actions->getBool("reportAgain", false),
    },
    warnings: dict->getStrArrayFromDict("warnings", []),
    startError: dict->getString("startError", ""),
  }
}

// The proxy answers errors as {"error": {"code", "message"}}; the fetch hooks raise that JSON as text
let getSimErrorMessage = (exn, ~default) =>
  switch exn {
  | Exn.Error(e) =>
    switch Exn.message(e) {
    | Some(message) =>
      message
      ->safeParse
      ->getDictFromJsonObject
      ->getDictfromDict("error")
      ->getString("message", message)
    | None => default
    }
  | _ => default
  }

// Flow diagram: four boxes on a 2 x 2 grid (viewBox 0 0 400 250)
let boxSize = (150, 70)
let boxOrigin = actor =>
  switch actor {
  | Customer => (10, 10)
  | Billing => (240, 10)
  | Processor => (10, 170)
  | RevRec => (240, 170)
  }

// Arrow end points on the box edges, for the box pair the arrow joins
let arrowPoints = (~from, ~to) => {
  let edge = (a, b) =>
    switch (a, b) {
    | (Customer, Billing) => ((160, 45), (240, 45))
    | (Billing, RevRec) => ((315, 80), (315, 170))
    | (Processor, RevRec) => ((160, 205), (240, 205))
    | (Billing, Processor) => ((240, 80), (160, 170))
    | (Customer, RevRec) => ((160, 80), (240, 170))
    | (Customer, Processor) => ((85, 80), (85, 170))
    | _ => ((0, 0), (0, 0))
    }
  let rank = actor =>
    switch actor {
    | Customer => 0
    | Billing => 1
    | Processor => 2
    | RevRec => 3
    }
  if from == to {
    None
  } else if rank(from) < rank(to) {
    Some(edge(from, to))
  } else {
    let (start, finish) = edge(to, from)
    Some((finish, start))
  }
}

// For each stepper position: did the invoice really pass through it? While the story runs,
// the engine moves in order. At the end, Rev Rec may have skipped steps (for example, the
// invoice was paid outside before any retry ran), so the data decides.
let reachedSteps = (story: story) => {
  let position = story.stage->stagePosition
  if story.stage->isFinalStage {
    let hasTask = !(story.processTracker->isEmptyDict)
    let hasRevRecRetry =
      story.attempts
      ->RevenueRecoveryEntity.getAttempts
      ->Array.some(attempt =>
        attempt.attempt_triggered_by->RevenueRecoveryOrderUtils.attemptTriggeredByVariantMapper ==
          INTERNAL
      )
    [true, hasTask || hasRevRecRetry, hasTask || hasRevRecRetry, hasRevRecRetry, true]
  } else {
    [0, 1, 2, 3, 4]->Array.map(index => index <= position)
  }
}

// The process tracker sends UTC times, sometimes without a zone ("2026-10-23 14:02:11.123")
let toUtcIso = time => {
  let iso = time->String.replace(" ", "T")
  let hasZone = iso->String.endsWith("Z") || %re("/[+-]\d\d:?\d\d$/")->RegExp.test(iso)
  hasZone ? iso : `${iso}Z`
}

// "in 2 min 05 s" until the booked retry, "due now" after it
let countdownText = (~nextRetryAt, ~nowMs) => {
  let target = nextRetryAt->toUtcIso->Date.fromString
  let seconds = ((target->Date.getTime -. nowMs) /. 1000.0)->Float.toInt
  if seconds <= 0 {
    "due now"
  } else {
    let minutes = seconds / 60
    let rest = mod(seconds, 60)
    let restText = rest < 10 ? `0${rest->Int.toString}` : rest->Int.toString
    minutes > 0 ? `in ${minutes->Int.toString} min ${restText} s` : `in ${rest->Int.toString} s`
  }
}
