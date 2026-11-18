# OpenCode database maintenance

Use this runbook when Paseo or OpenCode stalls on a session operation, when the
database volume is low on free space, or when the log reports `SQLITE_FULL`.

1. Resolve the live database from `OPENCODE_DB`, or from
   `XDG_DATA_HOME\opencode\opencode.db` when no override is set. Measure
   physical free space on that volume with `[System.IO.DriveInfo]`.
2. Open the database read-only and query SQLite's `page_count`, `page_size`,
   and `freelist_count`. Reusable pages can be large even when the file has
   already been pruned. They reduce future database growth without returning
   space to Windows.
3. If the volume is full, free space outside the database first. If session
   pruning is needed, inspect the retention cutoff and dry-run output. On
   this host the operator's tool is
   `D:\opencode-data\opencode\prune-sessions.py --dry-run`. Use `--write`
   when session removal is intended.
4. To reclaim file space, stop database writers, back up the database, and
   allow for SQLite's temporary workspace before running `VACUUM`. A
   `wal_checkpoint(TRUNCATE)` result with a nonzero first field reports
   outstanding readers or writers. Checkpointing handles the WAL and leaves
   the main file size intact.
5. Verify disk space and run an OpenCode request after restarting. Key Check
   checks free space before restarting Paseo and reports a low-space failure.
   Session retention and database compaction are maintenance operations.
