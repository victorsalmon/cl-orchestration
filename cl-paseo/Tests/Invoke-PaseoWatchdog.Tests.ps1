Describe 'Paseo watchdog cutover state' {
    BeforeAll {
        $watchdog = Join-Path $PSScriptRoot '..\scripts\Invoke-PaseoWatchdog.ps1'
        $pwsh = Join-Path $PSHOME 'pwsh.exe'
        function Invoke-FixtureWatchdog {
            & $pwsh -NoProfile -File $watchdog -StateDir $TestDrive -ProbeOnly | ConvertFrom-Json
        }
    }

    BeforeEach {
        $at = [DateTimeOffset]::UtcNow.ToString('o')
        $outcomePath = Join-Path $TestDrive 'fixture-cutover.json'
        @{ outcomePath = $outcomePath; runId = 'fixture'; at = $at } |
            ConvertTo-Json | Set-Content (Join-Path $TestDrive 'recovery-needed.json')
        @{
            applied = $true; verified = 'pending'; restartPending = $true
            runId = 'fixture'; reason = 'restart-pending'
        } | ConvertTo-Json | Set-Content $outcomePath
    }

    It 'does not treat a pending verification string as success' {
        $result = Invoke-FixtureWatchdog
        $result.code | Should -Be 'cutover-unverified'
        $result.alert | Should -BeTrue
        Test-Path (Join-Path $TestDrive 'recovery-needed.json') | Should -BeTrue
        Test-Path (Join-Path $TestDrive 'paseo-watchdog.json') | Should -BeFalse
    }

    It 'requests a Windows reboot when the original listener was stuck' {
        @{
            applied = $true; verified = $false; restartPending = $false
            runId = 'fixture'; reason = 'paseo-reboot-required'
        } | ConvertTo-Json | Set-Content $outcomePath
        $result = Invoke-FixtureWatchdog
        $result.code | Should -Be 'reboot-required'
        $result.alert | Should -BeTrue
    }

    It 'leaves a fresh cutover alone' {
        @{ runId = 'fixture'; startedAt = $at } |
            ConvertTo-Json | Set-Content (Join-Path $TestDrive 'cutover-in-progress.json')
        $result = Invoke-FixtureWatchdog
        $result.code | Should -Be 'cutover-in-progress'
        $result.alert | Should -BeFalse
    }
}
