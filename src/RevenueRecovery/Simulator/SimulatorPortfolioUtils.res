open SimulatorPortfolioTypes
open LogicUtils

// A run lasts up to 45 minutes and the proxy refreshes every 30 s, so a 10 s poll is enough
let pollIntervalMs = 10000

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
}

let mixTotal = (mix: Dict.t<int>) => mix->Dict.valuesToArray->Array.reduce(0, (sum, w) => sum + w)

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
      })

let runMapper = (json, ~isFixture): portfolioRun => {
  let dict = json->getDictFromJsonObject
  let profiles = dict->getDictfromDict("profiles")
  let cards = dict->getDictfromDict("cards")
  let arrayOf = (key, mapper) =>
    dict->getArrayFromDict(key, [])->Array.map(item => item->getDictFromJsonObject->mapper)
  {
    runId: dict->getString("runId", ""),
    seed: dict->getInt("seed", 0),
    status: dict->getString("status", "")->runStatusMapper,
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
    isFixture,
  }
}

let formatMoney = minor =>
  `$${(minor->Int.toFloat /. 100.0)->Float.toFixedWithPrecision(~digits=2)}`

// Copies that reached an end state, for the progress bar
let finishedCopies = (card: sideCard) => card.recovered + card.terminated + card.cancelled

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

// FIXTURE, not a sandbox run. Same shape as GET /sim/portfolio/:runId, used only while the
// proxy's portfolio run is off (SIM_PORTFOLIO), so the screen can be reviewed. Made-up numbers.
let fixtureText = `{
  "runId": "pf_fixture",
  "seed": 4242,
  "status": "done",
  "startedAt": "2026-10-23T20:00:00Z",
  "endReason": "every invoice reached an end state",
  "error": null,
  "profiles": {
    "static": {"profileId": "pro_fixture_static", "mode": "cascading"},
    "smart": {"profileId": "pro_fixture_smart", "mode": "smart"}
  },
  "cards": {
    "static": {"invoices": 10, "recovered": 6, "recoveryRate": 0.6, "recoveredAmount": 39240,
      "revrecAttempts": 21, "attemptsPerRecovery": 2.8,
      "minutesToRecovery": {"median": 9.5, "p90": 14.2}, "terminated": 1, "cancelled": 3, "open": 0},
    "smart": {"invoices": 10, "recovered": 8, "recoveryRate": 0.8, "recoveredAmount": 52320,
      "revrecAttempts": 15, "attemptsPerRecovery": 1.6,
      "minutesToRecovery": {"median": 7.1, "p90": 11.8}, "terminated": 1, "cancelled": 1, "open": 0}
  },
  "byReason": [
    {"reason": "insufficient_funds", "invoices": 4, "static": {"recovered": 2}, "smart": {"recovered": 3}},
    {"reason": "generic_decline", "invoices": 3, "static": {"recovered": 2}, "smart": {"recovered": 3}},
    {"reason": "processing_error", "invoices": 2, "static": {"recovered": 2}, "smart": {"recovered": 2}},
    {"reason": "stolen_card", "invoices": 1, "static": {"recovered": 0}, "smart": {"recovered": 0}}
  ],
  "bankRules": [
    {"reason": "insufficient_funds", "firstChargeCard": "9995", "rule": "No money until the payday, 4 to 12 minutes after the first failure."},
    {"reason": "generic_decline", "firstChargeCard": "0002", "rule": "Works again after a quiet window of 2 to 6 minutes."},
    {"reason": "processing_error", "firstChargeCard": "0119", "rule": "A temporary error: works again after 1 minute."},
    {"reason": "stolen_card", "firstChargeCard": "9979", "rule": "Never comes back: a hard decline."}
  ],
  "trend": [
    {"minute": 0, "static": 0, "smart": 0}, {"minute": 2, "static": 0, "smart": 1},
    {"minute": 4, "static": 1, "smart": 2}, {"minute": 6, "static": 2, "smart": 4},
    {"minute": 8, "static": 3, "smart": 5}, {"minute": 10, "static": 4, "smart": 6},
    {"minute": 12, "static": 5, "smart": 7}, {"minute": 14, "static": 5, "smart": 8},
    {"minute": 16, "static": 6, "smart": 8}, {"minute": 18, "static": 6, "smart": 8}
  ],
  "invoices": [
    {"i": 1, "reason": "insufficient_funds", "amount": 6540, "bank": {"flipAfterMin": 5},
      "static": {"storyId": "st_fixture01s", "status": "recovered", "revrecAttempts": 3},
      "smart": {"storyId": "st_fixture01r", "status": "recovered", "revrecAttempts": 2}},
    {"i": 2, "reason": "insufficient_funds", "amount": 6540, "bank": {"flipAfterMin": 9},
      "static": {"storyId": "st_fixture02s", "status": "cancelled", "revrecAttempts": 5},
      "smart": {"storyId": "st_fixture02r", "status": "recovered", "revrecAttempts": 2}},
    {"i": 3, "reason": "insufficient_funds", "amount": 6540, "bank": {"flipAfterMin": 11},
      "static": {"storyId": "st_fixture03s", "status": "cancelled", "revrecAttempts": 5},
      "smart": {"storyId": "st_fixture03r", "status": "cancelled", "revrecAttempts": 3}},
    {"i": 4, "reason": "insufficient_funds", "amount": 6540, "bank": {"flipAfterMin": 4},
      "static": {"storyId": "st_fixture04s", "status": "recovered", "revrecAttempts": 2},
      "smart": {"storyId": "st_fixture04r", "status": "recovered", "revrecAttempts": 1}},
    {"i": 5, "reason": "generic_decline", "amount": 6540, "bank": {"flipAfterMin": 3},
      "static": {"storyId": "st_fixture05s", "status": "recovered", "revrecAttempts": 2},
      "smart": {"storyId": "st_fixture05r", "status": "recovered", "revrecAttempts": 1}},
    {"i": 6, "reason": "generic_decline", "amount": 6540, "bank": {"flipAfterMin": 6},
      "static": {"storyId": "st_fixture06s", "status": "cancelled", "revrecAttempts": 4},
      "smart": {"storyId": "st_fixture06r", "status": "recovered", "revrecAttempts": 2}},
    {"i": 7, "reason": "generic_decline", "amount": 6540, "bank": {"flipAfterMin": 2},
      "static": {"storyId": "st_fixture07s", "status": "recovered", "revrecAttempts": 1},
      "smart": {"storyId": "st_fixture07r", "status": "recovered", "revrecAttempts": 1}},
    {"i": 8, "reason": "processing_error", "amount": 6540, "bank": {"flipAfterMin": 1},
      "static": {"storyId": "st_fixture08s", "status": "recovered", "revrecAttempts": 1},
      "smart": {"storyId": "st_fixture08r", "status": "recovered", "revrecAttempts": 1}},
    {"i": 9, "reason": "processing_error", "amount": 6540, "bank": {"flipAfterMin": 1},
      "static": {"storyId": "st_fixture09s", "status": "recovered", "revrecAttempts": 2},
      "smart": {"storyId": "st_fixture09r", "status": "recovered", "revrecAttempts": 1}},
    {"i": 10, "reason": "stolen_card", "amount": 6540, "bank": {"flipAfterMin": null},
      "static": {"storyId": "st_fixture10s", "status": "terminated", "revrecAttempts": 0},
      "smart": {"storyId": "st_fixture10r", "status": "terminated", "revrecAttempts": 0}}
  ],
  "warnings": []
}`

let fixtureRun = () => fixtureText->JSON.parseExn->runMapper(~isFixture=true)
