open SimulatorTypes
open SimulatorUtils
open Typography

let cardStyle = "bg-white border border-nd_gray-200 rounded-xl"

let toPercent = value => `${value->Float.toString}%`

// A raw event's colour, by the story's colour rule (see toneChipClass in SimulatorStorySteps):
// green only when money is collected, red for a decline or a refusal, amber when handed over or
// waiting, blue when Rev Rec acts, grey when nothing has happened yet
type eventColor = EventGreen | EventRed | EventAmber | EventBlue | EventGrey

let eventColor = (row: diagramRow) => {
  let has = text => row.label->String.includes(text)
  switch (row.status, row.from, row.to) {
  | (StepDeclined | StepFailed, _, _) => EventRed
  | (_, _, _) if has("already recorded") || has("terminated") => EventRed
  | (StepPending, _, _) => EventAmber
  | (StepOk, Billing, RevRec) => EventAmber
  | (StepOk, RevRec, RevRec) => EventBlue
  | (StepOk, _, Processor) if has("save card") || has("add card") => EventGrey
  | (StepOk, _, Processor) | (StepOk, RevRec, Billing) => EventGreen
  | _ => EventGrey
  }
}

// Line and arrow-head colours for a diagram row
let stepColor = (row: diagramRow) =>
  switch row->eventColor {
  | EventGreen => ("border-nd_green-400", "text-nd_green-400")
  | EventRed => ("border-nd_red-400", "text-nd_red-400")
  | EventAmber =>
    row.status == StepPending
      ? ("border-nd_yellow-500 border-dashed", "text-nd_yellow-500")
      : ("border-nd_yellow-500", "text-nd_yellow-500")
  | EventBlue => ("border-nd_primary_blue-450", "text-nd_primary_blue-450")
  | EventGrey => ("border-nd_gray-400", "text-nd_gray-400")
  }

// A form input outside react-final-form, fed from React state
let makeInput = (
  ~name,
  ~value,
  ~onChange,
  ~onBlur=() => (),
): ReactFinalForm.fieldRenderPropsInput => {
  name,
  onBlur: _ => onBlur(),
  onFocus: _ => (),
  // Selects send the new value as a string; text inputs send a change event
  onChange: event =>
    onChange(
      Js.typeof(event) == "string"
        ? event->Identity.formReactEventToString
        : ReactEvent.Form.target(event)["value"],
    ),
  value: value->JSON.Encode.string,
  checked: false,
}

module FormField = {
  @react.component
  let make = (~label, ~children) => {
    <div className="flex flex-col gap-1">
      <label className={`${body.md.semibold} text-nd_gray-700`}> {label->React.string} </label>
      children
    </div>
  }
}

// A dropdown under a label: the dashboard's Blend select at its large size (the select adapter does
// not pass a size, so the wrapper is used directly). Its largest trigger is 40 px; a scoped rule
// makes it 48 px like the amount field. The menu opens in a portal, so the rule does not reach it.
// A disabled option shows its description on hover.
let selectFieldCss = ".sim-select-48 [data-element='single-select-button'] { height: 48px !important; max-height: 48px !important; border-radius: 12px !important; }"

module SelectField = {
  @react.component
  let make = (~label, ~name, ~options, ~value, ~onChange, ~isDisabled=false) => {
    <FormField label>
      <div className="sim-select-48">
        <style> {selectFieldCss->React.string} </style>
        <SingleSelectWrapper
          items={SingleSelectWrapper.makeItems(
            options,
            ~deselectDisable=true,
            ~selectedValue=value,
          )}
          placeholder={`Select ${label->String.toLowerCase}`}
          input={makeInput(~name, ~value, ~onChange)}
          disabled=isDisabled
          size=Lg
          fullWidth=true
          allowDeselect=false
        />
      </div>
    </FormField>
  }
}

// Kebab menu with less common actions (the billing form's, the story panel's)
module ActionMenu = {
  open HeadlessUI
  @react.component
  let make = (~options: array<(string, unit => unit)>) => {
    <Popover \"as"="div" className="relative flex items-center text-left">
      {_ => <>
        <Popover.Button> {_ => <Icon name="menu-option" size=28 />} </Popover.Button>
        <Popover.Panel className="absolute z-20 right-0 top-8">
          {panelProps =>
            <div
              className="relative flex flex-col bg-white py-1 overflow-hidden rounded ring-1 ring-black ring-opacity-5 w-64">
              {options
              ->Array.map(((text, onClick)) =>
                <Navbar.MenuOption
                  key=text
                  text
                  onClick={_ => {
                    panelProps["close"]()
                    onClick()
                  }}
                />
              )
              ->React.array}
            </div>}
        </Popover.Panel>
      </>}
    </Popover>
  }
}

// The five main story tiles, in order (the sixth place is "More stories"): preset id, a short
// title, a grey outline icon and one line in the customer's words (the title stays on one line,
// the line may wrap to two). One list, so a story can be swapped here; every other story is under
// "More stories".
let scenarioTiles = [
  (15, "Payday", "nd-bank", "Gets paid on the 1st or 15th"),
  (12, "Daily limit", "nd-wallet", "Hit the daily spending limit"),
  (14, "Low until Monday", "nd-piggy-bank", "Account is low until Monday"),
  (19, "Last chance", "nd-flag", "Money comes just before retries end"),
  (20, "Too late", "nd-hour-glass-outline", "Money comes after fixed retries stop"),
]
let isMainStory = id => scenarioTiles->Array.some(((tileId, _, _, _)) => tileId == id)

// The icons of some stories under More stories (the others take their decline's icon)
let moreStoryIcons = [
  (1, "nd-wallet"),
  (2, "nd-hour-glass-outline"),
  (4, "nd-toast-warning"),
  (6, "nd-piggy-bank"),
  (7, "nd-toast-warning"),
  (13, "nd-shield"),
  (16, "paper-plane"),
]

// The two cards a customer can have on file: last four digits, name, works or not
let savedCardTiles = [("4242", "Good card", true), ("0341", "Declining card", false)]

// The icon set has no person glyphs, so small line icons
// A person with a cross: the customer cancels
let userCancelIcon =
  <svg
    width="16"
    height="16"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="2"
    strokeLinecap="round"
    strokeLinejoin="round">
    <path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2" />
    <circle cx="9" cy="7" r="4" />
    <path d="M17 8l5 5M22 8l-5 5" />
  </svg>

let personIcon = (~withPlus) =>
  <svg
    width="16"
    height="16"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="2"
    strokeLinecap="round"
    strokeLinejoin="round">
    {withPlus
      ? <>
          <path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2" />
          <circle cx="9" cy="7" r="4" />
          <path d="M19 8v6M22 11h-6" />
        </>
      : <>
          <path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2" />
          <circle cx="12" cy="7" r="4" />
        </>}
  </svg>

// New or returning customer: value, title, short line, icon
let customerTiles = [
  ("new", "New", "First invoice", personIcon(~withPlus=true)),
  ("same", "Returning", "Has paid before", personIcon(~withPlus=false)),
]

