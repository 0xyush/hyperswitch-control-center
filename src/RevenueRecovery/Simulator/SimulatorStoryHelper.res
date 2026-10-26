open SimulatorTypes
open SimulatorUtils
open Typography

let cardStyle = "bg-white border border-nd_gray-200 rounded-xl"

let toPercent = value => `${value->Float.toString}%`

// Line and arrow-head colours for a diagram row
let stepColor = status =>
  switch status {
  | StepOk => ("border-nd_green-400", "text-nd_green-400")
  | StepDeclined | StepFailed => ("border-nd_red-400", "text-nd_red-400")
  | StepPending => ("border-nd_primary_blue-450 border-dashed", "text-nd_primary_blue-450")
  | StepInfo => ("border-nd_gray-400", "text-nd_gray-400")
  }

// A form input outside react-final-form, fed from React state
let makeInput = (
  ~name,
  ~value,
  ~onChange,
  ~onBlur=() => (),
): ReactFinalForm.fieldRenderPropsInput => {
  name,
  onBlur: _ => onBlur(),
  onFocus: _ => (),
  // Selects send the new value as a string; text inputs send a change event
  onChange: event =>
    onChange(
      Js.typeof(event) == "string"
        ? event->Identity.formReactEventToString
        : ReactEvent.Form.target(event)["value"],
    ),
  value: value->JSON.Encode.string,
  checked: false,
}

module FormField = {
  @react.component
  let make = (~label, ~children) => {
    <div className="flex flex-col gap-1">
      <label className={`${body.md.semibold} text-nd_gray-700`}> {label->React.string} </label>
      children
    </div>
  }
}

module SelectField = {
  @react.component
  let make = (~label, ~name, ~options, ~value, ~onChange, ~isDisabled=false) => {
    <FormField label>
      {InputFields.selectInput(
        ~options,
        ~buttonText=`Select ${label->String.toLowerCase}`,
        ~deselectDisable=true,
        ~disableSelect=isDisabled,
        ~fullLength=true,
        ~textStyle="!font-normal",
      )(~input=makeInput(~name, ~value, ~onChange), ~placeholder="")}
    </FormField>
  }
}

// Kebab menu with less common actions (the billing form's, the story panel's)
module ActionMenu = {
  open HeadlessUI
  @react.component
  let make = (~options: array<(string, unit => unit)>) => {
    <Popover \"as"="div" className="relative inline-block text-left">
      {_ => <>
        <Popover.Button> {_ => <Icon name="menu-option" size=28 />} </Popover.Button>
        <Popover.Panel className="absolute z-20 right-0 top-8">
          {panelProps =>
            <div
              className="relative flex flex-col bg-white py-1 overflow-hidden rounded ring-1 ring-black ring-opacity-5 w-52">
              {options
              ->Array.map(((text, onClick)) =>
                <Navbar.MenuOption
                  key=text
                  text
                  onClick={_ => {
                    panelProps["close"]()
                    onClick()
                  }}
                />
              )
              ->React.array}
            </div>}
        </Popover.Panel>
      </>}
    </Popover>
  }
}

// The scenario tiles (UX-PASS-2 A1): preset id, a three-word title, an icon, one sentence on hover
let scenarioTiles = [
  (
    2,
    "Temporary error",
    "nd-hour-glass-outline",
    "The first charge fails. One Rev Rec retry collects the money.",
  ),
  (1, "Pays in app", "nd-wallet", "Rev Rec starts retrying. Then the customer pays in the app."),
  (
    6,
    "Insufficient funds",
    "nd-piggy-bank",
    "No money now. A later failure brings a card that works.",
  ),
  (7, "Stolen card", "nd-shield", "Declined as stolen. Rev Rec should stop at once."),
]

// The two cards a customer can have on file: last four digits, name, works or not
let savedCardTiles = [("4242", "Good card", true), ("0341", "Declining card", false)]

