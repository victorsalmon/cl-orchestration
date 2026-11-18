BeforeAll {
    $script:Health = (Resolve-Path (Join-Path $PSScriptRoot '..' 'scripts' 'Test-RepoHealth.ps1')).Path
}

Describe 'Test-RepoHealth.ps1 (the base repo-state probes)' {
    It 'exists, parses, and is the file Get-HealthReport borrows' {
        # Restored 2026-11-16: it had never landed on dev, so Get-HealthReport's
        # six state probes were silently skipped (cl-common-zh1l sibling finding).
        Test-Path -LiteralPath $script:Health | Should -BeTrue
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:Health, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
    }

    It 'emits a probes array and a verdict as JSON against a real checkout' {
        $repo = Join-Path $TestDrive 'repo'
        $null = New-Item -ItemType Directory -Path $repo -Force
        & git -C $repo init --initial-branch=dev --quiet 2>&1 | Out-Null
        & git -C $repo -c user.name=pester -c user.email=pester@test commit --allow-empty -m base --quiet 2>&1 | Out-Null

        $raw = & pwsh -NoProfile -File $script:Health -RepoRoot $repo -Json 2>&1 | Out-String
        $exit = $LASTEXITCODE
        # 0/1/2 all carry a verdict; a parse failure would carry none.
        $exit | Should -BeIn @(0, 1, 2)
        $payload = $raw.Substring($raw.IndexOf('{')) | ConvertFrom-Json
        $payload.verdict | Should -Not -BeNullOrEmpty
        @($payload.probes).Count | Should -BeGreaterThan 0
    }
}
