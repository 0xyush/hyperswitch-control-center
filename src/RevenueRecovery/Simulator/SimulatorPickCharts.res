// "Why the smart model picked this time" as charts (28 Oct): the three counts the model reads for the
// retry's decline cluster, each on its own (weekday, day of the month, UTC hour). A bar is the slot's
// success rate; the picked slot is blue; the dashed line is the cluster's average. The counts come
// from GET /sim/story/:id/model (stats, by cluster). Mounted in C's model view.
open LogicUtils
open Typography

type slotCount = {worked: int, tries: int}
type counts = {dow: array<slotCount>, dom: array<slotCount>, hod: array<slotCount>}
// A day the model weighed for the plan (the model view's best days and the picked one)
type planDay = {label: string, by: string, date: string, chance: float}

let slotsOf = (dict, key) =>
  dict
  ->getArrayFromDict(key, [])
  ->Array.map(json => {
    let d = json->getDictFromJsonObject
    {worked: d->getInt("k", 0), tries: d->getInt("n", 0)}
  })

// The counts behind one cluster's decisions, from the model endpoint's answer
let countsOf = (json, ~cluster) => {
  let d = json->getDictFromJsonObject->getDictfromDict("stats")->getDictfromDict(cluster)
  let c = {dow: d->slotsOf("dow"), dom: d->slotsOf("dom"), hod: d->slotsOf("hod")}
  c.dow->Array.length == 7 && c.dom->Array.length == 31 && c.hod->Array.length == 24
    ? Some(c)
    : None
}

let rate = (c: slotCount) => c.tries > 0 ? c.worked->Int.toFloat /. c.tries->Int.toFloat : 0.0
let pct = x => `${(x *. 100.0)->Math.round->Float.toInt->Int.toString}%`

// Our blue for the pick; the grey passes 3:1 on white and stays apart from the blue for
// colour-blind readers (checked with the dataviz palette validator)
let blue = "#0069FD"
let grey = "#8592A2"
let ink = "#667085"

let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

let hourLabel = h =>
  switch h {
  | 0 => "12 AM"
  | 12 => "12 PM"
  | h if h < 12 => `${h->Int.toString} AM`
  | h => `${(h - 12)->Int.toString} PM`
  }

let ordinal = n => {
  let suffix = switch n {
  | 1 | 21 | 31 => "st"
  | 2 | 22 => "nd"
  | 3 | 23 => "rd"
  | _ => "th"
  }
  `${n->Int.toString}${suffix}`
}

// Monday = 0, as the model counts weekdays
let dowOf = date => mod(date->Date.getUTCDay + 6, 7)

// The plan's word on a bar: "Tue, Nov 3: always in the plan"
let planNote = (days: array<planDay>, ~by, ~matches) =>
  days
  ->Array.filter(d => d.by == by && matches(Date.fromString(`${d.date}T00:00:00Z`)))
  ->Array.map(d =>
    `<br/>${d.label}: ${d.chance >= 0.995
        ? "always in the plan"
        : `${d.chance->pct} chance in the plan`}`
  )
  ->Array.joinWith("")

let point = (~name, ~count, ~picked, ~note) =>
  {
    "y": count->rate,
    "name": name,
    "color": picked ? blue : grey,
    "tip": count.tries > 0
      ? `Worked ${count.worked->Int.toString} of ${count.tries->Int.toString} times (${count
          ->rate
          ->pct})${note}`
      : `No tries yet${note}`,
    // Only the picked bar carries its value
    "dataLabels": {
      "enabled": picked,
      "format": count->rate->pct,
      // Kept inside the plot: an edge bar's label moves in rather than being cut (the 1st, the 31st)
      "crop": false,
      "overflow": "justify",
      "style": {"color": "#344054", "fontSize": "11px", "fontWeight": "600", "textOutline": "none"},
    },
  }

// A fixed plot height so the bars read; the margins hold the picked bar's label and the day labels
let plotHeight = 160
let marginTop = 20
let marginBottom = 22

let options = (~categories, ~tickPositions, ~points, ~average, ~yMax) =>
  {
    "chart": {
      "type": "column",
      "height": plotHeight + marginTop + marginBottom,
      "marginTop": marginTop,
      "marginBottom": marginBottom,
      "backgroundColor": "transparent",
      "spacing": [18, 2, 2, 2],
      "style": {"fontFamily": "inherit"},
    },
    "title": {"text": Nullable.null},
    "credits": {"enabled": false},
    "legend": {"enabled": false},
    "accessibility": {"enabled": false},
    "xAxis": {
      "categories": categories,
      "tickPositions": tickPositions,
      "lineColor": "#D0D5DD",
      "lineWidth": 1,
      "tickLength": 0,
      "labels": {"autoRotation": false, "style": {"color": ink, "fontSize": "11px"}},
    },
    "yAxis": {
      "min": 0,
      "max": yMax,
      // Else the top rounds up to the next tick (100%) and the bars sit low
      "endOnTick": false,
      "title": {"text": Nullable.null},
      "labels": {"enabled": false},
      "gridLineWidth": 0,
      "plotLines": [
        {
          "value": average,
          "color": ink,
          "dashStyle": "Dash",
          "width": 1,
          "zIndex": 4,
        },
      ],
    },
    "tooltip": {
      "useHTML": true,
      "headerFormat": "",
      "pointFormat": "<div style='font-weight:600;margin-bottom:2px'>{point.name}</div><div>{point.tip}</div>",
      "backgroundColor": "#FFFFFF",
      "borderColor": "#E4E7EC",
      "borderRadius": 8,
      "shadow": false,
      "padding": 8,
      "style": {"color": "#344054", "fontSize": "12px"},
    },
    "plotOptions": {
      "column": {
        "borderWidth": 0,
        "borderRadius": 2,
        "pointPadding": 0.1,
        "groupPadding": 0.04,
        "maxPointWidth": 24,
        "minPointLength": 2,
        "states": {"hover": {"brightness": 0.08}, "inactive": {"enabled": false}},
      },
    },
    "series": [{"name": "Worked", "data": points}],
  }->Identity.genericObjectOrRecordToJson

