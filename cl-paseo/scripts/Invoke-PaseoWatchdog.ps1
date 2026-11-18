#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$PaseoHome = (Join-Path $env:USERPROFILE '.paseo'),
    [string]$PaseoExe = 'C:\Program Files\Paseo\resources\bin\paseo.cmd',
    [string]$StateDir = (Join-Path $env:USERPROFILE '.machine\state\key-check'),
    [string]$TaskName = 'Paseo Daemon',
    [switch]$ResumeAtBoot,
    [switch]$ProbeOnly
)

$ErrorActionPreference = 'Stop'
if ($ResumeAtBoot -and $ProbeOnly) { throw 'Use -ProbeOnly without -ResumeAtBoot.' }
$StateDir = [IO.Path]::GetFullPath($StateDir)
$PaseoHome = [IO.Path]::GetFullPath($PaseoHome)
$scripts = Join-Path $PSScriptRoot '..\..\..\..\vendor\interactive-qa\vendor\credential-rescue\scripts'
. (Join-Path $scripts 'lib\PaseoCommon.ps1')
. (Join-Path $scripts 'lib\PaseoCutover.ps1')
. (Join-Path $scripts 'lib\CutoverRecovery.ps1')
. (Join-Path $scripts 'lib\CutoverSeam.ps1')
. (Join-Path $scripts '..\..\aws\scripts\SecretFingerprint.ps1')

$statusFile = Join-Path $StateDir 'paseo-watchdog.json'
$journalFile = Join-Path $StateDir 'recovery-needed.json'
$markerFile = Join-Path $StateDir 'cutover-in-progress.json'
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
$now = [DateTimeOffset]::UtcNow

function Read-State([string]$Path) {
    if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
}

function Write-State([string]$Path, $Value) {
    $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$Path.$PID.tmp" -Encoding utf8NoBOM
    [IO.File]::Move("$Path.$PID.tmp", $Path, $true)
}

function Get-DaemonStatus {
    try {
        Invoke-PaseoCutoverCommand $PaseoExe @('daemon', 'status', '--home', $PaseoHome, '--json') 'Paseo health' 15 |
            ConvertFrom-Json
    } catch { Write-Verbose 'Paseo health did not return status.' }
}

function Test-DaemonReady($Status) {
    return ($Status.localDaemon -eq 'running' -and $Status.connectedDaemon -eq 'reachable')
}

