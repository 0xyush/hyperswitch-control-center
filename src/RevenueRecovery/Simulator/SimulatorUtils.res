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
    group: dict->getString("group", ""),
    // A number is the recovering retry, null is never, and no field means it varies
    recoversOn: switch dict->Dict.get("recoversOn")->Option.map(JSON.Classify.classify) {
    | Some(Number(retry)) => RecoversOnRetry(retry->Float.toInt)
    | Some(Null) => NotRecovered
    | _ => Varies
    },
    v1Status: dict->getString("v1Status", ""),
    verified: dict->getBool("verified", dict->getBool("runnable", false)),
    stripeOnly: dict->getBool("stripeOnly", false),
    hint: dict->getString("hint", ""),
    fields: {
      preset: id,
      amount: fields->getInt("amount", 6540)->toMajorText,
      currency: fields->getString("currency", "USD"),
      card: "4242",
      savedCard: fields->getString("savedCard", fields->getString("card", "0341")),
      // With the visitor's one card, the first charge fails on the story's own card (storyFailure)
      firstCharge: dict
      ->getDictfromDict("storyFailure")
      ->getString(
        "firstCharge",
        fields->getString("firstCharge", fields->getString("card", "0341")),
      ),
      customer: fields->getString("customer", "new"),
      maxRetries: 15,
      retryMode: "smart",
      processor: "stripe",
    },
  }
}

// Used when the proxy sends no card list. The label says what happens in plain words; the
// Stripe test card behind it shows on hover.
let defaultCardOptions: array<SelectBox.dropdownOption> = [
  {label: "It works", value: "4242", description: "Stripe test card 4242"},
  {label: "Declined, no reason given", value: "0341", description: "Stripe test card 0341"},
  {label: "Bank says no", value: "0002", description: "Stripe test card 0002"},
  {label: "Not enough money", value: "9995", description: "Stripe test card 9995"},
  {label: "Card reported stolen", value: "9979", description: "Stripe test card 9979"},
  {label: "Bank system error", value: "0119", description: "Stripe test card 0119"},
  {label: "Card expired", value: "0069", description: "Stripe test card 0069"},
]

// Stories the simulator does not offer. Preset 9 (Rev Rec switches to another saved card) is off:
// the simulator must not promote charging a card the customer did not authorize for this invoice
// (user, 28 Oct). Its code paths stay; take it out of this list to offer it again.
let presetsHidden = [9]
let presetShown = id => !(presetsHidden->Array.includes(id))

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
        // "Stripe test card 9995 declines with insufficient_funds.", shown on hover
        description: ?card->getOptionString("behaviour"),
      }
      option
    })
  let currencies = switch dict->getStrArrayFromDict("currencies", []) {
  | [] => ["USD"]
  | list => list
  }
  {
    presets: presetList
    ->Array.map(item => item->getDictFromJsonObject->presetMapper)
    ->Array.filter(preset => preset.id->presetShown),
    cards: cards->Array.length > 0 ? cards : defaultCardOptions,
    currencies: currencies->SelectBox.makeOptions,
    processorRules: dict
    ->getDictfromDict("limits")
    ->getArrayFromDict("processors", [])
    ->Array.map(item => {
      let p = item->getDictFromJsonObject
      let bank = p->getDictfromDict("bank")
      {
        id: p->getString("id", ""),
        name: p->getString("name", ""),
        allPresets: p->getString("presets", "") == "all",
        presets: p
        ->getArrayFromDict("presets", [])
        ->Array.filterMap(JSON.Decode.float)
        ->Array.map(Float.toInt),
        bankReady: bank->getBool("ready", false),
        genericOnly: bank->getBool("genericOnly", false),
      }
    }),
  }
}

// Can this processor run this preset? Stripe runs all; without the proxy's list, only
// non-Stripe-only presets run elsewhere
let presetRunsOn = (~options: formOptions, ~processor, ~preset: preset) =>
  processor == "stripe" ||
    switch options.processorRules->Array.find(rule => rule.id == processor) {
    | Some(rule) => rule.allPresets || rule.presets->Array.includes(preset.id)
    | None => !preset.stripeOnly
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

// The story is over: the proxy says so, or its invoice has ended. A go-live story's stage follows
// invoice 1 only, so it is over only when the proxy says every old invoice has ended.
let storyHasEnded = (story: story) =>
  story.done || (story.goLive->Option.isNone && story.stage->isFinalStage)

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
  | RevRec => ("Rev Rec", "Hyperswitch")
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
  | "computed" => Computed
  | _ => Rule
  }

