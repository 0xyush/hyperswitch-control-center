// Learn Rev Rec (UX-PASS-2 section B): a path of eight levels, one per Rev Rec feature.
// A level opens a card with three panes: the idea, the real value from the sandbox, one question.
open SimulatorTourTypes
open SimulatorTourUtils
open Typography

let totalLevels = levels->Array.length

module Chip = {
  @react.component
  let make = (~text, ~colorClass) =>
    <span
      className={`shrink-0 w-fit rounded px-1.5 py-0.5 border whitespace-nowrap ${body.xs.semibold} ${colorClass}`}>
      {text->React.string}
    </span>
}

module SourceChip = {
  @react.component
  let make = (~source) => {
    let (text, colorClass) = source->SimulatorUtils.sourceLabel
    <Chip text colorClass />
  }
}

module ProgressBar = {
  @react.component
  let make = (~learnedCount) => {
    let percent = learnedCount * 100 / totalLevels
    <div className="flex flex-col gap-2 w-full max-w-2xl">
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
  let make = (~state, ~icon) => {
    let (circleClass, iconClass) = switch state {
    | Learned => ("bg-nd_green-400 border-nd_green-400", "text-white")
    | Current => (
        "bg-nd_primary_blue-50 border-nd_primary_blue-450 ring-4 ring-nd_primary_blue-100",
        "text-nd_primary_blue-450",
      )
    | Open => ("bg-white border-nd_gray-200", "text-nd_gray-500")
    }
    <div
      className={`relative z-10 shrink-0 flex items-center justify-center rounded-full w-14 h-14 border-2 ${circleClass}`}>
      <Icon name={state == Learned ? "nd-check" : icon} size=22 className=iconClass />
    </div>
  }
}

module LevelRow = {
  @react.component
  let make = (~level: level, ~state, ~isLast, ~onOpen) => {
    let titleClass = state == Open ? "text-nd_gray-600" : "text-nd_gray-800"
    <div className="relative flex items-center gap-4">
      <RenderIf condition={!isLast}>
        <div
          className={`absolute top-14 left-7 h-6 border-l-2 z-0 ${state == Learned
              ? "border-nd_green-400"
              : "border-nd_gray-150"}`}
        />
      </RenderIf>
      <div
        className="flex flex-1 items-center gap-4 rounded-xl p-1 pr-4 cursor-pointer hover:bg-nd_gray-25"
        onClick={_ => onOpen()}>
        <LevelCircle state icon=level.icon />
        <div className="flex flex-col flex-1 min-w-0">
          <span className={`${body.sm.medium} text-nd_gray-400`}>
            {`Level ${level.id->Int.toString}`->React.string}
          </span>
          <span className={`${body.lg.semibold} ${titleClass}`}> {level.title->React.string} </span>
          <span className={`${body.md.medium} text-nd_gray-500`}> {level.hook->React.string} </span>
        </div>
        <span
          className={`${body.md.semibold} ${state == Current
              ? "text-nd_primary_blue-450"
              : "text-nd_gray-400"}`}>
          {(state == Learned ? "Review" : "Start")->React.string}
        </span>
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
            {"Explained here, not run on the sandbox"->React.string}
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
                    <span className="flex items-center gap-2">
                      <span className={`${body.md.semibold} text-nd_gray-700`}>
                        {`${caption}: ${value}`->React.string}
                      </span>
                      <SourceChip source=SimulatorTypes.Sandbox />
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

// Pane steps at the top of the card, in the look of the dashboard's step indicators: the current
// step filled, a done step outlined with a check, connectors one colour so only the circles move
module PaneSteps = {
  @react.component
  let make = (~pane) => {
    let panes = [(IdeaPane, "Idea"), (ValuePane, "Real value"), (CheckPane, "Check")]
    let currentIndex = panes->Array.findIndex(((p, _)) => p == pane)
    <AddDataAttributes attributes=[("data-learn", "stepper")]>
      <div className="flex items-center w-full">
        {panes
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
            `${body.md.semibold} text-nd_gray-800`
          } else {
            `${body.md.medium} ${isDone ? "text-nd_gray-600" : "text-nd_gray-400"}`
          }
          <React.Fragment key=name>
            <RenderIf condition={index > 0}>
              <AddDataAttributes attributes=[("data-learn", "step-connector")]>
                <div className="flex-1 h-px mx-3 bg-nd_gray-200" />
              </AddDataAttributes>
            </RenderIf>
            <div className="flex items-center gap-2 shrink-0">
              <AddDataAttributes attributes=[("data-learn", "step-circle")]>
                <div
                  className={`flex items-center justify-center rounded-full w-8 h-8 border ${body.sm.semibold} ${circleClass}`}>
                  {isDone
                    ? <Icon name="nd-check" size=14 className="text-nd_primary_blue-450" />
                    : (index + 1)->Int.toString->React.string}
                </div>
              </AddDataAttributes>
              <AddDataAttributes attributes=[("data-learn", "step-label")]>
                <span className=labelClass> {name->React.string} </span>
              </AddDataAttributes>
            </div>
          </React.Fragment>
        })
        ->React.array}
      </div>
    </AddDataAttributes>
  }
}

