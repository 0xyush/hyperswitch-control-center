open SimulatorTypes
open SimulatorUtils
open Typography

let cardStyle = "bg-white border border-nd_gray-200 rounded-xl p-6"

// Scenario choice, in the style of the Intelligent Routing step cards
module ScenarioCard = {
  @react.component
  let make = (~scenario: scenario, ~isSelected, ~onClick) => {
    let ringClass = isSelected
      ? "border-blue-811 ring-blue-811/20 ring-offset-0 ring-2"
      : "ring-grey-outline"
    let statusClass = scenario.runnable
      ? "bg-nd_green-100 text-nd_green-500"
      : "bg-nd_gray-100 text-nd_gray-500"
    <div
      className={`flex items-start gap-3 border ${ringClass} rounded-lg p-4 transition-shadow ${scenario.runnable
          ? "cursor-pointer"
          : "opacity-60"}`}
      onClick={_ => scenario.runnable ? onClick() : ()}>
      <Icon
        name={isSelected ? "blue-circle" : "hollow-circle"} customHeight="20" className="mt-0.5"
      />
      <div className="flex flex-col gap-1 w-full">
        <div className="flex items-center justify-between gap-2">
          <p className={`${body.md.semibold} text-nd_gray-700`}>
            {`${scenario.id->Int.toString}. ${scenario.title}`->React.string}
          </p>
          <span
            className={`rounded-md px-2 py-0.5 whitespace-nowrap ${body.sm.semibold} ${statusClass}`}>
            {scenario.v1Status->React.string}
          </span>
        </div>
        <p className={`${body.sm.medium} text-nd_gray-500`}> {scenario.summary->React.string} </p>
        <p className={`${body.sm.medium} text-nd_gray-400`}>
          {`Expected: ${scenario.expected} · ${scenario.liveTime}`->React.string}
        </p>
      </div>
    </div>
  }
}

module ScenarioPicker = {
  @react.component
  let make = (~scenarios: array<scenario>, ~selectedId, ~setSelectedId) => {
    <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
      {scenarios
      ->Array.map(scenario =>
        <ScenarioCard
          key={scenario.id->Int.toString}
          scenario
          isSelected={selectedId == scenario.id}
          onClick={() => setSelectedId(_ => scenario.id)}
        />
      )
      ->React.array}
    </div>
  }
}

// Left column: the invoice states as a vertical stepper with plain captions
module StateStepper = {
  @react.component
  let make = (~stage: stage, ~reached: array<bool>) => {
    let position = stage->stagePosition
    let endStage = switch stage {
    | PartiallyRecovered | Terminated | Cancelled | StoryError => stage
    | _ => Recovered
    }
    let steps = [Monitoring, Queued, Scheduled, Processing, endStage]

    <div className={`${cardStyle} flex flex-col`}>
      <p className={`${body.lg.semibold} text-nd_gray-700 mb-4`}>
        {"Invoice state"->React.string}
      </p>
      {steps
      ->Array.mapWithIndex((step, index) => {
        let wasReached = reached->Array.get(index)->Option.getOr(false)
        let isPassed = index < position || (index == position && stage->isFinalStage)
        let isDone = isPassed && wasReached
        let isSkipped = isPassed && !wasReached
        let isCurrent = index == position && !(stage->isFinalStage)
        let isLast = index == steps->Array.length - 1
        let name = isLast && !(stage->isFinalStage) ? "Recovered or Terminated" : step->stageName
        let caption = switch (isLast && !(stage->isFinalStage), isSkipped) {
        | (true, _) => "Paid, or Rev Rec stopped"
        | (_, true) => "Skipped: the invoice did not go through this step"
        | _ => step->stageCaption
        }
        let dotClass = switch (isDone, isCurrent, step) {
        | (true, _, Terminated | StoryError) => "bg-nd_red-500 border-nd_red-500"
        | (true, _, _) => "bg-nd_green-400 border-nd_green-400"
        | (_, true, _) => "bg-nd_primary_blue-450 border-nd_primary_blue-450 animate-pulse"
        | _ => "bg-white border-nd_gray-300"
        }
        <div key={index->Int.toString} className="flex gap-3">
          <div className="flex flex-col items-center">
            <div className={`w-4 h-4 rounded-full border-2 ${dotClass}`} />
            <RenderIf condition={!isLast}>
              <div
                className={`w-0.5 flex-1 min-h-8 ${isDone ? "bg-nd_green-400" : "bg-nd_gray-200"}`}
              />
            </RenderIf>
          </div>
          <div className="flex flex-col pb-5 -mt-0.5">
            <p
              className={`${body.md.semibold} ${switch (isCurrent, isSkipped) {
                | (true, _) => "text-nd_primary_blue-450"
                | (_, true) => "text-nd_gray-400 line-through"
                | _ => "text-nd_gray-700"
                }}`}>
              {name->React.string}
            </p>
            <p className={`${body.sm.medium} text-nd_gray-400`}> {caption->React.string} </p>
          </div>
        </div>
      })
      ->React.array}
    </div>
  }
}

