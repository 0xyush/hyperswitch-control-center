// Learn Rev Rec v2 (simulator/LEARN-V2.md): one five-pane lesson per Rev Rec feature

// Pane 2: a read-only flow of actors, left to right. Positions are in grid steps: col to the
// right, row up (-) or down (+) for a branch. The highlighted node and edge are what the level is about.
type flowNode = {
  id: string,
  actor: option<SimulatorTypes.actor>,
  title: string,
  caption: string,
  col: float,
  row: float,
  highlighted: bool,
}

type flowEdge = {from: string, to: string, label: string, highlighted: bool}

type lessonFlow = {nodes: array<flowNode>, edges: array<flowEdge>}

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
