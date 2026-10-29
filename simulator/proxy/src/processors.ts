// Processors other than Stripe (simulator/NOTES.md, 27 Oct "Processors beyond Stripe"). For each one
// that works end to end on our engine: the billing simulator's calls at the processor's own test API
// (save a card for later merchant-initiated charges, a first charge that the processor declines), a
// live check, masked fields for the setup walkthrough, and its own profile on the engine
// (HS_<ID>_PROFILE_ID, _PAYMENT_MCA_ID, _BILLING_MCA_ID). Keys come from the env file only and are
// never sent anywhere but the processor; config.ts adds them to SECRET_VALUES.
import crypto from "node:crypto";
import { type ProfileRef } from "./config.ts";

export type ProcessorId =
  | "adyen"
  | "cybersource"
  | "authorizedotnet"
  | "worldpay"
  | "nmi"
  | "globalpay";
// The card each processor's test API stores (the engine reports it back on Rev Rec's attempts).
export type ProcCard = { last4: string; isin: string; network: "Visa" };
export type Saved = { token: string; customerId: string; card: ProcCard };
export type Failed = { txnId: string; code: string; message: string };
type Upstream = { status: number; json: any; text?: string };

const env = (k: string) => (process.env[k] ?? "").trim();
const VISA_4111: ProcCard = { last4: "1111", isin: "411111", network: "Visa" };

async function call(
  url: string,
  init: RequestInit & { form?: Record<string, string> } = {},
): Promise<Upstream> {
  const { form, ...rest } = init;
  const r = await fetch(url, {
    ...rest,
    ...(form
      ? {
          body: new URLSearchParams(form).toString(),
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
        }
      : {}),
    signal: AbortSignal.timeout(60_000),
  });
  const text = (await r.text()).replace(/^﻿/, "");
  let json: any = null;
  try {
    json = JSON.parse(text);
  } catch {
    // Not JSON (NMI answers form-encoded).
  }
  return { status: r.status, json, text };
}

const fail = (who: string, what: string, r: Upstream): never => {
  throw new Error(`${who}: ${what} did not work (HTTP ${r.status})`);
};

