#Requires -Version 7.0
<#
.SYNOPSIS
    Report Paseo workspace RECORDS that are duplicated on, or orphaned from, a
    filesystem path. READ-ONLY: this script never removes anything.

.DESCRIPTION
    A Paseo workspace record is bound to a path. `paseo run --new-workspace local`
    mints a NEW record every time, so any retry loop on a failing location
    multiplies them. Measured 2026-11-02:

        E:\repos\cl-common\.worktrees\merge-84m          6 records
        E:\repos\cl-common\.worktrees\merge-84m-b        1 record
        E:\Repos\upscale-havens\.worktrees\conf-onboarding-provisioning  10 records

    Once a path carries more than one record the daemon cannot reliably tell
    which one is live, so the dispatcher reuses a record instead of minting
    another.

    CORRECTION 2026-11-04 (bead cl-common-d5j): an earlier version of this note
    claimed duplicate records CAUSE

        OpenCode location <path> did not activate within 30000ms

    That is REFUTED by measurement. The failure hit paths with ZERO records
    (lane-n68, lane-hfm) and paths with ONE (lane-1yq), and the daemon log shows
    the real path: provider-snapshot-manager -> fetchCatalog ->
    waitForLocationReady, a fixed 30000ms poll of plugin.list with a 5000ms
    per-request timeout (readiness.js). It expires when the daemon cannot get a
    plugin answer back in time - DAEMON QUEUEING, not record bookkeeping. In the
    same window: `Timed out refreshing Gemini CLI after 120000ms` (another
    provider entirely), `Watcher subscription ... timed out after 10000ms`, and
    a probe create on a brand-new path that queued >180s and then SUCCEEDED on
    the same client, path and record.

    NARROWED 2026-11-05T07:56Z (same bead, same machine): queueing is real but
    it is NOT the whole cause. A fresh worktree (.worktrees/lane-merge-3qy)
    timed out on attempt 1 AND attempt 2 bound to the SAME record
    (wks_a2b9cd57e06d2988); the helper then refused a third attempt. The same
    lane at a NEW path (.worktrees/lane-merge-3qy-b) activated on the FIRST try
    and ran to completion, and a different fresh worktree (.worktrees/lane-3qy)
    did the same four minutes earlier. So a failed record is SPENT: it is bound
    to its path and does not recover by retrying, which is why the dispatcher's
    remedy is a fresh path and a fresh record, not another attempt on the same
    id.

    A real, separate defect this report DOES surface: Paseo leaves OpenCode
    helper servers (`opencode serve --hostname ... --port 0`) running after the
    supervisor that spawned them exits. Measured 2026-11-04: 20 running, 11
    older than the supervisor (oldest 65h), while runtime/managed-processes
    tracked 4. They hold their location's directory handle, which is why a
    worktree with no agent in it refuses `git worktree move`/remove with
    "Permission denied". Release them with
    vendor/interactive-qa/vendor/dispatch/scripts/Clear-OrphanedOpencodeServers.ps1 -Reap
    (never a `--service` server, never one started after the supervisor).

    WHY THIS SCRIPT ONLY REPORTS
    ----------------------------
    Paseo 0.14.0 exposes exactly four workspace verbs with any effect
    (`paseo workspace --help`): create, ls, rename, archive (plus setup). There
    is NO delete and NO detach:

      * `archive <workspace-id>` is documented as "Archive a workspace and
        everything it owns" - it takes the workspace's agents with it, and the
        CLI exposes no way to enumerate which agents a workspace owns
        (`paseo ls --json` carries no workspace id), so no script can prove an
        archive is safe.
      * Anything else (hand-editing ~/.paseo) is out of bounds.

    So record removal is an OPERATOR/PASEO decision, not an automated one. The
    dispatcher's mitigation is to stop creating duplicates
    (Skills/iqa-mode/scripts/run-iqa-worker.ps1 -> reuse-or-fail) and to fail
    once, named, with the duplicate count.

.PARAMETER Path
    Restrict the report to one path (exact match after normalizing case and
    separators). Omit to report every path with more than one record, plus every
    record whose path no longer exists on disk.

.PARAMETER Paseo
    Paseo CLI path. Defaults to PATH, then the desktop bundle.

