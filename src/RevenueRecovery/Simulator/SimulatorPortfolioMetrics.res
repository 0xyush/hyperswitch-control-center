// The team's four system metrics, smart retries against today's fixed retries, from the run's own
// numbers, as one row of compact tiles: recovery uplift (recovered of all failed invoices), attempts
// per recovered invoice (TP50 / TP90), time to recover (median, recovered invoices) and the dispute
// rate (not measured: test mode has no disputes). Then "The math" as charts: recovered of N (and
// within the first 5 retries), declined charges, and the money line. Every long sentence sits
// behind a "?". A small batch is an example, not a forecast.
open SimulatorPortfolioTypes
open Typography

// Below this many invoices the numbers are an example
let forecastSize = 100

// Smart in our blue, fixed in grey: the pick charts' colours
let smartColor = SimulatorPickCharts.blue
let fixedColor = SimulatorPickCharts.grey
let ink = SimulatorPickCharts.ink

// Nearest rank, as the proxy's quantile: the smallest value with at least q of the values at or
// below it
let quantile = (values: array<float>, q) => {
  let sorted = values->Array.copy
  sorted->Array.sort(Float.compare)
  let n = sorted->Array.length
  n == 0
    ? None
    : sorted->Array.get(
        Math.Int.max(0, Math.Int.min(n - 1, Math.ceil(q *. Int.toFloat(n))->Float.toInt - 1)),
      )
}

// The copies of one side that exist (a copy that could not be created has none)
let copiesOf = (run: portfolioRun, ~isSmart) =>
  run.invoices
  ->Array.filterMap(invoice => isSmart ? invoice.smartCopy : invoice.staticCopy)
  ->Array.filter(copy => copy.error == "")

// Rev Rec's tries on each recovered copy: the retries until the money came back
let recoveredAttempts = (run: portfolioRun, ~isSmart) =>
  run
  ->copiesOf(~isSmart)
  ->Array.filter(copy => copy.status == "recovered")
  ->Array.map(copy => copy.revrecAttempts->Int.toFloat)

// Recovered within the first 5 retries: the same retry budget on both sides
let withinFive = (run: portfolioRun, ~isSmart) =>
  run
  ->copiesOf(~isSmart)
  ->Array.filter(copy => copy.status == "recovered" && copy.revrecAttempts <= 5)
  ->Array.length

// Rev Rec's retries the bank declined: every retry but the one that recovered
let declined = (card: sideCard) => Math.Int.max(0, card.revrecAttempts - card.recovered)

let countText = value => value->Option.mapOr("–", v => v->Float.toInt->Int.toString)

// A recovery within the first real-life hours shows as "<0.1"
let daysText = value =>
  value->Option.mapOr("–", v => v < 0.05 ? "<0.1" : v->Float.toFixedWithPrecision(~digits=1))

// $1,234.50 from minor units
let money = minor => {
  let cents = Math.Int.abs(mod(minor, 100))
  `$${(minor / 100)->Math.Int.abs->Int.toLocaleString}.${cents < 10
      ? "0"
      : ""}${cents->Int.toString}`
}

let plural = (n, word) => `${n->Int.toString} ${word}${n == 1 ? "" : "s"}`

// "Smart recovered $240.00 more from the same 10 invoices · 57 declined charges avoided"
let roiText = (run: portfolioRun, ~invoices) => {
  let extra = run.smartCard.recoveredAmount - run.staticCard.recoveredAmount
  let same = `the same ${plural(invoices, "invoice")}`
  let avoided = run.staticCard->declined - run.smartCard->declined
  let moneyPart =
    extra == 0
      ? `Both recovered the same amount from ${same}`
      : `Smart recovered ${extra->money} ${extra > 0 ? "more" : "less"} from ${same}`
  let declinedPart =
    avoided >= 0
      ? `${plural(avoided, "declined charge")} avoided`
      : `${plural(-avoided, "more declined charge")} on smart`
  `${moneyPart} · ${declinedPart}`
}

