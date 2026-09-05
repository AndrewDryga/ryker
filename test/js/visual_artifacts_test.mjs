import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createCaptureDirectory} from '../../scripts/visual-artifacts.cjs';

test('organization screenshots cannot enter the checkout through a symlinked parent', async () => {
  // The first capture harness compared lexical paths, allowing an outside
  // symlink to redirect private screenshots into a committable directory.
  const scratch = await fs.mkdtemp(path.join(os.tmpdir(), 'responder-visual-test-'));
  try {
    const repository = path.join(scratch, 'repo');
    await fs.mkdir(repository);
    await fs.symlink(repository, path.join(scratch, 'alias'));
    await assert.rejects(createCaptureDirectory(path.join(scratch, 'alias', 'capture'), repository));
    assert.deepEqual(await fs.readdir(repository), []);
  } finally { await fs.rm(scratch, {recursive: true}); }
});

test('each capture creates a fresh private directory and never reuses an existing target', async () => {
  const scratch = await fs.mkdtemp(path.join(os.tmpdir(), 'responder-visual-test-'));
  try {
    const repository = path.join(scratch, 'repo');
    await fs.mkdir(repository);
    const prefix = path.join(scratch, 'capture');
    await fs.symlink(repository, prefix);
    const first = await createCaptureDirectory(prefix, repository);
    const second = await createCaptureDirectory(prefix, repository);
    assert.notEqual(first, prefix);
    assert.notEqual(first, second);
    assert.equal((await fs.stat(first)).mode & 0o777, 0o700);
    assert.deepEqual(await fs.readdir(repository), []);
  } finally { await fs.rm(scratch, {recursive: true}); }
});
