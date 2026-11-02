// Sign up as the customer (2 Nov): before the Invoice story, the visitor signs up for FinnstaAI, a
// made-up AI subscription, on a checkout like a streaming service's. The first month is a real test
// charge that saves the card (POST /sim/signup). The signup stands for last month: once it is paid,
// a calendar runs one month on, the renewal charge goes to the bank, and the bank declines it. The story form then
// charges that renewal (renewal mode), and the story picks why it fails.
open Typography
open SimulatorTestCards

type result = {
  signupId: string,
  plan: string,
  // Minor units, as the proxy keeps them: 2000 = $20.00
  amount: int,
  currency: string,
  // "charge": the first month paid
  mode: string,
  last4: string,
}

let logo = "/assets/simulator/finnstaai-logo.svg"
let mark = "/assets/simulator/finnstaai-mark.svg"
let brandName = "FinnstaAI"
let green = "#0E8A6A"
let ink = "#1F2430"

// (id, name, monthly amount in minor units, line, what it includes)
let plans = [
  (
    "starter",
    "Starter",
    2000,
    "For trying it out",
    ["AI budget assistant", "Connect up to 3 accounts", "Monthly spending report", "Email support"],
  ),
  (
    "growth",
    "Growth",
    10000,
    "For everyday work",
    [
      "Everything in Starter",
      "Unlimited accounts",
      "Cash-flow forecasts",
      "Tax-ready exports",
      "Priority support",
    ],
  ),
  (
    "scale",
    "Scale",
    20000,
    "For a whole team",
    [
      "Everything in Growth",
      "Up to 10 team seats",
      "Shared workspaces and approvals",
      "Audit trail",
      "A dedicated account manager",
    ],
  ),
]

let states = [
  "AL",
  "AK",
  "AZ",
  "AR",
  "CA",
  "CO",
  "CT",
  "DE",
  "DC",
  "FL",
  "GA",
  "HI",
  "ID",
  "IL",
  "IN",
  "IA",
  "KS",
  "KY",
  "LA",
  "ME",
  "MD",
  "MA",
  "MI",
  "MN",
  "MS",
  "MO",
  "MT",
  "NE",
  "NV",
  "NH",
  "NJ",
  "NM",
  "NY",
  "NC",
  "ND",
  "OH",
  "OK",
  "OR",
  "PA",
  "RI",
  "SC",
  "SD",
  "TN",
  "TX",
  "UT",
  "VT",
  "VA",
  "WA",
  "WV",
  "WI",
  "WY",
]

let dollars = minor => `$${(minor->Int.toFloat /. 100.0)->Float.toFixedWithPrecision(~digits=2)}`
// "20.00", as the story form's Amount field keeps it
let major = minor => (minor->Int.toFloat /. 100.0)->Float.toFixedWithPrecision(~digits=2)

let pad = n => n < 10 ? `0${n->Int.toString}` : n->Int.toString
let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
let midnight = d =>
  Date.makeWithYMD(~year=d->Date.getFullYear, ~month=d->Date.getMonth, ~date=d->Date.getDate)
// The signup stands for last month: the same day, one month back
let monthAgo = () => {
  let now = Date.make()
  Date.makeWithYMD(
    ~year=now->Date.getFullYear,
    ~month=now->Date.getMonth - 1,
    ~date=now->Date.getDate,
  )
}
let usDate = d =>
  `${(d->Date.getMonth + 1)->pad}/${d->Date.getDate->pad}/${d->Date.getFullYear->Int.toString}`
let shortDate = d => `${months->Array.getUnsafe(d->Date.getMonth)} ${d->Date.getDate->Int.toString}`
let plusDays = (d, n) =>
  Date.makeWithYMD(~year=d->Date.getFullYear, ~month=d->Date.getMonth, ~date=d->Date.getDate + n)

let brandLine = last4 => last4 == "4444" ? `Mastercard ••${last4}` : `Visa ••${last4}`

// The story form's step 2 in renewal mode: this month's renewal on the card saved at signup. A
// picked story runs it; working says what is going on until Rev Rec has it.
module RenewalCharge = {
  @react.component
  let make = (~result: result, ~working: option<string>=?) =>
    <AddDataAttributes attributes=[("data-sim", "renewal-charge")]>
      <div className="rounded-xl border border-nd_gray-200 bg-white p-6 flex flex-col gap-5">
        <img src=logo alt=brandName className="h-8 w-fit" />
        <div className="flex flex-col gap-1">
          <span className={`${body.sm.semibold} text-nd_gray-500`}>
            {"This month's renewal"->React.string}
          </span>
          <span className={`${heading.md.semibold} text-nd_gray-800`}>
            {`${brandName} ${result.plan} · ${result.amount->dollars}`->React.string}
          </span>
          <span className={`${body.md.medium} text-nd_gray-600`}>
            {`On ${result.last4->brandLine}, saved at signup. The bank declined it.`->React.string}
          </span>
        </div>
        {switch working {
        | Some(text) =>
          <div
            className={`flex items-center gap-3 rounded-lg bg-nd_gray-50 border border-nd_gray-150 px-4 py-3 ${body.md.semibold} text-nd_gray-700`}>
            <span
              className="h-4 w-4 shrink-0 animate-spin rounded-full border-2 border-nd_gray-300 border-t-[#1F2430]"
            />
            {text->React.string}
          </div>
        | None =>
          <p className={`${body.md.medium} text-nd_gray-500`}>
            {"Pick the customer's situation on the left. Rev Rec then takes over the failed renewal."->React.string}
          </p>
        }}
      </div>
    </AddDataAttributes>
}

