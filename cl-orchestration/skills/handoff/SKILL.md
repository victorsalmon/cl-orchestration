---
name: handoff
description: >
  Route and triage handoff records. TWO queues, chosen by SCOPE: a repo-scoped handoff
  (bead ids, branch SHAs, product decisions for one graph) lives in `<repo>/Tasks/00Handoff/`;
  a MACHINE-scoped handoff (absolute paths, credentials, cert ARNs, which box, machine-local
  env, anything that would be wrong on another machine) lives in `$HOME/.machine/state/handoffs/`.
  Handoffs carry data and context between agents, never a backlog: verify obsolescence against
  live state, mint anything describing work-to-do as a bead in the target repo's graph (the
  record points at the bead id), convert every other waiting item into a dependency wait or a
  watched prerequisite, and leave only true decisions for humans. Use when writing a handoff,
  when the user says "work the handoffs", "pick up a handoff", "00Handoff", or "hand-off pickup";
  also after user-decisions writes a consolidated handoff.
triggers:
  - user
  - model
---

Read and follow `$env:CL_REPOS_ROOT\cl-common\Skills\handoff\SKILL.md`.
