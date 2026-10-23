// Rev Rec Home: the two entry cards, placed like Orchestrator's
// "Make a test payment" card and "Explore Smart Retries" workflow card
@react.component
let make = () => {
  open PageUtils
  open CardUtils
  open Typography
  let {setWorkflowDrawerState} = React.useContext(GlobalProvider.defaultContext)
  let mixpanelEvent = MixpanelHook.useSendEvent()

  <div className="w-full gap-8 flex flex-col">
    <PageHeading
      title="Revenue Recovery"
      subTitle="Watch Rev Rec recover a failed subscription payment on the real sandbox, step by step"
      customTitleStyle={`!${heading.lg.semibold}`}
      customSubTitleStyle={`text-nd_gray-400 !opacity-100 !mt-1 ${body.lg.medium}`}
    />
    <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
      <CardLayout width="" customStyle="flex-1 rounded-xl p-6 gap-4">
        <div className="flex flex-col gap-4">
          <img alt="simulator" src="/assets/RevenueRecoveryHomePreview.svg" />
          <CardHeader
            heading="Try the simulator"
            subHeading="Pick a failed invoice scenario, press Play and see who does what, and why, at each step"
          />
        </div>
        <Button
          text="Try It Out"
          buttonType={Primary}
          buttonSize={Medium}
          onClick={_ => {
            mixpanelEvent(~eventName="recovery_simulator_try_it_out")
            RescriptReactRouter.push(
              GlobalVars.appendDashboardPath(~url=RevenueRecoverySidebarValues.simulatorStoryPath),
            )
          }}
        />
      </CardLayout>
    </div>
    <div className="py-6">
      <div className="flex flex-col gap-2 mb-6">
        <p className={heading.md.semibold}> {"Explore Workflows"->React.string} </p>
        <p className={`${body.lg.medium} text-nd_gray-400`}>
          {"Learn the product one part at a time, with a guide that stays open while you click around."->React.string}
        </p>
      </div>
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        <ExploreWorkflowsSection.InternalWorkflowDisplayCard
          title="Explore Revenue Recovery"
          description="What Rev Rec is, one invoice end to end, a portfolio run, the features and the maths behind each retry."
          buttonText="Explore Revenue Recovery"
          onButtonClick={() => {
            mixpanelEvent(~eventName="explore_revenue_recovery_button_click")
            setWorkflowDrawerState(_ => FullWidth(#ExploreRevenueRecovery))
          }}
          graphicComponent={<img
            src="/assets/DefaultHomeRecoveryCard.svg"
            alt="Explore Revenue Recovery"
            className="object-contain h-full w-full"
          />}
        />
      </div>
    </div>
  </div>
}
