---
name: paseo-troubleshoot
description: >
  Code-first diagnostic and health assessment for the Paseo installation on Windows.
  Executes modular invariant probes covering daemon liveness, lockfile integrity,
  OpenCode shared-service collision, Electron environment cleanliness, boot task
  arguments, config JSON syntax, and Windows User PATH truncation. Use when Paseo
  is in error, fails to start, closes immediately, or agents fail to dispatch.
triggers:
  - user
  - model
  - paseo health
  - paseo broken
  - paseo error
  - paseo status
  - diagnose paseo
---

# paseo-troubleshoot - Paseo Code-First Health & Diagnostic Runbook

Run executable diagnostic probes to determine the exact failure mode of Paseo in
under one second, without manual inspection or speculative log browsing.

## 1. Quick Diagnosis

Run the automated probe suite:

```powershell
pwsh -File "$env:CL_REPOS_ROOT\cl-common\vendor\cl-orchestration\cl-paseo\scripts\Test-PaseoHealth.ps1"
```

For programmatic consumption (JSON output):
```powershell
pwsh -File "$env:CL_REPOS_ROOT\cl-common\vendor\cl-orchestration\cl-paseo\scripts\Test-PaseoHealth.ps1" -Json
```

## 2. Invariant Probes & Failure Modes

The probe suite evaluates 9 discrete invariants:

| Probe ID | Check Name | Failure Signature | Countermeasure / Remedy |
| :--- | :--- | :--- | :--- |
| `DAEMON-RUNNING` | Daemon Process & Port | Port `6767` closed; daemon stopped | Start app or run `paseo daemon run --home $HOME\.paseo` |
| `LOCK-STALE` | PID Lock Integrity | `~/.paseo/paseo.pid` points to dead PID | `Remove-Item ~/.paseo/paseo.pid -Force` |
| `SERVICE-COLLISION` | Shared Service Collision | `~/.local/state/opencode/service.json` present; `opencode serve --service` running | Kill external process and delete `service.json`. Paseo v0.15.1 strictly forbids custom `OPENCODE_GO_KEY` on shared services. |
| `ENV-RUN-AS-NODE` | Electron Environment | `ELECTRON_RUN_AS_NODE=1` set | `Remove-Item env:ELECTRON_RUN_AS_NODE`. When set, `Paseo.exe` runs as Node CLI and exits code 0 without GUI. |
| `BOOT-TASK-ARG` | S4U Task Scheduler Action | `\Paseo Daemon` action uses `--foreground` | Run elevated: `pwsh -File scripts/Fix-PaseoBootTask.ps1` to update action to `daemon run`. |
| `CONFIG-SYNTAX` | JSON Schema & Parse | JSON parse error in `~/.paseo/config.json` | Restore from latest `~/.paseo/config.json.bak-*`. |
| `PATH-TRUNCATION` | User PATH Length | User `PATH` $\ge$ 1024 chars (setx overflow) | Clean duplicate machine entries out of User PATH. |
| `PROVIDER-BINARIES`| CLI Tools Discovery | `opencode`, `node`, `git` not found in PATH | Fix system PATH entries. |
| `KEY-PROVIDER-MATCH`| Active Key & Provider Pin | Provider pinned key differs from system key | Run `Repair-Paseo.ps1` to re-pin and restart helpers. |

## 3. Automated One-Stop Remediation

To automatically repair any recoverable failure detected by the probes:

```powershell
pwsh -File "$env:CL_REPOS_ROOT\cl-common\vendor\cl-orchestration\cl-paseo\scripts\Repair-PaseoHealth.ps1"
```

