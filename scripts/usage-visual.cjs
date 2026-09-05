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
      assert.equal(await page.locator('#usage-profiles h2').textContent(), 'By profile');
      assert.equal(await page.locator('.usage-trend-panel h2').textContent(), 'Token usage over time');
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
      for (const label of ['Conversation Lab', 'Slack app', 'universal']) {
        assert.equal(await page.locator('#usage-people').getByText(label, {exact: true}).count(), 0);
      }
      for (const href of await page.locator('#usage-people .usage-identity a').evaluateAll(es => es.map(e => e.href))) {
        assert.equal(new URL(href).searchParams.get('usage_actor_kind'), 'user');
        assert.notEqual(new URL(href).searchParams.get('usage_source'), 'control_plane');
      }
      const peopleBounds = await page.locator('#usage-people table').evaluate(e => [e.getBoundingClientRect().width, e.parentElement.clientWidth]);
      assert(peopleBounds[0] <= peopleBounds[1], 'The compact people table fits without horizontal scrolling');
      for (const href of await page.locator('#usage-models .usage-identity a').evaluateAll(es => es.map(e => e.href))) {
        assert(new URL(href).searchParams.has('usage_effort'), 'Model drilldown includes effort');
      }
      for (const table of await page.locator('.usage-detail-table').all()) {
        assert.deepEqual(await table.locator('.usage-metric-headings th').allTextContents(), ['Fresh input', 'Cached input', 'Output', 'Reasoning']);
        // Full-height separators must not make Performance look like Output.
        const headerIssues = await table.evaluate(element => {
          const heads = [...element.tHead.rows[0].cells];
          const metrics = [...element.tHead.rows[1].cells];
          const body = [...element.tBodies[0].rows[0].cells];
          const issues = [];
          for (const [headerIndex, bodyIndex] of [[2,2],[3,4],[4,6],[5,7]]) {
            const header = heads[headerIndex], cell = body[bodyIndex];
            const style = getComputedStyle(header);
            if (parseFloat(style.borderLeftWidth) < 1 || style.borderLeftStyle === 'none') issues.push(`${header.textContent}: missing header separator`);
            if (parseFloat(getComputedStyle(cell).borderLeftWidth) < 1) issues.push(`${header.textContent}: missing body separator`);
            if (Math.abs(header.getBoundingClientRect().left - cell.getBoundingClientRect().left) > 1) issues.push(`${header.textContent}: separator misaligned`);
          }
          for (const header of heads.filter(e => e.rowSpan === 2)) {
            if (getComputedStyle(header).verticalAlign !== 'middle') issues.push(`${header.textContent}: standalone heading is not centered`);
          }
          for (const [index, header] of metrics.entries()) {
            const cell = body[index + 2];
            if (getComputedStyle(header).textAlign !== 'right' || getComputedStyle(cell).textAlign !== 'right') issues.push(`${header.textContent}: numbers not right aligned`);
            if (Math.abs(header.getBoundingClientRect().right - cell.getBoundingClientRect().right) > 1) issues.push(`${header.textContent}: heading and values misaligned`);
          }
          return issues;
        });
        assert.deepEqual(headerIssues, [], 'Usage column groups remain separate and aligned');
        for (const value of await table.locator('.usage-token-cell').allTextContents()) {
          assert(/^(?:[\d,.]+[kM]?|—)$/.test(value), `Token cells contain only numbers: ${value}`);
        }
        // The phone table once squeezed model names into the next column.
        const crowdedNames = await table.locator('.usage-identity a').evaluateAll(links => links.filter(link => {
          const cell = link.closest('td');
          return link.getBoundingClientRect().right > cell.getBoundingClientRect().right - parseFloat(getComputedStyle(cell).paddingRight) + 1;
        }).map(link => link.textContent));
        assert.deepEqual(crowdedNames, [], 'Identity labels stay inside their column at every viewport');
      }
      const bounds = await page.evaluate(() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]);
      assert(bounds[0] <= bounds[1], 'No horizontal page overflow');
      await page.screenshot({path: path.join(output, `summary-${width}.png`)});
      await page.screenshot({path: path.join(output, `usage-${width}.png`), fullPage: true});
      await page.locator('#usage-profiles').scrollIntoViewIfNeeded();
      await page.screenshot({path: path.join(output, `profiles-${width}.png`)});
      await page.locator('#usage-models').scrollIntoViewIfNeeded();
      await page.screenshot({path: path.join(output, `models-${width}.png`)});
      const modelViewport = page.locator('#usage-models .table-wrap');
      await modelViewport.evaluate(element => {element.scrollLeft = element.scrollWidth;});
      await page.screenshot({path: path.join(output, `models-metrics-${width}.png`)});
      await modelViewport.evaluate(element => {element.scrollLeft = 0;});
      await page.locator('#usage-people').scrollIntoViewIfNeeded();
      await page.screenshot({path: path.join(output, `people-${width}.png`)});
      const method = page.locator('#cost-method');
      await method.locator('summary').click();
      assert.equal(await method.locator('summary').textContent(), 'Rates used for estimates');
      assert(!/Estimated cost:|Provider-reported cost:|executions/.test(await method.textContent()), 'Rate details must not repeat usage totals');
      const pricingBounds = await page.locator('.usage-pricing-table').evaluate(e => [e.getBoundingClientRect().width, e.parentElement.clientWidth]);
      assert(pricingBounds[0] <= pricingBounds[1], 'Estimate rates fit without horizontal scrolling');
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
      await page.locator('.usage-drilldown a', {hasText: 'Clear usage filters'}).click();
      await page.locator('.usage-drilldown').waitFor({state: 'detached'});
      assert.deepEqual(errors, []);
      console.log(`Usage ${width}: PASS`);
      await page.close();
    }
  } finally {await browser.close();}
  console.log(`Screenshots: ${output}`);
})().catch(error => {console.error(error); process.exitCode = 1;});
