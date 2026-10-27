// The "?" drawer, laid out like a form (Aayush's feedback, 26 Oct): a plain title, a grid of
// facts, what it means, why (one row per line, source chip first), then the raw calls, folded.
// Every step uses it: charges, reports, the booked retry, the outcome.
open SimulatorTypes
open SimulatorUtils
open Typography

// ---------- plain words for a step (they read the proxy's English labels; see NOTES) ----------

type rowKind =
  | NewInvoice
  | SaveCard
  | BillingCharge
  | ReportFailure
  | ReportAgain
  | ReportPaid
  | CancelInvoice
  | PickTime
  | BookedRetry
  | RevRecCharge
  | MarkPaid
  | PaidOutside
  | AddCard
  | CustomerPaid
  | OtherStep

let rowKind = (row: diagramRow) => {
  let startsWith = prefix => row.label->String.startsWith(prefix)
  switch (row.from, row.to) {
  | (Billing, Billing) => NewInvoice
  | (_, Processor) if startsWith("save card") => SaveCard
  | (Customer, Processor) if startsWith("add card") => AddCard
  | (Customer, Processor) => CustomerPaid
  | (Billing, Processor) => BillingCharge
  | (Billing, RevRec) if startsWith("report failure") => ReportFailure
  | (Billing, RevRec) if startsWith("report same failure again") => ReportAgain
  | (Billing, RevRec) if startsWith("report paid outside") => ReportPaid
  | (Billing, RevRec) if startsWith("cancel invoice") => CancelInvoice
  | (RevRec, RevRec) => PickTime
  | (RevRec, Processor) if row.status == StepPending => BookedRetry
  | (RevRec, Processor) => RevRecCharge
  | (RevRec, Billing) if row.label->String.includes("mark paid") => MarkPaid
  | (RevRec, Billing) => PaidOutside
  | _ => OtherStep
  }
}

let isApproved = (row: diagramRow) => row.status == StepOk

let plainTitle = (row: diagramRow) =>
  switch row->rowKind {
  | NewInvoice => "Invoice created"
  | SaveCard => "Card saved for the customer"
  | BillingCharge =>
    row->isApproved ? "Billing system's charge approved" : "Billing system's charge declined"
  | ReportFailure => "Failure reported to Rev Rec"
  | ReportAgain => "Same failure reported again"
  | ReportPaid => "Payment reported to Rev Rec"
  | CancelInvoice => "Invoice cancelled"
  | PickTime => "Retry time booked"
  | BookedRetry => "Retry booked"
  | RevRecCharge => row->isApproved ? "Rev Rec's retry approved" : "Rev Rec's retry declined"
  | MarkPaid => "Invoice recovered by Rev Rec"
  | PaidOutside => "Invoice paid outside Rev Rec"
  | AddCard => "Customer added a card"
  | CustomerPaid => row->isApproved ? "Customer paid in the app" : "Customer's payment declined"
  | OtherStep => row.label
  }

// One or two short sentences, with no ids in them
let meaning = (row: diagramRow) =>
  switch row->rowKind {
  | NewInvoice => "The billing system created this month's invoice for the customer."
  | SaveCard => "The customer's card is on file. Rev Rec retries this card."
  | BillingCharge =>
    row->isApproved
      ? "The billing system charged the card. The bank approved it."
      : "The billing system charged the card. The bank declined it."
  | ReportFailure => "The billing system told Rev Rec the payment failed. Rev Rec now tracks the invoice."
  | ReportAgain => "The billing system sent the same failure twice. Rev Rec keeps one copy."
  | ReportPaid => "The billing system told Rev Rec the invoice is paid. Rev Rec stops retrying."
  | CancelInvoice => "The merchant cancelled the invoice. Rev Rec stops retrying."
  | PickTime => "Rev Rec chose when to charge the saved card again."
  | BookedRetry => "Rev Rec will charge the saved card at the booked time."
  | RevRecCharge =>
    row->isApproved
      ? "Rev Rec charged the saved card by itself. The bank approved it."
      : "Rev Rec charged the saved card by itself. The bank declined it."
  | MarkPaid => "Rev Rec's retry collected the money. The billing system marks the invoice paid."
  | PaidOutside => "The invoice was paid outside Rev Rec, so Rev Rec stops."
  | AddCard => "The customer added a new card in the app."
  | CustomerPaid =>
    row->isApproved
      ? "The customer paid the invoice in the app."
      : "The customer tried to pay in the app. The bank declined it."
  | OtherStep => ""
  }

