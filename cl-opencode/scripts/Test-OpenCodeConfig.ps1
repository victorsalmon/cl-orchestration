#Requires -Version 7.0
<#
.SYNOPSIS
    Answer "did my opencode.jsonc edit actually apply?" in one read-only command.

.DESCRIPTION
    The executable readback of the cl-opencode config rule. Registered as the
    `opencode-config` row of
    Skills/windows-shell/scripts/runbooks.registry.json and dispatched through
    `runbooks.ps1 run opencode-config`, so the prose in
    vendor/cl-orchestration/cl-opencode/SKILL.md points at this file instead of restating the
    commands.

    An edit to opencode.jsonc proves nothing: a value can parse as JSONC, match
    the published docs, and still be skipped by the loader at load time
    (measured on v2.1.2: compaction.buffer "40%" was skipped as kind=invalid
    while the number 400000 was accepted, and compaction.prune was reported
    unsupported). Only the loader's own normalization diagnostic is evidence.

    THREE THINGS THIS PRINTS, which together answer the question:

      1. every `configuration normalization diagnostic` in the log window, as
         path / kind / action with a count and the newest timestamp;
      2. the canary proof - a field that always warns (compaction.prune here) -
         its newest timestamp compared with the config file's last write, which
         is what proves the loader re-read the file at all. No canary after the
         edit means "written, pending readback", never "set";
      3. the effective compaction summary from the config as it now stands, with
         each path marked accepted / rejected / inert.

    Two verdicts matter: `kind=invalid` means NOT applied (the docs do not
    outvote the loader); `kind=unsupported` means dropped and inert (harmless,
    but do not rely on it).

    READ-ONLY: nothing here writes. The risk class is `read-only`, so the
    dispatcher runs it without a confirmation token.

    EXIT CODES
      0  the readback is proven: the canary post-dates the config, and no path
         in the current config carries an `invalid` rejection
      1  measured problem: a field in the current config is rejected
         (kind=invalid), or the loader has not re-read the file since the edit
      3  cannot evaluate: the log, the config or the canary is missing or
         unreadable (RT-E- code names it)

.EXAMPLE
    pwsh -NoProfile -File vendor/cl-orchestration/cl-opencode/scripts/Test-OpenCodeConfig.ps1

.EXAMPLE
    pwsh -NoProfile -File Skills/windows-shell/scripts/runbooks.ps1 run opencode-config

.EXAMPLE
    pwsh -NoProfile -File vendor/cl-orchestration/cl-opencode/scripts/Test-OpenCodeConfig.ps1 -Json

.NOTES
    Codes this script can fail with, all catalogued in
    Skills/windows-shell/scripts/runbooks.errors.json: RT-E-CONFIG-LOG-MISSING,
    RT-E-CONFIG-UNREADABLE, RT-E-CONFIG-CANARY-ABSENT,
    RT-E-CONFIG-CANARY-STALE. Look one up with `runbooks.ps1 codes <code>`.
#>
[CmdletBinding()]
param(
    [string]$LogPath = 'D:\opencode-data\opencode\log\opencode.log',
    [string]$ConfigPath = 'D:\Apps\opencode\config\opencode\opencode.jsonc',
    [ValidateRange(50, 1000000)][int]$TailLines = 3000,
    [string]$CanaryPath = '$.compaction.prune',
    [switch]$Preflight,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CataloguePath = (Get-Item -LiteralPath (Join-Path $PSScriptRoot '../../../../Skills/windows-shell/scripts/runbooks.errors.json')).FullName
$script:Checks = [System.Collections.Generic.List[object]]::new()

function Get-CatalogueEntry {
    <#
    .SYNOPSIS
        One RT-E- entry from the shared catalogue, or $null.
    #>
    param([Parameter(Mandatory)][string]$Code)

    if (-not (Test-Path -LiteralPath $script:CataloguePath -PathType Leaf)) { return $null }
    try { $raw = Get-Content -LiteralPath $script:CataloguePath -Raw -Encoding utf8 | ConvertFrom-Json }
    catch { return $null }
    if (-not $raw.PSObject.Properties['errors']) { return $null }
    return (@($raw.errors) | Where-Object { [string]$_.code -eq $Code } | Select-Object -First 1)
}

function Stop-RunbookFailure {
    <#
    .SYNOPSIS
        Stop with an RT-E- code, printing the catalogue's symptom and fix.
    #>
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowEmptyCollection()][object[]]$Detail = @()
    )

    $entry = Get-CatalogueEntry -Code $Code
    $symptom = 'no catalogue entry for this code: add it to runbooks.errors.json'
    $fix = ('add {0} to Skills/windows-shell/scripts/runbooks.errors.json' -f $Code)
    if ($null -ne $entry) {
        $symptom = [string]$entry.symptom
        $fix = [string]$entry.fix
        if ($Detail.Count -gt 0 -and $symptom -match '\{0\}') { $symptom = ($symptom -f $Detail[0]) }
    }

    [Console]::Error.WriteLine(('{0}: {1}' -f $Code, $symptom))
    [Console]::Error.WriteLine(('fix: {0}' -f $fix))
    exit $ExitCode
}

