#Requires -Version 7.0
<#
.SYNOPSIS
    Measure, preflight and prune this machine's OpenCode database.

.DESCRIPTION
    The executable pilot of the cl-opencode database runbook. Registered as the
    `opencode-db` row of Skills/windows-shell/scripts/runbooks.registry.json, so
    it is dispatched through `runbooks.ps1 run opencode-db` and everything here
    is measured: the prose in vendor/cl-orchestration/cl-opencode/SKILL.md points at this file
    instead of restating commands.

    FOUR MODES, one script:

      (default)      Measure only. DB size, WAL size, page_count / page_size /
                     freelist_count, the four table row counts, and the canonical
                     prune script's own dry-run counts. Writes nothing.
      -WhatIf        With -Write, prints the plan and changes nothing.
      -Write         Runs the canonical prune script with --write, then
                     PRAGMA wal_checkpoint(TRUNCATE), then re-measures. Needs the
                     dispatcher's -Yes plus a same-invocation doctor pass.
      -Preflight     Runs the row's preconditions and reports pass/refuse per
                     check: python, DB present, no writer holding the write lock
                     (-LockPatienceMs, default 2000), disk headroom, canonical
                     pruner present. Changes nothing.

    WHAT IT DELIBERATELY DOES NOT DO
      - It never re-implements the prune: D:\opencode-data\opencode\prune-sessions.py
        stays the only place the delete order and the 7-day cutoff live. This
        script invokes it.
      - It never VACUUMs. VACUUM needs free space equal to the live pages and
        rewrites the whole file; it is an operator decision, not a diagnostic.
        The freelist count this script reports is the space a VACUUM could
        reclaim, and the row's rollback says so.

    EXIT CODES
      0  measured (and, with -Write, done): no precondition refused
      1  measured failure: a query or the prune script returned non-zero
      3  refused: a precondition refused (RT-E- code names it)

    PREFLIGHT CONTRACT
      -Preflight emits the same shape Skills/windows-shell/scripts/preflight.ps1
      emits - { schemaVersion, checks: [{name, verdict, detail, fix}], summary } -
      so a caller reads one shape for every preflight on this box. A verdict is
      pass, warn or refuse; an unmeasured context is a refuse, never a pass.

.EXAMPLE
    pwsh -NoProfile -File vendor/cl-orchestration/cl-opencode/scripts/Invoke-OpenCodeDb.ps1 -Preflight

.EXAMPLE
    pwsh -NoProfile -File Skills/windows-shell/scripts/runbooks.ps1 run opencode-db -Preflight -WhatIf

.EXAMPLE
    pwsh -NoProfile -File Skills/windows-shell/scripts/runbooks.ps1 run opencode-db -WhatIf

.EXAMPLE
    pwsh -NoProfile -File Skills/windows-shell/scripts/runbooks.ps1 run opencode-db -Write -Yes

.NOTES
    Codes this script can fail with, all catalogued in
    Skills/windows-shell/scripts/runbooks.errors.json: RT-E-PYTHON-MISSING,
    RT-E-DB-UNREADABLE, RT-E-DB-BUSY, RT-E-DB-LOW-DISK, RT-E-PRUNE-MISSING.
    Look one up with `runbooks.ps1 codes <code>`.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$DbPath = 'D:\opencode-data\opencode\opencode.db',
    [string]$PruneScriptPath = 'D:\opencode-data\opencode\prune-sessions.py',
    [ValidateRange(0, 1000000)][double]$MinFreeGb = 5,
    [ValidateRange(0, 60000)][int]$LockPatienceMs = 2000,
    [switch]$Write,
    [switch]$Preflight,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CataloguePath = (Get-Item -LiteralPath (Join-Path $PSScriptRoot '../../../../Skills/windows-shell/scripts/runbooks.errors.json')).FullName
$script:Checks = [System.Collections.Generic.List[object]]::new()

