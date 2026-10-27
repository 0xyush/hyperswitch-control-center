open SimulatorPortfolioTypes
open LogicUtils

// While a run is active (setting up or running) the screen polls every 2 s: the proxy answers
// from its own memory, and on the fast self-hosted engine a whole run takes about a minute.
// Polling stops when the run ends.
let activePollIntervalMs = 2000

let portfolioPath = RevenueRecoverySidebarValues.simulatorPortfolioPath

// Decline reasons the scripted bank knows (PORTFOLIO.md section 3), in the dial order
let reasons = [
  "insufficient_funds",
  "generic_decline",
  "processing_error",
  "stolen_card",
  "expired_card",
]

let reasonLabel = reason =>
  switch reason {
  | "insufficient_funds" => "Insufficient funds"
  | "generic_decline" => "Generic decline"
  | "processing_error" => "Processing error"
  | "stolen_card" => "Stolen card"
  | "expired_card" => "Expired card"
  | other => other->snakeToTitle
  }

// Hard declines never come back, whatever the bank rule says
let isHardReason = reason => reason == "stolen_card" || reason == "expired_card"

let defaultDials: portfolioDials = {
  invoiceCount: 10,
  amount: "65.40",
  mix: [
    ("insufficient_funds", 4),
    ("generic_decline", 3),
    ("processing_error", 2),
    ("stolen_card", 1),
    ("expired_card", 0),
  ]->Dict.fromArray,
  maxMinutes: 20.0,
}

// The tiles of the form. The limits come from GET /healthz; these are the values when the proxy
// does not report them (10 invoices, stop after 10, 20 or 45 min).
let invoiceCounts = [10, 25]
let defaultLimits: portfolioLimits = {maxInvoices: 10, stopAfterMinutes: [10.0, 20.0, 45.0]}

let limitsMapper = (json): portfolioLimits => {
  let limits = json->getDictFromJsonObject->getDictfromDict("limits")
  let stopAfter =
    limits
    ->getArrayFromDict("portfolioStopAfterMinutes", [])
    ->Array.filterMap(JSON.Decode.float)
    ->Array.filter(minutes => minutes > 0.0)
  {
    maxInvoices: limits->getInt("portfolioMaxInvoices", defaultLimits.maxInvoices),
    stopAfterMinutes: stopAfter->Array.length > 0 ? stopAfter : defaultLimits.stopAfterMinutes,
  }
}

// "30 s" under a minute, "10 min" or "1.5 min" above
let stopAfterLabel = minutes =>
  if minutes < 1.0 {
    `${(minutes *. 60.0)->Math.round->Float.toInt->Int.toString} s`
  } else {
    `${minutes->Float.toString} min`
  }

let mixTotal = (mix: Dict.t<int>) => mix->Dict.valuesToArray->Array.reduce(0, (sum, w) => sum + w)

// The decline mix bar: each reason's share in percent, and the four boundaries between the five
// segments (cumulative percent). A drag moves one boundary in steps of 10%, one invoice in ten.
let mixStep = 10

let mixShares = (mix: Dict.t<int>) => {
  let total = mix->mixTotal
  let cumulative = ref(0)
  let previous = ref(0)
  reasons->Array.map(reason => {
    cumulative := cumulative.contents + mix->Dict.get(reason)->Option.getOr(0)
    let boundary =
      total > 0
        ? (cumulative.contents->Int.toFloat *. 100.0 /. total->Int.toFloat)->Math.round->Float.toInt
        : 0
    let share = boundary - previous.contents
    previous := boundary
    share
  })
}

let mixBoundaries = (mix: Dict.t<int>) => {
  let sum = ref(0)
  mix
  ->mixShares
  ->Array.slice(~start=0, ~end=reasons->Array.length - 1)
  ->Array.map(share => {
    sum := sum.contents + share
    sum.contents
  })
}

// Back from boundaries to weights: the weights are the shares, so they add up to 100
let mixFromBoundaries = (boundaries: array<int>) =>
  reasons
  ->Array.mapWithIndex((reason, index) => {
    let low = index == 0 ? 0 : boundaries->Array.get(index - 1)->Option.getOr(0)
    let high = boundaries->Array.get(index)->Option.getOr(100)
    (reason, high - low)
  })
  ->Dict.fromArray

let reasonColor = reason =>
  switch reason {
  | "insufficient_funds" => "bg-nd_primary_blue-450"
  | "generic_decline" => "bg-nd_green-400"
  | "processing_error" => "bg-nd_yellow-500"
  | "stolen_card" => "bg-nd_red-400"
  | _ => "bg-nd_purple-300"
  }

// POST /sim/portfolio/start body: amount in minor units; zero weights are left out
let startBody = (dials: portfolioDials) => {
  let mix =
    dials.mix
    ->Dict.toArray
    ->Array.filter(((_, weight)) => weight > 0)
    ->Array.map(((reason, weight)) => (reason, weight->JSON.Encode.int))
    ->getJsonFromArrayOfJson
  [
    ("invoices", dials.invoiceCount->JSON.Encode.int),
    ("amount", dials.amount->SimulatorUtils.toMinor->JSON.Encode.int),
    ("mix", mix),
    ("maxMinutes", dials.maxMinutes->JSON.Encode.float),
  ]->getJsonFromArrayOfJson
}

