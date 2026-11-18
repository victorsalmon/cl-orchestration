#Requires -Version 7.0
<#
.SYNOPSIS
    Repo health - the PROGRESS and EVIDENCE probes.

.DESCRIPTION
    Additive to `Test-RepoHealth.ps1`'s six state probes (TRUNK-CLEAN,
    TRUNK-LAST-GREEN, TRUNK-LOCK, MERGE-QUEUE-READY, HUB-HEARTBEAT, LANE-LEASES).
    Those six answer "is the state what it should be". They cannot answer "is the
    thing that claims to be working actually moving", and on 2026-11-15 every loss
    on currents-bookkeeping happened while all six would have been green:

      * SUITE-SLOT-PROGRESS - a backend suite held 2/2 slots for 59 minutes at
        0.31s of CPU per 20s with all 69 threads parked. Every other suite on the
        box queued behind it, silently. A pid-alive test cannot see this.

      * QUEUE-EVIDENCE - 25 queued rows, and ZERO had a report naming the branch
        tip (most had no report at all). "Report on the branch" is the wrong test:
        a report naming an ancestor, or one that is INCOMPLETE on a required gate,
        passes existence and fails the gate.

      * QUEUE-GHOSTS - 3 queued rows whose tips were already ancestors of the
        trunk. They fed a false "starved" verdict for hours.

      * LOCK-HEALTH - the trunk lock was held for 77 minutes by pid 53516, which
        was `conhost.exe`: Windows had RECYCLED the groom's pid. The lock was
        expired at 07:15 and "pid alive" still said held, so a merge runner waited
        on a phantom.

    Exit codes follow the fleet dialect: 0 pass/warn/skip, 1 any FAIL,
    2 cannot-evaluate. A probe that cannot measure is CANNOT-EVALUATE - never pass.

.PARAMETER RepoRoot
    The checkout to inspect. Default: the current directory.

.PARAMETER Probe
    Run only these probes: LOCK-HEALTH, SUITE-SLOT-PROGRESS, QUEUE-EVIDENCE,
    QUEUE-GHOSTS, WORKER-HEARTBEAT, BRANCHES. Default: all of them.

.PARAMETER Json
    Emit one JSON object instead of the table (for a Hub/Unblock consumer).

.PARAMETER SuiteSlotWindowSeconds
    CPU sampling window for SUITE-SLOT-PROGRESS (default 8).

.EXAMPLE
    pwsh -NoProfile -File scripts/Test-RepoHealth.Additions.ps1 -RepoRoot E:\Repos\currents-bookkeeping
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string[]]$Probe = @(),
    [switch]$Json,
    [int]$SuiteSlotWindowSeconds = 8,
    # Get-HealthReport runs the inventory itself, so it passes this to avoid paying
    # for the branch plan twice. A standalone call keeps the probe.
    [switch]$SkipBranches,
    # Define the helper functions and return without probing (used by the Pester suite).
    [switch]$LibraryOnly,
    # Status marks: circles by default where the console proves it can carry them,
    # the bracketed word otherwise (see Skills/cl-clean/scripts/HealthStatus.ps1).
    [switch]$Ascii,
    [switch]$Glyphs
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$slug = Split-Path $RepoRoot -Leaf
$machineState = if ($env:MACHINE_STATE_HOME) { $env:MACHINE_STATE_HOME } else { Join-Path $HOME '.machine\state' }
$results = [System.Collections.Generic.List[object]]::new()

# ONE definition of the status vocabulary, shared with the process-health probe, so a
# green circle cannot mean two different things in two reports.. (Join-Path (Split-Path $PSScriptRoot -Parent) '..\..\..\Skills\cl-clean\scripts\HealthStatus.ps1')

function Add-Result {
    param([string]$Id, [string]$Status, [string]$Measured, [string]$Evidence, [string]$Remedy)
    $results.Add([pscustomobject]@{
            Id       = $Id
            Status   = $Status          # PASS | WARN | FAIL | SKIP | CANNOT-EVALUATE
            Measured = $Measured
            Evidence = $Evidence
            Remedy   = $Remedy
        })
}

