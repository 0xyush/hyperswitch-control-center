open SimulatorTypes
open LogicUtils

let getSimulatorConfig = (dict): simulatorConfig => {
  simUrl: dict->getString("sim_url", ""),
  orgId: dict->getString("org_id", ""),
  merchantId: dict->getString("merchant_id", ""),
  profileId: dict->getString("profile_id", ""),
}

let getConfig = () => Window.env.simulatorConfig->Option.getOr(Dict.make()->getSimulatorConfig)
