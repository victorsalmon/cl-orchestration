---
name: cheepseek
description: Operation CheepSeek — cost-optimized DeepSeek V4.1 Flash routing and prompt-cache discipline. Free Zen lane (opencode/deepseek-v4.1-flash-free, 200K in / 128K out billing guardrails) first, paid Go lane (opencode-go/deepseek-v4.1-flash, full 1M / 384K) on overflow or 429 exhaustion, direct BYO-key fallback last. Includes the lane-choice rules for when free is genuinely cheaper than paid. Use before dispatching any DeepSeek Flash work, or when a DeepSeek session looks expensive or cache-hit rates look low.
triggers:
  - user
  - model
---

Read and follow `$env:CL_REPOS_ROOT\cl-common\Skills\cheepseek\SKILL.md`.
