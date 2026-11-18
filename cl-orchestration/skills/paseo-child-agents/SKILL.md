---
name: paseo-child-agents
description: Dispatch Paseo workers as detached background child agents that survive the user's next message, and keep them visible in the parent's child list. Covers the `paseo run -d` dispatch, why a chat-coupled dispatch is cancelled the moment the user replies, per-harness mechanics for opencode, Codex, and Devin, PASEO_AGENT_ID/PASEO_AGENT_CWD parent linkage, ParentAgentId null diagnosis, and the `parent=` label fallback. Use when dispatching Paseo subagents or workers, when a worker dies, vanishes, or blocks mid-task, when a worker is missing from the parent's child list, or when deciding whether to wait on a subagent.
triggers:
  - user
  - model
---

Read and follow `$env:CL_REPOS_ROOT\cl-common\Skills\paseo-child-agents\SKILL.md`.