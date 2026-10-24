/* Run in the built landing page at 320x568, 375x812, 430x932 and 768x1024.
   First with previews closed, then with each player open and after seeking
   its chapters. Repeat Escape, closing and resizing to desktop. */
function checkMobileDemoLayout() {
  const fail = message => { throw new Error(message); };
  if (document.documentElement.scrollWidth > innerWidth + 1) fail("page overflows horizontally");
  const dialog = document.querySelector(".demo-player[open]");
  if (dialog) {
    const frame = dialog.getBoundingClientRect();
    if (frame.top < -1 || frame.bottom > innerHeight + 1) fail("player exceeds the viewport");
    for (const selector of [".demo-player-close", ".demo-controls", ".demo-viewport"]) {
      const box = dialog.querySelector(selector).getBoundingClientRect();
      if (box.top < 0 || box.bottom > innerHeight + 1 || box.left < 0 || box.right > innerWidth + 1) fail(selector + " is off screen");
    }
    for (const button of dialog.querySelectorAll("button")) {
      const box = button.getBoundingClientRect();
      if (box.width && (box.width < 44 || box.height < 44)) fail("small player control: " + button.textContent);
    }
    if (dialog.querySelector(".demo-viewport").getBoundingClientRect().height < 250) fail("not enough room for the conversation");
    return { player: dialog.querySelector("h2").textContent, width: innerWidth, height: innerHeight };
  }
  if (document.querySelector(".demo-slot")) fail("closing left an empty slot");
  if (document.documentElement.classList.contains("demo-player-open")) fail("closing left the page locked");
  const previews = Array.from(document.querySelectorAll('[data-mobile-state="preview"]')).filter(demo => !demo.closest("[hidden]"));
  for (const demo of previews) {
    const box = demo.getBoundingClientRect();
    if (box.height > 320) fail("preview leaves too much space below its content");
    if (!demo.querySelector(".demo-watch")) fail("preview has no way to open it");
  }
  return { previews: previews.length, width: innerWidth, height: innerHeight };
}