// Left panel: the form plays the merchant's billing system, like the checkout form plays the checkout
module BillingSystemForm = {
  @react.component
  let make = (
    ~options: formOptions,
    ~form: billingForm,
    ~setForm,
    ~isBusy,
    // True from the moment Charge customer is pressed until the story leaves "starting"
    ~isLocked,
    ~story: option<story>,
    ~onCharge,
    ~onCancel,
    ~onStartOver,
  ) => {
    let (showAdvanced, setShowAdvanced) = React.useState(_ => false)
    let presetById = id => options.presets->Array.find(preset => preset.id == id)
    // A scenario without a tile (from a tour link, or a portfolio copy) shows under Advanced
    let isTileScenario = scenarioTiles->Array.some(((id, _, _, _)) => id == form.preset)
    let actions =
      story->Option.mapOr({paidInApp: false, reportAgain: false, cancel: false}, s => s.actions)
    let menuOptions =
      [
        actions.cancel ? Some(("Cancel invoice", onCancel)) : None,
        story->Option.isSome ? Some(("Start over", onStartOver)) : None,
      ]->Array.filterMap(option => option)

    <div className={`${cardStyle} p-6 flex flex-col gap-5`}>
      <div className="flex items-start justify-between gap-4">
        <div className="flex flex-col gap-1">
          <p className={`${heading.sm.semibold} text-nd_gray-800`}>
            {"Billing system"->React.string}
          </p>
          <p className={`${body.sm.medium} text-nd_gray-500`}>
            {"You are the merchant's billing system."->React.string}
          </p>
        </div>
        <RenderIf condition={menuOptions->Array.length > 0}>
          <ActionMenu options=menuOptions />
        </RenderIf>
      </div>
      <FormField label="Scenario">
        <div className="grid grid-cols-2 sm:grid-cols-4 xl:grid-cols-2 gap-2">
          {scenarioTiles
          ->Array.map(((id, title, icon, hint)) => {
            let preset = presetById(id)
            let isRunnable = preset->Option.mapOr(false, preset => preset.verified)
            let isSelected = form.preset == id
            <SimulatorFormTiles.Tile
              key={id->Int.toString}
              title
              icon
              hint
              isSelected
              tag={isRunnable ? "" : "Not ready"}
              isDisabled={isLocked || preset->Option.isNone || (!isRunnable && !isSelected)}
              onClick={() => preset->Option.forEach(preset => setForm(_ => preset.fields))}
            />
          })
          ->React.array}
        </div>
      </FormField>
      <FormField label="Amount">
        <SimulatorFormTiles.AmountField
          amount=form.amount
          setAmount={amount => setForm(prev => {...prev, amount})}
          currency=form.currency
          setCurrency={currency => setForm(prev => {...prev, currency})}
          currencies={options.currencies->Array.map(option => option.value)}
          isDisabled=isLocked
        />
      </FormField>
      <FormField label="Saved card">
        <div className="grid grid-cols-2 gap-2">
          {savedCardTiles
          ->Array.map(((last4, name, isGood)) =>
            <SimulatorFormTiles.CardTile
              key=last4
              last4
              name
              isGood
              isSelected={form.savedCard == last4}
              isDisabled=isLocked
              onClick={() => setForm(prev => {...prev, savedCard: last4})}
            />
          )
          ->React.array}
        </div>
      </FormField>
      <FormField label="Customer">
        <div>
          <SimulatorFormTiles.ToggleChip
            options=customerOptions
            value=form.customer
            onChange={customer => setForm(prev => {...prev, customer})}
            isDisabled=isLocked
          />
        </div>
      </FormField>
      <div className="flex flex-col gap-4">
        <span
          className={`w-fit flex items-center gap-1 cursor-pointer text-nd_gray-500 hover:text-nd_gray-700 ${body.sm.semibold}`}
          onClick={_ => setShowAdvanced(prev => !prev)}>
          {"Advanced"->React.string}
          <Icon name={showAdvanced || !isTileScenario ? "nd-angle-up" : "nd-angle-down"} size=12 />
        </span>
        <RenderIf condition={showAdvanced || !isTileScenario}>
          <SelectField
            label="Other scenarios"
            name="preset"
            isDisabled=isLocked
            options={form.preset == 0
              ? [noPresetOption]->Array.concat(options.presets->presetOptions)
              : options.presets->presetOptions}
            value={form.preset->Int.toString}
            onChange={value =>
              options.presets
              ->Array.find(preset => preset.id->Int.toString == value)
              ->Option.forEach(preset => setForm(_ => preset.fields))}
          />
          <SelectField
            label="First charge"
            name="firstCharge"
            isDisabled=isLocked
            // The first charge is the billing system's own; 4242 would never fail
            options={options.cards->Array.filter(card => card.value != "4242")}
            value=form.firstCharge
            onChange={firstCharge => setForm(prev => {...prev, firstCharge})}
          />
        </RenderIf>
      </div>
      <Button
        text="Charge customer"
        loadingText="Charging…"
        buttonType=Primary
        buttonSize=Medium
        customButtonStyle="!w-full"
        buttonState={isBusy || isLocked ? Loading : Normal}
        onClick={_ => onCharge()}
      />
    </div>
  }
}

