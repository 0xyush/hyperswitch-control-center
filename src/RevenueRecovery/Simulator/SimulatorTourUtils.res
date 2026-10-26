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

// Flow nodes, one helper per actor. Captions say what the actor does at that step.
let billing = (id, caption, ~col, ~row=0.0, ~highlighted=false): flowNode => {
  id,
  actor: Some(SimulatorTypes.Billing),
  title: "Billing system",
  caption,
  col,
  row,
  highlighted,
}
let revRec = (id, caption, ~title="Rev Rec", ~col, ~row=0.0, ~highlighted=false): flowNode => {
  id,
  actor: Some(SimulatorTypes.RevRec),
  title,
  caption,
  col,
  row,
  highlighted,
}
let processor = (id, caption, ~col, ~row=0.0, ~highlighted=false): flowNode => {
  id,
  actor: Some(SimulatorTypes.Processor),
  title: "Processor",
  caption,
  col,
  row,
  highlighted,
}
let customer = (id, caption, ~col, ~row=0.0, ~highlighted=false): flowNode => {
  id,
  actor: Some(SimulatorTypes.Customer),
  title: "Customer",
  caption,
  col,
  row,
  highlighted,
}
let merchant = (id, caption, ~col, ~row=0.0, ~highlighted=false): flowNode => {
  id,
  actor: None,
  title: "Merchant app",
  caption,
  col,
  row,
  highlighted,
}
let arrow = (from, to, ~label="", ~highlighted=false): flowEdge => {from, to, label, highlighted}

// Pane 3 while the demo profile is being read, or when it cannot be read
let numberWhileLoading = ("…", "Reading the demo profile")
let numberNotAvailable = ("–", "The demo profile could not be read")

