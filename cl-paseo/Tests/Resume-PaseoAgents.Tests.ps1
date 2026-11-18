#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

<#
.SYNOPSIS
    Pester tests for Resume-PaseoAgents.ps1.

    Covers the classification contract that decides which agents a reboot
    interrupted, and the send path itself, without a live daemon:

      1. running + recent          -> resume
      2. idle                      -> leave alone
      3. archived                  -> leave alone
      4. stale beyond -MaxAgeHours -> leave alone
      5. error without requiresAttention -> resume; with it -> leave alone
      6. cap at -MaxResumes, most recent first
      7. -Manifest records the candidate set
      8. -FromManifest replays exactly that set
      9. -DryRun sends nothing
     10. a real run calls `send <id> Continue` through the Paseo CLI

    The script is invoked as a child process (never dot-sourced): its top-level
    body is the reconciler itself.
#>
BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' 'scripts' 'Resume-PaseoAgents.ps1'
    if (-not (Test-Path $script:Script)) { throw "reconciler not found: $script:Script" }

    function New-FixtureHome {
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][hashtable[]]$Records
        )
        if (Test-Path $Root) { Remove-Item $Root -Recurse -Force }
        $dir = Join-Path $Root 'agents\w1'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $now = (Get-Date).ToUniversalTime()
        foreach ($r in $Records) {
            $ageHours = if ($r.ContainsKey('ageHours')) { $r.ageHours } else { 1 }
            $archived = if ($r.ContainsKey('archived')) { $r.archived } else { $null }
            $attention = if ($r.ContainsKey('attention')) { $r.attention } else { $false }
            [ordered]@{
                id               = $r.id
                lastStatus       = $r.status
                title            = $r.id
                provider         = 'opencode'
                cwd              = 'C:\fixture'
                updatedAt        = $now.AddHours(-$ageHours)
                lastActivityAt   = $now.AddHours(-$ageHours)
                archivedAt       = $archived
                requiresAttention = $attention
            } | ConvertTo-Json | Set-Content -Path (Join-Path $dir "$($r.id).json") -Encoding utf8
        }
        return $Root
    }

    function New-RecordingPaseo {
        param([Parameter(Mandatory)][string]$Root)
        if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
        $stub = Join-Path $Root 'paseo-stub.cmd'
        $log = Join-Path $Root 'sent.log'
        "@echo off`r`necho %*>> `"$log`"" | Set-Content -Path $stub -Encoding ascii
        return [pscustomobject]@{ Path = $stub; Log = $log }
    }

    function Invoke-Reconciler {
        param(
            [Parameter(Mandatory)][string]$FixtureHome,
            [string]$PaseoExe,
            [switch]$DryRun,
            [string]$Manifest,
            [string]$FromManifest,
            [int]$MaxResumes = 12,
            [string]$BootTime,
            [switch]$WriteRoster
        )
        $argv = @('-NoProfile', '-File', $script:Script, '-PaseoHome', $FixtureHome, '-SkipDaemonWait', '-MaxResumes', $MaxResumes, '-BetweenResumesSeconds', '0')
        if ($DryRun) { $argv += '-DryRun' }
        if ($Manifest) { $argv += @('-Manifest', $Manifest) }
        if ($FromManifest) { $argv += @('-FromManifest', $FromManifest) }
        if ($PaseoExe) { $argv += @('-PaseoExe', $PaseoExe) }
        if ($BootTime) { $argv += @('-BootTime', $BootTime) }
        if ($WriteRoster) { $argv += '-WriteRoster' }
        $out = & pwsh @argv 2>&1 | Out-String
        return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
    }
    function New-Roster {
        param([string]$Home_, [string]$Name = 'running-roster.json', [string]$BootAt, [datetime]$At, [string[]]$Ids, [string]$ConsumedBoot)
        $doc = [ordered]@{ at = $At.ToString('o'); bootAt = $BootAt; agents = @($Ids | ForEach-Object { [ordered]@{ id = $_; title = $_ } }) }
        if ($ConsumedBoot) { $doc.consumedBoot = $ConsumedBoot }
        $doc | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $Home_ $Name) -Encoding utf8
    }

}

Describe 'Resume-PaseoAgents classification' -Tag 'cl-paseo' {
    BeforeEach {
        $script:FixtureHome = Join-Path $TestDrive ('home-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    }

    It 'resumes an interrupted (running) record' {
        New-FixtureHome -Root $script:FixtureHome -Records @(@{ id = 'run-1'; status = 'running' }) | Out-Null
        $r = Invoke-Reconciler -FixtureHome $script:FixtureHome -DryRun
        $r.Output | Should -Match 'WOULD RESUME run-1'
        $r.Output | Should -Match 'candidates: 1'
    }

    It 'leaves an idle record alone' {
        New-FixtureHome -Root $script:FixtureHome -Records @(@{ id = 'idle-1'; status = 'idle' }) | Out-Null
        $r = Invoke-Reconciler -FixtureHome $script:FixtureHome -DryRun
        $r.Output | Should -Match 'candidates: 0'
        $r.Output | Should -Not -Match 'WOULD RESUME'
    }

    It 'leaves an archived record alone even when it was running' {
        New-FixtureHome -Root $script:FixtureHome -Records @(@{ id = 'arch-1'; status = 'running'; archived = (Get-Date).ToUniversalTime() }) | Out-Null
        $r = Invoke-Reconciler -FixtureHome $script:FixtureHome -DryRun
        $r.Output | Should -Match 'candidates: 0'
    }

    It 'leaves a stale running record alone' {
        New-FixtureHome -Root $script:FixtureHome -Records @(@{ id = 'stale-1'; status = 'running'; ageHours = 72 }) | Out-Null
        $r = Invoke-Reconciler -FixtureHome $script:FixtureHome -DryRun
        $r.Output | Should -Match 'candidates: 0'
    }

    It 'resumes an errored record but not one flagged as finished' {
        New-FixtureHome -Root $script:FixtureHome -Records @(
            @{ id = 'err-1'; status = 'error' }
            @{ id = 'err-done'; status = 'error'; attention = $true }
        ) | Out-Null
        $r = Invoke-Reconciler -FixtureHome $script:FixtureHome -DryRun
        $r.Output | Should -Match 'WOULD RESUME err-1'
        $r.Output | Should -Not -Match 'err-done'
    }

    It 'caps the set at -MaxResumes and says so' {
        $records = 1..15 | ForEach-Object { @{ id = "cap-$_"; status = 'running'; ageHours = $_ } }
        New-FixtureHome -Root $script:FixtureHome -Records $records | Out-Null
        $r = Invoke-Reconciler -FixtureHome $script:FixtureHome -DryRun -MaxResumes 12
        $r.Output | Should -Match 'capped at 12 of 15'
        ([regex]::Matches($r.Output, 'WOULD RESUME')).Count | Should -Be 12
        $r.Output | Should -Match 'WOULD RESUME cap-1'
        $r.Output | Should -Not -Match 'WOULD RESUME cap-13'
    }
}

Describe 'Resume-PaseoAgents manifest and send path' -Tag 'cl-paseo' {
    BeforeEach {
        $script:FixtureHome = Join-Path $TestDrive ('home-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Manifest = Join-Path $script:FixtureHome 'manifest.json'
    }

    It 'records the candidate set in -Manifest' {
        New-FixtureHome -Root $script:FixtureHome -Records @(
            @{ id = 'm-1'; status = 'running' }
            @{ id = 'm-2'; status = 'idle' }
        ) | Out-Null
        Invoke-Reconciler -FixtureHome $script:FixtureHome -DryRun -Manifest $script:Manifest | Out-Null
        $doc = Get-Content $script:Manifest -Raw | ConvertFrom-Json
        $doc.count | Should -Be 1
        $doc.candidates[0].id | Should -Be 'm-1'
    }

    It 'replays exactly the manifest set with -FromManifest' {
        New-FixtureHome -Root $script:FixtureHome -Records @(
            @{ id = 'p-1'; status = 'running' }
            @{ id = 'p-2'; status = 'running' }
        ) | Out-Null
        Invoke-Reconciler -FixtureHome $script:FixtureHome -DryRun -Manifest $script:Manifest | Out-Null

        # shrink the manifest to one entry, then replay: the classifier must not re-add p-2
        $doc = Get-Content $script:Manifest -Raw | ConvertFrom-Json
        $doc.candidates = @($doc.candidates | Where-Object { $_.id -eq 'p-1' })
        $doc.count = 1
        $doc | ConvertTo-Json -Depth 5 | Set-Content $script:Manifest -Encoding utf8

        $r = Invoke-Reconciler -FixtureHome $script:FixtureHome -DryRun -FromManifest $script:Manifest
        $r.Output | Should -Match 'manifest mode'
        $r.Output | Should -Match 'WOULD RESUME p-1'
        $r.Output | Should -Not -Match 'p-2'
    }

    It 'sends nothing in -DryRun' {
        New-FixtureHome -Root $script:FixtureHome -Records @(@{ id = 'd-1'; status = 'running' }) | Out-Null
        $stub = New-RecordingPaseo -Root $script:FixtureHome
        Invoke-Reconciler -FixtureHome $script:FixtureHome -DryRun -PaseoExe $stub.Path | Out-Null
        Test-Path $stub.Log | Should -BeFalse
    }

    It 'sends Continue to each candidate through the Paseo CLI' {
        New-FixtureHome -Root $script:FixtureHome -Records @(
            @{ id = 's-1'; status = 'running' }
            @{ id = 's-2'; status = 'running'; ageHours = 2 }
        ) | Out-Null
        $stub = New-RecordingPaseo -Root $script:FixtureHome
        $r = Invoke-Reconciler -FixtureHome $script:FixtureHome -PaseoExe $stub.Path
        $r.Output | Should -Match 'RESUMED s-1'
        $r.Output | Should -Match 'RESUMED s-2'
        $r.Output | Should -Match 'reconcile done resumed=2'

        $sent = Get-Content $stub.Log
        $sent.Count | Should -Be 2
        $sent[0] | Should -Match '^"send" "s-1" "Continue" "--home" ".+" "--no-wait"$'
        $sent[1] | Should -Match '^"send" "s-2" "Continue" "--home" ".+" "--no-wait"$'
    }
}

# cl-common-923q: the 2026-11-13 reboot shut Paseo down gracefully, every
# interrupted lane was saved as closed/idle, and the lastStatus classifier
# resumed nothing. The watchdog now records which agents are running; the boot
# pass resumes the roster written in the PREVIOUS boot.
Describe 'Resume-PaseoAgents pre-boot roster' -Tag 'cl-paseo' {
    BeforeEach {
        $script:FixtureHome = Join-Path $TestDrive ('home-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Boot = '2026-11-13T16:37:35.0000000+00:00'
        $script:PrevBoot = '2026-11-12T21:24:44.0000000+00:00'
    }

    It 'resumes roster agents a graceful shutdown saved as closed or idle' {
        New-FixtureHome -Root $script:FixtureHome -Records @(
            @{ id = 'lane-c'; status = 'closed' }
            @{ id = 'lane-i'; status = 'idle' }
            @{ id = 'not-in-roster'; status = 'closed' }
        ) | Out-Null
        New-Roster -Home_ $script:FixtureHome -BootAt $script:PrevBoot -At (Get-Date).AddMinutes(-5) -Ids @('lane-c', 'lane-i')
        $r = Invoke-Reconciler -FixtureHome $script:FixtureHome -DryRun -BootTime $script:Boot
        $r.Output | Should -Match 'WOULD RESUME lane-c'
        $r.Output | Should -Match 'WOULD RESUME lane-i'
        $r.Output | Should -Not -Match 'not-in-roster'
        $r.Output | Should -Match 'roster: 2 from'
    }

    It 'ignores a roster written during the current boot' {
        New-FixtureHome -Root $script:FixtureHome -Records @(@{ id = 'lane-c'; status = 'closed' }) | Out-Null
        New-Roster -Home_ $script:FixtureHome -BootAt $script:Boot -At (Get-Date) -Ids @('lane-c')
        $r = Invoke-Reconciler -FixtureHome $script:FixtureHome -DryRun -BootTime $script:Boot
        $r.Output | Should -Match 'candidates: 0'
    }

    It 'reads the pre-boot roster that a post-boot write moved aside' {
        New-FixtureHome -Root $script:FixtureHome -Records @(@{ id = 'lane-c'; status = 'closed' }) | Out-Null
        New-Roster -Home_ $script:FixtureHome -BootAt $script:Boot -At (Get-Date) -Ids @()
        New-Roster -Home_ $script:FixtureHome -Name 'running-roster.preboot.json' -BootAt $script:PrevBoot -At (Get-Date).AddMinutes(-6) -Ids @('lane-c')
        $r = Invoke-Reconciler -FixtureHome $script:FixtureHome -DryRun -BootTime $script:Boot
        $r.Output | Should -Match 'WOULD RESUME lane-c'
    }

    It 'never resumes an archived or stale roster agent' {
        New-FixtureHome -Root $script:FixtureHome -Records @(
            @{ id = 'arch'; status = 'closed'; archived = (Get-Date).ToUniversalTime() }
            @{ id = 'old'; status = 'closed'; ageHours = 72 }
        ) | Out-Null
        New-Roster -Home_ $script:FixtureHome -BootAt $script:PrevBoot -At (Get-Date).AddMinutes(-5) -Ids @('arch', 'old')
        $r = Invoke-Reconciler -FixtureHome $script:FixtureHome -DryRun -BootTime $script:Boot
        $r.Output | Should -Match 'candidates: 0'
    }

    It 'consumes the roster once, so a second boot pass sends nothing' {
        New-FixtureHome -Root $script:FixtureHome -Records @(@{ id = 'lane-c'; status = 'closed' }) | Out-Null
        New-Roster -Home_ $script:FixtureHome -BootAt $script:PrevBoot -At (Get-Date).AddMinutes(-5) -Ids @('lane-c')
        $stub = New-RecordingPaseo -Root $script:FixtureHome
        $first = Invoke-Reconciler -FixtureHome $script:FixtureHome -PaseoExe $stub.Path -BootTime $script:Boot
        $first.Output | Should -Match 'RESUMED lane-c'
        $second = Invoke-Reconciler -FixtureHome $script:FixtureHome -PaseoExe $stub.Path -BootTime $script:Boot
        $second.Output | Should -Not -Match 'RESUMED lane-c'
        @(Get-Content $stub.Log).Count | Should -Be 1
    }
}

Describe 'Resume-PaseoAgents -WriteRoster' -Tag 'cl-paseo' {
    BeforeEach {
        $script:FixtureHome = Join-Path $TestDrive ('home-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:FixtureHome -Force | Out-Null
        $script:Boot = '2026-11-13T16:37:35.0000000+00:00'
        $script:PrevBoot = '2026-11-12T21:24:44.0000000+00:00'
    }

    It 'records only running agents, stamped with the current boot' {
        New-FixtureHome -Root $script:FixtureHome -Records @(
            @{ id = 'a-run'; status = 'running' }
            @{ id = 'a-init'; status = 'initializing' }
            @{ id = 'a-idle'; status = 'idle' }
            @{ id = 'a-arch'; status = 'running'; archived = (Get-Date).ToUniversalTime() }
        ) | Out-Null
        $r = Invoke-Reconciler -FixtureHome $script:FixtureHome -BootTime $script:Boot -WriteRoster
        $r.ExitCode | Should -Be 0
        $doc = Get-Content (Join-Path $script:FixtureHome 'running-roster.json') -Raw | ConvertFrom-Json
        @($doc.agents.id | Sort-Object) | Should -Be @('a-init', 'a-run')
        ([DateTimeOffset]$doc.bootAt).UtcTicks | Should -Be ([DateTimeOffset]::Parse($script:Boot)).UtcTicks
    }

    It 'moves a previous-boot roster aside before the first write of a new boot' {
        New-FixtureHome -Root $script:FixtureHome -Records @(@{ id = 'x'; status = 'idle' }) | Out-Null
        New-Roster -Home_ $script:FixtureHome -BootAt $script:PrevBoot -At (Get-Date).AddMinutes(-5) -Ids @('lane-c')
        Invoke-Reconciler -FixtureHome $script:FixtureHome -BootTime $script:Boot -WriteRoster | Out-Null
        $pre = Get-Content (Join-Path $script:FixtureHome 'running-roster.preboot.json') -Raw | ConvertFrom-Json
        @($pre.agents.id) | Should -Be @('lane-c')
        # a second write in the same boot must not clobber the pre-boot copy
        Invoke-Reconciler -FixtureHome $script:FixtureHome -BootTime $script:Boot -WriteRoster | Out-Null
        $pre = Get-Content (Join-Path $script:FixtureHome 'running-roster.preboot.json') -Raw | ConvertFrom-Json
        @($pre.agents.id) | Should -Be @('lane-c')
    }
}