module ValueBlock = {
  @react.component
  let make = (~value: levelValue, ~configState) => {
    let (big, caption, source) = switch value {
    | Fixed({value, caption, source}) => (value, caption, Some(source))
    | Setting(key) =>
      switch configState {
      | SimulatorTypes.ConfigLoading => ("…", "Reading the sandbox", None)
      | ConfigFailed => ("–", "Not available", None)
      | ConfigLoaded(config) =>
        let (big, caption) = config->settingValue(key)
        (big, caption, Some(SimulatorTypes.Sandbox))
      }
    }
    <div className="flex flex-col items-center gap-2 text-center min-w-40">
      <span className={`${display.sm.semibold} text-nd_gray-800`}> {big->React.string} </span>
      <span className={`${body.md.medium} text-nd_gray-500`}> {caption->React.string} </span>
      {switch source {
      | Some(source) => <SourceChip source />
      | None => React.null
      }}
    </div>
  }
}

module CheckChoices = {
  @react.component
  let make = (~check: check, ~picked, ~onPick) => {
    let isRight = picked == Some(check.answer)
    <div className="w-full flex flex-col gap-3">
      <p className={`${body.lg.semibold} text-nd_gray-800`}> {check.question->React.string} </p>
      {check.choices
      ->Array.mapWithIndex((choice, index) => {
        let isPicked = picked == Some(index)
        let stateClass = switch (isPicked, index == check.answer) {
        | (true, true) => "border-nd_green-400 bg-nd_green-50 text-nd_green-600"
        | (true, false) => "border-nd_red-400 bg-nd_red-50 text-nd_red-600"
        | _ => "border-nd_gray-200 text-nd_gray-700 hover:border-nd_primary_blue-450"
        }
        <div
          key=choice
          className={`flex items-center justify-between gap-3 rounded-lg border px-4 py-3 ${body.md.semibold} ${stateClass} ${isRight
              ? "pointer-events-none"
              : "cursor-pointer"}`}
          onClick={_ => onPick(index)}>
          <span> {choice->React.string} </span>
          {switch (isPicked, index == check.answer) {
          | (true, true) => <Icon name="nd-check-circle" size=18 className="text-nd_green-400" />
          | (true, false) => <Icon name="nd-cross" size=14 className="text-nd_red-500" />
          | _ => React.null
          }}
        </div>
      })
      ->React.array}
      // The line keeps its height before an answer, so answering does not move the choices
      {switch picked {
      | Some(index) if index == check.answer =>
        <p className={`h-5 ${body.md.semibold} text-nd_green-600`}>
          {"Right. Level learned."->React.string}
        </p>
      | Some(_) =>
        <p className={`h-5 ${body.md.medium} text-nd_red-600`}>
          {"Not quite. Try again."->React.string}
        </p>
      | None => <p className="h-5" />
      }}
    </div>
  }
}

// Each pane slides in from the side it comes from: from the right on Next (1), from the left on
// Back (-1). On open (0) it does not move, as the modal has its own entrance.
type paneMove = {pane: modalPane, direction: int}