function Add-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('pass', 'warn', 'refuse')][string]$Verdict,
        [string]$Detail = '',
        [string]$Fix = ''
    )
    $script:Checks.Add([pscustomobject]@{ name = $Name; verdict = $Verdict; detail = $Detail; fix = $Fix })
}

function ConvertFrom-Jsonc {
    <#
    .SYNOPSIS
        Parse JSONC: strip // and /* */ comments, nothing inside a string.
    .DESCRIPTION
        A naive line-based strip breaks this very config, whose `$schema` value
        is an https:// URL - the `//` there is data, not a comment. So the
        scanner tracks string state and backslash escapes.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $builder = [System.Text.StringBuilder]::new($Text.Length)
    $inString = $false
    $escaped = $false
    $index = 0
    while ($index -lt $Text.Length) {
        $char = $Text[$index]
        if ($inString) {
            $null = $builder.Append($char)
            if ($escaped) { $escaped = $false }
            elseif ($char -eq '\') { $escaped = $true }
            elseif ($char -eq '"') { $inString = $false }
            $index++
            continue
        }
        if ($char -eq '"') {
            $inString = $true
            $null = $builder.Append($char)
            $index++
            continue
        }
        if ($char -eq '/' -and ($index + 1) -lt $Text.Length) {
            $next = $Text[$index + 1]
            if ($next -eq '/') {
                while ($index -lt $Text.Length -and $Text[$index] -ne "`n") { $index++ }
                continue
            }
            if ($next -eq '*') {
                $index += 2
                while ($index -lt ($Text.Length - 1) -and -not ($Text[$index] -eq '*' -and $Text[$index + 1] -eq '/')) { $index++ }
                $index += 2
                continue
            }
        }
        $null = $builder.Append($char)
        $index++
    }

    return ($builder.ToString() | ConvertFrom-Json)
}

function Test-ConfigPath {
    <#
    .SYNOPSIS
        Does a `$.a.b[0].c` diagnostic path still exist in the parsed config?
    .DESCRIPTION
        A rejection for a path the operator has since removed is stale evidence,
        not a live defect: only a rejection whose path is still in the file says
        the value in the file is being ignored.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Data,
        [Parameter(Mandatory)][string]$JsonPath
    )

    if ([string]::IsNullOrWhiteSpace($JsonPath) -or -not $JsonPath.StartsWith('$')) { return $false }
    $relative = $JsonPath.Substring(1)
    if ([string]::IsNullOrWhiteSpace($relative)) { return $true }

    $current = $Data
    foreach ($segment in ($relative -split '\.' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if ($null -eq $current) { return $false }
        foreach ($part in [regex]::Matches($segment, '[^\[\]]+')) {
            $token = $part.Value
            $indexMatch = [regex]::Match($token, '^\[(\d+)\]$')
            if ($indexMatch.Success) {
                $position = [int]$indexMatch.Groups[1].Value
                $array = @($current)
                if ($position -ge $array.Count) { return $false }
                $current = $array[$position]
                continue
            }
            $properties = $current.PSObject.Properties
            if ($null -eq $properties -or -not $properties[$token]) { return $false }
            $current = $properties[$token].Value
        }
    }
    return ($null -ne $current)
}

function Get-DiagnosticLines {
    <#
    .SYNOPSIS
        Parse the loader's normalization diagnostics out of the log tail.
    #>
    param([Parameter(Mandatory)][string[]]$Lines)

    $diagnostics = @()
    foreach ($line in $Lines) {
        if ($line -notmatch 'configuration normalization diagnostic') { continue }
        $match = [regex]::Match($line, 'timestamp=(?<ts>\S+).*?path=(?<path>\S+)\s+kind=(?<kind>\S+)\s+action="(?<action>[^"]*)"')
        if (-not $match.Success) {
            $diagnostics += [pscustomobject]@{ path = '?'; kind = '?'; action = '?'; timestampUtc = $null }
            continue
        }
        $diagnostics += [pscustomobject]@{
            path         = $match.Groups['path'].Value
            kind         = $match.Groups['kind'].Value
            action       = $match.Groups['action'].Value
            timestampUtc = $match.Groups['ts'].Value
        }
    }
    return $diagnostics
}

function Get-CanaryLine {
    <#
    .SYNOPSIS
        The newest diagnostic for the canary path, which is the re-read proof.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Diagnostics, [Parameter(Mandatory)][string]$Path)

    return @($Diagnostics | Where-Object { $_.path -eq $Path -and -not [string]::IsNullOrWhiteSpace($_.timestampUtc) } |
            Sort-Object -Property timestampUtc | Select-Object -Last 1)
}

