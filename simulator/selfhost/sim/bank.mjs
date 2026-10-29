// The scripted bank (MODEL.md, "The bank, at charge time"): a pass-through between the engine and
// Stripe that decides Rev Rec's charges for invoices the proxy marks, by the charge's real-life
// slot. Pure functions; sim.mjs forwards the requests.
//
// The proxy marks an invoice with Stripe customer metadata "sim_bank", a JSON rule (v1):
//   { reason, worksFrom }   a story: the charge works from that real-life moment on
//   { reason, draw }        a portfolio invoice: works when draw < the slot's chance (slotChance)
//   failureAt (optional)    the story's real-life failure moment (ISO); default: the real failure
//   stolenFrom (optional)   from this real-life moment (ISO), charges hard-decline: stolen card
//   outages (optional)      [{ from, until }] (ISO): charges in between fail with a processing error
// The bank reads the rule again for every charge, so a changed rule applies to the next retry.
// worksFrom, in UTC, measured from the failure:
//   { at: "2026-10-29T13:00:00Z" } from this real-life moment on ("money is back")
//   { afterHours: 2 }              2 hours after the failure
//   { dayOffset: 1, hour: 10 }     10:00 on the day after the failure day (0 = the failure day)
//   { weekday: 0, hour: 8 }        the next Monday 08:00 after the failure (Monday = 0)
//   { payday: true, hour: 9 }      the next 1st or 15th, 09:00, after the failure
import { DAY_MS, ladderOffsets, slotOf } from "./calendar.mjs";

const HOUR_MS = 3_600_000;
const dayStart = (ms) => Math.floor(ms / DAY_MS) * DAY_MS;

// Stripe test PaymentMethods that decline a one-off charge with each reason's code and message
// (checked 27 Oct 2026). Each message has a GSM row (seed.sh 9b), so the engine files the decline
// under the reason's cluster.
export const DECLINE_CARD = {
  insufficient_funds: "pm_card_visa_chargeDeclinedInsufficientFunds",
  generic_decline: "pm_card_chargeDeclined",
  do_not_honor: "pm_card_chargeDeclined",
  processing_error: "pm_card_chargeDeclinedProcessingError",
  card_velocity_exceeded: "pm_card_chargeDeclinedVelocityLimitExceeded",
  // Events only: a hard decline (Stripe's decline code stolen_card, network code 43)
  stolen_card: "pm_card_visa_chargeDeclinedStolenCard",
};

// A rule from the customer's metadata, or null when it is missing or not one we know
export function parseRule(text) {
  let rule;
  try {
    rule = JSON.parse(text ?? "");
  } catch {
    return null;
  }
  const known =
    rule?.v === 1 &&
    DECLINE_CARD[rule.reason] !== undefined &&
    rule.reason !== "stolen_card" &&
    (typeof rule.draw === "number" || typeof rule.worksFrom === "object");
  return known ? rule : null;
}

// The real-life moment from which a story's charges work
export function worksFromMs(worksFrom, failureMs) {
  const day = dayStart(failureMs);
  const hour = (worksFrom.hour ?? 0) * HOUR_MS;
  if (worksFrom.at !== undefined) return Date.parse(worksFrom.at);
  if (worksFrom.afterHours !== undefined)
    return failureMs + worksFrom.afterHours * HOUR_MS;
  if (worksFrom.dayOffset !== undefined)
    return day + worksFrom.dayOffset * DAY_MS + hour;
  // The first matching day whose moment is after the failure
  const matches = (ms) =>
    worksFrom.payday
      ? [0, 14].includes(slotOf(ms).dom)
      : slotOf(ms).dow === worksFrom.weekday;
  for (let d = 0; d <= 62; d++) {
    const at = day + d * DAY_MS + hour;
    if (at > failureMs && matches(at)) return at;
  }
  return Infinity;
}

// The first ladder retry (1-based) that works for a story rule, or null when none of the 15 does.
// For checking a story against the fixed timetable.
export function firstWorkingRetry(worksFrom, failureMs) {
  const from = worksFromMs(worksFrom, failureMs);
  const i = ladderOffsets().findIndex((sec) => failureMs + sec * 1000 >= from);
  return i < 0 ? null : i + 1;
}

