#Requires -Version 7.0
<#
.SYNOPSIS
    Update Paseo - the runbook behind `Update Check`: prove a Paseo upgrade did not break the fleet's tooling.

.DESCRIPTION
    Run this after Paseo is upgraded (or after a restart that followed an
    upgrade). It answers one question with evidence: does this Paseo version
    still support everything the fleet's scripts, harnesses and stored records
    depend on?

    The battery is ordered cheapest-first and every check is read-only except
    the dispatch canary, which creates, inspects and archives one throwaway
    agent (skip it with -SkipCanary).

      01 VERSION        CLI, daemon and desktop app all report the same version
      02 DAEMON         daemon running, reachable, listening where config says
      03 CONFIG         config.json parses and keeps its expected shape
      04 ENV-RULE       no credential in agents.providers.*.env (shared service)
      05 RELOAD         `paseo reload` accepts the config without a restart
      06 CLI-SURFACE    every `paseo <verb>` the fleet invokes still exists
      07 CLI-FLAGS      every flag the fleet passes is still advertised
      08 PROVIDERS      every enabled provider reports available
      09 MODELS         every pinned model/profile id still resolves
      10 RECORDS        agent/schedule/project record files still parse
      11 DISPATCH       a canary agent is created, found and archived
      12 HEALTH         the 9 Test-PaseoHealth probes pass
      13 SCRIPT-PARSE   every fleet .ps1 still parses (AST, no execution)
      14 PESTER         the cl-paseo Pester suite passes
      15 HARNESS        skill pointers resolve across harnesses
      16 BOOT           the Paseo scheduled tasks exist and are not disabled
      17 MCP            MCP injection setting and server commands resolve

    Exit code 0 when nothing FAILs, 1 when a check FAILs (-Strict also fails on
    WARN). The run is recorded under
    ~\.machine\state\update-check\update-paseo\ so the next run can name the version
    transition.

.PARAMETER Json
    Emit the full result object instead of the console table.

.PARAMETER Detailed
    Show remedy and evidence for PASS rows too.

.PARAMETER Strict
    Treat WARN as failure (for unattended gates).

.PARAMETER SkipCanary
    Do not dispatch the canary agent. Use on a box where dispatch must not be
    exercised at all; the remaining checks still run.

.PARAMETER SkipTests
    Do not run the Pester suite (the slowest check).

.PARAMETER SkipSurface
    Do not run the static CLI surface scan (checks 06 and 07).

.PARAMETER PaseoCli
    Path to the paseo executable. Default: `paseo` on PATH.

.PARAMETER PaseoHome
    Paseo home. Default: ~\.paseo.

.PARAMETER ScanRoots
    Roots scanned for literal `paseo <verb>` invocations. Default: cl-common
    Skills/vendor/scripts, %USERPROFILE%\.machine, and every
    <repo>\scripts under $env:CL_REPOS_ROOT.

.PARAMETER StateRoot
    Where run records are written. Default: ~\.machine\state\update-check\update-paseo.

.PARAMETER CanaryProvider / CanaryModel
    The agent the dispatch canary launches. Default: opencode with
    opencode-go/deepseek-v4.1-flash.

.EXAMPLE
    pwsh -NoProfile -File Test-UpdatePaseo.ps1

.EXAMPLE
    pwsh -NoProfile -File Test-UpdatePaseo.ps1 -SkipCanary -Json
#>
[CmdletBinding()]
param(
    [string]$PaseoCli = 'paseo',
    [string]$PaseoHome = (Join-Path $env:USERPROFILE '.paseo'),
    [string[]]$ScanRoots = @(),
    [string]$StateRoot = (Join-Path $env:USERPROFILE '.machine\state\update-check\update-paseo'),
    [string]$CanaryProvider = 'opencode',
    [string]$CanaryModel = 'opencode-go/deepseek-v4.1-flash',
    [string[]]$ExpectedBootTasks = @('Paseo Daemon', 'Paseo Daemon Ensure'),
    [string]$PaseoPluginRoot = '',
    [string]$HarnessInstaller,
    [switch]$Json,
    [switch]$Detailed,
    [switch]$Strict,
    [switch]$SkipCanary,
    [switch]$SkipTests,
    [switch]$SkipSurface
)

$ErrorActionPreference = 'Stop'
$libPath = Join-Path $PSScriptRoot 'lib\UpdatePaseo.ps1'
if (-not (Test-Path -LiteralPath $libPath)) { throw "Required helper library missing: $libPath" }
. $libPath

if (-not $PaseoPluginRoot) {
    # This runbook lives inside the cl-paseo plugin: skills/update-paseo/scripts
    # -> the plugin root is three levels up. Fall back to the fleet checkout.
    $derived = Join-Path $PSScriptRoot '..\..\..'
    if (Test-Path -LiteralPath $derived) { $PaseoPluginRoot = (Resolve-Path -LiteralPath $derived).ProviderPath }
    elseif ($env:CL_REPOS_ROOT) { $PaseoPluginRoot = Join-Path $env:CL_REPOS_ROOT 'cl-common\vendor\cl-orchestration\cl-paseo' }
    else { throw 'cl-paseo plugin root not found; pass -PaseoPluginRoot explicitly.' }
}
if (-not (Test-Path -LiteralPath $PaseoPluginRoot)) { throw "cl-paseo plugin root not found: $PaseoPluginRoot" }
$pluginRoot = (Resolve-Path -LiteralPath $PaseoPluginRoot).ProviderPath
$results = [Collections.Generic.List[object]]::new()

function Add-Result {
    param([string]$Id, [string]$Name, [string]$Status, [string]$Detail, [string]$Remedy = '', [string[]]$Evidence = @())
    $results.Add((New-UpdateCheckResult -Id $Id -Name $Name -Status $Status -Detail $Detail -Remedy $Remedy -Evidence $Evidence))
}

