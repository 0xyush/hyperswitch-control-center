// Learn Rev Rec v2 (simulator/LEARN-V2.md, PRD section 9): eight five-pane lessons, one per Rev
// Rec feature. Pane 3 shows the real setting of the demo profile when there is one.
open SimulatorTourTypes
open LogicUtils

let retryModeText = mode =>
  switch mode {
  | "cascading" => "Fixed timetable"
  | "smart" => "Smart retries"
  | "monitoring" => "Monitoring"
  | other => other
  }

// A setting as one value and a short caption (the More features one-liners)
let settingValue = (config: SimulatorTypes.revRecConfig, key: SimulatorTypes.configKey) => {
  let notSet = "Not set"
  switch key {
  | StartRule =>
    switch config.startRule {
    | Some(0) => ("0", "Rev Rec takes over on the first failure")
    | Some(rule) => (
        rule->Int.toString,
        `Rev Rec takes over on failure ${(rule + 1)->Int.toString}`,
      )
    | None => (notSet, "Start rule")
    }
  | MaxRetries => (
      config.maxRetries->Option.mapOr(notSet, Int.toString),
      "Rev Rec retries at most this often",
    )
  | GracePeriod => (
      config.gracePeriodDays->Option.mapOr(notSet, days => `${days->Int.toString} days`),
      "Rev Rec may retry within this window",
    )
  | RetryMode => (
      config.retryMode->Option.mapOr(notSet, mode =>
        switch mode {
        | "cascading" => "Fixed timetable"
        | "smart" => "Smart"
        | other => other->snakeToTitle
        }
      ),
      "Retry mode of the demo profile",
    )
  | PartialAuth => (
      config.partialAuth->Option.mapOr(notSet, isOn => isOn ? "On" : "Off"),
      "Partial authorization on the demo",
    )
  }
}

// Start rule, max retries, grace period and partial authorization live on the billing connector;
// the retry mode lives on the profile
let getRevRecConfig = (
  ~billingConnector: Dict.t<JSON.t>,
  ~profile: Dict.t<JSON.t>,
): SimulatorTypes.revRecConfig => {
  let revenueRecovery =
    billingConnector->getDictfromDict("feature_metadata")->getDictfromDict("revenue_recovery")
  {
    startRule: revenueRecovery->getOptionInt("billing_connector_retry_threshold"),
    maxRetries: revenueRecovery->getOptionInt("max_retry_count"),
    gracePeriodDays: revenueRecovery->getOptionInt("grace_period_days"),
    retryMode: profile->getOptionString("revenue_recovery_retry_algorithm_type"),
    partialAuth: revenueRecovery->getOptionBool("enable_partial_authorization"),
  }
}

// None hides "Try it": a level's own preset is not in GET /sim/presets yet
let tryLink = (target, ~levelId, ~levelPresets: Dict.t<int>) => {
  let story = preset => (
    "Try it in the story →",
    `${RevenueRecoverySidebarValues.simulatorStoryPath}?preset=${preset->Int.toString}`,
  )
  switch target {
  | StoryPreset(preset) => Some(story(preset))
  | PortfolioRun =>
    Some(("Try it in a portfolio run →", RevenueRecoverySidebarValues.simulatorPortfolioPath))
  | PresetForLevel => levelPresets->Dict.get(levelId->Int.toString)->Option.map(story)
  }
}

// GET /sim/presets: the presets tagged with a Learn level (learnLevel), by level id
let levelPresetsMapper = json =>
  json
  ->getDictFromJsonObject
  ->getArrayFromDict("presets", [])
  ->Array.filterMap(item => {
    let dict = item->getDictFromJsonObject
    switch (dict->getOptionInt("learnLevel"), dict->getOptionInt("id")) {
    | (Some(level), Some(id)) => Some((level->Int.toString, id))
    | _ => None
    }
  })
  ->Dict.fromArray

// Progress: the ids of the levels with both checks right, kept in this browser only
let learnedKey = "simulator_learned_levels"

let readLearned = () =>
  try {
    LocalStorage.getItem(learnedKey)
    ->Nullable.toOption
    ->Option.mapOr([], text =>
      text->safeParse->getArrayFromJson([])->Array.filterMap(JSON.Decode.float)
    )
    ->Array.map(Float.toInt)
  } catch {
  | _ => []
  }

let saveLearned = (ids: array<int>) =>
  try {
    LocalStorage.setItem(
      learnedKey,
      ids->Array.map(JSON.Encode.int)->JSON.Encode.array->JSON.stringify,
    )
  } catch {
  | _ => ()
  }

