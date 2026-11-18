---
name: claude-lane-lessons
description: >
  Durable Claude-specific lessons for running lanes, notifications and
  hand-overs, each as a short rule, the reason, and the check that proves it
  (from the 2026-11-14/15 currents-bookkeeping epic session). Use before
  dispatching lanes as Claude, when a background lane reports done or "waiting",
  when resuming from a cross-session summary, or when recording a lesson that is
  about how Claude works rather than the fleet.
triggers:
  - user
  - model
  - claude lessons
  - lane lessons
  - claude executor lesson
---

# claude-lane-lessons - how Claude works, as checkable rules

Every rule is `rule / why / check` in [references/lessons.md](references/lessons.md).
Where a fleet skill already owns the rule, the entry is a one-line pointer to it;
nothing is duplicated here.

## Index

| # | Rule | Owner |
| :-- | :--- | :--- |
| 1 | Announce and start lanes; never ask permission to start or continue | `~/.claude/CLAUDE.md` (user memory) |
| 2 | The parent dispatches; subagents and forks cannot spawn agents | `git-operations/REFERENCE.md` |
| 3 | STEP 0 landed-check before any dispatch | `omnicode` |
| 4 | "Waiting on its own background work" is not completion | here |
| 5 | Retry loops test ancestry of `origin/dev`, not the runner exit code | here |
| 6 | Read the runner's own log before guessing | here |
| 7 | Never bypass hooks, override locks, or touch foreign files | `git-operations/hooks/README.md` |
| 8 | The lane report proves the tip and is the last commit | `repo-clean/REFERENCE.md` |
| 9 | Generated files are regenerated, not merged | `git-operations/REFERENCE.md` |
| 10 | Batch branches by file footprint; heavy-gate memory cap | `git-operations/REFERENCE.md` |
| 11 | System task-notifications are not user input | here |
| 12 | Claim with `bd update --claim`; skip beads others hold | `omnicode` |
| 13 | "Make this universal" writes memory and `~/.claude/CLAUDE.md` | here |
| 14 | Summaries lose live state; re-verify with `git fetch` + `bd` | here |
| 15 | Outward actions (deploy, push, send) need the user's word | here |

Add a lesson only when a future Claude run would otherwise relearn it; task
state and history never belong here.
