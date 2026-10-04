<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo-dark.svg">
    <img src="docs/logo-light.svg" alt="guyb" width="264">
  </picture>
</h1>

<p align="center"><a href="https://github.com/alamhanz/guyb/actions/workflows/ci.yml"><img src="https://github.com/alamhanz/guyb/actions/workflows/ci.yml/badge.svg" alt="CI"></a></p>

> From *guyub* (Javanese/Indonesian): a tight, harmonious collective where members work in sync.

guyb is a Claude Code plugin: one orchestrator per project that plans the work, then runs a team of 13 specialist subagents in parallel background waves while you keep chatting with it.

<p align="center"><img src="docs/how-guyb-works.svg" alt="You send a request; the orchestrator gets a plan from the architect; implementers and a data-modeler run in parallel while you keep chatting; then code review and a pull request." width="800"></p>

## How it works

1. A small change (max 3 files, 20 lines) is done inline; no agent is spawned.
2. Otherwise the `architect` returns scope, risks, a task table, and open questions. You answer and say OK.
3. Tasks are grouped into **waves**: runs in a wave are independent and start together. Parallel agents get disjoint files and worktree isolation. Up to `max_parallel` run at once (default 5).
4. `code-reviewer` reviews (skipped for docs-only changes), `git-ops` opens the PR, `/guyb:end` records the session in `STATE.md`.

While agents run you can talk about anything else; ask "what's running?" and the orchestrator answers from `.claude/guyb/pipeline/runs.md` and each run's progress file. Details: [`plugins/guyb/skills/pipeline/SKILL.md`](plugins/guyb/skills/pipeline/SKILL.md).

## Install

