// Not mounted (user, 28 Oct): Rev Rec Home is the real landing only. Kept for when it comes back.
// Rev Rec Home's two entry points (28 Oct), styled like the control center Home cards (HomeUtils
// "Integrate a Processor" and "Make a test payment"): a light grey illustration, a bold title, one
// grey line and a blue primary button. Watch opens the story page in watch mode (B's): story 15 with
// card 4242, narrated, with Pause. Try it out opens Setup Recovery (SimulatorSetup), as the real
// product's Explore Recovery does; its Start simulation then opens the story form.
open CardUtils

module EntryCard = {
  @react.component
  let make = (~image, ~alt, ~title, ~line, ~buttonText, ~dataSim, ~onClick) => {
    <CardLayout width="" customStyle="flex-1 rounded-xl p-6 gap-4">
      <div className="flex flex-col gap-4">
        <img alt src=image className="w-full rounded-lg" />
        <CardHeader heading=title subHeading=line />
      </div>
      <AddDataAttributes attributes=[("data-sim", dataSim)]>
        <div>
          <Button text=buttonText buttonType=Primary buttonSize=Medium onClick />
        </div>
      </AddDataAttributes>
    </CardLayout>
  }
}

let watchPath = `${RevenueRecoverySidebarValues.simulatorStoryPath}?mode=watch&preset=15`

@react.component
let make = () => {
  open Typography
  let mixpanelEvent = MixpanelHook.useSendEvent()
  let goTo = path => RescriptReactRouter.push(GlobalVars.appendDashboardPath(~url=path))

  // The page heading and the two cards, laid out as the control center Home (Home.res)
  <div className="flex flex-col gap-8 w-full max-w-5xl">
    <PageUtils.PageHeading
      title="Revenue Recovery"
      subTitle="Smart retries recover failed payments and protect your subscription revenue."
      customTitleStyle={`!${heading.lg.semibold}`}
      customSubTitleStyle={`text-nd_gray-400 !opacity-100 !mt-1 ${body.lg.medium}`}
      customHeadingStyle="!mb-0"
      showPermLink=false
    />
    <div className="flex flex-col md:flex-row gap-5 w-full">
      <EntryCard
        image="/assets/RevRecWatchSimulation.svg"
        alt="A failed charge, retries on a calendar, then recovered"
        title="Watch the simulation"
        line="Rev Rec runs a failed invoice on its own and explains each step."
        buttonText="Watch it"
        dataSim="home-watch"
        onClick={_ => {
          mixpanelEvent(~eventName="recovery_simulator_home_watch")
          goTo(watchPath)
        }}
      />
      <EntryCard
        image="/assets/RevRecTryYourself.svg"
        alt="A small checkout with a test card and a Pay button"
        title="Try Rev Rec yourself"
        line="Pick a story, enter a test card and pay. Then watch Rev Rec recover it."
        buttonText="Try it out"
        dataSim="home-try"
        onClick={_ => {
          mixpanelEvent(~eventName="recovery_simulator_try_it_out")
          goTo(RevenueRecoverySidebarValues.simulatorSetupPath)
        }}
      />
    </div>
  </div>
}
