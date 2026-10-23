// Demo session for the Rev Rec Simulator (feature flag `simulator_demo_session`).
// The visitor skips the login screen. The browser keeps only this placeholder token.
// The simulator proxy swaps it for the real dashboard token, so no secret reaches the browser.
open LogicUtils

let authInfo: AuthProviderTypes.authInfo = {token: Some("simulator-demo")}

// The proxy can inject the session into the page (M4). Without it, the ids come from config (M0).
@val @scope("window") external injectedSession: Nullable.t<JSON.t> = "__SIM_SESSION__"

// Same shape as the GET /user response, so UserInfoUtils maps it like a real session
let getUserInfoSeed = () => {
  let seed = switch injectedSession->Nullable.toOption {
  | Some(json) => json->getDictFromJsonObject
  | None => {
      let config = SimulatorUtils.getConfig()
      [
        ("org_id", config.orgId->JSON.Encode.string),
        ("merchant_id", config.merchantId->JSON.Encode.string),
        ("profile_id", config.profileId->JSON.Encode.string),
      ]->Dict.fromArray
    }
  }

  if seed->getString("merchant_id", "")->isEmptyString {
    Exn.raiseError("Simulator demo session: set merchant_id in [default.simulator]")
  }
  if seed->getString("profile_id", "")->isEmptyString {
    Exn.raiseError("Simulator demo session: set profile_id in [default.simulator]")
  }

  // Rev Rec runs as a V2 product, and the invoice lists are merchant scoped
  [
    ("name", "Demo visitor"->JSON.Encode.string),
    ("entity_type", "merchant"->JSON.Encode.string),
    ("version", "v2"->JSON.Encode.string),
    ("is_two_factor_auth_setup", true->JSON.Encode.bool),
  ]
  ->Dict.fromArray
  ->Dict.assign(seed)
  ->JSON.Encode.object
}
