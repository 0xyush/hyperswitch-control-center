// Setup Recovery (Home → Explore Recovery): the real Rev Rec onboarding steps
// (RevenueRecoveryOnboarding: Connect Processor, Add a Platform, Review Details), shown with the
// connectors this demo already runs on. Nothing is created here:
//   - Select steps show only the connectors that work right now (GET /sim/connectors, live-checked).
//   - Each Authenticate step opens a popup: the connector is already configured; its values are
//     masked and blurred.
//   - Review Details reads the demo profile's settings (GET /sim/setup/summary).
//   - Start simulation opens the Invoice story, on the processor picked here (kept in this browser).
//     "Skip to the simulator" opens it too, from any step.
open Typography
open LogicUtils

type check = {what: string, ok: bool}
type maskedField = {fieldLabel: string, value: string}
type demoConnector = {
  id: string,
  name: string,
  kind: string,
  working: bool,
  checks: array<check>,
  fields: array<maskedField>,
}
type setting = {label: string, text: string}
type summary = {processor: string, platform: string, settings: array<setting>, note: string}

let connectorMapper = (json): demoConnector => {
  let d = json->getDictFromJsonObject
  {
    id: d->getString("id", ""),
    name: d->getString("name", ""),
    kind: d->getString("kind", ""),
    working: d->getBool("working", false),
    checks: d
    ->getArrayFromDict("checks", [])
    ->Array.map(json => {
      let c = json->getDictFromJsonObject
      {what: c->getString("what", ""), ok: c->getBool("ok", false)}
    }),
    fields: d
    ->getArrayFromDict("maskedFields", [])
    ->Array.map(json => {
      let f = json->getDictFromJsonObject
      {fieldLabel: f->getString("label", ""), value: f->getString("value", "")}
    }),
  }
}

let summaryMapper = (json): summary => {
  let d = json->getDictFromJsonObject
  {
    processor: d->getDictfromDict("processor")->getString("text", ""),
    platform: d->getDictfromDict("platform")->getString("text", ""),
    settings: d
    ->getArrayFromDict("settings", [])
    ->Array.map(json => {
      let s = json->getDictFromJsonObject
      {label: s->getString("label", ""), text: s->getString("text", "")}
    }),
    note: d->getString("note", ""),
  }
}

// The custom billing system needs no processor reference, so its flow has no set-up step
let billingConnector = "custombilling"
let isLiveMode = true

let goTo = path => RescriptReactRouter.push(GlobalVars.appendDashboardPath(~url=path))

module SkipLink = {
  @react.component
  let make = () =>
    <AddDataAttributes attributes=[("data-sim", "skip-to-simulator")]>
      <button
        type_="button"
        className={`${body.md.semibold} text-nd_primary_blue-500 hover:underline`}
        onClick={_ => goTo(RevenueRecoverySidebarValues.simulatorStoryPath)}>
        {"Skip to the simulator"->React.string}
      </button>
    </AddDataAttributes>
}

module Checks = {
  @react.component
  let make = (~checks: array<check>) =>
    <div className="flex flex-col gap-1.5">
      {checks
      ->Array.map(check =>
        <div key=check.what className="flex items-center gap-2">
          <Icon
            name={check.ok ? "nd-tick-circle" : "nd-alert-triangle-outline"}
            size=16
            className={check.ok ? "text-nd_green-600" : "text-nd_red-500"}
          />
          <span className={`${body.md.medium} text-nd_gray-600`}> {check.what->React.string} </span>
        </div>
      )
      ->React.array}
    </div>
}

// The connector's fields, as a form would show them: the values masked, then blurred
module MaskedFields = {
  @react.component
  let make = (~fields: array<maskedField>) =>
    <div className="flex flex-col gap-4">
      {fields
      ->Array.map(field =>
        <div key=field.fieldLabel className="flex flex-col gap-1.5">
          <span className={`${body.md.semibold} text-nd_gray-700`}>
            {field.fieldLabel->React.string}
          </span>
          <div
            className="w-full rounded-lg border border-nd_gray-200 bg-nd_gray-50 px-3 py-2 select-none">
            <span className={`${body.md.medium} text-nd_gray-600 blur-[3px]`}>
              {field.value->React.string}
            </span>
          </div>
        </div>
      )
      ->React.array}
    </div>
}

