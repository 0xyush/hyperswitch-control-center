// The customer's checkout in the story form, drawn like the Hyperswitch Web SDK's card form: its
// default theme (DefaultTheme.res) and its icons (hyperswitch-web-icons.svg, copied from
// hyperswitch-web under the Apache License 2.0). Saved cards as tabs, or a new card. Only Stripe
// test cards that pay can be used; any other number is checked here and goes nowhere. Expiry and
// CVC never leave this browser: Pay gives only the card's last four (start field card).
open SimulatorTestCards

let sprite = "/assets/simulator/hyperswitch-web-icons.svg"

// An icon from the sprite. As the SDK's Icon: size is the height, the width is size unless given.
let icon = (~name, ~size, ~width=size) =>
  <svg width={`${width->Int.toString}px`} height={`${size->Int.toString}px`} ariaHidden=true>
    <use href={`${sprite}#${name}`} />
  </svg>

let brandIcon = brand =>
  switch brand {
  | Visa => "visa-light"
  | Mastercard => "mastercard"
  | Amex => "amex-light"
  | Discover => "discover"
  | OtherBrand => "default-card"
  }

// The SDK's rules with its default theme's values, under one root class
let css = `
.hsw { color: #545454; text-align: left; }
.hsw .Tab { display: flex; flex-direction: column; align-items: start; gap: 4px; min-width: 5rem;
  width: 100%; padding: 11px; border: 1px solid #e6e6e6; border-radius: 4px; background: #ffffff;
  color: #6d6e78; font-size: 14px; font-weight: 500; text-align: start; cursor: pointer;
  box-shadow: 0px 1px 1px rgb(0 0 0 / 3%), 0px 3px 6px rgb(0 0 0 / 2%);
  transition: background .15s ease, border .15s ease, box-shadow .15s ease, color .1s ease; }
.hsw .Tab:hover { color: #545454; }
.hsw .Tab--selected, .hsw .Tab--selected:hover { color: #006df9;
  box-shadow: 0px 1px 1px rgba(0, 0, 0, 0.03), 0px 3px 6px rgba(18, 42, 66, 0.02), 0 0 0 2px #006df9; }
.hsw .Tab--selected:hover { border-color: #006df9; }
.hsw .Tab:focus-visible { outline: none; border-color: #006df9; box-shadow: #006df94c 0px 0px 0px 3px; }
.hsw .Label { font-size: 14px; font-weight: 500; margin-bottom: 5px; opacity: 0.6; }
.hsw .Input { width: 100%; height: 48px; padding: 11px; border: 1px solid #e6e6e6; border-radius: 4px;
  background: #ffffff; color: #545454; font-size: 16px; font-weight: 400; outline: none;
  box-shadow: 0px 1px 1px rgb(0 0 0 / 3%), 0px 3px 6px rgb(0 0 0 / 2%);
  transition: background 0.15s ease, border 0.15s ease, box-shadow 0.15s ease, color 0.15s ease; }
.hsw .Input::placeholder { font-weight: 400; color: #a3a3a3; }
.hsw .Input:focus { border-color: #006df9; box-shadow: #006df94c 0px 0px 0px 3px; }
.hsw .Input--invalid, .hsw .Input--invalid:focus { color: #fd1717; border-color: #fd1717; }
.hsw .Input:disabled { background: #F6F8FA; }
.hsw .InputLogo { color: #979797; margin-left: -40px; }
.hsw .Error { color: #fd1717; font-size: 12px; padding-top: 4px; }
.hsw .PayButton { width: 100%; height: 48px; border-radius: 6px; background: #006df9; color: #ffffff;
  font-size: 16px; font-weight: 500; display: flex; align-items: center; justify-content: center; }
.hsw .PayButton:disabled { opacity: 0.6; cursor: not-allowed; }
.hsw .checkmark { display: block; flex-shrink: 0; transform: rotate(45deg); height: 1em; width: .4em;
  margin-top: -2px; margin-left: 4px; border: 2px solid #6d6e78; border-top-color: transparent;
  border-left-color: transparent; }
.hsw-in { animation: hsw-in .35s ease-out both; }
.hsw-failed > div { box-shadow: none; padding: 0; }
.hsw-failed > div > div { height: auto; padding: 28px 16px; }
@keyframes hsw-in { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: none; } }
@media (prefers-reduced-motion: reduce) { .hsw-in { animation: none; } }
`

// The cards a returning customer has saved: Stripe test cards that pay (the story makes the
// failure), as the SDK lists them: brand and last four
let savedCards = ["4242424242424242", "5555555555554444"]

