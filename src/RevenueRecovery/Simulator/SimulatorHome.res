// Rev Rec Home: one heading, then the two entry cards side by side, equal in size, like
// Orchestrator's "Make a test payment" and "Explore Smart Retries" cards

// One entry card. Both cards use it, so they match: the image in the same 2:1 box, the button at
// the bottom, the same height in the grid.
module HomeCard = {
  open Typography
  @react.component
  let make = (~image, ~imageAlt, ~title, ~description, ~button) => {
    <div className="h-full flex flex-col gap-4 rounded-xl border border-nd_gray-200 bg-white p-6">
      <div className="w-full aspect-[2/1] rounded-lg overflow-hidden bg-nd_gray-50">
        <img alt=imageAlt src=image className="w-full h-full object-cover object-center" />
      </div>
      <div className="flex flex-col gap-1">
        <p className={`${body.lg.semibold} text-nd_gray-800`}> {title->React.string} </p>
        <p className={`${body.md.medium} text-nd_gray-500`}> {description->React.string} </p>
      </div>
      <div className="mt-auto"> button </div>
    </div>
  }
}

let homeGridCss = "@media (min-width: 900px) { .sim-home-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); } }"

@react.component
let make = () => {
  open PageUtils
  open Typography
  let {setWorkflowDrawerState} = React.useContext(GlobalProvider.defaultContext)
  let mixpanelEvent = MixpanelHook.useSendEvent()

  <div className="w-full max-w-[1100px] gap-8 flex flex-col">
    <PageHeading
      title="Revenue Recovery"
      subTitle="Watch Rev Rec recover a failed subscription payment on the real sandbox, step by step"
      customTitleStyle={`!${heading.lg.semibold}`}
      customSubTitleStyle={`text-nd_gray-400 !opacity-100 !mt-1 ${body.lg.medium}`}
    />
    // One row of two equal cards; one column below 900 px. Tailwind cannot make a 900 px
    // breakpoint here (the theme mixes rem and px screens), so a small media rule does it.
    <style> {homeGridCss->React.string} </style>
    <div className="sim-home-grid grid grid-cols-1 gap-6">
      <HomeCard
        image="/assets/RevenueRecoveryHomePreview.svg"
        imageAlt="Try the simulator"
        title="Try the simulator"
        description="Charge a customer, then watch Rev Rec recover the failed payment, step by step."
        button={<Button
          text="Try It Out"
          buttonType=Primary
          buttonSize=Medium
          onClick={_ => {
            mixpanelEvent(~eventName="recovery_simulator_try_it_out")
            RescriptReactRouter.push(
              GlobalVars.appendDashboardPath(~url=RevenueRecoverySidebarValues.simulatorStoryPath),
            )
          }}
        />}
      />
      <HomeCard
        image="/assets/DefaultHomeRecoveryCard.svg"
        imageAlt="Explore Revenue Recovery"
        title="Explore Revenue Recovery"
        description="What Rev Rec is, one invoice end to end, and the maths behind each retry."
        button={<Button
          text="Explore Revenue Recovery"
          buttonType=Secondary
          buttonSize=Medium
          onClick={_ => {
            mixpanelEvent(~eventName="explore_revenue_recovery_button_click")
            setWorkflowDrawerState(_ => FullWidth(#ExploreRevenueRecovery))
          }}
        />}
      />
    </div>
  </div>
}
