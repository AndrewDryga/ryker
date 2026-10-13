import {test} from 'node:test';
import assert from 'node:assert/strict';
import {signInPath} from '../../scripts/visual-sign-in.cjs';

// Since 2026-10-13 every console page needs a signed-in person, so a harness without a link
// would capture the sign-in page at every route and call it the product.
test('a harness signs in with the link compose.sh printed, and says where one comes from', () => {
  const token = 'a'.repeat(43);
  assert.equal(signInPath(`http://127.0.0.1:4321/sign-in/${token}\n`), `/sign-in/${token}`);
  assert.equal(signInPath(`Ryker is ready\nhttp://localhost:4321/sign-in/${token}`), `/sign-in/${token}`);
  for (const printed of ['', 'http://127.0.0.1:4321/sign-in', `http://127.0.0.1:4321/sign-in/${token}b`]) {
    assert.throws(() => signInPath(printed), /scripts\/compose\.sh sign-in/);
  }
});
