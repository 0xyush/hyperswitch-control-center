// Form pieces for the simulator's left panels (simulator/UX-PASS-2.md A1): tiles, chips and toggles
// instead of a wall of dropdowns. The story form uses them; the portfolio form can too.
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

// A small picture of a payment card with its last four digits
module MiniCard = {
  @react.component
  let make = (~last4, ~isGood) => {
    <div
      className={`shrink-0 w-14 h-9 rounded-md p-1.5 flex flex-col justify-between text-white ${isGood
          ? "bg-gradient-to-br from-nd_primary_blue-450 to-nd_primary_blue-600"
          : "bg-gradient-to-br from-nd_gray-500 to-nd_gray-700"}`}>
      <div className="w-3 h-2 rounded-sm bg-nd_yellow-300 opacity-90" />
      <span className="text-[9px] leading-none font-semibold tracking-wide self-end">
        {`•• ${last4}`->React.string}
      </span>
    </div>
  }
}

// A saved-card tile: the card picture (it shows "•• 4242") above the card's name
module CardTile = {
  @react.component
  let make = (~last4, ~name, ~isGood, ~isSelected, ~onClick, ~isDisabled=false) => {
    <div
      className={`${tileBase} ${tileState(~isSelected, ~isDisabled)} p-3 flex flex-col gap-2`}
      onClick={_ => isDisabled ? () : onClick()}>
      <MiniCard last4 isGood />
      <p
        className={`${body.md.semibold} ${isSelected
            ? "text-nd_primary_blue-600"
            : "text-nd_gray-700"}`}>
        {name->React.string}
      </p>
    </div>
  }
}

// Two or three choices side by side, one selected: "New customer | Same customer"
module ToggleChip = {
  @react.component
  let make = (
    ~options: array<(string, string)>,
    ~value,
    ~onChange,
    ~isDisabled=false,
    ~size="h-9",
  ) => {
    <div className={`inline-flex rounded-lg bg-nd_gray-150 p-0.5 ${size}`}>
      {options
      ->Array.map(((optionValue, label)) => {
        let isSelected = optionValue == value
        <button
          key=optionValue
          type_="button"
          disabled=isDisabled
          className={`px-3 rounded-md ${body.sm.semibold} ${isSelected
              ? "bg-white text-nd_gray-800 shadow-sm"
              : "text-nd_gray-500 hover:text-nd_gray-700"} ${isDisabled
              ? "cursor-not-allowed"
              : ""}`}
          onClick={_ => onChange(optionValue)}>
          {label->React.string}
        </button>
      })
      ->React.array}
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

// The amount: one number field with the currency sign in front and a small currency toggle at
// the end, and quick-pick chips under it. The amount is text in major units ("65.40").
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
        leftIcon={<span className={`${body.md.semibold} text-nd_gray-600`}>
          {currency->currencySign->React.string}
        </span>}
        iconOpacity="opacity-100"
        rightIcon=?{setCurrency->Option.map(setCurrency =>
          <ToggleChip
            options={currencies->Array.map(code => (code, code))}
            value=currency
            onChange=setCurrency
            isDisabled
            size="h-7"
          />
        )}
        rightIconCustomStyle="-ml-[148px] self-center"
        customPaddingClass={setCurrency->Option.isSome ? "pl-8 pr-[152px]" : "pl-8 pr-2"}
        customStyle="rounded-lg border-nd_gray-200"
      />
      <div className="flex flex-wrap gap-2">
        {quickAmounts
        ->Array.map(quick => {
          let isSelected = quick == amount
          <button
            key=quick
            type_="button"
            disabled=isDisabled
            className={`h-7 px-3 rounded-full border ${body.sm.semibold} ${isSelected
                ? "border-nd_primary_blue-450 bg-nd_primary_blue-25 text-nd_primary_blue-600"
                : "border-nd_gray-200 text-nd_gray-600 hover:border-nd_gray-300"} ${isDisabled
                ? "cursor-not-allowed opacity-60"
                : ""}`}
            onClick={_ => setAmount(quick)}>
            {`${currency->currencySign}${quick->String.replace(".00", "")}`->React.string}
          </button>
        })
        ->React.array}
      </div>
    </div>
  }
}