module ArrowHead = {
  @react.component
  let make = (~pointsRight, ~colorClass) => {
    <svg width="8" height="8" viewBox="0 0 8 8" className=colorClass>
      <path d={pointsRight ? "M0 0 L8 4 L0 8 z" : "M8 0 L0 4 L8 8 z"} fill="currentColor" />
    </svg>
  }
}

module Countdown = {
  @react.component
  let make = (~nextRetryAt) => {
    let (nowMs, setNowMs) = React.useState(_ => Date.now())
    React.useEffect(() => {
      let intervalId = setInterval(() => setNowMs(_ => Date.now()), 1000)
      Some(() => clearInterval(intervalId))
    }, [])
    countdownText(~nextRetryAt, ~nowMs)->React.string
  }
}

// One message: label above a thin arrow between two lifelines, time in the right column
module DiagramRow = {
  @react.component
  let make = (~row: diagramRow, ~time: React.element, ~onClick) => {
    let isPending = row.status == StepPending
    let (lineClass, headClass) = row.status->stepColor
    let fromX = row.from->lifelinePercent
    let toX = row.to->lifelinePercent
    let left = Math.min(fromX, toX)
    let width = Math.abs(toX -. fromX)
    let pointsRight = toX > fromX
    let labelCenter = left +. width /. 2.0
    // A centred label may grow until it reaches the nearer edge of the diagram
    let labelMaxWidth = 2.0 *. Math.min(labelCenter, 100.0 -. labelCenter)
    let labelClass = `absolute whitespace-nowrap truncate px-1 ${body.sm.medium} ${isPending
        ? "text-nd_primary_blue-450"
        : "text-nd_gray-700"}`

    <div
      className="flex items-stretch rounded-md hover:bg-nd_gray-25 cursor-pointer"
      onClick={_ => onClick()}>
      <div className="relative flex-1 h-12">
        {lifelines
        ->Array.map(actor =>
          <div
            key={actor->actorLabel->fst}
            className="absolute top-0 bottom-0 border-l border-dashed border-nd_gray-200"
            style={left: actor->lifelinePercent->toPercent}
          />
        )
        ->React.array}
        {if row.from == row.to {
          // A step inside one system, drawn as a small loop on its lifeline
          <>
            <div
              className={`absolute h-3 w-6 border border-l-0 rounded-r ${lineClass}`}
              style={left: fromX->toPercent, top: "26px"}
            />
            <div
              className=labelClass
              style={
                left: `calc(${fromX->toPercent} + 32px)`,
                top: "6px",
                maxWidth: (100.0 -. fromX -. 5.0)->toPercent,
              }>
              {row.label->React.string}
            </div>
          </>
        } else {
          <>
            <div
              className={`${labelClass} -translate-x-1/2`}
              style={left: labelCenter->toPercent, top: "6px", maxWidth: labelMaxWidth->toPercent}>
              {row.label->React.string}
            </div>
            <div
              className={`absolute border-t ${lineClass}`}
              style={left: left->toPercent, width: width->toPercent, top: "32px"}
            />
            <div
              className="absolute flex"
              style={
                left: pointsRight ? `calc(${toX->toPercent} - 8px)` : toX->toPercent,
                top: "28px",
              }>
              <ArrowHead pointsRight colorClass=headClass />
            </div>
          </>
        }}
      </div>
      <div
        className={`w-32 shrink-0 flex items-end justify-end pb-2 ${body.sm.regular} text-nd_gray-500`}>
        time
      </div>
    </div>
  }
}

