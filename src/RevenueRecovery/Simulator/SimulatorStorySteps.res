// The invoice story as a story (simulator/STORY-DESIGN.md): steps grouped under phase headings,
// plumbing folded into its parent step, plain-words titles with an actor chip and a status chip,
// on one timeline rail like the invoice page's Attempts History.
open SimulatorTypes
open SimulatorUtils
open SimulatorStoryHelper
open Typography

type tone = ToneOk | ToneDeclined | ToneRevRec | TonePending | ToneInfo

// The outcome card's colour: green when Rev Rec recovered, red when it stopped, grey otherwise
type outcomeTone = OutcomeGreen | OutcomeRed | OutcomeGrey

// One thing the viewer reads: a step under a phase, or the outcome card
type storyItem = {
  phase: int,
  actor: option<actor>,
  title: string,
  chip: option<(string, tone)>,
  // Folded plumbing, for example "saved card ••4242 on file"
  detail: string,
  tone: tone,
  at: string,
  // While Rev Rec's booked retry has not run: its time, shown as a countdown
  pendingAt: option<string>,
  // The raw event the drawer opens
  row: option<diagramRow>,
  outcome: option<outcomeTone>,
  // Raw events up to here are covered, for "Show all events"
  lastRawIndex: int,
}

// Phase 6 is the outcome; phase 5 shows only when the customer acted
let outcomePhase = 6

let phaseTitle = phase =>
  switch phase {
  | 1 => "The charge fails"
  | 2 => "Rev Rec is told"
  | 3 => "Rev Rec plans a retry"
  | 4 => "Rev Rec retries"
  | 5 => "The customer acts"
  | _ => "Outcome"
  }

// ---------- reading the proxy's event labels (English; see NOTES "hard-coded") ----------

let capture = (re, text) =>
  re->RegExp.exec(text)->Option.flatMap(result => result->RegExp.Result.matches->Array.get(0))

let cardOf = label => %re("/••(\d{4})/")->capture(label)->Option.getOr("")
let amountOf = label =>
  %re("/([$€£][\d.,]+|[\d.,]+ [A-Z]{3})/")->capture(label)->Option.getOr("")
let httpStatusOf = label => %re("/→ (\d{3})/")->capture(label)->Option.getOr("")
let reasonOf = label =>
  %re("/declined \(([^)]+)\)/")
  ->capture(label)
  ->Option.map(reason => reason->String.replaceRegExp(%re("/_/g"), " "))

// "pick retry time → 18:20:31" is UTC on the day of the event; show it in the viewer's time
let bookedTimeOf = (row: diagramRow) =>
  switch %re("/(\d{2}:\d{2}:\d{2})/")->capture(row.label) {
  | Some(hms) if row.at->String.length >= 10 =>
    `${row.at->String.slice(~start=0, ~end=10)}T${hms}Z`->toClockTime
  | _ => ""
  }

let toneOf = status =>
  switch status {
  | StepOk => ToneOk
  | StepDeclined | StepFailed => ToneDeclined
  | StepPending => TonePending
  | StepInfo => ToneInfo
  }

let chargeChip = (row: diagramRow) =>
  switch row.status {
  | StepOk => Some(("Approved", ToneOk))
  | StepDeclined | StepFailed =>
    Some((
      row.label->reasonOf->Option.mapOr("Declined", reason => `Declined · ${reason}`),
      ToneDeclined,
    ))
  | _ => None
  }

let hardDeclines = ["stolen card", "lost card", "pickup card", "fraudulent"]

let outcomeTitle = (story: story) => {
  let hardDecline =
    story.timeline->Array.some(row =>
      row.label->reasonOf->Option.mapOr(false, reason => hardDeclines->Array.includes(reason))
    )
  switch story.stage {
  | Recovered if story.recoveredBy == "revrec" => ("Invoice recovered by Rev Rec", OutcomeGreen)
  | Recovered => ("Invoice paid outside Rev Rec", OutcomeGrey)
  | Terminated => (hardDecline ? "Rev Rec stopped: hard decline" : "Rev Rec stopped", OutcomeRed)
  | Cancelled => ("Invoice cancelled", OutcomeGrey)
  | StoryError => ("The story stopped with an error", OutcomeRed)
  | stage => (`Story complete: the invoice is still ${stage->stageName}`, OutcomeGrey)
  }
}