// The scenario's name: its tile title, else the preset's own title
let scenarioName = (~options: formOptions, ~preset) =>
  switch scenarioTiles->Array.find(((id, _, _, _)) => id == preset) {
  | Some((_, title, _, _)) => title
  | None =>
    options.presets
    ->Array.find(item => item.id == preset)
    ->Option.mapOr("None", item => item.title)
  }

// The scenario tile for a preset: its tile, with its one short line under the title
let scenarioTile = (
  ~id,
  ~title,
  ~icon,
  ~description,
  ~isSelected,
  ~isDisabled,
  ~onClick,
  ~hint="",
) =>
  <SimulatorFormTiles.StoryTile
    key={id->Int.toString} title icon line=description isSelected isDisabled hint onClick
  />

// What Rev Rec's model knows about the story's decline, as short rows: the reason it files the
// failure under, how often retries for that reason worked, the best hours and days (the seeded
// counts the model uses), and its pick for the next retry once the story runs.
module ModelKnowsCard = {
  let capitalize = text =>
    `${text->String.charAt(0)->String.toUpperCase}${text->String.sliceToEnd(~start=1)}`
  let row = (label, value) =>
    <div key=label className="flex items-baseline justify-between gap-3">
      <span className={`shrink-0 ${body.sm.medium} text-nd_gray-500`}> {label->React.string} </span>
      // A long value wraps (never cut, never past the card's edge)
      <span className={`min-w-0 break-words text-right ${body.sm.semibold} text-nd_gray-800`}>
        {value->React.string}
      </span>
    </div>

  @react.component
  let make = (~firstCharge, ~next="Picked after the charge fails") => {
    open SimulatorTestCards
    let decline = firstCharge->declineOf
    let group = decline->groupOf
    let seed = switch group {
    | Group(cluster, _) => SimulatorSeedStats.seeds->Array.find(s => s.cluster == cluster)
    | Hard | NoGroup => None
    }
    let reason = switch group {
    | Group(_, name) => name
    | Hard | NoGroup =>
      decline->Option.mapOr("Not given", code =>
        code->String.replaceRegExp(%re("/_/g"), " ")->capitalize
      )
    }
    let rows = switch (group, seed) {
    | (Hard, _) => [row("Reason", reason), row("Retries", "None: a hard decline")]
    | (_, Some(s)) => {
        let rate =
          s.tries == 0
            ? 0
            : Math.round(Int.toFloat(s.worked) *. 100.0 /. Int.toFloat(s.tries))->Float.toInt
        let days = s.days->String.startsWith("the ") ? s.days->String.sliceToEnd(~start=4) : s.days
        [
          row("Reason", reason),
          row(
            "Worked before",
            `${s.worked->Int.toLocaleString} of ${s.tries->Int.toLocaleString} retries (${rate->Int.toString}%)`,
          ),
          row("Best time", `${s.hours} UTC (${s.hoursRate->Int.toString}%)`),
          row("Best days", `${days->capitalize} (${s.daysRate->Int.toString}%)`),
          row("Next retry", next),
        ]
      }
    | (_, None) => [
        row("Reason", reason),
        row("Worked before", "No counts yet"),
        row("Next retry", next),
      ]
    }
    <div className={`${cardStyle} min-w-0 p-4 flex flex-col gap-2`}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className={`${body.md.semibold} text-nd_gray-800`}>
          {"What Rev Rec's model knows"->React.string}
        </p>
        <RenderIf condition={seed->Option.isSome}>
          <ToolTip
            description="These counts are made up for the demo, shaped like published retry patterns. The engine adds real outcomes as stories run."
            toolTipPosition=ToolTip.Top
            toolTipFor={<span
              className={`rounded px-1.5 py-0.5 border whitespace-nowrap cursor-help bg-nd_gray-50 text-nd_gray-600 border-nd_gray-200 ${body.xs.semibold}`}>
              {"Seeded counts ?"->React.string}
            </span>}
          />
        </RenderIf>
      </div>
      {rows->React.array}
    </div>
  }
}

// Where a real-world story ends on the fixed timetable, as a small chip. Every story runs Rev
// Rec's smart model, so the chip names the timetable: its number is the baseline, not the result.
let recoversChip = (recoversOn: recoversOn) => {
  let (text, colors) = switch recoversOn {
  | RecoversOnRetry(retry) => (
      `Fixed timetable: retry ${retry->Int.toString}`,
      "bg-nd_green-50 text-nd_green-600",
    )
  | NotRecovered => ("Fixed timetable: too late", "bg-nd_red-50 text-nd_red-600")
  | Varies => ("Fixed timetable: varies", "bg-nd_gray-150 text-nd_gray-600")
  }
  <span className={`w-fit rounded px-1.5 py-0.5 ${body.xs.semibold} ${colors}`}>
    {text->React.string}
  </span>
}

// A small icon for a real-world story's decline, from its first-charge card
let reasonIcon = firstCharge =>
  switch firstCharge {
  | "9995" => "nd-piggy-bank" // insufficient funds
  | "0119" => "nd-hour-glass-outline" // processing error: a short hiccup
  | "6975" => "nd-toast-warning" // over a spending limit
  | _ => "nd-shield" // the bank holds the card
  }

// A real-world story: the bank says no until a real-life moment, then the card works. Its tile
// says why in one line and where the fixed timetable ends.
// A story's icon: its own when it has one, else the icon of its decline
let storyIconOf = (preset: preset) =>
  moreStoryIcons
  ->Array.find(((id, _)) => id == preset.id)
  ->Option.mapOr(preset.fields.firstCharge->reasonIcon, ((_, icon)) => icon)

let realWorldTile = (~preset: preset, ~isSelected, ~isDisabled, ~onClick) =>
  <SimulatorFormTiles.Tile
    key={preset.id->Int.toString}
    title=preset.title
    icon={preset->storyIconOf}
    isSelected
    isDisabled
    onClick>
    // These names describe where the money lands on the fixed timetable
    <RenderIf condition={[18, 19, 20]->Array.includes(preset.id)}>
      <p className={`-mt-1.5 ${body.xs.medium} text-nd_gray-500`}>
        {"for the fixed timetable"->React.string}
      </p>
    </RenderIf>
    <p className={`${body.sm.medium} text-nd_gray-500`}> {preset.summary->React.string} </p>
    {preset.group == "real-world" ? preset.recoversOn->recoversChip : React.null}
  </SimulatorFormTiles.Tile>

// The More stories filter: when the money comes back, measured on the fixed timetable
type storyFilter = AllStories | RecoversEarly | RecoversLate | NeverRecovers
let storyFilters = [
  (AllStories, "All"),
  (RecoversEarly, "Money back soon"),
  (RecoversLate, "Money back later"),
  (NeverRecovers, "Too late for the timetable"),
]
// Early: by retry 6 (the first day); late: after it, or on payday (varies)
let matchesFilter = (filter, preset: preset) =>
  switch (filter, preset.recoversOn) {
  | (AllStories, _) => true
  // The filters measure the fixed timetable, so they hold the real-world stories only
  | _ if preset.group != "real-world" => false
  | (RecoversEarly, RecoversOnRetry(retry)) => retry <= 6
  | (RecoversLate, RecoversOnRetry(retry)) => retry > 6
  | (RecoversLate, Varies) => true
  | (NeverRecovers, NotRecovered) => true
  | _ => false
  }

