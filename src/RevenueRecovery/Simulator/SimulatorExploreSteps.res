// Steps for the "Explore Revenue Recovery" side drawer (PRD section 11)
open ExploreWorkflowsTypes
open Typography

let drawerHeading = "Revenue Recovery Guide"
let drawerSubHeading = "Learn how Rev Rec recovers failed subscription payments, one part at a time."

let stepText = (text: string) =>
  <p className={`${body.md.medium} text-nd_gray-600`}> {text->React.string} </p>

let comingSoon =
  <span
    className={`w-fit text-nd_gray-600 bg-nd_gray-50 px-2 py-0.5 border border-nd_gray-200 rounded ${body.sm.semibold}`}>
    {"Coming soon"->React.string}
  </span>

let steps: array<stepDetails> = [
  {
    title: "What Rev Rec is",
    description: <div className="flex flex-col gap-4">
      {stepText(
        "When a subscription payment fails, the billing system tells Revenue Recovery (Rev Rec). Rev Rec picks a time, charges the saved card again, and stops when the invoice is paid or a retry can no longer help.",
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
        "Pick a scenario and press Play. A real failed invoice moves from Monitoring to Queued, Scheduled and Processing, then to Recovered or Terminated.",
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
      comingSoon
    </div>,
    videoPath: None,
    sectionTrackingEvent: "explore_revenue_recovery_run_a_portfolio",
    cta: None,
  },
  {
    title: "Tour the features",
    description: <div className="flex flex-col gap-4">
      {stepText(
        "One panel per Rev Rec feature. Each panel says Live, Read-only or Display only, so you always know what is real.",
      )}
      comingSoon
    </div>,
    videoPath: None,
    sectionTrackingEvent: "explore_revenue_recovery_tour_the_features",
    cta: None,
  },
  {
    title: "Read the maths",
    description: <div className="flex flex-col gap-4">
      {stepText(
        "For any attempt, see the inputs Rev Rec used, the rule or model answer, the time it chose and the limits that applied.",
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