// A "?" with the long words behind it
let why = description =>
  <ToolTip
    description
    toolTipPosition=ToolTip.Top
    toolTipFor={<span
      className={`inline-flex h-4 w-4 shrink-0 items-center justify-center rounded-full border cursor-help bg-nd_gray-50 text-nd_gray-600 border-nd_gray-200 ${body.xs.semibold}`}>
      {"?"->React.string}
    </span>}
  />

// One compact tile: the number first, an optional short line, the label with its "?" at the bottom
module Tile = {
  @react.component
  let make = (
    ~value,
    ~valueClass="text-nd_gray-800",
    ~isPair=false,
    ~sub="",
    ~label,
    ~description,
  ) =>
    <div
      className="bg-white border border-nd_gray-200 rounded-xl px-4 py-3 flex flex-col gap-1 min-w-0">
      // A smart · fixed pair takes a size smaller, so it fits on one line
      <span
        className={`truncate leading-8 ${isPair
            ? body.lg.semibold
            : heading.sm.semibold} ${valueClass}`}
        title=value>
        {value->React.string}
      </span>
      <RenderIf condition={sub != ""}>
        <span className={`truncate ${body.sm.medium} text-nd_gray-500`}> {sub->React.string} </span>
      </RenderIf>
      <span className={`mt-auto pt-1 flex items-center gap-1.5 ${body.sm.medium} text-nd_gray-600`}>
        <span className="truncate"> {label->React.string} </span>
        {why(description)}
      </span>
    </div>
}

let baseOptions = (~kind, ~height) =>
  {
    "type": kind,
    "height": height,
    "backgroundColor": "transparent",
    "spacing": [8, 4, 4, 4],
    "style": {"fontFamily": "inherit"},
  }

let axisLabels = {"style": {"color": ink, "fontSize": "12px"}}
let dataLabels = {
  "enabled": true,
  "style": {"color": "#344054", "fontSize": "12px", "fontWeight": "600", "textOutline": "none"},
}

let tooltip = pointFormat =>
  {
    "backgroundColor": "#FFFFFF",
    "borderColor": "#E4E7EC",
    "borderRadius": 8,
    "shadow": false,
    "style": {"color": "#344054", "fontSize": "12px"},
    "pointFormat": pointFormat,
  }

// Recovered of N and within the first 5 retries, smart beside fixed
let recoveredOptions = (run: portfolioRun, ~invoices) =>
  {
    "chart": baseOptions(~kind="column", ~height=220),
    "title": {"text": Nullable.null},
    "credits": {"enabled": false},
    "accessibility": {"enabled": false},
    "legend": {
      "enabled": true,
      "align": "left",
      "verticalAlign": "top",
      "itemStyle": {"color": ink, "fontSize": "12px", "fontWeight": "500"},
    },
    "xAxis": {
      "categories": ["Recovered", "Within the first 5 retries"],
      "lineColor": "#D0D5DD",
      "tickLength": 0,
      "labels": axisLabels,
    },
    "yAxis": {
      "min": 0,
      "max": invoices,
      "title": {"text": Nullable.null},
      "labels": {"enabled": false},
      "gridLineWidth": 0,
    },
    "tooltip": tooltip(`{series.name}: {point.y} of ${invoices->Int.toString}`),
    "plotOptions": {
      "column": {
        "borderWidth": 0,
        "borderRadius": 3,
        "pointPadding": 0.06,
        "groupPadding": 0.22,
        "maxPointWidth": 56,
        "dataLabels": dataLabels,
        "states": {"inactive": {"enabled": false}},
      },
    },
    "series": [
      {
        "name": "Smart retries",
        "color": smartColor,
        "data": [run.smartCard.recovered, run->withinFive(~isSmart=true)],
      },
      {
        "name": SimulatorPortfolioUtils.baselineName,
        "color": fixedColor,
        "data": [run.staticCard.recovered, run->withinFive(~isSmart=false)],
      },
    ],
  }->Identity.genericObjectOrRecordToJson