// Does a charge at this real-life slot work, and if not, with which decline? Events come first:
// a stolen card, then an outage. chance(reason, slot) is the portfolio's slot chance.
export function decide(rule, { slotMs, failureMs }, chance) {
  if (rule.stolenFrom && slotMs >= Date.parse(rule.stolenFrom))
    return { works: false, decline: "stolen_card" };
  if (
    (rule.outages ?? []).some(
      (o) => slotMs >= Date.parse(o.from) && slotMs < Date.parse(o.until),
    )
  )
    return { works: false, decline: "processing_error" };
  if (rule.worksFrom) {
    const from = worksFromMs(rule.worksFrom, failureMs);
    return { works: slotMs >= from, decline: rule.reason, worksFromMs: from };
  }
  const p = chance(rule.reason, slotOf(slotMs));
  return { works: rule.draw < p, decline: rule.reason, chance: p };
}

// The charge the bank sends to Stripe instead of the engine's. A win charges the customer's good
// card; a loss charges a one-off card that declines with the given reason, with no customer
// (Stripe test mode does not let those cards be saved).
export function rewriteCharge(params, { works, goodCard, decline }) {
  const out = new URLSearchParams(params);
  if (works) {
    out.set("payment_method", goodCard);
    return out;
  }
  out.set("payment_method", DECLINE_CARD[decline]);
  for (const key of [...out.keys()])
    if (
      key === "customer" ||
      key === "setup_future_usage" ||
      key.startsWith("mandate_data") ||
      key.startsWith("payment_method_options[card][mit_exemption]")
    )
      out.delete(key);
  return out;
}

// ---- Processors other than Stripe (decided 27 Oct, interface with the proxy): the engine's
// connector base_url is http://sim:8095/<connector>/<its path>; the sim sends it on to the real
// test API. The proxy registers each marked story (POST /bank/stories): the good token it reported,
// the invoice id, the rule, and per decline reason the replacements that make the processor itself
// decline (a test card, a declining saved token, an amount). A win is the charge as the engine sent
// it; everything else passes byte for byte.

// The test APIs (origins; the engine's base_url path stays in the request)
export const PROCESSOR_UPSTREAMS = {
  adyen: "https://checkout-test.adyen.com",
  authorizedotnet: "https://apitest.authorize.net",
  cybersource: "https://apitest.cybersource.com",
  globalpay: "https://apis.sandbox.globalpay.com",
  nmi: "https://secure.nmi.com",
  worldpay: "https://try.access.worldpay.com",
};

// A registered story, or null when it is not complete
export function parseStory(body) {
  const rule = parseRule(JSON.stringify({ v: 1, ...(body?.rule ?? {}) }));
  const ok =
    body?.v === 1 &&
    PROCESSOR_UPSTREAMS[body.processor] !== undefined &&
    typeof body.invoiceId === "string" &&
    body.invoiceId !== "" &&
    typeof body.goodToken === "string" &&
    body.goodToken !== "" &&
    typeof body.replacements === "object" &&
    body.replacements !== null &&
    rule !== null;
  return ok ? { ...body, rule } : null;
}

// Is this request the story's charge? All its match strings (default: the good token) are in it,
// and so is its invoice id, as a whole word: the engine sends the invoice id as the processor's
// reference (connector_request_reference_id). Worldpay gives a card saved again the same token,
// so a token alone can belong to several stories.
const hasWord = (text, word) =>
  new RegExp(
    `(?<![A-Za-z0-9_-])${word.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?![A-Za-z0-9_-])`,
  ).test(text);
export const storyMatches = (text, story) =>
  (story.match ?? [story.goodToken]).every(
    (part) => typeof part === "string" && part !== "" && text.includes(part),
  ) &&
  typeof story.invoiceId === "string" &&
  story.invoiceId !== "" &&
  hasWord(text, story.invoiceId);

// The replacements for a decline: its own, else the generic decline's, else the first listed
export function replacementsFor(story, decline) {
  const r = story.replacements ?? {};
  return (
    r[decline] ??
    r.generic_decline ??
    r.do_not_honor ??
    Object.values(r)[0] ??
    null
  );
}

