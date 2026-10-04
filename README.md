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

## Why guyb

A plain Claude Code session works serially in one context. guyb changes that:

| Plain session | With guyb |
|---|---|
| Context fills with code and logs | The orchestrator only plans and integrates; agents work in fresh contexts and send short reports |
| You wait on each step | Independent work runs in parallel in the background (configurable, default 5 agents); you keep talking |
| Planning is whatever you remember to ask for | Non-trivial requests start with an architect plan and questions; you approve before code is written |
| Review and git hygiene are optional | Review runs before every PR (except docs-only); git-ops handles branch, commit, PR |
| Agents stall or guess | Agents never ask you directly; their questions are logged and routed through the orchestrator |
| Every session starts from zero | `.claude/guyb/STATE.md` records decisions and next steps; `/guyb:start` briefs you from it |
| Several projects get tangled | One terminal tab = one project = one orchestrator |

## How it works

1. You describe the work. A small change (max 3 files, 20 lines) is done inline; no agent is spawned.
2. Otherwise the `architect` returns scope, risks, a task table, and open questions. You answer and say OK.
3. The orchestrator groups the tasks into **waves**. Runs in the same wave are independent and start together; a wave starts when the runs it depends on are done. Parallel agents get disjoint files (one owner per file) and worktree isolation when they edit code at the same time.
4. `code-reviewer` reviews the result, `git-ops` opens the PR, `/guyb:end` records the session in `STATE.md`.

A wave plan, as the orchestrator tracks it:

```
[app-1] architect: plan the export feature
[app-2] implementer: API routes (wave 1, after app-1)
[app-3] implementer: UI (wave 1, after app-1)
[app-4] data-modeler: schema + migration (wave 1, after app-1)
[app-5] code-reviewer: review the diff (wave 2, after app-2, app-3, app-4)
[app-6] git-ops: branch, commit, PR (wave 3, after app-5)
```

While wave 1 runs, you can talk about anything else. Ask "what's running?" and the orchestrator answers from the run registry (`.claude/guyb/pipeline/runs.md`) and each run's progress file (`.claude/guyb/pipeline/progress/<id>.md`). Details are in [`plugins/guyb/skills/pipeline/SKILL.md`](plugins/guyb/skills/pipeline/SKILL.md).

## Install