// The Stripe customer the billing system created, from its own request log
let customerIdOf = (story: story) =>
  story.requests
  ->Array.find(request => request.method == "POST" && request.url->String.endsWith("/v1/customers"))
  ->Option.mapOr("", request =>
    request.response
    ->LogicUtils.getDictFromJsonObject
    ->LogicUtils.getDictfromDict("body")
    ->LogicUtils.getString("id", "")
  )

// The story header ("Invoice $65.40 · customer cus_… · card ••4242") and its items, built from
// every event that has arrived. Repeats fold into one step: three declined billing charges are
// one step with "3 tries" in its detail line.
let buildStoryItems = (story: story) => {
  let items: array<storyItem> = []
  let amount = ref("")
  let savedCard = ref("")
  let appCard = ref("")
  let chargeIndex = ref(-1)
  let chargeCount = ref(0)
  let reportIndex = ref(-1)
  let outcomeDetails = []
  let outcomeRow = ref(None)
  // The card of the billing system's own charge; the proxy's label leaves it out
  let firstChargeCard = switch story.firstChargeCard {
  | "" => story.form->Option.mapOr("", form => form.firstCharge)
  | card => card
  }

  let push = (item: storyItem) => items->Array.push(item)->ignore
  let update = (index, change) =>
    items->Array.get(index)->Option.forEach(item => items->Array.set(index, change(item)))
  let step = (~row: diagramRow, ~index, ~phase, ~actor, ~title, ~chip, ~tone) => {
    phase,
    actor: Some(actor),
    title,
    chip,
    detail: "",
    tone,
    at: row.at,
    pendingAt: None,
    row: Some(row),
    outcome: None,
    lastRawIndex: index,
  }
  let lastIndexOfPhase = phase =>
    items->Array.reduceWithIndex(-1, (found, item, index) => item.phase == phase ? index : found)

  story.timeline->Array.forEachWithIndex((row, index) => {
    let label = row.label
    let startsWith = prefix => label->String.startsWith(prefix)
    switch (row.from, row.to) {
    | (Billing, Billing) => amount := label->amountOf
    | (_, Processor) if startsWith("save card") => savedCard := label->cardOf
    | (Customer, Processor) if startsWith("add card") => appCard := label->cardOf
    | (Billing, Processor) => {
        chargeCount := chargeCount.contents + 1
        let card = switch label->cardOf {
        | "" => firstChargeCard
        | card => card
        }
        let cardText = card->LogicUtils.isNonEmptyString ? ` on ••${card}` : ""
        // The saved card is in the step that uses it, so only the number of tries is added
        let detail =
          chargeCount.contents > 1
            ? `${chargeCount.contents->Int.toString} tries, last one ${row.status == StepOk
                  ? "approved"
                  : "declined"}`
            : ""
        let item = {
          ...step(
            ~row,
            ~index,
            ~phase=1,
            ~actor=Billing,
            ~title=`Charged ${label->amountOf}${cardText}`,
            ~chip=row->chargeChip,
            ~tone=row.status->toneOf,
          ),
          detail,
        }
        switch chargeIndex.contents {
        | -1 => {
            chargeIndex := items->Array.length
            push(item)
          }
        // Keep the first charge's title, row and time; the chip shows how the last try ended
        | existing =>
          update(existing, first => {...item, title: first.title, at: first.at, row: first.row})
        }
      }
    | (Billing, RevRec) if startsWith("report failure") => {
        let code = label->httpStatusOf
        let recorded = code == "200"
        let item = step(
          ~row,
          ~index,
          ~phase=2,
          ~actor=Billing,
          ~title="Reported the failure to Rev Rec",
          // A check when Rev Rec recorded it; the HTTP code when it did not
          ~chip=code->LogicUtils.isNonEmptyString
            ? Some((recorded ? "✓" : code, recorded ? ToneOk : ToneDeclined))
            : None,
          ~tone=recorded ? ToneOk : ToneDeclined,
        )
        switch reportIndex.contents {
        | -1 => {
            reportIndex := items->Array.length
            push(item)
          }
        | existing => update(existing, first => {...item, at: first.at, row: first.row})
        }
      }
    | (Billing, RevRec) if startsWith("report same failure again") => {
        let refused = label->String.includes("already recorded")
        push(
          step(
            ~row,
            ~index,
            ~phase=2,
            ~actor=Billing,
            ~title="Reported the same failure again",
            ~chip=Some(refused ? ("Refused", ToneInfo) : ("✓", ToneOk)),
            ~tone=ToneInfo,
          ),
        )
      }
    | (Billing, RevRec) if startsWith("report paid outside") => {
        outcomeDetails
        ->Array.push(`Reported to Rev Rec (${label->httpStatusOf})`)
        ->ignore
        outcomeRow := Some(row)
      }
    | (Billing, RevRec) if startsWith("cancel invoice") => {
        outcomeDetails
        ->Array.push(`Merchant cancelled it (${label->httpStatusOf})`)
        ->ignore
        outcomeRow := Some(row)
      }
    | (Customer, Processor) => {
        let card =
          appCard.contents->LogicUtils.isNonEmptyString ? ` with ••${appCard.contents}` : ""
        push(
          step(
            ~row,
            ~index,
            ~phase=5,
            ~actor=Customer,
            ~title=`Paid ${label->amountOf} in the app${card}`,
            ~chip=row->chargeChip,
            ~tone=row.status->toneOf,
          ),
        )
      }
    | (RevRec, RevRec) =>
      push(
        step(
          ~row,
          ~index,
          ~phase=3,
          ~actor=RevRec,
          ~title=`Picked a retry time: ${row->bookedTimeOf}`,
          ~chip=None,
          ~tone=ToneRevRec,
        ),
      )
    // The booked retry belongs to the step that picked its time; its dot turns dashed
    | (RevRec, Processor) if row.status == StepPending =>
      switch lastIndexOfPhase(3) {
      | -1 =>
        push({
          ...step(
            ~row,
            ~index,
            ~phase=3,
            ~actor=RevRec,
            ~title=`Booked a retry for ${row.at->toClockTime}`,
            ~chip=None,
            ~tone=TonePending,
          ),
          pendingAt: Some(row.at),
        })
      | existing =>
        update(existing, item => {...item, pendingAt: Some(row.at), lastRawIndex: index})
      }
    | (RevRec, Processor) => {
        let card = label->cardOf
        push(
          step(
            ~row,
            ~index,
            ~phase=4,
            ~actor=RevRec,
            ~title=card->LogicUtils.isNonEmptyString
              ? `Charged the saved card ••${card}`
              : "Charged the saved card",
            ~chip=row->chargeChip,
            ~tone=row.status->toneOf,
          ),
        )
      }
    // "invoice recovered → mark paid" / "invoice paid outside Rev Rec": the outcome card's title
    // already says how it ended, so only the billing system's follow-up is added
    | (RevRec, Billing) => {
        if label->String.includes("mark paid") {
          outcomeDetails->Array.push("Billing system marked it paid")->ignore
        }
        outcomeRow := Some(row)
      }
    | (from, _) =>
      push(
        step(
          ~row,
          ~index,
          ~phase=Math.Int.min(row.phase, 4),
          ~actor=from,
          ~title=label,
          ~chip=None,
          ~tone=row.status->toneOf,
        ),
      )
    }
  })

  if story.done || story.stage->isFinalStage {
    let (title, tone) = story->outcomeTitle
    let errorDetail = story.stage == StoryError ? [story.startError] : []
    push({
      phase: outcomePhase,
      actor: None,
      title,
      chip: None,
      detail: outcomeDetails
      ->Array.concat(errorDetail)
      ->Array.filter(LogicUtils.isNonEmptyString)
      ->Array.joinWith(" · "),
      tone: ToneInfo,
      at: outcomeRow.contents->Option.mapOr("", row => row.at),
      pendingAt: None,
      row: outcomeRow.contents,
      outcome: Some(tone),
      lastRawIndex: story.timeline->Array.length - 1,
    })
  }

  let customerId = story->customerIdOf
  let card = savedCard.contents->LogicUtils.isNonEmptyString ? savedCard.contents : firstChargeCard
  let header =
    [
      amount.contents->LogicUtils.isNonEmptyString ? `Invoice ${amount.contents}` : "Invoice",
      customerId->LogicUtils.isNonEmptyString ? `customer ${customerId}` : "",
      card->LogicUtils.isNonEmptyString ? `card ••${card}` : "",
    ]
    ->Array.filter(LogicUtils.isNonEmptyString)
    ->Array.joinWith(" · ")
  (header, items)
}

