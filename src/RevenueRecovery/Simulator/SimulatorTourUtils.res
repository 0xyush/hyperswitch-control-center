// Learn Rev Rec v2 (simulator/LEARN-V2.md, PRD section 9): eight five-pane lessons, one per Rev
// Rec feature. Pane 3 shows the real setting of the demo profile when there is one.
open SimulatorTourTypes
open LogicUtils

let retryModeText = mode =>
  switch mode {
  | "cascading" => "Static retries (cascading)"
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
        | "cascading" => "Static"
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

let tryLink = target =>
  switch target {
  | StoryPreset(preset) => (
      "Try it in the story →",
      `${RevenueRecoverySidebarValues.simulatorStoryPath}?preset=${preset->Int.toString}`,
    )
  | PortfolioRun => (
      "Try it in a portfolio run →",
      RevenueRecoverySidebarValues.simulatorPortfolioPath,
    )
  }

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
let merchant = (id, caption, ~col, ~row=0.0, ~isKey=false): flowNode => {
  id,
  actor: None,
  title: "Merchant app",
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
    idea: "The start rule decides when Rev Rec steps in: after how many failed charges.",
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
          "The rule is met, so Rev Rec takes over and plans a retry.",
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
    title: "Static or smart retries",
    hook: "A fixed timetable or the best hour",
    icon: "nd-swap-arrow-horizontal",
    idea: "Static retries use the same fixed timetable for every invoice. Smart retries choose the best time for each invoice.",
    flow: {
      nodes: [
        revRec("pick", "Must choose when to retry", ~col=0.0),
        revRec(
          "static",
          "Follows a fixed timetable: 1 min, then 3 h, then 6 h",
          ~title="Static",
          ~col=1.0,
          ~row=-0.5,
        ),
        revRec(
          "smart",
          "Picks the hour most likely to work",
          ~title="Smart",
          ~col=1.0,
          ~row=0.5,
          ~isKey=true,
        ),
        revRec("retry", "Retries the card at that time", ~col=2.0),
      ],
      edges: [
        arrow("pick", "static", ~label="static mode"),
        arrow("pick", "smart", ~label="smart mode"),
        arrow("static", "retry", ~label="next time slot"),
        arrow("smart", "retry", ~label="best hour"),
      ],
      steps: [
        step(~at="pick", "The card was declined. Rev Rec must choose when to try again."),
        step(
          ~at="static",
          ~via=[("pick", "static")],
          "Static mode: Rev Rec follows the same timetable for every invoice.",
        ),
        step(
          ~at="smart",
          ~via=[("pick", "smart")],
          "Smart mode: Rev Rec looks at the decline reason, the card, the day and the hour, and picks the best time.",
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
        | Some("cascading") => ("Static", "This demo uses the fixed timetable")
        | Some("smart") => ("Smart", "This demo picks the best hour")
        | Some("monitoring") => ("Monitoring", "This demo watches but does not retry")
        | Some(other) => (other->snakeToTitle, "Retry mode of the demo profile")
        | None => ("–", "No retry mode set on the demo profile")
        },
    ),
    checks: (
      {
        question: "What does smart mode add?",
        choices: [
          "It retries more often",
          "It skips hard declines",
          "It picks the hour with the best chance",
        ],
        answer: 2,
      },
      {
        question: "On the fixed timetable, how long is the wait before retry number 3?",
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
    idea: "When one customer has several unpaid invoices, smart retries work on them one at a time.",
    flow: {
      nodes: [
        customer("open", "Has 2 unpaid invoices on one card", ~col=0.0),
        revRec("first", "Retries invoice 1 only", ~col=1.0, ~isKey=true),
        processor("recovered", "Approves: invoice 1 is paid", ~col=2.0),
        revRec("next", "Moves on to invoice 2", ~col=3.0),
      ],
      edges: [
        arrow("open", "first", ~label="wait in line"),
        arrow("first", "recovered", ~label="retry"),
        arrow("recovered", "next", ~label="next in line"),
      ],
      steps: [
        step(~at="open", "One customer has two unpaid invoices on the same card."),
        step(
          ~at="first",
          ~via=[("open", "first")],
          "Rev Rec puts them in line and retries invoice 1 only.",
        ),
        step(
          ~at="recovered",
          ~via=[("first", "recovered")],
          "The bank approves. Invoice 1 is paid.",
        ),
        step(~at="next", ~via=[("recovered", "next")], "Now Rev Rec starts on invoice 2."),
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
    idea: "If the customer pays another way, for example in the app, the billing system tells Rev Rec. Rev Rec stops retrying.",
    flow: {
      nodes: [
        customer("pay", "Pays the invoice in the app", ~col=0.0),
        billing("report", "Tells Rev Rec the invoice is paid", ~col=1.0),
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
          "The billing system sees the payment and tells Rev Rec.",
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
    hook: "Telling the billing system",
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
          "Rev Rec tells the billing platform the invoice is paid",
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
]

let moreFeatures: array<moreFeature> = [
  {
    title: "Multi-card recovery",
    line: "If one saved card keeps failing, Rev Rec tries another card.",
  },
  {
    title: "Account updater",
    line: "The card network supplies a replaced card's new details.",
  },
  {
    title: "Partial auth recovery",
    line: "If the bank approves part of the amount, Rev Rec collects the rest later.",
    setting: PartialAuth,
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