// "More stories": a centred window over a dimmed page; the cards in a grid, filter chips on top.
// X, Esc or a click outside closes it; picking a story fills the form.
module MoreStoriesModal = {
  @react.component
  let make = (~isOpen, ~onClose, ~stories: array<preset>, ~picked, ~isLocked, ~onPick) => {
    let (filter, setFilter) = React.useState(_ => AllStories)
    let shown =
      stories
      ->Array.filter(preset => filter->matchesFilter(preset))
      ->Array.toSorted((a, b) => Int.toFloat(a.id - b.id))
    <Modal
      showModal=isOpen
      setShowModal={_ => onClose()}
      closeOnOutsideClick=true
      modalHeading="More stories"
      modalClass="w-full max-w-[880px] max-h-[85vh] mx-auto my-auto !bg-white rounded-xl overflow-hidden flex flex-col"
      childClass="flex flex-col min-h-0">
      <AddDataAttributes attributes=[("data-sim", "more-stories")]>
        <div className="flex flex-col gap-4 px-6 pt-4 pb-6 min-h-0">
          <p className={`${body.md.medium} text-nd_gray-600`}>
            {"Every other story. The real-world ones show when a fixed timetable would recover."->React.string}
          </p>
          <div className="flex flex-wrap gap-2">
            {storyFilters
            ->Array.map(((value, label)) => {
              let isOn = value == filter
              <button
                key=label
                type_="button"
                className={`rounded-full border px-3 py-1 ${body.sm.semibold} ${isOn
                    ? "border-nd_primary_blue-450 bg-nd_primary_blue-50 text-nd_primary_blue-600"
                    : "border-nd_gray-200 bg-white text-nd_gray-600 hover:border-nd_gray-300"}`}
                onClick={_ => setFilter(_ => value)}>
                {label->React.string}
              </button>
            })
            ->React.array}
          </div>
          <div className="overflow-y-auto max-h-[60vh] -mx-1 px-1 pb-1">
            <div className="grid grid-cols-2 md:grid-cols-3 gap-3">
              {shown
              ->Array.map(preset =>
                realWorldTile(
                  ~preset,
                  ~isSelected={picked == preset.id},
                  ~isDisabled=isLocked,
                  ~onClick=() => onPick(preset),
                )
              )
              ->React.array}
            </div>
          </div>
        </div>
      </AddDataAttributes>
    </Modal>
  }
}

// A saved card's tile: its name, "••4242" and the card picture
let cardTile = (~last4, ~name, ~isGood, ~isSelected, ~isDisabled, ~isCompact, ~tag, ~onClick) =>
  <SimulatorFormTiles.ChoiceTile
    key=last4
    title=name
    subtitle={`••${last4}`}
    art={<SimulatorFormTiles.CardArt isGood />}
    isSelected
    isDisabled
    isCompact
    tag
    onClick
  />

let customerTile = (
  ~value,
  ~title,
  ~subtitle,
  ~icon,
  ~isSelected,
  ~isDisabled,
  ~onClick,
  ~isCompact=false,
) =>
  <SimulatorFormTiles.ChoiceTile
    key=value
    title
    subtitle
    art={<SimulatorFormTiles.IconArt isSelected> icon </SimulatorFormTiles.IconArt>}
    isSelected
    isDisabled
    onClick
    isCompact
  />

// Focus the first input inside an element (the checkout's Card Number once it unlocks)
let focusFirstInput: Dom.element => unit = %raw(`function (el) {
  var input = el.querySelector("input");
  if (input) input.focus();
}`)

// "1 Pick a story": the step's number (a check once done) and its words, above each column
module StepLabel = {
  @react.component
  let make = (~number, ~text, ~isDone=false, ~isActive=true) =>
    <div className="flex items-center gap-2">
      <span
        className={`w-6 h-6 rounded-full flex items-center justify-center ${body.sm.semibold} ${isDone
            ? "bg-nd_green-400 text-white"
            : isActive
            ? "bg-nd_primary_blue-450 text-white"
            : "bg-nd_gray-150 text-nd_gray-500"}`}>
        {isDone ? <Icon name="nd-check" size=12 /> : number->Int.toString->React.string}
      </span>
      <span
        className={`${body.md.semibold} ${isActive || isDone
            ? "text-nd_gray-700"
            : "text-nd_gray-400"}`}>
        {text->React.string}
      </span>
    </div>
}

