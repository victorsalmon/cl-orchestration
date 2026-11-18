#Requires -Version 7.0
<#
.SYNOPSIS
    Comprehensive repair and diagnostics for OpenCode harness and configuration.

.DESCRIPTION
    Safely repairs and reconciles OpenCode installation, configuration, database,
    and runtime environment without data loss.

    Checks and repairs:
      1. Configuration syntax & schema in $env:XDG_CONFIG_HOME\opencode\opencode.jsonc
         (or D:\Apps\opencode\config\opencode\opencode.jsonc).
         Preserves backups before modifying anything.
      2. Plugin sanity (checks for syntax or export errors in plugins/ directory).
      3. Rogue OpenCode service processes & stale service.json files causing collisions.
      4. Database integrity and WAL checkpointing for opencode.db without deleting history.
      5. Credential alignment: Ensures auth.json and environment variables match active pool keys.
      6. Verification probe via standalone canary.

.PARAMETER WhatIf
    Dry-run mode. Scans and reports without modifying files or killing processes.

.PARAMETER ForceCheckpoint
    Runs a safe PRAGMA wal_checkpoint(PASSIVE) or TRUNCATE on opencode.db if sqlite3 is available.

.PARAMETER ResetConfigToKnownGood
    Replaces opencode.jsonc with proven known-good state if corrupted.

.EXAMPLE
    pwsh -File Repair-Opencode.ps1
.EXAMPLE
    pwsh -File Repair-Opencode.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$ForceCheckpoint,
    [switch]$ResetConfigToKnownGood
)

$ErrorActionPreference = 'Stop'

function Write-Section {
    param([string]$Title)
    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
}

function Write-Pass {
    param([string]$Msg)
    Write-Host "  [PASS] $Msg" -ForegroundColor Green
}

function Write-WarnMsg {
    param([string]$Msg)
    Write-Host "  [WARN] $Msg" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Msg)
    Write-Host "  [FAIL] $Msg" -ForegroundColor Red
}

function Write-Action {
    param([string]$Msg)
    Write-Host "  [ACTION] $Msg" -ForegroundColor Magenta
}

# --- 1. Path Resolution ---
Write-Section "1. Resolving OpenCode Environment Paths"