Needs [Claude Code](https://code.claude.com/docs) v2.1.280+ and `git` (Git for Windows on Windows). `gh`, `glab`, `aws`, `gcloud`, `az` and DB clients are optional.

```powershell
# Windows (PowerShell 7): plugin + recommended permissions + launcher
git clone https://github.com/alamhanz/guyb.git
./guyb/scripts/install.ps1 -ProjectsRoot D:\projects
```

```bash
# macOS / Linux
git clone https://github.com/alamhanz/guyb.git
./guyb/scripts/install.sh --root ~/projects
```

Options (`-SkipPermissions` / `--skip-permissions`, `--skip-launcher`) are in the script headers. The permission rules are in [`settings/recommended-permissions.json`](settings/recommended-permissions.json): allow read-only git/cloud, ask on destructive ops, deny reading `.env` and key files.

**Plugin only:**

```
claude plugin marketplace add alamhanz/guyb
claude plugin install guyb@guyb
```

Then run `/guyb:setup` once in any project: it detects installed CLIs and logins, installs what you choose (asking first), and records a no-secrets profile in `~/.claude/guyb/profile.md`. It can also install a status line (with consent, never replacing an existing `statusLine`); to remove it, delete the `statusLine` key in `~/.claude/settings.json` and `~/.claude/guyb/statusline.*`.

**Updates and releases.** A tag and GitHub Release are created automatically when the plugin version is bumped on main. Update with:

```
claude plugin marketplace update guyb; claude plugin update guyb@guyb
```

## Usage

Tested mainly on Windows (PowerShell 7, Windows PowerShell 5.1, Windows Terminal) and WSL. macOS and Linux are covered by CI but less used in practice. Claude Desktop and Cowork may work, not guaranteed. If a guyb script fails on your platform, Claude is expected to do the step another way and tell you, then offer `/guyb:report-issue` (a redacted draft, filed as a public GitHub issue only with your consent).

**From the projects root.** Start `claude` in the folder that holds your projects and say "activate guyb" or "let's start myapp". It runs the setup check, shows a picker (skipped if you named a project), and opens the project in a new tab running `/guyb:start`. Or use the shell launcher:

```
guyb              # pick from GUYB_ROOT
guyb myapp        # open GUYB_ROOT/myapp in a new tab
```

Flags and the `-List` / `--list` format are in the headers of `scripts/launch.ps1` and `scripts/launch.sh`.

**Tabs.** Each launched tab keeps the project name as its title, with a colour derived from the name. The title is `<icon> <project>`: hourglass while Claude works, check mark when done, question mark when it waits for you (`GUYB_TAB_ASCII=1` gives `*` `+` `?`). guyb sets `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`, which is not a documented Claude Code setting; if an update drops it, Claude's own title may show again.

**In a project.** `/guyb:start` gives a briefing (branch, open PRs, next steps from `.claude/guyb/STATE.md`, outdated plugin, stale `STATE.md` entries, environment mismatches), drafts `.claude/CLAUDE.md` on first use, and asks what to work on. Then just talk: "add rate limiting to the API and ship it".

| Command | What it does |
|---|---|
| `/guyb:start [task]` | briefing, bootstrap project config, plan the task |
| `/guyb:launch [project]` | at the projects root: setup check, picker, open in a new tab |
| `/guyb:setup [area]` | one-time global setup: git host, cloud, DB clients |
| `/guyb:build <what>` | architect, implementers, review, PR |
| `/guyb:ship` | review, commit, push, PR, CI status |
| `/guyb:status` | status table across all projects |
| `/guyb:env [python\|node\|docker]` | set up the project's local environment after consent |
| `/guyb:creds [what]` | add credentials for this project (values go in `.env`, never the chat) |
| `/guyb:end` | record the session in `.claude/guyb/STATE.md` |
| `/guyb:report-issue` | draft a redacted bug report and file it on the guyb repo after you approve it |

## The team

| Agent | Model | Role |
|---|---|---|
| `architect` | opus | plans every non-small request; never edits code |
| `implementer` | sonnet | code and tests from the plan |
| `code-reviewer` | opus | critical / should fix / consider, with a security pass |
| `data-modeler` | opus | schemas, indexes, migrations |
| `data-analyst` | sonnet | EDA, stats, notebooks |
| `ml-engineer` | sonnet | baseline-first ML, leakage checks, serving |
| `mcp-developer` | sonnet | MCP servers and clients |
| `git-ops` | sonnet | branches, commits, PRs/MRs, CI, releases (GitHub, GitLab, Bitbucket) |
| `cloud-ops` | sonnet | identity-first AWS / GCP / Azure inspect and change |
| `deployer` | sonnet | test, build, deploy, verify live |
| `repo-steward` | sonnet | status and hygiene across repos |
| `brand-designer` | sonnet | logo and brand mark: SVG concepts, preview page, README block |
| `session-tracker` | haiku | end-of-session `STATE.md` update, docs drift |

Change defaults via `model:` in `plugins/guyb/agents/*.md`. Every agent starts with fresh context, so guyb spends agents where they pay off: small changes run inline, independent big areas run in parallel, haiku/sonnet/opus are picked per run. Set the parallel cap with `max_parallel: N` in the project `.claude/CLAUDE.md` or `~/.claude/guyb/profile.md` (project wins).

## Files guyb creates

| File | Commit it? |
|---|---|
| `.claude/CLAUDE.md` (stack, commands, credential names) | yes |
| `.claude/guyb/STATE.md` (status, decisions, next steps; line 1 is the marker `<!-- guyb:state -->`) | yes |
| `.env` (secrets; guyb makes sure it is gitignored) / `.env.example` | never / yes |
| `.claude/guyb/pipeline/` (plans, run registry, progress, questions) | no, auto-gitignored |

Upgrading from 0.6: files used to live in `.claude/STATE.md` and `.claude/pipeline/`. `/guyb:start` offers to move them; nothing moves without your OK. Cleanup suggestions never archive or delete without consent.

## Security

guyb manages where credentials live but never stores or sees their values.

- **Commit guard.** A hook blocks `git commit` when `.env`, keys, or credential files are staged, in both Bash and PowerShell, including `git -C dir commit`, `git -c ... commit`, `--git-dir`, chained commands, common wrappers (`env`, `sudo`, `time`, `if`/`then`, `$x = git commit`), `commit -a` and pathspecs. When the same command runs `git add`/`git stage` first, untracked files and the add paths are checked too. If the parser finds no commit but the text names git and commit (for example `git -c alias.x=commit x` or `bash -c "..."`), the repo in the current directory is checked; gitconfig aliases such as `git ci` are not resolved. Limits: no shell variable expansion or subshell scoping, ignored files are checked only when named in `git add`, and a repo git cannot read is allowed.
- **Read-only agents.** A second hook stops `architect`, `code-reviewer`, `data-modeler` and `data-analyst` from running git write commands. It is a best-effort, case-insensitive text match (quoted or full-path git, `-C`/`--git-dir`/`-p`, verbs such as `add`, `stage`, `commit`, `config` writes, `notes`, `submodule`); the agents' prompt rules are the main control.
- Other hooks only print the playbook at session start and update the tab icon. Plugins run with your permissions, so read the agents and hooks before installing.

## More

- [CONTRIBUTING.md](CONTRIBUTING.md): develop, test, and send changes
- [CREDITS.md](CREDITS.md): MIT-licensed work this was adapted from
- [LICENSE](LICENSE): MIT
