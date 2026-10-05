<!-- guyb:state -->
# guyb - State of the Project

## Overview
**guyb** is a Claude Code plugin that provides an orchestrator + specialist subagent team for code projects. It enables task delegation, project navigation, and integrated development workflows.

- **Repo**: https://github.com/alamhanz/guyb
- **License**: MIT
- **Owner**: @alamhanz

## Current Status
- **Branch**: feat/release-workflow (release workflow + README slim, PR not yet opened); main has 0.8.0 (PR #9 merged, 0027638)
- **Version**: 0.8.0 (plugins/guyb/.claude-plugin/plugin.json)

## Versions
- **0.8.0** (PR #9): tab status icon (hourglass working / check done / ? waiting; async hooks tab-status.sh/.ps1, GUYB_TAB_NAME tabs only); secrets guard covers `git -C`/`-c`, chained commands, `commit -a`, target repo; read-only guard catches chained and `git -C` write commands (also fixed sed-fallback JSON escape bug that made it fail open without jq); playbook: delegate long-running/stateful commands; parity fixes A13 (PS 5.1 UTF-8), A14 (invariant `-List` timestamp), A18 (sh/ps1 parity); tests/secrets.*
- **0.7.0** (PR #8): GitHub Actions CI (ubuntu/macos/windows; lint, smoke, permission tests, optional plugin validate), PowerShell secrets guard, read-only agent guard hook + prompt rules, brief flags outdated plugin and STATE.md PR drift, agent reports in .claude/pipeline/reports/, merge is the user's step, new brand: "flock in motion" mark (five dots in a V, black + phosphor green)
- **0.6.0** (PR #7): `max_parallel: N` in project `.claude/CLAUDE.md` or `~/.claude/guyb/profile.md`; cross-platform script fixes
- **0.5.0** (PR #5): natural-language activation, setup check, cost rules
- **0.4.0** (PR #4): root launcher tabs, delegation by default, intake via architect, question log
- **0.3.0** (PR #1): run IDs, waves, progress files

## Recent Changes
- 2026-10-05 - Session: PR #10 opened (release workflow + README slim, CI green, guyb-95; rulesets verified, unchanged). Installed plugin updated 0.5.0 -> 0.8.0. 0.8.1 on fix/tab-status-subagents (worktree .claude/worktrees/agent-adac6880fe2a8d8b3, not pushed): 149ad9a tab icon stays busy while subagents run (guyb-98), bdfc97f pipeline rule "finish clean" (agents left background tests running and stayed open in the panel); review guyb-106 approved with one should-fix (stuck ? after Notification + last agent-stop), fix round guyb-107 in progress. 0.8.2 guards rewrite on fix/guards-0.8.2 (worktree .claude/worktrees/guards-0.8.2, uncommitted): plan guyb-96, Q53-Q57 answered (all option a), wave 1: guyb-99 sh guard done, guyb-100 ps1 guard + hooks.json done, guyb-101 case table/smoke and guyb-102 shellcheck/CI/runners/bench still running at session end
- 2026-10-05 - 0.8.0 merged (PR #9, 0027638); feat/release-workflow: release.yml tags + publishes vX.Y.Z on version bump (guyb-91, f13cb61), README slimmed (d089cf0), main rulesets protect-main + main-merge-admin-only (guyb-92/93), review guyb-94 fixes uncommitted
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
- Check guyb-107 (0.8.1 fix round), guyb-101, guyb-102 results in .claude/guyb/pipeline/reports/; if their agents died with the session, mark them stopped and relaunch from their progress files
- User merges PR #10 (CI green); watch the first auto release later
- 0.8.1: after guyb-107, push fix/tab-status-subagents and open PR (git-ops); live check of the tab icon with background agents (hook order on background-task re-invoke is unverified)
- 0.8.2: wave 2 guyb-103 docs + version 0.8.2, wave 3 guyb-104 review + all checks on 4 shells + bench before/after (also covers the cut-off secrets.sh run); rebase fix/guards-0.8.2 onto 0.8.1 (hooks.json and tests/tabs.sh overlap; tabs.sh SC1010 shellcheck fixes after the merge)
- Feature request: "I need to go" wrap-up by default - /guyb:end has `disable-model-invocation: true`; allow model invocation with trigger phrases (need to go, done for today, wrap up). Flow (agreed 2026-10-05): ask running agents to checkpoint (progress + report files) and stop; stop leftovers; WIP-commit worktree changes locally (not pushed); write a local handoff file in .claude/guyb/pipeline/ (gitignored: same-machine resume); update and commit/push STATE.md (cross-machine); /guyb:start reads the handoff and offers to resume. Local handoff: .claude/guyb/pipeline/handoff.md
- Feature request (user, 2026-10-05): "commit" in a wrap-up means commit AND push every work branch (WIP commits included), no PR, so another machine can pull and continue
- Resume 0.8.2: fix/guards-0.8.2 is pushed as WIP 93b5cf7 (guyb-99/100 done; guyb-101 stopped at checkpoint with 4 failing ps rows; guyb-102 killed mid-task, check bench.ps1/run.ps1). 0.8.1 is pushed on fix/tab-status-subagents (d2ea909, review fixes done) - open its PR
- Weight audit after 0.8.2 (guyb-105, queued): orchestrator.md tokens per session, tab-status per-call spawns, brief/gh time; budget every change (guyb must stay lightweight)
- Consider item A15
- Gather feedback on 0.6.0, then pick next features

---
**Last updated**: 2026-10-05