let moneyText = (form: billingForm) =>
  form.currency == "USD" ? `$${form.amount}` : `${form.amount} ${form.currency}`

// Shown the instant Charge customer is pressed, and until the first charge lands
let creatingItem = (~form: option<billingForm>): storyItem => {
  phase: 1,
  actor: Some(Billing),
  title: form->Option.mapOr("Creates the invoice", form => `Creates invoice ${form->moneyText}`),
  chip: None,
  detail: "",
  tone: TonePending,
  at: "",
  pendingAt: None,
  row: None,
  outcome: None,
  lastRawIndex: -1,
}

// ---------- pacing over items (STORY-STEPS.md section 6) ----------

// The billing system's part shows by itself; the story pauses before Rev Rec's first step
let autoItemCount = (items: array<storyItem>) =>
  switch items->Array.findIndex(item => item.phase >= 3) {
  | -1 => items->Array.length
  | index => index
  }

let visibleItemCount = (~items: array<storyItem>, ~revealLimit, ~autoPlay) =>
  autoPlay
    ? items->Array.length
    : Math.Int.min(items->Array.length, Math.Int.max(items->autoItemCount, revealLimit))

// ---------- rendering ----------

let actorChipClass = actor =>
  switch actor {
  | Billing => "bg-nd_gray-100 text-nd_gray-700"
  | RevRec => "bg-nd_primary_blue-50 text-nd_primary_blue-600"
  | Processor => "bg-nd_orange-50 text-nd_orange-600"
  | Customer => "bg-nd_yellow-50 text-nd_yellow-700"
  }

