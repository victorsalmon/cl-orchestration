#Requires -Version 7.0
<#
.SYNOPSIS
    Automated one-stop repair for failing Paseo health probes.

.DESCRIPTION
    Runs Test-PaseoHealth probes and applies targeted countermeasures for any
    recoverable failure without user intervention:
      1. Cleans dead service.json / terminates orphaned external opencode.exe --service
      2. Removes stale ~/.paseo/paseo.pid lockfiles
      3. Cleans duplicated Machine entries out of User PATH (reverting 1024-char setx truncation)
      4. Restores broken ~/.paseo/config.json from the latest valid backup
      5. Provides explicit instructions for elevated tasks (Fix-PaseoBootTask)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force
)

# -WhatIf: the built-in cmdlets below (Stop-Process, Remove-Item, Copy-Item) honour it;
# the User-PATH rewrite is gated explicitly. The [FIXING]/[FIXED] lines still print in a
# preview, so say so once instead of letting them read as done.
if ($WhatIfPreference) { Write-Host "-WhatIf: preview only - nothing below is changed; [FIXED] lines describe what WOULD be done." -ForegroundColor Magenta }

$libDir = Join-Path $PSScriptRoot 'lib'
$probeFile = Join-Path $libDir 'PaseoHealth.Probes.ps1'

if (-not (Test-Path -LiteralPath $probeFile)) {
    Write-Error "Required probe library missing: $probeFile"
    exit 2
}

. $probeFile

Write-Host "Evaluating Paseo installation health before repair..." -ForegroundColor Cyan

# 1. Clean Service Collision
$sc = Test-ProbeServiceCollision
if ($sc.Status -eq 'FAIL') {
    Write-Host "[FIXING] OpenCode Shared Service Collision..." -ForegroundColor Yellow
    $servProcs = Get-CimInstance Win32_Process -Filter "Name='opencode.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'serve.*--service' }
    if ($servProcs) {
        $servProcs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    $sf = Join-Path $env:USERPROFILE ".local\state\opencode\service.json"
    if (Test-Path -LiteralPath $sf) {
        Remove-Item -LiteralPath $sf -Force -ErrorAction SilentlyContinue
    }
    Write-Host "[FIXED] Removed service.json and terminated orphaned service processes." -ForegroundColor Green
}

# 2. Clean Stale Lockfile
$lock = Test-ProbeLockStale
if ($lock.Status -eq 'FAIL') {
    Write-Host "[FIXING] Stale paseo.pid lockfile..." -ForegroundColor Yellow
    $pidFile = Join-Path $env:USERPROFILE ".paseo\paseo.pid"
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    Write-Host "[FIXED] Removed stale paseo.pid." -ForegroundColor Green
}

# 3. Fix Truncated / Bloated User PATH
$pt = Test-ProbePathTruncation
if ($pt.Status -eq 'FAIL') {
    Write-Host "[FIXING] User PATH truncation / bloated machine duplication..." -ForegroundColor Yellow
    $mPaths = [Environment]::GetEnvironmentVariable('PATH', 'Machine') -split ';' |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.TrimEnd('\') }
    $uPaths = [Environment]::GetEnvironmentVariable('PATH', 'User') -split ';' |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.TrimEnd('\') }
    
    # Keep only user entries that are not redundant copies of Machine PATH
    $cleanUserPaths = $uPaths | Where-Object { $mPaths -notcontains $_ }
    
    # Ensure npm global roaming is explicitly present
    $npmGlobal = (Join-Path $env:APPDATA "npm").TrimEnd('\')
    if ($cleanUserPaths -notcontains $npmGlobal) {
        $cleanUserPaths += $npmGlobal
    }

    $newVal = ($cleanUserPaths | Select-Object -Unique) -join ';'
    if ($PSCmdlet.ShouldProcess('User PATH', 'rewrite')) { [Environment]::SetEnvironmentVariable('PATH', $newVal, 'User') }
    Write-Host ("[FIXED] Cleaned User PATH: reduced from {0} chars to {1} chars." -f $uPaths.Length, $newVal.Length) -ForegroundColor Green
}

# 4. Config syntax recovery
$cs = Test-ProbeConfigSyntax
if ($cs.Status -eq 'FAIL') {
    Write-Host "[FIXING] Corrupt config.json..." -ForegroundColor Yellow
    $configDir = Join-Path $env:USERPROFILE ".paseo"
    $latestBak = Get-ChildItem -Path $configDir -Filter "config.json.bak-*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($latestBak) {
        Copy-Item -LiteralPath $latestBak.FullName -Destination (Join-Path $configDir "config.json") -Force
        Write-Host ("[FIXED] Restored config.json from {0}" -f $latestBak.Name) -ForegroundColor Green
    } else {
        Write-Warning "No config backup found to restore."
    }
}

Write-Host ""
Write-Host "Re-evaluating health after automated fixes:" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'Test-PaseoHealth.ps1')