let runStatusMapper = status =>
  switch status {
  | "setting_up" => SettingUp
  | "done" => Done
  | "error" => RunError
  | _ => Running
  }

let isRunOver = status => status == Done || status == RunError

// The run's dials, back in the form's shape (amount in major units)
let dialsMapper = (dict): portfolioDials => {
  invoiceCount: dict->getInt("invoices", defaultDials.invoiceCount),
  amount: dict->getInt("amount", 6540)->SimulatorUtils.toMajorText,
  mix: reasons
  ->Array.map(reason => (reason, dict->getDictfromDict("mix")->getInt(reason, 0)))
  ->Dict.fromArray,
  maxMinutes: dict->getFloat("maxMinutes", defaultDials.maxMinutes),
}

let sideCardMapper = (dict): sideCard => {
  let minutes = dict->getDictfromDict("minutesToRecovery")
  {
    invoices: dict->getInt("invoices", 0),
    recovered: dict->getInt("recovered", 0),
    recoveryRate: dict->getOptionFloat("recoveryRate"),
    recoveredAmount: dict->getInt("recoveredAmount", 0),
    revrecAttempts: dict->getInt("revrecAttempts", 0),
    attemptsPerRecovery: dict->getOptionFloat("attemptsPerRecovery"),
    medianMinutes: minutes->getOptionFloat("median"),
    p90Minutes: minutes->getOptionFloat("p90"),
    terminated: dict->getInt("terminated", 0),
    cancelled: dict->getInt("cancelled", 0),
    openCount: dict->getInt("open", 0),
  }
}

let invoiceCopyMapper = (dict): option<invoiceCopy> =>
  dict->isEmptyDict
    ? None
    : Some({
        storyId: dict->getString("storyId", ""),
        recoveryId: dict->getString("recoveryId", ""),
        status: dict->getString("status", ""),
        revrecAttempts: dict->getInt("revrecAttempts", 0),
        recoveredAt: dict->getOptionString("recoveredAt"),
        error: dict->getString("error", ""),
        setupStage: dict->getOptionString("setupStage"),
      })

let runMapper = (json, ~isFixture): portfolioRun => {
  let dict = json->getDictFromJsonObject
  let profiles = dict->getDictfromDict("profiles")
  let comparison = dict->getDictfromDict("comparison")
  let cards = dict->getDictfromDict("cards")
  let arrayOf = (key, mapper) =>
    dict->getArrayFromDict(key, [])->Array.map(item => item->getDictFromJsonObject->mapper)
  {
    runId: dict->getString("runId", ""),
    seed: dict->getInt("seed", 0),
    status: dict->getString("status", "")->runStatusMapper,
    dials: dict->getDictfromDict("dials")->dialsMapper,
    plannedInvoices: dict->getDictfromDict("dials")->getInt("invoices", 0),
    startedAt: dict->getString("startedAt", ""),
    endReason: dict->getString("endReason", ""),
    error: dict->getString("error", ""),
    staticMode: profiles->getDictfromDict("static")->getString("mode", ""),
    smartMode: profiles->getDictfromDict("smart")->getString("mode", ""),
    staticCard: cards->getDictfromDict("static")->sideCardMapper,
    smartCard: cards->getDictfromDict("smart")->sideCardMapper,
    byReason: arrayOf("byReason", row => {
      reason: row->getString("reason", ""),
      invoices: row->getInt("invoices", 0),
      staticRecovered: row->getDictfromDict("static")->getInt("recovered", 0),
      smartRecovered: row->getDictfromDict("smart")->getInt("recovered", 0),
    }),
    bankRules: arrayOf("bankRules", rule => {
      reason: rule->getString("reason", ""),
      firstChargeCard: rule->getString("firstChargeCard", ""),
      rule: rule->getString("rule", ""),
    }),
    trend: arrayOf("trend", point => {
      minute: point->getFloat("minute", 0.0),
      staticSoFar: point->getFloat("static", 0.0),
      smartSoFar: point->getFloat("smart", 0.0),
    }),
    invoices: arrayOf("invoices", invoice => {
      index: invoice->getInt("i", 0),
      reason: invoice->getString("reason", ""),
      amount: invoice->getInt("amount", 0),
      flipAfterMin: invoice->getDictfromDict("bank")->getOptionFloat("flipAfterMin"),
      staticCopy: invoice->getDictfromDict("static")->invoiceCopyMapper,
      smartCopy: invoice->getDictfromDict("smart")->invoiceCopyMapper,
    }),
    warnings: dict->getStrArrayFromDict("warnings", []),
    sameStrategy: comparison->getBool("sameStrategy", false),
    comparisonLabel: comparison->getString("label", ""),
    isFixture,
  }
}

