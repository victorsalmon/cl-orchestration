# update-paseo — reference

Measured detail behind the battery. Everything here was observed on this box;
re-measure after a Paseo upgrade rather than trusting the numbers.

## Measured: 0.15.4 → 0.16.1 (2026-11-18)

The upgrade itself (a desktop-app update, then a restart) kept the fleet green.
The battery's first full run reported 15 PASS / 2 WARN / 0 FAIL, and the two
WARNs are pre-existing drift rather than upgrade damage:

| Row | Result | What it actually was |
| :--- | :--- | :--- |
| `VERSION` | PASS | CLI, daemon and `Paseo.exe` all `0.16.1` — no skew after the restart |
| `DAEMON` | PASS | daemon restarted 09:27Z after the credential cutover; worker pid present |
| `CONFIG` | PASS | config `version: 1`; providers live at `agents.providers.*` (not top level) |
| `ENV-RULE` | WARN | `openrouter.env.OPENROUTER_API_KEY` is pinned in config. Not the fatal opencode case, so WARN |
| `CLI-SURFACE` | PASS | 870 literal invocations across 14 roots; every verb still advertised |
| `CLI-FLAGS` | PASS | every flag used next to an advertised verb still exists |
| `PROVIDERS` | PASS | opencode, codex, claude, gemini, openrouter all available |
| `MODELS` | PASS | 7 pinned profile/`additionalModel` ids resolve |
| `RECORDS` | PASS | ~5570 record files parse; agent/schedule/workspace/project listings answer |
| `DISPATCH` | PASS | canary agent created, listed, archived |
| `HEALTH` | WARN | `KEY-PROVIDER-MATCH` still warns "no pinned OPENCODE_GO_KEY", which is the *required* state on ≥0.15.3 |
| `SCRIPT-PARSE` | PASS | 322 `.ps1` files parse |
| `PESTER` | PASS | cl-paseo suite green |
| `HARNESS` | PASS | pointers resolve |
| `BOOT` | PASS | `Paseo Daemon`, `Paseo Daemon Ensure` present and enabled |
| `MCP` | SKIP | no harness MCP server config on this box; Paseo `mcp.injectIntoAgents=true` only |

Two real defects were found and fixed while measuring, both in the checker:

1. **Flags were attributed to the wrong invocation.** Catching everything to the
   end of the line meant `… via paseo send --no-wait.` inside a `paseo heartbeat
   create` paragraph reported `heartbeat create --no-wait`. The scan now stops a
   tail at the next `paseo` token, a backtick, or a table bar.
2. **Provider model ids are JSON-encoded pairs.** `paseo provider models
   <id> --json` returns `"id": "[\"openrouter\",\"~deepseek/deepseek-v4-flash-latest\"]"`,
   a string containing a two-element array. Comparing a profile's model against
   that raw string false-fails; the check now parses the pair and accepts either
   the joined form or the model segment.

## Measured: what an upgrade actually breaks

Ranked by how often it has bitten this fleet, not by severity.

1. **A flag that no longer exists.** `paseo run -d/--background` is gone in
   0.16.1; `--no-wait` is the current spelling. A removed option fails at
   argument parsing, so the dispatch never starts. This is why flags are checked
   against live `--help` output rather than against the skill text.
2. **A model id that no longer resolves.** Providers rename models; a pinned
   `additionalModel` or agent profile then fails on spawn. The battery proves
   each pinned id against `paseo provider models`.
3. **A config schema move.** `providers` moved under `agents.providers`; scripts
   that write the old top-level key silently stop having any effect. The config
   check asserts the current shape rather than "JSON parses".
4. **A credential pinned where the new runtime forbids it.** From 0.15.3 the
   opencode runtime refuses a custom credential in `agents.providers.opencode.env`
   while sharing an opencode service. `Repair-Paseo.ps1` removes the pin; keys
   live in User scope so every launch re-reads them.
5. **A stale shared-service file.** `~\.local\state\opencode\service.json`
   pointing at a dead pid makes the collision probe fail and is the classic
   post-restart surprise. Move it to `~\.machine\backups`; do not delete
   `~/.*/` credential folders (machine rule).

## Why a canary, and why it is archived immediately

`paseo provider ls` proves a provider is *configured*; it does not prove a
request reaches the model. The canary creates one agent with a two-word prompt,
confirms it appears in `paseo ls --json`, then archives it with `--force`
(archiving a still-running agent without `--force` exits 1 — that was measured).
The agent is titled `update-paseo canary` so a missed cleanup is findable.

## State and history

- `~\.machine\state\update-check\<yyyyMMddTHHmmssZ>-<version>.json` — one file per run.
- `~\.machine\state\update-check\last.json` — most recent run; the next run reads
  its `Version` to report the transition.
- Records are small JSON; prune them like other machine state when the folder
  grows, keeping the run that first recorded each version.

## Extending the battery

Add a row only if it can answer "did the upgrade break this?" with evidence a
reader can check. Keep the contract: `PASS`/`WARN`/`FAIL`/`SKIP`, a one-line
detail, a remedy, and evidence as `file:line` or `provider/model`. Row ids are
stable so a scheduled gate can diff them across runs. New deterministic logic
belongs in `scripts/lib/UpdatePaseo.ps1` with a test in
`vendor/cl-orchestration/cl-paseo/Tests/UpdatePaseo.Tests.ps1`; the orchestration in
`scripts/Test-UpdatePaseo.ps1` stays thin.
