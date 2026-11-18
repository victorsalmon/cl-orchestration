# agent-unarchive — reference detail

Full detail for [`SKILL.md`](SKILL.md). Every section below is normative; the entry
point names which one to read when.

## 1. Read the state (read-only, always first)

| Fact | File / call | What it tells you |
| :--- | :--- | :--- |
| Projects | `~/.paseo/projects/projects.json` | Which projects exist. An **archived** project keeps its row with `archivedAt` set; a **deleted** project's row is **gone** while its workspaces still reference the dead id. |
| Workspaces | `~/.paseo/projects/workspaces.json` (can be MBs) | Every workspace, active and archived, with `projectId`, `cwd`, `title`, `archivedAt`. This is the authoritative record of what was archived and when. |
| Agents | `~/.paseo/agents/<cwd-slug>/<agentId>.json` (thousands) | Per-agent record: `title`, `cwd`, `workspaceId`, `lastStatus`, `archivedAt`, and crucially `persistence.sessionId` / `nativeHandle` (the resumable provider session). |
| Daemon log | `~/.paseo/daemon.log` | `"msg":"Workspace archived"` lines carry `workspaceId`, `projectId`, `projectArchived` and the exact `archivedAt`. This is how you date the event and prove the cascade. |
| Live truth | `paseo_list_workspaces`, `paseo_list_agents` | What the daemon currently believes. Archived entries do **not** appear. |

Fast triage for "which agents were running when it happened":

```powershell
$rows = Get-ChildItem "$env:USERPROFILE\.paseo\agents" -Recurse -Filter *.json | ForEach-Object {
  try { $j = Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { return }
  [pscustomobject]@{ id=$j.id; title=$j.title; cwd=$j.cwd; ws=$j.workspaceId
    last=$j.lastStatus; updated=$j.updatedAt; archived=$j.archivedAt
    parent=$j.labels.'paseo.parent-agent-id' }
}
$rows | Where-Object { $_.updated -gt '<archive-time minus 30min>' } | Sort-Object updated
```

Batch-archived lanes share timestamps within a second or two — that cluster is
the incident, and the parent label tells you which Hub lost its workers.

---

## 2. Decide what was actually lost

Check these in order; the first is almost always the real answer.

1. **Git work.** Nothing an archive does touches a checkout. For every affected
   repo and lane worktree record: branch, HEAD, `status --porcelain`,
   `log --branches --not --remotes` (unpushed commits), and `ls-remote` for the
   true remote tip — **never trust a stale `refs/remotes/origin/*`**.
2. **Uncommitted lane work.** A lane whose agent was killed mid-edit leaves its
   dirty tree in place. This is the only genuinely at-risk asset. Preserve it
   (§4) before anything else touches the checkout.
3. **Stashes and dangling commits.** `git stash list`, `git fsck --lost-found`.
   Old foreign stashes are normal; today's are evidence.
4. **The agent's own transcript.** `paseo_get_agent_activity` reads an archived
   agent's timeline. Their last report usually names exactly what they had
   landed and what remained.
5. **Hub ownership.** Claims and registry entries survive independently of the
   UI (see §5).

---

## 3. Why the UI cannot just "unarchive" — the orphan trap

Measured 2026-11-07 on a currents-bookkeeping Hub project:

- Archiving a **project** removes its row from `projects.json`, but every
  workspace keeps `archivedAt` and its now-dead `projectId`. The result is
  **orphaned workspaces**: they are archived, and they have no project to be
  shown under, so nothing in the UI can reach them.
- Opening a new workspace for the same `rootPath` makes Paseo **auto-create a
  fresh project** for that path. You now have a live project and a set of
  invisible orphaned workspaces that used to belong to the old id.
- There is **no unarchive tool** in the Paseo MCP surface.
  `paseo_rename_workspace` on an archived workspace refuses, verbatim:
  `Workspace wks_… is archived`. `paseo_archive_agent`/`paseo_archive_workspace`
  have no inverse.

### The two real recovery routes

