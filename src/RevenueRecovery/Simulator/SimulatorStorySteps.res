// The invoice story as a story (simulator/STORY-DESIGN.md): steps grouped under phase headings,
// plumbing folded into its parent step, plain-words titles with an actor chip and a status chip,
// on one timeline rail like the invoice page's Attempts History.
open SimulatorTypes
open SimulatorUtils
open SimulatorStoryHelper
open Typography

type tone = ToneOk | ToneDeclined | ToneRevRec | TonePending | ToneWaiting | ToneInfo

// The outcome card's colour: green when Rev Rec recovered, red when it stopped, grey otherwise
type outcomeTone = OutcomeGreen | OutcomeRed | OutcomeAmber | OutcomeGrey

// One Rev Rec retry: the time it booked and the charge it made. A retry still to run has no
// charge yet and is due at dueAt.
type retry = {
  number: int,
  booking: option<diagramRow>,
  charge: option<diagramRow>,
  dueAt: option<string>,
}

// One thing the viewer reads: a step under a phase, the retries block, or the outcome card
type rec storyItem = {
  phase: int,
  actor: option<actor>,
  // The row's short label ("First charge", "Billing system reports the failed charge"), its icon
  // in the rail's circle and the card it charged, if any. The full sentence (title) is for the
  // drawer and the end row.
  label: string,
  icon: string,
  card: string,
  title: string,
  chip: option<(string, tone)>,
  // Folded plumbing, for example "saved card ••4242 on file"
  detail: string,
  tone: tone,
  at: string,
  // The raw event the drawer opens
  row: option<diagramRow>,
  outcome: option<outcomeTone>,
  // A line with its source chip under the title, for example the retry budget
  note: option<explainLine>,
  // Raw events up to here are covered, for "Show all events"
  lastRawIndex: int,
  // The Rev Rec retries block: one row per retry (empty for every other item)
  retries: array<retry>,
  // Other rows inside the retries block, at their time: the billing system's own tries during
  // recovery, or the same customer's earlier invoice ending (preset 8)
  otherRows: array<storyItem>,
}

// Phase 6 is the outcome; phase 5 shows only when the customer acted
let outcomePhase = 6

// Which kind of story the headings describe: a go-live story has three invoices and its retries
// block follows invoice 1; a queue story (preset 8) starts with the customer's earlier invoice
type storyKind = PlainStory | GoLiveStory | QueueStory

let storyKindOf = (story: story) =>
  switch (story.goLive, story.queue) {
  | (Some(_), _) => GoLiveStory
  | (None, Some(_)) => QueueStory
  | (None, None) => PlainStory
  }

// The rail's four numbered sections. Rev Rec's retries and what the customer does meanwhile share
// section 3; phase 0 (last month, the go-live setup) is context and has no number.
let sectionOf = phase =>
  switch phase {
  | 3 | 4 | 5 => 3
  | phase if phase == outcomePhase => 4
  | phase => phase
  }

