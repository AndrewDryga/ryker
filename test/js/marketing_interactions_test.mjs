import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";

const commonSource = await readFile(new URL("../../site/assets/site.js", import.meta.url), "utf8");
const examplesSource = await readFile(new URL("../../site/assets/everyday.js", import.meta.url), "utf8");
const heroSource = await readFile(new URL("../../site/assets/home.js", import.meta.url), "utf8");

function node(properties = {}) {
  const listeners = new Map();
  const classes = new Set();
  return {
    children: [], attributes: {}, hidden: false, tabIndex: -1,
    addEventListener(type, listener) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(listener);
    },
    dispatch(type, details = {}) {
      const event = { target: this, prevented: false, preventDefault() { this.prevented = true; }, ...details };
      for (const listener of listeners.get(type) || []) listener(event);
      return event;
    },
    setAttribute(name, value) { this.attributes[name] = String(value); },
    getAttribute(name) { return this.attributes[name] ?? null; },
    removeAttribute(name) { delete this.attributes[name]; },
    hasAttribute(name) { return name in this.attributes; },
    appendChild(child) { this.children.push(child); child.parentNode = this; },
    insertBefore(child) { this.appendChild(child); },
    contains(child) { return this === child || this.children.some(item => item.contains(child)); },
    focus() { this.focused = true; },
    classList: {
      add(name) { classes.add(name); },
      toggle(name, on) { if (on) classes.add(name); else classes.delete(name); },
      remove(name) { classes.delete(name); },
      contains(name) { return classes.has(name); }
    },
    ...properties
  };
}

function copyPage(writeText) {
  const created = [];
  const timers = [];
  const pre = node({ textContent: "node scripts/build-site.mjs\n" });
  node().appendChild(pre);
  const selection = { ranges: [], removeAllRanges() { this.ranges = []; }, addRange(range) { this.ranges.push(range); } };
  const document = {
    querySelector: () => null,
    querySelectorAll: selector => selector === ".doc pre, .install pre" ? [pre] : [],
    createElement(tag) { const element = node({ tag }); created.push(element); return element; },
    createRange() { return { selectNodeContents(target) { this.target = target; } }; }
  };
  const window = {
    getSelection: () => selection,
    clearTimeout() {},
    setTimeout(callback) { timers.push(callback); return timers.length; }
  };
  vm.runInNewContext(commonSource, { document, window, navigator: { clipboard: { writeText } } });
  return { pre, selection, timers, button: created.find(item => item.tag === "button"), created };
}

// Clipboard permission can fail even on a secure page. The old fallback said
// to press a Mac shortcut while leaving nothing selected, so it copied nothing.
test("a denied clipboard selects the actual command and explains manual copying", async () => {
  const page = copyPage(async () => { throw new Error("clipboard denied"); });
  page.button.dispatch("click");
  await new Promise(setImmediate);
  assert.equal(page.selection.ranges.length, 1);
  assert.equal(page.selection.ranges[0].target, page.pre);
  const status = page.created.find(item => item.attributes.role === "status");
  assert.match(status.textContent, /Code selected/);
  assert.match(status.textContent, /Copy command/);
  assert.doesNotMatch(status.textContent, /⌘|Ctrl|Command/);
  assert.match(page.button.attributes["aria-label"], /Code selected/);
});

function taskTimeline(source) {
  const frames = new Map();
  let frameId = 0;
  let now = 100;
  function element(properties = {}) {
    const descendants = new Map();
    return node({
      dataset: {}, style: { setProperty() {} }, textContent: "", offsetHeight: 600,
      getBoundingClientRect: () => ({ top: 100 }),
      querySelector(selector) {
        if (!descendants.has(selector)) descendants.set(selector, element());
        return descendants.get(selector);
      },
      querySelectorAll: () => [],
      closest(selector) {
        for (let current = this; current; current = current.parentNode) {
          if (selector === "[hidden]" && current.hidden) return current;
          if (selector === "[data-live-card]" && current.liveCard) return current;
          if (selector === ".chat-message" && current.message) return current;
        }
        return null;
      },
      ...properties
    });
  }
  function event(at, until, properties) {
    return element({
      hidden: true,
      dataset: { at: String(at), moment: String(at), ...(until ? { until: String(until) } : {}) },
      attributes: until ? { "data-until": String(until) } : {},
      ...properties
    });
  }
  const message = event(22, null, { message: true });
  const card = element({ liveCard: true });
  const planning = event(22, 25);
  const implementation = event(25, 32);
  const checks = event(32, null);
  const reply = event(30, null, { message: true });
  message.appendChild(card);
  card.appendChild(planning);
  card.appendChild(implementation);
  card.appendChild(checks);
  const scrolls = [];
  const pane = element({ scrollTop: 240, scrollHeight: 1000, scrollTo(options) { scrolls.push(options); this.scrollTop = options.top; } });
  const slack = element();
  slack.appendChild(message);
  slack.appendChild(reply);
  const play = element();
  const seek = element({ dataset: { seek: "22" } });
  const github = element();
  const controls = element();
  const demo = element({
    dataset: { duration: "40", demoName: "task" },
    querySelectorAll: selector => selector === "[data-seek]" ? [seek] : selector === "[data-at]" || selector === "[data-moment]" ? [message, planning, implementation, checks, reply] : []
  });
  const defaultQuery = demo.querySelector;
  demo.querySelector = selector => ({ ".slack-scroll": pane, ".slack-window": slack, ".github-window": github, ".demo-controls": controls, ".playback-toggle": play, "[data-working]": null }[selector] ?? (selector === "[data-working]" ? null : defaultQuery(selector)));
  demo.querySelector(".pr-scroll").scrollTo = () => {};
  const media = element({ matches: false });
  const document = element({
    hidden: false,
    querySelector: selector => selector === ".product-demo" ? demo : element(),
    querySelectorAll: selector => selector === ".everyday-demo" ? [demo] : []
  });
  const window = element({
    matchMedia: () => media,
    requestAnimationFrame(callback) { frames.set(++frameId, callback); return frameId; },
    cancelAnimationFrame(id) { frames.delete(id); },
    setTimeout() {}, clearTimeout() {}
  });
  vm.runInNewContext(source, { document, window });
  function advance(seconds) {
    for (let elapsed = 0; elapsed < seconds * 1000; elapsed += 50) {
      now += 50;
      const pending = [...frames.values()];
      frames.clear();
      pending.forEach(callback => callback(now));
    }
  }
  seek.dispatch("click");
  scrolls.length = 0;
  return { card, planning, implementation, checks, reply, pane, scrolls, advance };
}

