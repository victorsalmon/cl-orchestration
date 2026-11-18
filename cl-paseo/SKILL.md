---
name: cl-paseo
description: >
  Single front door for the Paseo ecosystem on the fleet: agent dispatch
  (attached background subagents and detached workers that survive chat),
  concurrency rails, automated code-first health diagnostics (Test-PaseoHealth),
  one-stop repair (Repair-PaseoHealth), config management, host rescue, and the
  model-choice layer that feeds dispatch - appraising a model, picking a cost
  lane, and round-robin or waterfall key dispatch.
triggers:
  - user
  - model
  - dispatch
  - subagent
  - worker
  - paseo
  - detached
  - paseo health
  - repair paseo
  - model choice
  - appraise model
  - cost lane
---

# cl-paseo - Paseo Agent & Host Management Plugin

The unified home for all Paseo operations across the fleet: dispatching agent teams,
enforcing concurrency rails, diagnosing runtime failures, and repairing host/config
issues.

## Quick Diagnostic & Health Gate

Before dispatching or when Paseo reports errors, run the automated health check:

```powershell
pwsh -File "$env:CL_REPOS_ROOT\cl-common\vendor\cl-orchestration\cl-paseo\scripts\Test-PaseoHealth.ps1"
```

To automatically fix detected issues (stale locks, service collisions, PATH bloat):
```powershell
pwsh -File "$env:CL_REPOS_ROOT\cl-common\vendor\cl-orchestration\cl-paseo\scripts\Repair-PaseoHealth.ps1"
```

Repo Health's full picture — the repo-state probes in `scripts/Test-RepoHealth*.ps1` plus
process health plus the branch and worktree inventory, prioritized so the first line is the
problem, and with **branch counts and statuses always in the headline** — is
`pwsh -NoProfile -File "$env:CL_REPOS_ROOT\cl-common\Skills\cl-clean\scripts\Get-HealthReport.ps1" -Repo <name>`
(`-All -Quiet` for the fleet). Those probes are inputs to it.

---

## Which Member for Which Task

Read this table, pick **one** member, and load only that member's runbook:

### Track 1: Host Diagnostics, Configuration & Recovery
| Task | Member | Canonical Path |
| :--- | :--- | :--- |
| **Code-first health check** & diagnostic probes (daemon, locks, service collisions, PATH truncation, Electron env traps) | `paseo-troubleshoot` | `vendor/cl-orchestration/cl-paseo/skills/paseo-troubleshoot/SKILL.md` |
| **Paseo host rescue**: pin pool keys, restart workers/app, classify BINARY/NAME/WEDGE/KEY | `paseo-rescue` | `vendor/cl-orchestration/cl-paseo/skills/paseo-rescue/SKILL.md` |
| **Configuration integrity**: `~/.paseo/config.json`, provider isolation, and backups | `paseo-config` | `vendor/cl-orchestration/cl-paseo/skills/paseo-config/SKILL.md` |
| **S4U boot task repair** & unattended reboot survival | `paseo-boot` | `vendor/cl-orchestration/cl-paseo/REFERENCE.md` & `scripts/Fix-PaseoBootTask.ps1` |
| **OpenCode database and disk pressure** | owned by `cl-harness` → `cl-opencode` | `$env:CL_REPOS_ROOT\cl-common\vendor\cl-orchestration\cl-opencode\SKILL.md` |
| **Archived / deleted project, workspace or agent recovery**: what survives an archive, orphaned-workspace restoration, preserving uncommitted lane work, the claim/registry takeover an adopting Hub must perform, and the "already has an active turn" collision | `agent-unarchive` | `vendor/cl-orchestration/cl-paseo/skills/agent-unarchive/SKILL.md` |

### Track 2: Agent Execution & Dispatch
| Task | Member | Canonical Path |
| :--- | :--- | :--- |
| **Attached dispatch**: background subagents in live session (`paseo_create_agent` + `notifyOnFinish`) | `subagent-dispatch` | `vendor/cl-orchestration/cl-paseo/skills/subagent-dispatch/SKILL.md` |
| **Detached dispatch**: `paseo run --no-wait` workers that survive the user's next message | `paseo-child-agents` | `$env:CL_REPOS_ROOT\cl-common\Skills\paseo-child-agents\SKILL.md` |
| **Spawn capacity & rails**: per-key-set concurrency caps, cooldown windows, model failover | `agent-spawn-capacity` | `$env:CL_REPOS_ROOT\cl-common\Skills\agent-spawn-capacity\SKILL.md` |
| **Personas & Kickoff**: OpenClaw project initiation and agent personas | `openclaw-agent` | `$env:CL_REPOS_ROOT\cl-common\Skills\openclaw-agent\SKILL.md` |

### Track 3: Model Choice & Cost

| Task | Member | Canonical Path |
| :--- | :--- | :--- |
| **Appraise a model**: benchmarks, pricing, features, comparison tables against the fleet's real usage strategy | `appraise-llm` | `$env:CL_REPOS_ROOT\cl-common\Skills\appraise-llm\SKILL.md` |
| **CheepSeek lane choice**: free Zen lane vs paid Go lane vs BYO key, and prompt-cache discipline | `cheepseek` | `$env:CL_REPOS_ROOT\cl-common\Skills\cheepseek\SKILL.md` |
| **Round-robin dispatch**: one agent per key cycling in pool order with a persisted cursor | `dispatch-round-robin` | `$env:CL_REPOS_ROOT\cl-common\Skills\dispatch-round-robin\SKILL.md` |
| **Waterfall dispatch**: fill each key to its per-key cap before spilling to the next, in pool order | `dispatch-waterfall` | `$env:CL_REPOS_ROOT\cl-common\Skills\dispatch-waterfall\SKILL.md` |

---

## Housekeeping & Grooming (Cross-Plugin Pointers)

For post-task cleanup and archiving, use the canonical members in `cl-clean`:
- **Workspace & Project Cleanup**: `clean-paseo-workspaces` (`Skills/clean-paseo-workspaces/SKILL.md`) - archives idle workspaces and purges empty projects.
- **Finished Agent Costing**: `clean-subagents` (`Skills/clean-subagents/SKILL.md`) - archives finished subagents and calculates token expenditure.

## Reference

Layout, red lines, unattended-reboot survival, and the duplicate-workspace
repair run live in [REFERENCE.md](REFERENCE.md), starting at `## Layout`.
