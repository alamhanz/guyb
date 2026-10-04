<!-- guyb:state -->
# guyb - State of the Project

## Overview
**guyb** is a Claude Code plugin that provides an orchestrator + specialist subagent team for code projects. It enables task delegation, project navigation, and integrated development workflows.

- **Repo**: https://github.com/alamhanz/guyb
- **License**: MIT
- **Owner**: @alamhanz

## Current Status
- **Branch**: fix/parity-a13-a18 (0.8.0, PR not yet opened); main has 0.7.0 (PR #8 merged, 1c034fd)
- **Version**: 0.8.0 (plugins/guyb/.claude-plugin/plugin.json)

## Versions
- **0.8.0** (branch fix/parity-a13-a18): tab status icon (hourglass working / check done / ? waiting; async hooks tab-status.sh/.ps1, GUYB_TAB_NAME tabs only); secrets guard covers `git -C`/`-c`, chained commands, `commit -a`, target repo; read-only guard catches chained and `git -C` write commands (also fixed sed-fallback JSON escape bug that made it fail open without jq); playbook: delegate long-running/stateful commands; parity fixes A13 (PS 5.1 UTF-8), A14 (invariant `-List` timestamp), A18 (sh/ps1 parity); tests/secrets.*
- **0.7.0** (PR #8): GitHub Actions CI (ubuntu/macos/windows; lint, smoke, permission tests, optional plugin validate), PowerShell secrets guard, read-only agent guard hook + prompt rules, brief flags outdated plugin and STATE.md PR drift, agent reports in .claude/pipeline/reports/, merge is the user's step, new brand: "flock in motion" mark (five dots in a V, black + phosphor green)
- **0.6.0** (PR #7): `max_parallel: N` in project `.claude/CLAUDE.md` or `~/.claude/guyb/profile.md`; cross-platform script fixes
- **0.5.0** (PR #5): natural-language activation, setup check, cost rules
- **0.4.0** (PR #4): root launcher tabs, delegation by default, intake via architect, question log
- **0.3.0** (PR #1): run IDs, waves, progress files

## Recent Changes
- 2026-10-04 - 0.8.0 on fix/parity-a13-a18 (guyb-70..79, guyb-84; guyb-80..83 stopped, superseded by guyb-84..87): 52e66a8 parity A13/A14/A18, 1bc73ae secrets guard hardening, a43bf22 playbook delegation rule, 1970efc tab icon + version 0.8.0, c196a1c read-only guard hardening; README/CONTRIBUTING drift fixed (guyb-85)
- 2026-10-04 - 0.7.0 merged (PR #8, 1c034fd)
- 2026-10-04 - Cross-platform audit (guyb-20, findings in .claude/pipeline/plans/guyb-20-audit.md) and fixes (guyb-21): brief.sh CRLF + BSD-safe tab split, check.sh BSD sed + $HOME with spaces + zsh/bash_profile hints, guard-secrets.sh non-ASCII/space filenames, install.sh jq-missing warning + invalid settings.json error, install.ps1 exit-code checks, -LiteralPath in brief.ps1/check.ps1; guyb-19 stopped (report lost, superseded by guyb-20)
- 2026-10-04 - Project `.claude/CLAUDE.md` added
- 2026-10-03 - README rewrite around parallel agents + animation (PR #6)
- 2026-10-03 - Releases 0.3.0-0.5.0 (PRs #1-#5)

## Decisions
- **Delegation model**: orchestrator plans and delegates; does small changes inline only (PR #3).
- **Q8**: install.sh without jq warns with install hints and ends "Done (permissions NOT merged)", exit 0.
- **Q9**: credential-returning AWS get verbs (ecr get-login-password/get-authorization-token, lambda get-function(-configuration), apigateway get-api-key(s)) are ask rules; .env read denies cover 9 read verbs x 4 patterns, symmetric for Bash and PowerShell.
- **Q51**: tab icon ~1s lag on Windows accepted (async hook).
- **Q52**: Notification on idle prompt turns the icon to `?` after done - kept.
- **STATE.md** is committed; `.claude/pipeline/` is gitignored.

## Open Issues
- Read-only guard hooks.json filter widened to `Bash(*git*)` / `PowerShell(*git*)`: it runs on every Bash call mentioning git (perf); `bash tests/smoke.sh` takes >2 min on Windows
- CI actions pinned to tags not SHAs; claude-code npm install unpinned; brief.sh gh calls have no timeout on macOS; no-jq paths not exercised in CI
- macOS behavior verified only by CI (first run pending)
- install.ps1 settings merge not executed in a test; tmux launch path untested
- Deferred consider item: A15 (docs note)

## Next Up
- Review (guyb-86), open 0.8.0 PR (guyb-87), user merges, watch CI (esp. macOS and validate job), then update installed plugin (installed is 0.5.0)
- Consider item A15
- Gather feedback on 0.6.0, then pick next features

---
**Last updated**: 2026-10-04
