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

// One Rev Rec retry: the time it booked and the charge it made. A retry still to run has no
// charge yet and is due at dueAt.
type retry = {
  number: int,
  booking: option<diagramRow>,
  charge: option<diagramRow>,
  dueAt: option<string>,
}

// One thing the viewer reads: a step under a phase, the retries block, or the outcome card
type storyItem = {
  phase: int,
  actor: option<actor>,
  title: string,
  chip: option<(string, tone)>,
  // Folded plumbing, for example "saved card ••4242 on file"
  detail: string,
  tone: tone,
  at: string,
  // The raw event the drawer opens
  row: option<diagramRow>,
  outcome: option<outcomeTone>,
  // Raw events up to here are covered, for "Show all events"
  lastRawIndex: int,
  // The Rev Rec retries block: one row per retry (empty for every other item)
  retries: array<retry>,
}

// Phase 6 is the outcome; phase 5 shows only when the customer acted
let outcomePhase = 6

let phaseTitle = phase =>
  switch phase {
  | 1 => "The charge fails"
  | 2 => "Rev Rec is told"
  | 3 | 4 => "Rev Rec retries"
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

// "pick retry time → 18:20:31" is UTC on the day of the event
let bookedIsoOf = (row: diagramRow) =>
  switch %re("/(\d{2}:\d{2}:\d{2})/")->capture(row.label) {
  | Some(hms) if row.at->String.length >= 10 =>
    Some(`${row.at->String.slice(~start=0, ~end=10)}T${hms}Z`)
  | _ => None
  }

// The booked time in the viewer's time zone
let bookedTimeOf = (row: diagramRow) => row->bookedIsoOf->Option.mapOr("", toClockTime)

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

// "38 s", "2 min 05 s"
let secondsInWords = seconds =>
  if seconds < 60 {
    `${seconds->Int.toString} s`
  } else {
    let rest = mod(seconds, 60)
    `${(seconds / 60)->Int.toString} min ${rest < 10 ? "0" : ""}${rest->Int.toString} s`
  }

let retriesText = count => count == 1 ? "1 retry" : `${count->Int.toString} retries`

// The end row: how the invoice ended, in one line
let outcomeTitle = (story: story, ~retries: array<retry>, ~maxRetries: option<int>) => {
  let charged = retries->Array.filter(retry => retry.charge->Option.isSome)
  let count = charged->Array.length
  let firstFailure =
    story.timeline->Array.find(row =>
      row.from == Billing && row.to == Processor && row.status != StepOk
    )
  let hardReason =
    firstFailure
    ->Option.flatMap(row => row.label->reasonOf)
    ->Option.filter(reason => hardDeclines->Array.includes(reason))
  switch story.stage {
  | Recovered if story.recoveredBy == "revrec" => {
      let approved =
        charged->Array.find(retry => retry.charge->Option.mapOr(false, row => row.status == StepOk))
      let after = switch (firstFailure, approved->Option.flatMap(retry => retry.charge)) {
      | (Some(first), Some(charge)) =>
        ` · ${((charge.at->toMillis -. first.at->toMillis) /. 1000.0)
          ->Float.toInt
          ->secondsInWords} after the first failure`
      | _ => ""
      }
      let number = approved->Option.mapOr(count, retry => retry.number)
      (`Recovered on retry ${number->Int.toString}${after}`, OutcomeGreen)
    }
  | Recovered => (
      count > 0 ? `Paid outside Rev Rec after ${count->retriesText}` : "Paid outside Rev Rec",
      OutcomeGrey,
    )
  | Terminated =>
    switch (count, hardReason, maxRetries) {
    | (0, Some(reason), _) => (`Stopped at once · hard decline (${reason})`, OutcomeRed)
    | (_, _, Some(max)) if count >= max => (
        `Stopped after ${count->retriesText} · max retries reached`,
        OutcomeRed,
      )
    | (0, None, _) => ("Rev Rec stopped", OutcomeRed)
    | _ => (`Stopped after ${count->retriesText}`, OutcomeRed)
    }
  | Cancelled => (
      count > 0 ? `Cancelled after ${count->retriesText}` : "Invoice cancelled",
      OutcomeGrey,
    )
  | StoryError => ("The story stopped with an error", OutcomeRed)
  | stage => (`Story complete: the invoice is still ${stage->stageName}`, OutcomeGrey)
  }
}

// Pairs each Rev Rec charge with its booking: the latest booking due at or before the charge. The
// proxy can note a booking after its charge, or miss one when retries come fast. A booking that is
// still to run becomes the waiting retry, due at the booked time.
let pairRetries = (
  ~bookings: array<diagramRow>,
  ~charges: array<diagramRow>,
  ~pending: option<diagramRow>,
  ~isOver,
) => {
  let dueMs =
    bookings->Array.map(booking =>
      booking->bookedIsoOf->Option.mapOr(booking.at->toMillis, iso => iso->toMillis)
    )
  let used = bookings->Array.map(_ => false)
  let retries = charges->Array.mapWithIndex((charge, index) => {
    let chargeMs = charge.at->toMillis
    let best = ref(-1)
    dueMs->Array.forEachWithIndex((ms, j) =>
      if (
        !(used->Array.getUnsafe(j)) &&
        ms <= chargeMs +. 3000.0 &&
        (best.contents < 0 || ms >= dueMs->Array.getUnsafe(best.contents))
      ) {
        best := j
      }
    )
    let booking = if best.contents >= 0 {
      used->Array.setUnsafe(best.contents, true)
      bookings->Array.get(best.contents)
    } else {
      None
    }
    {number: index + 1, booking, charge: Some(charge), dueAt: None}
  })
  let lastChargeMs = charges->Array.at(-1)->Option.mapOr(0.0, charge => charge.at->toMillis)
  let waitingIndex = ref(-1)
  dueMs->Array.forEachWithIndex((ms, j) =>
    if !(used->Array.getUnsafe(j)) && ms > lastChargeMs {
      waitingIndex := j
    }
  )
  let waitingBooking = bookings->Array.get(waitingIndex.contents)
  let dueAt = switch (isOver, pending, waitingBooking) {
  | (true, _, _) => None
  | (false, Some(row), _) => Some(row.at)
  | (false, None, Some(booking)) => booking->bookedIsoOf
  | (false, None, None) => None
  }
  switch dueAt {
  | Some(_) =>
    retries->Array.concat([
      {number: charges->Array.length + 1, booking: waitingBooking, charge: None, dueAt},
    ])
  | None => retries
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
let buildStoryItems = (story: story, ~maxRetries: option<int>) => {
  let items: array<storyItem> = []
  let amount = ref("")
  let savedCard = ref("")
  let appCard = ref("")
  let chargeIndex = ref(-1)
  let chargeCount = ref(0)
  let reportIndex = ref(-1)
  let outcomeDetails = []
  let outcomeRow = ref(None)
  // Rev Rec's retries form one block, placed where its first event came
  let retryIndex = ref(-1)
  let bookings = []
  let charges = []
  let pending = ref(None)
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
    row: Some(row),
    outcome: None,
    lastRawIndex: index,
    retries: [],
  }
  let noteRetryEvent = (~row: diagramRow, ~index) =>
    switch retryIndex.contents {
    | -1 => {
        retryIndex := items->Array.length
        push({
          ...step(
            ~row,
            ~index,
            ~phase=3,
            ~actor=RevRec,
            ~title="Rev Rec retries",
            ~chip=None,
            ~tone=ToneRevRec,
          ),
          row: None,
        })
      }
    | existing => update(existing, item => {...item, lastRawIndex: index})
    }

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
    // A booking, the booked retry still to run, and each charge: rows of the retries block
    | (RevRec, RevRec) => {
        noteRetryEvent(~row, ~index)
        bookings->Array.push(row)->ignore
      }
    | (RevRec, Processor) if row.status == StepPending => {
        noteRetryEvent(~row, ~index)
        pending := Some(row)
      }
    | (RevRec, Processor) => {
        noteRetryEvent(~row, ~index)
        charges->Array.push(row)->ignore
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
          ~phase=Math.Int.min(row.phase, 3),
          ~actor=from,
          ~title=label,
          ~chip=None,
          ~tone=row.status->toneOf,
        ),
      )
    }
  })

  let isOver = story.done || story.stage->isFinalStage
  let retries = pairRetries(~bookings, ~charges, ~pending=pending.contents, ~isOver)
  if retryIndex.contents >= 0 {
    update(retryIndex.contents, item => {...item, retries})
  }

  if isOver {
    let (title, tone) = story->outcomeTitle(~retries, ~maxRetries)
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
      row: outcomeRow.contents,
      outcome: Some(tone),
      lastRawIndex: story.timeline->Array.length - 1,
      retries: [],
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
  row: None,
  outcome: None,
  lastRawIndex: -1,
  retries: [],
}

