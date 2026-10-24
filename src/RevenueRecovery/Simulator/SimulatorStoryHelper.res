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
let makeInput = (~name, ~value, ~onChange): ReactFinalForm.fieldRenderPropsInput => {
  name,
  onBlur: _ => (),
  onFocus: _ => (),
  onChange: event => onChange(event->Identity.formReactEventToString),
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
  let make = (~label, ~name, ~options, ~value, ~onChange) => {
    <FormField label>
      {InputFields.selectInput(
        ~options,
        ~buttonText=`Select ${label->String.toLowerCase}`,
        ~deselectDisable=true,
        ~fullLength=true,
        ~textStyle="!font-normal",
      )(~input=makeInput(~name, ~value, ~onChange), ~placeholder="")}
    </FormField>
  }
}

// Kebab menu with the billing system's less common actions
module BillingMenu = {
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

// Left panel: the form plays the merchant's billing system, like the checkout form plays the checkout
module BillingSystemForm = {
  @react.component
  let make = (
    ~options: formOptions,
    ~form: billingForm,
    ~setForm,
    ~isBusy,
    ~story: option<story>,
    ~onCharge,
    ~onPaidInApp,
    ~onReportAgain,
    ~onCancel,
    ~onStartOver,
  ) => {
    let selectedPreset = options.presets->Array.find(preset => preset.id == form.preset)
    let hasInvoice = story->Option.mapOr(false, s => s.recoveryId->LogicUtils.isNonEmptyString)
    let actions =
      story->Option.mapOr({paidInApp: false, reportAgain: false, cancel: false}, s => s.actions)
    let menuOptions =
      [
        actions.reportAgain ? Some(("Report another failure", onReportAgain)) : None,
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
            {"Simulated by the proxy. It charges the customer's saved card and reports failures to Rev Rec."->React.string}
          </p>
        </div>
        <RenderIf condition={menuOptions->Array.length > 0}>
          <BillingMenu options=menuOptions />
        </RenderIf>
      </div>
      <div className="flex flex-col gap-1">
        <SelectField
          label="Preset"
          name="preset"
          options={options.presets->presetOptions}
          value={form.preset->Int.toString}
          onChange={value =>
            options.presets
            ->Array.find(preset => preset.id->Int.toString == value)
            ->Option.forEach(preset => setForm(_ => preset.fields))}
        />
        {switch selectedPreset {
        | Some(preset) =>
          <p className={`${body.sm.medium} text-nd_gray-500`}> {preset.summary->React.string} </p>
        | None => React.null
        }}
      </div>
      <FormField label="Amount">
        {InputFields.numericTextInput(
          ~customStyle="w-full border-nd_gray-200 rounded-lg",
          ~precision=2,
        )(
          ~input=makeInput(~name="amount", ~value=form.amount, ~onChange=amount =>
            setForm(prev => {...prev, amount})
          ),
          ~placeholder="Enter amount",
        )}
      </FormField>
      <SelectField
        label="Currency"
        name="currency"
        options=options.currencies
        value=form.currency
        onChange={currency => setForm(prev => {...prev, currency})}
      />
      <SelectField
        label="Saved card"
        name="card"
        options=options.cards
        value=form.card
        onChange={card => setForm(prev => {...prev, card})}
      />
      <SelectField
        label="Customer"
        name="customer"
        options=customerOptions
        value=form.customer
        onChange={customer => setForm(prev => {...prev, customer})}
      />
      <Button
        text="Charge customer"
        buttonType=Primary
        buttonSize=Medium
        customButtonStyle="!w-full"
        buttonState={isBusy ? Loading : Normal}
        onClick={_ => onCharge()}
      />
      <RenderIf condition=hasInvoice>
        <Button
          text="Customer pays in app"
          buttonType=Secondary
          buttonSize=Small
          customButtonStyle="!w-full"
          buttonState={actions.paidInApp && !isBusy ? Normal : Disabled}
          onClick={_ => onPaidInApp()}
        />
      </RenderIf>
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
      title=row.label
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

// UML-style sequence diagram. Rows are appended as real events arrive; nothing moves.
module SequenceDiagram = {
  @react.component
  let make = (~story: option<story>, ~onRowClick) => {
    // The proxy sends the booked retry as the last row, with status pending
    let rows = story->Option.mapOr([], s => s.timeline)

    <div className={`${cardStyle} px-6 py-5 flex flex-col gap-3`}>
      <div className="flex flex-col gap-1">
        <p className={`${heading.md.semibold} text-nd_gray-900`}>
          {"What happened"->React.string}
        </p>
        <p className={`${body.md.medium} text-nd_gray-500`}>
          {"Each real event is one row. Click a row to see why it happened."->React.string}
        </p>
      </div>
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
      {if rows->Array.length == 0 {
        <p className={`${body.md.medium} text-nd_gray-500 py-6 text-center`}>
          {"Press Charge customer. The billing system's charge and its report to Rev Rec appear here first."->React.string}
        </p>
      } else {
        <div className="flex flex-col">
          {rows
          ->Array.mapWithIndex((row, index) =>
            <DiagramRow
              key={`${row.stepId}-${index->Int.toString}`}
              row
              time={row.status == StepPending
                ? <Countdown nextRetryAt=row.at />
                : row.at->toClockTime->React.string}
              onClick={() => onRowClick(row)}
            />
          )
          ->React.array}
        </div>
      }}
    </div>
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
            {line.text->React.string}
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
  let make = (~row: option<diagramRow>, ~story: option<story>, ~onClose) => {
    let sectionTitle = text =>
      <p className={`${body.sm.semibold} text-nd_gray-400 uppercase`}> {text->React.string} </p>

    <Modal
      showModal={row->Option.isSome}
      setShowModal={_ => onClose()}
      closeOnOutsideClick=true
      modalHeading="What happened"
      modalClass="flex flex-col justify-start h-screen w-full md:w-2/5 float-right overflow-hidden !bg-white"
      childClass="relative h-full">
      {switch row {
      | Some(row) =>
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
      | None => React.null
      }}
    </Modal>
  }
}
