---
name: agent-unarchive
description: >-
  Recover a Paseo project, workspace or agent that was archived or deleted by
  accident, and re-establish the work that was running under it. Covers what
  actually survives an archive (agent records, opencode session ids, git
  worktrees, uncommitted lane work), why the UI cannot simply "unarchive" an
  orphaned workspace, the claim/registry takeover an adopting Hub must perform,
  and the turn-collision trap where a prompt into a still-running archived
  agent returns "OpenCode session already has an active turn". Use when a
  project/workspace/agent disappeared, when 7 lanes vanished mid-run, when an
  archived Hub is still alive and holding the repo claim, or when asked to
  recover lost agent work.
triggers:
  - user
  - model
  - unarchive
  - archived project
  - archived workspace
  - lost agents
  - recover work
  - project disappeared
  - paseo archive
---

# agent-unarchive — recovering an archived Paseo project, workspace or agent

An archive in Paseo is **soft**. Almost nothing is destroyed: the agent record,
the provider session id, the worktree, the uncommitted files and the git history
all survive. What is lost is **visibility and ownership** — and both are
recoverable if you read the state before you touch anything.

Work the steps in order. Steps 1–3 are read-only; do not skip to repair.

## Start here

1. **Read the state.** `projects.json`, `workspaces.json`, the per-agent records
   and `daemon.log` date the archive and name the affected workspaces and lanes.
   Live truth is `paseo_list_workspaces` / `paseo_list_agents`. → REFERENCE §1.
2. **Decide what was actually lost.** Git work first, then uncommitted lane
   work, then stashes, the agent's own transcript, and Hub ownership. The dirty
   lane tree is the only genuinely at-risk asset. → REFERENCE §2.
3. **Preserve uncommitted lane work before any cleanup** — a patch bundle
   outside the repo **and** a labeled WIP commit on the lane branch. → §4.
4. **Restore visibility.** The UI cannot unarchive an orphaned workspace: an
   archived project's row is gone while its workspaces keep the dead
   `projectId`. Re-point the single workspace record at the live project (Route
   A, inert until a daemon restart) or adopt the work under a new Hub (Route B,
   usually cheaper and always safer). → §3.
5. **Re-establish Hub ownership deliberately.** An archived agent is not a dead
   agent; liveness, not the archive flag, drives the claim. Retire the old
   owner, then claim, register, label, and hold the trunk lease from a
   persistent shell. → §5.
6. **Avoid the turn collision.** A prompt into a session whose turn never ended
   returns "OpenCode session already has an active turn". Obey the 60-second
   rule, queue instead of interrupting, and check status before prompting.
   → §6.

## Red lines

- Never restart the daemon while another agent is mid-turn — the restart ends
  those turns.
- Never `git add -A`, and never commit in someone else's checkout without
  labelling it.
- Never trust a stale `refs/remotes/origin/*`; read the true tip with
  `ls-remote`.
- A file edit to `workspaces.json` is not a restore until
  `paseo_list_workspaces` shows the workspace back.
- Anything operator-gated (human spot-check, money, prod deploy, legal sign-off)
  is named as waiting on the operator, never closed on their behalf.
- A recovery is proven by printed output, not asserted: the §7 checklist, plus
  `vendor/interactive-qa/vendor/iqa-merge/Invoke-HubClaim.ps1 -Mode Status` and `paseo_get_agent_status` for the
  ownership rows, before you report it done.

## Reference

The full procedure, the verification checklist and the symptom→cause→fix table
live in [REFERENCE.md](REFERENCE.md). Its sections:

- §1 Read the state (read-only, always first)
- §2 Decide what was actually lost
- §3 Why the UI cannot just "unarchive" — the orphan trap, Routes A and B
- §4 Preserve uncommitted lane work (do this before any cleanup)
- §5 Re-establish Hub ownership (the part that silently fails)
- §6 Turn collisions and the 60-second queue rule
- §7 Verification checklist (print all of it; a promise is not a receipt)
- Gotchas that have already cost a session
