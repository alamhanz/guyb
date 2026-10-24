<!-- guyb:state -->
# guyb - State of the Project

## Overview
**guyb** is a Claude Code plugin that provides an orchestrator + specialist subagent team for code projects. It enables task delegation, project navigation, and integrated development workflows.

- **Repo**: https://github.com/alamhanz/guyb
- **License**: MIT
- **Owner**: @alamhanz

## Current Status
- **Branch**: main (clean, c180a73); installed plugin not yet updated to 0.12.0
- **Version**: 0.12.0 (PR #22); see Versions

## Versions
- **0.12.0** (PR #22, c180a73, plan guyb-156, fixes #20): manager-only orchestrator (every project-file edit goes to an agent, trivial ones on haiku batched; reads ~3 files max); parallel by default for disjoint tasks; shared gitignored `pipeline/memory.md` fed from report `## Memory` bullets, session-tracker promotes durable items to Decisions; new key `cleanup_memory_lines` (100) in brief/connections; lint caps orchestrator.md at 8192 bytes (now 7692)
- **0.11.1** (PR #21, c66d26c, plan guyb-153; fixes #18, #19): PreToolUse hooks re-exec in bash under dash (POSIX guard line, dash test); setup check expands ~/$HOME in rc lines, marketplace fallback, PATH launcher detection; Windows guyb shim (scripts/guyb.cmd, guyb.ps1, winlauncher.ps1; install.ps1 adds user PATH entry, user GUYB_ROOT, Git Bash ~/.bashrc line)
- **0.11.0** (PR #17, 5ad7740, plan guyb-144): usage guard - status line records plan usage and writes a state file at/above warn (defaults 93/98); usage-guard.sh notices via asyncRewake on tab-status hooks (async kept for older CC); Agent launch ask gate at stop tier; /guyb:end usage-limit mode; /guyb:setup thresholds
- **0.10.1** (PR #16, plan guyb-142): project-level SessionStart hook (.claude/settings.json, not shipped) runs .claude/scripts/cloud-setup.sh on Linux non-WSL when pwsh or shellcheck is missing (pinned pwsh 7.4.20 sha256, no interactive sudo); CONTRIBUTING notes on cloud sessions and WSL dirty counts
- **0.10.0** (PR #15, plan guyb-133): connections awareness. Startup notice (separate SessionStart `startup` hook, systemMessage) plus brief/check lines list recorded global connections, warn on broken ones and show `project config:`; `/guyb:setup` is model-invocable and lists/adds/changes/removes connections (Cloudflare MCP + wrangler, generic user-scope MCP) and records `## Connections` in profile.md; routing line in the playbook; wrangler and `claude mcp` permission rules
- **0.9.2** (PR #14): smoke.sh on Git Bash ~8 min -> ~3.5 min (brief.sh/check.sh fork cuts with byte-identical output; read-only guard batch test entry `. guard-readonly.sh batch`, unreachable from hooks.json; fewer brief runs; no-jq brief copy in g_plugin); guard hardening (GUYB_MODE/GUYB_CWD cleared for the production awk call, read-only agent without awk on PATH is blocked); hooks.json guard entries for all 8 casings of "git" (the `if` globs are case-sensitive, no classes/alternation, `*` spans newlines; probed live) plus filter contract test in smoke.sh/smoke.ps1; CI: actions pinned to SHAs (checkout v7.0.1, setup-node v7.1.0, node 24), claude-code npm pinned 2.1.296, GUYB_RO_FULL=1 on Linux/macOS
- **0.9.0** (PR #12): read-only guard rewrite (parsed quotes/chains/substitutions/runners/aliases, shared case table, PS scriptblocks, read subcommands, branch/tag creation), secrets guard names, test runners + bench + shellcheck CI, `/guyb:end` wrap-up (model-invocable on "I need to go": stop agents, handoff, STATE.md, commit + push work branches, no PR), `/guyb:start` resumes from the handoff
- **0.8.1** (PR #11): tab icon tracks running subagents; release workflow + README slim (PR #10)
- **0.8.0** (PR #9): tab status icon (hourglass working / check done / ? waiting; async hooks tab-status.sh/.ps1, GUYB_TAB_NAME tabs only); secrets guard covers `git -C`/`-c`, chained commands, `commit -a`, target repo; read-only guard catches chained and `git -C` write commands (also fixed sed-fallback JSON escape bug that made it fail open without jq); playbook: delegate long-running/stateful commands; parity fixes A13 (PS 5.1 UTF-8), A14 (invariant `-List` timestamp), A18 (sh/ps1 parity); tests/secrets.*
- **0.7.0** (PR #8): GitHub Actions CI (ubuntu/macos/windows; lint, smoke, permission tests, optional plugin validate), PowerShell secrets guard, read-only agent guard hook + prompt rules, brief flags outdated plugin and STATE.md PR drift, agent reports in .claude/pipeline/reports/, merge is the user's step, new brand: "flock in motion" mark (five dots in a V, black + phosphor green)
- **0.6.0** (PR #7): `max_parallel: N` in project `.claude/CLAUDE.md` or `~/.claude/guyb/profile.md`; cross-platform script fixes
- **0.5.0** (PR #5): natural-language activation, setup check, cost rules
- **0.4.0** (PR #4): root launcher tabs, delegation by default, intake via architect, question log
- **0.3.0** (PR #1): run IDs, waves, progress files

## Recent Changes
- 2026-10-24 - 0.12.0 merged (PR #22, c180a73): runs guyb-159 (docs/skills), guyb-160 (scripts/tests; cut off by API 429, resumed), guyb-161 review approved with 1 should-fix, guyb-162 fixes + bump, guyb-163 PR. Full suite green (bash smoke 540/0, pwsh smoke 506/0, secrets 206/109, tabs 99/39, permissions 84, winlauncher 22), CI green on all 9 checks. Merge needed ruleset bypass (main `update` rule restricts updates to bypass actors)
- 2026-10-24 - 0.11.1 merged (PR #21, c66d26c): runs guyb-154 (stopped by session end), guyb-155 (Task 3), guyb-157 review approved (hooks-sh 30, setup-paths 9/11, winlauncher 22, permissions 84), guyb-158 PR; CI green on all 9 checks. Housekeeping: 105 pipeline scratch files older than 14 days deleted. Gotcha: sed -i in Git Bash strips CR from .ps1 files; use Edit for CRLF files
- 2026-10-13 - 0.11.0 merged (PR #17, 5ad7740): full suite green locally (bash smoke 538, pwsh smoke 504) and in CI on all 9 checks incl. macOS; PR conflicted because 0.10.1 was squash-merged (#16) while the branch kept e5e6d03, fixed with a merge commit (force-push blocked by auto mode). Installed plugin updated 0.9.1 -> 0.11.0. Runs guyb-149..152 done; branch deleted
- 2026-10-12 - 0.11.0 usage guard implemented (guyb-146 stopped, finished in guyb-149), review guyb-150 approved with fixes, fixes guyb-152 (keep async with asyncRewake, silent state write, no temp file below warn). Spikes (a) asyncRewake wake and (c) Agent ask not verified live (Q102: ship unverified)
- 2026-10-12 - 0.10.1 cloud-setup hook implemented (guyb-145); WSL install path verified with a local tarball, WSL network truncates the GitHub download (curl 18)
- 2026-10-12 - 0.9.2 merged (PR #14, 0e08c19; plan guyb-128): runs guyb-129/130 were interrupted, finished and audited in guyb-138. brief.sh/check.sh output verified byte-identical to 0.9.1 on 17 brief fixtures and 10 check variants (Git Bash + WSL); smoke.sh 463 checks, 206 s on Git Bash
- 2026-10-06 - Cloud session (Linux container, pwsh 7.4 + shellcheck installed per session; PS 5.1/Windows only via CI): all checks pass on bash + pwsh. PR #12 5.1 failure root-caused: .NET Framework Process.Start writes a UTF-8 BOM into redirected child stdin (AutoFlush on Console.InputEncoding), so the guard failed open in smoke; harness sets a BOM-less InputEncoding, guard skips pre-JSON junk (5cf1c2e). Edge-case probes (scratch, not committed): read-only guard 315 commands, 35 problems fixed (183280c: read subcommands of submodule/notes/bisect/symbolic-ref/sparse-checkout/replace/clean, branch/tag creation behind flags, PS scriptblocks via { } split, wsl/doas/ionice, $'..'), 76 rows added to readonly-cases.tsv, bench unchanged; secrets guard 50 forms + 39 names (85b0bf0: .git-credentials, id_dsa, *.ppk, .pgpass, .htpasswd; *.md safe; no-input smoke cases hung on a non-tty stdin). sh/ps parity: no differences found. brief/check/launcher sh vs ps: same output
- 2026-10-05 - Session: PR #10 opened (release workflow + README slim, CI green, guyb-95; rulesets verified, unchanged). Installed plugin updated 0.5.0 -> 0.8.0. 0.8.1 on fix/tab-status-subagents (worktree .claude/worktrees/agent-adac6880fe2a8d8b3, not pushed): 149ad9a tab icon stays busy while subagents run (guyb-98), bdfc97f pipeline rule "finish clean" (agents left background tests running and stayed open in the panel); review guyb-106 approved with one should-fix (stuck ? after Notification + last agent-stop), fix round guyb-107 in progress. 0.8.2 guards rewrite on fix/guards-0.8.2 (worktree .claude/worktrees/guards-0.8.2, uncommitted): plan guyb-96, Q53-Q57 answered (all option a), wave 1: guyb-99 sh guard done, guyb-100 ps1 guard + hooks.json done, guyb-101 case table/smoke and guyb-102 shellcheck/CI/runners/bench still running at session end
- 2026-10-05 - 0.8.0 merged (PR #9, 0027638); feat/release-workflow: release.yml tags + publishes vX.Y.Z on version bump (guyb-91, f13cb61), README slimmed (d089cf0), main rulesets protect-main + main-merge-admin-only (guyb-92/93), review guyb-94 fixes uncommitted
- 2026-10-04 - 0.8.0 on fix/parity-a13-a18 (guyb-70..79, guyb-84; guyb-80..83 stopped, superseded by guyb-84..87): 52e66a8 parity A13/A14/A18, 1bc73ae secrets guard hardening, a43bf22 playbook delegation rule, 1970efc tab icon + version 0.8.0, c196a1c read-only guard hardening; README/CONTRIBUTING drift fixed (guyb-85)
- 2026-10-04 - 0.7.0 merged (PR #8, 1c034fd)
- 2026-10-04 - Cross-platform audit (guyb-20, findings in .claude/pipeline/plans/guyb-20-audit.md) and fixes (guyb-21): brief.sh CRLF + BSD-safe tab split, check.sh BSD sed + $HOME with spaces + zsh/bash_profile hints, guard-secrets.sh non-ASCII/space filenames, install.sh jq-missing warning + invalid settings.json error, install.ps1 exit-code checks, -LiteralPath in brief.ps1/check.ps1; guyb-19 stopped (report lost, superseded by guyb-20)
- 2026-10-04 - Project `.claude/CLAUDE.md` added
- 2026-10-03 - README rewrite around parallel agents + animation (PR #6)
- 2026-10-03 - Releases 0.3.0-0.5.0 (PRs #1-#5)

## Decisions
- **Secrets guard** keeps blocking `git add <other> && git commit` while a non-ignored secret is untracked (add paths may hold unexpandable variables); alias commits (`git ci`) are a known gap (hooks.json filter is *commit*).
- **Delegation model** (0.12.0, issue #20): orchestrator is manager only; every project-file edit goes to an agent (trivial ones on haiku, batched per request); reads ~3 files at most for quick answers, else asks the agent (SendMessage) or Explore. Parallel by default for disjoint tasks (merge parts sharing files or under ~30 lines). Shared gitignored `pipeline/memory.md`, written only by the orchestrator from report `## Memory` bullets; session-tracker promotes durable items to Decisions; cap `cleanup_memory_lines` (100). Replaces "small changes inline only" (PR #3).
- **Q8**: install.sh without jq warns with install hints and ends "Done (permissions NOT merged)", exit 0.
- **Q9**: credential-returning AWS get verbs (ecr get-login-password/get-authorization-token, lambda get-function(-configuration), apigateway get-api-key(s)) are ask rules; .env read denies cover 9 read verbs x 4 patterns, symmetric for Bash and PowerShell.
- **Q51**: tab icon ~1s lag on Windows accepted (async hook).
- **Q52**: Notification on idle prompt turns the icon to `?` after done - kept.
- **Connections notice (0.10.0)** is local-only: file reads and `command -v`, no CLI or network call in any start path (measured: gh auth status 1.1 s, aws sts 3.9 s, claude mcp list 4.4 s, gcloud config list 47 s); startup hook budget: +1 bash +1 awk per new session, parallel with the playbook hook, no cost on resume/clear/compact or tool calls. Network verify only in `/guyb:setup` on request.
- **Ruleset bypass**: main has an `update` rule limiting updates to bypass actors, so merging PRs (#22) needs the bypass; the merge stays the user's step.
- **STATE.md** is committed; `.claude/pipeline/` is gitignored.

## Open Issues
- Read-only guard hooks.json filter: 8 entries per shell (one per casing of "git"); a call spawns the guard once per casing it contains. Cost measured: 0.2-0.3 s per git-mentioning call on Windows is the hook shell start (guard adds ~0 on the main-session path), ~3 ms on Linux; no cheaper safe filter. Revisit if Claude Code filters hooks by agent type
- Read-only guard: obfuscated command names (`g\it`, `gi""t`, `g'i't`) have no "git" substring, so the hooks.json filter never runs the guard (widening it costs a spawn per Bash call)
- Action SHA pins are not auto-bumped (no Dependabot); claude-code npm pin in the validate job needs deliberate bumps
- macOS behavior verified only by CI (passing on PR #22)
- install.ps1 settings merge not executed in a test; tmux launch path untested
- Sed -i on .ps1 files strips CR (CRLF required); edit them with Edit

## Next Up
- Live-check 0.12.0 in a fresh session: small edit goes to a haiku agent, parallel launch for disjoint tasks, memory.md flow (orchestrator writes from `## Memory` bullets) and the cleanup_memory_lines line in brief
- Live-check guyb.cmd from a fresh Windows terminal after running install.ps1
- Live-check 0.11.0 spikes (a) and (c): scratch plugin PostToolUse hook with asyncRewake exit 2 wakes the model; a stop state file in GUYB_USAGE_DIR makes Agent launches prompt
- Live check of 0.10.0 (plugin now updated): fresh session shows the connections notice; "add Cloudflare to guyb" runs /guyb:setup
- smoke.sh on Git Bash: 206 s on a loaded box (fork baseline 3.4 s per 20 forks), target 240 s met; remaining cost is hook/brief/check process starts
- Live check of the wrap-up: say "I need to go" in a session with a running agent (SendMessage checkpoint, TaskStop fallback, git-ops WIP push), then /guyb:start on the same machine (handoff) and on another (STATE.md + WIP branches)

---
**Last updated**: 2026-10-24
