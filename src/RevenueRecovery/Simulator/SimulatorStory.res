// Invoice story (simulator/REDESIGN-story.md and STORY-STEPS.md): the left form plays the
// merchant's billing system, like the checkout form on Orchestrator's "Try It Out" page. The right
// side is the product itself: the story as steps grouped by phase, then the real invoice page.
open SimulatorTypes
open SimulatorUtils
open SimulatorStoryHelper

// Faster polling while the billing system is still creating the invoice
let startingPollMs = 1000

// One window: on a wide screen the two columns fill the rest of the window, and only the story
// column scrolls inside. The page itself does not scroll.
@val @scope("window") external windowInnerWidth: float = "innerWidth"
let oneWindowMinWidth = 1280.0
// The columns' height: from their top (in the dashboard's own scroll box, which may be scrolled)
// to the bottom of the window, less a small gap
let columnsHeightFor: (Dom.element, float, float) => float = %raw(`function (el, gap, least) {
  var box = el.parentElement, scrolled = window.scrollY;
  while (box) {
    var style = getComputedStyle(box);
    if (/auto|scroll/.test(style.overflowY) && box.scrollHeight > box.clientHeight) {
      scrolled = box.scrollTop;
      break;
    }
    box = box.parentElement;
  }
  return Math.max(window.innerHeight - (el.getBoundingClientRect().top + scrolled) - gap, least);
}`)

// After Charge customer the hero form gives way to two columns: a 200 ms fade and rise, no bounce.
// "backwards", so no transform stays after it: a transform would trap the fixed "New retry" pill.
let storyEnterCss = "@keyframes simStoryEnter { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: none; } } .sim-story-enter > div { animation: simStoryEnter 200ms ease-out backwards; } @media (prefers-reduced-motion: reduce) { .sim-story-enter > div { animation: none; } }"