let phaseTitle = (phase, ~kind) =>
  switch (phase->sectionOf, kind) {
  | (0, GoLiveStory) => "Setup"
  | (0, QueueStory) => "Invoice 1 · earlier"
  | (0, PlainStory) => "Last month"
  | (1, GoLiveStory) => "1 · The charges fail"
  | (1, _) => "1 · The charge fails"
  | (2, _) => "2 · The billing system informs Rev Rec"
  | (3, _) => "3 · Rev Rec picks a time and retries"
  | _ => "4 · Result"
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

// Another processor's decline in plain words, from its own message ("Not enough balance",
// "CREDITCARD ISSUER TEMPORARILY NOT REACHABLE"): the same words a Stripe decline gets
let plainProcessorWords = message => {
  let m = message->String.toLowerCase
  let has = word => m->String.includes(word)
  if has("balance") || has("insufficient") || has("funds") || has("money") {
    "Not enough money"
  } else if has("not reachable") || has("unavailable") || has("timeout") {
    "Bank not reachable"
  } else if has("withdrawal") || has("velocity") || has("limit") {
    "Spending limit"
  } else if has("stolen") || has("lost") || has("blocked") || has("pick up") {
    "Card blocked"
  } else if has("fraud") {
    "Fraud suspected"
  } else if has("expired") {
    "Card expired"
  } else if has("refused") || has("not honor") || has("declined") {
    "Refused"
  } else {
    m->String.charAt(0)->String.toUpperCase ++ m->String.sliceToEnd(~start=1)
  }
}

// A decline's reason for the row: Stripe's code ("insufficient funds"), or, where the processor
// gives a number ("declined (12)"), its own words from the row ("Adyen said no: Not enough
// balance.") with the number kept for "?"
let declineOf = (row: diagramRow) =>
  row.label
  ->reasonOf
  ->Option.map(reason =>
    %re("/^\d+$/")->RegExp.test(reason)
      ? (
          %re("/said no: ([^.]+)/")
          ->capture(row.text)
          ->Option.mapOr("Card declined", plainProcessorWords),
          Some(reason),
        )
      : (reason, None)
  )

// The chip text: "Declined · insufficient funds", or "Declined · Not enough money|12" when a
// processor's code goes behind "?" (resultCell splits it off)
let chargeChip = (row: diagramRow) =>
  switch row.status {
  | StepOk => Some(("Approved", ToneOk))
  | StepDeclined | StepFailed =>
    Some((
      row
      ->declineOf
      ->Option.mapOr("Declined", ((reason, code)) =>
        `Declined · ${reason}${code->Option.mapOr("", code => `|${code}`)}`
      ),
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

@send external toLocaleStringWith: (Date.t, option<string>, {..}) => string = "toLocaleString"

// The simulated real-life calendar is in UTC (A's realLife.timeZone), the zone Rev Rec's model
// picks its days and hours in. Every real-life time shows in it, so a retry's time matches its
// "Picked" line and the proxy's own labels.
let calendarZone = "UTC"

// "Tue 5:30 PM" on the simulated calendar
let realLifeTime = iso =>
  iso
  ->toUtcIso
  ->Date.fromString
  ->toLocaleStringWith(
    None,
    {"weekday": "short", "hour": "numeric", "minute": "2-digit", "timeZone": calendarZone},
  )

// Day 1 is the failure's day on the simulated calendar
let slotDayNumber = (slot: realLifeSlot) => {
  let at = slot.at->toUtcIso->Date.fromString
  let failure = Date.fromTime(at->Date.getTime -. slot.offsetSec->Int.toFloat *. 1000.0)
  let dayOf = (date: Date.t) =>
    Date.UTC.makeWithYMD(
      ~year=date->Date.getUTCFullYear,
      ~month=date->Date.getUTCMonth,
      ~date=date->Date.getUTCDate,
    )
  ((dayOf(at) -. dayOf(failure)) /. 86400000.0)->Math.round->Float.toInt + 1
}

let slotFor = (plan: option<realLifePlan>, number) =>
  plan->Option.flatMap(plan => plan.slots->Array.find(slot => slot.retry == number))

// " · real life Tue 3:01 AM, 18 h after the failure" for the end row
let realLifeEnd = (plan, number) =>
  slotFor(plan, number)->Option.mapOr("", slot => {
    let after = slot.dayText->String.split(", ")->Array.at(-1)->Option.getOr(slot.dayText)
    ` · real life ${slot.at->realLifeTime}, ${after}`
  })

// The visitor cancelled the invoice and Rev Rec accepted it. The engine ends such an invoice as
// Terminated; the story calls it what it is.
let wasCancelled = (story: story) =>
  story.timeline->Array.some(row =>
    row.from == Billing &&
    row.to == RevRec &&
    row.label->String.startsWith("cancel invoice") &&
    row.label->httpStatusOf == "200"
  )

// The invoice's state as the story shows it: a visitor's cancel is Cancelled, not Terminated
let shownStage = (story: story) =>
  story.stage == Terminated && story->wasCancelled ? Cancelled : story.stage

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
  switch story->shownStage {
  | Recovered if story.recoveredBy == "revrec" => {
      let approved =
        charged->Array.find(retry => retry.charge->Option.mapOr(false, row => row.status == StepOk))
      let number = approved->Option.mapOr(count, retry => retry.number)
      // The real-life time when the timetable is known, else the demo's own seconds
      let after = switch (
        realLifeEnd(story.realLife, number),
        firstFailure,
        approved->Option.flatMap(retry => retry.charge),
      ) {
      | (realLife, _, _) if realLife->LogicUtils.isNonEmptyString => realLife
      | (_, Some(first), Some(charge)) =>
        ` · ${((charge.at->toMillis -. first.at->toMillis) /. 1000.0)
          ->Float.toInt
          ->secondsInWords} after the first failure`
      | _ => ""
      }
      (`Recovered on retry ${number->Int.toString}${after}`, OutcomeGreen)
    }
  // Paid outside Rev Rec is still money collected, so it is green too
  | Recovered => (
      count > 0 ? `Paid outside Rev Rec after ${count->retriesText}` : "Paid outside Rev Rec",
      OutcomeGreen,
    )
  | Terminated =>
    switch (count, hardReason, maxRetries) {
    // A second saved card does not help here: Rev Rec's retries only use this invoice's card
    | (0, _, _) if story.savedCards->Array.length > 1 => (
        "Stopped: Rev Rec only tries this invoice's card",
        OutcomeRed,
      )
    | (0, Some(reason), _) => (`Stopped at once · hard decline (${reason})`, OutcomeRed)
    | (_, _, Some(max)) if count >= max => (
        `Stopped after ${count->retriesText} · max retries reached${realLifeEnd(
            story.realLife,
            count,
          )}`,
        OutcomeRed,
      )
    | (0, None, _) => ("Rev Rec stopped", OutcomeRed)
    | _ => (`Stopped after ${count->retriesText}${realLifeEnd(story.realLife, count)}`, OutcomeRed)
    }
  | Cancelled => (
      count > 0
        ? `Cancelled · you cancelled the invoice after ${count->retriesText}`
        : "Cancelled · you cancelled the invoice",
      OutcomeGrey,
    )
  | StoryError => ("The story stopped with an error", OutcomeRed)
  | stage => (`Story complete: the invoice is still ${stage->stageName}`, OutcomeAmber)
  }
}

// The end row of a go-live story: how many old invoices Rev Rec got back
let goLiveOutcome = (story: story) => {
  let total = story.backlog->Array.length
  let recovered = story.backlog->Array.filter(invoice => invoice.stage == Recovered)->Array.length
  let stopped = story.backlog->Array.some(invoice => invoice.stage == Terminated)
  (
    `${recovered->Int.toString} of ${total->Int.toString} old invoices recovered`,
    recovered == total && total > 0 ? OutcomeGreen : stopped ? OutcomeRed : OutcomeGrey,
  )
}

// "Charged" → "charged", after "Invoice 2: "
let lowerFirst = text =>
  `${text->String.charAt(0)->String.toLowerCase}${text->String.sliceToEnd(~start=1)}`

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
  // Last month's invoice (preset 9), or connecting the billing system (preset 10), shows first,
  // under its own heading
  let lastMonthItems: array<storyItem> = []
  // Another failure the billing system reports after the end: its answer follows the outcome
  let afterEndItems: array<storyItem> = []
  // A charge the billing system makes again during recovery or after the end, until its report
  let againCharge = ref(None)
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
  // The customer's saved card, as the story says. The billing system charges this card; a test
  // card that only makes the decline does not show.
  let storySavedCard =
    story.savedCards
    ->Array.find(card => card.role == "main")
    ->Option.map(card => card.last4)
    ->Option.orElse(story.form->Option.map(form => form.savedCard))
    ->Option.filter(LogicUtils.isNonEmptyString)
  // Preset 10: a backlog of old invoices; Rev Rec only records them until it is turned on
  let isGoLive = story.goLive->Option.isSome
  // Preset 8: the earlier invoice's rows go first, under their own heading
  let pushTagged = (item: storyItem) =>
    story.queue->Option.isSome
      ? lastMonthItems->Array.push({...item, phase: 0})->ignore
      : items->Array.push(item)->ignore
  let isBeforeGoLive = (row: diagramRow) =>
    story.goLive->Option.mapOr(false, goLive =>
      goLive.revRecOnAt->LogicUtils.isEmptyString || row.at->toMillis < goLive.revRecOnAt->toMillis
    )

  let push = (item: storyItem) => items->Array.push(item)->ignore
  // A row that joins the retries block at its time once there is one
  let addToBlock = (item: storyItem) =>
    switch retryIndex.contents {
    | -1 => push(item)
    | block =>
      items
      ->Array.get(block)
      ->Option.forEach(retriesItem =>
        items->Array.set(
          block,
          {
            ...retriesItem,
            otherRows: retriesItem.otherRows->Array.concat([item]),
            lastRawIndex: item.lastRawIndex,
          },
        )
      )
    }
  let update = (index, change) =>
    items->Array.get(index)->Option.forEach(item => items->Array.set(index, change(item)))
  let step = (
    ~row: diagramRow,
    ~index,
    ~phase,
    ~actor,
    ~title,
    ~chip,
    ~tone,
    ~label=?,
    ~icon="nd-arrow-right",
    ~card="",
  ) => {
    phase,
    actor: Some(actor),
    label: label->Option.getOr(title),
    icon,
    card,
    title,
    chip,
    detail: "",
    tone,
    at: row.at,
    row: Some(row),
    outcome: None,
    note: None,
    lastRawIndex: index,
    retries: [],
    otherRows: [],
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

  let pushEvent = (~row: diagramRow, ~index, ~label, ~actor) => {
    let (chipText, rowLabel, icon, card) = if label->String.includes("money is back") {
      ("Money back", "Money back", "nd-piggy-bank", "")
    } else if label->String.includes("new card") {
      ("New card", "New card", "card", label->cardOf)
    } else if label->String.includes("stolen") {
      ("Reported stolen", "Card stolen", "nd-shield", "")
    } else {
      ("Outage", "Bank outage", "nd-bank", "")
    }
    addToBlock(
      step(
        ~row,
        ~index,
        ~phase=retryIndex.contents >= 0 ? 3 : 2,
        ~actor,
        // The new card's row text names the processor's card id; the screen never shows ids
        ~title=if label->String.includes("saved a new card") {
          `The customer saved a new card ••${label->cardOf}.`
        } else if row.text->LogicUtils.isNonEmptyString {
          row.text
        } else {
          label
        },
        ~chip=Some((chipText, ToneWaiting)),
        ~tone=ToneWaiting,
        ~label=rowLabel,
        ~icon,
        ~card,
      ),
    )
  }

  story.timeline->Array.forEachWithIndex((row, index) => {
    // Go-live rows name their invoice first ("invoice 2: report failure → 200 recorded")
    let (invoiceNumber, label) = switch %re("/^invoice (\d+): (.*)$/")->RegExp.exec(row.label) {
    | Some(result) =>
      switch result->RegExp.Result.matches {
      | [number, rest] => (number, rest)
      | _ => ("", row.label)
      }
    | None => ("", row.label)
    }
    let isTagged = invoiceNumber->LogicUtils.isNonEmptyString
    let tagged = title => isTagged ? `Invoice ${invoiceNumber}: ${title->lowerFirst}` : title
    let startsWith = prefix => label->String.startsWith(prefix)
    switch (row.from, row.to) {
    | (Billing, Billing) => amount := label->amountOf
    | (Billing, RevRec) if startsWith("connect the billing system") =>
      lastMonthItems
      ->Array.push(
        step(
          ~row,
          ~index,
          ~phase=0,
          ~actor=Billing,
          ~title="Connected the billing system to Rev Rec",
          ~label="Connected",
          ~icon="nd-swap-arrow-horizontal",
          ~chip=Some(("Monitoring", ToneWaiting)),
          ~tone=ToneWaiting,
        ),
      )
      ->ignore
    // Every story starts on Rev Rec's smart model, so the start's own mode row says nothing new;
    // the event list keeps it
    | (Billing, RevRec)
      if startsWith("setting: retry mode → smart") && reportIndex.contents < 0 => ()
    // The visitor paused or resumed Rev Rec (or it resumed by itself): among the retries, at its
    // time, like a setting
    | (Billing, RevRec) if label == "Paused" || label == "Resumed" => {
        let isPause = label == "Paused"
        let item = {
          ...step(
            ~row,
            ~index,
            ~phase=retryIndex.contents >= 0 ? 3 : reportIndex.contents >= 0 ? 2 : 1,
            ~actor=Billing,
            ~title=row.text,
            ~label=switch (isPause, row.text->String.includes("by itself")) {
            | (true, _) => "You paused Rev Rec"
            | (false, true) => "Rev Rec resumed by itself"
            | (false, false) => "You resumed Rev Rec"
            },
            ~icon=isPause ? "pause" : "play",
            ~chip=Some((label, ToneWaiting)),
            ~tone=ToneWaiting,
          ),
          actor: None,
        }
        switch retryIndex.contents {
        | -1 => push(item)
        | block =>
          update(block, retriesItem => {
            ...retriesItem,
            otherRows: retriesItem.otherRows->Array.concat([item]),
            lastRawIndex: index,
          })
        }
      }
    // A live setting the visitor changed: "You set max tries to 8." (amber, at its time)
    | (Billing, RevRec) if startsWith("setting:") => {
        let item = {
          ...step(
            ~row,
            ~index,
            // Before the handover (no report yet) it belongs to the first phase
            ~phase=retryIndex.contents >= 0 ? 3 : reportIndex.contents >= 0 ? 2 : 1,
            ~actor=Billing,
            ~title=row.text->LogicUtils.isNonEmptyString ? row.text : label,
            ~label=(row.text->LogicUtils.isNonEmptyString ? row.text : label)->String.replaceRegExp(
              %re("/\.$/"),
              "",
            ),
            ~icon="nd-settings",
            ~chip=Some(("Setting", ToneWaiting)),
            ~tone=ToneWaiting,
          ),
          // The visitor did it, not the billing system
          actor: None,
        }
        switch retryIndex.contents {
        | -1 => push(item)
        | block =>
          update(block, retriesItem => {
            ...retriesItem,
            otherRows: retriesItem.otherRows->Array.concat([item]),
            lastRawIndex: index,
          })
        }
      }
    // A real-world story's scripted bank is test setup, not a step: the "Test setup" line above the
    // rail says it. The event list keeps the row.
    | (Processor, Processor) if startsWith("the bank's plan") => ()
    // The story's own billing connector is removed at the end; plumbing, kept in the event list
    | (Billing, RevRec) if startsWith("disconnect") => ()
    | (Billing, RevRec) if startsWith("turn Rev Rec on") =>
      push(
        step(
          ~row,
          ~index,
          ~phase=2,
          ~actor=RevRec,
          ~title="Rev Rec turned on",
          ~label="Rev Rec on",
          ~icon="nd-check",
          ~chip=Some((
            label->String.includes("smart") ? "Smart retries" : "Fixed timetable",
            ToneRevRec,
          )),
          ~tone=ToneRevRec,
        ),
      )
    | (_, Processor) if startsWith("save card") => savedCard := label->cardOf
    | (Customer, Processor) if startsWith("add card") => appCard := label->cardOf
    | (Billing, Processor) if startsWith("last month's invoice") =>
      lastMonthItems
      ->Array.push(
        step(
          ~row,
          ~index,
          ~phase=0,
          ~actor=Billing,
          ~title=`Last month's invoice paid on ••${label->cardOf}`,
          ~label="Last month's charge",
          ~icon="card",
          ~card=label->cardOf,
          ~chip=row->chargeChip,
          ~tone=row.status->toneOf,
        ),
      )
      ->ignore
    // "charge $65.40 again on ••0341": the billing system charged again during recovery or after
    // the end ("again (2 of 3)" is one of its first tries, which fold into the first charge)
    | (Billing, Processor)
      if label->String.includes(" again") && !(%re("/\(\d+ of \d+\)/")->RegExp.test(label)) =>
      againCharge := Some(row)
    | (Billing, Processor) => {
        chargeCount := chargeCount.contents + 1
        let card = switch (storySavedCard, label->cardOf) {
        | (Some(saved), _) => saved
        | (None, "") => firstChargeCard
        | (None, card) => card
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
            ~title=tagged(`Charged ${label->amountOf}${cardText}`),
            ~label=isTagged ? `Invoice ${invoiceNumber} charge` : "First charge",
            ~icon="card",
            ~card,
            ~chip=row->chargeChip,
            ~tone=row.status->toneOf,
          ),
          detail: isTagged ? "" : detail,
        }
        switch chargeIndex.contents {
        // Each go-live invoice's charge is its own row
        | _ if isTagged => pushTagged(item)
        | -1 => {
            chargeIndex := items->Array.length
            push(item)
          }
        // Keep the first charge's title, row and time; the chip shows how the last try ended
        | existing =>
          update(existing, first => {...item, title: first.title, at: first.at, row: first.row})
        }
      }
    | (Billing, RevRec) if startsWith("report last month's invoice") =>
      lastMonthItems
      ->Array.push(
        step(
          ~row,
          ~index,
          ~phase=0,
          ~actor=Billing,
          ~title=`Reported last month's payment with ••${label->cardOf}`,
          ~label="Last month reported",
          ~chip=Some(("Reported", ToneWaiting)),
          ~tone=ToneWaiting,
        ),
      )
      ->ignore
    // After "New card added": the billing system charges the old card again and reports the
    // failure with the new card, which Rev Rec tries next
    | (Billing, RevRec)
      if startsWith("report failure") && label->String.includes("with the new card") => {
        let charge = againCharge.contents
        againCharge := None
        addToBlock(
          step(
            ~row,
            ~index,
            ~phase=retryIndex.contents >= 0 ? 3 : 2,
            ~actor=Billing,
            // The old card is the one charged; the report names the new one
            ~title=switch charge {
            | Some(charge) =>
              `Charged ••${charge.label->cardOf} again, reported the new card to Rev Rec`
            | None => "Reported the new card to Rev Rec"
            },
            ~label="New card reported",
            ~card=charge->Option.mapOr("", charge => charge.label->cardOf),
            ~chip=charge->Option.flatMap(chargeChip),
            ~tone=ToneWaiting,
          ),
        )
      }
    // "Charge fails again" during recovery, or after the end (then Rev Rec's answer)
    | (Billing, RevRec) if startsWith("report failure again") => {
        let charge = againCharge.contents
        againCharge := None
        let chargedText = switch (storySavedCard, charge) {
        | (Some(card), _) => `Charged ••${card} again`
        | (None, Some(charge)) => `Charged ••${charge.label->cardOf} again`
        | (None, None) => "Charged again"
        }
        if outcomeRow.contents->Option.isSome {
          let refused = row.status != StepOk
          afterEndItems
          ->Array.push(
            step(
              ~row,
              ~index,
              ~phase=outcomePhase,
              ~actor=Billing,
              ~title=`${chargedText}, reported it to Rev Rec`,
              ~label="Fails again",
              ~icon="card",
              ~card=charge->Option.mapOr("", charge => charge.label->cardOf),
              ~chip=Some(refused ? ("Refused", ToneDeclined) : ("Recorded, no retry", ToneWaiting)),
              ~tone=refused ? ToneDeclined : ToneWaiting,
            ),
          )
          ->ignore
        } else {
          let item = {
            ...step(
              ~row,
              ~index,
              ~phase=retryIndex.contents >= 0 ? 3 : 2,
              ~actor=Billing,
              ~title=tagged(`${chargedText}, reported it to Rev Rec`),
              ~label=isTagged ? `Invoice ${invoiceNumber} fails again` : "Fails again",
              ~icon="card",
              ~card=charge->Option.mapOr("", charge => charge.label->cardOf),
              ~chip=charge->Option.flatMap(chargeChip),
              ~tone=ToneDeclined,
            ),
            // The billing system's failure does not use one of Rev Rec's retries (a go-live
            // report is what restarts an old invoice, so it has no budget line)
            note: isTagged ? None : story.retryBudget->Option.map(budget => budget.note),
          }
          switch retryIndex.contents {
          | -1 => push(item)
          | block =>
            update(block, retriesItem => {
              ...retriesItem,
              otherRows: retriesItem.otherRows->Array.concat([item]),
              lastRawIndex: index,
            })
          }
        }
      }
    | (Billing, RevRec) if startsWith("report failure") => {
        let code = label->httpStatusOf
        let recorded = code == "200"
        // In monitoring Rev Rec records the failure and does not retry
        let recordedText = isTagged && isBeforeGoLive(row) ? "Recorded, no retry" : "Reported"
        let item = step(
          ~row,
          ~index,
          ~phase=2,
          ~actor=Billing,
          ~title=tagged("Reported the failure to Rev Rec"),
          ~label=isTagged
            ? `Billing system reports invoice ${invoiceNumber}`
            : "Billing system reports the failed charge",
          // Handed over is amber, not green: no money has moved. A refusal shows its HTTP code.
          ~chip=code->LogicUtils.isNonEmptyString
            ? Some((recorded ? recordedText : code, recorded ? ToneWaiting : ToneDeclined))
            : None,
          ~tone=recorded ? ToneWaiting : ToneDeclined,
        )
        switch reportIndex.contents {
        | _ if isTagged => pushTagged(item)
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
            ~label="Same failure again",
            ~chip=Some(refused ? ("Refused", ToneDeclined) : ("Reported", ToneWaiting)),
            ~tone=refused ? ToneDeclined : ToneWaiting,
          ),
        )
      }
    | (Billing, RevRec) if startsWith("report paid outside") => {
        outcomeDetails
        ->Array.push(`Reported to Rev Rec (${label->httpStatusOf})`)
        ->ignore
        outcomeRow := Some(row)
      }
    // The visitor's cancel: the end row says it (the HTTP answer is in the row's drawer)
    | (Billing, RevRec) if startsWith("cancel invoice") => {
        if label->httpStatusOf != "200" {
          outcomeDetails->Array.push("Rev Rec refused the cancel")->ignore
        }
        outcomeRow := Some(row)
      }
    // Something the visitor made happen: money back, a new card, a stolen card, a bank outage.
    // Amber (no money has moved), at its time.
    | (Customer, _) if startsWith("customer: ") => pushEvent(~row, ~index, ~label, ~actor=Customer)
    | (Processor, Processor) if startsWith("bank outage") =>
      pushEvent(~row, ~index, ~label, ~actor=Processor)
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
            ~label="Paid in app",
            ~icon="nd-wallet",
            ~card=appCard.contents,
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
    // Preset 8: the same customer's earlier invoice ended. A row at its time, not this story's end.
    | (RevRec, Billing) if startsWith("invoice ") && label->String.includes(" ended") => {
        let ended = label->String.includes("recovered")
        let item = step(
          ~row,
          ~index,
          ~phase=3,
          ~actor=RevRec,
          ~title=label->String.charAt(0)->String.toUpperCase ++ label->String.sliceToEnd(~start=1),
          ~label=(label->String.charAt(0)->String.toUpperCase ++ label->String.sliceToEnd(~start=1))
          ->String.split(":")
          ->Array.get(0)
          ->Option.getOr(label),
          ~icon=ended ? "nd-check" : "nd-cross",
          ~chip=None,
          ~tone=ended ? ToneOk : ToneDeclined,
        )
        switch retryIndex.contents {
        | -1 => push(item)
        | block =>
          update(block, retriesItem => {
            ...retriesItem,
            otherRows: retriesItem.otherRows->Array.concat([item]),
            lastRawIndex: index,
          })
        }
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

  let isOver = story->storyHasEnded
  let retries = pairRetries(~bookings, ~charges, ~pending=pending.contents, ~isOver)
  if retryIndex.contents >= 0 {
    update(retryIndex.contents, item => {...item, retries})
  }

  if isOver {
    let (title, tone) = isGoLive ? story->goLiveOutcome : story->outcomeTitle(~retries, ~maxRetries)
    // After a max-tries change, the proxy says how Rev Rec reacted: "Rev Rec stops: 8 of 8 tries
    // used."
    let title =
      story.timeline
      ->Array.findMap(row =>
        row.why->Array.find(line => line.text->String.startsWith("Rev Rec stops:"))
      )
      ->Option.mapOr(title, line => line.text->String.replaceRegExp(%re("/\.$/"), ""))
    let errorDetail = story.stage == StoryError ? [story.startError] : []
    push({
      phase: outcomePhase,
      actor: None,
      label: title,
      icon: "",
      card: "",
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
      note: None,
      lastRawIndex: story.timeline->Array.length - 1,
      retries: [],
      otherRows: [],
    })
    afterEndItems->Array.forEach(push)
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
  (header, lastMonthItems->Array.concat(items))
}

let moneyText = (form: billingForm) =>
  form.currency == "USD" ? `$${form.amount}` : `${form.amount} ${form.currency}`

// Shown the instant Charge customer is pressed, and until the first charge lands
let creatingItem = (~form: option<billingForm>): storyItem => {
  phase: 1,
  actor: Some(Billing),
  label: "Creating the invoice",
  icon: "card",
  card: "",
  title: form->Option.mapOr("Creates the invoice", form => `Creates invoice ${form->moneyText}`),
  chip: None,
  detail: "",
  tone: TonePending,
  at: "",
  row: None,
  outcome: None,
  note: None,
  lastRawIndex: -1,
  retries: [],
  otherRows: [],
}

// ---------- pacing over items (STORY-STEPS.md section 6) ----------

// The billing system's part shows by itself; the story pauses before Rev Rec's first step
let autoItemCount = (items: array<storyItem>) =>
  switch items->Array.findIndex(item => item.phase >= 3) {
  | -1 => items->Array.length
  | index => index
  }

// Once Rev Rec has the invoice (the report is on the rail), or auto-play is on, every later step
// shows as it happens. Before the handover only the billing system's charge is there to show.
let isFollowingLive = (~items: array<storyItem>, ~revealLimit, ~autoPlay) =>
  autoPlay || revealLimit > items->autoItemCount || items->Array.some(item => item.phase == 2)

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

// The story's colour rule, for every dot, chip and end row (the status pill keeps the Invoices
// badge colours):
// - GREEN (ToneOk) only when money is collected: an approved charge, Recovered, paid in app.
// - RED (ToneDeclined): a decline, Terminated, a refusal.
// - AMBER (ToneWaiting): handed over or waiting on someone: the failure reported to Rev Rec,
//   Monitoring, a booked retry waiting for its time.
// - BLUE (ToneRevRec): Rev Rec acting: it picked a time, it is charging now.
// - GREY (ToneInfo, TonePending): not happened yet, Cancelled.
let toneChipClass = tone =>
  switch tone {
  | ToneOk => "bg-nd_green-50 text-nd_green-600"
  | ToneDeclined => "bg-nd_red-50 text-nd_red-600"
  | ToneWaiting => "bg-nd_yellow-50 text-nd_yellow-700"
  | ToneRevRec => "bg-nd_primary_blue-50 text-nd_primary_blue-600"
  | TonePending | ToneInfo => "bg-nd_gray-150 text-nd_gray-600"
  }

// Rail dot, by the same rule
let dotClass = tone =>
  switch tone {
  | ToneOk => "bg-nd_green-400"
  | ToneDeclined => "bg-nd_red-500"
  | ToneWaiting => "bg-nd_yellow-500"
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
  let make = (~phase, ~kind, ~domId=?, ~isFirst, ~revealClass, ~animationDelay) => {
    <div
      id=?domId
      className={`flex items-center gap-3 ${isFirst ? "" : "mt-4"} ${revealClass}`}
      style={animationDelay: ?animationDelay}>
      <div className="w-8 shrink-0 flex justify-center">
        <div
          className="relative z-10 w-4 h-4 rounded-full bg-nd_gray-100 border-2 border-nd_gray-300"
        />
      </div>
      <p className={`${body.sm.semibold} text-nd_gray-500 uppercase tracking-wide`}>
        {phase->phaseTitle(~kind)->React.string}
      </p>
    </div>
  }
}

// A tiny source chip ("Rule-based"), as in the drawer
let sourceChip = (source: source) => {
  let (label, labelClass) = source->sourceLabel
  <span
    className={`inline-block rounded border px-1 text-[10px] leading-4 font-semibold whitespace-nowrap align-middle ${labelClass}`}>
    {label->React.string}
  </span>
}

// A line with its source chip, under a row's title
let noteLine = (note: option<explainLine>) =>
  switch note {
  | Some(note) =>
    <p className={`${body.sm.medium} text-nd_gray-600`}>
      {note.source->sourceChip}
      {` ${note.text}`->React.string}
    </p>
  | None => React.null
  }

// A result chip; a decline's plain meaning shows on hover
let chipWithMeaning = (chip: React.element, ~meaning: option<explainLine>) =>
  switch meaning {
  | Some(line) => <ToolTip description=line.text toolTipFor=chip toolTipPosition=ToolTip.Top />
  | None => chip
  }

// only when it adds something
// ---------- one row design for the whole rail ----------
// [circle] Label · Fri, Oct 30 · 4:43 PM [card]        [Result] reason    ›
// One 48 px line, the whole row clickable; hover shows a light grey background and the "›". The
// circle carries the result (a retry) or the kind of step (the other rows).

// "Fri, Oct 30 · 4:43 PM"
let realLifeDateTime = iso => {
  let date = iso->toUtcIso->Date.fromString
  `${date->toLocaleStringWith(
      None,
      {"weekday": "short", "month": "short", "day": "numeric", "timeZone": calendarZone},
    )} · ${date->toLocaleStringWith(
      None,
      {"hour": "numeric", "minute": "2-digit", "timeZone": calendarZone},
    )}`
}

// The decline in plain words, after the result word
let plainReason = reason =>
  switch reason->String.toLowerCase {
  | "insufficient funds" => "Not enough money"
  // The bank gave no reason
  | "generic decline" => "Card declined"
  | "stolen card" => "Card stolen"
  | "lost card" => "Card lost"
  | "processing error" => "Bank system error"
  | "do not honor" => "Bank said no"
  | "card velocity exceeded" => "Spending limit"
  | "expired card" => "Card expired"
  | "fraudulent" => "Fraud suspected"
  | "" => ""
  | other => other->String.charAt(0)->String.toUpperCase ++ other->String.sliceToEnd(~start=1)
  }

// The first charge's decline for the checkout: its reason in plain words and the card's last four.
// None until the billing system's first charge has declined.
let firstDecline = (story: story) =>
  story
  ->buildStoryItems(~maxRetries=None)
  ->snd
  ->Array.find(item => item.phase == 1 && item.chip->Option.isSome)
  ->Option.flatMap(item =>
    switch item.chip->Option.map(fst)->Option.getOr("")->String.split(" · ") {
    | [word, reason] if word == "Declined" => {
        let plain = reason->String.split("|")->Array.get(0)->Option.getOr("")->plainReason
        Some((
          plain == "Card declined" || plain->LogicUtils.isEmptyString
            ? "The bank gave no reason."
            : plain,
          item.card,
        ))
      }
    | [word] if word == "Declined" => Some(("The bank gave no reason.", item.card))
    | _ => None
    }
  )

// Watch mode's narration (?mode=watch, from Home): which of the four steps the story is in, one
// plain line about it, Pause / Resume while Rev Rec retries, and "Try it yourself" at the end
module WatchBar = {
  @react.component
  let make = (
    ~story: option<story>,
    ~items: array<storyItem>,
    ~visibleCount,
    ~isFinished,
    ~isBusy,
    ~onPause: bool => unit,
    ~onTryIt,
  ) => {
    let shown = items->Array.slice(~start=0, ~end=visibleCount)
    let kind = story->Option.mapOr(PlainStory, storyKindOf)
    let latest = shown->Array.at(-1)
    // Last month's row (a returning customer) is context: the story starts at step 1
    let phase = isFinished
      ? outcomePhase
      : latest->Option.mapOr(1, item => Math.Int.max(item.phase, 1))
    let section = phase->sectionOf
    let title = phaseTitle(phase, ~kind)->String.split(" · ")->Array.at(-1)->Option.getOr("")
    let settings = story->Option.flatMap(s => s.settings)
    let isPaused = settings->Option.mapOr(false, settings => settings.currentPaused)
    let charged =
      shown->Array.flatMap(item => item.retries)->Array.filter(retry => retry.charge->Option.isSome)
    let line = switch section {
    | 1 => "The billing system charges the card. The bank says no."
    | 2 => "The billing system reports the failed charge to Rev Rec."
    | 3 =>
      switch (isPaused, charged->Array.at(-1)) {
      | (true, _) => "Paused. Rev Rec waits until you resume."
      | (false, None) => "Rev Rec picks the best time to try again."
      | (false, Some({charge: Some(charge)})) if charge.status == StepOk =>
        `Retry ${charged->Array.length->Int.toString} worked. The invoice is paid.`
      | (false, Some(_)) =>
        `Retry ${charged->Array.length->Int.toString} was declined. Rev Rec picks the next time.`
      }
    | _ =>
      shown
      ->Array.find(item => item.outcome->Option.isSome)
      ->Option.mapOr("The story has ended.", item =>
        item.title->String.split(" · real life")->Array.get(0)->Option.getOr(item.title)
      )
    }
    <AddDataAttributes attributes=[("data-sim", "watch-bar")]>
      <div
        className={`${cardStyle} px-5 py-3 flex items-center gap-4 border-nd_primary_blue-200 bg-nd_primary_blue-25`}>
        <div className="flex gap-1" ariaHidden=true>
          {[1, 2, 3, 4]
          ->Array.map(step =>
            <span
              key={step->Int.toString}
              className={`w-6 h-1.5 rounded-full ${step < section || isFinished
                  ? "bg-nd_green-400"
                  : step == section
                  ? "bg-nd_primary_blue-450"
                  : "bg-nd_gray-200"}`}
            />
          )
          ->React.array}
        </div>
        <div className="min-w-0 flex-1 flex flex-col">
          <p className={`${body.md.semibold} text-nd_gray-800`}>
            {`Step ${section->Int.toString} of 4 · ${title}`->React.string}
          </p>
          <p className={`${body.sm.medium} text-nd_gray-600`}> {line->React.string} </p>
        </div>
        {switch (isFinished, settings) {
        | (true, _) =>
          <Button
            text="Try it yourself"
            buttonType=Primary
            buttonSize=Small
            customButtonStyle="!w-auto !h-9"
            onClick={_ => onTryIt()}
          />
        | (false, Some(settings)) if settings.paused.allowed || isPaused =>
          <Button
            text={isPaused ? "Resume" : "Pause"}
            buttonType=Secondary
            buttonSize=Small
            leftIcon={CustomIcon(<Icon name={isPaused ? "play" : "pause"} size=12 />)}
            customButtonStyle="!w-auto !h-9"
            buttonState={isBusy ? Disabled : Normal}
            onClick={_ => onPause(!isPaused)}
          />
        | _ => React.null
        }}
      </div>
    </AddDataAttributes>
  }
}

// A "?" that explains on hover (the drawer's "?" opens on click)
let helpTip = description =>
  <ToolTip
    description
    toolTipPosition=ToolTip.Bottom
    toolTipFor={<span
      className={`shrink-0 w-5 h-5 rounded-full border border-nd_gray-300 text-nd_gray-500 cursor-help flex items-center justify-center ${body.xs.semibold}`}>
      {"?"->React.string}
    </span>}
  />

// A plain sentence when an action fails; the proxy's own words behind "?"
module ActionNotice = {
  @react.component
  let make = (~text, ~detail, ~onClose) =>
    <div
      className="flex items-center gap-2 rounded-xl border border-nd_red-300 bg-nd_red-50 px-4 py-2.5">
      <Icon name="nd-toast-error" size=16 className="shrink-0 text-nd_red-600" />
      <p className={`${body.md.medium} text-nd_red-600`}> {text->React.string} </p>
      <RenderIf condition={detail->LogicUtils.isNonEmptyString && detail != text}>
        {helpTip(detail)}
      </RenderIf>
      <button
        type_="button"
        ariaLabel="Close"
        className="ml-auto text-nd_gray-500 hover:text-nd_gray-800"
        onClick={_ => onClose()}>
        <Icon name="nd-cross" size=12 />
      </button>
    </div>
}

// The result column: one word in a coloured chip, the card (its brand's logo and last four), then
// the reason in grey ("Declined  VISA ••4444  Not enough money"). The generic decline has no reason
// text: it would only repeat the chip. A processor's own decline code is behind "?".
let resultCell = (~chip: option<(string, tone)>, ~meaning: option<explainLine>, ~card="") => {
  let cardChip =
    <RenderIf condition={card->LogicUtils.isNonEmptyString}>
      <span className={`shrink-0 ${body.sm.medium} text-nd_gray-700`}>
        <SimulatorFormTiles.CardChip last4=card />
      </span>
    </RenderIf>
  switch chip {
  | Some((text, chipTone)) => {
      let (word, reason) = switch text->String.split(" · ") {
      | [word, reason] => (word, reason)
      | _ =>
        switch text->String.split(", ") {
        | [word, rest] => (word, rest)
        | _ => (text, "")
        }
      }
      let (reason, code) = switch reason->String.split("|") {
      | [reason, code] => (reason, Some(code))
      | _ => (reason, None)
      }
      let reason = switch reason->plainReason {
      | "Card declined" => ""
      | plain => plain
      }
      <div className="flex items-center gap-2 min-w-0">
        // The chip has a slot of its own, so the card starts at the same x on every row
        <span className="w-20 shrink-0 flex items-center">
          {<Chip className={chipTone->toneChipClass}> {word->React.string} </Chip>->chipWithMeaning(
            ~meaning,
          )}
        </span>
        cardChip
        <RenderIf condition={reason->LogicUtils.isNonEmptyString}>
          <span className={`truncate ${body.sm.medium} text-nd_gray-500`}>
            {reason->React.string}
          </span>
        </RenderIf>
        {switch code {
        | Some(code) => helpTip(`The processor's decline code: ${code}.`)
        | None => React.null
        }}
      </div>
    }
  | None => <div className="flex items-center gap-2 min-w-0"> cardChip </div>
  }
}

// A small payment card, white, for the circle of a step that charged or saved a card
let cardIcon =
  <svg
    width="13"
    height="13"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="2.4"
    strokeLinecap="round"
    strokeLinejoin="round">
    <rect x="2" y="5" width="20" height="14" rx="2" />
    <path d="M2 10h20" />
  </svg>

let markIcon = name =>
  switch name {
  | "card" => cardIcon
  | "" => <span className="w-1.5 h-1.5 rounded-full bg-white" />
  | name => <Icon name size=12 />
  }

// The row's circle on the rail (26 px), filled in the result's colour, with a white icon
module RowMark = {
  @react.component
  let make = (~fill, ~icon: React.element, ~pulse=false) =>
    <div
      className={`relative z-10 w-[26px] h-[26px] rounded-full flex items-center justify-center text-white ${fill} ${pulse
          ? "animate-pulse"
          : ""}`}>
      icon
    </div>
}

// The row itself: circle | text | result | "›"
// The result column fits "Declined", the card, a reason like "Not enough money" and its "?"
let rowColumns = "grid grid-cols-[2rem_minmax(0,1fr)_18rem_1rem] gap-x-3"

module RowLine = {
  @react.component
  let make = (
    ~domId=?,
    ~mark: React.element,
    ~line: React.element,
    ~result: React.element,
    ~onOpen: option<unit => unit>=?,
    ~tint="",
    ~below=React.null,
    // Under the row across the text and result columns (the result card's comparison)
    ~wide=React.null,
    ~trailing=?,
    ~revealClass="",
    ~animationDelay=?,
  ) => {
    let canOpen = onOpen->Option.isSome
    // One spacing scale: rows 16 px apart (8 px above and below), the line under the title 4 px down
    let cells = (~wideColumns) => <>
      <div className="min-w-0 flex flex-col gap-1">
        <div
          className={`min-h-6 flex flex-wrap items-center gap-x-2 gap-y-1 ${body.md.medium} text-nd_gray-700 tabular-nums`}>
          line
        </div>
        below
      </div>
      <div className="min-w-0 h-6 flex items-center"> result </div>
      <span
        className={`h-6 flex items-center justify-end text-nd_gray-400 ${canOpen
            ? "opacity-0 group-hover:opacity-100"
            : ""}`}>
        {switch trailing {
        | Some(element) => element
        | None => (canOpen ? "›" : "")->React.string
        }}
      </span>
      <div className=wideColumns> wide </div>
    </>
    tint->LogicUtils.isEmptyString
      ? <div
          id=?domId
          className={`group ${rowColumns} items-start py-2 pr-2 rounded-lg ${canOpen
              ? "cursor-pointer hover:bg-nd_gray-50"
              : ""} ${revealClass}`}
          style={animationDelay: ?animationDelay}
          onClick={_ => onOpen->Option.forEach(open_ => open_())}>
          <div className="flex justify-center h-6 items-center"> mark </div>
          {cells(~wideColumns="col-start-2 col-end-5")}
        </div>
      : // A result card: it starts at the text column and ends at the rows' right edge; the
        // node stays on the rail, centred on the card's first line. Inside, the result column
        // keeps the rows' x.
        <div
          id=?domId
          className={`group grid grid-cols-[2rem_minmax(0,1fr)] gap-x-3 items-start py-2 ${revealClass}`}
          style={animationDelay: ?animationDelay}
          onClick={_ => onOpen->Option.forEach(open_ => open_())}>
          <div className="flex justify-center h-6 items-center mt-3"> mark </div>
          <div
            className={`grid grid-cols-[minmax(0,1fr)_18rem_1rem] gap-x-3 items-start rounded-lg pl-3 pr-2 py-3 ${tint} ${canOpen
                ? "cursor-pointer"
                : ""}`}>
            {cells(~wideColumns="col-start-1 col-end-4")}
          </div>
        </div>
  }
}

// "Label · Fri, Oct 30 · 4:43 PM": the first line of every row (the card is in the result column)
let rowLine = (~label, ~whenText) => <>
  <span className={`${body.md.semibold} text-nd_gray-800`}> {label->React.string} </span>
  <RenderIf condition={whenText->LogicUtils.isNonEmptyString}>
    <span> {`· ${whenText}`->React.string} </span>
  </RenderIf>
</>

// A step on the rail (billing, the handover, an event, a setting) in the one row design. Its full
// sentence and details are in the drawer the row opens.
module StepRow = {
  @react.component
  let make = (
    ~domId,
    ~item: storyItem,
    ~whenText,
    ~revealClass,
    ~animationDelay,
    ~onOpen,
    ~time=?,
    ~children=React.null,
  ) => {
    let canOpen = item.row->Option.isSome
    <RowLine
      domId
      mark={<RowMark fill={item.tone->dotClass} icon={item.icon->markIcon} />}
      line={rowLine(~label=item.label, ~whenText)}
      result={resultCell(
        ~chip=item.chip,
        ~meaning=item.row->Option.flatMap(row => row.meaning),
        ~card=item.card,
      )}
      onOpen=?{canOpen ? Some(onOpen) : None}
      below={<>
        <RenderIf condition={item.detail->LogicUtils.isNonEmptyString}>
          <p className={`${body.sm.medium} text-nd_gray-500`}> {item.detail->React.string} </p>
        </RenderIf>
        {item.note->noteLine}
        children
      </>}
      trailing=?time
      revealClass
      ?animationDelay
    />
  }
}

// Rev Rec against the fixed timetable for the result card (stories 11-20): both sides, whether the
// fixed timetable recovered with Rev Rec's number of tries (A's sameTries, if sent), the proxy's
// sentence and math for the fixed timetable, and the invoice's amount
type comparison = {
  revrec: resultSide,
  fixed: option<resultSide>,
  sameTries: option<bool>,
  fixedText: string,
  math: array<string>,
  amount: string,
  // A's chart of both sides' tries, when the story has the lanes
  chart: option<SimulatorResultChart.data>,
}

// When the fixed timetable stops before the money is back, its last try (the proxy's math line
// "No try after it: the fixed timetable stops at try 15")
let fixedStopsAt = (c: comparison) =>
  c.math
  ->Array.find(line => line->String.includes("stops at try "))
  ->Option.flatMap(line =>
    line->String.split("stops at try ")->Array.get(1)->Option.flatMap(Int.fromString(_))
  )

// The fixed timetable with Rev Rec's number of tries: recovered only if its winning try came by then
let fixedWithSameTries = (c: comparison) =>
  switch (c.sameTries, c.fixed, c.revrec.tries) {
  | (Some(recovered), _, _) => Some(recovered)
  | (None, Some(fixed), Some(n)) =>
    Some(fixed.recovered && fixed.tries->Option.mapOr(false, tries => tries <= n))
  | _ => None
  }

// The result in plain words, honest both ways: "Same $65.40 with 10 fewer declined charges on the
// customer's card." Every try but the winning one is a declined charge, so the tries differ by as
// many declines.
let comparisonLine = (c: comparison) => {
  let charges = n => n == 1 ? "charge" : "charges"
  switch c.fixed {
  | None => c.fixedText
  | Some(fixed) =>
    switch (c.revrec.recovered, fixed.recovered, c.revrec.tries, fixed.tries) {
    | (true, true, Some(mine), Some(theirs)) if theirs > mine =>
      `Same ${c.amount} with ${(theirs - mine)->Int.toString} fewer declined ${(theirs - mine)
          ->charges} on the customer's card.`
    | (true, true, Some(mine), Some(theirs)) if theirs < mine =>
      `Same ${c.amount}, with ${(mine - theirs)->Int.toString} more declined ${(mine - theirs)
          ->charges} on the customer's card.`
    | (true, true, _, _) => `Same ${c.amount} with the same number of tries.`
    // Every fixed try declined before it stopped; Rev Rec's tries but the winning one declined
    | (true, false, Some(mine), _) if c->fixedStopsAt->Option.isSome => {
        let fewer = c->fixedStopsAt->Option.getOr(0) - (mine - 1)
        fewer > 0
          ? `Rev Rec recovered ${c.amount} with ${fewer->Int.toString} fewer declined ${fewer->charges}; the fixed timetable stops before the money is back.`
          : `Rev Rec recovered ${c.amount}; the fixed timetable stops before the money is back.`
      }
    | (true, false, _, _) =>
      `Rev Rec recovered ${c.amount}; the fixed timetable stops before the money is back.`
    | (false, true, _, _) =>
      `The fixed timetable would have recovered ${c.amount}; Rev Rec did not.`
    | (false, false, _, _) => `Neither recovered the ${c.amount}: the money came back too late.`
    }
  }
}

// "Try 11: Sat 9:03 PM, before the money" -> ("11", "Sat 9:03 PM")
let tryOf = (line, ~suffix) =>
  line->String.startsWith("Try ") && line->String.endsWith(suffix)
    ? switch line
      ->String.slice(~start=4, ~end=line->String.length - suffix->String.length)
      ->String.split(": ") {
      | [number, time] => Some((number, time))
      | _ => None
      }
    : None

// The math, one line each: when the money came back, the fixed timetable's tries around it (the
// proxy's lines, reshaped), Rev Rec's winning retry, and how long each took, honest both ways
let mathRows = (c: comparison) => {
  let before = line => line->tryOf(~suffix=", before the money")
  let after = line => line->tryOf(~suffix=", first after it")
  // The moment the card works: "Money back: Sun 9:00 AM" (a scripted bank or the visitor's Money is
  // back), or "Works again: Wed 7:48 PM" (the next try works, story 2)
  let isMoment = line =>
    line->String.startsWith("Money back: ") || line->String.startsWith("Works again: ")
  let moneyBack =
    c.math
    ->Array.find(isMoment)
    ->Option.map(line =>
      line->String.startsWith("Money back: ")
        ? ("Money came back", line->String.sliceToEnd(~start=12))
        : ("Card works again", line->String.sliceToEnd(~start=13))
    )
  let fixedTries = switch (
    c.math->Array.filterMap(before)->Array.get(0),
    c.math->Array.filterMap(after)->Array.get(0),
  ) {
  | (Some((b, bTime)), Some((a, aTime))) =>
    Some(("Fixed timetable", `try ${b} ${bTime} (before) · try ${a} ${aTime} (first after)`))
  | (None, Some((a, aTime))) => Some(("Fixed timetable", `try ${a} ${aTime} (first after)`))
  | _ => None
  }
  // Any other line as the proxy wrote it ("No try after it: the fixed timetable stops at try 15")
  let others =
    c.math
    ->Array.filter(line =>
      !(line->isMoment) && line->before->Option.isNone && line->after->Option.isNone
    )
    ->Array.map(line => Some(("Fixed timetable", line)))
  let revRec = switch (c.revrec.recovered, c.revrec.tries) {
  | (true, Some(n)) if c.revrec.recoveredAt->LogicUtils.isNonEmptyString =>
    Some((
      "Rev Rec",
      `retry ${n->Int.toString} ${c.revrec.recoveredAt->realLifeTime}, picked by the model`,
    ))
  | _ => None
  }
  let days = days => days->Float.toFixedWithPrecision(~digits=1)
  let tries = n => n == 1 ? "1 try" : `${n->Int.toString} tries`
  // How fast each side went, honest both ways
  let pace =
    [
      switch c.fixed {
      | Some({recovered: true, tries: Some(n), days: Some(d)}) if n > 0 =>
        Some(
          `Fixed timetable: ${n->tries} in ${d->days} days, about one every ${Math.round(
              d *. 24.0 /. n->Int.toFloat,
            )
            ->Float.toInt
            ->Int.toString} hours.`,
        )
      | _ => None
      },
      switch c.revrec {
      | {recovered: true, tries: Some(n), days: Some(d)} =>
        Some(`Rev Rec: ${n->tries} in ${d->days} days.`)
      | _ => None
      },
    ]
    ->Array.filterMap(part => part)
    ->Array.joinWith(" ")
  [moneyBack, fixedTries]
  ->Array.concat(others)
  ->Array.concat([revRec, pace->LogicUtils.isNonEmptyString ? Some(("Pace", pace)) : None])
  ->Array.filterMap(row => row)
}

// The math as a tidy list in the result card's left column: a small grey label, then the value
module MathRows = {
  @react.component
  let make = (~rows: array<(string, string)>) =>
    <RenderIf condition={rows->Array.length > 0}>
      <AddDataAttributes attributes=[("data-sim", "result-math-rows")]>
        <div className="flex flex-col gap-1.5">
          {rows
          ->Array.mapWithIndex(((label, value), index) =>
            <div
              key={index->Int.toString}
              className="grid grid-cols-[8.5rem_minmax(0,1fr)] gap-x-3 items-baseline">
              <span className={`${body.xs.semibold} text-nd_gray-500`}>
                {label->React.string}
              </span>
              <span className={`break-words ${body.sm.medium} text-nd_gray-700`}>
                {value->React.string}
              </span>
            </div>
          )
          ->React.array}
        </div>
      </AddDataAttributes>
    </RenderIf>
}

// The result card's right column: "The math" with the Computed chip, A's declined-charges bars, the
// two-lane chart and its legend (the math's lines are in the left column)
module MathPanel = {
  @react.component
  let make = (~chart: SimulatorResultChart.data) =>
    <AddDataAttributes attributes=[("data-sim", "result-math")]>
      // Its clicks stay here: a click on the result card opens the drawer
      <div
        className="h-full rounded-lg border border-nd_gray-150 bg-white p-4 flex flex-col gap-2"
        onClick={event => event->ReactEvent.Mouse.stopPropagation}>
        <div className="flex items-center gap-2">
          <p className={`${body.md.semibold} text-nd_gray-800`}> {"The math"->React.string} </p>
          {(Computed: source)->sourceChip}
        </div>
        <SimulatorResultChart data=chart />
      </div>
    </AddDataAttributes>
}

// The result's three tiles, Rev Rec first and the fixed timetable under it: Retries (the headline
// win), the same number of tries side by side (the team's like-for-like comparison), and
// Recovered. Then the plain line.
module ComparisonTiles = {
  let tile = (~label, ~mine, ~theirs) =>
    <div
      key=label
      className="min-w-0 rounded-lg border border-nd_gray-150 bg-white px-3 py-2.5 flex flex-col gap-1">
      <p className={`${body.sm.medium} text-nd_gray-500`}> {label->React.string} </p>
      <p className="flex flex-wrap items-baseline gap-x-1.5">
        <span className={`${heading.sm.semibold} text-nd_gray-800 tabular-nums`}>
          {mine->React.string}
        </span>
        <span className={`${body.xs.medium} text-nd_gray-500`}> {"Rev Rec"->React.string} </span>
      </p>
      <p className={`${body.xs.medium} text-nd_gray-400`}>
        {`Fixed timetable: ${theirs}`->React.string}
      </p>
    </div>

  @react.component
  let make = (~comparison as c: comparison) => {
    let tries = (side: option<resultSide>) =>
      side->Option.flatMap(side => side.tries)->Option.mapOr("—", Int.toString)
    let yesNo = recovered => recovered ? "Yes" : "No"
    let state = recovered => recovered ? "Recovered" : "Still declined"
    let sameLabel =
      c.revrec.tries->Option.mapOr("With the same tries", n =>
        `With the same ${n->Int.toString} ${n == 1 ? "try" : "tries"}`
      )
    <AddDataAttributes attributes=[("data-sim", "comparison")]>
      <div
        className="flex flex-col gap-3" onClick={event => event->ReactEvent.Mouse.stopPropagation}>
        <div className="grid grid-cols-3 gap-2">
          {tile(
            ~label="Retries",
            ~mine=Some(c.revrec)->tries,
            ~theirs=switch (c.fixed->Option.flatMap(fixed => fixed.tries), c->fixedStopsAt) {
            | (Some(n), _) => n->Int.toString
            | (None, Some(n)) => `${n->Int.toString}, then stops`
            | (None, None) => "—"
            },
          )}
          {tile(
            ~label=sameLabel,
            ~mine=c.revrec.recovered->state,
            ~theirs=c
            ->fixedWithSameTries
            ->Option.mapOr("—", recovered => recovered->state->String.toLowerCase),
          )}
          {tile(
            ~label="Recovered",
            ~mine=c.revrec.recovered->yesNo,
            ~theirs=c.fixed->Option.mapOr("—", fixed =>
              fixed.recovered->yesNo->String.toLowerCase
            ),
          )}
        </div>
        <p className={`${body.md.semibold} text-nd_gray-800`}>
          {c->comparisonLine->React.string}
        </p>
        <MathRows rows={c->mathRows} />
      </div>
    </AddDataAttributes>
  }
}

// The go-live story's result: one row per old invoice (Rev Rec's retries, how it ended and when),
// then one line saying what switching Rev Rec on did
module BacklogResult = {
  @react.component
  let make = (~backlog: array<backlogInvoice>) => {
    let recovered = backlog->Array.filter(invoice => invoice.stage == Recovered)->Array.length
    let total = backlog->Array.length
    let cell = `px-3 py-2 ${body.sm.medium} text-nd_gray-700`
    <AddDataAttributes attributes=[("data-sim", "backlog-result")]>
      <div className="mt-2 flex flex-col gap-2">
        <div className="rounded-lg border border-nd_gray-150 bg-white overflow-hidden">
          <div
            className={`grid grid-cols-[minmax(0,1fr)_8rem_minmax(0,1fr)] bg-nd_gray-25 border-b border-nd_gray-150 ${body.xs.semibold} text-nd_gray-500`}>
            <span className="px-3 py-2"> {"Invoice"->React.string} </span>
            <span className="px-3 py-2"> {"Rev Rec retries"->React.string} </span>
            <span className="px-3 py-2"> {"Result"->React.string} </span>
          </div>
          {backlog
          ->Array.map(invoice =>
            <div
              key={invoice.n->Int.toString}
              className="grid grid-cols-[minmax(0,1fr)_8rem_minmax(0,1fr)] border-b last:border-b-0 border-nd_gray-150 tabular-nums">
              <span className=cell> {`Old invoice ${invoice.n->Int.toString}`->React.string} </span>
              <span className=cell> {invoice.revrecRetries->Int.toString->React.string} </span>
              <span className=cell>
                {(
                  invoice.stage == Recovered && invoice.recoveredAt->LogicUtils.isNonEmptyString
                    ? `Recovered on ${invoice.recoveredAt->realLifeTime}`
                    : invoice.stage->stageName
                )->React.string}
              </span>
            </div>
          )
          ->React.array}
        </div>
        <p className={`${body.md.semibold} text-nd_gray-800`}>
          {(
            recovered == total
              ? `Rev Rec picked up all ${total->Int.toString} old invoices once switched on.`
              : `Rev Rec picked up ${total->Int.toString} old invoices once switched on; ${recovered->Int.toString} recovered.`
          )->React.string}
        </p>
      </div>
    </AddDataAttributes>
  }
}

// A story with no fixed-timetable comparison (presets 1 to 7): Rev Rec's side only, its retries and,
// when it recovered, how long it took (from the real-life timetable)
module RevRecOnly = {
  @react.component
  let make = (~tries: int, ~days: option<float>, ~recovered: bool) => {
    let tile = (~label, ~value) =>
      <div
        key=label
        className="min-w-0 rounded-lg border border-nd_gray-150 bg-white px-3 py-2.5 flex flex-col gap-1">
        <p className={`${body.sm.medium} text-nd_gray-500`}> {label->React.string} </p>
        <p className="flex flex-wrap items-baseline gap-x-1.5">
          <span className={`${heading.sm.semibold} text-nd_gray-800 tabular-nums`}>
            {value->React.string}
          </span>
          <span className={`${body.xs.medium} text-nd_gray-500`}> {"Rev Rec"->React.string} </span>
        </p>
      </div>
    <AddDataAttributes attributes=[("data-sim", "revrec-only")]>
      <div className="mt-2 grid grid-cols-2 laptop:grid-cols-3 gap-2">
        {tile(~label="Retries", ~value=tries->Int.toString)}
        {switch (recovered, days) {
        | (true, Some(days)) =>
          tile(
            ~label="Time to recover",
            ~value=`${days->Float.toFixedWithPrecision(~digits=1)} days`,
          )
        | _ => React.null
        }}
      </div>
    </AddDataAttributes>
  }
}

// The end row: a tick or a cross, how the invoice ended and when (real life), on a light tint
module OutcomeCard = {
  @react.component
  let make = (
    ~item: storyItem,
    ~whenText,
    ~revealClass,
    ~animationDelay,
    ~onOpen,
    ~comparison: option<comparison>=?,
    // The go-live story's old invoices, for its result table
    ~backlog: array<backlogInvoice>=[],
    // No comparison: Rev Rec's side only (retries, days to recover, recovered)
    ~revRecOnly: option<(int, option<float>, bool)>=?,
  ) => {
    let (fill, icon, word, tint) = switch item.outcome {
    | Some(OutcomeGreen) => ("bg-nd_green-400", "nd-check", "Recovered", "bg-nd_green-50")
    | Some(OutcomeRed) => ("bg-nd_red-500", "nd-cross", "Stopped", "bg-nd_red-50")
    | Some(OutcomeAmber) => ("bg-nd_yellow-500", "nd-hour-glass", "Waiting", "bg-nd_yellow-50")
    | _ => ("bg-nd_gray-400", "nd-check", "Ended", "bg-nd_gray-50")
    }
    // "Recovered on retry 3" without its real-life part: the time is on the first line
    let sentence = item.title->String.split(" · real life")->Array.get(0)->Option.getOr(item.title)
    // "Cancelled · you cancelled the invoice after 2 retries": the word on the first line, the
    // rest as the sentence under it
    let (word, sentence) = switch sentence->String.split("Cancelled · ") {
    | ["", rest] => (
        "Cancelled",
        rest->String.charAt(0)->String.toUpperCase ++ rest->String.sliceToEnd(~start=1),
      )
    | _ => (word, sentence)
    }
    let label =
      item.title->String.startsWith("Paid outside")
        ? "Paid outside Rev Rec"
        : item.title->String.includes("old invoices")
        ? item.title
        : word
    let canOpen = item.row->Option.isSome
    let belowLine = {
      let line =
        [sentence != label ? sentence : "", item.detail]
        ->Array.filter(LogicUtils.isNonEmptyString)
        ->Array.joinWith(" · ")
      <>
        <RenderIf condition={line->LogicUtils.isNonEmptyString}>
          <p className={`${body.sm.medium} text-nd_gray-500`}> {line->React.string} </p>
        </RenderIf>
        {item.note->noteLine}
      </>
    }
    switch comparison {
    // A real-world story's result: a bigger card in two columns (stacked below the dashboard's laptop
    // screen, 1080 px; arbitrary min-[] widths do not build with its mixed-unit screens). Left: how
    // it ended, the three tiles and the plain line; right: the math. The node stays on the rail,
    // centred on the card's first line.
    | Some(comparison) =>
      <div id=doneDomId>
        <div
          className={`grid grid-cols-[2rem_minmax(0,1fr)] gap-x-3 items-start py-2 ${revealClass}`}
          style={animationDelay: ?animationDelay}
          onClick={_ => canOpen ? onOpen() : ()}>
          <div className="flex justify-center h-6 items-center mt-4">
            <RowMark fill icon={icon->markIcon} />
          </div>
          <div
            className={`grid grid-cols-1 ${comparison.chart->Option.isSome
                ? "laptop:grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)]"
                : ""} gap-4 items-stretch rounded-lg p-4 ${tint} ${canOpen
                ? "cursor-pointer"
                : ""}`}>
            <div className="min-w-0 flex flex-col gap-3">
              <div className="flex flex-col gap-1">
                <div
                  className={`min-h-6 flex flex-wrap items-center gap-x-2 gap-y-1 ${body.md.medium} text-nd_gray-700 tabular-nums`}>
                  {rowLine(~label, ~whenText)}
                </div>
                belowLine
              </div>
              <ComparisonTiles comparison />
            </div>
            {switch comparison.chart {
            | Some(chart) => <MathPanel chart />
            | None => React.null
            }}
          </div>
        </div>
      </div>
    | None =>
      <div id=doneDomId>
        <RowLine
          mark={<RowMark fill icon={icon->markIcon} />}
          line={rowLine(~label, ~whenText)}
          // The label already says how it ended: no result chip, one grey line with the rest
          result=React.null
          onOpen=?{canOpen ? Some(onOpen) : None}
          tint
          below=belowLine
          wide={backlog->Array.length > 0
            ? <BacklogResult backlog />
            : switch revRecOnly {
              | Some((tries, days, recovered)) => <RevRecOnly tries days recovered />
              | None => React.null
              }}
          revealClass
          ?animationDelay
        />
      </div>
    }
  }
}

// The invoice state as one filled pill, the size and radius of the dashboard's medium button, in
// the Invoices badge colours (Monitoring blue, as asked; Processing a darker blue)
module StatePill = {
  @react.component
  let make = (~stage, ~isSmall=false) => {
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
      className={`shrink-0 flex items-center whitespace-nowrap ${isSmall
          ? `h-6 px-2 rounded-md ${body.sm.semibold}`
          : `h-9 px-4 rounded-10-px ${body.md.semibold}`} ${fill}`}>
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

// One Rev Rec retry in the row design: its result in the circle (a cross, a tick, or a pulsing
// clock for the next one), "Retry 11 · Fri, Oct 30 · 4:43 PM", the card, and the result
// Why Rev Rec's model picked a retry's time, in one line from its own counts (WORDING.md rule 6):
// how often that day worked before; a day with no tries yet, or one picked at the exploration
// floor to keep learning, says so. From one plan of GET /sim/story/:id/model (calendar.plans[]);
// None without a model decision.
let modelWhy = (plan: Dict.t<JSON.t>) => {
  open LogicUtils
  let model = plan->getDictfromDict("model")
  let days = model->getArrayFromDict("days", [])->Array.map(getDictFromJsonObject)
  let hours = model->getArrayFromDict("hours", [])->Array.map(getDictFromJsonObject)
  let isChosen = (d: Dict.t<JSON.t>) => d->getBool("chosen", false)
  days
  ->Array.find(isChosen)
  ->Option.map(day => {
    let short = day->getString("label", "")->String.split(",")->Array.get(0)->Option.getOr("")
    let hour =
      hours->Array.find(isChosen)->Option.mapOr("", hour => ` ${hour->getString("label", "")}`)
    let tries = day->getInt("of", 0)
    let chance = day->getFloat("chance", 0.1)
    // At the exploration floor: a day Rev Rec tries only to keep learning
    let isFloor = chance <= model->getFloat("explorationFloor", 0.1) +. 0.01
    let plural = switch short {
    | "Mon" => "Mondays"
    | "Tue" => "Tuesdays"
    | "Wed" => "Wednesdays"
    | "Thu" => "Thursdays"
    | "Fri" => "Fridays"
    | "Sat" => "Saturdays"
    | "Sun" => "Sundays"
    | other => other
    }
    if tries == 0 {
      `Picked ${short}${hour}: no tries on ${plural} yet, so Rev Rec tests it.`
    } else if isFloor {
      `Picked ${short}${hour} to keep learning (${chance->SimulatorModelView.oneIn} chance).`
    } else {
      `Picked ${short}${hour}: ${plural} worked ${day
        ->getInt("worked", 0)
        ->Int.toString} of ${tries->Int.toString} times before.`
    }
  })
}

// Each retry's reason by its number, read with the model view's endpoint (every 3 s while live)
let useModelWhys = (~storyId: option<string>, ~isLive) => {
  let simFetch = SimulatorApi.useSimFetch()
  let (whys, setWhys) = React.useState(_ => Dict.make())
  React.useEffect(() => {
    switch storyId {
    | None => None
    | Some(id) => {
        let read = async () =>
          try {
            let json = await simFetch(~path=`/sim/story/${id}/model`, ~method_=Get)
            let found = Dict.make()
            json
            ->LogicUtils.getDictFromJsonObject
            ->LogicUtils.getDictfromDict("calendar")
            ->LogicUtils.getArrayFromDict("plans", [])
            ->Array.forEach(item => {
              let plan = item->LogicUtils.getDictFromJsonObject
              plan
              ->modelWhy
              ->Option.forEach(
                text => found->Dict.set(plan->LogicUtils.getInt("n", 0)->Int.toString, text),
              )
            })
            setWhys(_ => found)
          } catch {
          | _ => ()
          }
        read()->ignore
        if isLive {
          let intervalId = setInterval(() => read()->ignore, 3000)
          Some(() => clearInterval(intervalId))
        } else {
          None
        }
      }
    }
  }, (storyId, isLive))
  whys
}

// The model's pick for each retry by its number, as "Fri 9 PM UTC · 30% worked at this hour": the
// chosen day and hour, and how often retries worked at that hour in the counts the model uses (its
// success counts, not the day's chance to be in the plan)
let modelPick = (plan: Dict.t<JSON.t>) => {
  open LogicUtils
  let model = plan->getDictfromDict("model")
  let isChosen = (d: Dict.t<JSON.t>) => d->getBool("chosen", false)
  let day =
    model->getArrayFromDict("days", [])->Array.map(getDictFromJsonObject)->Array.find(isChosen)
  let hour =
    model->getArrayFromDict("hours", [])->Array.map(getDictFromJsonObject)->Array.find(isChosen)
  switch (day, hour) {
  | (Some(day), Some(hour)) => {
      let short = day->getString("label", "")->String.split(",")->Array.get(0)->Option.getOr("")
      let tries = hour->getInt("of", 0)
      let worked =
        tries == 0
          ? "no tries at this hour yet"
          : `${Math.round(Int.toFloat(hour->getInt("worked", 0)) *. 100.0 /. Int.toFloat(tries))
              ->Float.toInt
              ->Int.toString}% worked at this hour`
      Some(`${short} ${hour->getString("label", "")} UTC · ${worked}`)
    }
  | _ => None
  }
}

// Each retry's pick by its number (every 3 s while live), for the model card beside the story
let useModelPicks = (~storyId: option<string>, ~isLive) => {
  let simFetch = SimulatorApi.useSimFetch()
  let (picks, setPicks) = React.useState(_ => Dict.make())
  React.useEffect(() => {
    switch storyId {
    | None => None
    | Some(id) => {
        let read = async () =>
          try {
            let json = await simFetch(~path=`/sim/story/${id}/model`, ~method_=Get)
            let found = Dict.make()
            json
            ->LogicUtils.getDictFromJsonObject
            ->LogicUtils.getDictfromDict("calendar")
            ->LogicUtils.getArrayFromDict("plans", [])
            ->Array.forEach(item => {
              let plan = item->LogicUtils.getDictFromJsonObject
              plan
              ->modelPick
              ->Option.forEach(
                text => found->Dict.set(plan->LogicUtils.getInt("n", 0)->Int.toString, text),
              )
            })
            setPicks(_ => found)
          } catch {
          | _ => ()
          }
        read()->ignore
        if isLive {
          let intervalId = setInterval(() => read()->ignore, 3000)
          Some(() => clearInterval(intervalId))
        } else {
          None
        }
      }
    }
  }, (storyId, isLive))
  picks
}

module RetryRow = {
  @react.component
  let make = (
    ~retry: retry,
    ~realLife: option<realLifeSlot>,
    ~card,
    ~onOpen,
    // Why Rev Rec's model picked this time, in one line
    ~why: option<string>=?,
    // Paused: the next retry waits, with no countdown (the engine holds it far ahead)
    ~isPaused=false,
    // The demo run time of the next retry; None while Rev Rec's pick moves to demo time
    ~nextRunsAt: option<string>=?,
  ) => {
    let whenText =
      realLife->Option.mapOr(
        retry.charge->Option.mapOr("", charge => charge.at->realLifeDateTime),
        slot => slot.at->realLifeDateTime,
      )
    let (mark, result) = switch (retry.charge, retry.dueAt) {
    | (Some(charge), _) => {
        let isOk = charge.status == StepOk
        (
          <RowMark
            fill={isOk ? "bg-nd_green-400" : "bg-nd_red-500"}
            icon={(isOk ? "nd-check" : "nd-cross")->markIcon}
          />,
          resultCell(
            ~chip=charge->chargeChip,
            ~meaning=charge.meaning,
            ~card=switch charge.label->cardOf {
            | "" => card
            | last4 => last4
            },
          ),
        )
      }
    // The next retry: its countdown takes the card's place, so the row stays one line
    | (None, _) if isPaused => (
        <RowMark fill="bg-nd_gray-400" icon={"pause"->markIcon} />,
        resultCell(~chip=Some(("Paused", ToneInfo)), ~meaning=None),
      )
    | (None, _) => (
        <RowMark fill="bg-nd_yellow-500" icon={"nd-hour-glass"->markIcon} pulse=true />,
        resultCell(~chip=Some(("Next", ToneWaiting)), ~meaning=None),
      )
    }
    // "Day 4 of the recovery" on hover; the drawer has it too
    let day = realLife->Option.mapOr("", slot =>
      `Day ${slot->slotDayNumber->Int.toString} of the recovery · ${slot.dayText
        ->String.split(", ")
        ->Array.at(-1)
        ->Option.getOr("")}`
    )
    <RowLine
      mark
      line={<>
        <span className={`${body.md.semibold} text-nd_gray-800`}>
          {`Retry ${retry.number->Int.toString}`->React.string}
        </span>
        <RenderIf condition={whenText->LogicUtils.isNonEmptyString}>
          {day->LogicUtils.isNonEmptyString
            ? <ToolTip
                description=day
                toolTipPosition=ToolTip.Top
                toolTipFor={<span> {`· ${whenText}`->React.string} </span>}
              />
            : <span> {`· ${whenText}`->React.string} </span>}
        </RenderIf>
        // Never an engine time: the demo run time, else "Picking a time"
        {switch (retry.charge, retry.dueAt, nextRunsAt) {
        | (None, Some(_), Some(runsAt)) if !isPaused =>
          <span
            className={`rounded-full px-2 py-0.5 bg-nd_yellow-50 text-nd_yellow-700 ${body.xs.semibold}`}>
            <Countdown nextRetryAt=runsAt />
          </span>
        | (None, Some(_), None) if !isPaused =>
          <span
            className={`rounded-full px-2 py-0.5 bg-nd_primary_blue-50 text-nd_primary_blue-600 ${body.xs.semibold}`}>
            {"Picking a time"->React.string}
          </span>
        | _ => React.null
        }}
      </>}
      result
      onOpen
      below={switch why {
      | Some(text) => <p className={`${body.sm.medium} text-nd_gray-500`}> {text->React.string} </p>
      | None => React.null
      }}
    />
  }
}

// Another row inside the retries block, at its time (a billing system try, an event, a setting,
// an earlier invoice ending), in the same design
module OtherRow = {
  @react.component
  let make = (~item: storyItem, ~whenText, ~onOpen) =>
    <RowLine
      mark={<RowMark fill={item.tone->dotClass} icon={item.icon->markIcon} />}
      line={rowLine(~label=item.label, ~whenText)}
      result={resultCell(
        ~chip=item.chip,
        ~meaning=item.row->Option.flatMap(row => row.meaning),
        ~card=item.card,
      )}
      onOpen
      below={item.note->noteLine}
    />
}

// A row of the retries block: a Rev Rec retry, or another row between two
type blockEntry = RetryEntry(retry) | OtherEntry(storyItem)

// When a retry ran, or is due; a retry with no time yet goes last
let retryMs = (retry: retry) => {
  let ms = switch (retry.charge, retry.dueAt, retry.booking) {
  | (Some(charge), _, _) => charge.at
  | (None, Some(dueAt), _) => dueAt
  | (None, None, Some(booking)) => booking.at
  | (None, None, None) => ""
  }->toMillis
  ms->Float.isNaN ? Float.Constants.maxValue : ms
}

let shownRetryLimit = 5

// Rev Rec's retries under one heading, one row each, on one grid so every chip, "?" and time
// starts at the same x. The chip column is as wide as the widest chip; the sentence takes the
// rest and wraps in its cell when the panel is narrow. A long run shows the latest five, with the
// rest behind "Show all N retries". Other rows (the billing system's own tries, an earlier invoice
// ending) sit between the retries at their time, and stay in view when the block is folded.
module RetryBlock = {
  @react.component
  let make = (
    ~retries: array<retry>,
    ~otherRows: array<storyItem>,
    ~plan: option<realLifePlan>,
    ~onRetryClick: retry => unit,
    ~onOtherClick: diagramRow => unit,
    ~whenOf: storyItem => string,
    ~revealClass,
    ~animationDelay,
    // A retry's one-line reason from Rev Rec's model, by its number
    ~whyOf: int => option<string>=_ => None,
    ~isPaused=false,
    // When the next retry runs in the demo (A's nextRetry.runsAt); None while a pick is re-timed
    ~nextRunsAt: option<string>=?,
    ~children=React.null,
  ) => {
    let (showAll, setShowAll) = React.useState(_ => false)
    // The next retry charges the card the last one did
    let lastCard =
      retries
      ->Array.toReversed
      ->Array.findMap(retry => retry.charge->Option.map(charge => charge.label->cardOf))
      ->Option.getOr("")
    let total = retries->Array.length
    let shown =
      retries
      ->Array.filter(retry => showAll || retry.number > total - shownRetryLimit)
      ->Array.map(retry => (retry->retryMs, RetryEntry(retry)))
      ->Array.concat(otherRows->Array.map(item => (item.at->toMillis, OtherEntry(item))))
    shown->Array.sort(((a, _), (b, _)) => a -. b)
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
      <div className="flex flex-col">
        {shown
        ->Array.map(((_, entry)) =>
          switch entry {
          | RetryEntry(retry) =>
            <RetryRow
              key={retry.number->Int.toString}
              retry
              realLife={slotFor(plan, retry.number)}
              card=lastCard
              onOpen={() => onRetryClick(retry)}
              why=?{whyOf(retry.number)}
              isPaused
              ?nextRunsAt
            />
          | OtherEntry(item) =>
            <OtherRow
              key={`billing-${item.lastRawIndex->Int.toString}`}
              item
              whenText={item->whenOf}
              onOpen={() => item.row->Option.forEach(onOtherClick)}
            />
          }
        )
        ->React.array}
      </div>
      <div className="ml-12"> children </div>
    </div>
  }
}

// How Rev Rec picks its retry times: Hyperswitch's fixed timetable, or (when C's smart profile
// lands) the Rev Rec model. The smart reason and candidates come in through `reason`.
type retryMode = StaticTimetable | SmartModel

// Every story runs the smart model; the fixed timetable shows only when the engine falls back to it
let retryModeLabel = mode =>
  switch mode {
  | StaticTimetable => "Fixed timetable"
  | SmartModel => "Smart · Rev Rec model"
  }

// "1 min", "9 h", "2 d 3 h"
let gapInWords = seconds =>
  if seconds < 3600 {
    `${Math.Int.max(seconds / 60, 1)->Int.toString} min`
  } else if seconds < 86400 {
    `${(seconds / 3600)->Int.toString} h`
  } else {
    let hours = mod(seconds, 86400) / 3600
    `${(seconds / 86400)->Int.toString} d${hours > 0 ? ` ${hours->Int.toString} h` : ""}`
  }

// Real-life calendar day of a slot, counted from the failure's day on the simulated calendar (UTC)
let utcDayOf = (date: Date.t) =>
  Date.UTC.makeWithYMD(
    ~year=date->Date.getUTCFullYear,
    ~month=date->Date.getUTCMonth,
    ~date=date->Date.getUTCDate,
  )

let failureDateOf = (slot: realLifeSlot) =>
  Date.fromTime(slot.at->toMillis -. slot.offsetSec->Int.toFloat *. 1000.0)

let dayNumberOfDate = (date: Date.t, ~failure: Date.t) =>
  ((utcDayOf(date) -. utcDayOf(failure)) /. 86400000.0)->Math.round->Float.toInt + 1

let dayNumberOf = (slot: realLifeSlot, ~failure: Date.t) =>
  slot.at->toUtcIso->Date.fromString->dayNumberOfDate(~failure)

// The static timetable's reason for a retry, from the gap before it
let staticReason = (plan: realLifePlan, slot: realLifeSlot) => {
  let previous = plan.slots->Array.find(other => other.retry == slot.retry - 1)
  switch previous {
  | Some(prev) =>
    `Fixed timetable: ${gapInWords(slot.offsetSec - prev.offsetSec)} after the last retry.`
  | None => `Fixed timetable: ${gapInWords(slot.offsetSec)} after the failure.`
  }
}

// The demo clock on the real-life calendar: between the last retry that ran and the next one, in
// proportion. Before the first retry it stays at the failure.
let realLifeNowMs = (~plan: realLifePlan, ~retries: array<retry>, ~nowMs, ~failureMs) => {
  let realMsOf = number => slotFor(Some(plan), number)->Option.map(slot => slot.at->toMillis)
  let ran = retries->Array.filterMap(retry =>
    switch (retry.charge, realMsOf(retry.number)) {
    | (Some(charge), Some(realMs)) => Some((charge.at->toMillis, realMs))
    | _ => None
    }
  )
  let due = retries->Array.filterMap(retry =>
    switch (retry.charge, retry.dueAt, realMsOf(retry.number)) {
    | (None, Some(dueAt), Some(realMs)) => Some((dueAt->toMillis, realMs))
    | _ => None
    }
  )
  let (fromDemo, fromReal) = ran->Array.at(-1)->Option.getOr((nowMs, failureMs))
  switch due->Array.get(0) {
  | Some((toDemo, toReal)) if toDemo > fromDemo => {
      let share = Math.min(Math.max((nowMs -. fromDemo) /. (toDemo -. fromDemo), 0.0), 1.0)
      fromReal +. share *. (toReal -. fromReal)
    }
  | _ => fromReal
  }
}

// Any demo moment on the real-life calendar: the failure until the first retry ran, in proportion
// between two retries, then toward the next booked one (or the last that ran)
let realLifeAtMs = (~plan: realLifePlan, ~retries: array<retry>, ~demoMs, ~failureMs) => {
  let realMsOf = number => slotFor(Some(plan), number)->Option.map(slot => slot.at->toMillis)
  let ran = retries->Array.filterMap(retry =>
    switch (retry.charge, realMsOf(retry.number)) {
    | (Some(charge), Some(realMs)) => Some((charge.at->toMillis, realMs))
    | _ => None
    }
  )
  let due = retries->Array.filterMap(retry =>
    switch (retry.charge, retry.dueAt, realMsOf(retry.number)) {
    | (None, Some(dueAt), Some(realMs)) => Some((dueAt->toMillis, realMs))
    | _ => None
    }
  )
  let anchors = ran->Array.concat(due)
  switch anchors->Array.findIndex(((anchorDemo, _)) => anchorDemo > demoMs) {
  // Before the first retry: the failure's moment
  | 0 => failureMs
  // After every anchor: the last one
  | -1 => anchors->Array.at(-1)->Option.mapOr(failureMs, ((_, realMs)) => realMs)
  | next => {
      let (fromDemo, fromReal) = anchors->Array.getUnsafe(next - 1)
      let (toDemo, toReal) = anchors->Array.getUnsafe(next)
      let share = Math.min(Math.max((demoMs -. fromDemo) /. (toDemo -. fromDemo), 0.0), 1.0)
      fromReal +. share *. (toReal -. fromReal)
    }
  }
}

// "declined, not enough money" for a retry's hover line; the generic decline is just "declined"
let retryResultText = (retry: option<retry>, ~isNext) =>
  switch retry->Option.flatMap(retry => retry.charge)->Option.flatMap(chargeChip) {
  | Some((text, _)) =>
    switch text->String.split(" · ") {
    | [word, reason] =>
      switch reason->String.split("|")->Array.get(0)->Option.getOr("")->plainReason {
      | "Card declined" | "" => word->String.toLowerCase
      | plain => `${word->String.toLowerCase}, ${plain->String.toLowerCase}`
      }
    | _ => text->String.toLowerCase
    }
  | None => isNext ? "next" : "planned"
  }

// Rev Rec's retries on the real calendar, above the rail. Compact: a strip with one column per
// day and its retries as dots. Expanded: a month grid (Mon to Sun, a row per week) with the same
// dots; a retry's time is in its dot's hover. Money-back days are green, outage days grey.
module RetryCalendar = {
  @react.component
  let make = (
    ~plan: realLifePlan,
    ~retries: array<retry>,
    ~isOver: bool,
    ~onRetryClick: retry => unit,
    ~mode: retryMode=StaticTimetable,
    // The next retry's reason; the smart model will send its own decision here
    ~reason: option<string>=?,
    // When the customer's money is back (the scripted bank's rule), in real-life time
    ~moneyBackAt: option<string>=?,
    // What the visitor changed, at its real-life moment: settings (markers), money back and
    // outages (bands)
    ~events: array<worldEvent>=[],
    // The visitor paused Rev Rec: the next retry waits (its dot stays still)
    ~isPaused=false,
    // A retry's one-line reason from Rev Rec's model, by its number
    ~whyOf: int => option<string>=_ => None,
    // The mode chip's text when it needs more than the mode ("Fixed timetable (smart not ready
    // for this processor)")
    ~modeLabel: option<string>=?,
  ) => {
    let (nowMs, setNowMs) = React.useState(_ => Date.now())
    // Compact by default (a week strip, so the story rows show too); Expand for the month grid
    let (isExpanded, setIsExpanded) = React.useState(_ => false)
    React.useEffect(() => {
      let intervalId = setInterval(() => setNowMs(_ => Date.now()), 1000)
      Some(() => clearInterval(intervalId))
    }, [])
    let retryFor = number => retries->Array.find(retry => retry.number == number)
    let isDone = (slot: realLifeSlot) =>
      retryFor(slot.retry)->Option.mapOr(false, retry => retry.charge->Option.isSome)
    let next = isOver ? None : plan.slots->Array.find(slot => !isDone(slot))
    let failure = plan.slots->Array.get(0)->Option.mapOr(Date.make(), failureDateOf)
    let realNow = Date.fromTime(
      realLifeNowMs(~plan, ~retries, ~nowMs, ~failureMs=failure->Date.getTime),
    )
    let nowDay = realNow->dayNumberOfDate(~failure)
    // The scripted bank's moment, else the visitor's "Money is back"
    let moneyBackAt = moneyBackAt->Option.orElse(
      events
      ->Array.find(event =>
        event.eventType == "money_back" && event.at->LogicUtils.isNonEmptyString
      )
      ->Option.map(event => event.at),
    )
    let moneyBack = moneyBackAt->Option.map(at => at->toUtcIso->Date.fromString)
    let dateOf = at => at->toUtcIso->Date.fromString
    let outages =
      events->Array.filter(event =>
        event.eventType == "outage" &&
        event.at->LogicUtils.isNonEmptyString &&
        event.until->LogicUtils.isNonEmptyString
      )
    // A mark for a setting change (amber), a stolen card (red) or a new card (blue)
    let markColor = eventType =>
      switch eventType {
      | "setting" => Some("bg-nd_yellow-500")
      | "stolen" => Some("bg-nd_red-500")
      | "new_card" => Some("bg-nd_primary_blue-450")
      | _ => None
      }
    let settingMarks =
      events->Array.filter(event =>
        event.eventType->markColor->Option.isSome && event.at->LogicUtils.isNonEmptyString
      )
    let moneyBackDay = moneyBack->Option.mapOr(0, date => date->dayNumberOfDate(~failure))
    let lastDay = plan.slots->Array.at(-1)->Option.mapOr(1, slot => slot->dayNumberOf(~failure))
    let dayCount = Math.Int.max(Math.Int.max(lastDay, moneyBackDay), 7)
    let days = Array.fromInitializer(~length=dayCount, index => index + 1)
    let dateOfDay = day =>
      Date.UTC.makeWithYMD(
        ~year=failure->Date.getUTCFullYear,
        ~month=failure->Date.getUTCMonth,
        ~date=failure->Date.getUTCDate + day - 1,
      )->Date.fromTime
    // Red declined, green approved, grey planned; the next one pulses (blue in the month grid)
    let dotClass = (slot: realLifeSlot, ~nextBlue) =>
      switch retryFor(slot.retry) {
      | Some({charge: Some(charge)}) =>
        charge.status == StepOk ? "bg-nd_green-400" : "bg-nd_red-500"
      | _ if next->Option.mapOr(false, other => other.retry == slot.retry) =>
        switch (isPaused, nextBlue) {
        | (true, _) => "bg-nd_gray-400"
        | (false, true) => "bg-nd_primary_blue-450 ring-4 ring-nd_primary_blue-100 animate-pulse"
        | (false, false) => "bg-nd_yellow-500 ring-4 ring-nd_yellow-100 animate-pulse"
        }
      | _ => "bg-nd_gray-300"
      }
    // Once the invoice has ended, only the retries that ran: the rest will never happen
    let slotsOfDay = day =>
      plan.slots->Array.filter(slot =>
        slot->dayNumberOf(~failure) == day && (!isOver || slot->isDone)
      )
    // A retry's dot: "Retry 6 · 5:00 PM UTC · Declined, not enough money" on hover, its drawer on
    // click
    let retryDot = (~nextBlue=false, slot: realLifeSlot) => {
      let retry = retryFor(slot.retry)
      let isNext = next->Option.mapOr(false, other => other.retry == slot.retry)
      let result = retry->retryResultText(~isNext)
      <ToolTip
        description={`Retry ${slot.retry->Int.toString} · ${slot.at->realLifeTime} ${calendarZone} · ${result
          ->String.charAt(0)
          ->String.toUpperCase}${result->String.sliceToEnd(~start=1)}`}
        toolTipPosition=ToolTip.Top
        toolTipFor={<div
          className={`w-3 h-3 rounded-full border-2 border-white ${retry->Option.isSome
              ? "cursor-pointer"
              : ""} ${slot->dotClass(~nextBlue)}`}
          onClick={_ => retry->Option.forEach(onRetryClick)}
        />}
      />
    }
    let markDot = (event: worldEvent) =>
      <ToolTip
        description=event.text
        toolTipPosition=ToolTip.Top
        toolTipFor={<div
          className={`w-2 h-2 rotate-45 border border-white ${event.eventType
            ->markColor
            ->Option.getOr("bg-nd_yellow-500")}`}
        />}
      />
    let dayHeader = day => {
      let date = dateOfDay(day)
      <div
        key={day->Int.toString}
        className={`flex justify-center pb-1.5 text-xs leading-4 whitespace-nowrap tabular-nums ${day ==
            nowDay
            ? "font-semibold text-nd_primary_blue-600"
            : "font-medium text-nd_gray-500"}`}>
        {`${date->toLocaleStringWith(None, {"weekday": "short", "timeZone": calendarZone})} ${date
          ->Date.getUTCDate
          ->Int.toString}`->React.string}
      </div>
    }
    // A day's tint: green once the money is back, grey in a bank outage
    let dayTint = day => {
      let dayStart = dateOfDay(day)->Date.getTime
      let dayEnd = dayStart +. 86400000.0
      let hasOutage =
        outages->Array.some(outage =>
          outage.at->dateOf->Date.getTime < dayEnd && outage.until->dateOf->Date.getTime > dayStart
        )
      switch moneyBack {
      | Some(_) if day > moneyBackDay => "bg-nd_green-50"
      | Some(_) if day == moneyBackDay => "bg-gradient-to-b from-white to-nd_green-50"
      | _ if hasOutage => "bg-nd_gray-100"
      | _ => ""
      }
    }
    // A day's retries and marks as dots, in time order
    let dotsOfDay = (~nextBlue=false, day) => {
      let dots =
        day
        ->slotsOfDay
        ->Array.map(slot => (slot.at->toMillis, retryDot(~nextBlue, slot)))
        ->Array.concat(
          settingMarks
          ->Array.filter(event => event.at->dateOf->dayNumberOfDate(~failure) == day)
          ->Array.map(event => (event.at->toMillis, markDot(event))),
        )
      dots->Array.sort(((a, _), (b, _)) => a -. b)
      dots->Array.mapWithIndex(((_, dot), index) =>
        <React.Fragment key={index->Int.toString}> dot </React.Fragment>
      )
    }
    // The compact week: one column per day, its retries and marks as dots in time order, no hour
    // axis. Money-back days are green, outage days grey, today light blue.
    let compactWeek =
      <div
        className="grid"
        style={gridTemplateColumns: `repeat(${dayCount->Int.toString}, minmax(0, 1fr))`}>
        {days->Array.map(dayHeader)->React.array}
        {days
        ->Array.map(day => {
          let tint = switch day->dayTint {
          | "" => day == nowDay && !isOver ? "bg-nd_primary_blue-25" : ""
          | tint => tint
          }
          <div
            key={day->Int.toString}
            className={`min-h-[36px] px-1 py-1.5 flex flex-wrap content-start justify-center gap-1.5 border-l border-nd_gray-150 ${day ==
                dayCount
                ? "border-r"
                : ""} ${tint}`}>
            {day->dotsOfDay->React.array}
          </div>
        })
        ->React.array}
      </div>
    // The month grid: Mon to Sun once, a row per week. Each day: its date (with the month on the
    // first day and on the 1st) and its dots side by side. Weeks with nothing stay low. Today and
    // the next retry's day are outlined; days outside the story are faint.
    let monthGrid = {
      let weekdayOf = (date: Date.t) => mod(date->Date.getUTCDay + 6, 7)
      let lead = dateOfDay(1)->weekdayOf
      let weekCount = (lead + dayCount + 6) / 7
      let nextDay = next->Option.map(slot => slot->dayNumberOf(~failure))
      let hasDots = day => day >= 1 && day <= dayCount && dotsOfDay(day)->Array.length > 0
      <div className="flex flex-col">
        <div className="grid grid-cols-7">
          {["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
          ->Array.map(name =>
            <div key=name className={`pb-1.5 text-center ${body.xs.semibold} text-nd_gray-500`}>
              {name->React.string}
            </div>
          )
          ->React.array}
        </div>
        <div className="grid grid-cols-7 border-l border-t border-nd_gray-150">
          {Array.fromInitializer(~length=weekCount, week => {
            let weekDays = Array.fromInitializer(~length=7, index => week * 7 + index + 1 - lead)
            let isQuiet = !(weekDays->Array.some(hasDots))
            weekDays->Array.map(day => {
              let date = dateOfDay(day)
              let inRange = day >= 1 && day <= dayCount
              let isToday = inRange && day == nowDay && !isOver
              let isNextDay = !isOver && nextDay == Some(day)
              let month =
                date->toLocaleStringWith(None, {"month": "short", "timeZone": calendarZone})
              let dateText = date->Date.getUTCDate->Int.toString
              <div
                key={day->Int.toString}
                className={`${isQuiet
                    ? "min-h-[30px]"
                    : "min-h-[60px]"} border-r border-b border-nd_gray-150 px-2 py-1.5 flex flex-col gap-1.5 ${inRange
                    ? day->dayTint
                    : "bg-nd_gray-25"} ${switch (isToday, isNextDay) {
                  | (_, true) => "ring-2 ring-inset ring-nd_primary_blue-450"
                  | (true, false) => "ring-2 ring-inset ring-nd_primary_blue-200"
                  | _ => ""
                  }}`}>
                <span
                  className={`text-xs leading-4 tabular-nums whitespace-nowrap ${!inRange
                      ? "text-nd_gray-300"
                      : isToday
                      ? "font-semibold text-nd_primary_blue-600"
                      : "font-medium text-nd_gray-500"}`}>
                  {(
                    inRange && (day == 1 || date->Date.getUTCDate == 1)
                      ? `${month} ${dateText}`
                      : dateText
                  )->React.string}
                </span>
                <RenderIf condition={day->hasDots}>
                  <div className="flex flex-wrap items-center gap-1.5">
                    {dotsOfDay(~nextBlue=true, day)->React.array}
                  </div>
                </RenderIf>
              </div>
            })
          })
          ->Array.flat
          ->React.array}
        </div>
      </div>
    }

    <div className="rounded-lg border border-nd_gray-150 bg-white px-4 py-3 flex flex-col gap-3">
      // The title stays whole; a long mode chip moves under it when the card is narrow
      <div className="flex flex-wrap items-start justify-between gap-x-3 gap-y-2">
        {switch next {
        | Some(_) if isPaused =>
          <p className={`${body.lg.semibold} text-nd_gray-800`}>
            {"Paused · next retry waits"->React.string}
          </p>
        | Some(slot) =>
          <div className="flex flex-col gap-0.5 min-w-0">
            <p className={`flex flex-wrap items-center gap-2 ${body.lg.semibold} text-nd_gray-800`}>
              {
                // The calendar's zone said once, here (and above the rail)
                let nextText = `Next retry: ${slot.at->realLifeTime} ${calendarZone} (day ${slot
                  ->dayNumberOf(~failure)
                  ->Int.toString})`
                // Compact: why this time is on hover, so the story rows get the room
                isExpanded
                  ? <span className="whitespace-nowrap"> {nextText->React.string} </span>
                  : <ToolTip
                      description={whyOf(slot.retry)
                      ->Option.orElse(reason)
                      ->Option.getOr(plan->staticReason(slot))}
                      toolTipPosition=ToolTip.Bottom
                      toolTipFor={<span className="cursor-help whitespace-nowrap">
                        {nextText->React.string}
                      </span>}
                    />
              }
            </p>
            <RenderIf condition=isExpanded>
              <p className={`${body.sm.medium} text-nd_gray-500`}>
                {whyOf(slot.retry)
                ->Option.orElse(reason)
                ->Option.getOr(plan->staticReason(slot))
                ->React.string}
              </p>
            </RenderIf>
          </div>
        | None =>
          <p className={`${body.lg.semibold} text-nd_gray-800`}>
            {"Real-life calendar"->React.string}
          </p>
        }}
        <div className="shrink-0 flex items-center gap-2">
          <RenderIf condition=isPaused>
            <Chip className="flex items-center gap-1 bg-nd_gray-150 text-nd_gray-700">
              <Icon name="pause" size=10 />
              {"Paused"->React.string}
            </Chip>
          </RenderIf>
          <Chip className="border border-nd_gray-200 bg-white text-nd_gray-600">
            {modeLabel->Option.getOr(mode->retryModeLabel)->React.string}
          </Chip>
          <button
            type_="button"
            className={`flex items-center gap-1 text-blue-500 hover:text-blue-700 ${body.sm.semibold}`}
            onClick={_ => setIsExpanded(prev => !prev)}>
            {(isExpanded ? "Collapse" : "Expand")->React.string}
            <Icon name={isExpanded ? "nd-angle-up" : "nd-angle-down"} size=12 />
          </button>
        </div>
      </div>
      {isExpanded ? monthGrid : compactWeek}
      {
        let legend =
          [
            moneyBackAt->Option.map(at => (
              "w-3 h-3 rounded-sm bg-nd_green-50 border border-nd_green-200",
              `Money back from ${at->realLifeTime}`,
            )),
            outages
            ->Array.get(0)
            ->Option.map(outage => (
              "w-3 h-3 rounded-sm bg-nd_gray-200",
              `Bank outage until ${outage.until->realLifeTime}`,
            )),
          ]
          ->Array.concat(
            [
              ("setting", "You changed a setting"),
              ("stolen", "Card reported stolen"),
              ("new_card", "New card added"),
            ]->Array.map(((eventType, text)) =>
              settingMarks->Array.some(event => event.eventType == eventType)
                ? eventType
                  ->markColor
                  ->Option.map(color => (`w-2 h-2 rotate-45 ${color}`, text))
                : None
            ),
          )
          ->Array.filterMap(entry => entry)
        <RenderIf condition={legend->Array.length > 0}>
          <div className="flex flex-wrap items-center gap-x-4 gap-y-1">
            {legend
            ->Array.map(((swatch, text)) =>
              <p key=text className={`flex items-center gap-2 ${body.sm.medium} text-nd_gray-600`}>
                <span className=swatch />
                {text->React.string}
              </p>
            )
            ->React.array}
          </div>
        </RenderIf>
      }
    </div>
  }
}

// The page never scrolls by itself. When a new row lands below the screen, a small pill offers to
// go there; only its click scrolls.
type tailRect = {top: float}
@val @scope("document")
external getElementById: string => Nullable.t<Dom.element> = "getElementById"
@send external getTailRect: Dom.element => tailRect = "getBoundingClientRect"
@val @scope("window") external windowHeight: float = "innerHeight"
@val @scope("window")
external removeEventListener3: (string, 'ev => unit, bool) => unit = "removeEventListener"

let tailDomId = "sim-story-tail"

let tailIsBelowScreen = () =>
  getElementById(tailDomId)
  ->Nullable.toOption
  ->Option.mapOr(false, tail => (tail->getTailRect).top > windowHeight)

let scrollToTail = () =>
  getElementById(tailDomId)
  ->Nullable.toOption
  ->Option.forEach(tail =>
    tail->Webapi.Dom.Element.scrollIntoViewWithOptions({"behavior": "smooth", "block": "end"})
  )

// One old invoice of a go-live story: its state, and what Rev Rec does with it
module BacklogCard = {
  @react.component
  let make = (~invoice: backlogInvoice, ~isOn) => {
    let (line, tone) = switch (isOn, invoice) {
    | (false, {recordedInMonitoringAt: ""}) => ("Declined, not reported yet", ToneInfo)
    | (false, _) => ("Monitoring: recorded, no retry", ToneWaiting)
    | (true, {waitingForReport: true}) => (
        "Waiting for the billing system to report it again",
        ToneWaiting,
      )
    | (true, {revrecRetries}) => (`Rev Rec: ${revrecRetries->retriesText}`, ToneRevRec)
    }
    <div className="rounded-xl border border-nd_gray-200 bg-white p-4 flex flex-col gap-3">
      <div className="flex items-center justify-between gap-2">
        <p className={`whitespace-nowrap ${body.md.semibold} text-nd_gray-800`}>
          {`Invoice ${invoice.n->Int.toString}`->React.string}
        </p>
        // Rev Rec has no state for an invoice it has not been informed about
        <RenderIf condition={invoice.stage != Starting}>
          <StatePill stage=invoice.stage isSmall=true />
        </RenderIf>
      </div>
      <p className={`w-fit rounded px-1.5 py-0.5 ${body.sm.semibold} ${tone->toneChipClass}`}>
        {line->React.string}
      </p>
    </div>
  }
}

// Preset 10: the old invoices Rev Rec finds when it goes live. In monitoring it records them and
// does not retry; after "Turn Rev Rec on" each restarts when the billing system reports it again.
module BacklogPanel = {
  @react.component
  let make = (~story: story, ~goLive: goLive, ~isBusy, ~onGoLive) => {
    let isOn = goLive.revRecOnAt->LogicUtils.isNonEmptyString
    <div className={`${cardStyle} px-6 py-5 flex flex-col gap-4`}>
      <div className="flex items-start justify-between gap-4">
        <div className="flex flex-col gap-0.5">
          <p className={`${body.lg.semibold} text-nd_gray-800`}> {"Old invoices"->React.string} </p>
          <p className={`${body.md.medium} text-nd_gray-500`}>
            {"Old invoices restart only when the billing system reports them again."->React.string}
          </p>
        </div>
        <Chip className={(isOn ? ToneRevRec : ToneWaiting)->toneChipClass}>
          {(isOn ? "Rev Rec on" : "Monitoring")->React.string}
        </Chip>
      </div>
      // Three in a row when there is room, else they wrap (at least 180 px each)
      <div className="grid grid-cols-[repeat(auto-fit,minmax(180px,1fr))] gap-3">
        {story.backlog
        ->Array.map(invoice => <BacklogCard key={invoice.n->Int.toString} invoice isOn />)
        ->React.array}
      </div>
      <RenderIf condition=story.canGoLive>
        <div>
          // 48 px; the padding sits on the text (the gradient is clipped to the content box)
          <Button
            text="Turn Rev Rec on"
            loadingText="Turning on…"
            buttonType=Primary
            buttonSize=Large
            customHeightClass="h-12"
            customTextPaddingClass="py-3 pl-8 pr-8"
            textWeight="text-base font-semibold"
            customButtonStyle="!w-auto"
            buttonState={isBusy ? Loading : Normal}
            onClick={_ => onGoLive()}
          />
        </div>
      </RenderIf>
    </div>
  }
}

// Preset 8: this invoice and the same customer's earlier one. Rev Rec charges one invoice per
// customer at a time, so this one waits (Queued) while the earlier one has its turn.
module QueuePanel = {
  @react.component
  let make = (~story: story, ~queue: queueInfo) => {
    let invoiceCard = (~title, ~stage, ~line, ~tone) =>
      <div className="rounded-xl border border-nd_gray-200 bg-white p-4 flex flex-col gap-3">
        <div className="flex items-center justify-between gap-2">
          <p className={`whitespace-nowrap ${body.md.semibold} text-nd_gray-800`}>
            {title->React.string}
          </p>
          <RenderIf condition={stage != Starting}>
            <StatePill stage isSmall=true />
          </RenderIf>
        </div>
        <p className={`w-fit rounded px-1.5 py-0.5 ${body.sm.semibold} ${tone->toneChipClass}`}>
          {line->React.string}
        </p>
      </div>
    let thisRetries = story.revrecRetries->Option.getOr(0)
    <div className={`${cardStyle} px-6 py-5 flex flex-col gap-4`}>
      <div className="flex flex-col gap-0.5">
        <p className={`${body.lg.semibold} text-nd_gray-800`}>
          {"One invoice at a time"->React.string}
        </p>
        <p className={`${body.md.medium} text-nd_gray-500`}>
          {queue.rule
          ->Option.mapOr("Rev Rec charges one invoice per customer at a time.", line => line.text)
          ->React.string}
        </p>
      </div>
      <div className="grid grid-cols-[repeat(auto-fit,minmax(180px,1fr))] gap-3">
        {invoiceCard(
          ~title="Invoice 1 · earlier",
          ~stage=queue.earlierStage,
          ~line=`Rev Rec: ${queue.earlierRetries->retriesText}`,
          ~tone=ToneRevRec,
        )}
        {queue.waiting
          ? invoiceCard(
              ~title="Invoice 2 · this one",
              ~stage=story.stage,
              ~line="Waiting for the customer's invoice 1",
              ~tone=ToneWaiting,
            )
          : invoiceCard(
              ~title="Invoice 2 · this one",
              ~stage=story.stage,
              ~line=`Rev Rec: ${thisRetries->retriesText}`,
              ~tone=ToneRevRec,
            )}
      </div>
      // What happened, once there is something to say, and the proof: never two charges at once
      {switch queue.result {
      | Some(line) =>
        <div className="flex flex-col gap-1">
          {Some(line)->noteLine}
          {switch queue.minGapSec {
          | Some(gap) =>
            <p className={`${body.sm.medium} text-nd_gray-500`}>
              {`Charges for this customer were at least ${gap
                ->Math.round
                ->Float.toInt
                ->Int.toString} s apart.`->React.string}
            </p>
          | None => React.null
          }}
        </div>
      | None => React.null
      }}
    </div>
  }
}

// The invoice's header bar, across the full page width above both columns: the state pill, the
// amount recovered with a slim bar, the retries by each side, the real invoice page, the menu.
// One 56 px row on a wide screen.
// What the scripted bank does to the card, in plain words, by the decline it gives
let bankDoes = reason =>
  switch reason {
  | "insufficient_funds" => "this card has no money"
  | "card_velocity_exceeded" => "this card is over its daily limit"
  | "processing_error" => "this card's bank is down"
  | "stolen_card" | "lost_card" => "this card is blocked"
  | "expired_card" => "this card has expired"
  | "fraudulent" => "this card is held for a fraud check"
  | _ => "this card is declined"
  }

// A real-world story's test bank, above the rail: one small line, the "why" behind "?"
module TestSetupLine = {
  @react.component
  let make = (~bank: bankPlan) => {
    let until =
      bank.worksFromAt->LogicUtils.isNonEmptyString
        ? ` until ${bank.worksFromAt->realLifeTime}`
        : ""
    <AddDataAttributes attributes=[("data-sim", "test-setup")]>
      <div
        className="flex items-center gap-2 rounded-lg border border-nd_gray-150 bg-nd_gray-25 px-3 py-2">
        <span className={`shrink-0 ${body.xs.semibold} uppercase tracking-wide text-nd_gray-500`}>
          {"Test setup"->React.string}
        </span>
        <span className={`min-w-0 ${body.md.medium} text-nd_gray-700`}>
          {`Test bank: ${bank.reason->bankDoes}${until}.`->React.string}
        </span>
        {helpTip(`${bank.text} The test bank is scripted: Rev Rec's retries fail until then.`)}
      </div>
    </AddDataAttributes>
  }
}

// Pause or Resume Rev Rec for this invoice: one clear, labelled primary button, in the status bar
// and on the focus card. Off (with the reason on hover) when the story cannot pause now.
module PauseButton = {
  @react.component
  let make = (
    ~isPaused,
    ~isOn,
    ~offReason="",
    ~onPause: bool => unit,
    ~height="!h-9",
    // "Pause" / "Resume" where the row is full (the status bar)
    ~isShort=false,
  ) =>
    <Button
      text={switch (isPaused, isShort) {
      | (true, true) => "Resume"
      | (false, true) => "Pause"
      | (true, false) => "Resume Rev Rec"
      | (false, false) => "Pause Rev Rec"
      }}
      buttonType=Primary
      buttonSize=Medium
      leftIcon={CustomIcon(<Icon name={isPaused ? "play" : "pause"} size=14 />)}
      customButtonStyle={`!w-auto ${height}`}
      buttonState={isOn ? Normal : Disabled}
      showTooltip={!isOn && offReason->LogicUtils.isNonEmptyString}
      tooltipText=offReason
      onClick={_ => onPause(!isPaused)}
    />
}

// The status bar, one line: the invoice (state, processor, money recovered) on the left; a thin
// divider; then Pause or Resume (primary), Make something happen, New story, Open invoice page (an
// icon, its name on hover) and the menu. Below 1200 px the left side shrinks; the buttons never
// wrap under it.
module InvoiceHeaderBar = {
  @react.component
  let make = (
    ~story: option<story>,
    ~form: option<billingForm>,
    ~menuOptions,
    // Pause (true) or resume (false) Rev Rec for this invoice
    ~onPause: option<bool => unit>=?,
    // New story (none in watch mode)
    ~onNewStory: option<unit => unit>=?,
    // "Make something happen", before New story
    ~eventsMenu=React.null,
    ~isBusy=false,
  ) => {
    let mixpanelEvent = MixpanelHook.useSendEvent()
    let {profileId, merchantId, orgId} = React.useContext(
      UserInfoProvider.defaultContext,
    ).getCommonSessionDetails()
    let stage = story->Option.mapOr(Starting, shownStage)
    let invoice = story->Option.mapOr(Dict.make(), s => s.invoice)
    let order = invoice->RevenueRecoveryEntity.itemToObjMapperForIntents
    let sign = form->Option.mapOr("USD", form => form.currency)->SimulatorFormTiles.currencySign
    // Until the engine records the invoice, the amount is the one the billing system charged
    let total =
      invoice->LogicUtils.isEmptyDict
        ? form->Option.mapOr(0.0, form => form.amount->LogicUtils.getFloatFromString(0.0))
        : order.order_amount
    let money = amount => `${sign}${amount->Float.toFixedWithPrecision(~digits=2)}`
    let percent = total > 0.0 ? Math.min(100.0, order.amount_captured /. total *. 100.0) : 0.0
    let recoveryId = story->Option.mapOr("", s => s.recoveryId)
    // The invoice page's path carries the profile, merchant and org, as the Invoices list's does
    let invoicePath = `/v2/recovery/invoices/${recoveryId}/${invoice->LogicUtils.getString(
        "profile_id",
        profileId,
      )}/${merchantId}/${orgId}`
    // The three actions look the same: secondary, 32 px, an icon and a label
    let actionButton = (~text, ~icon, ~isOn, ~offReason="", ~onClick) =>
      <Button
        text
        buttonType=Secondary
        buttonSize=Small
        leftIcon={CustomIcon(icon)}
        customButtonStyle="!w-auto !h-8"
        buttonState={isOn ? Normal : Disabled}
        showTooltip={!isOn && offReason->LogicUtils.isNonEmptyString}
        tooltipText=offReason
        onClick={_ => onClick()}
      />

    <div
      className={`${cardStyle} h-14 px-5 flex flex-nowrap items-center gap-4 ${body.md.medium} text-nd_gray-600`}>
      <div className="min-w-0 flex-1 flex items-center gap-3 overflow-hidden">
        <StatePill stage />
        // The processor the story charges through, by its logo (its name on hover)
        {switch story {
        | Some(s) if s.processorId->LogicUtils.isNonEmptyString =>
          <AddDataAttributes attributes=[("data-sim", "story-processor")]>
            <span
              className="shrink-0 flex items-center"
              title={s.processorName->LogicUtils.isNonEmptyString
                ? s.processorName
                : s.processorId}>
              <GatewayIcon gateway={s.processorId->String.toUpperCase} className="w-5 h-5" />
            </span>
          </AddDataAttributes>
        | _ => React.null
        }}
        <span className="min-w-0 truncate">
          <span className={`${body.md.semibold} text-nd_gray-800`}>
            {order.amount_captured->money->React.string}
          </span>
          {` / ${total->money} recovered`->React.string}
        </span>
        <div className="shrink-0 w-12 h-1.5 rounded-full bg-nd_gray-150 overflow-hidden">
          <div
            className="h-full rounded-full bg-nd_green-400"
            style={width: `${percent->Float.toString}%`}
          />
        </div>
      </div>
      <div className="shrink-0 w-px h-7 bg-nd_gray-200" />
      <div className="shrink-0 flex items-center gap-2">
        // Pause / Resume: the next retry waits while paused. Off (with the reason) when the story
        // cannot pause now; gone once the invoice has ended.
        {switch (story, onPause) {
        | (Some(s), Some(onPause)) if !(s->storyHasEnded) =>
          switch s.settings {
          | Some(settings) =>
            <PauseButton
              isPaused=settings.currentPaused
              isOn={settings.paused.allowed && !isBusy}
              offReason=settings.paused.reason
              onPause
              isShort=true
            />
          | None => React.null
          }
        | _ => React.null
        }}
        eventsMenu
        {switch onNewStory {
        | Some(onNewStory) =>
          actionButton(
            ~text="New story",
            ~icon=SimulatorStoryHelper.refreshIcon,
            ~isOn={!isBusy},
            ~onClick=onNewStory,
          )
        | None => React.null
        }}
        <RenderIf condition={recoveryId->LogicUtils.isNonEmptyString}>
          <ToolTip
            description="Open invoice page"
            toolTipPosition=ToolTip.Bottom
            toolTipFor={<button
              type_="button"
              ariaLabel="Open invoice page"
              className={`${SimulatorStoryHelper.statusButtonClass} w-8 justify-center`}
              onClick={_ => {
                mixpanelEvent(~eventName="recovery_simulator_open_invoice")
                RescriptReactRouter.push(GlobalVars.appendDashboardPath(~url=invoicePath))
              }}>
              <Icon name="external-link-alt" size=13 />
            </button>}
          />
        </RenderIf>
        <ActionMenu options=menuOptions />
      </div>
    </div>
  }
}

// The guided focus: the step happening now, on top in a highlighted card: Rev Rec's next retry
// (its countdown, the time the model picked and why), the retry running, Rev Rec picking a time, or
// the pause; with a large Pause or Resume (none in watch mode: the narration bar has it).
module FocusCard = {
  @react.component
  let make = (
    ~number: int,
    ~nextRunsAt: option<string>,
    ~pickedText: option<string>,
    ~why: option<string>,
    ~isPaused,
    ~settings: option<liveSettings>,
    ~onPause: option<bool => unit>=?,
    ~isBusy,
  ) => {
    let (nowMs, setNowMs) = React.useState(_ => Date.now())
    React.useEffect(() => {
      let intervalId = setInterval(() => setNowMs(_ => Date.now()), 1000)
      Some(() => clearInterval(intervalId))
    }, [])
    let retry = `Retry ${number->Int.toString}`
    let (title, line, isLive) = switch (isPaused, nextRunsAt) {
    | (true, _) => (`Paused · ${retry} waits`, "Rev Rec tries again when you resume.", false)
    | (false, Some(at)) if at->toMillis <= nowMs => (
        `${retry} is running`,
        "Rev Rec charges the card now.",
        true,
      )
    | (false, Some(at)) => (
        `${retry} ${countdownText(~nextRetryAt=at, ~nowMs)}`,
        [
          // "Sun 6:00 PM (day 4)" -> "Sun 6:00 PM UTC (day 4)"
          pickedText->Option.map(text => text->String.replace(" (day", ` ${calendarZone} (day`)),
          // The model's reason without its "Picked Sun 6 PM:" (the time is just before it)
          why->Option.map(why =>
            switch why->String.split(": ") {
            | [_, rest] => rest
            | _ => why
            }
          ),
        ]
        ->Array.filterMap(part => part)
        ->Array.joinWith(" · "),
        false,
      )
    | (false, None) => ("Rev Rec is picking a time", `For ${retry->String.toLowerCase}.`, true)
    }
    <AddDataAttributes attributes=[("data-sim", "focus-card")]>
      <div
        className="rounded-xl border-2 border-nd_primary_blue-200 bg-nd_primary_blue-25 px-5 py-4 flex flex-wrap items-center gap-4">
        <span className="relative flex h-3 w-3 shrink-0">
          <RenderIf condition=isLive>
            <span
              className="animate-ping absolute inline-flex h-full w-full rounded-full bg-nd_primary_blue-450 opacity-75"
            />
          </RenderIf>
          <span
            className={`relative inline-flex rounded-full h-3 w-3 ${isPaused
                ? "bg-nd_gray-400"
                : "bg-nd_primary_blue-450"}`}
          />
        </span>
        <div className="min-w-0 flex-1 flex flex-col gap-0.5">
          <p className={`${body.xs.semibold} uppercase tracking-wide text-nd_primary_blue-600`}>
            {"Happening now"->React.string}
          </p>
          <p className={`${heading.sm.semibold} text-nd_gray-800 tabular-nums`}>
            {title->React.string}
          </p>
          <RenderIf condition={line->LogicUtils.isNonEmptyString}>
            <p className={`${body.sm.medium} text-nd_gray-600`}> {line->React.string} </p>
          </RenderIf>
        </div>
        {switch (onPause, settings) {
        | (Some(onPause), Some(settings)) =>
          <PauseButton
            isPaused
            isOn={settings.paused.allowed && !isBusy}
            offReason=settings.paused.reason
            onPause
            height="!h-10"
          />
        | _ => React.null
        }}
      </div>
    </AddDataAttributes>
  }
}

// "Show steps" is remembered in this browser; storage may be blocked, then the steps start hidden
let readStepsShown: unit => bool = %raw(`function () {
  try { return window.localStorage.getItem("sim-story-steps-shown") === "1"; } catch (e) { return false; }
}`)
let saveStepsShown: bool => unit = %raw(`function (shown) {
  try { window.localStorage.setItem("sim-story-steps-shown", shown ? "1" : "0"); } catch (e) {}
}`)

// The story, step by step: the steps on one rail grouped by phase, under the focus card. The raw
// event list and the sequence diagram are optional, behind a link and a button.
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
    ~showDiagram,
    ~inlineActions,
    ~isBusy,
    ~onNext,
    ~onRowClick,
    ~onWaitingClick,
    ~onRetryClick: retry => unit,
    // Pause / Resume on the focus card (None in watch mode)
    ~onPause: option<bool => unit>=?,
    // Guided focus: "Hide steps" leaves the focus card and the result card (off in watch mode)
    ~guided=true,
  ) => {
    let (stepsShown, setStepsShown) = React.useState(_ => readStepsShown())
    let toggleSteps = () => {
      saveStepsShown(!stepsShown)
      setStepsShown(prev => !prev)
    }
    let rows = story->Option.mapOr([], s => s.timeline)
    let kind = story->Option.mapOr(PlainStory, storyKindOf)
    let isGoLive = kind == GoLiveStory
    // A go-live story's handover reports the old failures; Rev Rec only records them
    let nextLabel = isGoLive ? "Inform Rev Rec about the failures →" : "Let Rev Rec retry →"
    // Until the handover Rev Rec has nothing: no picking, no next retry, no planned dots
    let isAwaiting = story->Option.mapOr(false, s => s.awaitingHandover) && !isFinished
    // Each retry's one-line reason from Rev Rec's model
    let whys = useModelWhys(~storyId=story->Option.map(s => s.storyId), ~isLive=!isFinished)
    // A retry the model gave no time for ran on the fixed timetable: its line says so
    // The queue and second-card stories run smart on the decider, not Rev Rec's model
    let isDecider = story->Option.mapOr(false, s => s.scenarioId == 8 || s.scenarioId == 9)
    // Some processors' status sync loses the decline reason, so the model has no group for
    // retry 1 and it runs on the fixed timetable
    let processorName =
      story
      ->Option.filter(s => s.processorId->LogicUtils.isNonEmptyString && s.processorId != "stripe")
      ->Option.map(s =>
        s.processorName->LogicUtils.isNonEmptyString ? s.processorName : s.processorId
      )
    let whyOf = number =>
      isDecider
        ? Some("Smart mode, picked by the decider (not the model).")
        : whys
          ->Dict.get(number->Int.toString)
          ->Option.orElse(
            story
            ->Option.flatMap(s => s.realLife)
            ->Option.flatMap(plan =>
              plan.slots
              ->Array.find(slot => slot.retry == number && slot.source == "ladder")
              ->Option.map(slot =>
                switch (number, processorName) {
                | (1, Some(name)) =>
                  `Fixed timetable for this retry: ${name} did not pass on the decline reason.`
                | _ => plan->staticReason(slot)
                }
              )
            ),
          )
    // The visitor paused Rev Rec: the next retry waits until they resume
    let isPaused =
      !isFinished &&
      story
      ->Option.flatMap(s => s.settings)
      ->Option.mapOr(false, settings => settings.currentPaused)
    let visibleItems = items->Array.slice(~start=0, ~end=visibleCount)
    // Until the first charge lands, step 1 is the billing system creating the invoice
    let isCreating = visibleItems->Array.length == 0 && !isFinished
    let shownItems = isCreating
      ? [creatingItem(~form=optimistic->Option.orElse(story->Option.flatMap(s => s.form)))]
      : visibleItems
    let lastRawIndex = visibleItems->Array.at(-1)->Option.mapOr(-1, item => item.lastRawIndex)
    let visibleRows = rows->Array.slice(~start=0, ~end=lastRawIndex + 1)
    let hasStory = story->Option.isSome || optimistic->Option.isSome
    let hasRetries = visibleItems->Array.some(item => item.phase >= 3)
    let hasReport = visibleItems->Array.some(item => item.phase == 2)
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
    // "New retry ↓" when a row lands below the screen. The first rows of a story (on load, or
    // the first charge) never raise it; scrolling down to the end hides it.
    let (newBelow, setNewBelow) = React.useState(_ => None)
    let seenItems = React.useRef(-1)
    let seenRetries = React.useRef(0)
    let itemCount = shownItems->Array.length + (isFinished ? 1 : 0)
    React.useEffect(() => {
      let grew = itemCount > seenItems.current || retryRows > seenRetries.current
      if seenItems.current > 1 && grew && tailIsBelowScreen() {
        setNewBelow(_ => Some(retryRows > seenRetries.current ? "New retry ↓" : "New step ↓"))
      }
      seenItems.current = itemCount
      seenRetries.current = retryRows
      None
    }, (itemCount, retryRows))
    React.useEffect(() => {
      let onScroll = _ =>
        if !tailIsBelowScreen() {
          setNewBelow(_ => None)
        }
      // Captured, so a scroll inside the dashboard's own scroll box counts too
      Window.addEventListener3("scroll", onScroll, true)
      Some(() => removeEventListener3("scroll", onScroll, true))
    }, [])
    let revealOf = index => revealDelays->Dict.get(index->Int.toString)->revealProps
    // A row's real-life time: the demo clock mapped onto the real-life calendar (a retry's own
    // slot is exact). Last month's rows say so instead.
    let blockRetries =
      items
      ->Array.find(item => item.retries->Array.length > 0)
      ->Option.mapOr([], item => item.retries)
    let whenOf = (item: storyItem) =>
      if item.phase == 0 && kind == PlainStory {
        "Last month"
      } else if item.at->LogicUtils.isEmptyString {
        ""
      } else {
        switch story->Option.flatMap(s => s.realLife) {
        | Some(plan) => {
            let failureMs =
              plan.slots
              ->Array.get(0)
              ->Option.mapOr(item.at->toMillis, slot => slot->failureDateOf->Date.getTime)
            realLifeAtMs(~plan, ~retries=blockRetries, ~demoMs=item.at->toMillis, ~failureMs)
            ->Date.fromTime
            ->Date.toISOString
            ->realLifeDateTime
          }
        | None => item.at->realLifeDateTime
        }
      }
    // "Wed 8:00 PM (day 2)" for the waiting line, from A's nextRetry; none while a smart pick moves
    let nextRetry = story->Option.flatMap(s => s.nextRetry)
    let pickedText =
      nextRetry
      ->Option.filter(next => !next.pending && next.realLife->LogicUtils.isNonEmptyString)
      ->Option.map(next => `${next.realLife->realLifeTime} (day ${next.day->Int.toString})`)
    let nextRunsAt = switch nextRetry {
    | Some(next) if next.pending => None
    | Some(next) if next.runsAt->LogicUtils.isNonEmptyString => Some(next.runsAt)
    | _ => story->Option.flatMap(s => s.nextRetryAt)
    }
    let lastIndex = shownItems->Array.length - 1
    // The focus card leads once Rev Rec has the invoice and until the story ends
    let isFocusOn = story->Option.isSome && !isFinished && !isAwaiting && hasReport
    let focusNumber =
      nextRetry->Option.mapOr(
        blockRetries->Array.filter(retry => retry.charge->Option.isSome)->Array.length + 1,
        next => next.number,
      )
    // Steps hidden: only the focus card while the story runs, only the result card once it ends
    let canHideSteps = guided && (isFocusOn || isFinished)
    let hideSteps = canHideSteps && !stepsShown

    <div className={`${cardStyle} px-6 py-4 flex flex-col gap-4`}>
      <style> {revealCss->React.string} </style>
      {if !hasStory {
        <p className={`${body.md.medium} text-nd_gray-500`}>
          {"Loading the story…"->React.string}
        </p>
      } else {
        <>
          // Full width: the calendar and how Rev Rec picked the retry get room for their charts
          <div className="w-full flex flex-col gap-4">
            // The step happening now, on top
            {isFocusOn
              ? <FocusCard
                  number=focusNumber
                  nextRunsAt
                  pickedText
                  why={whyOf(focusNumber)}
                  isPaused
                  settings={story->Option.flatMap(s => s.settings)}
                  ?onPause
                  isBusy
                />
              : React.null}
            // C's model view: how Rev Rec's model picked the next retry.
            // It shows nothing until the model has decided (never on the static timetable).
            {switch story {
            // Its action row holds "Show the math" (left) and, on the right, the times' zone (said
            // once) and Show / Hide steps
            | Some(s) =>
              <SimulatorModelView
                storyId=s.storyId
                isLive={!(s->storyHasEnded)}
                footerRight={<>
                  <RenderIf condition={s.realLife->Option.isSome}>
                    <p className={`${body.xs.medium} text-nd_gray-400`}>
                      {`Times in ${calendarZone}`->React.string}
                    </p>
                  </RenderIf>
                  <RenderIf condition=canHideSteps>
                    <AddDataAttributes attributes=[("data-sim", "steps-toggle")]>
                      <button
                        type_="button"
                        className=SimulatorStoryHelper.statusButtonClass
                        onClick={_ => toggleSteps()}>
                        <span className=SimulatorStoryHelper.statusButtonText>
                          {(stepsShown ? "Hide steps" : "Show steps")->React.string}
                        </span>
                      </button>
                    </AddDataAttributes>
                  </RenderIf>
                </>}
              />
            | None => React.null
            }}
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
            // One rail, like Attempts History: a dashed line behind the dots. With the steps hidden it
            // holds only the result card.
            <div className="relative">
              <div className="relative flex flex-col">
                <div
                  className="absolute left-[15px] top-3 bottom-3 border-l-2 border-dashed border-nd_gray-200"
                />
                {shownItems
                ->Array.mapWithIndex((item, index) => {
                  if hideSteps && item.outcome->Option.isNone {
                    React.null
                  } else {
                    // -1 before the first item, so phase 0 ("Last month") gets its heading too; a new
                    // section (not each phase) starts a heading, the result included
                    let previousSection =
                      shownItems
                      ->Array.get(index - 1)
                      ->Option.mapOr(-1, previous => previous.phase->sectionOf)
                    let isFirstOfPhase =
                      shownItems->Array.findIndex(other => other.phase == item.phase) == index
                    let isLast = index == lastIndex
                    let (revealClass, animationDelay) = revealOf(index)
                    let onOpen = () => item.row->Option.forEach(onRowClick)
                    <React.Fragment key={index->Int.toString}>
                      <RenderIf condition={item.phase->sectionOf != previousSection}>
                        <PhaseHeading
                          phase=item.phase
                          kind
                          domId=?{isFirstOfPhase && item.phase != outcomePhase
                            ? Some(phaseDomId(item.phase))
                            : None}
                          isFirst={index == 0}
                          revealClass
                          animationDelay
                        />
                      </RenderIf>
                      {switch (item.outcome, item.retries) {
                      | (Some(_), _) =>
                        <div id={phaseDomId(outcomePhase)}>
                          <OutcomeCard
                            item
                            whenText={item->whenOf}
                            revealClass
                            animationDelay
                            onOpen
                            // The go-live story: its old invoices
                            backlog={story
                            ->Option.flatMap(s => s.goLive->Option.map(_ => s.backlog))
                            ->Option.getOr([])}
                            // No comparison (presets 1 to 7): Rev Rec's retries and, when it
                            // recovered, the days to its winning retry on the real-life timetable
                            revRecOnly=?{story->Option.flatMap(s =>
                              s.bank->Option.isSome || s.goLive->Option.isSome
                                ? None
                                : {
                                    let tries = s.revrecRetries->Option.getOr(
                                      blockRetries
                                      ->Array.filter(retry => retry.charge->Option.isSome)
                                      ->Array.length,
                                    )
                                    let recovered =
                                      item.outcome == Some(OutcomeGreen) &&
                                        s.recoveredBy == "revrec"
                                    let days =
                                      slotFor(s.realLife, tries)->Option.map(
                                        slot => slot.offsetSec->Int.toFloat /. 86400.0,
                                      )
                                    Some((tries, days, recovered))
                                  }
                            )}
                            // Stories 11-20: Rev Rec's tries against the fixed timetable's (computed)
                            comparison=?{story->Option.flatMap(s =>
                              s.bank->Option.flatMap(
                                bank =>
                                  bank.fixedTimetableText->Option.map(
                                    fixedText => {
                                      // The engine's side (A's bank.revRec); older stories count the
                                      // retries that ran
                                      revrec: bank.revRecSide->Option.getOr({
                                        recovered: item.outcome == Some(OutcomeGreen),
                                        tries: Some(
                                          s.revrecRetries->Option.getOr(
                                            blockRetries
                                            ->Array.filter(retry => retry.charge->Option.isSome)
                                            ->Array.length,
                                          ),
                                        ),
                                        days: None,
                                        recoveredAt: "",
                                      }),
                                      fixed: bank.fixedSide,
                                      sameTries: bank.fixedSameTries,
                                      fixedText,
                                      math: bank.fixedMath,
                                      chart: bank.resultChart,
                                      amount: s.form->Option.mapOr("", moneyText),
                                    },
                                  ),
                              )
                            )}
                          />
                        </div>
                      | (None, retries) if retries->Array.length > 0 =>
                        <RetryBlock
                          retries=item.retries
                          otherRows=item.otherRows
                          plan={story->Option.flatMap(s => s.realLife)}
                          onRetryClick
                          onOtherClick=onRowClick
                          whenOf
                          whyOf
                          isPaused
                          ?nextRunsAt
                          revealClass
                          animationDelay>
                          <RenderIf condition=isLast>
                            <NextControls
                              showNext=false
                              nextLabel
                              isWaiting=isWaitingForNext
                              nextRetryAt=nextRunsAt
                              ?pickedText
                              waiting
                              onWaitingWhy=onWaitingClick
                              onNext
                              inlineActions={isFinished ? [] : inlineActions}
                              isBusy
                              isPaused
                            />
                          </RenderIf>
                        </RetryBlock>
                      | (None, _) =>
                        <StepRow
                          domId={stepDomId(index)}
                          item
                          whenText={item->whenOf}
                          revealClass
                          animationDelay
                          onOpen
                          time=?{isCreating ? Some(<Loadericon size=14 />) : None}>
                          <RenderIf condition={isLast && !isCreating}>
                            <NextControls
                              showNext=false
                              nextLabel
                              isWaiting=isWaitingForNext
                              nextRetryAt=nextRunsAt
                              ?pickedText
                              waiting
                              onWaitingWhy=onWaitingClick
                              onNext
                              inlineActions={isFinished ? [] : inlineActions}
                              isBusy
                              isPaused
                            />
                          </RenderIf>
                        </StepRow>
                      }}
                    </React.Fragment>
                  }
                })
                ->React.array}
              </div>
            </div>
            <div id=tailDomId />
            {switch newBelow {
            | Some(text) =>
              <button
                className={`fixed bottom-6 right-6 z-30 rounded-full px-4 py-2 shadow-lg bg-nd_primary_blue-450 text-white hover:bg-nd_primary_blue-500 ${body.md.semibold}`}
                onClick={_ => {
                  scrollToTail()
                  setNewBelow(_ => None)
                }}>
                {text->React.string}
              </button>
            | None => React.null
            }}
            // "Show steps" shows every event too: one control, not two
            <RenderIf condition={guided && stepsShown && visibleRows->Array.length > 0}>
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
