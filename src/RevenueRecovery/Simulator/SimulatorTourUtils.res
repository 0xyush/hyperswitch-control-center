// Learn Rev Rec (UX-PASS-2 section B, PRD section 9): eight levels, one per Rev Rec feature.
// Pane 2 of a level shows the real setting from the sandbox when there is one.
open SimulatorTourTypes
open LogicUtils

let tagLabel = (tag: SimulatorTypes.featureTag) =>
  switch tag {
  | Live => ("Live", "bg-nd_green-50 text-nd_green-600 border-nd_green-200")
  | LiveToConfirm => (
      "Live · enforcement to confirm",
      "bg-nd_green-50 text-nd_green-600 border-nd_green-200",
    )
  | LiveSmartOnly => (
      "Live · smart profile only",
      "bg-nd_green-50 text-nd_green-600 border-nd_green-200",
    )
  | ReadOnly => (
      "Read-only",
      "bg-nd_primary_blue-50 text-nd_primary_blue-600 border-nd_primary_blue-200",
    )
  | DisplayOnly => ("Display only", "bg-nd_gray-50 text-nd_gray-600 border-nd_gray-200")
  }

let retryModeText = mode =>
  switch mode {
  | "cascading" => "Static retries (cascading)"
  | "smart" => "Smart retries"
  | "monitoring" => "Monitoring"
  | other => other
  }

// A setting as one big value and a short caption, for pane 2
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

// Progress: the ids of the levels answered right, kept in this browser only
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

let levels: array<level> = [
  {
    id: 1,
    title: "The start rule",
    hook: "When Rev Rec takes over",
    icon: "nd-flag",
    idea: "The start rule says how many failures the billing system handles before Rev Rec.",
    values: [Setting(StartRule)],
    tag: Live,
    check: {
      question: "With start rule 0, when does Rev Rec take over?",
      choices: ["After the first failure", "After three failures", "Never"],
      answer: 0,
    },
    tryTarget: StoryPreset(2),
  },
  {
    id: 2,
    title: "Static vs smart retries",
    hook: "A fixed ladder or the best hour",
    icon: "nd-swap-arrow-horizontal",
    idea: "Static retries follow a fixed schedule; smart retries pick the best time per invoice.",
    values: [Setting(RetryMode)],
    tag: Live,
    note: "The sandbox has no smart decider yet, so smart books no retries.",
    check: {
      question: "Which mode picks the retry time for each invoice?",
      choices: ["Static retries", "Smart retries", "Monitoring"],
      answer: 1,
    },
    tryTarget: PortfolioRun,
  },
  {
    id: 3,
    title: "Max retries & grace period",
    hook: "How long Rev Rec keeps trying",
    icon: "nd-hour-glass-outline",
    idea: "Max retries caps the tries per invoice; the grace period caps the days.",
    values: [Setting(MaxRetries), Setting(GracePeriod)],
    tag: Live,
    note: "Max retries is enforced on the sandbox; grace period is still to confirm.",
    check: {
      question: "Rev Rec reached max retries. What happens next?",
      choices: ["It retries once more", "It switches to smart mode", "It stops retrying"],
      answer: 2,
    },
    tryTarget: StoryPreset(4),
  },
  {
    id: 4,
    title: "Hard declines",
    hook: "When retrying is pointless",
    icon: "nd-shield",
    idea: "A hard decline, like a stolen card, never works, so Rev Rec stops.",
    values: [Fixed({value: "0", caption: "Retries after a hard decline", source: Rule})],
    tag: ReadOnly,
    note: "On 23 Oct the sandbox still retried a stolen card (ask 7).",
    check: {
      question: "A charge fails as a stolen card. How often does Rev Rec retry?",
      choices: ["Until max retries", "Never", "Once a day"],
      answer: 1,
    },
    tryTarget: StoryPreset(7),
  },
  {
    id: 5,
    title: "Card network limits",
    hook: "Visa and Mastercard set caps",
    icon: "nd-payment-terminal",
    idea: "Card networks cap how often one card may be retried each day.",
    values: [
      Fixed({value: "20", caption: "Visa retries per card a day", source: Rule}),
      Fixed({value: "10", caption: "Mastercard retries per card a day", source: Rule}),
    ],
    tag: ReadOnly,
    note: "The limits are still to confirm.",
    check: {
      question: "Visa's daily cap is reached. What does Rev Rec do?",
      choices: ["Goes quiet and waits", "Tries another network", "Cancels the invoice"],
      answer: 0,
    },
    tryTarget: StoryPreset(5),
  },
  {
    id: 6,
    title: "Invoice queuing",
    hook: "One invoice per customer",
    icon: "nd-payment-queued",
    idea: "With smart retries, Rev Rec works on one invoice per customer at a time.",
    values: [Fixed({value: "1", caption: "Invoice per customer at a time", source: Rule})],
    tag: LiveSmartOnly,
    note: "Needs smart retries, which the sandbox cannot run yet.",
    check: {
      question: "One customer has two failed invoices. What does smart Rev Rec do?",
      choices: ["Retries both at once", "Cancels the second", "Works on one at a time"],
      answer: 2,
    },
    tryTarget: StoryPreset(8),
  },
  {
    id: 7,
    title: "Paid outside Rev Rec",
    hook: "The customer paid another way",
    icon: "nd-wallet",
    idea: "When the customer pays another way, the billing system tells Rev Rec to stop.",
    values: [Fixed({value: "0", caption: "Retries after the customer pays", source: Rule})],
    tag: Live,
    check: {
      question: "The customer pays in the app. What does Rev Rec do?",
      choices: ["Stops retrying", "Charges the card again", "Refunds the payment"],
      answer: 0,
    },
    tryTarget: StoryPreset(1),
  },
  {
    id: 8,
    title: "Record back & webhooks",
    hook: "Telling the billing system",
    icon: "nd-webhook",
    idea: "When an invoice changes, Rev Rec can tell the billing system by webhook.",
    values: [Fixed({value: "0", caption: "Webhooks the sandbox sent so far", source: Rule})],
    tag: ReadOnly,
    note: "The demo's Custom billing connector has no record back.",
    check: {
      question: "Rev Rec recovers an invoice. Who should hear about it?",
      choices: ["The card network", "The billing system", "Nobody"],
      answer: 1,
    },
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
