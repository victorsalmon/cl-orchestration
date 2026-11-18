---
name: update-paseo
description: >
  The Paseo update runbook behind `Update Check`: after any Paseo upgrade or a
  restart that followed one, run the 17-row battery that proves the fleet's CLI
  surface, config schema, provider/model pins, stored records, canary dispatch,
  health probes, script parsing, Pester suite, harness pointers, boot tasks and
  MCP wiring still work, then record the version transition. Trigger words:
  "update-paseo", "Paseo update broke", "did the Paseo upgrade break",
  "paseo 0.16", "verify Paseo upgrade".
triggers:
  - user
  - model
  - update paseo
  - paseo update
  - post-upgrade
---

# update-paseo — Paseo upgrade verification runbook

A Paseo upgrade changes the runtime every harness, lane and schedule on this box
goes through. The failure mode is quiet: the app opens, the daemon answers, and
one flag a dispatcher passes stopped existing three versions ago. This runbook
replaces "does it look broken?" with one repeatable battery and a recorded
verdict.

Run it through the `Update Check` command, which is how the fleet invokes it:

```powershell
pwsh -NoProfile -File "$env:CL_REPOS_ROOT\cl-common\Skills\update-check\scripts\Invoke-UpdateCheck.ps1" -Runbook update-paseo
```

Run it directly when you are working on the runbook itself:

```powershell
pwsh -NoProfile -File "$env:CL_REPOS_ROOT\cl-common\vendor\cl-orchestration\cl-paseo\skills\update-paseo\scripts\Test-UpdatePaseo.ps1"
```

**When:** after every Paseo upgrade, and after any restart that followed one.
Cheap path while nothing is suspected: `-SkipCanary -SkipTests` (about 30s). Full
run including the canary dispatch and the Pester suite: 3–6 minutes.

| Flag | Effect |
| :--- | :--- |
| `-Json` | machine-readable result object (for a scheduled gate) |
| `-Strict` | WARN also exits 1 (unattended gates) |
| `-Detailed` | show remedy + evidence for PASS rows too |
| `-SkipCanary` | do not dispatch the throwaway canary agent |
| `-SkipTests` | do not run the cl-paseo Pester suite |
| `-SkipSurface` | do not run the static CLI surface scan |
| `-CanaryProvider` / `-CanaryModel` | choose the canary agent (default opencode + `opencode-go/deepseek-v4.1-flash`) |
| `-ScanRoots` | override the trees scanned for literal `paseo <verb>` calls |

Exit 0 means nothing is broken; exit 1 means a FAIL row exists; exit 2 means the
runbook could not evaluate.

## What it checks, and why each row exists

Ordered cheapest-first, so an early FAIL saves the expensive rows.

| # | Check | The question it answers |
| :--- | :--- | :--- |
| 01 | `VERSION` | do the CLI, daemon and desktop bundle report one version? Skew means a script talks to a different Paseo than the app. |
| 02 | `DAEMON` | running, reachable, and listening where the config says? |
| 03 | `CONFIG` | does `config.json` still parse and keep the shape Paseo needs (`version`, `daemon`, `agents.providers`)? |
| 04 | `ENV-RULE` | is a credential pinned in `agents.providers.*.env`? On ≥ 0.15.3 an opencode credential pin is fatal with a shared opencode service. |
| 05 | `RELOAD` | does `paseo reload` accept the file? |
| 06 | `CLI-SURFACE` | does every `paseo <verb>` the fleet invokes still exist? |
| 07 | `CLI-FLAGS` | does every flag the fleet passes still exist? A proven-removed flag is a FAIL. |
| 08 | `PROVIDERS` | is every enabled provider available? |
| 09 | `MODELS` | does every pinned `additionalModel` and agent-profile model id still resolve? Model renames are the most common silent break. |
| 10 | `RECORDS` | do stored agent, schedule and project records still parse, and do the four listing commands answer JSON? |
| 11 | `DISPATCH` | can a throwaway agent be created, listed and archived? The only row that proves provider auth end to end. |
| 12 | `HEALTH` | do the nine `Test-PaseoHealth` probes pass? A probe that only WARNs is reported as drift. |
| 13 | `SCRIPT-PARSE` | does every fleet `.ps1` still parse (AST only, nothing executed)? |
| 14 | `PESTER` | is the cl-paseo suite green? A test that mocked the old CLI shape fails here. |
| 15 | `HARNESS` | do skill pointers still resolve across harnesses? |
| 16 | `BOOT` | are the Paseo scheduled tasks present and enabled? |
| 17 | `MCP` | does the MCP injection setting hold and do configured server commands resolve? |

