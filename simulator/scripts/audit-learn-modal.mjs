// Measured audit of the Learn Rev Rec level modal (level 1). Headless Chrome opens the modal,
// reads getBoundingClientRect and computed styles of every element on the three panes, samples the
// pane transition frame by frame, and writes the numbers and checks to
// simulator/screenshots/learn-modal-audit.json under the given phase.
// The lesson has five panes (Learn v2): idea, flow, number, check 1, check 2.
// Usage: node simulator/scripts/audit-learn-modal.mjs --phase v2 [--base http://localhost:9000]
import { createRequire } from "node:module";
import { existsSync, readFileSync, writeFileSync } from "node:fs";

const args = process.argv.slice(2);
const arg = (name, fallback) =>
  args.includes(name) ? args[args.indexOf(name) + 1] : fallback;
const phase = arg("--phase", "after");
const base = arg("--base", "http://localhost:9000");
const repo = new URL("../..", import.meta.url).pathname;
const out = `${repo}simulator/screenshots/`;
const auditFile = `${out}learn-modal-audit.json`;

const require = createRequire(import.meta.url);
const { chromium } = require("playwright-core");

// Runs in the page: every measured element of the open modal
const measureInPage = () => {
  const round = (n) => Math.round(n * 10) / 10;
  const rect = (el) => {
    const b = el.getBoundingClientRect();
    return {
      x: round(b.x),
      y: round(b.y),
      width: round(b.width),
      height: round(b.height),
      right: round(b.right),
      bottom: round(b.bottom),
      cx: round(b.x + b.width / 2),
      cy: round(b.y + b.height / 2),
    };
  };
  const one = (name) => document.querySelector(`[data-learn="${name}"]`);
  const all = (name) => [
    ...document.querySelectorAll(`[data-learn="${name}"]`),
  ];
  const style = (el) => getComputedStyle(el);
  const font = (el) => {
    const s = style(el);
    return {
      fontSize: s.fontSize,
      fontWeight: s.fontWeight,
      lineHeight: s.lineHeight,
      color: s.color,
    };
  };
  const stepper = one("stepper");
  // The modal panel: the element right under the Modal overlay
  let panel = stepper;
  while (
    panel.parentElement &&
    !(panel.parentElement.getAttribute("data-component") ?? "").startsWith(
      "modal",
    )
  )
    panel = panel.parentElement;
  const header = panel.firstElementChild;
  const headerStyle = style(header);
  const pane = one("pane");
  const block = one("block") ?? pane.firstElementChild;
  const blockSource = one("block") ? "data-learn" : "pane child (no hook)";
  const badge = one("badge");
  const headline = one("headline");
  const footer = one("footer");
  return {
    panel: {
      ...rect(panel),
      clientLeft: panel.clientLeft,
      clientWidth: panel.clientWidth,
    },
    header: {
      ...rect(header),
      padding: [
        headerStyle.paddingTop,
        headerStyle.paddingRight,
        headerStyle.paddingBottom,
        headerStyle.paddingLeft,
      ],
      borderBottomWidth: headerStyle.borderBottomWidth,
    },
    title: rect(panel.querySelector("[data-modal-header-text]")),
    description: rect(panel.querySelector("[data-modal-description-text]")),
    stepper: rect(stepper),
    circles: all("step-circle").map((el) => ({
      ...rect(el),
      borderColor: style(el).borderTopColor,
      background: style(el).backgroundColor,
    })),
    connectors: all("step-connector").map((el) => {
      const s = style(el);
      return {
        ...rect(el),
        borderTopWidth: s.borderTopWidth,
        borderTopColor: s.borderTopColor,
        background: s.backgroundColor,
      };
    }),
    labels: all("step-label").map((el) => ({
      text: el.textContent,
      ...rect(el),
      ...font(el),
    })),
    pane: rect(pane),
    block: { ...rect(block), source: blockSource },
    badge: badge ? rect(badge) : null,
    headline: headline ? { ...rect(headline), ...font(headline) } : null,
    footer: { ...rect(footer), borderTopWidth: style(footer).borderTopWidth },
    footerButtons: [...footer.querySelectorAll("button")].map((b) => ({
      text: b.innerText.trim(),
      ...rect(b),
    })),
    footerLink: {
      ...rect(footer.firstElementChild),
      text: footer.firstElementChild.textContent.trim(),
    },
    flow: (() => {
      const viewport = document.querySelector(".react-flow__viewport");
      if (!viewport) return null;
      const m = style(viewport).transform.match(/matrix\(([^)]+)\)/);
      const edges = [...document.querySelectorAll(".react-flow__edge")];
      return {
        scale: m ? Math.round(parseFloat(m[1].split(",")[0]) * 1000) / 1000 : 1,
        nodes: [...document.querySelectorAll(".react-flow__node")].map(rect),
        // A caption that needs more than the node's two lines overflows the fixed node
        overflowing: [...document.querySelectorAll(".react-flow__node > div")]
          .filter((el) => el.scrollHeight > el.clientHeight + 1)
          .map((el) => el.innerText.replace(/\n/g, " / ")),
        labels: [
          ...document.querySelectorAll(".react-flow__edgelabel-renderer > div"),
        ].map(rect),
        edges: edges.length,
        animatedEdges: edges.filter((e) => e.classList.contains("animated"))
          .length,
      };
    })(),
    // Text the lessons must not show any more (LEARN-V2.md "Remove")
    bannedText: [
      /From the sandbox/,
      /\bLive\b/,
      /Read-only/,
      /Rule-based/,
      /decider/,
    ]
      .filter((re) => re.test(panel.innerText))
      .map(String),
  };
};

