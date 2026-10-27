// Portfolio run (PRD section 8). Left: the dials, in the same "Try It Out" layout as the story.
// Right: progress, then static retries vs Rev Rec on the same invoices. Every number says where
// it comes from: the sandbox, re-computed from it, the scripted bank, or a rule.
open SimulatorPortfolioTypes
open SimulatorPortfolioUtils
open Typography

let cardStyle = "bg-white border border-nd_gray-200 rounded-xl"

type sourceKind = FromSandbox | Recomputed | ScriptedBank | FromRule

module SourceChip = {
  @react.component
  let make = (~kind, ~isFixture) => {
    let (text, colorClass) = if isFixture {
      ("Fixture", "bg-nd_gray-50 text-nd_gray-600 border-nd_gray-200")
    } else {
      switch kind {
      | FromSandbox => SimulatorUtils.sourceLabel(Sandbox)
      | Recomputed => SimulatorUtils.sourceLabel(Recomputed)
      | FromRule => SimulatorUtils.sourceLabel(Rule)
      | ScriptedBank => (
          "Bank: scripted",
          "bg-nd_yellow-50 text-nd_yellow-700 border-nd_yellow-200",
        )
      }
    }
    <span
      className={`shrink-0 w-fit rounded px-1.5 py-0.5 border whitespace-nowrap ${body.xs.semibold} ${colorClass}`}>
      {text->React.string}
    </span>
  }
}

module SectionCard = {
  @react.component
  let make = (~title, ~subTitle="", ~accessory=React.null, ~children) => {
    <div className={`${cardStyle} px-6 py-5 flex flex-col gap-4`}>
      <div className="flex items-start justify-between gap-3">
        <div className="flex flex-col gap-1">
          <p className={`${heading.sm.semibold} text-nd_gray-800`}> {title->React.string} </p>
          <RenderIf condition={subTitle->LogicUtils.isNonEmptyString}>
            <p className={`${body.md.medium} text-nd_gray-500`}> {subTitle->React.string} </p>
          </RenderIf>
        </div>
        accessory
      </div>
      children
    </div>
  }
}

@send external setPointerCapture: (Dom.element, Dom.eventPointerId) => unit = "setPointerCapture"

