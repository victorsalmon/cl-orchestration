---
name: opencode-go-dispatch
description: >
  How Claude dispatches work to OpenCode Go workers through Paseo with
  round-robin key rotation, instead of doing the hands-on work in its own
  context or in Claude Code's own subagents. Use when Claude must hand a
  bounded task to a worker (recon, review, fix, code, refactor, simple),
  when it needs several workers at once, or when asked to "dispatch",
  "use opencode", "round-robin the keys" or "spread this across the Go keys".
  This member is the Claude-facing entry; every number and mechanism lives in
  the Paseo skills it points at.
triggers:
  - user
  - model
  - dispatch to opencode
  - opencode go keys
  - round robin keys
  - paseo worker
---

# opencode-go-dispatch - Claude hands work to Paseo OpenCode workers

**Do not restate the numbers here.** Caps, routes, efforts, key pool and
failover are owned by `agent-spawn-capacity`; the spawn contract by `dispatch`
(`paseo-child-agents`); rotation by `dispatch-round-robin`; cost lane by
`cheepseek`. Read those; this file is only what is specific to Claude.

| Need | Owner (read it, load only that) |
| :--- | :--- |
| The spawn contract, brief, ping, recovery | `$env:CL_REPOS_ROOT\cl-common\vendor\interactive-qa\members\dispatch\SKILL.md` |
| Caps, route + effort per work role, failover | `$env:CL_REPOS_ROOT\cl-common\Skills\agent-spawn-capacity\SKILL.md` |
| Round-robin over the OpenCode Go keys | `$env:CL_REPOS_ROOT\cl-common\Skills\dispatch-round-robin\SKILL.md` |
| Fill-one-key-first instead | `$env:CL_REPOS_ROOT\cl-common\Skills\dispatch-waterfall\SKILL.md` |
| Free Zen vs paid Go lane, cache discipline | `$env:CL_REPOS_ROOT\cl-common\Skills\cheepseek\SKILL.md` |
| A worker died, vanished, or is not in the child list | `$env:CL_REPOS_ROOT\cl-common\Skills\paseo-child-agents\SKILL.md` |
| A key is near its cap or spent: **Key Check** (deadline-bounded poll, read-only **Key Status**) and the watch that runs it | `$env:CL_REPOS_ROOT\cl-common\vendor\interactive-qa\members\key-watch\SKILL.md` |
| A key is exhausted and workers must move to a proven replacement (**Key Cutover**), or before a rotation | `$env:CL_REPOS_ROOT\cl-common\vendor\interactive-qa\members\key-cutover\SKILL.md` |

## What is Claude-specific

1. **Claude's own subagents are not Paseo workers.** The Agent tool, forks and
   Workflow agents run inside Claude's session: they are chat-coupled, are not
   rotated over the Go keys, are not visible to `paseo_list_agents`, and cannot
   spawn agents. Use them for reading and judgement that needs this
   conversation's context. Use a Paseo OpenCode worker for bounded, well-briefed
   hands-on work that should run on the Go wallet and outlive the turn.
2. **Only a gate launch rotates.** Rotation happens when a worker is started
   through `vendor/interactive-qa/vendor/dispatch/scripts/run-iqa-worker.ps1` (it defaults to `-Pool auto -DispatchMode
   round-robin`; name `-Pool opencode-go -DispatchMode round-robin` to require
   the Go pool). A worker started from the Paseo desktop, from `paseo_create_agent`
   or from a chat-coupled create tool carries no launch key, lands on the pinned
   `activeKey`, and is cancelled when the user next messages. Do not use them.
3. **Order is fixed: worktree, then begin, then dispatch.** Create the lane's
   worktree first and pass it as `-Workdir`; a writing role refused at the repo
   root is correct (`TRUNK-WRITE-REFUSED`). Never use `-AllowTrunkWrite`.
4. **Send the brief's path, not its text.** Write a brief that passes
   `vendor/interactive-qa/vendor/iqa-merge/Test-DispatchBrief.ps1` (<=80 lines, Role/Deliverable/Gates/Stop, report
   budget, report path), put your own agent id in it as `ParentAgentId`
   (never the worker's `$env:PASEO_AGENT_ID`), and tell the worker to push its
   branch before reporting. Resolve your own id with
   `Skills\paseo-child-agents\Get-PaseoSelfAgentId.ps1`.
5. **Dispatch, then continue; never wait.** The worker pings you on
   completion. A missing ping is *unmeasured*, not done and not dead: check the
   branch tip, the worktree mtimes or a process naming the worktree. Tell the
   user when you started workers, as one line per lane.
6. **Verify before you build on it.** A worker's report is a claim: read its
   diff and its lane report before you close a bead or merge. A worker that
   died mid-write leaves recoverable work in its worktree; read it before
   re-dispatching (see `paseo-child-agents`).
7. **Parallel writers need separate worktrees and one heavy job at a time.**
   Pick lanes by disjoint file footprint; the machine's heavy slot serialises
   builds and suites, so more lanes does not mean more throughput.

## The shape of one dispatch

```powershell
# 1. worktree exists (repo's provision command, or git worktree add)
# 2. brief written and checked
pwsh -NoProfile -File $env:CL_REPOS_ROOT\cl-common\vendor\interactive-qa\vendor\iqa-merge\Test-DispatchBrief.ps1 -Path <brief.md>
# 3. detached, rotated worker
pwsh -NoProfile -File $env:CL_REPOS_ROOT\cl-common\vendor\interactive-qa\vendor\dispatch\scripts\run-iqa-worker.ps1 `
  -Brief <brief.md> -Title "<title>" -Workdir <worktree> `
  -Role <recon|review|grill|fix|code|refactor|simple> `
  -Pool opencode-go -DispatchMode round-robin -ParentAgentId <your-own-id>
```

The launch receipt names the assigned key (for example `OPENCODE_GO8_KEY`).
See live load with
`Skills\agent-spawn-capacity\scripts\AgentCapacity.ps1 -Mode Status -DispatchMode round-robin -AsJson`.
For several workers at once use `vendor/interactive-qa/vendor/dispatch/scripts/run-iqa-wave.ps1` beside it.

## Red lines

- Never put a key value in a brief, a message or a file; names only.
- Never dispatch to OpenRouter or DeepInfra expecting rotation: they are not
  rotation members and the mode is downgraded to `single-active`.
- Never edit the key seam, pin a key or restart Paseo by hand to dodge a dead key: use Key Check / Key Cutover above, which canary the replacement first.
- Never use a free pool as the only route for implementation or review.
- Never pass `-IgnoreCapacity` / `-SkipCapacity`, or force a key past an
  exhausted canary, to get around a cap. Wait, or do the work yourself.
- Never ask the user's permission to start lanes; announce and start them.