function Get-CatalogueEntry {
    <#
    .SYNOPSIS
        One RT-E- entry from the shared catalogue, or $null.
    .DESCRIPTION
        The catalogue beside the dispatcher is the single source of truth for
        every RT-E- code. This script prints the catalogue's words rather than
        its own copy, so the refusal a caller sees here is the refusal
        `runbooks.ps1 codes <code>` describes.
    #>
    param([Parameter(Mandatory)][string]$Code)

    if (-not (Test-Path -LiteralPath $script:CataloguePath -PathType Leaf)) { return $null }
    try { $raw = Get-Content -LiteralPath $script:CataloguePath -Raw -Encoding utf8 | ConvertFrom-Json }
    catch { return $null }
    if (-not $raw.PSObject.Properties['errors']) { return $null }
    return (@($raw.errors) | Where-Object { [string]$_.code -eq $Code } | Select-Object -First 1)
}

function Stop-RunbookFailure {
    <#
    .SYNOPSIS
        Stop with an RT-E- code, printing the catalogue's symptom and fix.
    #>
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowEmptyCollection()][object[]]$Detail = @()
    )

    $entry = Get-CatalogueEntry -Code $Code
    $symptom = 'no catalogue entry for this code: add it to runbooks.errors.json'
    $fix = ('add {0} to Skills/windows-shell/scripts/runbooks.errors.json' -f $Code)
    if ($null -ne $entry) {
        $symptom = [string]$entry.symptom
        $fix = [string]$entry.fix
        if ($Detail.Count -gt 0 -and $symptom -match '\{0\}') { $symptom = ($symptom -f $Detail[0]) }
    }

    [Console]::Error.WriteLine(('{0}: {1}' -f $Code, $symptom))
    [Console]::Error.WriteLine(('fix: {0}' -f $fix))
    exit $ExitCode
}

function Add-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('pass', 'warn', 'refuse')][string]$Verdict,
        [string]$Detail = '',
        [string]$Fix = ''
    )
    $script:Checks.Add([pscustomobject]@{ name = $Name; verdict = $Verdict; detail = $Detail; fix = $Fix })
}

function Resolve-PythonExe {
    <#
    .SYNOPSIS
        Resolve python, or return $null (the caller decides how to refuse).
    .DESCRIPTION
        Split from the refusal so -Preflight can report "python missing" as one
        failing check instead of terminating before the other probes ran.
    #>
    $found = @(Get-Command -Name python -CommandType Application -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) { return $null }
    return $found[0].Source
}

function Get-PythonExe {
    <#
    .SYNOPSIS
        Resolve python, or refuse: the measurement is sqlite3 work, not PS work.
    #>
    $pythonExe = Resolve-PythonExe
    if ([string]::IsNullOrWhiteSpace($pythonExe)) {
        Stop-RunbookFailure -Code 'RT-E-PYTHON-MISSING' -ExitCode 3 -Detail 'python is not on PATH'
    }
    return $pythonExe
}

function Invoke-Python {
    <#
    .SYNOPSIS
        Run one python program, returning its text and exit code.
    .DESCRIPTION
        stderr is captured, never treated as an exit code: python writes
        warnings there (the canonical prune script emits SyntaxWarning for a
        docstring escape) and windows-shell Rule 5 says a successful command can
        look like a failure. The exit code decides.
    #>
    param(
        [Parameter(Mandatory)][string]$PythonExe,
        [Parameter(Mandatory)][string]$Program
    )

    $raw = & $PythonExe -c $Program 2>&1
    $code = $LASTEXITCODE
    return [pscustomobject]@{
        Text   = ((@($raw) | ForEach-Object { [string]$_ }) -join "`n")
        Code   = $code
    }
}

# ---- measurement ---------------------------------------------------------------------------

function Get-DbMeasurement {
    <#
    .SYNOPSIS
        Page, freelist, WAL and row-count facts in one round trip.
    #>
    param([Parameter(Mandatory)][string]$PythonExe)

    $program = @'
import sqlite3, os, json
db = r"%DB%"
out = {"dbPath": db, "exists": os.path.exists(db)}
if out["exists"]:
    out["sizeBytes"] = os.path.getsize(db)
    wal = db + "-wal"
    out["walBytes"] = os.path.getsize(wal) if os.path.exists(wal) else 0
    conn = sqlite3.connect(db, timeout=0, isolation_level=None)
    try:
        cur = conn.cursor()
        out["pageCount"] = cur.execute("PRAGMA page_count").fetchone()[0]
        out["pageSize"] = cur.execute("PRAGMA page_size").fetchone()[0]
        out["freelistCount"] = cur.execute("PRAGMA freelist_count").fetchone()[0] or 0
        out["journalMode"] = cur.execute("PRAGMA journal_mode").fetchone()[0]
        out["rowCounts"] = {}
        for t in ("session", "session_v2", "session_message", "part"):
            try:
                out["rowCounts"][t] = cur.execute("SELECT COUNT(*) FROM %s" % t).fetchone()[0]
            except sqlite3.Error as e:
                out["rowCounts"][t] = "error: %s" % e
    finally:
        conn.close()
print(json.dumps(out))
'@

    $result = Invoke-Python -PythonExe $PythonExe -Program ($program.Replace('%DB%', $DbPath))
    if ($result.Code -ne 0) {
        [Console]::Error.WriteLine($result.Text)
        return $null
    }
    try { return ($result.Text | ConvertFrom-Json) } catch { return $null }
}