let sourceLabel = source =>
  switch source {
  | Sandbox => ("From Rev Rec", "bg-nd_green-50 text-nd_green-600 border-nd_green-200")
  | Recomputed => (
      "Re-computed",
      "bg-nd_primary_blue-50 text-nd_primary_blue-600 border-nd_primary_blue-200",
    )
  | Rule => ("Rule-based", "bg-nd_orange-50 text-nd_orange-600 border-nd_orange-200")
  | Computed => ("Computed", "bg-nd_gray-50 text-nd_gray-600 border-nd_gray-200")
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

let realLifeSlotMapper = (dict): realLifeSlot => {
  retry: dict->getInt("retry", 0),
  offsetSec: dict->getInt("offsetSec", 0),
  at: dict->getString("at", ""),
  dayText: dict->getString("dayText", ""),
  source: dict->getString("source", ""),
}

let optionalDict = (dict, key) => dict->Dict.get(key)->Option.flatMap(JSON.Decode.object)

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
    realLife: dict->optionalDict("realLife")->Option.map(realLifeSlotMapper),
    meaning: dict->Dict.get("meaning")->Option.map(explainLineMapper),
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
      // Null on an older start: then the saved card stands for it
      card: dict->getString("visitorCard", savedCard),
      savedCard,
      firstCharge,
      customer: dict->getString("customer", "new"),
      maxRetries: dict->getInt("maxRetries", 15),
      retryMode: dict->getString("mode", "static"),
      processor: dict->getString("processor", "stripe"),
    })
  }

