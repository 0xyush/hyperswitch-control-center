// Sign up as the customer (2 Nov): before the Invoice story, the visitor signs up for ChotuAI, a
// made-up AI subscription, on a checkout like a streaming service's. The first month is a real
// test charge, or a $0 card check that saves the card (POST /sim/signup). The signup stands for
// last month: a calendar then runs one month on, and ChotuAI's email says the renewal failed. The
// story form then charges that renewal (renewal mode), and the story picks why it fails.
open Typography
open SimulatorTestCards

type result = {
  signupId: string,
  plan: string,
  // Minor units, as the proxy keeps them: 2000 = $20.00
  amount: int,
  currency: string,
  // "charge" (the first month paid) or "zero_auth" (a $0 card check)
  mode: string,
  last4: string,
}

let logo = "/assets/simulator/chotuai-logo.svg"
let mark = "/assets/simulator/chotuai-mark.svg"
let ink = "#1F2430"

// (id, name, monthly amount in minor units, line)
let plans = [
  ("starter", "Starter", 2000, "For trying it out"),
  ("growth", "Growth", 10000, "For everyday work"),
  ("scale", "Scale", 20000, "For a whole team"),
]

let dollars = minor => `$${(minor->Int.toFloat /. 100.0)->Float.toFixedWithPrecision(~digits=2)}`
// "20.00", as the story form's Amount field keeps it
let major = minor => (minor->Int.toFloat /. 100.0)->Float.toFixedWithPrecision(~digits=2)

let pad = n => n < 10 ? `0${n->Int.toString}` : n->Int.toString
let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
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

// The story form's step 2 in renewal mode: this month's renewal on the card saved at signup
module RenewalCharge = {
  @react.component
  let make = (~result: result, ~isBusy, ~isLocked, ~onCharge) =>
    <AddDataAttributes attributes=[("data-sim", "renewal-charge")]>
      <div className="rounded-xl border border-nd_gray-200 bg-white p-6 flex flex-col gap-5">
        <img src=logo alt="ChotuAI" className="h-8 w-fit" />
        <div className="flex flex-col gap-1">
          <span className={`${body.sm.semibold} text-nd_gray-500`}>
            {"This month's renewal"->React.string}
          </span>
          <span className={`${heading.md.semibold} text-nd_gray-800`}>
            {`ChotuAI ${result.plan} · ${result.amount->dollars}`->React.string}
          </span>
          <span className={`${body.md.medium} text-nd_gray-600`}>
            {`On ${result.last4->brandLine}, saved at signup${result.mode == "zero_auth"
                ? " with a $0 card check"
                : ""}.`->React.string}
          </span>
        </div>
        <p className={`${body.md.medium} text-nd_gray-500`}>
          {"The billing system charges the saved card. The story you picked decides what the bank says."->React.string}
        </p>
        <button
          type_="button"
          disabled={isLocked || isBusy}
          onClick={_ => onCharge()}
          className={`h-11 rounded-lg ${body.md.semibold} tracking-wide text-white transition-colors ${isLocked ||
            isBusy
              ? "bg-nd_gray-400 cursor-not-allowed"
              : "bg-[#1F2430] hover:bg-black"}`}>
          {(
            isBusy ? "Processing…" : `Run the renewal charge · ${result.amount->dollars}`
          )->React.string}
        </button>
      </div>
    </AddDataAttributes>
}

// One labelled input, drawn like the checkout in the reference: a floating label in a tall box
module Field = {
  @react.component
  let make = (~label, ~value, ~onChange, ~placeholder="", ~inputMode="text", ~maxLength=80) =>
    <label
      className="flex flex-col justify-center rounded-xl border border-nd_gray-300 bg-white px-4 h-[60px] focus-within:border-[#1F2430]">
      <span className={`${body.xs.medium} text-nd_gray-500`}> {label->React.string} </span>
      <input
        value
        placeholder
        inputMode
        maxLength
        onChange={e => onChange(ReactEvent.Form.target(e)["value"])}
        className={`w-full bg-transparent outline-none ${body.lg.medium} text-nd_gray-800 placeholder:text-nd_gray-400`}
      />
    </label>
}

