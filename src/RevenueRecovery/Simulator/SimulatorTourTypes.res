// Learn Rev Rec (UX-PASS-2 section B): one level per Rev Rec feature

// Pane 2: a live setting read from the sandbox, or a fixed value with its source
type levelValue =
  | Setting(SimulatorTypes.configKey)
  | Fixed({value: string, caption: string, source: SimulatorTypes.source})

// Where "Try it" goes: the invoice story with a preset, or the portfolio run
type tryTarget = StoryPreset(int) | PortfolioRun

// Pane 3: one question; answer is the index of the right choice
type check = {question: string, choices: array<string>, answer: int}

type level = {
  id: int,
  title: string,
  hook: string,
  icon: string,
  // Pane 1: one sentence
  idea: string,
  // Pane 2
  values: array<levelValue>,
  tag: SimulatorTypes.featureTag,
  note?: string,
  check: check,
  tryTarget: tryTarget,
}

// The 9th level: display-only features, one line each
type moreFeature = {title: string, line: string, setting?: SimulatorTypes.configKey}

type modalPane = IdeaPane | ValuePane | CheckPane