function Invoke-PreflightProbes {
    <#
    .SYNOPSIS
        The row's four measurable preconditions, one verdict each.
    #>
    $pythonExe = Resolve-PythonExe
    if ([string]::IsNullOrWhiteSpace($pythonExe)) {
        Add-Check -Name 'python' -Verdict 'refuse' -Detail 'python is not on PATH' `
            -Fix 'install python 3 (the DB probe is sqlite3 work) or add it to PATH'
    } else {
        Add-Check -Name 'python' -Verdict 'pass' -Detail ("python resolves to {0}" -f $pythonExe)
    }

    if (-not (Test-Path -LiteralPath $DbPath -PathType Leaf)) {
        Add-Check -Name 'db-present' -Verdict 'refuse' -Detail ("{0} does not exist" -f $DbPath) `
            -Fix 'pass -DbPath with the live OpenCode database, or restore it from backup'
    } else {
        $sizeGb = [Math]::Round((Get-Item -LiteralPath $DbPath).Length / 1GB, 2)
        Add-Check -Name 'db-present' -Verdict 'pass' -Detail ("{0} is {1} GB" -f $DbPath, $sizeGb)
    }

    # A live writer check that does not rely on process names: the Paseo daemon
    # holds this DB without an opencode image to match on. BEGIN IMMEDIATE asks
    # for the write lock, and LockPatienceMs is how long it waits before the
    # verdict is "a writer will not let go". Zero patience is wrong here: a
    # healthy session takes the write lock for milliseconds at a time, so
    # patience 0 reports a false "busy" on a perfectly healthy machine
    # (measured: 1 in 3 probes). The lock is released either way - ROLLBACK.
    if ($null -ne $pythonExe -and (Test-Path -LiteralPath $DbPath -PathType Leaf)) {
        $probe = @'
import sqlite3, sys
db = r"%DB%"
patience = %PATIENCE%
try:
    conn = sqlite3.connect(db, timeout=patience / 1000.0, isolation_level=None)
except sqlite3.Error as e:
    print("UNREADABLE " + str(e)); sys.exit(0)
try:
    conn.execute("BEGIN IMMEDIATE")
    conn.execute("ROLLBACK")
    print("IDLE")
except sqlite3.OperationalError as e:
    msg = str(e)
    print(("BUSY " if ("locked" in msg or "busy" in msg) else "UNREADABLE ") + msg)
finally:
    conn.close()
'@
        $probe = $probe.Replace('%DB%', $DbPath).Replace('%PATIENCE%', [string]$LockPatienceMs)
        $result = Invoke-Python -PythonExe $pythonExe -Program $probe
        $line = ([string]$result.Text).Trim()
        if ($line -like 'IDLE*') {
            Add-Check -Name 'db-idle' -Verdict 'pass' -Detail ("no writer held the database for {0} ms (BEGIN IMMEDIATE then ROLLBACK)" -f $LockPatienceMs)
        } elseif ($line -like 'BUSY*') {
            Add-Check -Name 'db-idle' -Verdict 'refuse' `
                -Detail ("a writer held the database for longer than {0} ms: {1}" -f $LockPatienceMs, $line) `
                -Fix 'stop the session or daemon holding opencode.db (a restart to release it is a deliberate operator act), then re-run'
        } else {
            Add-Check -Name 'db-idle' -Verdict 'refuse' -Detail ("the database could not be opened: {0}" -f $line) `
                -Fix 'check the file is a readable SQLite database and not held by a crashed process'
        }
    }

    $dbRoot = Split-Path -Parent $DbPath
    $qualifier = Split-Path -Qualifier $DbPath
    if ([string]::IsNullOrWhiteSpace($qualifier)) {
        Add-Check -Name 'disk-headroom' -Verdict 'refuse' -Detail ("{0} has no drive qualifier" -f $DbPath) `
            -Fix 'pass -DbPath with a drive-qualified path'
    } elseif (-not (Test-Path -LiteralPath $dbRoot -PathType Container)) {
        Add-Check -Name 'disk-headroom' -Verdict 'refuse' -Detail ("{0} does not exist" -f $dbRoot) `
            -Fix 'pass -DbPath inside an existing directory'
    } else {
        try {
            $freeGb = [Math]::Round(([System.IO.DriveInfo]::new($qualifier)).AvailableFreeSpace / 1GB, 1)
            if ($freeGb -lt $MinFreeGb) {
                Add-Check -Name 'disk-headroom' -Verdict 'refuse' `
                    -Detail ("only {0} GB free on {1} (refuse under {2} GB)" -f $freeGb, $qualifier, $MinFreeGb) `
                    -Fix 'reclaim space first (Skills/disk-bloat-cleanup/SKILL.md): a checkpoint needs room for the WAL'
            } elseif ($freeGb -lt (2 * $MinFreeGb)) {
                Add-Check -Name 'disk-headroom' -Verdict 'warn' `
                    -Detail ("{0} GB free on {1}; below twice the threshold, a VACUUM would not fit" -f $freeGb, $qualifier)
            } else {
                Add-Check -Name 'disk-headroom' -Verdict 'pass' -Detail ("{0} GB free on {1}" -f $freeGb, $qualifier)
            }
        } catch {
            Add-Check -Name 'disk-headroom' -Verdict 'refuse' -Detail ("free space on {0} could not be read: {1}" -f $qualifier, $_.Exception.Message) `
                -Fix 'check the drive is mounted, then re-run'
        }
    }

    if (-not (Test-Path -LiteralPath $PruneScriptPath -PathType Leaf)) {
        Add-Check -Name 'prune-script' -Verdict 'refuse' -Detail ("{0} does not exist" -f $PruneScriptPath) `
            -Fix 'restore the canonical pruner (D:\opencode-data\opencode\prune-sessions.py) or pass -PruneScriptPath'
    } else {
        Add-Check -Name 'prune-script' -Verdict 'pass' -Detail ("the canonical pruner is at {0}" -f $PruneScriptPath)
    }
}

