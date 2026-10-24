// Invoice story (simulator/REDESIGN-story.md): the left form plays the merchant's billing system,
// like the checkout form on Orchestrator's "Try It Out" page. The right side is the product itself:
// a sequence diagram of the real events, then the real invoice detail page, both updated live.
open SimulatorTypes
open SimulatorUtils
open SimulatorStoryHelper

@react.component
let make = (~storyIdFromUrl: option<string>) => {
  open LogicUtils
  let simFetch = SimulatorApi.useSimFetch()
  let url = RescriptReactRouter.useUrl()
  let showToast = ToastAdapter.useShowToast()
  let mixpanelEvent = MixpanelHook.useSendEvent()

  let (screenState, setScreenState) = React.useState(_ => PageLoaderWrapper.Loading)
  let (options, setOptions) = React.useState(_ => {presets: [], cards: [], currencies: []})
  let (form, setForm) = React.useState(_ => defaultForm)
  let (story, setStory) = React.useState(_ => None)
  let (isBusy, setIsBusy) = React.useState(_ => false)
  let (pollError, setPollError) = React.useState(_ => "")
  let (drawerContent, setDrawerContent) = React.useState(_ => None)
  // The story whose values the form shows, so a reopened story fills the form once
  let formStoryId = React.useRef("")

  // Scenario 3 can stay in Monitoring, so the proxy's done flag is the main end signal
  let isDone = story->Option.mapOr(false, (s: story) => s.done || s.stage->isFinalStage)
  let storyPath = id =>
    GlobalVars.appendDashboardPath(~url=`${RevenueRecoverySidebarValues.simulatorStoryPath}/${id}`)

  let fetchPresets = async () => {
    try {
      setScreenState(_ => PageLoaderWrapper.Loading)
      let json = await simFetch(~path="/sim/presets", ~method_=Get)
      let formOptions = json->getFormOptions
      setOptions(_ => formOptions)
      // A link like ?preset=7 (from the feature tour) picks that preset; otherwise the first one
      let presetFromUrl =
        url.search
        ->getDictFromUrlSearchParams
        ->Dict.get("preset")
        ->Option.flatMap(id =>
          formOptions.presets->Array.find(preset => preset.id->Int.toString == id)
        )
      presetFromUrl
      ->Option.orElse(formOptions.presets->Array.get(0))
      ->Option.forEach(preset => setForm(_ => preset.fields))
      setScreenState(_ => PageLoaderWrapper.Success)
    } catch {
    | _ => setScreenState(_ => PageLoaderWrapper.Custom)
    }
  }

  React.useEffect(() => {
    fetchPresets()->ignore
    None
  }, [])

  // Poll the story every 4 s until the proxy says it is done
  React.useEffect(() => {
    switch storyIdFromUrl {
    | Some(id) if !isDone => {
        let cancelled = ref(false)
        let inFlight = ref(false)
        let poll = async () => {
          if !inFlight.contents {
            inFlight := true
            try {
              let json = await simFetch(~path=`/sim/story/${id}`, ~method_=Get)
              if !cancelled.contents {
                let polledStory = json->storyMapper
                if formStoryId.current != id {
                  formStoryId.current = id
                  polledStory.form->Option.forEach(storyForm => setForm(_ => storyForm))
                }
                setStory(_ => Some(polledStory))
                setPollError(_ => "")
              }
            } catch {
            | exn =>
              if !cancelled.contents {
                setPollError(_ =>
                  exn->getSimErrorMessage(~default="The simulator proxy did not answer. Retrying.")
                )
              }
            }
            inFlight := false
          }
        }
        poll()->ignore
        let intervalId = setInterval(() => poll()->ignore, pollIntervalMs)
        Some(
          () => {
            cancelled := true
            clearInterval(intervalId)
          },
        )
      }
    | _ => None
    }
  }, (storyIdFromUrl, isDone))

  // Charge customer: the billing system's own charge starts a new story
  let onCharge = async () => {
    setIsBusy(_ => true)
    mixpanelEvent(~eventName="recovery_simulator_charge_customer")
    try {
      let json = await simFetch(~path="/sim/story/start", ~method_=Post, ~body=form->startBody)
      let newStory = json->storyMapper
      formStoryId.current = newStory.storyId
      setStory(_ => Some(newStory))
      setPollError(_ => "")
      RescriptReactRouter.replace(storyPath(newStory.storyId))
    } catch {
    | exn =>
      showToast(
        ~message=exn->getSimErrorMessage(~default="The billing system could not charge."),
        ~toastType=ToastError,
      )
    }
    setIsBusy(_ => false)
  }

  // Paid in app, Report another failure and Cancel invoice: the proxy answers with the updated story
  let runAction = async (~action, ~eventName) => {
    switch storyIdFromUrl {
    | Some(id) =>
      setIsBusy(_ => true)
      mixpanelEvent(~eventName)
      try {
        let json = await simFetch(
          ~path=`/sim/story/${id}/${action}`,
          ~method_=Post,
          ~body=Dict.make()->JSON.Encode.object,
        )
        setStory(_ => Some(json->storyMapper))
      } catch {
      | exn =>
        showToast(
          ~message=exn->getSimErrorMessage(~default="The simulator could not do that."),
          ~toastType=ToastError,
        )
      }
      setIsBusy(_ => false)
    | None => ()
    }
  }

  let onStartOver = () => {
    mixpanelEvent(~eventName="recovery_simulator_start_over")
    setStory(_ => None)
    setDrawerContent(_ => None)
    setPollError(_ => "")
    RescriptReactRouter.replace(
      GlobalVars.appendDashboardPath(~url=RevenueRecoverySidebarValues.simulatorStoryPath),
    )
  }

  // An attempt row opens the diagram row of the same charge, or one built from the attempt
  let onAttemptClick = (attempt: RevenueRecoveryOrderTypes.attempts) => {
    let row =
      story
      ->Option.flatMap(s => s.timeline->rowForAttempt(attempt))
      ->Option.getOr(attempt->attemptRow)
    setDrawerContent(_ => Some(StepDetails(row)))
  }

  let warnings = switch story {
  | Some(s) =>
    [s.startError]
    ->Array.concat(s.warnings)
    ->Array.concat([pollError])
    ->Array.filter(isNonEmptyString)
  | None => [pollError]->Array.filter(isNonEmptyString)
  }

  <div className="flex flex-col gap-6">
    <BreadCrumbNavigation
      path=[{title: "Home", link: RevenueRecoverySidebarValues.homePath}]
      currentPageTitle="Invoice Story"
    />
    <PageUtils.PageHeading
      title="Invoice story"
      subTitle="Play the merchant's billing system on the left. Rev Rec on the sandbox handles the failed invoice on the right, live."
    />
    <PageLoaderWrapper
      screenState
      customUI={<NoDataFound
        message={`The simulator proxy is not reachable at ${getConfig().simUrl}. Start it (simulator/proxy) and refresh.`}
        renderType=NotFound
      />}>
      <div className="flex flex-col xl:flex-row gap-10 items-start">
        <div className="w-full xl:w-1/3 shrink-0 xl:sticky xl:top-6">
          <BillingSystemForm
            options
            form
            setForm
            isBusy
            story
            onCharge={() => onCharge()->ignore}
            onPaidInApp={() =>
              runAction(~action="paid-in-app", ~eventName="recovery_simulator_paid_in_app")->ignore}
            onReportAgain={() =>
              runAction(
                ~action="report-again",
                ~eventName="recovery_simulator_report_again",
              )->ignore}
            onCancel={() =>
              runAction(~action="cancel", ~eventName="recovery_simulator_cancel")->ignore}
            onStartOver
          />
        </div>
        <div className="w-full min-w-0 flex flex-col gap-8">
          <PageUtils.PageHeading
            title="Revenue Recovery"
            subTitle="Live from the sandbox"
            showPermLink=false
            customTitleStyle="!font-medium !text-xl !text-nd_gray-600"
          />
          {warnings
          ->Array.mapWithIndex((warning, index) =>
            <AlertV2Binding
              key={index->Int.toString}
              alertType=Warning
              slot={{slot: <Icon name="nd-toast-warning" size=20 className="text-nd_yellow-500" />}}
              description=warning
            />
          )
          ->React.array}
          <SequenceDiagram
            story
            onRowClick={row => setDrawerContent(_ => Some(StepDetails(row)))}
            onStatesClick={() => setDrawerContent(_ => Some(StateHistory))}
          />
          {switch story {
          | Some(s) if !(s.invoice->isEmptyDict) => <InvoicePanel story=s onAttemptClick />
          | Some(_) =>
            <p className={`${Typography.body.md.medium} text-nd_gray-500`}>
              {"The invoice page appears once the sandbox has recorded the invoice."->React.string}
            </p>
          | None => React.null
          }}
        </div>
      </div>
    </PageLoaderWrapper>
    <ExplainDrawer content=drawerContent story onClose={() => setDrawerContent(_ => None)} />
  </div>
}
