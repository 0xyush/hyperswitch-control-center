// Learn Rev Rec v2 (simulator/LEARN-V2.md): a path of eight levels, one per Rev Rec feature. A
// level is a five-pane lesson: the idea, how it works (a flow), the real number, two checks.
open SimulatorTourTypes
open SimulatorTourUtils
open Typography

let totalLevels = levels->Array.length

module ProgressBar = {
  @react.component
  let make = (~learnedCount) => {
    let percent = learnedCount * 100 / totalLevels
    <div className="flex flex-col gap-2 w-full">
      <div className={`flex justify-between ${body.md.semibold} text-nd_gray-700`}>
        <span>
          {`${learnedCount->Int.toString} of ${totalLevels->Int.toString} learned`->React.string}
        </span>
        <RenderIf condition={learnedCount == totalLevels}>
          <span className="text-nd_green-600"> {"All done"->React.string} </span>
        </RenderIf>
      </div>
      <div className="w-full h-2 rounded-full bg-nd_gray-150 overflow-hidden">
        <div
          className="h-2 rounded-full bg-nd_green-400 transition-all duration-500"
          style={width: `${percent->Int.toString}%`}
        />
      </div>
    </div>
  }
}

type circleState = Learned | Current | Open

// The level circle, in the stepper look: green with a check once learned, blue ring for the next one
module LevelCircle = {
  @react.component
  let make = (~state, ~icon, ~size=56) => {
    let (circleClass, iconClass) = switch state {
    | Learned => ("bg-nd_green-400 border-nd_green-400", "text-white")
    | Current => (
        "bg-nd_primary_blue-50 border-nd_primary_blue-450 ring-4 ring-nd_primary_blue-100",
        "text-nd_primary_blue-450",
      )
    | Open => ("bg-white border-nd_gray-200", "text-nd_gray-500")
    }
    <div
      className={`relative z-10 shrink-0 flex items-center justify-center rounded-full border-2 ${circleClass}`}
      style={width: `${size->Int.toString}px`, height: `${size->Int.toString}px`}>
      <Icon name={state == Learned ? "nd-check" : icon} size={size * 2 / 5} className=iconClass />
    </div>
  }
}

// The level sections on the page (the lessons themselves are C's)
let levelSections = [("The basics", 1, 5), ("Special cases", 6, 8), ("From the workshops", 9, 14)]

// One level as a card in the page's grid: number and icon, title, one-line hook, a status chip
// (Learned, Next, or Planned while the engine does not do it yet) and one button
module LevelCard = {
  @react.component
  let make = (~level: level, ~state, ~onOpen) => {
    let chip = switch (state, level.planned) {
    | (Learned, _) => Some(("Learned", "bg-nd_green-50 text-nd_green-600"))
    | (Current, _) => Some(("Next", "bg-nd_primary_blue-50 text-nd_primary_blue-600"))
    | (Open, Some(_)) => Some(("Planned", "bg-nd_gray-150 text-nd_gray-600"))
    | (Open, None) => None
    }
    <div
      className={`h-full flex flex-col gap-3 rounded-xl border bg-white p-5 cursor-pointer hover:border-nd_gray-300 ${state ==
          Current
          ? "border-nd_primary_blue-450 ring-1 ring-nd_primary_blue-450"
          : "border-nd_gray-200"}`}
      onClick={_ => onOpen()}>
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-3">
          <LevelCircle state icon=level.icon size=40 />
          <span className={`${body.sm.semibold} text-nd_gray-500`}>
            {`Level ${level.id->Int.toString}`->React.string}
          </span>
        </div>
        {switch chip {
        | Some((text, chipClass)) =>
          <span className={`shrink-0 rounded px-1.5 py-0.5 ${body.xs.semibold} ${chipClass}`}>
            {text->React.string}
          </span>
        | None => React.null
        }}
      </div>
      <div className="flex flex-col gap-1">
        <p className={`${body.lg.semibold} text-nd_gray-800`}> {level.title->React.string} </p>
        <p className={`${body.md.medium} text-nd_gray-500`}> {level.hook->React.string} </p>
      </div>
      <div className="mt-auto pt-1">
        <Button
          text={state == Learned ? "Review" : "Start"}
          buttonType={state == Current ? Primary : Secondary}
          buttonSize=Small
          onClick={_ => onOpen()}
        />
      </div>
    </div>
  }
}