// ---------- pacing over items (STORY-STEPS.md section 6) ----------

// The billing system's part shows by itself; the story pauses before Rev Rec's first step
let autoItemCount = (items: array<storyItem>) =>
  switch items->Array.findIndex(item => item.phase >= 3) {
  | -1 => items->Array.length
  | index => index
  }

// Once the viewer lets Rev Rec retry (or auto-play is on), every later step shows as it happens
let isFollowingLive = (~items: array<storyItem>, ~revealLimit, ~autoPlay) =>
  autoPlay || revealLimit > items->autoItemCount

let visibleItemCount = (~items: array<storyItem>, ~revealLimit, ~autoPlay) =>
  isFollowingLive(~items, ~revealLimit, ~autoPlay) ? items->Array.length : items->autoItemCount

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
    let tone = item.tone
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
            {switch item.chip {
            | Some((text, chipTone)) =>
              <Chip className={chipTone->toneChipClass}> {text->React.string} </Chip>
            | None => React.null
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

// The invoice state as one filled pill, the size and radius of the dashboard's medium button, in
// the Invoices badge colours (Monitoring blue, as asked; Processing a darker blue)
module StatePill = {
  @react.component
  let make = (~stage) => {
    let fill = switch stage {
    | Monitoring => "bg-nd_primary_blue-450 text-white"
    | Queued => "bg-nd_gray-500 text-white"
    | Scheduled => "bg-nd_orange-300 text-white"
    | Processing => "bg-nd_primary_blue-600 text-white"
    | Recovered | PartiallyRecovered => "bg-nd_green-400 text-white"
    | Terminated | StoryError => "bg-nd_red-500 text-white"
    | Cancelled => "bg-nd_gray-400 text-white"
    | Starting => "bg-nd_gray-150 text-nd_gray-600"
    }
    <span
      className={`shrink-0 h-9 px-4 rounded-10-px flex items-center whitespace-nowrap ${body.md.semibold} ${fill}`}>
      {stage->stageName->React.string}
    </span>
  }
}

// The profile's max retries: a setting of the invoice's billing connector, read once per connector
let useMaxRetries = (story: option<story>) => {
  let getURL = APIUtils.useGetURL()
  let fetchQuietly = APIUtils.useGetMethod(~showErrorToast=false)
  let (maxRetries, setMaxRetries) = React.useState(_ => None)
  let billingConnectorId =
    story->Option.mapOr("", s =>
      (s.invoice->RevenueRecoveryEntity.itemToObjMapperForIntents).billing_connector_id
    )
  React.useEffect(() => {
    if billingConnectorId->LogicUtils.isNonEmptyString {
      let load = async () =>
        try {
          let url = getURL(
            ~entityName=V2(V2_CONNECTOR),
            ~methodType=Get,
            ~id=Some(billingConnectorId),
          )
          let json = await fetchQuietly(url, ~version=V2)
          setMaxRetries(_ =>
            json
            ->LogicUtils.getDictFromJsonObject
            ->LogicUtils.getDictfromDict("feature_metadata")
            ->LogicUtils.getDictfromDict("revenue_recovery")
            ->LogicUtils.getOptionInt("max_retry_count")
          )
        } catch {
        | _ => ()
        }
      load()->ignore
    }
    None
  }, [billingConnectorId])
  maxRetries
}

// One retry, one row of the block's grid: dot | sentence | chip | ? | time. The chip is the
// charge's result, or, while the retry waits, its countdown ("in 3 s").
module RetryRow = {
  @react.component
  let make = (~retry: retry, ~maxRetries: option<int>, ~onOpen) => {
    let number = `Retry ${retry.number->Int.toString}${maxRetries->Option.mapOr("", max =>
        ` of ${max->Int.toString}`
      )}`
    let (dot, text, chip, time) = switch (retry.charge, retry.dueAt) {
    | (Some(charge), _) => {
        let card = charge.label->cardOf
        (
          charge.status->toneOf->dotClass,
          `${number} · charged ${card->LogicUtils.isNonEmptyString
              ? `••${card}`
              : "the saved card"}`,
          charge
          ->chargeChip
          ->Option.mapOr(React.null, ((label, chipTone)) =>
            <Chip className={chipTone->toneChipClass}> {label->React.string} </Chip>
          ),
          charge.at->toClockTime,
        )
      }
    | (None, dueAt) => (
        "bg-nd_gray-300 animate-pulse",
        // A non-breaking space keeps "10:13:01 AM" together when the sentence wraps
        `${number} · booked for ${dueAt->Option.mapOr("", time =>
            time->toClockTime->String.replaceRegExp(%re("/ /g"), "\u00A0")
          )}`,
        dueAt->Option.mapOr(React.null, time =>
          <Chip className={ToneInfo->toneChipClass}>
            <Countdown nextRetryAt=time />
          </Chip>
        ),
        retry.booking->Option.mapOr("", booking => booking.at->toClockTime),
      )
    }
    <div
      className="col-span-5 grid grid-cols-subgrid items-center min-h-12 py-1.5 rounded-md cursor-pointer hover:bg-nd_gray-25"
      onClick={_ => onOpen()}>
      <div className="flex justify-center">
        <div className={`relative z-10 w-2.5 h-2.5 rounded-full ${dot}`} />
      </div>
      <p className={`${body.md.semibold} text-nd_gray-800`}> {text->React.string} </p>
      <div className="min-w-0"> chip </div>
      <HelpButton onClick=onOpen />
      <span className={`text-right pr-2 ${body.sm.regular} text-nd_gray-400`}>
        {time->React.string}
      </span>
    </div>
  }
}

let shownRetryLimit = 5

// Rev Rec's retries under one heading, one row each, on one grid so every chip, "?" and time
// starts at the same x. The chip column is as wide as the widest chip; the sentence takes the
// rest and wraps in its cell when the panel is narrow. A long run shows the latest five, with the
// rest behind "Show all N retries".
module RetryBlock = {
  @react.component
  let make = (
    ~retries: array<retry>,
    ~maxRetries,
    ~onRetryClick: retry => unit,
    ~revealClass,
    ~animationDelay,
    ~children=React.null,
  ) => {
    let (showAll, setShowAll) = React.useState(_ => false)
    let total = retries->Array.length
    let shown =
      showAll || total <= shownRetryLimit
        ? retries
        : retries->Array.slice(~start=total - shownRetryLimit, ~end=total)
    <div className={`flex flex-col ${revealClass}`} style={animationDelay: ?animationDelay}>
      <RenderIf condition={total > shownRetryLimit}>
        <span
          className={`ml-12 w-fit py-1 cursor-pointer text-blue-500 hover:text-blue-700 ${body.sm.medium}`}
          onClick={_ => setShowAll(prev => !prev)}>
          {(
            showAll ? "Show the latest 5" : `Show all ${total->Int.toString} retries`
          )->React.string}
        </span>
      </RenderIf>
      <div className="grid grid-cols-[2rem_minmax(0,1fr)_max-content_auto_5rem] gap-x-4">
        {shown
        ->Array.map(retry =>
          <RetryRow
            key={retry.number->Int.toString} retry maxRetries onOpen={() => onRetryClick(retry)}
          />
        )
        ->React.array}
      </div>
      <div className="ml-12"> children </div>
    </div>
  }
}

// Keeps the newest step in view while the viewer follows along: when the end of the rail was on
// screen before the step landed (within about two rows), the page scrolls down with it
type tailRect = {top: float}
@val @scope("document")
external getElementById: string => Nullable.t<Dom.element> = "getElementById"
@send external getTailRect: Dom.element => tailRect = "getBoundingClientRect"
@val @scope("window") external windowHeight: float = "innerHeight"

let tailDomId = "sim-story-tail"

let followTail = () =>
  getElementById(tailDomId)
  ->Nullable.toOption
  ->Option.forEach(tail =>
    if (tail->getTailRect).top -. 200.0 <= windowHeight {
      tail->Webapi.Dom.Element.scrollIntoViewWithOptions({"behavior": "smooth", "block": "end"})
    }
  )

// The panel's header row: the state pill, the amount recovered, and Rev Rec's retries against the
// profile's maximum. The rail below shows the steps.
module StatusRow = {
  @react.component
  let make = (~story: option<story>, ~form: option<billingForm>, ~maxRetries: option<int>) => {
    let stage = story->Option.mapOr(Starting, s => s.stage)
    let invoice = story->Option.mapOr(Dict.make(), s => s.invoice)
    let order = invoice->RevenueRecoveryEntity.itemToObjMapperForIntents
    let sign = form->Option.mapOr("USD", form => form.currency)->SimulatorFormTiles.currencySign
    // Until the sandbox records the invoice, the amount is the one the billing system charged
    let total =
      invoice->LogicUtils.isEmptyDict
        ? form->Option.mapOr(0.0, form => form.amount->LogicUtils.getFloatFromString(0.0))
        : order.order_amount
    let money = amount => `${sign}${amount->Float.toFixedWithPrecision(~digits=2)}`
    let retries = story->Option.mapOr(0, s => s->attemptCount(~by="revrec"))

    <div className={`flex-1 min-w-0 flex items-center gap-4 ${body.md.medium} text-nd_gray-600`}>
      <StatePill stage />
      <span className="min-w-0 truncate">
        <span className={`${body.md.semibold} text-nd_gray-800`}>
          {order.amount_captured->money->React.string}
        </span>
        {` / ${total->money} recovered`->React.string}
      </span>
      <span className="ml-auto shrink-0 whitespace-nowrap">
        {`Rev Rec retries ${retries->Int.toString}${maxRetries->Option.mapOr("", max =>
            ` of ${max->Int.toString}`
          )}`->React.string}
      </span>
    </div>
  }
}

// The story, step by step: one status row at the top, then the steps on one rail grouped by
// phase.
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
    // "Billing retries once more (fails)" in the menu, when the proxy allows it
    ~onReportAgain: option<unit => unit>=?,
    ~isBusy,
    ~onNext,
    ~onRowClick,
    ~onStatesClick,
    ~onWaitingClick,
    ~onRetryClick: retry => unit,
    ~maxRetries: option<int>,
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
    let hasRetries = visibleItems->Array.some(item => item.phase >= 3)
    // Rev Rec is overdue to book a retry: the proxy's note replaces the "Working…" line
    let waiting = isFinished ? None : story->Option.flatMap(s => s.waiting)
    // Until the report; after it the retry rows and the pills say what is going on
    let showWorking =
      hasStory &&
      !isFinished &&
      !showNext &&
      !isWaitingForNext &&
      !hasRetries &&
      waiting->Option.isNone
    let retryRows = shownItems->Array.reduce(0, (count, item) => count + item.retries->Array.length)
    let growthKey = `${shownItems
      ->Array.length
      ->Int.toString}-${retryRows->Int.toString}-${isFinished ? "end" : ""}`
    React.useEffect(() => {
      followTail()
      None
    }, [growthKey])
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
        isFinished
          ? None
          : onReportAgain->Option.map(onClick => ("Billing retries once more (fails)", onClick)),
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
      // The panel's header band, 56 px: state pill, amount, Rev Rec retries, then the menu
      <div className="-mx-6 -mt-5 h-14 px-5 flex items-center gap-4 border-b border-nd_gray-150">
        {if hasStory {
          <StatusRow
            story form={optimistic->Option.orElse(story->Option.flatMap(s => s.form))} maxRetries
          />
        } else {
          <p className={`flex-1 ${body.md.medium} text-nd_gray-500`}>
            {"Press Charge customer. Each step appears here."->React.string}
          </p>
        }}
        <ActionMenu options=menuOptions />
      </div>
      {if !hasStory {
        React.null
      } else {
        <>
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
                  {switch (item.outcome, item.retries) {
                  | (Some(_), _) =>
                    <div id={phaseDomId(outcomePhase)}>
                      <OutcomeCard item revealClass animationDelay onOpen />
                    </div>
                  | (None, retries) if retries->Array.length > 0 =>
                    <RetryBlock
                      retries=item.retries maxRetries onRetryClick revealClass animationDelay>
                      <RenderIf condition=isLast>
                        <NextControls
                          showNext
                          nextLabel="Let Rev Rec retry →"
                          isWaiting=isWaitingForNext
                          nextRetryAt={story->Option.flatMap(s => s.nextRetryAt)}
                          waiting
                          onWaitingWhy=onWaitingClick
                          onNext
                          inlineActions={isFinished ? [] : inlineActions}
                          isBusy
                        />
                      </RenderIf>
                    </RetryBlock>
                  | (None, _) =>
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
                          nextLabel="Let Rev Rec retry →"
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
            <div id=tailDomId />
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