// One labelled box, as in the reference checkout: the label small on top, the value under it
let boxClass = "flex flex-col justify-center rounded-xl border border-nd_gray-300 bg-white px-4 h-[54px] min-w-0 focus-within:border-[#1F2430]"

module Field = {
  @react.component
  let make = (~label, ~value, ~onChange, ~placeholder="", ~inputMode="text", ~maxLength=80) =>
    <label className=boxClass>
      <span className={`${body.xs.medium} text-nd_gray-500`}> {label->React.string} </span>
      <input
        value
        placeholder
        inputMode
        maxLength
        ariaLabel=label
        onChange={e => onChange(ReactEvent.Form.target(e)["value"])}
        className={`w-full bg-transparent outline-none ${body.lg.medium} text-nd_gray-800 placeholder:text-nd_gray-400`}
      />
    </label>
}

type suggestion = {label: string, line: string, city: string, state: string, postcode: string}

// Address, with suggestions as the visitor types (GET /sim/address: Photon, OpenStreetMap). Picking
// one fills the street, city, state and postcode.
module AddressField = {
  @react.component
  let make = (~value, ~onChange, ~onPick: suggestion => unit) => {
    let simFetch = SimulatorApi.useSimFetch()
    let (items, setItems) = React.useState(_ => [])
    let (isOpen, setIsOpen) = React.useState(_ => false)
    // Only typing asks for suggestions; a pick or a sample fill does not
    let typed = React.useRef(false)
    React.useEffect(() => {
      if !typed.current || value->String.trim->String.length < 3 {
        setItems(_ => [])
        None
      } else {
        let id = setTimeout(() => {
          let read = async () =>
            try {
              open LogicUtils
              let json = await simFetch(
                ~path=`/sim/address?q=${value->Js.Global.encodeURIComponent}`,
                ~method_=Get,
              )
              setItems(
                _ =>
                  json
                  ->getDictFromJsonObject
                  ->getArrayFromDict("suggestions", [])
                  ->Array.map(
                    item => {
                      let o = item->getDictFromJsonObject
                      {
                        label: o->getString("label", ""),
                        line: o->getString("line", ""),
                        city: o->getString("city", ""),
                        state: o->getString("state", ""),
                        postcode: o->getString("postcode", ""),
                      }
                    },
                  ),
              )
              setIsOpen(_ => true)
            } catch {
            | _ => ()
            }
          read()->ignore
        }, 300)
        Some(() => clearTimeout(id))
      }
    }, [value])
    <div className="relative">
      <label className=boxClass>
        <span className={`${body.xs.medium} text-nd_gray-500`}> {"Address"->React.string} </span>
        <input
          value
          ariaLabel="Address"
          autoComplete="off"
          maxLength=120
          onChange={e => {
            typed.current = true
            onChange(ReactEvent.Form.target(e)["value"])
          }}
          onFocus={_ => setIsOpen(_ => true)}
          onBlur={_ => setTimeout(() => setIsOpen(_ => false), 150)->ignore}
          className={`w-full bg-transparent outline-none ${body.lg.medium} text-nd_gray-800 placeholder:text-nd_gray-400`}
        />
      </label>
      <RenderIf condition={isOpen && items->Array.length > 0}>
        <AddDataAttributes attributes=[("data-sim", "address-suggestions")]>
          <div
            className="absolute z-30 mt-1 w-full overflow-hidden rounded-xl border border-nd_gray-200 bg-white shadow-lg">
            {items
            ->Array.map(item =>
              <button
                key=item.label
                type_="button"
                onMouseDown={e => {
                  ReactEvent.Mouse.preventDefault(e)
                  typed.current = false
                  setIsOpen(_ => false)
                  onPick(item)
                }}
                className="flex w-full flex-col items-start px-4 py-2.5 text-left hover:bg-nd_gray-50">
                <span className={`${body.md.semibold} text-nd_gray-800`}>
                  {item.line->React.string}
                </span>
                <span className={`${body.sm.medium} text-nd_gray-500`}>
                  {`${item.city}, ${item.state} ${item.postcode}`->React.string}
                </span>
              </button>
            )
            ->React.array}
            <div className="border-t border-nd_gray-150 px-4 py-1.5 text-[10px] text-nd_gray-400">
              {"Addresses © OpenStreetMap contributors"->React.string}
            </div>
          </div>
        </AddDataAttributes>
      </RenderIf>
    </div>
  }
}

