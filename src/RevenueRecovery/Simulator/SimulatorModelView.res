// The model view: how Rev Rec's model picked the story's latest retry, in plain numbers
// (simulator/WORDING.md rule 6). The numbers come from GET /sim/story/:id/model: the sim service
// re-computes the engine's decision from the counts the engine read. The formulas sit behind
// "Show the math". Content adapted from Balakrishna's Adaptive Retry Lab, used with permission.
open LogicUtils
open Typography

type modelDay = {
  label: string,
  // YYYY-MM-DD, the day in real life (for the pick charts' plan notes)
  date: string,
  by: string,
  worked: int,
  tries: int,
  chance: float,
  chosen: bool,
}
type modelHour = {label: string, worked: int, tries: int, noData: bool, chance: float, chosen: bool}
type decision = {
  n: int,
  // The engine's cluster key, "v1|<code>/UNK/UNK": the decline the retry tries to beat
  cluster: string,
  // Re-made on the simulated calendar from the day of the last try (later picks); else the
  // engine's own pick
  recomputed: bool,
  slot: string,
  windowDays: int,
  budget: int,
  explorationFloor: float,
  days: array<modelDay>,
  hours: array<modelHour>,
}

let dayMapper = json => {
  let d = json->getDictFromJsonObject
  {
    label: d->getString("label", ""),
    date: d->getString("date", ""),
    by: d->getString("by", ""),
    worked: d->getInt("worked", 0),
    tries: d->getInt("of", 0),
    chance: d->getFloat("chance", 0.0),
    chosen: d->getBool("chosen", false),
  }
}

let hourMapper = (json): modelHour => {
  let d = json->getDictFromJsonObject
  {
    label: d->getString("label", ""),
    worked: d->getInt("worked", 0),
    tries: d->getInt("of", 0),
    noData: d->getBool("noData", false),
    chance: d->getFloat("chance", 0.0),
    chosen: d->getBool("chosen", false),
  }
}

// The latest decision the model explained, if any
let latestDecision = (json): option<decision> =>
  json
  ->getDictFromJsonObject
  ->getDictfromDict("calendar")
  ->getArrayFromDict("plans", [])
  ->Array.filterMap(plan => {
    let p = plan->getDictFromJsonObject
    let model = p->getDictfromDict("model")
    model->Dict.keysToArray->Array.length == 0
      ? None
      : Some({
          n: p->getInt("n", 0),
          cluster: p->getString("cluster", ""),
          recomputed: p->getString("source", "") == "re-computed",
          slot: p->getString("slot", ""),
          windowDays: model->getInt("windowDays", 0),
          budget: model->getInt("budget", 0),
          explorationFloor: model->getFloat("explorationFloor", 0.1),
          days: model->getArrayFromDict("days", [])->Array.map(dayMapper),
          hours: model->getArrayFromDict("hours", [])->Array.map(hourMapper),
        })
  })
  ->Array.at(-1)

// "1 in 10" for 0.1; "about 1 in 5" for 0.195
let oneIn = chance => {
  let n = (1.0 /. chance)->Math.round->Float.toInt
  let exact = Math.abs(1.0 /. chance -. n->Int.toFloat) < 0.05
  `${exact ? "" : "about "}1 in ${n->Int.toString}`
}

// "Wed, Nov 4, 7 PM" in UTC, like the engine's slots
let slotLabel = iso => {
  let d = Date.fromString(iso)
  let weekday =
    ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]->Array.getUnsafe(d->Date.getUTCDay)
  let month =
    [
      "Jan",
      "Feb",
      "Mar",
      "Apr",
      "May",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Oct",
      "Nov",
      "Dec",
    ]->Array.getUnsafe(d->Date.getUTCMonth)
  let hour = d->Date.getUTCHours
  let hour12 = mod(hour, 12) == 0 ? 12 : mod(hour, 12)
  `${weekday}, ${month} ${d->Date.getUTCDate->Int.toString}, ${hour12->Int.toString} ${hour < 12
      ? "AM"
      : "PM"}`
}