// The decline mix: one stacked bar of five segments. Drag a boundary to move share between the
// two segments next to it.
module MixBar = {
  @react.component
  let make = (~mix, ~setMix, ~isDisabled) => {
    let barRef = React.useRef(Nullable.null)
    // While dragging: the boundaries that may move, and where the drag started (percent).
    // Two boundaries sit on the same spot when a segment is 0%; the first move picks one.
    let dragRef = React.useRef(None)
    let shares = mix->mixShares
    let boundaries = mix->mixBoundaries
    let lastIndex = boundaries->Array.length - 1

    let percentAt = event =>
      switch barRef.current->Nullable.toOption {
      | Some(element) =>
        let rect = element->Window.getBoundingClientRect
        let x = (event->ReactEvent.Pointer.clientX - rect.left)->Int.toFloat
        Math.max(0.0, Math.min(100.0, x /. rect.width->Int.toFloat *. 100.0))
      | None => 0.0
      }

    let onPointerDown = event =>
      if !isDisabled {
        let percent = event->percentAt
        let distance = boundary => Math.abs(boundary->Int.toFloat -. percent)
        let nearest = boundaries->Array.reduce(100.0, (best, b) => Math.min(best, b->distance))
        let candidates =
          boundaries
          ->Array.mapWithIndex((b, index) => (b, index))
          ->Array.filter(((b, _)) => b->distance == nearest)
          ->Array.map(((_, index)) => index)
        if nearest <= 8.0 {
          dragRef.current = Some((candidates, percent))
          barRef.current
          ->Nullable.toOption
          ->Option.forEach(element =>
            element->setPointerCapture(event->ReactEvent.Pointer.pointerId)
          )
        }
      }

    let onPointerMove = event =>
      switch dragRef.current {
      | Some((candidates, startPercent)) =>
        let percent = event->percentAt
        let index = switch candidates {
        | [index] => Some(index)
        | _ if percent < startPercent => candidates->Array.get(0)
        | _ if percent > startPercent => candidates->Array.at(-1)
        | _ => None
        }
        index->Option.forEach(index => {
          dragRef.current = Some(([index], startPercent))
          let low = index == 0 ? 0 : boundaries->Array.getUnsafe(index - 1)
          let high = index == lastIndex ? 100 : boundaries->Array.getUnsafe(index + 1)
          let snapped = (percent /. mixStep->Int.toFloat)->Math.round->Float.toInt * mixStep
          let next = Math.Int.max(low, Math.Int.min(high, snapped))
          if next != boundaries->Array.getUnsafe(index) {
            let moved = boundaries->Array.copy
            moved->Array.setUnsafe(index, next)
            setMix(moved->mixFromBoundaries)
          }
        })
      | None => ()
      }

    let onPointerEnd = _ => dragRef.current = None

    <div className="flex flex-col gap-3">
      <div
        ref={barRef->ReactDOM.Ref.domRef}
        className={`relative h-10 select-none touch-none ${isDisabled
            ? "opacity-60 cursor-not-allowed"
            : "cursor-ew-resize"}`}
        onPointerDown
        onPointerMove
        onPointerUp=onPointerEnd
        onPointerCancel=onPointerEnd>
        <div className="flex h-full w-full rounded-lg overflow-hidden bg-nd_gray-150">
          {reasons
          ->Array.mapWithIndex((reason, index) => {
            let share = shares->Array.get(index)->Option.getOr(0)
            <div
              key=reason
              className={`${reason->reasonColor} h-full flex items-center justify-center text-white ${share >
                mixStep
                  ? body.sm.semibold
                  : body.xs.semibold}`}
              style={width: `${share->Int.toString}%`}>
              <RenderIf condition={share >= mixStep}>
                {`${share->Int.toString}%`->React.string}
              </RenderIf>
            </div>
          })
          ->React.array}
        </div>
        // The handles, one per boundary; at 0% and 100% they sit on the bar's edge
        {boundaries
        ->Array.mapWithIndex((boundary, index) =>
          <div
            key={index->Int.toString}
            className="absolute -top-1 -bottom-1 w-1.5 -ml-[3px] rounded-full bg-white border border-nd_gray-300 shadow pointer-events-none"
            style={left: `${boundary->Int.toString}%`}
          />
        )
        ->React.array}
      </div>
      <div className="flex flex-col gap-1.5">
        {reasons
        ->Array.mapWithIndex((reason, index) => {
          let share = shares->Array.get(index)->Option.getOr(0)
          <div key=reason className={`flex items-center gap-2 ${body.sm.medium} text-nd_gray-600`}>
            <span className={`w-2.5 h-2.5 rounded-sm shrink-0 ${reason->reasonColor}`} />
            <span>
              {reason->reasonLabel->React.string}
              <RenderIf condition={reason->isHardReason}>
                <span className="text-nd_gray-400"> {" · hard"->React.string} </span>
              </RenderIf>
            </span>
            <span className="ml-auto text-nd_gray-500">
              {`${share->Int.toString}%`->React.string}
            </span>
          </div>
        })
        ->React.array}
      </div>
    </div>
  }
}

// Left panel: the dials, as tiles and one number field (UX-PASS-2 C, same pieces as the story form)
module DialsForm = {
  @react.component
  let make = (
    ~dials: portfolioDials,
    ~setDials,
    ~limits: portfolioLimits,
    ~isBusy,
    ~isRunning,
    ~onRun,
    ~onStop,
  ) => {
    let isLocked = isBusy || isRunning
    let total = dials.mix->mixTotal

    <div className={`${cardStyle} p-6 flex flex-col gap-5`}>
      <SimulatorStoryHelper.FormField label="Invoices">
        <div className="grid grid-cols-2 gap-3">
          {invoiceCounts
          ->Array.map(count => {
            let isAboveLimit = count > limits.maxInvoices
            <SimulatorFormTiles.Tile
              key={count->Int.toString}
              title={`${count->Int.toString} invoices`}
              isSelected={dials.invoiceCount == count}
              isDisabled={isLocked || isAboveLimit}
              tag={isAboveLimit ? "Soon" : ""}
              hint={isAboveLimit
                ? `The proxy allows ${limits.maxInvoices->Int.toString} invoices for now.`
                : ""}
              onClick={() => setDials(prev => {...prev, invoiceCount: count})}
            />
          })
          ->React.array}
        </div>
      </SimulatorStoryHelper.FormField>
      <SimulatorStoryHelper.FormField label="Stop after">
        <div className="grid grid-cols-3 gap-3">
          {limits.stopAfterMinutes
          ->Array.map(minutes =>
            <SimulatorFormTiles.Tile
              key={minutes->Float.toString}
              title={minutes->stopAfterLabel}
              isSelected={dials.maxMinutes == minutes}
              isDisabled=isLocked
              onClick={() => setDials(prev => {...prev, maxMinutes: minutes})}
            />
          )
          ->React.array}
        </div>
      </SimulatorStoryHelper.FormField>
      <SimulatorStoryHelper.FormField label="Amount per invoice">
        <SimulatorFormTiles.AmountField
          amount=dials.amount
          setAmount={amount => setDials(prev => {...prev, amount})}
          currency="USD"
          isDisabled=isLocked
        />
      </SimulatorStoryHelper.FormField>
      <SimulatorStoryHelper.FormField label="Decline mix">
        <MixBar
          mix=dials.mix setMix={mix => setDials(prev => {...prev, mix})} isDisabled=isLocked
        />
      </SimulatorStoryHelper.FormField>
      <Button
        text="Run"
        buttonType=Primary
        buttonSize=Medium
        customButtonStyle="!w-full"
        buttonState={isBusy ? Loading : total == 0 || isRunning ? Disabled : Normal}
        onClick={_ => onRun()}
      />
      <RenderIf condition=isRunning>
        <Button
          text="Stop run"
          buttonType=Secondary
          buttonSize=Small
          customButtonStyle="!w-full"
          onClick={_ => onStop()}
        />
      </RenderIf>
      <p className={`${body.sm.medium} text-nd_gray-400`}> {"Visa cards only."->React.string} </p>
    </div>
  }
}