module StateField = {
  @react.component
  let make = (~value, ~onChange) =>
    <label className=boxClass>
      <span className={`${body.xs.medium} text-nd_gray-500`}> {"State"->React.string} </span>
      <select
        value
        ariaLabel="State"
        onChange={e => onChange(ReactEvent.Form.target(e)["value"])}
        className={`w-full bg-transparent outline-none ${body.lg.medium} ${value == ""
            ? "text-nd_gray-400"
            : "text-nd_gray-800"}`}>
        <option value=""> {"Select"->React.string} </option>
        {states->Array.map(s => <option key=s value=s> {s->React.string} </option>)->React.array}
      </select>
    </label>
}

// The first text box in an element gets the cursor
let focusFirstInput: Dom.element => unit = %raw(`function (el) {
  var input = el.querySelector("input:not([type=checkbox])");
  if (input) input.focus();
}`)

type phase = Form | Paid(result) | Later(result) | Charging(result) | Declined(result)

let css = `
@keyframes sgn-hand { from { transform: rotate(0deg); } to { transform: rotate(720deg); } }
@keyframes sgn-pop { from { opacity: 0; transform: translateY(8px) scale(.98); } to { opacity: 1; transform: none; } }
@keyframes sgn-ring { from { stroke-dashoffset: 176; } to { stroke-dashoffset: 0; } }
@keyframes sgn-tick { from { stroke-dashoffset: 40; } to { stroke-dashoffset: 0; } }
.sgn-hand { transform-origin: 32px 32px; animation: sgn-hand 2.6s cubic-bezier(.4,0,.2,1) forwards; }
.sgn-pop { animation: sgn-pop .45s cubic-bezier(.2,.8,.2,1) backwards; }
.sgn-ring { stroke-dasharray: 176; animation: sgn-ring .7s cubic-bezier(.4,0,.2,1) forwards; }
.sgn-tick { stroke-dasharray: 40; stroke-dashoffset: 40; animation: sgn-tick .35s .6s ease-out forwards; }
@media (prefers-reduced-motion: reduce) { .sgn-hand, .sgn-pop, .sgn-ring, .sgn-tick { animation: none; stroke-dashoffset: 0; } }
`

// The first month is paid: a tick draws, then the month runs on
module PaidNow = {
  @react.component
  let make = (~result: result, ~onEnd) => {
    React.useEffect(() => {
      let id = setTimeout(() => onEnd(), 2200)
      Some(() => clearTimeout(id))
    }, [])
    <AddDataAttributes attributes=[("data-sim", "signup-paid")]>
      <div className="sgn-pop flex flex-col items-center gap-4 py-16 text-center">
        <svg width="72" height="72" viewBox="0 0 64 64" ariaHidden=true>
          <circle cx="32" cy="32" r="28" fill="#E7F6F1" />
          <circle
            className="sgn-ring"
            cx="32"
            cy="32"
            r="28"
            fill="none"
            stroke=green
            strokeWidth="4"
            strokeLinecap="round"
            transform="rotate(-90 32 32)"
          />
          <path
            className="sgn-tick"
            d="M20 33 L28 41 L44 24"
            fill="none"
            stroke=green
            strokeWidth="5"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
        <span className={`${heading.md.semibold} text-nd_gray-800`}>
          {"Payment successful"->React.string}
        </span>
        <span className={`${body.lg.medium} text-nd_gray-600`}>
          {`${result.amount->dollars} · ${brandName} ${result.plan} · ${result.last4->brandLine}`->React.string}
        </span>
        <span className={`${body.md.medium} text-nd_gray-500`}>
          {`Welcome to ${brandName}. Your plan renews every month.`->React.string}
        </span>
      </div>
    </AddDataAttributes>
  }
}

// One month on: the calendar counts the days from the signup to today
module MonthLater = {
  @react.component
  let make = (~result: result, ~onEnd) => {
    let start = monthAgo()
    // Whole days from the signup to today (both at midnight, so the time of day does not count)
    let total =
      Math.round(
        (Date.make()->midnight->Date.getTime -. start->Date.getTime) /. 86_400_000.0,
      )->Float.toInt
    let (day, setDay) = React.useState(_ => 0)
    React.useEffect(() => {
      let id = setInterval(() => setDay(d => d < total ? d + 1 : d), 2600 / Math.Int.max(total, 1))
      let endId = setTimeout(() => onEnd(), 3600)
      Some(
        () => {
          clearInterval(id)
          clearTimeout(endId)
        },
      )
    }, [])
    let shown = start->plusDays(day)
    <div className="sgn-pop flex flex-col items-center gap-6 py-16">
      <span className={`${body.lg.semibold} text-nd_gray-500`}>
        {`Subscribed to ${brandName} ${result.plan}. One month later…`->React.string}
      </span>
      <div className="flex items-center gap-8">
        <svg width="64" height="64" viewBox="0 0 64 64" ariaHidden=true>
          <circle cx="32" cy="32" r="29" fill="white" stroke="#D0D5DD" strokeWidth="3" />
          <line x1="32" y1="32" x2="32" y2="15" stroke=ink strokeWidth="3" strokeLinecap="round" />
          <line
            className="sgn-hand"
            x1="32"
            y1="32"
            x2="32"
            y2="9"
            stroke=green
            strokeWidth="2.5"
            strokeLinecap="round"
          />
          <circle cx="32" cy="32" r="3" fill=ink />
        </svg>
        <div
          className="w-40 overflow-hidden rounded-2xl border border-nd_gray-200 bg-white shadow-sm text-center">
          <div className={`bg-[#0E8A6A] py-1.5 ${body.md.semibold} text-white`}>
            {months->Array.getUnsafe(shown->Date.getMonth)->React.string}
          </div>
          <div className="py-3 text-5xl font-semibold tabular-nums text-nd_gray-800">
            {shown->Date.getDate->Int.toString->React.string}
          </div>
        </div>
      </div>
      <span className={`${body.md.medium} text-nd_gray-500 tabular-nums`}>
        {`Day ${day->Int.toString} of ${total->Int.toString} · next renewal ${Date.make()->shortDate}`->React.string}
      </span>
    </div>
  }
}