// Declined charges on the customers' cards: fixed against smart
let declinedOptions = (run: portfolioRun) =>
  {
    "chart": baseOptions(~kind="bar", ~height=150),
    "title": {"text": Nullable.null},
    "credits": {"enabled": false},
    "accessibility": {"enabled": false},
    "legend": {"enabled": false},
    "xAxis": {
      "categories": [SimulatorPortfolioUtils.baselineName, "Smart retries"],
      "lineColor": "#D0D5DD",
      "tickLength": 0,
      "labels": axisLabels,
    },
    "yAxis": {
      "min": 0,
      "title": {"text": Nullable.null},
      "labels": {"enabled": false},
      "gridLineWidth": 0,
    },
    "tooltip": tooltip("{point.y} declined charges"),
    "plotOptions": {
      "bar": {
        "borderWidth": 0,
        "borderRadius": 3,
        "pointPadding": 0.1,
        "groupPadding": 0.1,
        "maxPointWidth": 32,
        "dataLabels": dataLabels,
        "states": {"inactive": {"enabled": false}},
      },
    },
    "series": [
      {
        "name": "Declined charges",
        "data": [
          {"y": run.staticCard->declined, "color": fixedColor},
          {"y": run.smartCard->declined, "color": smartColor},
        ],
      },
    ],
  }->Identity.genericObjectOrRecordToJson

let chart = (~title, ~options) =>
  <div className="flex flex-col gap-1 min-w-0">
    <span className={`${body.sm.semibold} text-nd_gray-600`}> {title->React.string} </span>
    <HighchartsHorizontalBarChart.Chart
      highcharts=HighchartsHorizontalBarChart.highchartsModule options
    />
  </div>

