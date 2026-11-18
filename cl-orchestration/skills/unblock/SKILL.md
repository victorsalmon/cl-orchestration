---
name: unblock
description: Interrogate the agent's own uncertainty to unblock work — map every uncertain surface of the goal through grill-me batch rounds, separate what only the user can provide (API tokens, credentials, IAM permissions, accounts, console steps) from what the agent should just do, and hand back the user actions that unblock future work in priority order, most urgent first. Use when the user says "Unblock", "what do you need from me", or the route is fogged by uncertainty.
triggers:
  - user
  - model
---

Read and follow `$env:CL_REPOS_ROOT\cl-common\Skills\unblock\SKILL.md`.
