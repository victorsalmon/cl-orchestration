#!/usr/bin/env node
/**
 * run-with-heartbeat - a critical worker that tells the Hub what it is doing.
 *
 * The failure this exists for (measured 2026-11-15, currents-bookkeeping): two merge
 * trains sat for 8 and 21 minutes with 5.7s of PARENT CPU, so every "is it working?"
 * check said idle - while the same processes' TREES had spent 53.1s and were running
 * `node --test scripts/tests/iqa-merge-runner.test.mjs` as their gate. The machine was
 * not pinned (32 cores, Defender the top consumer, hundreds of idle processes); the
 * observer was measuring the wrong thing, and there was nowhere to read the phase.
 *
 * A beat names the PHASE, the CHILD COMMAND, the TREE CPU over the interval, the trunk
 * SHA, and an instance id, every --interval seconds. The verdict is progress-based:
 *
 *   working  the phase changed, the trunk advanced, or the tree burned CPU
 *   stalled  same phase and object-identical child and ~no CPU for N consecutive beats
 *   done     the child exited (with its code)
 *
 * Two rules learned the hard way, both encoded here:
 *   1. Measure the TREE. A parent that spawns work is idle by design.
 *   2. One signal is a report, never a kill: `stalled` needs a still phase AND idle
 *      tree CPU across consecutive beats, and it is the PROBE that decides, not this.
 *
 *   node run-with-heartbeat.mjs --label train-cbk --repo currents-bookkeeping \
 *     --interval 180 -- node scripts/iqa-merge-runner.mjs --train --max-merges 12 --no-deploy
 *
 * Exit code: the child's, or 3 when the child could not be started.
 */
import cp from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const DEFAULT_INTERVAL_SECONDS = 180;
/** Tree CPU (seconds) below which a beat counts as idle. */
export const IDLE_CPU_SECONDS = 0.5;
/** Consecutive idle+unchanged beats before the verdict is `stalled`. */
export const STALL_BEATS = 2;

/* ------------------------------------------------------------- process table */

const PS_SNAPSHOT =
  "$ErrorActionPreference='Stop';" +
  'Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,UserModeTime,KernelModeTime,CommandLine | ' +
  'ForEach-Object { "$($_.ProcessId)`t$($_.ParentProcessId)`t$($_.UserModeTime)`t$($_.KernelModeTime)`t$($_.CommandLine)" }';

/** Map<pid, {ppid, cpuSeconds, cmd}> or null. */
export function snapshotProcesses() {
  try {
    const out = cp.execSync(`powershell -NoProfile -NonInteractive -Command "${PS_SNAPSHOT.replace(/"/g, '\\"')}"`, {
      encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024,
      windowsHide: true,
    });
    const table = new Map();
    for (const line of out.split(/\r?\n/)) {
      const [pid, ppid, user, kernel, ...cmd] = line.split('\t');
      if (!pid) continue;
      table.set(Number(pid), {
        ppid: Number(ppid),
        cpuSeconds: (Number(user) + Number(kernel)) / 1e7,
        cmd: (cmd.join('\t') ?? '').slice(0, 200),
      });
    }
    return table.size ? table : null;
  } catch {
    return null;
  }
}

/**
 * The tree under `pid`: summed CPU plus the most CPU-consuming descendant command
 * (that command is the actionable fact - "gating test:scripts" beats "low CPU").
 */
export function treeSummary(table, pid) {
  if (!table || !table.has(pid)) return null;
  const children = new Map();
  for (const [childPid, row] of table) {
    if (!children.has(row.ppid)) children.set(row.ppid, []);
    children.get(row.ppid).push(childPid);
  }
  const seen = new Set();
  const stack = [pid];
  let cpu = 0;
  let busiest = { pid, cmd: table.get(pid)?.cmd ?? '', cpu: table.get(pid)?.cpuSeconds ?? 0 };
  while (stack.length) {
    const current = stack.pop();
    if (seen.has(current)) continue;
    seen.add(current);
    const row = table.get(current);
    if (row) {
      cpu += row.cpuSeconds;
      if (row.cpuSeconds > busiest.cpu) busiest = { pid: current, cmd: row.cmd, cpu: row.cpuSeconds };
    }
    for (const child of children.get(current) ?? []) stack.push(child);
  }
  return { processes: seen.size, cpuSeconds: cpu, busiestCommand: busiest.cmd };
}

