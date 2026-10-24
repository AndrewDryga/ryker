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

function copyPage(writeText, attributes = {}, code = "node scripts/build-site.mjs\n") {
  const created = [];
  const timers = [];
  const pre = node({ textContent: code, attributes });
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

test("the install action names and copies both commands as one block", async () => {
  const commands = "git clone https://github.com/AndrewDryga/ryker ryker\ncd ryker && ./install.sh";
  const writes = [];
  const page = copyPage(async value => writes.push(value), {
    "data-copy-button": "Copy both commands"
  }, commands);
  assert.equal(page.button.title, "Copy both commands");
  assert.equal(page.button.attributes["aria-label"], "Copy both commands");
  assert.ok(page.pre.parentNode.contains(page.button));
  page.button.dispatch("click");
  await new Promise(setImmediate);
  assert.deepEqual(writes, [commands]);
  page.timers.at(-1)();
  assert.equal(page.button.title, "Copy both commands");
});

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
  assert.equal(status.classList.contains("vh"), false, "manual-copy instructions stay visible");
  assert.match(status.textContent, /Copy command/);
  assert.doesNotMatch(status.textContent, /⌘|Ctrl|Command/);
  assert.match(page.button.attributes["aria-label"], /Code selected/);
});

function taskTimeline(source, mobile = false, reduced = false) {
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
    dataset: { duration: "40", demoName: "task", ...(mobile ? { mobileState: "preview" } : {}) },
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
    matchMedia: query => query.includes("prefers-reduced-motion") ? { ...media, matches: reduced } : media,
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
  return { card, planning, implementation, checks, reply, pane, scrolls, advance, demo, seek, controls };
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
  assert.equal(page.button.classList.contains("done"), true);
  const status = page.created.find(item => item.attributes.role === "status");
  assert.equal(status.textContent, "Code copied.");
  assert.equal(status.classList.contains("vh"), true, "the checkmark confirms copying without adding a row");
  page.timers.at(-1)();
  assert.equal(page.button.attributes["aria-label"], "Copy this code");
  assert.equal(page.button.classList.contains("done"), false);
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

// A phone showed only the top of an already-playing thread. Readers reached
// the controls after the story had moved on, then scrolled past a tall empty pane.
for (const [name, source] of [["hero", heroSource], ["examples", examplesSource]]) {
  test(`${name}: compact previews do not spend the viewer's playback time`, () => {
    const page = taskTimeline(source, true);
    page.advance(10);
    assert.equal(page.planning.hidden, false, "a closed preview must not advance");
    assert.equal(page.implementation.hidden, true);
    page.demo.dataset.mobileState = "playing";
    page.demo.dispatch("demomodechange");
    page.advance(3.3);
    assert.equal(page.implementation.hidden, false, "opening the player starts playback");
    page.demo.dataset.mobileState = "preview";
    page.demo.dispatch("demomodechange");
    page.advance(15);
    assert.equal(page.checks.hidden, true, "closing must stop playback");
  });
}

function mobilePlayerPage() {
  function element(properties = {}) {
    return node({
      style: {}, dataset: {},
      appendChild(child) {
        if (child.parentNode) child.parentNode.children = child.parentNode.children.filter(item => item !== child);
        this.children.push(child);
        child.parentNode = this;
      },
      insertBefore(child, sibling) {
        this.children.splice(this.children.indexOf(sibling), 0, child);
        child.parentNode = this;
      },
      replaceWith(child) {
        if (child.parentNode) child.parentNode.children = child.parentNode.children.filter(item => item !== child);
        const parent = this.parentNode;
        parent.children.splice(parent.children.indexOf(this), 1, child);
        child.parentNode = parent;
        this.parentNode = null;
      },
      dispatchEvent(event) { this.dispatch(event.type, event); },
      ...properties
    });
  }
  const pane = element();
  const demo = element({ dataset: { demoTitle: "Writing a fix", duration: "37" }, offsetHeight: 292, querySelector: () => pane });
  const home = element();
  home.appendChild(demo);
  const title = element();
  const close = element();
  const dialog = element({
    open: false,
    querySelector: selector => selector === "h2" ? title : close,
    showModal() { this.open = true; },
    close() { this.open = false; this.dispatch("close"); }
  });
  const document = {
    body: element(), documentElement: element(), querySelectorAll: () => [demo],
    createElement: name => name === "dialog" ? dialog : element()
  };
  const media = element({ matches: true });
  const window = element({ HTMLDialogElement: { prototype: { showModal() {} } }, matchMedia: () => media, requestAnimationFrame() {} });
  return { demo, pane, home, dialog, close, document, window, media, title };
}

// Moving the existing conversation must leave neither a second timeline nor
// a permanent gap behind, and Escape/rotation/printing must release the page.
test("the mobile player restores the original conversation and releases page scrolling", async () => {
  const source = await readFile(new URL("../../site/assets/mobile-demo.js", import.meta.url), "utf8");
  const page = mobilePlayerPage();
  vm.runInNewContext(source, { ...page, CustomEvent: class { constructor(type, options) { this.type = type; this.detail = options.detail; } } });
  const watch = page.demo.children[0];
  assert.equal(page.pane.inert, true);
  assert.equal(page.demo.dataset.mobileState, "preview");
  watch.dispatch("click");
  assert.equal(page.dialog.open, true);
  assert.equal(page.demo.parentNode, page.dialog);
  assert.equal(page.home.children[0].style.height, "292px");
  assert.equal(page.pane.inert, false);
  assert.equal(page.close.focused, true);
  assert.equal(page.title.textContent, "Writing a fix");
  assert.ok(page.document.body.classList.contains("demo-player-open"));
  page.dialog.close(); // Native Escape also dispatches close.
  assert.deepEqual(page.home.children, [page.demo]);
  assert.equal(page.pane.inert, true);
  assert.ok(watch.focused);
  assert.equal(page.document.body.classList.contains("demo-player-open"), false);
  watch.dispatch("click");
  page.media.matches = false;
  page.media.dispatch("change");
  assert.equal(page.dialog.open, false);
  assert.equal(page.demo.parentNode, page.home);
  assert.equal(page.demo.dataset.mobileState, "");
  assert.equal(page.pane.inert, false);
  page.media.matches = true;
  page.media.dispatch("change");
  watch.dispatch("click");
  page.window.dispatch("beforeprint");
  assert.equal(page.dialog.open, false);
  assert.equal(page.demo.parentNode, page.home);
  assert.equal(page.document.documentElement.classList.contains("demo-player-open"), false);
});

for (const [name, source] of [["hero", heroSource], ["examples", examplesSource]]) {
  test(`${name}: reduced motion allows manual chapters without autoplay on mobile`, () => {
    const page = taskTimeline(source, true, true);
    page.demo.dataset.mobileState = "playing";
    page.demo.dispatch("demomodechange");
    assert.equal(page.controls.hidden, false);
    page.advance(20);
    assert.equal(page.planning.hidden, false);
    assert.equal(page.implementation.hidden, true);
    page.seek.dataset.seek = "26";
    page.seek.dispatch("click");
    assert.equal(page.implementation.hidden, false);
    page.advance(20);
    assert.equal(page.checks.hidden, true);
  });
}

function navigationPage() {
  const summary = node();
  const link = node();
  const menu = node({ open: true, querySelector: () => summary });
  menu.appendChild(summary);
  menu.appendChild(link);
  const document = node({
    querySelector: selector => selector === "details.nav-menu" ? menu : null,
    querySelectorAll: selector => selector === "details.nav-menu, .docs-nav > details" ? [menu] : []
  });
  const media = node({ matches: false });
  const window = node({ matchMedia: () => media });
  vm.runInNewContext(commonSource, { document, window, navigator: {} });
  return { menu, summary, link, document, media };
}

// The mobile drawer used to stay over the page after tapping outside or
// tabbing into the content, leaving navigation detached from its trigger.
test("mobile navigation closes when interaction leaves it without taking focus back", () => {
  const page = navigationPage();
  page.document.dispatch("pointerdown", { target: page.link });
  assert.equal(page.menu.open, true, "interaction inside must keep the drawer available");
  page.document.dispatch("pointerdown", { target: node() });
  assert.equal(page.menu.open, false, "tapping outside dismisses the drawer");
  assert.notEqual(page.summary.focused, true, "outside taps keep the user's chosen focus");
  page.menu.open = true;
  page.menu.dispatch("focusout", { relatedTarget: page.link });
  assert.equal(page.menu.open, true);
  page.menu.dispatch("focusout", { relatedTarget: node() });
  assert.equal(page.menu.open, false, "tabbing into the page closes the drawer");
});

test("Escape returns focus to the menu control and desktop restores unobstructed navigation", () => {
  const page = navigationPage();
  page.menu.dispatch("keydown", { key: "Escape" });
  assert.equal(page.menu.open, false);
  assert.equal(page.summary.focused, true);
  page.menu.open = true;
  page.media.dispatch("change", { matches: true });
  assert.equal(page.menu.open, false);
});
