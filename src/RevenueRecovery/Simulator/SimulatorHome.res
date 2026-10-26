// Rev Rec Home: one heading, then one card across the full content width: the illustration on top,
// the title and a large Try It Out button under it

// From 900 px the text and the button share one line. Tailwind cannot make a 900 px breakpoint
// here (the theme mixes rem and px screens), so a small media rule does it.
let cardRowCss = "@media (min-width: 900px) { .sim-home-card-row { flex-direction: row; align-items: center; justify-content: space-between; } }"

@react.component
let make = () => {
  open PageUtils
  open Typography
  let mixpanelEvent = MixpanelHook.useSendEvent()

  <div className="w-full gap-8 flex flex-col">
    <PageHeading
      title="Revenue Recovery"
      subTitle="Watch Rev Rec recover a failed subscription payment on the real sandbox, step by step"
      customTitleStyle={`!${heading.lg.semibold}`}
      customSubTitleStyle={`text-nd_gray-400 !opacity-100 !mt-1 ${body.lg.medium}`}
    />
    <style> {cardRowCss->React.string} </style>
    <div
      className="w-full flex flex-col rounded-xl border border-nd_gray-200 bg-white overflow-hidden">
      <div className="w-full h-[360px] bg-nd_gray-50">
        <img
          alt="Try the simulator"
          src="/assets/RevenueRecoveryHomePreview.svg"
          className="w-full h-full object-cover object-center"
        />
      </div>
      <div className="sim-home-card-row flex flex-col gap-4 p-6">
        <div className="flex flex-col gap-1 min-w-0">
          <p className={`${heading.sm.semibold} text-nd_gray-800`}>
            {"Try the simulator"->React.string}
          </p>
          <p className={`${body.lg.medium} text-nd_gray-500`}>
            {"Charge a customer, then watch Rev Rec recover the failed payment, step by step."->React.string}
          </p>
        </div>
        <div className="shrink-0">
          <Button
            text="Try It Out"
            buttonType=Primary
            buttonSize=Large
            onClick={_ => {
              mixpanelEvent(~eventName="recovery_simulator_try_it_out")
              RescriptReactRouter.push(
                GlobalVars.appendDashboardPath(
                  ~url=RevenueRecoverySidebarValues.simulatorStoryPath,
                ),
              )
            }}
          />
        </div>
      </div>
    </div>
  </div>
}
