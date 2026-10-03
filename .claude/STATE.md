# guyb - State of the Project

## Overview
**guyb** is a Claude Code plugin that provides an orchestrator + specialist subagent team for code projects. It enables task delegation, project navigation, and integrated development workflows.

- **Repo**: https://github.com/alamhanz/guyb
- **License**: MIT
- **Owner**: @alamhanz

## Current Status
- **Branch**: feat/configurable-max-parallel (PR #7, merging)
- **Version**: 0.6.0 (plugins/guyb/.claude-plugin/plugin.json)
- **PR #7** carries: configurable max parallel agents (default 5) + cross-platform script fixes from this session

## Versions
- **0.6.0** (PR #7): `max_parallel: N` in project `.claude/CLAUDE.md` or `~/.claude/guyb/profile.md`; cross-platform script fixes
- **0.5.0** (PR #5): natural-language activation, setup check, cost rules
- **0.4.0** (PR #4): root launcher tabs, delegation by default, intake via architect, question log
- **0.3.0** (PR #1): run IDs, waves, progress files

## Recent Changes
- 2026-10-04 - Cross-platform audit (guyb-20, findings in .claude/pipeline/plans/guyb-20-audit.md) and fixes (guyb-21): brief.sh CRLF + BSD-safe tab split, check.sh BSD sed + $HOME with spaces + zsh/bash_profile hints, guard-secrets.sh non-ASCII/space filenames, install.sh jq-missing warning + invalid settings.json error, install.ps1 exit-code checks, -LiteralPath in brief.ps1/check.ps1; guyb-19 stopped (report lost, superseded by guyb-20)
- 2026-10-04 - Project `.claude/CLAUDE.md` added
- 2026-10-03 - README rewrite around parallel agents + animation (PR #6)
- 2026-10-03 - Releases 0.3.0-0.5.0 (PRs #1-#5)

## Decisions
- **Delegation model**: orchestrator plans and delegates; does small changes inline only (PR #3).
- **Q8**: install.sh without jq warns with install hints and ends "Done (permissions NOT merged)", exit 0.
- **Q9**: credential-returning AWS get verbs (ecr get-login-password/get-authorization-token, lambda get-function(-configuration), apigateway get-api-key(s)) are ask rules; .env read denies cover 9 read verbs x 4 patterns, symmetric for Bash and PowerShell.
- **STATE.md** is committed; `.claude/pipeline/` is gitignored.

## Open Issues
- macOS/BSD fixes (A2, A3, A9) verified statically only; no real Mac test
- install.ps1 settings merge not executed in a test; tmux launch path untested
- guard-secrets hook covers Bash only; no PowerShell guard (A16)
- Deferred consider items: A13 (PS 5.1 encoding), A14 (culture colon), A15 (docs note), A18 (sh/ps1 cosmetic parity)

## Next Up
- Test install/launch/brief/check on a real Mac (bash 3.2 + zsh)
- PowerShell guard-secrets hook (A16)
- Remaining consider items A13, A14, A18
- Gather feedback on 0.6.0, then pick next features

---
**Last updated**: 2026-10-04
