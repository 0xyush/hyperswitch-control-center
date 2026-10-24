// Glossary drawer (PRD section 20). An underlined term opens the drawer at that term.
open Typography

type entry = {term: string, aliases: array<string>, definition: string}

type drawerState = Closed | Open(option<string>)

let drawerAtom: Recoil.recoilAtom<drawerState> = Recoil.atom("simulatorGlossaryDrawer", Closed)

let entries: array<entry> = [
  {
    term: "Soft decline",
    aliases: ["soft decline", "soft declines"],
    definition: "The bank said \"not now\" (for example, no funds). Worth retrying.",
  },
  {
    term: "Hard decline",
    aliases: ["hard decline", "hard declines"],
    definition: "The bank said \"never\" (for example, a stolen card). Rev Rec stops.",
  },
  {
    term: "Monitoring",
    aliases: ["monitoring"],
    definition: "Rev Rec records failures but does not retry yet.",
  },
  {
    term: "Static retries (cascading)",
    aliases: ["static retries", "cascading"],
    definition: "A fixed ladder of retry times.",
  },
  {
    term: "Smart retries",
    aliases: ["smart retries"],
    definition: "Rev Rec picks the day and hour per invoice from past outcomes.",
  },
  {
    term: "Start rule",
    aliases: ["start rule"],
    definition: "How many failures before Rev Rec takes over (0 = on the first).",
  },
  {
    term: "Grace period",
    aliases: ["grace period"],
    definition: "The window in which Rev Rec may retry.",
  },
  {
    term: "Card network limits",
    aliases: ["card network limits", "card network limit", "network limit"],
    definition: "Visa and Mastercard caps on retries per card.",
  },
  {
    term: "MIT",
    aliases: ["MIT"],
    definition: "A charge the merchant starts on a saved card, with no customer present.",
  },
  {
    term: "Processor token",
    aliases: ["processor token"],
    definition: "The saved-card reference at the processor. No card numbers are stored.",
  },
  {
    term: "Record back",
    aliases: ["record back"],
    definition: "Rev Rec telling the billing platform that an invoice is paid.",
  },
  {
    term: "Webhook",
    aliases: ["webhook", "webhooks"],
    definition: "A message one system sends to another when something changes, for example when an invoice is paid.",
  },
  {
    term: "Error catalogue (GSM)",
    aliases: ["error catalogue", "GSM"],
    definition: "Juspay's table that maps processor error codes to categories such as hard decline.",
  },
  {
    term: "Billing simulator",
    aliases: ["billing simulator"],
    definition: "The part of the proxy that plays the merchant's billing system, and in the portfolio run, the customer's bank.",
  },
  {
    term: "Proxy",
    aliases: ["proxy"],
    definition: "The small server between the browser and the sandbox that holds the keys.",
  },
]

let aliasToTerm =
  entries
  ->Array.flatMap(entry =>
    entry.aliases->Array.map(alias => (alias->String.toLowerCase, entry.term))
  )
  ->Dict.fromArray

// Longest alias first, so "card network limits" wins over "network limit"
let termPattern = {
  let aliases = entries->Array.flatMap(entry => entry.aliases)
  aliases->Array.sort((a, b) => Int.toFloat(b->String.length - a->String.length))
  RegExp.fromStringWithFlags(`\\b(${aliases->Array.joinWith("|")})\\b`, ~flags="gi")
}

module Term = {
  @react.component
  let make = (~term: string, ~children) => {
    let setDrawerState = Recoil.useSetRecoilState(drawerAtom)
    <span
      className="underline decoration-dotted decoration-nd_gray-400 underline-offset-2 cursor-help hover:text-nd_primary_blue-450"
      onClick={_ => setDrawerState(_ => Open(Some(term)))}>
      children
    </span>
  }
}

// Underlines the first mention of each glossary term in a plain sentence
let linkTerms = (text: string) => {
  let linked = Dict.make()
  text
  ->String.splitByRegExp(termPattern)
  ->Array.filterMap(part => part)
  ->Array.mapWithIndex((part, index) => {
    let key = index->Int.toString
    switch aliasToTerm->Dict.get(part->String.toLowerCase) {
    | Some(term) if linked->Dict.get(term)->Option.isNone => {
        linked->Dict.set(term, true)
        <Term key term> {part->React.string} </Term>
      }
    | _ => <React.Fragment key> {part->React.string} </React.Fragment>
    }
  })
  ->React.array
}

module OpenButton = {
  @react.component
  let make = () => {
    let setDrawerState = Recoil.useSetRecoilState(drawerAtom)
    <Button
      text="Glossary"
      buttonType=Secondary
      buttonSize=Medium
      onClick={_ => setDrawerState(_ => Open(None))}
    />
  }
}

module EntryCard = {
  @react.component
  let make = (~entry: entry, ~isSelected) => {
    <div
      className={`flex flex-col gap-1 rounded-lg p-3 border ${isSelected
          ? "bg-nd_primary_blue-50 border-nd_primary_blue-200"
          : "border-transparent"}`}>
      <p className={`${body.md.semibold} text-nd_gray-700`}> {entry.term->React.string} </p>
      <p className={`${body.md.medium} text-nd_gray-500`}> {entry.definition->React.string} </p>
    </div>
  }
}

// Right-hand drawer in the style of the Explore Workflows drawer
module Drawer = {
  @react.component
  let make = () => {
    let (drawerState, setDrawerState) = Recoil.useRecoilState(drawerAtom)
    switch drawerState {
    | Closed => React.null
    | Open(selected) =>
      let selectedEntry = entries->Array.find(entry => Some(entry.term) == selected)
      <div
        className="fixed inset-0 z-50 flex justify-end items-end p-4 pointer-events-none overflow-x-hidden">
        <div
          className="w-100 h-full bg-white rounded-lg border border-jp-gray-300 shadow-rightDrawerShadow flex flex-col pointer-events-auto">
          <div className="flex flex-col p-6 gap-2">
            <div className="flex justify-between items-center">
              <p className={`${heading.sm.semibold} text-nd_gray-700`}>
                {"Glossary"->React.string}
              </p>
              <Icon
                name="close"
                size=14
                className="text-jp-gray-700 cursor-pointer"
                onClick={_ => setDrawerState(_ => Closed)}
              />
            </div>
            <span className={`${body.md.semibold} text-nd_gray-400`}>
              {"Plain words for the terms on these pages."->React.string}
            </span>
          </div>
          <hr />
          <div className="p-6 pt-3 overflow-y-scroll flex flex-col gap-2">
            {switch selectedEntry {
            | Some(entry) =>
              <>
                <EntryCard entry isSelected=true />
                <hr className="my-2" />
              </>
            | None => React.null
            }}
            {entries
            ->Array.filter(entry => Some(entry.term) != selected)
            ->Array.map(entry => <EntryCard key=entry.term entry isSelected=false />)
            ->React.array}
          </div>
        </div>
      </div>
    }
  }
}
