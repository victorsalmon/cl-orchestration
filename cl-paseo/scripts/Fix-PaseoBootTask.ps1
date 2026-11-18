<#
.SYNOPSIS
    Repair the "Paseo Daemon" boot task so the Paseo daemon comes back after an
    unattended reboot, before anyone logs in.

.DESCRIPTION
    The task is a boot-triggered scheduled task whose principal is the operator
    account with LogonType S4U (runs at boot with no stored password and no
    interactive logon). That design is correct; the launch command rotted:
    Paseo 0.14.x removed `daemon start --foreground`, so the task exited 1 and
    the daemon only ever came up when the desktop app was launched by hand.

    The repair runs the supported headless command with the current User key,
    restores Task Scheduler retry settings and enables its operational log.

    Requires an elevated session (the task file grants the operator account
    read-only; BUILTIN\Administrators has write).

.PARAMETER Verify
    Read-only. Prints the registered action, watchdog settings, last run
    result, and whether a daemon currently answers. No registration change.

.PARAMETER RunNow
    Starts the task immediately to exercise the boot path without a reboot.
    Refuses while any daemon already answers on the configured endpoint,
    because a second instance would just fail with an expected port/instance
    conflict and prove nothing.

.PARAMETER WithResumeTask
    Also register the companion task "Paseo Boot Resume", which fires
    -ResumeDelayMinutes after boot and runs Resume-PaseoAgents.ps1 to nudge the
    agents the reboot interrupted. Separate task on purpose: the daemon has to
    be up before a resume tick means anything.

.PARAMETER DispatchAgent
    With -WithResumeTask, make the companion task dispatch an agent running the
    `auto-resume` runbook instead of the deterministic script. Use when you want
    judgement in the loop (re-dispatch vs continue, provider-error triage);
    leave it off for a cheap, auditable, mechanical resume.

.PARAMETER WithWatchdog
    Register a noninteractive health check and an interactive Windows alert
    task. The health check runs independently of Paseo every five minutes.

.EXAMPLE
    # see what is registered today (no elevation needed)
    .\Fix-PaseoBootTask.ps1 -Verify

.EXAMPLE
    # apply the repair (elevated)
    .\Fix-PaseoBootTask.ps1

.EXAMPLE
    # exercise the repaired path before the next reboot (elevated, daemon stopped)
    .\Fix-PaseoBootTask.ps1 -RunNow
#>
[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Verify')][switch]$Verify,
    [Parameter(ParameterSetName = 'RunNow')][switch]$RunNow,
    [switch]$WithResumeTask,
    [switch]$WithWatchdog,
    [switch]$DispatchAgent,
    [string]$AgentModel = 'opencode-go/deepseek-v4.1-flash',
    [int]$ResumeDelayMinutes = 2,
    [string]$TaskName = 'Paseo Daemon',
    [string]$ResumeTaskName = 'Paseo Boot Resume',
    [string]$PaseoHome = (Join-Path $env:USERPROFILE '.paseo'),
    [string]$PaseoExe = 'C:\Program Files\Paseo\resources\bin\paseo.cmd'
)

$ErrorActionPreference = 'Stop'
$PaseoHome = [IO.Path]::GetFullPath($PaseoHome)
$pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
. (Join-Path $PSScriptRoot '..\..\..\..\vendor\interactive-qa\vendor\credential-rescue\scripts\lib\PaseoCutover.ps1')
# Every action below launches through the fleet's hidden task launcher: a bare
# pwsh.exe action allocates a console on the operator's desktop before PowerShell
# can hide it (measured ~8 pop-ups an hour from three Interactive-logon tasks,
# bead cl-common-xr7r).
Import-Module (Join-Path $PSScriptRoot '..\..\..\..\scripts\windows\HiddenTask.psm1') -Force

function Get-BootLogPath { Join-Path $PaseoHome 'daemon-boot.log' }

