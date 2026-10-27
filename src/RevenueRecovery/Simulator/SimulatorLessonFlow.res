// LessonFlow (Learn Rev Rec v2, pane 2): the actors of one lesson left to right, walked step by
// step like the merchant one-pager. Play (and the first time the pane shows) lights one step
// every 1.2 s: the active arrow turns green with moving dashes, the node it reaches lights blue,
// passed arrows stay green. A caption under the graph says the step in plain words. A click on a
// node jumps to its step. Built on the dashboard's React Flow bindings (libraries/ReactFlow.res).
open SimulatorTourTypes
open Typography

// Theme colours as values, for the SVG arrows: nd_gray-300 idle, nd_green-400 walked
let idleColor = "#CACFD8"
let walkColor = "#2DA160"

// Nodes 240 x 88 (two caption lines at most). 48 between rows; 136 between columns, wider than
// the widest label pill (three words), so a pill on an arrow never reaches a node.
let colStep = 376.0
let rowStep = 136.0
let stepMs = 1200
let fitPadding = 0.2

// The moving dashes (stroke-dashoffset to -32 every 0.8 s), still for reduced motion
let walkCss = `@keyframes lessonDash { to { stroke-dashoffset: -32; } }
.lesson-edge-active { stroke-dasharray: 10 6; animation: lessonDash 0.8s linear infinite; }
@media (prefers-reduced-motion: reduce) { .lesson-edge-active { animation: none; } }`

type nodeState = NodeIdle | NodeDone | NodeLit
type edgeState = EdgeIdle | EdgeActive | EdgePassed

type nodeData = {
  title: string,
  caption: string,
  actor: option<SimulatorTypes.actor>,
  isKey: bool,
  state: nodeState,
  onSelect: unit => unit,
}

type node = {
  id: string,
  @as("type") nodeType: string,
  position: ReactFlow.position,
  data: nodeData,
  draggable: bool,
  selectable: bool,
  // React Flow turns pointer events off for nodes that cannot be dragged or selected; a node
  // still takes clicks (jump to its step), so its own style turns them back on
  style: ReactDOM.Style.t,
}

type marker = {@as("type") markerType: string, color: string}
type edgeData = {label: string, state: edgeState}

type edge = {
  id: string,
  source: string,
  target: string,
  @as("type") edgeType: string,
  markerEnd: marker,
  data: edgeData,
}

// The actor badge: Billing system grey, Processor amber, Rev Rec blue, Customer green
let badgeClass = (actor: option<SimulatorTypes.actor>) =>
  switch actor {
  | Some(Billing) => "bg-nd_gray-150 text-nd_gray-700"
  | Some(Processor) => "bg-nd_orange-50 text-nd_orange-600"
  | Some(RevRec) => "bg-nd_primary_blue-50 text-nd_primary_blue-600"
  | Some(Customer) => "bg-nd_green-50 text-nd_green-600"
  | None => "bg-nd_purple-100 text-nd_purple-700"
  }

module ActorNode = {
  @react.component
  let make = (~data: nodeData) => {
    let hiddenHandle: ReactDOM.Style.t = {opacity: "0"}
    let stateClass = switch data.state {
    | NodeLit => "border-nd_primary_blue-450 bg-nd_primary_blue-25 ring-4 ring-nd_primary_blue-100"
    | NodeDone => "border-nd_primary_blue-200 bg-white"
    | NodeIdle => "border-nd_gray-200 bg-white"
    }
    <div
      className={`w-[240px] h-[88px] rounded-xl border-1.5 px-3 py-2.5 flex flex-col gap-1.5 cursor-pointer transition-colors duration-300 ease-in-out ${stateClass}`}
      onClick={_ => data.onSelect()}>
      <ReactFlow.HandleComponent
        \"type"="target" position=ReactFlow.positionLeft style=hiddenHandle
      />
      <ReactFlow.HandleComponent
        \"type"="source" position=ReactFlow.positionRight style=hiddenHandle
      />
      <div className="flex items-center justify-between gap-2">
        <span
          className={`w-fit rounded px-1.5 py-0.5 ${body.sm.semibold} ${data.actor->badgeClass}`}>
          {data.title->React.string}
        </span>
        // The node the level is about
        <RenderIf condition=data.isKey>
          <span className="text-fs-11 font-semibold text-nd_primary_blue-450">
            {"Key step"->React.string}
          </span>
        </RenderIf>
      </div>
      <span className={`line-clamp-2 ${body.md.medium} text-nd_gray-700`}>
        {data.caption->React.string}
      </span>
    </div>
  }
}

