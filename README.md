# cl-orchestration

Clock Lobster's orchestration plugins: how agents are dispatched, supervised and
run across the fleet. Four plugins, one folder each:

| Plugin | What it covers | Front door |
| :--- | :--- | :--- |
| `cl-claude/` | Runbooks written for Claude Code: omnicode, land-lanes, OpenCode Go dispatch, Claude lane lessons | [`cl-claude/SKILL.md`](cl-claude/SKILL.md) |
| `cl-orchestration/` | Fleet orchestration: dispatch modes, backlog, epic worktrees, hub/sub hand-offs | [`cl-orchestration/SKILL.md`](cl-orchestration/SKILL.md) |
| `cl-opencode/` | OpenCode runtime: config and database checks, recovery | [`cl-opencode/SKILL.md`](cl-opencode/SKILL.md) |
| `cl-paseo/` | Paseo daemon, agents, workspaces, health and repair | [`cl-paseo/SKILL.md`](cl-paseo/SKILL.md) |

## Where this is edited

This tree is canonical inside the
[`cl-common`](https://github.com/victorsalmon/cl-common) repository, at
`vendor/cl-orchestration/`. It is edited there like any other cl-common code.
These public repositories are **published copies** produced with
`git subtree split`, so their history contains only this folder:

- GitHub: `https://github.com/victorsalmon/cl-orchestration.git`
- worktree.ca: `git@worktree.ca:clocklobster/cl-orchestration.git`

Don't commit directly to the public repositories. A commit made there is
overwritten by the next publish. From a cl-common checkout, publish with:

```powershell
pwsh -NoProfile -File scripts/Publish-ClOrchestration.ps1          # dry run: show the split SHA
pwsh -NoProfile -File scripts/Publish-ClOrchestration.ps1 -Push    # push main to both remotes
```

## Dependencies

Some runbooks cite fleet skills that live in cl-common (`Skills/...`,
`vendor/interactive-qa/...`) through relative links such as
`../../../Skills/<name>`. Those links only resolve inside a cl-common checkout.
In a standalone clone of this repository, set `CL_COMMON_HOME` to a cl-common
checkout to follow them.

## License

MIT. See [`LICENSE`](LICENSE).
