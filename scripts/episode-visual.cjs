// Read-only timeline acceptance against real retained episodes. No actions/model calls.
// Screenshots stay in a private directory outside the repository.
// node scripts/episode-visual.cjs ORIGIN OUTPUT /episodes/ENCODED_REF [...]
const {chromium} = require(process.env.RESPONDER_PLAYWRIGHT_MODULE || 'playwright');
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');
const {createCaptureDirectory} = require('./visual-artifacts.cjs');
const origin = new URL(process.argv[2]);
assert(['localhost', '127.0.0.1', '[::1]'].includes(origin.hostname));
assert(origin.protocol === 'http:' && !origin.username && !origin.password && origin.pathname === '/');
assert(process.argv[3], 'Provide a private capture directory');
const routes = process.argv.slice(4);
assert(routes.length && routes.every(route => /^\/episodes\/[^/?#]+$/.test(route)), 'Supply episode paths');

(async () => {
  const output = await createCaptureDirectory(process.argv[3], path.resolve(__dirname, '..'));
  const browser = await chromium.launch({headless: true});
  const report = [];
  try {
    for (const width of [1440, 768, 390]) {
      const page = await browser.newPage({viewport: {width, height: 1000}, reducedMotion: 'reduce'});
      page.setDefaultTimeout(5000);
      for (const [index, route] of routes.entries()) {
        const errors = [];
        const onError = error => errors.push(error.message);
        page.on('pageerror', onError);
        const result = {route, width};
        const capture = async name => page.screenshot({path: path.join(output, `${index}-${width}-${name}.png`)});
        try {
          const response = await page.goto(new URL(route, origin).href);
          assert.equal(response.status(), 200);
          result.version = response.headers()['x-responder-version'];
          await page.locator('[data-connection-state="connected"]').waitFor();
          await page.evaluate(() => document.fonts.ready);
          await capture('overview');
          await page.screenshot({path: path.join(output, `${index}-${width}-full.png`), fullPage: true});
          result.layout = await page.evaluate(() => ({
            width: document.documentElement.scrollWidth, height: document.body.scrollHeight,
            rails: [...document.querySelectorAll('.case-entry-body')].filter(e => e.getBoundingClientRect().height > 0).map(e => e.getBoundingClientRect().left)
          }));
          assert(result.layout.width <= width, 'The page must not overflow horizontally');
          assert(result.layout.rails.every(left => Math.abs(left - result.layout.rails[0]) < 1), 'Every timeline entry must share one aligned rail');
          assert.equal(await page.locator('.case-timeline pre:visible').count(), 0, 'Raw protocol data must not dominate the default timeline');
          const receipts = page.locator('.case-receipt-group').first();
          if (await receipts.count()) {
            await receipts.locator(':scope > summary').click();
            assert(await receipts.locator('.case-entry time').first().isVisible(), 'Grouped receipts retain individual timestamps');
            const rails = await page.locator('.case-entry-body:visible').evaluateAll(es => es.map(e => e.getBoundingClientRect().left));
            assert(rails.every(left => Math.abs(left - rails[0]) < 1), 'Expanded receipts must share the timeline rail');
            await receipts.locator(':scope > summary').click();
          }
          assert.equal(await page.getByText('Inspect admission', {exact: true}).count(), 0);
          if ((await page.locator('h1').innerText()).trim() === 'Hi') {
            // This real greeting previously occupied 11,151px and seven chapters.
            assert(result.layout.height < (width < 600 ? 4100 : 2900), 'A greeting must remain a compact readable execution');
            assert.equal(await page.locator('.chapter-heading h3').filter({hasText: 'Answer & delivery'}).count(), 1);
          }
          const followup = page.locator('.conversation-boundary').first();
          if (await followup.count()) {
            await followup.scrollIntoViewIfNeeded();
            await capture('followup');
            assert(await followup.locator('.turn-divider-label').isVisible());
          }
          const instructions = page.locator('.request-input-parts > details').filter({has: page.locator('.prompt-source-body pre')}).first();
          if (await instructions.count()) {
            await instructions.locator(':scope > summary').click();
            // One click should expose the instructions, including their actual source.
            await instructions.locator('.prompt-source-body pre').waitFor({state: 'visible'});
            assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Opened instructions must not overflow');
            await capture('instructions');
            const updated = await page.locator('#responder-shell').getAttribute('data-updated-at');
            await page.waitForFunction(previous => document.querySelector('#responder-shell')?.dataset.updatedAt !== previous, updated, {timeout: 12000});
            assert(await instructions.locator('.prompt-source-body pre').isVisible(), 'Live updates must preserve open evidence');
            await instructions.locator(':scope > summary').click();
          }
          const context = page.locator('.request-input-parts > details').filter({has: page.locator('.request-context-readable')}).first();
          if (await context.count()) {
            await context.locator(':scope > summary').click();
            assert(await context.locator('.prompt-source-location').first().isVisible(), 'Context must explain where each component came from');
            assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Opened context must not overflow');
            await capture('context');
            await context.locator(':scope > summary').click();
          }
          const outcome = page.getByRole('link', {name: 'Jump to latest outcome'});
          const destination = await outcome.getAttribute('href');
          await outcome.click();
          assert(await page.locator(destination).isVisible(), 'The outcome shortcut must reveal its destination');
          await capture('outcome');
          assert.equal(errors.length, 0, 'Browser errors');
        } catch (error) { result.failure = error.message; await capture('failure'); }
        report.push(result);
        page.off('pageerror', onError);
        console.log(`Episode ${index + 1} / ${width}: ${result.failure || 'PASS'}`);
      }
      await page.close();
    }
  } finally {
    await browser.close();
    await fs.writeFile(path.join(output, 'manifest.json'), JSON.stringify(report, null, 2), {mode: 0o600});
    console.log(output);
  }
  if (report.some(result => result.failure)) process.exitCode = 1;
})().catch(error => {console.error(error.message); process.exitCode = 1;});
