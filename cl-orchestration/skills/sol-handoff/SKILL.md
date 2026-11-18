---
name: sol-handoff
description: Create and receive a Sol 6.1 review/decision work packet as one self-contained markdown handoff with an embedded copy-button prompt, sized to a token budget below Sol's 272K long-context price step. Use when handing tax/GIFI, EULA/copy, product-boundary, or least-privilege work to Sol; when splitting a packet that outgrows the budget; or when applying a returned DECISIONS.json plus patches bundle. This is the external-reviewer companion to the internal `handoff` queue skill.
triggers:
  - user
  - model
---

Read and follow `$env:CL_REPOS_ROOT\cl-common\Skills\sol-handoff\SKILL.md`.
