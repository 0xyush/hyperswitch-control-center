// "Step through the pick" (2 Nov): the engine's slot scoring, one step at a time, on the counts it
// read for this story's decline. Adapted from Anand's Retry Slot Playground, used with permission.
// The formulas are the engine's (simulator/selfhost/MODEL.md, "What runs"; sim/model.mjs):
// p̂ = (k+1)/(n+2), SE = √(p̂(1−p̂)/(n+3)), head to head Φ(gap / combined SE), score = the average
// logit of the head-to-heads, share = e^score / Σ e^score. A slot with no tries is not scored (0).
open Typography

type dim = Weekday | MonthDay | Hour

type cell = {
  index: int,
  name: string,
  worked: int,
  tries: int,
  scored: bool,
  p: float,
  se: float,
  score: float,
  share: float,
}

// erf by Abramowitz and Stegun 7.1.26, as sim/model.mjs
let erf = x => {
  let t = 1.0 /. (1.0 +. 0.3275911 *. Math.abs(x))
  let y =
    1.0 -.
    ((((1.061405429 *. t -. 1.453152027) *. t +. 1.421413741) *. t -. 0.284496736) *.
      t +. 0.254829592) *.
    t *.
    Math.exp(-.x *. x)
  x >= 0.0 ? y : -.y
}
let phi = z => 0.5 *. (1.0 +. erf(z /. Math.sqrt(2.0)))
let clip = 1e-4
let logit = c => {
  let p = Math.min(1.0 -. clip, Math.max(clip, c))
  Math.log(p /. (1.0 -. p))
}

// How surely a beats b
let beats = (a, b) => phi((a.p -. b.p) /. Math.sqrt(a.se *. a.se +. b.se *. b.se))

let build = (counts: array<SimulatorPickCharts.slotCount>, ~nameOf) => {
  let base = counts->Array.mapWithIndex((c, i) => {
    let n = c.tries->Int.toFloat
    let p = (c.worked->Int.toFloat +. 1.0) /. (n +. 2.0)
    {
      index: i,
      name: nameOf(i),
      worked: c.worked,
      tries: c.tries,
      scored: c.tries > 0 && c.worked <= c.tries,
      p,
      se: Math.sqrt(p *. (1.0 -. p) /. (n +. 3.0)),
      score: 0.0,
      share: 0.0,
    }
  })
  let scored = base->Array.filter(c => c.scored)
  let others = scored->Array.length - 1
  let withScores = base->Array.map(a =>
    a.scored && others > 0
      ? {
          ...a,
          score: scored->Array.reduce(0.0, (sum, b) =>
            b.index == a.index ? sum : sum +. logit(beats(a, b))
          ) /. others->Int.toFloat,
        }
      : a
  )
  let top = withScores->Array.reduce(neg_infinity, (m, c) => Math.max(m, c.score))
  let total = withScores->Array.reduce(0.0, (s, c) => s +. Math.exp(c.score -. top))
  withScores->Array.map(c => {...c, share: Math.exp(c.score -. top) /. total})
}

// "v1|insufficient_funds/UNK/UNK" -> "Insufficient funds"
let reasonOf = cluster => {
  let code =
    cluster
    ->String.split("|")
    ->Array.get(1)
    ->Option.getOr("")
    ->String.split("/")
    ->Array.get(0)
    ->Option.getOr("")
    ->String.replaceRegExp(%re("/_/g"), " ")
  code == ""
    ? "this decline"
    : `${code->String.charAt(0)->String.toUpperCase}${code->String.sliceToEnd(~start=1)}`
}

let pct = (x, ~digits=0) => `${(x *. 100.0)->Float.toFixedWithPrecision(~digits)}%`
let fixed = (x, digits) => x->Float.toFixedWithPrecision(~digits)
let signed = x => `${x >= 0.0 ? "+" : ""}${x->fixed(2)}`

