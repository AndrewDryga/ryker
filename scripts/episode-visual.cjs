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
          assert.equal(await page.locator('.case-receipt-group, .case-system-event').count(), 0, 'Actions must not be hidden inside nested receipt groups');
          assert.equal(await page.locator('.case-timeline details details details').count(), 0, 'Timeline evidence must not have three disclosure levels');
          const phases = await page.locator('.chapter-heading h3').allTextContents();
          assert(phases.every(title => ['Getting ready', 'Routing', 'The work', 'The answer'].includes(title)));
          assert.equal(await page.locator('.chapter-description > p:not(.turn-divider-label):visible').count(), phases.length);
          assert.equal(await page.locator('.case-timeline').evaluate(e => getComputedStyle(e).backgroundColor), 'rgba(0, 0, 0, 0)', 'The timeline is a sequence of action cards, not one white panel');
          assert.equal(await page.getByText('Inspect admission', {exact: true}).count(), 0);
          if ((await page.locator('h1').innerText()).trim() === 'Hi') {
            // This real greeting previously occupied 11,151px and seven chapters.
            assert(result.layout.height < (width < 600 ? 4100 : width < 1000 ? 3200 : 2900), 'A greeting must remain a compact readable execution');
            assert.deepEqual(phases, ['Getting ready', 'Routing', 'The work', 'The answer']);
            assert.equal(await page.getByRole('heading', {name: 'Conversational reply', exact: true}).count(), 1);
          }
          const followup = page.locator('.conversation-boundary').filter({has: page.locator('.turn-divider-label')}).first();
          if (await followup.count()) {
            await followup.scrollIntoViewIfNeeded();
            await capture('followup');
            assert(await followup.locator('.turn-divider-label').isVisible());
          }
          const instructions = page.locator('.prompt-assembly > details[data-source="instructions"]').first();
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
          const context = page.locator('.prompt-assembly > details[data-origin="conversation"]').first();
          if (await context.count()) {
            await context.locator(':scope > summary').click();
            assert(await context.locator('.prompt-source-location').first().isVisible(), 'Context must explain where each component came from');
            assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Opened context must not overflow');
            await capture('context');
            await context.locator(':scope > summary').click();
          }
          const work = page.locator('.phase-work').first();
          if (await work.count()) {
            await work.scrollIntoViewIfNeeded();
            await capture('work');
          }
          const prompt = page.locator('.phase-work .final-prompt').first();
          if (await prompt.count()) {
            await prompt.locator(':scope > summary').click();
            await prompt.locator('.submitted-prompt').waitFor({state: 'visible'});
            assert(await prompt.locator('.prompt-fragment[title][data-source]').count() > 0, 'The submitted prompt must identify its actual sources');
            await prompt.scrollIntoViewIfNeeded();
            assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'The full prompt must not overflow the page');
            await capture('full-prompt');
            await prompt.locator(':scope > summary').click();
          }
          const recall = page.locator('.prompt-assembly details[data-source="continuity"]').last();
          if (await recall.count()) {
            await recall.evaluate(element => { for (let parent = element; parent; parent = parent.parentElement) if (parent.tagName === 'DETAILS') parent.open = true; });
            await recall.scrollIntoViewIfNeeded();
            assert(await recall.locator('.conversation-recall').count() > 0, 'Conversation recall must use the compact summary layout');
            await capture('recall');
            await recall.evaluate(element => { for (let parent = element; parent; parent = parent.parentElement) if (parent.tagName === 'DETAILS') parent.open = false; });
          }
          const argumentsPanel = page.locator('.tool-evidence > details').filter({has: page.locator('summary', {hasText: 'Arguments'})}).first();
          if (await argumentsPanel.count()) {
            await argumentsPanel.locator(':scope > summary').click();
            await argumentsPanel.scrollIntoViewIfNeeded();
            await argumentsPanel.locator('pre').waitFor({state: 'visible'});
            const metadata = argumentsPanel.locator('..').locator('..').locator('.case-event-details');
            if (await metadata.count()) {
              const position = element => { const rect = element.getBoundingClientRect(); return {x: rect.x + scrollX, y: rect.y + scrollY}; };
              const before = await metadata.locator('summary').evaluate(position);
              await metadata.locator('summary').click();
              const after = await metadata.locator('summary').evaluate(position);
              assert(Math.abs(before.x - after.x) < 1 && Math.abs(before.y - after.y) < 1, 'Opening metadata must not move its disclosure control');
            }
            await capture('tool-evidence');
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