// Level 9: display-only features, each a one-liner you can open
module MoreFeatures = {
  @react.component
  let make = (~configState) => {
    let (openTitle, setOpenTitle) = React.useState(_ => "")
    <div className="flex items-start gap-4 p-1">
      <div
        className="shrink-0 flex items-center justify-center rounded-full w-14 h-14 border-2 border-dashed border-nd_gray-200 bg-white">
        <Icon name="nd-plugin" size=22 className="text-nd_gray-400" />
      </div>
      <div className="flex flex-col flex-1 min-w-0 gap-2">
        <div className="flex flex-col">
          <span className={`${body.sm.medium} text-nd_gray-400`}> {"Extra"->React.string} </span>
          <span className={`${body.lg.semibold} text-nd_gray-800`}>
            {"More features"->React.string}
          </span>
          <span className={`${body.md.medium} text-nd_gray-500`}>
            {"Explained here, not run on the demo engine"->React.string}
          </span>
        </div>
        <div
          className="flex flex-col divide-y divide-nd_gray-150 border border-nd_gray-150 rounded-lg">
          {moreFeatures
          ->Array.map(feature => {
            let isOpen = openTitle == feature.title
            <div key=feature.title className="flex flex-col px-4">
              <div
                className="flex items-center justify-between gap-3 py-3 cursor-pointer"
                onClick={_ => setOpenTitle(_ => isOpen ? "" : feature.title)}>
                <span className={`${body.md.semibold} text-nd_gray-700`}>
                  {feature.title->React.string}
                </span>
                <Icon
                  name={isOpen ? "nd-angle-up" : "nd-angle-down"}
                  size=14
                  className="text-nd_gray-400"
                />
              </div>
              <RenderIf condition=isOpen>
                <div className="flex flex-wrap items-center gap-2 pb-3">
                  <span className={`${body.md.medium} text-nd_gray-500`}>
                    {feature.line->React.string}
                  </span>
                  {switch (feature.setting, configState) {
                  | (Some(key), SimulatorTypes.ConfigLoaded(config)) =>
                    let (value, caption) = config->settingValue(key)
                    <span className={`${body.md.semibold} text-nd_gray-700`}>
                      {`${caption}: ${value}`->React.string}
                    </span>
                  | _ => React.null
                  }}
                </div>
              </RenderIf>
            </div>
          })
          ->React.array}
        </div>
      </div>
    </div>
  }
}

let lessonPanes = [
  (IdeaPane, "Idea"),
  (FlowPane, "How it works"),
  (NumberPane, "In numbers"),
  (FirstCheck, "Check 1"),
  (SecondCheck, "Check 2"),
]

