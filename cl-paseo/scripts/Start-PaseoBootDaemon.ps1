#Requires -Version 7.0
<#
.SYNOPSIS
    Boot-task launcher for the Paseo daemon (S4U, session 0).
.DESCRIPTION
    Self-contained on purpose: Fix-PaseoBootTask.ps1 stages a copy of this file
    under %USERPROFILE%\.machine\bin\paseo-boot\ and the boot task runs that
    copy, so the boot path never reads the repo drive (E:). On 2026-11-12 the
    task exited 0x1 at boot and left no log at all, so the cause could not be
    proven (cl-common-9m9y). Every failure now lands in daemon-boot-error.log
    under -PaseoHome (C:), including one thrown before the boot log is written.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PaseoHome,
    [Parameter(Mandatory)][string]$PaseoExe
)

$ErrorActionPreference = 'Stop'
$errorLog = Join-Path ([IO.Path]::GetFullPath($PaseoHome)) 'daemon-boot-error.log'

function Write-BootError([string]$Message) {
    try {
        $line = '{0} [s{1}] {2}' -f [DateTimeOffset]::Now.ToString('o'),
            [Diagnostics.Process]::GetCurrentProcess().SessionId, $Message
        Add-Content -LiteralPath $errorLog -Value $line -Encoding utf8NoBOM
    } catch { [Console]::Error.WriteLine($Message) }
}

try {
    $PaseoHome = [IO.Path]::GetFullPath($PaseoHome)
    if (-not (Test-Path -LiteralPath $PaseoHome)) { throw "PaseoHome not found: $PaseoHome" }
    if (-not (Test-Path -LiteralPath $PaseoExe)) { throw "Paseo CLI not found: $PaseoExe" }

    $log = Join-Path $PaseoHome 'daemon-boot.log'
    if (Test-Path -LiteralPath $log) {
        Move-Item -LiteralPath $log -Destination "$log.previous" -Force
    }

    foreach ($name in @('OPENCODE_GO_KEY', 'OPENCODE_API_KEY')) {
        # An existing task engine can predate the cutover's registry writes.
        [Environment]::SetEnvironmentVariable($name, [Environment]::GetEnvironmentVariable($name, 'User'), 'Process')
    }
    if (-not $env:OPENCODE_GO_KEY) { Write-BootError 'warning: OPENCODE_GO_KEY is empty at User scope in this session (profile hive not loaded?)' }

    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    "$([DateTimeOffset]::Now.ToString('o')) Starting Paseo in Windows session $sessionId (launcher $PSCommandPath)." |
        Set-Content -LiteralPath $log -Encoding utf8NoBOM

    # Keep the foreground launcher under the scheduled task so Task Scheduler
    # can observe its exit. Capture foreground diagnostics separately from Paseo's
    # usual daemon log.
    $start = [Diagnostics.ProcessStartInfo]::new($env:ComSpec)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.Environment['PASEO_BOOT_CLI'] = $PaseoExe
    $start.Environment['PASEO_BOOT_HOME'] = $PaseoHome
    $start.Environment['PASEO_BOOT_LOG'] = $log
    $start.Arguments = '/d /v:off /s /c ""%PASEO_BOOT_CLI%" daemon run --home "%PASEO_BOOT_HOME%" >nul 2>> "%PASEO_BOOT_LOG%""'
    $process = [Diagnostics.Process]::Start($start)
    try {
        $process.WaitForExit()
        $code = $process.ExitCode
    } finally {
        $process.Dispose()
    }
    if ($code -ne 0) { Write-BootError "paseo daemon run exited $code; see $log" }
    exit $code
} catch {
    Write-BootError ("launcher failed: {0}" -f $_.Exception.Message)
    exit 1
}
