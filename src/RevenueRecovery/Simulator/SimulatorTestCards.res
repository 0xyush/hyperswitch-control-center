// The test cards the story form knows: whose test card it is, what it does, which processor takes
// it. Only these can start a story, and even then only the card's id goes to the proxy, never the
// number. Any other number is checked here in the browser and goes nowhere.
type brand = Visa | Mastercard | Amex | Discover | OtherBrand

type testCard = {
  pan: string,
  owner: string,
  // Connector ids that take this card
  processors: array<string>,
  // The proxy's first-charge card id (scenarios.ts FIRST_CHARGE_CARDS); None: the card pays
  chargeId: option<string>,
  // Stripe's decline code; None: it pays, or the story's scripted bank decides
  declineCode: option<string>,
  does: string,
  cardType: string,
  country: string,
}

let stripeDecline = (last4, declineCode, does) => {
  pan: `400000000000${last4}`,
  owner: "Stripe test card",
  processors: ["stripe"],
  chargeId: Some(last4),
  declineCode: Some(declineCode),
  does,
  cardType: "Credit",
  country: "US",
}

let stripePays = (pan, does) => {
  pan,
  owner: "Stripe test card",
  processors: ["stripe"],
  chargeId: None,
  declineCode: None,
  does,
  cardType: "Credit",
  country: "US",
}

// A processor's own test card (processors.ts): it pays; in a story the scripted bank makes the
// charge fail
let processorCard = (pan, owner, processors) => {
  pan,
  owner,
  processors,
  chargeId: None,
  declineCode: None,
  does: "Pays. In a story, the scripted bank makes the charge fail.",
  cardType: "",
  country: "",
}

let cards = [
  stripePays("4242424242424242", "Pays every charge."),
  stripeDecline("0002", "generic_decline", "The bank says no."),
  stripeDecline("9995", "insufficient_funds", "Not enough money."),
  stripeDecline("0119", "processing_error", "The bank's system has an error."),
  stripeDecline("6975", "card_velocity_exceeded", "The spending limit is reached."),
  stripeDecline("0341", "generic_decline", "Saves, then the bank says no."),
  stripeDecline("0069", "expired_card", "The card has expired."),
  stripeDecline("9979", "stolen_card", "The card is reported stolen."),
  {...stripePays("4000056655665556", "Pays every charge."), cardType: "Debit"},
  stripePays("5555555555554444", "Pays every charge."),
  {...stripePays("5200828282828210", "Pays every charge."), cardType: "Debit"},
  stripePays("378282246310005", "Pays every charge."),
  stripePays("6011111111111117", "Pays every charge."),
  processorCard(
    "4111111111111111",
    "Test card on several processors",
    ["adyen", "authorizedotnet", "nmi", "cybersource"],
  ),
  processorCard("4444333322221111", "Worldpay test card", ["worldpay"]),
  processorCard("4263970000005262", "Global Payments test card", ["globalpay"]),
  processorCard("4007000000027", "Authorize.net test card", ["authorizedotnet"]),
]

// A Stripe test card the customer can pay with: it pays every charge (the story makes the
// failure). The proxy takes only these (GET /sim/presets visitorCards).
let isVisitorCard = card =>
  card.chargeId->Option.isNone && card.declineCode->Option.isNone && card.processors == ["stripe"]

// The quick picks under the field: the card and what it does
let quickPicks = [
  ("4242424242424242", "4242 pays"),
  ("4000000000009995", "9995 no money"),
  ("4000000000000002", "0002 declined"),
  ("4000000000000119", "0119 bank error"),
  ("4000000000000069", "0069 expired"),
  ("4000000000009979", "9979 stolen"),
  ("4111111111111111", "4111 several processors"),
]

let digits = s => s->String.replaceRegExp(%re("/\D/g"), "")

// 4242 4242 4242 4242; Amex 3782 822463 10005
let grouped = d =>
  d->String.length == 15
    ? `${d->String.slice(~start=0, ~end=4)} ${d->String.slice(
          ~start=4,
          ~end=10,
        )} ${d->String.sliceToEnd(~start=10)}`
    : d->String.replaceRegExp(%re("/(\d{4})(?=\d)/g"), "$1 ")

// The brand from the first digits (IIN ranges)
let brandOf = d => {
  let two = d->String.slice(~start=0, ~end=2)->Int.fromString->Option.getOr(0)
  let four = d->String.slice(~start=0, ~end=4)->Int.fromString->Option.getOr(0)
  let three = d->String.slice(~start=0, ~end=3)->Int.fromString->Option.getOr(0)
  if d->String.startsWith("4") {
    Visa
  } else if (two >= 51 && two <= 55) || (four >= 2221 && four <= 2720) {
    Mastercard
  } else if two == 34 || two == 37 {
    Amex
  } else if four == 6011 || two == 65 || (three >= 644 && three <= 649) {
    Discover
  } else {
    OtherBrand
  }
}

let brandName = brand =>
  switch brand {
  | Visa => "Visa"
  | Mastercard => "Mastercard"
  | Amex => "American Express"
  | Discover => "Discover"
  | OtherBrand => "Card"
  }

// The Luhn check digit
let luhn = d => {
  let total = ref(0)
  let n = d->String.length
  for i in 0 to n - 1 {
    let digit = d->String.charAt(n - 1 - i)->Int.fromString->Option.getOr(0)
    total := total.contents + (mod(i, 2) == 1 ? digit * 2 > 9 ? digit * 2 - 9 : digit * 2 : digit)
  }
  n > 0 && mod(total.contents, 10) == 0
}

type detection =
  | Empty
  | Typing(brand)
  | Test(testCard, brand)
  | NotTest(brand, bool)

let detect = raw => {
  let d = raw->digits
  if d == "" {
    Empty
  } else {
    switch cards->Array.find(c => c.pan == d) {
    | Some(card) => Test(card, d->brandOf)
    | None => d->String.length < 13 ? Typing(d->brandOf) : NotTest(d->brandOf, d->luhn)
    }
  }
}

// The test card that stands for a first-charge id on a processor (when a story fills the form)
let canonical = (~firstCharge, ~processor) =>
  processor == "stripe"
    ? cards->Array.find(c => c.chargeId == Some(firstCharge))
    : cards->Array.find(c => c.processors->Array.includes(processor))

// The decline code of a first-charge id (for a processor card, the story's own reason)
let declineOf = firstCharge =>
  cards->Array.find(c => c.chargeId == Some(firstCharge))->Option.flatMap(c => c.declineCode)

// Rev Rec's group (the engine's cluster, by decline reason only: MODEL.md) and its plain name. A
// hard decline has no group: Rev Rec stops at once.
type group = Group(string, string) | Hard | NoGroup

let groupOf = declineCode =>
  switch declineCode {
  | Some("insufficient_funds") => Group("insufficient_funds", "Insufficient funds")
  | Some("generic_decline") => Group("do_not_honor", "Do not honor")
  | Some("processing_error") => Group("downstream_technical_issue", "Technical issue")
  | Some("card_velocity_exceeded") => Group("velocity_limit_exceeded", "Velocity limit")
  | Some("stolen_card") | Some("expired_card") => Hard
  | _ => NoGroup
  }
