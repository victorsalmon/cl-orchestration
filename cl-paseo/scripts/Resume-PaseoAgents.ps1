<#
.SYNOPSIS
    Resume the agents a reboot interrupted, once the daemon is back.

.DESCRIPTION
    A reboot restarts the daemon but does not continue the work that was in
    flight: each agent keeps its provider session on disk with
    `lastStatus: "running"`, and nothing nudges it. This reconciler closes that
    gap deterministically - no agent judgement involved.

    Classification (same rule as the `auto-resume` skill):

      lastStatus=running, daemon does not report it running  -> interrupted, resume
      lastStatus=error                                       -> resume
      lastStatus=idle/closed                                 -> leave alone
      archived                                               -> leave alone
      lastActivityAt older than -MaxAgeHours                 -> leave alone (stale)

    PRE-BOOT ROSTER (cl-common-923q). A graceful Windows shutdown stops the
    daemon cleanly, and Paseo then saves every interrupted agent as
    closed/idle, so the lastStatus rule above finds nothing. Measured on the
    2026-11-13 reboot: 6 lanes were running, 0 were resumed. So the watchdog
    tick runs this script with -WriteRoster every few minutes, which records
    the agents whose on-disk record says running. The boot pass also resumes
    every agent on the roster written during the PREVIOUS boot (not archived,
    not stale, not live now), and marks that roster consumed for this boot so
    a re-run never sends twice.
    Resume means `paseo send <id> Continue`, which re-attaches the persisted
    provider session (`<home>/agents/<workspace>/<agent>.json` ->
    `persistence.sessionId`); it is not a fresh dispatch.

.PARAMETER PaseoHome
    Paseo home to reconcile. Defaults to ~/.paseo.

.PARAMETER DryRun
    Print the plan and write nothing, send nothing.

.PARAMETER SkipDaemonWait
    Do not wait for the daemon to answer. Useful for offline logic tests
    against a fixture home.

.PARAMETER MaxAgeHours
    Ignore agents whose last activity is older than this. Default 24.

.PARAMETER MaxResumes
    Hard ceiling on resumes per run. A corrupt or unexpected state must never
    resurrect hundreds of agents against one provider key. Default 12.

.PARAMETER BetweenResumesSeconds
    Pause between resumes. Provider keys have a concurrency cap (opencode-go 6)
    and an instant burst of N prompts trips 429s / key exhaustion. Default 20.

.PARAMETER Manifest
    Write the candidate list to this path as JSON before sending anything.
    Combine with -DryRun for a list-only pass that changes nothing.

.PARAMETER FromManifest
    Send `Continue` to exactly the ids in this manifest instead of
    re-classifying. Use it to replay a reviewed list deterministically.

.EXAMPLE
    .\Resume-PaseoAgents.ps1 -DryRun

.EXAMPLE
    # what the boot task runs
    .\Resume-PaseoAgents.ps1
#>
[CmdletBinding()]
param(
    [string]$PaseoHome = (Join-Path $env:USERPROFILE '.paseo'),
    [string]$PaseoExe = 'C:\Program Files\Paseo\resources\bin\paseo.cmd',
    [switch]$DryRun,
    [switch]$SkipDaemonWait,
    [int]$MaxAgeHours = 24,
    [int]$MaxResumes = 12,
    [int]$BetweenResumesSeconds = 20,
    [string]$Manifest,
    [string]$FromManifest,
    [int]$WaitSeconds = 300,
    # Record the running agents for the next boot's resume pass, then exit.
    [switch]$WriteRoster,
    # Override the OS boot time (tests). ISO-8601.
    [string]$BootTime
)

$ErrorActionPreference = 'Stop'
$cutoverScripts = Join-Path $PSScriptRoot '..\..\..\..\vendor\interactive-qa\vendor\credential-rescue\scripts'
. (Join-Path $cutoverScripts 'lib\PaseoCutover.ps1')
$logPath = Join-Path $PaseoHome 'resume-boot.log'

function Write-Log([string]$message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'), $message
    Write-Output $line
    if (-not $DryRun) { Add-Content -Path $logPath -Value $line -Encoding utf8 }
}

