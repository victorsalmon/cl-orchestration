#Requires -Version 7.0
<#
.SYNOPSIS
    Repo-level health probes: is this repo's trunk GREEN, is its merge queue
    LANDABLE, and is the Hub that owns it ALIVE.

.DESCRIPTION
    Test-PaseoHealth answers "can an agent spawn and run on this machine". It
    cannot answer "will the merge land", and on 2026-11-15 three merge trains were
    refused by conditions no Paseo probe looks at:

      * the trunk was red on the formatting gate (prettier drift from a commit that
        landed without running it) - the train gated the stack three times and
        correctly landed nothing;
      * a member was unlandable for paperwork (no lane report on the branch) and
        another for a dirty worktree (a launcher log inside the lane);
      * the Hub registry heartbeat was 472 minutes stale, so a groom refused the
        whole judgement tier with sole-writer:false (hub=none);
      * lane worktree leases were held by lanes that had finished hours earlier,
        so every hygiene dry run projected zero deletions.

    Each of those is a repo-shaped failure that looks like a task failure. These
    probes make them visible BEFORE a dispatch, which is the only place the
    information is still cheap.

    Every probe is read-only and bounded. A probe that cannot determine an answer
    reports WARN or SKIP - never PASS, because an unmeasured thing is not a
    healthy thing.

.PARAMETER RepoRoot
    The repo to inspect (default: the current directory).

.PARAMETER Trunk
    The integration trunk (default: resolved from the permanent-branch policy, else 'dev').

.PARAMETER Json
    Emit one machine-readable object instead of the table.

.EXAMPLE
    pwsh -NoProfile -File .\Test-RepoHealth.ps1 -RepoRoot E:\repos\upscale-havens

.EXAMPLE
    # the gate shape Unblock uses before resuming work as lanes
    pwsh -NoProfile -File .\Test-RepoHealth.ps1 -RepoRoot (Get-Location).Path -Json
    # exit 0 all PASS/WARN/SKIP | 1 any FAIL | 2 cannot-evaluate
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$Trunk = '',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RepoRoot).Path
if ([string]::IsNullOrWhiteSpace($Trunk)) {
    $policy = Join-Path $env:CL_REPOS_ROOT 'cl-common/Skills/git-operations/permanent-branches.json'
    $Trunk = 'dev'
    if (Test-Path $policy) {
        try {
            $leaf = (Split-Path -Leaf $root).ToLowerInvariant()
            $entry = (Get-Content $policy -Raw | ConvertFrom-Json).repos |
                Where-Object { ([string]$_.name).ToLowerInvariant() -eq $leaf } | Select-Object -First 1
            if ($entry -and $entry.primaryBranch) { $Trunk = [string]$entry.primaryBranch }
        } catch { }
    }
}

$results = [Collections.Generic.List[object]]::new()
function Add-Probe {
    param([string]$Id, [string]$Name, [string]$Status, [string]$Reason, [string]$Remedy = 'None required')
    $results.Add([pscustomobject]@{ Id = $Id; Name = $Name; Status = $Status; Reason = $Reason; Remedy = $Remedy })
}

function Invoke-Git {
    param([string[]]$GitArgs)
    try {
        $out = & git -C $root @GitArgs 2>&1
        return [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); out = (($out | Out-String).Trim()); code = $LASTEXITCODE }
    } catch {
        return [pscustomobject]@{ ok = $false; out = "$($_.Exception.Message)"; code = -1 }
    }
}

