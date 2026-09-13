// Read-only browser acceptance. Screenshots contain local organization data;
// keep the output private and outside the repository. No writes or model calls.
// Configured display names can refresh using read-only Slack directory calls.
// Usage: node scripts/control-plane-visual.cjs http://127.0.0.1:4321 OUTPUT [--filters]
// Install Playwright separately, or set RESPONDER_PLAYWRIGHT_MODULE to its path.
const { chromium } = require(process.env.RESPONDER_PLAYWRIGHT_MODULE || 'playwright');
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');
const {createCaptureDirectory} = require('./visual-artifacts.cjs');

const origin = new URL(process.argv[2] || 'http://127.0.0.1:4321');
assert(['localhost', '127.0.0.1', '[::1]'].includes(origin.hostname), 'Loopback only');
assert(origin.protocol === 'http:' && !origin.username && !origin.password && origin.pathname === '/', 'Use a local HTTP origin');
assert(process.argv[3], 'Supply a private output directory outside the repository');
let output = path.resolve(process.argv[3]);
const repository = path.resolve(__dirname, '..');
assert(output !== repository && !output.startsWith(repository + path.sep), 'Do not commit organization screenshots');
const filtersOnly = process.argv.includes('--filters');
const routes = filtersOnly ? [['activity-root', '/'], ['episodes', '/activity?state=complete']] : [
  ['activity-root', '/'], ['lab', '/lab'], ['activity', '/activity'],
  ['incident-rooms', '/incident-rooms'], ['failures', '/failures'], ['usage', '/usage'],
  ['schedules', '/schedules'], ['subscriptions', '/subscriptions'],
  ['rules', '/rules'], ['preferences', '/preferences'], ['guidance', '/guidance'],
  ['memory', '/memory'], ['decisions', '/decisions'], ['findings', '/findings'],
  ['calibration', '/calibration'], ['configuration', '/configuration'],
  ['channels', '/channels'], ['repositories', '/repositories'], ['workspaces', '/workspaces'],
  ['journeys', '/manual-tests'], ['card-lab', '/card-lab'],
  ['card-lab-state', '/card-lab/task-card/working'], ['missing-episode', '/timeline/missing']
];
// Pages removed as clean cuts. They must answer 404 without a redirect.
const removedPages = ['decisions', 'calibration', 'journeys', 'card-lab', 'card-lab-state'];

async function connected(page) {
  await page.locator('[data-connection-state="connected"]').waitFor({timeout: 5000});
}

async function checkFilterAlignment(page) {
  // The September 6 filter picker inherited 16px text and zero left padding,
  // beside 14px controls; its heading also used an unrelated size and weight.
  if (!await page.locator('#criterion-state').count()) {
    await page.locator('#request-filter-add').selectOption('state');
    await page.locator('#criterion-state').waitFor();
  }
  const layout = await page.evaluate(() => {
    const properties = selector => {
      const element = document.querySelector(selector);
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return {font: style.font, fontSize: style.fontSize, fontWeight: style.fontWeight,
        paddingLeft: style.paddingLeft, paddingRight: style.paddingRight,
        height: rect.height, centerY: rect.top + rect.height / 2};
    };
    return {picker: properties('#request-filter-add'), value: properties('#criterion-state'),
      heading: properties('.criteria-heading h2'), label: properties('label[for="criterion-state"]')};
  });
  assert.equal(layout.picker.font, layout.value.font, 'Add filter must match criterion typography');
  assert.equal(layout.picker.paddingLeft, layout.value.paddingLeft, 'Add filter text must have the same left inset');
  assert.equal(layout.picker.paddingRight, layout.value.paddingRight, 'Select arrows must have the same inset');
  assert.equal(layout.picker.height, layout.value.height, 'Filter controls must have matching heights');
  assert.equal(layout.heading.fontSize, layout.label.fontSize, 'Filters heading must match filter labels');
  assert.equal(layout.heading.fontWeight, layout.label.fontWeight, 'Filters heading must match label weight');
  assert(Math.abs(layout.heading.centerY - layout.picker.centerY) < 1, 'Filters heading must be vertically centered with its picker');
}

async function discover(page) {
  const absent = [];
  for (const [name, route, selector] of [
    ['episode-detail', '/', '.activity-title[href^="/timeline/"]'],
    ['lab-chat', '/lab', '.lab-directory-list a[href^="/lab/"]'],
    ['channel-detail', '/channels', 'a[href^="/channels/"]'],
    ['incident-room-detail', '/incident-rooms', 'a[href^="/incident-rooms/"]'],
    ['schedule-detail', '/schedules', 'a[href^="/schedules/"]'],
    ['failure-detail', '/failures', 'a[href^="/failures/"]']
  ]) {
    await page.goto(new URL(route, origin).href);
    const link = page.locator(selector).first();
    if (await link.count()) {
      const href = await link.getAttribute('href');
      routes.push([name, href]);
      if (name === 'episode-detail') routes.push(['request-detail', href + '/model-calls']);
    } else absent.push(name);
  }
  return absent;
}

