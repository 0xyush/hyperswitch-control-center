open SimulatorTypes
open LogicUtils

let getSimulatorConfig = (dict): SimulatorConfigTypes.simulatorConfig => {
  simUrl: dict->getString("sim_url", ""),
  orgId: dict->getString("org_id", ""),
  merchantId: dict->getString("merchant_id", ""),
  profileId: dict->getString("profile_id", ""),
}

let getConfig = () => Window.env.simulatorConfig->Option.getOr(Dict.make()->getSimulatorConfig)

// Simulator calls go to the proxy itself, not through api_url
let getSimUrl = path => `${getConfig().simUrl}${path}`

// Why a smart-mode profile books no retries on the sandbox today (PRD ask 2)
let smartDeciderNote = "Smart mode needs a decider service. The sandbox lacks it for this merchant (ask 2)."

// The story polls every 2 s while it runs, so a retry on the fast engine shows within about 2 s
let pollIntervalMs = 2000

// Amount on the wire is in minor units (6540 = 65.40); the form shows major units
let toMajorText = minor => (minor->Int.toFloat /. 100.0)->Float.toFixedWithPrecision(~digits=2)
// Two decimals, as the billing system would show it
let toAmountText = majorText =>
  majorText->getFloatFromString(0.0)->Float.toFixedWithPrecision(~digits=2)
let toMinor = majorText => (majorText->getFloatFromString(0.0) *. 100.0)->Math.round->Float.toInt

let presetMapper = (dict): preset => {
  let fields = dict->getDictfromDict("fields")
  let id = dict->getInt("id", 0)
  {
    id,
    title: dict->getString("title", ""),
    summary: dict->getString("summary", ""),
    v1Status: dict->getString("v1Status", ""),
    verified: dict->getBool("verified", dict->getBool("runnable", false)),
    hint: dict->getString("hint", ""),
    fields: {
      preset: id,
      amount: fields->getInt("amount", 6540)->toMajorText,
      currency: fields->getString("currency", "USD"),
      savedCard: fields->getString("savedCard", fields->getString("card", "0341")),
      firstCharge: fields->getString("firstCharge", fields->getString("card", "0341")),
      customer: fields->getString("customer", "new"),
    },
  }
}

// Used when the proxy sends no card list
let defaultCardOptions: array<SelectBox.dropdownOption> = [
  {label: "Good card 4242", value: "4242"},
  {label: "Declining card 0341", value: "0341"},
  {label: "Generic decline 0002 (first charge)", value: "0002"},
  {label: "Insufficient funds 9995 (first charge)", value: "9995"},
  {label: "Stolen card 9979 (first charge)", value: "9979"},
]

let getFormOptions = (json): formOptions => {
  let dict = json->getDictFromJsonObject
  // Older proxies answer /sim/scenarios with "scenarios" and no fields
  let presetList = switch dict->getArrayFromDict("presets", []) {
  | [] => dict->getArrayFromDict("scenarios", [])
  | list => list
  }
  let cards =
    dict
    ->getArrayFromDict("cards", [])
    ->Array.map(item => {
      let card = item->getDictFromJsonObject
      let option: SelectBox.dropdownOption = {
        label: card->getString("label", ""),
        value: card->getString("id", ""),
      }
      option
    })
  let currencies = switch dict->getStrArrayFromDict("currencies", []) {
  | [] => ["USD"]
  | list => list
  }
  {
    presets: presetList->Array.map(item => item->getDictFromJsonObject->presetMapper),
    cards: cards->Array.length > 0 ? cards : defaultCardOptions,
    currencies: currencies->SelectBox.makeOptions,
  }
}

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

// Name and "is it real" note for each lifeline
let actorLabel = actor =>
  switch actor {
  | Billing => ("Billing system", "Simulated")
  | RevRec => ("Rev Rec", "Sandbox")
  | Processor => ("Processor", "Stripe test mode")
  | Customer => ("Customer", "Simulated")
  }

let lifelines = [Billing, RevRec, Processor, Customer]

