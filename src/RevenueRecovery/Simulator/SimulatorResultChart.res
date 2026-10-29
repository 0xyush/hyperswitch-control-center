// "The math" as a chart (28 Oct), for the result card of stories 11-20, story 2 and a story with
// "Money is back": the fixed timetable's tries
// and Rev Rec's retries on one real-life time axis, from the first failure to the recovery, with
// the moment the money came back. Above it, each side's declined charges; under it, a legend and the
// math lines as a footnote. Data: the view's bank (A's failureAt, worksFromAt, worksFromLabel,
// fixedTimetable.timeline and stopsAfter, revRec.timeline). Mounted by B in the result card.
open LogicUtils
open Typography

type result = Declined | Recovered | Pending
// One try on a lane: its number, real-life time (ms) and label ("Thu 2:57 PM", UTC)
type mark = {n: int, at: float, label: string, result: result}
type data = {
  failureAt: float,
  moneyBackAt: float,
  moneyBackLabel: string,
  // The line's name: "Money came back", or "Card works again" (story 2: from the failure on)
  moneyBackName: string,
  fixed: array<mark>,
  // The fixed timetable's last try when it stops before the money is back (too late)
  fixedStopsAfter: option<int>,
  revRec: array<mark>,
}

let timeOf = iso => iso->Date.fromString->Date.getTime

let markOf = json => {
  let d = json->getDictFromJsonObject
  let at = d->getString("at", "")->timeOf
  at->Float.isNaN
    ? None
    : Some({
        n: d->getInt("n", 0),
        at,
        label: d->getString("label", ""),
        result: switch d->getString("result", "") {
        | "recovered" => Recovered
        | "declined" => Declined
        | _ => Pending
        },
      })
}

// The chart's data from the view's bank dict; None for an older story without the lanes
let fromBank = (bank: Dict.t<JSON.t>) => {
  let fixed = bank->getDictfromDict("fixedTimetable")
  let lane = dict => dict->getArrayFromDict("timeline", [])->Array.filterMap(markOf)
  let data = {
    failureAt: bank->getString("failureAt", "")->timeOf,
    moneyBackAt: bank->getString("worksFromAt", "")->timeOf,
    moneyBackLabel: bank->getString("worksFromLabel", ""),
    moneyBackName: bank->getString("worksFromName", "Money came back"),
    fixed: fixed->lane,
    fixedStopsAfter: fixed->getOptionInt("stopsAfter"),
    revRec: bank->getDictfromDict("revRec")->lane,
  }
  data.failureAt->Float.isNaN || data.moneyBackAt->Float.isNaN || data.fixed->Array.length == 0
    ? None
    : Some(data)
}

// The pick charts' blue and grey; a red and a green from the design system (nd_red.500,
// nd_green.400). Red against green is 7.8 apart for deuteranopes, so the result also has a shape
// (a circle declines, a diamond recovers) and the recovering mark its own label.
let blue = SimulatorPickCharts.blue
let grey = SimulatorPickCharts.grey
let ink = SimulatorPickCharts.ink
let red = "#DD2B0E"
let green = "#2DA160"

let hour = 3_600_000.0
let day = 24.0 *. hour

// A mark's word under it ("Recovered", "Stops"): under, so it never meets the lane's name above the
// line or the money line's label above the chart
let labelBelow = (~enabled, ~text, ~color, ~align="center") =>
  {
    "enabled": enabled,
    "format": text,
    "align": align,
    "verticalAlign": "top",
    "x": align == "right" ? 6 : 0,
    "y": 7,
    // A light backing, so the word stays clear where it crosses the money line
    "backgroundColor": "rgba(255, 255, 255, 0.85)",
    "borderRadius": 3,
    "padding": 2,
    "crop": false,
    "overflow": "justify",
    "style": {"color": color, "fontSize": "11px", "fontWeight": "600", "textOutline": "none"},
  }

let declinedOf = marks => marks->Array.filter(m => m.result == Declined)->Array.length