// Opens when an Authenticate step shows: nothing to enter, the connector is already set up
module ConfiguredPopup = {
  @react.component
  let make = (~connector: option<demoConnector>, ~onClose, ~onContinue) =>
    <Modal
      showModal={connector->Option.isSome}
      setShowModal={_ => onClose()}
      closeOnOutsideClick=true
      modalHeading="Already configured"
      modalClass="w-full max-w-lg mx-auto my-auto !bg-white rounded-xl"
      childClass="px-6 pt-5 pb-6">
      {switch connector {
      | Some(connector) =>
        <AddDataAttributes attributes=[("data-sim", "configured-popup")]>
          <div className="flex flex-col gap-5">
            <div className="flex items-center gap-3">
              <GatewayIcon gateway={connector.id->String.toUpperCase} className="w-10 h-10" />
              <div className="flex flex-col gap-0.5">
                <span className={`${body.lg.semibold} text-nd_gray-800`}>
                  {connector.name->React.string}
                </span>
                <span className={`${body.md.medium} text-nd_gray-500`}>
                  {"This demo already uses it. Nothing to enter."->React.string}
                </span>
              </div>
            </div>
            <Checks checks=connector.checks />
            <MaskedFields fields=connector.fields />
            <span className={`${body.sm.medium} text-nd_gray-500`}>
              {"The keys stay hidden. Rev Rec stores them encrypted."->React.string}
            </span>
            <Button
              text="Continue"
              buttonType=Primary
              customButtonStyle="!w-full"
              onClick={_ => onContinue()}
            />
          </div>
        </AddDataAttributes>
      | None => React.null
      }}
    </Modal>
}

// The Authenticate step's page: the same fields, behind the popup
module AuthenticateStep = {
  @react.component
  let make = (~connector: option<demoConnector>, ~onOpen, ~onNext) =>
    <div className="flex flex-col gap-6 w-540-px">
      {switch connector {
      | Some(connector) =>
        <>
          <div className="flex items-center gap-3">
            <GatewayIcon gateway={connector.id->String.toUpperCase} className="w-8 h-8" />
            <span className={`${body.lg.semibold} text-nd_gray-800`}>
              {connector.name->React.string}
            </span>
            <span
              className={`rounded px-1.5 py-0.5 border bg-nd_green-50 text-nd_green-600 border-nd_green-200 ${body.xs.semibold}`}>
              {"Already configured"->React.string}
            </span>
          </div>
          <MaskedFields fields=connector.fields />
          <div className="flex gap-3">
            <Button text="Why are the keys hidden?" buttonType=Secondary onClick={_ => onOpen()} />
            <Button text="Next" buttonType=Primary onClick={_ => onNext()} />
          </div>
        </>
      | None => React.null
      }}
    </div>
}

module ReviewStep = {
  @react.component
  let make = (~summary: option<summary>, ~connectors: array<demoConnector>) => {
    let row = (~label, ~value, ~working) =>
      <div key=label className="flex items-center justify-between gap-6 py-3">
        <span className={`${body.md.medium} text-nd_gray-500 whitespace-nowrap shrink-0`}>
          {label->React.string}
        </span>
        <div className="flex items-center gap-2 min-w-0">
          <span className={`${body.md.semibold} text-nd_gray-800 text-right`}>
            {value->React.string}
          </span>
          <RenderIf condition=working>
            <Icon name="nd-tick-circle" size=16 className="text-nd_green-600" />
          </RenderIf>
        </div>
      </div>
    let works = kind => connectors->Array.some(c => c.kind == kind && c.working)
    <div className="flex flex-col gap-6 w-540-px">
      <AddDataAttributes attributes=[("data-sim", "setup-review")]>
        <div
          className="flex flex-col divide-y divide-nd_gray-150 rounded-xl border border-nd_gray-200 bg-white px-5">
          {row(
            ~label="Processor",
            ~value=summary->Option.mapOr("Stripe (test mode)", s => s.processor),
            ~working=works("processor"),
          )}
          {row(
            ~label="Billing platform",
            ~value=summary->Option.mapOr("This simulator", s => s.platform),
            ~working=works("billing"),
          )}
          {summary
          ->Option.mapOr([], s => s.settings)
          ->Array.map(setting => row(~label=setting.label, ~value=setting.text, ~working=false))
          ->React.array}
        </div>
      </AddDataAttributes>
      {switch summary {
      | Some(s) if s.note->isNonEmptyString =>
        <span className={`${body.md.medium} text-nd_gray-500`}> {s.note->React.string} </span>
      | _ => React.null
      }}
      <Button
        text="Start simulation"
        buttonType=Primary
        buttonSize=Large
        customButtonStyle="!w-fit"
        onClick={_ => goTo(RevenueRecoverySidebarValues.simulatorStoryPath)}
      />
    </div>
  }
}