// Every progress change used to slide in and scroll the thread again, making
// an edit to one Slack message look like a stream of new task cards.
for (const [name, source] of [["hero", heroSource], ["examples", examplesSource]]) {
  test(`${name}: task edits keep the message and viewport in place`, () => {
    const page = taskTimeline(source);
    const top = page.pane.scrollTop;
    page.advance(3.3);
    assert.equal(page.planning.hidden, true);
    assert.equal(page.implementation.hidden, false);
    assert.equal(page.implementation.parentNode, page.card);
    assert.equal(page.implementation.classList.contains("is-arriving"), false, "a task edit must not animate as a new message");
    assert.equal(page.scrolls.length, 0, "a task edit must not scroll the conversation");
    assert.equal(page.pane.scrollTop, top);
    page.advance(5);
    assert.equal(page.reply.hidden, false);
    assert.equal(page.reply.classList.contains("is-arriving"), true, "new replies still arrive normally");
    assert.ok(page.scrolls.length > 0, "new replies still come into view");
    page.scrolls.length = 0;
    const replyTop = page.pane.scrollTop;
    page.advance(2.5);
    assert.equal(page.checks.hidden, false);
    assert.equal(page.checks.classList.contains("is-arriving"), false);
    assert.equal(page.scrolls.length, 0, "a later edit must not pull the reader away from a newer reply");
    assert.equal(page.pane.scrollTop, replyTop);
  });
}

test("successful copying announces the result and restores the action label", async () => {
  const writes = [];
  const page = copyPage(async value => writes.push(value));
  page.button.dispatch("click");
  await new Promise(setImmediate);
  assert.deepEqual(writes, ["node scripts/build-site.mjs"]);
  assert.equal(page.selection.ranges.length, 0);
  assert.equal(page.button.textContent, "Copied");
  const status = page.created.find(item => item.attributes.role === "status");
  assert.equal(status.textContent, "Code copied.");
  page.timers.at(-1)();
  assert.equal(page.button.attributes["aria-label"], "Copy this code");
});

function examplePage(hash = "") {
  const panels = ["coding", "review", "alerts"].map(name => node({ id: "example-" + name }));
  const tabs = panels.map(panel => node({ id: "tab-" + panel.id, hash: "#" + panel.id }));
  const tablist = node();
  const picker = node({ querySelector: () => tablist, querySelectorAll: () => tabs });
  const notifications = [];
  const document = {
    querySelectorAll: selector => selector === "[data-example-picker]" ? [picker] : [],
    getElementById: id => panels.find(panel => panel.id === id),
    dispatchEvent: event => notifications.push(event.type)
  };
  const replacements = [];
  const state = { retained: "history owned by the browser" };
  const location = { hash };
  const window = node({
    location,
    history: {
      state,
      replaceState(nextState, title, url) { replacements.push({ state: nextState, url }); location.hash = url; }
    },
    matchMedia: () => ({ matches: false }),
    requestAnimationFrame() {}
  });
  vm.runInNewContext(examplesSource, { document, window, Event: class { constructor(type) { this.type = type; } } });
  return { panels, tabs, window, replacements, state, notifications };
}

// A copied example URL must describe the example the reader actually chose;
// replacing history must not trigger native fragment scrolling or add entries.
test("selecting an example updates its shareable URL without native navigation", () => {
  const page = examplePage();
  const click = page.tabs[1].dispatch("click");
  assert.equal(click.prevented, true);
  assert.equal(page.panels[1].hidden, false);
  assert.equal(page.panels[1].tabIndex, 0);
  assert.equal(page.panels[0].hidden, true);
  assert.deepEqual(page.replacements, [{ state: page.state, url: "#example-review" }]);
  const arrow = page.tabs[1].dispatch("keydown", { key: "ArrowRight" });
  assert.equal(arrow.prevented, true);
  assert.equal(page.tabs[2].focused, true);
  assert.equal(page.tabs[2].attributes["aria-selected"], "true");
  assert.equal(page.replacements.at(-1).url, "#example-alerts");
});

test("initial fragments and print restore the selected example without rewriting history", () => {
  const page = examplePage("#example-review");
  assert.equal(page.panels[1].hidden, false);
  assert.equal(page.panels[0].hidden, true);
  assert.equal(page.replacements.length, 0);
  page.window.dispatch("beforeprint");
  assert.ok(page.panels.every(panel => !panel.hidden));
  page.window.dispatch("afterprint");
  assert.deepEqual(page.panels.map(panel => panel.hidden), [true, false, true]);
  assert.equal(page.replacements.length, 0);
  const modifiedClick = page.tabs[2].dispatch("click", { metaKey: true });
  assert.equal(modifiedClick.prevented, false);
  assert.equal(page.replacements.length, 0);
});