// Seconds or minutes since a step, ticking
module Elapsed = {
  @react.component
  let make = (~since) => {
    let (nowMs, setNowMs) = React.useState(_ => Date.now())
    React.useEffect(() => {
      let intervalId = setInterval(() => setNowMs(_ => Date.now()), 1000)
      Some(() => clearInterval(intervalId))
    }, [])
    elapsedText(~since, ~nowMs)->React.string
  }
}

// The lifeline view, behind "Show sequence diagram": the same visible steps, drawn as arrows
module LifelineDiagram = {
  @react.component
  let make = (~rows: array<diagramRow>, ~onRowClick) => {
    <div className="flex flex-col gap-3 border-t border-nd_gray-150 pt-4">
      <div className="flex border-b border-nd_gray-200 pb-3 pt-2">
        <div className="relative flex-1 h-10">
          {lifelines
          ->Array.map(actor => {
            let (name, note) = actor->actorLabel
            <div
              key=name
              className="absolute -translate-x-1/2 flex flex-col items-center"
              style={left: actor->lifelinePercent->toPercent}>
              <span className={`${body.md.semibold} text-nd_gray-800 whitespace-nowrap`}>
                {name->React.string}
              </span>
              <span className={`${body.sm.regular} text-nd_gray-400 whitespace-nowrap`}>
                {note->React.string}
              </span>
            </div>
          })
          ->React.array}
        </div>
        <div
          className={`w-32 shrink-0 flex items-end justify-end ${body.sm.medium} text-nd_gray-400`}>
          {"Time"->React.string}
        </div>
      </div>
      <div className="flex flex-col">
        {rows
        ->Array.mapWithIndex((row, index) =>
          <DiagramRow
            key={index->Int.toString}
            row
            time={row.status == StepPending
              ? <Countdown nextRetryAt=row.at />
              : row.at->toClockTime->React.string}
            onClick={() => onRowClick(row)}
          />
        )
        ->React.array}
      </div>
    </div>
  }
}

// Fade + slide in, 250 ms, with the dashboard's ease-in-out curve. Delays only stagger steps
// that arrived together; a step never moves after it has landed.
let revealCss = "@keyframes simStepIn { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: none; } } .sim-step-reveal { animation: simStepIn 250ms cubic-bezier(0.4, 0, 0.2, 1) both; } @media (prefers-reduced-motion: reduce) { .sim-step-reveal { animation: none; } }"

let revealStaggerMs = 400

// Which cards fade in, and after what delay. When a story is opened (or refreshed), the cards
// known at that moment show at once; only cards added later animate.
let useRevealDelays = (~storyKey: string, ~itemCount: int, ~initialCount: int) => {
  let tracked = React.useRef((storyKey, initialCount, Dict.make()))
  let (trackedKey, _, _) = tracked.current
  if trackedKey != storyKey {
    tracked.current = (storyKey, initialCount, Dict.make())
  }
  let (key, shown, delays) = tracked.current
  if itemCount > shown {
    for index in shown to itemCount - 1 {
      delays->Dict.set(index->Int.toString, (index - shown) * revealStaggerMs)
    }
    tracked.current = (key, itemCount, delays)
  }
  delays
}

let stepDomId = index => `sim-step-${index->Int.toString}`
let doneDomId = "sim-step-done"

@val @scope("document")
external getElementById: string => Nullable.t<Dom.element> = "getElementById"