// Before the first charge the form is the page, step by step: 1 pick a story on the left (the
// billing system), 2 enter the card in the customer's checkout on the right (as the control
// center's Setup Checkout: locked and blurred until a story is picked), the chain under both
module BillingSystemForm = {
  @react.component
  let make = (
    ~options: formOptions,
    ~form: billingForm,
    ~setForm,
    ~isBusy,
    // True from the moment Charge customer is pressed until the story leaves "starting"
    ~isLocked,
    ~onCharge,
    // The page was opened on a story (?preset=N), so step 1 is already done
    ~startUnlocked=false,
    // After Pay: the first charge's decline (reason in plain words, card), then the handover
    ~declined: option<(string, string)>=?,
    ~onHandover=() => (),
    ~isHandingOver=false,
    ~onStartOver=() => (),
    // The story failed before Rev Rec got it (a start error, the proxy restarted)
    ~startFailed=false,
  ) => {
    let (showAdvanced, setShowAdvanced) = React.useState(_ => false)
    // No story is picked at first (a ?preset link has one). Continue then opens step 2, the
    // checkout, and it stays open.
    let (hasPicked, setHasPicked) = React.useState(_ => startUnlocked)
    let (isUnlocked, setIsUnlocked) = React.useState(_ => startUnlocked)
    let checkoutRef = React.useRef(Nullable.null)
    let unlock = () =>
      if !isUnlocked {
        setIsUnlocked(_ => true)
        // The blur fades out; then the cursor waits in Card Number
        setTimeout(
          () => checkoutRef.current->Nullable.toOption->Option.forEach(focusFirstInput),
          320,
        )->ignore
      }

    let (showMore, setShowMore) = React.useState(_ => false)
    let presetById = id => options.presets->Array.find(preset => preset.id == id)
    // Every story has a tile or a place in More stories; only "no story" (preset 0) opens More
    // options
    let isTileScenario = form.preset->presetById->Option.isSome
    // More stories: every other story
    let moreStories = options.presets->Array.filter(preset => !(preset.id->isMainStory))

    // The processors that work now (GET /sim/connectors), as (connector name, display name). The
    // form starts on the one picked in Setup Recovery, when it works.
    let simFetch = SimulatorApi.useSimFetch()
    let (processors, setProcessors) = React.useState(_ => [("stripe", "Stripe")])
    React.useEffect(() => {
      let read = async () =>
        try {
          open LogicUtils
          let json = await simFetch(~path="/sim/connectors", ~method_=Get)
          let working =
            json
            ->getDictFromJsonObject
            ->getArrayFromDict("connectors", [])
            ->Array.filterMap(item => {
              let c = item->getDictFromJsonObject
              c->getString("kind", "") == "processor" &&
              c->getBool("working", false) &&
              c->getString("id", "")->processorEnabled
                ? Some((c->getString("id", ""), c->getString("name", "")))
                : None
            })
          if working->Array.length > 0 {
            setProcessors(_ => working)
          }
          switch savedProcessor() {
          | Some(id) if working->Array.some(((value, _)) => value == id) =>
            setForm((prev: billingForm) => {...prev, processor: id})
          | _ => ()
          }
        } catch {
        | _ => ()
        }
      read()->ignore
      None
    }, [])
    // A story fills the form; the chosen retry mode and processor stay, except that a story the
    // processor cannot run runs on Stripe
    let withPreset = (prev: billingForm, preset: preset) => {
      ...preset.fields,
      card: prev.card,
      maxRetries: prev.maxRetries,
      retryMode: prev.retryMode,
      processor: presetRunsOn(~options, ~processor=prev.processor, ~preset)
        ? prev.processor
        : "stripe",
    }
    // Picking a story is step 1: it fills the form; Continue opens the checkout
    let pickStory = preset => {
      setForm(prev => prev->withPreset(preset))
      setHasPicked(_ => true)
    }
    let isStripe = form.processor == "stripe"
    let processorName =
      processors
      ->Array.find(((value, _)) => value == form.processor)
      ->Option.mapOr(form.processor, ((_, name)) => name)
    // What this processor runs (GET /sim/presets limits.processors): Stripe runs every story; the
    // others run Temporary error, and the real-world stories once the scripted bank works there
    let rule = options.processorRules->Array.find(rule => rule.id == form.processor)
    let runsOn = (~processor, id) =>
      presetById(id)->Option.mapOr(false, preset => presetRunsOn(~options, ~processor, ~preset))
    let runsHere = id => runsOn(~processor=form.processor, id)
    let moreHere = moreStories->Array.filter(preset => runsHere(preset.id))
    let tileHint =
      rule->Option.mapOr(false, rule => rule.presets->Array.length > 1)
        ? "This story runs on Stripe only."
        : `${processorName} runs the Temporary error story only.`
    let moreHint = switch rule {
    | Some({bankReady: false}) => `The scripted bank is not ready for ${processorName} yet.`
    | _ => "Stories with a scripted bank run on Stripe only."
    }
    // The bank on this processor gives no decline reason (proxy's bank.genericOnly)
    let isGeneric = rule->Option.mapOr(!isStripe, rule => rule.genericOnly)

    // A story the new processor cannot run drops back to the first tile
    let setProcessor = processor =>
      setForm((prev: billingForm) =>
        !runsOn(~processor, prev.preset)
          ? scenarioTiles
            ->Array.get(0)
            ->Option.flatMap(((id, _, _, _)) => presetById(id))
            ->Option.mapOr({...prev, processor}, preset => {
              ...preset.fields,
              retryMode: prev.retryMode,
              processor,
            })
          : {...prev, processor}
      )

    // Two columns, like the control center's Setup Checkout: the billing system's choices on the
    // left, the customer's checkout on the right (C's preview), the chain under both
    <div className="flex flex-col gap-5">
      // One row, equal height: the shorter column stretches to the taller one (the left card grows;
      // on the right the model card sits at the bottom)
      <div
        className="grid grid-cols-1 laptop:grid-cols-[minmax(0,1.2fr)_minmax(0,1fr)] gap-6 items-stretch">
        <div className="min-w-0 flex flex-col gap-3">
          <StepLabel number=1 text="Pick a story" isDone=isUnlocked />
          <div className={`${cardStyle} flex-1 p-5 flex flex-col gap-4`}>
            <div className="flex flex-col gap-0.5">
              <p className={`${heading.sm.semibold} text-nd_gray-800`}>
                {"Billing system"->React.string}
              </p>
              <p className={`${body.md.medium} text-nd_gray-500`}>
                {"You are the merchant's billing system."->React.string}
              </p>
            </div>
            // The story decides what the bank says; two compact cards per row
            <FormField label="The customer's situation">
              <div className="flex flex-col gap-2">
                <p className={`-mt-1 ${body.sm.medium} text-nd_gray-500`}>
                  {"Why the payment fails"->React.string}
                </p>
                <div className="grid grid-cols-2 gap-2">
                  {scenarioTiles
                  ->Array.map(((id, title, icon, description)) => {
                    let preset = presetById(id)
                    scenarioTile(
                      ~id,
                      ~title,
                      ~icon,
                      ~description,
                      ~isSelected={hasPicked && form.preset == id},
                      ~isDisabled={
                        isLocked ||
                        preset->Option.isNone ||
                        (preset->Option.isSome && !runsHere(id))
                      },
                      ~hint={preset->Option.isSome && !runsHere(id) ? tileHint : ""},
                      ~onClick=() => preset->Option.forEach(pickStory),
                    )
                  })
                  ->React.array}
                  {
                    let picked = hasPicked
                      ? moreStories->Array.find(preset => preset.id == form.preset)
                      : None
                    <SimulatorFormTiles.StoryTile
                      title={picked->Option.mapOr(
                        `More stories (${moreHere->Array.length->Int.toString})`,
                        preset => preset.title,
                      )}
                      icon={picked->Option.mapOr("nd-plus", storyIconOf)}
                      line={picked->Option.mapOr("Every other situation", preset => preset.summary)}
                      isSelected={picked->Option.isSome}
                      isDisabled={isLocked || moreHere->Array.length == 0}
                      hint={moreStories->Array.length > 0 && moreHere->Array.length == 0
                        ? moreHint
                        : ""}
                      onClick={() => setShowMore(_ => true)}
                    />
                  }
                </div>
              </div>
            </FormField>
            <MoreStoriesModal
              isOpen=showMore
              onClose={() => setShowMore(_ => false)}
              stories=moreHere
              picked=form.preset
              isLocked
              onPick={preset => {
                pickStory(preset)
                setShowMore(_ => false)
              }}
            />
            // New or returning, as one slim segmented control (what each means on hover)
            <FormField label="Customer">
              <div
                role="tablist"
                className="grid grid-cols-2 gap-1 rounded-lg border border-nd_gray-200 bg-white p-1">
                {customerTiles
                ->Array.map(((value, title, subtitle, _)) => {
                  let isOn = form.customer == value
                  <ToolTip
                    key=value
                    description=subtitle
                    toolTipPosition=ToolTip.Top
                    fullWidth=true
                    toolTipFor={<button
                      type_="button"
                      role="tab"
                      ariaSelected=isOn
                      disabled=isLocked
                      className={`w-full h-9 rounded-md transition-colors ${body.sm.semibold} ${isOn
                          ? "bg-nd_primary_blue-450 text-white shadow-sm"
                          : "text-nd_gray-600 hover:bg-nd_gray-100 hover:text-nd_gray-800"} ${isLocked
                          ? "cursor-not-allowed"
                          : "cursor-pointer"}`}
                      onClick={_ => setForm(prev => {...prev, customer: value})}>
                      {`${title} customer`->React.string}
                    </button>}
                  />
                })
                ->React.array}
              </div>
            </FormField>
            // Currency and Amount as on Setup Checkout
            <div className="grid grid-cols-2 gap-3 items-start">
              <SelectField
                label="Currency"
                name="currency"
                isDisabled=isLocked
                options=options.currencies
                value=form.currency
                onChange={currency => setForm(prev => {...prev, currency})}
              />
              <FormField label="Amount">
                <SimulatorFormTiles.AmountField
                  amount=form.amount
                  setAmount={amount => setForm(prev => {...prev, amount})}
                  currency=form.currency
                  quickAmounts=[]
                  isDisabled=isLocked
                />
              </FormField>
            </div>
            // Like Setup Checkout's Show Preview: opens step 2 with the story as it is
            <RenderIf condition={!isUnlocked}>
              <Button
                text="Continue"
                buttonType=Primary
                buttonSize=Large
                customHeightClass="h-11"
                customButtonStyle="!w-full"
                buttonState={isLocked || !hasPicked ? Disabled : Normal}
                onClick={_ => unlock()}
              />
            </RenderIf>
            <RenderIf condition=isGeneric>
              <span className={`${body.md.medium} text-nd_gray-500`}>
                {`Decline reasons may be generic on ${processorName}.`->React.string}
              </span>
            </RenderIf>
            // The less common choices behind a link
            <button
              type_="button"
              className={`w-fit flex items-center gap-1 text-blue-500 hover:text-blue-700 ${body.md.semibold}`}
              onClick={_ => setShowAdvanced(prev => !prev)}>
              {(showAdvanced || !isTileScenario ? "Fewer options" : "More options")->React.string}
              <Icon
                name={showAdvanced || !isTileScenario ? "nd-angle-up" : "nd-angle-down"} size=12
              />
            </button>
            <RenderIf condition={showAdvanced || !isTileScenario}>
              <div className="grid grid-cols-1 gap-3">
                // Only when more than one processor is offered (processorsEnabled)
                <RenderIf condition={processors->Array.length > 1}>
                  <SelectField
                    label="Processor"
                    name="processor"
                    isDisabled=isLocked
                    options={processors->Array.map(((value, name)): SelectBox.dropdownOption => {
                      label: name,
                      value,
                      icon: Button.CustomIcon(
                        <GatewayIcon
                          gateway={value->String.toUpperCase} className="mr-2 w-5 h-5"
                        />,
                      ),
                    })}
                    value=form.processor
                    onChange=setProcessor
                  />
                </RenderIf>
                // Max tries: Rev Rec's limit for this story (15 by default)
                <FormField label="Max tries">
                  <div className="flex flex-col gap-1">
                    <div className="flex items-center gap-3">
                      <input
                        type_="range"
                        min="1"
                        max="15"
                        step=1.0
                        ariaLabel="Max tries"
                        value={form.maxRetries->Int.toString}
                        disabled=isLocked
                        className={`min-w-0 flex-1 accent-nd_primary_blue-450 ${isLocked
                            ? "cursor-not-allowed opacity-50"
                            : "cursor-pointer"}`}
                        onChange={event =>
                          ReactEvent.Form.target(event)["value"]
                          ->Int.fromString
                          ->Option.forEach(maxRetries => setForm(prev => {...prev, maxRetries}))}
                      />
                      <span
                        className={`w-6 text-right tabular-nums ${body.md.semibold} text-nd_gray-800`}>
                        {form.maxRetries->Int.toString->React.string}
                      </span>
                    </div>
                    <p className={`${body.sm.medium} text-nd_gray-500`}>
                      {"Rev Rec stops after this many retries."->React.string}
                    </p>
                  </div>
                </FormField>
                <SelectField
                  label="Other stories"
                  name="preset"
                  isDisabled=isLocked
                  options={form.preset == 0
                    ? [noPresetOption]->Array.concat(options.presets->presetOptions)
                    : options.presets->presetOptions}
                  value={form.preset->Int.toString}
                  onChange={value =>
                    options.presets
                    ->Array.find(preset => preset.id->Int.toString == value)
                    ->Option.forEach(pickStory)}
                />
              </div>
            </RenderIf>
          </div>
        </div>
        // Step 2, the customer's checkout (C's preview, like the Web SDK): blurred and locked until
        // Continue. Its card's last four go to the proxy as the start field card, never the number.
        <div className="min-w-0 flex flex-col gap-3">
          <StepLabel number=2 text="Enter the card" isActive=isUnlocked />
          <RenderIf condition=startFailed>
            <AddDataAttributes attributes=[("data-sim", "start-failed")]>
              <div
                className="flex flex-wrap items-center gap-3 rounded-lg border border-nd_red-300 bg-nd_red-50 px-4 py-3">
                <p className={`${body.md.medium} text-nd_red-600`}>
                  {"Something went wrong while starting. Try again."->React.string}
                </p>
                <button
                  type_="button"
                  className={`ml-auto text-blue-500 hover:text-blue-700 ${body.md.semibold}`}
                  onClick={_ => onStartOver()}>
                  {"Start over"->React.string}
                </button>
              </div>
            </AddDataAttributes>
          </RenderIf>
          // The column ends level with the left one: the model card grows to fill it; while locked
          // (no model card) the checkout does
          <div
            ref={ReactDOM.Ref.domRef(checkoutRef)}
            className={isUnlocked ? "" : "flex-1 flex flex-col [&>*]:flex-1"}>
            <SimulatorCheckout.Preview
              locked={!isUnlocked}
              lockText={hasPicked ? "Press Continue" : "Pick a story first"}
              amount=form.amount
              currency=form.currency
              customer=form.customer
              isBusy={isBusy || isLocked}
              // The card is set as it changes, so a charge never reads an old one
              onCard={pan =>
                if pan != "" {
                  setForm(prev => {...prev, card: pan->String.sliceToEnd(~start=-4)})
                }}
              onPay={_ => onCharge()}
              // The first charge's decline: C's failed page, the dunning email and the handover
              declined=?{declined->Option.map(((reason, last4)): SimulatorCheckout.declined => {
                reason,
                last4: last4->LogicUtils.isNonEmptyString ? last4 : form.card,
              })}
              onHandover
              isHandingOver
              onStartOver
            />
          </div>
          // The story's decline and what the model knows about it; it stays under C's preview
          <RenderIf condition=isUnlocked>
            <div className="flex-1 flex flex-col [&>*]:flex-1">
              <ModelKnowsCard firstCharge=form.firstCharge />
            </div>
          </RenderIf>
        </div>
      </div>
    </div>
  }
}

