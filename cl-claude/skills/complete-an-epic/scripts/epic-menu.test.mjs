import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { buildEpicRows, formatMenu, parseArgs, readRepo, selectRepos, PRODUCT_REPOS } from './epic-menu.mjs';

const status = (id, priority, closed, total, extra = {}) => ({
  epic: { id, priority, status: 'open', title: `t ${id}`, created_at: extra.created_at || '2026-11-01T00:00:00Z' },
  total_children: total,
  closed_children: closed,
  eligible_for_close: extra.eligible || false,
});

test('sorts by priority, then oldest first', () => {
  const rows = buildEpicRows(
    [status('a', 2, 0, 3), status('b', 0, 1, 2, { created_at: '2026-11-05' }), status('c', 0, 0, 1, { created_at: '2026-11-02' })],
    [],
  );
  assert.deepEqual(rows.map((r) => r.id), ['c', 'b', 'a']);
});

test('a childless epic from bd list is kept (bd epic status omits it)', () => {
  const rows = buildEpicRows([status('a', 1, 0, 2)], [{ id: 'z', priority: 0, status: 'open', title: 'goal' }]);
  assert.deepEqual(rows.map((r) => [r.id, r.state]), [['z', 'no-children'], ['a', 'build']]);
});

test('closed and deferred epics are dropped; all-closed children read close-only', () => {
  const s = [status('done', 1, 3, 3, { eligible: true }), { ...status('gone', 1, 0, 1), epic: { id: 'gone', status: 'closed', priority: 1 } }];
  const rows = buildEpicRows(s, [{ id: 'later', status: 'deferred', priority: 0 }]);
  assert.deepEqual(rows.map((r) => [r.id, r.state, r.remaining]), [['done', 'close-only', 0]]);
});

test('selectRepos: no name = every product repo, a name = that repo with its merge agent', () => {
  assert.equal(selectRepos([]).length, PRODUCT_REPOS.length);
  assert.deepEqual(selectRepos(['Currents-Bookkeeping']), [{ repo: 'currents-bookkeeping', mergeAgent: 'merge-cbk' }]);
  assert.deepEqual(selectRepos(['other']), [{ repo: 'other', mergeAgent: null }]);
});

test('parseArgs refuses an unknown flag and a bare --repo', () => {
  assert.deepEqual(parseArgs(['--repo', 'cl-common', '--json']), { repos: ['cl-common'], json: true, root: null });
  assert.throws(() => parseArgs(['--repo']), /needs a repo/);
  assert.throws(() => parseArgs(['--bogus']), /unknown argument/);
});

test('an unreadable graph is CANNOT-EVALUATE, never "no open epics"', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'epic-menu-'));
  fs.mkdirSync(path.join(root, 'cl-common'));
  const failing = () => ({ status: 1, stdout: '', stderr: 'database locked' });
  const missing = readRepo({ repo: 'nowhere', mergeAgent: null }, root, failing);
  const red = readRepo({ repo: 'cl-common', mergeAgent: 'merge-common' }, root, failing);
  const text = formatMenu([missing, red]);
  assert.match(text, /CANNOT-EVALUATE {2}checkout not found/);
  assert.match(text, /CANNOT-EVALUATE {2}bd epic status exit 1: database locked/);
  assert.doesNotMatch(text, /no open epics/);
});

test('the menu numbers rows and names the merge agent', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'epic-menu-'));
  fs.mkdirSync(path.join(root, 'cl-common'));
  const run = (args) =>
    args[0] === 'epic'
      ? { status: 0, stdout: JSON.stringify([status('cl-common-x', 0, 1, 4)]) }
      : { status: 0, stdout: '[]' };
  const text = formatMenu([readRepo({ repo: 'cl-common', mergeAgent: 'merge-common' }, root, run)]);
  assert.match(text, /=== cl-common {2}\(merge agent: merge-common\)/);
  assert.match(text, / 1\. P0 {2}cl-common-x {2}1\/4 {2}t cl-common-x/);
});
