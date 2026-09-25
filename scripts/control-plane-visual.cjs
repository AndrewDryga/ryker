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
  ['rules', '/rules'], ['preferences', '/preferences'], ['guidance', '/guidance'], ['instructions', '/instructions'],
  ['memory', '/memory'], ['decisions', '/decisions'], ['findings', '/findings'],
  ['calibration', '/calibration'], ['configuration', '/configuration'],
  ['channels', '/channels'], ['repositories', '/repositories'], ['workspaces', '/workspaces'],
  ['setup', '/setup'], ['integrations', '/integrations'], ['integrations-slack', '/integrations/slack'],
  ['integrations-github', '/integrations/github'], ['integrations-emisar', '/integrations/emisar'],
  ['integrations-webhooks', '/integrations/webhooks'], ['settings-models', '/settings/models'],
  ['settings-retention', '/settings/retention'], ['settings-prices', '/settings/prices'],
  ['settings-advanced', '/settings/advanced'],
  ['journeys', '/manual-tests'], ['card-lab', '/card-lab'],
  ['card-lab-state', '/card-lab/task-card/working'], ['missing-episode', '/timeline/missing']
];
// Pages removed as clean cuts. They must answer 404 without a redirect.
const removedPages = ['decisions', 'calibration', 'configuration', 'journeys', 'card-lab', 'card-lab-state', 'lab-retired'];
const sharedPageGutterPages = new Set([
  'activity-root', 'activity', 'incident-rooms', 'failures', 'usage', 'schedules',
  'subscriptions', 'rules', 'preferences', 'guidance', 'instructions', 'memory',
  'findings', 'channels', 'repositories', 'workspaces', 'setup', 'integrations',
  'integrations-slack', 'integrations-github', 'integrations-emisar',
  'integrations-webhooks', 'settings-models', 'settings-retention',
  'settings-prices', 'settings-advanced'
]);

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
  if (await page.locator('#filter-add').isDisabled()) {
    assert(await page.locator('#activity-filters-search').isDisabled(), 'Empty activity disables search');
    assert(await page.locator('#activity-mode').isDisabled(), 'Empty activity disables the work-mode filter');
    assert.equal(await page.locator('#request-filters button:not([disabled])').count(), 0, 'Empty activity disables filter chips and actions');
    assert.equal(await page.locator('.ui-tabs a').count(), 0, 'Empty activity disables status filters');
    return;
  }
  await page.locator('#filter-add').click();
  await page.locator('#filter-popover').waitFor();
  assert(await page.evaluate(() => Boolean(document.activeElement?.closest('#filter-popover'))), 'Focus moves into the filter menu');
  await page.keyboard.press('Escape');
  await page.locator('#filter-popover').waitFor({state: 'detached'});
  assert(await page.evaluate(() => document.activeElement?.id === 'filter-add'), 'Escape returns focus to + Filter');
  // Release 7d760b5d applied an empty value in the browser (LiveView overwrote it
  // with the clicked button's own value) while every server-side test passed.
  if (await page.locator('.filter-chip[data-filter=transport]').count()) return;
  await page.locator('#filter-add').click();
  // A field opens its values beside the list, never in its place (Andrew, 2026-09-19).
  const transport = page.locator('#filter-popover .filter-field[data-field=transport]');
  if (width <= 800) await transport.click();
  else await transport.hover();
  await page.locator('#filter-values-transport').waitFor();
  if (width > 800) {
    const beside = await page.evaluate(() => {
      const list = document.querySelector('.filter-fields').getBoundingClientRect();
      const values = document.querySelector('#filter-values-transport').getBoundingClientRect();
      return values.left >= list.right - 1 || values.right <= list.left + 1;
    });
    assert(beside, 'A field opens its values beside the list');
  }
  await page.locator('#filter-values-transport button[phx-value-choice=slack]').click();
  await page.locator('.filter-chip[data-filter=transport]').waitFor();
  assert(new URL(page.url()).searchParams.get('transport') === 'slack', 'Choosing a value applies it');
  await page.locator('.filter-chip[data-filter=transport] .filter-chip-remove').click();
  await page.locator('.filter-chip[data-filter=transport]').waitFor({state: 'detached'});
}

async function checkSharedFilterControls(page, width) {
  const controls = await page.evaluate(() => Array.from(document.querySelectorAll(
    '.filter-toolbar .search-field, .filter-toolbar select, .filter-toolbar .filter-add'
  )).filter(element => element.getBoundingClientRect().height > 0).map(element => {
    const style = getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return {
      primary: element.matches('.search-field, .filter-primary, #activity-mode, .filter-add'),
      height: Math.round(rect.height),
      center: Math.round(rect.top + rect.height / 2),
      borderWidth: style.borderWidth,
      borderStyle: style.borderStyle,
      borderColor: style.borderColor,
      borderRadius: style.borderRadius,
      fontSize: style.fontSize,
      lineHeight: style.lineHeight
    };
  }));
  if (!controls.length) return;
  for (const control of controls) {
    assert.equal(control.height, 44, 'Filter controls use the shared 44px height');
    assert.equal(control.borderWidth, '1px', 'Filter controls use the shared border width');
    assert.equal(control.borderStyle, 'solid', 'Filter controls use a solid border');
    assert.equal(control.borderColor, controls[0].borderColor, 'Filter controls use the same border color');
    assert.equal(control.borderRadius, '8px', 'Filter controls use the shared corner radius');
    assert.equal(control.fontSize, '14px', 'Filter controls use the shared type size');
    assert.equal(control.lineHeight, '20px', 'Filter controls use the shared text line height');
  }
  const primary = controls.filter(control => control.primary);
  if (width > 800) assert(primary.every(control => control.center === primary[0].center), 'Filter controls sit on one baseline');
}