// A small "?" that shows the why on hover
module WhyButton = {
  @react.component
  let make = (~why) =>
    <ToolTip
      description=why
      toolTipPosition=ToolTip.Top
      toolTipFor={<span
        className={`flex items-center justify-center w-5 h-5 rounded-full border border-nd_gray-300 bg-white text-nd_gray-500 cursor-help ${body.xs.semibold}`}>
        {"?"->React.string}
      </span>}
    />
}

// While the proxy creates the invoices: one column per side, one row per invoice that fills in
// as its copy is charged and reported, under a thin bar with the elapsed time and the time left.
// The dots and chips are the invoice story's.
module SetupBoard = {
  open SimulatorStorySteps

  let stateLook = state =>
    switch state {
    | SetupWaiting => (ToneInfo, None, "Waiting")
    | SetupCreating => (TonePending, Some(SimulatorTypes.Billing), "Charging")
    | SetupCharged => (ToneRevRec, Some(SimulatorTypes.Billing), "Charged")
    | SetupReported => (ToneOk, Some(SimulatorTypes.RevRec), "Reported")
    | SetupFailed => (ToneDeclined, Some(SimulatorTypes.Billing), "Failed")
    }

  module CopyRow = {
    @react.component
    let make = (~invoice: portfolioInvoice, ~state) => {
      let (tone, actor, statusText) = state->stateLook
      <div className="flex items-center gap-2 h-8">
        <span
          className={`w-2 h-2 rounded-full shrink-0 transition-colors duration-300 ease-in-out ${tone->dotClass}`}
        />
        <span className={`w-5 shrink-0 ${body.sm.medium} text-nd_gray-400`}>
          {`#${invoice.index->Int.toString}`->React.string}
        </span>
        <span
          title={invoice.reason->reasonLabel}
          className={`flex-1 min-w-0 truncate ${body.sm.medium} ${state == SetupWaiting
              ? "text-nd_gray-400"
              : "text-nd_gray-700"}`}>
          {invoice.reason->reasonLabel->React.string}
        </span>
        {switch actor {
        | Some(actor) =>
          <span
            className={`shrink-0 rounded px-1.5 py-0.5 ${body.xs.semibold} ${actor->actorChipClass}`}>
            {actor->actorChipText->React.string}
          </span>
        | None => React.null
        }}
        <span
          className={`shrink-0 w-16 text-center rounded px-1.5 py-0.5 ${body.xs.semibold} ${tone->toneChipClass}`}>
          {statusText->React.string}
        </span>
      </div>
    }
  }

