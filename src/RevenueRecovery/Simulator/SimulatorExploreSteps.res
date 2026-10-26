// Steps for the "Explore Revenue Recovery" side drawer (PRD section 11)
open ExploreWorkflowsTypes
open Typography

let drawerHeading = "Revenue Recovery Guide"
let drawerSubHeading = "Learn how Rev Rec recovers failed subscription payments, one part at a time."

// Glossary terms in the text are underlined and open the glossary drawer
let stepText = (text: string) =>
  <p className={`${body.md.medium} text-nd_gray-600`}> {text->SimulatorGlossary.linkTerms} </p>

let steps: array<stepDetails> = [
  {
    title: "What Rev Rec is",
    description: <div className="flex flex-col gap-4">
      {stepText(
        "When a subscription payment fails, the billing system tells Revenue Recovery (Rev Rec). Rev Rec picks a time and charges the saved card again. It stops when the invoice is paid or a retry cannot help.",
      )}
      {stepText(
        "A soft decline (for example, no funds) is worth a retry. A hard decline (for example, a stolen card) is not.",
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
      {stepText(
        "Pick a scenario and charge the customer. A real failed invoice moves through Monitoring, Scheduled and Processing. It ends Recovered or Terminated.",
      )}
      {stepText(
        "Each step says who acted (billing system, Rev Rec, processor or customer) and why.",
      )}
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
      {stepText(
        "Run a batch of invoices twice: once with static retries and once with smart retries. Compare the recovery rate, the recovered amount and the attempts used, side by side.",
      )}
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
      {stepText(
        "Eight short levels, one per feature. Each shows the real sandbox value and ends with one question.",
      )}
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
      {stepText(
        "For any attempt, see what Rev Rec used and the time it chose. You also see the limits that applied.",
      )}
      {stepText("Every line says where it comes from: the sandbox, re-computed, or a rule.")}
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
