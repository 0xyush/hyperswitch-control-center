// Portfolio run (PRD section 8). Left: the dials, in the same "Try It Out" layout as the story.
// Right: progress, then static retries vs Rev Rec on the same invoices. Every number says where
// it comes from: the sandbox, re-computed from it, the scripted bank, or a rule.
open SimulatorPortfolioTypes
open SimulatorPortfolioUtils
open Typography

let cardStyle = "bg-white border border-nd_gray-200 rounded-xl"

type sourceKind = FromSandbox | Recomputed | ScriptedBank | FromRule

module SourceChip = {
  @react.component
  let make = (~kind, ~isFixture) => {
    let (text, colorClass) = if isFixture {
      ("Fixture", "bg-nd_gray-50 text-nd_gray-600 border-nd_gray-200")
    } else {
      switch kind {
      | FromSandbox => SimulatorUtils.sourceLabel(Sandbox)
      | Recomputed => SimulatorUtils.sourceLabel(Recomputed)
      | FromRule => SimulatorUtils.sourceLabel(Rule)
      | ScriptedBank => (
          "Bank: scripted",
          "bg-nd_yellow-50 text-nd_yellow-700 border-nd_yellow-200",
        )
      }
    }
    <span
      className={`shrink-0 w-fit rounded px-1.5 py-0.5 border whitespace-nowrap ${body.xs.semibold} ${colorClass}`}>
      {text->React.string}
    </span>
  }
}

module SectionCard = {
  @react.component
  let make = (~title, ~subTitle="", ~accessory=React.null, ~children) => {
    <div className={`${cardStyle} px-6 py-5 flex flex-col gap-4`}>
      <div className="flex items-start justify-between gap-3">
        <div className="flex flex-col gap-1">
          <p className={`${heading.sm.semibold} text-nd_gray-800`}> {title->React.string} </p>
          <RenderIf condition={subTitle->LogicUtils.isNonEmptyString}>
            <p className={`${body.md.medium} text-nd_gray-500`}> {subTitle->React.string} </p>
          </RenderIf>
        </div>
        accessory
      </div>
      children
    </div>
  }
}

