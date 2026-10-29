// Learning re-file (MODEL.md, "Learning uses the attempt's actual time"): the stats the engine
// should hold are the seed plus every outcome since the last reset, each filed at its real-life
// slot. Pure functions; sim.mjs reads the outcomes and writes the documents.
import { slotOf } from "./calendar.mjs";

const SIZES = { dow: 7, dom: 31, hod: 24 };

export const clusterKey = (code) => `v1|${code ?? "UNK"}/UNK/UNK`;

export const emptyDocument = () =>
  Object.fromEntries(
    Object.entries(SIZES).map(([family, size]) => [
      family,
      Array.from({ length: size }, () => ({ n: 0, k: 0 })),
    ]),
  );

// One outcome adds a try to its slot in each family, and a success too when it worked
// (StatsDelta::for_event in hyperswitch_domain_models/src/revenue_recovery/retry_stats_document.rs)
export function addOutcome(doc, slotMs, success) {
  const slot = slotOf(slotMs);
  for (const family of Object.keys(SIZES)) {
    doc[family][slot[family]].n += 1;
    if (success) doc[family][slot[family]].k += 1;
  }
}

// cluster key -> document: the seed documents plus the outcomes, each at outcome.slotMs
export function expectedDocuments(seedDocs, outcomes) {
  const docs = new Map(
    [...seedDocs].map(([key, doc]) => [key, structuredClone(doc)]),
  );
  for (const o of outcomes) {
    if (!docs.has(o.cluster)) docs.set(o.cluster, emptyDocument());
    addOutcome(docs.get(o.cluster), o.slotMs, o.success);
  }
  return docs;
}

// Equal counts in every slot (key order and extra fields do not matter)
export function sameDocument(a, b) {
  return Object.keys(SIZES).every(
    (family) =>
      a?.[family]?.length === b?.[family]?.length &&
      a[family].every(
        (slot, i) => slot.n === b[family][i].n && slot.k === b[family][i].k,
      ),
  );
}

// What the database must change to hold the expected documents
export function documentChanges(expected, current) {
  const write = [...expected].filter(
    ([key, doc]) => !sameDocument(doc, current.get(key)),
  );
  const remove = [...current.keys()].filter((key) => !expected.has(key));
  return { write, remove };
}

const csvField = (text) => `"${text.replaceAll('"', '""')}"`;

// The admin route's CSV (POST /v2/recovery/data-backfill/retry-stats, multipart field "file")
export const documentsCsv = (docs) =>
  [
    "cluster_key,stats",
    ...docs.map(([key, doc]) => `${key},${csvField(JSON.stringify(doc))}`),
  ].join("\n") + "\n";
