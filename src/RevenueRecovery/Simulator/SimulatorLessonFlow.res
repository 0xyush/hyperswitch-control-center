// LessonFlow (Learn Rev Rec v2, pane 2): the actors of one lesson left to right, read-only, with
// the step the level is about highlighted and its arrow animated. Built on the dashboard's React
// Flow bindings (libraries/ReactFlow.res, @xyflow/react), which the Recon flow diagram already loads.
open SimulatorTourTypes
open Typography

// Theme colours as values, for the SVG arrows: nd_primary_blue-450, nd_gray-300
let highlightColor = "#247DF9"
let edgeColor = "#CACFD8"

// Grid step between nodes, in flow units: 120-wide nodes and an 80 gap, room for a label of
// about 12 characters above each arrow. fitView scales the flow into the pane (4 columns: ~0.83).
let colStep = 200.0
let rowStep = 88.0

type nodeData = {
  title: string,
  caption: string,
  actor: option<SimulatorTypes.actor>,
  highlighted: bool,
}

type node = {
  id: string,
  @as("type") nodeType: string,
  position: ReactFlow.position,
  data: nodeData,
  draggable: bool,
  selectable: bool,
}

type marker = {@as("type") markerType: string, color: string}
type edgeStyle = {stroke: string, strokeWidth: float}
// Where the label sits: over the middle of a straight arrow; for a branch, over its straight
// part next to the target (branching out) or next to the source (branches joining)
type labelAt = Middle | NearTarget | NearSource
type edgeData = {label: string, highlighted: bool, labelAt: labelAt}

type edge = {
  id: string,
  source: string,
  target: string,
  @as("type") edgeType: string,
  // React Flow's dashed flow, on the highlighted arrow only
  animated: bool,
  style: edgeStyle,
  markerEnd: marker,
  data: edgeData,
}

// An arrow with its label just above it, so the label never covers the arrow
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
    ~style: option<ReactDOM.Style.t>=?,
  ) => {
    let (edgePath, bendX, bendY, _, _) = ReactFlow.getSmoothStepPath({
      sourceX,
      sourceY,
      sourcePosition,
      targetX,
      targetY,
      targetPosition,
    })
    let (labelX, labelY) = switch data.labelAt {
    | Middle => (bendX, bendY)
    | NearTarget => ((bendX +. targetX) /. 2.0, targetY)
    | NearSource => ((sourceX +. bendX) /. 2.0, sourceY)
    }
    <>
      <ReactFlow.BaseEdge path=edgePath ?markerEnd ?style />
      <RenderIf condition={data.label->LogicUtils.isNonEmptyString}>
        <ReactFlow.EdgeLabelRenderer>
          <div
            className={`nodrag nopan absolute -translate-x-1/2 -translate-y-full whitespace-nowrap ${body.sm.medium} ${data.highlighted
                ? "text-nd_primary_blue-450"
                : "text-nd_gray-500"}`}
            style={ReactDOM.Style.make(
              ~left=`${labelX->Float.toString}px`,
              ~top=`${(labelY -. 4.0)->Float.toString}px`,
              (),
            )}>
            {data.label->React.string}
          </div>
        </ReactFlow.EdgeLabelRenderer>
      </RenderIf>
    </>
  }
}

// One fixed size for every node (two caption lines), so all arrows run straight
module ActorNode = {
  @react.component
  let make = (~data: nodeData) => {
    let hiddenHandle: ReactDOM.Style.t = {opacity: "0"}
    let chipClass = switch data.actor {
    | Some(actor) => actor->SimulatorStorySteps.actorChipClass
    | None => "bg-nd_gray-150 text-nd_gray-600"
    }
    <div
      className={`w-[120px] h-[80px] overflow-hidden rounded-lg border bg-white px-2.5 py-2 flex flex-col gap-1 ${data.highlighted
          ? "border-nd_primary_blue-450 ring-2 ring-nd_primary_blue-100"
          : "border-nd_gray-200"}`}>
      <ReactFlow.HandleComponent
        \"type"="target" position=ReactFlow.positionLeft style=hiddenHandle
      />
      <ReactFlow.HandleComponent
        \"type"="source" position=ReactFlow.positionRight style=hiddenHandle
      />
      <span className={`w-fit rounded px-1.5 py-0.5 ${body.sm.semibold} ${chipClass}`}>
        {data.title->React.string}
      </span>
      <span className={`${body.sm.medium} text-nd_gray-700`}> {data.caption->React.string} </span>
    </div>
  }
}

// Defined once, so React Flow keeps the same node and edge types between renders
let nodeTypes = {"actor": ActorNode.make}
let edgeTypes = {"lesson": LessonEdge.make}

let toNode = (node: flowNode): node => {
  id: node.id,
  nodeType: "actor",
  position: {x: node.col *. colStep, y: node.row *. rowStep},
  data: {
    title: node.title,
    caption: node.caption,
    actor: node.actor,
    highlighted: node.highlighted,
  },
  draggable: false,
  selectable: false,
}

let toEdge = (edge: flowEdge, ~rowOf): edge => {
  let color = edge.highlighted ? highlightColor : edgeColor
  {
    id: `${edge.from}-${edge.to}`,
    source: edge.from,
    target: edge.to,
    edgeType: "lesson",
    animated: edge.highlighted,
    style: {stroke: color, strokeWidth: edge.highlighted ? 2.0 : 1.5},
    markerEnd: {markerType: ReactFlow.markerTypeArrowClosed, color},
    data: {
      label: edge.label,
      highlighted: edge.highlighted,
      labelAt: switch (edge.from->rowOf, edge.to->rowOf) {
      | (fromRow, toRow) if fromRow == toRow => Middle
      | (0.0, _) => NearTarget
      | _ => NearSource
      },
    },
  }
}

@react.component
let make = (~flow: lessonFlow) => {
  let nodes = React.useMemo(() => flow.nodes->Array.map(toNode), [flow])
  let edges = React.useMemo(() => {
    let rowOf = id =>
      flow.nodes->Array.find(node => node.id == id)->Option.mapOr(0.0, node => node.row)
    flow.edges->Array.map(edge => edge->toEdge(~rowOf))
  }, [flow])
  <div className="w-full h-full">
    <ReactFlow.ReactFlowComponent
      nodes
      edges
      nodeTypes
      edgeTypes
      onNodesChange={_ => ()}
      onEdgesChange={_ => ()}
      fitView=true
      fitViewOptions={{"padding": 0.02}}
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
}
