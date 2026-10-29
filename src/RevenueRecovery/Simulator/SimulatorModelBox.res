// The running story's Smart model row (full width, under the status bar): what Rev Rec's model
// knows about this decline, one box each (its group's seeded counts, made up for the demo), and
// the hero box, its pick for the next retry with a live countdown ring. The hero moves with the
// story: a new pick slides in, a retry that runs pulses, its result flips in. The same facts as the
// "What Rev Rec's model knows" card.
open Typography
open SimulatorTypes
open SimulatorTestCards

// One stat box: a glyph in a disc, a label, a value and a smaller line under it
type stat = {icon: string, label: string, value: string, sub: string, help: option<string>}

let stat = (~sub="", ~help=?, icon, label, value) => {icon, label, value, sub, help}

let capitalize = text =>
  `${text->String.charAt(0)->String.toUpperCase}${text->String.sliceToEnd(~start=1)}`

let percent = (k, n) =>
  n == 0 ? 0 : Math.round(Int.toFloat(k) *. 100.0 /. Int.toFloat(n))->Float.toInt

// "the 1st and 15th" -> "1st, 15th"
let shortDays = days =>
  (
    days->String.startsWith("the ") ? days->String.sliceToEnd(~start=4) : days->capitalize
  )->String.replaceRegExp(%re("/ and /g"), ", ")

// "6 PM to 11 PM" -> "6–11 PM"; "9 AM to 6 PM" -> "9 AM–6 PM"
let shortHours = hours =>
  hours
  ->String.replaceRegExp(%re("/(\d+) AM to (\d+) AM/g"), "$1–$2 AM")
  ->String.replaceRegExp(%re("/(\d+) PM to (\d+) PM/g"), "$1–$2 PM")
  ->String.replaceRegExp(%re("/ to /g"), "–")

let pickingText = "Rev Rec is picking a time"

// The engine's group is the decline reason only (MODEL.md): the card's brand is not part of it
let reasonWhy = "Rev Rec groups retries by the decline reason. Visa and Mastercard with the same reason share one group."

let seededWhy = "These counts are made up for the demo, shaped like published retry patterns. The engine adds real outcomes as stories run."

// The four stat boxes, whether the decline is hard, and whether seeded counts are behind them
let facts = firstCharge => {
  let decline = firstCharge->declineOf
  let group = decline->groupOf
  let seed = switch group {
  | Group(cluster, _) => SimulatorSeedStats.seeds->Array.find(s => s.cluster == cluster)
  | Hard | NoGroup => None
  }
  let reason = switch group {
  | Group(_, name) => name
  | Hard | NoGroup =>
    decline->Option.mapOr("Not given", code =>
      code->String.replaceRegExp(%re("/_/g"), " ")->capitalize
    )
  }
  let reasonBox = stat(
    ~sub=group == Hard ? "A hard decline" : "Rev Rec's group",
    ~help=reasonWhy,
    "exclamation-circle",
    "Reason",
    reason,
  )
  let stats = switch (group, seed) {
  | (_, Some(s)) => [
      reasonBox,
      stat(
        ~sub=`${s.worked->Int.toLocaleString} of ${s.tries->Int.toLocaleString}`,
        "analytics",
        "Worked before",
        `${percent(s.worked, s.tries)->Int.toString}%`,
      ),
      stat(
        ~sub=`UTC · ${s.hoursRate->Int.toString}% worked`,
        "clock",
        "Best time",
        s.hours->shortHours,
      ),
      // A flat month: every day worked at the group's own rate
      stat(
        ~sub=`${s.daysRate->Int.toString}% worked`,
        "calendar",
        "Best days",
        s.days == "any day of the month" ? "Any day" : s.days->shortDays,
      ),
    ]
  | (Hard, None) => [
      reasonBox,
      stat(~sub="Not retried", "analytics", "Worked before", "None"),
      stat(~sub="Not retried", "clock", "Best time", "None"),
      stat(~sub="Not retried", "calendar", "Best days", "None"),
    ]
  | (_, None) => [
      reasonBox,
      stat("analytics", "Worked before", "No counts yet"),
      stat("clock", "Best time", "No counts yet"),
      stat("calendar", "Best days", "No counts yet"),
    ]
  }
  (stats, group == Hard, seed->Option.isSome)
}

