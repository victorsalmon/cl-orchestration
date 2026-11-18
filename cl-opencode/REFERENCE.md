# cl-opencode — reference

Adjacent detail for [SKILL.md](SKILL.md). The decisions and the emergency path stay in
the skill; this file holds the exact commands and the measured history.

## The root mechanism

Successful cutovers (Nov 2-3) worked because the DB was smaller and D:\ had free
space. As the DB grew to 44 GB with only ~1 GB of live data, the file consumed the
partition.

## The prune script — detail

`D:\opencode-data\opencode\prune-sessions.py` is the canonical pruner and the
only place the delete order and the cutoff live. The `opencode-db` row invokes
it; nothing restates its invocation here.

It accepts `--dry-run` (default) which counts, and `--write` which deletes.

It deletes:

1. `part` rows for old V1 sessions (the big content blobs)
2. `message` rows for old V1 sessions
3. `session_message` rows for old V2 sessions
4. Old V1 and V2 `session`/`session_v2` rows
5. `auth.json.bak-*` files older than the cutoff beside the DB

Default cutoff: **7 days** (the `cutoff_7d` variable inside the script).

## Post-prune state and verification

After a prune, the DB file on disk is the same size (SQLite does not shrink the
file on DELETE). The freed space becomes **freelist pages** that SQLite reuses
for future writes. VACUUM shrinks the file, but it needs free disk space equal to
the DB's live pages and rewrites the whole file, so it is an operator decision —
the row reports `page_count`, `page_size` and `freelist_count` (the space a VACUUM
could reclaim) instead of running one.

Measured on 2026-11-13: 44.09 GB file, 11,559,167 pages × 4096 B, freelist
11,306,145 pages (43.1 GB reclaimable), live ~1 GB — the 44 GB-with-1 GB-of-data
case that makes a checkpoint hang under a full drive.

## The runbook commands — now the `opencode-db` row

Diagnose, prune, checkpoint and verify are one executable path:
`runbooks.ps1 run opencode-db` (measure), `-WhatIf` (preview), `-Write -Yes`
(prune + checkpoint + re-measure), `-Preflight` (the preconditions). The commands
they replaced are in that script, so they cannot drift from it. The one step that
is not the DB row's business:

```powershell
# Test paseo restart once the DB has room again
pwsh -File "$env:CL_REPOS_ROOT\cl-common\vendor\interactive-qa\vendor\credential-rescue\scripts\Repair-Paseo.ps1" -VerifyOnly
```

If classification reports `KEY` or `WEDGE`, proceed with the full repair.

## Repo Clean integration — proposed call

When Repo Clean runs with the `-Disk` flag, it should also run the DB prune
on this machine. The Repo Clean disk sweep at
`Skills/repo-clean/scripts/Prune-CdkTempDirs.ps1` is the natural hook point.
Add a call to the prune script after the CDK temp-dir prune:

```powershell
# In Skills/repo-clean/scripts/Invoke-RepoClean.ps1 or the -Disk mode:
if ($RunOpenCodeDbPrune) {
    Write-Output "--- opencode.db prune ---"
    $pruneScript = 'D:\opencode-data\opencode\prune-sessions.py'
    if (Test-Path $pruneScript) {
        & python $pruneScript --write 2>&1
        # Checkpoint WAL
        python -c "import sqlite3; conn=sqlite3.connect(r'D:\opencode-data\opencode\opencode.db'); conn.execute('PRAGMA wal_checkpoint(TRUNCATE)'); conn.close()" 2>&1
    }
}
```

## Symptom to cause table

Moved from [SKILL.md](SKILL.md) `## Symptoms this skill addresses`, which keeps
the pointer. Nothing below was removed.

| Symptom | Likely cause |
| :--- | :--- |
| `paseo restart` hangs past 300s | WAL checkpoint can't complete — D:\ full or near-full |
| D: drive has 0 bytes free | `opencode.db` + WAL consumed the partition |
| `vendor/cl-orchestration/cl-paseo/scripts/Repair-Paseo.ps1` times out with exit 124 | Same root cause - daemon stuck on checkpoint |
| Key Watch cutover says `paseo-repair-failed` | Same — the restart step is the only step that writes |
| `opencode session list` shows hundreds of sessions | The DB has never been pruned |

## Runbook preconditions and refusal codes

Moved from [SKILL.md](SKILL.md) `## Database runbook: opencode-db`, which keeps
the decision and the refusal codes by name.

The preconditions, each measured rather than assumed: python on PATH; the DB
present; **no wedged writer** (BEGIN IMMEDIATE with a short patience
`-LockPatienceMs`, never process-name matching, because the Paseo daemon holds
this DB without an `opencode` image to match); free space on the DB's drive; the
canonical pruner present. Refusals: `RT-E-PYTHON-MISSING`,
`RT-E-DB-UNREADABLE`, `RT-E-DB-BUSY`, `RT-E-DB-LOW-DISK`,
`RT-E-PRUNE-MISSING`.

## Preventing recurrence - the VACUUM rule

Moved from [SKILL.md](SKILL.md) `## Preventing recurrence`, which keeps the two
decisions.

**Scheduled prune** weekly (fast — freelist reuse, not file-size work), then
**VACUUM** as a deliberate act once free space on D: exceeds the live-page size
the row reports. VACUUM on a nearly-full drive is the one time it cannot work,
which is why the row refuses to automate it.