# 1 ---------------------------------------------------------------- TRUNK-CLEAN
try {
    $status = (Invoke-Git @('status', '--porcelain')).out
    if ([string]::IsNullOrWhiteSpace($status)) {
        Add-Probe 'TRUNK-CLEAN' 'Worktree has no uncommitted paths' 'PASS' 'git status --porcelain is empty'
    } else {
        $lines = ($status -split "`r?`n" | Where-Object { $_ })
        $tracked = @($lines | Where-Object { $_ -notmatch '^\?\?' })
        $st = if ($tracked.Count -gt 0) { 'FAIL' } else { 'WARN' }
        Add-Probe 'TRUNK-CLEAN' 'Worktree has no uncommitted paths' $st `
            ("{0} path(s): {1} tracked, {2} untracked" -f $lines.Count, $tracked.Count, ($lines.Count - $tracked.Count)) `
            'A dirty trunk refuses the merge train ([TRUNK_DIRTY]) and makes a groom fold nothing. Commit or ignore deliberately.'
    }
} catch {
    Add-Probe 'TRUNK-CLEAN' 'Worktree has no uncommitted paths' 'WARN' "could not read status: $($_.Exception.Message)"
}

# 2 ------------------------------------------------------------ TRUNK-LAST-GREEN
# The blocking tier costs ~5-7 minutes, so health does not run it. It reads the
# most recent gate evidence and the adaptive window instead: a window that has
# been halved is the train telling you the last batch went red.
try {
    $gateDir = Join-Path $root '.iqa/gate-logs'
    $lastLog = $null
    if (Test-Path $gateDir) {
        $lastLog = Get-ChildItem $gateDir -File -Filter '*preflight.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    $window = $null
    $stateFile = Join-Path $root '.iqa/merge-train.json'
    if (Test-Path $stateFile) {
        try { $window = (Get-Content $stateFile -Raw | ConvertFrom-Json).window } catch { }
    }
    $windowNote = if ($null -ne $window) { "window=$window" } else { 'window=unset' }
    # Two evidence shapes, both real: `.gate-runs/<stamp>/final-qa.json` carries a
    # `verdict`/`exitCode`, while `.iqa/gate-logs/<stamp>-preflight.log` carries one
    # `gate: pass|fail (Ns)` line per gate and NO verdict line. Reading only the
    # second shape's verdict is how a green run reported "no verdict line" forever.
    $gateRun = $null
    $runsDir = Join-Path $root '.gate-runs'
    if (Test-Path $runsDir) {
        $newest = Get-ChildItem $runsDir -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($newest) {
            $final = Join-Path $newest.FullName 'final-qa.json'
            if (Test-Path $final) { $gateRun = Get-Item $final }
        }
    }
    $source = $null; $verdict = $null; $age = 0
    if ($gateRun) {
        $source = $gateRun.FullName
        $age = [int]((Get-Date) - $gateRun.LastWriteTime).TotalMinutes
        try {
            $j = Get-Content $gateRun.FullName -Raw | ConvertFrom-Json
            if ($j.verdict) { $verdict = [string]$j.verdict }
            elseif ($null -ne $j.exitCode) { $verdict = if ([int]$j.exitCode -eq 0) { 'pass' } else { 'fail' } }
        } catch { }
    }
    if (-not $verdict -and $lastLog) {
        $source = $lastLog.FullName
        $age = [int]((Get-Date) - $lastLog.LastWriteTime).TotalMinutes
        $text = Get-Content $lastLog.FullName -Raw -ErrorAction SilentlyContinue
        if ($text -match '(?im)^\s*verdict\s*=\s*(pass|fail)') { $verdict = $Matches[1].ToLowerInvariant() }
        elseif ($text -match '(?im)^\s*[\w-]+:\s*fail\b') { $verdict = 'fail' }
        elseif ($text -match '(?im)^\s*[\w-]+:\s*(pass|cannot-evaluate)\b') { $verdict = 'pass' }
    }
    if ($verdict) {
        $verdict = $verdict.ToLowerInvariant()
        $st = if ($verdict -eq 'pass') { if ($age -le 720) { 'PASS' } else { 'WARN' } } elseif ($age -le 720) { 'FAIL' } else { 'WARN' }
        $remedy = if ($verdict -eq 'pass') { if ($age -le 720) { 'None required' } else { 'Verdict is older than 12 h; re-run the blocking tier before trusting it.' } } else { 'The trunk was RED at the last gate run; fix it before dispatching lanes - every lane gate runs on this base.' }
        Add-Probe 'TRUNK-LAST-GREEN' 'Blocking tier verdict from the last gate evidence' $st `
            "verdict=$verdict, $age min old, $windowNote ($(Split-Path -Leaf $source))" $remedy
    } elseif ($source) {
        Add-Probe 'TRUNK-LAST-GREEN' 'Blocking tier verdict from the last gate evidence' 'WARN' `
            "evidence present but unreadable, $age min old, $windowNote ($(Split-Path -Leaf $source))" 'Re-run the blocking tier to establish a verdict.'
    } else {
        Add-Probe 'TRUNK-LAST-GREEN' 'Blocking tier verdict from the last gate evidence' 'WARN' `
            "no gate evidence under .gate-runs or .iqa/gate-logs, $windowNote" 'Run `node scripts/preflight.mjs` once to establish a baseline verdict.'
    }
} catch {
    Add-Probe 'TRUNK-LAST-GREEN' 'Blocking tier verdict from the last gate log' 'WARN' "probe error: $($_.Exception.Message)"
}

# 3 ---------------------------------------------------------------- TRUNK-LOCK
try {
    $lockScript = Join-Path $env:CL_REPOS_ROOT 'cl-common/Skills/git-operations/Invoke-TrunkMergeLock.ps1'
    if (Test-Path $lockScript) {
        $raw = & pwsh -NoProfile -File $lockScript -Mode Status -RepoRoot $root -Trunk $Trunk -Json 2>&1 | Out-String
        $obj = $null
        try { $obj = $raw | ConvertFrom-Json } catch { }
        if ($obj) {
            $held = [bool]$obj.Held
            $live = [bool]$obj.Live
            $st = if (-not $held) { 'PASS' } elseif ($live) { 'WARN' } else { 'FAIL' }
            Add-Probe 'TRUNK-LOCK' "Trunk lock ($Trunk) is free or owned by a live writer" $st `
                ("held={0} live={1} owner={2} reason={3}" -f $held, $live, $obj.Lock.owner, $obj.Reason) `
                $(if (-not $held) { 'None required' } elseif ($live) { 'A live writer owns the trunk; wait, do not dispatch a second one.' } else { 'Stale lock: take it over deliberately or release it, or the next merge refuses.' })
        } else {
            Add-Probe 'TRUNK-LOCK' "Trunk lock ($Trunk) is free or owned by a live writer" 'WARN' 'status helper returned no JSON' 'Check Invoke-TrunkMergeLock.ps1 -Mode Status by hand.'
        }
    } else {
        Add-Probe 'TRUNK-LOCK' "Trunk lock ($Trunk) is free or owned by a live writer" 'SKIP' 'lock helper not found' 'No trunk lock on this machine.'
    }
} catch {
    Add-Probe 'TRUNK-LOCK' "Trunk lock ($Trunk) is free or owned by a live writer" 'WARN' "probe error: $($_.Exception.Message)"
}

# 4 ------------------------------------------------------------ MERGE-QUEUE-READY
# A queued row is not a landable branch. Measured refusals on one night: no lane
# report on the branch (needs-report), a launcher log dirtying the worktree
# (live-lane), a tip that moved after the brief (stale sha).
try {
    $queueFile = Join-Path $root (".iqa/merge-queue/" + (Split-Path -Leaf $root) + '.jsonl')
    if (-not (Test-Path $queueFile)) {
        Add-Probe 'MERGE-QUEUE-READY' 'Every queued row is landable' 'SKIP' 'no merge-queue file' 'Nothing queued.'
    } else {
        $latest = @{}
        foreach ($line in (Get-Content $queueFile)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $row = $line | ConvertFrom-Json } catch { continue }
            if (-not $row.branch) { continue }
            $latest[[string]$row.branch] = $row
        }
        $queued = @($latest.Values | Where-Object { $_.status -eq 'queued' })
        $problems = @()
        foreach ($row in $queued) {
            $b = [string]$row.branch
            $ref = Invoke-Git @('rev-parse', '--verify', '--quiet', $b)
            if (-not $ref.ok) { $problems += "$b (branch missing)"; continue }
            $pushed = Invoke-Git @('ls-remote', '--heads', 'origin', $b)
            if (-not $pushed.ok -or [string]::IsNullOrWhiteSpace($pushed.out)) { $problems += "$b (not pushed)"; continue }
            $tip = (Invoke-Git @('rev-parse', '--short', $b)).out
            if ($row.sha -and ([string]$row.sha).Length -ge 7 -and -not $tip.StartsWith(([string]$row.sha).Substring(0, 7))) {
                $problems += "$b (row sha $(([string]$row.sha).Substring(0, 7)) != tip $tip)"
            }
            $addsReport = Invoke-Git @('diff', '--name-only', "origin/$Trunk...$b", '--', 'docs/iqa/reports')
            if ([string]::IsNullOrWhiteSpace($addsReport.out)) { $problems += "$b (needs-report)" }
            $wt = [string]$row.worktree
            if ($wt -and (Test-Path $wt)) {
                $dirty = (Invoke-Git @('-C', $wt, 'status', '--porcelain')).out
                if (-not [string]::IsNullOrWhiteSpace($dirty)) { $problems += "$b (worktree dirty)" }
            }
        }
        if ($queued.Count -eq 0) {
            Add-Probe 'MERGE-QUEUE-READY' 'Every queued row is landable' 'PASS' 'no queued rows'
        } elseif ($problems.Count -eq 0) {
            Add-Probe 'MERGE-QUEUE-READY' 'Every queued row is landable' 'PASS' ("{0} queued row(s), all pushed, reported, clean and tip-matched" -f $queued.Count)
        } else {
            Add-Probe 'MERGE-QUEUE-READY' 'Every queued row is landable' 'FAIL' `
                ("{0} of {1} queued row(s) are NOT landable: {2}" -f $problems.Count, $queued.Count, ($problems -join '; ')) `
                'Each item is a refusal the merge train will make. Fix the row (report on the branch, clean the worktree, re-enqueue at the real tip) before expecting a landing.'
        }
    }
} catch {
    Add-Probe 'MERGE-QUEUE-READY' 'Every queued row is landable' 'WARN' "probe error: $($_.Exception.Message)"
}

# 5 ------------------------------------------------------------ HUB-HEARTBEAT
try {
    $slug = Split-Path -Leaf $root
    $hubFile = Join-Path $env:USERPROFILE ".machine/state/hubs/$slug.json"
    if (-not (Test-Path $hubFile)) {
        Add-Probe 'HUB-HEARTBEAT' 'The Hub owning this repo has a fresh heartbeat' 'SKIP' 'no hub record' 'No Hub registered for this repo.'
    } else {
        $rec = Get-Content $hubFile -Raw | ConvertFrom-Json
        $hubs = @($rec.hubs)
        if ($hubs.Count -eq 0) {
            Add-Probe 'HUB-HEARTBEAT' 'The Hub owning this repo has a fresh heartbeat' 'WARN' 'record exists with no hubs' 'Re-register the Hub so a groom can claim sole-writer.'
        } else {
            $h = $hubs[0]
            $ageMin = [int]((Get-Date).ToUniversalTime() - ([datetime]$h.heartbeatAt).ToUniversalTime()).TotalMinutes
            $st = if ($ageMin -le 60) { 'PASS' } elseif ($ageMin -le 240) { 'WARN' } else { 'FAIL' }
            Add-Probe 'HUB-HEARTBEAT' 'The Hub owning this repo has a fresh heartbeat' $st `
                ("hub={0} heartbeat {1} min old" -f $h.agentId, $ageMin) `
                $(if ($st -eq 'PASS') { 'None required' } else { 'A groom reads hub=none past the staleness ceiling and refuses the judgement tier (sole-writer:false), so nothing folds. Renew the registry heartbeat.' })
        }
    }
} catch {
    Add-Probe 'HUB-HEARTBEAT' 'The Hub owning this repo has a fresh heartbeat' 'WARN' "probe error: $($_.Exception.Message)"
}

# 6 ---------------------------------------------------------------- LANE-LEASES
# A lease outlives the lane that took it: the holder is a detached process that
# exits without releasing when its agent dies. Hygiene then sees every worktree as
# busy and projects zero deletions.
try {
    $leaseDir = Join-Path $env:USERPROFILE '.machine/state/worktree-leases'
    if (-not (Test-Path $leaseDir)) {
        Add-Probe 'LANE-LEASES' 'No worktree lease is held by a lane that has finished' 'SKIP' 'no lease store'
    } else {
        $now = Get-Date
        $files = Get-ChildItem $leaseDir -File -Filter '*.json' -ErrorAction SilentlyContinue
        $expired = 0; $live = 0; $mine = 0
        foreach ($f in $files) {
            try { $l = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
            $wt = [string]$l.worktree
            if ($wt -and $wt.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $mine++ }
            $exp = $null
            try { if ($l.expiresAt) { $exp = [datetime]$l.expiresAt } } catch { }
            if ($exp -and $exp -gt $now) { $live++ } else { $expired++ }
        }
        $st = if ($expired -gt 200) { 'WARN' } else { 'PASS' }
        Add-Probe 'LANE-LEASES' 'The lease store does not accumulate dead leases' $st `
            ("{0} file(s): {1} unexpired, {2} expired, {3} for this repo" -f $files.Count, $live, $expired, $mine) `
            $(if ($st -eq 'PASS') { 'None required' } else { 'Expired leases are never pruned, so a reader that treats presence as liveness sees every worktree as busy. Release the landed ones and prune the store.' })
    }
} catch {
    Add-Probe 'LANE-LEASES' 'The lease store does not accumulate dead leases' 'WARN' "probe error: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------- output
$fail = @($results | Where-Object { $_.Status -eq 'FAIL' })
$warn = @($results | Where-Object { $_.Status -eq 'WARN' })
$verdict = if ($fail.Count -gt 0) { 'UNHEALTHY' } elseif ($warn.Count -gt 0) { 'DEGRADED' } else { 'HEALTHY' }
$exit = if ($fail.Count -gt 0) { 1 } else { 0 }

if ($Json) {
    [pscustomobject]@{ repo = $root; trunk = $Trunk; verdict = $verdict; probes = $results; checkedAt = (Get-Date).ToUniversalTime().ToString('o') } |
        ConvertTo-Json -Depth 5
    exit $exit
}

Write-Host ""
Write-Host "Repo health - $(Split-Path -Leaf $root) ($Trunk) -> $verdict" -ForegroundColor $(if ($exit -eq 0) { 'Green' } else { 'Red' })
Write-Host ""
$fmt = '{0,-20} {1,-7} {2}'
Write-Host ($fmt -f 'Probe', 'Status', 'Detail')
Write-Host ($fmt -f '-----', '------', '------')
foreach ($r in $results) {
    $colour = switch ($r.Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'DarkGray' } }
    Write-Host ($fmt -f $r.Id, $r.Status, $r.Reason) -ForegroundColor $colour
}
$remedies = @($results | Where-Object { $_.Status -in @('FAIL', 'WARN') -and $_.Remedy -ne 'None required' })
if ($remedies.Count -gt 0) {
    Write-Host ""
    Write-Host 'Remedies' -ForegroundColor Yellow
    foreach ($r in $remedies) { Write-Host ("  {0}: {1}" -f $r.Id, $r.Remedy) }
}
Write-Host ""
exit $exit