let resultText = (row: diagramRow, ~httpStatus: option<int>) => {
  let http = httpStatus->Option.mapOr("", code => ` (HTTP ${code->Int.toString})`)
  let declined =
    row.label
    ->SimulatorStorySteps.reasonOf
    ->Option.mapOr("Declined", reason => `Declined · ${reason}`)
  switch row->rowKind {
  | ReportFailure | ReportPaid | CancelInvoice =>
    row->isApproved ? `Recorded${http}` : `Refused${http}`
  | ReportAgain =>
    row.label->String.includes("already recorded") ? `Refused as a copy${http}` : `Recorded${http}`
  | PickTime => `Booked for ${row->SimulatorStorySteps.bookedTimeOf}`
  | BookedRetry => `Due at ${row.at->toClockTime}`
  | BillingCharge | RevRecCharge | CustomerPaid => row->isApproved ? "Approved" : declined
  | SaveCard | AddCard => "Saved"
  | NewInvoice => "Created"
  | MarkPaid | PaidOutside => "Paid"
  | OtherStep => ""
  }
}

// The Stripe charge (pi_…) of a step: from Rev Rec's attempt list, else named in the proxy's text
let chargeIdOf = (row: diagramRow, ~story: option<story>) =>
  row.attemptId
  ->Option.flatMap(attemptId => story->Option.flatMap(s => s.attemptTxn->Dict.get(attemptId)))
  ->Option.orElse(SimulatorStorySteps.capture(%re("/\b(pi_[A-Za-z0-9]+)/"), row.text))

let actorName = actor =>
  switch actor {
  | Processor => "Stripe"
  | other => other->actorLabel->fst
  }

// ---------- layout ----------

// A tiny chip for where a fact comes from: "From the sandbox", "Re-computed", "Rule-based"
let tinyChipStyle = "inline-block rounded border px-1 text-[10px] leading-4 font-semibold whitespace-nowrap"

module SourceChip = {
  @react.component
  let make = (~source: source) => {
    let (label, labelClass) = source->sourceLabel
    <span className={`${tinyChipStyle} ${labelClass}`}> {label->React.string} </span>
  }
}

// A titled block: 12 px grey capitals, 8 px above the content
module Section = {
  @react.component
  let make = (~title, ~children) => {
    <section className="flex flex-col gap-2">
      <p className="text-xs font-semibold uppercase tracking-wide text-nd_gray-400">
        {title->React.string}
      </p>
      children
    </section>
  }
}

// Label and value pairs: the label grey in a 120 px column
module Facts = {
  @react.component
  let make = (~facts: array<(string, React.element)>) => {
    <div
      className={`grid grid-cols-[120px_minmax(0,1fr)] gap-x-4 gap-y-2 items-center ${body.md.medium}`}>
      {facts
      ->Array.map(((label, value)) =>
        <React.Fragment key=label>
          <span className="text-nd_gray-500"> {label->React.string} </span>
          <div className="min-w-0 text-nd_gray-800"> value </div>
        </React.Fragment>
      )
      ->React.array}
    </div>
  }
}

// An id in monospace, cut to fit, with a copy button
module CopyId = {
  @react.component
  let make = (~id) => {
    <HelperComponents.CopyTextCustomComp
      displayValue=Some(id)
      customParentClass="flex items-center gap-2 min-w-0"
      customTextCss="font-jetbrains-mono text-[13px] truncate"
      customIconCss="h-5 opacity-70 shrink-0"
    />
  }
}

