// Form pieces for the simulator's left panels (simulator/UX-PASS-2.md A1): one tile style for every
// choice instead of a wall of dropdowns. The story form uses them; the portfolio form can too.
open Typography

let tileBase = "rounded-xl border text-left transition-colors"

let tileState = (~isSelected, ~isDisabled) =>
  switch (isSelected, isDisabled) {
  | (true, _) => "border-nd_primary_blue-450 bg-nd_primary_blue-25 ring-1 ring-nd_primary_blue-450"
  | (false, true) => "border-nd_gray-150 bg-nd_gray-50 opacity-60 cursor-not-allowed"
  | (false, false) => "border-nd_gray-200 bg-white hover:border-nd_gray-300 cursor-pointer"
  }

// One big selectable tile: an icon, a short title, and a tiny tag when it cannot be picked.
// The hint shows on hover.
module Tile = {
  @react.component
  let make = (
    ~title,
    ~isSelected,
    ~onClick,
    ~icon="",
    ~hint="",
    ~tag="",
    ~isDisabled=false,
    ~children=React.null,
  ) => {
    let tile =
      <div
        className={`${tileBase} ${tileState(
            ~isSelected,
            ~isDisabled,
          )} p-3 flex flex-col gap-2 h-full`}
        onClick={_ => isDisabled ? () : onClick()}>
        <div className="flex items-start justify-between gap-2">
          <RenderIf condition={icon->LogicUtils.isNonEmptyString}>
            <Icon
              name=icon
              size=18
              className={isSelected ? "text-nd_primary_blue-450" : "text-nd_gray-500"}
            />
          </RenderIf>
          <RenderIf condition={tag->LogicUtils.isNonEmptyString}>
            <span
              className={`rounded px-1 py-0.5 bg-nd_gray-150 text-nd_gray-500 ${body.xs.semibold}`}>
              {tag->React.string}
            </span>
          </RenderIf>
        </div>
        <p
          className={`${body.md.semibold} ${isSelected
              ? "text-nd_primary_blue-600"
              : "text-nd_gray-700"}`}>
          {title->React.string}
        </p>
        children
      </div>
    hint->LogicUtils.isEmptyString
      ? tile
      : <ToolTip description=hint toolTipFor=tile toolTipPosition=ToolTip.Top fullWidth=true />
  }
}

// A story card: a grey icon, the title and one short grey line. One accent only: the picked card
// has a blue edge and a check; the others lift a little on hover.
module StoryTile = {
  @react.component
  let make = (~title, ~icon, ~line, ~isSelected, ~onClick, ~isDisabled=false, ~hint="") => {
    let tile =
      <div
        role="button"
        ariaSelected=isSelected
        className={`relative h-[68px] rounded-xl border bg-white px-2.5 py-2 flex items-start gap-2.5 text-left transition duration-150 ${switch (
            isSelected,
            isDisabled,
          ) {
          | (true, _) => "border-nd_primary_blue-450 ring-1 ring-nd_primary_blue-450"
          | (false, true) => "border-nd_gray-150 !bg-nd_gray-50 opacity-60 cursor-not-allowed"
          | (
              false,
              false,
            ) => "border-nd_gray-200 cursor-pointer hover:-translate-y-0.5 hover:border-nd_gray-300 hover:shadow-md"
          }}`}
        onClick={_ => isDisabled ? () : onClick()}>
        <RenderIf condition=isSelected>
          <span
            className="absolute top-2.5 right-2.5 w-5 h-5 rounded-full bg-nd_primary_blue-450 text-white flex items-center justify-center">
            <Icon name="nd-check" size=10 />
          </span>
        </RenderIf>
        <span
          // Hidden where the two-column form is narrowest (1080 to 1280 px), so the words fit
          className="shrink-0 w-7 h-7 rounded-full bg-nd_gray-100 text-nd_gray-600 flex laptop:hidden xl:flex items-center justify-center">
          <Icon name=icon size=14 />
        </span>
        // One fixed height for every tile, so the grid stays even: the title on one line (cut only
        // as a last resort), the grey line on up to two (the whole text on hover)
        <div className="min-w-0 flex flex-col gap-0.5 pr-4">
          <p title className={`truncate ${body.sm.semibold} text-nd_gray-800`}>
            {title->React.string}
          </p>
          <p title=line className={`line-clamp-2 ${body.xs.medium} text-nd_gray-500`}>
            {line->React.string}
          </p>
        </div>
      </div>
    hint->LogicUtils.isEmptyString
      ? tile
      : <ToolTip description=hint toolTipFor=tile toolTipPosition=ToolTip.Top fullWidth=true />
  }
}

// A small picture of a payment card: blue for the good card, grey for a declining one
module CardArt = {
  @react.component
  let make = (~isGood) => {
    <div
      className={`shrink-0 w-9 h-6 rounded p-1 ${isGood
          ? "bg-gradient-to-br from-nd_primary_blue-450 to-nd_primary_blue-600"
          : "bg-gradient-to-br from-nd_gray-500 to-nd_gray-700"}`}>
      <div className="w-2.5 h-1.5 rounded-sm bg-nd_yellow-300 opacity-90" />
    </div>
  }
}

