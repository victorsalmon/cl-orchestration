#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

<#
.SYNOPSIS
    Two rules this probe got wrong, and the tests that keep them fixed.

    1. LOCK-HEALTH: liveness is HEARTBEAT-BASED, never PID-BASED.

    The lock contract (cl-common-0co.26) records the pid of the short-lived shell that
    WROTE the lock, not of the session holding it. Judging by that pid makes "pid alive"
    lie in both directions: a live lock can carry a dead pid, and an expired lock can
    carry a live one.

    This probe originally broke that rule and FAILed healthy locks all session - and once
    led the Hub to force-release a lock whose heartbeat was still fresh. The tests below
    pin the corrected behaviour: expiry decides, a dead recorded pid is advisory only.

    2. QUEUE-EVIDENCE: a missing or unreadable queue is never a FAIL.

    Measured 2026-11-16 on cl-common: the probe asked the classifier for its DEFAULT
    queue, which was hard-coded to currents-bookkeeping's filename. The classifier
    exited 2 with "no queue at ..." on stderr; the probe ignored the exit code, filtered
    stderr out, parsed the EMPTY stdout into $null, and counted @($null) as ONE queued
    row - reporting FAIL with evidence "=". On a repo that has no queue at all that was
    a red with nothing behind it. The tests below pin SKIP for a missing queue,
    CANNOT-EVALUATE for a classifier that cannot produce JSON, and FAIL only for parsed
    rows whose reports name no tip.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'scripts' 'Test-RepoHealth.Additions.ps1') -LibraryOnly
}

Describe 'Format-BranchSummary' {
    It 'renders the total and every non-zero class' {
        $branches = [pscustomobject]@{
            total = 3; reconciled = $true
            classes = [pscustomobject]@{ permanent = 1; merged = 1; 'lane-active' = 1; parked = 0 }
        }
        Format-BranchSummary $branches | Should -Be 'branches 3 (permanent 1, merged 1, lane-active 1)'
    }

    It 'marks a plan whose counts do not reconcile' {
        $branches = [pscustomobject]@{ total = 2; reconciled = $false; classes = [pscustomobject]@{ merged = 2 } }
        Format-BranchSummary $branches | Should -Be 'branches 2 (merged 2) UNRECONCILED'
    }

    It 'never invents a count when the inventory is missing' {
        Format-BranchSummary $null | Should -Be 'branches unknown'
    }
}

Describe 'Get-LockVerdict' {
    BeforeEach {
        $script:now = [datetime]::new(2026, 11, 15, 8, 0, 0, [System.DateTimeKind]::Utc)
    }

    It 'passes a lock whose recorded pid is dead but whose expiry is still in the future' {
        $lock = [pscustomobject]@{ pid = 999999; acquiredAt = '2026-11-15T06:25:21Z'; expiresAt = '2026-11-15T09:00:00Z' }
        $v = Get-LockVerdict -Lock $lock -HolderStartUtc $null -NowUtc $script:now
        $v.Status | Should -Be 'PASS'
        $v.Why | Should -Match 'advisory only'
    }

    It 'FAILS a lock whose expiry has passed, whatever its pid says' {
        $lock = [pscustomobject]@{ pid = $PID; acquiredAt = '2026-11-15T06:25:21Z'; expiresAt = '2026-11-15T07:15:52Z' }
        $v = Get-LockVerdict -Lock $lock -HolderStartUtc $null -NowUtc $script:now
        $v.Status | Should -Be 'FAIL'
        $v.Why | Should -Match 'expired'
    }

    It 'FAILS an expired lock even when the recorded pid is a live process' {
        $lock = [pscustomobject]@{ pid = $PID; acquiredAt = '2026-11-15T06:25:21Z'; expiresAt = '2026-11-15T07:00:00Z' }
        $v = Get-LockVerdict -Lock $lock -HolderStartUtc ([datetime]::new(2026, 11, 15, 6, 20, 0, [System.DateTimeKind]::Utc)) -NowUtc $script:now
        $v.Status | Should -Be 'FAIL'
    }

    It 'judges an identity claim (no pid by design) by its expiry' {
        $claim = [pscustomobject]@{ ownerAgentId = 'hub'; state = 'mine'; expiresAt = '2026-11-15T09:30:00Z' }
        $v = Get-LockVerdict -Lock $claim -HolderStartUtc $null -NowUtc $script:now
        $v.Status | Should -Be 'PASS'
        $v.Why | Should -Match 'no pid by design'
    }

    It 'FAILs an expired identity claim - nothing renewed it' {
        $claim = [pscustomobject]@{ ownerAgentId = 'hub'; state = 'mine'; expiresAt = '2026-11-15T06:00:00Z' }
        $v = Get-LockVerdict -Lock $claim -HolderStartUtc $null -NowUtc $script:now
        $v.Status | Should -Be 'FAIL'
    }

    It 'passes an unexpired lock and reports it as not expired' {
        $fresh = [pscustomobject]@{ pid = 1; acquiredAt = '2026-11-15T07:59:00Z'; expiresAt = '2026-11-15T09:00:00Z' }
        $v = Get-LockVerdict -Lock $fresh -HolderStartUtc $null -NowUtc $script:now
        $v.Status | Should -Be 'PASS'
        $v.Expired | Should -BeFalse
    }

    It 'treats a lock with no expiry as held rather than guessing' {
        $lock = [pscustomobject]@{ pid = 1; acquiredAt = '2026-11-15T07:59:00Z' }
        $v = Get-LockVerdict -Lock $lock -HolderStartUtc $null -NowUtc $script:now
        $v.Status | Should -Be 'PASS'
        $v.Why | Should -Match 'no expiry recorded'
    }
}