module LevelModal = {
  @react.component
  let make = (~level: level, ~configState, ~isLearned, ~onLearned, ~onClose) => {
    let ({pane, direction}, setMove) = React.useState(_ => {pane: IdeaPane, direction: 0})
    let (picked, setPicked) = React.useState(_ => None)
    let isRight = picked == Some(level.check.answer)
    let (tryText, tryUrl) = level.tryTarget->tryLink
    let (tagText, tagClass) = level.tag->tagLabel

    let onPick = index => {
      setPicked(_ => Some(index))
      if index == level.check.answer {
        onLearned(level.id)
      }
    }
    let goNext = () =>
      setMove(prev => {
        pane: prev.pane == IdeaPane ? ValuePane : CheckPane,
        direction: 1,
      })
    let goBack = () =>
      setMove(prev => {
        pane: prev.pane == CheckPane ? ValuePane : IdeaPane,
        direction: -1,
      })
    let paneKey = switch pane {
    | IdeaPane => "idea"
    | ValuePane => "value"
    | CheckPane => "check"
    }

    <Modal
      showModal=true
      setShowModal={_ => onClose()}
      closeOnOutsideClick=true
      modalHeading=level.title
      modalHeadingDescription={`Level ${level.id->Int.toString} of ${totalLevels->Int.toString}`}
      modalClass="w-full max-w-2xl mx-auto my-auto"
      headingClass="!p-6"
      childClass="px-6 pt-4 pb-6">
      <div className="flex flex-col gap-6">
        <PaneSteps pane />
        // One height for every pane (the check pane is the tallest), so the footer never moves
        <AddDataAttributes attributes=[("data-learn", "pane")]>
          <div className="h-60">
            <FramerMotion.Motion.Div
              key=paneKey
              initial={{opacity: direction == 0 ? 1.0 : 0.0, x: 8 * direction}}
              animate={{opacity: 1.0, x: 0}}
              transition={{duration: 0.18, ease: "easeInOut"}}
              className="h-full flex flex-col items-center justify-center">
              <AddDataAttributes attributes=[("data-learn", "block")]>
                {switch pane {
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
                | ValuePane =>
                  <div className="flex flex-col items-center gap-5">
                    <div className="flex flex-wrap justify-center gap-10">
                      {level.values
                      ->Array.mapWithIndex((value, index) =>
                        <ValueBlock key={index->Int.toString} value configState />
                      )
                      ->React.array}
                    </div>
                    <Chip text=tagText colorClass=tagClass />
                    {switch level.note {
                    | Some(note) =>
                      <p
                        className={`flex items-center gap-2 text-center ${body.sm.medium} text-nd_yellow-700`}>
                        <Icon
                          name="nd-toast-warning" size=14 className="text-nd_yellow-500 shrink-0"
                        />
                        {note->React.string}
                      </p>
                    | None => React.null
                    }}
                  </div>
                // A DOM root, so the audit attribute lands on the element
                | CheckPane =>
                  <div className="w-full">
                    <CheckChoices check=level.check picked onPick />
                  </div>
                }}
              </AddDataAttributes>
            </FramerMotion.Motion.Div>
          </div>
        </AddDataAttributes>
        <AddDataAttributes attributes=[("data-learn", "footer")]>
          <div className="flex items-center justify-between gap-3 border-t border-nd_gray-150 pt-4">
            <span
              className={`cursor-pointer text-nd_primary_blue-450 hover:underline ${body.md.semibold}`}
              onClick={_ => RescriptReactRouter.push(GlobalVars.appendDashboardPath(~url=tryUrl))}>
              {tryText->React.string}
            </span>
            <div className="flex items-center gap-3">
              <RenderIf condition={pane != IdeaPane}>
                <Button text="Back" buttonType=Secondary buttonSize=Small onClick={_ => goBack()} />
              </RenderIf>
              {switch pane {
              | CheckPane =>
                <Button
                  text="Done"
                  buttonType=Primary
                  buttonSize=Small
                  buttonState={isRight || isLearned ? Normal : Disabled}
                  onClick={_ => onClose()}
                />
              | _ =>
                <Button text="Next" buttonType=Primary buttonSize=Small onClick={_ => goNext()} />
              }}
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
      <PageUtils.PageHeading
        title="Learn Rev Rec" subTitle="Eight short levels. Each ends with one question."
      />
      <SimulatorGlossary.OpenButton />
    </div>
    <ProgressBar learnedCount />
    <RenderIf condition={configState == SimulatorTypes.ConfigFailed}>
      <div className="max-w-2xl">
        <AlertV2Binding
          alertType=Warning
          slot={{slot: <Icon name="nd-toast-warning" size=20 className="text-nd_yellow-500" />}}
          description="The sandbox settings could not be read right now."
        />
      </div>
    </RenderIf>
    <div className="flex flex-col gap-6 w-full max-w-2xl">
      {levels
      ->Array.mapWithIndex((level, index) => {
        let state = if learned->Array.includes(level.id) {
          Learned
        } else if level.id == currentId {
          Current
        } else {
          Open
        }
        <LevelRow
          key={level.id->Int.toString}
          level
          state
          isLast={index == totalLevels - 1}
          onOpen={() => setOpenLevel(_ => Some(level))}
        />
      })
      ->React.array}
      <div className="border-t border-dashed border-nd_gray-200" />
      <MoreFeatures configState />
    </div>
    {switch openLevel {
    | Some(level) =>
      <LevelModal
        key={level.id->Int.toString}
        level
        configState
        isLearned={learned->Array.includes(level.id)}
        onLearned
        onClose={() => setOpenLevel(_ => None)}
      />
    | None => React.null
    }}
  </div>
}
