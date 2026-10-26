// Operator page: is the demo ready? Reads the proxy's /healthz and its lists.
// In M4 it moves behind sign-in (PRD section 13); for now it is behind the simulator flag only.
open Typography
open LogicUtils

let refreshIntervalMs = 30000

let statusCell = (isOk: bool) =>
  <Table.TableCell
    cell={Label({title: isOk ? "OK" : "FAIL", color: isOk ? LabelGreen : LabelRed})}
  />

let text = (value: string) => value->React.string

let muted = (value: string) =>
  <span className={`${body.md.medium} text-nd_gray-400`}> {value->React.string} </span>

let clockTime = time =>
  time->isNonEmptyString
    ? time->SimulatorUtils.toUtcIso->Date.fromString->Date.toLocaleString
    : "–"

// "in 1 day 2 h", or "expired"
let expiresIn = time => {
  let hours = ((time->SimulatorUtils.toMillis -. Date.now()) /. 3_600_000.0)->Float.toInt
  if time->isEmptyString {
    ""
  } else if hours < 0 {
    "expired"
  } else if hours >= 24 {
    `in ${(hours / 24)->Int.toString} d ${mod(hours, 24)->Int.toString} h`
  } else {
    `in ${hours->Int.toString} h`
  }
}

module Section = {
  @react.component
  let make = (~title, ~subTitle="", ~children) => {
    <div className="flex flex-col gap-3">
      <div className="flex flex-col gap-1">
        <p className={`${heading.sm.semibold} text-nd_gray-800`}> {title->React.string} </p>
        <RenderIf condition={subTitle->isNonEmptyString}>
          <p className={`${body.md.medium} text-nd_gray-500`}> {subTitle->React.string} </p>
        </RenderIf>
      </div>
      children
    </div>
  }
}

let checkRows = (health: Dict.t<JSON.t>) => {
  let sandbox = health->getDictfromDict("sandbox")
  let stripe = health->getDictfromDict("stripe")
  let config = health->getDictfromDict("config")
  let dashboard = health->getDictfromDict("dashboard")
  let scoped = dashboard->getDictfromDict("scoped")
  let missing = config->getStrArrayFromDict("missing", [])
  let isLive = stripe->getBool("livemode", false)
  let expiresAt = scoped->getString("expiresAt", "")
  [
    [
      text("Sandbox"),
      statusCell(sandbox->getBool("ok", false)),
      text(
        `HTTP ${sandbox->getInt("status", 0)->Int.toString} in ${sandbox
          ->getInt("ms", 0)
          ->Int.toString} ms · ${sandbox
          ->getInt("invoices", 0)
          ->Int.toString} invoices on the demo profile`,
      ),
    ],
    [
      text("Stripe"),
      statusCell(stripe->getBool("ok", false) && !isLive),
      text(
        `HTTP ${stripe->getInt("status", 0)->Int.toString} in ${stripe
          ->getInt("ms", 0)
          ->Int.toString} ms · ${isLive ? "LIVE MODE: stop and check the key" : "test mode"}`,
      ),
    ],
    [
      text("Proxy config"),
      statusCell(config->getBool("ok", false)),
      text(
        missing->Array.length == 0
          ? "All keys present (values are never shown)"
          : `Missing: ${missing->Array.joinWith(", ")}`,
      ),
    ],
    [
      text("Dashboard token"),
      statusCell(dashboard->getBool("ok", false)),
      text(
        switch dashboard->getString("error", "") {
        | "" =>
          `Scoped to ${scoped->getString(
              "merchantId",
              "–",
            )} · expires ${expiresAt->clockTime} (${expiresAt->expiresIn})`
        | error => error
        },
      ),
    ],
  ]
}

let tokenRows = (dashboard: Dict.t<JSON.t>) =>
  [("Pasted (from .env)", "pasted"), ("Scoped (after the switch)", "scoped")]->Array.map(((
    label,
    key,
  )) => {
    let token = dashboard->getDictfromDict(key)
    let expiresAt = token->getString("expiresAt", "")
    [
      text(label),
      text(token->getString("merchantId", "–")),
      text(token->getString("profileId", "–")),
      text(token->getString("role", "–")),
      text(`${expiresAt->clockTime} ${expiresAt->expiresIn}`),
    ]
  })

let switchRows = (dashboard: Dict.t<JSON.t>) =>
  dashboard
  ->getArrayFromDict("switchSteps", [])
  ->Array.map(item => {
    let step = item->getDictFromJsonObject
    let status = step->getInt("status", 0)
    [
      text(step->getString("step", "")),
      text(step->getString("path", "")),
      statusCell(status >= 200 && status < 300),
      text(`HTTP ${status->Int.toString} in ${step->getInt("ms", 0)->Int.toString} ms`),
    ]
  })

// Rate limits, if the proxy reports them in /healthz under "limits"
let limitRows = (health: Dict.t<JSON.t>) =>
  health
  ->getDictfromDict("limits")
  ->Dict.toArray
  ->Array.map(((key, value)) => [
    text(key->snakeToTitle),
    text(value->JSON.stringify->String.replaceRegExp(%re("/\"/g"), "")),
  ])