// What the hero shows, from the story page's pick (nextPick)
type hero =
  | NotYet(string)
  | Picking
  // The pick's time on the simulated calendar ("Fri 4 PM") and its line ("38% worked at this hour")
  | Booked(string, string)
  | Paused
  | NoRetry(string)

let heroOf = (~next, ~isHard) =>
  switch next->String.split(" · ") {
  | _ if isHard => NoRetry("Hard declines are not retried.")
  | _ if next == pickingText => Picking
  | _ if next->String.startsWith("Paused") => Paused
  | _ if next->String.startsWith("None: ") =>
    NoRetry(`${next->String.sliceToEnd(~start=6)->capitalize}.`)
  | [time, sub] => Booked(time->String.replaceRegExp(%re("/ UTC$/"), ""), sub)
  | _ if next->String.startsWith("Picked after") => NotYet(next)
  | _ => Booked(next, "")
  }

// A Rev Rec retry's result: its number, approved or not, and the decline in plain words
type result = {number: int, approved: bool, reason: string}

let resultOf = (retry: SimulatorStorySteps.retry) =>
  retry.charge->Option.map(row => {
    number: retry.number,
    approved: row.status == StepOk,
    reason: row
    ->SimulatorStorySteps.declineOf
    ->Option.mapOr("", ((reason, _)) => reason->SimulatorStorySteps.plainReason),
  })

// The flip shows a new result this long, then the hero turns back to the next pick
let flipMs = 2600

let css = `
.smb-in { animation: smb-in .45s cubic-bezier(.2, .8, .2, 1) backwards; }
.smb-flip { animation: smb-flip .55s cubic-bezier(.2, .8, .2, 1) backwards; }
.smb-spin { animation: smb-spin 1s linear infinite; transform-origin: 50% 50%; }
.smb-ping { animation: smb-ping 1.2s ease-out infinite; }
.smb-ring { transition: stroke-dashoffset .25s linear, stroke .3s ease; }
@keyframes smb-in { from { opacity: 0; transform: translateY(12px); } to { opacity: 1; transform: none; } }
@keyframes smb-flip { from { opacity: 0; transform: perspective(700px) rotateX(-80deg); }
  to { opacity: 1; transform: perspective(700px) rotateX(0); } }
@keyframes smb-spin { to { transform: rotate(360deg); } }
@keyframes smb-ping { 0% { box-shadow: 0 0 0 0 rgba(255, 255, 255, .6); }
  100% { box-shadow: 0 0 0 16px rgba(255, 255, 255, 0); } }
@media (prefers-reduced-motion: reduce) {
  .smb-in, .smb-flip, .smb-spin, .smb-ping { animation: none; } .smb-ring { transition: none; } }
`

// "0:42" for the ring
let clockText = ms => {
  let seconds = Math.ceil(ms /. 1000.0)->Float.toInt->Math.Int.max(0)
  let rest = mod(seconds, 60)
  `${(seconds / 60)->Int.toString}:${rest < 10 ? "0" : ""}${rest->Int.toString}`
}

let chipClass = `rounded px-1.5 py-0.5 border whitespace-nowrap cursor-help bg-nd_gray-50 text-nd_gray-600 border-nd_gray-200 ${body.xs.semibold}`

// Nothing is cut: the label is short, and the value and its line wrap when the box is narrow
module StatBox = {
  @react.component
  let make = (~stat as {icon, label, value, sub, help}) =>
    <div
      className="min-w-0 bg-white border border-nd_gray-200 rounded-xl px-3 py-3 flex flex-col gap-1.5">
      <div className="flex items-center gap-1.5 text-nd_gray-500">
        <span className="shrink-0 flex text-nd_gray-400">
          <Icon name=icon size=14 />
        </span>
        <span className={`min-w-0 ${body.sm.semibold}`}> {label->React.string} </span>
        {help->Option.mapOr(React.null, description =>
          <div className="ml-auto flex items-center">
            <ToolTip
              description
              toolTipPosition=ToolTip.Top
              toolTipFor={<span className=chipClass> {"?"->React.string} </span>}
            />
          </div>
        )}
      </div>
      <span className={`break-words ${heading.sm.semibold} text-nd_gray-800`}>
        {value->React.string}
      </span>
      <span className={`${body.sm.medium} text-nd_gray-500`}> {sub->React.string} </span>
    </div>
}

