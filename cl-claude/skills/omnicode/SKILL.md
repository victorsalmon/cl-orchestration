---
name: omnicode
description: >
  /omnicode - claim a set of beads, complete them in a massively parallel
  fashion on multiple worktrees, batch-merge the lane branches into one gated
  batch branch, then send a high-priority merge request to the hub in charge of
  the repo asking it to merge that branch next. Claude runs it; it never lands
  its own work. Use on "/omnicode", "omnicode", "claim these beads and run them
  in parallel", or when asked to deliver many beads at once and hand them to
  the hub.
triggers:
  - user
  - model
  - omnicode
  - /omnicode
  - claim these beads
  - massively parallel beads
---

# omnicode - claim, parallelise, batch, hand over

The definition: *claim these beads; complete them massively parallel on
multiple worktrees; batch-merge your worktrees; send a high-priority merge
request to the hub in charge of the repo, saying to merge your branch next.*
Detail, commands and message template: [REFERENCE.md](REFERENCE.md).
Claude-only lessons behind the gates: `../claude-lane-lessons/SKILL.md`.

**You are the parent. Announce the lanes and start them; never ask permission.**
Subagents and forks cannot spawn agents, so the parent starts every lane.

## Steps

1. **Claim.** Resolve the bead set (arguments, else `bd ready` / the repo's
   priority query). `bd update <id> --claim` each; a bead held by another actor
   is skipped and named in the report (never `--force`).
   *Done when:* every bead is claimed by you or listed as skipped-with-holder.
2. **STEP 0, per bead: prove it is not already landed.** Search `origin/dev`
   (`git fetch`, file:line, `git log --grep <bead>`, the tests). Landed: close
   the bead with that evidence and drop it. Never rebuild landed work.
   *Done when:* each remaining bead has a stated "not on origin/dev" proof.
3. **Group into lanes by file footprint.** Disjoint footprints run in parallel;
   overlapping or dependent beads share one lane, one commit each. Protected
   surfaces (RLS, auth, money, migrations, secrets) get their own fully gated
   lane. Cross-repo order: cl-common first (dist stamped), then the product
   migration with no behaviour change, then the other product's bead.
   *Done when:* a lane table (beads, footprint, repo) exists.
4. **One worktree + branch per lane**, `npm run worktree:provision -- <name>
   --bead <id>` (or the repo's equivalent), under `.worktrees/`. One commit per
   bead. Cap lanes by machine memory (default 5); one heavy gate at a time per
   lane; exit `3221225773` is commit-limit exhaustion, retry, not red.
   *Done when:* every lane has its commits pushed and a lane-scoped gate green.
5. **Integrate.** Merge lane branches into one short-lived batch branch;
   regenerate generated files (`npm run regen:generated`), never hand-merge;
   gate the merged tree once; write the lane report as the **last** commit so
   it proves the tip (a report for another SHA is `COMMIT-MISMATCH`).
   *Done when:* tip = report SHA = pushed SHA, gates recorded in the report.
6. **Hand over, do not self-land.** Enqueue the batch with `--urgent`, then
   message the repo's hub (names, discovery and template in REFERENCE.md) with
   branch, tip SHA, beads, base, gate evidence and "merge this next". No live
   hub: record the request in the queue note and report.
   *Done when:* the queue row exists and the message `Delivered: true` (or the
   no-hub note is written).
7. **Report.** Beads closed, blocked (reason), next three ready. Close a bead
   only after the hub lands it.

## Stop and ask

- A protected-surface diff would need `--allow-report-override`, a lock
  override, `--no-verify`, or any hook bypass: stop; those are never yours.
- Two beads need contradictory changes to one file: stop, the user decides.
- A step needs an outward action (deploy, send, push to a shared trunk): stop,
  it needs the user's word. `omnicode` itself never deploys.
- A rewrite of stored data, or a bead held by another actor you would have to
  `--force`: stop.

## Verify after any runner exit

`git merge-base --is-ancestor <branch> origin/dev` after a `git fetch`. Exit 0
from the runner with "nothing actionable" is **not** landed; read the runner log.