  @react.component
  let make = (~run: portfolioRun) => {
    let (nowMs, setNowMs) = React.useState(_ => Date.now())
    React.useEffect(() => {
      let intervalId = setInterval(() => setNowMs(_ => Date.now()), 1000)
      Some(() => clearInterval(intervalId))
    }, [])
    let total = Math.Int.max(run.plannedInvoices, run.invoices->Array.length)
    let totalCopies = total * 2
    let states =
      run.invoices->Array.map(invoice => (
        invoice,
        invoice.staticCopy->copySetupState,
        invoice.smartCopy->copySetupState,
      ))
    let finalCount = state => state->isSetupFinal ? 1 : 0
    let copiesDone =
      states->Array.reduce(0, (sum, (_, onStatic, onSmart)) =>
        sum + onStatic->finalCount + onSmart->finalCount
      )
    let invoicesDone =
      states
      ->Array.filter(((_, onStatic, onSmart)) => onStatic->isSetupFinal && onSmart->isSetupFinal)
      ->Array.length
    let current = Math.Int.min(total, invoicesDone + 1)
    let elapsed = Math.Int.max(
      0,
      ((nowMs -. run.startedAt->Date.fromString->Date.getTime) /. 1000.0)->Float.toInt,
    )
    let percent = totalCopies > 0 ? copiesDone * 100 / totalCopies : 0
    // The time left from the pace so far (seconds per finished copy), rounded to 5 s
    let leftText = if copiesDone < 2 {
      "Measuring the pace…"
    } else if copiesDone < totalCopies {
      let left = (totalCopies - copiesDone) * elapsed / copiesDone
      `About ${((left + 4) / 5 * 5)->durationText} left`
    } else {
      "Almost done"
    }
    let column = (~title, ~isStatic) => {
      let reported =
        states
        ->Array.filter(((_, onStatic, onSmart)) => (isStatic ? onStatic : onSmart) == SetupReported)
        ->Array.length
      <div className="flex flex-col gap-1 min-w-0">
        <div className="flex items-center justify-between gap-2 pb-2 border-b border-nd_gray-150">
          <span className={`${body.md.semibold} text-nd_gray-800`}> {title->React.string} </span>
          <span className={`${body.sm.medium} text-nd_gray-500`}>
            {`${reported->Int.toString} of ${total->Int.toString} reported`->React.string}
          </span>
        </div>
        {states
        ->Array.map(((invoice, onStatic, onSmart)) =>
          <CopyRow
            key={invoice.index->Int.toString} invoice state={isStatic ? onStatic : onSmart}
          />
        )
        ->React.array}
      </div>
    }

    <div className={`${cardStyle} p-6 flex flex-col gap-6`}>
      <div className="flex flex-col gap-2">
        <div className={`flex justify-between gap-3 ${body.md.semibold} text-nd_gray-700`}>
          <span>
            {`Creating invoice ${current->Int.toString} of ${total->Int.toString} · ${elapsed->durationText} elapsed`->React.string}
          </span>
          <span className="whitespace-nowrap text-nd_gray-500"> {leftText->React.string} </span>
        </div>
        <div className="w-full h-1.5 rounded-full bg-nd_gray-150 overflow-hidden">
          <div
            className="h-1.5 rounded-full bg-nd_primary_blue-450 transition-all duration-500 ease-in-out"
            style={width: `${percent->Int.toString}%`}
          />
        </div>
      </div>
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        {column(~title="Static retries", ~isStatic=true)}
        {column(~title="Rev Rec", ~isStatic=false)}
      </div>
    </div>
  }
}

// After setup: one line and a slim bar for how many copies are final
module RunStatus = {
  @react.component
  let make = (~run: portfolioRun) => {
    let total = Math.Int.max(
      run.plannedInvoices * 2,
      run.staticCard.invoices + run.smartCard.invoices,
    )
    let finished = run.staticCard->finishedCopies + run.smartCard->finishedCopies
    let percent = total > 0 ? finished * 100 / total : 0
    let caption = switch run.status {
    | SettingUp | Running => "Running"
    | Done => `Done · ${run.endReason}`
    | RunError => `Stopped · ${run.error}`
    }
    <div className="flex flex-col gap-2">
      <div className={`flex justify-between gap-3 ${body.md.semibold} text-nd_gray-600`}>
        <span> {caption->React.string} </span>
        <span className="whitespace-nowrap text-nd_gray-500">
          {`${finished->Int.toString} of ${total->Int.toString} final`->React.string}
        </span>
      </div>
      <div className="w-full h-2 rounded-full bg-nd_gray-150 overflow-hidden">
        <div
          className="h-2 rounded-full bg-nd_primary_blue-450 transition-all duration-500"
          style={width: `${percent->Int.toString}%`}
        />
      </div>
    </div>
  }
}

