#Requires -Version 7.0
<#
.SYNOPSIS
    Pure helpers for the Update Check battery (Test-UpdateCheck.ps1).

.DESCRIPTION
    Everything here is deterministic and side-effect free so it can be unit
    tested without a live daemon or a real paseo binary:

      * ConvertFrom-PaseoHelpText      - parse `paseo --help` / `paseo <verb> --help`
      * Get-PaseoCommandSet            - the verbs a CLI actually advertises
      * Get-PaseoSubCommandSet         - the sub-verbs one verb advertises
      * Get-PaseoInvocationScan        - every literal `paseo <verb> ...` in a tree
      * Test-KeyBearingEnvName         - the shared-service env rule
      * Test-JsonRecordTree            - record files that an upgrade corrupted
      * New-UpdateCheckResult          - the result contract
      * Get-UpdateCheckExitCode        - FAIL beats WARN beats PASS
      * Format-UpdateCheckReport       - the console table

    No function here calls paseo or touches the network. The orchestration of
    live checks lives in ../Test-UpdateCheck.ps1.
#>


# Global options commander accepts on every subcommand. A flag that appears in
# a script next to any verb is legal if it is in this set.
$script:GlobalPaseoFlags = @(
    '--host', '--home', '--format', '--json', '--quiet', '--no-headers',
    '--no-color', '--version', '--help', '-o', '-q', '-v', '-h'
)

function ConvertFrom-PaseoHelpText {
    <#
    .SYNOPSIS
        Split a `--help` payload into its advertised commands and flags.
    .DESCRIPTION
        Commander prints commands as `  <name> [options]  <description>` inside a
        `Commands:` block and options as `  --flag <value>  <description>`.
        Anything outside those shapes (usage banners, argument help, prose) is
        ignored, so a version that adds a word to a description cannot create a
        phantom command.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $commands = [Collections.Generic.List[string]]::new()
    $flags = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    $inCommands = $false
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^Commands:\s*$') { $inCommands = $true; continue }
        if ($inCommands) {
            if ($line -match '^\S') { $inCommands = $false }
            else {
                $m = [regex]::Match($line, '^\s{2}([a-z][a-z0-9-]*)(?=\s|$)')
                if ($m.Success) { $commands.Add($m.Groups[1].Value) }
            }
        }
        foreach ($fm in [regex]::Matches($line, '(?:^|\s)(--?[a-zA-Z][a-zA-Z0-9-]*)')) {
            [void]$flags.Add($fm.Groups[1].Value)
        }
    }

    [pscustomobject]@{
        Commands = @($commands)
        Flags    = $flags
    }
}

function Get-PaseoCommandSet {
    <#
    .SYNOPSIS
        Every top-level verb the CLI advertises.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$TopLevelHelpText)
    $parsed = ConvertFrom-PaseoHelpText -Text $TopLevelHelpText
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($c in $parsed.Commands) { [void]$set.Add($c) }
    $set
}

function Get-PaseoSubCommandSet {
    <#
    .SYNOPSIS
        Every sub-verb one verb advertises (empty set when it is leaf-only).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$VerbHelpText)
    $parsed = ConvertFrom-PaseoHelpText -Text $VerbHelpText
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($c in $parsed.Commands) { [void]$set.Add($c) }
    if ($set.Contains('help')) { [void]$set.Remove('help') }
    $set
}

function Get-PaseoFlagSet {
    <#
    .SYNOPSIS
        The flag set a context accepts: its own advertised flags plus the global ones.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$HelpText,
        [switch]$IncludeGlobals
    )
    $parsed = ConvertFrom-PaseoHelpText -Text $HelpText
    $set = [Collections.Generic.HashSet[string]]::new($parsed.Flags, [StringComparer]::OrdinalIgnoreCase)
    if ($IncludeGlobals) { foreach ($g in $script:GlobalPaseoFlags) { [void]$set.Add($g) } }
    $set
}

function Test-KeyBearingEnvName {
    <#
    .SYNOPSIS
        True when an env var NAME carries a credential.
    .DESCRIPTION
        Paseo >= v0.15.3 refuses a custom credential in
        agents.providers.<id>.env while sharing an opencode service. Pin names
        such as XDG_STATE_HOME or GEMINI_CLI_TRUST_WORKSPACE are layout, not
        credentials, and must not be flagged.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    return ($Name -match '(?i)(^|_)(API_?KEY|KEY|TOKEN|SECRET|PASSWORD|PAT|CREDENTIALS?)$')
}

