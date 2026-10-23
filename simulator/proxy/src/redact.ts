// Removes secrets from anything the proxy sends to the browser, writes to disk, or logs.
import { SECRET_VALUES } from "./config.ts";

const HIDDEN = "<hidden by proxy>";

// Field names whose values are always hidden, wherever they appear in a response.
// A pattern, not a fixed list: the profile read carries payment_response_hash_key (webhook signing key).
const SECRET_FIELD =
  /secret|password|passwd|hash_key|api_key|private_key|access_token|refresh_token|^key[12]$|^token$/i;

// String values that look like keys or tokens, even under an unexpected field name.
const SECRET_PATTERN = /^(sk|rk)_(test|live)_|^snd_|^dev_|^prd_|^Bearer\s/;

// Connector accounts carry processor credentials. Keep the shape, hide the values.
const SHAPE_ONLY_FIELDS = new Set([
  "connector_account_details",
  "additional_merchant_data",
  "outgoing_webhook_custom_http_headers",
]);

function hideValues(value: unknown): unknown {
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([k, v]) => [
        k,
        k === "auth_type" ? v : HIDDEN,
      ]),
    );
  }
  return value === null || value === undefined ? value : HIDDEN;
}

export function redact<T>(value: T): T {
  const walk = (v: unknown): unknown => {
    if (Array.isArray(v)) return v.map(walk);
    if (v && typeof v === "object") {
      return Object.fromEntries(
        Object.entries(v).map(([k, child]) => {
          if (SECRET_FIELD.test(k)) return [k, child == null ? child : HIDDEN];
          if (SHAPE_ONLY_FIELDS.has(k)) return [k, hideValues(child)];
          return [k, walk(child)];
        }),
      );
    }
    if (typeof v === "string")
      return SECRET_PATTERN.test(v) ? HIDDEN : scrubText(v);
    return v;
  };
  return walk(value) as T;
}

// Replaces any secret we hold if it appears inside free text (error messages, logs).
export function scrubText(text: string): string {
  let out = text;
  for (const s of SECRET_VALUES) out = out.split(s).join(HIDDEN);
  return out;
}
