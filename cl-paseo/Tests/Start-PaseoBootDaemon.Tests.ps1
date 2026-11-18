#Requires -Version 7.0
# cl-common-9m9y: the boot launcher must leave evidence on C: for every failure,
# including one before the boot log is written, and must stay self-contained so a
# staged copy outside the repo runs on its own.

BeforeAll {
    $script:Launcher = Join-Path $PSScriptRoot '..\scripts\Start-PaseoBootDaemon.ps1'
    $script:Pwsh = (Get-Process -Id $PID).Path

    function Invoke-Launcher([string]$PaseoHome, [string]$PaseoExe) {
        # Run a STAGED copy from an unrelated folder: proves no sibling lookups.
        $stage = Join-Path $TestDrive ("stage-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stage | Out-Null
        $copy = Join-Path $stage 'Start-PaseoBootDaemon.ps1'
        Copy-Item -LiteralPath $script:Launcher -Destination $copy
        & $script:Pwsh -NoProfile -NonInteractive -File $copy -PaseoHome $PaseoHome -PaseoExe $PaseoExe *> $null
        return $LASTEXITCODE
    }

    function New-FakeCli([int]$ExitCode) {
        $path = Join-Path $TestDrive ("fake-paseo-$ExitCode-" + [guid]::NewGuid().ToString('N') + '.cmd')
        Set-Content -LiteralPath $path -Value "@echo off`r`necho fake daemon stderr 1>&2`r`nexit /b $ExitCode" -Encoding ascii
        return $path
    }

    function New-PaseoHome {
        $h = Join-Path $TestDrive ("home-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $h | Out-Null
        return $h
    }
}

Describe 'Start-PaseoBootDaemon (boot launcher)' {
    It 'logs to the C: error log and exits 1 when the Paseo CLI is missing' {
        $h = New-PaseoHome
        $code = Invoke-Launcher -PaseoHome $h -PaseoExe (Join-Path $TestDrive 'no-such-paseo.cmd')
        $code | Should -Be 1
        $err = Join-Path $h 'daemon-boot-error.log'
        $err | Should -Exist
        (Get-Content $err -Raw) | Should -Match 'launcher failed: Paseo CLI not found'
    }

    It 'writes the boot log, rotates the previous one, and passes a clean exit through' {
        $h = New-PaseoHome
        Set-Content -LiteralPath (Join-Path $h 'daemon-boot.log') -Value 'older boot'
        $code = Invoke-Launcher -PaseoHome $h -PaseoExe (New-FakeCli 0)
        $code | Should -Be 0
        (Get-Content (Join-Path $h 'daemon-boot.log') -Raw) | Should -Match 'Starting Paseo in Windows session'
        (Get-Content (Join-Path $h 'daemon-boot.log.previous') -Raw) | Should -Match 'older boot'
        (Get-Content (Join-Path $h 'daemon-boot.log') -Raw) | Should -Match 'fake daemon stderr'
    }

    It 'passes a daemon failure exit code through and records it in the error log' {
        $h = New-PaseoHome
        $code = Invoke-Launcher -PaseoHome $h -PaseoExe (New-FakeCli 3)
        $code | Should -Be 3
        (Get-Content (Join-Path $h 'daemon-boot-error.log') -Raw) | Should -Match 'paseo daemon run exited 3'
    }
}