// ---------- Adyen (Checkout API v71 test) ----------
const adyen = {
  key: () => env("ADYEN_API_KEY"),
  account: () => env("ADYEN_MERCHANT_ACCOUNT"),
  post: (path: string, body: object) =>
    call(`https://checkout-test.adyen.com/v71/${path}`, {
      method: "POST",
      headers: { "X-API-Key": adyen.key(), "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }),
  card: (holderName: string) => ({
    type: "scheme",
    encryptedCardNumber: "test_4111111111111111",
    encryptedExpiryMonth: "test_03",
    encryptedExpiryYear: "test_2030",
    encryptedSecurityCode: "test_737",
    holderName,
  }),
};

// ---------- Cybersource (REST, HTTP signature) ----------
const cyb = {
  async post(path: string, body: object) {
    const host = "apitest.cybersource.com";
    const date = new Date().toUTCString();
    const raw = JSON.stringify(body);
    const digest =
      "SHA-256=" + crypto.createHash("sha256").update(raw).digest("base64");
    const mid = env("CYBERSOURCE_MERCHANT_ID");
    const signing = `host: ${host}\ndate: ${date}\n(request-target): post ${path}\ndigest: ${digest}\nv-c-merchant-id: ${mid}`;
    const sig = crypto
      .createHmac(
        "sha256",
        Buffer.from(env("CYBERSOURCE_API_SECRET"), "base64"),
      )
      .update(signing)
      .digest("base64");
    return call(`https://${host}${path}`, {
      method: "POST",
      headers: {
        host,
        date,
        digest,
        "v-c-merchant-id": mid,
        "Content-Type": "application/json",
        signature: `keyid="${env("CYBERSOURCE_API_KEY")}", algorithm="HmacSHA256", headers="host date (request-target) digest v-c-merchant-id", signature="${sig}"`,
      },
      body: raw,
    });
  },
  billTo: {
    firstName: "Sim",
    lastName: "Customer",
    address1: "1 Main St",
    locality: "San Francisco",
    administrativeArea: "CA",
    postalCode: "94105",
    country: "US",
    email: "sim@example.com",
  },
};

// ---------- Authorize.net (JSON API sandbox) ----------
const anet = {
  auth: () => ({
    name: env("AUTHORIZEDOTNET_LOGIN_ID"),
    transactionKey: env("AUTHORIZEDOTNET_TRANSACTION_KEY"),
  }),
  post: (body: object) =>
    call("https://apitest.authorize.net/xml/v1/request.api", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }),
};

// ---------- Worldpay (Access, Payments API 2024-06-01) ----------
const wp = {
  auth: () =>
    "Basic " +
    Buffer.from(
      `${env("WORLDPAY_CREDS_KEY1")}:${env("WORLDPAY_CREDS_API_KEY")}`,
    ).toString("base64"),
  entity: () => env("WORLDPAY_CREDS_API_SECRET") || "default",
  post: (body: object) =>
    call("https://try.access.worldpay.com/api/payments", {
      method: "POST",
      headers: {
        Authorization: wp.auth(),
        "WP-Api-Version": "2024-06-01",
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(body),
    }),
  instruction: (holder: string, amount: number, extra: object = {}) => ({
    method: "card",
    paymentInstrument: {
      type: "plain",
      cardHolderName: holder,
      cardNumber: "4444333322221111",
      expiryDate: { month: 3, year: 2030 },
      cvc: "123",
    },
    narrative: { line1: "Rev Rec sim" },
    value: { currency: "USD", amount },
    ...extra,
  }),
};

// ---------- NMI (transact.php, form-encoded) ----------
const nmi = {
  post: async (fields: Record<string, string>) => {
    const r = await call("https://secure.nmi.com/api/transact.php", {
      method: "POST",
      form: { security_key: env("NMI_SECURITY_KEY"), ...fields },
    });
    return Object.fromEntries(new URLSearchParams(r.text ?? ""));
  },
};

// ---------- Global Payments (GP API sandbox, OAuth access token) ----------
const gp = {
  token: null as { value: string; at: number } | null,
  async accessToken() {
    if (gp.token && Date.now() - gp.token.at < 30 * 60_000)
      return gp.token.value;
    const nonce = new Date().toISOString();
    const r = await call("https://apis.sandbox.globalpay.com/ucp/accesstoken", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-GP-Version": "2021-03-22",
      },
      body: JSON.stringify({
        app_id: env("GLOBALPAY_APP_ID"),
        nonce,
        secret: crypto
          .createHash("sha512")
          .update(nonce + env("GLOBALPAY_APP_KEY"))
          .digest("hex"),
        grant_type: "client_credentials",
      }),
    });
    if (!r.json?.token) fail("Global Payments", "the access token", r);
    gp.token = { value: r.json.token, at: Date.now() };
    return gp.token.value;
  },
  async post(path: string, body: object) {
    return call(`https://apis.sandbox.globalpay.com/ucp/${path}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-GP-Version": "2021-03-22",
        Authorization: `Bearer ${await gp.accessToken()}`,
      },
      body: JSON.stringify(body),
    });
  },
  card: (number: string) => ({
    number,
    expiry_month: "12",
    expiry_year: "30",
    cvv: "123",
  }),
};

export type Adapter = {
  id: ProcessorId;
  name: string;
  logoKey: string; // the dashboard's connector name, for its logo
  envKeys: string[]; // what must be set for it to be configured
  saveCard: (ref: string) => Promise<Saved>;
  failCharge: (ref: string, amountMinor: number) => Promise<Failed>;
  check: () => Promise<boolean>;
  masked: () => { label: string; value: string | null }[];
};

const DOTS = "••••••••";
const last4 = (s: string) =>
  s ? `${DOTS}${s.length > 8 ? s.slice(-4) : ""}` : null;

export const ADAPTERS: Adapter[] = [
  {
    id: "adyen",
    name: "Adyen",
    logoKey: "adyen",
    envKeys: ["ADYEN_API_KEY", "ADYEN_MERCHANT_ACCOUNT"],
    async saveCard(ref) {
      const r = await adyen.post("payments", {
        amount: { currency: "USD", value: 0 },
        reference: `sim-store-${ref}`,
        merchantAccount: adyen.account(),
        paymentMethod: adyen.card("Sim Customer"),
        shopperReference: ref,
        storePaymentMethod: true,
        recurringProcessingModel: "UnscheduledCardOnFile",
        shopperInteraction: "Ecommerce",
      });
      const ad = r.json?.additionalData ?? {};
      const token =
        ad["tokenization.storedPaymentMethodId"] ??
        ad["recurring.recurringDetailReference"];
      if (!token) fail("Adyen", "saving the card", r);
      return { token, customerId: ref, card: VISA_4111 };
    },
    async failCharge(ref, amount) {
      // Adyen's test refusal by holder name.
      const r = await adyen.post("payments", {
        amount: { currency: "USD", value: amount },
        reference: `sim-first-${ref}`,
        merchantAccount: adyen.account(),
        paymentMethod: adyen.card("NOT_ENOUGH_BALANCE"),
        shopperReference: ref,
        shopperInteraction: "Ecommerce",
      });
      if (r.json?.resultCode !== "Refused")
        fail("Adyen", "the declined charge", r);
      return {
        txnId: r.json.pspReference,
        code: String(r.json.refusalReasonCode ?? "refused"),
        message: String(r.json.refusalReason ?? "Refused"),
      };
    },
    async check() {
      const r = await adyen.post("paymentMethods", {
        merchantAccount: adyen.account(),
      });
      return r.status === 200;
    },
    masked: () => [
      { label: "API key", value: last4(adyen.key()) },
      { label: "Merchant account", value: last4(adyen.account()) },
    ],
  },
  {
    id: "cybersource",
    name: "Cybersource",
    logoKey: "cybersource",
    envKeys: [
      "CYBERSOURCE_API_KEY",
      "CYBERSOURCE_API_SECRET",
      "CYBERSOURCE_MERCHANT_ID",
    ],
    async saveCard(ref) {
      // A $0 authorization that creates a payment instrument token (customer tokens are not
      // allowed on this test account).
      const r = await cyb.post("/pts/v2/payments", {
        clientReferenceInformation: { code: `sim-store-${ref}` },
        processingInformation: {
          capture: false,
          actionList: ["TOKEN_CREATE"],
          actionTokenTypes: ["paymentInstrument"],
          authorizationOptions: {
            initiator: { type: "customer", credentialStoredOnFile: true },
          },
        },
        paymentInformation: {
          card: {
            number: "4111111111111111",
            expirationMonth: "03",
            expirationYear: "2030",
            securityCode: "123",
          },
        },
        orderInformation: {
          amountDetails: { totalAmount: "0.00", currency: "USD" },
          billTo: cyb.billTo,
        },
      });
      const token = r.json?.tokenInformation?.paymentInstrument?.id;
      if (!token) fail("Cybersource", "saving the card", r);
      return { token, customerId: ref, card: VISA_4111 };
    },
    async failCharge(ref, amount) {
      // An out-of-date expiry: the test processor declines it.
      const r = await cyb.post("/pts/v2/payments", {
        clientReferenceInformation: { code: `sim-first-${ref}` },
        processingInformation: { capture: false },
        paymentInformation: {
          card: {
            number: "4111111111111111",
            expirationMonth: "03",
            expirationYear: "2020",
          },
        },
        orderInformation: {
          amountDetails: {
            totalAmount: (amount / 100).toFixed(2),
            currency: "USD",
          },
          billTo: cyb.billTo,
        },
      });
      if (r.json?.status !== "DECLINED" || !r.json?.id)
        fail("Cybersource", "the declined charge", r);
      return {
        txnId: r.json.id,
        code: String(r.json.errorInformation?.reason ?? "DECLINED"),
        message: String(r.json.errorInformation?.message ?? "Declined"),
      };
    },
    async check() {
      try {
        await this.saveCard(`check-${Date.now().toString(36)}`);
        return true;
      } catch {
        return false;
      }
    },
    masked: () => [
      { label: "Key id", value: last4(env("CYBERSOURCE_API_KEY")) },
      { label: "Shared secret", value: last4(env("CYBERSOURCE_API_SECRET")) },
      { label: "Merchant id", value: last4(env("CYBERSOURCE_MERCHANT_ID")) },
    ],
  },
  {
    id: "authorizedotnet",
    name: "Authorize.net",
    logoKey: "authorizedotnet",
    envKeys: ["AUTHORIZEDOTNET_LOGIN_ID", "AUTHORIZEDOTNET_TRANSACTION_KEY"],
    async saveCard(ref) {
      const r = await anet.post({
        createCustomerProfileRequest: {
          merchantAuthentication: anet.auth(),
          profile: {
            merchantCustomerId: ref.slice(0, 20),
            description: "Rev Rec simulator",
            email: `${ref}@example.com`,
            paymentProfiles: {
              customerType: "individual",
              payment: {
                creditCard: {
                  cardNumber: "4111111111111111",
                  expirationDate: "2030-03",
                },
              },
            },
          },
          validationMode: "testMode",
        },
      });
      const cp = r.json?.customerProfileId;
      const pp = r.json?.customerPaymentProfileIdList?.[0];
      if (!cp || !pp) fail("Authorize.net", "saving the card", r);
      // The engine's token format: customer profile id - payment profile id.
      return { token: `${cp}-${pp}`, customerId: String(cp), card: VISA_4111 };
    },
    async failCharge(ref, amount) {
      // The sandbox declines billing zip 46282.
      const r = await anet.post({
        createTransactionRequest: {
          merchantAuthentication: anet.auth(),
          refId: ref.slice(0, 20),
          transactionRequest: {
            transactionType: "authCaptureTransaction",
            amount: (amount / 100).toFixed(2),
            payment: {
              creditCard: {
                cardNumber: "4111111111111111",
                expirationDate: "2030-03",
                cardCode: "123",
              },
            },
            billTo: {
              firstName: "Sim",
              lastName: "Customer",
              address: "1 Main St",
              city: "Seattle",
              state: "WA",
              zip: "46282",
              country: "US",
            },
            // Same card and amount in parallel stories: no duplicate check (default 2 min).
            // Authorize.net needs this field after billTo.
            transactionSettings: {
              setting: [{ settingName: "duplicateWindow", settingValue: "0" }],
            },
          },
        },
      });
      const tr = r.json?.transactionResponse ?? {};
      if (tr.responseCode !== "2")
        fail("Authorize.net", "the declined charge", r);
      return {
        txnId: String(tr.transId),
        code: String(tr.errors?.[0]?.errorCode ?? "2"),
        message: String(
          tr.errors?.[0]?.errorText ?? "This transaction has been declined.",
        ),
      };
    },
    async check() {
      const r = await anet.post({
        authenticateTestRequest: { merchantAuthentication: anet.auth() },
      });
      return r.json?.messages?.resultCode === "Ok";
    },
    masked: () => [
      { label: "API login id", value: last4(env("AUTHORIZEDOTNET_LOGIN_ID")) },
      {
        label: "Transaction key",
        value: last4(env("AUTHORIZEDOTNET_TRANSACTION_KEY")),
      },
    ],
  },
  {
    id: "worldpay",
    name: "Worldpay",
    logoKey: "worldpay",
    envKeys: ["WORLDPAY_CREDS_API_KEY", "WORLDPAY_CREDS_KEY1"],
    async saveCard(ref) {
      const r = await wp.post({
        transactionReference: `sim-store-${ref}`,
        merchant: { entity: wp.entity() },
        instruction: wp.instruction("Sim Customer", 100, {
          // Worldpay gives the same card the same token; a namespace per customer keeps each
          // story's token its own (the sim's bank finds the story by it).
          tokenCreation: { type: "worldpay", namespace: ref },
          customerAgreement: { type: "cardOnFile", storedCardUsage: "first" },
        }),
      });
      const token = r.json?.token?.href;
      if (!token) fail("Worldpay", "saving the card", r);
      return {
        token,
        customerId: ref,
        card: { last4: "1111", isin: "444433", network: "Visa" },
      };
    },
    async failCharge(ref, amount) {
      // Worldpay's test outcome by holder name.
      const r = await wp.post({
        transactionReference: `sim-first-${ref}`,
        merchant: { entity: wp.entity() },
        instruction: wp.instruction("REFUSED", amount),
      });
      if (r.json?.outcome !== "refused" || !r.json?.paymentId)
        fail("Worldpay", "the declined charge", r);
      return {
        txnId: r.json.paymentId,
        code: String(r.json.refusalCode ?? "refused"),
        message: String(r.json.refusalDescription ?? "Refused"),
      };
    },
    async check() {
      // A read of an unknown payment: 404 with good keys, 401 with bad ones.
      const r = await call(
        "https://try.access.worldpay.com/api/payments/sim-check",
        {
          headers: { Authorization: wp.auth(), "WP-Api-Version": "2024-06-01" },
        },
      );
      return r.status !== 401 && r.status !== 403;
    },
    masked: () => [
      { label: "Username", value: last4(env("WORLDPAY_CREDS_KEY1")) },
      { label: "Password", value: last4(env("WORLDPAY_CREDS_API_KEY")) },
      { label: "Entity", value: last4(env("WORLDPAY_CREDS_API_SECRET")) },
    ],
  },
  {
    id: "nmi",
    name: "NMI",
    logoKey: "nmi",
    envKeys: ["NMI_SECURITY_KEY", "NMI_PUBLIC_KEY"],
    async saveCard(ref) {
      const r = await nmi.post({
        customer_vault: "add_customer",
        ccnumber: "4111111111111111",
        ccexp: "1030",
        first_name: "Sim",
        last_name: "Customer",
      });
      if (!r.customer_vault_id)
        throw new Error(
          `NMI: saving the card did not work (${r.responsetext ?? "no answer"})`,
        );
      return { token: r.customer_vault_id, customerId: ref, card: VISA_4111 };
    },
    async failCharge(ref) {
      // NMI's test mode declines amounts under $1.00.
      const r = await nmi.post({
        type: "sale",
        amount: "0.50",
        ccnumber: "4111111111111111",
        ccexp: "1030",
        orderid: `sim-first-${ref}`,
      });
      if (r.response !== "2" || !r.transactionid)
        throw new Error(
          `NMI: the declined charge did not work (${r.responsetext ?? "no answer"})`,
        );
      return {
        txnId: r.transactionid,
        code: String(r.response_code ?? "200"),
        message: String(r.responsetext ?? "DECLINE"),
      };
    },
    async check() {
      const r = await nmi.post({
        type: "validate",
        ccnumber: "4111111111111111",
        ccexp: "1030",
      });
      return r.response === "1";
    },
    masked: () => [
      { label: "Security key", value: last4(env("NMI_SECURITY_KEY")) },
      { label: "Public key", value: last4(env("NMI_PUBLIC_KEY")) },
    ],
  },
  {
    id: "globalpay",
    name: "Global Payments",
    logoKey: "globalpay",
    envKeys: ["GLOBALPAY_APP_KEY", "GLOBALPAY_APP_ID"],
    async saveCard(ref) {
      const r = await gp.post("payment-methods", {
        reference: `sim-store-${ref}`,
        usage_mode: "MULTIPLE",
        card: gp.card("4263970000005262"),
      });
      if (!String(r.json?.id ?? "").startsWith("PMT_"))
        fail("Global Payments", "saving the card", r);
      return {
        token: r.json.id,
        customerId: ref,
        card: { last4: "5262", isin: "426397", network: "Visa" },
      };
    },
    async failCharge(ref, amount) {
      const r = await gp.post("transactions", {
        account_name: "transaction_processing",
        type: "SALE",
        channel: "CNP",
        amount: String(amount),
        currency: "USD",
        reference: `sim-first-${ref}`,
        country: "US",
        payment_method: {
          name: "Sim Customer",
          entry_mode: "ECOM",
          card: gp.card("4000120000001154"),
        },
      });
      if (r.json?.status !== "DECLINED" || !r.json?.id)
        fail("Global Payments", "the declined charge", r);
      return {
        txnId: r.json.id,
        code: String(r.json.payment_method?.result ?? "declined"),
        message: String(r.json.payment_method?.message ?? "Declined"),
      };
    },
    async check() {
      try {
        gp.token = null;
        await gp.accessToken();
        return true;
      } catch {
        return false;
      }
    },
    masked: () => [
      { label: "App id", value: last4(env("GLOBALPAY_APP_ID")) },
      { label: "App key", value: last4(env("GLOBALPAY_APP_KEY")) },
    ],
  },
];

export const adapterOf = (id: string) => ADAPTERS.find((a) => a.id === id);

// The processor's own profile on the engine, or null when it is not set up.
export function processorProfile(id: ProcessorId): ProfileRef | null {
  const N = id.toUpperCase();
  const profileId = env(`HS_${N}_PROFILE_ID`);
  const paymentMcaId = env(`HS_${N}_PAYMENT_MCA_ID`);
  const billingMcaId = env(`HS_${N}_BILLING_MCA_ID`);
  return profileId && paymentMcaId && billingMcaId
    ? { key: "story", profileId, paymentMcaId, billingMcaId }
    : null;
}

// On = listed in PROCESSORS_ENABLED (ids, comma separated, or "all"). Unset = Stripe only: the user's
// decision on 28 Oct. The others stay set up (keys, engine profiles, scripts), hidden for later.
export const processorOn = (a: Adapter) => {
  const on = env("PROCESSORS_ENABLED")
    .split(",")
    .map((x) => x.trim().toLowerCase())
    .filter(Boolean);
  return on.includes("all") || on.includes(a.id);
};

// Configured = on, and its keys and its engine profile are set.
export const configured = (a: Adapter) =>
  processorOn(a) &&
  a.envKeys.every((k) => env(k)) &&
  processorProfile(a.id) !== null;

// ---------- the scripted bank on other processors (NOTES 27 Oct 23:20Z) ----------
// The sim service's pass-through (C) decides Rev Rec's charges by the real-life slot. To decline it
// applies REPLACEMENTS to the engine's request, so the processor itself answers with a real decline.
// Each route below was proven against the sandbox on a merchant-initiated charge.
export type BankReasonX =
  | "insufficient_funds"
  | "generic_decline"
  | "do_not_honor"
  | "processing_error"
  | "card_velocity_exceeded"
  | "stolen_card";
export type Replacement =
  | { path: string; value: unknown }
  | { path: string; delete: true }
  | { field: string; value: string };
export type BankRoute = {
  // What the sandbox says per reason; a missing reason is not possible there.
  says: Partial<Record<BankReasonX, string>>;
  genericOnly: boolean;
  // Saves any declining card needed at the processor; the replacements per reason.
  replacements: (
    ref: string,
    saved: Saved,
  ) => Promise<Partial<Record<BankReasonX, Replacement[]>>>;
  // The billing system's own first charge, declining with the reason (when the sandbox can).
  failFirst?: (
    ref: string,
    amount: number,
    reason: BankReasonX,
    saved: Saved,
  ) => Promise<Failed>;
  // Strings the sim finds in the engine's request body to know the story (default: the token).
  match?: (token: string) => string[];
};

const SOFT: BankReasonX[] = [
  "insufficient_funds",
  "generic_decline",
  "do_not_honor",
  "card_velocity_exceeded",
];
// A sandbox with one generic decline: every soft reason gets it; no stolen, no outage.
const generic = (says: string, r: Replacement[]) => ({
  says: Object.fromEntries(SOFT.map((k) => [k, says])),
  all: Object.fromEntries(SOFT.map((k) => [k, r])),
});

const ADYEN_HOLDER: Record<BankReasonX, string> = {
  insufficient_funds: "NOT_ENOUGH_BALANCE",
  generic_decline: "DECLINED",
  do_not_honor: "DECLINED",
  processing_error: "ISSUER_UNAVAILABLE",
  card_velocity_exceeded: "WITHDRAWAL_COUNT_EXCEEDED",
  stolen_card: "BLOCK_CARD",
};
const WORLDPAY_HOLDER: Record<BankReasonX, string> = {
  insufficient_funds: "REFUSED51",
  generic_decline: "REFUSED",
  do_not_honor: "REFUSED",
  processing_error: "REFUSED91",
  card_velocity_exceeded: "REFUSED51",
  stolen_card: "REFUSED43",
};
const each = <T>(f: (k: BankReasonX) => T) =>
  Object.fromEntries(
    (Object.keys(ADYEN_HOLDER) as BankReasonX[]).map((k) => [k, f(k)]),
  ) as Record<BankReasonX, T>;

export const BANK_ROUTES: Partial<Record<ProcessorId, BankRoute>> = {
  adyen: {
    says: {
      insufficient_funds: "Not enough balance",
      generic_decline: "Refused",
      do_not_honor: "Refused",
      processing_error: "Issuer Unavailable",
      card_velocity_exceeded: "Withdrawal count exceeded",
      stolen_card: "Blocked Card",
    },
    genericOnly: false,
    // Adyen test honours the holder name on a stored card too, so the token stays the same.
    replacements: async () =>
      each((k) => [
        { path: "paymentMethod.holderName", value: ADYEN_HOLDER[k] },
      ]),
    async failFirst(ref, amount, reason, saved) {
      const r = await adyen.post("payments", {
        amount: { currency: "USD", value: amount },
        reference: `sim-first-${ref}`,
        merchantAccount: adyen.account(),
        paymentMethod: {
          type: "scheme",
          storedPaymentMethodId: saved.token,
          holderName: ADYEN_HOLDER[reason],
        },
        shopperReference: ref,
        shopperInteraction: "ContAuth",
        recurringProcessingModel: "UnscheduledCardOnFile",
      });
      if (r.json?.resultCode !== "Refused")
        fail("Adyen", "the declined charge", r);
      return {
        txnId: r.json.pspReference,
        code: String(r.json.refusalReasonCode ?? "refused"),
        message: String(r.json.refusalReason ?? "Refused"),
      };
    },
  },
  worldpay: {
    says: {
      insufficient_funds: "LIMIT EXCEEDED",
      generic_decline: "REFUSED",
      do_not_honor: "REFUSED",
      processing_error: "CREDITCARD ISSUER TEMPORARILY NOT REACHABLE",
      card_velocity_exceeded: "LIMIT EXCEEDED",
      stolen_card: "STOLEN CARD, PICK UP",
    },
    genericOnly: false,
    // A plain card is not valid in a subsequent charge, so the agreement goes too.
    replacements: async () =>
      each((k) => [
        {
          path: "instruction.paymentInstrument",
          value: wp.instruction(WORLDPAY_HOLDER[k], 0).paymentInstrument,
        },
        { path: "instruction.customerAgreement", delete: true as const },
      ]),
    async failFirst(ref, amount, reason) {
      const r = await wp.post({
        transactionReference: `sim-first-${ref}`,
        merchant: { entity: wp.entity() },
        instruction: wp.instruction(WORLDPAY_HOLDER[reason], amount),
      });
      if (r.json?.outcome !== "refused" || !r.json?.paymentId)
        fail("Worldpay", "the declined charge", r);
      return {
        txnId: r.json.paymentId,
        code: String(r.json.refusalCode ?? "refused"),
        message: String(r.json.refusalDescription ?? "Refused"),
      };
    },
  },
  authorizedotnet: {
    ...(() => {
      const g = generic("This transaction has been declined.", []);
      return { says: g.says };
    })(),
    genericOnly: true,
    // The engine sends the 'cp-pp' token as two fields.
    match: (token) => token.split("-"),
    // A second payment profile on the customer, billed to zip 46282 (saved without validation).
    async replacements(_ref, saved) {
      const r = await anet.post({
        createCustomerPaymentProfileRequest: {
          merchantAuthentication: anet.auth(),
          customerProfileId: saved.customerId,
          paymentProfile: {
            billTo: {
              firstName: "Sim",
              lastName: "Customer",
              zip: "46282",
              country: "US",
            },
            payment: {
              creditCard: {
                cardNumber: "4007000000027",
                expirationDate: "2030-03",
              },
            },
          },
          validationMode: "none",
        },
      });
      const bad = r.json?.customerPaymentProfileId;
      if (!bad) fail("Authorize.net", "saving the declining card", r);
      return generic("", [
        {
          path: "createTransactionRequest.transactionRequest.profile.paymentProfile.paymentProfileId",
          value: String(bad),
        },
      ]).all;
    },
  },
  nmi: {
    says: generic("DECLINE", []).says,
    genericOnly: true,
    // NMI's test mode declines amounts under $1.00; no stored card declines.
    replacements: async () =>
      generic("", [{ field: "amount", value: "0.50" }]).all,
  },
  globalpay: {
    // The engine stores the sandbox text with its prefix.
    says: generic("(101)[ test system ] Declined", []).says,
    genericOnly: true,
    async replacements() {
      const r = await gp.post("payment-methods", {
        reference: `sim-bad-${Date.now().toString(36)}`,
        usage_mode: "MULTIPLE",
        card: gp.card("4000120000001154"),
      });
      if (!String(r.json?.id ?? "").startsWith("PMT_"))
        fail("Global Payments", "saving the declining card", r);
      return generic("", [{ path: "payment_method.id", value: r.json.id }]).all;
    },
  },
  cybersource: {
    says: generic("EXPIRED_CARD", []).says,
    genericOnly: true,
    // Only an expired date declines in this sandbox; the pass-through re-signs the body.
    replacements: async () =>
      generic("", [
        {
          path: "paymentInformation",
          value: {
            card: {
              number: "4111111111111111",
              expirationMonth: "03",
              expirationYear: "2020",
            },
          },
        },
      ]).all,
  },
};
