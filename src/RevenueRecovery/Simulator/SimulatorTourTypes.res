// Learn Rev Rec v2 (simulator/LEARN-V2.md): one five-pane lesson per Rev Rec feature

// Pane 2 (simulator/LEARN-COPY.md): a flow of actors, left to right, walked step by step.
// Positions are in grid steps: col to the right, row up (-) or down (+) for a branch.
// The key node is the one the level is about.
type flowNode = {
  id: string,
  actor: option<SimulatorTypes.actor>,
  title: string,
  caption: string,
  col: float,
  row: float,
  isKey: bool,
}

// An arrow and its label: what passes between the boxes, or the answer of a yes/no box
type flowEdge = {from: string, to: string, label: string}

// One step of the walk: the node it reaches, the arrows it lights (none for the first step), and
// the plain-words line under the diagram
type flowStep = {at: string, via: array<(string, string)>, says: string}

type lessonFlow = {nodes: array<flowNode>, edges: array<flowEdge>, steps: array<flowStep>}

// Pane 3: the real number for the demo profile, with one line of context
type levelNumber =
  | FromConfig(SimulatorTypes.revRecConfig => (string, string))
  | Fixed(string, string)

// Where "Try it" goes: the invoice story with a preset, or the portfolio run
type tryTarget = StoryPreset(int) | PortfolioRun

// Panes 4 and 5: one question each; answer is the index of the right choice
type check = {question: string, choices: array<string>, answer: int}

type level = {
  id: int,
  title: string,
  hook: string,
  icon: string,
  // Pane 1: one sentence
  idea: string,
  flow: lessonFlow,
  number: levelNumber,
  checks: (check, check),
  tryTarget: tryTarget,
}

// The 9th level: display-only features, one line each
type moreFeature = {title: string, line: string, setting?: SimulatorTypes.configKey}

type modalPane = IdeaPane | FlowPane | NumberPane | FirstCheck | SecondCheck