// "New story": the icon set has no refresh glyph, so a small circular arrow
let refreshIcon =
  <svg
    width="14"
    height="14"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="2"
    strokeLinecap="round"
    strokeLinejoin="round">
    <path d="M21 12a9 9 0 1 1-2.64-6.36" />
    <path d="M21 3v6h-6" />
  </svg>

// Why an action cannot run now, for its tooltip
let unavailableReason = (~story: option<story>, ~isBusy) =>
  switch story {
  | _ if isBusy => "Wait for the last action to finish."
  | None => "The billing system is still charging."
  | Some(s) if s->storyHasEnded => "Not available: the invoice has ended."
  | Some(s) if s.recoveryId->LogicUtils.isEmptyString => "Wait for Rev Rec to record the invoice."
  | Some(_) => "Not possible at this step."
  }

// The status bar's buttons, as the dashboard's secondary button draws them (32 px)
// The dashboard's secondary fill is clipped to the content box, so the padding sits on the inner
// text (statusButtonText), never on the button: one solid fill, as on New story
let statusButtonClass = `h-8 flex items-center whitespace-nowrap rounded-lg border border-border_gray secondary-gradient-button text-button-secondary-text ${body.md.medium}`
let statusButtonText = "h-full px-3 flex items-center gap-1.5"