let flowCss = `
@keyframes sgn-go { 0% { left: 9%; opacity: 0; } 8% { opacity: 1; } 45% { left: 50%; } 88% { left: 91%; opacity: 1; } 100% { left: 91%; opacity: 0; } }
@keyframes sgn-back { 0% { left: 91%; opacity: 0; } 10% { opacity: 1; } 90% { left: 9%; opacity: 1; } 100% { left: 9%; opacity: 0; } }
@keyframes sgn-deny { to { border-color: #F04438; background: #FEF3F2; } }
@keyframes sgn-show { from { opacity: 0; transform: translateY(4px); } to { opacity: 1; transform: none; } }
@keyframes sgn-shake { 0%, 100% { transform: translateX(0); } 25% { transform: translateX(-4px); } 75% { transform: translateX(4px); } }
.sgn-go { animation: sgn-go 1.8s cubic-bezier(.45,0,.25,1) forwards; }
.sgn-back { opacity: 0; animation: sgn-back 1.1s 2.2s cubic-bezier(.45,0,.25,1) forwards; }
.sgn-deny { animation: sgn-deny .25s 1.75s ease-out forwards, sgn-shake .35s 1.8s ease-in-out; }
.sgn-show { opacity: 0; animation: sgn-show .3s 1.9s ease-out forwards; }
@media (prefers-reduced-motion: reduce) { .sgn-go, .sgn-back { animation: none; opacity: 0; } .sgn-deny { animation: sgn-deny 0s forwards; } .sgn-show { animation: none; opacity: 1; } }
`

// Renewal day: the billing platform charges the saved card, the charge goes through the processor
// to the customer's bank, and the bank says no
module ChargeFlow = {
  @react.component
  let make = (~result: result, ~onEnd) => {
    let (stage, setStage) = React.useState(_ => 0)
    React.useEffect(() => {
      let a = setTimeout(() => setStage(_ => 1), 900)
      let b = setTimeout(() => setStage(_ => 2), 1900)
      let c = setTimeout(() => onEnd(), 3900)
      Some(
        () => {
          clearTimeout(a)
          clearTimeout(b)
          clearTimeout(c)
        },
      )
    }, [])
    let node = (~icon, ~title, ~line, ~extra="") =>
      <div
        className={`relative z-10 flex flex-col items-center gap-2 w-40 rounded-2xl border-2 border-nd_gray-200 bg-white px-3 py-4 text-center ${extra}`}>
        icon
        <span className={`${body.md.semibold} text-nd_gray-800`}> {title->React.string} </span>
        <span className={`${body.sm.medium} text-nd_gray-500`}> {line->React.string} </span>
      </div>
    let cardIcon =
      <svg width="40" height="28" viewBox="0 0 40 28" ariaHidden=true>
        <rect
          x="1" y="1" width="38" height="26" rx="4" fill="#EEF2F7" stroke="#98A2B3" strokeWidth="2"
        />
        <rect x="1" y="7" width="38" height="5" fill="#98A2B3" />
        <rect x="6" y="18" width="12" height="3" rx="1.5" fill="#98A2B3" />
      </svg>
    let bankIcon =
      <svg width="40" height="32" viewBox="0 0 40 32" ariaHidden=true>
        <path d="M20 2 L37 10 L3 10 Z" fill="#98A2B3" />
        <rect x="6" y="12" width="4" height="13" fill="#98A2B3" />
        <rect x="14" y="12" width="4" height="13" fill="#98A2B3" />
        <rect x="22" y="12" width="4" height="13" fill="#98A2B3" />
        <rect x="30" y="12" width="4" height="13" fill="#98A2B3" />
        <rect x="3" y="27" width="34" height="3" fill="#98A2B3" />
      </svg>
    <AddDataAttributes attributes=[("data-sim", "renewal-flow")]>
      <div className="sgn-pop flex flex-col items-center gap-8 py-12">
        <style> {flowCss->React.string} </style>
        <span className={`${body.lg.semibold} text-nd_gray-500`}>
          {`Renewal day, ${Date.make()->shortDate}: ${brandName} charges the saved card`->React.string}
        </span>
        <div className="relative w-full max-w-[640px] flex items-center justify-between">
          // The wire between the three, and the charge moving along it
          <div
            className="absolute left-[9%] right-[9%] top-1/2 h-0.5 -translate-y-1/2 bg-nd_gray-200"
          />
          <span
            className="sgn-go absolute top-1/2 z-0 h-4 w-4 -translate-x-1/2 -translate-y-1/2 rounded-full bg-[#2D5BD7] shadow-[0_0_0_6px_rgba(45,91,215,.18)]"
          />
          <span
            className="sgn-back absolute top-1/2 z-0 h-4 w-4 -translate-x-1/2 -translate-y-1/2 rounded-full bg-[#F04438] shadow-[0_0_0_6px_rgba(240,68,56,.18)]"
          />
          {node(
            ~icon=<img src=mark alt="" className="h-8 w-8" />,
            ~title=`${brandName} billing`,
            ~line=`Renews ${result.amount->dollars}`,
          )}
          {node(~icon=cardIcon, ~title="Payment processor", ~line=result.last4->brandLine)}
          <div className="relative">
            {node(
              ~icon=bankIcon,
              ~title="Customer's bank",
              ~line="Approves or declines",
              ~extra="sgn-deny",
            )}
            <span
              className={`sgn-show absolute z-30 -top-3 left-1/2 -translate-x-1/2 rounded-full bg-[#F04438] px-2.5 py-0.5 ${body.xs.semibold} text-white`}>
              {"Declined"->React.string}
            </span>
          </div>
        </div>
        <span className={`${body.md.medium} text-nd_gray-600`}>
          {switch stage {
          | 0 => `Charging ${result.last4->brandLine} for ${result.amount->dollars}…`
          | 1 => "The processor asks the customer's bank…"
          | _ => "The bank declined the renewal."
          }->React.string}
        </span>
      </div>
    </AddDataAttributes>
  }
}