// Pane steps at the top of the card, in the look of the dashboard's step indicators: the current
// step filled, a done step outlined with a check. Five equal columns, the label under its circle,
// connectors one colour and one length between the circles.
module PaneSteps = {
  @react.component
  let make = (~pane) => {
    let currentIndex = lessonPanes->Array.findIndex(((p, _)) => p == pane)
    <AddDataAttributes attributes=[("data-learn", "stepper")]>
      <div className="grid grid-cols-5 w-full">
        {lessonPanes
        ->Array.mapWithIndex(((_, name), index) => {
          let isDone = index < currentIndex
          let isCurrent = index == currentIndex
          let circleClass = if isCurrent {
            "bg-nd_primary_blue-450 border-nd_primary_blue-450 text-white"
          } else if isDone {
            "bg-white border-nd_primary_blue-450 text-nd_primary_blue-450"
          } else {
            "bg-white border-nd_gray-200 text-nd_gray-400"
          }
          let labelClass = if isCurrent {
            `${body.sm.semibold} text-nd_gray-800`
          } else {
            `${body.sm.medium} ${isDone ? "text-nd_gray-600" : "text-nd_gray-400"}`
          }
          <div key=name className="relative flex flex-col items-center gap-2">
            // From 8 px after the previous circle to 8 px before this one
            <RenderIf condition={index > 0}>
              <AddDataAttributes attributes=[("data-learn", "step-connector")]>
                <div
                  className="absolute top-4 left-[calc(-50%_+_24px)] right-[calc(50%_+_24px)] h-px bg-nd_gray-200"
                />
              </AddDataAttributes>
            </RenderIf>
            <AddDataAttributes attributes=[("data-learn", "step-circle")]>
              <div
                className={`flex items-center justify-center rounded-full w-8 h-8 border ${body.sm.semibold} ${circleClass}`}>
                {isDone
                  ? <Icon name="nd-check" size=14 className="text-nd_primary_blue-450" />
                  : (index + 1)->Int.toString->React.string}
              </div>
            </AddDataAttributes>
            <AddDataAttributes attributes=[("data-learn", "step-label")]>
              <span className={`whitespace-nowrap ${labelClass}`}> {name->React.string} </span>
            </AddDataAttributes>
          </div>
        })
        ->React.array}
      </div>
    </AddDataAttributes>
  }
}

// Pane 3: the real number in big type and one line of context
// A grey status chip: "Planned" (not on the engine yet) or "Being checked"
module StatusChip = {
  @react.component
  let make = (~text) =>
    <span
      className={`shrink-0 rounded px-1.5 py-0.5 border bg-nd_gray-50 text-nd_gray-600 border-nd_gray-200 ${body.xs.semibold}`}>
      {text->React.string}
    </span>
}

module NumberBlock = {
  @react.component
  let make = (
    ~number: levelNumber,
    ~planned: option<string>,
    ~engineNote: option<string>,
    ~configState,
  ) => {
    let (big, line) = switch number {
    | Fixed(big, line) => (big, line)
    | FromConfig(read) =>
      switch configState {
      | SimulatorTypes.ConfigLoading => numberWhileLoading
      | ConfigFailed => numberNotAvailable
      | ConfigLoaded(config) => config->read
      }
    }
    <div className="flex flex-col items-center gap-3 text-center">
      <span className={`${display.md.semibold} text-nd_gray-800`}> {big->React.string} </span>
      <span className={`${body.lg.medium} text-nd_gray-600`}> {line->React.string} </span>
      {[("Planned", planned), ("On this engine", engineNote)]
      ->Array.filterMap(((chip, line)) => line->Option.map(line => (chip, line)))
      ->Array.map(((chip, line)) =>
        <span key=chip className={`flex items-center gap-2 ${body.md.medium} text-nd_gray-500`}>
          <StatusChip text=chip />
          {line->React.string}
        </span>
      )
      ->React.array}
    </div>
  }
}

// One question. A wrong pick allows one more try; after a second wrong pick the right choice is
// marked. picks are the choices clicked, in order.
let isCheckPending = (check: check) => check.pending->Option.getOr(false)
let isCheckRight = (check: check, picks) =>
  check->isCheckPending || picks->Array.includes(check.answer)
let isCheckOver = (check: check, picks) => check->isCheckRight(picks) || picks->Array.length >= 2