// Left panel: the dials
module DialsForm = {
  @react.component
  let make = (~dials: portfolioDials, ~setDials, ~isBusy, ~isRunning, ~onRun, ~onStop) => {
    let total = dials.mix->mixTotal
    let setWeight = (reason, weight) =>
      setDials(prev => {
        let mix = prev.mix->Dict.copy
        mix->Dict.set(reason, weight)
        {...prev, mix}
      })

    <div className={`${cardStyle} p-6 flex flex-col gap-5`}>
      <div className="flex flex-col gap-1">
        <p className={`${heading.sm.semibold} text-nd_gray-800`}>
          {"Portfolio run"->React.string}
        </p>
        <p className={`${body.sm.medium} text-nd_gray-500`}>
          {"The proxy creates each invoice twice: once on a static-retries profile and once on a Rev Rec (smart) profile. The customer's bank is scripted per decline reason."->React.string}
        </p>
      </div>
      <SimulatorStoryHelper.SelectField
        label="Number of invoices"
        name="invoices"
        options=invoiceCountOptions
        value={dials.invoiceCount->Int.toString}
        onChange={value =>
          setDials(prev => {...prev, invoiceCount: value->Int.fromString->Option.getOr(10)})}
      />
      <SimulatorStoryHelper.SelectField
        label="Stop after"
        name="maxMinutes"
        options=maxMinutesOptions
        value={dials.maxMinutes->Int.toString}
        onChange={value =>
          setDials(prev => {...prev, maxMinutes: value->Int.fromString->Option.getOr(20)})}
      />
      <SimulatorStoryHelper.FormField label="Amount per invoice (USD)">
        {InputFields.textInput(~customStyle="w-full border-nd_gray-200 rounded-lg")(
          ~input=SimulatorStoryHelper.makeInput(
            ~name="amount",
            ~value=dials.amount,
            ~onChange=text =>
              setDials(prev => {
                ...prev,
                amount: text->String.replaceRegExp(%re("/[^\\d.]/g"), ""),
              }),
            ~onBlur=() =>
              setDials(prev => {...prev, amount: prev.amount->SimulatorUtils.toAmountText}),
          ),
          ~placeholder="Enter amount",
        )}
      </SimulatorStoryHelper.FormField>
      <SimulatorStoryHelper.FormField label="Decline mix">
        <div className="flex flex-col gap-3 pt-1">
          {reasons
          ->Array.map(reason => {
            let weight = dials.mix->Dict.get(reason)->Option.getOr(0)
            let share =
              total > 0 ? (weight->Int.toFloat /. total->Int.toFloat *. 100.0)->Float.toInt : 0
            <div key=reason className="flex flex-col gap-1">
              <div className={`flex justify-between ${body.sm.medium} text-nd_gray-600`}>
                <span>
                  {reason->reasonLabel->React.string}
                  <span className="text-nd_gray-400">
                    {(reason->isHardReason ? " · hard" : " · soft")->React.string}
                  </span>
                </span>
                <span className="text-nd_gray-500">
                  {`${share->Int.toString}%`->React.string}
                </span>
              </div>
              <input
                type_="range"
                min="0"
                max="10"
                step=1.0
                value={weight->Int.toString}
                className="w-full accent-primary cursor-pointer"
                onChange={event => {
                  let value: string = ReactEvent.Form.target(event)["value"]
                  setWeight(reason, value->Int.fromString->Option.getOr(0))
                }}
              />
            </div>
          })
          ->React.array}
        </div>
      </SimulatorStoryHelper.FormField>
      <SimulatorStoryHelper.FormField label="Card mix">
        <div className="flex flex-col gap-1">
          <p className={`${body.md.medium} text-nd_gray-700`}> {"Visa 100%"->React.string} </p>
          <p className={`${body.sm.medium} text-nd_gray-400`}>
            {"Other networks come once the sandbox is shown to keep the reported network (PORTFOLIO.md, question 5)."->React.string}
          </p>
        </div>
      </SimulatorStoryHelper.FormField>
      <Button
        text="Run"
        buttonType=Primary
        buttonSize=Medium
        customButtonStyle="!w-full"
        buttonState={isBusy ? Loading : total == 0 || isRunning ? Disabled : Normal}
        onClick={_ => onRun()}
      />
      <RenderIf condition=isRunning>
        <Button
          text="Stop run"
          buttonType=Secondary
          buttonSize=Small
          customButtonStyle="!w-full"
          onClick={_ => onStop()}
        />
      </RenderIf>
    </div>
  }
}

module Progress = {
  @react.component
  let make = (~run: portfolioRun) => {
    // During setup the cards count only the copies created so far; the dials give the plan
    let total = Math.Int.max(
      run.plannedInvoices * 2,
      run.staticCard.invoices + run.smartCard.invoices,
    )
    let finished = run.staticCard->finishedCopies + run.smartCard->finishedCopies
    let percent = total > 0 ? finished * 100 / total : 0
    let caption = switch run.status {
    | SettingUp => "Setting up: creating each invoice on both profiles, with real Stripe test charges."
    | Running => "Running: Rev Rec retries on the sandbox; the bank flips on its scripted clock."
    | Done => `Done: ${run.endReason}.`
    | RunError => `The run stopped: ${run.error}`
    }
    <SectionCard
      title="Progress"
      subTitle="Time is compressed: the sandbox retries every few minutes where production waits hours.">
      <div className="flex flex-col gap-2">
        <div className="w-full h-2 rounded-full bg-nd_gray-100 overflow-hidden">
          <div
            className="h-2 rounded-full bg-nd_primary_blue-450"
            style={width: `${percent->Int.toString}%`}
          />
        </div>
        <div className={`flex justify-between ${body.md.medium} text-nd_gray-600`}>
          <span> {caption->React.string} </span>
          <span className="whitespace-nowrap">
            {`${finished->Int.toString} of ${total->Int.toString} copies final`->React.string}
          </span>
        </div>
      </div>
    </SectionCard>
  }
}