// "Make something happen": a status bar button; the live events in a popover under it. Off (with
// the reason on hover) until Rev Rec has the invoice.
module MakeSomethingHappen = {
  open HeadlessUI
  @react.component
  let make = (~isOn, ~offReason, ~children: (unit => unit) => React.element) =>
    isOn
      ? <Popover \"as"="div" className="relative">
          {_ => <>
            <Popover.Button className=statusButtonClass>
              {_ =>
                <span className=statusButtonText>
                  {"Make something happen"->React.string}
                  <Icon name="nd-angle-down" size=10 />
                </span>}
            </Popover.Button>
            <Popover.Panel className="absolute z-30 right-0 top-10">
              {panelProps =>
                <div
                  className="w-[360px] rounded-xl border border-nd_gray-200 bg-white p-3 shadow-lg flex flex-col gap-2">
                  <p className={`${body.sm.medium} text-nd_gray-500`}>
                    {"Make something happen. Rev Rec reacts at its next step."->React.string}
                  </p>
                  {children(() => panelProps["close"]())}
                </div>}
            </Popover.Panel>
          </>}
        </Popover>
      : <ToolTip
          description=offReason
          toolTipPosition=ToolTip.Top
          toolTipFor={<button
            type_="button"
            disabled=true
            className={`${statusButtonClass} opacity-50 cursor-not-allowed`}>
            <span className=statusButtonText>
              {"Make something happen"->React.string}
              <Icon name="nd-angle-down" size=10 />
            </span>
          </button>}
        />
}

// The live events behind "Make something happen", two rows of three: what fixes it (money back,
// pays, fails again), then what ends or blocks it (stolen, outage, the customer cancels)
module EventsMenu = {
  @react.component
  let make = (
    ~story: option<story>,
    ~isBusy,
    ~onPaidInApp,
    ~onReportAgain,
    ~onEvent: string => unit,
    // The customer cancels the subscription (POST cancel)
    ~onCustomerCancels,
  ) => {
    let isAwaiting = story->Option.mapOr(false, s => s.awaitingHandover)
    let handoverFirst = "Pass the invoice to Rev Rec first."
    let actions =
      story->Option.mapOr({paidInApp: false, reportAgain: false, cancel: false}, s => s.actions)
    let reason = unavailableReason(~story, ~isBusy)
    // One event: an icon over a short label, the full sentence on hover; it closes the menu when
    // it runs
    let eventButton = (~label, ~icon, ~hint, ~isAvailable, ~offReason, ~onClick, ~close) => {
      let isOn = isAvailable && !isBusy && !isAwaiting
      let offReason = isAwaiting ? handoverFirst : offReason
      <ToolTip
        key=label
        description={isOn ? hint : offReason}
        toolTipPosition=ToolTip.Top
        fullWidth=true
        toolTipFor={<button
          type_="button"
          disabled={!isOn}
          className={`w-full h-14 rounded-lg border flex flex-col items-center justify-center gap-1 ${body.sm.semibold} ${isOn
              ? "border-nd_gray-200 bg-white text-nd_gray-700 hover:border-nd_gray-300 hover:bg-nd_gray-25 cursor-pointer"
              : "border-nd_gray-150 bg-nd_gray-50 text-nd_gray-400 cursor-not-allowed"}`}
          onClick={_ =>
            if isOn {
              close()
              onClick()
            }}>
          icon
          {label->React.string}
        </button>}
      />
    }
    let rules = story->Option.flatMap(s => s.eventRules)
    let worldEvent = (~eventType, ~label, ~icon, ~hint, ~close) => {
      let rule = rules->Option.flatMap(rules => rules->Dict.get(eventType))
      eventButton(
        ~label,
        ~icon=<Icon name=icon size=16 />,
        ~hint,
        ~isAvailable=rule->Option.mapOr(false, rule => rule.allowed),
        ~offReason=rule
        ->Option.map(rule => rule.reason)
        ->Option.filter(LogicUtils.isNonEmptyString)
        ->Option.getOr(rules->Option.isSome ? reason : "Not in this story."),
        ~onClick=() => onEvent(eventType),
        ~close,
      )
    }
    // Open after the end too: "Fails again" then shows Rev Rec's answer to a late failure
    <MakeSomethingHappen isOn={story->Option.isSome && !isAwaiting} offReason=handoverFirst>
      {close =>
        <div className="grid grid-cols-3 gap-2">
          {worldEvent(
            ~eventType="money_back",
            ~label="Money back",
            ~icon="nd-piggy-bank",
            ~hint="The customer's account has money again. Rev Rec's next try works.",
            ~close,
          )}
          {eventButton(
            ~label="Pays in app",
            ~icon=<Icon name="nd-wallet" size=16 />,
            ~hint="The customer pays by hand. Rev Rec stops.",
            ~isAvailable=actions.paidInApp,
            ~offReason=reason,
            ~onClick=onPaidInApp,
            ~close,
          )}
          {eventButton(
            ~label="Fails again",
            ~icon=<Icon name="nd-toast-warning" size=16 />,
            ~hint={
              story->Option.flatMap(s => s.reportAgainClosed)->Option.isSome
                ? "This invoice is closed. Rev Rec will refuse it."
                : "The billing system tries the card and it fails."
            },
            ~isAvailable=actions.reportAgain,
            ~offReason=reason,
            ~onClick=onReportAgain,
            ~close,
          )}
          // No "New card": Rev Rec retries only the card the customer authorized for this
          // invoice (user, 28 Oct). The money comes back on the same card instead.
          {worldEvent(
            ~eventType="stolen",
            ~label="Stolen",
            ~icon="nd-shield",
            ~hint="The bank flags the card. The next charge is a hard decline.",
            ~close,
          )}
          {worldEvent(
            ~eventType="outage",
            ~label="Bank outage",
            ~icon="nd-bank",
            ~hint="The bank is down for 6 hours. Charges fail until then.",
            ~close,
          )}
          {eventButton(
            ~label="Customer cancels",
            ~icon=userCancelIcon,
            ~hint="The customer cancels the subscription. Rev Rec stops.",
            ~isAvailable=actions.cancel,
            ~offReason=reason,
            ~onClick=onCustomerCancels,
            ~close,
          )}
        </div>}
    </MakeSomethingHappen>
  }
}

