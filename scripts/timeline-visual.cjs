// Read-only, real-episode regression for the timeline rail and prompt provenance.
// Usage: node scripts/timeline-visual.cjs EPISODE_URL PRIVATE_OUTPUT_PREFIX
const {chromium} = require(process.env.RESPONDER_PLAYWRIGHT_MODULE || 'playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const {createCaptureDirectory} = require('./visual-artifacts.cjs');

(async () => {
  const url = new URL(process.argv[2]);
  assert(['localhost', '127.0.0.1', '[::1]'].includes(url.hostname));
  assert(url.protocol === 'http:' && !url.username && !url.password);
  assert(url.pathname.startsWith('/timeline/'));
  assert(process.argv[3], 'Supply a private output prefix');
  const output = await createCaptureDirectory(process.argv[3], path.resolve(__dirname, '..'));
  console.log(output);
  const browser = await chromium.launch({headless: true});
  const results = [];
  try {
    for (const width of [1440, 900, 390]) {
      const page = await browser.newPage({viewport: {width, height: 1000}, reducedMotion: 'reduce'});
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
      const response = await page.goto(url.href);
      await page.locator('[data-connection-state="connected"]').waitFor();
      await page.evaluate(() => document.fonts.ready);
      await page.locator('#execution-timeline').scrollIntoViewIfNeeded();
      const rails = await page.locator('.case-entry-body').evaluateAll(es => es.map(e => e.getBoundingClientRect().left));
      const markerOffsets = await page.locator('.case-entry-body').evaluateAll(es => es.map(e => {
        const rail = parseFloat(getComputedStyle(e).borderLeftWidth);
        const marker = getComputedStyle(e, '::before');
        return rail / 2 + parseFloat(marker.left) + (parseFloat(marker.width) + parseFloat(marker.borderLeftWidth) + parseFloat(marker.borderRightWidth)) / 2;
      }));
      const result = {width, version: response.headers()['x-responder-version'], rails, markerOffsets, errors};
      await page.screenshot({path: path.join(output, `timeline-${width}.png`)});
      try {
        // User and host rows once inherited different side margins: the rail jumped 22px.
        assert(rails.length > 2, 'Use a populated episode, not an empty page');
        assert(Math.max(...rails) - Math.min(...rails) < 1, 'Every row must share one timeline rail');
        assert(markerOffsets.every(offset => Number.isFinite(offset) && Math.abs(offset) < 1), 'Each marker must be centered on its rail');
        assert.equal(response.status(), 200);
        assert(await page.locator('.prompt-source[data-source="instructions"]').count() > 0, 'Host instructions need source labels');
        assert(await page.locator('.prompt-source[data-source="input"], .prompt-source[data-source="inputs"], .prompt-source[data-source="current_inputs"]').count() > 0, 'Input context needs source labels');
        const instructions = page.locator('.prompt-source[data-source="instructions"]').first();
        await instructions.locator('summary').click();
        await instructions.locator('.prompt-source-body').waitFor();
        const updatedAt = await page.locator('#responder-shell').getAttribute('data-updated-at');
        await page.waitForFunction(previous => document.querySelector('#responder-shell')?.dataset.updatedAt !== previous, updatedAt, {timeout: 12000});
        assert(await instructions.getAttribute('open') !== null, 'Expanded prompt survives refresh');
        await instructions.locator('summary').scrollIntoViewIfNeeded();
        await page.screenshot({path: path.join(output, `prompt-${width}.png`)});
        await page.locator('.artifact-context').last().scrollIntoViewIfNeeded();
        await page.screenshot({path: path.join(output, `context-sources-${width}.png`)});
        const bounds = await page.evaluate(() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]);
        assert(bounds[0] <= bounds[1], 'No horizontal page overflow');
        assert.deepEqual(errors, []);
      } catch (error) { result.failure = error.message; }
      results.push(result);
      console.log(`${width}: ${result.failure || 'PASS'}`);
      await page.close();
    }
  } finally {
    await browser.close();
    await fs.writeFile(path.join(output, 'manifest.json'), JSON.stringify(results, null, 2), {mode: 0o600});
  }
  if (results.some(r => r.failure)) process.exitCode = 1;
})().catch(error => {console.error(error); process.exitCode = 1;});