let actorChipText = actor =>
  switch actor {
  | Billing => "Billing"
  | RevRec => "Rev Rec"
  | Processor => "Bank"
  | Customer => "Customer"
  }

let toneChipClass = tone =>
  switch tone {
  | ToneOk => "bg-nd_green-50 text-nd_green-600"
  | ToneDeclined => "bg-nd_red-50 text-nd_red-600"
  | ToneRevRec | TonePending => "bg-nd_primary_blue-50 text-nd_primary_blue-600"
  | ToneInfo => "bg-nd_gray-100 text-nd_gray-600"
  }

// Rail dot: grey pending, green ok, red declined, blue for a Rev Rec action
let dotClass = tone =>
  switch tone {
  | ToneOk => "bg-nd_green-400"
  | ToneDeclined => "bg-nd_red-500"
  | ToneRevRec => "bg-nd_primary_blue-450"
  | TonePending => "bg-white border border-dashed border-nd_gray-500"
  | ToneInfo => "bg-nd_gray-300"
  }

let phaseDomId = phase => `sim-phase-${phase->Int.toString}`

// "+1 min 12 s since charge", for the time's hover text
let sinceText = (~at, ~firstAt) =>
  if at->LogicUtils.isEmptyString || firstAt->LogicUtils.isEmptyString {
    ""
  } else {
    let seconds = ((at->toMillis -. firstAt->toMillis) /. 1000.0)->Float.toInt
    seconds < 60
      ? `+${seconds->Int.toString} s since charge`
      : `+${(seconds / 60)->Int.toString} min ${mod(seconds, 60)->Int.toString} s since charge`
  }

// "in 0:28" until the booked retry
module ClockCountdown = {
  @react.component
  let make = (~until) => {
    let (nowMs, setNowMs) = React.useState(_ => Date.now())
    React.useEffect(() => {
      let intervalId = setInterval(() => setNowMs(_ => Date.now()), 1000)
      Some(() => clearInterval(intervalId))
    }, [])
    let seconds = ((until->toMillis -. nowMs) /. 1000.0)->Float.toInt
    let rest = mod(seconds, 60)
    let text =
      seconds <= 0
        ? "due now"
        : `in ${(seconds / 60)->Int.toString}:${rest < 10 ? "0" : ""}${rest->Int.toString}`
    text->React.string
  }
}

module Chip = {
  @react.component
  let make = (~className, ~children) => {
    <span
      className={`shrink-0 whitespace-nowrap rounded px-1.5 py-0.5 ${body.sm.semibold} ${className}`}>
      children
    </span>
  }
}

// A phase heading on the rail, with a larger dot
module PhaseHeading = {
  @react.component
  let make = (~phase, ~domId=?, ~isFirst, ~revealClass, ~animationDelay) => {
    <div
      id=?domId
      className={`flex items-center gap-3 ${isFirst ? "" : "mt-3"} ${revealClass}`}
      style={animationDelay: ?animationDelay}>
      <div className="w-8 shrink-0 flex justify-center">
        <div
          className="relative z-10 w-4 h-4 rounded-full bg-nd_gray-100 border-2 border-nd_gray-300"
        />
      </div>
      <p className={`${body.sm.semibold} text-nd_gray-500 uppercase tracking-wide`}>
        {phase->phaseTitle->React.string}
      </p>
    </div>
  }
}