const pathParts = (path) => path.split(".");
function setPath(obj, path, value) {
  const parts = pathParts(path);
  let at = obj;
  // Creates or overwrites each level (Adyen: paymentMethod.holderName on a stored-card charge)
  for (const part of parts.slice(0, -1))
    at =
      typeof at[part] === "object" && at[part] !== null
        ? at[part]
        : (at[part] = {});
  at[parts.at(-1)] = value;
}
function deletePath(obj, path) {
  const parts = pathParts(path);
  let at = obj;
  for (const part of parts.slice(0, -1)) {
    at = at?.[part];
    if (at === undefined) return;
  }
  delete at[parts.at(-1)];
}

// The engine's body with the replacements applied: JSON paths ({path, value} or {path, delete})
// or form fields ({field, value})
export function applyReplacements(text, contentType, replacements) {
  if (String(contentType).startsWith("application/x-www-form-urlencoded")) {
    const form = new URLSearchParams(text);
    for (const r of replacements)
      if (r.field)
        r.delete ? form.delete(r.field) : form.set(r.field, String(r.value));
    return form.toString();
  }
  const body = JSON.parse(text);
  for (const r of replacements)
    if (r.path)
      r.delete ? deletePath(body, r.path) : setPath(body, r.path, r.value);
  return JSON.stringify(body);
}

// Authorize.net turns down a charge as a duplicate (code 11) when the same card, amount and
// invoice came in the last 2 minutes, and every lost retry of a story declines on the same profile.
// duplicateWindow 0 turns the check off for that charge. Its JSON keeps the XML schema's order, so
// transactionSettings goes before userFields and the fields after it.
const AFTER_SETTINGS = [
  "userFields",
  "surcharge",
  "merchantDescriptor",
  "subMerchant",
  "tip",
  "processingOptions",
  "subsequentAuthInformation",
  "otherTax",
  "shipFrom",
  "authorizationIndicatorType",
];
export function withoutDuplicateCheck(text) {
  const body = JSON.parse(text);
  const request = body.createTransactionRequest?.transactionRequest;
  if (!request || typeof request !== "object") return text;
  const others = [request.transactionSettings?.setting ?? []]
    .flat()
    .filter((setting) => setting?.settingName !== "duplicateWindow");
  const settings = {
    setting: [...others, { settingName: "duplicateWindow", settingValue: "0" }],
  };
  const entries = Object.entries(request).filter(
    ([key]) => key !== "transactionSettings",
  );
  const at = entries.findIndex(([key]) => AFTER_SETTINGS.includes(key));
  entries.splice(at === -1 ? entries.length : at, 0, [
    "transactionSettings",
    settings,
  ]);
  body.createTransactionRequest.transactionRequest =
    Object.fromEntries(entries);
  return JSON.stringify(body);
}

// Worldpay turns down a charge (400 transactionStageHasAlreadyBeenProcessed) when the invoice's
// last decline under the same transactionReference had another code, and the engine sends the
// invoice id as the reference on every retry. A declined charge gets its own reference
// (<invoice>-r<n>); a win goes as sent, which Worldpay accepts after declines. Max 64 characters.
export function withOwnReference(text, reference) {
  const body = JSON.parse(text);
  if (typeof body.transactionReference !== "string" || reference.length > 64)
    return text;
  body.transactionReference = reference;
  return JSON.stringify(body);
}

// Cybersource's HTTP signature (the engine signs for the sim's host and path, so every request is
// signed again for Cybersource's): the same headers the engine listed, HMAC-SHA256 with the
// base64-decoded shared secret. Returns the headers to set.
export function cybersourceHeaders(
  { method, path, host, headers, body, keyId, secret },
  hash,
) {
  const listed = String(headers.signature ?? "")
    .match(/headers="([^"]+)"/)?.[1]
    ?.split(" ") ?? ["host", "date", "(request-target)", "v-c-merchant-id"];
  const digest = listed.includes("digest")
    ? `SHA-256=${hash.sha256(body)}`
    : undefined;
  const value = (name) =>
    name === "host"
      ? host
      : name === "(request-target)"
        ? `${method.toLowerCase()} ${path}`
        : name === "digest"
          ? digest
          : headers[name];
  const signing = listed.map((name) => `${name}: ${value(name)}`).join("\n");
  const signature = hash.hmac(secret, signing);
  return {
    ...(digest ? { digest } : {}),
    signature: `keyid="${keyId}", algorithm="HmacSHA256", headers="${listed.join(" ")}", signature="${signature}"`,
  };
}
