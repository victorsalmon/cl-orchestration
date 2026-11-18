#!/usr/bin/env node
// epic-menu.mjs - the "Complete an Epic" menu: every OPEN epic in one or more
// repos' beads graphs, in priority order, with its child progress and the
// merge agent that lands that repo's branches.
//
//   node epic-menu.mjs                       # every product repo
//   node epic-menu.mjs --repo cl-common      # one repo (repeatable)
//   node epic-menu.mjs --json                # machine-readable
//
// Read-only: it runs `bd epic status --json` and `bd list --type epic` in each
// repo's main checkout and writes nothing. A repo whose graph cannot be read is
// printed as CANNOT-EVALUATE with the reason; it is never shown as "no epics".
// Exit: 0 menu printed (every repo read), 3 at least one repo could not be read,
// 2 usage error.

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/** Product repos and the agent that lands each one's merge queue (owner: vendor/interactive-qa/members/iqa-hub/references/role-contract.md). */
export const PRODUCT_REPOS = [
  { repo: 'cl-common', mergeAgent: 'merge-common' },
  { repo: 'currents-bookkeeping', mergeAgent: 'merge-cbk' },
  { repo: 'upscale-havens', mergeAgent: 'hub-uh' }, // role-contract.md: hub-uh lands UH
];

export function parseArgs(argv) {
  const out = { repos: [], json: false, root: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') out.json = true;
    else if (a === '--repo') {
      const v = argv[++i];
      if (!v) throw new Error('--repo needs a repo name');
      out.repos.push(v);
    } else if (a === '--root') {
      const v = argv[++i];
      if (!v) throw new Error('--root needs a directory');
      out.root = v;
    } else if (a === '-h' || a === '--help') out.help = true;
    else throw new Error(`unknown argument: ${a}`);
  }
  return out;
}

/** Resolve the repos to read: named ones (any repo, known or not) or the product set. */
export function selectRepos(named) {
  if (!named.length) return PRODUCT_REPOS.map((r) => ({ ...r }));
  return named.map((name) => {
    const known = PRODUCT_REPOS.find((r) => r.repo.toLowerCase() === name.toLowerCase());
    return known ? { ...known } : { repo: name, mergeAgent: null };
  });
}

/**
 * Merge `bd epic status` rows (which carry child counts but omit childless
 * epics) with `bd list --type epic` rows (which carry every open epic), keep
 * open/in-progress epics only, and sort: priority ascending, then oldest first.
 */
export function buildEpicRows(statusRows, listRows) {
  const byId = new Map();
  for (const e of listRows || []) {
    if (!e || !e.id) continue;
    byId.set(e.id, { epic: e, total: 0, closed: 0, eligible: false });
  }
  for (const r of statusRows || []) {
    const e = r && r.epic;
    if (!e || !e.id) continue;
    byId.set(e.id, {
      epic: { ...(byId.get(e.id)?.epic || {}), ...e },
      total: Number(r.total_children) || 0,
      closed: Number(r.closed_children) || 0,
      eligible: Boolean(r.eligible_for_close),
    });
  }
  const live = [...byId.values()].filter((x) => x.epic.status !== 'closed' && x.epic.status !== 'deferred');
  live.sort((a, b) => {
    const pa = Number.isFinite(Number(a.epic.priority)) ? Number(a.epic.priority) : 9;
    const pb = Number.isFinite(Number(b.epic.priority)) ? Number(b.epic.priority) : 9;
    if (pa !== pb) return pa - pb;
    return String(a.epic.created_at || '').localeCompare(String(b.epic.created_at || ''));
  });
  return live.map((x) => ({
    id: x.epic.id,
    priority: Number.isFinite(Number(x.epic.priority)) ? Number(x.epic.priority) : null,
    status: x.epic.status || 'open',
    title: String(x.epic.title || '').replace(/\s+/g, ' ').trim(),
    closedChildren: x.closed,
    totalChildren: x.total,
    remaining: Math.max(0, x.total - x.closed),
    state: x.total === 0 ? 'no-children' : x.eligible || x.closed >= x.total ? 'close-only' : 'build',
  }));
}