@react.component
let make = (~run: portfolioRun) => {
  let invoices = Math.Int.max(run.staticCard.invoices, run.smartCard.invoices)
  let share = SimulatorPortfolioUtils.recoveryShare
  let rate = value =>
    value->Option.mapOr("–", v => `${(v *. 100.0)->Math.round->Float.toString}%`)
  let points = switch (run.smartCard->share, run.staticCard->share) {
  | (Some(smart), Some(fixed)) => Some(((smart -. fixed) *. 100.0)->Math.round->Float.toInt)
  | _ => None
  }
  let attempts = (~isSmart) => {
    let values = run->recoveredAttempts(~isSmart)
    `${values->quantile(0.5)->countText} / ${values->quantile(0.9)->countText}`
  }
  // Real-life days on the simulated calendar; without it, demo minutes
  let inDays = run.staticCard.medianDays->Option.isSome || run.smartCard.medianDays->Option.isSome
  let unit = inDays ? "d" : "min"
  let median = (card: sideCard) => inDays ? card.medianDays : card.medianMinutes
  // Like for like: the invoices both sides recovered, each side's median real-life days on them
  let bothRecovered = run.invoices->Array.filterMap(invoice =>
    switch (invoice.smartCopy, invoice.staticCopy) {
    | (
        Some({status: "recovered", realDays: Some(smart)}),
        Some({status: "recovered", realDays: Some(fixed)}),
      ) =>
      Some((smart, fixed))
    | _ => None
    }
  )
  let sameInvoices = switch bothRecovered->Array.length {
  | 0 => "No invoice was recovered on both sides."
  | n =>
    `On the ${plural(n, "invoice")} both recovered: smart ${bothRecovered
      ->Array.map(((smart, _)) => smart)
      ->quantile(0.5)
      ->daysText} d vs fixed ${bothRecovered
      ->Array.map(((_, fixed)) => fixed)
      ->quantile(0.5)
      ->daysText} d.`
  }
  let stillTrying = run.smartCard.stillTrying + run.staticCard.stillTrying
  let stillTryingWords =
    stillTrying > 0
      ? ` Still trying at the end: ${run.smartCard.stillTrying->Int.toString} on smart, ${run.staticCard.stillTrying->Int.toString} on fixed; they count as not recovered.`
      : ""

  <AddDataAttributes attributes=[("data-sim", "portfolio-metrics")]>
    <div className="flex flex-col gap-6">
      <div className="grid grid-cols-2 xl:grid-cols-4 gap-4">
        <Tile
          value={points->Option.mapOr("–", p => `${p > 0 ? "+" : ""}${p->Int.toString} pts`)}
          valueClass={switch points {
          | Some(p) if p > 0 => "text-nd_green-600"
          | Some(p) if p < 0 => "text-nd_red-600"
          | _ => "text-nd_gray-800"
          }}
          sub={`Smart ${run.smartCard->share->rate} · Fixed ${run.staticCard->share->rate}`}
          label="Recovery uplift"
          description={`Recovered ÷ all failed invoices, the same on both sides: smart ${run.smartCard.recovered->Int.toString} of ${run.smartCard.invoices->Int.toString}, fixed ${run.staticCard.recovered->Int.toString} of ${run.staticCard.invoices->Int.toString}.${stillTryingWords}`}
        />
        <Tile
          value={`Smart ${attempts(~isSmart=true)} · Fixed ${attempts(~isSmart=false)}`}
          isPair=true
          sub="TP50 / TP90"
          label="Attempts per recovered invoice"
          description="Retries until the money came back, recovered invoices only. TP50: half took this many or fewer. TP90: 9 in 10 did."
        />
        <Tile
          value={`Smart ${run.smartCard->median->daysText} ${unit} · Fixed ${run.staticCard
            ->median
            ->daysText} ${unit}`}
          isPair=true
          sub={inDays ? "Real-life days" : "Demo minutes"}
          label="Time to recover (median)"
          description={`Recovered invoices only.${inDays
              ? ` ${sameInvoices} Rev Rec's model never retries on the day of the failure; the fixed timetable's first retry comes 1 minute later and catches short bank hiccups.`
              : ""}`}
        />
        <Tile
          value="Not measured"
          valueClass="text-nd_gray-500"
          sub="In this demo"
          label="Dispute rate"
          description="Disputes on recovered invoices ÷ invoices recovered. Test mode has no disputes, so this demo cannot measure it."
        />
      </div>
      <div className="bg-white border border-nd_gray-200 rounded-xl p-5 flex flex-col gap-4">
        <div className="flex flex-col gap-1">
          <p className={`${body.md.semibold} text-nd_gray-600`}> {"The math"->React.string} </p>
          <p className={`${heading.sm.semibold} text-nd_gray-800`}>
            {run->roiText(~invoices)->React.string}
          </p>
        </div>
        <div className="grid grid-cols-1 xl:grid-cols-2 gap-6">
          {chart(
            ~title=`Recovered of ${invoices->Int.toString}`,
            ~options=run->recoveredOptions(~invoices),
          )}
          {chart(~title="Declined charges", ~options=run->declinedOptions)}
        </div>
        <div className={`flex flex-wrap items-center gap-2 ${body.xs.medium} text-nd_gray-500`}>
          <RenderIf condition={invoices < forecastSize}>
            <span
              className={`rounded px-1.5 py-0.5 border whitespace-nowrap bg-nd_gray-50 text-nd_gray-600 border-nd_gray-200 ${body.xs.semibold}`}>
              {`${invoices->Int.toString} invoices: an example, not a forecast`->React.string}
            </span>
          </RenderIf>
          <span> {"How these are counted"->React.string} </span>
          {why(
            `Recovery rate: recovered ÷ all failed invoices. Declined charges: Rev Rec's retries the bank declined, every invoice (every retry but the one that recovered).${stillTrying > 0
                ? " Invoices still trying can add more."
                : ""}`,
          )}
        </div>
      </div>
    </div>
  </AddDataAttributes>
}