/* -------------------------------------------------------------------- phase */

/** Runner log lines that name a phase. First match wins. */
export const PHASE_MARKERS = [
  [/merge train:/i, 'planning'],
  [/planner|plan:/i, 'planning'],
  [/gating|blocking tier|gate run/i, 'gating'],
  [/merging .* into|merge:/i, 'merging'],
  [/pushing|pushed/i, 'pushing'],
  [/hygien|sweep/i, 'hygiene'],
  [/nothing actionable|no ready|queue empty/i, 'idle'],
];

export function phaseFrom(line) {
  for (const [re, phase] of PHASE_MARKERS) if (re.test(line)) return phase;
  return null;
}

/* --------------------------------------------------------------------- beat */

export function makeBeat({
  label,
  repo = null,
  instanceId,
  pid,
  startedAt,
  now = new Date(),
  phase = null,
  lastLine = null,
  tree = null,
  previousTreeCpu = null,
  trunkSha = null,
  previousTrunkSha = null,
  previous = null,
  stalledEnough = STALL_BEATS,
  exitCode = null,
}) {
  const elapsedSeconds = Math.max(0, Math.round((now.getTime() - new Date(startedAt).getTime()) / 1000));
  const cpu = tree?.cpuSeconds ?? null;
  const cpuDelta = cpu !== null && previousTreeCpu !== null ? Number((cpu - previousTreeCpu).toFixed(2)) : null;
  const trunkAdvanced = Boolean(trunkSha && previousTrunkSha && trunkSha !== previousTrunkSha);
  const phaseChanged = Boolean(previous && previous.phase && phase && previous.phase !== phase);
  const idle = cpuDelta !== null && cpuDelta < IDLE_CPU_SECONDS;
  const unchanged = Boolean(previous && previous.phase === phase && previous.lastLine === lastLine);

  let verdict = 'working';
  let repeats = 0;
  if (exitCode !== null) verdict = 'done';
  else if (previous && idle && unchanged && !trunkAdvanced && !phaseChanged) {
    // Count this beat as the next consecutive idle+unchanged beat. With
    // STALL_BEATS = 2 the SECOND such beat is `stalled` - one idle beat is a
    // report, two is a pattern.
    repeats = (previous.repeats ?? 0) + 1;
    verdict = repeats >= stalledEnough ? 'stalled' : 'working';
  }

  return {
    v: 1,
    label,
    repo,
    instanceId,
    pid,
    startedAt,
    updatedAt: now.toISOString(),
    elapsedSeconds,
    phase,
    lastLine,
    treeProcesses: tree?.processes ?? null,
    treeCpuSeconds: cpu,
    treeCpuDelta: cpuDelta,
    busiestCommand: tree?.busiestCommand ?? null,
    trunkSha,
    trunkAdvanced,
    verdict,
    repeats,
    exitCode,
  };
}

/** One line an operator can read in a table. */
export function summarise(beat) {
  const cpu = beat.treeCpuDelta === null ? '?' : `${beat.treeCpuDelta >= 0 ? '+' : ''}${beat.treeCpuDelta}s`;
  return `[${beat.verdict}] ${beat.repo ?? beat.label} ${beat.elapsedSeconds}s phase=${beat.phase ?? '?'} treeCpu=${cpu}${beat.busiestCommand ? ` child=${beat.busiestCommand}` : ''}`;
}

export function heartbeatPath({ repo, env = process.env, home = os.homedir() } = {}) {
  const state = env.MACHINE_STATE_HOME ? path.resolve(env.MACHINE_STATE_HOME) : path.join(home, '.machine', 'state');
  return path.join(state, 'merge-runner', `${repo ?? 'worker'}.heartbeat.json`);
}

/* ---------------------------------------------------------------------- cli */