// Centre column: the four parties and an animated arrow for the latest step
module FlowDiagram = {
  @react.component
  let make = (~activeActor: option<actor>, ~lastEvent: option<flowEvent>) => {
    let (boxWidth, boxHeight) = boxSize
    let actors = [Customer, Billing, Processor, RevRec]
    let arrow = lastEvent->Option.flatMap(event => arrowPoints(~from=event.from, ~to=event.to))

    <div className={`${cardStyle} flex flex-col gap-3`}>
      <p className={`${body.lg.semibold} text-nd_gray-700`}> {"Who does what"->React.string} </p>
      <svg viewBox="0 0 400 250" className="w-full h-auto">
        <defs>
          <marker
            id="sim-arrow-head"
            viewBox="0 0 10 10"
            refX="9"
            refY="5"
            markerWidth="7"
            markerHeight="7"
            orient="auto-start-reverse">
            <path d="M 0 0 L 10 5 L 0 10 z" fill="#006DF9" />
          </marker>
        </defs>
        {actors
        ->Array.map(actor => {
          let (x, y) = actor->boxOrigin
          let (name, note) = actor->actorLabel
          let isActive = activeActor == Some(actor)
          <g key=name>
            <rect
              x={x->Int.toString}
              y={y->Int.toString}
              width={boxWidth->Int.toString}
              height={boxHeight->Int.toString}
              rx="10"
              fill={isActive ? "#EFF6FF" : "#FFFFFF"}
              stroke={isActive ? "#006DF9" : "#D9DDE3"}
              strokeWidth={isActive ? "2" : "1"}
            />
            <text
              x={(x + boxWidth / 2)->Int.toString}
              y={(y + 31)->Int.toString}
              textAnchor="middle"
              fontSize="17"
              fontWeight="600"
              fill="#333C49">
              {name->React.string}
            </text>
            <text
              x={(x + boxWidth / 2)->Int.toString}
              y={(y + 53)->Int.toString}
              textAnchor="middle"
              fontSize="13"
              fill="#8A93A0">
              {note->React.string}
            </text>
          </g>
        })
        ->React.array}
        {switch arrow {
        | Some(((x1, y1), (x2, y2))) =>
          <line
            key={lastEvent->Option.mapOr("", event => event.at ++ event.text)}
            x1={x1->Int.toString}
            y1={y1->Int.toString}
            x2={x2->Int.toString}
            y2={y2->Int.toString}
            stroke="#006DF9"
            strokeWidth="3"
            strokeDasharray="8 6"
            markerEnd="url(#sim-arrow-head)"
            className="sim-flow-arrow"
          />
        | None => React.null
        }}
      </svg>
      <style>
        {".sim-flow-arrow { animation: simFlowDash 1s linear infinite; } @keyframes simFlowDash { to { stroke-dashoffset: -28; } }"->React.string}
      </style>
      <p className={`${body.md.medium} text-nd_gray-600 min-h-6`}>
        {lastEvent->Option.mapOr("Press Play to start a story.", event => event.text)->React.string}
      </p>
    </div>
  }
}

