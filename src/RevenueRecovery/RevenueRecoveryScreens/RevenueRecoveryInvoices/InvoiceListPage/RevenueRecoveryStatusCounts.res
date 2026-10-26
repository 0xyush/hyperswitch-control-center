// recovery-list answers at most 100 invoices a page; the fallback counts up to 10 pages
let listPageSize = 100
let listMaxInvoices = 1000

@react.component
let make = () => {
  open APIUtils
  open LogicUtils
  open Typography
  let getURL = useGetURL()
  let fetchDetails = useGetMethod()
  // The aggregate may be missing (404 on upstream Hyperswitch main), so it fails quietly
  let fetchQuietly = useGetMethod(~showErrorToast=false)
  let showToast = ToastAdapter.useShowToast()
  let {transactionEntity} = React.useContext(UserInfoProvider.defaultContext).getResolvedUserInfo()
  let {updateExistingKeys, removeKeys, filterValueJson, filterValue, filterKeys, setfilterKeys} =
    FilterContext.filterContext->React.useContext
  let (statusWithCount, setStatusWithCount) = React.useState(_ => Dict.make())
  let (total, setTotal) = React.useState(_ => 0)
  let statusKey = RevenueRecoveryOrderUtils.recoveryStatusFilterKey

  // falls back to the default range until a date is picked
  let (startTime, endTime) = React.useMemo(() => {
    let defaultDate = HSwitchRemoteFilter.getDateFilteredObject(~range=30)
    (
      filterValueJson->getString(OrderUIUtils.startTimeFilterKey(V2), defaultDate.start_time),
      filterValueJson->getString(OrderUIUtils.endTimeFilterKey(V2), defaultDate.end_time),
    )
  }, filterValue)

  // Without recovery-aggregate, count each invoice's status from recovery-list, page by page
  let countFromList = async () => {
    let counts = Dict.make()
    let offset = ref(0)
    let total = ref(0)
    let hasMore = ref(true)
    while hasMore.contents {
      let url = getURL(
        ~entityName=V2(V2_RECOVERY_INVOICES_LIST),
        ~methodType=Get,
        ~queryParameters=Some(
          `created.gte=${startTime}&created.lte=${endTime}&limit=${listPageSize->Int.toString}&offset=${offset.contents->Int.toString}`,
        ),
      )
      let responseDict = (await fetchDetails(url, ~version=V2))->getDictFromJsonObject
      let page = responseDict->getArrayFromDict("data", [])
      page->Array.forEach(invoice => {
        let status = invoice->getDictFromJsonObject->getString("status", "")
        counts->Dict.set(status, (counts->getInt(status, 0) + 1)->JSON.Encode.int)
      })
      offset := offset.contents + page->Array.length
      total := responseDict->getInt("total_count", offset.contents)
      hasMore :=
        page->Array.length == listPageSize &&
        offset.contents < total.contents &&
        offset.contents < listMaxInvoices
    }
    (counts, total.contents)
  }

  let loadCounts = async () => {
    try {
      let (counts, totalCount) = try {
        let url = getURL(
          ~entityName=V2(RECOVERY_AGGREGATE),
          ~methodType=Get,
          ~queryParameters=Some(`start_time=${startTime}&end_time=${endTime}`),
        )
        let responseDict = (await fetchQuietly(url, ~version=V2))->getDictFromJsonObject
        (responseDict->getDictfromDict("status_with_count"), responseDict->getInt("total_count", 0))
      } catch {
      | _ => await countFromList()
      }
      setStatusWithCount(_ => counts)
      setTotal(_ => totalCount)
    } catch {
    | _ =>
      showToast(~toastType=ToastError, ~message="Failed to fetch status counts", ~autoClose=true)
    }
  }

  React.useEffect(() => {
    if startTime->isNonEmptyString && endTime->isNonEmptyString {
      loadCounts()->ignore
    }
    None
  }, (startTime, endTime, transactionEntity))

  let appliedStatuses = filterValueJson->getStrArrayFromDict(statusKey, [])

  let onClick = status => {
    switch status {
    | Some(value) =>
      updateExistingKeys(Dict.fromArray([(statusKey, `[${value}]`)]))
      setfilterKeys(_ =>
        filterKeys->Array.includes(statusKey) ? filterKeys : [...filterKeys, statusKey]
      )
    | None => removeKeys([statusKey])
    }
  }

  let card = (~label, ~count, ~isActive, ~status) =>
    <div
      key=label
      className={`flex min-w-0 flex-col justify-center flex-auto gap-1 bg-white border rounded-md px-4 py-2.5 cursor-pointer hover:bg-nd_gray-50 ${isActive
          ? "border-primary"
          : ""}`}
      onClick={_ => onClick(status)}>
      <p
        className={`${body.md.semibold} truncate ${isActive
            ? "text-primary"
            : "text-nd_gray-700"}`}>
        {label->React.string}
      </p>
      <p className={`${body.md.semibold} ${isActive ? "text-primary" : "text-nd_gray-900"}`}>
        {count->Int.toString->React.string}
      </p>
    </div>

  <div className="flex flex-wrap gap-3 mb-6">
    {card(~label="All", ~count=total, ~isActive=appliedStatuses->isEmptyArray, ~status=None)}
    {RevenueRecoveryOrderUtils.recoveryMetricStatuses
    ->Array.map(metricStatus => {
      let status = (metricStatus :> string)
      card(
        ~label=status->snakeToTitle,
        ~count=statusWithCount->getInt(status, 0),
        ~isActive=appliedStatuses == [status],
        ~status=Some(status),
      )
    })
    ->React.array}
  </div>
}