@react.component
let make = (~storyIdFromUrl: option<string>) => {
  open LogicUtils
  let simFetch = SimulatorApi.useSimFetch()
  let url = RescriptReactRouter.useUrl()
  // Watch mode (?mode=watch&preset=N, from Home's cards): no form; the story starts by itself with
  // the default card, hands over by itself, and a narration bar says each step
  let isWatch = url.search->getDictFromUrlSearchParams->Dict.get("mode") == Some("watch")
  let mixpanelEvent = MixpanelHook.useSendEvent()

  let (screenState, setScreenState) = React.useState(_ => PageLoaderWrapper.Loading)
  let (options, setOptions) = React.useState(_ => {
    presets: [],
    cards: [],
    currencies: [],
    processorRules: [],
  })
  let (form, setForm) = React.useState(_ => defaultForm)
  let (story, setStory) = React.useState(_ => None)
  let (isBusy, setIsBusy) = React.useState(_ => false)
  let (pollError, setPollError) = React.useState(_ => "")
  // An action that failed: a plain sentence, and the proxy's own words behind "?"
  let (actionError, setActionError) = React.useState(_ => None)
  let failed = (exn, ~text) => {
    let detail = exn->getSimErrorMessage(~default="")
    let text = switch exn->getSimErrorCode {
    // Every leased demo profile is in use (they free up when stories end)
    | "pool_busy" => "Every demo is in use right now. Try again in a few minutes."
    // The proxy's own refusals are written for people ("There is no earlier customer to reuse...")
    | "not_available" | "rate_limited" if detail->isNonEmptyString => detail
    | _ => text
    }
    setActionError(_ => Some((text, detail)))
  }
  // After a first charge the form comes back open on its story (a failed charge, New story)
  let (hasCharged, setHasCharged) = React.useState(_ => false)
  // The story handed to Rev Rec in this tab: the running view opens for it at once
  let (handedOverId, setHandedOverId) = React.useState(_ => "")
  let (drawerContent, setDrawerContent) = React.useState(_ => None)
  // The form values of a charge that is on its way, shown as step 1 before the proxy answers
  let (optimistic, setOptimistic) = React.useState(_ => None)
  // How many steps the viewer has allowed so far (the billing steps always show)
  let (revealLimit, setRevealLimit) = React.useState(_ => 0)
  let (autoPlay, setAutoPlay) = React.useState(_ => isWatch)
  let (showDiagram, setShowDiagram) = React.useState(_ => false)
  // The story whose values the form shows, so a reopened story fills the form once
  let formStoryId = React.useRef("")
  // The story started in this tab: its steps animate from step 1; a reopened story's do not
  let startedHereId = React.useRef("")

  // Scenario 3 can stay in Monitoring, so the proxy's done flag is the main end signal
  let isDone = story->Option.mapOr(false, storyHasEnded)
  let isStarting =
    story->Option.mapOr(optimistic->Option.isSome, (s: story) => s.stage == Starting && !s.done)
  // A watched story keeps ?mode=watch, so a reload goes on narrating
  let storyPath = id =>
    GlobalVars.appendDashboardPath(
      ~url=`${RevenueRecoverySidebarValues.simulatorStoryPath}/${id}${isWatch
          ? "?mode=watch"
          : ""}`,
    )

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
                      polledStory
                      ->SimulatorStorySteps.buildStoryItems(~maxRetries=None)
                      ->snd
                      ->Array.length
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
    // Leave the old story first, so its polling stops and its steps clear (watch mode has none,
    // and keeps its query)
    if !isWatch {
      RescriptReactRouter.replace(
        GlobalVars.appendDashboardPath(~url=RevenueRecoverySidebarValues.simulatorStoryPath),
      )
    }
    setStory(_ => None)
    setDrawerContent(_ => None)
    setRevealLimit(_ => 0)
    setOptimistic(_ => Some(form))
    setActionError(_ => None)
    setHasCharged(_ => true)
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
        exn->failed(~text="The billing system could not charge. Try again.")
      }
    }
    setIsBusy(_ => false)
  }

  // Watch mode starts the story by itself once the presets are in (once per visit)
  let watchStarted = React.useRef(false)
  React.useEffect(() => {
    if (
      isWatch &&
      screenState == PageLoaderWrapper.Success &&
      storyIdFromUrl->Option.isNone &&
      !watchStarted.current
    ) {
      watchStarted.current = true
      onCharge()->ignore
    }
    None
  }, (isWatch, screenState))

  // Customer pays in the app, Charge fails again and Cancel invoice: the proxy answers with the updated
  // story, and the steps the viewer caused show at once
  let runAction = async (~action, ~eventName, ~body=Dict.make(), ~failText) => {
    switch storyIdFromUrl {
    | Some(id) =>
      setIsBusy(_ => true)
      mixpanelEvent(~eventName)
      try {
        let json = await simFetch(
          ~path=`/sim/story/${id}/${action}`,
          ~method_=Post,
          ~body=body->JSON.Encode.object,
        )
        let updated = json->storyMapper
        setRevealLimit(_ =>
          updated->SimulatorStorySteps.buildStoryItems(~maxRetries=None)->snd->Array.length
        )
        if action == "handover" {
          setHandedOverId(_ => id)
        }
        setStory(_ => Some(updated))
        setActionError(_ => None)
      } catch {
      | exn => exn->failed(~text=failText)
      }
      setIsBusy(_ => false)
    | None => ()
    }
  }
  let onPaidInApp = () =>
    runAction(
      ~action="paid-in-app",
      ~eventName="recovery_simulator_paid_in_app",
      ~failText="The customer's payment did not go through. Try again.",
    )->ignore
  let onReportAgain = () =>
    runAction(
      ~action="report-again",
      ~eventName="recovery_simulator_report_again",
      ~failText="The billing system could not report the failure. Try again.",
    )->ignore
  // Pause and resume have their own calls (they skip the settings)
  let onPause = paused =>
    runAction(
      ~action=paused ? "pause" : "resume",
      ~eventName=paused ? "recovery_simulator_pause" : "recovery_simulator_resume",
      ~failText=paused
        ? "Rev Rec could not pause. Try again."
        : "Rev Rec could not resume. Try again.",
    )->ignore
  // Something the visitor makes happen: money back, a stolen card, a bank outage
  let onEvent = eventType =>
    runAction(
      ~action="event",
      ~eventName=`recovery_simulator_event_${eventType}`,
      ~body=Dict.fromArray([("type", eventType->JSON.Encode.string)]),
      ~failText="That did not happen. Try again.",
    )->ignore
  // Preset 10: Rev Rec leaves monitoring for this story's profile
  let onGoLive = () =>
    runAction(
      ~action="go-live",
      ~eventName="recovery_simulator_go_live",
      ~failText="Rev Rec could not turn on. Try again.",
    )->ignore

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

  // Pacing: the billing part shows by itself, then one press of "Let Rev Rec retry" and every
  // retry after it shows live until the invoice ends
  // The live setting wins over the billing connector's value read once at the start
  let connectorMaxRetries = SimulatorStorySteps.useMaxRetries(story)
  let maxRetries =
    story
    ->Option.flatMap(s => s.settings)
    ->Option.flatMap(settings => settings.currentMaxRetries)
    ->Option.orElse(connectorMaxRetries)
  let (_, items) = React.useMemo2(
    () =>
      story->Option.mapOr(("", []), story =>
        story->SimulatorStorySteps.buildStoryItems(~maxRetries)
      ),
    (story, maxRetries),
  )
  let itemTotal = items->Array.length
  let isFollowing = SimulatorStorySteps.isFollowingLive(~items, ~revealLimit, ~autoPlay)
  let visibleCount = SimulatorStorySteps.visibleItemCount(~items, ~revealLimit, ~autoPlay)
  let allShown = visibleCount == itemTotal
  // The outcome card is the last item once the story is done
  let isFinished = isDone && itemTotal > 0 && allShown
  // Watch mode follows the story: the newest step scrolls into view
  React.useEffect(() => {
    if isWatch && visibleCount > 0 {
      let timeoutId = setTimeout(() => SimulatorStorySteps.scrollToTail(), 400)
      Some(() => clearTimeout(timeoutId))
    } else {
      None
    }
  }, (isWatch, visibleCount))
  // The pause starts once the billing system has informed Rev Rec
  let hasReport = items->Array.some(item => item.phase >= 2)
  let hasRetries = items->Array.some(item => item.phase >= 3)
  // "Let Rev Rec retry" hands the failed invoice over (the proxy informs Rev Rec only then)
  let canHandover = story->Option.mapOr(false, s => s.awaitingHandover && s.canHandover)
  let showNext = canHandover && !isFinished
  // The model's pick for the next retry, for the model card beside the story
  let picks = SimulatorStorySteps.useModelPicks(
    ~storyId=story->Option.map(s => s.storyId),
    ~isLive=!isFinished,
  )
  let nextPick = switch story {
  | None => "Picked after the charge fails"
  | Some(s) if s->storyHasEnded => "None: the invoice has ended"
  // Paused: the proxy sends no next retry, and Rev Rec is not picking (C's smoke test)
  | Some(s)
    if s.settings->Option.mapOr(false, settings =>
      settings.currentPaused
    ) => "Paused · next retry waits"
  | Some(s) =>
    s.nextRetry
    ->Option.flatMap(next => picks->Dict.get(next.number->Int.toString))
    ->Option.getOr("Rev Rec is picking a time")
  }
  // Rev Rec has not booked its first retry yet
  // Never before the handover: until then Rev Rec has nothing to pick
  let isAwaitingHandover = story->Option.mapOr(false, s => s.awaitingHandover)
  let isWaitingForNext =
    isFollowing && hasReport && !hasRetries && !isFinished && !isAwaitingHandover
  let onNext = () =>
    runAction(
      ~action="handover",
      ~eventName="recovery_simulator_handover",
      ~failText="The invoice did not reach Rev Rec. Try again.",
    )->ignore
  // Auto-play hands over by itself
  React.useEffect(() => {
    if autoPlay && canHandover && !isBusy {
      onNext()
    }
    None
  }, (autoPlay, canHandover, isBusy))

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

  // Before the first charge the form is the page; a story (started here or opened by URL) shows
  // beside the summary card
  let hasStarted =
    storyIdFromUrl->Option.isSome || story->Option.isSome || optimistic->Option.isSome
  // The checkout owns the decline: after Pay the form stays while the billing system charges, then
  // shows the decline and "Pass it to Rev Rec"; the running view starts with the handover. Watch
  // mode hands over by itself and shows the running view at once.
  // Everything before the handover happens on the form: creating the invoice and the first charge
  // (Pay shows "Processing…"), then the decline and "Pass it to Rev Rec". The running view opens
  // only once Rev Rec has the invoice, or for a story that has ended; never in its "Starting" state.
  let isBeforeHandover = switch story {
  | None => optimistic->Option.isSome
  | Some(s) =>
    s.storyId != handedOverId &&
    !(s->storyHasEnded) &&
    !s.done &&
    (s.awaitingHandover || s.stage == Starting)
  }
  // The decline once the proxy waits for the handover (its first charge has failed): the reason
  // from the first charge's row, else a plain one, so the checkout never waits on a row's wording
  let declined = switch story {
  | Some(s) if isBeforeHandover && s.awaitingHandover =>
    s
    ->SimulatorStorySteps.firstDecline
    ->Option.orElse(Some(("The bank declined the charge.", form.card)))
  | Some(s) if isBeforeHandover => s->SimulatorStorySteps.firstDecline
  | _ => None
  }
  // A story that failed before Rev Rec got it (a start error, the proxy restarted) comes back to
  // the form with a plain line and Start over: never the running view's endless spinner
  let startFailed =
    story->Option.mapOr(false, s =>
      s.storyId != handedOverId &&
      s.recoveryId->isEmptyString &&
      (s.stage == StoryError || s.startError->isNonEmptyString)
    )
  // A story URL that is still loading shows "Loading the story…" in the running view's place
  let showForm = !isWatch && (!hasStarted || isBeforeHandover || startFailed)
  let columnsRef = React.useRef(Nullable.null)
  let (columnsHeight, setColumnsHeight) = React.useState(_ => None)
  // Measured once the columns are on the page (after the presets load), and on resize
  let isShown = hasStarted && screenState == PageLoaderWrapper.Success
  React.useEffect(() => {
    let measure = _ =>
      setColumnsHeight(_ =>
        switch columnsRef.current->Nullable.toOption {
        | Some(element) if windowInnerWidth >= oneWindowMinWidth =>
          Some(columnsHeightFor(element, 24.0, 420.0))
        | _ => None
        }
      )
    let timeoutId = setTimeout(() => measure(), 0)
    Window.addEventListener("resize", measure)
    Some(
      () => {
        clearTimeout(timeoutId)
        Window.removeEventListener("resize", measure)
      },
    )
  }, [isShown])
  let hasHistory = story->Option.mapOr(false, s => s.stageHistory->Array.length > 0)
  // Less common controls live in the header bar's menu; auto-play stays off until chosen
  let menuOptions = [
    Some((
      autoPlay ? "Turn auto-play off" : "Turn auto-play on",
      () => {
        // Turning auto-play off keeps the steps already on screen
        setRevealLimit(_ => visibleCount)
        setAutoPlay(prev => !prev)
      },
    )),
    hasHistory ? Some(("Invoice states", () => setDrawerContent(_ => Some(StateHistory)))) : None,
    story->Option.isSome
      ? Some((
          showDiagram ? "Hide sequence diagram" : "Show sequence diagram",
          () => setShowDiagram(prev => !prev),
        ))
      : None,
  ]->Array.filterMap(option => option)

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

  // A running story sits closer to the top bar: the control center's page wrapper has 32 px of top
  // padding, so the page moves up 24 px (the breadcrumb is then 8 px under the bar) and the status
  // bar is 12 px under the breadcrumb. Other pages keep the wrapper's spacing.
  <div className={`flex flex-col ${hasStarted ? "-mt-6 gap-3" : "gap-6"}`}>
    <BreadCrumbNavigation
      path=[{title: "Home", link: RevenueRecoverySidebarValues.homePath}]
      currentPageTitle={isWatch ? "Watch the simulation" : "Invoice Story"}
    />
    // A running story starts with its status bar; the title shows only before the charge
    {switch (hasStarted, isWatch) {
    | (true, _) => React.null
    | (false, true) =>
      <PageUtils.PageHeading
        title="Watch the simulation"
        subTitle="Rev Rec handles a failed invoice on its own. Pause at any step."
      />
    | (false, false) =>
      <PageUtils.PageHeading
        title="Invoice story"
        subTitle="Charge a customer. Watch Rev Rec handle the failed invoice, step by step."
      />
    }}
    {switch actionError {
    | Some((text, detail)) =>
      <SimulatorStorySteps.ActionNotice text detail onClose={() => setActionError(_ => None)} />
    | None => React.null
    }}
    <PageLoaderWrapper
      screenState
      customUI={<NoDataFound
        message={`The simulator proxy is not reachable at ${getConfig().simUrl}. Start it (simulator/proxy) and refresh.`}
        renderType=NotFound
      />}>
      {if !hasStarted && isWatch {
        <div className={`${cardStyle} p-5`}>
          <p className={`${Typography.body.md.medium} text-nd_gray-600`}>
            {"Starting the story…"->React.string}
          </p>
        </div>
      } else if showForm {
        // Until the handover the form is the page, across the full content width
        <BillingSystemForm
          options
          form
          setForm
          // Opened on a story (?preset=N) or charged: the checkout is open at once
          startUnlocked={hasCharged ||
          storyIdFromUrl->Option.isSome ||
          url.search->getDictFromUrlSearchParams->Dict.get("preset")->Option.isSome}
          // Charging until the first charge declines
          isBusy={isBusy || (isBeforeHandover && declined->Option.isNone)}
          isLocked={isBusy || isStarting || isBeforeHandover}
          onCharge={() => onCharge()->ignore}
          ?declined
          // The handover: Rev Rec gets the invoice, and the running view starts
          onHandover=onNext
          isHandingOver=isBusy
          onStartOver
          startFailed
        />
      } else {
        <div className="sim-story-enter flex flex-col gap-4">
          <style> {storyEnterCss->React.string} </style>
          <RenderIf condition=isWatch>
            <SimulatorStorySteps.WatchBar
              story
              items
              visibleCount
              isFinished
              isBusy
              onPause
              // The form, open on this story
              onTryIt={() => {
                let preset = story->Option.mapOr(form.preset, s => s.scenarioId)
                setAutoPlay(_ => false)
                onStartOver()
                RescriptReactRouter.replace(
                  GlobalVars.appendDashboardPath(
                    ~url=`${RevenueRecoverySidebarValues.simulatorStoryPath}?preset=${preset->Int.toString}`,
                  ),
                )
              }}
            />
          </RenderIf>
          // Row 1, the status bar: the invoice's state, amount, retries, Pause, page, menu
          <div>
            <SimulatorStorySteps.InvoiceHeaderBar
              story
              form={optimistic->Option.orElse(story->Option.flatMap(s => s.form))}
              menuOptions
              isBusy
              // In watch mode the narration bar has Pause, and Try it yourself stands for New story
              onPause=?{isWatch ? None : Some(onPause)}
              onNewStory=?{isWatch ? None : Some(onStartOver)}
              // The live events (none in watch mode: the story plays by itself)
              eventsMenu={isWatch
                ? React.null
                : <EventsMenu
                    story
                    isBusy
                    onPaidInApp
                    onReportAgain
                    onEvent
                    onCustomerCancels={() =>
                      runAction(
                        ~action="cancel",
                        ~eventName="recovery_simulator_customer_cancels",
                        ~body=Dict.fromArray([("by", "customer"->JSON.Encode.string)]),
                        ~failText="The subscription was not cancelled.",
                      )->ignore}
                  />}
            />
          </div>
          // Row 2, the star row: C's Smart model box, full width
          <SimulatorModelBox
            firstCharge=form.firstCharge
            next=nextPick
            ?story
            // A new charged retry flips the hero to Approved or Declined
            retries={items->Array.flatMap(item => item.retries)}
          />
          // Row 3, full width: the step happening now, how Rev Rec picked the retry, the timeline.
          // It scrolls inside the window's height.
          <div
            ref={ReactDOM.Ref.domRef(columnsRef)}
            className="w-full xl:overflow-hidden"
            style=?{columnsHeight->Option.map(height => {
              JsxDOMStyle.height: `${height->Float.toString}px`,
            })}>
            <AddDataAttributes attributes=[("data-story-scroll", "true")]>
              <div
                className="w-full min-w-0 flex flex-col gap-8 xl:h-full xl:overflow-y-auto xl:pr-1">
                {warnings
                ->Array.mapWithIndex((warning, index) =>
                  <AlertV2Binding
                    key={index->Int.toString}
                    alertType=Warning
                    slot={{
                      slot: <Icon name="nd-toast-warning" size=20 className="text-nd_yellow-500" />,
                    }}
                    description=warning
                  />
                )
                ->React.array}
                {switch story->Option.flatMap(s => s.goLive->Option.map(goLive => (s, goLive))) {
                | Some((s, goLive)) =>
                  <SimulatorStorySteps.BacklogPanel story=s goLive isBusy onGoLive />
                | None => React.null
                }}
                // Preset 8's "One invoice at a time" panel is not shown (user, 28 Oct): its rows say
                // it (SimulatorStorySteps.QueuePanel stays for when it comes back)
                <SimulatorStorySteps.StoryView
                  story
                  optimistic
                  items
                  visibleCount
                  isFinished
                  showNext
                  isWaitingForNext
                  revealDelays
                  showDiagram
                  // Customer pays in the app and Charge fails again live in the summary card
                  inlineActions=[]
                  isBusy
                  onNext
                  onRowClick={row => setDrawerContent(_ => Some(StepDetails(row)))}
                  onWaitingClick={() => setDrawerContent(_ => Some(WaitingDetails))}
                  onRetryClick={retry =>
                    setDrawerContent(_ => Some(
                      RetryDetails(retry.booking, retry.charge, retry.number),
                    ))}
                  // Watch mode: the narration bar has Pause and guides the eye
                  onPause=?{isWatch ? None : Some(onPause)}
                  guided={!isWatch}
                />
              </div>
            </AddDataAttributes>
          </div>
        </div>
      }}
    </PageLoaderWrapper>
    <SimulatorStoryDrawer.ExplainDrawer
      content=drawerContent story onClose={() => setDrawerContent(_ => None)}
    />
  </div>
}