function Wait-BootDaemon {
    $deadline = (Get-Date).AddMinutes(4)
    do {
        $status = Get-DaemonStatus
        if (Test-DaemonReady $status) { return $status }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    return $status
}

function Get-CutoverOutcome($Journal) {
    if (-not $Journal -or [string]::IsNullOrWhiteSpace($Journal.outcomePath)) { return }
    $path = [IO.Path]::GetFullPath($Journal.outcomePath)
    if ([IO.Path]::GetDirectoryName($path) -ne [IO.Path]::GetFullPath($StateDir).TrimEnd('\') -or
        $Journal.runId -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid recovery journal.' }
    $outcome = Read-State $path
    if (-not $outcome -or $outcome.runId -ne $Journal.runId -or -not $outcome.applied) {
        throw 'Recovery journal has no matching applied outcome.'
    }
    return $outcome
}

function Invoke-BootRecovery($Journal, $Outcome) {
    $receipt = Join-Path $StateDir "$($Journal.runId)-paseo-restart.json"
    $config = Join-Path $PaseoHome 'config.json'
    $expected = "GO$([int]$Outcome.keyNumber)"
    $seam = Read-CutoverSeamConfig -Path (Resolve-CutoverSeamPath)
    if ((Get-CutoverSeamKeyLabel $seam) -ne $expected) { throw 'Post-reboot seam no longer agrees with the saved cutover.' }
    $label = Get-PaseoRestartKeyLabel -ReceiptPath $receipt -ConfigPath $config -DaemonPidFile (Join-Path $PaseoHome 'paseo.pid')
    if ($label -ne $expected) {
        $null = Invoke-PaseoCutoverCommand (Join-Path $scripts 'Repair-Paseo.ps1') @(
            '-KeyNumber', [string]$Outcome.keyNumber, '-PaseoCli', $PaseoExe, '-PaseoConfig', $config, '-RestartReceipt', $receipt, '-NoDshSync'
        ) 'Paseo post-reboot cutover recovery' 270
        $label = Get-PaseoRestartKeyLabel -ReceiptPath $receipt -ConfigPath $config -DaemonPidFile (Join-Path $PaseoHome 'paseo.pid')
    }
    if ($label -ne $expected) { throw 'Post-reboot repair did not prove the selected key.' }

    if ($Outcome.rosterPath) {
        $resumed = Invoke-PaseoCutoverCommand (Join-Path $scripts 'Resume-KeyCheckRoster.ps1') @(
            '-RosterPath', [string]$Outcome.rosterPath, '-StateDir', $StateDir, '-Json'
        ) 'Post-reboot cutover roster' 330 | ConvertFrom-Json
        if ($resumed.counts.failed -gt 0) { throw 'The saved roster includes agents that could not resume.' }
    }
    $Outcome.verified = $true
    $Outcome.restartPending = $false
    $Outcome.reason = 'verified-after-reboot'
    $Outcome.surfaces = @($Outcome.surfaces | Where-Object name -notin @('paseo-pin', 'paseo-restart'))
    $Outcome.surfaces += @{ name = 'paseo-restart'; expected = $expected; actual = $label; ok = $true }
    Write-State $Journal.outcomePath $Outcome
    Remove-Item -LiteralPath $journalFile
}

function Invoke-Watchdog {
    $journal = Read-State $journalFile
    $outcome = Get-CutoverOutcome $journal
    $verified = $outcome.verified -is [bool] -and $outcome.verified
    $marker = Read-State $markerFile
    $activeCutover = $marker -and [DateTimeOffset]$marker.startedAt -ge $boot -and
        ($now - [DateTimeOffset]$marker.startedAt).TotalMinutes -lt 10
    if ($activeCutover) { return 'cutover-in-progress' }
    if (Test-Path -LiteralPath (Join-Path $StateDir 'partial-cutover.json')) { return 'partial-cutover' }

    if ($ResumeAtBoot -and $journal -and -not $verified -and [DateTimeOffset]$journal.at -lt $boot) {
        if ($journal.lastRecoveryBoot -eq $boot.ToString('o')) { return 'post-reboot-recovery-failed' }
        $journal | Add-Member -NotePropertyName lastRecoveryBoot -NotePropertyValue $boot.ToString('o') -Force
        Write-State $journalFile $journal
        try {
            Invoke-BootRecovery $journal $outcome
            if ($marker.runId -eq $journal.runId) { Remove-Item -LiteralPath $markerFile }
        } catch { return 'post-reboot-recovery-failed' }
        $journal = $null
        $marker = $null
        $recoveredRoster = [bool]$outcome.rosterPath
    }
    if ($journal -and -not $verified) {
        if ($journal.lastRecoveryBoot -eq $boot.ToString('o')) { return 'post-reboot-recovery-failed' }
        if ($outcome.reason -eq 'paseo-reboot-required' -and [DateTimeOffset]$journal.at -ge $boot) {
            return 'reboot-required'
        }
        return 'cutover-unverified'
    }
    if ($marker) {
        if ($verified -and $marker.runId -eq $outcome.runId) {
            if (-not $ProbeOnly) { Remove-Item -LiteralPath $markerFile }
        } else { return 'cutover-marker-stale' }
    }
    if ($journal -and -not $ProbeOnly) { Remove-Item -LiteralPath $journalFile }
    try { $free = Get-OpenCodeStorageFreeBytes } catch { return 'opencode-storage-unavailable' }
    if ($free -lt 500MB) { return 'opencode-storage-unavailable' }

    $livenessArgs = @('-StatePath', (Join-Path $StateDir 'state.json'), '-Json')
    if (-not $ProbeOnly) { $livenessArgs += '-Restart' }
    $liveness = $null
    try {
        $liveness = Invoke-PaseoCutoverCommand (Join-Path $scripts 'Test-KeyCheckLiveness.ps1') $livenessArgs 'Key Check supervisor' 25 |
            ConvertFrom-Json
    } catch { Write-Verbose 'Key Check supervisor did not return a live verdict.' }

    if (-not $ResumeAtBoot -and -not $ProbeOnly) {
        # Record which agents are running for the next boot's resume pass
        # (cl-common-923q): a graceful shutdown saves them as closed/idle, so the
        # boot pass cannot rely on lastStatus. Reads on-disk records only, so it
        # works with the daemon down; a failure never fails the watchdog tick.
        try {
            $null = Invoke-PaseoCutoverCommand (Join-Path $PSScriptRoot 'Resume-PaseoAgents.ps1') @(
                '-PaseoHome', $PaseoHome, '-WriteRoster'
            ) 'Paseo running roster' 30
        } catch { Write-Verbose 'Running roster was not written.' }
    }    $daemon = if ($ResumeAtBoot) { Wait-BootDaemon } else { Get-DaemonStatus }
    if (-not (Test-DaemonReady $daemon)) {
        if (-not $ProbeOnly -and -not $ResumeAtBoot -and $daemon.localDaemon -ne 'running' -and
            $daemon.configuredListen -match ':(\d+)$' -and
            -not @(Get-PaseoListenerOwners -Port ([int]$Matches[1])).Count) {
            Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            return 'daemon-restarting'
        }
        return 'daemon-unreachable'
    }
    if (-not ($daemon.providers | Where-Object { $_.provider -eq 'opencode' -and $_.available })) {
        return 'opencode-unavailable'
    }
    if ($ResumeAtBoot -and -not $recoveredRoster) {
        try {
            $null = Invoke-PaseoCutoverCommand (Join-Path $PSScriptRoot 'Resume-PaseoAgents.ps1') @(
                '-PaseoHome', $PaseoHome, '-PaseoExe', $PaseoExe, '-WaitSeconds', '45'
            ) 'Paseo boot resume' 570
        } catch { return 'boot-resume-failed' }
    }
    if ($free -lt 2GB) { return 'opencode-storage-low' }
    if (-not $liveness) { return 'watcher-unavailable' }
    if ($liveness.status -eq 'lapsed' -and $liveness.endReason -eq 'no-eligible-replacement') {
        return 'no-eligible-replacement'
    }
    if ($liveness.action -eq 'restarted') { return 'watcher-restarting' }
    if ($liveness.status -ne 'live') { return 'watcher-unavailable' }
    $verdict = Read-State (Join-Path $StateDir 'verdict.json')
    if ($verdict.runId -eq $liveness.runId) {
        if ($verdict.verdict -eq 'IMMINENT') { return 'key-imminent' }
        if ($verdict.cannotEvaluate -and $verdict.cannotEvaluateStreak -ge 2) { return 'key-usage-unavailable' }
        $state = Read-State (Join-Path $StateDir 'state.json')
        $maxAge = [Math]::Max(900, 2 * [int]$state.cadenceSeconds + 300)
        if ($verdict.checkedAt -and ($now - [DateTimeOffset]$verdict.checkedAt).TotalSeconds -gt $maxAge) {
            return 'key-watch-reading-stale'
        }
    } else { return 'watch-reading-pending' }
    return 'healthy'
}

function Publish-WatchdogStatus([string]$Code, [bool]$Alert) {
    $previous = $null
    try { $previous = Read-State $statusFile } catch { Write-Verbose 'Previous watchdog status was unreadable.' }
    $since = if ($previous.code -eq $code) { $previous.since } else { $now.ToString('o') }
    $result = @{ code = $code; alert = $alert; since = $since; checkedAt = $now.ToString('o'); sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId }
    $null = New-Item -ItemType Directory -Force -Path $StateDir
    Write-State $statusFile $result
    if ($alert -and (-not $previous.alert -or $previous.code -ne $code)) {
        $message = "Paseo watchdog: $code. See $statusFile."
        if ($code -eq 'reboot-required') { $message += ' Save your work and restart Windows to release the stuck Paseo process.' }
        try { [Diagnostics.EventLog]::WriteEntry('Paseo Watchdog', $message, 'Error', 676) } catch {
            Write-Warning 'Paseo watchdog could not write to the Windows Application log.'
        }
    }
    # The external receiver must expect a ping every five minutes. A missing
    # ping then catches failures that stop the scheduler or PowerShell itself.
    $endpoint = [Environment]::GetEnvironmentVariable('KEY_CHECK_HEALTHCHECK_URL', 'User')
    if ($endpoint) {
        try {
            $uri = [uri]$endpoint
            if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.Query -or $uri.Fragment -or $uri.UserInfo) { throw 'Invalid HTTPS ping URL.' }
            if ($alert) {
                $null = Invoke-WebRequest -Uri ($endpoint.TrimEnd('/') + '/fail') -Method Post -Body $code -TimeoutSec 10 -MaximumRedirection 0
            } elseif ($code -eq 'healthy') {
                $null = Invoke-WebRequest -Uri $endpoint -Method Post -TimeoutSec 10 -MaximumRedirection 0
            }
        } catch { Write-Warning 'Paseo watchdog could not send the configured external heartbeat.' }
    }
}

$mutex = [Threading.Mutex]::new($false, 'Local\Paseo-KeyCheck-Watchdog')
try {
    $entered = $false
    if (-not $ProbeOnly) {
        try { $entered = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $entered = $true }
        if (-not $entered) { return }
    }
    try { $code = Invoke-Watchdog } catch {
        Write-Verbose "Watchdog check failed ($($_.Exception.GetType().Name))."
        $code = 'watchdog-check-failed'
    }
    $transient = $code -in @('cutover-in-progress', 'daemon-restarting', 'watcher-restarting', 'watch-reading-pending')
    $alert = $code -ne 'healthy' -and -not $transient
    if (-not $ProbeOnly) {
        if ($transient) {
            try {
                $previous = Read-State $statusFile
                $alert = $previous.code -eq $code -and ($now - [DateTimeOffset]$previous.since).TotalMinutes -ge 5
            } catch { Write-Verbose 'Previous watchdog status was unreadable.' }
        }
        Publish-WatchdogStatus $code $alert
    }
    [pscustomobject]@{ code = $code; alert = $alert; checkedAt = $now.ToString('o') } | ConvertTo-Json -Compress
    if ($alert) { exit 1 }
} finally {
    if ($entered) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