@react.component
let make = () => {
  let simFetch = SimulatorApi.useSimFetch()
  let (health, setHealth) = React.useState(_ => None)
  let (healthError, setHealthError) = React.useState(_ => "")
  let (blocked, setBlocked) = React.useState(_ => [])
  let (stories, setStories) = React.useState(_ => [])
  let (runs, setRuns) = React.useState(_ => None)
  let (checkedAt, setCheckedAt) = React.useState(_ => "")

  // Each read stands alone, so one failure does not hide the rest
  let refresh = async () => {
    let read = async (path, key) => {
      try {
        let json = await simFetch(~path, ~method_=Get)
        Some(json->getDictFromJsonObject->getArrayFromDict(key, []))
      } catch {
      | _ => None
      }
    }
    try {
      let json = await simFetch(~path="/healthz", ~method_=Get)
      setHealth(_ => Some(json->getDictFromJsonObject))
      setHealthError(_ => "")
    } catch {
    | exn => {
        setHealth(_ => None)
        setHealthError(_ =>
          exn->SimulatorUtils.getSimErrorMessage(
            ~default=`The proxy is not reachable at ${SimulatorUtils.getConfig().simUrl}.`,
          )
        )
      }
    }
    let (blockedList, storyList, runList) = await Promise.all3((
      read("/sim/blocked", "blocked"),
      read("/sim/stories", "stories"),
      read("/sim/portfolio", "runs"),
    ))
    setBlocked(_ => blockedList->Option.getOr([]))
    setStories(_ => storyList->Option.getOr([]))
    setRuns(_ => runList)
    setCheckedAt(_ => Date.make()->Date.toLocaleTimeString)
  }

  React.useEffect(() => {
    refresh()->ignore
    let intervalId = setInterval(() => refresh()->ignore, refreshIntervalMs)
    Some(() => clearInterval(intervalId))
  }, [])

  let openPath = path => RescriptReactRouter.push(GlobalVars.appendDashboardPath(~url=path))
  let link = (label, path) =>
    <span
      className="cursor-pointer text-blue-500 hover:text-blue-700" onClick={_ => openPath(path)}>
      {label->React.string}
    </span>

  <div className="flex flex-col gap-8">
    <BreadCrumbNavigation
      path=[{title: "Home", link: RevenueRecoverySidebarValues.homePath}]
      currentPageTitle="Simulator Health"
    />
    <div className="flex items-start justify-between gap-4">
      <PageUtils.PageHeading
        title="Simulator health"
        subTitle="Operator page: is the demo ready? It reads the proxy's health check and lists. In M4 it moves behind sign-in."
      />
      <div className="flex items-center gap-3">
        <RenderIf condition={checkedAt->isNonEmptyString}>
          {muted(`Checked ${checkedAt}`)}
        </RenderIf>
        <Button
          text="Refresh" buttonType=Secondary buttonSize=Medium onClick={_ => refresh()->ignore}
        />
      </div>
    </div>
    {switch health {
    | None =>
      <RenderIf condition={healthError->isNonEmptyString}>
        <AlertV2Binding
          alertType=Error
          slot={{slot: <Icon name="nd-cross" size=20 className="text-nd_red-500" />}}
          heading="Proxy not reachable"
          description=healthError
        />
      </RenderIf>
    | Some(health) =>
      let dashboard = health->getDictfromDict("dashboard")
      <>
        <Section
          title="Checks"
          subTitle={`Proxy health check at ${health->getString("checkedAt", "")->clockTime}`}>
          <SimulatorTable headers=["Check", "Status", "Details"] rows={health->checkRows} />
        </Section>
        <Section
          title="Dashboard tokens"
          subTitle="The token pasted into the proxy, and the one for the Rev Rec merchant.">
          <SimulatorTable
            headers=["Token", "Merchant", "Profile", "Role", "Expires"] rows={dashboard->tokenRows}
          />
        </Section>
        <Section title="Merchant switch">
          <SimulatorTable
            headers=["Step", "Path", "Status", "Result"]
            rows={dashboard->switchRows}
            emptyText="No switch steps reported."
          />
        </Section>
        <Section title="Limits" subTitle="Rate limits for public visitors (PRD section 13).">
          <SimulatorTable
            headers=["Setting", "Value"]
            rows={health->limitRows}
            emptyText="This proxy does not report its limits in /healthz yet."
          />
        </Section>
      </>
    }}
    <Section title="Blocked calls" subTitle="Dashboard calls the proxy refused (ids masked).">
      <SimulatorTable
        headers=["Request", "Count", "Last"]
        rows={blocked->Array.map(item => {
          let row = item->getDictFromJsonObject
          [
            text(row->getString("request", "")),
            text(row->getInt("count", 0)->Int.toString),
            text(row->getString("last", "")->clockTime),
          ]
        })}
        emptyText="None."
      />
    </Section>
    <Section title="Stories" subTitle="Invoice stories the proxy holds. A story id opens it.">
      <SimulatorTable
        headers=["Story", "Preset", "Invoice", "Payment", "Started", "Error"]
        rows={stories->Array.map(item => {
          let row = item->getDictFromJsonObject
          let storyId = row->getString("storyId", "")
          [
            link(storyId, `${RevenueRecoverySidebarValues.simulatorStoryPath}/${storyId}`),
            text(row->getInt("preset", row->getInt("scenarioId", 0))->Int.toString),
            text(row->getString("invoiceId", "")),
            text(row->getString("recoveryId", "–")),
            text(row->getString("startedAt", "")->clockTime),
            text(row->getString("error", "")),
          ]
        })}
        emptyText="No stories since the proxy started."
      />
    </Section>
    <Section title="Portfolio runs">
      <SimulatorTable
        headers=["Run", "Status", "Started", "Invoices"]
        rows={runs
        ->Option.getOr([])
        ->Array.map(item => {
          let row = item->getDictFromJsonObject
          let runId = row->getString("runId", "")
          [
            link(runId, `${RevenueRecoverySidebarValues.simulatorPortfolioPath}/${runId}`),
            text(row->getString("status", "")),
            text(row->getString("startedAt", "")->clockTime),
            text(row->getInt("invoices", 0)->Int.toString),
          ]
        })}
        emptyText={runs->Option.isSome
          ? "No portfolio runs since the proxy started."
          : "The portfolio run is off on this proxy."}
      />
    </Section>
  </div>
}