// The real onboarding's connector cards (PaymentProcessorCards), without its permission gate:
// the demo's user does not manage connectors, and picking here creates nothing
module ConnectorCards = {
  @react.component
  let make = (~connectors, ~connectorType, ~heading, ~onPick) =>
    <div className="flex flex-col gap-4">
      <h2 className={`${body.lg.semibold} text-nd_gray-600`}> {heading->React.string} </h2>
      <div className="grid gap-x-5 gap-y-6 lg:grid-cols-3 md:grid-cols-2 grid-cols-1 mb-5">
        {connectors
        ->Array.map((connector: ConnectorTypes.connectorTypes) => {
          let name = connector->ConnectorUtils.getConnectorNameString
          <AddDataAttributes key=name attributes=[("data-sim", `connector-${name}`)]>
            <div
              role="button"
              className="border p-4 gap-3 bg-white rounded-lg flex flex-col justify-start h-9.5-rem hover:bg-gray-50 cursor-pointer"
              onClick={_ => onPick(name)}>
              <div className="flex flex-row gap-3 items-center">
                <GatewayIcon gateway={name->String.toUpperCase} className="w-10 h-10 rounded-sm" />
                <p className={`${body.lg.semibold} text-nd_gray-800 break-all`}>
                  {name->ConnectorUtils.getDisplayNameForConnector(~connectorType)->React.string}
                </p>
              </div>
              <p className={`overflow-hidden ${body.md.medium} text-nd_gray-400 line-clamp-3`}>
                {(connector->ConnectorUtils.getConnectorInfo).description->React.string}
              </p>
            </div>
          </AddDataAttributes>
        })
        ->React.array}
      </div>
    </div>
}

module NoneWorking = {
  @react.component
  let make = (~what) =>
    <div className="flex flex-col gap-3">
      <span className={`${body.md.medium} text-nd_gray-600`}>
        {`No ${what} works in this demo right now.`->React.string}
      </span>
      <SkipLink />
    </div>
}

