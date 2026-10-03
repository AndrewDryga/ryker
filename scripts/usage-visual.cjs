// Read-only acceptance against a running Ryker console, with private screenshots.
const assert = require('node:assert/strict');
const path = require('node:path');
const {createCaptureDirectory} = require('./visual-artifacts.cjs');
const {chromium} = require(process.env.RYKER_PLAYWRIGHT_MODULE || 'playwright');

// What the cost can be broken down by, in the order the switch offers them.
const breakdowns = [
  ['work-type', 'Work type'],
  ['model', 'Model'],
  ['channel', 'Channel'],
  ['repository', 'Repository'],
  ['person', 'Person'],
  ['account', 'Account'],
];

(async () => {
  const origin = process.argv[2] || 'http://127.0.0.1:4321';
  assert(['127.0.0.1', 'localhost', '[::1]'].includes(new URL(origin).hostname));
  const output = await createCaptureDirectory(process.argv[3] || '/tmp/ryker-usage-visual', path.resolve(__dirname, '..'));
  const browser = await chromium.launch({headless: true});
  try {
    for (const width of [1440, 1024, 390]) {
      const page = await browser.newPage({viewport: {width, height: 1050}, reducedMotion: 'reduce'});
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      page.on('console', message => {if (message.type() === 'error') errors.push(message.text());});

      for (const [by, label] of breakdowns) {
        const response = await page.goto(`${origin}/usage?window=30d&by=${by}`);
        assert.equal(response.status(), 200);
        await page.locator('#ryker-shell[data-connection-state=connected]').waitFor();
        await page.locator('.usage-summary').waitFor();
        await page.evaluate(() => document.fonts.ready);

        assert.deepEqual(await page.locator('.usage-headlines .usage-stat > span').allTextContents(), ['Cost', 'Requests', 'Executions', 'Total tokens']);
        assert.equal(await page.locator('.usage-page > :last-child').getAttribute('id'), 'cost-method');
        assert.equal(await page.locator('.usage-scope [aria-current=page]').textContent(), 'Live work');
        // The local routing model has its own page under Settings › Models.
        assert.equal(await page.locator('#local-routing').count(), 0);

        const section = page.locator('#usage-breakdown');
        assert.deepEqual((await section.locator('.segmented a').allTextContents()).map(text => text.trim()), breakdowns.map(([, name]) => name));
        assert.equal((await section.locator('.segmented a[aria-current=page]').textContent()).trim(), label);

        const rows = section.locator('tbody tr');
        if (by === 'work-type' || by === 'model') assert(await rows.count() > 0, 'Use actual populated execution data');
        if (await rows.count() > 0) {
          assert.deepEqual((await section.locator('thead th').allTextContents()).map(text => text.trim()).slice(1), ['Share of cost', 'Cost', 'Requests', 'Per request', 'Failed runs']);
          // Ranked by cost, most first.
          const costs = (await section.locator('tbody td:nth-child(3)').allTextContents()).map(text => text.trim()).filter(text => text.startsWith('$')).map(text => Number(text.slice(1)));
          assert.deepEqual(costs, [...costs].sort((a, b) => b - a), `${label} rows are ranked by cost`);
          // A name opens the requests behind it; the line under it is quiet.
          for (const href of await section.locator('.usage-name a').evaluateAll(links => links.map(link => link.getAttribute('href')))) {
            assert(href.startsWith('/activity?') || ['/memory/learning', '/feedback/fix', '/repositories'].includes(href), href);
          }
          const tones = await rows.first().evaluate(row => {
            const name = row.querySelector('.usage-name a');
            const line = row.querySelector('small');
            return line && [getComputedStyle(name).color, getComputedStyle(line).color, parseFloat(getComputedStyle(name).fontSize), parseFloat(getComputedStyle(line).fontSize)];
          });
          if (tones) {
            assert.notEqual(tones[0], tones[1], 'The line under a name is quieter than the name');
            assert(tones[3] < tones[2], 'The line under a name is smaller than the name');
          }
        }

        const bounds = await page.evaluate(() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]);
        assert(bounds[0] <= bounds[1], `No horizontal page overflow (${label}, ${width}px)`);
        if (width > 1000) {
          const table = await section.locator('.kit-table-wrap').evaluateAll(wraps => wraps.map(wrap => [wrap.scrollWidth, wrap.clientWidth]));
          for (const [scroll, client] of table) assert(scroll <= client, `The ${label} table fits without scrolling at ${width}px`);
        }

        await section.scrollIntoViewIfNeeded();
        await section.screenshot({path: path.join(output, `${by}-${width}.png`)});
      }

      await page.goto(`${origin}/usage?window=30d`);
      await page.screenshot({path: path.join(output, `usage-${width}.png`), fullPage: true});
      const method = page.locator('#cost-method');
      await method.locator('summary').click();
      assert.equal(await method.locator('summary').textContent(), 'Rates used for estimates');
      assert(!/Estimated cost:|Provider-reported cost:|executions/.test(await method.textContent()), 'Rate details must not repeat usage totals');
      const pricingBounds = await page.locator('.usage-pricing-table').evaluate(e => [e.getBoundingClientRect().width, e.parentElement.clientWidth]);
      assert(pricingBounds[0] <= pricingBounds[1], 'Estimate rates fit without horizontal scrolling');

      const link = page.locator('#usage-breakdown .usage-name a[href^="/activity?"]').first();
      await link.click();
      // Activity opens filtered to what the row stands for, said in its filter chips.
      await page.locator('.filter-chip[data-filter^=usage_]').first().waitFor();
      assert(await page.locator('#activity-stream article').count() > 0, 'A name finds its actual requests');
      assert.deepEqual(errors, []);
      console.log(`Usage ${width}: PASS`);
      await page.close();
    }
  } finally {await browser.close();}
  console.log(`Screenshots: ${output}`);
})().catch(error => {console.error(error); process.exitCode = 1;});