// A smoothstep arrow with its label in a white pill on the arrow's middle
module LessonEdge = {
  @react.component
  let make = (
    ~sourceX: float,
    ~sourceY: float,
    ~sourcePosition: string,
    ~targetX: float,
    ~targetY: float,
    ~targetPosition: string,
    ~data: edgeData,
    ~markerEnd: option<string>=?,
  ) => {
    let (path, labelX, labelY, _, _) = ReactFlow.getSmoothStepPath({
      sourceX,
      sourceY,
      sourcePosition,
      targetX,
      targetY,
      targetPosition,
    })
    let (stroke, strokeWidth, walkClass, pillClass) = switch data.state {
    | EdgeActive => (walkColor, "3", "lesson-edge-active", "border-nd_green-400 text-nd_green-600")
    | EdgePassed => (walkColor, "2.5", "", "border-nd_green-200 text-nd_green-600")
    | EdgeIdle => (idleColor, "1.5", "", "border-nd_gray-200 text-nd_gray-600")
    }
    <>
      <path
        d=path
        fill="none"
        className={`react-flow__edge-path ${walkClass}`}
        ?markerEnd
        style={ReactDOM.Style.make(
          ~stroke,
          ~strokeWidth,
          ~transition="stroke 0.3s ease-in-out",
          (),
        )}
      />
      <ReactFlow.EdgeLabelRenderer>
        <div
          className={`nodrag nopan absolute -translate-x-1/2 -translate-y-1/2 rounded-full border bg-white px-2 py-0.5 whitespace-nowrap text-fs-11 font-semibold transition-colors duration-300 ease-in-out ${pillClass}`}
          style={ReactDOM.Style.make(
            ~left=`${labelX->Float.toString}px`,
            ~top=`${labelY->Float.toString}px`,
            (),
          )}>
          {data.label->React.string}
        </div>
      </ReactFlow.EdgeLabelRenderer>
    </>
  }
}

// Defined once, so React Flow keeps the same node and edge types between renders
let nodeTypes = {"actor": ActorNode.make}
let edgeTypes = {"lesson": LessonEdge.make}

@send
external fitViewWith: (
  ReactFlow.reactFlowInstance,
  {"padding": float, "duration": int},
) => promise<bool> = "fitView"

