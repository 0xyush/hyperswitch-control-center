@react.component
let make = () => {
  let url = RescriptReactRouter.useUrl()
  let {devRecoverySimulator} = HyperswitchAtom.featureFlagAtom->Recoil.useRecoilValueFromAtom

  {
    switch url.path->HSwitchUtils.urlPath {
    // The simulator build has no onboarding, so the module root opens the simulator Home
    | list{"v2", "recovery"} if devRecoverySimulator =>
      <EmptyPage path=RevenueRecoverySidebarValues.homePath />
    | list{"v2", "recovery"} => <RevenueRecoveryOnboardingLanding createMerchant=true />
    | list{"v2", "recovery", "home"} if devRecoverySimulator => <SimulatorHome />
    | list{"v2", "recovery", "simulator", "story"} if devRecoverySimulator =>
      <SimulatorStory storyIdFromUrl=None />
    | list{"v2", "recovery", "simulator", "story", storyId} if devRecoverySimulator =>
      <SimulatorStory storyIdFromUrl=Some(storyId) />
    | list{"v2", "recovery", "simulator", ..._} if devRecoverySimulator =>
      <EmptyPage path=RevenueRecoverySidebarValues.simulatorStoryPath />
    | _ => <RecoveryConnectorContainer />
    }
  }
}