function Join-Evidence {
    param($Items, [int]$Max = 8)
    @($Items | Select-Object -First $Max)
}

function Invoke-ChildProcess {
    <#
        Run a program with an exact argument list and a hard timeout.

        ArgumentList is used instead of a joined command line so a prompt with
        spaces (the canary) reaches the child as one argument. A `paseo` that
        resolves to a .cmd shim is executed through cmd.exe, which is how the
        fleet's PATH-installed CLI is reached.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 120
    )
    $resolved = Get-Command $FilePath -ErrorAction SilentlyContinue | Select-Object -First 1
    $exe = if ($resolved) { $resolved.Source } else { $FilePath }
    $argv = @($Arguments)

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    if ($exe -match '\.(cmd|bat)$') {
        $psi.FileName = $env:ComSpec
        $psi.ArgumentList.Add('/c')
        $psi.ArgumentList.Add($exe)
    }
    else {
        $psi.FileName = $exe
    }
    foreach ($a in $argv) { $psi.ArgumentList.Add([string]$a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill($true) } catch { }
        return [pscustomobject]@{ ExitCode = 124; StdOut = ''; StdErr = "timed out after ${TimeoutSeconds}s" }
    }
    [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $outTask.GetAwaiter().GetResult()
        StdErr   = $errTask.GetAwaiter().GetResult()
    }
}

function Invoke-PaseoCli {
    param([string[]]$Arguments, [int]$TimeoutSeconds = 120)
    Invoke-ChildProcess -FilePath $PaseoCli -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
}

function ConvertFrom-JsonLoose {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return ($Text | ConvertFrom-Json -Depth 40 -ErrorAction Stop) } catch { return $null }
}

function Get-FirstAgentId {
    param($Object)
    if ($null -eq $Object) { return $null }
    if ($Object -is [string]) {
        $inner = ConvertFrom-JsonLoose -Text $Object
        if ($null -ne $inner) { return (Get-FirstAgentId -Object $inner) }
        return $null
    }
    foreach ($name in 'id', 'agentId', 'agent_id') {
        if ($Object.PSObject.Properties.Name -contains $name -and $Object.$name) { return [string]$Object.$name }
    }
    if ($Object -is [array] -and $Object.Count -gt 0) { return (Get-FirstAgentId -Object $Object[0]) }
    foreach ($name in 'agent', 'created', 'data', 'result') {
        if ($Object.PSObject.Properties.Name -contains $name -and $null -ne $Object.$name) {
            $found = Get-FirstAgentId -Object $Object.$name
            if ($found) { return $found }
        }
    }
    return $null
}

# ---------------------------------------------------------------- 01 VERSION
$version = $null
$statusJson = $null
try {
    $raw = (& $PaseoCli --version 2>&1 | Out-String).Trim()
    if ($raw -match '(\d+\.\d+\.\d+)') { $version = $Matches[1] }
    if (-not $version) { Add-Result 'VERSION' 'CLI version' 'FAIL' "could not parse a semantic version from: $raw" 'Verify the paseo binary: paseo --version' }
}
catch {
    Add-Result 'VERSION' 'CLI version' 'FAIL' "paseo --version failed: $($_.Exception.Message)" 'Repair the Paseo installation (Repair-PaseoHealth.ps1) before re-running.'
}

$status = Invoke-PaseoCli -Arguments @('status', '--json')
if ($status.ExitCode -eq 0) { $statusJson = ConvertFrom-JsonLoose -Text $status.StdOut }

$appVersion = $null
try {
    $exe = Join-Path $env:ProgramFiles 'Paseo\Paseo.exe'
    if (Test-Path -LiteralPath $exe) { $appVersion = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion }
}
catch { }

