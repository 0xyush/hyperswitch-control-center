// Portfolio run (PRD section 8, simulator/PORTFOLIO.md): one batch of invoices runs twice,
// on a static-retries profile and on a smart-retries (Rev Rec) profile.

type runStatus = SettingUp | Running | Done | RunError

// Totals for one side, recomputed by the proxy from the sandbox's statuses and attempts
type sideCard = {
  invoices: int,
  recovered: int,
  recoveryRate: option<float>,
  // Minor units
  recoveredAmount: int,
  revrecAttempts: int,
  attemptsPerRecovery: option<float>,
  medianMinutes: option<float>,
  p90Minutes: option<float>,
  terminated: int,
  cancelled: int,
  openCount: int,
}

// One copy of an invoice on one profile; storyId opens it in the invoice story
type invoiceCopy = {
  storyId: string,
  recoveryId: string,
  status: string,
  revrecAttempts: int,
  recoveredAt: option<string>,
}

type portfolioInvoice = {
  index: int,
  reason: string,
  amount: int,
  // When the scripted bank says the money is back, minutes after the first failure
  flipAfterMin: option<float>,
  staticCopy: option<invoiceCopy>,
  smartCopy: option<invoiceCopy>,
}

type reasonRow = {
  reason: string,
  invoices: int,
  staticRecovered: int,
  smartRecovered: int,
}

type bankRule = {reason: string, firstChargeCard: string, rule: string}

type trendPoint = {minute: float, staticSoFar: float, smartSoFar: float}

// The dials in the left panel. Amount is typed text in major units.
type portfolioDials = {
  invoiceCount: int,
  amount: string,
  mix: Dict.t<int>,
  // The run stops after this many minutes; open copies are then cancelled
  maxMinutes: int,
}

type portfolioRun = {
  runId: string,
  seed: int,
  status: runStatus,
  // The dials the run was started with
  dials: portfolioDials,
  // Invoices asked for in the dials; copies appear one by one during setup
  plannedInvoices: int,
  startedAt: string,
  endReason: string,
  error: string,
  staticMode: string,
  smartMode: string,
  staticCard: sideCard,
  smartCard: sideCard,
  byReason: array<reasonRow>,
  bankRules: array<bankRule>,
  trend: array<trendPoint>,
  invoices: array<portfolioInvoice>,
  warnings: array<string>,
  // True while both sides share one profile or retry mode: then differences are sandbox noise
  sameStrategy: bool,
  comparisonLabel: string,
  // True when the numbers come from the built-in fixture, not a run on the sandbox
  isFixture: bool,
}