// A banner in the column of each side that booked no retries, so a 0 is not read as a result
module NoRetriesBanners = {
  @react.component
  let make = (~run: portfolioRun) => {
    let banner = (~card, ~mode, ~sideName) =>
      if run->bookedNoRetries(card) {
        <AlertV2Binding
          alertType=Warning
          slot={{slot: <Icon name="nd-toast-warning" size=20 className="text-nd_yellow-500" />}}
          heading={`${sideName}: no retries booked`}
          description={noRetriesText(~mode)}
        />
      } else {
        <div />
      }

    <RenderIf
      condition={run->bookedNoRetries(run.staticCard) || run->bookedNoRetries(run.smartCard)}>
      // Same two columns as the result cards: static on the left, Rev Rec on the right
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        {banner(~card=run.staticCard, ~mode=run.staticMode, ~sideName="Static retries")}
        {banner(~card=run.smartCard, ~mode=run.smartMode, ~sideName="Rev Rec")}
      </div>
    </RenderIf>
  }
}

// Static retries vs Rev Rec, one Intelligent Routing simulator card per metric
module ResultCards = {
  @react.component
  let make = (~run: portfolioRun) => {
    let accessory = <SourceChip kind=Recomputed isFixture=run.isFixture />
    let metricCard = (
      ~title,
      ~staticValue,
      ~smartValue,
      ~statType,
      ~currency="",
      ~lowerIsBetter=false,
    ) =>
      switch (staticValue, smartValue) {
      | (Some(staticValue), Some(smartValue)) =>
        <IntelligentRoutingAnalytics.Card
          title
          actualValue=staticValue
          simulatedValue=smartValue
          valueFormat=true
          statType
          currency
          baselineLabel="Static retries"
          modelLabel="Rev Rec"
          lowerIsBetter
          colorByDirection=true
          titleAccessory=accessory
        />
      | _ =>
        <div className="flex flex-col gap-3 border rounded-xl border-nd_gray-150 p-4">
          <div className="flex items-center justify-between">
            <p className="text-nd_gray-500 text-md leading-4 font-medium">
              {title->React.string}
            </p>
            accessory
          </div>
          <p className={`${body.md.medium} text-nd_gray-400`}>
            {"Not enough recoveries yet."->React.string}
          </p>
        </div>
      }
    let percent = rate => rate->Option.map(value => value *. 100.0)
    let major = minor => Some(minor->Int.toFloat /. 100.0)

    <div className="grid grid-cols-1 2xl:grid-cols-2 gap-4">
      {metricCard(
        ~title="Recovery rate",
        ~staticValue=run.staticCard.recoveryRate->percent,
        ~smartValue=run.smartCard.recoveryRate->percent,
        ~statType=Rate,
      )}
      {metricCard(
        ~title="Recovered amount",
        ~staticValue=run.staticCard.recoveredAmount->major,
        ~smartValue=run.smartCard.recoveredAmount->major,
        ~statType=AmountWithSuffix,
        ~currency="$",
      )}
      {metricCard(
        ~title="Rev Rec attempts per recovery",
        ~staticValue=run.staticCard.attemptsPerRecovery,
        ~smartValue=run.smartCard.attemptsPerRecovery,
        ~statType=Default,
        ~lowerIsBetter=true,
      )}
      {metricCard(
        ~title="Minutes to recovery (median)",
        ~staticValue=run.staticCard.medianMinutes,
        ~smartValue=run.smartCard.medianMinutes,
        ~statType=Default,
        ~lowerIsBetter=true,
      )}
    </div>
  }
}

