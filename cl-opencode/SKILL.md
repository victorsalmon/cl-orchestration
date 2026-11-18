---
name: cl-opencode
description: >
  Maintenance, config, and database hygiene for the OpenCode installation on
  this Windows machine. Owns the opencode.db VACUUM cadence, the session-pruning
  runbook (delete sessions older than N days), the WAL-checkpoint recovery
  procedure, config-change verification against the running loader, and the
  Repo Clean integration hook. Use when opencode.db grows too large, when Paseo
  restart hangs on a full drive, when a config edit must be proven accepted,
  or when asked about compaction thresholds or database maintenance.
triggers:
  - database maintenance
  - opencode.db
  - prune sessions
  - vacuum opencode
  - DB full
  - drive full
  - Paseo restart hang
  - opencode config
  - config not applied
  - compaction threshold
---

# cl-opencode — OpenCode installation maintenance

One owner for the OpenCode database lifecycle on this Windows machine. `opencode.db`
stores every session, message and agent turn, and grows without bound unless pruned.

## Symptoms this skill addresses

The symptom→cause table (`paseo restart` hangs, D: at 0 bytes, repair exit 124, `paseo-repair-failed`, hundreds of sessions) is
[REFERENCE.md](REFERENCE.md) → `## Symptom to cause table`.

**Root mechanism:** Paseo's daemon opens `opencode.db` in WAL mode and checkpoints on
SIGTERM; with 0 free bytes the checkpoint cannot complete, the daemon hangs past the
300s cutover timeout, and the cutover reports `paseo-repair-failed`. Measured: a
44 GB file holding ~1 GB of live data. Why Nov 2-3 succeeded and later runs did not:
[REFERENCE.md](REFERENCE.md) → `## The root mechanism`.

## The two runbooks — `opencode-db` and `opencode-config`

Both are rows in `Skills/windows-shell/scripts/runbooks.registry.json` and run
through the one dispatcher, so this skill states the decision and the row owns
the command. `show <row>` prints the blast radius, rollback and preconditions;
`codes <RT-E-code>` prints what a refusal means. Neither row's command is
restated here — that restatement is exactly how prose and reality drift.

```powershell
pwsh -NoProfile -File Skills/windows-shell/scripts/runbooks.ps1 show opencode-db
pwsh -NoProfile -File Skills/windows-shell/scripts/runbooks.ps1 show opencode-config
```

## Database runbook: opencode-db

Blast radius: **destructive** — it deletes rows. Rollback: there is none for
deleted sessions, so a copy of the DB first is the only one.

| Call | What happens |
| :--- | :--- |
| `run opencode-db -Preflight -WhatIf` | the row's five preconditions measured, nothing changed |
| `run opencode-db -WhatIf` | measurement only: size, page/freelist counts, row counts, the pruner's own dry-run |
| `run opencode-db -Write -Yes` | prune, then `wal_checkpoint(TRUNCATE)`, then re-measure (needs a doctor pass in the same invocation) |

The preconditions, each measured rather than assumed, and the refusal codes
(`RT-E-PYTHON-MISSING`, `RT-E-DB-UNREADABLE`, `RT-E-DB-BUSY`,
`RT-E-DB-LOW-DISK`, `RT-E-PRUNE-MISSING`): [REFERENCE.md](REFERENCE.md) →
`## Runbook preconditions and refusal codes`.

The pruner itself is not re-implemented: `D:\opencode-data\opencode\prune-sessions.py`
keeps the 7-day cutoff and the delete order, and the row invokes it. What it
deletes, and what the freed freelist pages mean, is measured history:
[REFERENCE.md](REFERENCE.md) → `## The prune script — detail`.

The row never VACUUMs. VACUUM needs free space equal to the live pages and
rewrites the whole file, so it is an operator decision; the row reports the
freelist, which is the space a VACUUM could reclaim.

Once the DB has room again, the restart that was stuck can complete: verify with
`vendor/cl-orchestration/cl-paseo/scripts/Repair-Paseo.ps1 -VerifyOnly` (the registered
`paseo-health` probe), and treat a `KEY` or `WEDGE` classification as the signal
to run the full repair.

## Config runbook: opencode-config

Read-only, so it runs without a confirmation token.

```powershell
pwsh -NoProfile -File Skills/windows-shell/scripts/runbooks.ps1 run opencode-config
```

One command answers "did my edit apply?": it prints every
`configuration normalization diagnostic` in the log window as path / kind /
action, the canary line whose timestamp proves the loader re-read the file, and
the effective compaction summary. Exit **0** accepted, **1** a field in the file
is rejected (`kind=invalid`), **3** cannot evaluate — the log, the config, or the
canary is missing, or the canary has not moved since the edit
(`RT-E-CONFIG-LOG-MISSING`, `RT-E-CONFIG-UNREADABLE`,
`RT-E-CONFIG-CANARY-ABSENT`, `RT-E-CONFIG-CANARY-STALE`).

The rule it encodes: a value can parse, match the docs, and still be skipped at
load. Measured facts, the three `kind` values, and the "managed service port is
held by the live session" trap: [references/config-verification.md](references/config-verification.md).

## Repo Clean integration

Repo Clean's `-Disk` mode is the natural hook: run the prune after the CDK temp-dir
prune, then the WAL checkpoint, only when the prune script exists. The proposed call
and its guard: [REFERENCE.md](REFERENCE.md) → `## Repo Clean integration — proposed call`.
## Preventing recurrence

**Scheduled prune** weekly, then **VACUUM** as a deliberate act once free space on
D: exceeds the live-page size. Why VACUUM is never automated:
[REFERENCE.md](REFERENCE.md) → `## Preventing recurrence - the VACUUM rule`.

## Reference

- Prune script `D:\opencode-data\opencode\prune-sessions.py`; DB
  `D:\opencode-data\opencode\opencode.db` (+ `-wal`); config log
  `D:\opencode-data\opencode\log\opencode.log`; CLI `opencode session list` /
  `delete <id>`. Moved detail: [REFERENCE.md](REFERENCE.md).