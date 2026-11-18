---
name: cl-orchestration
description: >
  Use when driving multi-agent work: orchestrating a run, dispatching background
  subagents or detached Paseo workers, moving plans through the queue, recording
  manual tasks, or pairing interactively with the user. Front door for
  orchestration on this machine; pick the member below that matches the task and
  load only that one. Covers the top-level coordinating role, the subagent
  dispatch contract, detached child agents and parentage repair, the
  human-driven pipeline, queue/task records, and cowork
  pair-work with its handoff tooling.
triggers:
  - user
  - model
  - orchestrate
  - subagent
  - dispatch
  - cowork
---

# cl-orchestration — multi-agent orchestration plugin runbook

Seven members cover multi-agent work: the orchestrator role, background
subagents, detached workers, queue mechanics, task records, and pair-work. Read
the table, pick **one** member, then load only that member's file.

## Which member for which task

| Task | Member | Canonical path |
| :--- | :--- | :--- |
| Coordinate a repository backlog using the IQA Hub and beads | `orchestrator` | [Work Now](../../../Skills/work-now/SKILL.md) |
| Build one coupled epic on a private `epic/<name>` root with phase-forked lane swarms, then land `dev` once | `epic-worktree` | [Epic worktree](../../../Skills/epic-worktree/SKILL.md) |
| Contract for dispatching background subagents from a Paseo-driven OpenCode session (`paseo_create_agent` + `notifyOnFinish`, durable briefs, never block) | `subagent-dispatch` | [Subagent dispatch](../../interactive-qa/members/dispatch/SKILL.md) |
| Detached `paseo run --no-wait` workers that survive the user's next message; per-harness mechanics, parent linkage, `ParentAgentId: null` diagnosis | `paseo-child-agents` | `Skills/paseo-child-agents/SKILL.md` |
| Manually coordinate an explicitly scoped repository workflow | `manual-orchestration` | `Skills/saas-common/manual-orchestration/SKILL.md` |
| Manual task records: capture work that needs a human, and route dispatch to the owning runbook | `task-management` | `Skills/task-management/SKILL.md` |
| Interactive pair-work with the user: build → test → refine, record findings, write handoff | `cowork` | `Skills/cowork/SKILL.md` |
| Helper scripts and handoff artifacts used by cowork | `cowork-tooling` | `Skills/cowork-tooling/SKILL.md` |
| Produce the operator's **Work Report** (features, completeness, spend per 24-hour period, MEASURED vs ESTIMATED) | `work-report` | `$env:CL_REPOS_ROOT\cl-common\Skills\work-report\SKILL.md` |
| Keep a durable per-repo record of what happened (completions, caught-and-fixed, unresolved, blockers) for unattended runs | `active-history` | `$env:CL_REPOS_ROOT\cl-common\Skills\active-history\SKILL.md` |
| Report this session's task/bead to subagent mapping and live subagent state on demand | `subagent-status` | `$env:CL_REPOS_ROOT\cl-common\Skills\subagent-status\SKILL.md` |
| Route or triage handoff records (repo-scoped `Tasks/00Handoff/` vs machine-scoped `~/.machine/state/handoffs/`) | `handoff` | `$env:CL_REPOS_ROOT\cl-common\Skills\handoff\SKILL.md` |
| Package work for an **external reviewer** (Sol 6.1) inside one token budget and apply the returned decisions | `sol-handoff` | `$env:CL_REPOS_ROOT\cl-common\Skills\sol-handoff\SKILL.md` |
| Dispatch an **expert** model (Sol 6.1 high, Opus 5.5 xhigh) on a diff-only, read-list contract checked against its token budget; profiles in `experts.json` | `expert-dispatch` | `$env:CL_REPOS_ROOT\cl-common\Skills\expert-dispatch\SKILL.md` |
| Interrogate the agent's own uncertainty, then hand back the user actions that unblock future work, most urgent first | `unblock` | `$env:CL_REPOS_ROOT\cl-common\Skills\unblock\SKILL.md` |
| **Do your CC**: finish session work, update docs/tests/skills, commit, land, deploy, report | `completion-checklist` | `$env:CL_REPOS_ROOT\cl-common\Skills\completion-checklist\SKILL.md` |

## Run order: the cost ladder

Cheapest tier that can decide the question, expensive tiers batched. Static
(seconds) → unit (~1 min) → integration (~30 min) → live journey (~20–25 min) →
mutation (hours): merge the batch then test once at the tip, never run a higher
tier for a lower-tier question, fail fast on entry-point gates, deploy once per
batch, and run no suites inside a read-only survey.

Full table with the measured numbers, the six rules and their evidence:
[REFERENCE.md](REFERENCE.md) § "The cost ladder".

Enforced by: every gate claim names the tier that decided it.

## Disambiguation

**`subagent-dispatch` vs `paseo-child-agents`** — complementary, not duplicates.
Use **`subagent-dispatch`** by default for in-session dispatch
(`paseo_create_agent` + `notifyOnFinish: true`, one durable brief per worker,
fleet default harness, then return control; treat completions as events). Switch
to **`paseo-child-agents`** when the dispatch must survive the user's next
message (detached `paseo run --no-wait`), when a worker dies, vanishes or blocks, when
one is missing from the parent's child list, or for per-harness modes/models and
the `ParentAgentId: null` repair. `subagent-dispatch` links here for per-harness
mechanics rather than duplicating them. Both runbooks are additionally fronted
by **`cl-paseo`** (`vendor/cl-orchestration/cl-paseo/SKILL.md`) — the canonical owner of Paseo
agent mechanics (attached vs detached, the brief → report → ping handshake,
supervision). This plugin owns driving the work; `cl-paseo` owns how agents
dispatch. Link there for mechanics, do not duplicate them here.

**Backlog and manual work.** Use [Work Now](../../../Skills/work-now/SKILL.md) for the live
backlog and [IQA dispatch](../../interactive-qa/members/dispatch/SKILL.md)
for assignment. Record human work through `task-management`. The former
Devin Salmon Run review drain is retired. Use [IQA Hub](../../interactive-qa/members/iqa-hub/SKILL.md)
for live review coordination.

**`cowork` vs `cowork-tooling`.** `cowork` is the *workflow* — interactive
pair-work through the Phase 0–4 build → test → refine loop, ending in handoff
documents. `cowork-tooling` is its *toolbox*: the verified helpers
(`Skills/cowork/Scripts/New-CredentialRef.ps1`, `Skills/cowork/Scripts/New-FinalHandoff.ps1`, `Skills/cowork/Scripts/New-ForkStub.ps1`,
`Skills/cowork/Scripts/New-LockHeader.ps1`, `Skills/cowork/Scripts/New-ManualTask.ps1`, `Skills/cowork/Scripts/New-MemoryEntry.ps1`,
`Skills/cowork/Scripts/New-PostHocPlan.ps1`, `Skills/cowork/Scripts/New-SessionLog.ps1`), their JSON contract
(`Skills/cowork/cowork-scripts.schema.json`), and the handoff artifacts.

## Layout

```
<plugin>/
  SKILL.md     # this runbook
  skills-index.json  # generated member index
```

See [fleet orientation](../../../AGENTS.md) for shared rules.

## Reference

Continued in [REFERENCE.md](REFERENCE.md), starting at:

- `## Order of operations`

That detail was moved out to keep this skill within the progressive-disclosure
budget; nothing was removed.