// The renewal failed: the control center's failed panel, as the story's decline
module RenewalDeclined = {
  @react.component
  let make = (~result: result, ~onNext) => {
    let message = `Declined · ${result.amount->dollars} · ${result.last4->brandLine}`
    <AddDataAttributes attributes=[("data-sim", "renewal-declined")]>
      <div className="sgn-pop flex flex-col gap-5 max-w-[560px] w-full mx-auto">
        <span className={`${body.md.semibold} text-nd_gray-500`}>
          {`${brandName} ${result.plan} renewal · ${Date.make()->shortDate}`->React.string}
        </span>
        <div className="bg-white border border-nd_gray-200 rounded-xl p-5">
          <style> {SimulatorCheckout.css->React.string} </style>
          <div className="hsw-failed">
            <SDKProvider.Provider value={...SDKProvider.defaultValue, errorMessage: message}>
              <SDKPayment.PaymentStatusPage
                config=SimulatorCheckout.failedConfig
                buttonText=""
                buttonOnClick={_ => ()}
                isButtonVisible=false
              />
            </SDKProvider.Provider>
          </div>
        </div>
        <Button
          text="See why it failed and what Rev Rec does"
          buttonType=Primary
          buttonSize=Large
          customButtonStyle="!w-full"
          rightIcon={FontAwesome("arrow-right")}
          onClick={_ => onNext()}
        />
      </div>
    </AddDataAttributes>
  }
}

