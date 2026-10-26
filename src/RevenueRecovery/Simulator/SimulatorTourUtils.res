// Feature tour (PRD section 9): one panel per Rev Rec feature, each tagged
// Live, Read-only or Display only. Live and Read-only panels show real values from the sandbox.
open SimulatorTypes
open LogicUtils

let tagLabel = tag =>
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

let configLabel = key =>
  switch key {
  | StartRule => "Start rule"
  | MaxRetries => "Max retries"
  | GracePeriod => "Grace period"
  | RetryMode => "Retry mode"
  | PartialAuth => "Partial authorization"
  }

let retryModeText = mode =>
  switch mode {
  | "cascading" => "Static retries (cascading)"
  | "smart" => "Smart retries"
  | "monitoring" => "Monitoring"
  | other => other
  }

// The current value of a setting, in plain words
let configValueText = (config: revRecConfig, key) => {
  let notSet = "Not set"
  switch key {
  | StartRule =>
    config.startRule->Option.mapOr(notSet, rule =>
      rule == 0
        ? "0: Rev Rec takes over on the first failure"
        : `${rule->Int.toString}: Rev Rec takes over after more than ${rule->Int.toString} failures`
    )
  | MaxRetries => config.maxRetries->Option.mapOr(notSet, Int.toString)
  | GracePeriod =>
    config.gracePeriodDays->Option.mapOr(notSet, days => `${days->Int.toString} days`)
  | RetryMode => config.retryMode->Option.mapOr(notSet, retryModeText)
  | PartialAuth => config.partialAuth->Option.mapOr(notSet, isOn => isOn ? "On" : "Off")
  }
}

// Start rule, max retries, grace period and partial authorization live on the billing connector;
// the retry mode lives on the profile
let getRevRecConfig = (~billingConnector: Dict.t<JSON.t>, ~profile: Dict.t<JSON.t>) => {
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

let liveFeatures: array<feature> = [
  {
    title: "Monitoring vs retry mode",
    tag: ReadOnly,
    description: "Rev Rec can only watch an invoice (monitoring: it records failures but does not retry), or take over and retry it. This shows the mode of the demo profile.",
    facts: [Config(RetryMode)],
    preset: None,
  },
  {
    title: "Start rule (retry after N failures)",
    tag: Live,
    description: "How many failures the billing system may report before Rev Rec takes over. Rev Rec starts after more than N failures, so with 0 it starts on the first one.",
    facts: [Config(StartRule)],
    preset: Some(1),
  },
  {
    title: "Max retries and grace period",
    tag: LiveToConfirm,
    description: "Max retries caps how often Rev Rec retries one invoice. The grace period is the window in which it may retry. Whether the engine enforces both today is still to confirm.",
    facts: [Config(MaxRetries), Config(GracePeriod)],
    preset: None,
  },
  {
    title: "Hard-decline stop",
    tag: ReadOnly,
    description: "A hard decline, for example a stolen card, should stop Rev Rec at once. The engine knows a decline is hard from the error catalogue. The stolen-card preset shows it once the sandbox has a matching row.",
    facts: [Fact("Retries for hard declines", "0 (fixed in the dashboard)", Rule)],
    preset: Some(7),
  },
  {
    title: "Card network limits",
    tag: ReadOnly,
    description: "Card networks cap how often a merchant may retry one card. When the cap is reached, Rev Rec goes quiet and waits. The values are still to confirm.",
    facts: [
      Fact("Visa", "20 a day, 20 in 30 days", Rule),
      Fact("Mastercard", "10 a day, 35 in 30 days", Rule),
      Fact("Amex and Discover", "20 a day, 20 in 30 days", Rule),
    ],
    preset: Some(5),
  },
  {
    title: "Static vs smart retries",
    tag: Live,
    description: "Static retries use a fixed ladder of retry times. Smart retries pick the day and hour per invoice. In the simulator, this picks which demo profile the story uses.",
    facts: [Config(RetryMode)],
    preset: None,
    // The tour reads the static demo profile, so the note says why a smart profile books no retries
    note: `${SimulatorUtils.smartDeciderNote} So no retries are booked on a smart profile.`,
  },
  {
    title: "Webhooks to the billing system",
    tag: ReadOnly,
    description: "Rev Rec can tell the billing system when an invoice changes, for example when it is paid. The sandbox has sent none so far, so the story reads the status instead.",
    facts: [],
    preset: None,
  },
  {
    title: "Invoice queuing (one invoice per customer)",
    tag: LiveSmartOnly,
    description: "With smart retries, Rev Rec works on one invoice per customer at a time. A second invoice for the same customer waits for the first.",
    facts: [],
    preset: Some(8),
  },
  {
    title: "Two strategies side by side",
    tag: Live,
    description: "Rev Rec has no built-in A/B test. The portfolio run, coming in a later version, gets the same effect: one batch of invoices runs on a static profile and on a smart profile.",
    facts: [],
    preset: None,
  },
]

let displayOnlyFeatures: array<feature> = [
  {
    title: "Record back to billing platform",
    tag: DisplayOnly,
    description: "When Rev Rec recovers an invoice, it can mark it paid in Chargebee, Recurly or Stripe Billing. The demo uses a Custom billing connector, which has no record back.",
    facts: [],
    preset: None,
  },
  {
    title: "Multi-card recovery",
    tag: DisplayOnly,
    description: "If a customer has more than one saved card, Rev Rec can try another card when the first one keeps failing.",
    facts: [],
    preset: None,
  },
  {
    title: "Account updater",
    tag: DisplayOnly,
    description: "When a card is replaced (expired, lost or stolen), the card network can supply the new details, so the next retry uses the new card.",
    facts: [],
    preset: None,
  },
  {
    title: "Partial auth recovery",
    tag: DisplayOnly,
    description: "If the bank approves only part of the amount, Rev Rec can collect the rest in later attempts.",
    facts: [Config(PartialAuth)],
    preset: None,
  },
  {
    title: "Dunning emails",
    tag: DisplayOnly,
    description: "Reminder emails to the customer about a failed payment. The simulator explains them but sends none.",
    facts: [],
    preset: None,
  },
  {
    title: "Integration models",
    tag: DisplayOnly,
    description: "Model 1: Rev Rec retries by itself; this is what the demo runs. Models 2 and 3: Rev Rec only sends signals, such as the best retry time, and the billing system retries.",
    facts: [],
    preset: None,
  },
  {
    title: "Which processor to retry on",
    tag: DisplayOnly,
    description: "Today Rev Rec retries on the same processor. A later option is to pick the processor with the best success rate.",
    facts: [],
    preset: None,
  },
]