function New-PaseoPowerShellAction {
    param([string]$Script, [string]$Arguments)
    New-HiddenTaskAction -Command ('"{0}" -NoProfile -NonInteractive -File "{1}" {2}' -f $pwsh, (Join-Path $PSScriptRoot $Script), $Arguments) `
        -WorkingDirectory $env:USERPROFILE
}

# The boot task runs a STAGED copy of the launcher on C:, never the repo copy on
# E:. On 2026-11-12 the task exited 0x1 at boot with no log (cl-common-9m9y); a
# boot path that reads the repo drive cannot be told apart from one that failed
# for another reason. The launcher is self-contained, so the copy is enough.
$BootStageDir = Join-Path $env:USERPROFILE '.machine\bin\paseo-boot'
function Get-StagedLauncherPath { Join-Path $BootStageDir 'Start-PaseoBootDaemon.ps1' }

function Copy-BootLauncher {
    New-Item -ItemType Directory -Force -Path $BootStageDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Start-PaseoBootDaemon.ps1') -Destination (Get-StagedLauncherPath) -Force
}

function Get-StagedLauncherState {
    $staged = Get-StagedLauncherPath
    if (-not (Test-Path -LiteralPath $staged)) { return 'absent' }
    $a = (Get-FileHash -LiteralPath $staged).Hash
    $b = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'Start-PaseoBootDaemon.ps1')).Hash
    if ($a -eq $b) { 'current' } else { 'STALE (re-run the elevated apply)' }
}

function Get-ExpectedAction {
    New-HiddenTaskAction -Command ('"{0}" -NoProfile -NonInteractive -File "{1}" -PaseoHome "{2}" -PaseoExe "{3}"' -f $pwsh, (Get-StagedLauncherPath), $PaseoHome, $PaseoExe) `
        -WorkingDirectory $env:USERPROFILE
}

function New-PaseoTaskSettings {
    param([int]$ExecutionLimitMinutes, [switch]$RestartOnFailure)
    $retry = @{}
    if ($RestartOnFailure) {
        $retry = @{ RestartCount = 3; RestartInterval = (New-TimeSpan -Minutes 1) }
    }
    New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes $ExecutionLimitMinutes) @retry
}

function Get-ResumeTaskAction {
    New-PaseoPowerShellAction 'Invoke-PaseoWatchdog.ps1' (
        '-PaseoHome "{0}" -PaseoExe "{1}" -TaskName "{2}" -ResumeAtBoot' -f $PaseoHome, $PaseoExe, $TaskName)
}