type tab = Saved(string) | NewCard

// The billing system's charge declined: the reason in plain words ("Not enough money") and the
// card it used (its last four)
type declined = {reason: string, last4: string}

// The control center's result page for a failed payment (SDKPayment's FAILED config); the error
// line under it is the decline
let failedConfig: SDKPaymentTypes.statusConfig = {
  iconName: "account-setup-failed",
  statusText: "Payment failed",
  bgColor: "bg-red-failed_page_bg",
  showErrorMessage: true,
}

// The test card behind a last four, for its brand logo ("" when none is known)
let fullCard = card =>
  card->String.length > 4
    ? card
    : cards
      ->Array.filter(isVisitorCard)
      ->Array.map(c => c.pan)
      ->Array.find(pan => pan->String.endsWith(card))
      ->Option.getOr("")

let last4 = pan => pan->String.sliceToEnd(~start=-4)

// MM / YY as the customer types: a first digit above 1 is a month on its own
let formatExpiry = raw => {
  let d = raw->digits
  let d = d->String.length == 1 && d > "1" ? `0${d}` : d
  let d = d->String.slice(~start=0, ~end=4)
  d->String.length > 2
    ? `${d->String.slice(~start=0, ~end=2)} / ${d->String.sliceToEnd(~start=2)}`
    : d
}

// A full month that is not past
let isExpiryValid = expiry => {
  let d = expiry->digits
  let month = d->String.slice(~start=0, ~end=2)->Int.fromString->Option.getOr(0)
  let year = d->String.sliceToEnd(~start=2)->Int.fromString->Option.getOr(0)
  let now = Date.make()
  let thisYear = mod(now->Date.getFullYear, 100)
  let thisMonth = now->Date.getMonth + 1
  d->String.length == 4 &&
  month >= 1 &&
  month <= 12 &&
  (year > thisYear || (year == thisYear && month >= thisMonth))
}