function Write-PreflightReport {
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Checks)

    $refused = @($Checks | Where-Object { $_.verdict -eq 'refuse' })
    if ($Json) {
        $overall = if ($refused.Count -gt 0) { 'refuse' } else { 'pass' }
        [ordered]@{
            schemaVersion = 1
            runbook       = 'opencode-db'
            mode          = 'preflight'
            checks        = @($Checks | ForEach-Object {
                    [ordered]@{ name = $_.name; verdict = $_.verdict; detail = $_.detail; fix = $_.fix }
                })
            summary       = [ordered]@{
                pass    = @($Checks | Where-Object { $_.verdict -eq 'pass' }).Count
                warn    = @($Checks | Where-Object { $_.verdict -eq 'warn' }).Count
                refuse  = $refused.Count
                overall = $overall
            }
        } | ConvertTo-Json -Depth 6
    } else {
        foreach ($check in $Checks) {
            Write-Output ('[{0,-6}] {1} - {2}' -f $check.verdict, $check.name, $check.detail)
            if ($check.verdict -eq 'refuse' -and -not [string]::IsNullOrWhiteSpace($check.fix)) {
                Write-Output ('         fix: {0}' -f $check.fix)
            }
        }
        $tail = if ($refused.Count -gt 0) { ('preflight: {0} of {1} checks refused' -f $refused.Count, $Checks.Count) }
        else { ('preflight: {0} checks passed' -f $Checks.Count) }
        Write-Output $tail
    }

    if ($refused.Count -gt 0) { exit 3 }
    exit 0
}

# ---- prune ---------------------------------------------------------------------------------

