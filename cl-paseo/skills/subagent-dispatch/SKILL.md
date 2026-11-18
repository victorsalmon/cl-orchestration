---
name: subagent-dispatch
description: Dispatch background subagents from a Paseo-driven OpenCode session so the main window stays interactive — create agents with background mode and finish notification, brief them durably, and never block on a worker. The fleet default harness is opencode/opencode-go/deepseek-v4.1-flash (build, thinking low; high only for complex logic/edge cases/multi-step invariants); do not substitute Codex or Devin unless the operator asks.
triggers:
  - user
  - model
---

Read and follow `$env:CL_REPOS_ROOT\cl-common\vendor\interactive-qa\members\dispatch\SKILL.md`.
