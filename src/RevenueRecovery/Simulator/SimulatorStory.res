// Invoice story (simulator/REDESIGN-story.md and STORY-STEPS.md): the left form plays the
// merchant's billing system, like the checkout form on Orchestrator's "Try It Out" page. The right
// side is the product itself: the story as steps grouped by phase, then the real invoice page.
open SimulatorTypes
open SimulatorUtils
open SimulatorStoryHelper

// Faster polling while the billing system is still creating the invoice
let startingPollMs = 1000

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
  // The form values of a charge that is on its way, shown as step 1 before the proxy answers
  let (optimistic, setOptimistic) = React.useState(_ => None)
  // How many steps the viewer has allowed so far (the billing steps always show)
  let (revealLimit, setRevealLimit) = React.useState(_ => 0)
  let (autoPlay, setAutoPlay) = React.useState(_ => false)
  let (showDiagram, setShowDiagram) = React.useState(_ => false)
  // The story whose values the form shows, so a reopened story fills the form once
  let formStoryId = React.useRef("")
  // The story started in this tab: its steps animate from step 1; a reopened story's do not
  let startedHereId = React.useRef("")

  // Scenario 3 can stay in Monitoring, so the proxy's done flag is the main end signal
  let isDone = story->Option.mapOr(false, (s: story) => s.done || s.stage->isFinalStage)
  let isStarting =
    story->Option.mapOr(optimistic->Option.isSome, (s: story) => s.stage == Starting && !s.done)
  let storyPath = id =>
    GlobalVars.appendDashboardPath(~url=`${RevenueRecoverySidebarValues.simulatorStoryPath}/${id}`)

  let fetchPresets = async () => {
    try {
      setScreenState(_ => PageLoaderWrapper.Loading)
      let json = await simFetch(~path="/sim/presets", ~method_=Get)
      let formOptions = json->getFormOptions
      setOptions(_ => formOptions)
      // A link like ?preset=7 (from the feature tour) picks that preset; otherwise the first
      // scenario tile
      let firstTile =
        scenarioTiles
        ->Array.get(0)
        ->Option.flatMap(((id, _, _, _)) =>
          formOptions.presets->Array.find(preset => preset.id == id)
        )
      let presetFromUrl =
        url.search
        ->getDictFromUrlSearchParams
        ->Dict.get("preset")
        ->Option.flatMap(id =>
          formOptions.presets->Array.find(preset => preset.id->Int.toString == id)
        )
      presetFromUrl
      ->Option.orElse(firstTile)
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

  // Poll the story until the proxy says it is done: every second while it is starting, then 4 s
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

                  // A reopened story shows every step it already has
                  if startedHereId.current != id {
                    setRevealLimit(_ =>
                      polledStory->SimulatorStorySteps.buildStoryItems->snd->Array.length
                    )
                  }
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
        let intervalId = setInterval(
          () => poll()->ignore,
          isStarting ? startingPollMs : pollIntervalMs,
        )
        Some(
          () => {
            cancelled := true
            clearInterval(intervalId)
          },
        )
      }
    | _ => None
    }
  }, (storyIdFromUrl, isDone, isStarting))

  // Charge customer: step 1 shows at once; the proxy then answers with status "starting"
  let onCharge = async () => {
    // Leave the old story first, so its polling stops and its steps clear
    RescriptReactRouter.replace(
      GlobalVars.appendDashboardPath(~url=RevenueRecoverySidebarValues.simulatorStoryPath),
    )
    setStory(_ => None)
    setDrawerContent(_ => None)
    setRevealLimit(_ => 0)
    setOptimistic(_ => Some(form))
    setIsBusy(_ => true)
    mixpanelEvent(~eventName="recovery_simulator_charge_customer")
    try {
      let json = await simFetch(~path="/sim/story/start", ~method_=Post, ~body=form->startBody)
      let newStory = json->storyMapper
      startedHereId.current = newStory.storyId
      formStoryId.current = newStory.storyId
      setStory(_ => Some(newStory))
      setPollError(_ => "")
      RescriptReactRouter.replace(storyPath(newStory.storyId))
    } catch {
    | exn => {
        setOptimistic(_ => None)
        showToast(
          ~message=exn->getSimErrorMessage(~default="The billing system could not charge."),
          ~toastType=ToastError,
        )
      }
    }
    setIsBusy(_ => false)
  }

  // Paid in app, Report another failure and Cancel invoice: the proxy answers with the updated
  // story, and the steps the viewer caused show at once
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
        let updated = json->storyMapper
        setRevealLimit(_ => updated->SimulatorStorySteps.buildStoryItems->snd->Array.length)
        setStory(_ => Some(updated))
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
  let onPaidInApp = () =>
    runAction(~action="paid-in-app", ~eventName="recovery_simulator_paid_in_app")->ignore
  let onReportAgain = () =>
    runAction(~action="report-again", ~eventName="recovery_simulator_report_again")->ignore

  let onStartOver = () => {
    mixpanelEvent(~eventName="recovery_simulator_start_over")
    setStory(_ => None)
    setOptimistic(_ => None)
    setRevealLimit(_ => 0)
    setDrawerContent(_ => None)
    setPollError(_ => "")
    RescriptReactRouter.replace(
      GlobalVars.appendDashboardPath(~url=RevenueRecoverySidebarValues.simulatorStoryPath),
    )
  }

  // Pacing (STORY-STEPS.md section 6), over the grouped steps of STORY-DESIGN.md
  let (_, items) = React.useMemo1(
    () => story->Option.mapOr(("", []), SimulatorStorySteps.buildStoryItems),
    [story],
  )
  let itemTotal = items->Array.length
  let visibleCount = SimulatorStorySteps.visibleItemCount(~items, ~revealLimit, ~autoPlay)
  let allShown = visibleCount == itemTotal
  // The outcome card is the last item once the story is done
  let isFinished = isDone && itemTotal > 0 && allShown
  // The pause starts once the billing system has told Rev Rec
  let hasReport = items->Array.some(item => item.phase >= 2)
  let showNext = !autoPlay && hasReport && !isFinished
  let isWaitingForNext = showNext && revealLimit > visibleCount && allShown
  let onNext = () => {
    mixpanelEvent(~eventName="recovery_simulator_next_step")
    setRevealLimit(_ => visibleCount + 1)
  }

  // Which steps fade in: those added in this tab, not those known when the story was opened
  let itemCount = Math.Int.max(visibleCount, 1)
  let storyKey = switch story {
  | Some(s) => s.storyId
  | None => optimistic->Option.isSome ? "pending" : "none"
  }
  let initialCount = switch storyKey {
  | "pending" | "none" => 0
  | key if key == startedHereId.current => 1 // the optimistic step 1 already showed
  | _ => itemCount
  }
  let revealDelays = useRevealDelays(~storyKey, ~itemCount, ~initialCount)

  let actions =
    story->Option.mapOr({paidInApp: false, reportAgain: false, cancel: false}, s => s.actions)
  let inlineActions =
    [
      actions.paidInApp ? Some(("Customer pays in app", onPaidInApp)) : None,
    ]->Array.filterMap(action => action)

  let warnings = switch story {
  | Some(s) =>
    // The waiting note shows inside the story, so its warning would only repeat it
    let waitingText = s.waiting->Option.mapOr("", waiting => waiting.text)
    [s.startError]
    ->Array.concat(
      s.warnings->Array.filter(warning =>
        waitingText->isEmptyString || !(warning->String.startsWith(waitingText))
      ),
    )
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
      subTitle="Charge a customer on the left. Watch Rev Rec handle the failed invoice on the right."
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
            isLocked={isBusy || isStarting}
            story
            onCharge={() => onCharge()->ignore}
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
          <SimulatorStorySteps.StoryView
            story
            optimistic
            items
            visibleCount
            isFinished
            showNext
            isWaitingForNext
            revealDelays
            autoPlay
            setAutoPlay={value => {
              // Turning auto-play off keeps the steps already on screen
              setRevealLimit(_ => visibleCount)
              setAutoPlay(_ => value)
            }}
            showDiagram
            setShowDiagram
            inlineActions
            onReportAgain=?{actions.reportAgain ? Some(onReportAgain) : None}
            isBusy
            onNext
            onRowClick={row => setDrawerContent(_ => Some(StepDetails(row)))}
            onStatesClick={() => setDrawerContent(_ => Some(StateHistory))}
            onWaitingClick={() => setDrawerContent(_ => Some(WaitingDetails))}
          />
          {switch story {
          | Some(s) if !(s.invoice->isEmptyDict) => <InvoiceCard story=s />
          | _ => React.null
          }}
        </div>
      </div>
    </PageLoaderWrapper>
    <ExplainDrawer content=drawerContent story onClose={() => setDrawerContent(_ => None)} />
  </div>
}