function Invoke-Pruner {
    <#
    .SYNOPSIS
        Run the canonical pruner and parse the counts it prints.
    .DESCRIPTION
        The pruner owns the delete order and the cutoff. This wrapper only
        decides DRY-RUN vs WRITE and lifts the numbers so a caller can compare
        before with after. An unparseable line is reported, never invented.
    #>
    param(
        [Parameter(Mandatory)][string]$PythonExe,
        [switch]$ActuallyWrite
    )

    $arguments = @($PruneScriptPath)
    if ($ActuallyWrite) { $arguments += '--write' } else { $arguments += '--dry-run' }

    $raw = & $PythonExe @arguments 2>&1
    $code = $LASTEXITCODE
    $text = ((@($raw) | ForEach-Object { [string]$_ }) -join "`n")

    $counts = [ordered]@{}
    foreach ($pair in @(
            @{ Key = 'oldV2Sessions'; Pattern = 'Old V2 sessions:\s*(\d+)' }
            @{ Key = 'oldV1Sessions'; Pattern = 'Old V1 sessions:\s*(\d+)' }
            @{ Key = 'sessionMessageRows'; Pattern = 'session_message rows:\s*(\d+)' }
            @{ Key = 'v1MessageRows'; Pattern = 'V1 message rows:\s*(\d+)' }
            @{ Key = 'partRows'; Pattern = 'part rows:\s*(\d+)' }
            @{ Key = 'oldAuthBakFiles'; Pattern = '(\d+) older than 7d' }
        )) {
        $match = [regex]::Match($text, $pair.Pattern)
        $counts[$pair.Key] = if ($match.Success) { [int]$match.Groups[1].Value } else { $null }
    }

    return [pscustomobject]@{ Text = $text; Code = $code; Counts = $counts }
}

# ---- main ----------------------------------------------------------------------------------

if ($Preflight) {
    Invoke-PreflightProbes
    Write-PreflightReport -Checks @($script:Checks)
}

$pythonExe = Get-PythonExe
$measurement = Get-DbMeasurement -PythonExe $pythonExe
if ($null -eq $measurement) {
    Stop-RunbookFailure -Code 'RT-E-DB-UNREADABLE' -ExitCode 3 `
        -Detail ("{0} could not be measured (python exited non-zero)" -f $DbPath)
}
if (-not $measurement.exists) {
    Stop-RunbookFailure -Code 'RT-E-DB-UNREADABLE' -ExitCode 3 `
        -Detail ("{0} does not exist" -f $DbPath)
}

$mode = 'measure'
if ($Write -and $WhatIfPreference) { $mode = 'preview' }
elseif ($Write) { $mode = 'write' }

if (-not (Test-Path -LiteralPath $PruneScriptPath -PathType Leaf)) {
    Stop-RunbookFailure -Code 'RT-E-PRUNE-MISSING' -ExitCode 3 -Detail $PruneScriptPath
}

# A write is the only mode that can damage anything, so it re-measures the
# row's preconditions here rather than trusting the dispatcher's -Yes. Each
# refusing probe maps to the code that names it, so a direct invocation fails
# as loudly as a dispatched one.
if ($mode -eq 'write') {
    $script:Checks.Clear()
    Invoke-PreflightProbes
    $refused = @($script:Checks | Where-Object { $_.verdict -eq 'refuse' })
    if ($refused.Count -gt 0) {
        $first = $refused[0]
        $detail = ("{0}: {1}" -f $first.name, $first.detail)
        switch ([string]$first.name) {
            'python' { Stop-RunbookFailure -Code 'RT-E-PYTHON-MISSING' -ExitCode 3 -Detail $detail }
            'db-present' { Stop-RunbookFailure -Code 'RT-E-DB-UNREADABLE' -ExitCode 3 -Detail $detail }
            'db-idle' { Stop-RunbookFailure -Code 'RT-E-DB-BUSY' -ExitCode 3 -Detail $detail }
            'disk-headroom' { Stop-RunbookFailure -Code 'RT-E-DB-LOW-DISK' -ExitCode 3 -Detail $detail }
            default { Stop-RunbookFailure -Code 'RT-E-PRUNE-MISSING' -ExitCode 3 -Detail $detail }
        }
    }
}