// Worse to better, as in the playground: soft red, amber, soft green. Each stop is light enough for
// ink text (contrast above 4.5:1), and every cell shows its number, so colour is never the only cue
let worse = (239, 142, 142)
let middle = (251, 228, 168)
let better = (124, 201, 106)
let heat = t => {
  let ((r1, g1, b1), (r2, g2, b2), u) =
    t < 0.5 ? (worse, middle, t *. 2.0) : (middle, better, (t -. 0.5) *. 2.0)
  let mix = (a, b) => (a->Int.toFloat +. (b - a)->Int.toFloat *. u)->Math.round->Float.toInt
  (
    `rgb(${mix(r1, r2)->Int.toString},${mix(g1, g2)->Int.toString},${mix(b1, b2)->Int.toString})`,
    "#1F2937",
  )
}

let stepTitles = [
  "Wins and tries",
  "Success rate",
  "How sure",
  "Head to head",
  "One score",
  "Share",
  "The pick",
]

// The cell's two lines and its heat value (None = no colour) at a step
let cellView = (c, ~step, ~focus: cell, ~dim) =>
  if !c.scored {
    ("no data", "", None)
  } else {
    switch step {
    | 0 => (`${c.worked->Int.toString}/${c.tries->Int.toString}`, "worked/tries", None)
    | 1 => (c.p->pct, "", Some(c.p))
    | 2 => (`±${c.se->pct(~digits=1)}`, c.p->pct, Some(-.c.se))
    | 3 =>
      c.index == focus.index
        ? ("vs all", "", None)
        : (beats(focus, c)->pct, "sure it wins", Some(beats(focus, c)))
    | 4 => (c.score->signed, "score", Some(c.score))
    | _ => (c.share->pct(~digits=1), dim == Hour && step == 6 ? "chance" : "share", Some(c.share))
    }
  }

module Formula = {
  @react.component
  let make = (~text) =>
    <div
      className="font-mono text-xs leading-relaxed rounded-md bg-nd_gray-50 border border-nd_gray-150 px-3 py-2 text-nd_gray-800 break-words">
      {text->React.string}
    </div>
}

// The step's explanation, worked on the followed cell
module Explain = {
  @react.component
  let make = (
    ~step,
    ~dim,
    ~focus: cell,
    ~rival: option<cell>,
    ~cells,
    ~pick: cell,
    ~budget,
    ~windowDays,
    ~floor,
    ~pickLabel,
    ~pickChance,
  ) => {
    let line = text =>
      <p className={`${body.md.medium} text-nd_gray-600`}> {text->React.string} </p>
    let k = focus.worked->Int.toString
    let n = focus.tries->Int.toString
    let unit = switch dim {
    | Weekday => "weekday"
    | MonthDay => "day of the month"
    | Hour => "hour"
    }
    <div className="flex flex-col gap-3">
      {switch step {
      | 0 =>
        <>
          {line(`How often a retry worked at each ${unit}, out of how many tries.`)}
          <Formula text="k = retries that worked, n = retries tried" />
          <Formula text={`${focus.name}: k = ${k}, n = ${n}`} />
        </>
      | 1 =>
        <>
          {line(
            "How often each slot works. The +1 and +2 stop a slot with few tries from looking perfect.",
          )}
          <Formula text="p̂ = (k + 1) / (n + 2)" />
          <Formula text={`(${k} + 1) / (${n} + 2) = ${focus.p->pct(~digits=1)}`} />
        </>
      | 2 =>
        <>
          {line("Fewer tries means more doubt. A small number is a sure number.")}
          <Formula text="SE = √( p̂ × (1 − p̂) / (n + 3) )" />
          <Formula
            text={`√( ${focus.p->fixed(3)} × ${(1.0 -. focus.p)->fixed(3)} / ${(focus.tries + 3)
                ->Int.toString} ) = ±${focus.se->pct(~digits=1)}`}
          />
        </>
      | 3 =>
        <>
          {line(
            "The chance that the outlined slot beats each other slot, given the doubt on both.",
          )}
          <Formula text="C = Φ( (p̂A − p̂B) / √(SE²A + SE²B) )" />
          {switch rival {
          | Some(b) =>
            let z = (focus.p -. b.p) /. Math.sqrt(focus.se *. focus.se +. b.se *. b.se)
            <Formula
              text={`${focus.name} vs ${b.name}: z = (${focus.p->fixed(3)} − ${b.p->fixed(
                  3,
                )}) / √(${focus.se->fixed(4)}² + ${b.se->fixed(4)}²) = ${z->fixed(
                  2,
                )}, C = Φ(${z->fixed(2)}) = ${phi(z)->pct(~digits=1)}`}
            />
          | None => React.null
          }}
        </>
      | 4 =>
        let scoredCount = cells->Array.filter(c => c.scored)->Array.length
        <>
          {line(
            "One number per slot: the average of its head-to-heads. Above 0 means it usually wins.",
          )}
          <Formula text="score = average of log( C / (1 − C) )" />
          <Formula
            text={`${focus.name}: ${focus.score->signed} (over ${(scoredCount - 1)
                ->Int.toString} other slots)`}
          />
        </>
      | 5 =>
        <>
          {line("The scores become slices of 100%. A higher score gets a bigger slice.")}
          <Formula text="share = e^score / Σ e^score" />
          <Formula text={`${focus.name}: ${focus.share->pct(~digits=2)}`} />
        </>
      | _ =>
        switch dim {
        | Hour =>
          <>
            {line("The engine draws the hour with these chances.")}
            <Formula text="P(hour) = share" />
            <Formula text={`It drew ${pick.name}: ${pick.share->pct(~digits=1)} chance.`} />
          </>
        | _ =>
          <>
            {line(
              `A calendar day takes the larger of its weekday and day-of-month scores. The ${budget->Int.toString} best of the next ${windowDays->Int.toString} days go in the plan. Every other day keeps at least ${floor->pct}.`,
            )}
            <Formula text="Rev Rec acts on the soonest day in the plan." />
            <Formula
              text={`It picked ${pickLabel}: ${pickChance >= 0.995
                  ? "always in the plan"
                  : `${pickChance->pct} chance in the plan`}, and the soonest.`}
            />
          </>
        }
      }}
    </div>
  }
}

