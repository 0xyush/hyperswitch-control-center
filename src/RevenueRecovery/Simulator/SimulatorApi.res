// Calls to the simulator proxy (/sim/*). Each call carries x-sim-session, a random id kept in
// localStorage: the proxy keys its rate limit and "same customer" on it.
let sessionKey = "simulator_session_id"

@val @scope("crypto") external randomUUID: unit => string = "randomUUID"

let getSessionId = () => {
  switch LocalStorage.getItem(sessionKey)->Nullable.toOption {
  | Some(id) if id->String.length >= 8 && id->String.length <= 64 => id
  | _ => {
      let id = randomUUID()
      LocalStorage.setItem(sessionKey, id)
      id
    }
  }
}

// Returns the response JSON. On an error status it raises the error body as text, so
// SimulatorUtils.getSimErrorMessage can read {"error": {"message"}} from it.
let useSimFetch = () => {
  let fetchApi = AuthHooks.useApiFetcher()
  let {xFeatureRoute, forceCookies} = HyperswitchAtom.featureFlagAtom->Recoil.useRecoilValueFromAtom

  async (~path, ~method_: Fetch.requestMethod, ~body=?) => {
    let res = await fetchApi(
      SimulatorUtils.getSimUrl(path),
      ~method_,
      ~bodyStr=body->Option.mapOr("", JSON.stringify),
      ~headers=[("x-sim-session", getSessionId())]->Dict.fromArray,
      ~xFeatureRoute,
      ~forceCookies,
    )
    let json = await res->Fetch.Response.json
    res->Fetch.Response.ok ? json : Exn.raiseError(json->JSON.stringify)
  }
}

// The proxy's health and limits: GET /sim/health, or /healthz on a proxy without it (Cloud Run
// does not let /healthz through from outside)
let useFetchHealth = () => {
  let simFetch = useSimFetch()
  async () =>
    try {
      await simFetch(~path="/sim/health", ~method_=Get)
    } catch {
    | _ => await simFetch(~path="/healthz", ~method_=Get)
    }
}