$daemonVersion = if ($statusJson -and $statusJson.PSObject.Properties.Name -contains 'daemonVersion') { $statusJson.daemonVersion } else { $null }
if ($version) {
    $skew = [Collections.Generic.List[string]]::new()
    if ($daemonVersion -and $daemonVersion -ne $version) { $skew.Add("cli=$version daemon=$daemonVersion") }
    if ($appVersion) {
        $appShort = ($appVersion -split '\.')[0..([Math]::Min(2, ($appVersion -split '\.').Count - 1))] -join '.'
        if ($appShort -ne $version) { $skew.Add("cli=$version app=$appVersion") }
    }
    if ($skew.Count -eq 0) {
        Add-Result 'VERSION' 'CLI/daemon/app version' 'PASS' "all report $version"
    }
    else {
        Add-Result 'VERSION' 'CLI/daemon/app version' 'FAIL' ('version skew: ' + ($skew -join '; ')) `
            'Restart the Paseo app so the CLI, daemon and desktop bundle come from one install, then re-run.'
    }
}

# ----------------------------------------------------------------- 02 DAEMON
if ($null -eq $statusJson) {
    Add-Result 'DAEMON' 'daemon status' 'FAIL' 'paseo status --json did not return JSON' 'Start Paseo (or Test-PaseoHealth.ps1 to classify why it is down).'
}
else {
    $problems = [Collections.Generic.List[string]]::new()
    if ($statusJson.PSObject.Properties.Name -contains 'localDaemon' -and $statusJson.localDaemon -notmatch 'running') { $problems.Add("localDaemon=$($statusJson.localDaemon)") }
    if ($statusJson.PSObject.Properties.Name -contains 'connectedDaemon' -and $statusJson.connectedDaemon -notmatch 'reachable') { $problems.Add("connectedDaemon=$($statusJson.connectedDaemon)") }
    if (-not $statusJson.PSObject.Properties.Name -contains 'pid') { $problems.Add('no pid reported') }
    $listen = if ($statusJson.PSObject.Properties.Name -contains 'listen') { $statusJson.listen } else { '' }
    if ($problems.Count -eq 0) {
        Add-Result 'DAEMON' 'daemon status' 'PASS' "pid $($statusJson.pid) on $listen, worker $($statusJson.workerPid)"
    }
    else {
        Add-Result 'DAEMON' 'daemon status' 'FAIL' ($problems -join '; ') 'Run the Paseo app, or Test-PaseoHealth.ps1 and Repair-PaseoHealth.ps1.'
    }
}

# ----------------------------------------------------------------- 03 CONFIG
$configPath = Join-Path $PaseoHome 'config.json'
$config = $null
if (-not (Test-Path -LiteralPath $configPath)) {
    Add-Result 'CONFIG' 'config.json schema' 'FAIL' "missing: $configPath" 'Restore a backup: ~\.paseo\config.json.bak-*.'
}
else {
    try { $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 50 -ErrorAction Stop }
    catch { Add-Result 'CONFIG' 'config.json schema' 'FAIL' "does not parse: $($_.Exception.Message)" 'Restore the newest ~\.paseo\config.json.bak-* and re-run.' }

    if ($null -ne $config) {
        $missing = [Collections.Generic.List[string]]::new()
        foreach ($key in 'version', 'daemon', 'agents') {
            if (-not ($config.PSObject.Properties.Name -contains $key)) { $missing.Add($key) }
        }
        $providers = if ($config.PSObject.Properties.Name -contains 'agents' -and $config.agents.PSObject.Properties.Name -contains 'providers') { $config.agents.providers } else { $null }
        if ($null -eq $providers) { $missing.Add('agents.providers') }
        if ($missing.Count -gt 0) {
            Add-Result 'CONFIG' 'config.json schema' 'FAIL' ('missing: ' + ($missing -join ', ')) 'Paseo now expects this shape; restore a backup or re-run `paseo onboard` and re-add providers.'
        }
        else {
            $enabled = @($providers.PSObject.Properties | Where-Object { $_.Value.PSObject.Properties.Name -contains 'enabled' -and $_.Value.enabled -eq $true } | ForEach-Object { $_.Name })
            Add-Result 'CONFIG' 'config.json schema' 'PASS' ("config version {0}; providers: {1}" -f $config.version, ($enabled -join ', '))
        }
    }
}

# ---------------------------------------------------------------- 04 ENV-RULE
if ($null -ne $config -and $config.PSObject.Properties.Name -contains 'agents') {
    $offenders = [Collections.Generic.List[string]]::new()
    $layoutPins = [Collections.Generic.List[string]]::new()
    foreach ($p in $config.agents.providers.PSObject.Properties) {
        if (-not ($p.Value.PSObject.Properties.Name -contains 'env') -or $null -eq $p.Value.env) { continue }
        foreach ($e in $p.Value.env.PSObject.Properties) {
            if (Test-KeyBearingEnvName -Name $e.Name) { $offenders.Add("$($p.Name).env.$($e.Name)") }
            else { $layoutPins.Add("$($p.Name).env.$($e.Name)") }
        }
    }
    if ($offenders.Count -gt 0) {
        # The shared-service rule is an opencode runtime rule: a credential under
        # agents.providers.opencode.env is a hard failure. A credential pinned on
        # another provider is drift worth reporting, not a proven break.
        $opencodeOffenders = @($offenders | Where-Object { $_ -like 'opencode.*' })
        $status = if ($opencodeOffenders.Count -gt 0) { 'FAIL' } else { 'WARN' }
        Add-Result 'ENV-RULE' 'no credential pinned in config' $status ('credential env in config: ' + ($offenders -join ', ')) `
            'Keep keys in User scope; Repair-Paseo.ps1 removes the opencode pin (required >= 0.15.3).' -Evidence $offenders
    }
    else {
        $detail = if ($layoutPins.Count -gt 0) { "no credentials pinned; layout pins: $($layoutPins -join ', ')" } else { 'no provider env block carries a credential' }
        Add-Result 'ENV-RULE' 'no credential pinned in config' 'PASS' $detail
    }
}

# ----------------------------------------------------------------- 05 RELOAD
$reload = Invoke-PaseoCli -Arguments @('reload')
if ($reload.ExitCode -eq 0) { Add-Result 'RELOAD' 'config accepted by daemon' 'PASS' 'paseo reload accepted the file' }
else { Add-Result 'RELOAD' 'config accepted by daemon' 'FAIL' "paseo reload exited $($reload.ExitCode): $(($reload.StdErr + $reload.StdOut).Trim())" 'The daemon rejects the config; fix it before restarting or agents will spawn without settings.' }