// Runs in the page: from the next click on, sample the pane content's opacity and translateX
const startSampler = () => {
  window.__samples = [];
  document.addEventListener(
    "click",
    () => {
      const t0 = performance.now();
      const tick = () => {
        // The pane on show (Learn v2 keeps all panes mounted); older modals had one pane child
        const el =
          document.querySelector('[data-learn="pane-current"]') ??
          document.querySelector('[data-learn="pane"]')?.firstElementChild;
        if (el) {
          const s = getComputedStyle(el);
          const m = s.transform.match(/matrix\(([^)]+)\)/);
          window.__samples.push({
            t: Math.round(performance.now() - t0),
            opacity: Math.round(parseFloat(s.opacity) * 1000) / 1000,
            translateX: m
              ? Math.round(parseFloat(m[1].split(",")[4]) * 10) / 10
              : 0,
          });
        }
        if (performance.now() - t0 < 400) requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    },
    { once: true, capture: true },
  );
};

const summarizeTransition = (samples) => {
  const moving = samples.filter(
    (s) => s.opacity < 0.999 || Math.abs(s.translateX) > 0.05,
  );
  const settled = samples.find(
    (s, i) =>
      i > 0 &&
      s.opacity >= 0.999 &&
      Math.abs(s.translateX) <= 0.05 &&
      moving.length > 0 &&
      s.t > moving[0].t,
  );
  return {
    animated: moving.length > 0,
    minOpacity: Math.min(...samples.map((s) => s.opacity)),
    startTranslateX: moving[0]?.translateX ?? 0,
    maxAbsTranslateX: Math.max(...samples.map((s) => Math.abs(s.translateX))),
    settledAtMs: settled?.t ?? null,
    samples,
  };
};

const browser = await chromium.launch({ channel: "chrome", headless: true });
const page = await (
  await browser.newContext({
    viewport: { width: 1440, height: 1000 },
    deviceScaleFactor: 2,
  })
).newPage();
const pageErrors = [];
page.on("pageerror", (e) => pageErrors.push(e.message));

await page.goto(`${base}/dashboard/v2/recovery/simulator/tour`, {
  waitUntil: "domcontentloaded",
});
await page.evaluate(() => localStorage.removeItem("simulator_learned_levels"));
await page.reload({ waitUntil: "domcontentloaded" });
await page.getByText("Eight short levels").waitFor({ timeout: 30000 });
await page.waitForTimeout(2500);
const paneNames = ["idea", "flow", "number", "check1", "check2"];
const button = (name) => page.getByRole("button", { name, exact: true });
const learnedIds = () =>
  page.evaluate(() =>
    JSON.parse(localStorage.getItem("simulator_learned_levels") ?? "[]"),
  );