module CheckChoices = {
  @react.component
  let make = (~check: check, ~picks: array<int>, ~onPick) => {
    let isRight = check->isCheckRight(picks)
    let isOver = check->isCheckOver(picks)
    check->isCheckPending
      ? <div className="w-full flex flex-col items-center gap-3 text-center">
          <StatusChip text="Being checked" />
          <p className={`${body.lg.medium} text-nd_gray-600`}>
            {"This question comes once the engine's behaviour is confirmed."->React.string}
          </p>
        </div>
      : <div className="w-full flex flex-col gap-2">
          <p className={`${body.lg.semibold} text-nd_gray-800`}> {check.question->React.string} </p>
          {check.choices
          ->Array.mapWithIndex((choice, index) => {
            let isAnswer = index == check.answer
            let isWrongPick = picks->Array.includes(index) && !isAnswer
            let stateClass = if isAnswer && isRight {
              "border-nd_green-400 bg-nd_green-50 text-nd_green-600"
            } else if isAnswer && isOver {
              // Shown after two wrong picks
              "border-nd_green-400 border-dashed text-nd_green-600"
            } else if isWrongPick {
              "border-nd_red-400 bg-nd_red-50 text-nd_red-600"
            } else {
              "border-nd_gray-200 text-nd_gray-700 hover:border-nd_primary_blue-450"
            }
            let canPick = !isOver && !isWrongPick
            <div
              key=choice
              className={`flex items-center justify-between gap-3 rounded-lg border px-4 py-2.5 ${body.md.semibold} ${stateClass} ${canPick
                  ? "cursor-pointer"
                  : "pointer-events-none"}`}
              onClick={_ => onPick(index)}>
              <span> {choice->React.string} </span>
              {if isAnswer && isOver {
                <Icon name="nd-check-circle" size=18 className="text-nd_green-400" />
              } else if isWrongPick {
                <Icon name="nd-cross" size=14 className="text-nd_red-500" />
              } else {
                React.null
              }}
            </div>
          })
          ->React.array}
          // The line keeps its height before an answer, so answering does not move the choices
          {if isRight {
            <p className={`h-5 ${body.md.semibold} text-nd_green-600`}>
              {(picks->Array.length == 1 ? "Right." : "Right on the second try.")->React.string}
            </p>
          } else if isOver {
            <p className={`h-5 ${body.md.medium} text-nd_gray-600`}>
              {"Not this time. The right answer is marked."->React.string}
            </p>
          } else if picks->Array.length == 1 {
            <p className={`h-5 ${body.md.medium} text-nd_red-600`}>
              {"Not quite. One more try."->React.string}
            </p>
          } else {
            <p className="h-5" />
          }}
        </div>
  }
}