// One amber line in the column of a side that booked no retries, so a 0 is not read as a result
module NoRetriesBanners = {
  @react.component
  let make = (~run: portfolioRun) => {
    let showStatic = run->bookedNoRetries(~card=run.staticCard, ~other=run.smartCard)
    let showSmart = run->bookedNoRetries(~card=run.smartCard, ~other=run.staticCard)
    let banner = (~isShown, ~mode) =>
      if isShown {
        <div
          className="flex items-center gap-2 rounded-lg border border-nd_yellow-300 bg-nd_yellow-50 px-3 py-2">
          <Icon name="nd-toast-warning" size=16 className="text-nd_yellow-500 shrink-0" />
          <span className={`${body.md.semibold} text-nd_yellow-700`}>
            {"No retries booked on this side."->React.string}
          </span>
          <WhyButton why={noRetriesWhy(~mode)} />
        </div>
      } else {
        <div />
      }

    <RenderIf condition={showStatic || showSmart}>
      // Same two columns as the values in the result cards: static left, Rev Rec right
      <div className="grid grid-cols-2 gap-6 px-4">
        {banner(~isShown=showStatic, ~mode=run.staticMode)}
        {banner(~isShown=showSmart, ~mode=run.smartMode)}
      </div>
    </RenderIf>
  }
}

// The proxy's notes about a run (sleep pauses, late bank flips): one amber line that opens the list
module RunNotes = {
  @react.component
  let make = (~notes: array<string>) => {
    let (isOpen, setIsOpen) = React.useState(_ => false)
    let count = notes->Array.length
    <RenderIf condition={count > 0}>
      <div
        className="flex flex-col gap-2 rounded-lg border border-nd_yellow-300 bg-nd_yellow-50 px-3 py-2">
        <div
          className="flex items-center gap-2 cursor-pointer"
          onClick={_ => setIsOpen(prev => !prev)}>
          <Icon name="nd-toast-warning" size=16 className="text-nd_yellow-500 shrink-0" />
          <span className={`flex-1 ${body.md.semibold} text-nd_yellow-700`}>
            {`${count->Int.toString} ${count == 1 ? "note" : "notes"} on this run`->React.string}
          </span>
          <Icon
            name={isOpen ? "nd-angle-up" : "nd-angle-down"} size=14 className="text-nd_yellow-700"
          />
        </div>
        <RenderIf condition=isOpen>
          <ul
            className={`flex flex-col gap-1.5 pl-6 list-disc ${body.sm.medium} text-nd_yellow-700`}>
            {notes
            ->Array.mapWithIndex((note, index) =>
              <li key={index->Int.toString}> {note->React.string} </li>
            )
            ->React.array}
          </ul>
        </RenderIf>
      </div>
    </RenderIf>
  }
}

// Static retries vs Rev Rec, one Intelligent Routing simulator card per metric. One column, so
// each card's two values line up with the banners above.
module ResultCards = {
  @react.component
  let make = (~run: portfolioRun) => {
    let accessory = <SourceChip kind=Recomputed isFixture=run.isFixture />
    // Before the first copy is final every value is 0, so the cards wait
    let isReady = run.isFixture || run.status->isRunOver || hasFinishedCopy(run)
    let metricCard = (
      ~title,
      ~staticValue,
      ~smartValue,
      ~statType,
      ~currency="",
      ~lowerIsBetter=false,
    ) =>
      switch (staticValue, smartValue) {
      | (Some(staticValue), Some(smartValue)) if isReady =>
        <IntelligentRoutingAnalytics.Card
          title
          actualValue=staticValue
          simulatedValue=smartValue
          valueFormat=true
          statType
          currency
          baselineLabel="Static retries"
          modelLabel="Rev Rec"
          lowerIsBetter
          colorByDirection=true
          titleAccessory=accessory
        />
      // One side has no value yet (no recoveries): the same card look, with "–" on that side
      | _ =>
        let sideValue = (~label, ~value, ~valueClass) =>
          <div className="w-full flex flex-col gap-2 items-start justify-between">
            <p className="text-nd_gray-400 text-sm leading-4 font-medium">
              {label->React.string}
            </p>
            <p className={`font-semibold leading-8 text-lg text-nowrap ${valueClass}`}>
              {(
                isReady
                  ? value->Option.mapOr("–", value =>
                      value->CurrencyFormatUtils.valueFormatter(statType, ~currency)
                    )
                  : "–"
              )->React.string}
            </p>
          </div>
        <div className="flex flex-col gap-6 items-start border rounded-xl border-nd_gray-150 p-4">
          <div className="w-full flex items-center justify-between">
            <p className="text-nd_gray-500 text-md leading-4 font-medium">
              {title->React.string}
            </p>
            accessory
          </div>
          <div className="w-full flex gap-6">
            {sideValue(~label="Static retries", ~value=staticValue, ~valueClass="text-nd_gray-500")}
            {sideValue(~label="Rev Rec", ~value=smartValue, ~valueClass="text-nd_gray-700")}
          </div>
        </div>
      }
    let percent = rate => rate->Option.map(value => value *. 100.0)
    let major = minor => Some(minor->Int.toFloat /. 100.0)

    <div className="flex flex-col gap-4">
      {metricCard(
        ~title="Recovery rate",
        ~staticValue=run.staticCard.recoveryRate->percent,
        ~smartValue=run.smartCard.recoveryRate->percent,
        ~statType=Rate,
      )}
      {metricCard(
        ~title="Recovered",
        ~staticValue=run.staticCard.recoveredAmount->major,
        ~smartValue=run.smartCard.recoveredAmount->major,
        ~statType=AmountWithSuffix,
        ~currency="$",
      )}
      {metricCard(
        ~title="Attempts per recovery",
        ~staticValue=run.staticCard.attemptsPerRecovery,
        ~smartValue=run.smartCard.attemptsPerRecovery,
        ~statType=Default,
        ~lowerIsBetter=true,
      )}
      {metricCard(
        ~title="Minutes to recover",
        ~staticValue=run.staticCard.medianMinutes,
        ~smartValue=run.smartCard.medianMinutes,
        ~statType=Default,
        ~lowerIsBetter=true,
      )}
    </div>
  }
}