// A flat step on the rail: dot, actor chip, sentence, status chip, "?", time; a muted detail line
// only when it adds something
module StepRow = {
  @react.component
  let make = (
    ~domId,
    ~item: storyItem,
    ~isNewest,
    ~firstAt,
    ~revealClass,
    ~animationDelay,
    ~onOpen,
    ~time=?,
    ~children=React.null,
  ) => {
    let tone = item.pendingAt->Option.isSome ? TonePending : item.tone
    let canOpen = item.row->Option.isSome
    <div
      id=domId
      className={`flex items-start gap-3 ${canOpen ? "cursor-pointer" : ""} ${revealClass}`}
      style={animationDelay: ?animationDelay}
      onClick={_ => canOpen ? onOpen() : ()}>
      <div className="w-8 shrink-0 flex justify-center pt-2.5">
        <div className={`relative z-10 w-2.5 h-2.5 rounded-full ${tone->dotClass}`} />
      </div>
      // The newest step glows with a primary-blue edge until the next one lands
      <div
        className={`flex-1 min-w-0 flex flex-col gap-1 rounded-r-md py-1.5 pl-3 pr-2 border-l-2 hover:bg-nd_gray-25 ${isNewest
            ? "border-nd_primary_blue-450 bg-nd_primary_blue-25"
            : "border-transparent"}`}>
        <div className="flex items-start gap-2">
          {switch item.actor {
          | Some(actor) =>
            <Chip className={`mt-0.5 ${actor->actorChipClass}`}>
              {actor->actorChipText->React.string}
            </Chip>
          | None => React.null
          }}
          // The status chip follows the sentence and drops below it when the line is full
          <div className="flex-1 min-w-0 flex flex-wrap items-center gap-x-2 gap-y-1">
            <p
              className={`${body.md.semibold} text-nd_gray-800 min-w-0`}
              style={overflowWrap: "anywhere"}>
              {item.title->React.string}
            </p>
            {switch (item.pendingAt, item.chip) {
            | (Some(until), _) =>
              <Chip className={TonePending->toneChipClass}>
                <ClockCountdown until />
              </Chip>
            | (None, Some((text, chipTone))) =>
              <Chip className={chipTone->toneChipClass}> {text->React.string} </Chip>
            | _ => React.null
            }}
          </div>
          <RenderIf condition=canOpen>
            <HelpButton onClick=onOpen />
          </RenderIf>
          <span
            className={`shrink-0 w-24 flex justify-end ${body.sm.regular} text-nd_gray-400`}
            title={sinceText(~at=item.at, ~firstAt)}>
            {switch time {
            | Some(element) => element
            | None =>
              (item.at->LogicUtils.isNonEmptyString ? item.at->toClockTime : "")->React.string
            }}
          </span>
        </div>
        <RenderIf condition={item.detail->LogicUtils.isNonEmptyString}>
          <p className={`${body.sm.medium} text-nd_gray-500`}> {item.detail->React.string} </p>
        </RenderIf>
        children
      </div>
    </div>
  }
}

// The only filled card: how the story ended
module OutcomeCard = {
  @react.component
  let make = (~item: storyItem, ~revealClass, ~animationDelay, ~onOpen) => {
    let (cardClass, dot, icon) = switch item.outcome {
    | Some(OutcomeGreen) => (
        "bg-nd_green-50 border-nd_green-200 text-nd_green-600",
        "bg-nd_green-400",
        "nd-check",
      )
    | Some(OutcomeRed) => (
        "bg-nd_red-50 border-nd_red-200 text-nd_red-600",
        "bg-nd_red-500",
        "nd-cross",
      )
    | _ => ("bg-nd_gray-50 border-nd_gray-200 text-nd_gray-600", "bg-nd_gray-400", "nd-check")
    }
    let canOpen = item.row->Option.isSome
    <div
      id=doneDomId
      className={`flex items-start gap-3 mt-3 ${canOpen ? "cursor-pointer" : ""} ${revealClass}`}
      style={animationDelay: ?animationDelay}
      onClick={_ => canOpen ? onOpen() : ()}>
      <div className="w-8 shrink-0 flex justify-center pt-4">
        <div className={`relative z-10 w-3 h-3 rounded-full ${dot}`} />
      </div>
      <div className={`flex-1 rounded-xl border px-4 py-3 flex items-start gap-3 ${cardClass}`}>
        <Icon name=icon size=16 className="mt-0.5" />
        <div className="flex-1 flex flex-col gap-0.5">
          <p className={body.md.semibold}> {item.title->React.string} </p>
          <RenderIf condition={item.detail->LogicUtils.isNonEmptyString}>
            <p className={`${body.sm.medium} opacity-80`}> {item.detail->React.string} </p>
          </RenderIf>
        </div>
        <RenderIf condition=canOpen>
          <HelpButton onClick=onOpen />
        </RenderIf>
      </div>
    </div>
  }
}