// Flow nodes, one helper per actor (simulator/LEARN-COPY.md). The title says who, the caption
// says what that actor does. Rev Rec does its own retries, so a retry node is Rev Rec.
let billing = (id, caption, ~col, ~row=0.0, ~isKey=false): flowNode => {
  id,
  actor: Some(SimulatorTypes.Billing),
  title: "Billing system",
  caption,
  col,
  row,
  isKey,
}
let revRec = (id, caption, ~title="Rev Rec", ~col, ~row=0.0, ~isKey=false): flowNode => {
  id,
  actor: Some(SimulatorTypes.RevRec),
  title,
  caption,
  col,
  row,
  isKey,
}
let processor = (id, caption, ~col, ~row=0.0, ~isKey=false): flowNode => {
  id,
  actor: Some(SimulatorTypes.Processor),
  title: "Processor",
  caption,
  col,
  row,
  isKey,
}
let customer = (id, caption, ~col, ~row=0.0, ~isKey=false): flowNode => {
  id,
  actor: Some(SimulatorTypes.Customer),
  title: "Customer",
  caption,
  col,
  row,
  isKey,
}
let merchant = (id, caption, ~title="Merchant app", ~col, ~row=0.0, ~isKey=false): flowNode => {
  id,
  actor: None,
  title,
  caption,
  col,
  row,
  isKey,
}
let arrow = (from, to, ~label): flowEdge => {from, to, label}
// One step of the walk, in the order it plays
let step = (~at, ~via=[], says): flowStep => {at, via, says}

// Pane 3 while the demo profile is being read, or when it cannot be read
let numberWhileLoading = ("…", "Reading the demo profile")
let numberNotAvailable = ("–", "The demo profile could not be read")