// A card as the timeline shows it: its brand's logo (the dashboard's own files in /assets/Gateway,
// as C's checkout shows the brands) and the last four digits. An unknown brand gets a grey card shape.
module CardChip = {
  @react.component
  let make = (~last4) => {
    open SimulatorTestCards
    let logo = switch cards
    ->Array.find(card => card.pan->String.endsWith(last4))
    ->Option.map(card => card.pan->brandOf) {
    | Some(Visa) => Some("VISA")
    | Some(Mastercard) => Some("MASTERCARD")
    | Some(Amex) => Some("AMERICANEXPRESS")
    | Some(Discover) => Some("DISCOVER")
    | _ => None
    }
    <span className="inline-flex items-center gap-1 align-middle whitespace-nowrap tabular-nums">
      {switch logo {
      | Some(gateway) => <GatewayIcon gateway className="h-4 w-auto" />
      | None => <span className="inline-block w-[27px] h-4 rounded-[3px] bg-nd_gray-300" />
      }}
      {`••${last4}`->React.string}
    </span>
  }
}

// An icon in a small square, the picture of a choice that has no card
module IconArt = {
  @react.component
  let make = (~isSelected, ~children) => {
    <div
      className={`shrink-0 w-9 h-6 rounded flex items-center justify-center ${isSelected
          ? "bg-nd_primary_blue-50 text-nd_primary_blue-600"
          : "bg-nd_gray-100 text-nd_gray-600"}`}>
      children
    </div>
  }
}

// One choice in the form's one tile style: a picture, a title and a short line under it. About
// 88 px high, so every column of the form ends at the same height; smaller beside a story.
module ChoiceTile = {
  @react.component
  let make = (
    ~title,
    ~subtitle,
    ~art: React.element,
    ~isSelected,
    ~onClick,
    ~isDisabled=false,
    ~isCompact=false,
    ~tag=React.null,
  ) => {
    <div
      className={`${tileBase} ${tileState(~isSelected, ~isDisabled)} ${isCompact
          ? "p-2.5 gap-1.5"
          : "h-[88px] p-3"} min-w-0 flex flex-col justify-between`}
      onClick={_ => isDisabled ? () : onClick()}>
      art
      <div className="flex flex-col min-w-0">
        <p
          className={`truncate ${body.md.semibold} ${isSelected
              ? "text-nd_primary_blue-600"
              : "text-nd_gray-700"}`}>
          {title->React.string}
        </p>
        <p className={`truncate ${body.sm.medium} text-nd_gray-500`}> {subtitle->React.string} </p>
      </div>
      // A tag (for example "Hard decline") goes under the text, so a narrow tile has room for it
      {tag === React.null ? React.null : <div className="flex"> tag </div>}
    </div>
  }
}

let currencySign = currency =>
  switch currency {
  | "USD" => "$"
  | "EUR" => "€"
  | "GBP" => "£"
  | other => other
  }

// The amount: one 48 px field with the currency sign in front and a compact currency select inside
// it on the right, and the usual amounts as small tiles under it (88 px in all, like the tiles).
// The amount is text in major units ("65.40").
module AmountField = {
  @react.component
  let make = (
    ~amount,
    ~setAmount,
    ~currency,
    ~setCurrency=?,
    ~currencies=["USD", "EUR", "GBP"],
    ~quickAmounts=["25.00", "65.40", "120.00"],
    ~isDisabled=false,
  ) => {
    let input: ReactFinalForm.fieldRenderPropsInput = {
      name: "amount",
      onBlur: _ => setAmount(amount->SimulatorUtils.toAmountText),
      onFocus: _ => (),
      onChange: event =>
        setAmount(
          ReactEvent.Form.target(event)["value"]->String.replaceRegExp(%re("/[^\d.]/g"), ""),
        ),
      value: amount->JSON.Encode.string,
      checked: false,
    }
    <div className="flex flex-col gap-2">
      <TextInput
        input
        placeholder="0.00"
        inputMode="decimal"
        isDisabled
        customDashboardClass="h-12 text-sm font-normal"
        leftIcon={<span className={`${body.md.semibold} text-nd_gray-600`}>
          {currency->currencySign->React.string}
        </span>}
        iconOpacity="opacity-100"
        rightIcon=?{setCurrency->Option.map(setCurrency =>
          <select
            value=currency
            disabled=isDisabled
            onChange={event => setCurrency(ReactEvent.Form.target(event)["value"])}
            className={`h-8 rounded-lg border border-nd_gray-150 bg-nd_gray-50 pl-2 pr-1 ${body.sm.semibold} text-nd_gray-700 focus:outline-none ${isDisabled
                ? "cursor-not-allowed"
                : "cursor-pointer"}`}>
            {currencies
            ->Array.map(code => <option key=code value=code> {code->React.string} </option>)
            ->React.array}
          </select>
        )}
        rightIconCustomStyle="-ml-[80px] self-center"
        customPaddingClass={setCurrency->Option.isSome ? "pl-8 pr-[88px]" : "pl-8 pr-2"}
        customStyle="rounded-xl border-nd_gray-200"
      />
      <RenderIf condition={quickAmounts->Array.length > 0}>
        <div className="grid grid-cols-3 gap-2">
          {quickAmounts
          ->Array.map(quick =>
            <button
              key=quick
              type_="button"
              disabled=isDisabled
              className={`${tileBase} ${tileState(
                  ~isSelected=quick == amount,
                  ~isDisabled,
                )} h-8 ${body.sm.semibold} !text-center ${quick == amount
                  ? "text-nd_primary_blue-600"
                  : "text-nd_gray-700"}`}
              onClick={_ => setAmount(quick)}>
              {`${currency->currencySign}${quick->String.replace(".00", "")}`->React.string}
            </button>
          )
          ->React.array}
        </div>
      </RenderIf>
    </div>
  }
}