@react.component
let make = (~onDone: result => unit, ~onSkip) => {
  let simFetch = SimulatorApi.useSimFetch()
  let (phase, setPhase) = React.useState(_ => Form)
  let (planId, setPlanId) = React.useState(_ => "starter")
  // Step 1 is the plan; Continue opens step 2, the payment, as on the Invoice story form
  let (planPicked, setPlanPicked) = React.useState(_ => false)
  let paymentRef = React.useRef(Nullable.null)
  let openPayment = () => {
    setPlanPicked(_ => true)
    // The blur fades out; then the cursor waits in First Name
    setTimeout(
      () => paymentRef.current->Nullable.toOption->Option.forEach(focusFirstInput),
      320,
    )->ignore
  }
  let stepLabel = (~number, ~text, ~isDone, ~isActive) =>
    <div className="flex items-center gap-2.5">
      <span
        className={`flex h-6 w-6 items-center justify-center rounded-full ${body.sm.semibold} ${isDone
            ? "bg-nd_green-500 text-white"
            : isActive
            ? "bg-primary text-white"
            : "bg-nd_gray-200 text-nd_gray-500"}`}>
        {(isDone ? "✓" : number)->React.string}
      </span>
      <span
        className={`${body.md.semibold} ${isActive || isDone
            ? "text-nd_gray-800"
            : "text-nd_gray-400"}`}>
        {text->React.string}
      </span>
    </div>
  // The visitor types every detail; only the card's last four leave this browser
  let (first, setFirst) = React.useState(_ => "")
  let (last, setLast) = React.useState(_ => "")
  let (address, setAddress) = React.useState(_ => "")
  let (city, setCity) = React.useState(_ => "")
  let (state, setState) = React.useState(_ => "")
  let (postcode, setPostcode) = React.useState(_ => "")
  let (number, setNumber) = React.useState(_ => "")
  let (expMonth, setExpMonth) = React.useState(_ => "")
  let (expYear, setExpYear) = React.useState(_ => "")
  let (cvv, setCvv) = React.useState(_ => "")
  let (agreed, setAgreed) = React.useState(_ => false)
  let (isBusy, setIsBusy) = React.useState(_ => false)
  let (error, setError) = React.useState(_ => "")

  let (_, planName, amount, _, _) =
    plans->Array.find(((id, _, _, _, _)) => id == planId)->Option.getOr(plans->Array.getUnsafe(0))
  let d = number->digits
  let card = switch d->detect {
  | Test(card, _) if card->isVisitorCard && (d->brandOf == Visa || d->brandOf == Mastercard) =>
    Some(card)
  | _ => None
  }
  let cardError = switch d->detect {
  | _ if d->String.length < 16 => ""
  | Test(_, _) if card->Option.isSome => ""
  | _ => "Use a test card."
  }
  let monthOk = expMonth->Int.fromString->Option.mapOr(false, m => m >= 1 && m <= 12)
  let yearOk = expYear->Int.fromString->Option.mapOr(false, y => y >= Date.make()->Date.getFullYear)
  let cvvOk = cvv->digits->String.length >= 3
  let filled = [first, last, address, city, state, postcode]->Array.every(v => v->String.trim != "")
  let complete = card->Option.isSome && monthOk && yearOk && cvvOk && filled
  let canSubscribe = !isBusy && complete && agreed

  let useTestCard = pan => {
    setNumber(_ => pan->grouped)
    setExpMonth(_ => "12")
    setExpYear(_ => "2030")
    setCvv(_ => "123")
  }

  let subscribe = async () => {
    setIsBusy(_ => true)
    setError(_ => "")
    try {
      let body =
        [
          ("plan", planId->JSON.Encode.string),
          ("card", d->String.sliceToEnd(~start=-4)->JSON.Encode.string),
          ("mode", "charge"->JSON.Encode.string),
        ]
        ->Dict.fromArray
        ->JSON.Encode.object
      let json = await simFetch(~path="/sim/signup", ~method_=Post, ~body)
      open LogicUtils
      let o = json->getDictFromJsonObject
      let result = {
        signupId: o->getString("signupId", ""),
        plan: o->getString("plan", planName),
        amount: o->getInt("amount", amount),
        currency: o->getString("currency", "USD"),
        mode: o->getString("mode", "charge"),
        last4: o->getString("last4", d->String.sliceToEnd(~start=-4)),
      }
      setPhase(_ => Paid(result))
    } catch {
    | _ => setError(_ => "The payment did not go through. Try again in a moment.")
    }
    setIsBusy(_ => false)
  }

  // Small fill buttons under the fields: sample details, or a test card
  let pill = (~label, ~icon=React.null, ~onClick) =>
    <button
      type_="button"
      onClick={_ => onClick()}
      className={`flex items-center gap-1.5 rounded-full border border-nd_gray-200 bg-white px-3 py-1 ${body.sm.semibold} text-nd_gray-700 hover:border-nd_gray-400`}>
      icon
      {label->React.string}
    </button>
  let testCardButton = (~label, ~pan) =>
    pill(
      ~label,
      ~icon=SimulatorCheckout.icon(
        ~name=pan->String.startsWith("4") ? "visa-light" : "mastercard",
        ~size=14,
        ~width=22,
      ),
      ~onClick=() => useTestCard(pan),
    )
  let sampleName = () => {
    setFirst(_ => "John")
    setLast(_ => "Doe")
  }
  let sampleAddress = () => {
    setAddress(_ => "1 Market St")
    setCity(_ => "San Francisco")
    setState(_ => "CA")
    setPostcode(_ => "94105")
  }

  <div className="flex flex-col gap-6">
    <style> {css->React.string} </style>
    {switch phase {
    | Paid(result) => <PaidNow result onEnd={() => setPhase(_ => Later(result))} />
    | Later(result) => <MonthLater result onEnd={() => setPhase(_ => Charging(result))} />
    | Charging(result) => <ChargeFlow result onEnd={() => setPhase(_ => Declined(result))} />
    | Declined(result) => <RenewalDeclined result onNext={() => onDone(result)} />
    | Form =>
      <AddDataAttributes attributes=[("data-sim", "signup")]>
        // One screen: the logo and Skip on top; the plan and the bill on the left, the payment on
        // the right
        <div className="w-full max-w-[1180px] mx-auto flex flex-col gap-5">
          <div className="flex items-center justify-between gap-4">
            <img src=logo alt=brandName className="h-10 w-fit" />
            <button
              type_="button"
              className={`text-blue-500 hover:text-blue-700 ${body.md.semibold}`}
              onClick={_ => onSkip()}>
              {"Skip signup"->React.string}
            </button>
          </div>
          <div
            className="w-full grid grid-cols-1 lg:grid-cols-[minmax(0,0.85fr)_minmax(0,1.15fr)] gap-8 items-start">
            <div className="flex flex-col gap-5">
              <div className="flex flex-col gap-2.5">
                {stepLabel(
                  ~number="1",
                  ~text="Choose your plan",
                  ~isDone=planPicked,
                  ~isActive=true,
                )}
                {plans
                ->Array.map(((id, name, monthly, line, includes)) => {
                  let isOn = id == planId
                  <button
                    key=id
                    type_="button"
                    onClick={_ => setPlanId(_ => id)}
                    className={`flex flex-col gap-3 rounded-xl border-2 px-4 py-3 text-left transition-colors ${isOn
                        ? "border-[#0E8A6A] bg-[#F0FAF6]"
                        : "border-nd_gray-200 bg-white hover:border-nd_gray-400"}`}>
                    <span className="flex w-full items-center justify-between gap-3">
                      <span className="flex items-center gap-3">
                        <span
                          className={`h-4 w-4 shrink-0 rounded-full border-2 ${isOn
                              ? "border-[#0E8A6A] bg-[#0E8A6A] shadow-[inset_0_0_0_3px_white]"
                              : "border-nd_gray-300"}`}
                        />
                        <span className="flex flex-col">
                          <span className={`${body.md.semibold} text-nd_gray-800`}>
                            {name->React.string}
                          </span>
                          <span className={`${body.sm.medium} text-nd_gray-500`}>
                            {line->React.string}
                          </span>
                        </span>
                      </span>
                      <span className={`${body.lg.semibold} text-nd_gray-800 whitespace-nowrap`}>
                        {monthly->dollars->React.string}
                        <span className={`${body.sm.medium} text-nd_gray-500`}>
                          {" / month"->React.string}
                        </span>
                      </span>
                    </span>
                    // What the picked plan includes
                    <RenderIf condition=isOn>
                      <ul className="flex flex-col gap-1.5 border-t border-[#CDEBE0] pl-7 pt-3">
                        {includes
                        ->Array.map(item =>
                          <li
                            key=item
                            className={`flex items-center gap-2 ${body.sm.medium} text-nd_gray-700`}>
                            <svg width="14" height="14" viewBox="0 0 14 14" ariaHidden=true>
                              <path
                                d="M2.5 7.5 L5.5 10.5 L11.5 3.5"
                                fill="none"
                                stroke=green
                                strokeWidth="2"
                                strokeLinecap="round"
                                strokeLinejoin="round"
                              />
                            </svg>
                            {item->React.string}
                          </li>
                        )
                        ->React.array}
                      </ul>
                    </RenderIf>
                  </button>
                })
                ->React.array}
              </div>
              // Your bill
              <div
                className="rounded-2xl border border-nd_gray-200 bg-nd_gray-25 px-6 py-5 flex flex-col gap-2.5">
                <span className={`${heading.sm.semibold} text-nd_gray-800`}>
                  {"Your Bill"->React.string}
                </span>
                <div className={`flex justify-between ${body.md.medium} text-nd_gray-800`}>
                  <span> {"First Payment Date"->React.string} </span>
                  <span> {monthAgo()->usDate->React.string} </span>
                </div>
                <div className={`flex justify-between ${body.md.medium} text-nd_gray-800`}>
                  <span> {"First Payment"->React.string} </span>
                  <span> {amount->dollars->React.string} </span>
                </div>
                <p className={`${body.sm.medium} text-nd_gray-500`}>
                  {"Taxes apply in some states. Any credit in your account is used first toward your plan."->React.string}
                </p>
              </div>
              <RenderIf condition={!planPicked}>
                <Button
                  text="Continue"
                  buttonType=Primary
                  buttonSize=Large
                  customHeightClass="h-11"
                  customButtonStyle="!w-full"
                  onClick={_ => openPayment()}
                />
              </RenderIf>
            </div>
            <div className="flex flex-col gap-3">
              {stepLabel(~number="2", ~text="Payment details", ~isDone=false, ~isActive=planPicked)}
              // Locked and blurred until Continue
              <div ref={ReactDOM.Ref.domRef(paymentRef)} className="relative">
                <div
                  className={`flex flex-col gap-3 transition-[filter,opacity] duration-300 ${planPicked
                      ? ""
                      : "blur-[2px] opacity-50 pointer-events-none select-none"}`}>
                  // Cards only
                  <div className="flex items-center gap-2 border-b-2 border-[#2D5BD7] pb-2.5">
                    {["visa-light", "mastercard", "amex-light", "discover"]
                    ->Array.map(name =>
                      <React.Fragment key=name>
                        {SimulatorCheckout.icon(~name, ~size=20, ~width=30)}
                      </React.Fragment>
                    )
                    ->React.array}
                    <span className={`ml-1 ${body.md.semibold} text-nd_gray-700`}>
                      {"Credit or debit card"->React.string}
                    </span>
                  </div>
                  // Fill buttons, in one row: test cards on the left, sample details on the right
                  <div className="flex flex-wrap items-center gap-2">
                    {testCardButton(~label="Test card", ~pan="4242424242424242")}
                    {testCardButton(~label="Test card", ~pan="5555555555554444")}
                    <div className="ml-auto flex flex-wrap items-center gap-2">
                      {pill(~label="Sample name", ~onClick=sampleName)}
                      {pill(~label="Sample address", ~onClick=sampleAddress)}
                    </div>
                  </div>
                  <div className="grid grid-cols-2 gap-3">
                    <Field label="First Name" value=first onChange={v => setFirst(_ => v)} />
                    <Field label="Last Name" value=last onChange={v => setLast(_ => v)} />
                  </div>
                  <AddressField
                    value=address
                    onChange={v => setAddress(_ => v)}
                    onPick={item => {
                      setAddress(_ => item.line)
                      setCity(_ => item.city)
                      setState(_ => item.state)
                      setPostcode(_ => item.postcode)
                    }}
                  />
                  <div
                    className="grid grid-cols-[minmax(0,2fr)_minmax(0,1fr)_minmax(0,1.3fr)] gap-3">
                    <Field label="City" value=city onChange={v => setCity(_ => v)} />
                    <StateField value=state onChange={v => setState(_ => v)} />
                    <Field
                      label="Postcode"
                      value=postcode
                      inputMode="numeric"
                      maxLength=10
                      onChange={v => setPostcode(_ => v)}
                    />
                  </div>
                  <div
                    className="grid grid-cols-[minmax(0,2fr)_minmax(0,1fr)_minmax(0,1fr)_minmax(0,1fr)] gap-3">
                    <Field
                      label="Credit Card Number"
                      value=number
                      inputMode="numeric"
                      maxLength=19
                      onChange={v =>
                        setNumber(_ => v->digits->String.slice(~start=0, ~end=16)->grouped)}
                    />
                    <Field
                      label="Exp. MM"
                      value=expMonth
                      placeholder="MM"
                      inputMode="numeric"
                      maxLength=2
                      onChange={v => setExpMonth(_ => v->digits)}
                    />
                    <Field
                      label="YYYY"
                      value=expYear
                      placeholder="YYYY"
                      inputMode="numeric"
                      maxLength=4
                      onChange={v => setExpYear(_ => v->digits)}
                    />
                    <Field
                      label="CVV"
                      value=cvv
                      placeholder="123"
                      inputMode="numeric"
                      maxLength=4
                      onChange={v => setCvv(_ => v->digits)}
                    />
                  </div>
                  <RenderIf condition={cardError != ""}>
                    <span className={`${body.sm.medium} text-nd_red-600`}>
                      {cardError->React.string}
                    </span>
                  </RenderIf>
                  // The agreement
                  <div
                    className="mt-1 rounded-2xl border border-nd_gray-200 bg-nd_gray-25 px-5 py-4 flex flex-col gap-3">
                    <label className="flex items-start gap-3 cursor-pointer">
                      <input
                        type_="checkbox"
                        checked=agreed
                        onChange={_ => setAgreed(prev => !prev)}
                        className="mt-0.5 h-5 w-5 shrink-0 accent-[#2D5BD7]"
                      />
                      <span className={`${body.sm.medium} text-nd_gray-700`}>
                        {`I agree to pay the First Payment shown and that my subscription will auto-renew each month at ${amount->dollars} unless I cancel. Taxes may apply; prices may change. Cancel any time in your account settings before a renewal to avoid future charges. Cancelling takes effect at the end of the current billing period. No refunds or credits for part of a billing period.`->React.string}
                      </span>
                    </label>
                    <p className={`text-center ${body.sm.medium} text-nd_gray-500`}>
                      {`By clicking "Subscribe", you agree to ${brandName}'s Terms of Use and to enrol in the auto-renewing subscription.`->React.string}
                    </p>
                    <RenderIf condition={error != ""}>
                      <span className={`${body.md.semibold} text-nd_red-600`}>
                        {error->React.string}
                      </span>
                    </RenderIf>
                    <AddDataAttributes attributes=[("data-sim", "subscribe")]>
                      <button
                        type_="button"
                        disabled={!canSubscribe}
                        onClick={_ => subscribe()->ignore}
                        className={`h-12 rounded-lg ${body.md.semibold} uppercase tracking-[0.12em] text-white transition-colors ${canSubscribe
                            ? "bg-[#1F2430] hover:bg-black"
                            : "bg-nd_gray-400 cursor-not-allowed"}`}>
                        {(isBusy ? "Processing…" : "Subscribe")->React.string}
                      </button>
                    </AddDataAttributes>
                  </div>
                </div>
                <RenderIf condition={!planPicked}>
                  <div className="absolute inset-0 flex items-start justify-center pt-40">
                    <span
                      className={`flex items-center gap-2 rounded-full border border-nd_gray-200 bg-white px-4 py-2 shadow-sm ${body.md.semibold} text-nd_gray-700`}>
                      <span className="text-nd_gray-500">
                        {SimulatorCheckout.icon(~name="lock", ~size=11, ~width=8)}
                      </span>
                      {"Pick a plan first"->React.string}
                    </span>
                  </div>
                </RenderIf>
              </div>
            </div>
          </div>
        </div>
      </AddDataAttributes>
    }}
  </div>
}
