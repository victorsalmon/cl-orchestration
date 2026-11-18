#Requires -Version 7.0
<#
.SYNOPSIS
    Modular probe definitions for Paseo health checks.

.DESCRIPTION
    Provides discrete, side-effect-free probe functions that test the 9 core
    invariants of a working Paseo installation on Windows:
      1. DAEMON-RUNNING: Daemon process is running and endpoint is listening
      2. LOCK-STALE: ~/.paseo/paseo.pid does not point to a dead process
      3. SERVICE-COLLISION: No ~/.local/state/opencode/service.json causing shared-service env bans
      4. ENV-RUN-AS-NODE: ELECTRON_RUN_AS_NODE is not poisoning the environment
      5. BOOT-TASK-ARG: S4U Scheduled Task does not use deprecated --foreground
      6. CONFIG-SYNTAX: ~/.paseo/config.json parses cleanly with required sections
      7. PATH-TRUNCATION: User PATH has not been truncated at 1024 characters
      8. PROVIDER-BINARIES: opencode, node, git resolve cleanly in PATH
      9. KEY-PROVIDER-MATCH: Paseo provider env key matches active system key label
#>

function Test-ProbeDaemonRunning {
    $listen = "127.0.0.1:6767"
    $pidFile = Join-Path $env:USERPROFILE ".paseo\paseo.pid"
    
    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect("127.0.0.1", 6767, $null, $null)
        $success = $iar.AsyncWaitHandle.WaitOne(800, $false)
        if ($success -and $tcp.Connected) {
            $tcp.EndConnect($iar)
            return [PSCustomObject]@{
                Id = "DAEMON-RUNNING"
                Name = "Daemon listening on $listen"
                Status = "PASS"
                Reason = "Endpoint 127.0.0.1:6767 is responding"
                Remedy = "None required"
            }
        }
    } catch {
    } finally {
        if ($tcp) { $tcp.Dispose() }
    }

    # If endpoint didn't respond, check if process exists
    $proc = Get-Process Paseo -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        return [PSCustomObject]@{
            Id = "DAEMON-RUNNING"
            Name = "Daemon listening on $listen"
            Status = "WARN"
            Reason = "Paseo processes exist (PID $($proc.Id)) but 127.0.0.1:6767 not responding"
            Remedy = "Allow daemon startup to complete or run: paseo restart"
        }
    }

    return [PSCustomObject]@{
        Id = "DAEMON-RUNNING"
        Name = "Daemon listening on $listen"
        Status = "FAIL"
        Reason = "Paseo daemon is stopped and not listening on 127.0.0.1:6767"
        Remedy = "Start Paseo app or run: paseo daemon run --home $env:USERPROFILE\.paseo"
    }
}

function Test-ProbeLockStale {
    $pidFile = Join-Path $env:USERPROFILE ".paseo\paseo.pid"
    if (-not (Test-Path -LiteralPath $pidFile)) {
        return [PSCustomObject]@{
            Id = "LOCK-STALE"
            Name = "Paseo PID lock integrity"
            Status = "PASS"
            Reason = "No lockfile present (daemon stopped or socket-only)"
            Remedy = "None required"
        }
    }

    try {
        $data = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
        $proc = Get-Process -Id $data.pid -ErrorAction SilentlyContinue
        if ($proc) {
            return [PSCustomObject]@{
                Id = "LOCK-STALE"
                Name = "Paseo PID lock integrity"
                Status = "PASS"
                Reason = "Lockfile points to active process PID $($data.pid)"
                Remedy = "None required"
            }
        } else {
            return [PSCustomObject]@{
                Id = "LOCK-STALE"
                Name = "Paseo PID lock integrity"
                Status = "FAIL"
                Reason = "Stale lockfile! points to dead PID $($data.pid)"
                Remedy = "Remove-Item '$pidFile' -Force"
            }
        }
    } catch {
        return [PSCustomObject]@{
            Id = "LOCK-STALE"
            Name = "Paseo PID lock integrity"
            Status = "WARN"
            Reason = "Corrupt lockfile: $_"
            Remedy = "Remove-Item '$pidFile' -Force"
        }
    }
}

