/**
 * run-with-heartbeat - the beat that names the PHASE, not just "alive".
 *
 * Measured 2026-11-15: two merge trains sat 8 and 21 minutes with 5.7s of PARENT CPU
 * (so every observer said idle) while their TREES had spent 53.1s running
 * `node --test scripts/tests/iqa-merge-runner.test.mjs` as the gate. The machine was
 * not pinned: 32 cores, Defender the top consumer. The observer was measuring the
 * wrong thing, and the phase was nowhere to be read.
 *
 * Pinned here: tree CPU (parent + children), phase parsing from child output, and a
 * `stalled` verdict that needs BOTH a still phase AND idle tree CPU across consecutive
 * beats - one signal is a report, never a kill.
 */
import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  IDLE_CPU_SECONDS,
  STALL_BEATS,
  makeBeat,
  phaseFrom,
  summarise,
  treeSummary,
} from './run-with-heartbeat.mjs';

const START = '2026-11-15T09:00:00.000Z';
const at = (seconds) => new Date(Date.parse(START) + seconds * 1000);

test('the tree sums the children - the parent of a gate is idle by design', () => {
  const table = new Map([
    [100, { ppid: 1, cpuSeconds: 5.7, cmd: 'node iqa-merge-runner.mjs --train' }],
    [101, { ppid: 100, cpuSeconds: 40, cmd: 'node --test scripts/tests/iqa-merge-runner.test.mjs' }],
    [102, { ppid: 101, cpuSeconds: 7.4, cmd: 'node --test worker' }],
    [200, { ppid: 1, cpuSeconds: 900, cmd: 'MsMpEng.exe' }],
  ]);
  const tree = treeSummary(table, 100);
  assert.equal(tree.processes, 3);
  assert.equal(tree.cpuSeconds, 53.1);
  assert.match(tree.busiestCommand, /iqa-merge-runner\.test/);
  assert.equal(treeSummary(table, 999), null, 'an absent pid is cannot-evaluate, not zero');
});

test('phase markers name what the worker is IN, first match wins', () => {
  assert.equal(phaseFrom('merge train: 4 members, 2 groups'), 'planning');
  assert.equal(phaseFrom('gating the merged tree in a scratch worktree'), 'gating');
  assert.equal(phaseFrom('merge: batch/one into dev'), 'merging');
  assert.equal(phaseFrom('pushed 6e456a926 to dev'), 'pushing');
  assert.equal(phaseFrom('nothing actionable this tick'), 'idle');
  assert.equal(phaseFrom('some ordinary log line'), null);
});

test('a moving phase is working even with little CPU', () => {
  const first = makeBeat({ label: 'train', repo: 'cbk', instanceId: 'i', pid: 1, startedAt: START, now: at(180), phase: 'planning', lastLine: 'merge train: 4 members' });
  const second = makeBeat({ label: 'train', repo: 'cbk', instanceId: 'i', pid: 1, startedAt: START, now: at(360), phase: 'gating', lastLine: 'gating the merged tree', previous: first, previousTreeCpu: 5, tree: { cpuSeconds: 5.2, processes: 3, busiestCommand: 'x' } });
  assert.equal(second.verdict, 'working');
});

test('a trunk advance is progress even when the phase is still', () => {
  const beat = makeBeat({ label: 'train', repo: 'cbk', instanceId: 'i', pid: 1, startedAt: START, now: at(180), phase: 'merging', lastLine: 'merge: a', previous: { phase: 'merging', lastLine: 'merge: a', repeats: 4 }, previousTreeCpu: 5, tree: { cpuSeconds: 5.1, processes: 3 }, trunkSha: 'bbb', previousTrunkSha: 'aaa' });
  assert.equal(beat.verdict, 'working');
  assert.equal(beat.trunkAdvanced, true);
});

test('stalled needs two consecutive idle+unchanged beats - the first is only a report', () => {
  const base = { phase: 'gating', lastLine: 'gating the merged tree' };
  // beat 1 cannot judge idleness (no previous CPU sample) - it establishes the baseline
  let previous = makeBeat({ label: 't', instanceId: 'i', pid: 1, startedAt: START, now: at(180), ...base, previousTreeCpu: 5, tree: { cpuSeconds: 5.1 }, trunkSha: 'a', previousTrunkSha: 'a' });
  assert.equal(previous.verdict, 'working');

  // beat 2: first idle+unchanged sample - a report, not a kill
  previous = makeBeat({ label: 't', instanceId: 'i', pid: 1, startedAt: START, now: at(360), ...base, previous, previousTreeCpu: 5.1, tree: { cpuSeconds: 5.2 }, trunkSha: 'a', previousTrunkSha: 'a' });
  assert.equal(previous.verdict, 'working', 'one idle beat is a report');
  assert.equal(previous.repeats, 1);

  // beat 3: second consecutive idle+unchanged sample - now it is a pattern
  previous = makeBeat({ label: 't', instanceId: 'i', pid: 1, startedAt: START, now: at(540), ...base, previous, previousTreeCpu: 5.2, tree: { cpuSeconds: 5.3 }, trunkSha: 'a', previousTrunkSha: 'a' });
  assert.equal(previous.verdict, 'stalled', `STALL_BEATS=${STALL_BEATS}`);
  assert.equal(previous.repeats, 2);
});

test('busy CPU under the same phase is working, not stalled', () => {
  const beat = makeBeat({ label: 't', instanceId: 'i', pid: 1, startedAt: START, now: at(360), phase: 'gating', lastLine: 'gating the merged tree', previous: { phase: 'gating', lastLine: 'gating the merged tree', repeats: 5 }, previousTreeCpu: 5, tree: { cpuSeconds: 40 }, trunkSha: 'a', previousTrunkSha: 'a' });
  assert.equal(beat.verdict, 'working');
  assert.ok(beat.treeCpuDelta >= IDLE_CPU_SECONDS);
});

test('an exited child is done and carries its exit code', () => {
  const beat = makeBeat({ label: 't', instanceId: 'i', pid: 1, startedAt: START, now: at(60), exitCode: 0 });
  assert.equal(beat.verdict, 'done');
  assert.equal(beat.exitCode, 0);
});

test('the summary line is readable and carries the child command', () => {
  const beat = makeBeat({ label: 'train', repo: 'cbk', instanceId: 'i', pid: 1, startedAt: START, now: at(180), phase: 'gating', lastLine: 'gating', previous: { phase: 'gating', lastLine: 'gating', repeats: 1 }, previousTreeCpu: 5, tree: { cpuSeconds: 5.2, processes: 2, busiestCommand: 'node --test x.test.mjs' } });
  const line = summarise(beat);
  assert.match(line, /phase=gating/);
  assert.match(line, /treeCpu=\+0\.2s/);
  assert.match(line, /child=node --test x\.test\.mjs/);
});