**Route A — re-point the orphaned workspace at the live project (preferred).**

1. Back up: `Copy-Item workspaces.json "$p.bak-recovery-$(Get-Date -f yyyyMMddTHHmmss)"`.
2. In `workspaces.json`, on the single workspace record, set
   `"projectId"` to the **live** project for that path and `"archivedAt": null`.
   Keep the edit surgical (exact string replace of the record block); do not
   round-trip the whole multi-MB file through `ConvertTo-Json`.
3. **The daemon caches state.** The edit is inert until the daemon restarts, and
   a daemon write from memory will revert it. Verify with
   `paseo_list_workspaces` before claiming success; if it did not appear, say so
   rather than reporting a restore.
4. A restart is the only way to make it take effect — **never restart while
   another agent is mid-turn**, because the restart ends those turns.

**Route B — adopt.** If the old Hub is wedged, re-establish ownership (§5) and
run the work under a new Hub instead of restoring the old one. This is usually
cheaper and always safer than a restart.

---

## 4. Preserve uncommitted lane work (do this before any cleanup)

Never `git add -A`; never commit in someone else's checkout without labelling it.

1. **Patch bundle outside the repo** (survives any later checkout/clean):
   ```powershell
   $out = "$env:USERPROFILE\.machine\state\recovery\<date>-<incident>"
   git -C $lane diff --binary    > "$out\<lane>.tracked.patch"
   git -C $lane status --porcelain | Where-Object { $_ -match '^\?\?' } |
     ForEach-Object { $_.Substring(3).Trim('"') } | Set-Content "$out\<lane>.untracked.txt"
   # copy each untracked file under $out\<lane>.untracked\ preserving its path
   ```
2. **Labeled WIP commit on the lane branch** (holding point, never pushed):
   ```powershell
   git -C $lane add -- <explicit paths, including each untracked file>
   git -C $lane -c user.name="paseo-recovery" -c user.email="recovery@local" `
       commit -m "wip(recovery): preserve <lane> work left uncommitted by <incident>"
   ```
   Stage the **tracked modifications too** — `git add -- <untracked>` alone
   commits only the new files and looks clean while the real diff is still dirty.
   Re-check `status --porcelain` afterwards; expect **0** remaining entries.
3. Report the WIP SHA and say plainly that it is a holding point, not a
   review-ready change.

---

## 5. Re-establish Hub ownership (the part that silently fails)

An archived agent is **not** a dead agent, and Paseo's ownership helpers are
built on liveness, not on the archive flag.

1. `Invoke-HubClaim.ps1 -Mode Status` will report
   `YIELD / code: peer-agent-alive` while the archived Hub's record still says
   `status: idle`. **Age is not death**; the registry's `live: false` does not
   override a live peer agent.
2. Retire the old owner deliberately, in this order:
   - `paseo_archive_agent <oldHubId>` (stops it counting as alive), then
   - `HubRegistry.ps1 -Mode Clear -Repo <repo> -AgentId <oldHubId>` — this also
     **releases the old claim** (`claimReleased: True`).
3. Then claim: `Invoke-HubClaim.ps1 -Mode Acquire -Role hub` →
   `dispatch: true`, `claim.ownerAgentId = <you>`; `HubRegistry.ps1 -Mode Register`;
   set `hub-<x>` + `iqa-role=merge` labels; print the `Find` self-verdict
   (`state: live`, `primaryAgentId: <you>`).
4. The trunk lease must be held from a **persistent** shell. A lease acquired by
   `pwsh -File script.ps1` records that short-lived pid and immediately reads
   `Live: false` / `stale lease present`. Hold it from an interactive `pwsh`
   terminal (Paseo terminal session) and confirm `Held: True`, `Live: True`,
   `Reason: held by live owner`.

---

## 6. Turn collisions and the 60-second queue rule

**The symptom:** sending a prompt to an agent returns
`[System Error] OpenCode session already has an active turn`, and the agent
flips to `status: error` with `lastError` = that string.

**Why it happens (measured):**

1. An archive request can fail to cancel the running turn. The daemon logs
   `AgentRunCancellationError: Cannot replace agent <id> because its active run
   cancellation was not acknowledged`, then later `Agent resumed from
   persistence` — the provider session keeps its turn. A Hub archived at 21:46
   went on merging into `dev` until 21:54.
2. The Paseo agent record and the provider session disagree: Paseo reports
   `idle` (or `error`) while the provider still has an open turn. A prompt then
   has nowhere to go and the provider refuses it.
3. A long turn is the trigger. A Hub that runs a 50-minute battery *in its own
   session* is unreachable for prompts for 50 minutes, and every dispatch
   attempt in that window collides.

**How to avoid it:**

- **Obey the 60-second rule.** A Hub turn should never run a command that takes
  longer than ~60 s. Dispatch long work (tests, builds, mutation, batteries) to
  a subagent and read its report. A Hub that only dispatches and merges is
  always promptable within a minute.
- **Queue, do not interrupt.** `paseo_send_agent_prompt` takes
  `activeTurnBehavior`: `steer` (join the running turn; the default for agent
  callers) or `interrupt` (replace it). Steering is what you want for a working
  agent; `interrupt` on a wedged session is what produces the collision error.
- **Check before prompting.** `paseo_get_agent_status` →
  `activeTurn != null` or `lastError == "OpenCode session already has an active
  turn"` means: do not prompt, wait or retire it.
