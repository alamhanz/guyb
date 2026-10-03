# guyb - State of the Project

## Overview
**guyb** is a Claude Code plugin that provides an orchestrator + specialist subagent team for code projects. It enables task delegation, project navigation, and integrated development workflows.

- **Repo**: https://github.com/alamhanz/guyb
- **License**: MIT
- **Owner**: @alamhanz

## Current Status
- **Branch**: feat/safety-ci-0.7.0 (PR open, awaiting user merge)
- **Version**: 0.7.0 (plugins/guyb/.claude-plugin/plugin.json)

## Versions
- **0.7.0**: GitHub Actions CI (ubuntu/macos/windows; lint, smoke, permission tests, optional plugin validate), PowerShell secrets guard, read-only agent guard hook + prompt rules, brief flags outdated plugin and STATE.md PR drift, agent reports in .claude/pipeline/reports/, merge is the user's step, option D brand (g> monogram, black + phosphor green)
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
- Secrets guard fires only on plain `git commit ...` (not `git -C dir commit` or chained commands)
- CI actions pinned to tags not SHAs; claude-code npm install unpinned; brief.sh gh calls have no timeout on macOS; no-jq paths not exercised in CI
- macOS behavior verified only by CI (first run pending)
- install.ps1 settings merge not executed in a test; tmux launch path untested
- Deferred consider items: A13 (PS 5.1 encoding), A14 (culture colon), A15 (docs note), A18 (sh/ps1 cosmetic parity)

## Next Up
- Merge 0.7.0 PR, watch first CI run (esp. macOS and validate job), then update installed plugin (installed is 0.5.0)
- Remaining consider items A13, A14, A18
- Gather feedback on 0.6.0, then pick next features

---
**Last updated**: 2026-10-04
