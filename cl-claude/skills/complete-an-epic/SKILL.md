---
name: complete-an-epic
description: >
  "Complete an Epic (in <repo>)" - show the open epics of every product repo
  (cl-common, currents-bookkeeping, upscale-havens), or only of the named repo,
  in priority order; wait for the operator to pick; then build the picked epic
  in parallel lanes, fold them into one gated batch branch, park it URGENT on
  THAT repo's merge queue and message THAT repo's merge agent (merge-common /
  merge-cbk / hub-uh) to merge it next. Claude never lands the branch itself.
  Use on "Complete an Epic", "complete an epic in <repo>", "which epics are
  left", or "finish epic <id> and send it to merge".
triggers:
  - user
  - model
  - complete an epic
  - complete epic
  - finish the epic
  - epics remaining
  - which epics are left
---

# Complete an Epic - menu, pick, build, hand to the repo's merge agent

Two turns. **Turn 1 shows the menu and stops**: the epic choice is the
operator's. **Turn 2 builds what they picked** and ends with a hand-over, never
a merge. Commands, per-repo tools and measured traps: [REFERENCE.md](REFERENCE.md).
How lanes are built: [`omnicode`](../omnicode/SKILL.md) (flat epic) or
[`epic-worktree`](../../../../../Skills/epic-worktree/SKILL.md) (phase-coupled epic). This
skill does not restate them.

## Turn 1 - the menu

1. Run the menu: `node <this skill>/scripts/epic-menu.mjs` for every product
   repo, or `--repo <repo>` when the operator said "in <repo>".
   *Done when:* every repo printed its epics, or printed `CANNOT-EVALUATE` with
   the reason (a repo that could not be read is never shown as "no epics").
2. Show it: per repo, numbered, priority order, `closed/total` children, and the
   flags `close-only` (every child closed: closing needs no build) and
   `no child beads` (a goal epic: its work must be cut first). Name the merge
   agent beside each repo. Then stop and let the operator pick.

## Turn 2 - build the picked epic(s)

1. **Own it or coordinate.** `bd show <epic>`. If a live agent holds the epic
   (assignee, an `epic/*` branch, a queue row, a worktree), message it and fold
   its pushed branch; never write into its worktree. Otherwise `bd update --claim`.
   *Done when:* you hold the claim, or the owner has agreed the split in writing.
2. **STEP 0 + cut.** Prove each open child is not already on `origin/<trunk>`
   (close landed ones with the evidence); find branches that already carry the
   work (contained / superseded). Group the rest into lanes by file footprint.
   *Done when:* a lane table exists: beads, footprint, branch it starts from.
3. **Lanes in parallel.** Announce and start them (never ask). One worktree per
   lane under `<repo>/.worktrees/`, from the current `origin/<trunk>`.
   *Done when:* every lane is pushed with its own gate green.
4. **One batch branch.** `batch/<epic-slug>` from `origin/<trunk>`; merge every
   lane and every contained branch `--no-ff`; regenerate generated files (never
   hand-merge them); run **the train's own gate plan** for that repo, and prove
   any red on a baseline worktree at `origin/<trunk>` before calling it
   pre-existing. *Done when:* every gate is green or proven pre-existing.
5. **Report last.** The repo's lane report names the code tip SHA (9+ hex) with a
   positive Status; it is the last commit. Push the branch.
   *Done when:* pushed SHA = branch tip, and the report proves the tip.
6. **Hand over to the RIGHT repo.** Park URGENT on that repo's queue (pass that
   repo's main checkout as the root), mark contained / superseded rows, dry-run
   the repo's merge runner for the branch, then message that repo's merge agent:
   branch, tip, beads, base, gate evidence, report path, contained and superseded
   branches, "high priority: merge this next".
   *Done when:* the queue row reads `queued URGENT @ <tip>` in that repo's store,
   the dry run says `ready`, and the message reports `delivered`.
7. **Report to the operator.** What is queued where, which agent has it, what
   was pre-existing red, and any operator-only residual. Close beads only after
   the merge agent lands the branch (`git merge-base --is-ancestor`).

## Stop and ask

- The operator has not picked an epic (Turn 1 always ends here).
- The epic is owned by a live agent that refuses the split.
- A gate would need a bypass, a lock override or `--allow-report-override`.
- The merge agent for the repo is not known or not live: write the request in
  the queue note, report it, and do not merge it yourself.