function Read-LogTail {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][int]$Tail)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return @(Get-Content -LiteralPath $Path -Tail $Tail -ErrorAction Stop) }
    catch { return $null }
}

function Read-Config {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $text = Get-Content -LiteralPath $Path -Raw -Encoding utf8 -ErrorAction Stop
        return ConvertFrom-Jsonc -Text $text
    } catch {
        return $null
    }
}

# ---- preflight -----------------------------------------------------------------------------

function Invoke-PreflightProbes {
    $tail = @(Read-LogTail -Path $LogPath -Tail $TailLines)
    if ($null -eq $tail -or $tail.Count -eq 0) {
        Add-Check -Name 'log-readable' -Verdict 'refuse' -Detail ("{0} is missing or empty" -f $LogPath) `
            -Fix 'pass -LogPath with the live OpenCode log (D:\opencode-data\opencode\log\opencode.log)'
        return
    }
    Add-Check -Name 'log-readable' -Verdict 'pass' -Detail ("read the last {0} line(s) of {1}" -f $tail.Count, $LogPath)

    $config = Read-Config -Path $ConfigPath
    if ($null -eq $config) {
        Add-Check -Name 'config-readable' -Verdict 'refuse' -Detail ("{0} is missing or is not parseable JSONC" -f $ConfigPath) `
            -Fix 'fix the JSONC syntax (comments and trailing structure) and re-run; an unparseable file is never loaded'
    } else {
        Add-Check -Name 'config-readable' -Verdict 'pass' -Detail ("{0} parses as JSONC" -f $ConfigPath)
    }

    $diagnostics = @(Get-DiagnosticLines -Lines $tail)
    $canary = @(Get-CanaryLine -Diagnostics $diagnostics -Path $CanaryPath)
    if ($canary.Count -eq 0) {
        Add-Check -Name 'canary-present' -Verdict 'refuse' -Detail ("no diagnostic for {0} in the last {1} line(s)" -f $CanaryPath, $TailLines) `
            -Fix ("raise -TailLines, or pass -CanaryPath with a field this build is known to warn about; without a canary, 'accepted' cannot be proven")
    } else {
        Add-Check -Name 'canary-present' -Verdict 'pass' -Detail ("{0} warns at {1} (kind={2})" -f $CanaryPath, $canary[0].timestampUtc, $canary[0].kind)

        $configItem = Get-Item -LiteralPath $ConfigPath -ErrorAction SilentlyContinue
        if ($null -eq $configItem) {
            Add-Check -Name 'canary-after-edit' -Verdict 'refuse' -Detail ("{0} has no last-write time to compare" -f $ConfigPath) `
                -Fix 'pass -ConfigPath with the file you edited'
        } else {
            $canaryTime = [datetimeoffset]::MinValue
            $parsed = [datetimeoffset]::TryParse([string]$canary[0].timestampUtc, [ref]$canaryTime)
            $edited = [datetimeoffset]::new($configItem.LastWriteTimeUtc, [TimeSpan]::Zero)
            if (-not $parsed) {
                Add-Check -Name 'canary-after-edit' -Verdict 'refuse' -Detail ("the canary timestamp '{0}' is not a time" -f $canary[0].timestampUtc) `
                    -Fix 'read the log line by hand; the timestamp format changed'
            } elseif ($canaryTime -lt $edited) {
                Add-Check -Name 'canary-after-edit' -Verdict 'refuse' `
                    -Detail ("the canary predates the edit ({0} < {1}); the loader has not re-read the file" -f $canaryTime.ToString('o'), $edited.ToString('o')) `
                    -Fix 'send one request through the live session (the loader re-reads per request); a restart to pick up a value is a deliberate operator act'
            } else {
                Add-Check -Name 'canary-after-edit' -Verdict 'pass' `
                    -Detail ("the canary post-dates the edit ({0} >= {1})" -f $canaryTime.ToString('o'), $edited.ToString('o'))
            }
        }
    }
}