module Charts = {
  @react.component
  let make = (~run: portfolioRun) => {
    <div className="flex flex-col gap-6">
      <SectionCard
        title="Recovered by decline reason"
        accessory={<SourceChip kind=Recomputed isFixture=run.isFixture />}>
        <ColumnGraph
          options={run.byReason->reasonChartPayload->ColumnGraphUtils.getColumnGraphOptions}
        />
        <div className="flex flex-col divide-y divide-nd_gray-150 border-t border-nd_gray-150">
          {run.bankRules
          ->Array.map(rule =>
            <div key=rule.reason className="flex items-start justify-between gap-3 py-3">
              <div className="flex flex-col gap-0.5">
                <span className={`${body.md.semibold} text-nd_gray-700`}>
                  {`${rule.reason->reasonLabel} · first charge on ${rule.firstChargeCard}`->React.string}
                </span>
                <span className={`${body.md.medium} text-nd_gray-500`}>
                  {rule.rule->SimulatorGlossary.linkTerms}
                </span>
              </div>
              <SourceChip kind=ScriptedBank isFixture=run.isFixture />
            </div>
          )
          ->React.array}
        </div>
      </SectionCard>
      <SectionCard
        title="Recovered over the run"
        subTitle="Invoices recovered so far, by minute since the run started."
        accessory={<SourceChip kind=Recomputed isFixture=run.isFixture />}>
        <LineGraph options={run.trend->trendChartPayload->LineGraphUtils.getLineGraphOptions} />
      </SectionCard>
    </div>
  }
}

module InvoiceTable = {
  @react.component
  let make = (~run: portfolioRun) => {
    let headerClass = `px-3 py-3 text-left ${body.sm.semibold} text-nd_gray-500 whitespace-nowrap`
    let cellClass = `px-3 py-3 ${body.md.medium} text-nd_gray-700 whitespace-nowrap`
    let copyCells = (copy: option<invoiceCopy>) =>
      switch copy {
      | Some(copy) =>
        let canOpen = !run.isFixture && copy.storyId->LogicUtils.isNonEmptyString
        let attemptsText = `${copy.revrecAttempts->Int.toString} ${copy.revrecAttempts == 1
            ? "attempt"
            : "attempts"}`
        // Status and Rev Rec attempts share one cell, so the table fits next to the dials
        <td className=cellClass>
          <div className="flex flex-col items-start gap-1">
            <div
              className={canOpen ? "cursor-pointer w-fit" : "w-fit"}
              title={canOpen ? "Open in the invoice story" : ""}
              onClick={_ =>
                if canOpen {
                  RescriptReactRouter.push(
                    GlobalVars.appendDashboardPath(
                      ~url=`${RevenueRecoverySidebarValues.simulatorStoryPath}/${copy.storyId}`,
                    ),
                  )
                }}>
              <Table.TableCell cell={copy.status->invoiceStatusLabel} />
            </div>
            <span className={`${body.sm.medium} text-nd_gray-500`}>
              {attemptsText->React.string}
            </span>
          </div>
        </td>
      | None => <td className=cellClass> {"–"->React.string} </td>
      }

    <SectionCard
      title="Invoices"
      subTitle={run.isFixture
        ? "Fixture rows. In a real run, a status opens that copy in the invoice story."
        : "Click a status to open that copy in the invoice story."}
      accessory={<SourceChip kind=FromSandbox isFixture=run.isFixture />}>
      <div className="overflow-x-auto border border-nd_gray-150 rounded-lg">
        <table className="w-full">
          <thead className="bg-nd_gray-25 border-b border-nd_gray-150">
            <tr>
              <th className=headerClass> {"#"->React.string} </th>
              <th className=headerClass> {"Decline reason"->React.string} </th>
              <th className=headerClass> {"Amount"->React.string} </th>
              <th className=headerClass> {"Bank flip"->React.string} </th>
              <th className=headerClass> {"Static retries"->React.string} </th>
              <th className=headerClass> {"Rev Rec"->React.string} </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-nd_gray-150">
            {run.invoices
            ->Array.map(invoice =>
              <tr key={invoice.index->Int.toString}>
                <td className=cellClass> {invoice.index->Int.toString->React.string} </td>
                <td className=cellClass> {invoice.reason->reasonLabel->React.string} </td>
                <td className=cellClass> {invoice.amount->formatMoney->React.string} </td>
                <td className=cellClass>
                  {invoice.flipAfterMin
                  ->Option.mapOr("never", minutes => `${minutes->Float.toString} min`)
                  ->React.string}
                </td>
                {copyCells(invoice.staticCopy)}
                {copyCells(invoice.smartCopy)}
              </tr>
            )
            ->React.array}
          </tbody>
        </table>
      </div>
    </SectionCard>
  }
}

