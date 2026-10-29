// Rev Rec Home: a copy of the real Revenue Recovery landing (RevenueRecoveryOnboardingLanding):
// the illustration, the title and subtitle, Explore Recovery and the three features. Explore
// Recovery opens the Setup Recovery walkthrough (SimulatorSetup); a link skips to the simulator.
@react.component
let make = () => {
  open Typography
  let mixpanelEvent = MixpanelHook.useSendEvent()
  let goTo = path => RescriptReactRouter.push(GlobalVars.appendDashboardPath(~url=path))

  <div className="flex flex-1 flex-col gap-6 items-center w-full pt-2">
    <object
      type_="image/svg+xml"
      data="/assets/RevenueRecoveryHomePreview.svg"
      className="w-full max-w-4xl h-auto flex-shrink-0 rounded-2xl"
      ariaLabel="Revenue Recovery Dashboard Preview"
    />
    <div className="flex flex-col gap-4 items-center">
      <div className="flex flex-col gap-2 items-center">
        <p className={`${heading.md.bold} text-center text-nd_gray-700`}>
          {"Recover Lost Revenue & Minimize Churn"->React.string}
        </p>
        <p className={`${body.md.regular} text-center text-nd_gray-500 max-w-3xl`}>
          {"Smart retries recover failed payments and protect your subscription revenue."->React.string}
        </p>
      </div>
      <Button
        text="Explore Recovery"
        buttonType=Primary
        buttonSize=Large
        onClick={_ => {
          mixpanelEvent(~eventName="recovery_simulator_explore_recovery")
          goTo(RevenueRecoverySidebarValues.simulatorSetupPath)
        }}
      />
      <AddDataAttributes attributes=[("data-sim", "skip-to-simulator")]>
        <button
          type_="button"
          className={`${body.md.semibold} text-nd_primary_blue-500 hover:underline`}
          onClick={_ => {
            mixpanelEvent(~eventName="recovery_simulator_try_it_out")
            goTo(RevenueRecoverySidebarValues.simulatorStoryPath)
          }}>
          {"Skip to the simulator"->React.string}
        </button>
      </AddDataAttributes>
    </div>
    <div className="grid grid-cols-1 md:grid-cols-2 gap-x-10 gap-y-6 w-full max-w-2xl mt-2">
      {RevenueRecoveryOnboardingUtils.features
      ->Array.map(feature => {
        <div
          key=feature.title
          className="flex flex-row gap-3 items-start md:last:col-span-2 md:last:justify-self-center md:last:w-[calc(50%-1.25rem)]">
          <div
            className={`${feature.bgColor} rounded-xl w-12 h-12 flex-shrink-0 flex items-center justify-center`}>
            <Icon
              name=feature.icon
              size=28
              className=feature.iconColor
              parentClass="w-full h-full flex items-center justify-center"
            />
          </div>
          <div className="flex flex-col gap-0.5">
            <p className={`${body.md.semibold} text-nd_gray-700`}>
              {feature.title->React.string}
            </p>
            <p className={`${body.sm.regular} text-nd_gray-500`}>
              {feature.description->React.string}
            </p>
          </div>
        </div>
      })
      ->React.array}
    </div>
  </div>
}