let scrollToElement = id =>
  getElementById(id)
  ->Nullable.toOption
  ->Option.forEach(element =>
    element->Webapi.Dom.Element.scrollIntoViewWithOptions({"behavior": "smooth", "block": "center"})
  )

let revealProps = (delay: option<int>) => (
  delay->Option.isSome ? "sim-step-reveal" : "",
  delay->Option.map(ms => `${ms->Int.toString}ms`),
)

let badgeClass = status =>
  switch status {
  | StepOk => "bg-nd_green-50 text-nd_green-600 border border-nd_green-200"
  | StepDeclined | StepFailed => "bg-nd_red-50 text-nd_red-600 border border-nd_red-200"
  | StepPending => "bg-white text-nd_primary_blue-450 border border-dashed border-nd_primary_blue-450"
  | StepInfo => "bg-nd_gray-50 text-nd_gray-600 border border-nd_gray-200"
  }

// The "?" button that opens why something happened (it replaces the "Why" text links)
module HelpButton = {
  @react.component
  let make = (~onClick, ~label="Why") => {
    <button
      type_="button"
      ariaLabel=label
      title=label
      className={`shrink-0 w-5 h-5 rounded-full border border-nd_gray-300 text-nd_gray-500 hover:border-nd_primary_blue-450 hover:text-nd_primary_blue-450 flex items-center justify-center ${body.xs.semibold}`}
      onClick={event => {
        event->ReactEvent.Mouse.stopPropagation
        onClick()
      }}>
      {"?"->React.string}
    </button>
  }
}

// One step card: number, title, who to whom, time, a "?" button. Status sets the badge colour.
module StepCard = {
  @react.component
  let make = (
    ~row: diagramRow,
    ~stepNumber: int,
    ~domId=?,
    ~time: React.element,
    ~isNewest: bool,
    ~revealDelay: option<int>,
    ~onOpen,
    ~children=React.null,
  ) => {
    let isPending = row.status == StepPending
    let (fromName, _) = row.from->actorLabel
    let (toName, _) = row.to->actorLabel
    let who = row.from == row.to ? fromName : `${fromName} → ${toName}`
    let (revealClass, animationDelay) = revealDelay->revealProps
    <div
      id={domId->Option.getOr(stepDomId(stepNumber - 1))}
      className={`relative overflow-hidden rounded-lg border bg-white px-4 py-3 flex gap-3 cursor-pointer hover:bg-nd_gray-25 ${isPending
          ? "border-dashed border-nd_primary_blue-450"
          : "border-nd_gray-150"} ${revealClass}`}
      style={animationDelay: ?animationDelay}
      onClick={_ => onOpen()}>
      // The newest step carries a primary-blue edge until the next one lands
      <RenderIf condition=isNewest>
        <div className="absolute left-0 top-0 bottom-0 w-1 bg-nd_primary_blue-450" />
      </RenderIf>
      <div
        className={`shrink-0 w-7 h-7 rounded-full flex items-center justify-center ${body.sm.semibold} ${row.status->badgeClass}`}>
        {stepNumber->Int.toString->React.string}
      </div>
      <div className="flex-1 min-w-0 flex flex-col gap-1">
        <div className="flex items-start justify-between gap-3">
          <p className={`${body.md.semibold} text-nd_gray-800`} style={overflowWrap: "anywhere"}>
            {row.label->React.string}
          </p>
          <span className={`${body.sm.regular} text-nd_gray-500 whitespace-nowrap`}> time </span>
        </div>
        <div className={`flex items-center gap-2 ${body.sm.medium} text-nd_gray-500`}>
          <span> {who->React.string} </span>
          <HelpButton onClick=onOpen />
        </div>
        children
      </div>
    </div>
  }
}