Needs [Claude Code](https://code.claude.com/docs) v2.1.280+ and `git` (Git for Windows on Windows). Everything else (`gh`, `glab`, `aws`, `gcloud`, `az`, DB clients) is optional.

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

Options (`-SkipPermissions` / `--skip-permissions`, `--skip-launcher`) are in the script headers; the permission rules are in [`settings/recommended-permissions.json`](settings/recommended-permissions.json) (allow read-only git/cloud, ask on destructive ops, deny reading `.env` and key files).

**Plugin only:**

```
claude plugin marketplace add alamhanz/guyb
claude plugin install guyb@guyb
```

Then run `/guyb:setup` once in any project: it detects installed CLIs and logins, installs what you choose (asking first), and records a no-secrets profile in `~/.claude/guyb/profile.md`.

## Usage

### Platform support

- **Optimized for:** Claude Code in a terminal: PowerShell 7 / Windows PowerShell 5.1 in Windows Terminal, and bash. Development and manual testing happen on Windows and WSL (Ubuntu).
- **macOS and native Linux:** the scripts are written to be portable (bash 3.2, BSD tools, pwsh 7) and CI runs them on Ubuntu and macOS, but day-to-day use there is less tested. Expect rough edges.
- **Claude Desktop and Cowork:** may work, not guaranteed.
- **When a guyb script fails on your platform,** the Claude session running guyb is expected to diagnose it and do the step another way (read the files directly, use the equivalent command) and tell you what it did. It then offers `/guyb:report-issue`, which shows a redacted draft and files a public GitHub issue on the guyb repo only with your consent.

**From the projects root.** Start `claude` in the folder that holds your projects and say "activate guyb" or "let's start myapp". That session is a launcher (`/guyb:launch`): it runs the setup check, shows a picker (skipped if you named a project), and opens the project in a new tab running `/guyb:start`. Or use the shell launcher directly:

```
guyb              # pick from GUYB_ROOT
guyb myapp        # open GUYB_ROOT/myapp in a new tab
```

Launcher flags and the `-List` / `--list` output format are documented in the headers of `scripts/launch.ps1` and `scripts/launch.sh`; the check JSON is described in `plugins/guyb/skills/launch/SKILL.md`.

**Tabs and status line.** With many tabs open, each `guyb myapp` tab keeps a stable title (the project name) and a colour derived from that name (8-colour palette, same name = same colour). Windows Terminal: `--tabColor`. tmux: window rename is turned off for that window only, and the window status is coloured. Other terminals: the launcher writes the title once (OSC 0) before starting Claude. Every guyb-launched tab also sets `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` so Claude does not overwrite the title. That variable is not in Claude Code's documented settings; it was seen to stop the title write at startup only. If a Claude Code update drops it, Claude's own title may show again; only tmux keeps a lock (its window rename is turned off).

**Tab status icon.** The title is `<icon> <project>` and the icon follows Claude: hourglass while it works, check mark when it is done, question mark when it waits for input or permission (the plugin's hooks `UserPromptSubmit`, `PostToolUse`, `Notification`, `Stop`, `SessionEnd`, async, only in guyb-launched tabs where `GUYB_TAB_NAME` is set). It works in tmux (window name), in Windows Terminal (the hook attaches to the Claude Code console; the hook takes about a second there, so the icon lags), and in terminals that accept OSC 0 on Linux, macOS and WSL. Set `GUYB_TAB_ASCII=1` (or `TERM=linux`/`dumb`) for `*` `+` `?` instead of emoji. In `claude -p` runs the last icon may not update, because Claude exits before the async hook finishes.

`/guyb:setup` can also install a status line (with your consent, never replacing an existing `statusLine` without asking): `guyb > myapp  main  2 running  1 question`, read from `.claude/guyb/pipeline/` and the git HEAD file, no network. It copies the scripts to `~/.claude/guyb/` and adds a `statusLine` entry to `~/.claude/settings.json`. To uninstall: remove the `statusLine` key and delete `~/.claude/guyb/statusline.*`.

**In a project.** `/guyb:start` gives a briefing (branch, open PRs, next steps from `.claude/guyb/STATE.md`; it also flags an outdated plugin and `STATE.md` entries about PRs that are already merged or closed, and shows an `env:` line when the project's Python, Node, package manager, or Docker is missing or mismatched), drafts `.claude/CLAUDE.md` on first use, and asks what to work on. Then just talk: "add rate limiting to the API and ship it".

| Command | What it does |
|---|---|
| `/guyb:start [task]` | briefing, bootstrap project config, plan the task |
| `/guyb:launch [project]` | at the projects root: setup check, picker, open in a new tab |
| `/guyb:setup [area]` | one-time global setup: git host, cloud, DB clients |
| `/guyb:build <what>` | architect, implementers, review, PR |
| `/guyb:ship` | review, commit, push, PR, CI status |
| `/guyb:status` | status table across all projects |
| `/guyb:env [python\|node\|docker]` | set up the project's local environment (venv, dependencies, image pull) after consent |
| `/guyb:creds [what]` | add credentials for this project (values go in `.env`, never the chat) |
| `/guyb:end` | record the session in `.claude/guyb/STATE.md` |
| `/guyb:report-issue` | draft a redacted bug report for a guyb failure and file it on the guyb repo after you approve it |

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

Change defaults via `model:` in `plugins/guyb/agents/*.md`; the orchestrator can pick another model per run.

## Cost rules

Every agent starts with fresh context (roughly 15-50k tokens), so guyb spends agents where they pay off:

- Heavy work goes parallel: independent big areas (roughly >100 changed lines each) get their own implementers, up to `max_parallel` at once (default 5), or whenever you ask for speed. Otherwise one implementer does the parts in sequence.
- Set the cap with a line `max_parallel: N` in the project `.claude/CLAUDE.md` or `~/.claude/guyb/profile.md` (project wins). Higher is faster but uses more tokens and risks rate limits.
- Small changes (max 3 files, 20 lines, no new tests) are done inline.
- Model per run: haiku for mechanical work, sonnet for normal work, opus only for large planning, hard debugging, security review.
- Review is skipped for docs-only changes and limited to one round for small diffs.
- Briefings come from a script, not an agent.
- Agent reports are short, and follow-up fixes go to the same agent.

## Files guyb creates

| File | Commit it? |
|---|---|
| `.claude/CLAUDE.md` (stack, commands, credential names) | yes |
| `.claude/guyb/STATE.md` (status, decisions, next steps; line 1 is the marker `<!-- guyb:state -->`) | yes |
| `.env` (secrets; guyb makes sure it is gitignored) / `.env.example` | never / yes |
| `.claude/guyb/pipeline/` (plans, run registry, progress, questions; `runs-archive.md` / `questions-archive.md` after a cleanup) | no, auto-gitignored |

**Upgrading from 0.6.** Files used to live in `.claude/STATE.md` and `.claude/pipeline/`. `/guyb:start` offers to move them to `.claude/guyb/`; nothing moves without your OK, and a `.claude/STATE.md` that guyb did not write (no marker, not guyb's structure) is never touched.

**Cleanup suggestions.** `/guyb:start` suggests a cleanup when `.claude/CLAUDE.md` passes 200 lines, `STATE.md` 300 lines, `runs.md` or `questions.md` 200 rows, or scratch files under `pipeline/` are older than 14 days. Unfinished runs and open questions older than 14 days are listed as overdue and asked about one by one; nothing is archived or deleted without consent. Override the limits with lines in the project `.claude/CLAUDE.md` or `~/.claude/guyb/profile.md` (project wins): `cleanup_claude_md_lines: 200`, `cleanup_state_lines: 300`, `cleanup_rows: 200`, `cleanup_days: 14` (positive integers; invalid values are ignored). If `.gitignore` ignores all of `.claude/`, the briefing warns that `STATE.md` will not be committed.

## Security

guyb manages where credentials live but never stores or sees their values. A commit guard hook blocks `git commit` when `.env`, keys, or credential files are staged; it covers both Bash and PowerShell commits, including `git -C dir commit`, `git -c ... commit`, `--git-dir`, chained commands, common wrappers (`env`, `sudo`, `time`, `if`/`then`, `$x = git commit`), `commit -a` and pathspecs. When the same command runs `git add`/`git stage` first, untracked files and the add paths are checked too. If the parser cannot find a commit but the text names git and commit (for example `git -c alias.x=commit x` or `bash -c "..."`; aliases defined in gitconfig, such as `git ci`, are not resolved), the repo in the current directory is checked. Limits: no shell variable expansion or subshell scoping, ignored files are checked only when named in `git add`, and a repo git cannot read is allowed. A second hook stops the read-only subagents (`architect`, `code-reviewer`, `data-modeler`, `data-analyst`) from running git write commands (a best-effort, case-insensitive text match covering quoted or full-path git, `-C`/`--git-dir`/`-p` options and write verbs such as `add`, `stage`, `commit`, `config` writes, `notes`, `submodule`; the agents' prompt rules are the main control). Hooks only print the playbook at session start and check file names about to be committed and subagent git commands. Plugins run with your permissions, so read the agents and hooks before installing.

## More

- [CONTRIBUTING.md](CONTRIBUTING.md): develop, test, and send changes
- [CREDITS.md](CREDITS.md): MIT-licensed work this was adapted from
- [LICENSE](LICENSE): MIT