function parseArgs(argv) {
  const out = { interval: DEFAULT_INTERVAL_SECONDS, label: 'worker', repo: null, out: null, trunk: null };
  let i = 2;
  for (; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--') {
      i += 1;
      break;
    }
    if (a === '--interval') out.interval = Math.max(5, Number(argv[++i]) || DEFAULT_INTERVAL_SECONDS);
    else if (a === '--label') out.label = argv[++i];
    else if (a === '--repo') out.repo = argv[++i];
    else if (a === '--out') out.out = argv[++i];
    else if (a === '--trunk') out.trunk = argv[++i];
    else if (a === '--help' || a === '-h') out.help = true;
  }
  out.command = argv.slice(i);
  return out;
}

function trunkHead(dir) {
  if (!dir) return null;
  try {
    return cp.execSync('git rev-parse --short HEAD', { windowsHide: true, cwd: dir, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return null;
  }
}

function main() {
  const args = parseArgs(process.argv);
  if (args.help || args.command.length === 0) {
    process.stderr.write('usage: run-with-heartbeat.mjs --label <name> [--repo <slug>] [--interval 180] [--trunk <dir>] [--out <file>] -- <command...>\n');
    return 2;
  }
  const outFile = args.out ? path.resolve(args.out) : heartbeatPath({ repo: args.repo ?? args.label });
  const instanceId = `${process.pid}-${Date.now().toString(36)}`;
  const startedAt = new Date().toISOString();
  let phase = null;
  let lastLine = null;
  let previousBeat = null;
  let previousCpu = null;
  let previousTrunk = null;
  let exitCode = null;

  const write = (beat) => {
    try {
      fs.mkdirSync(path.dirname(outFile), { recursive: true });
      fs.writeFileSync(outFile, `${JSON.stringify(beat, null, 2)}\n`);
    } catch {
      /* a beat that cannot be written must never kill the work */
    }
    process.stderr.write(`${summarise(beat)}\n`);
  };

  const child = cp.spawn(args.command[0] === 'node' ? process.execPath : args.command[0], args.command.slice(1), {
    // No shell: with `shell: true` the reported pid is cmd.exe, which can exit while
    // the real worker runs on, and the tree CPU then reads null - the exact blind spot
    // this tool exists to remove.
    stdio: ['ignore', 'pipe', 'pipe'],
    shell: false,
    windowsHide: true,
  });
  const onData = (chunk) => {
    for (const line of String(chunk).split(/\r?\n/)) {
      if (!line.trim()) continue;
      lastLine = line.trim().slice(0, 200);
      const found = phaseFrom(lastLine);
      if (found) phase = found;
    }
  };
  child.stdout.on('data', onData);
  child.stderr.on('data', onData);
  child.on('exit', (code) => {
    exitCode = code ?? 1;
  });

  const beat = () => {
    const table = snapshotProcesses();
    const tree = treeSummary(table, child.pid);
    const trunkSha = trunkHead(args.trunk);
    const b = makeBeat({
      label: args.label,
      repo: args.repo,
      instanceId,
      pid: child.pid,
      startedAt,
      phase,
      lastLine,
      tree,
      previousTreeCpu: previousCpu,
      trunkSha,
      previousTrunkSha: previousTrunk,
      previous: previousBeat,
      exitCode,
    });
    previousBeat = b;
    previousCpu = b.treeCpuSeconds;
    previousTrunk = trunkSha;
    write(b);
    return b;
  };

  write(beat());
  const timer = setInterval(() => {
    const b = beat();
    if (exitCode !== null) {
      clearInterval(timer);
      process.exit(exitCode);
    }
    if (b.verdict === 'stalled') {
      process.stderr.write(
        `run-with-heartbeat: ${args.label} looks stalled (same phase, ${b.treeCpuDelta}s tree CPU, ${b.repeats} beats). The PROBE decides - this only reports.\n`,
      );
    }
  }, args.interval * 1000);

  const finish = (code) => {
    exitCode = code ?? 1;
    beat();
    clearInterval(timer);
    process.exit(exitCode);
  };
  process.on('SIGTERM', () => finish(143));
  process.on('SIGINT', () => finish(130));
  return null;
}

const invoked = process.argv[1] && path.resolve(process.argv[1]) === path.resolve(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
if (invoked) {
  const code = main();
  if (code !== null && code !== undefined) process.exit(code);
}