$freelistGb = 0
if ($measurement.PSObject.Properties['freelistCount'] -and $measurement.PSObject.Properties['pageSize']) {
    $freelistGb = [Math]::Round(($measurement.freelistCount * $measurement.pageSize) / 1GB, 1)
}
$usedGb = 0
if ($measurement.PSObject.Properties['pageCount']) {
    $livePages = $measurement.pageCount - $measurement.freelistCount
    $usedGb = [Math]::Round(($livePages * $measurement.pageSize) / 1GB, 1)
}

if (-not $Json) {
    Write-Output ('db:      {0}' -f $DbPath)
    Write-Output ('mode:    {0}' -f $(switch ($mode) {
                'measure' { 'measure (read-only; nothing changes)' }
                'preview' { 'preview (-Write -WhatIf; nothing changes)' }
                default { 'write (prune then WAL checkpoint)' }
            }))
    if ($measurement.PSObject.Properties['sizeBytes']) {
        Write-Output ('file:    {0} GB ({1:N0} bytes), WAL {2:N1} MB' -f `
            [Math]::Round($measurement.sizeBytes / 1GB, 2), $measurement.sizeBytes, ($measurement.walBytes / 1MB))
        Write-Output ('pages:   {0:N0} total x {1:N0} B; freelist {2:N0} ({3} GB reclaimable), live {4} GB' -f `
            $measurement.pageCount, $measurement.pageSize, $measurement.freelistCount, $freelistGb, $usedGb)
        Write-Output ('journal: {0}' -f $measurement.journalMode)
        $rows = $measurement.rowCounts
        Write-Output ('rows:    session={0} session_v2={1} session_message={2} part={3}' -f `
            $rows.session, $rows.session_v2, $rows.session_message, $rows.part)
    }
}

$pruner = Invoke-Pruner -PythonExe $pythonExe
if (-not $Json) {
    Write-Output ''
    Write-Output '--- canonical pruner (dry-run; it owns the cutoff and the delete order) ---'
    Write-Output $pruner.Text
}
if ($pruner.Code -ne 0 -and $mode -ne 'write') {
    Stop-RunbookFailure -Code 'RT-E-DB-UNREADABLE' -ExitCode 1 `
        -Detail ("{0} exited {1}" -f $PruneScriptPath, $pruner.Code)
}

$written = $false
if ($mode -eq 'write') {
    if ($PSCmdlet.ShouldProcess($DbPath, 'prune sessions, checkpoint the WAL, then re-measure')) {
        $pruner = Invoke-Pruner -PythonExe $pythonExe -ActuallyWrite
        if (-not $Json) { Write-Output ''; Write-Output '--- prune --write ---'; Write-Output $pruner.Text }

        $checkpointProgram = @'
import sqlite3
conn = sqlite3.connect(r"%DB%", isolation_level=None)
conn.execute("PRAGMA busy_timeout=1800000")
row = conn.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
conn.close()
print("wal_checkpoint(TRUNCATE): %s" % (row,))
'@
        $checkpoint = Invoke-Python -PythonExe $pythonExe -Program ($checkpointProgram.Replace('%DB%', $DbPath))
        if (-not $Json) { Write-Output ''; Write-Output '--- WAL checkpoint ---'; Write-Output $checkpoint.Text }

        if ($pruner.Code -ne 0 -or $checkpoint.Code -ne 0) {
            Stop-RunbookFailure -Code 'RT-E-DB-UNREADABLE' -ExitCode 1 `
                -Detail ("prune exited {0}, checkpoint exited {1}" -f $pruner.Code, $checkpoint.Code)
        }
        $written = $true
        $measurement = Get-DbMeasurement -PythonExe $pythonExe
    }
}

if ($Json) {
    $payload = [ordered]@{
        schemaVersion = 1
        runbook       = 'opencode-db'
        mode          = $mode
        written       = $written
        db            = [ordered]@{
            path      = $DbPath
            sizeBytes = $measurement.sizeBytes
            walBytes  = $measurement.walBytes
            pageCount = $measurement.pageCount
            pageSize  = $measurement.pageSize
            freelist  = $measurement.freelistCount
            liveGb    = $usedGb
            reclaimGb = $freelistGb
            journal   = $measurement.journalMode
            rows      = $measurement.rowCounts
        }
        prune         = [ordered]@{
            script     = $PruneScriptPath
            exitCode   = $pruner.Code
            wouldDelete = $pruner.Counts
        }
    }
    $payload | ConvertTo-Json -Depth 6
}

exit 0