module ArrowHead = {
  @react.component
  let make = (~pointsRight, ~colorClass) => {
    <svg width="8" height="8" viewBox="0 0 8 8" className=colorClass>
      <path d={pointsRight ? "M0 0 L8 4 L0 8 z" : "M8 0 L0 4 L8 8 z"} fill="currentColor" />
    </svg>
  }
}

module Countdown = {
  @react.component
  let make = (~nextRetryAt) => {
    let (nowMs, setNowMs) = React.useState(_ => Date.now())
    React.useEffect(() => {
      let intervalId = setInterval(() => setNowMs(_ => Date.now()), 1000)
      Some(() => clearInterval(intervalId))
    }, [])
    countdownText(~nextRetryAt, ~nowMs)->React.string
  }
}

// One message: label above a thin arrow between two lifelines, time in the right column
module DiagramRow = {
  @react.component
  let make = (~row: diagramRow, ~time: React.element, ~onClick) => {
    let isPending = row.status == StepPending
    let (lineClass, headClass) = row->stepColor
    let fromX = row.from->lifelinePercent
    let toX = row.to->lifelinePercent
    let left = Math.min(fromX, toX)
    let width = Math.abs(toX -. fromX)
    let pointsRight = toX > fromX
    let labelCenter = left +. width /. 2.0
    // A centred label may grow until it reaches the nearer edge of the diagram
    let labelMaxWidth = 2.0 *. Math.min(labelCenter, 100.0 -. labelCenter)
    let labelClass = `absolute whitespace-nowrap truncate px-1 ${body.sm.medium} ${isPending
        ? "text-nd_primary_blue-450"
        : "text-nd_gray-700"}`

    <div
      className="flex items-stretch rounded-md hover:bg-nd_gray-25 cursor-pointer"
      onClick={_ => onClick()}>
      <div className="relative flex-1 h-12">
        {lifelines
        ->Array.map(actor =>
          <div
            key={actor->actorLabel->fst}
            className="absolute top-0 bottom-0 border-l border-dashed border-nd_gray-200"
            style={left: actor->lifelinePercent->toPercent}
          />
        )
        ->React.array}
        {if row.from == row.to {
          // A step inside one system, drawn as a small loop on its lifeline
          <>
            <div
              className={`absolute h-3 w-6 border border-l-0 rounded-r ${lineClass}`}
              style={left: fromX->toPercent, top: "26px"}
            />
            <div
              className=labelClass
              style={
                left: `calc(${fromX->toPercent} + 32px)`,
                top: "6px",
                maxWidth: (100.0 -. fromX -. 5.0)->toPercent,
              }>
              {row.label->React.string}
            </div>
          </>
        } else {
          <>
            <div
              className={`${labelClass} -translate-x-1/2`}
              style={left: labelCenter->toPercent, top: "6px", maxWidth: labelMaxWidth->toPercent}>
              {row.label->React.string}
            </div>
            <div
              className={`absolute border-t ${lineClass}`}
              style={left: left->toPercent, width: width->toPercent, top: "32px"}
            />
            <div
              className="absolute flex"
              style={
                left: pointsRight ? `calc(${toX->toPercent} - 8px)` : toX->toPercent,
                top: "28px",
              }>
              <ArrowHead pointsRight colorClass=headClass />
            </div>
          </>
        }}
      </div>
      <div
        className={`w-32 shrink-0 flex items-end justify-end pb-2 ${body.sm.regular} text-nd_gray-500`}>
        time
      </div>
    </div>
  }
}

// Seconds or minutes since a step, ticking
module Elapsed = {
  @react.component
  let make = (~since) => {
    let (nowMs, setNowMs) = React.useState(_ => Date.now())
    React.useEffect(() => {
      let intervalId = setInterval(() => setNowMs(_ => Date.now()), 1000)
      Some(() => clearInterval(intervalId))
    }, [])
    elapsedText(~since, ~nowMs)->React.string
  }
}

// The lifeline view, behind "Show sequence diagram": the same visible steps, drawn as arrows
module LifelineDiagram = {
  @react.component
  let make = (~rows: array<diagramRow>, ~onRowClick) => {
    <div className="flex flex-col gap-3 border-t border-nd_gray-150 pt-4">
      <div className="flex border-b border-nd_gray-200 pb-3 pt-2">
        <div className="relative flex-1 h-10">
          {lifelines
          ->Array.map(actor => {
            let (name, note) = actor->actorLabel
            <div
              key=name
              className="absolute -translate-x-1/2 flex flex-col items-center"
              style={left: actor->lifelinePercent->toPercent}>
              <span className={`${body.md.semibold} text-nd_gray-800 whitespace-nowrap`}>
                {name->React.string}
              </span>
              <span className={`${body.sm.regular} text-nd_gray-400 whitespace-nowrap`}>
                {note->React.string}
              </span>
            </div>
          })
          ->React.array}
        </div>
        <div
          className={`w-32 shrink-0 flex items-end justify-end ${body.sm.medium} text-nd_gray-400`}>
          {"Time"->React.string}
        </div>
      </div>
      <div className="flex flex-col">
        {rows
        ->Array.mapWithIndex((row, index) =>
          <DiagramRow
            key={index->Int.toString}
            row
            time={row.status == StepPending
              ? <Countdown nextRetryAt=row.at />
              : row.at->toClockTime->React.string}
            onClick={() => onRowClick(row)}
          />
        )
        ->React.array}
      </div>
    </div>
  }
}

// Fade + slide in, 250 ms, with the dashboard's ease-in-out curve. Delays only stagger steps
// that arrived together; a step never moves after it has landed.
let revealCss = "@keyframes simStepIn { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: none; } } .sim-step-reveal { animation: simStepIn 250ms cubic-bezier(0.4, 0, 0.2, 1) both; } @media (prefers-reduced-motion: reduce) { .sim-step-reveal { animation: none; } }"

let revealStaggerMs = 400

// Which cards fade in, and after what delay. When a story is opened (or refreshed), the cards
// known at that moment show at once; only cards added later animate.
let useRevealDelays = (~storyKey: string, ~itemCount: int, ~initialCount: int) => {
  let tracked = React.useRef((storyKey, initialCount, Dict.make()))
  let (trackedKey, _, _) = tracked.current
  if trackedKey != storyKey {
    tracked.current = (storyKey, initialCount, Dict.make())
  }
  let (key, shown, delays) = tracked.current
  if itemCount > shown {
    for index in shown to itemCount - 1 {
      delays->Dict.set(index->Int.toString, (index - shown) * revealStaggerMs)
    }
    tracked.current = (key, itemCount, delays)
  }
  delays
}

let stepDomId = index => `sim-step-${index->Int.toString}`
let doneDomId = "sim-step-done"

let revealProps = (delay: option<int>) => (
  delay->Option.isSome ? "sim-step-reveal" : "",
  delay->Option.map(ms => `${ms->Int.toString}ms`),
)

