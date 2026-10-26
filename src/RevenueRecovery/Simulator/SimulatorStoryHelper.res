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
              className="relative flex flex-col bg-white py-1 overflow-hidden rounded ring-1 ring-black ring-opacity-5 w-64">
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

let pillStyle = `h-9 w-fit flex items-center gap-2 px-3 rounded-full ${body.md.semibold}`

// The proxy sets `waiting` when Rev Rec has not booked a retry long after it should have (sandbox
// scheduler). A quiet amber pill says so in place of the next action; "?" opens the why.
module StallPill = {
  @react.component
  let make = (~onWhy) => {
    <div className={`${pillStyle} border bg-nd_orange-50 border-nd_orange-200 text-nd_orange-600`}>
      <span> {"Rev Rec hasn't booked a retry yet · sandbox"->React.string} </span>
      <HelpButton onClick=onWhy />
    </div>
  }
}

// The one next action on the last step (UX-PASS-2 A4). "Next" reveals one more step; when that
// step has not arrived yet a quiet pill waits for it (with the countdown to a booked retry). A
// stalled sandbox shows the amber pill instead. "Customer pays in app" sits beside, secondary.
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
    let isStalled = waiting->Option.isSome
    <RenderIf condition={showNext || isStalled || inlineActions->Array.length > 0}>
      // Clicks here must not open the step's drawer
      <div
        className="flex flex-wrap items-center gap-3 pt-3"
        onClick={event => event->ReactEvent.Mouse.stopPropagation}>
        {switch (isStalled, showNext, isWaiting, nextRetryAt) {
        | (true, _, _, _) => <StallPill onWhy=onWaitingWhy />
        | (false, false, _, _) => React.null
        | (false, true, true, Some(time)) =>
          <div className={`${pillStyle} bg-nd_gray-150 text-nd_gray-600`}>
            {"Rev Rec retries "->React.string}
            <Countdown nextRetryAt=time />
          </div>
        | (false, true, true, None) =>
          <div className={`${pillStyle} bg-nd_gray-150 text-nd_gray-600`}>
            <Loadericon size=14 iconColor="text-nd_gray-500" />
            {"Waiting for Rev Rec…"->React.string}
          </div>
        | (false, true, false, _) =>
          <Button text=nextLabel buttonType=Primary buttonSize=Medium onClick={_ => onNext()} />
        }}
        {inlineActions
        ->Array.map(((text, onClick)) =>
          <Button
            key=text
            text
            buttonType=Secondary
            buttonSize=Medium
            buttonState={isBusy ? Disabled : Normal}
            onClick={_ => onClick()}
          />
        )
        ->React.array}
      </div>
    </RenderIf>
  }
}

// How many sandbox attempts each side made: "Billing 3 · Rev Rec 1"
let attemptCount = (story: story, ~by) =>
  story.attemptBy->Array.filter(who => who == by)->Array.length

// Below the story (UX-PASS-2 A5): one compact card in place of the invoice page. The steps
// already show each attempt; the real page is one click away.
module InvoiceCard = {
  @react.component
  let make = (~story: story) => {
    let order = story.invoice->RevenueRecoveryEntity.itemToObjMapperForIntents
    let order = {...order, status: story.stage->toInvoiceStatus(~default=order.status)}
    let mixpanelEvent = MixpanelHook.useSendEvent()
    // The invoice page's path carries the profile, merchant and org, as the Invoices list's does
    let {profileId, merchantId, orgId} = React.useContext(
      UserInfoProvider.defaultContext,
    ).getCommonSessionDetails()
    let invoicePath = `/v2/recovery/invoices/${story.recoveryId}/${story.invoice->LogicUtils.getString(
        "profile_id",
        profileId,
      )}/${merchantId}/${orgId}`

    <div className={`${cardStyle} px-6 py-4 flex flex-col gap-3`}>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-3">
          <p className={`${body.lg.semibold} text-nd_gray-800`}> {"Invoice"->React.string} </p>
          <Table.TableCell cell={RevenueRecoveryEntity.getCell(order, Status)} />
        </div>
        <span
          className={`cursor-pointer text-blue-500 hover:text-blue-700 ${body.md.semibold}`}
          onClick={_ => {
            mixpanelEvent(~eventName="recovery_simulator_open_invoice")
            RescriptReactRouter.push(GlobalVars.appendDashboardPath(~url=invoicePath))
          }}>
          {"Open invoice page →"->React.string}
        </span>
      </div>
      <RecoveryInvoicesHelper.SegmentedProgressBar
        orderAmount=order.order_amount amountCaptured=order.amount_captured
      />
      <p className={`${body.md.medium} text-nd_gray-500`}>
        {`Attempts: Billing ${story
          ->attemptCount(~by="billing")
          ->Int.toString} · Rev Rec ${story
          ->attemptCount(~by="revrec")
          ->Int.toString}`->React.string}
      </p>
    </div>
  }
}
