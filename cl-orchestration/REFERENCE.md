# cl-orchestration — reference

Adjacent reference for [SKILL.md](SKILL.md). Moved out of the skill body to
keep `SKILL.md` within the progressive-disclosure budget; content unchanged.

## Moved from SKILL.md

## Order of operations

Fan-out: `subagent-dispatch` (parallel-safe scopes, one durable brief per
worker, `notifyOnFinish: true`) → `paseo-child-agents` if the work must outlive
the chat or a worker misbehaves → verify each completion before integrating.

Backlog: [Work Now](../../../Skills/work-now/SKILL.md) owns repository backlog coordination.
Use [IQA dispatch](../../interactive-qa/members/dispatch/SKILL.md) for
assignment and `task-management` for human-required work.

Interactive: `cowork`, with `cowork-tooling` for the handoff artifacts.

### The cost ladder (measured 2026-11-06)

Verification tiers cost orders of magnitude more than the questions they answer.
Run the cheapest tier that can decide the question, and batch the expensive ones.

| Tier | Cost measured on currents-bookkeeping | Answers |
| :--- | :--- | :--- |
| static / typecheck | seconds | type errors, structure, route parity, workflow order |
| unit (`test:fe`) | ~1 min | component and route logic |
| integration (`test:backend`) | ~30 min (1,756–1,997 s measured) | DB-backed routes |
| live journey (FEQA) | ~20–25 min | deployed behaviour |
| mutation | hours | test strength |

1. **Batch the merge, then test once.** Landing N lanes and running the 30-minute
   suite after each is N×30 minutes for one verdict — the verdict the final tree
   already gives. Merge the batch, then run the expensive tier at the tip.
2. **Never run a higher tier to answer a lower-tier question.** A typecheck
   failure does not need the backend suite; a stale assertion does not need a
   deploy; a docs edit does not need either.
3. **Fail fast on entry-point gates.** A sweep that fails its first navigation or
   sign-in keeps going and manufactures cascades. One measured pass produced 50
   "failures" from a single session defect; asserting the entry point and
   aborting the leg would have cost seconds instead of the full pass.
4. **Deploy once per batch, when the next tier needs live code.** A deploy is
   ~3 minutes plus re-verification; three deploys in one session were three times
   the cost of one.
5. **A read-only survey runs no suites.** Static audit reads gates and code; do
   not spend the integration tier inside recon.
6. **Per-lane installs are not free.** Every worktree pays its own
   `pnpm install`. Prefer fewer, longer lanes when the change sets do not need
   isolation.

Enforced by: every gate claim names the tier that decided it, and the batch
lander's single post-merge run is the evidence for the whole batch.

## Red lines (hard rules)

- **Never start an agent with `cwd` at the fleet root `$env:CL_REPOS_ROOT`.** Use the repo
  itself (`$env:CL_REPOS_ROOT\<repo>`) or an in-repo worktree (`<repo>/.worktrees/<name>`).
- **Never run full test batteries in parallel on one repo.** Focused gate first;
  the full suite is serialized in QA.
- **Never block the main window.** Return control; handle completions as events.
- **One writer per repo/worktree**; never overlap two workers' write paths.
- **A detached worker has no human:** its prompt must end with "Do not ask
  questions; if blocked, record the blocker and stop", and its config must deny
  the `question` tool.
- **Never dispatch without an explicit, valid `provider/model`.** Fleet default is
  `opencode/opencode-go/deepseek-v4.1-flash` (thinking low; high only for complex logic)
  unless the operator names another. Nightly/weekly schedules always track the
  current default — never re-pin a retired model.
- **A worker's report is a claim, not proof.** Re-read its commits and gates.
- **Never let a worker force-push, rewrite history, or commit secrets.**
- **Never park plans outside the queue conventions** the owning runbook names
  (e.g. `manual-orchestration` parks in Handoff, not Quarantine).
