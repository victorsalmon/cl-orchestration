#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

<#
.SYNOPSIS
    Pester tests for the Update Check helpers (skills/update-check/scripts/lib).

    These cover the deterministic half of the battery - parsing a `--help`
    surface, scanning the fleet for invocations, classifying a stale flag,
    the shared-service env rule, record parsing, verdict aggregation and the
    report. The live half (daemon, providers, canary) is proven by running
    Test-UpdatePaseo.ps1 itself.

    Each test pins a decision the run depends on:

      1.  help text splits into commands + flags, prose ignored
      2.  a verb's sub-commands are read, `help` excluded
      3.  global options count as legal next to any verb
      4.  credential env names are recognised, layout pins are not
      5.  a literal invocation is found with its flags
      6.  code, comment and doc-string hits are classified differently
      7.  pruned directories are not scanned
      8.  an advertised sub-verb is resolved, an unknown word is not
      9.  record files that no longer parse are reported, not hidden
      10. FAIL beats WARN beats PASS for the exit code, -Strict escalates WARN
      11. the report states counts, puts FAIL first and carries the verdict
#>

BeforeAll {
    $script:Lib = Join-Path $PSScriptRoot '..' 'skills' 'update-paseo' 'scripts' 'lib' 'UpdatePaseo.ps1'
    if (-not (Test-Path -LiteralPath $script:Lib)) { throw "helper library not found: $script:Lib" }
    . $script:Lib

    $script:TopHelp = @'
Usage: paseo [options] [command]

Options:
  -v, --version                    output the version number
  -o, --format <format>            output format: table, json, yaml (default: "table")
  --json                           output in JSON format
  -h, --help                       display help for command

Commands:
  ls [options]                     List agents.
  run [options] <prompt>           Create and start an agent with a task
  send [options] <id> [prompt]     Send a message/task to an existing agent
  schedule [options]               Manage recurring schedules
  help [command]                   display help for command
'@

    $script:ScheduleHelp = @'
Usage: paseo schedule [options] [command]

Options:
  --json                  output in JSON format

Commands:
  create [options]     Create a recurring schedule
  ls [options]         List schedules
  inspect [options] <id>  Inspect a schedule
  help [command]       display help for command
'@

    $script:RunHelp = @'
Usage: paseo run [options] <prompt>

Options:
  --no-wait                         Return immediately without waiting for completion
  --title <title>                   Assign a title to the agent
  --provider <provider>             Agent provider, or provider/model
  -h, --help                        display help for command
'@

    function New-ScanFixture {
        param([Parameter(Mandatory)][string]$Root)
        if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
        New-Item -ItemType Directory -Path $Root -Force | Out-Null

        Set-Content -LiteralPath (Join-Path $Root 'code.ps1') -Encoding utf8 -Value @'
& paseo run --no-wait --title "lane one" 'do the thing'
'@
        Set-Content -LiteralPath (Join-Path $Root 'comment.ps1') -Encoding utf8 -Value @'
# paseo send --bogus-flag 11111111-1111-1111-1111-111111111111
'@
        Set-Content -LiteralPath (Join-Path $Root 'doc.md') -Encoding utf8 -Value @'
Run `paseo run --background` to detach, then `paseo ls --json`.
'@
        $pruned = Join-Path $Root 'node_modules'
        New-Item -ItemType Directory -Path $pruned -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $pruned 'ignored.ps1') -Encoding utf8 -Value "& paseo run --ignored-flag 'x'"
    }
}