# Dot-sourced by the Pester suite: helpers only, no probes.

function Test-ProbeWanted([string]$Id) {
    if ($Probe.Count -eq 0) { return $true }
    return $Probe -contains $Id
}

function Format-BranchSummary {
    <#
    .SYNOPSIS
        One line: branch total, per-class counts, and whether the counts reconcile.
    .DESCRIPTION
        Pure, so the Pester suite proves the shape without a checkout. The classes
        come from the inventory, which is the ONE owner of branch classification
        (`repo-clean -Plan`); this function only renders them.
    #>
    param($Branches)
    if ($null -eq $Branches) { return 'branches unknown' }
    $bits = @()
    $classes = $Branches.classes
    if ($classes) {
        $props = if ($classes -is [System.Collections.IDictionary]) {
            @($classes.Keys | ForEach-Object { [pscustomobject]@{ Name = [string]$_; Value = $classes[$_] } })
        }
        else { @($classes.PSObject.Properties) }
        foreach ($p in $props) {
            if ($null -ne $p.Value -and [int]$p.Value -gt 0) { $bits += "$($p.Name) $($p.Value)" }
        }
    }
    return ('branches {0}{1}{2}' -f $Branches.total,
        $(if ($bits.Count -gt 0) { " ($($bits -join ', '))" } else { '' }),
        $(if ($Branches.reconciled -eq $false) { ' UNRECONCILED' } else { '' }))
}

# ---------------------------------------------------------------- LOCK-HEALTH
# A pid can be recycled. Windows reuses pids aggressively; a lock whose holder
# process STARTED AFTER the lock was ACQUIRED is not the same process. That test
# is platform-independent and cheap, and it is the one that was missing when a
# conhost.exe held the trunk lock for 77 minutes.
function Get-ProcessStartUtc {
    param([int]$ProcessId)
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        return $p.StartTime.ToUniversalTime()
    }
    catch {
        return $null
    }
}

function Get-LockVerdict {
    <#  Pure-ish: takes the lock object and the holder's start time (or $null).  #>
    param(
        [Parameter(Mandatory)]$Lock,
        [Nullable[datetime]]$HolderStartUtc,
        [datetime]$NowUtc = [datetime]::UtcNow
    )
    $acquired = $null
    if ($Lock.PSObject.Properties['acquiredAt'] -and $Lock.acquiredAt) {
        try { $acquired = ([datetime]$Lock.acquiredAt).ToUniversalTime() } catch { $acquired = $null }
    }
    $expires = $null
    if ($Lock.PSObject.Properties['expiresAt'] -and $Lock.expiresAt) {
        try { $expires = ([datetime]$Lock.expiresAt).ToUniversalTime() } catch { $expires = $null }
    }
    $expired = $expires -and $NowUtc -gt $expires

    # LIVENESS IS HEARTBEAT-BASED, NEVER PID-BASED (cl-common-0co.26). The lock records
    # the pid of the short-lived shell that WROTE it, not of the session holding it, so a
    # dead recorded pid says nothing about the holder. Judging by pid made this probe FAIL
    # on healthy locks all session, and it once led the Hub to force-release a lock whose
    # heartbeat was still fresh. A dead pid is ADVISORY; expiry is the verdict.
    $pidNote = ''
    if ($Lock.PSObject.Properties['pid'] -and $Lock.pid) {
        if (-not (Get-Process -Id ([int]$Lock.pid) -ErrorAction SilentlyContinue)) {
            $pidNote = ' (recorded pid is dead - writer was a short-lived shell; advisory only)'
        }
    }
    elseif ($Lock.PSObject.Properties['ownerAgentId']) {
        $pidNote = ' (identity claim - no pid by design)'
    }

    if ($expired) {
        return @{ Status = 'FAIL'; Why = ('expired at {0:u} and nothing renewed it{1}' -f $expires, $pidNote); Expired = $true }
    }
    $state = if ($expires) { "expires $($expires.ToString('u'))" } else { 'no expiry recorded - treated as held' }
    return @{ Status = 'PASS'; Why = ("not expired ($state)$pidNote"); Expired = $false }
}