module Preview = {
  @react.component
  let make = (
    // Blurred and closed until a story is picked
    ~locked: bool,
    ~lockText="Pick a story first",
    // Major units, as the form keeps it ("65.40")
    ~amount: string,
    ~currency: string,
    // "new" opens on New card; a returning customer ("same") opens on Visa ••4242
    ~customer: string,
    ~isBusy=false,
    // The card's last four (start field card)
    ~onPay: string => unit,
    // The full test card that Pay would use, "" while there is none (for the story's chain)
    ~onCard: option<string => unit>=?,
    // After Pay: the charge declined. The checkout shows the control center's failed page and the
    // handover to Rev Rec (no button when None)
    ~declined: option<declined>=?,
    ~onHandover: option<unit => unit>=?,
    ~isHandingOver=false,
    ~onStartOver: option<unit => unit>=?,
  ) => {
    let startTab = customer => customer == "new" ? NewCard : Saved("4242424242424242")
    let (tab, setTab) = React.useState(_ => customer->startTab)
    React.useEffect(() => {
      setTab(_ => customer->startTab)
      None
    }, [customer])

    let (number, setNumber) = React.useState(_ => "")
    let (expiry, setExpiry) = React.useState(_ => "")
    let (cvc, setCvc) = React.useState(_ => "")

    let d = number->digits
    let brand = d->brandOf
    let fullLength = brand == Amex ? 15 : 16
    let cvcLength = brand == Amex ? 4 : 3
    // An Amex CVC has four digits; after a change of card only the first ones count
    let cvc = cvc->String.slice(~start=0, ~end=cvcLength)
    let detection = number->detect
    let isPaying = switch detection {
    | Test(card, _) => card->isVisitorCard
    | _ => false
    }
    // A short red line only for a full number that cannot be used
    let error = switch detection {
    | _ if d->String.length < fullLength => None
    | Test(card, _) if card->isVisitorCard => None
    | Test(card, _) if card.processors == ["stripe"] =>
      Some("This test card declines. Use one that pays, like 4242.")
    | _ => Some("Use a Stripe test card. Real cards are never charged here.")
    }

    let card = switch tab {
    | Saved(pan) => pan
    | NewCard => isPaying && expiry->isExpiryValid && cvc->String.length == cvcLength ? d : ""
    }
    React.useEffect(() => {
      onCard->Option.forEach(f => f(card))
      None
    }, [card])

    let canPay = !locked && !isBusy && card != ""

    // The label in lines: the brand, then the last four
    let tabButton = (~key, ~iconName, ~label: array<string>, ~isOn, ~onClick) =>
      <button
        key
        type_="button"
        disabled=locked
        className={`Tab ${isOn ? "Tab--selected" : ""}`}
        onClick={_ => onClick()}>
        {icon(~name=iconName, ~size=19, ~width=28)}
        <span className="flex flex-col">
          {label->Array.map(line => <span key=line> {line->React.string} </span>)->React.array}
        </span>
      </button>

    let field = (~label, ~input, ~logo) =>
      <div className="flex flex-col w-full">
        <div className="Label" ariaHidden=true> {label->React.string} </div>
        <div className="flex flex-row">
          <div className="relative w-full"> input </div>
          <div className="InputLogo relative flex items-center"> logo </div>
        </div>
      </div>

    let spinner =
      <span className="h-5 w-5 rounded-full border-2 border-white/40 border-t-white animate-spin" />

    // As the control center's SDK try-out after a failed payment, then the handover to Rev Rec
    let declinedView = ({reason, last4: four}) => {
      let pan = four->fullCard
      let reason = reason->String.replaceRegExp(%re("/\.$/"), "")
      let message = `Declined · ${reason == "" ? "Card declined" : reason} · ${pan == ""
          ? "Card"
          : pan->brandOf->brandName}\u00A0••${four->last4}`
      <AddDataAttributes attributes=[("data-sim", "decline")]>
        // One card, as the checkout before Pay: the control center's failed panel (its own card
        // look is turned off), then the two buttons inside it
        <div
          className="hsw-in bg-white border border-nd_gray-200 rounded-xl p-5 flex flex-col gap-5">
          <style> {css->React.string} </style>
          <div className="hsw-failed">
            <SDKProvider.Provider value={...SDKProvider.defaultValue, errorMessage: message}>
              // Its button is ours, under the panel; it reads the text even when hidden
              <SDKPayment.PaymentStatusPage
                config=failedConfig buttonText="" buttonOnClick={_ => ()} isButtonVisible=false
              />
            </SDKProvider.Provider>
          </div>
          <div
            className={`grid gap-3 ${onStartOver->Option.isSome && onHandover->Option.isSome
                ? "grid-cols-2"
                : "grid-cols-1"}`}>
            {onStartOver->Option.mapOr(React.null, onStartOver =>
              <AddDataAttributes attributes=[("data-sim", "start-over")]>
                <div>
                  <Button
                    text="Start over"
                    buttonType=Secondary
                    buttonSize=Large
                    customButtonStyle="w-full !bg-none !bg-white"
                    buttonState={isHandingOver ? Disabled : Normal}
                    onClick={_ => onStartOver()}
                  />
                </div>
              </AddDataAttributes>
            )}
            {onHandover->Option.mapOr(React.null, onHandover =>
              <AddDataAttributes attributes=[("data-sim", "pass-to-revrec")]>
                <div>
                  <Button
                    text="Pass it to Rev Rec →"
                    loadingText="Passing it to Rev Rec..."
                    buttonType=Primary
                    buttonSize=Large
                    customButtonStyle="w-full"
                    buttonState={isHandingOver ? Loading : Normal}
                    onClick={_ => onHandover()}
                  />
                </div>
              </AddDataAttributes>
            )}
          </div>
        </div>
      </AddDataAttributes>
    }

    switch declined {
    | Some(d) => declinedView(d)
    | None =>
      <div className="relative">
        <style> {css->React.string} </style>
        <div
          className={`hsw bg-white border border-nd_gray-200 rounded-xl p-5 flex flex-col gap-5 transition duration-300 ${locked
              ? "blur-[3px] opacity-60 pointer-events-none select-none"
              : ""}`}
          ariaHidden=locked>
          <div className="grid grid-cols-3 gap-3">
            {savedCards
            ->Array.map(pan =>
              tabButton(
                ~key=pan,
                ~iconName=pan->brandOf->brandIcon,
                ~label=[pan->brandOf->brandName, `••${pan->last4}`],
                ~isOn=tab == Saved(pan),
                ~onClick=() => setTab(_ => Saved(pan)),
              )
            )
            ->React.array}
            {tabButton(
              ~key="new",
              ~iconName="default-card",
              ~label=["New card"],
              ~isOn=tab == NewCard,
              ~onClick=() => setTab(_ => NewCard),
            )}
          </div>
          <RenderIf condition={tab == NewCard}>
            <div className="flex flex-col gap-5">
              <div className="flex flex-col">
                {field(
                  ~label="Card Number",
                  ~input=<AddDataAttributes attributes=[("data-sim", "card-number")]>
                    <input
                      type_="tel"
                      inputMode="numeric"
                      autoComplete="off"
                      spellCheck=false
                      disabled=locked
                      value=number
                      placeholder="1234 1234 1234 1234"
                      maxLength=19
                      ariaLabel="Card Number"
                      onChange={e => {
                        let raw: string = ReactEvent.Form.target(e)["value"]
                        let typed = raw->digits
                        let max = typed->brandOf == Amex ? 15 : 16
                        setNumber(_ => typed->String.slice(~start=0, ~end=max)->grouped)
                      }}
                      className={`Input ${error->Option.isSome ? "Input--invalid" : ""}`}
                    />
                  </AddDataAttributes>,
                  ~logo=icon(~name=d == "" ? "default-card" : brand->brandIcon, ~size=28),
                )}
                {error->Option.mapOr(React.null, text =>
                  <div className="Error"> {text->React.string} </div>
                )}
              </div>
              <div className="flex flex-row w-full justify-between gap-5">
                <div className="w-[47%]">
                  {field(
                    ~label="Expiry",
                    ~input=<input
                      type_="tel"
                      inputMode="numeric"
                      autoComplete="off"
                      disabled=locked
                      value=expiry
                      placeholder="MM / YY"
                      maxLength=7
                      ariaLabel="Expiry"
                      onChange={e =>
                        setExpiry(_ => ReactEvent.Form.target(e)["value"]->formatExpiry)}
                      className={`Input ${expiry->digits->String.length == 4 &&
                          !(expiry->isExpiryValid)
                          ? "Input--invalid"
                          : ""}`}
                    />,
                    ~logo=React.null,
                  )}
                </div>
                <div className="w-[47%]">
                  {field(
                    ~label="CVC",
                    ~input=<input
                      type_="tel"
                      inputMode="numeric"
                      autoComplete="off"
                      disabled=locked
                      value=cvc
                      placeholder="123"
                      maxLength=cvcLength
                      ariaLabel="CVC"
                      onChange={e =>
                        setCvc(_ =>
                          ReactEvent.Form.target(e)["value"]
                          ->digits
                          ->String.slice(~start=0, ~end=cvcLength)
                        )}
                      className="Input tracking-widest"
                    />,
                    ~logo=icon(
                      ~name=cvc->String.length == cvcLength ? "cvc-complete" : "cvc-empty",
                      ~size=28,
                    ),
                  )}
                </div>
              </div>
              // Saved for the customer, always: Rev Rec retries on the saved card
              <div className="flex flex-row items-center">
                <label className="flex items-center cursor-not-allowed">
                  <input
                    type_="checkbox" checked=true disabled=true readOnly=true className="sr-only"
                  />
                  <span className="checkmark" />
                  <span className="ml-2 opacity-50 text-xs select-none">
                    {"Save card details"->React.string}
                  </span>
                </label>
                <ToolTip
                  description="Rev Rec needs the saved card to retry."
                  toolTipPosition=ToolTip.Top
                  toolTipFor={<span
                    className="ml-2 inline-flex h-4 w-4 items-center justify-center rounded-full border border-[#e6e6e6] text-[10px] font-semibold text-[#6d6e78] cursor-help">
                    {"?"->React.string}
                  </span>}
                />
              </div>
            </div>
          </RenderIf>
          <AddDataAttributes attributes=[("data-sim", "pay")]>
            <button
              type_="button"
              className="PayButton"
              disabled={!canPay}
              onClick={_ => onPay(card->last4)}>
              {isBusy
                ? <span className="flex items-center gap-2">
                    spinner
                    {"Processing..."->React.string}
                  </span>
                : `Pay ${currency} ${amount}`->React.string}
            </button>
          </AddDataAttributes>
          <div className="text-xs text-center w-full flex justify-center -mt-1" ariaHidden=true>
            {icon(~name="powerd-by-hyper", ~size=18, ~width=130)}
          </div>
        </div>
        <RenderIf condition=locked>
          <div className="absolute inset-0 flex items-center justify-center">
            <span
              className={`flex items-center gap-2 rounded-full border border-nd_gray-200 bg-white px-4 py-2 shadow-sm ${Typography.body.md.semibold} text-nd_gray-700`}>
              <span className="text-nd_gray-500"> {icon(~name="lock", ~size=11, ~width=8)} </span>
              {lockText->React.string}
            </span>
          </div>
        </RenderIf>
      </div>
    }
  }
}