// Clicks the open choices of a check, first to last, until Next (or Done) is enabled
const resolveCheck = async (goOn) => {
  for (let i = 0; i < 3 && (await button(goOn).isDisabled()); i++) {
    await page
      .locator('[data-learn="block"] div.cursor-pointer')
      .first()
      .click();
    await page.waitForTimeout(150);
  }
};
const openLevel = async (title) => {
  await page.keyboard.press("Escape");
  await page.waitForTimeout(300);
  await page.getByText(title, { exact: true }).first().click();
  await page.locator('[data-learn="stepper"]').waitFor();
  await page.waitForTimeout(500);
};

await page.evaluate(startSampler);
await page.getByText("The start rule", { exact: true }).click();
await page.locator('[data-learn="stepper"]').waitFor();
await page.waitForTimeout(500);
const openSamples = await page.evaluate(() => window.__samples);

const shoot = async (name, panel) =>
  page.screenshot({
    path: `${out}learn-modal-${phase}-${name}.png`,
    clip: {
      x: panel.x - 16,
      y: panel.y - 16,
      width: panel.width + 32,
      height: panel.height + 32,
    },
  });

// Level 1, pane by pane
const panes = {};
panes.idea = await page.evaluate(measureInPage);
await shoot("1-idea", panes.idea.panel);
// The flow is built when the card opens; Next must show that same element, not build a new one
await page.evaluate(() => {
  window.__flowElement = document.querySelector(".react-flow");
});
await page.evaluate(startSampler);
await button("Next").click();
await page.waitForTimeout(700);
const nextSamples = await page.evaluate(() => window.__samples);
panes.flow = await page.evaluate(measureInPage);
const flowMountedOnce = await page.evaluate(
  () =>
    !!window.__flowElement &&
    document.querySelector(".react-flow") === window.__flowElement,
);
await shoot("2-flow", panes.flow.panel);
await page.evaluate(startSampler);
await button("Back").click();
await page.waitForTimeout(500);
const backSamples = await page.evaluate(() => window.__samples);
await button("Next").click();
await page.waitForTimeout(500);
await button("Next").click();
await page.waitForTimeout(500);
panes.number = await page.evaluate(measureInPage);
await shoot("3-number", panes.number.panel);
await button("Next").click();
await page.waitForTimeout(500);
panes.check1 = await page.evaluate(measureInPage);
const nextLockedBeforeAnswer = await button("Next").isDisabled();
await shoot("4-check1", panes.check1.panel);
await page.getByText("After the first failure", { exact: true }).click();
await page.waitForTimeout(400);
panes.check1Answered = await page.evaluate(measureInPage);
const learnedAfterOneCheck = (await learnedIds()).includes(1);
await button("Next").click();
await page.waitForTimeout(500);
panes.check2 = await page.evaluate(measureInPage);
await page
  .getByText("Rev Rec waits for more failures", { exact: true })
  .click();
await page.waitForTimeout(400);
panes.check2Answered = await page.evaluate(measureInPage);
await shoot("5-check2", panes.check2Answered.panel);
const learnedAfterBothChecks = (await learnedIds()).includes(1);

// Level 2: two wrong picks on check 1 mark the answer; a right check 2 then must not mark the level
await openLevel("Static vs smart retries");
for (let i = 0; i < 3; i++) {
  await button("Next").click();
  await page.waitForTimeout(400);
}
await page.getByText("It retries more often", { exact: true }).click();
await page.waitForTimeout(200);
const afterOneWrong = {
  nextDisabled: await button("Next").isDisabled(),
  feedback: await page.getByText("Not quite. One more try.").count(),
};
await page.getByText("It skips hard declines", { exact: true }).click();
await page.waitForTimeout(200);
const afterTwoWrong = {
  nextDisabled: await button("Next").isDisabled(),
  answerMarked: await page
    .getByText("The right answer is marked.", { exact: false })
    .count(),
};
await shoot("6-answer-shown", (await page.evaluate(measureInPage)).panel);
await button("Next").click();
await page.waitForTimeout(400);
await page.getByText("6 hours", { exact: true }).click();
await page.waitForTimeout(200);
const level2Learned = (await learnedIds()).includes(2);