function Get-ResumeTaskPrincipal {
    New-ScheduledTaskPrincipal -UserId (Get-ScheduledTask -TaskName $TaskName -TaskPath '\').Principal.UserId -LogonType S4U -RunLevel Limited
}

function Grant-PaseoTaskRunAccess {
    param([string]$Name, [string]$UserId)
    $sid = ([Security.Principal.NTAccount]::new($UserId)).Translate([Security.Principal.SecurityIdentifier])
    $service = New-Object -ComObject Schedule.Service
    $service.Connect()
    $registeredTask = $service.GetFolder('\').GetTask($Name)
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($registeredTask.GetSecurityDescriptor(4))
    $readAndExecute = 0x1200a9
    $hasAccess = $descriptor.DiscretionaryAcl | Where-Object {
        $_.AceQualifier -eq 'AccessAllowed' -and $_.SecurityIdentifier -eq $sid -and
        ($_.AccessMask -band $readAndExecute) -eq $readAndExecute
    }
    if (-not $hasAccess) {
        $ace = [Security.AccessControl.CommonAce]::new('None', 'AccessAllowed', $readAndExecute, $sid, $false, $null)
        $descriptor.DiscretionaryAcl.InsertAce(0, $ace)
        $registeredTask.SetSecurityDescriptor($descriptor.GetSddlForm('Access'), 0x10)
    }
}

function Register-PaseoWatchdog {
    if (-not [Diagnostics.EventLog]::SourceExists('Paseo Watchdog')) {
        [Diagnostics.EventLog]::CreateEventSource('Paseo Watchdog', 'Application')
    }
    $principal = Get-ResumeTaskPrincipal
    $startup = New-ScheduledTaskTrigger -AtStartup
    $startup.Delay = 'PT3M'
    $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $settings = New-PaseoTaskSettings -ExecutionLimitMinutes 2
    $action = New-PaseoPowerShellAction 'Invoke-PaseoWatchdog.ps1' (
        '-PaseoHome "{0}" -PaseoExe "{1}" -TaskName "{2}"' -f $PaseoHome, $PaseoExe, $TaskName)
    Register-ScheduledTask -TaskName 'Paseo Key Check Watchdog' -Action $action -Trigger @($startup, $repeat) `
        -Principal $principal -Settings $settings -Description 'Checks Paseo and Key Check outside the desktop session.' -Force | Out-Null

    $atLogon = New-ScheduledTaskTrigger -AtLogOn -User $principal.UserId
    $interactive = New-ScheduledTaskPrincipal -UserId $principal.UserId -LogonType Interactive -RunLevel Limited
    $action = New-PaseoPowerShellAction 'Show-PaseoWatchdogAlert.ps1' ''
    Register-ScheduledTask -TaskName 'Paseo Key Check Alert' -Action $action -Trigger @($atLogon, $repeat) `
        -Principal $interactive -Settings $settings -Description 'Shows actionable Key Check incidents in the Windows session.' -Force | Out-Null
    Write-Host 'Registered the Paseo Key Check Watchdog and Paseo Key Check Alert.'
}

function Get-AgentResumeAction {
    $prompt = @'
Post-reboot resume. Read E:\repos\cl-common\Skills\auto-resume\SKILL.md and follow it.
Resume ONLY agents the reboot interrupted: those the daemon reports idle/closed
with no completion signal, or records in ~/.paseo/agents marked lastStatus=running
that `paseo ls --json` does not report as running. Never resume a finished agent.
Send exactly the word Continue (paseo send <id> Continue), at most 12 agents,
at least 20 seconds apart. Do not start new work, do not edit code, do not merge.
Append what you resumed to ~/.paseo/resume-boot.log and stop.
'@
    New-HiddenTaskAction -Command ('"{0}" /c ""{1}" run --no-wait --provider opencode --model "{2}" --title "Resume on Start" "{3}" 2>> "{4}""' -f `
            (Join-Path $env:SystemRoot 'System32\cmd.exe'), $PaseoExe, $AgentModel, ($prompt -replace '"', "'" -replace "`r?`n", ' '), (Join-Path $PaseoHome 'resume-boot.log')) `
        -WorkingDirectory (Split-Path $PaseoHome -Parent)
}

function Test-DaemonAnswers {
    try {
        $status = Invoke-PaseoCutoverCommand $PaseoExe @('daemon', 'status', '--home', $PaseoHome, '--json') 'Paseo task readiness' 10 |
            ConvertFrom-Json
        return ($status.localDaemon -eq 'running' -and $status.connectedDaemon -eq 'reachable')
    } catch {
        return $false
    }
}

function Show-State {
    $task = Get-ScheduledTask -TaskName $TaskName
    $info = Get-ScheduledTaskInfo -TaskName $TaskName

    Write-Host "task        : $TaskName  state=$($task.State)"
    Write-Host "principal   : $($task.Principal.UserId) logon=$($task.Principal.LogonType) runLevel=$($task.Principal.RunLevel)"
    Write-Host "triggers    : $((($task.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ', '))"
    Write-Host "execute     : $($task.Actions[0].Execute)"
    Write-Host "arguments   : $($task.Actions[0].Arguments)"
    Write-Host "multiple    : $($task.Settings.MultipleInstances)  restart=$($task.Settings.RestartCount)x$($task.Settings.RestartInterval)"
    Write-Host "lastRun     : $($info.LastRunTime)  lastResult=$($info.LastTaskResult)  missed=$($info.NumberOfMissedRuns)"

    $opLog = [string](wevtutil gl Microsoft-Windows-TaskScheduler/Operational 2>$null | Select-String 'enabled')
    Write-Host "task op log : $opLog"
    Write-Host "daemon up   : $(Test-DaemonAnswers)"
    Write-Host "launcher    : $(Get-StagedLauncherPath) [$(Get-StagedLauncherState)]"
    $bootErr = Join-Path $PaseoHome 'daemon-boot-error.log'
    if (Test-Path $bootErr) { Write-Host 'boot errors :'; Get-Content $bootErr -Tail 5 | ForEach-Object { "  $_" } }

    $bootLog = Get-BootLogPath
    if (Test-Path $bootLog) {
        Write-Host "boot log    : $bootLog"
    } else {
        Write-Host "boot log    : (absent) $bootLog"
    }

    $resumeTask = Get-ScheduledTask -TaskName $ResumeTaskName -ErrorAction SilentlyContinue
    if ($resumeTask) {
        $resumeInfo = Get-ScheduledTaskInfo -TaskName $ResumeTaskName
        Write-Host "resume task : $ResumeTaskName  state=$($resumeTask.State) delay=$($resumeTask.Triggers[0].Delay)"
        Write-Host "resume cmd  : $($resumeTask.Actions[0].Execute) $($resumeTask.Actions[0].Arguments)"
        Write-Host "resume last : $($resumeInfo.LastRunTime)  lastResult=$($resumeInfo.LastTaskResult)"
        $resumeLog = Join-Path $PaseoHome 'resume-boot.log'
        if (Test-Path $resumeLog) { Get-Content $resumeLog -Tail 10 | ForEach-Object { "  $_" } }
    } else {
        Write-Host "resume task : (not registered) $ResumeTaskName"
    }
}

switch ($PSCmdlet.ParameterSetName) {
    'Verify' {
        Show-State
        return
    }
    'RunNow' {
        if (Test-DaemonAnswers) {
            throw 'A daemon already answers on the configured endpoint. Stop it first (paseo daemon stop) so the boot path is what gets exercised.'
        }
        Show-State
        Write-Host '--- starting task ---'
        Start-ScheduledTask -TaskName $TaskName
        for ($i = 1; $i -le 40; $i++) {
            Start-Sleep -Seconds 3
            if (Test-DaemonAnswers) { Write-Host "daemon answered after $($i*3)s"; break }
        }
        Write-Host '--- after ---'
        Show-State
        if (-not (Test-DaemonAnswers)) { throw 'Daemon did not come up; read the boot log above and the task operational log.' }
        return
    }
}

# --- Apply ---------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Registration needs an elevated session (the task grants the operator account read-only).' }
if (-not (Test-Path $PaseoExe)) { throw "Paseo CLI not found: $PaseoExe" }
if (-not (Test-Path -LiteralPath $pwsh)) { throw "PowerShell 7 is required at $pwsh." }

Write-Host '--- before ---'
Show-State

Copy-BootLauncher
Write-Host "staged      : $(Get-StagedLauncherPath)"
Set-ScheduledTask -TaskName $TaskName -Action (Get-ExpectedAction) `
    -Settings (New-PaseoTaskSettings -ExecutionLimitMinutes 0 -RestartOnFailure) | Out-Null
Grant-PaseoTaskRunAccess -Name $TaskName -UserId (Get-ResumeTaskPrincipal).UserId
wevtutil sl Microsoft-Windows-TaskScheduler/Operational /e:true

if ($WithResumeTask) {
    $resumeTrigger = New-ScheduledTaskTrigger -AtStartup
    $resumeTrigger.Delay = "PT${ResumeDelayMinutes}M"
    $resumeAction = if ($DispatchAgent) { Get-AgentResumeAction } else { Get-ResumeTaskAction }
    Register-ScheduledTask -TaskName $ResumeTaskName `
        -Action $resumeAction `
        -Trigger $resumeTrigger `
        -Principal (Get-ResumeTaskPrincipal) `
        -Settings (New-PaseoTaskSettings -ExecutionLimitMinutes 16) `
        -Description "Resumes the Paseo agents a reboot interrupted, $ResumeDelayMinutes minutes after boot (S4U, no stored password)." `
        -Force | Out-Null
    Write-Host ("registered  : {0} (boot + {1}m, {2})" -f $ResumeTaskName, $ResumeDelayMinutes, $(if ($DispatchAgent) { 'dispatches auto-resume agent' } else { 'deterministic script' }))
}

if ($WithWatchdog) { Register-PaseoWatchdog }

Write-Host '--- after ---'
Show-State

$registered = (Get-ScheduledTask -TaskName $TaskName).Actions[0].Arguments
if ($registered -notmatch [regex]::Escape((Get-StagedLauncherPath))) { throw "Unexpected action after repair (expected the staged C: launcher): $registered" }
Write-Host 'Repair applied. Prove it at the next reboot, or run with -RunNow while no daemon is up.'
