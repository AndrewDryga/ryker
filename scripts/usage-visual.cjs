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
      assert.equal(await page.locator('#usage-profiles h2').textContent(), 'Profiles');
      assert.equal(await page.locator('#daily-values, #usage-profiles details').count(), 0);
      assert.equal(await page.getByText('Unattributed profile', {exact: true}).count(), 0);
      assert.equal(await page.getByText('Unclassified work', {exact: true}).count(), 0);
      assert.equal(await page.getByText('Execution ledger', {exact: true}).count(), 0);
      assert.equal(await page.locator('.execution-ledger-disclosure').count(), 0);
      assert.equal(await page.locator('.usage-scope [aria-current=page]').textContent(), 'All work');
      assert.equal(await page.getByText('Unknown model', {exact: true}).count(), 0);
      assert.equal(await page.locator('#usage-channels').getByText('Conversation Lab', {exact: true}).count(), 0);
      for (const href of await page.locator('#usage-channels .usage-identity a').evaluateAll(es => es.map(e => e.href))) {
        assert.equal(new URL(href).searchParams.get('usage_transport'), 'slack');
      }
      assert.deepEqual(await page.locator('#usage-people th').allTextContents(), ['Person', 'Episodes', 'Tokens', 'Cost']);
      const peopleBounds = await page.locator('#usage-people table').evaluate(e => [e.getBoundingClientRect().width, e.parentElement.clientWidth]);
      assert(peopleBounds[0] <= peopleBounds[1], 'The compact people table fits without horizontal scrolling');
      for (const href of await page.locator('#usage-models .usage-identity a').evaluateAll(es => es.map(e => e.href))) {
        assert(new URL(href).searchParams.has('usage_effort'), 'Model drilldown includes effort');
      }
      const bounds = await page.evaluate(() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]);
      assert(bounds[0] <= bounds[1], 'No horizontal page overflow');
      await page.screenshot({path: path.join(output, `summary-${width}.png`)});
      await page.screenshot({path: path.join(output, `usage-${width}.png`), fullPage: true});
      await page.locator('#usage-profiles').scrollIntoViewIfNeeded();
      await page.screenshot({path: path.join(output, `profiles-${width}.png`)});
      await page.locator('#usage-models').scrollIntoViewIfNeeded();
      await page.screenshot({path: path.join(output, `models-${width}.png`)});
      await page.locator('#usage-people').scrollIntoViewIfNeeded();
      await page.screenshot({path: path.join(output, `people-${width}.png`)});
      const method = page.locator('#cost-method');
      await method.locator('summary').click();
      assert.equal(await method.locator('summary').textContent(), 'Token pricing');
      const pricingBounds = await page.locator('.usage-pricing-table').evaluate(e => [e.getBoundingClientRect().width, e.parentElement.clientWidth]);
      assert(pricingBounds[0] <= pricingBounds[1], 'Token pricing fits without horizontal scrolling');
      await method.scrollIntoViewIfNeeded();
      await page.screenshot({path: path.join(output, `pricing-${width}.png`)});
      // Automatic refresh preserves reading state, without a Pause/Refresh UI.
      const updated = await page.locator('#responder-shell').getAttribute('data-updated-at');
      await page.waitForFunction(previous => document.querySelector('#responder-shell')?.dataset.updatedAt !== previous, updated, {timeout: 12000});
      assert.notEqual(await method.getAttribute('open'), null);
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
