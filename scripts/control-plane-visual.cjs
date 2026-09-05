// Read-only browser acceptance. Screenshots contain local organization data;
// keep the output private and outside the repository. No writes or model calls.
// Configured display names can refresh using read-only Slack directory calls.
// Usage: node scripts/control-plane-visual.cjs http://127.0.0.1:4321 OUTPUT [--cards]
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
const allCards = process.argv.includes('--cards');
const routes = [
  ['requests', '/'], ['lab', '/lab'], ['episodes', '/episodes'],
  ['incidents', '/incidents'], ['failures', '/failures'], ['usage', '/usage'],
  ['schedules', '/schedules'], ['subscriptions', '/subscriptions'],
  ['memory', '/memory'], ['decisions', '/decisions'], ['findings', '/findings'],
  ['calibration', '/calibration'], ['configuration', '/configuration'],
  ['channels', '/channels'], ['repositories', '/repositories'], ['workspaces', '/workspaces'],
  ['journeys', '/manual-tests'], ['task-working', '/card-lab/task-card/working'],
  ['task-goals', '/card-lab/task-card/recorded-goals'], ['missing-episode', '/episodes/missing']
];

async function connected(page) {
  await page.locator('[data-connection-state="connected"]').waitFor({timeout: 5000});
}

async function discover(page) {
  const absent = [];
  for (const [name, route, selector] of [
    ['episode-detail', '/', '.activity-title[href^="/episodes/"]'],
    ['lab-chat', '/lab', '.lab-directory-list a[href^="/lab/"]'],
    ['channel-detail', '/channels', 'a[href^="/channels/"]'],
    ['incident-detail', '/incidents', 'a[href^="/incidents/"]'],
    ['schedule-detail', '/schedules', 'a[href^="/schedules/"]'],
    ['failure-detail', '/failures', 'a[href^="/failures/"]']
  ]) {
    await page.goto(new URL(route, origin).href);
    const link = page.locator(selector).first();
    if (await link.count()) {
      const href = await link.getAttribute('href');
      routes.push([name, href]);
      if (name === 'episode-detail') routes.push(['request-detail', href + '/requests']);
    } else absent.push(name);
  }
  if (allCards) {
    await page.goto(new URL('/card-lab/task-card/working', origin).href);
    await connected(page);
    const families = await page.locator('.specimen-catalog a[data-family]').evaluateAll(es => es.map(e => e.dataset.family));
    for (const family of families) {
      await page.locator(`.specimen-catalog a[data-family="${family}"]`).click();
      await page.waitForURL(url => url.pathname.split('/')[2] === family);
      const states = await page.locator('#card-state-picker a').evaluateAll(es => es.map(e => e.dataset.state));
      for (const state of states) routes.push([`card-${family}-${state}`, `/card-lab/${family}/${state}`]);
    }
  }
  return absent;
}

async function interactions(page) {
  await page.goto(new URL('/card-lab/task-card/working', origin).href);
  await connected(page);
  await page.locator('#card-state-picker > summary').click();
  await page.locator('#card-state-picker a[data-state="recorded-goals"]').click();
  await page.waitForURL('**/card-lab/task-card/recorded-goals');
  await page.locator('.preview-width a', {hasText: 'Compact'}).click();
  await page.locator('.specimen-canvas.compact').waitFor();
  await page.locator('#card-state-picker > summary').click();
  await page.locator('#card-state-picker a[data-state="working"]').click();
  await page.waitForURL('**/working?width=compact');
  await page.locator('button[phx-value-id="next-recorded"]').click();
  await page.waitForURL('**/working-validation');
  await page.locator('.specimen-provenance summary').click();
  await page.locator('.specimen-provenance details[open]').waitFor();
  const updatedAt = await page.locator('#responder-shell').getAttribute('data-updated-at');
  await page.waitForFunction(previous => document.querySelector('#responder-shell')?.dataset.updatedAt !== previous, updatedAt, {timeout: 12000});
  // The automatic projection update must preserve the open disclosure.
  await page.locator('.specimen-provenance details[open]').waitFor();
  await page.locator('a', {hasText: 'Block Kit payload'}).click();
  await page.locator('.specimen-payload').waitFor();
  await page.screenshot({path: path.join(output, 'interaction-payload.png')});
  await page.locator('.specimen-catalog a[data-family="incident-room"]').click();
  await page.waitForURL(url => url.pathname === '/card-lab/incident-room/provisioning');
  await page.locator('.specimen-catalog a[aria-current="page"]').focus();
  await page.screenshot({path: path.join(output, 'interaction-keyboard-focus.png')});
}

(async () => {
  output = await createCaptureDirectory(output, repository);
  console.log(`Private capture directory: ${output}`);
  const browser = await chromium.launch({headless: true});
  const report = {origin: origin.origin, capturedAt: new Date().toISOString(), absent: [], captures: [], interactionError: null};
  try {
    const discovery = await browser.newPage();
    report.absent = await discover(discovery);
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
          await connected(page);
          await page.evaluate(() => document.fonts.ready);
          result.layout = await page.evaluate(() => ({
            width: document.documentElement.clientWidth,
            scrollWidth: document.documentElement.scrollWidth,
            previewTop: document.querySelector('.specimen-canvas')?.getBoundingClientRect().top,
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
          if (name === 'task-working') {
            assert(result.layout.previewTop < height - 120, 'Card preview is buried below the first screen');
            if (width > 1000) {
              assert(await page.locator('.specimen-catalog').isVisible(), 'Card families belong in the desktop side rail');
              assert(!await page.locator('#card-family').isVisible(), 'The family dropdown is only for narrow screens');
              const edges = await page.locator('.specimen-catalog nav small').evaluateAll(es => es.map(e => e.getBoundingClientRect().right));
              assert(edges.every(x => Math.abs(x - edges[0]) < 1), 'State counts must align in one column');
            } else {
              assert(await page.locator('#card-family').isVisible(), 'Keep a compact family picker on narrow screens');
            }
          }
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
      if (width === 1440) {
        try { await interactions(page); }
        catch (error) { report.interactionError = error.message; }
      }
      await context.close();
    }
  } finally {
    await browser.close();
    await fs.writeFile(path.join(output, 'manifest.json'), JSON.stringify(report, null, 2), {mode: 0o600});
  }
  const failed = report.captures.filter(capture => capture.failure);
  console.log(`${report.captures.length} captures; ${failed.length} failures; interactions: ${report.interactionError || 'PASS'}`);
  if (failed.length || report.interactionError) process.exitCode = 1;
})().catch(error => {console.error(error.message); process.exitCode = 1;});