function Get-LiveAgentIds {
    if ($SkipDaemonWait) { return @() }
    $raw = Invoke-PaseoCutoverCommand $PaseoExe @('ls', '--global', '--background', '--home', $PaseoHome, '--json') 'Paseo live agent list' 20
    $agents = $raw | ConvertFrom-Json
    return @($agents | Where-Object { $_.status -eq 'running' -or $_.lifecycle -eq 'running' } | ForEach-Object { $_.id })
}

$rosterPath = Join-Path $PaseoHome 'running-roster.json'
$prebootPath = Join-Path $PaseoHome 'running-roster.preboot.json'
$boot = if ($BootTime) { [DateTimeOffset]::Parse($BootTime) } else {
    [DateTimeOffset](Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
}

function ConvertTo-Instant($Stamp) {
    # ConvertFrom-Json turns an ISO string back into a [DateTime]; accept both.
    if ($null -eq $Stamp -or "$Stamp" -eq '') { return $null }
    if ($Stamp -is [DateTimeOffset]) { return $Stamp }
    if ($Stamp -is [DateTime]) { return [DateTimeOffset]$Stamp }
    try { return [DateTimeOffset]::Parse([string]$Stamp, [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}

function Test-SameBoot($Stamp) {
    $instant = ConvertTo-Instant $Stamp
    if ($null -eq $instant) { return $false }
    return [Math]::Abs(($instant - $boot).TotalSeconds) -lt 2
}

function Read-Roster([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
}

function Get-AgentRecords {
    Get-ChildItem (Join-Path $PaseoHome 'agents') -Recurse -Filter *.json -ErrorAction SilentlyContinue |
        ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { } } |
        Where-Object { $_ -and $_.id -and -not $_.archivedAt }
}

if ($WriteRoster) {
    # Source of truth is the on-disk record (the daemon keeps lastStatus current
    # while an agent runs). `paseo ls` is directory-scoped and hides background
    # agents by default, so it is not used here.
    $running = @(Get-AgentRecords | Where-Object { $_.lastStatus -in @('running', 'initializing') } |
        ForEach-Object { [ordered]@{ id = $_.id; title = [string]$_.title } })
    $existing = Read-Roster $rosterPath
    if ($existing -and -not (Test-SameBoot $existing.bootAt)) {
        # First write of a new boot: keep the previous boot's roster for the boot pass.
        Move-Item -LiteralPath $rosterPath -Destination $prebootPath -Force
    }
    $doc = [ordered]@{ at = [DateTimeOffset]::UtcNow.ToString('o'); bootAt = $boot.ToUniversalTime().ToString('o'); agents = $running }
    $tmp = "$rosterPath.tmp"
    $doc | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $rosterPath -Force
    Write-Output ("roster: {0} running agent(s) -> {1}" -f $running.Count, $rosterPath)
    exit 0
}

Write-Log "reconcile start home=$PaseoHome dryRun=$([bool]$DryRun)"

if (-not $SkipDaemonWait) {
    $reachable = $false
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        try {
            $status = Invoke-PaseoCutoverCommand $PaseoExe @('daemon', 'status', '--home', $PaseoHome, '--json') 'Paseo boot health' 8 | ConvertFrom-Json
            if ($status.localDaemon -eq 'running' -and $status.connectedDaemon -eq 'reachable') { $reachable = $true; break }
        } catch { }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    if (-not $reachable) {
        Write-Log "daemon did not answer within ${WaitSeconds}s; nothing resumed"
        exit 1
    }
    Write-Log 'daemon reachable'
}

$live = @(Get-LiveAgentIds)
$cutoff = (Get-Date).ToUniversalTime().AddHours(-$MaxAgeHours)

if ($FromManifest) {
    Write-Log "manifest mode: $FromManifest (classification skipped)"
    $doc = Get-Content $FromManifest -Raw | ConvertFrom-Json
    $interrupted = @(
        foreach ($c in $doc.candidates) {
            if ($live -contains $c.id) { continue }
            [pscustomobject]@{
                id = $c.id; title = $c.title; lastStatus = 'manifest'
                provider = $c.provider; cwd = $c.cwd; updatedAt = $c.lastActivityAt
            }
        }
    )
    Write-Log ("candidates: {0} from manifest, live-skipped={1}" -f $interrupted.Count, $live.Count)
} else {
    $records = @(Get-AgentRecords)

    $interrupted = @()
    foreach ($agent in $records) {
        $age = if ($agent.lastActivityAt) { ([datetime]$agent.lastActivityAt).ToUniversalTime() } else { $cutoff.AddSeconds(-1) }

        if ($live -contains $agent.id) { continue }
        if ($age -lt $cutoff) { continue }

        switch ($agent.lastStatus) {
            'running' { $interrupted += $agent }
            'error' { if ($agent.requiresAttention -ne $true) { $interrupted += $agent } }
            default { }
        }
    }

    # Pre-boot roster: the previous boot's running set, consumed once per boot.
    $rosterSource = $null
    foreach ($candidatePath in @($rosterPath, $prebootPath)) {
        $doc = Read-Roster $candidatePath
        if ($doc -and -not (Test-SameBoot $doc.bootAt)) { $rosterSource = @{ Path = $candidatePath; Doc = $doc }; break }
    }
    if ($rosterSource -and (Test-SameBoot $rosterSource.Doc.consumedBoot)) {
        Write-Log "roster: $($rosterSource.Path) already consumed for this boot"
        $rosterSource = $null
    }
    if ($rosterSource) {
        $ids = @($rosterSource.Doc.agents | ForEach-Object { [string]$_.id })
        $added = 0
        foreach ($agent in $records) {
            if ($ids -notcontains $agent.id) { continue }
            if ($live -contains $agent.id) { continue }
            if (@($interrupted | Where-Object { $_.id -eq $agent.id }).Count) { continue }
            $age = if ($agent.lastActivityAt) { ([datetime]$agent.lastActivityAt).ToUniversalTime() } else { $cutoff.AddSeconds(-1) }
            if ($age -lt $cutoff) { continue }
            $interrupted += $agent
            $added++
        }
        Write-Log ("roster: {0} from {1} (written {2})" -f $added, $rosterSource.Path, $rosterSource.Doc.at)
    }

    Write-Log ("candidates: {0} live-skipped={1}" -f $interrupted.Count, $live.Count)

    $interrupted = @($interrupted | Sort-Object { $_.lastActivityAt } -Descending)
}

if ($interrupted.Count -gt $MaxResumes) {
    Write-Log ("capped at {0} of {1}; most recent first, raise -MaxResumes deliberately" -f $MaxResumes, $interrupted.Count)
    $interrupted = @($interrupted | Select-Object -First $MaxResumes)
}

if ($Manifest) {
    $doc = [ordered]@{
        generatedAt = (Get-Date).ToString('o')
        paseoHome   = $PaseoHome
        dryRun      = [bool]$DryRun
        count       = $interrupted.Count
        candidates  = @($interrupted | ForEach-Object {
            [ordered]@{
                id = $_.id; title = $_.title; status = $_.lastStatus
                provider = $_.provider; cwd = $_.cwd; lastActivityAt = $_.lastActivityAt
            }
        })
    }
    $doc | ConvertTo-Json -Depth 5 | Set-Content -Path $Manifest -Encoding utf8
    Write-Log "manifest written: $Manifest ($($interrupted.Count) candidates)"
}

$resumed = 0
$failed = 0
foreach ($agent in $interrupted) {
    $title = if ($agent.title) { $agent.title } else { '(untitled)' }
    $why = "status=$($agent.lastStatus) provider=$($agent.provider) cwd=$($agent.cwd) updated=$($agent.updatedAt)"
    if ($DryRun) {
        Write-Log "WOULD RESUME $($agent.id)  $title  [$why]"
        continue
    }
    try {
        $null = Invoke-PaseoCutoverCommand $PaseoExe @('send', $agent.id, 'Continue', '--home', $PaseoHome, '--no-wait') 'Paseo Continue' 25
        $resumed++
        Write-Log "RESUMED $($agent.id)  $title  [$why]"
    } catch {
        $failed++
        Write-Log "FAILED  $($agent.id)  $title  err=$($_.Exception.Message)"
    }
    if ($BetweenResumesSeconds -gt 0) { Start-Sleep -Seconds $BetweenResumesSeconds }
}

if (-not $DryRun -and -not $FromManifest -and $rosterSource) {
    $rosterSource.Doc | Add-Member -NotePropertyName consumedBoot -NotePropertyValue $boot.ToUniversalTime().ToString('o') -Force
    $rosterSource.Doc | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $rosterSource.Path -Encoding utf8
}

Write-Log "reconcile done resumed=$resumed failed=$failed dryRun=$([bool]$DryRun)"
if ($failed) { exit 1 }