let badgeClass = (row: diagramRow) =>
  switch row->eventColor {
  | EventGreen => "bg-nd_green-50 text-nd_green-600 border border-nd_green-200"
  | EventRed => "bg-nd_red-50 text-nd_red-600 border border-nd_red-200"
  | EventAmber =>
    row.status == StepPending
      ? "bg-white text-nd_yellow-700 border border-dashed border-nd_yellow-500"
      : "bg-nd_yellow-50 text-nd_yellow-700 border border-nd_yellow-300"
  | EventBlue => "bg-nd_primary_blue-50 text-nd_primary_blue-600 border border-nd_primary_blue-200"
  | EventGrey => "bg-nd_gray-50 text-nd_gray-600 border border-nd_gray-200"
  }

// The "?" button that opens why something happened (it replaces the "Why" text links)
module HelpButton = {
  @react.component
  let make = (~onClick, ~label="Why") => {
    <button
      type_="button"
      ariaLabel=label
      title=label
      className={`shrink-0 w-5 h-5 rounded-full border border-nd_gray-300 text-nd_gray-500 hover:border-nd_primary_blue-450 hover:text-nd_primary_blue-450 flex items-center justify-center ${body.xs.semibold}`}
      onClick={event => {
        event->ReactEvent.Mouse.stopPropagation
        onClick()
      }}>
      {"?"->React.string}
    </button>
  }
}

// One step card: number, title, who to whom, time, a "?" button. Status sets the badge colour.
module StepCard = {
  @react.component
  let make = (
    ~row: diagramRow,
    ~stepNumber: int,
    ~domId=?,
    ~time: React.element,
    ~isNewest: bool,
    ~revealDelay: option<int>,
    ~onOpen,
    ~children=React.null,
  ) => {
    let isPending = row.status == StepPending
    let (fromName, _) = row.from->actorLabel
    let (toName, _) = row.to->actorLabel
    let who = row.from == row.to ? fromName : `${fromName} → ${toName}`
    let (revealClass, animationDelay) = revealDelay->revealProps
    <div
      id={domId->Option.getOr(stepDomId(stepNumber - 1))}
      className={`relative overflow-hidden rounded-lg border bg-white px-4 py-3 flex gap-3 cursor-pointer hover:bg-nd_gray-25 ${isPending
          ? "border-dashed border-nd_primary_blue-450"
          : "border-nd_gray-150"} ${revealClass}`}
      style={animationDelay: ?animationDelay}
      onClick={_ => onOpen()}>
      // The newest step carries a primary-blue edge until the next one lands
      <RenderIf condition=isNewest>
        <div className="absolute left-0 top-0 bottom-0 w-1 bg-nd_primary_blue-450" />
      </RenderIf>
      <div
        className={`shrink-0 w-7 h-7 rounded-full flex items-center justify-center ${body.sm.semibold} ${row->badgeClass}`}>
        {stepNumber->Int.toString->React.string}
      </div>
      <div className="flex-1 min-w-0 flex flex-col gap-1">
        <div className="flex items-start justify-between gap-3">
          <p className={`${body.md.semibold} text-nd_gray-800`} style={overflowWrap: "anywhere"}>
            {row.label->React.string}
          </p>
          <span className={`${body.sm.regular} text-nd_gray-500 whitespace-nowrap`}> time </span>
        </div>
        <div className={`flex items-center gap-2 ${body.sm.medium} text-nd_gray-500`}>
          <span> {who->React.string} </span>
          <HelpButton onClick=onOpen />
        </div>
        children
      </div>
    </div>
  }
}

let pillStyle = `h-9 w-fit flex items-center gap-2 px-3 rounded-full ${body.md.semibold}`

// The proxy sets `waiting` when Rev Rec has not booked a retry long after it should have (sandbox
// scheduler). A quiet amber pill says so in place of the next action; "?" opens the why.
module StallPill = {
  @react.component
  let make = (~onWhy) => {
    <div className={`${pillStyle} border bg-nd_orange-50 border-nd_orange-200 text-nd_orange-600`}>
      <span> {"Rev Rec has not booked a retry yet"->React.string} </span>
      <HelpButton onClick=onWhy />
    </div>
  }
}

// The one next action on the last step (UX-PASS-2 A4). "Next" reveals one more step; when that
// step has not arrived yet a quiet pill waits for it (with the countdown to a booked retry). A
// stalled sandbox shows the amber pill instead. "Customer pays in the app" sits beside, secondary.
module NextControls = {
  @react.component
  let make = (
    ~showNext,
    ~nextLabel,
    ~isWaiting,
    ~nextRetryAt: option<string>,
    ~waiting: option<waitingNote>,
    ~onWaitingWhy,
    ~onNext,
    ~inlineActions: array<(string, unit => unit)>,
    ~isBusy,
    // "Wed 8:00 PM (day 2)": the booked retry's real-life time
    ~pickedText: option<string>=?,
    // The visitor paused Rev Rec: the next retry waits until they resume
    ~isPaused=false,
  ) => {
    let isStalled = waiting->Option.isSome
    <RenderIf
      condition={showNext || isStalled || isWaiting || isPaused || inlineActions->Array.length > 0}>
      // Clicks here must not open the step's drawer
      <div
        className="flex flex-wrap items-center gap-3 pt-3"
        onClick={event => event->ReactEvent.Mouse.stopPropagation}>
        {switch (isStalled, showNext, isWaiting, nextRetryAt) {
        | _ if isPaused =>
          <div className={`${pillStyle} bg-nd_gray-150 text-nd_gray-600`}>
            <Icon name="pause" size=12 />
            {"Paused · next retry waits"->React.string}
          </div>
        | (true, _, _, _) => <StallPill onWhy=onWaitingWhy />
        | (false, _, true, Some(time)) =>
          <div className={`${pillStyle} bg-nd_gray-150 text-nd_gray-600`}>
            {pickedText
            ->Option.mapOr("Next retry ", picked => `Next retry: ${picked} · `)
            ->React.string}
            <Countdown nextRetryAt=time />
          </div>
        | (false, _, true, None) =>
          <div className={`${pillStyle} bg-nd_gray-150 text-nd_gray-600`}>
            <Loadericon size=14 iconColor="text-nd_gray-500" />
            {"Rev Rec is picking a time…"->React.string}
          </div>
        | (false, true, false, _) =>
          <div className="flex flex-col gap-2">
            <Button text=nextLabel buttonType=Primary buttonSize=Medium onClick={_ => onNext()} />
            <p className={`${body.sm.medium} text-nd_gray-500`}>
              {"Rev Rec has not been informed yet. Tap to hand the failed invoice over."->React.string}
            </p>
          </div>
        | (false, false, false, _) => React.null
        }}
        {inlineActions
        ->Array.map(((text, onClick)) =>
          <Button
            key=text
            text
            buttonType=Secondary
            buttonSize=Medium
            buttonState={isBusy ? Disabled : Normal}
            onClick={_ => onClick()}
          />
        )
        ->React.array}
      </div>
    </RenderIf>
  }
}

// How many sandbox attempts each side made: "Billing 3 · Rev Rec 1"
let attemptCount = (story: story, ~by) =>
  story.attemptBy->Array.filter(who => who == by)->Array.length
