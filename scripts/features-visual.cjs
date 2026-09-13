// Read-only feature discovery checks: the shared Configuration shell, GET filters and help disclosures.
// node scripts/features-visual.cjs http://127.0.0.1:4321 PRIVATE_OUTPUT
const {chromium} = require(process.env.RESPONDER_PLAYWRIGHT_MODULE || 'playwright');
const fs = require('node:fs/promises');
const path = require('node:path');
const assert = require('node:assert/strict');
const {createCaptureDirectory} = require('./visual-artifacts.cjs');
const origin = new URL(process.argv[2]);
assert(['localhost', '127.0.0.1', '[::1]'].includes(origin.hostname));
assert(origin.protocol === 'http:' && !origin.username && !origin.password && origin.pathname === '/');
assert(process.argv[3], 'Provide a private output directory');

(async () => {
  const output = await createCaptureDirectory(process.argv[3], path.resolve(__dirname, '..'));
  const browser = await chromium.launch({headless: true});
  const report = [];
  const fixture = process.argv[4] ? await fs.readFile(process.argv[4], 'utf8') : null;
  try {
    for (const width of [1440, 768, 390]) {
      const page = await browser.newPage({viewport: {width, height: 1000}, reducedMotion: 'reduce'});
      page.setDefaultTimeout(6000);
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      for (const route of ['/rules', '/preferences', '/guidance', '/memory', '/conversations']) {
        const result = {route, width};
        try {
          const response = await page.goto(new URL(route, origin).href);
          assert.equal(response.status(), 200);
          result.version = response.headers()['x-responder-version'];
          await page.locator('[data-connection-state="connected"]').waitFor();
          await page.evaluate(() => document.fonts.ready);
          assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Horizontal overflow');
          await page.screenshot({path: path.join(output, `${route.slice(1)}-${width}.png`), fullPage: true});
          if (['/rules', '/preferences', '/guidance'].includes(route)) {
            // The approved shell: one title, its description 8px under it, then the
            // page's own column — help, toolbar, count, entries — down one left edge.
            const shell = await page.locator('main .secondary-page').evaluate(e => {
              const heading = e.querySelector('header.page-header .page-heading');
              const h1 = heading.querySelector('h1'), description = heading.nextElementSibling;
              const help = e.querySelector('.behavior-library > details.page-help');
              const toolbar = e.querySelector('.behavior-library > form.filter-toolbar');
              const box = node => node.getBoundingClientRect();
              return {titles: e.querySelectorAll('h1').length, titleSize: getComputedStyle(h1).fontSize,
                descriptionGap: Math.round(box(description).top - box(h1).bottom),
                describes: description.matches('p.page-description'),
                helpClosed: help && !help.open, helpLeft: Math.round(box(help).left - box(h1).left),
                toolbarLeft: Math.round(box(toolbar).left - box(h1).left),
                applyButtons: toolbar.querySelectorAll('button').length,
                stats: e.querySelectorAll('.behavior-counts, .behavior-overview, .behavior-create').length};
            });
            assert.equal(shell.titles, 1, 'The title renders once');
            assert.equal(shell.titleSize, width === 390 ? '24px' : '28px');
            assert(shell.describes && shell.descriptionGap <= 8, `Description sits directly under the title (${shell.descriptionGap}px)`);
            assert(shell.helpClosed && shell.helpLeft === 0 && shell.toolbarLeft === 0, 'Help and toolbar share the title\'s left edge');
            assert.equal(shell.applyButtons, 0, 'No Apply button: dropdowns apply on change');
            assert.equal(shell.stats, 0, 'No statistics row or side help column');
            if (width === 390) {
              const search = await page.locator('#behavior-search').boundingBox();
              assert(search.width > 300, 'Mobile search gets its own full row');
              assert((await page.locator('#behavior-status').boundingBox()).width >= 150, 'The selected status must remain readable');
            }
            await page.locator('details.page-help > summary').focus();
            await page.keyboard.press('Enter');
            assert(await page.getByText('Review and confirm the proposed card', {exact: false}).isVisible());
            await page.screenshot({path: path.join(output, `${route.slice(1)}-${width}-help.png`)});
            for (const href of await page.locator('details.page-help a').evaluateAll(es => es.map(e => e.getAttribute('href')))) {
              assert(!href.startsWith('/card-lab') && !href.startsWith('/lab'), `Help must not link a retired page: ${href}`);
              assert.equal((await page.request.get(new URL(href, origin).href)).status(), 200, `Help link must be a real route: ${href}`);
            }
            await page.locator('#behavior-search').fill('No matching instruction');
            await page.locator('#behavior-search').press('Enter');
            await page.waitForURL(url => url.searchParams.get('q') === 'No matching instruction');
            await page.locator('[data-connection-state="connected"]').waitFor();
            await page.locator('#behavior-status').selectOption('all');
            await page.waitForURL(url => url.searchParams.get('status') === 'all');
            await page.locator('[data-connection-state="connected"]').waitFor();
            await page.locator('#behavior-scope').selectOption('repository');
            await page.waitForURL(url => url.searchParams.get('scope') === 'repository');
            await page.locator('[data-connection-state="connected"]').waitFor();
            assert.equal(await page.locator('#behavior-search').inputValue(), 'No matching instruction');
            assert.equal(await page.locator('#behavior-status').inputValue(), 'all');
            assert.equal(await page.locator('#behavior-scope').inputValue(), 'repository');
            assert(await page.getByRole('heading', {name: 'No matching entries'}).isVisible());
            const updated = await page.locator('#responder-shell').getAttribute('data-updated-at');
            await page.waitForFunction(previous => document.querySelector('#responder-shell')?.dataset.updatedAt !== previous, updated, {timeout: 12000});
            assert.equal(await page.locator('#behavior-search').inputValue(), 'No matching instruction');
            await page.getByRole('link', {name: 'Clear filters', exact: true}).click();
            await page.waitForURL(url => url.search === '');
            if (route === '/rules' && fixture) {
              // Optional host-state render: exercise populated layout without
              // creating a rule or enabling automation in the live database.
              await page.locator('[data-connection-state="connected"]').waitFor();
              await page.evaluate(html => {
                document.querySelector('.behavior-library').outerHTML = new DOMParser()
                  .parseFromString(html, 'text/html').querySelector('.behavior-library').outerHTML;
              }, fixture);
              result.populatedFixture = true;
              await page.screenshot({path: path.join(output, `rules-${width}-populated.png`), fullPage: true});
              const entry = await page.locator('.behavior-entry').first().evaluate(e => {
                const header = getComputedStyle(e.querySelector('header'));
                const footer = getComputedStyle(e.querySelector('footer'));
                return {background: header.backgroundColor, position: header.position,
                  leftPadding: footer.paddingLeft, bottomMargin: footer.marginBottom};
              });
              assert.equal(entry.background, 'rgba(0, 0, 0, 0)', 'Rule heading must not inherit the old dark page header');
              assert.equal(entry.position, 'static');
              assert.equal(entry.leftPadding, '0px');
              assert.equal(entry.bottomMargin, '0px');
              assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Populated layout overflow');
            }
          }
          if (route === '/conversations') {
            assert.equal(await page.locator('.workflow-list, #workflows, a[href^="/card-lab/"]').count(), 0, 'The retired card catalog must not come back');
          }
          assert.equal(errors.length, 0, 'Browser errors');
        } catch (error) {
          result.failure = error.message;
          await page.screenshot({path: path.join(output, `${route.slice(1)}-${width}-failure.png`)});
        }
        report.push(result);
        console.log(`${route} ${width}: ${result.failure || 'PASS'}`);
      }
      await page.close();
      if (fixture) {
        const confirmation = await browser.newPage({viewport: {width, height: 1000}});
        try {
          // Retain the application's origin so its same-origin stylesheet
          // policy applies exactly as it does for real confirmation pages.
          await confirmation.goto(new URL('/healthz', origin).href);
          await confirmation.setContent(fixture);
          await confirmation.evaluate(() => document.fonts.ready);
          await confirmation.screenshot({path: path.join(output, `static-layout-${width}.png`), fullPage: true});
          assert(await confirmation.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Confirmation layout must fit the viewport');
        } finally {
          await confirmation.close();
        }
      }
    }
  } finally {
    await browser.close();
    await fs.writeFile(path.join(output, 'manifest.json'), JSON.stringify(report, null, 2), {mode: 0o600});
    console.log(output);
  }
  if (report.some(result => result.failure)) process.exitCode = 1;
})().catch(error => {console.error(error.message); process.exitCode = 1;});