// Each line its own row: the source chip in a 96 px column, the text beside it
module WhyLines = {
  @react.component
  let make = (~lines: array<explainLine>) => {
    <div className="grid grid-cols-[96px_minmax(0,1fr)] gap-x-2 gap-y-2 items-start">
      {lines
      ->Array.mapWithIndex((line, index) =>
        <React.Fragment key={index->Int.toString}>
          <span className="pt-0.5">
            <SourceChip source=line.source />
          </span>
          <p className={`${body.md.medium} text-nd_gray-700`} style={overflowWrap: "anywhere"}>
            {line.text->SimulatorGlossary.linkTerms}
          </p>
        </React.Fragment>
      )
      ->React.array}
    </div>
  }
}

// A request or response body, folded until "Show"; 13 px monospace, scrolls past 320 px
module JsonBody = {
  @react.component
  let make = (~label, ~json: JSON.t) => {
    let (isOpen, setIsOpen) = React.useState(_ => false)
    let text = json->JSON.stringifyWithIndent(2)
    <div className="flex flex-col gap-2">
      <button
        type_="button"
        className={`w-fit flex items-center gap-1 ${body.sm.semibold} text-nd_gray-600 hover:text-nd_gray-800`}
        onClick={_ => setIsOpen(prev => !prev)}>
        {`${label} · ${isOpen ? "Hide" : "Show"}`->React.string}
        <Icon name={isOpen ? "nd-angle-up" : "nd-angle-down"} size=12 />
      </button>
      <RenderIf condition=isOpen>
        <div className="relative">
          <pre
            className="font-jetbrains-mono text-[13px] leading-5 max-h-[320px] overflow-auto rounded-md bg-nd_gray-50 border border-nd_gray-150 p-3 pr-10 whitespace-pre-wrap break-all text-nd_gray-700">
            {text->React.string}
          </pre>
          <div className="absolute top-1 right-2">
            <HelperComponents.CopyTextCustomComp displayValue=Some("") copyValue=Some(text) />
          </div>
        </div>
      </RenderIf>
    </div>
  }
}

let statusPillClass = status =>
  if status >= 200 && status < 300 {
    "bg-nd_green-50 text-nd_green-600"
  } else if status >= 400 {
    "bg-nd_red-50 text-nd_red-600"
  } else {
    "bg-nd_gray-150 text-nd_gray-600"
  }

// One raw call: its name, method and path (no host) with the status, then the bodies, folded
module CallCard = {
  @react.component
  let make = (~log: requestLog) => {
    let path = log.url->String.replaceRegExp(%re("/^https?:\/\/[^/]+/"), "")
    <div className="rounded-lg border border-nd_gray-150 p-4 flex flex-col gap-2">
      <p className={`${body.md.semibold} text-nd_gray-800`}> {log.step->React.string} </p>
      <div className="flex items-center gap-2 min-w-0">
        <span
          className="font-jetbrains-mono text-[13px] text-nd_gray-600 truncate"
          title={`${log.method} ${path}`}>
          {`${log.method} ${path}`->React.string}
        </span>
        <span
          className={`shrink-0 rounded-full px-2 text-xs leading-5 font-semibold ${log.status->statusPillClass}`}>
          {log.status->Int.toString->React.string}
        </span>
      </div>
      <JsonBody label="Request" json=log.request />
      <JsonBody label="Response" json=log.response />
    </div>
  }
}

// The drawer's scrolling body: 24 px padding, 24 px between sections
module Body = {
  @react.component
  let make = (~children) => {
    <div className="h-full relative">
      <div className="absolute inset-0 overflow-y-auto p-6 pb-20 flex flex-col gap-6">
        children
      </div>
    </div>
  }
}