module LevelModal = {
  @react.component
  let make = (~level: level, ~tryLink, ~configState, ~isLearned, ~onLearned, ~onClose) => {
    let (pane, setPane) = React.useState(_ => IdeaPane)
    let (isFullscreen, setIsFullscreen) = React.useState(_ => false)

    // Esc leaves fullscreen first; the Modal's own Esc (close) is off while fullscreen
    React.useEffect(() => {
      let onKeyUp = event => {
        open ReactEvent.Keyboard
        if event->key === "Escape" || event->keyCode === 27 {
          setIsFullscreen(_ => false)
        }
      }
      if isFullscreen {
        Window.addEventListener("keyup", onKeyUp)
      }
      Some(() => Window.removeEventListener("keyup", onKeyUp))
    }, [isFullscreen])
    let ((firstPicks, secondPicks), setPicks) = React.useState(_ => ([], []))
    let (firstCheck, secondCheck) = level.checks
    let paneIndex = lessonPanes->Array.findIndex(((p, _)) => p == pane)
    let paneAt = index => lessonPanes->Array.get(index)->Option.mapOr(pane, ((p, _)) => p)

    // The level is learned when both checks are right
    let onPick = (~isFirst, index) => {
      let (nextFirst, nextSecond) = isFirst
        ? (firstPicks->Array.concat([index]), secondPicks)
        : (firstPicks, secondPicks->Array.concat([index]))
      setPicks(_ => (nextFirst, nextSecond))
      if firstCheck->isCheckRight(nextFirst) && secondCheck->isCheckRight(nextSecond) {
        onLearned(level.id)
      }
    }
    let goNext = () => setPane(_ => paneAt(paneIndex + 1))
    let goBack = () => setPane(_ => paneAt(paneIndex - 1))
    // A check pane lets you go on once it is answered (or the level is learned already)
    let canGoOn = switch pane {
    | FirstCheck => isLearned || firstCheck->isCheckOver(firstPicks)
    | SecondCheck => isLearned || secondCheck->isCheckOver(secondPicks)
    | _ => true
    }
    let paneContent = lessonPane =>
      switch lessonPane {
      | IdeaPane =>
        <div className="flex flex-col items-center gap-4 text-center">
          <AddDataAttributes attributes=[("data-learn", "badge")]>
            <div
              className="flex items-center justify-center rounded-full w-24 h-24 bg-nd_primary_blue-50">
              <Icon name=level.icon size=44 className="text-nd_primary_blue-450" />
            </div>
          </AddDataAttributes>
          <AddDataAttributes attributes=[("data-learn", "headline")]>
            <p
              className="max-w-[560px] line-clamp-2 text-fs-22 leading-32 font-semibold text-nd_gray-800">
              {level.idea->React.string}
            </p>
          </AddDataAttributes>
        </div>
      | FlowPane =>
        <div className="w-full h-full">
          <SimulatorLessonFlow flow=level.flow isActive={pane == FlowPane} isFullscreen />
        </div>
      | NumberPane =>
        <div className="w-full">
          <NumberBlock
            number=level.number planned=level.planned engineNote=level.engineNote configState
          />
        </div>
      // DOM roots, so the audit attribute lands on an element
      | FirstCheck =>
        <div className="w-full max-w-2xl">
          <CheckChoices
            check=firstCheck picks=firstPicks onPick={index => onPick(~isFirst=true, index)}
          />
        </div>
      | SecondCheck =>
        <div className="w-full max-w-2xl">
          <CheckChoices
            check=secondCheck picks=secondPicks onPick={index => onPick(~isFirst=false, index)}
          />
        </div>
      }

    <Modal
      showModal=true
      setShowModal={_ => onClose()}
      closeOnOutsideClick={!isFullscreen}
      modalHeading=level.title
      modalHeadingDescription={`Level ${level.id->Int.toString} of ${totalLevels->Int.toString}`}
      // 92vw x 90vh (at most 1400 px wide), or the whole window in fullscreen
      modalClass={isFullscreen
        ? "w-screen max-w-none !rounded-none !border-0 flex flex-col"
        : "w-[92vw] max-w-[1400px] mx-auto my-auto flex flex-col"}
      customHeight={isFullscreen ? "h-screen" : "h-[90vh]"}
      rightHeading={<AddDataAttributes attributes=[("data-learn", "fullscreen")]>
        <button
          type_="button"
          title={isFullscreen ? "Exit fullscreen (Esc)" : "Fullscreen"}
          ariaLabel={isFullscreen ? "Exit fullscreen" : "Fullscreen"}
          className="mr-4 flex items-center justify-center w-8 h-8 rounded-md text-nd_gray-600 hover:bg-nd_gray-50"
          onClick={_ => setIsFullscreen(prev => !prev)}>
          <Icon name={isFullscreen ? "compress-alt" : "expand-alt"} size=16 />
        </button>
      </AddDataAttributes>}
      headingClass="!p-6"
      childClass="flex-1 min-h-0 flex flex-col px-6 pt-4 pb-6">
      <div className="flex-1 min-h-0 flex flex-col gap-6">
        <PaneSteps pane />
        // The panes fill the card between the stepper and the footer, so the footer never moves.
        // All five panes stay mounted, stacked: the flow is built once when the card opens, and
        // Next or Back only fades the panes (180 ms) with an 8 px slide, the new one in from its
        // side and the old one out the other way. Hidden panes take no clicks.
        <AddDataAttributes attributes=[("data-learn", "pane")]>
          <div className="relative flex-1 min-h-0">
            {lessonPanes
            ->Array.mapWithIndex(((lessonPane, name), index) => {
              let isCurrent = index == paneIndex
              let rest: FramerMotion.animate = {
                opacity: isCurrent ? 1.0 : 0.0,
                x: isCurrent ? 0 : index > paneIndex ? 8 : -8,
              }
              let content = lessonPane->paneContent
              <AddDataAttributes
                key=name attributes=[("data-learn", isCurrent ? "pane-current" : "pane-hidden")]>
                <FramerMotion.Motion.Div
                  initial=rest
                  animate=rest
                  transition={{duration: 0.18, ease: "easeInOut"}}
                  className={`absolute inset-0 flex flex-col items-center justify-center ${isCurrent
                      ? ""
                      : "pointer-events-none"}`}>
                  // Always wrapped, so a pane keeps its content (and its flow) when it shows
                  <AddDataAttributes
                    attributes=[("data-learn", isCurrent ? "block" : "block-hidden")]>
                    content
                  </AddDataAttributes>
                </FramerMotion.Motion.Div>
              </AddDataAttributes>
            })
            ->React.array}
          </div>
        </AddDataAttributes>
        <AddDataAttributes attributes=[("data-learn", "footer")]>
          <div className="flex items-center justify-between gap-3 border-t border-nd_gray-150 pt-4">
            // "Try it" on the last pane only, when the level has a preset; the empty span keeps
            // the buttons on the right
            {switch (pane, tryLink) {
            | (SecondCheck, Some((tryText, tryUrl))) =>
              <span
                className={`cursor-pointer text-nd_primary_blue-450 hover:underline ${body.md.semibold}`}
                onClick={_ =>
                  RescriptReactRouter.push(GlobalVars.appendDashboardPath(~url=tryUrl))}>
                {tryText->React.string}
              </span>
            | _ => <span />
            }}
            <div className="flex items-center gap-3">
              <RenderIf condition={pane != IdeaPane}>
                <Button text="Back" buttonType=Secondary buttonSize=Small onClick={_ => goBack()} />
              </RenderIf>
              {pane == SecondCheck
                ? <Button
                    text="Done"
                    buttonType=Primary
                    buttonSize=Small
                    buttonState={canGoOn ? Normal : Disabled}
                    onClick={_ => onClose()}
                  />
                : <Button
                    text="Next"
                    buttonType=Primary
                    buttonSize=Small
                    buttonState={canGoOn ? Normal : Disabled}
                    onClick={_ => goNext()}
                  />}
            </div>
          </div>
        </AddDataAttributes>
      </div>
    </Modal>
  }
}

