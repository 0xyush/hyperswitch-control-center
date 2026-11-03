@react.component
let make = () => {
  let url = RescriptReactRouter.useUrl()
  let {devRecoverySimulator, devRecoverySimulatorExtras} =
    HyperswitchAtom.featureFlagAtom->Recoil.useRecoilValueFromAtom
  // Portfolio Run and Learn Rev Rec only with their flag; else they open the Invoice Story
  let extras = devRecoverySimulator && devRecoverySimulatorExtras

  <>
    {switch url.path->HSwitchUtils.urlPath {
    // The simulator build has no onboarding, so the module root opens the simulator Home
    | list{"v2", "recovery"} if devRecoverySimulator =>
      <EmptyPage path=RevenueRecoverySidebarValues.homePath />
    | list{"v2", "recovery"} => <RevenueRecoveryOnboardingLanding createMerchant=true />
    | list{"v2", "recovery", "home"} if devRecoverySimulator => <SimulatorHome />
    | list{"v2", "recovery", "simulator", "story"} if devRecoverySimulator =>
      <SimulatorStory storyIdFromUrl=None />
    | list{"v2", "recovery", "simulator", "story", storyId} if devRecoverySimulator =>
      <SimulatorStory storyIdFromUrl=Some(storyId) />
    | list{"v2", "recovery", "simulator", "tour"} if extras => <SimulatorTour />
    | list{"v2", "recovery", "simulator", "setup"} if devRecoverySimulator => <SimulatorSetup />
    // Operator page, reached by URL only (not in the sidebar)
    | list{"v2", "recovery", "simulator", "health"} if devRecoverySimulator => <SimulatorHealth />
    | list{"v2", "recovery", "simulator", "portfolio"} if extras =>
      <SimulatorPortfolio runIdFromUrl=None />
    | list{"v2", "recovery", "simulator", "portfolio", runId} if extras =>
      <SimulatorPortfolio runIdFromUrl=Some(runId) />
    | list{"v2", "recovery", "simulator", ..._} if devRecoverySimulator =>
      <EmptyPage path=RevenueRecoverySidebarValues.simulatorStoryPath />
    | _ => <RecoveryConnectorContainer />
    }}
    // Underlined terms on any Rev Rec page open this drawer
    <RenderIf condition=devRecoverySimulator>
      <SimulatorGlossary.Drawer />
    </RenderIf>
  </>
}
