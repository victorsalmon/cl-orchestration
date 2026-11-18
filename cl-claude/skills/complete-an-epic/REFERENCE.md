# Complete an Epic - reference

## The menu

```powershell
node $env:CL_REPOS_ROOT\cl-common\vendor\cl-orchestration\cl-claude\skills\complete-an-epic\scripts\epic-menu.mjs             # all product repos
node $env:CL_REPOS_ROOT\cl-common\vendor\cl-orchestration\cl-claude\skills\complete-an-epic\scripts\epic-menu.mjs --repo currents-bookkeeping
node ...\epic-menu.mjs --json                                                                                # machine-readable
```

It merges `bd epic status --json` (child counts; omits childless epics) with
`bd list --type epic --status open --json --limit 0` (every open epic), drops
closed and deferred epics, and sorts priority ascending, oldest first. Exit 0 =
every repo read; 3 = at least one repo `CANNOT-EVALUATE`; 2 = usage error.

## Repo map - queue, merge agent, gates, report

Always run queue tools with the **target repo's main checkout** as the root. The
queue store is `<repo>/.iqa/merge-queue/<repo>.jsonl`; a tool run from another
repo's checkout reads and writes THAT checkout's store, not the target's.

| Repo | Trunk | Merge agent | Train gate / dry run | Lane report |
| :--- | :--- | :--- | :--- | :--- |
| cl-common | `dev` | `merge-common` | `scripts/lib/merge-runner-gates.mjs` `buildGatePlan`; `node scripts/iqa-merge-runner.mjs --dry-run --only <branch>` | `docs/iqa/reports/<bead>-<slug>.md`: names the tip (9+ hex), positive `Status:` |
| currents-bookkeeping | `dev` | `merge-cbk` | `npm run qa:changed`; `npm run iqa:merge-runner -- --dry-run --only <branch>` | `node scripts/lane-report.mjs --bead <id> --lane <slug> --class <c> --gate <name>=<exit>` (AGENTS.md § Lane reports) |
| upscale-havens | `dev` | `hub-uh` | its `qa:changed`; `node scripts/iqa-merge-runner.mjs --dry-run --json` (a shim over the cl-common engine; find the branch in the output) | `docs/iqa/reports/<slug>.md` naming the tip |

The repo-to-merge-agent split is owned by
`vendor/interactive-qa/members/iqa-hub/references/role-contract.md` § "One merge
agent, one repo"; when that section and this table disagree, the role contract
wins and this table is stale (upscale-havens lands through `hub-uh` even though a
`merge-uh` agent exists). Agent ids change; resolve by name every time:

```powershell
& "$env:ProgramFiles\Paseo\paseo.exe" ls -a | Select-String '^\S+\s+(merge|hub)-'
```

## Park URGENT on the right queue

```powershell
$t = "$env:CL_REPOS_ROOT\cl-common\vendor\interactive-qa\tools"
pwsh -NoProfile -File $t\Invoke-IqaPark.ps1 -Repo <repo> -RepoRoot "$env:CL_REPOS_ROOT\<repo>" `
  -Bead <epic-id> -Branch batch/<slug> -Sha <full tip> -Worktree <batch worktree> -Owner <you> -Urgent `
  -Note "<epic> complete; report <path>; contains <branches>; supersedes <branches>; urgent: merge next"
pwsh -NoProfile -File $t\Invoke-IqaQueue.ps1 -Mode Mark -Repo <repo> -RepoRoot "$env:CL_REPOS_ROOT\<repo>" `
  -Branch <contained-or-superseded> -Status superseded -Note "contained in batch/<slug> @ <tip>"
pwsh -NoProfile -File $t\Invoke-IqaQueue.ps1 -Mode List -Repo <repo> -RepoRoot "$env:CL_REPOS_ROOT\<repo>"
```

`-Urgent` is per enqueue: a re-park without it drops the urgency. A `merging`
row is never superseded; leave it to the merge agent.

## Message the merge agent

```powershell
pwsh -NoProfile -File $env:CL_REPOS_ROOT\cl-common\Skills\paseo-child-agents\Send-PaseoMessage.ps1 `
  -To <merge-agent> -AgentId <id from paseo ls> -From <you> `
  -Subject "MERGE NEXT: batch/<slug> @ <short tip> (<epic>)" -File <body.md>
```

Body: high priority: merge this next; branch; tip (full SHA, pushed, queue row
URGENT); base (`origin/<trunk>` SHA, 0 behind); beads; report path; dry-run
verdict; gates with counts; pre-existing reds with the baseline evidence;
contained branches (land with it); superseded branches (do not merge).
`Unknown recipient` means the name is not registered: pass `-AgentId`.

## Measured traps (2026-11-17, cl-common-za6w)

- **A live owner already had the epic.** Coordinating by message and folding its
  pushed branch was faster than rebuilding; its worktree stayed untouched.
- **Generated indexes carry dates.** `Gen-SkillsIndex.ps1` / `hub-ref.mjs index
  --write` rewrite every `updated` date: keep real changes, restore date-only churn.
- **Hash manifests must be computed on a clean tree.** A vendored-helpers
  manifest written while other regenerated files were dirty recorded hashes of
  content that was then restored; re-run `Sync-VendoredHelpers.ps1` last.
- **Two allowlists, two rule vocabularies.** A file hit by both the adapter-seam
  and package-paths gates needs a row in both; package-paths knows only
  `absolute-path`, so its row names only that rule.
- **Resident budget.** Adding a section to `members/iqa-hub/SKILL.md` pushed it
  over 3600 tokens; keep the section a pointer (`hub-ref.mjs budget`).
- **A one-off red under load.** Re-run the single suite on the SAME tip before
  calling it real; record both runs in the report.
- **Wrong queue store.** `currents-bookkeeping/scripts/merge-queue.mjs --repo
  cl-common` read CBK's `.iqa`, not cl-common's: use `Invoke-IqaQueue.ps1` /
  `Invoke-IqaPark.ps1` with `-RepoRoot <target repo>`.