function Get-PaseoInvocationScan {
    <#
    .SYNOPSIS
        Find every literal `paseo <verb> [sub] ...` in a tree, with its flags.
    .DESCRIPTION
        Only literal invocations are visible to a text scan: a script that runs
        `& $paseoCli run ...` through a variable is covered by the live checks,
        not by this one.

        Each hit records whether it sits in a comment or a quoted string. A
        flag that no longer exists in code is a break; the same words inside a
        doc sentence are a stale claim worth reporting, not a failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [Parameter(Mandatory)][string[]]$Verb,
        [string[]]$PruneName = @('node_modules', '.git', '.worktrees', '.iqa', '.claude', 'dist', 'coverage', 'archive', '_archive', 'personas', '.next', 'build'),
        [string[]]$Extension = @('.ps1', '.mjs', '.js', '.sh', '.cmd', '.bat', '.md'),
        [int]$MaxFileBytes = 524288
    )

    $prune = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $PruneName) { [void]$prune.Add($p) }
    $exts = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $Extension) { [void]$exts.Add($e) }

    $verbs = @($Verb | Where-Object { $_ } | Sort-Object -Descending { $_.Length })
    if ($verbs.Count -eq 0) { return @() }
    $pattern = '(?<![\w.-])paseo\s+(' + (($verbs | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\b([^\r\n]*)'
    $rx = [regex]::new($pattern, 'Compiled, IgnoreCase')
    $flagRx = [regex]::new('(--[a-z][a-z0-9-]+)', 'Compiled')

    $hits = [Collections.Generic.List[object]]::new()

    foreach ($root in $Path) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $stack = [Collections.Generic.Stack[string]]::new()
        $stack.Push((Resolve-Path -LiteralPath $root).ProviderPath)
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            try {
                foreach ($file in [IO.Directory]::EnumerateFiles($dir)) {
                    if (-not $exts.Contains([IO.Path]::GetExtension($file))) { continue }
                    if ([IO.FileInfo]::new($file).Length -gt $MaxFileBytes) { continue }
                    $text = $null
                    try { $text = [IO.File]::ReadAllText($file) } catch { continue }
                    foreach ($m in $rx.Matches($text)) {
                        $lineStart = $text.LastIndexOf("`n", [Math]::Max(0, $m.Index - 1))
                        $lineStart = if ($lineStart -lt 0) { 0 } else { $lineStart + 1 }
                        $lineEnd = $text.IndexOf("`n", $m.Index)
                        if ($lineEnd -lt 0) { $lineEnd = $text.Length }
                        $line = $text.Substring($lineStart, $lineEnd - $lineStart)
                        $lineNo = ([regex]::Matches($text.Substring(0, $lineStart), "`n")).Count + 1
                        $prefix = $text.Substring($lineStart, $m.Index - $lineStart)

                        # Flags belong to THEIR invocation: stop at the next paseo
                        # call, at a markdown/table boundary, or at the line end.
                        $tail = $m.Groups[2].Value
                        foreach ($cut in @('(?<![\w.-])paseo\s+', '`', '\|')) {
                            $cm = [regex]::Match($tail, $cut)
                            if ($cm.Success -and $cm.Index -lt $tail.Length) { $tail = $tail.Substring(0, $cm.Index) }
                        }

                        $trimmed = $line.TrimStart()
                        $inLineComment = $trimmed.StartsWith('#') -or $trimmed.StartsWith('//') -or $trimmed.StartsWith('*') -or $trimmed.StartsWith('<!--')
                        $openBlock = $text.LastIndexOf('<#', $m.Index, [StringComparison]::Ordinal)
                        $closeBlock = $text.LastIndexOf('#>', $m.Index, [StringComparison]::Ordinal)
                        $inBlockComment = $openBlock -gt $closeBlock
                        # A here-string is a quoted fixture or a doc block: its
                        # contents are text, not a call the fleet makes.
                        $openHere = [Math]::Max($text.LastIndexOf("@'", $m.Index, [StringComparison]::Ordinal), $text.LastIndexOf('@"', $m.Index, [StringComparison]::Ordinal))
                        $closeHere = [Math]::Max($text.LastIndexOf("'@", $m.Index, [StringComparison]::Ordinal), $text.LastIndexOf('"@', $m.Index, [StringComparison]::Ordinal))
                        $inHereString = $openHere -gt $closeHere
                        $quotes = ([regex]::Matches($prefix, "['`"``$([char]0x2018)$([char]0x2019)$([char]0x201C)$([char]0x201D)]")).Count
                        $inString = ($quotes % 2) -eq 1

                        $flags = [Collections.Generic.List[string]]::new()
                        foreach ($fm in $flagRx.Matches($tail)) { $flags.Add($fm.Groups[1].Value) }

                        $hits.Add([pscustomobject]@{
                            File            = $file
                            Line            = $lineNo
                            Verb            = $m.Groups[1].Value.ToLowerInvariant()
                            Sub             = $null
                            Flags           = @($flags)
                            InCommentOrText = ($inLineComment -or $inBlockComment -or $inHereString -or $inString)
                            Text            = $line.Trim()
                        })
                    }
                }
                foreach ($sub in [IO.Directory]::EnumerateDirectories($dir)) {
                    if (-not $prune.Contains([IO.Path]::GetFileName($sub))) { $stack.Push($sub) }
                }
            }
            catch { continue }
        }
    }

    @($hits)
}

