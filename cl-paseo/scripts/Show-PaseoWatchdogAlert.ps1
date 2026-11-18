#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$StateDir = (Join-Path $env:USERPROFILE '.machine\state\key-check')
)

$ErrorActionPreference = 'Stop'
$statusPath = Join-Path $StateDir 'paseo-watchdog.json'
$shownPath = Join-Path $StateDir 'paseo-watchdog-alerted.txt'
if (-not (Test-Path -LiteralPath $statusPath)) { return }
$status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
$stale = ([DateTimeOffset]::UtcNow - [DateTimeOffset]$status.checkedAt).TotalMinutes -ge 15
if (-not $status.alert -and -not $stale) { return }
$incident = if ($stale) { 'watchdog-heartbeat-missing' } else { [string]$status.code }
$signature = "$incident/$($status.since)"
if ((Test-Path -LiteralPath $shownPath) -and (Get-Content -LiteralPath $shownPath -Raw).Trim() -eq $signature) { return }

$message = switch ($incident) {
    'reboot-required' { 'A stuck Paseo process still holds its listen socket after shutdown recovery. Save your work and restart Windows. Key Check saved the cutover for recovery after startup.' }
    'watchdog-heartbeat-missing' { 'The Windows watchdog has missed its checks for at least 15 minutes. Verify the Paseo Key Check Watchdog task in Task Scheduler.' }
    'opencode-storage-low' { 'The OpenCode database volume has less than 2 GiB free. Free disk space before the next cutover.' }
    'opencode-storage-unavailable' { 'The OpenCode database volume is unavailable or has less than 500 MiB free. Restore the volume or free space to allow key cutover.' }
    'no-eligible-replacement' { 'Key Check could not find a replacement that passed its checks. Add or replenish an OpenCode Go key before the active key runs out.' }
    default { "Paseo Key Check needs attention ($incident). Review the watchdog status in $statusPath." }
}

$session = [Diagnostics.Process]::GetCurrentProcess().SessionId
& "$env:SystemRoot\System32\msg.exe" $session /TIME:120 $message
if ($LASTEXITCODE -eq 0) { Set-Content -LiteralPath $shownPath -Value $signature -Encoding utf8NoBOM }
exit $LASTEXITCODE