function Write-PreflightReport {
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Checks)

    $refused = @($Checks | Where-Object { $_.verdict -eq 'refuse' })
    if ($Json) {
        $overall = if ($refused.Count -gt 0) { 'refuse' } else { 'pass' }
        [ordered]@{
            schemaVersion = 1
            runbook       = 'opencode-config'
            mode          = 'preflight'
            checks        = @($Checks | ForEach-Object {
                    [ordered]@{ name = $_.name; verdict = $_.verdict; detail = $_.detail; fix = $_.fix }
                })
            summary       = [ordered]@{
                pass    = @($Checks | Where-Object { $_.verdict -eq 'pass' }).Count
                warn    = @($Checks | Where-Object { $_.verdict -eq 'warn' }).Count
                refuse  = $refused.Count
                overall = $overall
            }
        } | ConvertTo-Json -Depth 6
    } else {
        foreach ($check in $Checks) {
            Write-Output ('[{0,-6}] {1} - {2}' -f $check.verdict, $check.name, $check.detail)
            if ($check.verdict -eq 'refuse' -and -not [string]::IsNullOrWhiteSpace($check.fix)) {
                Write-Output ('         fix: {0}' -f $check.fix)
            }
        }
        $tail = if ($refused.Count -gt 0) { ('preflight: {0} of {1} checks refused' -f $refused.Count, $Checks.Count) }
        else { ('preflight: {0} checks passed' -f $Checks.Count) }
        Write-Output $tail
    }

    if ($refused.Count -gt 0) { exit 3 }
    exit 0
}

# ---- readback ------------------------------------------------------------------------------

if ($Preflight) {
    Invoke-PreflightProbes
    Write-PreflightReport -Checks @($script:Checks)
}

$tail = @(Read-LogTail -Path $LogPath -Tail $TailLines)
if ($null -eq $tail -or $tail.Count -eq 0) {
    Stop-RunbookFailure -Code 'RT-E-CONFIG-LOG-MISSING' -ExitCode 3 -Detail $LogPath
}

$config = Read-Config -Path $ConfigPath
if ($null -eq $config) {
    Stop-RunbookFailure -Code 'RT-E-CONFIG-UNREADABLE' -ExitCode 3 -Detail $ConfigPath
}

$diagnostics = @(Get-DiagnosticLines -Lines $tail)
$canary = @(Get-CanaryLine -Diagnostics $diagnostics -Path $CanaryPath)
if ($canary.Count -eq 0) {
    Stop-RunbookFailure -Code 'RT-E-CONFIG-CANARY-ABSENT' -ExitCode 3 -Detail $CanaryPath
}

$configItem = Get-Item -LiteralPath $ConfigPath
$edited = [datetimeoffset]::new($configItem.LastWriteTimeUtc, [TimeSpan]::Zero)
$canaryTime = [datetimeoffset]::MinValue
$canaryStamped = [datetimeoffset]::TryParse([string]$canary[0].timestampUtc, [ref]$canaryTime)
$reReadProven = ($canaryStamped -and $canaryTime -ge $edited)

# One row per (path, kind, action), newest timestamp wins.
$grouped = @($diagnostics | Where-Object { $_.path -ne '?' } |
        Group-Object -Property { '{0}|{1}|{2}' -f $_.path, $_.kind, $_.action } |
        ForEach-Object {
            $newest = @($_.Group | Sort-Object -Property timestampUtc | Select-Object -Last 1)[0]
            [pscustomobject]@{
                path         = $newest.path
                kind         = $newest.kind
                action       = $newest.action
                count        = $_.Count
                newestUtc    = $newest.timestampUtc
                inConfig     = (Test-ConfigPath -Data $config -JsonPath $newest.path)
                isRejection  = ($newest.kind -eq 'invalid')
                isInert      = ($newest.kind -eq 'unsupported')
            }
        } | Sort-Object -Property path)

$problems = @()
foreach ($row in $grouped) {
    if ($row.isRejection -and $row.inConfig) {
        $problems += ('{0} is rejected: kind=invalid action="{1}" (the value in the file is ignored)' -f $row.path, $row.action)
    }
}
$pending = (-not $reReadProven)
$pendingReason = if ($canaryStamped) {
    ('the loader has not re-read {0} since it was edited ({1} < {2})' -f $ConfigPath, $canaryTime.ToString('o'), $edited.ToString('o'))
} else {
    ('the canary timestamp "{0}" is not a time, so a re-read cannot be proven' -f $canary[0].timestampUtc)
}