# ------------------------------------------------------------ 06/07 SURFACE
if ($SkipSurface) {
    Add-Result 'CLI-SURFACE' 'CLI verbs the fleet invokes' 'SKIP' 'skipped by -SkipSurface'
    Add-Result 'CLI-FLAGS' 'CLI flags the fleet passes' 'SKIP' 'skipped by -SkipSurface'
}
else {
    $topHelp = Invoke-PaseoCli -Arguments @('--help')
    $verbs = if ($topHelp.ExitCode -eq 0) { Get-PaseoCommandSet -TopLevelHelpText $topHelp.StdOut } else { $null }

    if ($null -eq $verbs -or $verbs.Count -eq 0) {
        Add-Result 'CLI-SURFACE' 'CLI verbs the fleet invokes' 'FAIL' 'paseo --help produced no command list' 'The CLI is not answering; repair the install before trusting any other row.'
    }
    else {
        $subMap = @{}
        $flagCache = @{}
        foreach ($v in $verbs) {
            $h = Invoke-PaseoCli -Arguments @($v, '--help')
            $subMap[$v] = if ($h.ExitCode -eq 0) { Get-PaseoSubCommandSet -VerbHelpText $h.StdOut } else { [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
            if ($h.ExitCode -eq 0) { $flagCache["$v|"] = Get-PaseoFlagSet -HelpText $h.StdOut -IncludeGlobals }
        }
        function Get-CtxFlagSet {
            param([string]$Verb, [string]$Sub)
            $key = "$Verb|$Sub"
            if ($flagCache.ContainsKey($key)) { return $flagCache[$key] }
            $args = if ($Sub) { @($Verb, $Sub) } else { @($Verb) }
            $h = Invoke-PaseoCli -Arguments ($args + '--help')
            $set = if ($h.ExitCode -eq 0) { Get-PaseoFlagSet -HelpText $h.StdOut -IncludeGlobals } else { $null }
            $flagCache[$key] = $set
            $set
        }

        if ($ScanRoots.Count -eq 0) {
            $roots = [Collections.Generic.List[string]]::new()
            foreach ($p in @(
                    (Join-Path $env:CL_REPOS_ROOT 'cl-common\Skills'),
                    (Join-Path $env:CL_REPOS_ROOT 'cl-common\vendor'),
                    (Join-Path $env:CL_REPOS_ROOT 'cl-common\scripts'),
                    (Join-Path $env:USERPROFILE '.machine'))) {
                if (Test-Path -LiteralPath $p) { $roots.Add($p) }
            }
            if ($env:CL_REPOS_ROOT -and (Test-Path -LiteralPath $env:CL_REPOS_ROOT)) {
                foreach ($d in Get-ChildItem -LiteralPath $env:CL_REPOS_ROOT -Directory -ErrorAction SilentlyContinue) {
                    if ($d.Name.StartsWith('.') -or $d.Name -eq 'cl-common') { continue }
                    $s = Join-Path $d.FullName 'scripts'
                    if (Test-Path -LiteralPath $s) { $roots.Add($s) }
                }
            }
            $ScanRoots = @($roots)
        }

        $invocations = Get-PaseoInvocationScan -Path $ScanRoots -Verb @($verbs)
        $invocations = @(Resolve-PaseoInvocationSubCommand -Invocation $invocations -SubCommandMap $subMap)

        $unknownCommands = [Collections.Generic.List[string]]::new()
        $missingFlags = [Collections.Generic.List[object]]::new()
        $checked = 0
        foreach ($inv in $invocations) {
            if (-not $verbs.Contains($inv.Verb)) {
                $unknownCommands.Add(("{0}:{1}: paseo {2}" -f $inv.File, $inv.Line, $inv.Verb))
                continue
            }
            $allowed = Get-CtxFlagSet -Verb $inv.Verb -Sub $inv.Sub
            if ($null -eq $allowed) { continue }
            $checked++
            foreach ($f in $inv.Flags) {
                if (-not $allowed.Contains($f)) {
                    $missingFlags.Add([pscustomobject]@{ Invocation = $inv; Flag = $f })
                }
            }
        }

        if ($unknownCommands.Count -eq 0) {
            Add-Result 'CLI-SURFACE' 'CLI verbs the fleet invokes' 'PASS' ("$checked literal invocations across $($ScanRoots.Count) roots; all verbs still advertised")
        }
        else {
            Add-Result 'CLI-SURFACE' 'CLI verbs the fleet invokes' 'FAIL' ("$($unknownCommands.Count) invocation(s) name a verb this CLI does not advertise") `
                'Either restore the verb or update the calling script; a script calling a removed verb fails at runtime.' -Evidence (Join-Evidence $unknownCommands)
        }

        # A flag absent from --help is either deprecated-but-accepted or removed.
        # Prove which, only with read-only verbs, then classify.
        $readOnlyVerbs = @('ls', 'status', 'inspect', 'logs', 'wait', 'provider', 'usage', 'host', 'plugin', 'permission')
        $removed = [Collections.Generic.List[string]]::new()
        $unadvertised = [Collections.Generic.List[string]]::new()
        foreach ($mf in $missingFlags) {
            $label = "{0}:{1}: paseo {2} {3} {4}" -f $mf.Invocation.File, $mf.Invocation.Line, $mf.Invocation.Verb, $mf.Invocation.Sub, $mf.Flag
            $proof = $null
            $isLeaf = ($null -ne $subMap[$mf.Invocation.Verb] -and $subMap[$mf.Invocation.Verb].Count -eq 0)
            if ($isLeaf -and $readOnlyVerbs -contains $mf.Invocation.Verb) {
                $probeArgs = @($mf.Invocation.Verb)
                if ($mf.Invocation.Sub) { $probeArgs += $mf.Invocation.Sub }
                $probeArgs += $mf.Flag
                $probe = Invoke-PaseoCli -Arguments $probeArgs -TimeoutSeconds 30
                $probeText = "$($probe.StdErr) $($probe.StdOut)"
                if ($probeText -match "unknown option") { $proof = 'removed' }
                elseif ($probe.ExitCode -ge 0) { $proof = 'accepted' }
            }
            if ($proof -eq 'removed') {
                # Proven removed: a live call errors at argument parsing.
                $removed.Add("$label [$proof]")
            }
            elseif ($mf.Invocation.InCommentOrText -eq $false) {
                # Real code, not advertised: confirm before trusting the call.
                $unadvertised.Add("$label [not advertised]")
            }
            # Documentation that mentions an unadvertised-but-accepted flag is
            # not a finding; only a proven removal is worth reporting above.
        }
        if ($removed.Count -gt 0) {
            Add-Result 'CLI-FLAGS' 'CLI flags the fleet passes' 'FAIL' ("$($removed.Count) flag use(s) this CLI no longer accepts") `
                'Update the script to the current flag (see `paseo <verb> --help`); a live call would error at argument parsing.' -Evidence (Join-Evidence $removed)
        }
        elseif ($unadvertised.Count -gt 0) {
            Add-Result 'CLI-FLAGS' 'CLI flags the fleet passes' 'WARN' ("$($unadvertised.Count) flag use(s) are not advertised by --help (docs or deprecated aliases)") `
                'Confirm each against `paseo <verb> --help` and rewrite the doc/script if the flag moved.' -Evidence (Join-Evidence $unadvertised)
        }
        else {
            Add-Result 'CLI-FLAGS' 'CLI flags the fleet passes' 'PASS' 'every flag used next to an advertised verb is still advertised'
        }
    }
}

# -------------------------------------------------------------- 08 PROVIDERS
$providerList = Invoke-PaseoCli -Arguments @('provider', 'ls', '--json')
$providersJson = if ($providerList.ExitCode -eq 0) { ConvertFrom-JsonLoose -Text $providerList.StdOut } else { $null }
if ($null -eq $providersJson) {
    Add-Result 'PROVIDERS' 'provider availability' 'FAIL' "paseo provider ls --json exited $($providerList.ExitCode)" 'Run `paseo provider diagnostic <id>` for the failing provider.'
}
else {
    $available = @{}
    foreach ($p in @($providersJson)) {
        if ($p.PSObject.Properties.Name -contains 'provider') { $available[$p.provider] = [string]$p.status }
    }
    $enabled = @()
    if ($null -ne $config -and $config.agents.PSObject.Properties.Name -contains 'providers') {
        $enabled = @($config.agents.providers.PSObject.Properties | Where-Object { $_.Value.PSObject.Properties.Name -contains 'enabled' -and $_.Value.enabled -eq $true } | ForEach-Object { $_.Name })
    }
    $bad = @($enabled | Where-Object { -not $available.ContainsKey($_) -or $available[$_] -notmatch 'available' })
    if ($bad.Count -eq 0) {
        Add-Result 'PROVIDERS' 'provider availability' 'PASS' ("enabled and available: " + ($enabled -join ', '))
    }
    else {
        Add-Result 'PROVIDERS' 'provider availability' 'FAIL' ("not available: " + ($bad -join ', ')) 'Run `paseo provider diagnostic <provider>`; this is the row that usually explains dead dispatches after an upgrade.'
    }
}

# ----------------------------------------------------------------- 09 MODELS
if ($null -ne $config -and $config.agents.PSObject.Properties.Name -contains 'providers') {
    $pinned = @{}
    foreach ($p in $config.agents.providers.PSObject.Properties) {
        if (-not ($p.Value.PSObject.Properties.Name -contains 'enabled') -or $p.Value.enabled -ne $true) { continue }
        $pinned[$p.Name] = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        if ($p.Value.PSObject.Properties.Name -contains 'additionalModels') {
            foreach ($m in @($p.Value.additionalModels)) {
                if ($m -and $m.PSObject.Properties.Name -contains 'id' -and $m.id) { [void]$pinned[$p.Name].Add([string]$m.id) }
            }
        }
    }
    if ($config.daemon.PSObject.Properties.Name -contains 'agentProfiles') {
        foreach ($prof in @($config.daemon.agentProfiles)) {
            if (-not $prof.provider -or -not $prof.model) { continue }
            if (-not $pinned.ContainsKey($prof.provider)) { $pinned[$prof.provider] = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
            $model = [string]$prof.model
            if ($model.StartsWith('[')) {
                try { $arr = $model | ConvertFrom-Json; if (@($arr).Count -ge 2) { $model = [string]$arr[1] } } catch { }
            }
            [void]$pinned[$prof.provider].Add($model)
        }
    }

    $unresolved = [Collections.Generic.List[string]]::new()
    $resolvedCount = 0
    foreach ($providerId in $pinned.Keys) {
        if ($pinned[$providerId].Count -eq 0) { continue }
        $ml = Invoke-PaseoCli -Arguments @('provider', 'models', $providerId, '--json') -TimeoutSeconds 180
        $models = if ($ml.ExitCode -eq 0) { ConvertFrom-JsonLoose -Text $ml.StdOut } else { $null }
        if ($null -eq $models) {
            $unresolved.Add("$providerId (model list failed: exit $($ml.ExitCode))")
            continue
        }
        # A provider's model id is sometimes a [provider, model] pair and
        # sometimes a plain string; accept either shape.
        # A provider's model id is sometimes a [provider, model] pair serialised
        # as a JSON string and sometimes a plain id; accept every shape.
        $ids = [Collections.Generic.List[string]]::new()
        foreach ($m in @($models)) {
            if (-not ($m.PSObject.Properties.Name -contains 'id') -or $null -eq $m.id) { continue }
            $raw = [string]$m.id
            if ($m.id -is [array]) { $raw = '[' + (($m.id | ForEach-Object { '"' + [string]$_ + '"' }) -join ',') + ']' }
            if ($raw.StartsWith('[')) {
                try {
                    $pair = $raw | ConvertFrom-Json -ErrorAction Stop
                    if (@($pair).Count -ge 2) {
                        $ids.Add((@($pair) | ForEach-Object { [string]$_ }) -join '/')
                        $ids.Add([string]@($pair)[-1])
                    }
                    continue
                }
                catch { }
            }
            $ids.Add($raw)
        }
        foreach ($want in $pinned[$providerId]) {
            if ($ids -contains $want) { $resolvedCount++ }
            else { $unresolved.Add("$providerId/$want") }
        }
    }
    if ($unresolved.Count -eq 0) {
        Add-Result 'MODELS' 'pinned models resolve' 'PASS' "$resolvedCount pinned model id(s) resolve on their provider"
    }
    else {
        Add-Result 'MODELS' 'pinned models resolve' 'FAIL' ("$($unresolved.Count) pinned model id(s) do not resolve") `
            'A profile or additionalModel names a model this provider no longer lists. `paseo provider models <id> --json` shows the current ids; update config.' -Evidence (Join-Evidence $unresolved)
    }
}

# ---------------------------------------------------------------- 10 RECORDS
$recordRoots = @(
    @{ Name = 'agents'; Path = (Join-Path $PaseoHome 'agents') },
    @{ Name = 'schedules'; Path = (Join-Path $PaseoHome 'schedules') },
    @{ Name = 'projects'; Path = (Join-Path $PaseoHome 'projects') }
)
$recordFailures = [Collections.Generic.List[string]]::new()
$recordTotal = 0
foreach ($r in $recordRoots) {
    $scan = Test-JsonRecordTree -Path $r.Path
    $recordTotal += $scan.Total
    foreach ($f in $scan.Failures) { $recordFailures.Add("$($r.Name)/$([IO.Path]::GetFileName($f.File)): $($f.Error)") }
}
$listCommands = @(
    @{ Id = 'ls'; Args = @('ls', '--json') },
    @{ Id = 'schedule ls'; Args = @('schedule', 'ls', '--json') },
    @{ Id = 'workspace ls'; Args = @('workspace', 'ls', '--json') },
    @{ Id = 'project ls'; Args = @('project', 'ls', '--json') }
)
$listFailures = [Collections.Generic.List[string]]::new()
foreach ($c in $listCommands) {
    $r = Invoke-PaseoCli -Arguments $c.Args
    if ($r.ExitCode -ne 0) { $listFailures.Add("paseo $($c.Id) exited $($r.ExitCode)") }
    elseif ($null -eq (ConvertFrom-JsonLoose -Text $r.StdOut)) { $listFailures.Add("paseo $($c.Id) did not return JSON") }
}
if ($recordFailures.Count -eq 0 -and $listFailures.Count -eq 0) {
    Add-Result 'RECORDS' 'stored records parse' 'PASS' "$recordTotal record file(s) parse; agent/schedule/workspace/project listings answer"
}
else {
    Add-Result 'RECORDS' 'stored records parse' 'FAIL' ("$($recordFailures.Count) record file(s) unreadable, $($listFailures.Count) listing(s) broken") `
        'An upgrade migrated the record shape. Do not delete records: back up ~\.paseo, then let Paseo migrate or restore from ~\.machine\backups.' -Evidence (Join-Evidence (@($recordFailures) + @($listFailures)))
}

# --------------------------------------------------------------- 11 DISPATCH
if ($SkipCanary) {
    Add-Result 'DISPATCH' 'canary dispatch' 'SKIP' 'skipped by -SkipCanary'
}
else {
    $canaryTitle = 'update-paseo canary'
    $canaryArgs = @('run', '--no-wait', '--json', '--title', $canaryTitle)
    if ($CanaryProvider) { $canaryArgs += @('--provider', $CanaryProvider) }
    if ($CanaryModel) { $canaryArgs += @('--model', $CanaryModel) }
    $canaryArgs += 'Reply with the single word OK and nothing else.'
    $created = Invoke-PaseoCli -Arguments $canaryArgs -TimeoutSeconds 180
    $agentId = $null
    if ($created.ExitCode -eq 0) { $agentId = Get-FirstAgentId -Object (ConvertFrom-JsonLoose -Text $created.StdOut) }
    if (-not $agentId) {
        Add-Result 'DISPATCH' 'canary dispatch' 'FAIL' "could not create a canary agent (exit $($created.ExitCode)): $(($created.StdErr + $created.StdOut).Trim())" `
            'Dispatch is broken on this build. `paseo provider diagnostic <id>` and Test-PaseoHealth.ps1 narrow it down before you dispatch real work.'
    }
    else {
        Start-Sleep -Seconds 2
        $ls = Invoke-PaseoCli -Arguments @('ls', '--json')
        $visible = $false
        $lsJson = ConvertFrom-JsonLoose -Text $ls.StdOut
        if ($null -ne $lsJson) { $visible = (@($lsJson | ForEach-Object { $_.id }) -contains $agentId) }
        $archived = Invoke-PaseoCli -Arguments @('archive', $agentId, '--force') -TimeoutSeconds 60
        if ($visible -and $archived.ExitCode -eq 0) {
            Add-Result 'DISPATCH' 'canary dispatch' 'PASS' "agent $agentId created, listed, archived"
        }
        elseif (-not $visible) {
            Add-Result 'DISPATCH' 'canary dispatch' 'WARN' ("agent {0} was created but not listed by 'paseo ls --json'" -f $agentId) 'Check that `paseo ls` and the app agree on the same daemon home.'
        }
        else {
            Add-Result 'DISPATCH' 'canary dispatch' 'WARN' "agent $agentId created and listed but archive exited $($archived.ExitCode)" 'Archive it by hand so the track does not accumulate canaries.'
        }
    }
}

# ----------------------------------------------------------------- 12 HEALTH
$healthScript = Join-Path $pluginRoot 'scripts\Test-PaseoHealth.ps1'
if (-not (Test-Path -LiteralPath $healthScript)) {
    Add-Result 'HEALTH' 'health probes' 'SKIP' "Test-PaseoHealth.ps1 not found at $healthScript"
}
else {
    $healthRun = Invoke-ChildProcess -FilePath 'pwsh' -Arguments @('-NoProfile', '-File', $healthScript, '-Json') -TimeoutSeconds 240
    $healthText = $healthRun.StdOut
    $jsonStart = $healthText.IndexOf('[')
    $healthJson = if ($jsonStart -ge 0) { ConvertFrom-JsonLoose -Text ($healthText.Substring($jsonStart)) } else { $null }
    $fails = @()
    if ($null -ne $healthJson) {
        $fails = @(@($healthJson) | Where-Object { $_.Status -eq 'FAIL' } | ForEach-Object { "$($_.Id): $($_.Reason)" })
    }
    if ($null -eq $healthJson) {
        Add-Result 'HEALTH' 'health probes' 'WARN' 'Test-PaseoHealth -Json did not return parseable JSON' 'Run Test-PaseoHealth.ps1 by hand and read the table.'
    }
    elseif ($fails.Count -eq 0) {
        $warnRows = @(@($healthJson) | Where-Object { $_.Status -eq 'WARN' } | ForEach-Object { "$($_.Id): $($_.Reason)" })
        if ($warnRows.Count -eq 0) {
            Add-Result 'HEALTH' 'health probes' 'PASS' 'all Test-PaseoHealth probes pass'
        }
        else {
            Add-Result 'HEALTH' 'health probes' 'WARN' ("$($warnRows.Count) probe(s) warn; none fail") 'A warning here is usually a probe that still encodes a pre-upgrade rule; confirm it against the current docs before silencing it.' -Evidence (Join-Evidence $warnRows)
        }
    }
    else {
        Add-Result 'HEALTH' 'health probes' 'FAIL' ("$($fails.Count) probe(s) failing") 'Repair-PaseoHealth.ps1 fixes the mechanical ones; read the probe remedy for the rest.' -Evidence (Join-Evidence $fails)
    }
}

# ----------------------------------------------------------- 13 SCRIPT-PARSE
$parseFailures = [Collections.Generic.List[string]]::new()
$parsed = 0
$parseRoots = @($pluginRoot, (Join-Path $env:CL_REPOS_ROOT 'cl-common\Skills'))
foreach ($root in $parseRoots) {
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
    foreach ($f in Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse -File -ErrorAction SilentlyContinue) {
        if ($f.FullName -match '[\\/](node_modules|\.worktrees|\.iqa|\.claude)[\\/]') { continue }
        $parsed++
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) { $parseFailures.Add("$($f.FullName): $($errors[0].Message)") }
    }
}
if ($parseFailures.Count -eq 0) { Add-Result 'SCRIPT-PARSE' 'fleet scripts parse' 'PASS' "$parsed .ps1 file(s) parse cleanly" }
else { Add-Result 'SCRIPT-PARSE' 'fleet scripts parse' 'FAIL' ("$($parseFailures.Count) file(s) no longer parse") 'A parse error is a hard break; fix it before the gate runs.' -Evidence (Join-Evidence $parseFailures) }

# ------------------------------------------------------------------ 14 PESTER
if ($SkipTests) {
    Add-Result 'PESTER' 'cl-paseo test suite' 'SKIP' 'skipped by -SkipTests'
}
else {
    $testPaths = @(
        (Join-Path $pluginRoot 'Tests')
    ) | Where-Object { Test-Path -LiteralPath $_ }
    if ($testPaths.Count -eq 0) {
        Add-Result 'PESTER' 'cl-paseo test suite' 'SKIP' "no Tests directory beside cl-paseo at $pluginRoot"
    }
    else {
        $quoted = ($testPaths | ForEach-Object { "'" + (Resolve-Path -LiteralPath $_).ProviderPath + "'" }) -join ','
        $testRun = Invoke-ChildProcess -FilePath 'pwsh' -TimeoutSeconds 1800 `
            -Arguments @('-NoProfile', '-Command', "Invoke-Pester -Path $quoted -CI -Output None")
        if ($testRun.ExitCode -eq 0) {
            Add-Result 'PESTER' 'cl-paseo test suite' 'PASS' 'cl-paseo Pester suite green'
        }
        else {
            Add-Result 'PESTER' 'cl-paseo test suite' 'FAIL' "Pester exited $($testRun.ExitCode)" 'Run Invoke-Pester on cl-paseo/Tests for the failing assertion; a fixture that mocked the old CLI shape shows up here.' -Evidence (Join-Evidence (($testRun.StdOut + "`n" + $testRun.StdErr) -split "`r?`n" | Where-Object { $_ -match '\[-\]|Failed|Expected' }))
        }
    }
}