// The phases, as a horizontal step indicator in the dashboard's style. "The customer acts"
// shows only when the customer did act.
module PhaseStrip = {
  @react.component
  let make = (~items: array<storyItem>, ~isFinished, ~onPhaseClick) => {
    let reached = phase => items->Array.some(item => item.phase == phase)
    let phases = [1, 2, 3, 4, 5, outcomePhase]->Array.filter(phase => phase != 5 || reached(5))
    let current = isFinished ? None : items->Array.at(-1)->Option.map(item => item.phase)
    let lastIndex = phases->Array.length - 1

    <div className="flex items-start">
      {phases
      ->Array.mapWithIndex((phase, index) => {
        let isReached = reached(phase)
        let isCurrent = current == Some(phase)
        let circleClass = switch (isCurrent, isReached) {
        | (true, _) => "bg-nd_primary_blue-450 border-nd_primary_blue-450 text-white animate-pulse"
        | (false, true) => "bg-nd_primary_blue-450 border-nd_primary_blue-450 text-white"
        | _ => "bg-white border-nd_gray-200 text-nd_gray-400"
        }
        let nextReached = phases->Array.get(index + 1)->Option.mapOr(false, reached)
        <React.Fragment key={phase->Int.toString}>
          <div
            className={`flex flex-col items-center gap-2 w-20 shrink-0 ${isReached
                ? "cursor-pointer"
                : ""}`}
            onClick={_ => isReached ? onPhaseClick(phase) : ()}>
            <div
              className={`flex items-center justify-center rounded-full w-8 h-8 border ${circleClass}`}>
              {isReached && !isCurrent
                ? <Icon name="nd-check" size=14 className="text-white" />
                : <span className={body.sm.semibold}>
                    {(index + 1)->Int.toString->React.string}
                  </span>}
            </div>
            <span
              className={`text-center ${isReached
                  ? `text-nd_gray-700 ${body.sm.semibold}`
                  : `text-nd_gray-400 ${body.sm.medium}`}`}>
              {phase->phaseTitle->React.string}
            </span>
          </div>
          <RenderIf condition={index < lastIndex}>
            <div
              className={`flex-1 border-t mt-4 ${nextReached
                  ? "border-nd_primary_blue-450"
                  : "border-gray-150"}`}
            />
          </RenderIf>
        </React.Fragment>
      })
      ->React.array}
    </div>
  }
}

// Under the phase strip: the invoice's live status badge (the Invoices list's own), the amount
// recovered and Rev Rec's attempts, so the visitor need not open the invoice page
module StatusLine = {
  @react.component
  let make = (~story: story) => {
    let order = story.invoice->RevenueRecoveryEntity.itemToObjMapperForIntents
    let order = {...order, status: story.stage->toInvoiceStatus(~default=order.status)}
    let sign =
      story.form->Option.mapOr("USD", form => form.currency)->SimulatorFormTiles.currencySign
    // Until the sandbox records the invoice, the amount is the one the billing system charged
    let total =
      story.invoice->LogicUtils.isEmptyDict
        ? story.form->Option.mapOr(0.0, form => form.amount->LogicUtils.getFloatFromString(0.0))
        : order.order_amount
    let money = amount => `${sign}${amount->Float.toFixedWithPrecision(~digits=2)}`
    let revRecAttempts =
      story.timeline
      ->Array.filter(row => row.from == RevRec && row.to == Processor && row.status != StepPending)
      ->Array.length

    <div
      className={`flex flex-wrap items-center gap-x-3 gap-y-1 ${body.md.medium} text-nd_gray-600`}>
      <RenderIf condition={order.status->LogicUtils.isNonEmptyString}>
        <Table.TableCell cell={RevenueRecoveryEntity.getCell(order, Status)} />
      </RenderIf>
      <span>
        <span className={`${body.md.semibold} text-nd_gray-800`}>
          {order.amount_captured->money->React.string}
        </span>
        {` of ${total->money} recovered`->React.string}
      </span>
      <span className="text-nd_gray-300"> {"·"->React.string} </span>
      <span>
        {`${revRecAttempts->Int.toString} Rev Rec attempt${revRecAttempts == 1
            ? ""
            : "s"}`->React.string}
      </span>
    </div>
  }
}

