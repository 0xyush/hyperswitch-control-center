// The story form's card number: type a test card (or pick one) and the form shows what it is, whose
// test card, what the bank says, Rev Rec's group for it and what the model knows about that group.
// Only known test cards can start a story; any other number stays in this browser.
open SimulatorTypes
open SimulatorTestCards
open Typography

let processorName = (processors, id) =>
  processors->Array.find(((value, _)) => value == id)->Option.mapOr(id, ((_, name)) => name)

// Can a story start with this number on this processor?
let isUsable = (detection, ~processor) =>
  switch detection {
  | Test(card, _) =>
    card.chargeId->Option.isSome
      ? card.processors->Array.includes(processor)
      : card.declineCode->Option.isNone &&
        card.processors->Array.some(p => p != "stripe") &&
        card.processors->Array.includes(processor)
  | _ => false
  }

let note = (~text, ~tone) =>
  <p
    className={`${body.sm.medium} ${tone == "bad"
        ? "text-nd_red-600"
        : tone == "warn"
        ? "text-nd_orange-600"
        : "text-nd_gray-500"}`}>
    {text->React.string}
  </p>

module Field = {
  @react.component
  let make = (
    ~number: string,
    ~setNumber: string => unit,
    ~form: billingForm,
    ~setForm: (billingForm => billingForm) => unit,
    ~isLocked: bool,
    ~processors: array<(string, string)>,
    ~onProcessor: string => unit,
  ) => {
    let detection = number->detect
    let working = id => processors->Array.some(((value, _)) => value == id)

    // A known test card fills the form: a Stripe decline sets the first charge (and leaves the story,
    // unless it is the story's own card); a processor's card picks that processor
    let apply = raw => {
      setNumber(raw->digits->grouped)
      switch raw->detect {
      | Test(card, _) =>
        switch card.chargeId {
        | Some(firstCharge) =>
          if form.processor != "stripe" {
            onProcessor("stripe")
          }
          setForm(prev =>
            prev.firstCharge == firstCharge ? prev : {...prev, firstCharge, preset: 0}
          )
        | None =>
          switch card.processors->Array.filter(working) {
          | [] => ()
          | usable =>
            if !(usable->Array.includes(form.processor)) {
              usable->Array.get(0)->Option.forEach(onProcessor)
            }
          }
        }
      | _ => ()
      }
    }

    let detected = switch detection {
    | Test(card, brand) =>
      <div className="flex flex-col gap-1">
        <div className="flex flex-wrap items-center gap-2">
          <span
            className={`rounded px-1.5 py-0.5 bg-nd_gray-100 text-nd_gray-700 ${body.xs.semibold}`}>
            {brand->brandName->React.string}
          </span>
          <span className={`${body.sm.semibold} text-nd_gray-700`}>
            {card.owner->React.string}
          </span>
          {card.processors
          ->Array.filter(working)
          ->Array.map(p =>
            <GatewayIcon key=p gateway={p->String.toUpperCase} className="w-4 h-4" />
          )
          ->React.array}
        </div>
        <p className={`${body.sm.medium} text-nd_gray-500`}>
          {[card.does, card.cardType, card.country]
          ->Array.filter(s => s != "")
          ->Array.joinWith(" · ")
          ->React.string}
        </p>
      </div>
    | Typing(brand) => note(~text=`${brand->brandName} · keep typing`, ~tone="")
    | NotTest(brand, valid) =>
      <div className="flex flex-col gap-0.5">
        {note(~text=`${brand->brandName}${valid ? "" : " · not a valid number"}`, ~tone="")}
        {note(~text="Use a test card. Real cards are never charged here.", ~tone="bad")}
      </div>
    | Empty => note(~text="Type a test card number, or pick one below.", ~tone="")
    }

    // What stops a story with this card, in plain words
    let blocker = switch detection {
    | Test(card, _) if card.chargeId->Option.isNone && card.processors == ["stripe"] =>
      Some("This card pays at once, so nothing fails. Pick a card that declines.")
    | Test(card, _) if !(card.processors->Array.some(working)) =>
      Some(
        `${card.processors
          ->Array.map(p => processorName(processors, p))
          ->Array.joinWith(", ")} is not set up here.`,
      )
    | _ => None
    }

    // A card that several processors take: pick one
    let choice = switch detection {
    | Test(card, _)
      if card.chargeId->Option.isNone && card.processors->Array.filter(working)->Array.length > 1 =>
      <div className="flex flex-wrap items-center gap-1.5">
        <span className={`${body.xs.semibold} text-nd_gray-500`}> {"Run on"->React.string} </span>
        {card.processors
        ->Array.filter(working)
        ->Array.map(p =>
          <button
            key=p
            type_="button"
            disabled=isLocked
            onClick={_ => onProcessor(p)}
            className={`flex items-center gap-1 rounded-full border px-2 py-0.5 ${body.xs.semibold} ${form.processor ==
                p
                ? "border-nd_primary_blue-500 bg-nd_primary_blue-50 text-nd_primary_blue-600"
                : "border-nd_gray-200 bg-nd_gray-50 text-nd_gray-600 hover:border-nd_gray-400"}`}>
            <GatewayIcon gateway={p->String.toUpperCase} className="w-3.5 h-3.5" />
            {processorName(processors, p)->React.string}
          </button>
        )
        ->React.array}
      </div>
    | _ => React.null
    }

    <div className="flex flex-col gap-2">
      <AddDataAttributes attributes=[("data-sim", "card-number")]>
        <input
          type_="text"
          inputMode="numeric"
          autoComplete="off"
          spellCheck=false
          disabled=isLocked
          value=number
          placeholder="4000 0000 0000 9995"
          maxLength=23
          onChange={e => apply(ReactEvent.Form.target(e)["value"])}
          className={`h-12 w-full rounded-xl border px-4 font-mono ${body.lg.medium} text-nd_gray-800 outline-none transition focus:border-nd_primary_blue-500 focus:ring-2 focus:ring-nd_primary_blue-100 disabled:bg-nd_gray-50 ${switch detection {
            | NotTest(_) => "border-nd_red-300"
            | Test(_) => "border-nd_green-300"
            | _ => "border-nd_gray-200"
            }}`}
        />
      </AddDataAttributes>
      detected
      choice
      {blocker->Option.mapOr(React.null, text => note(~text, ~tone="warn"))}
      <div className="flex flex-wrap gap-1.5">
        {quickPicks
        ->Array.map(((pan, label)) => {
          let isOn = number->digits == pan
          <button
            key=pan
            type_="button"
            disabled=isLocked
            onClick={_ => apply(pan)}
            className={`rounded-lg border px-2 py-1 ${body.xs.semibold} transition ${isOn
                ? "border-nd_primary_blue-500 bg-nd_primary_blue-50 text-nd_primary_blue-600"
                : "border-nd_gray-200 bg-nd_gray-50 text-nd_gray-600 hover:border-nd_gray-400 hover:text-nd_gray-800"}`}>
            {label->React.string}
          </button>
        })
        ->React.array}
      </div>
    </div>
  }
}