// slot: the picked real-life moment (ISO); dayBy: what the model ranked the day by; pickChance:
// the picked day's chance to be in the plan
@react.component
let make = (
  ~counts: SimulatorPickCharts.counts,
  ~cluster,
  ~slot,
  ~dayBy,
  ~pickChance,
  ~budget,
  ~windowDays,
  ~floor,
  ~isOpen,
  ~onClose,
) => {
  let picked = Date.fromString(slot)
  let pickIndex = dim =>
    switch dim {
    | Weekday => picked->SimulatorPickCharts.dowOf
    | MonthDay => picked->Date.getUTCDate - 1
    | Hour => picked->Date.getUTCHours
    }
  let firstDim = dayBy == "day of month" ? MonthDay : Weekday
  let (dim, setDim) = React.useState(_ => firstDim)
  let (step, setStep) = React.useState(_ => 0)
  let (focusAt, setFocusAt) = React.useState(_ => pickIndex(firstDim))

  let shortDays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
  let cells = switch dim {
  | Weekday => counts.dow->build(~nameOf=i => shortDays->Array.getUnsafe(i))
  | MonthDay => counts.dom->build(~nameOf=i => SimulatorPickCharts.ordinal(i + 1))
  | Hour => counts.hod->build(~nameOf=SimulatorPickCharts.hourLabel)
  }
  // Weekday: Mon-Wed, then Thu-Sun, each row full width (12 columns: 3 × 4, then 4 × 3); day of
  // month: a 7 × 5 calendar; hour: 6 × 4 (night to evening)
  let big = dim == Weekday
  let columns = switch dim {
  | Weekday => 12
  | Hour => 6
  | MonthDay => 7
  }
  let spanOf = i => big ? Some(i < 3 ? "span 4" : "span 3") : None
  let blanks = dim == MonthDay ? 35 - cells->Array.length : 0
  let pick = cells->Array.getUnsafe(pickIndex(dim))
  let focus = cells->Array.get(focusAt)->Option.getOr(pick)
  // Step 3's worked example: the followed slot against the pick, or against the best other slot
  let rival =
    focus.index != pick.index
      ? Some(pick)
      : cells
        ->Array.filter(c => c.scored && c.index != focus.index)
        ->Array.reduce(None, (best, c) =>
          switch best {
          | Some(b) if b.p >= c.p => best
          | _ => Some(c)
          }
        )
  let pickLabel = {
    let month = SimulatorPickCharts.months->Array.getUnsafe(picked->Date.getUTCMonth)
    let weekday = SimulatorPickCharts.weekdays->Array.getUnsafe(picked->SimulatorPickCharts.dowOf)
    `${weekday}, ${month} ${picked->Date.getUTCDate->Int.toString} · ${picked
      ->Date.getUTCHours
      ->SimulatorPickCharts.hourLabel} UTC`
  }

  let views = cells->Array.map(c => cellView(c, ~step, ~focus, ~dim))
  let heats = views->Array.filterMap(((_, _, h)) => h)
  let lo = heats->Array.reduce(infinity, Math.min)
  let hi = heats->Array.reduce(neg_infinity, Math.max)

  let switchDim = d => {
    setDim(_ => d)
    setFocusAt(_ => pickIndex(d))
  }
  let tab = (d, label) =>
    <button
      key=label
      className={`px-3 py-1.5 rounded-md ${body.sm.semibold} ${dim == d
          ? "bg-white text-primary shadow-sm"
          : "text-nd_gray-600 hover:text-nd_gray-800"}`}
      onClick={_ => switchDim(d)}>
      {label->React.string}
    </button>

  <Modal
    showModal=isOpen
    setShowModal={_ => onClose()}
    closeOnOutsideClick=true
    modalHeading="Step through the pick"
    modalClass="w-full max-w-[1040px] max-h-[90vh] mx-auto my-auto !bg-white rounded-xl overflow-hidden flex flex-col"
    childClass="flex flex-col min-h-0 overflow-y-auto">
    <AddDataAttributes attributes=[("data-sim", "slot-walk")]>
      <div className="flex flex-col gap-4 px-6 pt-3 pb-6">
        <div className="flex flex-col gap-0.5">
          <p className={`${body.md.medium} text-nd_gray-600`}>
            {`The engine's own formulas, on the counts it read for ${cluster->reasonOf}. Click a cell to follow it.`->React.string}
          </p>
          <p className={`${body.sm.medium} text-nd_gray-500`}>
            {"This engine groups the counts by decline code only. Card type, country, network and issuer are not used."->React.string}
          </p>
        </div>
        <div className="flex items-center gap-1 self-start rounded-lg bg-nd_gray-100 p-1">
          {tab(Weekday, "Weekday")}
          {tab(MonthDay, "Day of month")}
          {tab(Hour, "Hour (UTC)")}
        </div>
        <div className="flex flex-col lg:flex-row gap-5 lg:items-stretch lg:min-h-[360px]">
          <div className="flex flex-col gap-3 w-full lg:flex-[1.2] min-w-0">
            <div
              className={`grid flex-1 ${big ? "gap-2" : "gap-1"}`}
              style={ReactDOM.Style.make(
                ~gridTemplateColumns=`repeat(${columns->Int.toString}, minmax(0, 1fr))`,
                ~gridAutoRows=big ? "minmax(96px, 1fr)" : "minmax(56px, 1fr)",
                (),
              )}>
              {cells
              ->Array.mapWithIndex((c, i) => {
                let (value, sub, h) = views->Array.getUnsafe(i)
                let (bg, fg) = switch h {
                | Some(v) => heat(hi > lo ? (v -. lo) /. (hi -. lo) : 0.5)
                | None => (c.scored ? "#F1F5F9" : "#F8FAFC", c.scored ? "#1F2937" : "#98A2B3")
                }
                let colour = ReactDOM.Style.make(~background=bg, ~color=fg, ())
                <button
                  key={c.name}
                  ariaLabel={`${c.name}: ${value} ${sub}`}
                  className={`relative ${big
                      ? "rounded-lg gap-1"
                      : "rounded-md"} flex flex-col items-center justify-center leading-tight transition-colors ${c.index ==
                      focus.index
                      ? "ring-[3px] ring-nd_gray-800 ring-inset"
                      : ""}`}
                  style={switch spanOf(i) {
                  | Some(span) =>
                    colour->ReactDOM.Style.combine(ReactDOM.Style.make(~gridColumn=span, ()))
                  | None => colour
                  }}
                  onClick={_ => setFocusAt(_ => i)}>
                  <span className={`${big ? "text-sm" : "text-[10px]"} opacity-75`}>
                    {c.name->React.string}
                  </span>
                  <span className={`${big ? "text-xl" : "text-sm"} font-semibold tabular-nums`}>
                    {value->React.string}
                  </span>
                  <RenderIf condition={sub != ""}>
                    <span className={`${big ? "text-xs" : "text-[10px]"} opacity-75`}>
                      {sub->React.string}
                    </span>
                  </RenderIf>
                  <RenderIf condition={c.index == pick.index}>
                    <span
                      className={`absolute ${big
                          ? "top-2 right-2 w-2.5 h-2.5"
                          : "top-1 right-1 w-2 h-2"} rounded-full bg-primary ring-2 ring-white`}
                    />
                  </RenderIf>
                </button>
              })
              ->React.array}
              // The calendar's empty days, so the month keeps its shape
              {Array.fromInitializer(~length=blanks, i =>
                <div
                  key={`blank${i->Int.toString}`}
                  className="rounded-md border border-dashed border-nd_gray-150"
                />
              )->React.array}
            </div>
            <div
              className={`flex flex-wrap items-center gap-x-4 gap-y-1 ${body.sm.medium} text-nd_gray-500`}>
              <span className="flex items-center gap-2">
                {"Worse"->React.string}
                <span
                  className="inline-block w-24 h-2 rounded"
                  style={ReactDOM.Style.make(
                    ~background="linear-gradient(90deg, rgb(239,142,142), rgb(251,228,168), rgb(124,201,106))",
                    (),
                  )}
                />
                {"Better"->React.string}
              </span>
              <span className="flex items-center gap-1.5">
                <span className="w-2 h-2 rounded-full bg-primary" />
                {"Rev Rec's pick"->React.string}
              </span>
              <span> {"Outlined: the cell you follow"->React.string} </span>
            </div>
          </div>
          <div
            className="w-full lg:flex-1 min-w-0 rounded-xl border border-nd_gray-150 bg-white p-4 flex flex-col gap-2"
            ariaLive=#polite>
            <span className={`${body.sm.semibold} text-nd_gray-500`}>
              {(step == 0 ? "Start" : `Step ${step->Int.toString} of 6`)->React.string}
            </span>
            <span className={`${body.lg.semibold} text-nd_gray-800`}>
              {stepTitles->Array.getUnsafe(step)->React.string}
            </span>
            <Explain step dim focus rival cells pick budget windowDays floor pickLabel pickChance />
          </div>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Button
            text="Back"
            buttonType=Secondary
            buttonSize=Small
            buttonState={step == 0 ? Disabled : Normal}
            onClick={_ => setStep(s => Math.Int.max(s - 1, 0))}
          />
          <Button
            text={step < 6 ? `Run step ${(step + 1)->Int.toString}` : "Done"}
            buttonType=Primary
            buttonSize=Small
            buttonState={step == 6 ? Disabled : Normal}
            onClick={_ => setStep(s => Math.Int.min(s + 1, 6))}
          />
          <Button
            text="Reset"
            buttonType=Secondary
            buttonSize=Small
            onClick={_ => {
              setStep(_ => 0)
              setFocusAt(_ => pickIndex(dim))
            }}
          />
          <div className="ml-auto flex gap-1.5" ariaHidden=true>
            {stepTitles
            ->Array.mapWithIndex((t, i) =>
              <span
                key=t
                className={`w-2 h-2 rounded-full ${i <= step ? "bg-primary" : "bg-nd_gray-200"}`}
              />
            )
            ->React.array}
          </div>
        </div>
        <p className={`${body.sm.medium} text-nd_gray-500`}>
          {"Adapted from Anand's Retry Slot Playground, used with permission. Counts: seeded, plus this demo's own results."->React.string}
        </p>
      </div>
    </AddDataAttributes>
  </Modal>
}
