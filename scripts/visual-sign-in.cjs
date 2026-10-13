// Every console page needs a signed-in person (Ryker.ControlPlane.SignInGate), and a sign-in
// link works once. A screenshot harness presses one link's Sign in button and hands that
// browser's cookies to every page after it. The link comes from `scripts/compose.sh sign-in`,
// in RYKER_SIGN_IN_LINK, and only its path is used, on the origin the harness checks.
const assert = require('node:assert/strict');

function signInPath(printed = process.env.RYKER_SIGN_IN_LINK || '') {
  const found = printed.match(/\/sign-in\/[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])/);
  assert(found, 'Set RYKER_SIGN_IN_LINK to a link from scripts/compose.sh sign-in');
  return found[0];
}

async function signedInState(browser, origin) {
  const context = await browser.newContext();
  try {
    const page = await context.newPage();
    const response = await page.goto(new URL(signInPath(), origin).href);
    assert.equal(response.status(), 200, 'The sign-in link no longer works: get a new one from scripts/compose.sh sign-in');
    await Promise.all([
      page.waitForURL(url => !url.pathname.startsWith('/sign-in')),
      page.getByRole('button', {name: 'Sign in'}).click()
    ]);
    return await context.storageState();
  } finally {
    await context.close();
  }
}

// A run signs its browser out when it ends, so runs don't pile up on Settings › Access.
async function signOut(browser, origin, storageState) {
  if (!storageState) return;
  const page = await browser.newPage({storageState});
  try {
    await page.goto(new URL('/settings/access', origin).href);
    await page.locator('[data-connection-state="connected"]').waitFor({timeout: 5000});
    await Promise.all([
      page.waitForURL(url => url.pathname === '/sign-in'),
      page.locator('#sign-out').click()
    ]);
  } catch (error) {
    console.error(`Signing out failed: ${error.message}`);
  } finally {
    await page.close();
  }
}

module.exports = {signInPath, signedInState, signOut};