module Charts = {
  @react.component
  let make = (~run: portfolioRun) => {
    <div className="flex flex-col gap-6">
      <SectionCard
        title="Recovered by decline reason"
        accessory={<SourceChip kind=Recomputed isFixture=run.isFixture />}>
        <ColumnGraph
          options={run.byReason->reasonChartPayload->ColumnGraphUtils.getColumnGraphOptions}
        />
        <div className="flex flex-col divide-y divide-nd_gray-150 border-t border-nd_gray-150">
          {run.bankRules
          ->Array.map(rule =>
            <div key=rule.reason className="flex items-start justify-between gap-3 py-3">
              <div className="flex flex-col gap-0.5">
                <span className={`${body.md.semibold} text-nd_gray-700`}>
                  {`${rule.reason->reasonLabel} · first charge on ${rule.firstChargeCard}`->React.string}
                </span>
                <span className={`${body.md.medium} text-nd_gray-500`}>
                  {rule.rule->SimulatorGlossary.linkTerms}
                </span>
              </div>
              <SourceChip kind=ScriptedBank isFixture=run.isFixture />
            </div>
          )
          ->React.array}
        </div>
      </SectionCard>
      <SectionCard
        title="Recovered over the run"
        accessory={<SourceChip kind=Recomputed isFixture=run.isFixture />}>
        <LineGraph options={run.trend->trendChartPayload->LineGraphUtils.getLineGraphOptions} />
      </SectionCard>
    </div>
  }
}

module InvoiceTable = {
  @react.component
  let make = (~run: portfolioRun) => {
    let headerClass = `px-3 py-3 text-left ${body.sm.semibold} text-nd_gray-500 whitespace-nowrap`
    let cellClass = `px-3 py-3 ${body.md.medium} text-nd_gray-700 whitespace-nowrap`
    let copyCells = (copy: option<invoiceCopy>) =>
      switch copy {
      | Some(copy) =>
        let canOpen = !run.isFixture && copy.storyId->LogicUtils.isNonEmptyString
        let attemptsText = `${copy.revrecAttempts->Int.toString} ${copy.revrecAttempts == 1
            ? "attempt"
            : "attempts"}`
        // Status and Rev Rec attempts share one cell, so the table fits next to the dials
        <td className=cellClass>
          <div className="flex flex-col items-start gap-1">
            <div
              className={canOpen ? "cursor-pointer w-fit" : "w-fit"}
              title={canOpen ? "Open in the invoice story" : ""}
              onClick={_ =>
                if canOpen {
                  RescriptReactRouter.push(
                    GlobalVars.appendDashboardPath(
                      ~url=`${RevenueRecoverySidebarValues.simulatorStoryPath}/${copy.storyId}`,
                    ),
                  )
                }}>
              <Table.TableCell cell={copy.status->invoiceStatusLabel} />
            </div>
            <span className={`${body.sm.medium} text-nd_gray-500`}>
              {attemptsText->React.string}
            </span>
          </div>
        </td>
      | None => <td className=cellClass> {"–"->React.string} </td>
      }

    <SectionCard
      title="Invoices"
      subTitle={run.isFixture ? "Fixture rows." : "Click a status to open its story."}
      accessory={<SourceChip kind=FromSandbox isFixture=run.isFixture />}>
      <div className="overflow-x-auto border border-nd_gray-150 rounded-lg">
        <table className="w-full">
          <thead className="bg-nd_gray-25 border-b border-nd_gray-150">
            <tr>
              <th className=headerClass> {"#"->React.string} </th>
              <th className=headerClass> {"Decline reason"->React.string} </th>
              <th className=headerClass> {"Amount"->React.string} </th>
              <th className=headerClass> {"Bank flip"->React.string} </th>
              <th className=headerClass> {"Static retries"->React.string} </th>
              <th className=headerClass> {"Rev Rec"->React.string} </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-nd_gray-150">
            {run.invoices
            ->Array.map(invoice =>
              <tr key={invoice.index->Int.toString}>
                <td className=cellClass> {invoice.index->Int.toString->React.string} </td>
                <td className=cellClass> {invoice.reason->reasonLabel->React.string} </td>
                <td className=cellClass> {invoice.amount->formatMoney->React.string} </td>
                <td className=cellClass>
                  {invoice.flipAfterMin
                  ->Option.mapOr("never", minutes => `${minutes->Float.toString} min`)
                  ->React.string}
                </td>
                {copyCells(invoice.staticCopy)}
                {copyCells(invoice.smartCopy)}
              </tr>
            )
            ->React.array}
          </tbody>
        </table>
      </div>
    </SectionCard>
  }
}