# ------------------------------------------------------------ QUEUE-EVIDENCE
# ONE definition of "this repo's merge queue", shared by QUEUE-EVIDENCE and
# QUEUE-GHOSTS: <repo>/.iqa/merge-queue/<repo>.jsonl. The probe used to hand the
# classifier no queue at all, so the classifier's hard-coded
# currents-bookkeeping filename was used on every repo; on cl-common that named a
# file that does not exist, and the "no queue" message became a fabricated FAIL.
function Get-MergeQueuePath {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $trimmed = [IO.Path]::TrimEndingDirectorySeparator($RepoRoot)
    $slug = Split-Path $trimmed -Leaf
    return (Join-Path (Join-Path (Join-Path $trimmed '.iqa') 'merge-queue') "$slug.jsonl")
}

function Get-QueueEvidenceVerdict {
    <#
        Turn ONE classifier invocation into a probe record. Pure: no I/O, no child
        process, so every branch is testable.

        The three lies this pins shut (measured 2026-11-16 on cl-common):
          * a missing queue was reported FAIL. It is SKIP: a repo with no queue has
            nothing to prove, exactly as QUEUE-GHOSTS already treats it.
          * the exit code was ignored and stderr was filtered out, so a classifier
            that exited 2 with "no queue at ..." on stderr produced EMPTY stdout;
            '' | ConvertFrom-Json is $null and @($null) counts as ONE row, which
            printed as count 1 / evidence '='. A record can only be built from a
            parsed row set, and a non-zero exit is CANNOT-EVALUATE naming what was
            printed.
          * a genuine red stays red: parsed rows whose reports name no tip still FAIL.
    #>
    param(
        [Parameter(Mandatory)][string]$QueuePath,
        [bool]$QueueExists = $true,
        [int]$ExitCode = 0,
        [string]$Stdout = '',
        [string]$Stderr = ''
    )
    $queueName = Split-Path $QueuePath -Leaf
    $printed = (@($Stderr, $Stdout) | Where-Object { $_ -and $_.Trim() }) -join ' '
    $printed = ($printed -replace '\s+', ' ').Trim()
    if ($printed.Length -gt 400) { $printed = $printed.Substring(0, 400) + '...' }
    $cannot = 'the probe cannot measure this queue: check node, the classifier and the queue path'

    if (-not $QueueExists) {
        return @{ Status = 'SKIP'; Measured = 'no merge queue for this repo'
            Evidence = "looked for $QueuePath"; Remedy = ''
        }
    }
    if ($ExitCode -ne 0) {
        return @{ Status = 'CANNOT-EVALUATE'; Measured = "classifier exited $ExitCode for $queueName"
            Evidence = $(if ($printed) { $printed } else { "printed nothing; queue $QueuePath" }); Remedy = $cannot
        }
    }
    $text = $Stdout.Trim()
    if (-not $text) {
        return @{ Status = 'CANNOT-EVALUATE'; Measured = "classifier printed nothing for $queueName"
            Evidence = "queue $QueuePath"; Remedy = $cannot
        }
    }
    try { $data = $text | ConvertFrom-Json -ErrorAction Stop }
    catch {
        return @{ Status = 'CANNOT-EVALUATE'; Measured = "classifier printed non-JSON for $queueName"
            Evidence = $printed; Remedy = $cannot
        }
    }
    if ($null -eq $data -or $data -is [array] -or -not $data.PSObject.Properties['rows']) {
        return @{ Status = 'CANNOT-EVALUATE'; Measured = "classifier printed no rows array for $queueName"
            Evidence = $printed; Remedy = $cannot
        }
    }

    # A row that is not an object cannot prove anything; drop the null hole so an
    # empty result is "no rows", never "one null row".
    $rows = @($data.rows | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0) {
        return @{ Status = 'PASS'; Measured = "queue empty ($queueName)"; Evidence = ''; Remedy = '' }
    }
    if (@($rows | Where-Object { $_.PSObject.Properties['report'] }).Count -eq 0) {
        return @{ Status = 'CANNOT-EVALUATE'; Measured = "rows carry no report field for $queueName"
            Evidence = $printed; Remedy = $cannot
        }
    }

    $proven = @($rows | Where-Object { $_.report -like 'TIP:*' })
    $stale = @($rows | Where-Object { $_.report -like 'stale:*' })
    $none = @($rows | Where-Object { $_.report -eq 'none' })
    $incomplete = @($proven | Where-Object { $_.report -notlike 'TIP:COMPLETE' })
    # Bounded on purpose: one unreadable 4,000-character line hides the count that matters.
    $shown = @($rows | Select-Object -First 12 | ForEach-Object { ('{0}={1}' -f $_.branch, $_.report) })
    if ($rows.Count -gt $shown.Count) { $shown += "+$($rows.Count - $shown.Count) more" }
    $status = if ($proven.Count -eq $rows.Count) { 'PASS' } elseif ($proven.Count -gt 0) { 'WARN' } else { 'FAIL' }
    return @{
        Status   = $status
        Measured = "$($rows.Count) queued from $queueName; proven $($proven.Count) (incomplete $($incomplete.Count)), stale $($stale.Count), none $($none.Count)"
        Evidence = ($shown -join '; ')
        Remedy   = $(if ($status -eq 'FAIL') { 'run the merge-unproven-tip skill: prove the tip, cherry-pick the small ones, discard superseded' } else { '' })
    }
}

