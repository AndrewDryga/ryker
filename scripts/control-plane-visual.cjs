// Read-only browser acceptance. Screenshots contain local organization data;
// keep the output private and outside the repository. No writes or model calls.
// Configured display names can refresh using read-only Slack directory calls.
// Usage: RYKER_SIGN_IN_LINK=$(scripts/compose.sh sign-in) \
//   node scripts/control-plane-visual.cjs http://127.0.0.1:4321 OUTPUT [--filters]
// Install Playwright separately, or set RYKER_PLAYWRIGHT_MODULE to its path.
const { chromium } = require(process.env.RYKER_PLAYWRIGHT_MODULE || 'playwright');
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');
const {createCaptureDirectory} = require('./visual-artifacts.cjs');
const {liveRoutes} = require('./visual-routes.cjs');
const {signedInState, signOut} = require('./visual-sign-in.cjs');

const origin = new URL(process.argv[2] || 'http://127.0.0.1:4321');
assert(['localhost', '127.0.0.1', '[::1]'].includes(origin.hostname), 'Loopback only');
assert(origin.protocol === 'http:' && !origin.username && !origin.password && origin.pathname === '/', 'Use a local HTTP origin');
assert(process.argv[3], 'Supply a private output directory outside the repository');
let output = path.resolve(process.argv[3]);
const repository = path.resolve(__dirname, '..');
assert(output !== repository && !output.startsWith(repository + path.sep), 'Do not commit organization screenshots');
const filtersOnly = process.argv.includes('--filters');
const routeName = route => route === '/' ? 'activity-root' : route.slice(1).replace(/\//g, '-');
// Every live route the router declares, read from lib/ryker/control_plane/web_router.ex
// so this list cannot drift from the product; detail routes are discovered from real rows.
const livePages = liveRoutes().map(route => [routeName(route), route]);
// Pages removed as clean cuts. They must answer 404 without a redirect and never
// return to navigation.
const removedRoutes = [
  '/audit', '/calibration', '/card-lab', '/card-lab/task-card/working', '/configuration', '/decisions',
  '/findings', '/guidance', '/lab', '/manual-tests', '/preferences', '/subscriptions', '/workspaces'
];
const removedPages = removedRoutes.map(routeName);
const removedNavigation = [...removedRoutes.map(route => `a[href="${route}"]`), 'a[href^="/card-lab"]'].join(', ');
const routes = filtersOnly ? [['activity-root', '/'], ['episodes', '/activity?state=complete']] : [
  ...livePages, ['missing-episode', '/timeline/missing'], ...removedRoutes.map(route => [routeName(route), route])
];
// Every live page but the conversation workspace shares the page-title gutter.
const sharedPageGutterPages = new Set(livePages.map(([name]) => name).filter(name => name !== 'conversations'));

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
    assert.equal(control.fontSize, '16px', 'Filter controls use the shared type size');
    assert.equal(control.lineHeight, '23px', 'Filter controls use the shared text line height');
  }
  const primary = controls.filter(control => control.primary);
  if (width > 800) assert(primary.every(control => control.center === primary[0].center), 'Filter controls sit on one baseline');
}

// Andrew, 2026-11-20: "make sure all our pages have standard width and layout". Every page's
// header and its top-level cards and lists share one left edge and one width, whichever page
// box draws them. Chat keeps a conversation column, and Usage sets panels side by side.
async function checkStandardColumn(page, name) {
  if (['conversations', 'conversation', 'lab', 'usage'].includes(name)) return;
  const blocks = await page.evaluate(() => {
    const pick = '.page-header, .kit-card, .kit-form-card, .entity-list, .setup';
    const main = document.querySelector('main');
    if (!main) return [];
    const found = [];
    for (const element of main.querySelectorAll(pick)) {
      if (element.parentElement && element.parentElement.closest(pick)) continue;
      const rect = element.getBoundingClientRect();
      if (rect.width === 0 || rect.height === 0) continue;
      found.push({what: element.className.toString().split(' ')[0], left: Math.round(rect.left), width: Math.round(rect.width)});
    }
    return found;
  });
  if (blocks.length < 2) return;
  const [column] = blocks;
  for (const block of blocks) {
    assert(Math.abs(block.left - column.left) <= 1, `${block.what} starts at ${block.left}px, the page's column at ${column.left}px`);
    assert(Math.abs(block.width - column.width) <= 1, `${block.what} is ${block.width}px wide, the page's column ${column.width}px`);
  }
}