// The countdown ring: full when the retry is booked, empty when it runs
let ringSize = 64.0
let ringRadius = 27.0
let ringLength = 2.0 *. Math.Constants.pi *. ringRadius

module Ring = {
  @react.component
  let make = (~fraction, ~isSpinning=false, ~isPulsing=false, ~children) => {
    let size = ringSize->Float.toString
    let center = (ringSize /. 2.0)->Float.toString
    let radius = ringRadius->Float.toString
    <div
      className={`relative shrink-0 rounded-full ${isPulsing ? "smb-ping" : ""}`}
      style={width: `${size}px`, height: `${size}px`}>
      <svg
        width=size
        height=size
        viewBox={`0 0 ${size} ${size}`}
        className={isSpinning ? "smb-spin" : "-rotate-90"}
        ariaHidden=true>
        <circle
          cx=center cy=center r=radius fill="none" stroke="rgba(255,255,255,0.25)" strokeWidth="5"
        />
        <circle
          className="smb-ring"
          cx=center
          cy=center
          r=radius
          fill="none"
          stroke="#ffffff"
          strokeWidth="5"
          strokeLinecap="round"
          strokeDasharray={ringLength->Float.toString}
          strokeDashoffset={(ringLength *. (1.0 -. fraction))->Float.toString}
        />
      </svg>
      <div className="absolute inset-0 flex flex-col items-center justify-center"> children </div>
    </div>
  }
}