# Dot-sourced by the Pester suite: helpers are defined, no probes run.
if ($LibraryOnly) { return }

# A native command writing to stderr becomes a terminating ErrorRecord while
# $ErrorActionPreference is 'Stop' - so `node ... 2>$null` throws instead of
# discarding. Every node probe goes through this helper: stdout only, stderr read
# as text (never thrown), and the caller still sees a real exit code.
function Invoke-NodeStdout {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & node @Arguments 2>&1
        $code = $LASTEXITCODE
        $stdout = @($lines | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
        # stderr is kept as TEXT, not thrown: a caller that cannot parse the
        # result must be able to say what the tool actually printed.
        $stderr = @($lines | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        return @{
            Output   = ($stdout | Out-String)
            Stderr   = (($stderr | ForEach-Object { $_.ToString() }) -join "`n")
            ExitCode = $code
        }
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

if (Test-ProbeWanted 'LOCK-HEALTH') {
    $lockFiles = @()
    $leaseDir = Join-Path $machineState 'worktree-leases'
    if (Test-Path -LiteralPath $leaseDir) {
        $lockFiles += @(Get-ChildItem -LiteralPath $leaseDir -Filter "$slug.*.json" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    $claimFile = Join-Path $machineState "claims\$slug.json"
    if (Test-Path -LiteralPath $claimFile) { $lockFiles += $claimFile }

    if ($lockFiles.Count -eq 0) {
        Add-Result 'LOCK-HEALTH' 'PASS' 'no lock or claim held' "looked in $leaseDir and $claimFile" ''
    }
    else {
        $failures = @()
        $warns = @()
        $checked = @()
        foreach ($file in $lockFiles) {
            try {
                $lock = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            }
            catch {
                $checked += "$([IO.Path]::GetFileName($file)): unreadable ($($_.Exception.Message))"
                $failures += "unreadable lock file $file"
                continue
            }
            $pidValue = 0
            if ($lock.PSObject.Properties['pid']) { try { $pidValue = [int]$lock.pid } catch { $pidValue = 0 } }
            $startUtc = if ($pidValue -gt 0) { Get-ProcessStartUtc $pidValue } else { $null }
            $verdict = Get-LockVerdict -Lock $lock -HolderStartUtc $startUtc
            $name = [IO.Path]::GetFileNameWithoutExtension($file)
            $checked += ('{0}: {1} - {2}' -f $name, $verdict.Status, $verdict.Why)
            if ($verdict.Status -eq 'FAIL') { $failures += ('{0}: {1}' -f $name, $verdict.Why) }
            if ($verdict.Status -eq 'WARN') { $warns += ('{0}: {1}' -f $name, $verdict.Why) }
        }
        $status = if ($failures.Count -gt 0) { 'FAIL' } elseif ($warns.Count -gt 0) { 'WARN' } else { 'PASS' }
        Add-Result 'LOCK-HEALTH' $status ("$($lockFiles.Count) lock file(s) checked") ($checked -join '; ') `
            ($(if ($status -eq 'FAIL') { 'release the stale lock by its helping tool (Invoke-TrunkMergeLock -Mode Release -Force) after proving the holder is gone/recycled' } else { '' }))
    }
}

# ------------------------------------------------------- SUITE-SLOT-PROGRESS
# A pid-alive test cannot tell a running suite from a parked one. This reuses the
# doctor that samples the holder's process TREE CPU against its tier ceiling:
# two signals to convict, one signal is a report.
if (Test-ProbeWanted 'SUITE-SLOT-PROGRESS') {
    $tool = Join-Path $RepoRoot 'scripts\suite-slot.mjs'
    if (-not (Test-Path -LiteralPath $tool)) {
        Add-Result 'SUITE-SLOT-PROGRESS' 'SKIP' 'no scripts/suite-slot.mjs in this repo' "looked for $tool" ''
    }
    else {
        try {
            $invoked = Invoke-NodeStdout -Arguments @($tool, 'doctor', '--json', '--window', "$SuiteSlotWindowSeconds")
            $parsed = $invoked.Output | ConvertFrom-Json
            $holders = @($parsed.holders)
            # A single CIM read can come back short on a busy box; re-measure once
            # before telling the operator "cannot evaluate" about a live suite.
            if ($holders.Count -gt 0 -and @($holders | Where-Object { $_.state -ne 'cannot-evaluate' }).Count -eq 0) {
                $retry = Invoke-NodeStdout -Arguments @($tool, 'doctor', '--json', '--window', "$SuiteSlotWindowSeconds")
                $retryParsed = $retry.Output | ConvertFrom-Json
                if (@($retryParsed.holders | Where-Object { $_.state -ne 'cannot-evaluate' }).Count -gt 0) { $parsed = $retryParsed }
                $holders = @($parsed.holders)
            }
            if ($holders.Count -eq 0) {
                Add-Result 'SUITE-SLOT-PROGRESS' 'PASS' 'no suite slot held' '' ''
            }
            else {
                $bad = @($holders | Where-Object { $_.state -eq 'wedged' })
                $warn = @($holders | Where-Object { $_.state -in @('idle-suspect', 'overdue-active') })
                $cannot = @($holders | Where-Object { $_.state -eq 'cannot-evaluate' })
                $lines = @($holders | ForEach-Object { ('pid {0} {1} {2}m {3}' -f $_.pid, $_.tier, [int]([double]$_.ageMs / 60000), $_.state) })
                if ($bad.Count -gt 0) {
                    Add-Result 'SUITE-SLOT-PROGRESS' 'FAIL' ("$($holders.Count) holder(s), $($bad.Count) wedged") ($lines -join '; ') `
                        'node scripts/suite-slot.mjs reap --apply   (kills wedged only, logs evidence)'
                }
                elseif ($cannot.Count -eq $holders.Count) {
                    Add-Result 'SUITE-SLOT-PROGRESS' 'CANNOT-EVALUATE' "$($holders.Count) holder(s), no CPU sample" ($lines -join '; ') 'run on the host that owns the slots; CPU sampling needs Get-CimInstance'
                }
                elseif ($warn.Count -gt 0) {
                    Add-Result 'SUITE-SLOT-PROGRESS' 'WARN' ("$($holders.Count) holder(s), $($warn.Count) slow/overdue") ($lines -join '; ') 'watch the next window; reap only on the wedged verdict'
                }
                else {
                    Add-Result 'SUITE-SLOT-PROGRESS' 'PASS' ("$($holders.Count) holder(s) burning CPU") ($lines -join '; ') ''
                }
            }
        }
        catch {
            Add-Result 'SUITE-SLOT-PROGRESS' 'CANNOT-EVALUATE' "suite-slot doctor failed: $($_.Exception.Message)" '' 'check node and the script path'
        }
    }
}

# ------------------------------------------------------------ QUEUE-EVIDENCE
# "A report exists" is not proof. The gate needs a report whose commit names the
# TIP with a COMPLETE status; anything else is a different repair.
if (Test-ProbeWanted 'QUEUE-EVIDENCE') {
    # $PSScriptRoot = <cl-common>/vendor/cl-orchestration/cl-paseo/scripts -> <cl-common>/Skills
    $skillsRoot = Join-Path (Split-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) -Parent) 'Skills'
    $classify = Join-Path $skillsRoot 'merge-unproven-tip\tools\classify-unproven.mjs'
    if (-not (Test-Path -LiteralPath $classify) -and $env:CL_REPOS_ROOT) {
        $classify = Join-Path $env:CL_REPOS_ROOT 'cl-common\Skills\merge-unproven-tip\tools\classify-unproven.mjs'
    }
    if (-not (Test-Path -LiteralPath $classify)) {
        Add-Result 'QUEUE-EVIDENCE' 'SKIP' 'classify-unproven.mjs not found' "looked for $classify" 'land the merge-unproven-tip skill or pass a repo that has it'
    }
    else {
        # Resolve THIS repo's queue and measure it, or say so. A repo with no queue
        # is not a failing repo; it is a repo with nothing queued.
        $queueFile = Get-MergeQueuePath -RepoRoot $RepoRoot
        if (-not (Test-Path -LiteralPath $queueFile)) {
            $verdict = Get-QueueEvidenceVerdict -QueuePath $queueFile -QueueExists $false
        }
        else {
            try {
                $invoked = Invoke-NodeStdout -Arguments @($classify, '--repo-root', $RepoRoot, '--queue', $queueFile, '--json')
                $verdict = Get-QueueEvidenceVerdict -QueuePath $queueFile -ExitCode $invoked.ExitCode `
                    -Stdout $invoked.Output -Stderr $invoked.Stderr
            }
            catch {
                $verdict = @{ Status = 'CANNOT-EVALUATE'; Measured = "classifier failed: $($_.Exception.Message)"
                    Evidence = "queue $queueFile"; Remedy = 'check node and the queue file path'
                }
            }
        }
        Add-Result 'QUEUE-EVIDENCE' $verdict.Status $verdict.Measured $verdict.Evidence $verdict.Remedy
    }
}

# -------------------------------------------------------------- QUEUE-GHOSTS
# A row whose tip is already an ancestor of the trunk is not pending work; it is
# a false starvation signal. Cheap: one merge-base per row.
if (Test-ProbeWanted 'QUEUE-GHOSTS') {
    $queueFile = Get-MergeQueuePath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $queueFile)) {
        Add-Result 'QUEUE-GHOSTS' 'SKIP' 'no merge queue for this repo' "looked for $queueFile" ''
    }
    else {
        try {
            $rows = [System.Collections.Generic.List[object]]::new()
            foreach ($line in (Get-Content -LiteralPath $queueFile | Where-Object { $_.Trim() })) {
                $rows.Add(($line | ConvertFrom-Json))
            }
            $latest = @{}
            foreach ($row in $rows) {
                if ($row.branch) { $latest[$row.branch] = $row }
            }
            $live = @($latest.Values | Where-Object { $_.status -in @('queued', 'merging') })
            $ghosts = @()
            foreach ($row in $live) {
                if (-not $row.sha) { continue }
                & git -C $RepoRoot merge-base --is-ancestor $row.sha HEAD 2>$null
                if ($LASTEXITCODE -eq 0) { $ghosts += $row.branch }
            }
            if ($ghosts.Count -gt 0) {
                Add-Result 'QUEUE-GHOSTS' 'FAIL' ("$($ghosts.Count) of $($live.Count) queued rows are already in HEAD") ($ghosts -join ', ') `
                    'Invoke-IqaQueue.ps1 -Mode Mark -Branch <b> -Status merged -Note "ancestry proven"'
            }
            else {
                Add-Result 'QUEUE-GHOSTS' 'PASS' ("$($live.Count) queued row(s), none landed") '' ''
            }
        }
        catch {
            Add-Result 'QUEUE-GHOSTS' 'CANNOT-EVALUATE' "queue read failed: $($_.Exception.Message)" '' ''
        }
    }
}

# ------------------------------------------------------------ WORKER-HEARTBEAT
# A worker that says what phase it is in, and how much TREE CPU it spent.
# Measured 2026-11-15: two trains sat 8 and 21 minutes with 5.7s of PARENT CPU while
# their trees had spent 53.1s gating; the machine was not pinned (32 cores, Defender
# the top consumer), the observer simply could not see the phase. This probe reads
# the beats the wrapper writes and convicts only on the two-signal rule.
if (Test-ProbeWanted 'WORKER-HEARTBEAT') {
    $beatDir = Join-Path $machineState 'merge-runner'
    $beats = @()
    if (Test-Path -LiteralPath $beatDir) {
        $beats = @(Get-ChildItem -LiteralPath $beatDir -Filter '*.heartbeat.json' -ErrorAction SilentlyContinue)
    }
    $liveRunners = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'iqa-merge-runner\.mjs' })

    if ($beats.Count -eq 0) {
        if ($liveRunners.Count -gt 0) {
            Add-Result 'WORKER-HEARTBEAT' 'WARN' ("$($liveRunners.Count) runner(s) live, no heartbeat") `
                (($liveRunners | ForEach-Object { "pid=$($_.ProcessId)" }) -join ', ') `
                'start the runner through cl-paseo/tools/run-with-heartbeat.mjs so its phase and tree CPU are readable'
        }
        else {
            Add-Result 'WORKER-HEARTBEAT' 'PASS' 'no runner and no beat' '' ''
        }
    }
    else {
        $fail = @()
        $warn = @()
        $pass = @()
        $unreadable = 0
        $instances = @{}
        foreach ($file in $beats) {
            try {
                $beat = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            }
            catch {
                $unreadable += 1
                continue
            }
            $alive = $false
            if ($beat.pid) { $alive = [bool](Get-Process -Id ([int]$beat.pid) -ErrorAction SilentlyContinue) }
            $ageSec = $null
            if ($beat.updatedAt) {
                try { $ageSec = [int](([datetime]::UtcNow - ([datetime]$beat.updatedAt).ToUniversalTime()).TotalSeconds) } catch { $ageSec = $null }
            }
            $interval = if ($beat.intervalSeconds) { [int]$beat.intervalSeconds } else { 180 }
            $label = if ($beat.label) { [string]$beat.label } else { [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($file.Name)) }
            if ($alive) {
                if (-not $instances.ContainsKey($label)) { $instances[$label] = @() }
                $instances[$label] += $beat.instanceId
            }
            if ($beat.verdict -eq 'stalled') {
                $fail += ('{0}: STALLED phase={1} treeCpu={2}s beats={3}' -f $label, $beat.phase, $beat.treeCpuDelta, $beat.repeats)
            }
            elseif ($alive -and $null -ne $ageSec -and $ageSec -gt (3 * $interval)) {
                $fail += ('{0}: no beat for {1}s (interval {2}s) while pid {3} is alive' -f $label, $ageSec, $interval, $beat.pid)
            }
            elseif (-not $alive -and $beat.verdict -ne 'done') {
                $fail += ('{0}: pid {1} is gone but the last beat says {2}' -f $label, $beat.pid, $beat.verdict)
            }
            elseif ($beat.verdict -eq 'done') {
                $pass += ('{0}: done exit={1}' -f $label, $beat.exitCode)
            }
            else {
                $pass += ('{0}: {1} phase={2} treeCpu={3}s' -f $label, $beat.verdict, $beat.phase, $beat.treeCpuDelta)
            }
        }
        foreach ($label in $instances.Keys) {
            $ids = @($instances[$label] | Where-Object { $_ } | Select-Object -Unique)
            if ($ids.Count -gt 1) {
                $fail += ('{0}: {1} LIVE instances at once ({2}) - the one-merge-lane rule' -f $label, $ids.Count, ($ids -join ', '))
            }
        }
        $status = if ($fail.Count -gt 0) { 'FAIL' } elseif ($unreadable -eq $beats.Count) { 'CANNOT-EVALUATE' } elseif ($warn.Count -gt 0) { 'WARN' } else { 'PASS' }
        Add-Result 'WORKER-HEARTBEAT' $status ("$($beats.Count) beat file(s), $($fail.Count) failing") `
            (@($fail) + @($warn) + @($pass) | Where-Object { $_ }) -join '; ' `
            ($(if ($fail.Count -gt 0) { 'a stalled worker is normally killed by the owner (the probe decides, the Hub acts); duplicate instances: kill the younger' } else { '' }))
    }
}