// "Try 5 · Thu 2:57 PM · declined (before the money)"
// No side when the card works from the failure on (story 2): every try is after it
let tipOf = (m, ~word, ~moneyBackAt, ~failureAt) => {
  let side =
    moneyBackAt <= failureAt
      ? ""
      : m.at < moneyBackAt
      ? " (before the money)"
      : " (after the money)"
  let what = switch m.result {
  | Declined => `declined${side}`
  | Recovered => `recovered${side}`
  | Pending => "running now"
  }
  `${word} ${m.n->Int.toString} · ${m.label} · ${what}`
}

let point = (m, ~lane, ~laneName, ~word, ~moneyBackAt, ~failureAt) =>
  {
    "x": m.at,
    "y": lane,
    "lane": laneName,
    "tip": m->tipOf(~word, ~moneyBackAt, ~failureAt),
    "color": switch m.result {
    | Declined => red
    | Recovered => green
    | Pending => grey
    },
    "marker": {
      "symbol": m.result == Recovered ? "diamond" : "circle",
      "radius": m.result == Recovered ? 6 : 4,
    },
    "dataLabels": labelBelow(~enabled=m.result == Recovered, ~text="Recovered", ~color="#344054"),
  }->Identity.genericObjectOrRecordToJson

// A lane's line: from the failure to its last try, in the side's colour, its name above its start
let laneLine = (~y: float, ~name, ~from, ~to_, ~color) =>
  {
    "type": "line",
    "data": [
      {
        "x": from,
        "y": y,
        "dataLabels": {
          "enabled": true,
          "format": name,
          "align": "left",
          "verticalAlign": "bottom",
          "x": 0,
          "y": -7,
          "crop": false,
          "overflow": "allow",
          "style": {
            "color": "#344054",
            "fontSize": "12px",
            "fontWeight": "600",
            "textOutline": "none",
          },
        },
      }->Identity.genericObjectOrRecordToJson,
      {"x": to_, "y": y, "dataLabels": {"enabled": false}}->Identity.genericObjectOrRecordToJson,
    ],
    "color": color,
    "lineWidth": 2,
    "marker": {"enabled": false},
    "enableMouseTracking": false,
    "zIndex": 1,
  }->Identity.genericObjectOrRecordToJson