module Canvas = {
  @react.component
  let make = (~flow: lessonFlow, ~isActive, ~isFullscreen) => {
    let reactFlow = ReactFlow.useReactFlow()
    let total = flow.steps->Array.length
    // step 0: not started; step k: step k is the latest shown
    let (step, setStep) = React.useState(_ => 0)
    let (isPlaying, setIsPlaying) = React.useState(_ => false)
    let isFinished = step == total && !isPlaying

    let play = () => {
      setStep(prev => prev == 0 || prev == total ? 1 : prev)
      setIsPlaying(_ => true)
    }

    // Plays by itself the first time the pane shows
    React.useEffect(() => {
      if isActive && step == 0 {
        play()
      }
      None
    }, [isActive])

    // One step every 1.2 s; after the last one the walk stops
    React.useEffect(() => {
      if isPlaying {
        let timeoutId = setTimeout(
          () => step < total ? setStep(prev => prev + 1) : setIsPlaying(_ => false),
          stepMs,
        )
        Some(() => clearTimeout(timeoutId))
      } else {
        None
      }
    }, (isPlaying, step))

    // Fit again when the card goes fullscreen or back, and when the window changes size
    let refit = () => reactFlow->fitViewWith({"padding": fitPadding, "duration": 300})->ignore
    React.useEffect(() => {
      let timeoutId = setTimeout(refit, 60)
      Some(() => clearTimeout(timeoutId))
    }, [isFullscreen])
    React.useEffect(() => {
      let onResize = _ => refit()
      Window.addEventListener("resize", onResize)
      Some(() => Window.removeEventListener("resize", onResize))
    }, [])

    let shown = flow.steps->Array.slice(~start=0, ~end=step)
    let current = shown->Array.at(-1)
    let edgeId = ((from, to)) => `${from}-${to}`
    let activeIds = current->Option.mapOr([], current => current.via->Array.map(edgeId))
    let passedIds =
      shown
      ->Array.slice(~start=0, ~end=isFinished ? step : step - 1)
      ->Array.flatMap(step => step.via->Array.map(edgeId))
    let edgeState = id =>
      if passedIds->Array.includes(id) {
        EdgePassed
      } else if activeIds->Array.includes(id) {
        EdgeActive
      } else {
        EdgeIdle
      }
    let litId = current->Option.mapOr("", current => current.at)
    let nodeState = id =>
      if id == litId {
        NodeLit
      } else if shown->Array.some(step => step.at == id) {
        NodeDone
      } else {
        NodeIdle
      }
    // A click on a node shows the step that reaches it
    let jumpTo = id => {
      let index = flow.steps->Array.findIndex(step => step.at == id)
      setStep(_ => index >= 0 ? index + 1 : 1)
      setIsPlaying(_ => false)
    }

    let nodes = flow.nodes->Array.map((node): node => {
      id: node.id,
      nodeType: "actor",
      position: {x: node.col *. colStep, y: node.row *. rowStep},
      data: {
        title: node.title,
        caption: node.caption,
        actor: node.actor,
        isKey: node.isKey,
        state: node.id->nodeState,
        onSelect: () => jumpTo(node.id),
      },
      draggable: false,
      selectable: false,
      style: {pointerEvents: "all"},
    })
    let edges = flow.edges->Array.map((edge): edge => {
      let state = (edge.from, edge.to)->edgeId->edgeState
      {
        id: `${edge.from}-${edge.to}`,
        source: edge.from,
        target: edge.to,
        edgeType: "lesson",
        markerEnd: {
          markerType: ReactFlow.markerTypeArrowClosed,
          color: state == EdgeIdle ? idleColor : walkColor,
        },
        data: {label: edge.label, state},
      }
    })
    let caption = current->Option.mapOr("Press Play to walk through the steps.", step => step.says)

    <div className="w-full h-full flex flex-col gap-3">
      <AddDataAttributes attributes=[("data-learn", "flow-canvas")]>
        <div className="flex-1 min-h-0 rounded-xl border border-nd_gray-150 bg-nd_gray-25">
          <ReactFlow.ReactFlowComponent
            nodes
            edges
            nodeTypes
            edgeTypes
            onNodesChange={_ => ()}
            onEdgesChange={_ => ()}
            fitView=true
            fitViewOptions={{"padding": fitPadding}}
            nodesDraggable=false
            nodesConnectable=false
            elementsSelectable=false
            panOnDrag=false
            zoomOnScroll=false
            zoomOnPinch=false
            zoomOnDoubleClick=false
            minZoom=0.3
            maxZoom=1.0
            proOptions={{"hideAttribution": true}}
          />
        </div>
      </AddDataAttributes>
      <div className="flex items-center gap-3 h-9">
        <Button
          text={isPlaying ? "Pause" : isFinished ? "Replay" : "Play"}
          buttonType=Secondary
          buttonSize=Small
          onClick={_ => isPlaying ? setIsPlaying(_ => false) : play()}
        />
        <AddDataAttributes attributes=[("data-learn", "flow-caption")]>
          <span className={`flex-1 min-w-0 truncate ${body.md.medium} text-nd_gray-700`}>
            {caption->React.string}
          </span>
        </AddDataAttributes>
        <span className={`shrink-0 ${body.sm.medium} text-nd_gray-400`}>
          {`Step ${step->Int.toString} of ${total->Int.toString}`->React.string}
        </span>
      </div>
    </div>
  }
}

@react.component
let make = (~flow: lessonFlow, ~isActive, ~isFullscreen) => <>
  <style> {walkCss->React.string} </style>
  <ReactFlow.ReactFlowProvider>
    <Canvas flow isActive isFullscreen />
  </ReactFlow.ReactFlowProvider>
</>