// Every level: each pane fits the slot, the footer does not move, the flow fits and is readable
const levelTitles = [
  "The start rule",
  "Static vs smart retries",
  "Max retries & grace period",
  "Hard declines",
  "Card network limits",
  "Invoice queuing",
  "Paid outside Rev Rec",
  "Record back & webhooks",
];
const sweep = [];
for (const title of levelTitles) {
  await openLevel(title);
  const row = { title, panes: [] };
  for (const [index, paneName] of paneNames.entries()) {
    const m = await page.evaluate(measureInPage);
    row.panes.push({
      pane: paneName,
      blockHeight: m.block.height,
      paneHeight: m.pane.height,
      footerY: m.footer.y,
      footerLinkText: m.footerLink.text,
      bannedText: m.bannedText,
      headlineLines: m.headline
        ? Math.round(m.headline.height / parseFloat(m.headline.lineHeight))
        : null,
      flow: m.flow && {
        scale: m.flow.scale,
        animatedEdges: m.flow.animatedEdges,
        edges: m.flow.edges,
        overflowing: m.flow.overflowing,
        labelsClear: m.flow.labels.every((l) =>
          m.flow.nodes.every(
            (n) =>
              l.right <= n.x + 0.5 ||
              l.x >= n.right - 0.5 ||
              l.bottom <= n.y + 0.5 ||
              l.y >= n.bottom - 0.5,
          ),
        ),
        nodesInside: m.flow.nodes.every(
          (n) =>
            n.x >= m.pane.x - 1 &&
            n.right <= m.pane.right + 1 &&
            n.y >= m.pane.y - 1 &&
            n.bottom <= m.pane.bottom + 1,
        ),
      },
    });
    if (index < paneNames.length - 1) {
      if (paneName.startsWith("check")) await resolveCheck("Next");
      await button("Next").click();
      await page.waitForTimeout(paneName === "idea" ? 700 : 400);
    }
  }
  sweep.push(row);
}
await browser.close();

// Checks, with the tolerances of the polish brief
const spread = (values) => Math.max(...values) - Math.min(...values);
const near = (value, target, tolerance) =>
  Math.abs(value - target) <= tolerance;
const px = (text) => parseFloat(text);
const checks = [];
const check = (name, value, pass, rule) =>
  checks.push({
    name,
    value: typeof value === "number" ? Math.round(value * 10) / 10 : value,
    rule,
    pass,
  });