let levels: array<level> = [
  {
    id: 1,
    title: "The start rule",
    hook: "When Rev Rec takes over",
    icon: "nd-flag",
    idea: "Rev Rec steps in after this many failed charges.",
    flow: {
      nodes: [
        billing("charge", "Charges the customer's card", ~col=0.0),
        processor("decline", "Declines the charge", ~col=1.0),
        revRec(
          "count",
          "Counts the failed charges and checks the start rule",
          ~col=2.0,
          ~isKey=true,
        ),
        revRec("retry", "Takes over and plans a retry", ~col=3.0),
      ],
      edges: [
        arrow("charge", "decline", ~label="payment"),
        arrow("decline", "count", ~label="failure reported"),
        arrow("count", "retry", ~label="rule met"),
      ],
      steps: [
        step(~at="charge", "The billing system charges the card for this month's invoice."),
        step(
          ~at="decline",
          ~via=[("charge", "decline")],
          "The bank declines. The billing system reports the failure to Rev Rec.",
        ),
        step(
          ~at="count",
          ~via=[("decline", "count")],
          "Rev Rec counts the failures. Start rule 0 means: take over after the first failure.",
        ),
        step(
          ~at="retry",
          ~via=[("count", "retry")],
          "The rule is met. Rev Rec takes over and plans a retry.",
        ),
      ],
    },
    number: FromConfig(
      config =>
        switch config.startRule {
        | Some(0) => ("0", "Rev Rec takes over on the first failure")
        | Some(rule) => (
            rule->Int.toString,
            `Rev Rec takes over on failure ${(rule + 1)->Int.toString}`,
          )
        | None => ("–", "No start rule set on the demo profile")
        },
    ),
    checks: (
      {
        question: "With start rule 0, when does Rev Rec take over?",
        choices: ["After the first failure", "After three failures", "Never"],
        answer: 0,
      },
      {
        question: "The start rule is 2. The billing system has reported one failed charge. What happens?",
        choices: [
          "Rev Rec retries now",
          "Rev Rec waits. The billing system keeps trying first.",
          "The invoice is cancelled",
        ],
        answer: 1,
      },
    ),
    tryTarget: StoryPreset(2),
  },
  {
    id: 2,
    title: "From a fixed timetable to smart retries",
    hook: "The same timetable, or the best hour",
    icon: "nd-swap-arrow-horizontal",
    idea: "A fixed timetable retries every invoice the same way. Smart retries pick the best time.",
    flow: {
      nodes: [
        revRec("pick", "Must choose when to retry", ~col=0.0),
        revRec(
          "static",
          "1 min, then 3 h, then 6 h, for every invoice",
          ~title="Fixed timetable",
          ~col=1.0,
          ~row=-0.5,
        ),
        revRec(
          "smart",
          "Picks the hour most likely to work",
          ~title="Smart retries",
          ~col=1.0,
          ~row=0.5,
          ~isKey=true,
        ),
        revRec("retry", "Retries the card at that time", ~col=2.0),
      ],
      edges: [
        arrow("pick", "static", ~label="today"),
        arrow("pick", "smart", ~label="with Rev Rec"),
        arrow("static", "retry", ~label="next time slot"),
        arrow("smart", "retry", ~label="best hour"),
      ],
      steps: [
        step(~at="pick", "The card was declined. Rev Rec must choose when to try again."),
        step(
          ~at="static",
          ~via=[("pick", "static")],
          "A fixed timetable waits the same times for every invoice.",
        ),
        step(
          ~at="smart",
          ~via=[("pick", "smart")],
          "Smart retries look at the decline reason, the day and the hour.",
        ),
        step(
          ~at="retry",
          ~via=[("static", "retry"), ("smart", "retry")],
          "At the chosen time, Rev Rec charges the saved card again.",
        ),
      ],
    },
    number: FromConfig(
      config =>
        switch config.retryMode {
        | Some("cascading") => ("Fixed timetable", "This demo uses the fixed timetable")
        | Some("smart") => ("Smart", "This demo picks the best hour")
        | Some("monitoring") => ("Monitoring", "This demo watches but does not retry")
        | Some(other) => (other->snakeToTitle, "Retry mode of the demo profile")
        | None => ("–", "No retry mode set on the demo profile")
        },
    ),
    checks: (
      {
        question: "What do smart retries add?",
        choices: [
          "It retries more often",
          "It skips hard declines",
          "It picks the hour with the best chance",
        ],
        answer: 2,
      },
      {
        question: "On the fixed timetable, how long before retry 3?",
        choices: ["6 hours", "1 minute", "1 day"],
        answer: 0,
      },
    ),
    tryTarget: PortfolioRun,
  },
  {
    id: 3,
    title: "Max retries and grace period",
    hook: "How long Rev Rec keeps trying",
    icon: "nd-hour-glass-outline",
    idea: "Rev Rec stops after a set number of retries (max retries) or a set number of days (grace period), whichever comes first.",
    flow: {
      nodes: [
        revRec("retry", "Retries the card", ~col=0.0),
        processor("decline", "Declines again", ~col=1.0),
        revRec("check", "Retries left, and still inside the grace period?", ~col=2.0, ~isKey=true),
        revRec("again", "Plans the next retry", ~col=3.0, ~row=-0.5),
        revRec("stop", "Stops retrying this invoice", ~col=3.0, ~row=0.5),
      ],
      edges: [
        arrow("retry", "decline", ~label="retry"),
        arrow("decline", "check", ~label="one retry used"),
        arrow("check", "again", ~label="yes"),
        arrow("check", "stop", ~label="no"),
      ],
      steps: [
        step(~at="retry", "Rev Rec retries the saved card."),
        step(
          ~at="decline",
          ~via=[("retry", "decline")],
          "The card is declined again. One more retry is used up.",
        ),
        step(
          ~at="check",
          ~via=[("decline", "check")],
          "Rev Rec checks two limits: retries used against the maximum, and days passed against the grace period.",
        ),
        step(
          ~at="again",
          ~via=[("check", "again")],
          "Both limits are fine: Rev Rec plans another retry.",
        ),
        step(
          ~at="stop",
          ~via=[("check", "stop")],
          "One limit is reached: Rev Rec stops. The invoice ends as Terminated.",
        ),
      ],
    },
    number: FromConfig(
      config =>
        switch (config.maxRetries, config.gracePeriodDays) {
        | (Some(max), Some(days)) => (
            `${max->Int.toString} · ${days->Int.toString} days`,
            `Up to ${max->Int.toString} retries within ${days->Int.toString} days`,
          )
        | (Some(max), None) => (max->Int.toString, "Retries at most per invoice")
        | _ => ("–", "No max retries set on the demo profile")
        },
    ),
    checks: (
      {
        question: "Max retries is 15. After the 15th decline Rev Rec…",
        choices: ["Keeps going", "Stops", "Asks the customer"],
        answer: 1,
      },
      {
        question: "The grace period ends before the next retry. Rev Rec…",
        choices: ["Retries once more", "Extends the period", "Stops retrying"],
        answer: 2,
      },
    ),
    tryTarget: StoryPreset(4),
  },
  {
    id: 4,
    title: "Hard declines",
    hook: "When retrying is pointless",
    icon: "nd-shield",
    idea: "Some declines can never succeed, like a stolen or closed card. Rev Rec stops on these at once.",
    flow: {
      nodes: [
        processor("decline", "Declines and gives a reason", ~col=0.0),
        revRec("catalogue", "Looks up the reason: can a retry still work?", ~col=1.0, ~isKey=true),
        revRec("later", "Soft decline: retries later", ~col=2.0, ~row=-0.5),
        revRec("stop", "Hard decline: stops at once", ~col=2.0, ~row=0.5),
      ],
      edges: [
        arrow("decline", "catalogue", ~label="decline reason"),
        arrow("catalogue", "later", ~label="yes"),
        arrow("catalogue", "stop", ~label="no"),
      ],
      steps: [
        step(
          ~at="decline",
          "The bank declines and gives a reason, for example insufficient funds or stolen card.",
        ),
        step(
          ~at="catalogue",
          ~via=[("decline", "catalogue")],
          "Rev Rec looks up the reason in its list of decline codes.",
        ),
        step(
          ~at="later",
          ~via=[("catalogue", "later")],
          "Soft decline, like insufficient funds: the money may come back, so Rev Rec retries later.",
        ),
        step(
          ~at="stop",
          ~via=[("catalogue", "stop")],
          "Hard decline, like a stolen card: a retry can never work, so Rev Rec stops.",
        ),
      ],
    },
    number: Fixed("0", "Retries after a hard decline"),
    checks: (
      {
        question: "A stolen card is a…",
        choices: ["Hard decline", "Soft decline", "Temporary error"],
        answer: 0,
      },
      {
        question: "Why stop on a hard decline?",
        choices: [
          "The customer asked",
          "More retries cannot succeed and can cost fees",
          "The card is expired",
        ],
        answer: 1,
      },
    ),
    tryTarget: StoryPreset(7),
  },
  {
    id: 5,
    title: "Card network limits",
    hook: "Visa and Mastercard set limits",
    icon: "nd-payment-terminal",
    idea: "Visa and Mastercard limit how often a merchant may retry the same card. Rev Rec stays inside these limits.",
    flow: {
      nodes: [
        revRec("want", "Is ready to retry the card", ~col=0.0),
        revRec("cap", "Has this card reached the Visa or Mastercard limit?", ~col=1.0, ~isKey=true),
        revRec("retry", "Not yet: retries now", ~col=2.0, ~row=-0.5),
        revRec("wait", "Limit reached: waits for it to reset", ~col=2.0, ~row=0.5),
      ],
      edges: [
        arrow("want", "cap", ~label="check limit"),
        arrow("cap", "retry", ~label="no"),
        arrow("cap", "wait", ~label="yes"),
      ],
      steps: [
        step(~at="want", "Rev Rec is ready to retry the card."),
        step(
          ~at="cap",
          ~via=[("want", "cap")],
          "First it counts this card's retries today and in the last 30 days.",
        ),
        step(~at="retry", ~via=[("cap", "retry")], "Under the limit: Rev Rec retries now."),
        step(
          ~at="wait",
          ~via=[("cap", "wait")],
          "Limit reached: Rev Rec waits until the count resets, then retries.",
        ),
      ],
    },
    number: Fixed("20", "Retries per Visa card per day. Mastercard allows 10."),
    checks: (
      {
        question: "Who sets the limit on retries per card?",
        choices: ["The merchant", "Stripe", "The card networks, Visa and Mastercard"],
        answer: 2,
      },
      {
        question: "The limit is reached. Rev Rec…",
        choices: ["Waits until the limit resets", "Switches to another card", "Gives up"],
        answer: 0,
      },
    ),
    tryTarget: StoryPreset(5),
  },
  {
    id: 6,
    title: "Invoice queuing",
    hook: "One invoice per customer",
    icon: "nd-payment-queued",
    // A's proof on the engine (preset 8): one invoice per customer at a time; after every retry
    // the next invoice can take its turn
    idea: "When one customer has several unpaid invoices, Rev Rec charges them one at a time.",
    flow: {
      nodes: [
        customer("open", "Has 2 unpaid invoices on one card", ~col=0.0),
        revRec("first", "Retries one invoice", ~col=1.0, ~isKey=true),
        // The waiting invoice's status lives in Rev Rec, so it takes Rev Rec's colour
        revRec("wait", "Shows Queued while it waits", ~title="Invoice 2", ~col=2.0),
        revRec("next", "Gives the next invoice its turn", ~col=3.0),
      ],
      edges: [
        arrow("open", "first", ~label="one at a time"),
        arrow("first", "wait", ~label="busy"),
        arrow("wait", "next", ~label="next turn"),
      ],
      steps: [
        step(~at="open", "One customer has two unpaid invoices on the same card."),
        step(
          ~at="first",
          ~via=[("open", "first")],
          "Rev Rec takes the customer for one invoice and retries it.",
        ),
        step(
          ~at="wait",
          ~via=[("first", "wait")],
          "The other invoice waits. Its status shows Queued.",
        ),
        step(
          ~at="next",
          ~via=[("wait", "next")],
          "After each retry, the next invoice can take its turn.",
        ),
      ],
    },
    number: Fixed("1", "Invoice per customer at a time"),
    checks: (
      {
        question: "Two invoices, one customer. Rev Rec retries…",
        choices: ["Both at once", "One at a time", "The newest only"],
        answer: 1,
      },
      {
        question: "Why one at a time?",
        choices: [
          "The processor requires it",
          "It is faster",
          "Every retry hits the same card. One at a time wastes fewer retries and avoids fraud alerts.",
        ],
        answer: 2,
      },
    ),
    tryTarget: StoryPreset(8),
  },
  {
    id: 7,
    title: "Paid outside Rev Rec",
    hook: "The customer paid another way",
    icon: "nd-wallet",
    idea: "If the customer pays another way, for example in the app, the billing system informs Rev Rec. Rev Rec stops retrying.",
    flow: {
      nodes: [
        customer("pay", "Pays the invoice in the app", ~col=0.0),
        billing("report", "Informs Rev Rec the invoice is paid", ~col=1.0),
        revRec("stop", "Cancels its planned retries", ~col=2.0, ~isKey=true),
        revRec("closed", "Closes the invoice as paid outside Rev Rec", ~col=3.0),
      ],
      edges: [
        arrow("pay", "report", ~label="payment"),
        arrow("report", "stop", ~label="invoice paid"),
        arrow("stop", "closed", ~label="close"),
      ],
      steps: [
        step(~at="pay", "While Rev Rec is still retrying, the customer pays in the app."),
        step(
          ~at="report",
          ~via=[("pay", "report")],
          "The billing system sees the payment and informs Rev Rec.",
        ),
        step(
          ~at="stop",
          ~via=[("report", "stop")],
          "Rev Rec cancels the retries it had planned, so the customer is never charged twice.",
        ),
        step(
          ~at="closed",
          ~via=[("stop", "closed")],
          "The invoice closes as paid, but Rev Rec does not count it as its own recovery.",
        ),
      ],
    },
    number: Fixed("0", "Retries after the customer pays another way"),
    checks: (
      {
        question: "The customer pays in the app mid-recovery. Rev Rec…",
        choices: ["Stops and marks it paid outside", "Retries anyway", "Refunds"],
        answer: 0,
      },
      {
        question: "Who gets credit for that payment?",
        choices: ["Rev Rec", "The billing system, not Rev Rec", "Nobody"],
        answer: 1,
      },
    ),
    tryTarget: StoryPreset(1),
  },
  {
    id: 8,
    title: "Record back and webhooks",
    hook: "Informing the billing system",
    icon: "nd-webhook",
    idea: "When Rev Rec recovers an invoice, the merchant must learn it was paid. Rev Rec can update the billing platform directly (record back) or send a message (webhook).",
    flow: {
      nodes: [
        processor("approved", "Approves the retry", ~col=0.0),
        revRec("recovers", "Marks the invoice recovered", ~col=1.0),
        billing("paid", "Shows the invoice as paid", ~col=2.0, ~row=-0.5, ~isKey=true),
        merchant("updates", "Gets the message and unlocks the account", ~col=2.0, ~row=0.5),
      ],
      edges: [
        arrow("approved", "recovers", ~label="approved"),
        arrow("recovers", "paid", ~label="record back"),
        arrow("recovers", "updates", ~label="webhook"),
      ],
      steps: [
        step(~at="approved", "The bank approves Rev Rec's retry."),
        step(
          ~at="recovers",
          ~via=[("approved", "recovers")],
          "Rev Rec marks the invoice recovered.",
        ),
        step(
          ~at="paid",
          ~via=[("recovers", "paid")],
          "Record back: Rev Rec writes \"paid\" straight into the billing platform, for example Chargebee or Recurly.",
        ),
        step(
          ~at="updates",
          ~via=[("recovers", "updates")],
          "Webhook: Rev Rec also sends a message to the merchant's server, so the app can unlock the account.",
        ),
      ],
    },
    number: Fixed(
      "Webhook",
      "This demo's billing system has no record back. It learns the result by webhook.",
    ),
    checks: (
      {
        question: "Record back means…",
        choices: [
          "The customer gets a receipt",
          "The card is saved",
          "Rev Rec informs the billing platform the invoice is paid",
        ],
        answer: 2,
      },
      {
        question: "This demo's billing system has no record back. How does the merchant learn the result?",
        choices: ["By webhook", "By email", "It never learns"],
        answer: 0,
      },
    ),
    tryTarget: StoryPreset(2),
  },
  {
    id: 9,
    title: "One webhook at the end",
    hook: "The billing system learns the final result",
    icon: "nd-inbox",
    idea: "Rev Rec sends the billing system one webhook when the invoice ends.",
    flow: {
      nodes: [
        revRec("retry", "Retries the saved card", ~col=0.0),
        processor("bank", "Declines, or approves at last", ~col=1.0),
        revRec("send", "Sends one message at the end", ~col=2.0, ~isKey=true),
        billing("update", "Updates the invoice with the result", ~col=3.0),
      ],
      edges: [
        arrow("retry", "bank", ~label="retry"),
        arrow("bank", "send", ~label="final result"),
        arrow("send", "update", ~label="webhook"),
      ],
      steps: [
        step(~at="retry", "Rev Rec retries the saved card."),
        step(
          ~at="bank",
          ~via=[("retry", "bank")],
          "A declined retry sends no message. Rev Rec tries again.",
        ),
        step(~at="send", ~via=[("bank", "send")], "The invoice ends: recovered, or Rev Rec stops."),
        step(
          ~at="update",
          ~via=[("send", "update")],
          "Rev Rec sends the billing system one webhook with the result.",
        ),
      ],
    },
    // Confirmed on the demo engine (A, 27 Oct): 15 declined retries, then one payment_failed
    number: Fixed("1 webhook", "15 declined retries, then one webhook: payment failed."),
    checks: (
      {
        question: "When does Rev Rec send the webhook?",
        choices: ["When the invoice ends", "After every retry", "Never"],
        answer: 0,
      },
      {
        question: "Why does the billing system need the webhook?",
        choices: [
          "To show the invoice's final result",
          "To charge the card again",
          "To tell the bank",
        ],
        answer: 0,
      },
    ),
    tryTarget: PresetForLevel,
  },
  {
    id: 10,
    title: "Billing failures keep the budget",
    hook: "Rev Rec keeps all its retries",
    icon: "nd-alert-triangle-outline",
    idea: "While Rev Rec is retrying, the billing system may also charge the card. If that charge fails, Rev Rec still keeps all its retries.",
    flow: {
      nodes: [
        billing("charge", "Charges the card itself during recovery", ~col=0.0),
        processor("decline", "Declines the charge", ~col=1.0),
        revRec("count", "Adds it to the invoice's failure count", ~col=2.0, ~isKey=true),
        revRec("left", "Still has all its retries", ~col=3.0),
      ],
      edges: [
        arrow("charge", "decline", ~label="payment"),
        arrow("decline", "count", ~label="failure reported"),
        arrow("count", "left", ~label="budget unchanged"),
      ],
      steps: [
        step(
          ~at="charge",
          "Rev Rec is recovering the invoice. The billing system also charges the card.",
        ),
        step(
          ~at="decline",
          ~via=[("charge", "decline")],
          "The bank declines the billing system's charge.",
        ),
        step(
          ~at="count",
          ~via=[("decline", "count")],
          "The billing system reports the failure. Rev Rec adds it to the invoice's failure count.",
        ),
        step(
          ~at="left",
          ~via=[("count", "left")],
          "Rev Rec's own retry budget does not change: it still makes all its retries.",
        ),
      ],
    },
    // A's flow 2 finding (27 Oct): a billing-side failure does not use Rev Rec's retry budget
    number: FromConfig(
      config =>
        switch config.maxRetries {
        | Some(max) => (max->Int.toString, "Retries Rev Rec still makes after a billing failure")
        | None => ("–", "No max retries set on the demo profile")
        },
    ),
    planned: "The workshop plan says such failures should use the budget; the engine does not do that yet.",
    checks: (
      {
        question: "Who can charge the card while Rev Rec is recovering an invoice?",
        choices: ["Only Rev Rec", "The billing system can too", "Only the bank"],
        answer: 1,
      },
      {
        question: "The billing system's charge fails during recovery. What happens to Rev Rec's retries?",
        choices: [
          "One is used up",
          "None is used: Rev Rec keeps all its retries",
          "They reset to zero",
        ],
        answer: 1,
      },
    ),
    tryTarget: PresetForLevel,
  },
  {
    id: 11,
    title: "Finished invoices stay closed",
    hook: "No new retries after the end",
    icon: "nd-check-circle-outline",
    // A's flow 3 finding (27 Oct): Recovered or Cancelled refuses a late report; Terminated by a hard
    // decline accepts it but stays terminated
    idea: "A paid or cancelled invoice refuses new reports. A stopped invoice records them but never restarts.",
    flow: {
      nodes: [
        billing("report", "Reports a new failure for an ended invoice", ~col=0.0),
        revRec("check", "Checks: how did this invoice end?", ~col=1.0, ~isKey=true),
        revRec("refuse", "Paid or cancelled: refuses the report", ~col=2.0, ~row=-0.5),
        revRec("record", "Stopped: records it, never restarts", ~col=2.0, ~row=0.5),
        billing("told", "Gets a \"not allowed\" answer", ~col=3.0, ~row=-0.5),
      ],
      edges: [
        arrow("report", "check", ~label="failure report"),
        arrow("check", "refuse", ~label="paid or cancelled"),
        arrow("check", "record", ~label="stopped"),
        arrow("refuse", "told", ~label="not allowed"),
      ],
      steps: [
        step(
          ~at="report",
          "The billing system reports a new failure for an invoice that has ended.",
        ),
        step(
          ~at="check",
          ~via=[("report", "check")],
          "Rev Rec checks how the invoice ended: paid, cancelled or stopped.",
        ),
        step(
          ~at="refuse",
          ~via=[("check", "refuse")],
          "Paid or cancelled: Rev Rec refuses the report, so the invoice is never reopened.",
        ),
        step(
          ~at="told",
          ~via=[("refuse", "told")],
          "The billing system gets a \"not allowed\" answer, and nothing changes.",
        ),
        step(
          ~at="record",
          ~via=[("check", "record")],
          "Stopped after a hard decline: Rev Rec records the report, but no retry starts.",
        ),
      ],
    },
    number: Fixed("0", "Retries after a report on an ended invoice"),
    checks: (
      {
        question: "An invoice is already recovered. The billing system reports a new failure. What does Rev Rec do?",
        choices: ["Starts retrying again", "Refuses the report", "Refunds the customer"],
        answer: 1,
      },
      {
        question: "An invoice was stopped by a hard decline. A new failure report arrives. What happens?",
        choices: [
          "Rev Rec records it, but no retry starts",
          "Rev Rec starts retrying again",
          "The invoice is deleted",
        ],
        answer: 0,
      },
    ),
    tryTarget: PresetForLevel,
  },
  {
    id: 12,
    title: "Go live: watch first",
    hook: "Old failed invoices, then retries",
    icon: "nd-eye-on",
    idea: "A new merchant may already have many failed invoices. Rev Rec first only records them (monitoring). Then the merchant switches retries on.",
    flow: {
      nodes: [
        billing("backlog", "Sends the invoices that already failed", ~col=0.0),
        revRec("watch", "Monitoring: records them, no retries yet", ~col=1.0, ~isKey=true),
        merchant("switch", "Checks the numbers, switches retries on", ~title="Merchant", ~col=2.0),
        revRec("retry", "Retries the invoices on its timetable", ~col=3.0),
      ],
      edges: [
        arrow("backlog", "watch", ~label="old failures"),
        arrow("watch", "switch", ~label="numbers"),
        arrow("switch", "retry", ~label="retries on"),
      ],
      steps: [
        step(~at="backlog", "The merchant goes live with many invoices that already failed."),
        step(
          ~at="watch",
          ~via=[("backlog", "watch")],
          "Rev Rec starts in monitoring: it records each invoice but does not retry yet.",
        ),
        step(
          ~at="switch",
          ~via=[("watch", "switch")],
          "The merchant checks the numbers, then switches retries on in the dashboard.",
        ),
        step(
          ~at="retry",
          ~via=[("switch", "retry")],
          "Now Rev Rec retries the invoices on its normal timetable.",
        ),
      ],
    },
    number: FromConfig(
      config =>
        switch config.retryMode {
        | Some("monitoring") => (
            "Monitoring",
            "The demo profile records failures but does not retry yet",
          )
        | Some(_) => ("Retries on", "The demo profile is past monitoring: it retries")
        | None => ("–", "No retry mode set on the demo profile")
        },
    ),
    checks: (
      {
        question: "What does Rev Rec do in monitoring?",
        choices: [
          "Retries every invoice",
          "Records the invoices but does not retry",
          "Cancels old invoices",
        ],
        answer: 1,
      },
      {
        question: "Why start a backlog in monitoring?",
        choices: [
          "To see the numbers before any customer is charged again",
          "Because retries cost nothing",
          "To delete old invoices",
        ],
        answer: 0,
      },
    ),
    tryTarget: PresetForLevel,
  },
  {
    id: 13,
    title: "Partly paid invoices",
    hook: "The paid part closes, the rest is retried",
    icon: "nd-payment-partial-captured",
    idea: "Sometimes only part of an invoice gets paid. That part is done, and Rev Rec keeps retrying the rest.",
    flow: {
      nodes: [
        revRec("retry", "Retries the full amount", ~col=0.0),
        processor("partial", "Approves only part of it", ~col=1.0),
        revRec("split", "Marks the paid part as recovered", ~col=2.0, ~isKey=true),
        revRec("rest", "Retries the amount still owed", ~col=3.0),
      ],
      edges: [
        arrow("retry", "partial", ~label="retry"),
        arrow("partial", "split", ~label="part paid"),
        arrow("split", "rest", ~label="rest owed"),
      ],
      steps: [
        step(~at="retry", "Rev Rec retries the full invoice amount."),
        step(
          ~at="partial",
          ~via=[("retry", "partial")],
          "The bank approves only part of it, for example $40 of $65.40.",
        ),
        step(
          ~at="split",
          ~via=[("partial", "split")],
          "Rev Rec marks the paid part as recovered. The invoice shows as partly recovered.",
        ),
        step(
          ~at="rest",
          ~via=[("split", "rest")],
          "Rev Rec keeps retrying the amount still owed, until it is paid or Rev Rec stops.",
        ),
      ],
    },
    // Being checked: the workshop flow is the billing system reporting a partial payment (A's item 5)
    number: Fixed("Being checked", "We are testing how the demo engine handles a partial payment."),
    checks: (
      {
        question: "The bank approves $40 of a $65.40 invoice. What does Rev Rec retry next?",
        choices: ["$65.40 again", "The $25.40 still owed", "Nothing, it stops"],
        answer: 1,
      },
      {
        question: "What happens to the $40 already paid?",
        choices: ["It is refunded", "It counts as recovered", "It is charged again"],
        answer: 1,
      },
    ),
    tryTarget: PresetForLevel,
  },
  {
    id: 14,
    title: "How smart picks a day",
    hook: "Why Friday at 9 PM?",
    icon: "nd-analytics",
    // The engine's model (simulator/selfhost/MODEL.md), in the model view's words
    idea: "Rev Rec's model tries when the same decline worked most often before.",
    flow: {
      nodes: [
        billing("fail", "Reports the failed charge and its decline", ~col=0.0),
        revRec("counts", "Looks up past tries for this decline", ~col=1.0),
        revRec("days", "Ranks the next days by how often they worked", ~col=2.0, ~isKey=true),
        revRec("floor", "Every day keeps at least a 1 in 10 chance", ~col=3.0),
        revRec("pick", "Tries on the soonest planned day, at a likely hour", ~col=4.0),
      ],
      edges: [
        arrow("fail", "counts", ~label="decline"),
        arrow("counts", "days", ~label="worked k of n"),
        arrow("days", "floor", ~label="plan"),
        arrow("floor", "pick", ~label="soonest day"),
      ],
      steps: [
        step(~at="fail", "The billing system reports a failed charge and its decline."),
        step(
          ~at="counts",
          ~via=[("fail", "counts")],
          "Rev Rec looks up how often each day and hour worked before.",
        ),
        step(
          ~at="days",
          ~via=[("counts", "days")],
          "It ranks the next days. The best ones get a place in the plan.",
        ),
        step(
          ~at="floor",
          ~via=[("days", "floor")],
          "Every other day keeps at least a 1 in 10 chance, so Rev Rec keeps learning.",
        ),
        step(
          ~at="pick",
          ~via=[("floor", "pick")],
          "Rev Rec tries on the soonest planned day, at a likely hour.",
        ),
      ],
    },
    number: Fixed("1 in 10", "The smallest chance any day keeps"),
    engineNote: "The model never retries the same day.",
    checks: (
      {
        question: "Fridays worked 204 of 745 times before. What does that mean for Rev Rec?",
        choices: [
          "Friday is a good day to try",
          "The next try on Friday will work",
          "Never try on a Friday",
        ],
        answer: 0,
      },
      {
        question: "Why does every day keep a small chance?",
        choices: [
          "So Rev Rec keeps learning about every day",
          "To slow Rev Rec down",
          "Because the bank asks",
        ],
        answer: 0,
      },
    ),
    // The portfolio run's smart side; a smart invoice there shows its model view
    tryTarget: PortfolioRun,
  },
]

let moreFeatures: array<moreFeature> = [
  {
    title: "Account updater",
    line: "The card network supplies a replaced card's new details.",
  },
  {
    title: "Dunning emails",
    line: "Reminder emails to the customer. The simulator sends none.",
  },
  {
    title: "Integration models",
    line: "Rev Rec retries by itself, or only sends signals to the billing system.",
  },
  {
    title: "Processor choice",
    line: "Today Rev Rec retries on the same processor.",
  },
]