$verdict = 'accepted'
if ($pending) { $verdict = 'pending' }
if (@($problems | Where-Object { $_ -match 'is rejected' }).Count -gt 0) { $verdict = 'rejected' }

$compaction = $null
if ($config.PSObject.Properties['compaction']) { $compaction = $config.compaction }
$bufferValue = $null
$autoValue = $null
$pruneValue = $null
if ($null -ne $compaction) {
    if ($compaction.PSObject.Properties['buffer']) { $bufferValue = $compaction.buffer }
    if ($compaction.PSObject.Properties['auto']) { $autoValue = $compaction.auto }
    if ($compaction.PSObject.Properties['prune']) { $pruneValue = $compaction.prune }
}
$bufferKind = 'absent'
if ($null -ne $bufferValue) {
    $bufferKind = if ($bufferValue -is [string]) { 'string (a percentage string is rejected by v2.1.2: use a token number)' } else { 'token number' }
}

if (-not $Json) {
    Write-Output ('config:  {0} (last write {1})' -f $ConfigPath, $edited.ToString('o'))
    Write-Output ('log:     {0} (last {1} lines)' -f $LogPath, $tail.Count)
    Write-Output ''
    Write-Output '--- normalization diagnostics in the window ---'
    if ($grouped.Count -eq 0) {
        Write-Output '  (none)'
    }
    foreach ($row in $grouped) {
        $state = if ($row.isInert) { 'inert (dropped, not applied)' }
        elseif ($row.isRejection -and $row.inConfig) { 'REJECTED (not applied)' }
        elseif ($row.isRejection) { 'stale (path no longer in the file)' }
        else { $row.kind }
        Write-Output ('  {0,-28} kind={1,-12} action="{2}" x{3} newest={4} -> {5}' -f `
            $row.path, $row.kind, $row.action, $row.count, $row.newestUtc, $state)
    }
    Write-Output ''
    Write-Output '--- canary (proves the file was re-read) ---'
    Write-Output ('  {0} newest={1} x{2}' -f $CanaryPath, $canary[0].timestampUtc, @($diagnostics | Where-Object { $_.path -eq $CanaryPath }).Count)
    Write-Output ('  re-read after the edit: {0}' -f $(if ($reReadProven) { 'yes' } else { 'NO - written, pending readback' }))
    Write-Output ''
    Write-Output '--- effective compaction summary ---'
    Write-Output ('  auto={0} buffer={1} ({2})' -f $autoValue, $bufferValue, $bufferKind)
    Write-Output ('  prune={0} -> {1}' -f $pruneValue, $(if ($null -eq $pruneValue) { 'absent' } else { 'unsupported on v2.1.2 (omitted, inert)' }))
    Write-Output '  buffer is headroom, not the trigger: compaction starts at (model window - buffer), so a larger buffer compacts earlier.'
    Write-Output ''
    Write-Output ('verdict: {0}' -f $verdict)
    foreach ($problem in $problems) { Write-Output ('  - {0}' -f $problem) }
    if ($pending) { Write-Output ('  - {0}: written, pending readback' -f $pendingReason) }
}

if ($Json) {
    [ordered]@{
        schemaVersion     = 1
        runbook           = 'opencode-config'
        mode              = 'readback'
        verdict           = $verdict
        ok                = ($problems.Count -eq 0 -and -not $pending)
        reReadProven      = $reReadProven
        config            = [ordered]@{ path = $ConfigPath; lastWriteUtc = $edited.ToString('o') }
        canary            = [ordered]@{ path = $CanaryPath; newestUtc = $canary[0].timestampUtc; count = @($diagnostics | Where-Object { $_.path -eq $CanaryPath }).Count }
        diagnostics       = @($grouped | ForEach-Object {
                [ordered]@{
                    path = $_.path; kind = $_.kind; action = $_.action; count = $_.count
                    newestUtc = $_.newestUtc; inConfig = $_.inConfig
                }
            })
        compaction        = [ordered]@{ auto = $autoValue; buffer = $bufferValue; bufferKind = $bufferKind; prune = $pruneValue }
        problems          = @($problems)
    } | ConvertTo-Json -Depth 6
}

if ($pending) {
    Stop-RunbookFailure -Code 'RT-E-CONFIG-CANARY-STALE' -ExitCode 3 -Detail $pendingReason
}

if ($problems.Count -gt 0) { exit 1 }
exit 0