let options = (data, ~stopAt) => {
  let lastOf = marks => marks->Array.reduce(data.failureAt, (m, x) => Math.max(m, x.at))
  let fixedEnd = stopAt->Option.getOr(data.fixed->lastOf)
  let revRecEnd = data.revRec->lastOf
  let latest = Math.max(Math.max(fixedEnd, revRecEnd), data.moneyBackAt)
  let span = Math.max(latest -. data.failureAt, hour)
  // Room after the last mark for its "Recovered" or "Stops" label
  let xMax = latest +. span *. 0.16
  // The money line's label sits on the side with room
  let labelLeft = (data.moneyBackAt -. data.failureAt) /. (xMax -. data.failureAt) > 0.55
  let points = (marks, ~lane, ~laneName, ~word) =>
    marks->Array.map(m =>
      m->point(~lane, ~laneName, ~word, ~moneyBackAt=data.moneyBackAt, ~failureAt=data.failureAt)
    )
  let stops = switch (stopAt, data.fixedStopsAfter) {
  | (Some(at), Some(n)) => [
      {
        "x": at,
        "y": 0,
        "lane": "Fixed timetable",
        "tip": `Stops after try ${n->Int.toString}, before the money is back`,
        "color": grey,
        "marker": {"symbol": "square", "radius": 4},
        "dataLabels": labelBelow(~enabled=true, ~text="Stops", ~color=ink, ~align="right"),
      }->Identity.genericObjectOrRecordToJson,
    ]
  | _ => []
  }
  {
    "chart": {
      "height": 180,
      "backgroundColor": "transparent",
      "spacing": [26, 8, 2, 4],
      "style": {"fontFamily": "inherit"},
    },
    "title": {"text": Nullable.null},
    "credits": {"enabled": false},
    "legend": {"enabled": false},
    "accessibility": {"enabled": false},
    "xAxis": {
      "type": "datetime",
      "min": data.failureAt -. span *. 0.02,
      "max": xMax,
      "lineColor": "#D0D5DD",
      "lineWidth": 1,
      "tickLength": 4,
      "tickColor": "#D0D5DD",
      "startOnTick": false,
      "endOnTick": false,
      // A tick a day when the story spans days; hours otherwise
      "tickInterval": span >= 1.5 *. day ? Nullable.make(day) : Nullable.null,
      "dateTimeLabelFormats": {"hour": "%l %p", "day": "%a", "week": "%a %e"},
      "labels": {"style": {"color": ink, "fontSize": "11px"}},
      "plotBands": [{"from": data.moneyBackAt, "to": xMax, "color": "rgba(45, 161, 96, 0.07)"}],
      "plotLines": [
        {
          "value": data.moneyBackAt,
          "color": green,
          "width": 2,
          "zIndex": 3,
          "label": {
            "text": `${data.moneyBackName} · ${data.moneyBackLabel}`,
            "rotation": 0,
            "align": labelLeft ? "right" : "left",
            "x": labelLeft ? -6 : 6,
            "y": -8,
            "style": {"color": "#344054", "fontSize": "11px", "fontWeight": "600"},
          },
        },
      ],
    },
    "yAxis": {
      // Lane 0 (the fixed timetable) on top; room above it for its name, below lane 1 for a word
      "reversed": true,
      "min": -0.62,
      "max": 1.62,
      "startOnTick": false,
      "endOnTick": false,
      "title": {"text": Nullable.null},
      "gridLineWidth": 0,
      "labels": {"enabled": false},
    },
    "tooltip": {
      "useHTML": true,
      "headerFormat": "",
      "pointFormat": "<div style='font-weight:600;margin-bottom:2px'>{point.lane}</div><div>{point.tip}</div>",
      "backgroundColor": "#FFFFFF",
      "borderColor": "#E4E7EC",
      "borderRadius": 8,
      "shadow": false,
      "padding": 8,
      "style": {"color": "#344054", "fontSize": "12px"},
    },
    "plotOptions": {
      "scatter": {
        "zIndex": 4,
        "marker": {"lineColor": "#FFFFFF", "lineWidth": 1.5},
        "states": {"hover": {"halo": {"size": 6}}, "inactive": {"enabled": false}},
        "stickyTracking": false,
      },
      "series": {"animation": false, "states": {"inactive": {"enabled": false}}},
    },
    "series": [
      laneLine(~y=0.0, ~name="Fixed timetable", ~from=data.failureAt, ~to_=fixedEnd, ~color=grey),
      laneLine(~y=1.0, ~name="Rev Rec", ~from=data.failureAt, ~to_=revRecEnd, ~color=blue),
      {
        "type": "scatter",
        "name": "Fixed timetable",
        "data": data.fixed
        ->points(~lane=0, ~laneName="Fixed timetable", ~word="Try")
        ->Array.concat(stops),
      }->Identity.genericObjectOrRecordToJson,
      {
        "type": "scatter",
        "name": "Rev Rec",
        "data": data.revRec->points(~lane=1, ~laneName="Rev Rec", ~word="Retry"),
      }->Identity.genericObjectOrRecordToJson,
    ],
  }->Identity.genericObjectOrRecordToJson
}