// Andrew, 2026-11-20, of an environment's Remove environment card: "button outside of block".
// A long description could squeeze a card's actions until its button crossed the card's edge,
// which no page-wide overflow check sees.
async function checkControlsInsideCards(page) {
  const outside = await page.evaluate(() => {
    const found = [];
    for (const card of document.querySelectorAll('.kit-card')) {
      const box = card.getBoundingClientRect();
      if (box.width === 0) continue;
      for (const control of card.querySelectorAll('button, a.ui-button, select, input:not([type=hidden])')) {
        const rect = control.getBoundingClientRect();
        if (rect.width === 0 || rect.height === 0) continue;
        if (rect.left < box.left - 0.5 || rect.right > box.right + 0.5) {
          found.push(`${control.textContent.trim().slice(0, 40) || control.tagName} in ${card.getAttribute('aria-label') || card.id || 'a card'}`);
        }
      }
    }
    return found;
  });
  assert.deepEqual(outside, [], 'A control crosses the edge of its card');
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

  // Connecting an account happens on a page of its own (2026-10-01), which the Emisar page
  // leads to while none is connected.
  if (name === 'integrations-emisar' && await page.getByText('Not connected', {exact: true}).count()) {
    assert.equal(await page.locator('a[href="/integrations/emisar/new"]').count() > 0, true, 'The Emisar page leads to connecting an account');
  }

  if (name === 'integrations-emisar-new') {
    const form = page.locator('form[phx-submit="connect-emisar"]');
    assert.equal(await form.count(), 1, 'The Emisar connection form is visible');
    assert.equal(await form.locator('xpath=ancestor::details').count(), 0, 'The Emisar connection is not hidden in a disclosure');
    assert.equal(await form.locator('input[name="connection[ref]"]').count(), 0, 'Emisar derives internal identity instead of asking for it');
  }
}

// These controls used to sit below the text they belong to. Measure the rendered positions.
async function checkCopyBlocks(page) {
  const step = page.locator('#github-app');
  if (!await step.count()) return;
  const open = await step.evaluate(element => element.open);
  if (!open) await step.locator('summary').first().click();
  try {
    const block = step.locator('.copy-block').filter({has: page.getByRole('button', {name: 'Copy webhook URL'})});
    const aligned = await block.evaluate(element => {
      const code = element.querySelector('pre').getBoundingClientRect();
      const button = element.querySelector('[data-copy-block]').getBoundingClientRect();
      return Math.abs(code.top - button.top) <= 1 && code.right <= button.left + 1;
    });
    assert(aligned, 'The copy button sits beside the code within the same block');
  } finally {
    if (!open) await step.locator('summary').first().click();
  }
}

async function checkStorageFigures(page) {
  // Definition-list table padding used to indent every storage value 16px past its label.
  const indents = await page.locator('.storage-figures > div').evaluateAll(figures =>
    figures.map(figure => {
      const x = element => {
        const range = document.createRange();
        range.selectNodeContents(element);
        return range.getBoundingClientRect().left;
      };
      return x(figure.querySelector('dd')) - x(figure.querySelector('dt'));
    })
  );
  assert(indents.every(indent => Math.abs(indent) <= 1), 'Storage values align with their labels');
}