@react.component
let make = (
  // The billing system's first charge (form.firstCharge): its decline sets the group
  ~firstCharge: string,
  // The model's pick for the next retry, as the story page has it (nextPick): "Tue 10 AM UTC ·
  // 44% worked at this hour", "Rev Rec is picking a time", "Paused · next retry waits"
  ~next="Picked after the charge fails",
  // For the ring: when the next retry runs here (A's nextRetry.runsAt) and its number
  ~story: option<story>=?,
  // Rev Rec's retries so far (the retries block's): a new charge flips in its result
  ~retries: array<SimulatorStorySteps.retry>=[],
) => {
  let (stats, isHard, isSeeded) = facts(firstCharge)
  let hero = heroOf(~next, ~isHard)

  // The same rule as the story's waiting line: no time while a smart pick moves to the demo clock
  let runsAt = switch (hero, story->Option.flatMap(s => s.nextRetry)) {
  | (Booked(_), Some(next)) if next.pending => None
  | (Booked(_), Some(next)) if next.runsAt->LogicUtils.isNonEmptyString => Some(next.runsAt)
  | (Booked(_), _) => story->Option.flatMap(s => s.nextRetryAt)
  | _ => None
  }
  let charged = retries->Array.filterMap(resultOf)
  let last = charged->Array.at(-1)
  let number =
    story
    ->Option.flatMap(s => s.nextRetry)
    ->Option.mapOr(charged->Array.length + 1, next => next.number)

  // The ring runs from the booking (or from when this page first saw the time) to the retry
  let started = React.useRef(None)
  let startMs = runsAt->Option.map(at => {
    switch started.current {
    | Some((seen, ms)) if seen == at => ms
    | _ => {
        let booked =
          retries
          ->Array.find(retry => retry.charge->Option.isNone)
          ->Option.flatMap(retry => retry.booking)
          ->Option.map(row => row.at->SimulatorUtils.toMillis)
          ->Option.filter(ms => ms < at->SimulatorUtils.toMillis)
        let ms = booked->Option.getOr(Date.now())
        started.current = Some((at, ms))
        ms
      }
    }
  })
  let (nowMs, setNowMs) = React.useState(_ => Date.now())
  React.useEffect(() =>
    runsAt->Option.map(_ => {
      let intervalId = setInterval(() => setNowMs(_ => Date.now()), 200)
      () => clearInterval(intervalId)
    })
  , [runsAt])

  // A result that arrives while the page is open flips in; one known on load does not
  let seenCount = React.useRef(None)
  let (flip, setFlip) = React.useState(_ => None)
  let chargedCount = charged->Array.length
  React.useEffect(() => {
    let isNew = seenCount.current->Option.mapOr(false, before => chargedCount > before)
    seenCount.current = Some(chargedCount)
    if isNew {
      setFlip(_ => last)
      let timeoutId = setTimeout(() => setFlip(_ => None), flipMs)
      Some(() => clearTimeout(timeoutId))
    } else {
      None
    }
  }, [chargedCount])

  let isDue = switch runsAt {
  | Some(at) => nowMs >= at->SimulatorUtils.toMillis
  | None => false
  }
  // A result face: a fresh one for a moment, or the approved one once the invoice is recovered
  let face = switch (flip, hero, last) {
  | (Some(result), _, _) => Some(result)
  | (None, NoRetry(_), Some(result)) if result.approved => Some(result)
  | _ => None
  }

  let label = (text, ~extra=React.null) =>
    <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
      <span className={`uppercase tracking-wide ${body.sm.semibold} opacity-80`}>
        {text->React.string}
      </span>
      extra
    </div>
  let numberChip =
    <span className={`rounded-full bg-white/20 px-2 py-0.5 ${body.xs.semibold}`}>
      {`Retry ${number->Int.toString}`->React.string}
    </span>
  let glyph = name => <Icon name size=18 />

  let (viewKey, content) = switch (face, hero) {
  | (Some({number, approved, reason}), _) => (
      `result-${number->Int.toString}`,
      <div className="flex items-center gap-3">
        <span
          className={`shrink-0 w-12 h-12 rounded-full flex items-center justify-center ${approved
              ? "bg-nd_green-50 text-nd_green-400"
              : "bg-nd_red-50 text-nd_red-500"}`}>
          <Icon name={approved ? "nd-check" : "nd-cross"} size=22 />
        </span>
        <div className="flex min-w-0 flex-col gap-1">
          <span className={`uppercase tracking-wide ${body.sm.semibold} text-nd_gray-500`}>
            {`Retry ${number->Int.toString} result`->React.string}
          </span>
          <span
            className={`${heading.md.semibold} ${approved
                ? "text-nd_green-400"
                : "text-nd_red-500"}`}>
            {(approved ? "Approved" : "Declined")->React.string}
          </span>
          <span className={`${body.md.medium} text-nd_gray-600`}>
            {(
              approved
                ? "The money is back."
                : reason == ""
                ? "Card declined. Rev Rec picks again."
                : `${reason}. Rev Rec picks again.`
            )->React.string}
          </span>
        </div>
      </div>,
    )
  | (None, Booked(_)) if isDue => (
      `running-${number->Int.toString}`,
      <div className="flex items-center gap-3">
        <Ring fraction=1.0 isPulsing=true> {glyph("sync")} </Ring>
        <div className="flex min-w-0 flex-col gap-1">
          {label("Next retry", ~extra=numberChip)}
          <span className={`${heading.md.semibold}`}> {"Running now"->React.string} </span>
          <span className={`${body.md.medium} opacity-90`}>
            {"Charging the saved card."->React.string}
          </span>
        </div>
      </div>,
    )
  | (None, Booked(time, sub)) => {
      let fraction = switch (runsAt, startMs) {
      | (Some(at), Some(start)) => {
          let total = at->SimulatorUtils.toMillis -. start
          total <= 0.0
            ? 0.0
            : Math.max(0.0, Math.min(1.0, (at->SimulatorUtils.toMillis -. nowMs) /. total))
        }
      | _ => 1.0
      }
      (
        `booked-${number->Int.toString}-${time}`,
        <div className="flex items-center gap-3">
          <Ring fraction>
            {switch runsAt {
            | Some(at) =>
              <>
                <span className={`${body.lg.semibold} tabular-nums`}>
                  {(at->SimulatorUtils.toMillis -. nowMs)->clockText->React.string}
                </span>
                <span className={`${body.xs.medium} opacity-80`}> {"to go"->React.string} </span>
              </>
            | None => glyph("clock")
            }}
          </Ring>
          <div className="flex min-w-0 flex-col gap-1">
            {label("Next retry", ~extra=numberChip)}
            <span className={`whitespace-nowrap ${heading.md.semibold}`}>
              {time->React.string}
            </span>
            <span className={`${body.md.medium} opacity-90`}>
              {`UTC · ${sub == "" ? "picked by Rev Rec's model" : sub}`->React.string}
            </span>
          </div>
        </div>,
      )
    }
  | (None, Picking) => (
      "picking",
      <div className="flex items-center gap-3">
        <Ring fraction=0.25 isSpinning=true> React.null </Ring>
        <div className="flex min-w-0 flex-col gap-1">
          {label("Next retry", ~extra=numberChip)}
          <span className={`${heading.md.semibold}`}> {"Picking a time"->React.string} </span>
          <span className={`${body.md.medium} opacity-90`}>
            {"Rev Rec reads the counts."->React.string}
          </span>
        </div>
      </div>,
    )
  | (None, Paused) => (
      "paused",
      <div className="flex items-center gap-3">
        <Ring fraction=0.0>
          <span className="flex gap-1">
            <span className="w-1.5 h-5 rounded-sm bg-white" />
            <span className="w-1.5 h-5 rounded-sm bg-white" />
          </span>
        </Ring>
        <div className="flex min-w-0 flex-col gap-1">
          {label("Next retry")}
          <span className={`${heading.md.semibold}`}> {"Paused"->React.string} </span>
          <span className={`${body.md.medium} opacity-90`}>
            {"Waits until you resume."->React.string}
          </span>
        </div>
      </div>,
    )
  | (None, NoRetry(why)) => (
      "none",
      <div className="flex items-center gap-3">
        <Ring fraction=0.0> {glyph("nd-cross")} </Ring>
        <div className="flex min-w-0 flex-col gap-1">
          {label("Next retry")}
          <span className={`${heading.md.semibold}`}> {"None"->React.string} </span>
          <span className={`${body.md.medium} opacity-90`}> {why->React.string} </span>
        </div>
      </div>,
    )
  | (None, NotYet(text)) => (
      "not-yet",
      <div className="flex items-center gap-3">
        <Ring fraction=0.0> {glyph("clock")} </Ring>
        <div className="flex min-w-0 flex-col gap-1">
          {label("Next retry")}
          <span className={`${heading.md.semibold}`}> {"Not picked yet"->React.string} </span>
          <span className={`${body.md.medium} opacity-90`}> {text->React.string} </span>
        </div>
      </div>,
    )
  }

  <AddDataAttributes attributes=[("data-sim", "model-box")]>
    <div className="flex flex-col gap-3">
      <style> {css->React.string} </style>
      <div className="flex items-center gap-2">
        <p className={`${body.lg.semibold} text-nd_gray-800`}> {"Smart model"->React.string} </p>
        <p className={`${body.md.medium} text-nd_gray-500`}>
          {"What Rev Rec knows about this decline, and when it retries."->React.string}
        </p>
        <RenderIf condition=isSeeded>
          // Honest label: the counts the model starts from are made up for the demo
          <div className="ml-auto flex items-center">
            <ToolTip
              description=seededWhy
              toolTipPosition=ToolTip.Top
              toolTipFor={<span className=chipClass> {"Seeded counts ?"->React.string} </span>}
            />
          </div>
        </RenderIf>
      </div>
      <div
        className="grid grid-cols-2 lg:grid-cols-4 xl:grid-cols-[repeat(4,minmax(0,1fr))_minmax(0,1.7fr)] gap-3 items-stretch">
        {stats->Array.map(stat => <StatBox key=stat.label stat />)->React.array}
        // Its own key per face, so a result flips in and the next pick flips back
        <AddDataAttributes attributes=[("data-sim", "next-retry"), ("data-state", viewKey)]>
          <div
            key={face->Option.isSome ? viewKey : "pick"}
            className={`smb-flip col-span-2 lg:col-span-4 xl:col-span-1 min-w-0 rounded-xl px-4 py-3.5 flex items-center ${switch face {
              | Some({approved: true}) => "bg-white border-2 border-nd_green-200 text-nd_gray-800"
              | Some(_) => "bg-white border-2 border-nd_red-200 text-nd_gray-800"
              | None => "bg-gradient-to-br from-nd_primary_blue-600 to-nd_primary_blue-400 text-white shadow-sm"
              }}`}>
            <div key=viewKey className="smb-in w-full"> content </div>
          </div>
        </AddDataAttributes>
      </div>
    </div>
  </AddDataAttributes>
}