async function checkKeyboardFocus(page) {
  await page.evaluate(() => document.activeElement?.blur());
  await page.keyboard.press('Tab');
  const focus = await page.evaluate(() => {
    const element = document.activeElement;
    const rect = element?.getBoundingClientRect();
    const style = element && getComputedStyle(element);
    return {
      interactive: Boolean(element?.matches('a[href], button, input, select, textarea, summary, [tabindex]:not([tabindex="-1"])')),
      visible: Boolean(rect && rect.width > 0 && rect.height > 0),
      indicated: Boolean(style && ((style.outlineStyle !== 'none' && style.outlineWidth !== '0px') || style.boxShadow !== 'none'))
    };
  });
  assert(focus.interactive && focus.visible, 'Tab reaches a visible interactive control');
  assert(focus.indicated, 'Keyboard focus has a visible indicator');
}

async function checkSettingsPage(page, name) {
  const title = (await page.locator('main h1').first().textContent()).trim();
  assert.equal(await page.getByRole('heading', {name: title, exact: true}).count(), 1, `${name}: the page title renders once`);

  if (name === 'integrations-emisar' && await page.getByText('Not connected', {exact: true}).count()) {
    const form = page.locator('form[phx-submit="connect-emisar"]');
    assert.equal(await form.count(), 1, 'The first Emisar connection form is visible');
    assert.equal(await form.locator('xpath=ancestor::details').count(), 0, 'The first Emisar connection is not hidden in a disclosure');
    assert.equal(await form.locator('input[name="connection[ref]"], input[name="connection[display_name]"]').count(), 0, 'Emisar derives internal identity instead of asking for it');
  }
}

async function checkSharedPageGutter(page, width) {
  const gutter = await page.evaluate(() => {
    const workspace = document.querySelector('.app-workspace')?.getBoundingClientRect();
    const title = document.querySelector('main h1')?.getBoundingClientRect();
    return workspace && title ? Math.round(title.left - workspace.left) : null;
  });
  const expected = width > 800 ? 32 : width <= 600 ? 16 : 20;
  assert.equal(gutter, expected, 'Page titles use the shared responsive gutter');
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
    } else absent.push(name);
  }
  return absent;
}

(async () => {
  output = await createCaptureDirectory(output, repository);
  console.log(`Private capture directory: ${output}`);
  const browser = await chromium.launch({
    headless: true,
    executablePath: process.env.RYKER_PLAYWRIGHT_EXECUTABLE || undefined
  });
  const report = {origin: origin.origin, capturedAt: new Date().toISOString(), absent: [], captures: []};
  try {
    const discovery = await browser.newPage();
    if (!filtersOnly) report.absent = await discover(discovery);
    await discovery.close();
    const viewports = [
      {width: 1440, height: 1000, label: '1440', mode: 'desktop', deviceScaleFactor: 1},
      // Browser zoom at 200% gives a 1440px display a 720px CSS viewport.
      {width: 720, height: 500, label: 'zoom200', mode: 'zoom-200', deviceScaleFactor: 2},
      {width: 390, height: 844, label: '390', mode: 'mobile', deviceScaleFactor: 1},
      {width: 320, height: 720, label: '320', mode: 'minimum', deviceScaleFactor: 1}
    ];
    for (const {width, height, label, mode, deviceScaleFactor} of viewports) {
      const context = await browser.newContext({viewport: {width, height}, reducedMotion: 'reduce', deviceScaleFactor});
      const page = await context.newPage();
      page.setDefaultTimeout(5000);
      for (const [name, route] of routes) {
        const errors = [];
        const onError = error => errors.push(error.message);
        const onConsole = message => { if (message.type() === 'error') errors.push(message.text()); };
        page.on('pageerror', onError);
        page.on('console', onConsole);
        const file = `${name}-${label}.png`;
        const result = {name, route, width, mode, file, errors};
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
            if (sharedPageGutterPages.has(name)) await checkSharedPageGutter(page, width);
            await checkSharedFilterControls(page, width);
            await checkKeyboardFocus(page);
            if (/^(setup|integrations|settings)/.test(name)) await checkSettingsPage(page, name);
            if (name === 'activity-root' || name === 'activity') await checkFilterToolbar(page, width);
            assert.equal(await page.locator('a[href^="/card-lab"], a[href="/manual-tests"]').count(), 0, 'Retired testing pages must not return to navigation');
            assert.equal(await page.locator('.nav-caption', {hasText: 'Testing'}).count(), 0, 'The Testing navigation group was removed');
            if (name === 'conversation' && width <= 390) assert(result.layout.composerTop >= result.layout.transcriptBottom, 'Composer obscures the conversation');
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
          await page.screenshot({path: path.join(output, `usage-chart-${label}.png`)});
        }
        report.captures.push(result);
        page.off('pageerror', onError);
        page.off('console', onConsole);
        console.log(`${name} ${label}: ${result.failure || 'PASS'}`);
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