// card -> what the bank says -> Rev Rec's group -> what the model knows (seeded counts)
module Chain = {
  let step = (~label, ~children) =>
    <div className="flex min-w-0 flex-col gap-0.5">
      <span className={`${body.xs.semibold} uppercase tracking-wide text-nd_gray-400`}>
        {label->React.string}
      </span>
      children
    </div>

  let arrow =
    <Icon name="nd-arrow-right" size=12 className="shrink-0 self-center text-nd_gray-300" />

  @react.component
  let make = (~number: string, ~form: billingForm) => {
    let detection = number->detect
    let card = switch detection {
    | Test(card, _) => Some(card)
    | _ => None
    }
    // A Stripe decline card brings its own reason; a processor card runs the story's reason
    let decline =
      card->Option.flatMap(c => c.declineCode)->Option.orElse(form.firstCharge->declineOf)
    let fromStory = card->Option.mapOr(true, c => c.declineCode->Option.isNone)
    let bankSays =
      cards
      ->Array.find(c => c.chargeId == Some(form.firstCharge))
      ->Option.mapOr("The bank says no.", c => c.does)
    let seed = cluster => SimulatorSeedStats.seeds->Array.find(s => s.cluster == cluster)
    let pct = (k, n) =>
      n == 0 ? 0 : Math.round(Int.toFloat(k) *. 100.0 /. Int.toFloat(n))->Float.toInt

    switch card {
    | None => React.null
    | Some(card) =>
      <div
        className="flex flex-wrap items-start gap-x-4 gap-y-2 rounded-xl border border-nd_gray-150 bg-nd_gray-25 px-4 py-3">
        {step(
          ~label="Card",
          ~children=<span className={`${body.md.semibold} text-nd_gray-700`}>
            {`••${card.pan->String.sliceToEnd(~start=-4)} · ${card.owner}`->React.string}
          </span>,
        )}
        arrow
        {step(
          ~label="The bank says",
          ~children=<span className={`${body.md.semibold} text-nd_gray-700`}>
            {(fromStory ? `${bankSays} (set by the story)` : bankSays)->React.string}
          </span>,
        )}
        arrow
        {switch decline->groupOf {
        | Hard =>
          step(
            ~label="Rev Rec",
            ~children=<span className={`${body.md.semibold} text-nd_red-600`}>
              {"Hard decline: Rev Rec stops at once."->React.string}
            </span>,
          )
        | Group(cluster, name) =>
          <>
            {step(
              ~label="Rev Rec's group for this card",
              ~children=<span className={`${body.md.semibold} text-nd_gray-700`}>
                {name->React.string}
              </span>,
            )}
            arrow
            {step(
              ~label="What the model knows",
              ~children=<span
                className={`flex flex-wrap items-center gap-2 ${body.md.medium} text-nd_gray-600`}>
                // Honest label: the counts the model starts from are made up for the demo
                <ToolTip
                  description="These counts are made up for the demo, shaped like published retry patterns. The engine adds real outcomes as stories run."
                  toolTipPosition=ToolTip.Top
                  toolTipFor={<span
                    className={`shrink-0 rounded px-1.5 py-0.5 border whitespace-nowrap cursor-help bg-nd_gray-50 text-nd_gray-600 border-nd_gray-200 ${body.xs.semibold}`}>
                    {"Seeded counts ?"->React.string}
                  </span>}
                />
                {switch seed(cluster) {
                | Some(s) =>
                  `Worked ${s.worked->Int.toLocaleString} of ${s.tries->Int.toLocaleString} tries (${pct(
                      s.worked,
                      s.tries,
                    )->Int.toString}%). Best: ${s.days} (${s.daysRate->Int.toString}%), ${s.hours} UTC (${s.hoursRate->Int.toString}%).`->React.string
                | None =>
                  "No seeded counts yet: Rev Rec uses its fixed timetable until it learns."->React.string
                }}
                <ToolTip
                  description="Rev Rec groups retries by the decline reason. Visa and Mastercard with the same reason share one group."
                  toolTipPosition=ToolTip.Top
                  toolTipFor={<span
                    className={`shrink-0 rounded px-1.5 py-0.5 border cursor-help bg-nd_gray-50 text-nd_gray-600 border-nd_gray-200 ${body.xs.semibold}`}>
                    {"?"->React.string}
                  </span>}
                />
              </span>,
            )}
          </>
        | NoGroup => React.null
        }}
      </div>
    }
  }
}