@react.component
let make = (~runIdFromUrl: option<string>) => {
  open LogicUtils
  let simFetch = SimulatorApi.useSimFetch()
  let showToast = ToastAdapter.useShowToast()
  let mixpanelEvent = MixpanelHook.useSendEvent()

  let (dials, setDials) = React.useState(_ => defaultDials)
  let (run, setRun) = React.useState(_ => None)
  let (isBusy, setIsBusy) = React.useState(_ => false)
  let (pollError, setPollError) = React.useState(_ => "")
  // The run whose dials the form shows, so a reopened run fills the form once
  let dialsRunId = React.useRef("")

  let isOver = run->Option.mapOr(false, (r: portfolioRun) => r.status->isRunOver || r.isFixture)
  let isRunning = run->Option.isSome && !isOver

  // Poll a real run until it is done
  React.useEffect(() => {
    switch runIdFromUrl {
    | Some(id) if !isOver => {
        let cancelled = ref(false)
        let poll = async () => {
          try {
            let json = await simFetch(~path=`/sim/portfolio/${id}`, ~method_=Get)
            if !cancelled.contents {
              let polledRun = json->runMapper(~isFixture=false)
              if dialsRunId.current != id {
                dialsRunId.current = id
                setDials(_ => polledRun.dials)
              }
              setRun(_ => Some(polledRun))
              setPollError(_ => "")
            }
          } catch {
          | exn =>
            if !cancelled.contents {
              setPollError(_ =>
                exn->SimulatorUtils.getSimErrorMessage(
                  ~default="The simulator proxy did not answer.",
                )
              )
            }
          }
        }
        poll()->ignore
        let intervalId = setInterval(() => poll()->ignore, pollIntervalMs)
        Some(
          () => {
            cancelled := true
            clearInterval(intervalId)
          },
        )
      }
    | _ => None
    }
  }, (runIdFromUrl, isOver))

  let onRun = async () => {
    setIsBusy(_ => true)
    mixpanelEvent(~eventName="recovery_simulator_portfolio_run")
    try {
      let json = await simFetch(~path="/sim/portfolio/start", ~method_=Post, ~body=dials->startBody)
      let newRun = json->runMapper(~isFixture=false)
      dialsRunId.current = newRun.runId
      setRun(_ => Some(newRun))
      RescriptReactRouter.replace(
        GlobalVars.appendDashboardPath(~url=`${portfolioPath}/${newRun.runId}`),
      )
    } catch {
    | exn => {
        let message = exn->SimulatorUtils.getSimErrorMessage(~default="The run could not start.")

        showToast(~message, ~toastType=ToastError)
      }
    }
    setIsBusy(_ => false)
  }

  let onStop = async () => {
    switch runIdFromUrl {
    | Some(id) =>
      try {
        let json = await simFetch(~path=`/sim/portfolio/${id}/stop`, ~method_=Post)
        setRun(_ => Some(json->runMapper(~isFixture=false)))
      } catch {
      | exn =>
        showToast(
          ~message=exn->SimulatorUtils.getSimErrorMessage(~default="The run could not stop."),
          ~toastType=ToastError,
        )
      }
    | None => ()
    }
  }

  <div className="flex flex-col gap-6">
    <BreadCrumbNavigation
      path=[{title: "Home", link: RevenueRecoverySidebarValues.homePath}]
      currentPageTitle="Portfolio Run"
    />
    <div className="flex items-start justify-between gap-4">
      <PageUtils.PageHeading
        title="Portfolio run"
        subTitle="The same batch of failed invoices, once with static retries and once with Rev Rec. Real sandbox runs; only the bank is scripted."
      />
      <SimulatorGlossary.OpenButton />
    </div>
    <div className="flex flex-col xl:flex-row gap-10 items-start">
      <div className="w-full xl:w-1/3 shrink-0 xl:sticky xl:top-6">
        <DialsForm
          dials
          setDials
          isBusy
          isRunning
          onRun={() => onRun()->ignore}
          onStop={() => onStop()->ignore}
        />
      </div>
      <div className="w-full min-w-0 flex flex-col gap-6">
        <PageUtils.PageHeading
          title="Static retries vs Rev Rec"
          subTitle={run->Option.mapOr(false, r => r.isFixture)
            ? "Fixture data, not from the sandbox"
            : "Live from the sandbox"}
          showPermLink=false
          customTitleStyle="!font-medium !text-xl !text-nd_gray-600"
        />
        {switch run {
        | Some(run) =>
          <>
            <RenderIf condition=run.isFixture>
              <AlertV2Binding
                alertType=Warning
                slot={{
                  slot: <Icon name="nd-toast-warning" size=20 className="text-nd_yellow-500" />,
                }}
                heading="Fixture data, not a sandbox run"
                description="A built-in example in the real result shape, for tests and layout checks. The numbers are made up."
              />
            </RenderIf>
            {[pollError]
            ->Array.concat(run.warnings)
            ->Array.filter(isNonEmptyString)
            ->Array.mapWithIndex((warning, index) =>
              <AlertV2Binding
                key={index->Int.toString}
                alertType=Warning
                slot={{
                  slot: <Icon name="nd-toast-warning" size=20 className="text-nd_yellow-500" />,
                }}
                description=warning
              />
            )
            ->React.array}
            <Progress run />
            // Results wait for the first copy to finish; before that every value is 0
            {if run.isFixture || run.status->isRunOver || hasFinishedCopy(run) {
              <>
                // The proxy's comparison label, next to the numbers: the noise note when both
                // sides share a strategy, otherwise which strategies are compared
                <RenderIf condition={run.comparisonLabel->isNonEmptyString}>
                  <p className={`${body.md.semibold} text-nd_gray-600`}>
                    {(
                      run.sameStrategy
                        ? `${run.comparisonLabel}.`
                        : `Comparison: ${run.comparisonLabel}`
                    )->React.string}
                  </p>
                </RenderIf>
                <NoRetriesBanners run />
                <ResultCards run />
                <div
                  className={`flex flex-wrap gap-x-6 gap-y-2 ${body.md.medium} text-nd_gray-500`}>
                  <span className="flex items-center gap-2">
                    {`Static profile mode: ${run.staticMode->SimulatorTourUtils.retryModeText}`->React.string}
                    <SourceChip kind=FromSandbox isFixture=run.isFixture />
                  </span>
                  <span className="flex items-center gap-2">
                    {`Rev Rec profile mode: ${run.smartMode->SimulatorTourUtils.retryModeText}`->React.string}
                    <SourceChip kind=FromSandbox isFixture=run.isFixture />
                  </span>
                </div>
                <Charts run />
                <InvoiceTable run />
              </>
            } else {
              <div className={`${cardStyle} px-6 py-8`}>
                <p className={`${body.md.medium} text-nd_gray-500 text-center`}>
                  {"Results appear here as soon as the first copies reach an end state."->React.string}
                </p>
              </div>
            }}
          </>
        | None =>
          <div className={`${cardStyle} px-6 py-10`}>
            <p className={`${body.md.medium} text-nd_gray-500 text-center`}>
              {(
                runIdFromUrl->Option.isSome
                  ? "Loading the run."
                  : "Set the dials and press Run. Progress shows here, then the results side by side."
              )->React.string}
            </p>
          </div>
        }}
      </div>
    </div>
  </div>
}
