---
name: paseo-config
description: >
  Manage and repair ~/.paseo/config.json, provider model mappings, environment
  pins, and runtime isolation. Enforces Paseo v0.15.1 schema constraints where
  custom provider environment variables require isolated server instances.
triggers:
  - user
  - model
  - paseo config
  - paseo settings
  - paseo provider
---

# paseo-config - Paseo Configuration & Provider Management

Manages the core configuration file for Paseo at `~/.paseo/config.json`.

## Safe Editing Principles

1. **Automatic Backup**:
   Every edit made by automated scripts creates a timestamped backup:
   `~/.paseo/config.json.bak-yyyyMMddTHHmmssZ`.
2. **Schema Integrity**:
   Paseo expects `agents.providers.<providerId>` structures. Corrupted JSON or
   missing blocks cause the daemon to fail during bootstrap.
3. **Paseo v0.15.1 Runtime Isolation Rule**:
   > [!IMPORTANT]
   > In Paseo v0.15.1+, setting custom environment variables (like `OPENCODE_GO_KEY`
   > or `OPENCODE_API_KEY`) under `agents.providers.opencode.env` **strictly requires**
   > an isolated, owned server instance (`kind: "owned"`). If Paseo discovers an
   > external running service (`~/.local/state/opencode/service.json`), it throws a
   > fatal exception on every agent request. Never mix external shared services
   > with custom environment keys in Paseo.

## Inspecting Configuration

```powershell
$cfg = Get-Content -LiteralPath "$env:USERPROFILE\.paseo\config.json" -Raw | ConvertFrom-Json
$cfg.agents.providers.opencode.env
```

## Restoring from Backup

If `config.json` is corrupted:
```powershell
$bak = Get-ChildItem "$env:USERPROFILE\.paseo\config.json.bak-*" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Copy-Item $bak.FullName "$env:USERPROFILE\.paseo\config.json" -Force
```