# ----------------------------------------------------------------- 15 HARNESS
if (-not $HarnessInstaller) {
    $HarnessInstaller = Join-Path $env:CL_REPOS_ROOT 'cl-common\Skills\install-harness\Invoke-HarnessInstall.ps1'
}
if (-not (Test-Path -LiteralPath $HarnessInstaller)) {
    Add-Result 'HARNESS' 'skill pointers resolve' 'SKIP' "install-harness not found at $HarnessInstaller"
}
else {
    $verifyRun = Invoke-ChildProcess -FilePath 'pwsh' -Arguments @('-NoProfile', '-File', $HarnessInstaller, '-Verify') -TimeoutSeconds 600
    if ($verifyRun.ExitCode -eq 0) { Add-Result 'HARNESS' 'skill pointers resolve' 'PASS' 'every harness pointer resolves to its canonical skill' }
    else { Add-Result 'HARNESS' 'skill pointers resolve' 'WARN' "verify exited $($verifyRun.ExitCode)" 'Run Invoke-HarnessInstall.ps1 without -Verify to converge pointers, then re-run Update Check.' -Evidence (Join-Evidence (($verifyRun.StdOut + "`n" + $verifyRun.StdErr) -split "`r?`n" | Where-Object { $_ -match 'missing|stale|drift|unresolved' })) }
}

