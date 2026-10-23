// Invoice story (PRD section 7): pick a scenario, press Play, and watch one real failed
// invoice move through Rev Rec on the sandbox. The proxy plays the billing system.
open SimulatorTypes
open SimulatorUtils
open SimulatorStoryHelper

module AttemptsSection = {
  @react.component
  let make = (~story: story) => {
    let order = story.invoice->RevenueRecoveryEntity.itemToObjMapperForIntents
    let order = {...order, status: story.stage->toInvoiceStatus(~default=order.status)}
    let attemptsList =
      story.attempts
      ->RevenueRecoveryEntity.getAttempts
      ->Array.filter(item => item.status !== "started")
    // Newest first, like the invoice page
    attemptsList->Array.reverse

    <div className=cardStyle>
      <RecoveryInvoicesHelper.AttemptsHistory
        order attemptsList processTracker={story.processTracker->Some} startRetryThreshold=0
      />
    </div>
  }
}

@react.component
let make = (~storyIdFromUrl: option<string>) => {
  open APIUtils
  open LogicUtils
  open Typography
  let fetchDetails = useGetMethod(~showErrorToast=false)
  let updateDetails = useUpdateMethod(~showErrorToast=false)
  let showToast = ToastAdapter.useShowToast()
  let mixpanelEvent = MixpanelHook.useSendEvent()

  let (screenState, setScreenState) = React.useState(_ => PageLoaderWrapper.Loading)
  let (scenarios, setScenarios) = React.useState(_ => [])
  let (selectedId, setSelectedId) = React.useState(_ => 1)
  let (story, setStory) = React.useState(_ => None)
  let (isPaused, setIsPaused) = React.useState(_ => false)
  let (isBusy, setIsBusy) = React.useState(_ => false)
  let (showRequests, setShowRequests) = React.useState(_ => false)
  let (pollError, setPollError) = React.useState(_ => "")

  // Scenario 3 can stay in Monitoring, so the proxy's done flag is the main end signal
  let isDone = story->Option.mapOr(false, (s: story) => s.done || s.stage->isFinalStage)
  let storyPath = id =>
    GlobalVars.appendDashboardPath(~url=`${RevenueRecoverySidebarValues.simulatorStoryPath}/${id}`)

  let fetchScenarios = async () => {
    try {
      setScreenState(_ => PageLoaderWrapper.Loading)
      let json = await fetchDetails(getSimUrl("/sim/scenarios"))
      setScenarios(_ => json->getScenarios)
      setScreenState(_ => PageLoaderWrapper.Success)
    } catch {
    | _ => setScreenState(_ => PageLoaderWrapper.Custom)
    }
  }

  React.useEffect(() => {
    fetchScenarios()->ignore
    None
  }, [])

  // Poll the story every 4 s until it reaches an end state, or the visitor pauses
  React.useEffect(() => {
    switch storyIdFromUrl {
    | Some(id) if !isPaused && !isDone => {
        let cancelled = ref(false)
        let inFlight = ref(false)
        let poll = async () => {
          if !inFlight.contents {
            inFlight := true
            try {
              let json = await fetchDetails(getSimUrl(`/sim/story/${id}`))
              if !cancelled.contents {
                setStory(_ => Some(json->storyMapper))
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
  }, (storyIdFromUrl, isPaused, isDone))

  let onPlay = async () => {
    setIsBusy(_ => true)
    mixpanelEvent(~eventName="recovery_simulator_play")
    try {
      let body = [("scenario", selectedId->JSON.Encode.int)]->getJsonFromArrayOfJson
      let json = await updateDetails(getSimUrl("/sim/story/start"), body, Post)
      let newStory = json->storyMapper
      setStory(_ => Some(newStory))
      setIsPaused(_ => false)
      setPollError(_ => "")
      RescriptReactRouter.replace(storyPath(newStory.storyId))
    } catch {
    | exn =>
      showToast(
        ~message=exn->getSimErrorMessage(~default="Could not start the story."),
        ~toastType=ToastError,
      )
    }
    setIsBusy(_ => false)
  }

  // Paid in app and Report another failure: the proxy answers with the updated story
  let runAction = async (~action, ~eventName) => {
    switch storyIdFromUrl {
    | Some(id) =>
      setIsBusy(_ => true)
      mixpanelEvent(~eventName)
      try {
        let json = await updateDetails(
          getSimUrl(`/sim/story/${id}/${action}`),
          Dict.make()->JSON.Encode.object,
          Post,
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

  let onReset = () => {
    mixpanelEvent(~eventName="recovery_simulator_reset")
    setStory(_ => None)
    setIsPaused(_ => false)
    setShowRequests(_ => false)
    setPollError(_ => "")
    RescriptReactRouter.replace(
      GlobalVars.appendDashboardPath(~url=RevenueRecoverySidebarValues.simulatorStoryPath),
    )
  }

  let hasStory = storyIdFromUrl->Option.isSome
  let actions = story->Option.mapOr({paidInApp: false, reportAgain: false}, s => s.actions)
  let disabledUnless = condition => condition && !isBusy ? Button.Normal : Button.Disabled
  let warnings = switch story {
  | Some(s) =>
    [s.startError]
    ->Array.concat(s.warnings)
    ->Array.concat([pollError])
    ->Array.filter(isNonEmptyString)
  | None => [pollError]->Array.filter(isNonEmptyString)
  }
  let lastEvent = story->Option.flatMap(s => s.timeline->Array.at(-1))
  let activeActor = story->Option.flatMap(s => s.now->Option.map(now => now.actor))
  let stage = story->Option.mapOr(Starting, s => s.stage)

  <div className="flex flex-col gap-6">
    <BreadCrumbNavigation
      path=[{title: "Home", link: RevenueRecoverySidebarValues.homePath}]
      currentPageTitle="Invoice Story"
    />
    <PageUtils.PageHeading
      title="Invoice story"
      subTitle="Pick a scenario and press Play. The simulator plays the billing system; Rev Rec on the sandbox does the rest."
    />
    <PageLoaderWrapper
      screenState
      customUI={<NoDataFound
        message={`The simulator proxy is not reachable at ${getConfig().simUrl}. Start it (simulator/proxy) and refresh.`}
        renderType=NotFound
      />}>
      <div className="flex flex-col gap-6">
        <div className="flex flex-wrap gap-3 items-center">
          <Button
            text={hasStory ? "Play again" : "Play"}
            buttonType=Primary
            buttonSize=Medium
            leftIcon={CustomIcon(<Icon name="play" size=14 />)}
            buttonState={isBusy ? Loading : Normal}
            onClick={_ => onPlay()->ignore}
          />
          <Button
            text={isPaused ? "Resume polling" : "Pause polling"}
            buttonType=Secondary
            buttonSize=Medium
            leftIcon={CustomIcon(<Icon name={isPaused ? "play" : "pause"} size=14 />)}
            buttonState={disabledUnless(hasStory && !isDone)}
            onClick={_ => setIsPaused(prev => !prev)}
          />
          <Button
            text="Paid in app"
            buttonType=Secondary
            buttonSize=Medium
            buttonState={disabledUnless(actions.paidInApp)}
            onClick={_ =>
              runAction(~action="paid-in-app", ~eventName="recovery_simulator_paid_in_app")->ignore}
          />
          <Button
            text="Report another failure"
            buttonType=Secondary
            buttonSize=Medium
            buttonState={disabledUnless(actions.reportAgain)}
            onClick={_ =>
              runAction(
                ~action="report-again",
                ~eventName="recovery_simulator_report_again",
              )->ignore}
          />
          <Button
            text="Reset"
            buttonType=Secondary
            buttonSize=Medium
            buttonState={disabledUnless(hasStory)}
            onClick={_ => onReset()}
          />
          <Button
            text={showRequests ? "Hide requests" : "Show requests"}
            buttonType=Secondary
            buttonSize=Medium
            leftIcon={CustomIcon(<Icon name="code" size=14 />)}
            onClick={_ => setShowRequests(prev => !prev)}
          />
        </div>
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
        {switch story {
        | Some(s) =>
          <div
            className={`${cardStyle} flex flex-wrap gap-x-8 gap-y-2 ${body.md.medium} text-nd_gray-600`}>
            <span className={`${body.md.semibold} text-nd_gray-700`}>
              {`Scenario ${s.scenarioId->Int.toString}: ${s.scenarioTitle}`->React.string}
            </span>
            <span> {`Invoice ${s.invoiceId}`->React.string} </span>
            <RenderIf condition={s.recoveryId->isNonEmptyString}>
              <span> {`Payment ${s.recoveryId}`->React.string} </span>
            </RenderIf>
            <span className="flex gap-1">
              {"Started"->React.string}
              <Table.DateCell timestamp={s.startedAt} isCard=true />
            </span>
          </div>
        | None =>
          <RenderIf condition={!hasStory}>
            <ScenarioPicker scenarios selectedId setSelectedId />
          </RenderIf>
        }}
        <div className="grid grid-cols-1 xl:grid-cols-12 gap-6">
          <div className="xl:col-span-3 min-w-0">
            <StateStepper
              stage reached={story->Option.mapOr([false, false, false, false, false], reachedSteps)}
            />
          </div>
          <div className="xl:col-span-5 min-w-0">
            <FlowDiagram activeActor lastEvent />
          </div>
          <div className="xl:col-span-4 min-w-0 flex flex-col gap-6">
            {switch story {
            | Some(s) => <NowCard story=s />
            | None =>
              <div className={`${cardStyle} flex flex-col gap-2`}>
                <p className={`${body.lg.semibold} text-nd_gray-700`}> {"Now"->React.string} </p>
                <p className={`${body.md.medium} text-nd_gray-500`}>
                  {(
                    hasStory ? "Loading the story." : "Pick a scenario, then press Play."
                  )->React.string}
                </p>
              </div>
            }}
            <ExplainPanel lines={story->Option.mapOr([], s => s.explain)} />
          </div>
        </div>
        {switch story {
        | Some(s) if !(s.invoice->isEmptyDict) => <AttemptsSection story=s />
        | _ => React.null
        }}
        <RenderIf condition={showRequests}>
          <RequestsPanel requests={story->Option.mapOr([], s => s.requests)} />
        </RenderIf>
      </div>
    </PageLoaderWrapper>
  </div>
}
