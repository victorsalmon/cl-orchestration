# Claude lane lessons

Source: the 2026-11-14/15 currents-bookkeeping epic session. Format: rule, why,
check. Entries owned by a fleet skill are pointers only.

## 1. Announce and start lanes; never ask permission
Owner: the user's standing instruction in `~/.claude/CLAUDE.md` ("Continuing
work"). Say "starting the lanes" and start them. Stop only for genuine
blockers: a user decision, a stored-data rewrite, a hard-to-reverse outward
action.

## 2. The parent dispatches
Owner: `Skills/git-operations/REFERENCE.md` ("A fork cannot spawn agents").
A fork told to start lanes can only report that the parent must. Brief forks and
subagents with work they can do themselves. Check: the parent's transcript, not
the worker's, contains the lane-start calls.

## 3. STEP 0: prove the bead is not already landed
Owner: `omnicode`. Why: several beads in the epic were already on `dev`.
Check: `git fetch`, then `git log origin/dev --grep <bead>` and `git grep` on the
named symbol, before any worktree is cut.

## 4. "Waiting on its own background work" is not completion
Why: an interim task notification from a lane means it has not finished, and a
lane marked completed can leave a retry loop running. Check: git (branch tip,
`git merge-base --is-ancestor <branch> origin/dev`) and the merge queue
(`node scripts/merge-queue.mjs list --repo <repo> --bead <id>`), never the
notification text. Liveness measurement: `Skills/paseo-child-agents/SKILL.md`
("Liveness is measured by artifact movement, never by a heartbeat").

## 5. Retry loops test ancestry, not the exit code
Why: runner exit 0 with "nothing actionable" is not a landing. Check: after each
attempt, `git fetch origin; git merge-base --is-ancestor <branch> origin/dev`;
loop until it exits 0 or the attempt budget is spent.

## 6. Read the runner's own log first
Why: measured causes were not the guessed ones: exit 255 was a git fetch SSH
drop (retryable), and "nothing actionable" was a stale lane report naming a
different SHA. Check: open the runner log and quote the line that names the
cause before changing anything.

## 7. Never bypass hooks, override locks, or touch foreign files
Owner: `Skills/git-operations/hooks/README.md` and the repo AGENTS.md
"Concurrent agents". No `--no-verify`, no `core.hooksPath=NUL`, no lock
overrides, and leave files you did not author (for example `.rc-plan.txt`) alone;
name them in the report. Check: `git diff --cached --name-only` lists only your
paths.

## 8. The lane report proves the tip and is the last commit
Owner: `Skills/repo-clean/REFERENCE.md` (close-out refusals `NOT-PUSHED` /
`COMMIT-MISMATCH`). A report for a different SHA makes the runner find nothing
actionable. Check: report SHA equals `git rev-parse HEAD` of the pushed tip.

## 9. Regenerate generated files
Owner: `Skills/git-operations/REFERENCE.md` ("A generated-file conflict is
regenerated, never hand-merged"). Check: `npm run regen:generated` then
`npm run check:generated` (currents-bookkeeping).

## 10. Batch branches by footprint; cap heavy gates
Owner: `Skills/git-operations/REFERENCE.md` ("Batch related lanes"; exit
`3221225773` is commit-limit exhaustion, retry). One heavy gate at a time per
lane; default 5 lanes. Plan the merge train by file footprint, not bead count.

## 11. System task-notifications are not user input
Why: background-task completion events arrive in the user channel but carry no
user words and grant no approval. Check: before any outward action, point at an
actual user message that authorised it.

## 12. Claim, and skip what others hold
Owner: `omnicode`. `bd update <id> --claim` is atomic and refuses another live
claim; skip, name the holder, never `--force` a live claim.

## 13. "Make this universal" means persist it
Why: a rule the user says to make universal must survive the session. Check:
the rule appears in the project memory file and in `~/.claude/CLAUDE.md`, and a
fresh session would read it.

## 14. Re-verify after a handoff
Why: a cross-session summary loses live state (a lane may have landed, a bead
may be claimed by another). Check: `git fetch`, `git status`, `bd show <id>` and
the queue before acting on any claim in the summary.

## 15. Outward actions need the user's word
Deploy, push to a shared trunk, send messages, close beads before the hub lands
them: only on an explicit user instruction in chat. Handing a request to the hub
(`omnicode` step 6) is inside the user's `/omnicode` request; a deploy is not.
