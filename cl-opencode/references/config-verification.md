# Config verification — did the runtime actually accept the edit?

An edit to `opencode.jsonc` is **not** a config change until the loader says it took
it. A file that parses as JSONC, and even matches the published V2 docs, can be
silently skipped at load time.

Measured 2026-11-13 on `opencode v2.1.2`: `"compaction": { "buffer": "40%" }`
parsed cleanly, matched the documented percentage form, and was skipped:

```text
level=WARN message="configuration normalization diagnostic"
  source="D:\\Apps\\opencode\\config\\opencode\\opencode.jsonc"
  path=$.compaction.buffer kind=invalid
  action="skipped malformed recognized value"
```

The config looked set, was reported as set, and never applied. JSON syntax
validation proves nothing about schema acceptance.

## Readback procedure

Run this after **every** config edit. It is the only proof, and it is one command:

```powershell
pwsh -NoProfile -File Skills/windows-shell/scripts/runbooks.ps1 run opencode-config
```

That row (script: `vendor/cl-orchestration/cl-opencode/scripts/Test-OpenCodeConfig.ps1`) prints
every `configuration normalization diagnostic` in the log window as path / kind /
action, the canary comparison below, and the effective compaction summary. It
reads only; exit 0 accepted, 1 a field in the file is rejected, 3 cannot evaluate.

Read the `kind` and `action` pair it reports:

| `kind` | `action` | Meaning |
| :--- | :--- | :--- |
| `invalid` | `skipped malformed recognized value` | Field is known but the value shape is wrong — **not applied**. |
| `unsupported` | `omitted unsupported legacy setting` | Legacy field, dropped — harmless but inert; do not rely on it. |
| absent | — | Accepted. Only meaningful if you also prove the file was re-read (below). |

## Proving the file was re-read

The absence of a warning is not evidence unless the loader actually read the file
again. The loader re-reads config per request, so pin the proof to a line that
**always** warns and check its timestamp moved: the row does exactly this
(`-CanaryPath`, default `$.compaction.prune`), comparing the newest canary
timestamp with the config file's last write.

If the canary timestamp is newer than your edit and no `path=$.<your field>`
warning exists after that edit, the value was accepted. If the canary did not
move, the row refuses with `RT-E-CONFIG-CANARY-STALE` — say "written, pending
readback", never "set".

## Measured facts on this machine (v2.1.2, 2026-11-13)

- `compaction.buffer` accepts a **token number** (`400000`). The documented
  percentage string (`"40%"`) is rejected as malformed. Docs can run ahead of the
  installed build; the log decides.
- `compaction.prune` is `unsupported` and omitted. Harmless, inert, V1 legacy.
- `buffer` is **headroom, not the trigger**: compaction starts when the
  conversation reaches `window − buffer`. A larger buffer compacts *earlier*.
- A token buffer at least as large as the model's window is ignored and the
  default `"15%"` (floor 16k) applies. A numeric buffer is therefore
  model-specific: `400000` compacts at 600k on a 1M window and does **nothing**
  on a 200K window (the free Zen lane).

## CLI trap: the port belongs to the live session

`opencode models` and `opencode api ...` can fail with:

```text
Managed service port 45278 on 127.0.0.1 is already in use by another process
```

That port is held by the Paseo-managed service hosting the live conversation.
Do **not** restart the service to clear it — that kills the session you are
typing into. Read the log for the answer, or pass `--standalone` deliberately on
a spare port. A running session keeps the config it loaded; a restart to pick up
a new value is a deliberate operator act, not a diagnostic step.

## Scope

This file answers "did this machine accept it". For field shape, defaults, and
semantics, use the `opencode` V2 docs skill and treat this log as the tiebreaker
when they disagree with the installed build.
