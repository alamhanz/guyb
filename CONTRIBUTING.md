# Contributing to guyb

Thanks for helping. Issues and pull requests are welcome: bug reports, rough edges in the setup flow, new agents, and docs fixes.

## Repo layout

```
.claude-plugin/marketplace.json   marketplace entry (points at plugins/guyb)
plugins/guyb/
  .claude-plugin/plugin.json      plugin name, version, description
  agents/*.md                     one subagent per file
  skills/<name>/SKILL.md          slash commands (/guyb:<name>); helper scripts live beside them
  hooks/                          hooks.json, orchestrator.md (playbook), guard-secrets.*, guard-readonly.*
scripts/                          install.ps1/.sh, launch.ps1/.sh (the `guyb` command)
settings/                         recommended-permissions.json
plugins/guyb/statusline/          guyb-status.sh/.ps1 (optional status line; setup copies them to ~/.claude/guyb/)
tests/                            lint.*, smoke.*, tabs.*, statusline.*, permissions.ps1 + permission-cases.json
.github/workflows/ci.yml          CI: runs the tests/ scripts on ubuntu, macOS, and Windows
docs/                             README images (logo, icon, how-guyb-works.svg)
```

## Develop and test locally

1. Clone the repo and edit the source files.
2. Install from your clone so the plugin reads local files:
   ```
   claude plugin marketplace add ./guyb
   claude plugin install guyb@guyb
   ```
   After edits, run `claude plugin marketplace update guyb` and `claude plugin update guyb@guyb`, then start a **fresh session**. The playbook is injected at session start, so old sessions keep the old text.
3. Validate: `claude plugin validate ./plugins/guyb`.
4. Run helper scripts directly: `skills/setup/check.ps1` / `check.sh` (setup check JSON), `skills/start/brief.ps1` / `brief.sh` (briefing), and the launchers with `guyb -List` / `guyb --list`.
5. Test scripts on every shell you touched: PowerShell 7, Windows PowerShell 5.1, and bash (macOS/Linux or Git Bash).
6. This repo keeps its own STATE.md and pipeline files in `.claude/guyb/`, like any project.

## Run the checks locally

CI runs these same scripts. They write nothing in the repo (smoke tests use a temp dir and a stubbed `gh`) and need no network.

```
bash tests/lint.sh                 # bash -n, JSON/SVG validity, ASCII, line endings (sh LF, ps1 CRLF)
bash tests/smoke.sh                # brief.sh (incl. migration and cleanup detection), check.sh, guard hooks on throwaway repos
bash tests/tabs.sh                 # launcher colour table, dry-run tab/tmux commands, title sanitising
bash tests/statusline.sh           # status line fixtures (registries, branch, worktree, paths)
pwsh -File tests/lint.ps1          # ps1 parse, same file rules
pwsh -File tests/smoke.ps1         # brief.ps1, check.ps1, guard hooks
pwsh -File tests/tabs.ps1          # same as tabs.sh
pwsh -File tests/statusline.ps1    # same as statusline.sh
pwsh -File tests/permissions.ps1   # settings/recommended-permissions.json vs tests/permission-cases.json
```

Run the `.ps1` scripts with `powershell -File` as well to cover Windows PowerShell 5.1. macOS bash 3.2 and BSD tools are only covered by CI.

Changing `settings/recommended-permissions.json`? Update `tests/permission-cases.json` in the same PR. The matcher in `permissions.ps1` is an approximation of Claude Code's rule matching, so a pass is evidence, not proof; check surprising cases in a live session.

The `claude plugin validate` CI job is not required yet; run it locally (step 3 above).

## Conventions

- **Agents** (`agents/*.md`) have frontmatter with `name`, `description` (when to use it), `tools`, and `model`. Keep the body focused on role, approach, and report format.
- **Skills** (`skills/<name>/SKILL.md`) have frontmatter with `name`, `description`, and `argument-hint` where it takes input. Put step-by-step mechanics here.
- **Keep the playbook short.** `hooks/orchestrator.md` is loaded into every session, so it costs tokens every time. Mechanics belong in skills, not the playbook.
- **Line endings and encoding.** Scripts are ASCII. `.sh` files use LF, `.ps1` files use CRLF (`.gitattributes` enforces this on checkout). Keep bash scripts bash 3.2 compatible (macOS) and PowerShell scripts working on 5.1 and 7.
- **Scripts** never prompt, never print secret values, and never change the caller's working directory or config without consent. Read-only scripts stay read-only.
- Match the existing tone: terse, concrete, no marketing language. No emoji in new prose.
- Don't add features to the README that don't exist; keep it short and point to the SKILL.md or script header for detail.

## Versioning

Bump `version` in `plugins/guyb/.claude-plugin/plugin.json` using semver when you change behavior users will notice: patch for fixes, minor for new commands, agents, or options, major for breaking changes. Docs-only changes need no bump.

## Pull requests

1. Branch from `main` (`feat/...`, `fix/...`, `docs/...`). Never push to `main` directly.
2. One topic per PR; keep unrelated cleanups out.
3. Describe what changed, why, and how you tested it (which shells, which commands).
4. Never commit secrets, `.env` files, or real account IDs. Credits for adapted third-party work go in `CREDITS.md`.

By contributing you agree your work is released under the [MIT License](LICENSE).