(async () => {
  output = await createCaptureDirectory(output, repository);
  console.log(`Private capture directory: ${output}`);
  const browser = await chromium.launch({headless: true});
  const report = {origin: origin.origin, capturedAt: new Date().toISOString(), absent: [], captures: []};
  try {
    const discovery = await browser.newPage();
    if (!filtersOnly) report.absent = await discover(discovery);
    await discovery.close();
    for (const [width, height] of [[1440, 1000], [390, 844]]) {
      const context = await browser.newContext({viewport: {width, height}, reducedMotion: 'reduce', deviceScaleFactor: 1});
      const page = await context.newPage();
      page.setDefaultTimeout(5000);
      for (const [name, route] of routes) {
        const errors = [];
        const onError = error => errors.push(error.message);
        const onConsole = message => { if (message.type() === 'error') errors.push(message.text()); };
        page.on('pageerror', onError);
        page.on('console', onConsole);
        const file = `${name}-${width}.png`;
        const result = {name, route, width, file, errors};
        try {
          const response = await page.goto(new URL(route, origin).href, {waitUntil: 'domcontentloaded'});
          result.status = response.status();
          result.version = response.headers()['x-responder-version'];
          if (removedPages.includes(name)) {
            assert.equal(result.status, 404, 'Removed pages must return a real 404');
            assert.equal(response.request().redirectedFrom(), null, 'Removed pages must not acquire compatibility redirects');
          } else {
            await connected(page);
            await page.evaluate(() => document.fonts.ready);
            result.layout = await page.evaluate(() => ({
              width: document.documentElement.clientWidth,
              scrollWidth: document.documentElement.scrollWidth,
              composerTop: document.querySelector('.lab-native-composer')?.getBoundingClientRect().top,
              transcriptBottom: document.querySelector('.lab-transcript')?.getBoundingClientRect().bottom
            }));
            assert.equal(result.status, 200);
            assert.equal(await page.locator('a[href="/audit"]').count(), 0, 'The removed Audit page must not return to navigation');
            assert.equal(await page.locator('a[href^="/actions/"]').count(), 0, 'Operator actions must be native buttons, not navigation links');
            for (const label of await page.locator('form[action^="/actions/"] button').allTextContents()) {
              assert(!/(?:…|\.\.\.)$/.test(label.trim()), 'Action labels must not end in ellipses');
            }
            assert(result.layout.scrollWidth <= width, 'Page overflows horizontally');
            if (name === 'activity-root' || name === 'activity') await checkFilterAlignment(page);
            assert.equal(await page.locator('a[href^="/card-lab"], a[href="/manual-tests"]').count(), 0, 'Retired testing pages must not return to navigation');
            assert.equal(await page.locator('.nav-caption', {hasText: 'Testing'}).count(), 0, 'The Testing navigation group was removed');
            if (name === 'lab-chat' && width === 390) assert(result.layout.composerTop >= result.layout.transcriptBottom, 'Composer obscures the conversation');
            if (name === 'repositories') {
              const panels = await page.locator('.repository-card > header').evaluateAll(es => es.map(e => getComputedStyle(e).backgroundColor));
              assert(panels.every(color => color === 'rgba(0, 0, 0, 0)' || color === 'rgb(255, 255, 255)'), 'Repository headings must not inherit the old dark page banner');
            }
            if (name === 'requests') {
              const titles = await page.locator('.activity-title').allTextContents();
              assert(titles.every(title => !/<@[UW][A-Z0-9]+>/.test(title)), 'Slack mentions must be readable in request titles');
            }
            assert.equal(errors.length, 0, 'Browser or CSP errors');
          }
        } catch (error) { result.failure = error.message; }
        await page.screenshot({path: path.join(output, file), animations: 'disabled'});
        await page.screenshot({path: path.join(output, file.replace('.png', '-full.png')), fullPage: true, animations: 'disabled'});
        // Read a mid-page chart at actual viewport size, not a shrunk tall image.
        if (name === 'usage') {
          await page.locator('.token-trend').scrollIntoViewIfNeeded().catch(() => {});
          await page.screenshot({path: path.join(output, `usage-chart-${width}.png`)});
        }
        report.captures.push(result);
        page.off('pageerror', onError);
        page.off('console', onConsole);
        console.log(`${name} ${width}: ${result.failure || 'PASS'}`);
      }
      await context.close();
    }
  } finally {
    await browser.close();
    await fs.writeFile(path.join(output, 'manifest.json'), JSON.stringify(report, null, 2), {mode: 0o600});
  }
  const failed = report.captures.filter(capture => capture.failure);
  console.log(`${report.captures.length} captures; ${failed.length} failures`);
  if (failed.length) process.exitCode = 1;
})().catch(error => {console.error(error.message); process.exitCode = 1;});