let percent = chance => `${(chance *. 100.0)->Math.round->Float.toInt->Int.toString}%`

// "Fridays" or "The 1st of the month" from the day row the engine ranked by
let slotName = (day: modelDay) =>
  if day.by == "weekday" {
    `${day.label->String.slice(~start=0, ~end=3)}days`
    ->String.replace("Wed", "Wednes")
    ->String.replace("Thu", "Thurs")
    ->String.replace("Tue", "Tues")
    ->String.replace("Sat", "Satur")
  } else {
    let date = day.label->String.split(" ")->Array.at(-1)->Option.getOr("")
    let suffix = switch date {
    | "1" | "21" | "31" => "st"
    | "2" | "22" => "nd"
    | "3" | "23" => "rd"
    | _ => "th"
    }
    `The ${date}${suffix} of the month`
  }

// A row with a small bar: how often this slot worked before
module SlotRow = {
  @react.component
  let make = (~label, ~worked, ~tries, ~chanceText, ~chosen, ~noData=false) => {
    let rate = tries > 0 ? worked->Int.toFloat /. tries->Int.toFloat : 0.0
    <div className="flex items-center gap-3">
      <span
        className={`w-28 shrink-0 ${body.md.semibold} ${chosen
            ? "text-nd_primary_blue-600"
            : "text-nd_gray-700"}`}>
        {label->React.string}
      </span>
      <div className="flex-1 min-w-0 flex flex-col gap-1">
        <div className="h-1.5 w-full rounded-full bg-nd_gray-100">
          <div
            className={`h-1.5 rounded-full ${chosen ? "bg-nd_primary_blue-450" : "bg-nd_gray-300"}`}
            style={ReactDOM.Style.make(
              ~width=`${(rate *. 100.0)->Float.toFixedWithPrecision(~digits=1)}%`,
              (),
            )}
          />
        </div>
        <span className={`${body.sm.medium} text-nd_gray-500`}>
          {(
            noData
              ? "No data yet"
              : `Worked ${worked->Int.toString} of ${tries->Int.toString} times · ${chanceText}`
          )->React.string}
        </span>
      </div>
      <RenderIf condition=chosen>
        <span
          className={`shrink-0 rounded px-1.5 py-0.5 border bg-nd_primary_blue-50 text-nd_primary_blue-600 border-nd_primary_blue-200 ${body.xs.semibold}`}>
          {"Picked"->React.string}
        </span>
      </RenderIf>
    </div>
  }
}

// A chip with its reason behind "?"
module ChipWithWhy = {
  @react.component
  let make = (~text, ~why) =>
    <ToolTip
      description=why
      toolTipPosition=ToolTip.Top
      toolTipFor={<span
        className={`shrink-0 w-fit rounded px-1.5 py-0.5 border whitespace-nowrap cursor-help bg-nd_gray-50 text-nd_gray-600 border-nd_gray-200 ${body.xs.semibold}`}>
        {`${text} ?`->React.string}
      </span>}
    />
}

module Chip = {
  @react.component
  let make = (~text) =>
    <span
      className={`shrink-0 w-fit rounded px-1.5 py-0.5 border whitespace-nowrap bg-nd_gray-50 text-nd_gray-600 border-nd_gray-200 ${body.xs.semibold}`}>
      {text->React.string}
    </span>
}