- **One owner per repo.** Two Hubs prompt each other into this state; the claim
  helper exists to prevent exactly that — obey its `YIELD`.
- **A collision is not the work failing.** The turn that was running usually
  completes; read `paseo_get_agent_activity` before concluding anything was
  lost. Marked `error` is the prompt's status, not the agent's work.

---

## 7. Verification checklist (print all of it; a promise is not a receipt)

- [ ] The archive event is dated from `daemon.log` with the workspace ids.
- [ ] Every affected repo is enumerated with branch, HEAD, `status`, unpushed
      commits, and the **live** remote tip (`ls-remote`).
- [ ] Uncommitted lane work is preserved twice: patch bundle outside the repo
      **and** a labeled WIP commit; `status --porcelain` is empty afterwards.
- [ ] The agent record for each lost lane is named with its resumable
      `persistence.sessionId`.
- [ ] Restored workspace: verified through `paseo_list_workspaces`, not through
      the file edit — or explicitly reported as "file patched, daemon restart
      required".
- [ ] Hub adoption: claim `ACT` + owner = you, `Register` ok, labels set,
      `Find` = live, lease `Held: True` / `Live: True` from a persistent shell.
- [ ] Anything operator-gated (human spot-check, money, prod deploy, legal
      sign-off) is named as waiting on the operator, never closed on their
      behalf.

## Gotchas that have already cost a session

| Symptom | Cause | Fix |
| :--- | :--- | :--- |
| Workspace vanished, project still shows | Project deleted, workspaces orphaned | §3 Route A, or adopt |
| Edited `workspaces.json`, nothing changed | Daemon caches state | Verify via the tool; restart only when no agent is mid-turn |
| `Workspace … is archived` on rename | No unarchive surface exists | Restore via §3, or adopt |
| Archiving "succeeded" but the agent keeps working | Cancellation not acknowledged | Read `daemon.log` for `AgentRunCancellationError`; treat the agent as live |
| Prompt returns "already has an active turn" | Prompt landed in a running/wedged turn | Do not re-prompt; read activity, or retire the agent and adopt |
| Hub claim says `peer-agent-alive` for a Hub you archived | Liveness ≠ archive flag | Archive the agent, then `HubRegistry -Mode Clear -AgentId <old>` |
| Lease says `Live: false` right after acquiring | Recorded pid exited with `pwsh -File` | Hold the lease from an interactive terminal |
| "Lane worktree" edits show up in the trunk | `.worktrees/<name>` with no `.git` file is not a registered worktree | `git worktree list` first; recreate with `git worktree add` |