// The story, step by step: the phase strip as the header, a status line, then the steps on one
// rail grouped by phase.
// The raw event list and the sequence diagram are optional, behind a link and a button.
module StoryView = {
  @react.component
  let make = (
    ~story: option<story>,
    ~optimistic: option<billingForm>,
    ~items: array<storyItem>,
    ~visibleCount: int,
    ~isFinished: bool,
    ~showNext: bool,
    ~isWaitingForNext: bool,
    ~revealDelays: Dict.t<int>,
    ~autoPlay,
    ~setAutoPlay,
    ~showDiagram,
    ~setShowDiagram,
    ~inlineActions,
    ~isBusy,
    ~onNext,
    ~onRowClick,
    ~onStatesClick,
    ~onWaitingClick,
  ) => {
    let (showEvents, setShowEvents) = React.useState(_ => false)
    let rows = story->Option.mapOr([], s => s.timeline)
    let visibleItems = items->Array.slice(~start=0, ~end=visibleCount)
    // Until the first charge lands, step 1 is the billing system creating the invoice
    let isCreating = visibleItems->Array.length == 0 && !isFinished
    let shownItems = isCreating
      ? [creatingItem(~form=optimistic->Option.orElse(story->Option.flatMap(s => s.form)))]
      : visibleItems
    let lastRawIndex = visibleItems->Array.at(-1)->Option.mapOr(-1, item => item.lastRawIndex)
    let visibleRows = rows->Array.slice(~start=0, ~end=lastRawIndex + 1)
    let hasHistory = story->Option.mapOr(false, s => s.stageHistory->Array.length > 0)
    let hasStory = story->Option.isSome || optimistic->Option.isSome
    let nextLabel =
      visibleItems->Array.some(item => item.phase >= 3)
        ? "Next step →"
        : "Next: let Rev Rec retry →"
    // Rev Rec is overdue to book a retry: the proxy's note replaces the "Working…" line
    let waiting = isFinished ? None : story->Option.flatMap(s => s.waiting)
    let showWorking = hasStory && !isFinished && !showNext && waiting->Option.isNone
    let firstAt =
      items
      ->Array.find(item => item.phase == 1 && item.at->LogicUtils.isNonEmptyString)
      ->Option.mapOr("", item => item.at)
    let revealOf = index => revealDelays->Dict.get(index->Int.toString)->revealProps
    let lastIndex = shownItems->Array.length - 1
    // Less common controls live in one menu; auto-play stays off until chosen
    let menuOptions =
      [
        Some((autoPlay ? "Turn auto-play off" : "Turn auto-play on", () => setAutoPlay(!autoPlay))),
        hasHistory ? Some(("Invoice states", onStatesClick)) : None,
        story->Option.isSome
          ? Some((
              showDiagram ? "Hide sequence diagram" : "Show sequence diagram",
              () => setShowDiagram(prev => !prev),
            ))
          : None,
      ]->Array.filterMap(option => option)

    <div className={`${cardStyle} px-6 py-5 flex flex-col gap-5`}>
      <style> {revealCss->React.string} </style>
      // The phase strip is the header; before a story it shows what is coming
      <div className="flex items-start gap-4">
        <div className="flex-1 min-w-0">
          <PhaseStrip
            items={hasStory ? shownItems : []}
            isFinished
            onPhaseClick={phase => scrollToElement(phaseDomId(phase))}
          />
        </div>
        <ActionMenu options=menuOptions />
      </div>
      {switch story {
      | Some(s) => <StatusLine story=s />
      | None => React.null
      }}
      {if !hasStory {
        <p className={`${body.md.medium} text-nd_gray-500 py-6 text-center`}>
          {"Press Charge customer. Each step appears here."->React.string}
        </p>
      } else {
        <>
          {switch waiting {
          | Some(waiting) => <WaitingNoteLine waiting onWhy=onWaitingClick />
          | None => React.null
          }}
          <div className="max-w-[760px] w-full flex flex-col gap-4">
            <RenderIf condition=showWorking>
              <div className={`flex items-center gap-2 ${body.md.medium} text-nd_gray-600`}>
                <span className="relative flex h-2 w-2">
                  <span
                    className="animate-ping absolute inline-flex h-full w-full rounded-full bg-nd_primary_blue-450 opacity-75"
                  />
                  <span
                    className="relative inline-flex rounded-full h-2 w-2 bg-nd_primary_blue-450"
                  />
                </span>
                {rows->Array.at(-1)->workingText->React.string}
                // How long the wait has lasted, so a slow sandbox reads as slow, not stuck
                {switch rows->Array.at(-1) {
                | Some(row) if row.status != StepPending && row.at->LogicUtils.isNonEmptyString =>
                  <span className="text-nd_gray-400">
                    {"· "->React.string}
                    <Elapsed since=row.at />
                  </span>
                | _ => React.null
                }}
              </div>
            </RenderIf>
            // One rail, like Attempts History: a dashed line behind the dots
            <div className="relative flex flex-col gap-3">
              <div
                className="absolute left-4 top-3 bottom-3 border-l-2 border-dashed border-nd_gray-200"
              />
              {shownItems
              ->Array.mapWithIndex((item, index) => {
                let previousPhase =
                  shownItems->Array.get(index - 1)->Option.mapOr(0, previous => previous.phase)
                let isFirstOfPhase =
                  shownItems->Array.findIndex(other => other.phase == item.phase) == index
                let isLast = index == lastIndex
                let (revealClass, animationDelay) = revealOf(index)
                let onOpen = () => item.row->Option.forEach(onRowClick)
                <React.Fragment key={index->Int.toString}>
                  <RenderIf condition={item.phase != previousPhase && item.phase != outcomePhase}>
                    <PhaseHeading
                      phase=item.phase
                      domId=?{isFirstOfPhase ? Some(phaseDomId(item.phase)) : None}
                      isFirst={index == 0}
                      revealClass
                      animationDelay
                    />
                  </RenderIf>
                  {switch item.outcome {
                  | Some(_) =>
                    <div id={phaseDomId(outcomePhase)}>
                      <OutcomeCard item revealClass animationDelay onOpen />
                    </div>
                  | None =>
                    <StepRow
                      domId={stepDomId(index)}
                      item
                      isNewest={isLast && !isFinished}
                      firstAt
                      revealClass
                      animationDelay
                      onOpen
                      time=?{isCreating ? Some(<Loadericon size=14 />) : None}>
                      <RenderIf condition={isLast && !isCreating}>
                        <NextControls
                          showNext
                          nextLabel
                          isWaiting=isWaitingForNext
                          nextRetryAt={story->Option.flatMap(s => s.nextRetryAt)}
                          waiting
                          onWaitingWhy=onWaitingClick
                          onNext
                          inlineActions={isFinished ? [] : inlineActions}
                          isBusy
                        />
                      </RenderIf>
                    </StepRow>
                  }}
                </React.Fragment>
              })
              ->React.array}
            </div>
            <RenderIf condition={visibleRows->Array.length > 0}>
              <span
                className={`w-fit cursor-pointer text-blue-500 hover:text-blue-700 ${body.md.medium}`}
                onClick={_ => setShowEvents(prev => !prev)}>
                {(
                  showEvents
                    ? "Hide the event list"
                    : `Show all ${visibleRows->Array.length->Int.toString} events`
                )->React.string}
              </span>
            </RenderIf>
            <RenderIf condition=showEvents>
              <div className="flex flex-col gap-2">
                {visibleRows
                ->Array.mapWithIndex((row, index) =>
                  <StepCard
                    key={index->Int.toString}
                    domId={`sim-event-${index->Int.toString}`}
                    row
                    stepNumber={index + 1}
                    time={row.status == StepPending
                      ? <Countdown nextRetryAt=row.at />
                      : row.at->toClockTime->React.string}
                    isNewest=false
                    revealDelay=None
                    onOpen={() => onRowClick(row)}
                  />
                )
                ->React.array}
              </div>
            </RenderIf>
          </div>
          <RenderIf condition=showDiagram>
            <LifelineDiagram rows=visibleRows onRowClick />
          </RenderIf>
        </>
      }}
    </div>
  }
}