## How to read the verdict

- **FAIL** — the new version broke a dependency. Fix before dispatching work;
  the row names the file, line and flag, or the provider and model id.
- **WARN** — drift, not breakage: a doc claims a flag that changed, a credential
  is pinned on a non-opencode provider, or a health probe still encodes a
  pre-upgrade rule. Confirm, then fix the claim or the probe.
- **SKIP** — nothing to measure (no harness MCP config, `-SkipCanary`, …). A
  SKIP is never evidence that something works.

The run is recorded at
`~\.machine\state\update-check\update-paseo\<stamp>-<version>.json`, and
`last.json` holds the most recent one. The next run names the transition
(`0.15.4 -> 0.16.1`) in the report header and in `Transition` under `-Json`.

## What it deliberately does not cover

- **A product repo's CI battery, deploy or test suite.** This checks the harness
  layer; run those in the repo under change.
- **Remote hosts.** `paseo host ls` targets are not probed; run the battery on
  each host.
- **Non-literal invocations.** A script that runs `& $paseoCli run …` through a
  variable is invisible to the text scan. `SCRIPT-PARSE`, `PESTER` and
  `DISPATCH` are what cover it.
- **Behaviour changes with no CLI surface.** A changed default or output shape
  only shows up in `DISPATCH`, `RECORDS` and the product suites.

## Step by step

1. Run the battery. Do not pre-run `Test-PaseoHealth` separately — row 12 does it.
2. Report the verdict table as-is: counts, then every FAIL and WARN row with its
   remedy. Do not summarise a FAIL into "mostly fine".
3. Classify each FAIL before touching anything:
   - a **removed verb or flag** → update the calling script (same class as
     `paseo run --background` disappearing in favour of `--no-wait`);
   - a **model id that no longer resolves** → repoint the profile using
     `paseo provider models <provider> --json`;
   - a **config/env rule** → fix the provider block, then `Repair-Paseo.ps1`;
   - a **record or listing failure** → stop; back up `~\.paseo` before anything
     writes to it.
4. Fix in the owning repo, re-run to green, then commit. Never silence a check
   to make the report green: a FAIL row is the finding.
5. If the transition changed behaviour the fleet depends on, record the fact in
   the owning runbook (`cl-paseo` REFERENCE, `paseo-config`, or the calling
   skill) in the same change set.

## Remediation map

| Symptom | First move |
| :--- | :--- |
| `VERSION` skew | restart the Paseo app so CLI, daemon and bundle come from one install |
| `DAEMON` down | `Test-PaseoHealth.ps1`, then `Repair-PaseoHealth.ps1`, then the app |
| `CONFIG` shape changed | restore the newest `~\.paseo\config.json.bak-*`; re-add what the new schema needs |
| `ENV-RULE` opencode credential pin | `Repair-Paseo.ps1` (removes the pin on ≥ 0.15.3); keys stay in User scope |
| `CLI-FLAGS` removed flag | update the invoking script to the current flag |
| `MODELS` unresolved id | repoint the profile to an id from `paseo provider models <id> --json` |
| `RECORDS` unreadable file | back up `~\.paseo` first; then let Paseo migrate or restore from `~\.machine\backups` |
| `DISPATCH` cannot create an agent | `paseo provider diagnostic <provider>`; check the key lane before redispatching |
| `HEALTH` SERVICE-COLLISION | a stale `~\.local\state\opencode\service.json` with a dead pid: move it to `~\.machine\backups`, never delete blindly |
| `HARNESS` drift | `Invoke-HarnessInstall.ps1` (no `-Verify`) to converge pointers |
| `BOOT` missing task | `Fix-PaseoBootTask.ps1 -WithResumeTask` |

## Tests

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path '$env:CL_REPOS_ROOT\cl-common\vendor\cl-orchestration\cl-paseo\Tests\UpdatePaseo.Tests.ps1'"
```

The suite pins the deterministic half: help parsing, the invocation scan (code
vs comment vs here-string), the shared-service env rule, record parsing, verdict
aggregation and the report. The live half is proven by running the battery.

## Reference

Measured findings from the 0.15.4 → 0.16.1 transition, ranked by what actually
breaks, and the two checker defects found while measuring:
[REFERENCE.md](REFERENCE.md).
