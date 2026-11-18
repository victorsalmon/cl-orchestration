---
name: agent-spawn-capacity
description: Per-key-set concurrency caps, model failover, and the provider-error log for every Paseo agent spawn (attached or detached). Owns the numbers — opencode-go 6 agents across both routes, gemini 4, devin 2 when enabled, codex 8 fix/code-refactor + 4 recon when enabled — the 15-minute failure windows that trip a 1-hour model cooldown, the primary→alternate route swap (Muse Spark 1.3 Contributor → DeepSeek Harness DS4.1Flash on the same opencode-go wallet), where each harness's credential lives (names only, never values), and how to answer "were there any errors last night?". Use before spawning any agent, when a worker dies on a provider error, when a pool looks exhausted, or when the operator asks about overnight provider errors.
triggers:
  - user
  - model
  - spawn
  - capacity
  - concurrency
  - quota
  - errors last night
---

Read and follow `$env:CL_REPOS_ROOT\cl-common\Skills\agent-spawn-capacity\SKILL.md`.
