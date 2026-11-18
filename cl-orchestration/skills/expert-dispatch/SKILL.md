---
name: expert-dispatch
description: Dispatch an "expert" model (Sol 6.1 on high, Opus 5.5 on xhigh) on a token-metered, diff-only contract - a fixed list of files to read, the decisions already made, one task, output as ONE unified diff plus a DONE.json in an out-of-repo outbox, then ping the dispatcher and exit. Owns the expert profiles (experts.json), the contract template, and the checker that measures a contract against the profile's token budget before anything is spent. Use when the operator asks for Sol or Opus by name, for copy sign-off, translation, an AI legal review or second opinion, or any review where expensive-model tokens must buy context rather than exploration.
triggers:
  - user
  - model
---

Read and follow `$env:CL_REPOS_ROOT\cl-common\Skills\expert-dispatch\SKILL.md`.
