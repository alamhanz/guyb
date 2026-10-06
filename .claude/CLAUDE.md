# guyb
Claude Code plugin + marketplace: orchestrator playbook (hooks/orchestrator.md), 13 subagents, /guyb:* skills, and the `guyb` launcher.

- Stack: Markdown (agents/skills), PowerShell 7/5.1 + bash scripts, JSON (plugin/marketplace/hooks/settings)
- Git host: GitHub (alamhanz/guyb), PRs from feat/ fix/ docs/ branches, never push main
- Validate: `claude plugin validate ./plugins/guyb`
- Checks: `bash tests/lint.sh; bash tests/smoke.sh; bash tests/tabs.sh; bash tests/statusline.sh; bash tests/secrets.sh; pwsh -File tests/lint.ps1; pwsh -File tests/smoke.ps1; pwsh -File tests/tabs.ps1; pwsh -File tests/statusline.ps1; pwsh -File tests/permissions.ps1; pwsh -File tests/secrets.ps1`; or runners: `bash tests/run.sh` / `pwsh -File tests/run.ps1` (same tests, parallel within shell)
- Test scripts: run skills/setup/check.*, skills/start/brief.*, `guyb -List` / `guyb --list` on every shell touched (pwsh 7, PS 5.1, Git Bash/bash; WSL available as distro `ubuntu-24`)
- Reload after edits: `claude plugin marketplace update guyb; claude plugin update guyb@guyb`, then a fresh session
- Release: semver bump in plugins/guyb/.claude-plugin/plugin.json (patch fix / minor feature / major breaking; docs-only no bump)
- Cloud: none

## Credentials
None.

## Conventions
- Keep orchestrator.md short (loaded every session); mechanics go in skills
- Scripts: never prompt, never print secrets, read-only stays read-only; ASCII only, sh=LF, ps1=CRLF
- Terse prose, no emoji, no marketing; README only documents what exists
- .claude/guyb/STATE.md is committed; .claude/guyb/pipeline/ is not