type phase = Form | Later(result) | Notice(result)

let laterCss = `
@keyframes sgn-hand { from { transform: rotate(0deg); } to { transform: rotate(720deg); } }
@keyframes sgn-pop { from { opacity: 0; transform: translateY(8px) scale(.98); } to { opacity: 1; transform: none; } }
.sgn-hand { transform-origin: 32px 32px; animation: sgn-hand 2.6s cubic-bezier(.4,0,.2,1) forwards; }
.sgn-pop { animation: sgn-pop .45s cubic-bezier(.2,.8,.2,1) backwards; }
@media (prefers-reduced-motion: reduce) { .sgn-hand, .sgn-pop { animation: none; } }
`

// One month on: the calendar counts the days from the signup to today
module MonthLater = {
  @react.component
  let make = (~result: result, ~onEnd) => {
    let start = monthAgo()
    // Whole days from the signup to today (both at midnight, so the time of day does not count)
    let total = {
      let now = Date.make()
      let today = Date.makeWithYMD(
        ~year=now->Date.getFullYear,
        ~month=now->Date.getMonth,
        ~date=now->Date.getDate,
      )
      Math.round((today->Date.getTime -. start->Date.getTime) /. 86_400_000.0)->Float.toInt
    }
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
        {`Subscribed to ChotuAI ${result.plan}. One month later…`->React.string}
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
            stroke="#E8673C"
            strokeWidth="2.5"
            strokeLinecap="round"
          />
          <circle cx="32" cy="32" r="3" fill=ink />
        </svg>
        <div
          className="w-40 overflow-hidden rounded-2xl border border-nd_gray-200 bg-white shadow-sm text-center">
          <div className={`bg-[#E8673C] py-1.5 ${body.md.semibold} text-white`}>
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

// The renewal failed: ChotuAI's email to the customer
module RenewalNotice = {
  @react.component
  let make = (~result: result, ~onNext) =>
    <AddDataAttributes attributes=[("data-sim", "renewal-notice")]>
      <div className="sgn-pop flex flex-col gap-5 max-w-[640px] w-full mx-auto">
        <span className={`${body.md.semibold} text-nd_gray-500`}>
          {`Today, ${Date.make()->shortDate}: the customer's inbox`->React.string}
        </span>
        <div className="rounded-2xl border border-nd_gray-200 bg-white shadow-sm overflow-hidden">
          <div className="flex items-center gap-3 border-b border-nd_gray-150 px-6 py-4">
            <img src=mark alt="" className="h-9 w-9" />
            <div className="flex flex-col">
              <span className={`${body.md.semibold} text-nd_gray-800`}>
                {"ChotuAI Billing"->React.string}
              </span>
              <span className={`${body.sm.medium} text-nd_gray-500`}>
                {"to you · just now"->React.string}
              </span>
            </div>
          </div>
          <div className="flex flex-col gap-4 px-6 py-6">
            <span className={`${heading.md.semibold} text-nd_gray-800`}>
              {"Your payment didn't go through"->React.string}
            </span>
            <p className={`${body.lg.medium} text-nd_gray-700`}>
              {`We tried to renew your ChotuAI ${result.plan} plan today, but your bank declined the ${result.amount->dollars} payment on ${result.last4->brandLine}.`->React.string}
            </p>
            <p className={`${body.lg.medium} text-nd_gray-700`}>
              {"Your plan stays on while we try the payment again."->React.string}
            </p>
            <div
              className={`flex items-center gap-2 rounded-lg bg-nd_red-50 border border-nd_red-200 px-4 py-3 ${body.md.semibold} text-nd_red-600`}>
              {`Declined · ${result.amount->dollars} · ${result.last4->brandLine}`->React.string}
            </div>
          </div>
        </div>
        <Button
          text="See why it failed and what Rev Rec does"
          buttonType=Primary
          buttonSize=Large
          customButtonStyle="!w-fit"
          rightIcon={FontAwesome("arrow-right")}
          onClick={_ => onNext()}
        />
      </div>
    </AddDataAttributes>
}

@react.component
let make = (~onDone: result => unit, ~onSkip) => {
  let simFetch = SimulatorApi.useSimFetch()
  let (phase, setPhase) = React.useState(_ => Form)
  let (planId, setPlanId) = React.useState(_ => "starter")
  let (mode, setMode) = React.useState(_ => "charge")
  // Made-up details, ready to use: nothing but the card's last four leaves this browser
  let (first, setFirst) = React.useState(_ => "Chotu")
  let (last, setLast) = React.useState(_ => "Customer")
  let (address, setAddress) = React.useState(_ => "1 Demo Street")
  let (city, setCity) = React.useState(_ => "San Francisco")
  let (state, setState) = React.useState(_ => "CA")
  let (postcode, setPostcode) = React.useState(_ => "94105")
  let (number, setNumber) = React.useState(_ => "")
  let (expMonth, setExpMonth) = React.useState(_ => "")
  let (expYear, setExpYear) = React.useState(_ => "")
  let (cvv, setCvv) = React.useState(_ => "")
  let (agreed, setAgreed) = React.useState(_ => false)
  let (isBusy, setIsBusy) = React.useState(_ => false)
  let (error, setError) = React.useState(_ => "")

  let (_, planName, amount, _) =
    plans->Array.find(((id, _, _, _)) => id == planId)->Option.getOr(plans->Array.getUnsafe(0))
  let firstPayment = mode == "charge" ? amount : 0
  let d = number->digits
  let card = switch d->detect {
  | Test(card, _) if card->isVisitorCard && (d->brandOf == Visa || d->brandOf == Mastercard) =>
    Some(card)
  | _ => None
  }
  let cardError = switch d->detect {
  | _ if d->String.length < 16 => ""
  | Test(_, _) if card->Option.isSome => ""
  | _ => "Use test card 4242 4242 4242 4242 or 5555 5555 5555 4444."
  }
  let monthOk = expMonth->Int.fromString->Option.mapOr(false, m => m >= 1 && m <= 12)
  let yearOk = expYear->Int.fromString->Option.mapOr(false, y => y >= Date.make()->Date.getFullYear)
  let cvvOk = cvv->digits->String.length >= 3
  let filled = [first, last, address, city, state, postcode]->Array.every(v => v->String.trim != "")
  let canSubscribe =
    !isBusy && card->Option.isSome && monthOk && yearOk && cvvOk && filled && agreed

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
          ("mode", mode->JSON.Encode.string),
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
        mode: o->getString("mode", mode),
        last4: o->getString("last4", d->String.sliceToEnd(~start=-4)),
      }
      setPhase(_ => Later(result))
    } catch {
    | _ => setError(_ => "The signup did not go through. Try again in a moment.")
    }
    setIsBusy(_ => false)
  }

  let steps =
    <div className="flex items-center gap-2">
      {["Sign up", "One month later", "Renewal"]
      ->Array.mapWithIndex((label, i) => {
        let current = switch phase {
        | Form => 0
        | Later(_) => 1
        | Notice(_) => 2
        }
        <React.Fragment key=label>
          <RenderIf condition={i > 0}>
            <span className="h-px w-6 bg-nd_gray-300" />
          </RenderIf>
          <span
            className={`rounded-full px-3 py-1 ${body.sm.semibold} ${i == current
                ? "bg-[#1F2430] text-white"
                : i < current
                ? "bg-nd_gray-100 text-nd_gray-600"
                : "bg-white border border-nd_gray-200 text-nd_gray-400"}`}>
            {`${(i + 1)->Int.toString}. ${label}`->React.string}
          </span>
        </React.Fragment>
      })
      ->React.array}
    </div>

  <div className="flex flex-col gap-6">
    <style> {laterCss->React.string} </style>
    <div className="flex flex-wrap items-center justify-between gap-3">
      steps
      <button
        type_="button"
        className={`text-blue-500 hover:text-blue-700 ${body.md.semibold}`}
        onClick={_ => onSkip()}>
        {"Skip signup"->React.string}
      </button>
    </div>
    {switch phase {
    | Later(result) => <MonthLater result onEnd={() => setPhase(_ => Notice(result))} />
    | Notice(result) => <RenewalNotice result onNext={() => onDone(result)} />
    | Form =>
      <AddDataAttributes attributes=[("data-sim", "signup")]>
        <div className="max-w-[720px] w-full mx-auto flex flex-col gap-6">
          <div className="flex flex-col gap-2">
            <img src=logo alt="ChotuAI" className="h-10 w-fit" />
            <p className={`${body.lg.medium} text-nd_gray-600`}>
              {"You are the customer. Pick a plan and sign up. This stands for last month."->React.string}
            </p>
          </div>
          // The plan
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
            {plans
            ->Array.map(((id, name, monthly, line)) => {
              let isOn = id == planId
              <button
                key=id
                type_="button"
                onClick={_ => setPlanId(_ => id)}
                className={`rounded-xl border-2 p-4 text-left transition-colors ${isOn
                    ? "border-[#E8673C] bg-[#FFF7F2]"
                    : "border-nd_gray-200 bg-white hover:border-nd_gray-400"}`}>
                <span className={`block ${body.md.semibold} text-nd_gray-800`}>
                  {name->React.string}
                </span>
                <span className={`block ${heading.md.semibold} text-nd_gray-800`}>
                  {`${monthly->dollars}`->React.string}
                  <span className={`${body.md.medium} text-nd_gray-500`}>
                    {" / month"->React.string}
                  </span>
                </span>
                <span className={`block ${body.sm.medium} text-nd_gray-500`}>
                  {line->React.string}
                </span>
              </button>
            })
            ->React.array}
          </div>
          // How the first month starts
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            {[
              ("charge", `Pay the first month today`, `${amount->dollars} now, then monthly`),
              ("zero_auth", "Start with a $0 card check", "The card is saved; $0 today"),
            ]
            ->Array.map(((value, title, line)) => {
              let isOn = value == mode
              <button
                key=value
                type_="button"
                onClick={_ => setMode(_ => value)}
                className={`flex items-start gap-3 rounded-xl border p-4 text-left ${isOn
                    ? "border-[#1F2430] bg-nd_gray-50"
                    : "border-nd_gray-200 bg-white hover:border-nd_gray-400"}`}>
                <span
                  className={`mt-0.5 h-4 w-4 shrink-0 rounded-full border-2 ${isOn
                      ? "border-[#1F2430] bg-[#1F2430] shadow-[inset_0_0_0_3px_white]"
                      : "border-nd_gray-300"}`}
                />
                <span className="flex flex-col">
                  <span className={`${body.md.semibold} text-nd_gray-800`}>
                    {title->React.string}
                  </span>
                  <span className={`${body.sm.medium} text-nd_gray-500`}>
                    {line->React.string}
                  </span>
                </span>
              </button>
            })
            ->React.array}
          </div>
          // Your bill
          <div
            className="rounded-2xl border border-nd_gray-200 bg-nd_gray-25 px-8 py-6 flex flex-col gap-3">
            <span className={`${heading.md.semibold} text-nd_gray-800`}>
              {"Your Bill"->React.string}
            </span>
            <div className={`flex justify-between ${body.lg.medium} text-nd_gray-800`}>
              <span> {"First Payment Date"->React.string} </span>
              <span> {monthAgo()->usDate->React.string} </span>
            </div>
            <div className={`flex justify-between ${body.lg.medium} text-nd_gray-800`}>
              <span> {"First Payment"->React.string} </span>
              <span> {firstPayment->dollars->React.string} </span>
            </div>
            <p className={`text-right ${body.md.medium} text-nd_gray-500`}>
              {`Then ${amount->dollars} every month. Taxes apply in some states. Any credit in your account is used first toward your plan.`->React.string}
            </p>
          </div>
          // Card, or PayPal (not in this demo)
          <div className="grid grid-cols-2 border-b border-nd_gray-200">
            <div
              className="flex items-center justify-center gap-2 border-b-2 border-[#2D5BD7] pb-3">
              {["visa-light", "mastercard", "amex-light", "discover"]
              ->Array.map(name =>
                <React.Fragment key=name>
                  {SimulatorCheckout.icon(~name, ~size=22, ~width=34)}
                </React.Fragment>
              )
              ->React.array}
            </div>
            <ToolTip
              description="Not in this demo"
              toolTipPosition=ToolTip.Top
              toolTipFor={<div
                className="flex items-center justify-center pb-3 text-xl font-extrabold italic text-nd_gray-300 cursor-not-allowed">
                {"PayPal"->React.string}
              </div>}
            />
          </div>
          <div className="grid grid-cols-2 gap-4">
            <Field label="First Name" value=first onChange={v => setFirst(_ => v)} />
            <Field label="Last Name" value=last onChange={v => setLast(_ => v)} />
          </div>
          <Field label="Address" value=address onChange={v => setAddress(_ => v)} />
          <div className="grid grid-cols-[2fr_1fr_1.3fr] gap-4">
            <Field label="City" value=city onChange={v => setCity(_ => v)} />
            <Field
              label="State"
              value=state
              maxLength=2
              onChange={v => setState(_ => v->String.toUpperCase)}
            />
            <Field
              label="Postcode"
              value=postcode
              inputMode="numeric"
              maxLength=10
              onChange={v => setPostcode(_ => v)}
            />
          </div>
          <div className="flex flex-col gap-2">
            <div className="grid grid-cols-[2fr_1fr_1fr_1fr] gap-4">
              <Field
                label="Credit Card Number"
                value=number
                placeholder="4242 4242 4242 4242"
                inputMode="numeric"
                maxLength=19
                onChange={v => setNumber(_ => v->digits->String.slice(~start=0, ~end=16)->grouped)}
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
            <div
              className={`flex flex-wrap items-center gap-x-3 gap-y-1 ${body.sm.medium} text-nd_gray-500`}>
              <span> {"Test mode. Use a test card:"->React.string} </span>
              <button
                type_="button"
                className="text-blue-500 hover:text-blue-700 font-semibold"
                onClick={_ => useTestCard("4242424242424242")}>
                {"Visa 4242"->React.string}
              </button>
              <button
                type_="button"
                className="text-blue-500 hover:text-blue-700 font-semibold"
                onClick={_ => useTestCard("5555555555554444")}>
                {"Mastercard 4444"->React.string}
              </button>
              <span> {"Only the last four digits leave this page."->React.string} </span>
            </div>
          </div>
          // The agreement
          <div
            className="rounded-2xl border border-nd_gray-200 bg-nd_gray-25 px-8 py-6 flex flex-col gap-5">
            <label className="flex items-start gap-4 cursor-pointer">
              <input
                type_="checkbox"
                checked=agreed
                onChange={_ => setAgreed(prev => !prev)}
                className="mt-1 h-6 w-6 shrink-0 accent-[#2D5BD7]"
              />
              <span className={`${body.lg.medium} text-nd_gray-700`}>
                {`I agree to pay the First Payment shown above and that my subscription will auto-renew each month at ${amount->dollars} unless I cancel. Taxes may apply; prices may change. Cancel any time in your account settings before a renewal to avoid future charges. Cancelling takes effect at the end of the current billing period. No refunds or credits for part of a billing period.`->React.string}
              </span>
            </label>
            <p className={`text-center ${body.md.medium} text-nd_gray-600`}>
              {`By clicking "Subscribe", you agree to ChotuAI's Terms of Use and to enrol in the auto-renewing subscription.`->React.string}
            </p>
            <RenderIf condition={error != ""}>
              <span className={`${body.md.semibold} text-nd_red-600`}> {error->React.string} </span>
            </RenderIf>
            <AddDataAttributes attributes=[("data-sim", "subscribe")]>
              <button
                type_="button"
                disabled={!canSubscribe}
                onClick={_ => subscribe()->ignore}
                className={`h-14 rounded-lg ${body.lg.semibold} uppercase tracking-[0.12em] text-white transition-colors ${canSubscribe
                    ? "bg-[#1F2430] hover:bg-black"
                    : "bg-nd_gray-400 cursor-not-allowed"}`}>
                {(isBusy ? "Processing…" : "Subscribe")->React.string}
              </button>
            </AddDataAttributes>
          </div>
        </div>
      </AddDataAttributes>
    }}
  </div>
}