function Test-ProbeServiceCollision {
    $serviceFile = Join-Path $env:USERPROFILE ".local\state\opencode\service.json"
    $hasFile = Test-Path -LiteralPath $serviceFile
    
    $servProcs = Get-CimInstance Win32_Process -Filter "Name='opencode.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'serve.*--service' }

    if ($hasFile -or $servProcs) {
        $pids = ($servProcs | ForEach-Object { $_.ProcessId }) -join ", "
        return [PSCustomObject]@{
            Id = "SERVICE-COLLISION"
            Name = "OpenCode Shared Service Collision"
            Status = "FAIL"
            Reason = "Discovered external OpenCode service! (file: $hasFile, PIDs: $pids). Shared service strictly forbids custom OPENCODE_GO_KEY in Paseo config."
            Remedy = "Stop-Process -Id $pids -Force; Remove-Item '$serviceFile' -Force"
        }
    }

    return [PSCustomObject]@{
        Id = "SERVICE-COLLISION"
        Name = "OpenCode Shared Service Collision"
        Status = "PASS"
        Reason = "No rogue service.json or opencode --service processes found"
        Remedy = "None required"
    }
}

function Test-ProbeEnvRunAsNode {
    $val = [Environment]::GetEnvironmentVariable("ELECTRON_RUN_AS_NODE", "Process")
    if ([string]::IsNullOrEmpty($val)) {
        $val = [Environment]::GetEnvironmentVariable("ELECTRON_RUN_AS_NODE", "User")
    }
    
    if (-not [string]::IsNullOrEmpty($val)) {
        return [PSCustomObject]@{
            Id = "ENV-RUN-AS-NODE"
            Name = "Electron Environment Cleanliness"
            Status = "FAIL"
            Reason = "ELECTRON_RUN_AS_NODE is set ($val). This causes Paseo.exe to immediately exit code 0 without GUI!"
            Remedy = "Remove-Item env:ELECTRON_RUN_AS_NODE; [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', `$null, 'User')"
        }
    }

    return [PSCustomObject]@{
        Id = "ENV-RUN-AS-NODE"
        Name = "Electron Environment Cleanliness"
        Status = "PASS"
        Reason = "ELECTRON_RUN_AS_NODE is not set"
        Remedy = "None required"
    }
}

function Test-ProbeBootTaskArg {
    $task = Get-ScheduledTask -TaskName "Paseo Daemon" -ErrorAction SilentlyContinue
    if (-not $task) {
        return [PSCustomObject]@{
            Id = "BOOT-TASK-ARG"
            Name = "S4U Boot Scheduled Task"
            Status = "WARN"
            Reason = "Scheduled task 'Paseo Daemon' is not registered"
            Remedy = "pwsh -File (Join-Path `$PSScriptRoot 'Fix-PaseoBootTask.ps1')"
        }
    }

    $action = $task.Actions | Select-Object -First 1
    if ($action -and $action.Arguments -match "daemon\s+start\s+--foreground") {
        return [PSCustomObject]@{
            Id = "BOOT-TASK-ARG"
            Name = "S4U Boot Scheduled Task"
            Status = "FAIL"
            Reason = "Task uses obsolete 'daemon start --foreground' argument removed in Paseo 0.14+ (causes LastTaskResult=1)"
            Remedy = "Run elevated: pwsh -File (Join-Path `$PSScriptRoot 'Fix-PaseoBootTask.ps1')"
        }
    }

    return [PSCustomObject]@{
        Id = "BOOT-TASK-ARG"
        Name = "S4U Boot Scheduled Task"
        Status = "PASS"
        Reason = "Task action uses modern arguments ('daemon run' or custom headless command)"
        Remedy = "None required"
    }
}

function Test-ProbeConfigSyntax {
    $configPath = Join-Path $env:USERPROFILE ".paseo\config.json"
    if (-not (Test-Path -LiteralPath $configPath)) {
        return [PSCustomObject]@{
            Id = "CONFIG-SYNTAX"
            Name = "Paseo config.json schema and syntax"
            Status = "WARN"
            Reason = "Config file does not exist at $configPath"
            Remedy = "Launch Paseo to generate default config"
        }
    }

    try {
        $raw = Get-Content -LiteralPath $configPath -Raw
        $cfg = $raw | ConvertFrom-Json
        if ($null -eq $cfg.agents -or $null -eq $cfg.agents.providers) {
            return [PSCustomObject]@{
                Id = "CONFIG-SYNTAX"
                Name = "Paseo config.json schema and syntax"
                Status = "WARN"
                Reason = "Config missing agents.providers section"
                Remedy = "Repair config using Repair-Paseo.ps1 or restore from backup"
            }
        }
        return [PSCustomObject]@{
            Id = "CONFIG-SYNTAX"
            Name = "Paseo config.json schema and syntax"
            Status = "PASS"
            Reason = "JSON is valid and agents.providers structure is present"
            Remedy = "None required"
        }
    } catch {
        return [PSCustomObject]@{
            Id = "CONFIG-SYNTAX"
            Name = "Paseo config.json schema and syntax"
            Status = "FAIL"
            Reason = "Invalid JSON in $configPath : $_"
            Remedy = "Restore from latest ~/.paseo/config.json.bak-*"
        }
    }
}