const idea = panes.idea;
const panelInnerLeft = idea.panel.x + idea.panel.clientLeft;
const panelInnerRight = panelInnerLeft + idea.panel.clientWidth;
for (const [paneName, m] of Object.entries(panes)) {
  const cy = m.circles.map((c) => c.cy);
  check(
    `${paneName}: circle centres on one y`,
    spread(cy),
    spread(cy) <= 1,
    "spread <= 1 px",
  );
  const widths = m.connectors.map((c) => c.width);
  check(
    `${paneName}: connectors same length`,
    spread(widths),
    spread(widths) <= 1,
    "spread <= 1 px",
  );
  const thickness = m.connectors.map((c) =>
    px(c.borderTopWidth) > 0 ? px(c.borderTopWidth) : c.height,
  );
  check(
    `${paneName}: connectors 1 px`,
    thickness,
    thickness.every((t) => near(t, 1, 0.01)),
    "all = 1 px",
  );
  const colours = new Set(
    m.connectors.map((c) =>
      px(c.borderTopWidth) > 0 ? c.borderTopColor : c.background,
    ),
  );
  check(
    `${paneName}: connectors same colour`,
    [...colours],
    colours.size === 1,
    "one colour",
  );
  const sizes = new Set(m.labels.map((l) => l.fontSize));
  check(
    `${paneName}: labels same font size`,
    [...sizes],
    sizes.size === 1,
    "one size",
  );
  const weights = m.labels.map((l) => l.fontWeight);
  const activeIndex = {
    idea: 0,
    flow: 1,
    number: 2,
    check1: 3,
    check1Answered: 3,
    check2: 4,
    check2Answered: 4,
  }[paneName];
  const otherWeights = new Set(weights.filter((_, i) => i !== activeIndex));
  check(
    `${paneName}: label weights (active bold)`,
    weights,
    otherWeights.size === 1 &&
      px(weights[activeIndex]) >= 600 &&
      px([...otherWeights][0]) < 600,
    "active >= 600, others equal and < 600",
  );
  const above = m.block.y - m.stepper.bottom;
  const below = m.footer.y - m.block.bottom;
  check(
    `${paneName}: block centred between stepper and footer`,
    { above, below, diff: Math.round((above - below) * 10) / 10 },
    Math.abs(above - below) <= 4,
    "|above - below| <= 4 px",
  );
  check(
    `${paneName}: footer top same as idea pane`,
    m.footer.y - idea.footer.y,
    near(m.footer.y, idea.footer.y, 0.5),
    "diff <= 0.5 px",
  );
  check(
    `${paneName}: modal height same as idea pane`,
    m.panel.height - idea.panel.height,
    near(m.panel.height, idea.panel.height, 0.5),
    "diff <= 0.5 px",
  );
}
check(
  "header padding 24 px",
  idea.header.padding,
  idea.header.padding.every((p) => px(p) === 24),
  "all sides 24 px",
);
check(
  "stepper 16 px below the divider",
  idea.stepper.y - idea.header.bottom,
  near(idea.stepper.y - idea.header.bottom, 16, 1),
  "16 +- 1 px",
);
check(
  "stepper spans the content width (24 px side padding)",
  {
    left: idea.stepper.x - panelInnerLeft,
    right: panelInnerRight - idea.stepper.right,
  },
  near(idea.stepper.x - panelInnerLeft, 24, 1) &&
    near(panelInnerRight - idea.stepper.right, 24, 1),
  "24 +- 1 px each side",
);
check(
  "badge 96 px",
  idea.badge && [idea.badge.width, idea.badge.height],
  !!idea.badge &&
    near(idea.badge.width, 96, 0.5) &&
    near(idea.badge.height, 96, 0.5),
  "96 x 96",
);
check(
  "badge to headline 16 px",
  idea.headline && idea.badge && idea.headline.y - idea.badge.bottom,
  !!idea.headline &&
    !!idea.badge &&
    near(idea.headline.y - idea.badge.bottom, 16, 1),
  "16 +- 1 px",
);
check(
  "headline 22 px",
  idea.headline?.fontSize,
  idea.headline?.fontSize === "22px",
  "22px",
);
const lines = idea.headline
  ? Math.round(idea.headline.height / px(idea.headline.lineHeight))
  : 0;
check("headline at most 2 lines", lines, lines >= 1 && lines <= 2, "<= 2");
check(
  "headline max width 560 px",
  idea.headline?.width,
  !!idea.headline && idea.headline.width <= 560.5,
  "<= 560 px",
);
check(
  "headline centred in the panel",
  idea.headline && idea.headline.cx - idea.panel.cx,
  !!idea.headline && near(idea.headline.cx, idea.panel.cx, 1),
  "centre x +- 1 px",
);
const open = summarizeTransition(openSamples);
check(
  "on open the pane does not slide (the modal has its own entrance)",
  { animated: open.animated, maxAbsTranslateX: open.maxAbsTranslateX },
  !open.animated,
  "no pane motion",
);
const next = summarizeTransition(nextSamples);
const back = summarizeTransition(backSamples);
for (const [name, t, sign] of [
  ["Next", next, 1],
  ["Back", back, -1],
]) {
  check(
    `transition on ${name}: fade + 8 px slide`,
    {
      minOpacity: t.minOpacity,
      startTranslateX: t.startTranslateX,
      settledAtMs: t.settledAtMs,
    },
    t.animated &&
      t.minOpacity < 0.5 &&
      near(t.maxAbsTranslateX, 8, 1) &&
      Math.sign(t.startTranslateX) === sign &&
      t.settledAtMs !== null &&
      t.settledAtMs <= 180 + 40,
    `opacity from < 0.5, slide ${sign > 0 ? "+" : "-"}8 px, settled by ~180 ms (+ 2 frames)`,
  );
}
for (const name of ["check1", "check2"])
  check(
    `answering does not move ${name}`,
    panes[`${name}Answered`].block.y - panes[name].block.y,
    near(panes[`${name}Answered`].block.y, panes[name].block.y, 0.5),
    "block top diff <= 0.5 px",
  );
