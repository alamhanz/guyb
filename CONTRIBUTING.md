# Contributing to guyb

Thanks for helping. Issues and pull requests are welcome: bug reports, rough edges in the setup flow, new agents, and docs fixes.

## Repo layout

```
.claude-plugin/marketplace.json   marketplace entry (points at plugins/guyb)
plugins/guyb/
  .claude-plugin/plugin.json      plugin name, version, description
  agents/*.md                     one subagent per file
  skills/<name>/SKILL.md          slash commands (/guyb:<name>); helper scripts live beside them
  hooks/                          hooks.json, orchestrator.md (playbook), guard-secrets.sh
scripts/                          install.ps1/.sh, launch.ps1/.sh (the `guyb` command)
settings/                         recommended-permissions.json
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

## Conventions

- **Agents** (`agents/*.md`) have frontmatter with `name`, `description` (when to use it), `tools`, and `model`. Keep the body focused on role, approach, and report format.
- **Skills** (`skills/<name>/SKILL.md`) have frontmatter with `name`, `description`, and `argument-hint` where it takes input. Put step-by-step mechanics here.
- **Keep the playbook short.** `hooks/orchestrator.md` is loaded into every session, so it costs tokens every time. Mechanics belong in skills, not the playbook.
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