let formatMoney = minor =>
  `$${(minor->Int.toFloat /. 100.0)->Float.toFixedWithPrecision(~digits=2)}`

// Copies that reached an end state, for the progress bar
let finishedCopies = (card: sideCard) => card.recovered + card.terminated + card.cancelled

// A side with invoices but no Rev Rec attempts booked no retries: at the end of the run, or
// already while running when the other side has attempts
let bookedNoRetries = (run: portfolioRun, ~card: sideCard, ~other: sideCard) =>
  run.status != SettingUp &&
  card.invoices > 0 &&
  card.revrecAttempts == 0 &&
  (run.status->isRunOver || other.revrecAttempts > 0)

// The decider reason applies only to a smart profile
let noRetriesWhy = (~mode) =>
  mode == "smart"
    ? "Smart mode needs a decider service; this sandbox has none yet."
    : "The sandbox booked no retry task for these invoices."

// The proxy sends every copy with a setupStage: "pending" (no story id yet: waiting; with one:
// being charged), "charged" or "reported". Older runs send null for a copy not started yet and
// no stage; then a copy is reported once it has a recovery id.
let copySetupState = (copy: option<invoiceCopy>) =>
  switch copy {
  | None => SetupWaiting
  | Some(copy) if copy.error->isNonEmptyString => SetupFailed
  | Some(copy) =>
    switch copy.setupStage {
    | Some("reported") => SetupReported
    | Some("charged") => SetupCharged
    | Some(_) => copy.storyId->isEmptyString ? SetupWaiting : SetupCreating
    | None => copy.recoveryId->isNonEmptyString ? SetupReported : SetupCreating
    }
  }

let isSetupFinal = state => state == SetupReported || state == SetupFailed

// "40 s" or "2 min 10 s"
let durationText = seconds =>
  seconds < 60
    ? `${seconds->Int.toString} s`
    : `${(seconds / 60)->Int.toString} min ${mod(seconds, 60)->Int.toString} s`

let hasFinishedCopy = (run: portfolioRun) =>
  run.staticCard->finishedCopies + run.smartCard->finishedCopies > 0

let invoiceStatusLabel = (status: string): Table.cell => {
  let color: Table.labelColor = switch status {
  | "recovered" => LabelGreen
  | "terminated" => LabelRed
  | "cancelled" => LabelLightGray
  | "" => LabelLightGray
  | _ => LabelOrange
  }
  Label({title: (status->isEmptyString ? "pending" : status)->String.toUpperCase, color})
}

let staticColor = "#8BA3C7"
let revrecColor = "#006DF9"

// Bar chart: invoices recovered per decline reason, static vs Rev Rec
let reasonChartPayload = (rows: array<reasonRow>): ColumnGraphTypes.columnGraphPayload => {
  let series = (~name, ~color, ~value) => {
    let seriesObj: ColumnGraphTypes.seriesObj = {
      showInLegend: true,
      name,
      colorByPoint: false,
      data: rows->Array.map(row => {
        let point: ColumnGraphTypes.dataObj = {
          name: row.reason->reasonLabel,
          y: row->value->Int.toFloat,
          color,
        }
        point
      }),
      color,
    }
    seriesObj
  }
  {
    title: {text: ""},
    data: [
      series(~name="Static retries", ~color=staticColor, ~value=row => row.staticRecovered),
      series(~name="Rev Rec", ~color=revrecColor, ~value=row => row.smartRecovered),
    ],
    tooltipFormatter: ColumnGraphUtils.columnGraphTooltipFormatter(
      ~title="Invoices recovered",
      ~metricType=Default,
    ),
    yAxisFormatter: ColumnGraphUtils.columnGraphYAxisFormatter(~statType=Default),
  }
}

// Line chart: invoices recovered so far, by minute of the run
let trendChartPayload = (points: array<trendPoint>): LineGraphTypes.lineGraphPayload => {
  {
    chartHeight: Custom(280),
    chartLeftSpacing: DefaultLeftSpacing,
    categories: points->Array.map(point => `${point.minute->Float.toString} min`),
    data: [
      {
        showInLegend: true,
        name: "Static retries",
        data: points->Array.map(point => point.staticSoFar),
        color: staticColor,
      },
      {
        showInLegend: true,
        name: "Rev Rec",
        data: points->Array.map(point => point.smartSoFar),
        color: revrecColor,
      },
    ],
    title: {text: ""},
    yAxisMaxValue: None,
    yAxisMinValue: Some(0),
    tooltipFormatter: InsightsUtils.tooltipFormatter(
      ~secondaryCategories=[],
      ~title="Recovered so far",
      ~metricType=Default,
      ~showNameInTooltip=true,
    ),
    yAxisFormatter: LineGraphUtils.lineGraphYAxisFormatter(~statType=Default),
    legend: {
      useHTML: true,
      labelFormatter: LineGraphUtils.valueFormatter,
      align: "right",
      verticalAlign: "top",
    },
  }
}
