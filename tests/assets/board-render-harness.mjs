// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html> [idea-to-submit...]
// Prints one JSON document:
//   { stats:[{n,label}], fuel:{hidden,cells:[{tone,name,pct,fill,meta}]},
//     charted:[{title,sub,badges,pickable}], underway:[title], landed:[title],
//     parkedIdeas:[{title,sub}], ideaCapture:{submitted,cleared,limitText,queued} }
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.listeners = {};
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      remove: (c) => {
        this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" ");
      },
      contains: (c) => this.className.split(/\s+/).includes(c),
    };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  dispatch(type, ev) {
    for (const fn of this.listeners[type] || []) fn.call(this, ev);
  }
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
// Stand in for the Lavish bridge the real board talks to, and record every
// prompt the page queues so submissions can be asserted as observable output.
const queued = [];
// FM_BOARD_NO_LAVISH=1 stands in for an exported or file:// copy of the board,
// where the host frame never injects the SDK.
globalThis.window = process.env.FM_BOARD_NO_LAVISH === "1" ? {} : {
  lavish: {
    queuePrompt: (prompt, opts) => {
      queued.push({ prompt, text: opts?.text ?? "", key: opts?.data?.question ?? "", answer: opts?.data?.answer ?? "" });
    },
  },
};
globalThis.TextEncoder = TextEncoder;
// Deferred UI resets are captured, not scheduled, so the harness exits at once.
globalThis.setTimeout = (fn) => fn && 0;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

// The fuel gauge strip: what the board actually shows for each provider pool.
const fuelNode = byId.get("bb-fuel") || new Node("div");
const fuel = {
  hidden: fuelNode.hidden === true,
  cells: fuelNode.children.map((cell) => {
    const head = cell.children.find((c) => c.className.includes("bb-fuel__head"));
    const track = cell.children.find((c) => c.className.includes("bb-fuel__track"));
    const fill = track?.children[0];
    return {
      tone: cell.className.replace(/.*bb-fuel__cell--/, "").trim(),
      name: head?.children.find((c) => c.className.includes("bb-fuel__name"))?.textContent ?? "",
      pct: head?.children.find((c) => c.className.includes("bb-fuel__pct"))?.textContent ?? "",
      fill: fill?.attributes.style ?? "",
      meta: cell.children.find((c) => c.className.includes("bb-fuel__meta"))?.textContent ?? "",
    };
  }),
};

// Underway and Recently Landed: the titles those two sections actually show.
const titlesOf = (id) =>
  (byId.get(id) || new Node("div")).children
    .filter((r) => r.className.split(/\s+/).includes("bb-row"))
    .map((row) =>
      row.children
        .find((c) => c.className.includes("bb-row__main"))
        ?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "");
const underway = titlesOf("bb-underway");
const landed = titlesOf("bb-landed");

const ch = byId.get("bb-charted") || new Node("div");
const charted = ch.children
  .filter((r) => r.className.split(/\s+/).includes("bb-row"))
  .map((row) => {
    const main = row.children.find((c) => c.className.includes("bb-row__main"));
    return {
      title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
      sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
      badges: badgesOf(row),
      pickable: row.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
    };
  });
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

// Parked ideas: the small list of already-captured ideas from the payload.
const piNode = byId.get("bb-parked-ideas") || new Node("div");
const parkedIdeas = piNode.children
  .filter((r) => r.className.split(/\s+/).includes("bb-row"))
  .map((row) => {
    const main = row.children.find((c) => c.className.includes("bb-row__main"));
    return {
      title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
      sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
    };
  });
const parkedIdeasEmpty = piNode.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);

// Drive the capture box itself: every extra argument is one idea typed into the
// form and submitted, in order, so the queued prompts show what the real
// handler does with repeated submissions.
const ideaForm = byId.get("bb-idea-form");
const ideaInput = byId.get("bb-idea-input");
const ideaLimit = byId.get("bb-idea-limit");
const ideaCapture = { submitted: 0, queued: [], limitText: "" };
for (const text of process.argv.slice(3)) {
  ideaInput.value = text;
  ideaForm.dispatch("submit", { preventDefault() {} });
  ideaCapture.submitted += 1;
  ideaCapture.limitText = ideaLimit.textContent;
  ideaCapture.cleared = ideaInput.value === "";
  ideaCapture.kept = ideaInput.value;
  ideaCapture.queuedTick = ideaForm.classList.contains("is-queued");
}
ideaCapture.queued = queued;

process.stdout.write(JSON.stringify({
  stats, fuel, charted, empty, more, underway, landed,
  parkedIdeas, parkedIdeasEmpty, ideaCapture, error: errorText,
}) + "\n");