# -------------------------------------------------------------------- 16 BOOT
try {
    $tasks = Get-ScheduledTask -ErrorAction Stop
    $missingTasks = @($ExpectedBootTasks | Where-Object { $n = $_; -not ($tasks | Where-Object { $_.TaskName -eq $n }) })
    $disabledTasks = @($ExpectedBootTasks | Where-Object { $n = $_; $tasks | Where-Object { $_.TaskName -eq $n -and $_.State -eq 'Disabled' } })
    if ($missingTasks.Count -gt 0) {
        Add-Result 'BOOT' 'boot tasks registered' 'FAIL' ('missing: ' + ($missingTasks -join ', ')) 'pwsh -File Fix-PaseoBootTask.ps1 -WithResumeTask re-registers the boot path.'
    }
    elseif ($disabledTasks.Count -gt 0) {
        Add-Result 'BOOT' 'boot tasks registered' 'FAIL' ('disabled: ' + ($disabledTasks -join ', ')) 'Enable the task, or re-run Fix-PaseoBootTask.ps1.'
    }
    else {
        Add-Result 'BOOT' 'boot tasks registered' 'PASS' ("present and enabled: " + ($ExpectedBootTasks -join ', '))
    }
}
catch {
    Add-Result 'BOOT' 'boot tasks registered' 'SKIP' "could not read scheduled tasks: $($_.Exception.Message)"
}

