// Steps for the "Explore Revenue Recovery" side drawer (PRD section 11)
open ExploreWorkflowsTypes
open Typography

let drawerHeading = "Revenue Recovery Guide"
let drawerSubHeading = "How Rev Rec recovers failed payments, one part at a time."

// Glossary terms in the text are underlined and open the glossary drawer
let stepText = (text: string) =>
  <p className={`${body.md.medium} text-nd_gray-600`}> {text->SimulatorGlossary.linkTerms} </p>

let steps: array<stepDetails> = [
  {
    title: "What Rev Rec is",
    description: <div className="flex flex-col gap-4">
      {stepText("A payment fails. The billing system informs Revenue Recovery (Rev Rec).")}
      {stepText("Rev Rec picks a time and tries the saved card again.")}
      {stepText(
        "A soft decline (no money now) is worth a retry. A hard decline (stolen card) is not.",
      )}
    </div>,
    videoPath: None,
    sectionTrackingEvent: "explore_revenue_recovery_what_it_is",
    cta: Some((
      "See the invoices →",
      InternalRoute({url: "/v2/recovery/invoices", trackingEvent: "redirect_to_recovery_invoices"}),
    )),
  },
  {
    title: "Watch one invoice",
    description: <div className="flex flex-col gap-4">
      {stepText("Pick a story and charge the customer.")}
      {stepText("Watch the invoice until Rev Rec recovers it or stops.")}
      {stepText("Each step says who acted, and why.")}
    </div>,
    videoPath: None,
    sectionTrackingEvent: "explore_revenue_recovery_watch_one_invoice",
    cta: Some((
      "Try the simulator →",
      InternalRoute({
        url: RevenueRecoverySidebarValues.simulatorStoryPath,
        trackingEvent: "redirect_to_simulator_story",
      }),
    )),
  },
  {
    title: "Run a portfolio",
    description: <div className="flex flex-col gap-4">
      {stepText("Run the same invoices twice: static retries, then smart retries.")}
      {stepText("Compare how many each recovers, side by side.")}
    </div>,
    videoPath: None,
    sectionTrackingEvent: "explore_revenue_recovery_run_a_portfolio",
    cta: Some((
      "Open the portfolio run →",
      InternalRoute({
        url: RevenueRecoverySidebarValues.simulatorPortfolioPath,
        trackingEvent: "redirect_to_simulator_portfolio",
      }),
    )),
  },
  {
    title: "Learn Rev Rec",
    description: <div className="flex flex-col gap-4">
      {stepText("Short levels, one per feature. Each ends with two questions.")}
    </div>,
    videoPath: None,
    sectionTrackingEvent: "explore_revenue_recovery_tour_the_features",
    cta: Some((
      "Open Learn Rev Rec →",
      InternalRoute({
        url: RevenueRecoverySidebarValues.simulatorTourPath,
        trackingEvent: "redirect_to_simulator_tour",
      }),
    )),
  },
  {
    title: "Read the maths",
    description: <div className="flex flex-col gap-4">
      {stepText("Tap \"?\" on any retry: what Rev Rec used, and why it chose that time.")}
      {stepText("Each line says where it comes from: Rev Rec, re-computed, or a rule.")}
    </div>,
    videoPath: None,
    sectionTrackingEvent: "explore_revenue_recovery_read_the_maths",
    cta: Some((
      "Open an invoice story →",
      InternalRoute({
        url: RevenueRecoverySidebarValues.simulatorStoryPath,
        trackingEvent: "redirect_to_simulator_explain",
      }),
    )),
  },
]