check(
  "level 1 flow: 4 nodes inside the pane, one animated edge, readable zoom",
  {
    scale: panes.flow.flow?.scale,
    nodes: panes.flow.flow?.nodes.length,
    animatedEdges: panes.flow.flow?.animatedEdges,
  },
  !!panes.flow.flow &&
    panes.flow.flow.nodes.length === 4 &&
    panes.flow.flow.animatedEdges === 1 &&
    panes.flow.flow.scale >= 0.6,
  "4 nodes, 1 animated edge, zoom >= 0.6",
);
check(
  "the flow is built once (Next shows the element built on open)",
  flowMountedOnce,
  flowMountedOnce === true,
  "same element",
);
check(
  "Next is locked until check 1 is answered",
  nextLockedBeforeAnswer,
  nextLockedBeforeAnswer === true,
  "disabled",
);
check(
  "one right check does not learn the level",
  learnedAfterOneCheck,
  learnedAfterOneCheck === false,
  "level 1 not learned after check 1",
);
check(
  "both right checks learn the level",
  learnedAfterBothChecks,
  learnedAfterBothChecks === true,
  "level 1 learned after check 2",
);
check(
  "one wrong pick: one more try",
  afterOneWrong,
  afterOneWrong.nextDisabled && afterOneWrong.feedback === 1,
  "Next locked, 'One more try' shown",
);
check(
  "two wrong picks: the answer is shown and Next opens",
  afterTwoWrong,
  !afterTwoWrong.nextDisabled && afterTwoWrong.answerMarked === 1,
  "Next enabled, answer marked",
);
check(
  "a missed check keeps the level open",
  level2Learned,
  level2Learned === false,
  "level 2 not learned (check 1 missed, check 2 right)",
);
for (const row of sweep) {
  const fits = row.panes.every((p) => p.blockHeight <= p.paneHeight + 0.5);
  const footerSpread = spread(row.panes.map((p) => p.footerY));
  const lines = row.panes[0].headlineLines;
  const flow = row.panes[1].flow;
  const banned = row.panes.flatMap((p) => p.bannedText);
  const linkOnlyLast = row.panes.every((p, i) =>
    i === row.panes.length - 1
      ? p.footerLinkText.startsWith("Try it")
      : p.footerLinkText === "",
  );
  check(
    `level "${row.title}"`,
    {
      blockHeights: row.panes.map((p) => p.blockHeight),
      paneHeight: row.panes[0].paneHeight,
      footerSpread,
      headlineLines: lines,
      flow,
      banned,
      linkOnlyLast,
    },
    fits &&
      footerSpread <= 0.5 &&
      lines !== null &&
      lines <= 2 &&
      !!flow &&
      flow.nodesInside &&
      flow.labelsClear &&
      flow.overflowing.length === 0 &&
      flow.animatedEdges === 1 &&
      flow.scale >= 0.6 &&
      banned.length === 0 &&
      linkOnlyLast,
    "panes fit, footer still, headline <= 2 lines, flow inside + labels clear of nodes + 1 animated edge + zoom >= 0.6, no chips, Try it on pane 5 only",
  );
}
check("no page errors", pageErrors, pageErrors.length === 0, "none");

const result = {
  measuredAt: new Date().toISOString(),
  viewport: "1440x1000",
  level: 1,
  panes,
  transitions: { open, next, back },
  levels: sweep,
  behaviour: {
    flowMountedOnce,
    nextLockedBeforeAnswer,
    learnedAfterOneCheck,
    learnedAfterBothChecks,
    afterOneWrong,
    afterTwoWrong,
    level2Learned,
  },
  checks,
  passed: checks.filter((c) => c.pass).length,
  failed: checks.filter((c) => !c.pass).length,
};
const audit = existsSync(auditFile)
  ? JSON.parse(readFileSync(auditFile, "utf8"))
  : {};
audit[phase] = result;
writeFileSync(auditFile, JSON.stringify(audit, null, 2) + "\n");

for (const c of checks)
  console.log(
    `${c.pass ? "ok  " : "FAIL"} ${c.name}: ${JSON.stringify(c.value)} (${c.rule})`,
  );
console.log(
  `${phase}: ${result.passed} passed, ${result.failed} failed -> ${auditFile}`,
);