# --------------------------------------------------------------------- 17 MCP
if ($null -eq $config) {
    Add-Result 'MCP' 'MCP wiring' 'SKIP' 'config.json unavailable'
}
else {
    $inject = if ($config.daemon.PSObject.Properties.Name -contains 'mcp' -and $config.daemon.mcp.PSObject.Properties.Name -contains 'injectIntoAgents') { [bool]$config.daemon.mcp.injectIntoAgents } else { $false }
    $mcpProblems = [Collections.Generic.List[string]]::new()
    $mcpCount = 0
    $candidateConfigs = @(
        (Join-Path $env:USERPROFILE '.config\opencode\opencode.json'),
        (Join-Path $env:USERPROFILE '.config\opencode\opencode.jsonc'),
        (Join-Path $env:USERPROFILE '.opencode\opencode.json'),
        (Join-Path $env:APPDATA 'opencode\opencode.json')
    )
    if ($env:XDG_CONFIG_HOME) {
        $candidateConfigs = @(
            (Join-Path $env:XDG_CONFIG_HOME 'opencode\opencode.json'),
            (Join-Path $env:XDG_CONFIG_HOME 'opencode\opencode.jsonc')
        ) + $candidateConfigs
    }
    $foundConfig = $false
    foreach ($c in $candidateConfigs) {
        if (-not (Test-Path -LiteralPath $c)) { continue }
        $foundConfig = $true
        $rawConfig = Get-Content -LiteralPath $c -Raw
        # .jsonc: strip line and block comments before parsing.
        $rawConfig = [regex]::Replace($rawConfig, '(?m)^\s*//.*$', '')
        $rawConfig = [regex]::Replace($rawConfig, '/\*.*?\*/', '', 'Singleline')
        $oc = ConvertFrom-JsonLoose -Text $rawConfig
        if ($null -ne $oc -and $oc.PSObject.Properties.Name -contains 'mcp') {
            foreach ($m in $oc.mcp.PSObject.Properties) {
                if ($m.Value.PSObject.Properties.Name -contains 'enabled' -and $m.Value.enabled -eq $false) { continue }
                $mcpCount++
                $cmd = $null
                if ($m.Value.PSObject.Properties.Name -contains 'command') {
                    $cmd = if ($m.Value.command -is [array]) { $m.Value.command[0] } else { $m.Value.command }
                }
                if ($cmd -and -not (Get-Command $cmd -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $cmd)) {
                    $mcpProblems.Add("$($m.Name): command '$cmd' not found")
                }
            }
        }
        break
    }
    if ($mcpProblems.Count -gt 0) {
        Add-Result 'MCP' 'MCP wiring' 'WARN' ("$($mcpProblems.Count) MCP server command(s) missing") 'Install the missing server or disable it; agents inherit a broken tool list otherwise.' -Evidence (Join-Evidence $mcpProblems)
    }
    elseif (-not $foundConfig -or $mcpCount -eq 0) {
        Add-Result 'MCP' 'MCP wiring' 'SKIP' ("no harness MCP server config found; Paseo mcp.injectIntoAgents=$inject")
    }
    else {
        Add-Result 'MCP' 'MCP wiring' 'PASS' ("mcp.injectIntoAgents=$inject; $mcpCount configured server command(s) resolve")
    }
}