// The proxy's note when Rev Rec has not booked a retry long after it should have (sandbox
// scheduler). It replaces the countdown; "?" opens the drawer.
module WaitingNoteLine = {
  @react.component
  let make = (~waiting: waitingNote, ~onWhy) => {
    <div
      className={`w-fit flex flex-wrap items-center gap-x-2 gap-y-1 px-3 py-2 rounded-lg border bg-nd_orange-50 border-nd_orange-200 text-nd_orange-600 ${body.md.semibold}`}>
      <Icon name="nd-toast-warning" size=16 />
      <span> {waiting.text->React.string} </span>
      <span className={`${body.md.medium} opacity-80`}>
        {`· ${waiting.minutes->Int.toString} min`->React.string}
      </span>
      <HelpButton onClick=onWhy />
    </div>
  }
}

// The pause control on the last step: "Next" reveals one more step; when that step has not
// arrived yet it waits, with the countdown to the booked retry, and shows it when it lands
module NextControls = {
  @react.component
  let make = (
    ~showNext,
    ~nextLabel,
    ~isWaiting,
    ~nextRetryAt: option<string>,
    ~waiting: option<waitingNote>,
    ~onWaitingWhy,
    ~onNext,
    ~inlineActions: array<(string, unit => unit)>,
    ~isBusy,
  ) => {
    <RenderIf condition={showNext || inlineActions->Array.length > 0}>
      // Clicks here must not open the step's drawer
      <div
        className="flex flex-wrap items-center gap-3 pt-3"
        onClick={event => event->ReactEvent.Mouse.stopPropagation}>
        <RenderIf condition=showNext>
          {switch (isWaiting, waiting) {
          | (true, Some(waiting)) => <WaitingNoteLine waiting onWhy=onWaitingWhy />
          | (true, None) =>
            <div
              className={`flex items-center gap-2 px-3 py-2 rounded-lg bg-nd_primary_blue-50 text-nd_primary_blue-450 ${body.md.semibold}`}>
              <Loadericon size=14 iconColor="text-nd_primary_blue-450" />
              <span> {"Waiting for Rev Rec…"->React.string} </span>
              {switch nextRetryAt {
              | Some(time) =>
                <span>
                  {"("->React.string}
                  <Countdown nextRetryAt=time />
                  {")"->React.string}
                </span>
              | None => React.null
              }}
            </div>
          | (false, _) =>
            <Button text=nextLabel buttonType=Primary buttonSize=Medium onClick={_ => onNext()} />
          }}
        </RenderIf>
        {inlineActions
        ->Array.map(((text, onClick)) =>
          <Button
            key=text
            text
            buttonType=Secondary
            buttonSize=Small
            buttonState={isBusy ? Disabled : Normal}
            onClick={_ => onClick()}
          />
        )
        ->React.array}
      </div>
    </RenderIf>
  }
}