Describe 'Get-MergeQueuePath' {
    It 'resolves the queue the repo owns' {
        Get-MergeQueuePath -RepoRoot 'E:\repos\cl-common' |
            Should -Be (Join-Path 'E:\repos\cl-common' '.iqa\merge-queue\cl-common.jsonl')
    }

    It 'never hands a repo another repo''s queue file' {
        Get-MergeQueuePath -RepoRoot 'E:\repos\cl-common' | Should -Not -Match 'currents-bookkeeping'
        Get-MergeQueuePath -RepoRoot 'C:\tmp\probe-fixture\' | Should -Match 'merge-queue\\probe-fixture\.jsonl$'
    }
}

Describe 'Get-QueueEvidenceVerdict' {
    BeforeEach {
        $script:queue = Join-Path (Join-Path $TestDrive 'merge-queue') 'cl-common.jsonl'
    }

    It 'SKIPs a repo with no merge queue, naming the path - it does not FAIL it' {
        $v = Get-QueueEvidenceVerdict -QueuePath $script:queue -QueueExists $false
        $v.Status | Should -Be 'SKIP'
        $v.Measured | Should -Match 'no merge queue'
        $v.Evidence | Should -Match ([regex]::Escape($script:queue))
    }

    It 'CANNOT-EVALUATEs a classifier that exits non-zero, naming what it printed' {
        $v = Get-QueueEvidenceVerdict -QueuePath $script:queue -ExitCode 1 -Stdout '' `
            -Stderr 'classify-unproven: cannot read the ledger'
        $v.Status | Should -Be 'CANNOT-EVALUATE'
        $v.Measured | Should -Match 'exited 1'
        $v.Evidence | Should -Match 'cannot read the ledger'
    }

    It 'still FAILs genuine queued rows that prove no tip' {
        $json = '{"rows":[{"branch":"fix/unproven","report":"none"},{"branch":"fix/stale","report":"stale:INCOMPLETE"}]}'
        $v = Get-QueueEvidenceVerdict -QueuePath $script:queue -ExitCode 0 -Stdout $json
        $v.Status | Should -Be 'FAIL'
        $v.Measured | Should -Match '^2 queued'
        $v.Evidence | Should -Match 'fix/unproven=none'
        $v.Evidence | Should -Match 'fix/stale=stale:INCOMPLETE'
    }

    It 'WARNs when some rows prove their tip and others do not' {
        $json = '{"rows":[{"branch":"fix/unproven","report":"none"},{"branch":"fix/proven","report":"TIP:COMPLETE"}]}'
        (Get-QueueEvidenceVerdict -QueuePath $script:queue -ExitCode 0 -Stdout $json).Status | Should -Be 'WARN'
    }

    It 'never fabricates a queued row from empty output - the @($null) count-1 defect' {
        $v = Get-QueueEvidenceVerdict -QueuePath $script:queue -ExitCode 0 -Stdout "   `n"
        $v.Status | Should -Be 'CANNOT-EVALUATE'
        $v.Measured | Should -Not -Match '1 queued'
        $v.Evidence | Should -Not -Be '='
    }

    It 'CANNOT-EVALUATEs a non-JSON body, naming what was printed' {
        $v = Get-QueueEvidenceVerdict -QueuePath $script:queue -ExitCode 0 -Stdout 'classify-unproven: no queue'
        $v.Status | Should -Be 'CANNOT-EVALUATE'
        $v.Evidence | Should -Match 'no queue'
    }

    It 'CANNOT-EVALUATEs JSON that is not a rows document' {
        $v = Get-QueueEvidenceVerdict -QueuePath $script:queue -ExitCode 0 -Stdout '"no queue here"'
        $v.Status | Should -Be 'CANNOT-EVALUATE'
        $v.Measured | Should -Match 'no rows array'
    }

    It 'PASSes an empty queue and a queue whose tips are all proven' {
        (Get-QueueEvidenceVerdict -QueuePath $script:queue -Stdout '{"rows":[]}').Status | Should -Be 'PASS'
        $proven = '{"rows":[{"branch":"fix/done","report":"TIP:COMPLETE"}]}'
        (Get-QueueEvidenceVerdict -QueuePath $script:queue -Stdout $proven).Status | Should -Be 'PASS'
    }
}