@react.component
let make = () => {
  open APIUtils
  open LogicUtils
  let getURL = useGetURL()
  let fetchDetails = useGetMethod(~showErrorToast=false)
  let {profileId} = React.useContext(UserInfoProvider.defaultContext).getCommonSessionDetails()
  let (configState, setConfigState) = React.useState(_ => SimulatorTypes.ConfigLoading)
  let (learned, setLearned) = React.useState(_ => readLearned())
  let (openLevel, setOpenLevel) = React.useState(_ => None)
  let simFetch = SimulatorApi.useSimFetch()
  // Level id -> story preset, for the levels whose preset is tagged in GET /sim/presets
  let (levelPresets, setLevelPresets) = React.useState(_ => Dict.make())

  React.useEffect(() => {
    let read = async () =>
      try {
        let json = await simFetch(~path="/sim/presets", ~method_=Get)
        setLevelPresets(_ => json->levelPresetsMapper)
      } catch {
      | _ => ()
      }
    read()->ignore
    None
  }, [])

  // The same reads as Configuration Details: the profile, its billing connector, and that connector
  let fetchConfig = async () => {
    try {
      setConfigState(_ => ConfigLoading)
      let connectorListUrl = getURL(~entityName=V2(V2_CONNECTOR), ~methodType=Get)
      let profileUrl = getURL(
        ~entityName=V2(BUSINESS_PROFILE),
        ~methodType=Get,
        ~id=Some(profileId),
      )
      let (connectorList, profile) = await Promise.all2((
        fetchDetails(connectorListUrl, ~version=V2),
        fetchDetails(profileUrl, ~version=V2),
      ))
      let billingConnectorId =
        connectorList
        ->getArrayFromJson([])
        ->Array.map(getDictFromJsonObject)
        ->Array.find(connector => connector->getString("connector_type", "") == "billing_processor")
        ->Option.mapOr("", connector => connector->getString("id", ""))
      let billingConnector = if billingConnectorId->isNonEmptyString {
        let connectorUrl = getURL(
          ~entityName=V2(V2_CONNECTOR),
          ~methodType=Get,
          ~id=Some(billingConnectorId),
        )
        await fetchDetails(connectorUrl, ~version=V2)
      } else {
        JSON.Encode.null
      }
      setConfigState(_ => ConfigLoaded(
        getRevRecConfig(
          ~billingConnector=billingConnector->getDictFromJsonObject,
          ~profile=profile->getDictFromJsonObject,
        ),
      ))
    } catch {
    | _ => setConfigState(_ => ConfigFailed)
    }
  }

  React.useEffect(() => {
    fetchConfig()->ignore
    None
  }, [profileId])

  let onLearned = id =>
    if !(learned->Array.includes(id)) {
      let next = learned->Array.concat([id])
      saveLearned(next)
      setLearned(_ => next)
    }

  let learnedCount = levels->Array.filter(level => learned->Array.includes(level.id))->Array.length
  // The first level not learned yet gets the blue ring
  let currentId =
    levels->Array.find(level => !(learned->Array.includes(level.id)))->Option.mapOr(0, l => l.id)

  <div className="flex flex-col gap-8">
    <BreadCrumbNavigation
      path=[{title: "Home", link: RevenueRecoverySidebarValues.homePath}]
      currentPageTitle="Learn Rev Rec"
    />
    <div className="flex items-start justify-between gap-4">
      <PageUtils.PageHeading title="Learn Rev Rec" subTitle="Fourteen short levels." />
      <SimulatorGlossary.OpenButton />
    </div>
    <ProgressBar learnedCount />
    <RenderIf condition={configState == SimulatorTypes.ConfigFailed}>
      <div>
        <AlertV2Binding
          alertType=Warning
          slot={{slot: <Icon name="nd-toast-warning" size=20 className="text-nd_yellow-500" />}}
          description="The demo engine's settings could not be read right now."
        />
      </div>
    </RenderIf>
    <div className="flex flex-col gap-8 w-full">
      {levelSections
      ->Array.map(((title, first, last)) =>
        <section key=title className="flex flex-col gap-3">
          <p className={`${body.sm.semibold} uppercase tracking-wide text-nd_gray-500`}>
            {title->React.string}
          </p>
          <div className="grid grid-cols-1 lg:grid-cols-2 xl:grid-cols-3 gap-4">
            {levels
            ->Array.filter(level => level.id >= first && level.id <= last)
            ->Array.map(level => {
              let state = if learned->Array.includes(level.id) {
                Learned
              } else if level.id == currentId {
                Current
              } else {
                Open
              }
              <LevelCard
                key={level.id->Int.toString}
                level
                state
                onOpen={() => setOpenLevel(_ => Some(level))}
              />
            })
            ->React.array}
          </div>
        </section>
      )
      ->React.array}
      <div className="border-t border-dashed border-nd_gray-200" />
      <MoreFeatures configState />
    </div>
    {switch openLevel {
    | Some(level) =>
      <LevelModal
        key={level.id->Int.toString}
        level
        tryLink={level.tryTarget->tryLink(~levelId=level.id, ~levelPresets)}
        configState
        isLearned={learned->Array.includes(level.id)}
        onLearned
        onClose={() => setOpenLevel(_ => None)}
      />
    | None => React.null
    }}
  </div>
}
