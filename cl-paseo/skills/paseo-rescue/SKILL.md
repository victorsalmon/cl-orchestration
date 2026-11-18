---
name: paseo-rescue
description: >
  Canonical Paseo rescue and credential re-pinning track. Repairs Paseo's OpenCode
  and DeepSeek Harness providers via Repair-Paseo.ps1 (classifies BINARY, NAME,
  WEDGE, KEY; on Paseo &lt; v0.15.3 pins provider env in ~/.paseo/config.json;
  on Paseo &gt;= v0.15.3 removes the env block to avoid shared-service collision;
  performs worker restart or desktop app fallback, and canaries the live helper).
triggers:
  - user
  - model
  - paseo rescue
  - repair paseo
  - paseo key
  - restart paseo
---

# paseo-rescue - Paseo Host & Provider Rescue Runbook

Canonical home for Paseo host and provider repair on this machine.

## When to Use

- A key cutover occurred (e.g. `OPENCODE_GO_KEY` moved to a new pool key) and Paseo helpers are still holding the old key.
- Paseo reports `Model not found: opencode/muse-spark-1.3-contributor` (prefix drift).
- Paseo reports `session.create timed out after 30s` followed by `workspace_request_key_conflict` (Wedge / timeout storm).
- DeepSeek Harness (`deepseek-harness`) calls fail while OpenCode works.

## Procedures

### 1. Verification (Read-Only)
Inspect daemon status, helper ages, provider diagnostics, and name canaries without touching credentials or restarting processes:

```powershell
pwsh -File "$env:CL_REPOS_ROOT\cl-common\vendor\cl-orchestration\cl-paseo\scripts\Repair-Paseo.ps1" -VerifyOnly
```

### 2. Standard Restart

Use the same repair entry point as Key Check. On Paseo 0.15.3 and later it
restarts the daemon and OpenCode with the current User key. It configures
Paseo to discover its own OpenCode service so saved agent environment
settings keep working. Older versions use the provider key pin.

```powershell
pwsh -File "$env:CL_REPOS_ROOT\cl-common\vendor\interactive-qa\vendor\credential-rescue\scripts\Repair-Paseo.ps1"
```

To repair after a switch to a specific machine pool key (e.g., `OPENCODE_GO8_KEY`):
```powershell
pwsh -File "$env:CL_REPOS_ROOT\cl-common\vendor\interactive-qa\vendor\credential-rescue\scripts\Repair-Paseo.ps1" -KeyNumber 8
```

If the daemon log repeats `V2Runtime.assertSharedConfiguration`, verify
that the OpenCode provider uses its own `XDG_STATE_HOME` and that the daemon
was relaunched after the configuration change.

### 3. Full Desktop App Fallback
When the daemon inherited a stale shell environment or will not release port 6767, perform a full close and relaunch of the desktop app with an explicitly composed environment:

```powershell
pwsh -File "$env:CL_REPOS_ROOT\cl-common\vendor\cl-orchestration\cl-paseo\scripts\Repair-Paseo.ps1" -FullApp
```