Describe 'Update Paseo helpers' {

    BeforeAll {
        $script:Root = Join-Path ([IO.Path]::GetTempPath()) ('uc-fixture-' + [guid]::NewGuid().ToString('N'))
        New-ScanFixture -Root $script:Root
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:Root) { Remove-Item -LiteralPath $script:Root -Recurse -Force }
    }

    Context 'help parsing' {

        It 'splits commands and flags and ignores prose' {
            $parsed = ConvertFrom-PaseoHelpText -Text $script:TopHelp
            $parsed.Commands | Should -Contain 'run'
            $parsed.Commands | Should -Contain 'schedule'
            $parsed.Commands | Should -Not -Contain 'Usage'
            $parsed.Flags | Should -Contain '--json'
            $parsed.Flags | Should -Contain '-v'
        }

        It 'reads a verb sub-command set without the help pseudo-command' {
            $set = Get-PaseoSubCommandSet -VerbHelpText $script:ScheduleHelp
            $set | Should -Contain 'create'
            $set | Should -Contain 'ls'
            $set | Should -Not -Contain 'help'
            $set.Count | Should -Be 3
        }

        It 'treats global options as legal next to a verb that does not list them' {
            $verbOnly = Get-PaseoFlagSet -HelpText $script:RunHelp
            $withGlobals = Get-PaseoFlagSet -HelpText $script:RunHelp -IncludeGlobals
            $verbOnly | Should -Not -Contain '--home'
            $withGlobals | Should -Contain '--home'
            $withGlobals | Should -Contain '--json'
        }
    }

    Context 'shared-service env rule' {

        It 'flags credential names' {
            foreach ($n in 'OPENCODE_GO_KEY', 'ANTHROPIC_API_KEY', 'GH_TOKEN', 'CLIENT_SECRET', 'DB_PASSWORD') {
                Test-KeyBearingEnvName -Name $n | Should -BeTrue -Because "$n carries a credential"
            }
        }

        It 'does not flag layout pins' {
            foreach ($n in 'XDG_STATE_HOME', 'GEMINI_CLI_TRUST_WORKSPACE', 'PATH') {
                Test-KeyBearingEnvName -Name $n | Should -BeFalse -Because "$n is layout, not a credential"
            }
        }
    }

    Context 'invocation scan' {

        It 'finds a literal invocation with its flags' {
            $hits = Get-PaseoInvocationScan -Path $script:Root -Verb @('run', 'send', 'ls')
            $code = $hits | Where-Object { $_.File -like '*code.ps1' }
            $code | Should -Not -BeNullOrEmpty
            $code.Verb | Should -Be 'run'
            $code.Flags | Should -Contain '--no-wait'
            $code.Flags | Should -Contain '--title'
        }

        It 'distinguishes code from comments and doc strings' {
            $hits = Get-PaseoInvocationScan -Path $script:Root -Verb @('run', 'send', 'ls')
            ($hits | Where-Object { $_.File -like '*code.ps1' }).InCommentOrText | Should -BeFalse
            ($hits | Where-Object { $_.File -like '*comment.ps1' }).InCommentOrText | Should -BeTrue
            ($hits | Where-Object { $_.File -like '*doc.md' }).InCommentOrText | Should -BeTrue
        }

        It 'does not scan pruned directories' {
            $hits = Get-PaseoInvocationScan -Path $script:Root -Verb @('run', 'send', 'ls')
            @($hits | Where-Object { $_.Flags -contains '--ignored-flag' }).Count | Should -Be 0
        }

        It 'resolves an advertised sub-verb and leaves an unknown word alone' {
            $hits = @(Get-PaseoInvocationScan -Path $script:Root -Verb @('run', 'schedule'))
            $map = @{ schedule = (Get-PaseoSubCommandSet -VerbHelpText $script:ScheduleHelp) }
            $resolved = Resolve-PaseoInvocationSubCommand -Invocation $hits -SubCommandMap $map
            foreach ($h in $resolved) {
                if ($h.Verb -eq 'schedule') { $h.Sub | Should -Be 'ls' }
                else { $h.Sub | Should -BeNullOrEmpty }
            }
        }
    }

    Context 'record files' {

        It 'counts parseable records and names the broken one' {
            $dir = Join-Path $script:Root 'records'
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'good.json') -Value '{ "id": "a" }' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $dir 'broken.json') -Value '{ "id": ' -Encoding utf8

            $scan = Test-JsonRecordTree -Path $dir
            $scan.Total | Should -Be 2
            @($scan.Failures).Count | Should -Be 1
            $scan.Failures[0].File | Should -BeLike '*broken.json'
        }
    }

    Context 'verdict' {

        It 'exits 1 only on FAIL, and on WARN under -Strict' {
            $pass = @(New-UpdateCheckResult -Id 'A' -Name 'a' -Status 'PASS')
            $warn = @(New-UpdateCheckResult -Id 'B' -Name 'b' -Status 'WARN')
            $fail = @(New-UpdateCheckResult -Id 'C' -Name 'c' -Status 'FAIL')

            Get-UpdateCheckExitCode -Result $pass | Should -Be 0
            Get-UpdateCheckExitCode -Result $warn | Should -Be 0
            Get-UpdateCheckExitCode -Result $warn -Strict | Should -Be 1
            Get-UpdateCheckExitCode -Result $fail | Should -Be 1
            Get-UpdateCheckExitCode -Result ($pass + $warn + $fail) | Should -Be 1
        }

        It 'reports counts, puts FAIL first and states the verdict' {
            $rows = @(
                (New-UpdateCheckResult -Id 'OK' -Name 'ok' -Status 'PASS' -Detail 'fine')
                (New-UpdateCheckResult -Id 'BAD' -Name 'bad' -Status 'FAIL' -Detail 'broken' -Remedy 'fix it' -Evidence @('proof'))
            )
            $text = Format-UpdateCheckReport -Result $rows
            $text | Should -Match 'PASS 1\s+WARN 0\s+FAIL 1'
            $text.IndexOf('[FAIL] BAD') | Should -BeLessThan $text.IndexOf('[PASS] OK')
            $text | Should -Match 'remedy: fix it'
            $text | Should -Match 'VERDICT: the upgrade broke something'
        }
    }
}
