#Requires -Version 7.0
<#
.SYNOPSIS
    Execute comprehensive, non-destructive health checks across all Paseo invariants.

.DESCRIPTION
    Runs the 9 modular health probes for Paseo and prints a structured, colored
    report or JSON payload. Maps every failure directly to its root cause and remedy.

.PARAMETER Json
    Emits raw JSON for automated consumption by agents, watchdog tasks, or CI.

.PARAMETER Detailed
    Shows full Reason and Remedy for every check, including PASS items.

.EXAMPLE
    pwsh -File Test-PaseoHealth.ps1

.EXAMPLE
    pwsh -File Test-PaseoHealth.ps1 -Json
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$Detailed
)

$libDir = Join-Path $PSScriptRoot 'lib'
$probeFile = Join-Path $libDir 'PaseoHealth.Probes.ps1'

if (-not (Test-Path -LiteralPath $probeFile)) {
    Write-Error "Required probe library missing: $probeFile"
    exit 2
}

. $probeFile

$probes = @(
    'Test-ProbeDaemonRunning',
    'Test-ProbeLockStale',
    'Test-ProbeServiceCollision',
    'Test-ProbeEnvRunAsNode',
    'Test-ProbeBootTaskArg',
    'Test-ProbeConfigSyntax',
    'Test-ProbePathTruncation',
    'Test-ProbeProviderBinaries',
    'Test-ProbeKeyProviderMatch'
)

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($fn in $probes) {
    try {
        $res = & $fn
        if ($res) { $results.Add($res) }
    } catch {
        $results.Add([PSCustomObject]@{
            Id = $fn
            Name = "Error running $fn"
            Status = "ERROR"
            Reason = "$_"
            Remedy = "Check probe script syntax"
        })
    }
}

if ($Json) {
    $results | ConvertTo-Json -Depth 5
    $exitCode = if ($results | Where-Object Status -in @('FAIL', 'ERROR')) { 1 } else { 0 }
    exit $exitCode
}

Write-Host ""
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "                       PASEO INSTALLATION HEALTH REPORT                         " -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host ""

$failCount = 0
$warnCount = 0
$passCount = 0

foreach ($r in $results) {
    $color = switch ($r.Status) {
        'PASS'  { 'Green' }
        'WARN'  { 'Yellow' }
        'FAIL'  { 'Red' }
        'ERROR' { 'Magenta' }
        default { 'White' }
    }

    if ($r.Status -eq 'PASS') { $passCount++ }
    elseif ($r.Status -eq 'WARN') { $warnCount++ }
    else { $failCount++ }

    $badge = "[{0}]" -f $r.Status.PadRight(5)
    Write-Host ("{0} {1,-24} : {2}" -f $badge, $r.Id, $r.Name) -ForegroundColor $color

    if ($r.Status -ne 'PASS' -or $Detailed) {
        Write-Host ("       Reason : {0}" -f $r.Reason) -ForegroundColor Gray
        if ($r.Remedy -and $r.Remedy -ne 'None required') {
            Write-Host ("       Remedy : {0}" -f $r.Remedy) -ForegroundColor Cyan
        }
    }
}

Write-Host ""
Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Gray
$summaryColor = if ($failCount -gt 0) { 'Red' } elseif ($warnCount -gt 0) { 'Yellow' } else { 'Green' }
Write-Host ("Summary: {0} PASS, {1} WARN, {2} FAIL" -f $passCount, $warnCount, $failCount) -ForegroundColor $summaryColor
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host ""

if ($failCount -gt 0) {
    Write-Host "Action required: Run the recommended Remedy commands above or execute:" -ForegroundColor Yellow
    Write-Host "   pwsh -File (Join-Path `$PSScriptRoot 'Repair-PaseoHealth.ps1')" -ForegroundColor White
    Write-Host ""
    exit 1
}

exit 0
