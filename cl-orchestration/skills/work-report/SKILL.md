---
name: work-report
description: >-
  Produce the operator's Work Report: for the last N days (default 7), grouped into 24-hour
  periods in America/Vancouver, show which features were worked on, the completeness percentage
  each one started the period at, how much was added, and where it ended, together with the token
  spend for that period. Every number is marked MEASURED or ESTIMATED and carries its source, so a
  percentage can never be invented and a cost can never be silently guessed. Use when the operator
  says "Work Report", "what did you work on this week", "feature progress by day", "how many tokens
  did we spend", or asks for a weekly progress table.
triggers:
  - user
  - model
---

Read and follow `$env:CL_REPOS_ROOT\cl-common\Skills\work-report\SKILL.md`.
