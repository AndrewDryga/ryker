// Read-only filter acceptance against the local control plane. No model or effect calls.
const assert = require('node:assert/strict');
const path = require('node:path');
const {chromium} = require(process.env.RESPONDER_PLAYWRIGHT_MODULE || 'playwright');
const {createCaptureDirectory} = require('./visual-artifacts.cjs');

async function contrast(locator) {
  return locator.evaluateAll(elements => elements.map(element => {
    const rgb = value => value.match(/[\d.]+/g).slice(0, 3).map(Number);
    const luminance = color => rgb(color).map(v => {
      v /= 255; return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
    }).reduce((sum, v, i) => sum + v * [0.2126, 0.7152, 0.0722][i], 0);
    let parent = element;
    while (parent.parentElement && ['rgba(0, 0, 0, 0)', 'transparent'].includes(getComputedStyle(parent).backgroundColor)) parent = parent.parentElement;
    const ink = luminance(getComputedStyle(element).color);
    const paper = luminance(getComputedStyle(parent).backgroundColor);
    return {text: element.textContent.trim(), ratio: (Math.max(ink, paper) + .05) / (Math.min(ink, paper) + .05)};
  }));
}

(async () => {
  const origin = process.argv[2] || 'http://127.0.0.1:4321';
  assert(['127.0.0.1', 'localhost'].includes(new URL(origin).hostname));
  const output = await createCaptureDirectory(process.argv[3] || '/tmp/responder-filters', path.resolve(__dirname, '..'));
  console.log(`Screenshots: ${output}`);
  const browser = await chromium.launch({headless: true});
  try {
    for (const width of [1440, 1024, 390]) {
      const page = await browser.newPage({viewport: {width, height: 1000}, reducedMotion: 'reduce'});
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      const open = async route => {
        const response = await page.goto(origin + route);
        assert.equal(response.status(), 200);
        await page.locator('[data-connection-state=connected]').waitFor();
        await page.evaluate(() => document.fonts.ready);
      };
      await open('/activity?mode=all&usage_profile=emisar&usage_window=30d');
      for (const item of await contrast(page.locator('.usage-drilldown a'))) {
        assert(item.ratio >= 4.5, `${item.text}: contrast ${item.ratio.toFixed(2)} must be at least 4.5`);
      }
      assert.equal(await page.locator('[name="criteria[usage_profile][value]"]').inputValue(), 'emisar');
      assert.equal(await page.locator('[name="criteria[usage_window][value]"]').inputValue(), '30d');
      const profileMatch = page.locator('[name="criteria[usage_profile][match]"]');
      const profileValue = page.locator('[name="criteria[usage_profile][value]"]');
      for (const match of ['missing', 'any']) {
        await profileMatch.selectOption(match);
        await page.waitForFunction(() => document.getElementById('criterion-usage_profile').disabled);
        await profileMatch.selectOption('equals');
        await page.waitForFunction(() => !document.getElementById('criterion-usage_profile').disabled);
      }
      await profileValue.fill('emisar');
      await page.locator('#request-filter-add').selectOption('state');
      await page.locator('[name="criteria[state][value]"]').selectOption('complete');
      await page.locator('#request-criteria button[type=submit]').click();
      await page.waitForURL(url => url.searchParams.get('state') === 'complete');
      assert.equal(new URL(page.url()).searchParams.get('usage_profile'), 'emisar');
      const updated = await page.locator('#responder-shell').getAttribute('data-updated-at');
      await page.waitForFunction(previous => document.querySelector('#responder-shell').dataset.updatedAt !== previous, updated, {timeout: 12000});
      assert.equal(await page.locator('[name="criteria[state][value]"]').inputValue(), 'complete');
      await page.screenshot({path: path.join(output, `requests-${width}.png`)});
      await page.getByRole('link', {name: 'Clear usage filters', exact: true}).click();
      await page.locator('.usage-drilldown').waitFor({state: 'detached'});
      assert.equal(new URL(page.url()).searchParams.get('state'), 'complete');

      for (const [route, status] of [['incident-rooms', 'blocked'], ['schedules', 'paused'], ['subscriptions', 'timed_out'], ['channels', null], ['repositories', null]]) {
        await open(`/${route}?q=emisar${status ? '&status=' + status : ''}`);
        const form = page.locator('form.filter-toolbar');
        assert.equal(await page.locator('main h1').count(), 1, `${route}: the title renders once`);
        assert.equal(await page.locator('main header.page-header .page-heading + p.page-description').count(), 1, `${route}: description under the title`);
        assert.equal(await form.locator('input[name=q]').inputValue(), 'emisar');
        assert.equal(await form.locator('button').count(), 0, `${route}: no Apply button`);
        if (status) {
          const select = form.locator('select[name=status]');
          assert.equal(await select.inputValue(), status);
          assert.notEqual(await select.evaluate(el => getComputedStyle(el).backgroundImage), 'none', `${route}: dropdown arrow must remain visible`);
        }
        assert(await form.getByRole('link', {name: 'Clear filters', exact: true}).isVisible());
        for (const item of await contrast(form.locator('a'))) assert(item.ratio >= 4.5, `${route}: ${item.text} contrast ${item.ratio}`);
        await form.locator('input[name=q]').fill('another search');
        await form.locator('input[name=q]').press('Enter');
        await page.waitForURL(url => url.searchParams.get('q') === 'another search');
        if (status) assert.equal(new URL(page.url()).searchParams.get('status'), status);
        if (status) {
          // A dropdown applies on change; the search it sits beside is kept.
          await page.locator('[data-connection-state=connected]').waitFor();
          await page.locator('form.filter-toolbar select[name=status]').selectOption('');
          await page.waitForURL(url => url.searchParams.get('status') === '' && url.searchParams.get('q') === 'another search');
        }
        const bounds = await page.evaluate(() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]);
        assert(bounds[0] <= bounds[1], `${route} must fit at ${width}`);
        await page.screenshot({path: path.join(output, `${route}-${width}.png`)});
        await page.getByRole('link', {name: 'Clear filters', exact: true}).click();
        await page.waitForURL(url => !url.search);
        assert.equal(await page.locator('form.filter-toolbar input[name=q]').inputValue(), '');
      }
      assert.deepEqual(errors, []);
      console.log(`Filters ${width}: PASS`);
      await page.close();
    }
  } finally {await browser.close();}
})().catch(error => {console.error(error); process.exitCode = 1;});
