// Feature tour (PRD section 9). Values are read from the sandbox through the proxy; no writes yet.
open SimulatorTypes
open SimulatorTourUtils
open Typography

module FactRow = {
  @react.component
  let make = (~fact: featureFact, ~configState: configState) => {
    let (label, value, source) = switch fact {
    | Fact(label, value, source) => (label, value, Some(source))
    | Config(key) =>
      switch configState {
      | ConfigLoading => (key->configLabel, "Loading…", None)
      | ConfigFailed => (key->configLabel, "Not available", None)
      | ConfigLoaded(config) => (key->configLabel, config->configValueText(key), Some(Sandbox))
      }
    }
    <div className="flex flex-wrap items-center justify-between gap-2 py-3">
      <span className={`${body.md.medium} text-nd_gray-500`}> {label->React.string} </span>
      <div className="flex items-center gap-2">
        <span className={`${body.md.semibold} text-nd_gray-800`}> {value->React.string} </span>
        {switch source {
        | Some(source) =>
          let (sourceText, sourceClass) = source->SimulatorUtils.sourceLabel
          <span className={`rounded px-1.5 py-0.5 border ${body.xs.semibold} ${sourceClass}`}>
            {sourceText->React.string}
          </span>
        | None => React.null
        }}
      </div>
    </div>
  }
}

module FeaturePanel = {
  @react.component
  let make = (~feature: feature, ~configState) => {
    let (tagText, tagClass) = feature.tag->tagLabel
    <div className="bg-white border border-nd_gray-200 rounded-xl p-6 flex flex-col gap-4">
      <div className="flex items-start justify-between gap-3">
        <p className={`${body.lg.semibold} text-nd_gray-800`}> {feature.title->React.string} </p>
        <span
          className={`shrink-0 rounded-md px-2 py-0.5 border whitespace-nowrap ${body.sm.semibold} ${tagClass}`}>
          {tagText->React.string}
        </span>
      </div>
      <p className={`${body.md.medium} text-nd_gray-500`}>
        {feature.description->SimulatorGlossary.linkTerms}
      </p>
      <RenderIf condition={feature.facts->Array.length > 0}>
        <div className="flex flex-col divide-y divide-nd_gray-150 border-t border-nd_gray-150">
          {feature.facts
          ->Array.mapWithIndex((fact, index) =>
            <FactRow key={index->Int.toString} fact configState />
          )
          ->React.array}
        </div>
      </RenderIf>
      {switch feature.note {
      | Some(note) =>
        <AlertV2Binding
          alertType=Warning
          slot={{slot: <Icon name="nd-toast-warning" size=20 className="text-nd_yellow-500" />}}
          description=note
        />
      | None => React.null
      }}
      {switch feature.preset {
      | Some(preset) =>
        <span
          className={`w-fit cursor-pointer text-blue-500 hover:text-blue-700 ${body.md.medium}`}
          onClick={_ =>
            RescriptReactRouter.push(
              GlobalVars.appendDashboardPath(
                ~url=`${RevenueRecoverySidebarValues.simulatorStoryPath}?preset=${preset->Int.toString}`,
              ),
            )}>
          {"See it in the invoice story →"->React.string}
        </span>
      | None => React.null
      }}
    </div>
  }
}

module FeatureSection = {
  @react.component
  let make = (~title, ~subTitle, ~features: array<feature>, ~configState) => {
    <div className="flex flex-col gap-4">
      <div className="flex flex-col gap-1">
        <p className={`${heading.md.semibold} text-nd_gray-900`}> {title->React.string} </p>
        <p className={`${body.md.medium} text-nd_gray-500`}> {subTitle->React.string} </p>
      </div>
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {features
        ->Array.map(feature => <FeaturePanel key=feature.title feature configState />)
        ->React.array}
      </div>
    </div>
  }
}

@react.component
let make = () => {
  open APIUtils
  open LogicUtils
  let getURL = useGetURL()
  let fetchDetails = useGetMethod(~showErrorToast=false)
  let {profileId} = React.useContext(UserInfoProvider.defaultContext).getCommonSessionDetails()
  let (configState, setConfigState) = React.useState(_ => ConfigLoading)

  // The same reads as Configuration Details: the profile, its billing connector, and that connector
  let fetchConfig = async () => {
    try {
      setConfigState(_ => ConfigLoading)
      let connectorListUrl = getURL(~entityName=V2(V2_CONNECTOR), ~methodType=Get)
      let profileUrl = getURL(
        ~entityName=V2(BUSINESS_PROFILE),
        ~methodType=Get,
        ~id=Some(profileId),
      )
      let (connectorList, profile) = await Promise.all2((
        fetchDetails(connectorListUrl, ~version=V2),
        fetchDetails(profileUrl, ~version=V2),
      ))
      let billingConnectorId =
        connectorList
        ->getArrayFromJson([])
        ->Array.map(getDictFromJsonObject)
        ->Array.find(connector => connector->getString("connector_type", "") == "billing_processor")
        ->Option.mapOr("", connector => connector->getString("id", ""))
      let billingConnector = if billingConnectorId->isNonEmptyString {
        let connectorUrl = getURL(
          ~entityName=V2(V2_CONNECTOR),
          ~methodType=Get,
          ~id=Some(billingConnectorId),
        )
        await fetchDetails(connectorUrl, ~version=V2)
      } else {
        JSON.Encode.null
      }
      setConfigState(_ => ConfigLoaded(
        getRevRecConfig(
          ~billingConnector=billingConnector->getDictFromJsonObject,
          ~profile=profile->getDictFromJsonObject,
        ),
      ))
    } catch {
    | _ => setConfigState(_ => ConfigFailed)
    }
  }

  React.useEffect(() => {
    fetchConfig()->ignore
    None
  }, [profileId])

  <div className="flex flex-col gap-8">
    <BreadCrumbNavigation
      path=[{title: "Home", link: RevenueRecoverySidebarValues.homePath}]
      currentPageTitle="Feature Tour"
    />
    <div className="flex items-start justify-between gap-4">
      <PageUtils.PageHeading
        title="Feature tour"
        subTitle="One panel per Rev Rec feature. Each says whether it is live on the sandbox, read-only, or explained only."
      />
      <SimulatorGlossary.OpenButton />
    </div>
    <RenderIf condition={configState == ConfigFailed}>
      <AlertV2Binding
        alertType=Warning
        slot={{slot: <Icon name="nd-toast-warning" size=20 className="text-nd_yellow-500" />}}
        description="The current settings could not be read from the sandbox, so they show as Not available."
      />
    </RenderIf>
    <FeatureSection
      title="Live and read-only"
      subTitle="Values come from the demo profile on the sandbox. Changing them comes in a later version."
      features=liveFeatures
      configState
    />
    <FeatureSection
      title="Display only"
      subTitle="Explained, not run on the sandbox."
      features=displayOnlyFeatures
      configState
    />
  </div>
}
