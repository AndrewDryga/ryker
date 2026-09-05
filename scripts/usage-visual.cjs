// Read-only acceptance against a running Emisar control plane, with private screenshots.
const assert = require('node:assert/strict');
const path = require('node:path');
const {createCaptureDirectory} = require('./visual-artifacts.cjs');
const {chromium} = require(process.env.RESPONDER_PLAYWRIGHT_MODULE || 'playwright');

(async () => {
  const origin = process.argv[2] || 'http://127.0.0.1:4321';
  assert(['127.0.0.1', 'localhost', '[::1]'].includes(new URL(origin).hostname));
  const output = await createCaptureDirectory(process.argv[3] || '/tmp/responder-usage-visual', path.resolve(__dirname, '..'));
  const browser = await chromium.launch({headless: true});
  try {
    for (const width of [1440, 1024, 390]) {
      const page = await browser.newPage({viewport: {width, height: 1050}, reducedMotion: 'reduce'});
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      page.on('console', message => {if (message.type() === 'error') errors.push(message.text());});
      const response = await page.goto(origin + '/usage');
      assert.equal(response.status(), 200);
      await page.locator('#responder-shell[data-connection-state=connected]').waitFor();
      await page.locator('.usage-summary').waitFor();
      await page.evaluate(() => document.fonts.ready);
      assert.equal(await page.locator('.app-topbar, #live-controls, button[phx-click=toggle-live]').count(), 0);
      assert.equal(await page.locator('.connection-offline').isVisible(), false);
      assert.deepEqual(await page.locator('.usage-headlines .usage-stat > span').allTextContents(), ['Cost', 'Episodes', 'Executions', 'Total tokens']);
      assert.equal(await page.locator('.usage-page > :last-child').getAttribute('id'), 'cost-method');
      assert(await page.locator('#usage-profiles tbody > tr').count() > 0, 'Use actual populated execution data');
      const bounds = await page.evaluate(() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]);
      assert(bounds[0] <= bounds[1], 'No horizontal page overflow');
      await page.screenshot({path: path.join(output, `summary-${width}.png`)});
      await page.screenshot({path: path.join(output, `usage-${width}.png`), fullPage: true});
      await page.locator('#usage-profiles').scrollIntoViewIfNeeded();
      await page.screenshot({path: path.join(output, `profiles-${width}.png`)});
      const models = page.locator('.usage-profile-models details').first();
      await models.locator('summary').click();
      await page.screenshot({path: path.join(output, `profile-models-${width}.png`)});
      // Automatic refresh must keep the expanded profile, without a Pause/Refresh UI.
      const updated = await page.locator('#responder-shell').getAttribute('data-updated-at');
      await page.waitForFunction(previous => document.querySelector('#responder-shell')?.dataset.updatedAt !== previous, updated, {timeout: 12000});
      assert.notEqual(await models.getAttribute('open'), null);
      const link = page.locator('#usage-profiles .usage-identity a').first();
      await link.click();
      await page.locator('.usage-drilldown').waitFor();
      assert(await page.locator('#activity-stream article').count() > 0, 'Profile link finds its actual episodes');
      await page.locator('.usage-drilldown a', {hasText: 'Clear filter'}).click();
      await page.locator('.usage-drilldown').waitFor({state: 'detached'});
      assert.deepEqual(errors, []);
      console.log(`Usage ${width}: PASS`);
      await page.close();
    }
  } finally {await browser.close();}
  console.log(`Screenshots: ${output}`);
})().catch(error => {console.error(error); process.exitCode = 1;});