function Test-ProbePathTruncation {
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($null -eq $userPath) { $userPath = "" }
    
    $len = $userPath.Length
    if ($len -ge 1024) {
        return [PSCustomObject]@{
            Id = "PATH-TRUNCATION"
            Name = "Windows User PATH Length"
            Status = "FAIL"
            Reason = "User PATH length is $len >= 1024 chars! Hit setx 1024-char limit, truncating essential npm/tooling paths."
            Remedy = "Clean duplicated machine paths out of User PATH per Runbook C"
        }
    }

    $npmGlobal = Join-Path $env:APPDATA "npm"
    if ($userPath -notmatch [regex]::Escape($npmGlobal) -and $env:PATH -notmatch [regex]::Escape($npmGlobal)) {
        return [PSCustomObject]@{
            Id = "PATH-TRUNCATION"
            Name = "Windows User PATH Length"
            Status = "WARN"
            Reason = "User PATH ($len chars) does not explicitly include npm global roaming directory ($npmGlobal)"
            Remedy = "Append '$npmGlobal' to User PATH without using setx"
        }
    }

    return [PSCustomObject]@{
        Id = "PATH-TRUNCATION"
        Name = "Windows User PATH Length"
        Status = "PASS"
        Reason = "User PATH is healthy ($len chars < 1024) and includes essential tool directories"
        Remedy = "None required"
    }
}

function Test-ProbeProviderBinaries {
    $tools = @("node", "git", "opencode")
    $missing = @()
    foreach ($t in $tools) {
        if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
            $missing += $t
        }
    }

    if ($missing.Count -gt 0) {
        return [PSCustomObject]@{
            Id = "PROVIDER-BINARIES"
            Name = "Provider CLI Tools Discovery"
            Status = "FAIL"
            Reason = "Required binaries missing from PATH: $($missing -join ', ')"
            Remedy = "Install missing tools or add their install directories to system PATH"
        }
    }

    return [PSCustomObject]@{
        Id = "PROVIDER-BINARIES"
        Name = "Provider CLI Tools Discovery"
        Status = "PASS"
        Reason = "All core provider tools resolve cleanly (node, git, opencode)"
        Remedy = "None required"
    }
}

function Test-ProbeKeyProviderMatch {
    $configPath = Join-Path $env:USERPROFILE ".paseo\config.json"
    if (-not (Test-Path -LiteralPath $configPath)) {
        return [PSCustomObject]@{
            Id = "KEY-PROVIDER-MATCH"
            Name = "Active Key and Paseo Provider Pin"
            Status = "WARN"
            Reason = "Cannot verify: config.json missing"
            Remedy = "None required"
        }
    }

    try {
        $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $pinnedKey = $cfg.agents.providers.opencode.env.OPENCODE_GO_KEY
        if ([string]::IsNullOrWhiteSpace($pinnedKey)) {
            return [PSCustomObject]@{
                Id = "KEY-PROVIDER-MATCH"
                Name = "Active Key and Paseo Provider Pin"
                Status = "WARN"
                Reason = "No pinned OPENCODE_GO_KEY in ~/.paseo/config.json (running default/inherited)"
                Remedy = "Run Repair-Paseo.ps1 to pin active pool key"
            }
        }

        # Compare labels only
        $activeUserKey = [Environment]::GetEnvironmentVariable("OPENCODE_GO_KEY", "User")
        if (-not [string]::IsNullOrWhiteSpace($activeUserKey) -and $pinnedKey -ne $activeUserKey) {
            return [PSCustomObject]@{
                Id = "KEY-PROVIDER-MATCH"
                Name = "Active Key and Paseo Provider Pin"
                Status = "WARN"
                Reason = "Paseo config pinned key differs from User OPENCODE_GO_KEY! (Paseo will use pinned key)"
                Remedy = "Run Repair-Paseo.ps1 to sync Paseo provider env with active pool key"
            }
        }

        return [PSCustomObject]@{
            Id = "KEY-PROVIDER-MATCH"
            Name = "Active Key and Paseo Provider Pin"
            Status = "PASS"
            Reason = "Paseo provider pin matches User environment key"
            Remedy = "None required"
        }
    } catch {
        return [PSCustomObject]@{
            Id = "KEY-PROVIDER-MATCH"
            Name = "Active Key and Paseo Provider Pin"
            Status = "WARN"
            Reason = "Could not parse config: $_"
            Remedy = "Run Test-ProbeConfigSyntax"
        }
    }
}

