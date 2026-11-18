---
name: active-history
description: >-
  Per-repo running record of what actually happened, so an unattended session does not bury its work in
  chat. Append-only event log with a delta view: completions, problems caught and fixed, problems not fixed
  (with why), decision blockers and action blockers — in that order. Events are never deleted; resolving an
  item hides it from the report and keeps the record. Use when asked for "Active History", when running
  unattended and needing somewhere durable to report, when recording a caught-and-fixed problem, when
  parking a blocker on the operator, or when a lane finishes and its outcome must not evaporate.
triggers:
  - user
  - model
---

Read and follow `$env:CL_REPOS_ROOT\cl-common\Skills\active-history\SKILL.md`.