async function checkChannelHeading(page) {
  const heading = page.locator('.page-title-line:has(.page-title-link)');
  if (!await heading.count()) return;
  const aligned = await heading.evaluate(element => {
    const box = selector => element.querySelector(selector)?.getBoundingClientRect();
    const label = box('h1'), icon = box('.page-title-external'), state = box('.state-word');
    const middle = rect => rect.top + rect.height / 2;
    return Math.abs(middle(label) - middle(icon)) <= 1 &&
      (!state || state.top >= label.bottom || Math.abs(middle(label) - middle(state)) <= 1);
  });
  assert(aligned, 'Channel title, external link icon and status align vertically');
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
    ['episode-detail', '/', '#activity-stream .entity-name a[href^="/timeline/"]'],
    ['conversation', '/conversations', '.lab-directory-list a[href^="/conversations/"]'],
    ['channel-detail', '/channels', 'a[href^="/channels/"]'],
    ['environment-detail', '/environments', '.entity-name a[href^="/environments/"]'],
    ['repository-detail', '/repositories', '.entity-name a[href^="/repositories/"]'],
    ['incident-room-detail', '/incident-rooms', 'a[href^="/incident-rooms/"]'],
    ['schedule-detail', '/schedules', 'a[href^="/schedules/"]'],
    ['failure-detail', '/failures', 'a[href^="/failures/"]']
  ]) {
    await page.goto(new URL(route, origin).href);
    await connected(page);
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
  let storageState;
  try {
    storageState = await signedInState(browser, origin);
    const discovery = await browser.newPage({storageState});
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
      const context = await browser.newContext({viewport: {width, height}, reducedMotion: 'reduce', deviceScaleFactor, storageState});
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
            // A record that is not there reads "Not found" with a real 404 (2026-09-26).
            assert.equal(result.status, name === 'missing-episode' ? 404 : 200);
            assert.equal(await page.locator(removedNavigation).count(), 0, 'Removed pages must not return to navigation');
            assert.equal(await page.locator('a[href^="/actions/"]').count(), 0, 'Operator actions must be native buttons, not navigation links');
            for (const label of await page.locator('form[action^="/actions/"] button').allTextContents()) {
              assert(!/(?:…|\.\.\.)$/.test(label.trim()), 'Action labels must not end in ellipses');
            }
            assert(result.layout.scrollWidth <= width, 'Page overflows horizontally');
            if (sharedPageGutterPages.has(name)) await checkSharedPageGutter(page, width);
            await checkSharedFilterControls(page, width);
            await checkControlsInsideCards(page);
            await checkStandardColumn(page, name);
            await checkKeyboardFocus(page);
            if (/^(setup|integrations|settings)/.test(name)) await checkSettingsPage(page, name);
            if (name === 'skills-catalog-install') {
              const github = await page.locator('#install-skill-github').boundingBox();
              const markdown = await page.locator('#install-skill-paste').boundingBox();
              assert(github && markdown && markdown.y >= github.y + github.height,
                'The Markdown installer must sit below the GitHub installer at every width');
            }
            if (name === 'activity-root' || name === 'activity') await checkFilterToolbar(page, width);
            assert.equal(await page.locator('.nav-caption', {hasText: 'Testing'}).count(), 0, 'The Testing navigation group was removed');
            if (name === 'conversation' && width <= 390) assert(result.layout.composerTop >= result.layout.transcriptBottom, 'Composer obscures the conversation');
            if (name === 'conversation' && width > 800) {
              // On 2026-09-19 the composer sat under the top bar of a new conversation and
              // jumped to the bottom once the first message opened the conversation.
              const draft = report.captures.find(capture => capture.name === 'conversations' && capture.width === width);
              assert(Math.abs(result.layout.composerBottom - draft?.layout?.composerBottom) < 1, 'The composer must not move between a new and an open conversation');
            }
            if (name === 'working-copies') await checkStorageFigures(page);
            if (name === 'channel-detail') await checkChannelHeading(page);
            if (name === 'integrations-github') await checkCopyBlocks(page);
            if (['schedules', 'channels', 'repositories', 'working-copies'].includes(name)) {
              // One shell: the title once, then the page's own column with its comparison
              // table stacked into label/value rows on a phone instead of scrolling sideways.
              assert.equal(await page.locator('main h1').count(), 1, `${name}: the title renders once`);
              assert.equal(await page.locator('main .repository-card, main .table-wrap, main .page-description h2').count(), 0, `${name}: no legacy card or table-wrap layout`);
              const cell = page.locator('main table.data-table tbody td:not(.row-identity)').first();
              if (await cell.count()) {
                assert.equal(await cell.evaluate(e => getComputedStyle(e).display), width <= 760 ? 'grid' : 'table-cell', `${name}: table rows stack only on narrow screens`);
              }
            }
            if (name === 'activity-root' || name === 'activity') {
              const titles = await page.locator('.activity-title').allTextContents();
              assert(titles.every(title => !/<@[UW][A-Z0-9]+>/.test(title)), 'Slack mentions must be readable in activity titles');
            }
            // The browser reports a page's own 404 as a failed load; that is the answer, not an error.
            const pageErrors = name === 'missing-episode' ? errors.filter(error => !/status of 404/.test(error)) : errors;
            assert.equal(pageErrors.length, 0, 'Browser or CSP errors');
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
    await signOut(browser, origin, storageState);
    await browser.close();
    await fs.writeFile(path.join(output, 'manifest.json'), JSON.stringify(report, null, 2), {mode: 0o600});
  }
  const failed = report.captures.filter(capture => capture.failure);
  console.log(`${report.captures.length} captures; ${failed.length} failures`);
  if (failed.length) process.exitCode = 1;
})().catch(error => {console.error(error.message); process.exitCode = 1;});
