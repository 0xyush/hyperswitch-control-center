// The run names no processor (2 Nov): the visitor picks any processor on Setup Recovery, and every
// story runs in the demo's own test mode. Every JSON answer to the browser passes through here, so
// the stories' words say "the processor" and its object ids do not show. Keys and lowercase ids
// ("stripe" as a processor id) stay as they are. SIM_NEUTRAL_PROCESSOR=0 turns it off.

export const neutralOn = process.env.SIM_NEUTRAL_PROCESSOR !== "0";

// Most specific first; each is [pattern, replacement in mid-sentence form]
const WORDS: [RegExp, string][] = [
  [/\bStripe's test cards?\b/g, "the test card"],
  [/\bStripe test cards?\b/g, "test card"],
  [/\bStripe test mode\b/g, "test mode"],
  [/\bStripe (customer|charge|payment|card)\b/g, "$1"],
  [/\bat Stripe\b/g, "at the processor"],
  [/\bStripe's\b/g, "the processor's"],
  [/\bStripe\b/g, "the processor"],
];

// The processor's object ids: dropped when in parentheses, else shortened to their end
const PAREN_ID = /\s*\((?:pi|pm|ch|cus|seti|re|in|py)_[A-Za-z0-9]{6,}\)/g;
const ID = /\b(?:pi|pm|ch|cus|seti|re|in|py)_[A-Za-z0-9]{6,}\b/g;

// A replacement that starts a sentence starts with a capital
const startsSentence = (text: string, at: number) =>
  /(^|[.!?:]\s+|["(\n]\s*)$/.test(text.slice(0, at));

export function neutralText(text: string): string {
  if (!text.includes("Stripe") && !/(?:pi|pm|ch|cus|seti|re|in|py)_/.test(text))
    return text;
  let out = text.replace(PAREN_ID, "");
  for (const [pattern, word] of WORDS)
    out = out.replace(pattern, (...m) => {
      const at = m[m.length - 2] as number;
      const whole = m[m.length - 1] as string;
      const said = m.length > 3 ? word.replace("$1", m[1] as string) : word;
      return startsSentence(whole, at)
        ? said.charAt(0).toUpperCase() + said.slice(1)
        : said;
    });
  return out.replace(ID, (id) => `…${id.slice(-6)}`);
}

export function neutralize<T>(value: T): T {
  if (typeof value === "string") return neutralText(value) as T;
  if (Array.isArray(value)) return value.map(neutralize) as T;
  if (value && typeof value === "object")
    return Object.fromEntries(
      Object.entries(value).map(([k, v]) => [k, neutralize(v)]),
    ) as T;
  return value;
}
