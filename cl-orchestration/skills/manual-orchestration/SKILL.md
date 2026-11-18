---
name: manual-orchestration
description: Manually drive a repository's Salmon Run backlog through the remaining pipeline stages (Code → Review → Maintain → QA → Merge → Complete) with subagents, parking every taken plan in the Handoff queue under a generated run index instead of Quarantine. Use when the user says "Manual Orchestration", "manually orchestrate", or asks to clear a repo's salmon-run backlog by hand.
triggers:
  - user
  - model
---

Read and follow `$env:CL_REPOS_ROOT\cl-common\Skills\saas-common\manual-orchestration\SKILL.md`.