/* Run in the browser on a built public page at 320, 768, and 1440px.
   A wide-screen rule once pulled nested pre elements 24px outside their
   copy cards, clipping the inset and long messages. Check rendered bounds,
   including the text itself, so selector changes cannot hide a recurrence. */
function checkCopyBlockLayout() {
  const blocks = [...document.querySelectorAll('.copy-wrap')];
  const failures = [];
  for (const [index, block] of blocks.entries()) {
    const pre = block.querySelector('pre');
    const button = block.querySelector('button');
    const label = block.querySelector('.copy-label');
    const range = document.createRange();
    range.selectNodeContents(pre.querySelector('code') || pre);
    const card = block.getBoundingClientRect();
    const content = pre.getBoundingClientRect();
    const text = range.getBoundingClientRect();
    const control = button.getBoundingClientRect();
    const name = `${index + 1}: ${label.textContent}`;
    if (content.left < card.left || content.right > card.right)
      failures.push(`${name}: content extends outside the card`);
    if (text.left < card.left + 12 || text.right > card.right - 12)
      failures.push(`${name}: text has less than 12px of horizontal inset`);
    const labelBounds = label.getBoundingClientRect();
    // The small landing-page installer omits its redundant Terminal label.
    if (labelBounds.width > 0 && Math.abs(text.left - labelBounds.left) > 1)
      failures.push(`${name}: label and content do not align`);
    if (control.width < 44 || control.height < 44)
      failures.push(`${name}: copy control is smaller than 44px`);
    if (control.left < card.left || control.right > card.right)
      failures.push(`${name}: copy control extends outside the card`);
    if (pre.scrollWidth > pre.clientWidth + 1)
      failures.push(`${name}: content overflows horizontally`);
  }
  if (!blocks.length) failures.push('No copy blocks found');
  if (document.documentElement.scrollWidth > innerWidth)
    failures.push('The page overflows horizontally');
  if (failures.length) throw new Error(failures.join('\n'));
  return { blocks: blocks.length, viewport: innerWidth, result: 'pass' };
}
