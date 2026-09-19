// Read-only browser acceptance. Screenshots contain local organization data;
// keep the output private and outside the repository. No writes or model calls.
// Configured display names can refresh using read-only Slack directory calls.
// Usage: node scripts/control-plane-visual.cjs http://127.0.0.1:4321 OUTPUT [--filters]
// Install Playwright separately, or set RYKER_PLAYWRIGHT_MODULE to its path.
const { chromium } = require(process.env.RYKER_PLAYWRIGHT_MODULE || 'playwright');
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
  ['activity-root', '/'], ['conversations', '/conversations'], ['lab-retired', '/lab'], ['activity', '/activity'],
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
const removedPages = ['decisions', 'calibration', 'journeys', 'card-lab', 'card-lab-state', 'lab-retired'];

async function connected(page) {
  await page.locator('[data-connection-state="connected"]').waitFor({timeout: 5000});
}

async function checkFilterToolbar(page, width) {
  // Until 2026-09-19 the Activity filters were a separate band: an "Add filter…"
  // select first, Is/Any/Not recorded operators and an Apply button. They are now
  // one toolbar whose controls share one height and, on a wide screen, one line.
  const rows = await page.evaluate(() => Array.from(document.querySelectorAll('.search-field, #activity-mode, #filter-add, .filter-chip'))
    .map(element => { const rect = element.getBoundingClientRect(); return {height: Math.round(rect.height), center: Math.round(rect.top + rect.height / 2)}; }));
  assert(rows.length >= 3, 'The toolbar holds search, work mode and + Filter');
  assert(rows.every(row => row.height === rows[0].height), 'Toolbar controls share one height');
  if (width > 800) assert(rows.every(row => row.center === rows[0].center), 'Toolbar controls sit on one line');
  await page.locator('#filter-add').click();
  await page.locator('#filter-popover').waitFor();
  assert(await page.evaluate(() => Boolean(document.activeElement?.closest('#filter-popover'))), 'Focus moves into the filter menu');
  await page.keyboard.press('Escape');
  await page.locator('#filter-popover').waitFor({state: 'detached'});
  assert(await page.evaluate(() => document.activeElement?.id === 'filter-add'), 'Escape returns focus to + Filter');
}

async function discover(page) {
  const absent = [];
  for (const [name, route, selector] of [
    ['episode-detail', '/', '.activity-title[href^="/timeline/"]'],
    ['conversation', '/conversations', '.lab-directory-list a[href^="/conversations/"]'],
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
          result.version = response.headers()['x-ryker-version'];
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
              composerBottom: document.querySelector('.lab-native-composer')?.getBoundingClientRect().bottom,
              transcriptBottom: document.querySelector('.lab-transcript')?.getBoundingClientRect().bottom
            }));
            assert.equal(result.status, 200);
            assert.equal(await page.locator('a[href="/audit"]').count(), 0, 'The removed Audit page must not return to navigation');
            assert.equal(await page.locator('a[href^="/actions/"]').count(), 0, 'Operator actions must be native buttons, not navigation links');
            for (const label of await page.locator('form[action^="/actions/"] button').allTextContents()) {
              assert(!/(?:…|\.\.\.)$/.test(label.trim()), 'Action labels must not end in ellipses');
            }
            assert(result.layout.scrollWidth <= width, 'Page overflows horizontally');
            if (name === 'activity-root' || name === 'activity') await checkFilterToolbar(page, width);
            assert.equal(await page.locator('a[href^="/card-lab"], a[href="/manual-tests"]').count(), 0, 'Retired testing pages must not return to navigation');
            assert.equal(await page.locator('.nav-caption', {hasText: 'Testing'}).count(), 0, 'The Testing navigation group was removed');
            if (name === 'conversation' && width === 390) assert(result.layout.composerTop >= result.layout.transcriptBottom, 'Composer obscures the conversation');
            if (name === 'conversation' && width > 800) {
              // On 2026-09-19 the composer sat under the top bar of a new conversation and
              // jumped to the bottom once the first message opened the conversation.
              const draft = report.captures.find(capture => capture.name === 'conversations' && capture.width === width);
              assert(Math.abs(result.layout.composerBottom - draft?.layout?.composerBottom) < 1, 'The composer must not move between a new and an open conversation');
            }
            if (['schedules', 'channels', 'repositories', 'workspaces'].includes(name)) {
              // One shell: the title once, then the page's own column with its comparison
              // table stacked into label/value rows on a phone instead of scrolling sideways.
              assert.equal(await page.locator('main h1').count(), 1, `${name}: the title renders once`);
              assert.equal(await page.locator('main .repository-card, main .table-wrap, main .page-description h2').count(), 0, `${name}: no legacy card or table-wrap layout`);
              const cell = page.locator('main table.data-table tbody td:not(.row-identity)').first();
              if (await cell.count()) {
                assert.equal(await cell.evaluate(e => getComputedStyle(e).display), width <= 760 ? 'grid' : 'table-cell', `${name}: table rows stack only on narrow screens`);
              }
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