function Resolve-PaseoInvocationSubCommand {
    <#
    .SYNOPSIS
        Fill in the sub-verb of each hit when the verb advertises one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Invocation,
        [Parameter(Mandatory)][hashtable]$SubCommandMap
    )
    foreach ($inv in $Invocation) {
        $set = $SubCommandMap[$inv.Verb]
        if ($null -eq $set) { continue }
        $m = [regex]::Match($inv.Text, '(?<![\w.-])paseo\s+' + [regex]::Escape($inv.Verb) + '\s+([a-z][a-z0-9-]*)\b', 'IgnoreCase')
        if ($m.Success -and $set.Contains($m.Groups[1].Value)) { $inv.Sub = $m.Groups[1].Value.ToLowerInvariant() }
    }
    $Invocation
}

function Test-JsonRecordTree {
    <#
    .SYNOPSIS
        Count record files and list the ones that no longer parse as JSON.
    .DESCRIPTION
        An upgrade that migrates a record schema can leave Paseo's own files
        unreadable. This is cheap, read-only proof either way.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Filter = '*.json',
        [int]$MaxFileBytes = 8388608
    )
    $total = 0
    $failures = [Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $Path) {
        $files = Get-ChildItem -LiteralPath $Path -Filter $Filter -Recurse -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            if ($f.Length -gt $MaxFileBytes) { continue }
            $total++
            try { $null = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
            catch { $failures.Add([pscustomobject]@{ File = $f.FullName; Error = $_.Exception.Message }) }
        }
    }
    [pscustomobject]@{
        Path     = $Path
        Total    = $total
        Failures = @($failures)
    }
}

function New-UpdateCheckResult {
    <#
    .SYNOPSIS
        One row of the report. Status is PASS, WARN, FAIL or SKIP.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('PASS', 'WARN', 'FAIL', 'SKIP')][string]$Status,
        [string]$Detail = '',
        [string]$Remedy = '',
        [AllowEmptyCollection()][string[]]$Evidence = @()
    )
    [pscustomobject]@{
        Id       = $Id
        Name     = $Name
        Status   = $Status
        Detail   = $Detail
        Remedy   = $Remedy
        Evidence = @($Evidence)
    }
}

function Get-UpdateCheckExitCode {
    <#
    .SYNOPSIS
        FAIL always exits 1; -Strict also fails on WARN.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Result,
        [switch]$Strict
    )
    if (@($Result | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0) { return 1 }
    if ($Strict -and @($Result | Where-Object { $_.Status -eq 'WARN' }).Count -gt 0) { return 1 }
    return 0
}

function Format-UpdateCheckReport {
    <#
    .SYNOPSIS
        Render the verdict table, failures first, with remedy and evidence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Result,
        [string]$Title = 'Update Check',
        [switch]$Detailed
    )
    $order = @{ FAIL = 0; WARN = 1; SKIP = 2; PASS = 3 }
    $lines = [Collections.Generic.List[string]]::new()
    $passed = @($Result | Where-Object { $_.Status -eq 'PASS' }).Count
    $warned = @($Result | Where-Object { $_.Status -eq 'WARN' }).Count
    $failed = @($Result | Where-Object { $_.Status -eq 'FAIL' }).Count
    $skipped = @($Result | Where-Object { $_.Status -eq 'SKIP' }).Count

    $lines.Add('')
    $lines.Add("=== $Title ===")
    $lines.Add("PASS $passed   WARN $warned   FAIL $failed   SKIP $skipped")
    $lines.Add('')
    foreach ($r in ($Result | Sort-Object @{ Expression = { $order[$_.Status] } }, Id)) {
        $lines.Add(('[{0}] {1,-22} {2}' -f $r.Status, $r.Id, $r.Detail))
        if ($Detailed -or $r.Status -ne 'PASS') {
            if ($r.Remedy) { $lines.Add("        remedy: $($r.Remedy)") }
            foreach ($e in @($r.Evidence | Select-Object -First 8)) { $lines.Add("        - $e") }
            if (@($r.Evidence).Count -gt 8) { $lines.Add("        - (+$(@($r.Evidence).Count - 8) more)") }
        }
    }
    $lines.Add('')
    if ($failed -gt 0) { $lines.Add('VERDICT: the upgrade broke something - fix the FAIL rows before dispatching work.') }
    elseif ($warned -gt 0) { $lines.Add('VERDICT: nothing is broken; review the WARN rows (stale claims or drift).') }
    else { $lines.Add('VERDICT: this Paseo version is compatible with the fleet tooling measured here.') }
    $lines.Add('')
    ($lines -join [Environment]::NewLine)
}