# ------------------------------------------------------------------- BRANCHES
# How many branches exist, which class each is, and whether the counts reconcile.
# Operator direction 2026-11-16: every Repo Health call carries this from now on.
# The reason is a measured false-green: a report could say PASS while 25 branches
# waited behind the trunk. Classification belongs to the inventory (repo-clean
# -Plan); this probe only runs it and renders it, never re-derives a class.
if (-not $SkipBranches -and (Test-ProbeWanted 'BRANCHES')) {
    $inventory = Join-Path $PSScriptRoot '..\..\..\..\Skills\cl-clean\scripts\ProcessHealth.Inventory.ps1'
    if (-not (Test-Path -LiteralPath $inventory)) {
        Add-Result 'BRANCHES' 'CANNOT-EVALUATE' 'inventory script not found' "looked for $inventory" `
            'restore Skills/cl-clean/scripts/ProcessHealth.Inventory.ps1'
    }
    else {
        try {
            $raw = & pwsh -NoProfile -File $inventory -RepoRoot $RepoRoot -Json 2>&1 | Out-String
            $start = $raw.IndexOf('{')
            if ($start -lt 0) { throw "no JSON: $($raw.Substring(0, [Math]::Min(200, $raw.Length)))" }
            $payload = $raw.Substring($start) | ConvertFrom-Json
            $status = switch ([string]$payload.verdict) {
                'PASS' { 'PASS' }
                'WARN' { 'WARN' }
                default { 'CANNOT-EVALUATE' }
            }
            $evidence = @()
            $problems = @($payload.branches.reconcileProblems | Where-Object { $_ })
            if ($problems.Count -gt 0) { $evidence += ($problems -join '; ') }
            $merged = @($payload.mergedButPresent.names | Where-Object { $_ })
            if ($merged.Count -gt 0) { $evidence += "$($merged.Count) merged branch(es) still present: $($merged -join ', ')" }
            Add-Result 'BRANCHES' $status (Format-BranchSummary $payload.branches) ($evidence -join '; ') `
                'repo-clean -Plan is the one owner of branch classification; delete merged branches with the groom, and a plan that cannot reconcile is not a pass'
        }
        catch {
            Add-Result 'BRANCHES' 'CANNOT-EVALUATE' "inventory failed: $($_.Exception.Message)" '' `
                'check pwsh, the inventory path, and whether its output is JSON'
        }
    }
}

# ------------------------------------------------------------------- output
$failCount = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$ceCount = @($results | Where-Object { $_.Status -eq 'CANNOT-EVALUATE' }).Count

if ($Json) {
    [pscustomobject]@{
        repo      = $slug
        repoRoot  = $RepoRoot
        checkedAt = (Get-Date).ToUniversalTime().ToString('o')
        probes    = @($results)
        exitCode  = if ($failCount -gt 0) { 1 } elseif ($ceCount -gt 0) { 2 } else { 0 }
    } | ConvertTo-Json -Depth 6
}
else {
    $marked = $results | Select-Object @{ n = 'Status'; e = { Format-HealthStatus -Status $_.Status -Ascii:$Ascii -Glyphs:$Glyphs } }, Id, Measured
    $marked | Format-Table -AutoSize | Out-String | Write-Host
    foreach ($r in $results) {
        if ($r.Status -in @('FAIL', 'WARN', 'CANNOT-EVALUATE')) {
            Write-Host ("{0} {1}: {2}" -f (Format-HealthStatus -Status $r.Status -Ascii:$Ascii -Glyphs:$Glyphs), $r.Id, $r.Evidence)
            if ($r.Remedy) { Write-Host ("       remedy: {0}" -f $r.Remedy) }
        }
    }
}

if ($failCount -gt 0) { exit 1 }
if ($ceCount -gt 0) { exit 2 }
exit 0
