---
name: subagent-dispatch
description: >
  Dispatch background subagents from a Paseo-driven OpenCode session so the main window stays interactive — create agents with background mode and finish notification, brief them durably, and never block on a worker. The fleet default harness is opencode/opencode-go/deepseek-v4.1-flash (build; effort follows the work role: recon and review high, fix/code/refactor low and escalated only with a named reason); do not substitute Codex or Devin unless the operator asks.
triggers:
  - user
  - model
---

Read and follow `$env:CL_REPOS_ROOT\cl-common\vendor\interactive-qa\members\dispatch\SKILL.md`.