# ------------------------------------------------------------------- REPORT
$previous = $null
$lastPath = Join-Path $StateRoot 'last.json'
if (Test-Path -LiteralPath $lastPath) {
    try { $previous = Get-Content -LiteralPath $lastPath -Raw | ConvertFrom-Json -Depth 20 } catch { }
}

$summary = [pscustomobject]@{
    Kind        = 'update-paseo'
    GeneratedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Version     = $version
    Previous    = if ($previous) { $previous.Version } else { $null }
    Transition  = if ($previous -and $previous.Version) { "$($previous.Version) -> $version" } else { "first run ($version)" }
    Host        = $env:COMPUTERNAME
    Results     = @($results)
    Counts      = [pscustomobject]@{
        PASS = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
        WARN = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
        FAIL = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
        SKIP = @($results | Where-Object { $_.Status -eq 'SKIP' }).Count
    }
}

try {
    if (-not (Test-Path -LiteralPath $StateRoot)) { New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $StateRoot "$stamp-$version.json") -Encoding utf8
    $summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $lastPath -Encoding utf8
}
catch { Write-Warning "could not write the update-paseo record: $($_.Exception.Message)" }

if ($Json) {
    $summary | ConvertTo-Json -Depth 20
}
else {
    Write-Host (Format-UpdateCheckReport -Result @($results) -Title ("Update Paseo - Paseo {0} ({1})" -f $version, $summary.Transition) -Detailed:$Detailed)
    if ($version -ne $previous.Version -and $previous.Version) {
        Write-Host "Transition recorded: $($summary.Transition)" -ForegroundColor Yellow
    }
    Write-Host "Record: $(Join-Path $StateRoot 'last.json')" -ForegroundColor DarkGray
}

exit (Get-UpdateCheckExitCode -Result @($results) -Strict:$Strict)
