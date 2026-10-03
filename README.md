# guyb

> From *guyub* (Javanese/Indonesian): a tight, harmonious collective where members work in sync.

guyb is a Claude Code plugin: one orchestrator per project that plans the work, then runs a team of 12 specialist subagents in parallel background waves while you keep chatting with it.

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
| Every session starts from zero | `.claude/STATE.md` records decisions and next steps; `/guyb:start` briefs you from it |
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

While wave 1 runs, you can talk about anything else. Ask "what's running?" and the orchestrator answers from the run registry (`.claude/pipeline/runs.md`) and each run's progress file (`.claude/pipeline/progress/<id>.md`). Details are in [`plugins/guyb/skills/pipeline/SKILL.md`](plugins/guyb/skills/pipeline/SKILL.md).

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

guyb is built and tested for the terminal (Windows Terminal, or tmux on macOS/Linux). Claude Desktop and Cowork are untested.

**From the projects root.** Start `claude` in the folder that holds your projects and say "activate guyb" or "let's start myapp". That session is a launcher (`/guyb:launch`): it runs the setup check, shows a picker (skipped if you named a project), and opens the project in a new tab running `/guyb:start`. Or use the shell launcher directly:

```
guyb              # pick from GUYB_ROOT
guyb myapp        # open GUYB_ROOT/myapp in a new tab
```

Launcher flags and the `-List` / `--list` output format are documented in the headers of `scripts/launch.ps1` and `scripts/launch.sh`; the check JSON is described in `plugins/guyb/skills/launch/SKILL.md`.

**In a project.** `/guyb:start` gives a briefing (branch, open PRs, next steps from `.claude/STATE.md`), drafts `.claude/CLAUDE.md` on first use, and asks what to work on. Then just talk: "add rate limiting to the API and ship it".

| Command | What it does |
|---|---|
| `/guyb:start [task]` | briefing, bootstrap project config, plan the task |
| `/guyb:launch [project]` | at the projects root: setup check, picker, open in a new tab |
| `/guyb:setup [area]` | one-time global setup: git host, cloud, DB clients |
| `/guyb:build <what>` | architect, implementers, review, PR |
| `/guyb:ship` | review, commit, push, PR, CI status |
| `/guyb:status` | status table across all projects |
| `/guyb:creds [what]` | add credentials for this project (values go in `.env`, never the chat) |
| `/guyb:end` | record the session in `.claude/STATE.md` |

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
| `.claude/STATE.md` (status, decisions, next steps) | yes |
| `.env` (secrets; guyb makes sure it is gitignored) / `.env.example` | never / yes |
| `.claude/pipeline/` (plans, run registry, progress, questions) | no, auto-gitignored |

## Security

guyb manages where credentials live but never stores or sees their values. A commit guard hook blocks staging `.env`, keys, and credential files. Hooks only print the playbook at session start and check staged file names. Plugins run with your permissions, so read the agents and hooks before installing.

## More

- [CONTRIBUTING.md](CONTRIBUTING.md): develop, test, and send changes
- [CREDITS.md](CREDITS.md): MIT-licensed work this was adapted from
- [LICENSE](LICENSE): MIT