// Below the diagram: the real invoice detail page, fed by the story's raw sandbox JSON
module InvoicePanel = {
  @react.component
  let make = (~story: story, ~onAttemptClick) => {
    let getURL = APIUtils.useGetURL()
    let fetchDetails = APIUtils.useGetMethod(~showErrorToast=false)
    let (startRetryThreshold, setStartRetryThreshold) = React.useState(_ => 0)

    let order = story.invoice->RevenueRecoveryEntity.itemToObjMapperForIntents
    let order = {...order, status: story.stage->toInvoiceStatus(~default=order.status)}
    let attemptsList =
      story.attempts
      ->RevenueRecoveryEntity.getAttempts
      ->Array.filter(item => item.status !== "started")
    // Newest first, like the invoice page
    attemptsList->Array.reverse
    let detailsFields: array<RevenueRecoveryOrderTypes.colType> = [
      Id,
      Created,
      OrderAmount,
      Status,
      Connector,
    ]

    // The start rule decides when the attempts table shows Rev Rec's section, as on the invoice page
    let fetchStartRetryThreshold = async billingConnectorId => {
      try {
        let url = getURL(
          ~entityName=V2(V2_CONNECTOR),
          ~methodType=Get,
          ~id=Some(billingConnectorId),
        )
        let json = await fetchDetails(url, ~version=V2)
        let threshold =
          json
          ->LogicUtils.getDictFromJsonObject
          ->LogicUtils.getDictfromDict("feature_metadata")
          ->LogicUtils.getDictfromDict("revenue_recovery")
          ->LogicUtils.getInt("billing_connector_retry_threshold", 0)
        setStartRetryThreshold(_ => threshold)
      } catch {
      | _ => ()
      }
    }

    React.useEffect(() => {
      if order.billing_connector_id->LogicUtils.isNonEmptyString {
        fetchStartRetryThreshold(order.billing_connector_id)->ignore
      }
      None
    }, [order.billing_connector_id])

    <div className="flex flex-col gap-6">
      <div className="flex flex-col gap-1">
        <p className={`${heading.md.semibold} text-nd_gray-900`}>
          {"Invoice Recovery Details"->React.string}
        </p>
        <p className={`${body.md.medium} text-nd_gray-500`}>
          {`The same page as Invoices › ${story.recoveryId}, updated live.`->React.string}
        </p>
      </div>
      // The invoice page puts the details card in a side column. This panel is narrower,
      // so the same components stack; -ml-6 cancels the card's built-in left margin.
      <div className="w-full flex flex-col gap-7">
        <ShowRevenueRecovery.RecoveryAmountStatus order processTracker=story.processTracker />
        <div className="-ml-6">
          <ShowRevenueRecovery.OrderDetailsCard
            order
            getHeading=RevenueRecoveryEntity.getHeading
            getCell=RevenueRecoveryEntity.getCell
            detailsFields
          />
        </div>
        <RecoveryInvoicesHelper.AttemptsHistory
          order
          attemptsList
          processTracker={story.processTracker->Some}
          startRetryThreshold
          onAttemptClick
        />
      </div>
    </div>
  }
}

module ExplainLines = {
  @react.component
  let make = (~lines: array<explainLine>) => {
    <div className="flex flex-col gap-3">
      {lines
      ->Array.mapWithIndex((line, index) => {
        let (label, labelClass) = line.source->sourceLabel
        <div key={index->Int.toString} className="flex flex-col gap-1">
          <span className={`w-fit rounded px-1.5 py-0.5 border ${body.xs.semibold} ${labelClass}`}>
            {label->React.string}
          </span>
          <p className={`${body.md.medium} text-nd_gray-600`} style={overflowWrap: "anywhere"}>
            {line.text->SimulatorGlossary.linkTerms}
          </p>
        </div>
      })
      ->React.array}
    </div>
  }
}