let drawerTitle = text =>
  <p className={`${heading.sm.semibold} text-nd_gray-800`} style={overflowWrap: "anywhere"}>
    {text->React.string}
  </p>

// ---------- the drawer ----------

module ExplainDrawer = {
  @react.component
  let make = (~content: option<drawerContent>, ~story: option<story>, ~onClose) => {
    let history = story->Option.mapOr([], s => s.stageHistory)
    let recoveryId = story->Option.mapOr("", s => s.recoveryId)

    <Modal
      showModal={content->Option.isSome}
      setShowModal={_ => onClose()}
      closeOnOutsideClick=true
      modalHeading={switch content {
      | Some(StateHistory) => "Invoice states"
      | Some(WaitingDetails) => "Why Rev Rec is waiting"
      | _ => "What happened"
      }}
      modalClass="flex flex-col justify-start h-screen w-full md:w-2/5 float-right overflow-hidden !bg-white"
      childClass="relative h-full">
      {switch content {
      | Some(StepDetails(row)) =>
        let requests = story->Option.mapOr([], s => s.requests->requestsForRow(row))
        let httpStatus = requests->Array.at(-1)->Option.map(log => log.status)
        let who =
          row.from == row.to
            ? row.from->actorName
            : `${row.from->actorName} to ${row.to->actorName}`
        let facts = [
          Some(("Who", who->React.string)),
          Some((
            "When",
            <Table.DateCell
              textStyle={`${body.md.medium} text-nd_gray-800`}
              // Whole seconds: the dashboard's date cell would show milliseconds
              timestamp={row.at->toUtcIso->String.replaceRegExp(%re("/\.\d+(?=Z$)/"), "")}
              isCard=true
            />,
          )),
          history
          ->stageAt(row.at)
          ->Option.map(visit => (
            "Invoice state",
            `${visit.stage->stageName} (since ${visit.firstSeenAt->toClockTime})`->React.string,
          )),
          row->chargeIdOf(~story)->Option.map(id => ("Charge", <CopyId id />)),
          recoveryId->LogicUtils.isNonEmptyString
            ? Some(("Invoice", <CopyId id=recoveryId />))
            : None,
          switch row->resultText(~httpStatus) {
          | "" => None
          | text => Some(("Result", text->React.string))
          },
        ]->Array.filterMap(fact => fact)
        <Body>
          {row->plainTitle->drawerTitle}
          <Facts facts />
          <RenderIf condition={row->meaning->LogicUtils.isNonEmptyString}>
            <Section title="What this means">
              <p className={`${body.md.medium} text-nd_gray-700`}> {row->meaning->React.string} </p>
            </Section>
          </RenderIf>
          <RenderIf condition={row.why->Array.length > 0}>
            <Section title="Why">
              <WhyLines lines=row.why />
            </Section>
          </RenderIf>
          <RenderIf condition={requests->Array.length > 0}>
            <Section title="Request and response">
              <div className="flex flex-col gap-4">
                {requests
                ->Array.mapWithIndex((log, index) => <CallCard key={index->Int.toString} log />)
                ->React.array}
              </div>
            </Section>
          </RenderIf>
        </Body>
      // One retry: the booking and the charge together
      | Some(RetryDetails(booking, charge, number)) =>
        let rows = [booking, charge]->Array.filterMap(row => row)
        let requests =
          rows->Array.flatMap(row => story->Option.mapOr([], s => s.requests->requestsForRow(row)))
        let main = charge->Option.orElse(booking)
        let title = switch charge {
        | Some(row) =>
          `Retry ${number->Int.toString} · ${row->isApproved ? "Approved" : "Declined"}`
        | None => `Retry ${number->Int.toString} · Booked`
        }
        let facts = [
          Some(("Who", "Rev Rec to Stripe"->React.string)),
          booking->Option.map(row => (
            "Booked",
            `For ${row->SimulatorStorySteps.bookedTimeOf}, picked at ${row.at->toClockTime}`->React.string,
          )),
          charge->Option.map(row => (
            "Charged",
            <Table.DateCell
              textStyle={`${body.md.medium} text-nd_gray-800`}
              timestamp={row.at->toUtcIso->String.replaceRegExp(%re("/\.\d+(?=Z$)/"), "")}
              isCard=true
            />,
          )),
          main->Option.flatMap(row =>
            history
            ->stageAt(row.at)
            ->Option.map(visit => (
              "Invoice state",
              `${visit.stage->stageName} (since ${visit.firstSeenAt->toClockTime})`->React.string,
            ))
          ),
          charge
          ->Option.flatMap(row => row->chargeIdOf(~story))
          ->Option.map(id => ("Charge", <CopyId id />)),
          recoveryId->LogicUtils.isNonEmptyString
            ? Some(("Invoice", <CopyId id=recoveryId />))
            : None,
          Some((
            "Result",
            switch charge {
            | Some(row) => row->resultText(~httpStatus=None)
            | None => "Waiting for the booked time"
            }->React.string,
          )),
        ]->Array.filterMap(fact => fact)
        let meaningText =
          rows->Array.map(meaning)->Array.filter(LogicUtils.isNonEmptyString)->Array.joinWith(" ")
        // The same reason can come with both events
        let why =
          rows
          ->Array.flatMap(row => row.why)
          ->Array.reduce([], (kept, line: explainLine) =>
            kept->Array.some((other: explainLine) => other.text == line.text)
              ? kept
              : kept->Array.concat([line])
          )
        <Body>
          {title->drawerTitle}
          <Facts facts />
          <RenderIf condition={meaningText->LogicUtils.isNonEmptyString}>
            <Section title="What this means">
              <p className={`${body.md.medium} text-nd_gray-700`}> {meaningText->React.string} </p>
            </Section>
          </RenderIf>
          <RenderIf condition={why->Array.length > 0}>
            <Section title="Why">
              <WhyLines lines=why />
            </Section>
          </RenderIf>
          <RenderIf condition={requests->Array.length > 0}>
            <Section title="Request and response">
              <div className="flex flex-col gap-4">
                {requests
                ->Array.mapWithIndex((log, index) => <CallCard key={index->Int.toString} log />)
                ->React.array}
              </div>
            </Section>
          </RenderIf>
        </Body>
      | Some(WaitingDetails) =>
        <Body>
          {switch story->Option.flatMap(s => s.waiting) {
          | Some(waiting) =>
            <>
              {"Rev Rec has not booked a retry yet"->drawerTitle}
              <Facts
                facts=[
                  (
                    "Waiting",
                    `${waiting.minutes->Int.toString} min, no retry booked`->React.string,
                  ),
                  ("Invoice state", "Monitoring"->React.string),
                ]
              />
              <Section title="Why">
                <WhyLines lines=[{text: waiting.why, source: waiting.source}] />
              </Section>
            </>
          // The note goes away once Rev Rec books a retry
          | None =>
            <p className={`${body.md.medium} text-nd_gray-700`}>
              {"Rev Rec is not waiting any more. The steps show what it did."->React.string}
            </p>
          }}
        </Body>
      | Some(StateHistory) =>
        <Body>
          <p className={`${body.md.medium} text-nd_gray-600`}>
            {"When the invoice was first seen in each state. Times from Rev Rec are exact. Proxy times can be one poll late."->React.string}
          </p>
          <SimulatorTable
            headers=["State", "First seen", "Source"]
            rows={history->Array.map(visit => {
              let (sourceText, sourceClass) = visit->stageVisitSource
              [
                visit.stage->stageName->React.string,
                visit.firstSeenAt->toClockTime->React.string,
                <span className={`${tinyChipStyle} ${sourceClass}`}>
                  {sourceText->React.string}
                </span>,
              ]
            })}
            emptyText="The proxy has not reported any states yet."
          />
        </Body>
      | None => React.null
      }}
    </Modal>
  }
}