// The formulas, with this decision's numbers
module MathDetails = {
  @react.component
  let make = (~decision: decision, ~day: modelDay, ~hour: option<modelHour>) => {
    let pHat = (k, n) => (k->Int.toFloat +. 1.0) /. (n->Int.toFloat +. 2.0)
    let se = (k, n) => {
      let p = pHat(k, n)
      Math.sqrt(p *. (1.0 -. p) /. (n->Int.toFloat +. 3.0))
    }
    let line = text =>
      <span className={`${body.sm.medium} text-nd_gray-600`}> {text->React.string} </span>
    let fixed = (x, digits) => x->Float.toFixedWithPrecision(~digits)
    <div className="flex flex-col gap-1.5 rounded-lg bg-nd_gray-25 border border-nd_gray-150 p-3">
      {line(
        `Rate: p̂ = (k+1)/(n+2) = (${day.worked->Int.toString}+1)/(${day.tries->Int.toString}+2) = ${pHat(
            day.worked,
            day.tries,
          )->fixed(3)}`,
      )}
      {line(`Spread: SE = √(p̂(1−p̂)/(n+3)) = ${se(day.worked, day.tries)->fixed(4)}`)}
      {line(
        "Score: the average over the other slots of logit(Φ(gap / combined SE)): how surely this slot beats each other one.",
      )}
      {line(
        `Days: the ${decision.budget->Int.toString} best of the next ${decision.windowDays->Int.toString} days get a place in the plan; every other day keeps ${percent(
            decision.explorationFloor,
          )}. Rev Rec acts on the soonest planned day.`,
      )}
      {switch hour {
      | Some(hour) =>
        line(`Hour: drawn in proportion to e^score. ${hour.label}: ${percent(hour.chance)}.`)
      | None => React.null
      }}
      {line("Re-computed from the engine's formulas and the counts it read.")}
    </div>
  }
}