// Right column, top: who acts now, what, why, and the countdown to the booked retry
module NowCard = {
  @react.component
  let make = (~story: story) => {
    let (nowMs, setNowMs) = React.useState(_ => Date.now())
    React.useEffect(() => {
      let intervalId = setInterval(() => setNowMs(_ => Date.now()), 1000)
      Some(() => clearInterval(intervalId))
    }, [])

    let caption =
      story.stageCaption->LogicUtils.isNonEmptyString
        ? story.stageCaption
        : story.stage->stageCaption

    <div className={`${cardStyle} flex flex-col gap-3`}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className={`${body.lg.semibold} text-nd_gray-700`}> {"Now"->React.string} </p>
        <span
          className={`rounded-md px-2 py-0.5 bg-nd_gray-50 border border-nd_gray-200 text-nd_gray-600 ${body.sm.semibold}`}>
          {`${story.stage->stageName} · ${caption}`->React.string}
        </span>
      </div>
      {switch story.now {
      | Some(now) =>
        <>
          <p className={`${body.sm.semibold} text-nd_gray-400 uppercase`}>
            {now.actor->actorLabel->fst->React.string}
          </p>
          <p className={`${body.md.semibold} text-nd_gray-700`}> {now.text->React.string} </p>
          <RenderIf condition={now.why->LogicUtils.isNonEmptyString}>
            <p className={`${body.md.medium} text-nd_gray-500`}> {now.why->React.string} </p>
          </RenderIf>
        </>
      | None =>
        <p className={`${body.md.medium} text-nd_gray-500`}>
          {"Waiting for the first status read."->React.string}
        </p>
      }}
      {switch story.nextRetryAt {
      | Some(nextRetryAt) =>
        <div className={`flex items-center gap-2 ${body.md.medium} text-nd_gray-600`}>
          <div className="w-2 h-2 bg-nd_orange-300 rounded-full" />
          <span> {"Next retry booked for"->React.string} </span>
          <Table.DateCell timestamp={nextRetryAt->toUtcIso} isCard=true />
          <span className={body.md.semibold}>
            {`(${countdownText(~nextRetryAt, ~nowMs)})`->React.string}
          </span>
        </div>
      | None => React.null
      }}
      <RenderIf condition={story.hint->LogicUtils.isNonEmptyString && !(story.stage->isFinalStage)}>
        <p className={`${body.sm.medium} text-nd_primary_blue-450`}> {story.hint->React.string} </p>
      </RenderIf>
    </div>
  }
}

// Right column, bottom: the explain lines, each with its source label
module ExplainPanel = {
  @react.component
  let make = (~lines: array<explainLine>) => {
    <div className={`${cardStyle} flex flex-col gap-3`}>
      <p className={`${body.lg.semibold} text-nd_gray-700`}> {"Why"->React.string} </p>
      {if lines->Array.length == 0 {
        <p className={`${body.md.medium} text-nd_gray-500`}>
          {"The explain lines appear once the story starts."->React.string}
        </p>
      } else {
        lines
        ->Array.mapWithIndex((line, index) => {
          let (label, labelClass) = line.source->sourceLabel
          <div key={index->Int.toString} className="flex flex-col gap-1">
            <span
              className={`w-fit rounded px-1.5 py-0.5 border ${body.xs.semibold} ${labelClass}`}>
              {label->React.string}
            </span>
            <p className={`${body.md.medium} text-nd_gray-600`} style={overflowWrap: "anywhere"}>
              {line.text->React.string}
            </p>
          </div>
        })
        ->React.array
      }}
    </div>
  }
}

// "Show requests": the real request and response for each step (secrets redacted by the proxy)
module RequestsPanel = {
  @react.component
  let make = (~requests: array<requestLog>) => {
    <div className={`${cardStyle} flex flex-col gap-4`}>
      <p className={`${body.lg.semibold} text-nd_gray-700`}> {"Requests"->React.string} </p>
      {if requests->Array.length == 0 {
        <p className={`${body.md.medium} text-nd_gray-500`}> {"No requests yet."->React.string} </p>
      } else {
        requests
        ->Array.mapWithIndex((log, index) =>
          <details key={index->Int.toString} className="border border-nd_gray-200 rounded-lg">
            <summary
              className={`cursor-pointer px-4 py-3 flex gap-3 items-center ${body.md.medium} text-nd_gray-600`}>
              <span className={body.md.semibold}> {log.step->React.string} </span>
              <span className="font-mono text-nd_gray-500" style={overflowWrap: "anywhere"}>
                {`${log.method} ${log.url}`->React.string}
              </span>
              <span className="ml-auto"> {log.status->Int.toString->React.string} </span>
            </summary>
            <div className="grid grid-cols-1 xl:grid-cols-2 gap-4 p-4 pt-0">
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
          </details>
        )
        ->React.array
      }}
    </div>
  }
}