module SlotChart = {
  @react.component
  let make = (~title, ~options, ~className) =>
    <div className={`flex flex-col gap-1 min-w-0 ${className}`}>
      <span className={`${body.sm.semibold} text-nd_gray-600`}> {title->React.string} </span>
      <HighchartsHorizontalBarChart.Chart
        highcharts=HighchartsHorizontalBarChart.highchartsModule options
      />
    </div>
}

// slot: the picked real-life moment (ISO); dayBy: what the model ranked the day by ("weekday" or
// "day of month"); oneIn: the exploration floor in words ("1 in 10"); children: the counts' chip
@react.component
let make = (~counts, ~slot, ~dayBy, ~planDays: array<planDay>, ~oneIn, ~children=React.null) => {
  let picked = Date.fromString(slot)
  let pickDow = picked->dowOf
  let pickDom = picked->Date.getUTCDate - 1
  let pickHour = picked->Date.getUTCHours
  let total = counts.hod->Array.reduce({worked: 0, tries: 0}, (a, c) => {
    worked: a.worked + c.worked,
    tries: a.tries + c.tries,
  })
  let average = total->rate
  // One scale for the three charts, with room for the picked bar's label
  let top =
    [counts.dow, counts.dom, counts.hod]
    ->Array.flat
    ->Array.reduce(average, (m, c) => Math.max(m, c->rate))
  let yMax = Math.min(1.0, top *. 1.18)
  let byDom = dayBy == "day of month"
  let dayRate = byDom
    ? counts.dom->Array.getUnsafe(pickDom)->rate
    : counts.dow->Array.getUnsafe(pickDow)->rate
  let dayName = byDom ? `The ${(pickDom + 1)->ordinal}` : `${weekdays->Array.getUnsafe(pickDow)}s`
  let hourRate = counts.hod->Array.getUnsafe(pickHour)->rate
  // The picked time as the value ("Sun, Nov 1 · 7 PM UTC"); the card's title says it was picked
  let headline = `${weekdays
    ->Array.getUnsafe(pickDow)
    ->String.slice(~start=0, ~end=3)}, ${months->Array.getUnsafe(
      picked->Date.getUTCMonth,
    )} ${(pickDom + 1)->Int.toString} · ${pickHour->hourLabel} UTC`

  let dowChart = options(
    ~categories=weekdays->Array.map(w => w->String.slice(~start=0, ~end=3)),
    ~tickPositions=[0, 1, 2, 3, 4, 5, 6],
    ~points=counts.dow->Array.mapWithIndex((count, i) =>
      point(
        ~name=`${weekdays->Array.getUnsafe(i)}s`,
        ~count,
        ~picked=i == pickDow,
        ~note=planDays->planNote(~by="weekday", ~matches=d => d->dowOf == i) ++ (
            byDom && i == pickDow ? "<br/>Rev Rec ranked this day by its date." : ""
          ),
      )
    ),
    ~average,
    ~yMax,
  )
  let domChart = options(
    ~categories=Array.fromInitializer(~length=31, i => (i + 1)->Int.toString),
    ~tickPositions=[0, 9, 19, 30],
    ~points=counts.dom->Array.mapWithIndex((count, i) =>
      point(
        ~name=`The ${(i + 1)->ordinal}`,
        ~count,
        ~picked=i == pickDom,
        ~note=planDays->planNote(~by="day of month", ~matches=d => d->Date.getUTCDate - 1 == i) ++ (
            !byDom && i == pickDom ? "<br/>Rev Rec ranked this day by its weekday." : ""
          ),
      )
    ),
    ~average,
    ~yMax,
  )
  let hodChart = options(
    ~categories=Array.fromInitializer(~length=24, h => h->Int.toString),
    ~tickPositions=[0, 6, 12, 18, 23],
    ~points=counts.hod->Array.mapWithIndex((count, h) =>
      point(~name=`${h->hourLabel} UTC`, ~count, ~picked=h == pickHour, ~note="")
    ),
    ~average,
    ~yMax,
  )

  <AddDataAttributes attributes=[("data-sim", "pick-charts")]>
    <div className="flex flex-col gap-4">
      <div className="flex flex-col gap-1">
        <span className={`${body.md.semibold} text-nd_gray-800`}> {headline->React.string} </span>
        <span className={`${body.md.medium} text-nd_gray-600`}>
          {`${dayName} worked ${dayRate->pct} before; ${pickHour->hourLabel} worked ${hourRate->pct}.`->React.string}
        </span>
      </div>
      // One row from about 900 px wide (the minimums and gaps add up to 888 px); narrower, they wrap.
      // No minimum is wider than the card, so a phone shows each chart whole.
      <div className="flex flex-wrap gap-x-6 gap-y-4">
        <SlotChart
          title="Day of week" options=dowChart className="flex-1 min-w-[min(220px,100%)]"
        />
        <SlotChart
          title="Day of month" options=domChart className="flex-[1.6] min-w-[min(330px,100%)]"
        />
        <SlotChart
          title="Hour (UTC)" options=hodChart className="flex-[1.3] min-w-[min(290px,100%)]"
        />
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <span className={`${body.sm.medium} text-nd_gray-500`}>
          {`Dashed line: the average for this decline, ${average->pct}. Every day keeps at least a ${oneIn} chance, so Rev Rec keeps learning.`->React.string}
        </span>
        children
      </div>
    </div>
  </AddDataAttributes>
}
