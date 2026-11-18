# omnicode - reference

## Claim and skip

```powershell
bd ready                         # or the repo's priority query, per repo
bd update <id> --claim           # atomic; idempotent for you; refuses another live claim
bd show <id>                     # who holds it, if the claim is refused
```

`--force` overrides another actor's live claim and is for abandoned claims only
(`bd reclaim` is preferred); it is a Stop-and-ask, never a default.

## STEP 0: the landed check

```powershell
git fetch origin
git log origin/dev --oneline --grep "<bead-id>" | Select-Object -First 5
git grep -n "<symbol from the bead>" origin/dev -- <path>
```

Several beads in the 2026-11-14 epic were already on `dev`; closing them with
evidence is cheaper than rebuilding. Close with the commit and file:line.

## Footprint grouping

List the files each bead will touch (`git grep`, the bead's own text). Two beads
that share a file, a package manifest or a workspace package share a lane.
The fleet's own rule: `Skills/git-operations/REFERENCE.md` -> "Batch related
lanes" and `iqa-merge-runner --train` (conflict graph by shared file/package).
Cross-repo: cl-common lands and its dist is stamped before a product consumes it.

## Lanes

```powershell
npm run worktree:provision -- <name> --bead <id> [--branch <b>] [--base dev]
```

The parent starts each lane (Agent tool or a Paseo agent). Brief each lane
standalone: goal, files, exact change, done-state, verify command. A lane that
reports "waiting on its own background work" is not finished; verify state from
git and the queue (see `claude-lane-lessons`). Memory cap: default 5 lanes; one
heavy gate (full test/build) at a time inside a lane.

## Integrate

```powershell
git worktree add .worktrees/<batch> -b batch/<topic> origin/dev
git -C .worktrees/<batch> merge --no-ff <lane-branch>      # per lane
npm run regen:generated                                    # never hand-merge generated files
node scripts/lane-report.mjs --bead <id> --lane <slug> --class code --gate <name>=<exit>
git push origin batch/<topic>                              # the report commit is LAST
```

`COMMIT-MISMATCH`: the report names a SHA other than the tip. Re-run
`lane-report.mjs` after the final commit and commit that file as the last commit.

## Hand-over

```powershell
node scripts/merge-queue.mjs enqueue --repo <repo> --branch batch/<topic> --sha <tip> `
  --worktree <path> --owner <you> --base dev --bead <ids> --urgent --note "omnicode batch: merge next"
Skills/paseo-child-agents/Send-PaseoMessage.ps1 -To <hub> -Subject 'omnicode: merge next' -Body <below>
```

Hub per repo: `hub-cbk` = currents-bookkeeping, `hub-uh` = upscale-havens,
`hub-common` = cl-common (`Skills/paseo-child-agents/REFERENCE.md`). Discover
liveness with `paseo ls` / ListAgents and the hub registry
`~/.machine/state/hubs/<repo>.json` (`heartbeatAt`). A stale or missing hub
means: write the request in the queue note, report, stop.

Message body: branch, tip SHA, beads (closed on land), base, gate evidence
(commands + exit codes, report path), and "high priority: merge this next".
Do not run the merge runner, take the trunk lock, or deploy.

## After the hub lands it

```powershell
git fetch origin; git merge-base --is-ancestor <branch> origin/dev; $LASTEXITCODE   # 0 = landed
bd close <id> --reason "landed <sha>"
```

Report: closed, blocked (reason), next three from `bd ready`.