@react.component
let make = (~runIdFromUrl: option<string>) => {
  open LogicUtils
  let simFetch = SimulatorApi.useSimFetch()
  let showToast = ToastAdapter.useShowToast()
  let mixpanelEvent = MixpanelHook.useSendEvent()

  let (dials, setDials) = React.useState(_ => defaultDials)
  let (run, setRun) = React.useState(_ => None)
  let (isBusy, setIsBusy) = React.useState(_ => false)
  let (pollError, setPollError) = React.useState(_ => "")
  // The run whose dials the form shows, so a reopened run fills the form once
  let dialsRunId = React.useRef("")

  let isOver = run->Option.mapOr(false, (r: portfolioRun) => r.status->isRunOver || r.isFixture)
  let isRunning = run->Option.isSome && !isOver
  let (limits, setLimits) = React.useState(_ => defaultLimits)

  // The proxy's limits: how many invoices, and the stop-after choices
  React.useEffect(() => {
    let read = async () => {
      try {
        let proxyLimits = (await simFetch(~path="/healthz", ~method_=Get))->limitsMapper
        setLimits(_ => proxyLimits)

        // A fresh form picks the middle choice when its default is not offered
        if dialsRunId.current->isEmptyString {
          setDials(prev =>
            proxyLimits.stopAfterMinutes->Array.includes(prev.maxMinutes)
              ? prev
              : {
                  ...prev,
                  maxMinutes: proxyLimits.stopAfterMinutes
                  ->Array.get(proxyLimits.stopAfterMinutes->Array.length / 2)
                  ->Option.getOr(prev.maxMinutes),
                }
          )
        }
      } catch {
      | _ => ()
      }
    }
    read()->ignore
    None
  }, [])

  // Poll a real run every 2 s while it is active; no polling once it has ended
  React.useEffect(() => {
    switch runIdFromUrl {
    | Some(id) if !isOver => {
        let cancelled = ref(false)
        let poll = async () => {
          try {
            let json = await simFetch(~path=`/sim/portfolio/${id}`, ~method_=Get)
            if !cancelled.contents {
              let polledRun = json->runMapper(~isFixture=false)
              if dialsRunId.current != id {
                dialsRunId.current = id
                setDials(_ => polledRun.dials)
              }
              setRun(_ => Some(polledRun))
              setPollError(_ => "")
            }
          } catch {
          | exn =>
            if !cancelled.contents {
              setPollError(_ =>
                exn->SimulatorUtils.getSimErrorMessage(
                  ~default="The simulator proxy did not answer.",
                )
              )
            }
          }
        }
        poll()->ignore
        let intervalId = setInterval(() => poll()->ignore, activePollIntervalMs)
        Some(
          () => {
            cancelled := true
            clearInterval(intervalId)
          },
        )
      }
    | _ => None
    }
  }, (runIdFromUrl, isOver))

  let onRun = async () => {
    setIsBusy(_ => true)
    mixpanelEvent(~eventName="recovery_simulator_portfolio_run")
    try {
      let json = await simFetch(~path="/sim/portfolio/start", ~method_=Post, ~body=dials->startBody)
      let newRun = json->runMapper(~isFixture=false)
      dialsRunId.current = newRun.runId
      setRun(_ => Some(newRun))
      RescriptReactRouter.replace(
        GlobalVars.appendDashboardPath(~url=`${portfolioPath}/${newRun.runId}`),
      )
    } catch {
    | exn => {
        let message = exn->SimulatorUtils.getSimErrorMessage(~default="The run could not start.")

        showToast(~message, ~toastType=ToastError)
      }
    }
    setIsBusy(_ => false)
  }

  let onStop = async () => {
    switch runIdFromUrl {
    | Some(id) =>
      try {
        let json = await simFetch(~path=`/sim/portfolio/${id}/stop`, ~method_=Post)
        setRun(_ => Some(json->runMapper(~isFixture=false)))
      } catch {
      | exn =>
        showToast(
          ~message=exn->SimulatorUtils.getSimErrorMessage(~default="The run could not stop."),
          ~toastType=ToastError,
        )
      }
    | None => ()
    }
  }

  <div className="flex flex-col gap-6">
    <BreadCrumbNavigation
      path=[{title: "Home", link: RevenueRecoverySidebarValues.homePath}]
      currentPageTitle="Portfolio Run"
    />
    <div className="flex items-start justify-between gap-4">
      <PageUtils.PageHeading
        title="Portfolio run" subTitle="Same invoices, two strategies, real Hyperswitch engine."
      />
      <SimulatorGlossary.OpenButton />
    </div>
    <div className="flex flex-col xl:flex-row gap-10 items-start">
      <div className="w-full xl:w-1/3 shrink-0 xl:sticky xl:top-6">
        <DialsForm
          dials
          setDials
          limits
          isBusy
          isRunning
          onRun={() => onRun()->ignore}
          onStop={() => onStop()->ignore}
        />
      </div>
      <div className="w-full min-w-0 flex flex-col gap-6">
        {switch run {
        | Some(run) =>
          <>
            <RenderIf condition=run.isFixture>
              <AlertV2Binding
                alertType=Warning
                slot={{
                  slot: <Icon name="nd-toast-warning" size=20 className="text-nd_yellow-500" />,
                }}
                heading="Fixture data, not a run on the demo engine"
                description="Made-up numbers in the real result shape."
              />
            </RenderIf>
            <RenderIf condition={pollError->isNonEmptyString}>
              <AlertV2Binding
                alertType=Warning
                slot={{
                  slot: <Icon name="nd-toast-warning" size=20 className="text-nd_yellow-500" />,
                }}
                description=pollError
              />
            </RenderIf>
            <RunNotes notes={run.warnings->Array.filter(isNonEmptyString)} />
            {switch run.status {
            | SettingUp => <SetupBoard run />
            | _ =>
              <>
                <RunStatus run />
                // The proxy's comparison label, next to the numbers: the noise note when both
                // sides share a strategy, otherwise which strategies are compared
                <RenderIf condition={run.comparisonLabel->isNonEmptyString}>
                  <p className={`${body.md.semibold} text-nd_gray-600`}>
                    {run
                    ->comparisonText
                    ->React.string}
                  </p>
                </RenderIf>
                <NoRetriesBanners run />
                <ResultCards run />
                <div
                  className={`flex flex-wrap gap-x-6 gap-y-2 ${body.md.medium} text-nd_gray-500`}>
                  <span className="flex items-center gap-2">
                    {`Static side: ${run.staticMode->SimulatorTourUtils.retryModeText}`->React.string}
                    <SourceChip kind=FromSandbox isFixture=run.isFixture />
                  </span>
                  <span className="flex items-center gap-2">
                    {`Rev Rec side: ${run.smartMode->SimulatorTourUtils.retryModeText}`->React.string}
                    <SourceChip kind=FromSandbox isFixture=run.isFixture />
                  </span>
                </div>
                <RenderIf
                  condition={run.isFixture || run.status->isRunOver || hasFinishedCopy(run)}>
                  <Charts run />
                </RenderIf>
                <InvoiceTable run />
              </>
            }}
          </>
        | None =>
          <div className={`${cardStyle} px-6 py-10`}>
            <p className={`${body.md.medium} text-nd_gray-500 text-center`}>
              {(
                runIdFromUrl->Option.isSome
                  ? "Loading the run."
                  : "Press Run to compare the two strategies."
              )->React.string}
            </p>
          </div>
        }}
      </div>
    </div>
  </div>
}
