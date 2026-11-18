#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

<#
.SYNOPSIS
    WORKER-HEARTBEAT: a live pid is not a live worker, and one instance is not enough.

    Measured 2026-11-15 (currents-bookkeeping): two merge trains sat 8 and 21 minutes
    with 5.7s of PARENT CPU while their process TREES had spent 53.1s running
    `node --test scripts/tests/iqa-merge-runner.test.mjs` as the gate. The box was not
    pinned (32 cores; Defender the top consumer). Nobody could see the phase, and two
    trains ran at once - the one-merge-lane rule - because nothing counted instances.

    Pinned here: a beat must be FRESH (3 intervals), the pid must still be alive unless
    the beat says `done`, two live instances of one label is a FAIL, and a runner with no
    beat at all is a WARN (instrument it) rather than a silent pass.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'scripts' 'Test-RepoHealth.Additions.ps1') -LibraryOnly
    $script:scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'scripts' 'Test-RepoHealth.Additions.ps1')).Path
}

Describe 'WORKER-HEARTBEAT' {
    BeforeEach {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("repohealth-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path (Join-Path $script:tmp 'merge-runner') -Force | Out-Null
        $env:MACHINE_STATE_HOME = $script:tmp
    }
    AfterEach {
        Remove-Item Env:MACHINE_STATE_HOME -ErrorAction SilentlyContinue
        Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'passes with no beat, and WARNs if a runner is live but uninstrumented' {
        $out = & pwsh -NoProfile -File $script:scriptPath -RepoRoot $env:TEMP -Probe WORKER-HEARTBEAT -Json | Out-String
        $r = ($out | ConvertFrom-Json).probes | Where-Object { $_.Id -eq 'WORKER-HEARTBEAT' }
        # The probe scans the whole machine, so on a busy box a live runner without a
        # beat correctly reads WARN ("instrument it"). Both are acceptable when no beat
        # file exists; a FAIL would not be.
        $r.Status | Should -BeIn @('PASS', 'WARN')
        if ($r.Status -eq 'WARN') { $r.Measured | Should -Match 'no heartbeat' }
    }

    It 'FAILS a beat whose pid is alive but which has stopped beating' {
        $file = Join-Path $script:tmp 'merge-runner\cbk.heartbeat.json'
        @{
            v = 1; label = 'cbk'; repo = 'cbk'; instanceId = 'a'; pid = $PID
            updatedAt = (Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o')
            intervalSeconds = 180; verdict = 'working'; phase = 'gating'; treeCpuDelta = 0.1; repeats = 0
        } | ConvertTo-Json | Set-Content -LiteralPath $file
        $out = & pwsh -NoProfile -File $script:scriptPath -RepoRoot $env:TEMP -Probe WORKER-HEARTBEAT -Json | Out-String
        $r = ($out | ConvertFrom-Json).probes | Where-Object { $_.Id -eq 'WORKER-HEARTBEAT' }
        $r.Status | Should -Be 'FAIL'
        $r.Evidence | Should -Match 'no beat for'
    }

    It 'FAILS a stalled verdict' {
        $file = Join-Path $script:tmp 'merge-runner\cbk.heartbeat.json'
        @{
            v = 1; label = 'cbk'; repo = 'cbk'; instanceId = 'a'; pid = $PID
            updatedAt = (Get-Date).ToUniversalTime().ToString('o')
            intervalSeconds = 180; verdict = 'stalled'; phase = 'gating'; treeCpuDelta = 0.05; repeats = 3
        } | ConvertTo-Json | Set-Content -LiteralPath $file
        $out = & pwsh -NoProfile -File $script:scriptPath -RepoRoot $env:TEMP -Probe WORKER-HEARTBEAT -Json | Out-String
        $r = ($out | ConvertFrom-Json).probes | Where-Object { $_.Id -eq 'WORKER-HEARTBEAT' }
        $r.Status | Should -Be 'FAIL'
        $r.Evidence | Should -Match 'STALLED'
    }

    It 'FAILS an orphaned beat: pid gone but the last beat does not say done' {
        $file = Join-Path $script:tmp 'merge-runner\cbk.heartbeat.json'
        @{
            v = 1; label = 'cbk'; repo = 'cbk'; instanceId = 'a'; pid = 999999
            updatedAt = (Get-Date).ToUniversalTime().ToString('o')
            intervalSeconds = 180; verdict = 'working'; phase = 'merging'; treeCpuDelta = 1.0; repeats = 0
        } | ConvertTo-Json | Set-Content -LiteralPath $file
        $out = & pwsh -NoProfile -File $script:scriptPath -RepoRoot $env:TEMP -Probe WORKER-HEARTBEAT -Json | Out-String
        $r = ($out | ConvertFrom-Json).probes | Where-Object { $_.Id -eq 'WORKER-HEARTBEAT' }
        $r.Status | Should -Be 'FAIL'
        $r.Evidence | Should -Match 'is gone but the last beat says'
    }

    It 'FAILS two live instances of the same worker label' {
        foreach ($id in @('instance-a', 'instance-b')) {
            @{
                v = 1; label = 'cbk'; repo = 'cbk'; instanceId = $id; pid = $PID
                updatedAt = (Get-Date).ToUniversalTime().ToString('o')
                intervalSeconds = 180; verdict = 'working'; phase = 'gating'; treeCpuDelta = 4.0; repeats = 0
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:tmp "merge-runner\cbk-$id.heartbeat.json")
        }
        $out = & pwsh -NoProfile -File $script:scriptPath -RepoRoot $env:TEMP -Probe WORKER-HEARTBEAT -Json | Out-String
        $r = ($out | ConvertFrom-Json).probes | Where-Object { $_.Id -eq 'WORKER-HEARTBEAT' }
        $r.Status | Should -Be 'FAIL'
        $r.Evidence | Should -Match 'LIVE instances at once'
    }

    It 'passes a fresh, working beat' {
        $file = Join-Path $script:tmp 'merge-runner\cbk.heartbeat.json'
        @{
            v = 1; label = 'cbk'; repo = 'cbk'; instanceId = 'a'; pid = $PID
            updatedAt = (Get-Date).ToUniversalTime().ToString('o')
            intervalSeconds = 180; verdict = 'working'; phase = 'gating'; treeCpuDelta = 6.4; repeats = 0
        } | ConvertTo-Json | Set-Content -LiteralPath $file
        $out = & pwsh -NoProfile -File $script:scriptPath -RepoRoot $env:TEMP -Probe WORKER-HEARTBEAT -Json | Out-String
        $r = ($out | ConvertFrom-Json).probes | Where-Object { $_.Id -eq 'WORKER-HEARTBEAT' }
        $r.Status | Should -Be 'PASS'
    }
}