// One side of a real-world story's result (bank.fixedTimetable or bank.revRec). The fixed
// timetable recovered when it has a recoveredAt; Rev Rec's side says so itself.
let resultSideOf = (side: Dict.t<JSON.t>, ~triesKey): resultSide => {
  let recoveredAt = side->getString("recoveredAt", "")
  {
    recovered: side->getOptionBool("recovered")->Option.getOr(recoveredAt->isNonEmptyString),
    tries: side->getOptionInt(triesKey),
    days: side->Dict.get("daysToRecover")->Option.flatMap(JSON.Decode.float),
    recoveredAt,
  }
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
    processorId: dict->getDictfromDict("processor")->getString("id", ""),
    processorName: dict->getDictfromDict("processor")->getString("name", ""),
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
    realLife: dict
    ->optionalDict("realLife")
    ->Option.map(plan => {
      maxRetries: plan->getInt("maxRetries", 0),
      spanText: plan->getString("spanText", ""),
      demoText: plan->getString("demoText", ""),
      slots: plan
      ->getArrayFromDict("slots", [])
      ->Array.map(slot => slot->getDictFromJsonObject->realLifeSlotMapper),
    }),
    smartNote: dict->Dict.get("smartNote")->Option.map(explainLineMapper),
    savedCards: dict
    ->getArrayFromDict("savedCards", [])
    ->Array.map(item => {
      let card = item->getDictFromJsonObject
      {
        last4: card->getString("last4", ""),
        role: card->getString("role", "main"),
        hardDecline: card->getBool("hardDecline", false),
        approved: card->getBool("approved", false),
      }
    }),
    retryBudget: dict
    ->optionalDict("retryBudget")
    ->Option.map(budget => {
      max: budget->getInt("max", 0),
      retriesLeft: budget->getInt("retriesLeft", 0),
      billingFailuresDuringRecovery: budget->getInt("billingFailuresDuringRecovery", 0),
      note: {
        text: budget->getString("text", ""),
        source: budget->getString("source", "")->sourceMapper,
      },
    }),
    reportAgainClosed: actions->getOptionString("reportAgainClosed"),
    awaitingHandover: dict->getDictfromDict("handover")->getBool("awaiting", false),
    canHandover: actions->getBool("handover", false),
    billingFailures: dict->getDictfromDict("counts")->getOptionInt("billingFailures"),
    revrecRetries: dict->getDictfromDict("counts")->getOptionInt("revrecRetries"),
    nextRetry: dict
    ->optionalDict("nextRetry")
    ->Option.map(next => {
      number: next->getInt("n", 0),
      runsAt: next->getString("runsAt", ""),
      realLife: next->getString("realLife", ""),
      day: next->getInt("day", 0),
      pending: next->getBool("pending", false),
    }),
    handoverNote: dict
    ->getArrayFromDict("explain", [])
    ->Array.find(item => item->getDictFromJsonObject->getString("id", "") == "handover-settings")
    ->Option.map(explainLineMapper),
    settings: actions
    ->optionalDict("settings")
    ->Option.map(settings => {
      let allowed = settings->getDictfromDict("allowed")
      let reasons = settings->getDictfromDict("reasons")
      let current = settings->getDictfromDict("current")
      let rule = key => {
        allowed: allowed->getBool(key, false),
        reason: reasons->getString(key, ""),
      }
      {
        mode: rule("mode"),
        maxRetries: rule("maxRetries"),
        graceDays: rule("graceDays"),
        paused: rule("paused"),
        currentMode: current->getString("mode", "static"),
        currentMaxRetries: current->getOptionInt("maxRetries"),
        currentGraceDays: current->getOptionInt("graceDays"),
        currentPaused: current->getBool("paused", false),
      }
    }),
    eventRules: actions
    ->optionalDict("events")
    ->Option.map(events => {
      let allowed = events->getDictfromDict("allowed")
      let reasons = events->getDictfromDict("reasons")
      ["money_back", "new_card", "stolen", "outage"]
      ->Array.map(key => (
        key,
        {allowed: allowed->getBool(key, false), reason: reasons->getString(key, "")},
      ))
      ->Dict.fromArray
    }),
    worldEvents: dict
    ->getArrayFromDict("worldEvents", [])
    ->Array.map(item => {
      let event = item->getDictFromJsonObject
      {
        eventType: event->getString("type", ""),
        at: event->getString("at", ""),
        until: event->getString("until", ""),
        text: event->getString("text", ""),
      }
    }),
    bank: dict
    ->optionalDict("bank")
    ->Option.map(bank => {
      text: bank->getString("text", ""),
      reason: bank->getString("reason", ""),
      fixedTimetableText: bank
      ->optionalDict("fixedTimetable")
      ->Option.map(fixed => fixed->getString("text", ""))
      ->Option.filter(isNonEmptyString),
      fixedTimetableTries: bank
      ->optionalDict("fixedTimetable")
      ->Option.flatMap(fixed => fixed->getOptionInt("tries")),
      fixedSide: bank
      ->optionalDict("fixedTimetable")
      ->Option.map(side => side->resultSideOf(~triesKey="tries")),
      fixedMath: bank
      ->optionalDict("fixedTimetable")
      ->Option.mapOr([], fixed => fixed->getStrArrayFromDict("math", [])),
      fixedSameTries: bank
      ->optionalDict("fixedTimetable")
      ->Option.flatMap(fixed => fixed->getDictfromDict("sameTries")->getOptionBool("recovered")),
      resultChart: bank->SimulatorResultChart.fromBank,
      revRecSide: bank
      ->optionalDict("revRec")
      ->Option.map(side => side->resultSideOf(~triesKey="retries")),
      worksFromAt: bank->getString("worksFromAt", ""),
      staticRetry: bank->getOptionInt("staticRetry"),
      source: bank->getString("source", "")->sourceMapper,
    }),
    queue: dict
    ->optionalDict("queue")
    ->Option.map(queue => {
      let explainById = id =>
        dict
        ->getArrayFromDict("explain", [])
        ->Array.find(item => item->getDictFromJsonObject->getString("id", "") == id)
        ->Option.map(explainLineMapper)
      let earlier = queue->getDictfromDict("earlier")
      {
        earlierStage: earlier->getString("stage", "")->stageMapper,
        earlierRetries: earlier->getInt("revrecRetries", 0),
        waiting: queue->getBool("waiting", false),
        minGapSec: queue->getOptionFloat("minGapSec"),
        result: explainById("queue"),
        rule: explainById("queue-rule"),
      }
    }),
    goLive: dict
    ->optionalDict("goLive")
    ->Option.map(goLive => {
      mode: goLive->getString("mode", ""),
      revRecOnAt: goLive->getString("revRecOnAt", ""),
      cleanedUp: goLive->getBool("cleanedUp", false),
    }),
    backlog: dict
    ->getArrayFromDict("backlog", [])
    ->Array.map(item => {
      let invoice = item->getDictFromJsonObject
      {
        n: invoice->getInt("n", 0),
        invoiceId: invoice->getString("invoiceId", ""),
        stage: invoice->getString("stage", "")->stageMapper,
        revrecRetries: invoice->getInt("revrecRetries", 0),
        recordedInMonitoringAt: invoice->getString("recordedInMonitoringAt", ""),
        reportedAgainAt: invoice->getString("reportedAgainAt", ""),
        waitingForReport: invoice->getBool("waitingForReport", false),
        recoveredAt: invoice->getString("recoveredAt", ""),
      }
    }),
    canGoLive: actions->getBool("goLive", false),
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
// The proxy's error code ({"error": {"code"}}), "" when there is none
let getSimErrorCode = exn =>
  switch exn {
  | Exn.Error(e) =>
    Exn.message(e)->Option.mapOr("", message =>
      message->safeParse->getDictFromJsonObject->getDictfromDict("error")->getString("code", "")
    )
  | _ => ""
  }

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
// "in 42 s", "in 3 min 05 s", "in 2 h 20 min": the wait in the largest units that help
let countdownText = (~nextRetryAt, ~nowMs) => {
  let seconds = ((nextRetryAt->toMillis -. nowMs) /. 1000.0)->Float.toInt
  let two = n => n < 10 ? `0${n->Int.toString}` : n->Int.toString
  if seconds <= 0 {
    "due now"
  } else if seconds < 60 {
    `in ${seconds->Int.toString} s`
  } else if seconds < 3600 {
    `in ${(seconds / 60)->Int.toString} min ${mod(seconds, 60)->two} s`
  } else {
    `in ${(seconds / 3600)->Int.toString} h ${mod(seconds / 60, 60)->Int.toString} min`
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
  | Some({from: Billing, to: RevRec}) => "Rev Rec is picking a time…"
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

let defaultForm: billingForm = {
  preset: 1,
  amount: "65.40",
  currency: "USD",
  card: "4242",
  savedCard: "0341",
  firstCharge: "0341",
  customer: "new",
  maxRetries: 15,
  retryMode: "smart",
  processor: "stripe",
}

// The processors the simulator offers. Stripe only for now (user, 28 Oct): the other processors'
// code paths stay, hidden; add their connector names here to offer them again.
let processorsEnabled = ["stripe"]
let processorEnabled = id => processorsEnabled->Array.includes(id)

// The processor picked in Setup Recovery, kept for the story form (this browser only; storage may
// be blocked, then the form starts on Stripe)
let processorKey = "simulator_processor"
let saveProcessor = id =>
  try {
    LocalStorage.setItem(processorKey, id)
  } catch {
  | _ => ()
  }
let savedProcessor = () =>
  try {
    LocalStorage.getItem(processorKey)->Nullable.toOption->Option.filter(processorEnabled)
  } catch {
  | _ => None
  }

// POST /sim/story/start body: the preset fills defaults on the proxy, explicit fields win
let startBody = (form: billingForm) => {
  // Stripe is the proxy's default; another (enabled) processor is sent by its connector name
  let otherProcessor = form.processor != "stripe" && form.processor->processorEnabled
  [
    // Preset 0 (none) is left out; the explicit fields then define the charge
    form.preset > 0 ? Some(("preset", form.preset->JSON.Encode.int)) : None,
    Some(("amount", form.amount->toMinor->JSON.Encode.int)),
    Some(("currency", form.currency->JSON.Encode.string)),
    // On Stripe the visitor's one card; the story makes the failure (A, 28 Oct). Another processor
    // keeps the saved card and the first-charge card.
    otherProcessor ? None : Some(("card", form.card->JSON.Encode.string)),
    otherProcessor ? Some(("savedCard", form.savedCard->JSON.Encode.string)) : None,
    otherProcessor ? Some(("firstCharge", form.firstCharge->JSON.Encode.string)) : None,
    Some(("customer", form.customer->JSON.Encode.string)),
    // Max tries, only when changed from Rev Rec's 15
    form.maxRetries != 15 ? Some(("maxRetries", form.maxRetries->JSON.Encode.int)) : None,
    // Every story starts smart: every processor and preset takes it (A, 28 Oct)
    Some(("mode", "smart"->JSON.Encode.string)),
    otherProcessor ? Some(("processor", form.processor->JSON.Encode.string)) : None,
  ]
  ->Array.filterMap(field => field)
  ->getJsonFromArrayOfJson
}