// Horizontal position of a lifeline, in percent of the diagram width
let lifelinePercent = actor =>
  switch actor {
  | Billing => 12.5
  | RevRec => 37.5
  | Processor => 62.5
  | Customer => 87.5
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

let explainLineMapper = (json): explainLine => {
  let dict = json->getDictFromJsonObject
  {text: dict->getString("text", ""), source: dict->getString("source", "")->sourceMapper}
}

let stepStatusMapper = str =>
  switch str->String.toLowerCase {
  | "ok" | "approved" | "success" | "succeeded" => StepOk
  | "declined" | "failure" | "refused" => StepDeclined
  | "error" | "failed" => StepFailed
  | "pending" => StepPending
  | _ => StepInfo
  }

// Older proxy rows have no status, so read it from the words
let inferStepStatus = label => {
  let text = label->String.toLowerCase
  if ["declin", "fail", "refused", "rejected"]->Array.some(word => text->String.includes(word)) {
    StepDeclined
  } else if (
    ["approved", "paid", "recovered", "succeeded"]->Array.some(word => text->String.includes(word))
  ) {
    StepOk
  } else {
    StepInfo
  }
}

// A row's phase, from who sends it to whom (the proxy may send "phase" itself)
let derivePhase = (~from, ~to, ~status) =>
  switch (from, to, status) {
  | (_, _, StepPending) => 3
  | (Billing, RevRec, _) => 2
  | (RevRec, RevRec, _) => 3
  | (RevRec, Processor, _) => 4
  | (Billing, _, _) => 1
  | _ => 5
  }

let diagramRowMapper = (index, json): diagramRow => {
  let dict = json->getDictFromJsonObject
  let label = switch dict->getString("label", "") {
  | "" => dict->getString("text", "")
  | label => label
  }
  let statusText = dict->getString("status", "")
  let from = dict->getString("from", "")->actorMapper
  let to = dict->getString("to", "")->actorMapper
  let status = statusText->isNonEmptyString ? statusText->stepStatusMapper : label->inferStepStatus
  {
    stepId: dict->getString("stepId", `row-${index->Int.toString}`),
    at: dict->getString("at", ""),
    from,
    to,
    label,
    text: dict->getString("text", ""),
    status,
    why: dict->getArrayFromDict("why", [])->Array.map(explainLineMapper),
    attemptId: dict->getOptionString("attemptId"),
    phase: dict->getOptionInt("phase")->Option.getOr(derivePhase(~from, ~to, ~status)),
  }
}

let requestLogMapper = (dict): requestLog => {
  let request = dict->getDictfromDict("request")
  let response = dict->getDictfromDict("response")
  {
    stepId: dict->getString("stepId", ""),
    step: dict->getString("step", ""),
    at: dict->getString("at", ""),
    method: request->getString("method", ""),
    url: request->getString("url", ""),
    status: response->getInt("status", 0),
    request: request->JSON.Encode.object,
    response: response->JSON.Encode.object,
  }
}

// The proxy keeps the saved card and the first-charge card apart; the form has one card field.
// This reverses the proxy's mapping: 4242 is saved as is, the one-off cards decline the first charge.
let formFromStory = (dict, ~preset): option<billingForm> =>
  if dict->isEmptyDict {
    None
  } else {
    let savedCard = dict->getString("savedCard", "0341")
    let firstCharge = dict->getString("firstCharge", savedCard)
    Some({
      preset,
      amount: dict->getInt("amount", 6540)->toMajorText,
      currency: dict->getString("currency", "USD"),
      savedCard,
      firstCharge,
      customer: dict->getString("customer", "new"),
    })
  }

let storyMapper = (json): story => {
  let dict = json->getDictFromJsonObject
  let scenarioInfo = dict->getDictfromDict("scenarioInfo")
  let presetInfo = dict->getDictfromDict("presetInfo")
  let actions = dict->getDictfromDict("actions")
  let stageText = dict->getString("stage", "")
  {
    storyId: dict->getString("storyId", ""),
    scenarioId: dict->getInt("preset", dict->getInt("scenario", 0)),
    scenarioTitle: presetInfo->getString("title", scenarioInfo->getString("title", "")),
    invoiceId: dict->getString("invoiceId", ""),
    recoveryId: dict->getString("recoveryId", ""),
    startedAt: dict->getString("startedAt", ""),
    stage: (stageText->isNonEmptyString ? stageText : dict->getString("status", ""))->stageMapper,
    recoveredBy: dict->getString("recoveredBy", ""),
    done: dict->getBool("done", false),
    stageHistory: dict
    ->getArrayFromDict("stageHistory", [])
    ->Array.map(item => {
      let visit = item->getDictFromJsonObject
      {
        stage: visit->getString("stage", "")->stageMapper,
        firstSeenAt: visit->getString("firstSeenAt", visit->getString("at", "")),
        fromSandbox: visit->getString("source", "") == "sandbox",
      }
    }),
    nextRetryAt: dict->getOptionString("nextRetryAt"),
    // null until the wait lasts 3 min
    waiting: dict
    ->Dict.get("waiting")
    ->Option.flatMap(JSON.Decode.object)
    ->Option.map(waiting => {
      minutes: waiting->getInt("minutes", 0),
      text: waiting->getString("text", dict->getString("stageCaption", "")),
      why: waiting->getString("why", ""),
      source: waiting->getString("source", "")->sourceMapper,
    }),
    invoice: dict->getDictfromDict("invoice"),
    attempts: dict->getArrayFromDict("attempts", [])->JSON.Encode.array,
    attemptBy: dict
    ->getArrayFromDict("attemptSummary", [])
    ->Array.map(item => item->getDictFromJsonObject->getString("by", "")),
    attemptTxn: dict
    ->getArrayFromDict("attemptSummary", [])
    ->Array.map(item => {
      let attempt = item->getDictFromJsonObject
      (attempt->getString("id", ""), attempt->getString("connectorTxnId", ""))
    })
    ->Array.filter(((_, txnId)) => txnId->isNonEmptyString)
    ->Dict.fromArray,
    processTracker: dict->getDictfromDict("processTracker"),
    explain: dict->getArrayFromDict("explain", [])->Array.map(explainLineMapper),
    timeline: dict
    ->getArrayFromDict("timeline", [])
    ->Array.mapWithIndex((item, index) => diagramRowMapper(index, item)),
    requests: dict
    ->getArrayFromDict("requests", [])
    ->Array.map(item => item->getDictFromJsonObject->requestLogMapper),
    actions: {
      paidInApp: actions->getBool("paidInApp", false),
      reportAgain: actions->getBool("reportAgain", false),
      cancel: actions->getBool("cancel", false),
    },
    warnings: dict->getStrArrayFromDict("warnings", []),
    startError: dict->getString("startError", ""),
    firstChargeCard: dict->getDictfromDict("form")->getString("firstCharge", ""),
    form: dict
    ->getDictfromDict("form")
    // Portfolio copies have no preset: 0 shows as "None" in the form
    ->formFromStory(
      ~preset=dict
      ->getOptionInt("preset")
      ->Option.orElse(dict->getOptionInt("scenario"))
      ->Option.getOr(0),
    ),
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

// The process tracker sends UTC times, sometimes without a zone ("2026-10-23 14:02:11.123")
let toUtcIso = time => {
  let iso = time->String.replace(" ", "T")
  let hasZone = iso->String.endsWith("Z") || %re("/[+-]\d\d:?\d\d$/")->RegExp.test(iso)
  hasZone ? iso : `${iso}Z`
}

let toMillis = time => time->toUtcIso->Date.fromString->Date.getTime

// Clock time in the visitor's time zone, for the diagram's time column
let toClockTime = time => time->toUtcIso->Date.fromString->Date.toLocaleTimeString

// "in 2 min 05 s" until the booked retry, "due now" after it
let countdownText = (~nextRetryAt, ~nowMs) => {
  let seconds = ((nextRetryAt->toMillis -. nowMs) /. 1000.0)->Float.toInt
  if seconds <= 0 {
    "due now"
  } else {
    let minutes = seconds / 60
    let rest = mod(seconds, 60)
    let restText = rest < 10 ? `0${rest->Int.toString}` : rest->Int.toString
    minutes > 0 ? `in ${minutes->Int.toString} min ${restText} s` : `in ${rest->Int.toString} s`
  }
}

// The state the invoice was in at a moment: the last state first seen at or before it
let stageAt = (history: array<stageVisit>, time) => {
  let millis = time->toMillis
  history->Array.reduce(None, (found, visit) =>
    visit.firstSeenAt->toMillis <= millis ? Some(visit) : found
  )
}

let stageVisitSource = (visit: stageVisit) =>
  visit.fromSandbox
    ? sourceLabel(Sandbox)
    : ("Seen by the proxy", "bg-nd_gray-50 text-nd_gray-600 border-nd_gray-200")

// "Working…" line under the header: what happens next, from the latest step's sender and receiver
let workingText = (latest: option<diagramRow>) =>
  switch latest {
  | None => "Working… the billing system is creating the invoice"
  | Some({status: StepPending}) => "Waiting for the retry Rev Rec booked"
  | Some({
      from: Billing,
      to: Processor,
      status: StepDeclined | StepFailed,
    }) => "Working… the billing system is reporting to Rev Rec"
  | Some({from: Billing, to: RevRec}) => "Working… Rev Rec is picking a retry time"
  | Some({from: Billing}) => "Working… the billing system is charging the card"
  | Some({from: RevRec, to: RevRec}) => "Working… Rev Rec is booking the retry"
  | Some({from: RevRec, to: Processor}) => "Working… waiting for the invoice to update"
  | Some(_) => "Working… the billing system is recording the result"
  }

// "2 min so far" since a step, for the "Working…" line during long sandbox waits
let elapsedText = (~since, ~nowMs) => {
  let seconds = ((nowMs -. since->toMillis) /. 1000.0)->Float.toInt
  seconds < 60 ? `${seconds->Int.toString} s so far` : `${(seconds / 60)->Int.toString} min so far`
}

// Raw calls behind a diagram row. Older proxies send no step ids, so match by time (within 3 s).
let requestsForRow = (requests: array<requestLog>, row: diagramRow) =>
  if requests->Array.some(request => request.stepId->isNonEmptyString) {
    requests->Array.filter(request => request.stepId == row.stepId)
  } else {
    let rowMillis = row.at->toMillis
    requests->Array.filter(request => Math.abs(request.at->toMillis -. rowMillis) <= 3000.0)
  }

// Preset 0 = no preset (a portfolio copy)
let noPresetOption: SelectBox.dropdownOption = {label: "None (a portfolio copy)", value: "0"}

let presetOptions = (presets: array<preset>): array<SelectBox.dropdownOption> =>
  presets->Array.map(preset => {
    let suffix = preset.verified ? "" : ` (${preset.v1Status})`
    let option: SelectBox.dropdownOption = {
      label: `${preset.title}${suffix}`,
      value: preset.id->Int.toString,
    }
    option
  })

let customerOptions = [("new", "New customer"), ("same", "Same customer")]

let defaultForm: billingForm = {
  preset: 1,
  amount: "65.40",
  currency: "USD",
  savedCard: "0341",
  firstCharge: "0341",
  customer: "new",
}

// POST /sim/story/start body: the preset fills defaults on the proxy, explicit fields win
let startBody = (form: billingForm) =>
  [
    // Preset 0 (none) is left out; the explicit fields then define the charge
    form.preset > 0 ? Some(("preset", form.preset->JSON.Encode.int)) : None,
    Some(("amount", form.amount->toMinor->JSON.Encode.int)),
    Some(("currency", form.currency->JSON.Encode.string)),
    Some(("savedCard", form.savedCard->JSON.Encode.string)),
    Some(("firstCharge", form.firstCharge->JSON.Encode.string)),
    Some(("customer", form.customer->JSON.Encode.string)),
  ]
  ->Array.filterMap(field => field)
  ->getJsonFromArrayOfJson