// footerRight: the story page's controls, right-aligned in the card's action row (with "Show the
// math" on the left). Before the model decides, the row holds only them.
@react.component
let make = (~storyId, ~isLive, ~footerRight: React.element=React.null) => {
  let simFetch = SimulatorApi.useSimFetch()
  let (state, setState) = React.useState(_ => None)
  let (showMath, setShowMath) = React.useState(_ => false)

  // Read now, then every 3 s while the story runs
  React.useEffect(() => {
    let read = async () =>
      try {
        let json = await simFetch(~path=`/sim/story/${storyId}/model`, ~method_=Get)
        // The decision and the counts behind it (SimulatorPickCharts)
        setState(_ =>
          json
          ->latestDecision
          ->Option.map(d => (d, json->SimulatorPickCharts.countsOf(~cluster=d.cluster)))
        )
      } catch {
      | _ => ()
      }
    read()->ignore
    if isLive {
      let id = setInterval(() => read()->ignore, 3000)
      Some(() => clearInterval(id))
    } else {
      None
    }
  }, (storyId, isLive))

  let footer = <div className="ml-auto flex items-center gap-3"> footerRight </div>

  switch state {
  | None => footerRight === React.null ? React.null : <div className="flex"> footer </div>
  | Some((decision, counts)) =>
    let chosenDay = decision.days->Array.find(d => d.chosen)
    let chosenHour = decision.hours->Array.find(h => h.chosen)
    // Only when there are at least as many retries left as best days and each is pinned at 1.0
    // (the engine's inclusion probabilities sum to the retries left); otherwise the rows and bars
    // show the real chances
    let allInPlanNote =
      <RenderIf
        condition={decision.days->Array.length > 0 &&
        decision.budget >= decision.days->Array.length &&
        decision.days->Array.every(day => day.chance >= 0.995)}>
        <span className={`${body.sm.medium} text-nd_gray-500`}>
          {`${decision.budget->Int.toString} ${decision.budget == 1
              ? "retry"
              : "retries"} left: every best day is in the plan. Rev Rec acts on the soonest planned day.`->React.string}
        </span>
      </RenderIf>
    <AddDataAttributes attributes=[("data-sim", "model-view")]>
      <div className="flex flex-col gap-4 rounded-xl border border-nd_gray-150 bg-white p-4">
        <div className="flex items-center justify-between gap-2">
          <span className={`${body.lg.semibold} text-nd_gray-800`}>
            {"Why the smart model picked this time"->React.string}
          </span>
          <div className="flex gap-1.5">
            <RenderIf condition={counts->Option.isNone}>
              <Chip text="Seeded counts" />
            </RenderIf>
            <RenderIf condition=decision.recomputed>
              <ChipWithWhy
                text="Re-computed"
                why="The engine plans from the real today. On the simulated calendar, later picks are re-made with its formulas from the day of the last try."
              />
            </RenderIf>
          </div>
        </div>
        // The pick as charts (SimulatorPickCharts) when the counts are there; else the text rows
        {switch (counts, chosenDay) {
        | (Some(counts), Some(day)) =>
          <>
            <SimulatorPickCharts
              counts
              slot=decision.slot
              dayBy=day.by
              planDays={decision.days->Array.map((d): SimulatorPickCharts.planDay => {
                label: d.label,
                by: d.by,
                date: d.date,
                chance: d.chance,
              })}
              oneIn={decision.explorationFloor->oneIn}>
              <ChipWithWhy
                text="Seeded counts"
                why="Made-up counts for this demo, plus the demo's own results. Rev Rec's real model reads them."
              />
            </SimulatorPickCharts>
            allInPlanNote
          </>
        | _ =>
          <>
            {switch (chosenDay, chosenHour) {
            | (Some(day), Some(hour)) =>
              <div className="flex flex-col gap-1">
                <span className={`${body.md.semibold} text-nd_gray-800`}>
                  {`${day.label}, ${hour.label}`->React.string}
                </span>
                <span className={`${body.md.medium} text-nd_gray-600`}>
                  {`${day->slotName} worked ${day.worked->Int.toString} of ${day.tries->Int.toString} times before.`->React.string}
                </span>
                <span className={`${body.md.medium} text-nd_gray-600`}>
                  {`${hour.label} worked ${hour.worked->Int.toString} of ${hour.tries->Int.toString} times.`->React.string}
                </span>
                <span className={`${body.md.medium} text-nd_gray-600`}>
                  {`Every day keeps at least a ${oneIn(
                      decision.explorationFloor,
                    )} chance.`->React.string}
                </span>
              </div>
            | _ => React.null
            }}
            <div className="flex flex-col gap-2">
              <span className={`${body.sm.semibold} text-nd_gray-500`}>
                {"Best days"->React.string}
              </span>
              allInPlanNote
              {decision.days
              ->Array.map(day =>
                <SlotRow
                  key=day.label
                  label=day.label
                  worked=day.worked
                  tries=day.tries
                  chanceText={day.chance >= 0.995
                    ? "Always in the plan"
                    : `${day.chance->percent} chance in the plan`}
                  chosen=day.chosen
                />
              )
              ->React.array}
            </div>
            <div className="flex flex-col gap-2">
              <span className={`${body.sm.semibold} text-nd_gray-500`}>
                {"Best hours"->React.string}
              </span>
              {decision.hours
              ->Array.map(hour =>
                <SlotRow
                  key=hour.label
                  label=hour.label
                  worked=hour.worked
                  tries=hour.tries
                  chanceText={`${hour.chance->percent} chance to be picked`}
                  chosen=hour.chosen
                  noData=hour.noData
                />
              )
              ->React.array}
            </div>
          </>
        }}
        // A processing error: the model's next-day rule costs time against the fixed timetable
        <RenderIf condition={decision.cluster->String.includes("downstream_technical_issue")}>
          <div className="flex flex-col gap-0.5">
            <span className={`${body.md.medium} text-nd_gray-700`}>
              {"Rev Rec's model never retries the same day."->React.string}
            </span>
            <span className={`${body.md.medium} text-nd_gray-700`}>
              {"For a short bank outage, the fixed timetable is faster."->React.string}
            </span>
          </div>
        </RenderIf>
        <span className={`${body.sm.medium} text-nd_gray-500`}>
          {"A good slot is not a sure thing: Rev Rec still may not recover."->React.string}
        </span>
        // The math opens above the action row, so the row stays at the card's bottom
        {switch (showMath, chosenDay) {
        | (true, Some(day)) => <MathDetails decision day hour=chosenHour />
        | _ => React.null
        }}
        <AddDataAttributes attributes=[("data-sim", "model-actions")]>
          <div className="flex flex-wrap items-center gap-3">
            <Button
              text={showMath ? "Hide the math" : "Show the math"}
              buttonType=Secondary
              buttonSize=Small
              onClick={_ => setShowMath(prev => !prev)}
            />
            footer
          </div>
        </AddDataAttributes>
      </div>
    </AddDataAttributes>
  }
}