function parseJsonArray(text) {
  const t = String(text || '').trim();
  if (!t) return [];
  const v = JSON.parse(t);
  return Array.isArray(v) ? v : [];
}

/** Read one repo's graph. `run(args, cwd)` -> { status, stdout, stderr } (injected in tests). */
export function readRepo(entry, root, run) {
  const cwd = path.join(root, entry.repo);
  if (!fs.existsSync(cwd)) return { ...entry, error: `checkout not found: ${cwd}` };
  const status = run(['epic', 'status', '--json'], cwd);
  if (status.status !== 0) return { ...entry, error: `bd epic status exit ${status.status}: ${String(status.stderr || '').trim().slice(0, 200)}` };
  const list = run(['list', '--type', 'epic', '--status', 'open', '--json', '--limit', '0'], cwd);
  if (list.status !== 0) return { ...entry, error: `bd list exit ${list.status}: ${String(list.stderr || '').trim().slice(0, 200)}` };
  try {
    return { ...entry, epics: buildEpicRows(parseJsonArray(status.stdout), parseJsonArray(list.stdout)) };
  } catch (err) {
    return { ...entry, error: `unparseable bd output: ${err.message}` };
  }
}

export function formatMenu(results) {
  const lines = [];
  for (const r of results) {
    lines.push(`=== ${r.repo}  (merge agent: ${r.mergeAgent || 'none known - ask which agent merges this repo'})`);
    if (r.error) {
      lines.push(`  CANNOT-EVALUATE  ${r.error}`);
      continue;
    }
    if (!r.epics.length) {
      lines.push('  (no open epics)');
      continue;
    }
    r.epics.forEach((e, i) => {
      const prog = e.totalChildren ? `${e.closedChildren}/${e.totalChildren}` : '-';
      const tag = e.state === 'close-only' ? '  [all children closed: close-only]' : e.state === 'no-children' ? '  [no child beads]' : '';
      lines.push(`  ${String(i + 1).padStart(2)}. P${e.priority ?? '?'}  ${e.id}  ${prog}  ${e.title.slice(0, 90)}${tag}`);
    });
  }
  return lines.join('\n');
}

function defaultRoot() {
  if (process.env.CL_REPOS_ROOT) return process.env.CL_REPOS_ROOT;
  // <root>/cl-common/vendor/cl-orchestration/cl-claude/skills/complete-an-epic/scripts/epic-menu.mjs
  const here = path.dirname(fileURLToPath(import.meta.url));
  let dir = here;
  for (let i = 0; i < 8; i++) {
    if (fs.existsSync(path.join(dir, 'Skills')) && path.basename(dir).toLowerCase() === 'cl-common') return path.dirname(dir);
    const up = path.dirname(dir);
    if (up === dir) break;
    dir = up;
  }
  // a .worktrees/<lane> checkout: <root>/cl-common/.worktrees/<lane>/Skills/...
  const m = here.match(/^(.*?)[\\/]cl-common[\\/]/i);
  return m ? m[1] : process.cwd();
}

function bdRun(args, cwd) {
  const r = spawnSync('bd', args, { cwd, encoding: 'utf8', windowsHide: true, shell: process.platform === 'win32', maxBuffer: 1 << 26, timeout: 120000 });
  return { status: r.status ?? 1, stdout: r.stdout, stderr: r.stderr || (r.error ? String(r.error.message) : '') };
}

function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(`epic-menu: ${err.message}`);
    process.exit(2);
  }
  if (opts.help) {
    console.log('usage: node epic-menu.mjs [--repo <name>]... [--json] [--root <repos-root>]');
    process.exit(0);
  }
  const root = opts.root || defaultRoot();
  const results = selectRepos(opts.repos).map((e) => readRepo(e, root, bdRun));
  if (opts.json) console.log(JSON.stringify(results, null, 2));
  else console.log(formatMenu(results));
  process.exit(results.some((r) => r.error) ? 3 : 0);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