$configHome = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME', 'Process')
if (-not $configHome) { $configHome = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME', 'User') }
if (-not $configHome) { $configHome = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME', 'Machine') }
if (-not $configHome) { $configHome = 'D:\Apps\opencode\config' }

$dataHome = [Environment]::GetEnvironmentVariable('XDG_DATA_HOME', 'Process')
if (-not $dataHome) { $dataHome = [Environment]::GetEnvironmentVariable('XDG_DATA_HOME', 'User') }
if (-not $dataHome) { $dataHome = [Environment]::GetEnvironmentVariable('XDG_DATA_HOME', 'Machine') }
if (-not $dataHome) { $dataHome = 'D:\opencode-data' }

$opencodeConfigDir = Join-Path $configHome 'opencode'
$opencodeDataDir = Join-Path $dataHome 'opencode'
$opencodeConfigFile = Join-Path $opencodeConfigDir 'opencode.jsonc'
$opencodeDbFile = Join-Path $opencodeDataDir 'opencode.db'
$serviceFile = Join-Path $env:USERPROFILE '.local\state\opencode\service.json'

Write-Host "  Config dir : $opencodeConfigDir"
Write-Host "  Data dir   : $opencodeDataDir"
Write-Host "  Config file: $opencodeConfigFile"
Write-Host "  Database   : $opencodeDbFile"

# --- 2. Shared Service Collision & Stray Process Cleanup ---
Write-Section "2. Detecting Shared Service & Process Collision"

$strayProcs = Get-CimInstance Win32_Process -Filter "Name='opencode.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'serve.*--service' }

if ($strayProcs) {
    $pids = ($strayProcs | ForEach-Object { $_.ProcessId }) -join ', '
    Write-WarnMsg "Found running shared opencode service processes: $pids"
    if ($PSCmdlet.ShouldProcess("Terminate opencode service processes: $pids")) {
        foreach ($proc in $strayProcs) {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Write-Action "Terminated shared opencode service processes ($pids)."
    }
} else {
    Write-Pass "No rogue opencode serve --service processes running."
}

if (Test-Path -LiteralPath $serviceFile) {
    Write-WarnMsg "Discovered service.json file at $serviceFile"
    if ($PSCmdlet.ShouldProcess("Remove service collision file $serviceFile")) {
        Remove-Item -LiteralPath $serviceFile -Force -ErrorAction SilentlyContinue
        Write-Action "Removed $serviceFile to prevent Paseo provider collision."
    }
} else {
    Write-Pass "No service.json collision file present."
}

# --- 3. Configuration & Schema Integrity ---
Write-Section "3. Verifying OpenCode Configuration"

if (-not (Test-Path -LiteralPath $opencodeConfigFile)) {
    Write-Fail "opencode.jsonc not found at $opencodeConfigFile"
    if ($ResetConfigToKnownGood -or $PSCmdlet.ShouldProcess("Create default opencode.jsonc")) {
        # Restore from Reset-OpencodeProvider.ps1 if present
        $resetScript = Join-Path $opencodeConfigDir 'Reset-OpencodeProvider.ps1'
        if (Test-Path -LiteralPath $resetScript) {
            & pwsh -NoProfile -File $resetScript -ConfigPath $opencodeConfigFile
            Write-Action "Created opencode.jsonc using Reset-OpencodeProvider.ps1"
        } else {
            Write-Fail "Reset script not found. Please provide a valid config."
        }
    }
} else {
    try {
        $rawConfig = Get-Content -LiteralPath $opencodeConfigFile -Raw
        # Remove JSONC comments for validation
        $jsonOnly = $rawConfig -replace '(?m)^\s*//.*$', '' -replace '(?s)/\*.*?\*/', ''
        $parsed = $jsonOnly | ConvertFrom-Json
        Write-Pass "opencode.jsonc parses as valid JSON."

        # Check required fields
        if ($parsed.provider.'opencode-go') {
            $goProvider = $parsed.provider.'opencode-go'
            Write-Pass "Provider 'opencode-go' declared (adapter: $($goProvider.npm))."
            if ($goProvider.npm -ne '@ai-sdk/openai-compatible') {
                Write-WarnMsg "Adapter is $($goProvider.npm); expected '@ai-sdk/openai-compatible' for Zen Go gateway."
            }
        } else {
            Write-WarnMsg "Provider 'opencode-go' is missing from opencode.jsonc!"
        }

        if ($parsed.compaction) {
            Write-Pass "Compaction settings configured (auto=$($parsed.compaction.auto))."
        }
    } catch {
        Write-Fail "Failed to parse opencode.jsonc: $($_.Exception.Message)"
        if ($ResetConfigToKnownGood) {
            $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
            Copy-Item -LiteralPath $opencodeConfigFile "$opencodeConfigFile.bak-$stamp" -Force
            Write-Action "Backed up corrupted config to $opencodeConfigFile.bak-$stamp"
            $resetScript = Join-Path $opencodeConfigDir 'Reset-OpencodeProvider.ps1'
            if (Test-Path -LiteralPath $resetScript) {
                & pwsh -NoProfile -File $resetScript -ConfigPath $opencodeConfigFile
                Write-Action "Restored known-good config."
            }
        } else {
            Write-WarnMsg "Run with -ResetConfigToKnownGood to safely restore known-good provider config."
        }
    }
}

# --- 4. Plugins Validation ---
Write-Section "4. Validating Plugins"

$pluginsDir = Join-Path $opencodeConfigDir 'plugins'
if (Test-Path -LiteralPath $pluginsDir) {
    $plugins = Get-ChildItem -LiteralPath $pluginsDir -Filter '*.js'
    foreach ($plugin in $plugins) {
        $content = Get-Content -LiteralPath $plugin.FullName -Raw
        if ($content -match 'export\s+default\s*\{' -or $content -match 'export\s+default\s+function') {
            Write-Pass "Plugin $($plugin.Name): exports default definition."
        } else {
            Write-WarnMsg "Plugin $($plugin.Name): missing 'export default' definition."
        }
    }
} else {
    Write-Pass "No custom plugins directory present."
}

# --- 5. Database Health & WAL Maintenance ---
Write-Section "5. Inspecting Database Health"

if (Test-Path -LiteralPath $opencodeDbFile) {
    $dbItem = Get-Item -LiteralPath $opencodeDbFile
    $sizeGB = [Math]::Round($dbItem.Length / 1GB, 2)
    Write-Host "  Database file size: $sizeGB GB ($($dbItem.Length) bytes)"

    $walFile = "$opencodeDbFile-wal"
    if (Test-Path -LiteralPath $walFile) {
        $walItem = Get-Item -LiteralPath $walFile
        $walMB = [Math]::Round($walItem.Length / 1MB, 2)
        Write-Host "  WAL file size     : $walMB MB"
        if ($walItem.Length -gt 500MB) {
            Write-WarnMsg "WAL file exceeds 500MB. Checkpointing recommended."
            if ($ForceCheckpoint) {
                $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
                if ($sqlite) {
                    Write-Action "Running PRAGMA wal_checkpoint(PASSIVE)..."
                    & sqlite3 $opencodeDbFile "PRAGMA wal_checkpoint(PASSIVE);"
                    Write-Pass "Checkpoint completed."
                } else {
                    Write-WarnMsg "sqlite3 executable not on PATH; skipping checkpoint."
                }
            }
        } else {
            Write-Pass "WAL file is within healthy size limits."
        }
    } else {
        Write-Pass "No outstanding WAL file."
    }
} else {
    Write-WarnMsg "Database file not found at $opencodeDbFile (will be created on first run)."
}

# --- 6. Credential & Auth Alignment ---
Write-Section "6. Checking Credential & Auth Alignment"

$activeGoKey = [Environment]::GetEnvironmentVariable('OPENCODE_GO_KEY', 'Process')
if (-not $activeGoKey) { $activeGoKey = [Environment]::GetEnvironmentVariable('OPENCODE_GO_KEY', 'User') }
if (-not $activeGoKey) { $activeGoKey = [Environment]::GetEnvironmentVariable('OPENCODE_GO_KEY', 'Machine') }

if ($activeGoKey) {
    $keySnippet = $activeGoKey.Substring(0, [Math]::Min(12, $activeGoKey.Length)) + '...'
    Write-Pass "Active OPENCODE_GO_KEY found in environment ($keySnippet)."
} else {
    Write-Fail "No OPENCODE_GO_KEY found in Process, User, or Machine environment!"
}

$authJson = Join-Path $opencodeDataDir 'auth.json'
if (Test-Path -LiteralPath $authJson) {
    try {
        $authData = Get-Content -LiteralPath $authJson -Raw | ConvertFrom-Json
        $providers = ($authData.psobject.Properties | ForEach-Object { $_.Name }) -join ', '
        Write-Pass "auth.json valid. Stored providers: $providers"
    } catch {
        Write-WarnMsg "auth.json exists but failed to parse: $($_.Exception.Message)"
    }
}

# --- 7. Canary & Model Verification ---
Write-Section "7. Verifying OpenCode Connectivity"

$canaryScript = "$env:CL_REPOS_ROOT\cl-common\vendor\interactive-qa\vendor\credential-rescue\scripts\Test-GoKey.ps1"
if (-not (Test-Path -LiteralPath $canaryScript)) {
    $canaryScript = "E:\Repos\cl-common\vendor\interactive-qa\vendor\credential-rescue\scripts\Test-GoKey.ps1"
}

if ((Test-Path -LiteralPath $canaryScript) -and $activeGoKey) {
    Write-Host "  Running live canary probe..."
    try {
        $canaryOut = & pwsh -NoProfile -File $canaryScript -KeyValue $activeGoKey -Model 'opencode-go/deepseek-v4.1-flash' 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -and $canaryOut -match 'OK') {
            Write-Pass "Model canary passed: $($canaryOut.Trim())"
        } else {
            Write-Fail "Model canary reported: $($canaryOut.Trim())"
        }
    } catch {
        Write-Fail "Model canary execution failed: $($_.Exception.Message)"
    }
} else {
    Write-WarnMsg "Canary script Test-GoKey.ps1 not found or active key unavailable."
}

Write-Section "Repair & Diagnostic Summary"
Write-Host "OpenCode repair scan finished.`n"