let levels: array<level> = [
  {
    id: 1,
    title: "The start rule",
    hook: "When Rev Rec takes over",
    icon: "nd-flag",
    idea: "The start rule says how many failures the billing system handles before Rev Rec.",
    flow: {
      nodes: [
        billing("charge", "Charges the card", ~col=0.0),
        processor("decline", "Declines", ~col=1.0),
        revRec("count", "Counts failures vs the start rule", ~col=2.0, ~highlighted=true),
        processor("retry", "Rev Rec retries", ~col=3.0),
      ],
      edges: [
        arrow("charge", "decline", ~label="charge"),
        arrow("decline", "count", ~label="reported"),
        arrow("count", "retry", ~label="takes over", ~highlighted=true),
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
        question: "Start rule is 2 and the billing system reported one failure. What happens?",
        choices: [
          "Rev Rec retries now",
          "Rev Rec waits for more failures",
          "The invoice is cancelled",
        ],
        answer: 1,
      },
    ),
    tryTarget: StoryPreset(2),
  },
  {
    id: 2,
    title: "Static vs smart retries",
    hook: "A fixed ladder or the best hour",
    icon: "nd-swap-arrow-horizontal",
    idea: "Static retries follow a fixed schedule; smart retries pick the best time per invoice.",
    flow: {
      nodes: [
        revRec("pick", "Picks a retry time", ~col=0.0),
        revRec("static", "Fixed ladder: 1 min, 3 h, 6 h", ~title="Static", ~col=1.25, ~row=-0.6),
        revRec("smart", "Scores each hour", ~title="Smart", ~col=1.25, ~row=0.6, ~highlighted=true),
        processor("retry", "Retries at the booked time", ~col=2.5),
      ],
      edges: [
        arrow("pick", "static", ~label="static"),
        arrow("pick", "smart", ~label="smart", ~highlighted=true),
        arrow("static", "retry", ~label="next rung"),
        arrow("smart", "retry", ~label="best hour"),
      ],
    },
    number: FromConfig(
      config =>
        switch config.retryMode {
        | Some("cascading") => ("Static", "The demo profile uses the fixed ladder")
        | Some("smart") => ("Smart", "The demo profile picks the best hour")
        | Some("monitoring") => ("Monitoring", "The demo profile watches but does not retry")
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
        question: "Static retry number 3 waits how long on the production ladder?",
        choices: ["6 hours", "1 minute", "1 day"],
        answer: 0,
      },
    ),
    tryTarget: PortfolioRun,
  },
  {
    id: 3,
    title: "Max retries & grace period",
    hook: "How long Rev Rec keeps trying",
    icon: "nd-hour-glass-outline",
    idea: "Max retries caps the tries per invoice; the grace period caps the days.",
    flow: {
      nodes: [
        revRec("retry", "Retries", ~col=0.0),
        processor("decline", "Declines", ~col=1.0),
        revRec("check", "Under max and inside grace?", ~col=2.0, ~highlighted=true),
        revRec("again", "Retries again", ~col=3.0, ~row=-0.6),
        revRec("stop", "Stops", ~col=3.0, ~row=0.6),
      ],
      edges: [
        arrow("retry", "decline", ~label="retry"),
        arrow("decline", "check", ~label="count + 1"),
        arrow("check", "again", ~label="yes"),
        arrow("check", "stop", ~label="no", ~highlighted=true),
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
    idea: "A hard decline, like a stolen card, never works, so Rev Rec stops.",
    flow: {
      nodes: [
        processor("decline", "Declines", ~col=0.0),
        revRec("catalogue", "Error catalogue: soft or hard?", ~col=1.0, ~highlighted=true),
        revRec("later", "Retries later", ~col=2.0, ~row=-0.6),
        revRec("stop", "Stops at once", ~col=2.0, ~row=0.6),
      ],
      edges: [
        arrow("decline", "catalogue", ~label="decline code"),
        arrow("catalogue", "later", ~label="soft"),
        arrow("catalogue", "stop", ~label="hard", ~highlighted=true),
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
    hook: "Visa and Mastercard set caps",
    icon: "nd-payment-terminal",
    idea: "Card networks cap how often one card may be retried each day.",
    flow: {
      nodes: [
        revRec("want", "Wants to retry", ~col=0.0),
        revRec("cap", "Under the cap? (day, month)", ~col=1.0, ~highlighted=true),
        processor("retry", "Retries", ~col=2.0, ~row=-0.6),
        revRec("wait", "Waits for the window", ~col=2.0, ~row=0.6),
      ],
      edges: [
        arrow("want", "cap", ~label="count"),
        arrow("cap", "retry", ~label="yes"),
        arrow("cap", "wait", ~label="no", ~highlighted=true),
      ],
    },
    number: Fixed("20", "Visa retries per card a day; Mastercard allows 10"),
    checks: (
      {
        question: "Who sets the cap on retries per card?",
        choices: ["The merchant", "Stripe", "The card networks, Visa and Mastercard"],
        answer: 2,
      },
      {
        question: "The cap is reached. Rev Rec…",
        choices: ["Waits until the window resets", "Switches card", "Gives up"],
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
    idea: "With smart retries, Rev Rec works on one invoice per customer at a time.",
    flow: {
      nodes: [
        customer("open", "2 open invoices", ~col=0.0),
        revRec("first", "Works on invoice 1", ~col=1.0, ~highlighted=true),
        processor("recovered", "Invoice 1 recovered", ~col=2.0),
        revRec("next", "Starts invoice 2", ~col=3.0),
      ],
      edges: [
        arrow("open", "first", ~label="queues"),
        arrow("first", "recovered", ~label="retry"),
        arrow("recovered", "next", ~label="next", ~highlighted=true),
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
          "Spend the retry budget wisely and avoid fraud flags",
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
    idea: "When the customer pays another way, the billing system tells Rev Rec to stop.",
    flow: {
      nodes: [
        customer("pay", "Pays in the app", ~col=0.0),
        billing("report", "Reports the success", ~col=1.0),
        revRec("stop", "Stops retrying", ~col=2.0, ~highlighted=true),
        revRec("closed", "Recovered, paid outside", ~col=3.0),
      ],
      edges: [
        arrow("pay", "report", ~label="payment"),
        arrow("report", "stop", ~label="success", ~highlighted=true),
        arrow("stop", "closed", ~label="closes"),
      ],
    },
    number: Fixed("0", "Retries after the customer pays outside Rev Rec"),
    checks: (
      {
        question: "The customer pays in the app mid-recovery. Rev Rec…",
        choices: ["Stops and marks it paid outside", "Retries anyway", "Refunds"],
        answer: 0,
      },
      {
        question: "Who counts that recovery?",
        choices: ["Rev Rec", "The billing system, not Rev Rec", "Nobody"],
        answer: 1,
      },
    ),
    tryTarget: StoryPreset(1),
  },
  {
    id: 8,
    title: "Record back & webhooks",
    hook: "Telling the billing system",
    icon: "nd-webhook",
    idea: "When an invoice changes, Rev Rec can tell the billing system by webhook.",
    flow: {
      nodes: [
        processor("approved", "Retry approved", ~col=0.0),
        revRec("recovers", "Recovers the invoice", ~col=1.0),
        billing("paid", "Marks it paid", ~col=2.4, ~row=-0.6, ~highlighted=true),
        merchant("updates", "Updates the account", ~col=2.4, ~row=0.6),
      ],
      edges: [
        arrow("approved", "recovers", ~label="approved"),
        arrow("recovers", "paid", ~label="record back", ~highlighted=true),
        arrow("recovers", "updates", ~label="webhook"),
      ],
    },
    number: Fixed("0", "Record backs on this demo's Custom connector; webhooks carry the result"),
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
        question: "Custom billing has no record back. The merchant learns the result from…",
        choices: ["The webhook", "An email", "Nothing"],
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