// Declined charges on the customer's card, Rev Rec beside the fixed timetable, on one scale
module DeclinedBars = {
  let bar = (~label, ~count, ~top, ~color) =>
    <div key=label className="flex-1 min-w-0 flex flex-col gap-1">
      <div className="flex items-baseline justify-between gap-2">
        <span className={`${body.sm.medium} text-nd_gray-600 truncate`}>
          {label->React.string}
        </span>
        <span className={`${body.md.semibold} text-nd_gray-800 tabular-nums`}>
          {count->Int.toString->React.string}
        </span>
      </div>
      <div className="h-2 rounded bg-nd_gray-100">
        <div
          className="h-2 rounded"
          style={
            width: `${(count->Int.toFloat /. top->Int.toFloat *. 100.0)->Float.toString}%`,
            backgroundColor: color,
          }
        />
      </div>
    </div>

  @react.component
  let make = (~revRec, ~fixed) => {
    let top = Math.Int.max(1, Math.Int.max(revRec, fixed))
    <AddDataAttributes attributes=[("data-sim", "result-declined")]>
      <div className="flex flex-col gap-2">
        <span className={`${body.sm.semibold} text-nd_gray-600`}>
          {"Declined charges on the customer's card"->React.string}
        </span>
        <div className="flex gap-4">
          {bar(~label="Rev Rec", ~count=revRec, ~top, ~color=blue)}
          {bar(~label="Fixed timetable", ~count=fixed, ~top, ~color=grey)}
        </div>
      </div>
    </AddDataAttributes>
  }
}

module Key = {
  let swatch = (~shape, ~color) =>
    switch shape {
    | #circle =>
      <span className="inline-block w-2.5 h-2.5 rounded-full" style={backgroundColor: color} />
    | #diamond => <span className="inline-block w-2 h-2 rotate-45" style={backgroundColor: color} />
    | #square => <span className="inline-block w-2 h-2" style={backgroundColor: color} />
    | #line => <span className="inline-block w-0.5 h-3" style={backgroundColor: color} />
    }

  @react.component
  let make = (~stops, ~moneyBackName) => {
    let item = (~shape, ~color, ~text) =>
      <span key=text className="inline-flex items-center gap-1.5">
        {swatch(~shape, ~color)}
        {text->React.string}
      </span>
    <div className={`flex flex-wrap gap-x-4 gap-y-1 ${body.sm.medium} text-nd_gray-600`}>
      {item(~shape=#circle, ~color=red, ~text="Declined")}
      {item(~shape=#diamond, ~color=green, ~text="Recovered")}
      {item(~shape=#line, ~color=green, ~text=moneyBackName)}
      {stops ? item(~shape=#square, ~color=grey, ~text="Fixed timetable stops") : React.null}
    </div>
  }
}

// footnote: the math as text lines (B's), small under the chart
@react.component
let make = (~data, ~footnote: array<string>=[]) => {
  // The stop mark sits a little after the fixed timetable's last try
  let stopAt = data.fixedStopsAfter->Option.map(_ => {
    let last = data.fixed->Array.reduce(data.failureAt, (m, x) => Math.max(m, x.at))
    let latest =
      data.revRec->Array.reduce(Math.max(last, data.moneyBackAt), (m, x) => Math.max(m, x.at))
    last +. Math.max(latest -. data.failureAt, hour) *. 0.025
  })
  <AddDataAttributes attributes=[("data-sim", "result-chart")]>
    <div className="flex flex-col gap-3">
      <DeclinedBars revRec={data.revRec->declinedOf} fixed={data.fixed->declinedOf} />
      <div className="min-w-0">
        <HighchartsHorizontalBarChart.Chart
          highcharts=HighchartsHorizontalBarChart.highchartsModule options={data->options(~stopAt)}
        />
      </div>
      <Key stops={stopAt->Option.isSome} moneyBackName=data.moneyBackName />
      <RenderIf condition={footnote->Array.length > 0}>
        <div className="flex flex-col gap-0.5 border-t border-nd_gray-150 pt-2">
          {footnote
          ->Array.mapWithIndex((line, index) =>
            <p key={index->Int.toString} className={`${body.xs.medium} text-nd_gray-500`}>
              {line->React.string}
            </p>
          )
          ->React.array}
        </div>
      </RenderIf>
    </div>
  </AddDataAttributes>
}