.PARAMETER FailOnDuplicates
    Exit 2 when any path carries more than one active record (for CI/monitoring).

.OUTPUTS
    Text report, or JSON with -Json. Exit codes: 0 ok, 2 duplicates found
    (-FailOnDuplicates), 3 CLI unavailable.

.EXAMPLE
    ./Get-PaseoWorkspaceRecordReport.ps1
.EXAMPLE
    ./Get-PaseoWorkspaceRecordReport.ps1 -Path E:\Repos\cl-common\.worktrees\merge-84m -Json
#>
[CmdletBinding()]
param(
    [string]$Path = '',
    [string]$Paseo = '',
    [switch]$Json,
    [switch]$FailOnDuplicates
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-PaseoCli {
    param([string]$Override)
    if (-not [string]::IsNullOrWhiteSpace($Override)) { return $Override }
    $command = Get-Command paseo -ErrorAction SilentlyContinue
    # Two paseo executables can exist (npm shim + desktop app); .Source on that
    # array joins both paths with a space, which no caller can execute. Take ONE,
    # preferring a shim. Measured 2026-11-18: broke paseo ls and every hub keeper.
    $command = @($command) | Where-Object { $_.Source -match '\.(cmd|bat|ps1)$' } | Select-Object -First 1
    if ($command) { return $command.Source }
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs')) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($root in $roots) {
        $candidate = Join-Path $root 'Paseo/resources/bin/paseo.cmd'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return ''
}

function ConvertTo-NormalPath {
    param($Value)
    if ($null -eq $Value) { return '' }
    return ("$Value".Trim().TrimEnd('\', '/') -replace '/', '\').ToLowerInvariant()
}

$paseoExe = Resolve-PaseoCli -Override $Paseo
if (-not $paseoExe) {
    Write-Error 'Paseo CLI not found on PATH or in the desktop bundle.'
    exit 3
}

$raw = & $paseoExe workspace ls --json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $raw) {
    Write-Error "Could not list workspaces: 'paseo workspace ls --json' exited $LASTEXITCODE."
    exit 3
}
$records = @($raw | Out-String | ConvertFrom-Json)

$target = ConvertTo-NormalPath $Path
$groups = foreach ($group in ($records | Group-Object { ConvertTo-NormalPath $_.cwd })) {
    $cwd = $group.Name
    $exists = $cwd -and (Test-Path -LiteralPath $cwd -PathType Container)
    [pscustomobject]@{
        Path        = if ($cwd) { $cwd } else { '(no cwd)' }
        Count       = $group.Count
        Exists      = [bool]$exists
        Duplicated  = $group.Count -gt 1
        WorkspaceIds = @($group.Group | ForEach-Object { [string]$_.workspaceId })
    }
}
$all = @($groups)
$interesting = if ($target) {
    @($all | Where-Object { (ConvertTo-NormalPath $_.Path) -eq $target })
}
else {
    @($all | Where-Object { $_.Duplicated -or -not $_.Exists })
}

$duplicatePaths = @($all | Where-Object { $_.Duplicated })
$orphanPaths = @($all | Where-Object { -not $_.Exists })

# OpenCode helper servers that outlived the supervisor that spawned them. They
# are a separate defect from record bookkeeping (see .DESCRIPTION): they hold a
# location's directory handle, which is what makes a worktree refuse to move or
# delete with "Permission denied". Classified exactly like the dispatch helper:
# `serve --hostname` only (never --service), and only a start time STRICTLY
# before the supervisor's, because a supervisor restart keeps live agents and
# their servers.
$serveRunning = 0
$serveStale = @()
try {
    $pidPath = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))))) '.paseo\paseo.pid'
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $pidPath = Join-Path $env:USERPROFILE '.paseo\paseo.pid' }
    $supervisorStart = $null
    if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
        $state = Get-Content -LiteralPath $pidPath -Raw | ConvertFrom-Json
        if ($state.startedAt) {
            $raw = $state.startedAt
            $supervisorStart = if ($raw -is [datetime]) { ([datetime]$raw).ToUniversalTime() }
            else { [System.DateTimeOffset]::Parse([string]$raw, [System.Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
        }
    }
    $servers = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='opencode.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'serve\s+--hostname' -and $_.CommandLine -notmatch '--service\b' })
    $serveRunning = $servers.Count
    if ($null -ne $supervisorStart) {
        $cutoff = $supervisorStart.ToUniversalTime()
        $serveStale = @($servers | Where-Object {
                $null -ne $_.CreationDate -and ([datetime]$_.CreationDate).ToUniversalTime() -lt $cutoff
            })
    }
}
catch { }

if ($Json) {
    [pscustomobject]@{
        RecordedPaths    = $all.Count
        RecordedRecords  = $records.Count
        DuplicatePaths   = $duplicatePaths.Count
        DuplicateRecords = ($duplicatePaths | Measure-Object -Property Count -Sum).Sum
        OrphanPaths      = $orphanPaths.Count
        Paths            = @($interesting)
        OpencodeServers  = [pscustomobject]@{
            Running = $serveRunning
            Stale   = @($serveStale | ForEach-Object { [int]$_.ProcessId })
            Note    = 'Stale = `serve --hostname` started before the supervisor. They hold directory handles; they are NOT the cause of "did not activate within 30000ms" (that is daemon provider-readiness queueing).'
        }
        Removal          = 'not available: paseo 0.14.0 has create/ls/rename/archive only; archive also archives the agents the workspace owns. Operator/Paseo decision. Stale OpenCode servers are separately releasable: Clear-OrphanedOpencodeServers.ps1 -Reap.'
    } | ConvertTo-Json -Depth 5
}
else {
    Write-Host "Paseo workspace records: $($records.Count) active across $($all.Count) path(s)." -ForegroundColor Cyan
    Write-Host ("Duplicate paths: {0} ({1} records)  Orphan paths (directory gone): {2}" -f `
            $duplicatePaths.Count, ($duplicatePaths | Measure-Object -Property Count -Sum).Sum, $orphanPaths.Count) -ForegroundColor Yellow
    if (@($interesting).Count -eq 0) {
        Write-Host 'No duplicated or orphaned record paths.' -ForegroundColor Green
    }
    foreach ($row in @($interesting)) {
        $state = if ($row.Duplicated) { 'DUPLICATED' } else { 'ok' }
        $present = if ($row.Exists) { 'exists' } else { 'MISSING' }
        Write-Host ''
        Write-Host ("{0}  {1} records  ({2})" -f $row.Path, $row.Count, $present) -ForegroundColor $(if ($row.Duplicated) { 'Yellow' } else { 'DarkGray' })
        Write-Host ("  state: {0}" -f $state) -ForegroundColor DarkGray
        foreach ($id in $row.WorkspaceIds) { Write-Host "  - $id" }
    }
    Write-Host ''
    Write-Host ("OpenCode helper servers: {0} running, {1} stale (started before the supervisor)." -f $serveRunning, @($serveStale).Count) `
        -ForegroundColor $(if (@($serveStale).Count -gt 0) { 'Yellow' } else { 'DarkGray' })
    Write-Host 'Stale servers hold their location directory handle: that is why a worktree can refuse to move/delete with "Permission denied".' -ForegroundColor DarkGray
    Write-Host 'They are NOT the cause of "did not activate within 30000ms" - that is the daemon provider-readiness deadline under load.' -ForegroundColor DarkGray
    if (@($serveStale).Count -gt 0) {
        Write-Host 'Release them: <dispatch>/scripts/Clear-OrphanedOpencodeServers.ps1 -Reap (never --service, never one started after the supervisor).' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host 'Removal is NOT available for workspace RECORDS: paseo 0.14.0 exposes create/ls/rename/archive/setup only,' -ForegroundColor DarkGray
    Write-Host 'and archive also archives the agents the workspace owns (not enumerable from the CLI).' -ForegroundColor DarkGray
    Write-Host 'Mitigation: run-iqa-worker.ps1 never reuses a spent record - it moves the lane to a fresh path and mints a new record there (or waits before a create), and a path with no record at all may mint exactly one.' -ForegroundColor DarkGray
    Write-Host 'Record removal needs a Paseo change or an operator decision.' -ForegroundColor DarkGray
}

if ($FailOnDuplicates -and $duplicatePaths.Count -gt 0) { exit 2 }
exit 0