// Explanation on click only: what happened, who did it, why, and the raw call
module ExplainDrawer = {
  @react.component
  let make = (~content: option<drawerContent>, ~story: option<story>, ~onClose) => {
    let sectionTitle = text =>
      <p className={`${body.sm.semibold} text-nd_gray-400 uppercase`}> {text->React.string} </p>
    let history = story->Option.mapOr([], s => s.stageHistory)

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
        let (fromName, _) = row.from->actorLabel
        let (toName, _) = row.to->actorLabel
        let requests = story->Option.mapOr([], s => s.requests->requestsForRow(row))
        let storyLines = story->Option.mapOr([], s => s.explain)
        <div className="h-full relative">
          <div className="absolute inset-0 overflow-y-auto px-4 pb-20 flex flex-col gap-7">
            <div className="flex flex-col gap-2">
              <p
                className={`${body.lg.semibold} text-nd_gray-800`} style={overflowWrap: "anywhere"}>
                {row.label->React.string}
              </p>
              <RenderIf condition={row.text->LogicUtils.isNonEmptyString}>
                <p className={`${body.md.medium} text-nd_gray-600`}> {row.text->React.string} </p>
              </RenderIf>
              <div
                className={`flex flex-wrap items-center gap-2 ${body.md.medium} text-nd_gray-500`}>
                <span> {`${fromName} → ${toName}`->React.string} </span>
                <span className="text-nd_gray-300"> {"•"->React.string} </span>
                <Table.DateCell
                  textStyle={`${body.md.medium} text-nd_gray-500`}
                  timestamp={row.at->toUtcIso}
                  isCard=true
                />
              </div>
              {switch history->stageAt(row.at) {
              | Some(visit) =>
                <p className={`${body.md.medium} text-nd_gray-500`}>
                  {`Invoice state then: ${visit.stage->stageName}, first seen at ${visit.firstSeenAt->toClockTime}`->React.string}
                </p>
              | None => React.null
              }}
            </div>
            <div className="flex flex-col gap-3">
              {sectionTitle("Why")}
              {if row.why->Array.length > 0 {
                <ExplainLines lines=row.why />
              } else {
                <>
                  <p className={`${body.sm.medium} text-nd_gray-400`}>
                    {"The proxy has not split the reasons by step yet. These lines explain the whole story."->React.string}
                  </p>
                  <ExplainLines lines=storyLines />
                </>
              }}
            </div>
            <div className="flex flex-col gap-3">
              {sectionTitle("Request and response")}
              {if requests->Array.length == 0 {
                <p className={`${body.md.medium} text-nd_gray-500`}>
                  {"No raw call is linked to this step."->React.string}
                </p>
              } else {
                requests
                ->Array.mapWithIndex((log, index) =>
                  <div key={index->Int.toString} className="flex flex-col gap-2">
                    <p className={`${body.md.semibold} text-nd_gray-700`}>
                      {log.step->React.string}
                    </p>
                    <p
                      className={`font-mono ${body.sm.medium} text-nd_gray-500`}
                      style={overflowWrap: "anywhere"}>
                      {`${log.method} ${log.url} → ${log.status->Int.toString}`->React.string}
                    </p>
                    <PrettyPrintJson
                      jsonToDisplay={log.request->JSON.stringify}
                      headerText=Some("Request")
                      wrapLongLines=true
                    />
                    <PrettyPrintJson
                      jsonToDisplay={log.response->JSON.stringify}
                      headerText=Some("Response")
                      wrapLongLines=true
                    />
                  </div>
                )
                ->React.array
              }}
            </div>
          </div>
        </div>
      | Some(WaitingDetails) =>
        <div className="h-full relative">
          <div className="absolute inset-0 overflow-y-auto px-4 pb-20 flex flex-col gap-7">
            {switch story->Option.flatMap(s => s.waiting) {
            | Some(waiting) =>
              <>
                <div className="flex flex-col gap-2">
                  <p className={`${body.lg.semibold} text-nd_gray-800`}>
                    {waiting.text->React.string}
                  </p>
                  <p className={`${body.md.medium} text-nd_gray-500`}>
                    {`No retry booked for ${waiting.minutes->Int.toString} min. The invoice stays in Monitoring.`->React.string}
                  </p>
                </div>
                <div className="flex flex-col gap-3">
                  {sectionTitle("Why")}
                  <ExplainLines lines=[{text: waiting.why, source: waiting.source}] />
                </div>
              </>
            // The note goes away once Rev Rec books a retry
            | None =>
              <p className={`${body.md.medium} text-nd_gray-600`}>
                {"Rev Rec is not waiting any more. The steps show what it did."->React.string}
              </p>
            }}
          </div>
        </div>
      | Some(StateHistory) =>
        <div className="h-full relative">
          <div className="absolute inset-0 overflow-y-auto px-4 pb-20 flex flex-col gap-4">
            <p className={`${body.md.medium} text-nd_gray-500`}>
              {"When the invoice was first seen in each state. Sandbox times are exact; times seen by the proxy can be up to one poll late."->React.string}
            </p>
            <SimulatorTable
              headers=["State", "First seen", "Source"]
              rows={history->Array.map(visit => {
                let (sourceText, sourceClass) = visit->stageVisitSource
                [
                  visit.stage->stageName->React.string,
                  visit.firstSeenAt->toClockTime->React.string,
                  <span
                    className={`w-fit rounded px-1.5 py-0.5 border whitespace-nowrap ${body.xs.semibold} ${sourceClass}`}>
                    {sourceText->React.string}
                  </span>,
                ]
              })}
              emptyText="The proxy has not reported any states yet."
            />
          </div>
        </div>
      | None => React.null
      }}
    </Modal>
  }
}