@react.component
let make = () => {
  open RevenueRecoveryOnboardingUtils
  let simFetch = SimulatorApi.useSimFetch()
  let {setShowSideBar} = React.useContext(GlobalProvider.defaultContext)
  let (screenState, setScreenState) = React.useState(_ => PageLoaderWrapper.Loading)
  let (connectors, setConnectors) = React.useState(_ => [])
  let (summary, setSummary) = React.useState(_ => None)
  let (currentStep, setCurrentStep) = React.useState(_ => getDefaultStep(isLiveMode))
  let (processorId, setProcessorId) = React.useState(_ => "")
  let (platformId, setPlatformId) = React.useState(_ => "")
  let (popupFor, setPopupFor) = React.useState(_ => None)

  // Like the real onboarding: full width, no sidebar, while the walkthrough shows
  React.useEffect(() => {
    setShowSideBar(_ => false)
    let read = async () => {
      try {
        let json = await simFetch(~path="/sim/connectors", ~method_=Get)
        setConnectors(_ =>
          json
          ->getDictFromJsonObject
          ->getArrayFromDict("connectors", [])
          ->Array.map(connectorMapper)
        )
        setScreenState(_ => Success)
      } catch {
      | _ => setScreenState(_ => Error("The demo's connectors could not be read."))
      }
      try {
        let json = await simFetch(~path="/sim/setup/summary", ~method_=Get)
        setSummary(_ => Some(json->summaryMapper))
      } catch {
      | _ => ()
      }
    }
    read()->ignore
    Some(() => setShowSideBar(_ => true))
  }, [])

  let next = () => onNextClick(currentStep, setCurrentStep, ~isLiveMode, ~billingConnector)
  let find = id => connectors->Array.find(c => c.id == id)
  // Only connectors that work right now can be picked
  // Processors the simulator offers now (SimulatorUtils.processorsEnabled: Stripe only)
  let working = (kind, ~connectorType) =>
    connectors
    ->Array.filter(c =>
      c.kind == kind && c.working && (kind != "processor" || c.id->SimulatorUtils.processorEnabled)
    )
    ->Array.map(c => c.id->ConnectorUtils.getConnectorNameTypeFromString(~connectorType))
  let pick = (id, setId) => {
    setId(_ => id)
    next()
    setPopupFor(_ => find(id))
  }

  let content = switch currentStep->getSectionVariant {
  | (#connectProcessor, #selectProcessor) =>
    let processors = working("processor", ~connectorType=ConnectorTypes.Processor)
    <PageWrapper
      title="Where do you process your payments"
      subTitle={processors->Array.length == 1
        ? "This demo runs on one processor, in test mode."
        : "Only processors that work in this demo are shown."}>
      {processors->Array.length == 0
        ? <NoneWorking what="processor" />
        : <ConnectorCards
            connectors=processors
            connectorType=ConnectorTypes.Processor
            heading="Choose a processor"
            onPick={id => {
              // The story form starts on this processor
              SimulatorUtils.saveProcessor(id)
              pick(id, setProcessorId)
            }}
          />}
    </PageWrapper>
  | (#connectProcessor, #authenticateProcessor) =>
    <PageWrapper
      title="Authenticate Processor" subTitle="Rev Rec already holds this processor's keys.">
      <AuthenticateStep
        connector={find(processorId)} onOpen={() => setPopupFor(_ => find(processorId))} onNext=next
      />
    </PageWrapper>
  | (#addAPlatform, #selectAPlatform) =>
    let platforms = working("billing", ~connectorType=ConnectorTypes.BillingProcessor)
    <PageWrapper
      title="Choose your Billing Platform"
      subTitle="In this demo, the simulator is the billing system. It informs Rev Rec of each failed charge.">
      {platforms->Array.length == 0
        ? <NoneWorking what="billing platform" />
        : <ConnectorCards
            connectors=platforms
            connectorType=ConnectorTypes.BillingProcessor
            heading="Choose a platform"
            onPick={id => pick(id, setPlatformId)}
          />}
    </PageWrapper>
  | (#addAPlatform, #authenticateBilling) =>
    <PageWrapper
      title="Authenticate Platform" subTitle="Rev Rec already knows this billing system.">
      <AuthenticateStep
        connector={find(platformId)} onOpen={() => setPopupFor(_ => find(platformId))} onNext=next
      />
    </PageWrapper>
  | (#reviewDetails, _) =>
    <PageWrapper title="Review Details" subTitle="Rev Rec is ready to recover failed payments.">
      <ReviewStep summary connectors />
    </PageWrapper>
  | _ => React.null
  }

  <div className="flex flex-row">
    <VerticalStepIndicator
      titleElement={"Setup Recovery"->React.string}
      sections={getSections(~isLiveMode, ~billingConnector)}
      currentStep
      backClick={() => goTo(RevenueRecoverySidebarValues.homePath)}
    />
    <div className="flex flex-col gap-6 ml-14 mt-16 w-full pr-14">
      <div className="flex justify-end">
        <SkipLink />
      </div>
      <PageLoaderWrapper screenState> content </PageLoaderWrapper>
    </div>
    <ConfiguredPopup
      connector=popupFor
      onClose={() => setPopupFor(_ => None)}
      onContinue={() => {
        setPopupFor(_ => None)
        next()
      }}
    />
  </div>
}
