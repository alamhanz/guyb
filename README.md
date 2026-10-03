# guyb

> From *guyub* (Javanese/Indonesian): a tight, harmonious collective where members work in sync with strong camaraderie.

A plugin for Claude Code. It turns every Claude Code session into a **project orchestrator** with a team of specialist subagents, and open each project in its own terminal tab with one command.

```
guyb myapp
   └─ new terminal tab "myapp"  ->  claude /guyb:start
        └─ Orchestrator (the session you talk to)
             ├─ briefing from .claude/STATE.md, plan as a todo list
             ├─ delegates in the background, you keep chatting:
             │    architect -> implementer(s) -> code-reviewer -> git-ops
             │    data-modeler · data-analyst · ml-engineer · mcp-developer
             │    aws-ops · deployer · repo-steward · session-tracker
             └─ relays results, asks you only for real decisions
```

## How it works

- **One tab = one project = one orchestrator.** The `guyb` launcher opens a Windows Terminal tab (or tmux window) in the project folder and starts Claude with `/guyb:start`.
- **The orchestrator plans and delegates.** A `SessionStart` hook loads the orchestrator playbook into every session. It keeps a visible todo list and hands steps to subagents.
- **Subagents run in the background.** You keep talking to the orchestrator while they work; results come back to it and it summarizes them for you. Subagents never talk to you directly, and permission prompts still surface in your tab.
- **State survives sessions.** `session-tracker` keeps `.claude/STATE.md` per project: status, change log, decisions, open issues, next steps.

## Install

Requirements: [Claude Code](https://code.claude.com/docs) v2.1.280+, `git`. Optional: `gh` (GitHub CLI, logged in) for PR/issue work, `aws` CLI v2 for AWS work.

### Option A: full setup (plugin + permissions + launcher)

```powershell
# Windows (PowerShell 7)
git clone https://github.com/alamhanz/guyb.git
./guyb/scripts/install.ps1 -ProjectsRoot D:\projects
```

```bash
# macOS / Linux
git clone https://github.com/alamhanz/guyb.git
./guyb/scripts/install.sh --root ~/projects
```

The installer:
1. adds this repo as a plugin marketplace and installs the `guyb` plugin (user scope),
2. merges [`settings/recommended-permissions.json`](settings/recommended-permissions.json) into `~/.claude/settings.json` (backup kept). Read-only git/gh/aws commands are allowed, normal commits and pushes are allowed, and destructive operations (force-push, hard reset, PR merge, AWS delete/terminate, IAM) always ask. Skip with `-SkipPermissions` / `--skip-permissions`,
3. adds the `guyb` command to your shell profile.

### Option B: plugin only

```
claude plugin marketplace add alamhanz/guyb
claude plugin install guyb@guyb
```

## Usage guide (terminal)

> **v0.1 is built and tested for the terminal** (Windows Terminal, or tmux on macOS/Linux). Claude Desktop (Code tab) and Cowork can load parts of the plugin, but they aren't documented or tested yet. See [Roadmap](#roadmap).

### 1. Open a project

```powershell
guyb               # numbered list of projects in GUYB_ROOT -> pick one
guyb myapp         # open GUYB_ROOT/myapp in a new terminal tab titled "myapp"
guyb D:\code\x     # any folder by path
guyb myapp -Here   # (PowerShell) run in the current terminal instead of a new tab
```

Each tab is one project with its own orchestrator. Open as many tabs as you have projects in flight. Without the launcher, `cd` into the project and run `claude`, then `/guyb:start`.

### 2. Start the session

The tab runs `/guyb:start` for you. The orchestrator:
- gives a **briefing**: branch, uncommitted work, open PRs, and "next up" from `.claude/STATE.md`,
- on first use, **drafts `.claude/CLAUDE.md`** for the project (stack, run/test/build/deploy commands, AWS profile and region) and asks before saving it,
- asks what you want to work on.

### 3. Give it work

Talk normally. The orchestrator decides which agents to use:

```
> add rate limiting to the API and ship it
> analyze data/sales.csv - why did March revenue drop?
> build an MCP server that exposes our Postgres read-only
> the Lambda in prod is timing out, find out why
> what's the status of PR #4?
```

Or use a command to run a full workflow:

| Command | What it does |
|---|---|
| `/guyb:start [task]` | briefing, bootstrap `.claude/CLAUDE.md` if missing, plan the task |
| `/guyb:build <what>` | architect -> parallel implementers -> review -> PR |
| `/guyb:ship` | review -> commit -> push -> PR -> CI status |
| `/guyb:status` | status table across all projects |
| `/guyb:end` | record the session in `.claude/STATE.md` |

For anything with several steps, the orchestrator shows the plan as a **todo list** that updates as agents finish. For big or risky plans it shows a summary and waits for your OK before writing code.

### 4. Watch the subagents (optional)

Subagents run in the background. Keep chatting with the orchestrator; it relays their results when they finish. A panel under the prompt shows one row per running agent:

| Key | Action |
|---|---|
| `↑` / `↓` | select an agent row |
| `Enter` | open that agent's live transcript |
| `x` | stop the selected agent |
| `Esc` | back to your prompt |
| `/tasks` | list all running agents with their model and status |

Agents never ask you questions directly. Permission prompts and decisions (🔴 review findings, big plans, production deploys, anything destructive) come to you through the orchestrator.

### 5. End the session

Run `/guyb:end`. `session-tracker` appends what changed, the decisions made, open issues, and next steps to `.claude/STATE.md`, and fixes docs that no longer match the code. The next `/guyb:start` picks up from there.

### Files guyb creates in your projects

| File | Purpose | Commit it? |
|---|---|---|
| `.claude/CLAUDE.md` | project facts: stack, commands, AWS profile/region | yes |
| `.claude/STATE.md` | status, change log, decisions, next steps | yes (it's useful history) |
| `.claude/pipeline/plan.md` | the architect's current plan | optional; add `.claude/pipeline/` to `.gitignore` if you prefer |

### Tips

- **Several projects at once:** one tab per project. To see all sessions on one screen, try Claude Code's built-in agent view: `claude agents`.
- **Small tasks** ("rename this function") skip the pipeline; the orchestrator just does them.
- **Usage:** subagents use extra tokens, and a full `/guyb:build` costs noticeably more than a single chat. `architect`, `code-reviewer`, and `data-modeler` run on Opus; switch them to `sonnet` (see [The team](#the-team)) to save usage.
- **AWS:** log in first (`aws configure sso` or `aws configure`). `aws-ops` always prints the account and region before doing anything.

## The team

| Agent | Model | Role |
|---|---|---|
| `architect` | opus | plans builds into `.claude/pipeline/plan.md`; never edits code |
| `implementer` | sonnet | implements the plan + tests; flags plan deviations |
| `code-reviewer` | opus | 🔴 critical / 🟡 should fix / 💡 consider; mandatory security pass |
| `data-modeler` | opus | schemas, DB choice, indexes, zero-downtime migrations, warehouse models |
| `data-analyst` | sonnet | EDA, data quality, stats with effect sizes, reproducible notebooks |
| `ml-engineer` | sonnet | baseline-first ML, leakage checks, experiment tracking, serving |
| `mcp-developer` | sonnet | MCP servers/clients with the official SDKs, tested with the Inspector |
| `git-ops` | sonnet | branches, conventional commits, PRs, CI logs, issues, releases |
| `aws-ops` | sonnet | identity-first AWS inspect / troubleshoot / cost / IaC-first changes |
| `deployer` | sonnet | test -> build -> deploy -> **verify live** -> record |
| `repo-steward` | sonnet | portfolio status and hygiene across all repos |
| `session-tracker` | haiku | `.claude/STATE.md` briefings, change log, docs drift |

To use cheaper models, change `model:` in `plugins/guyb/agents/*.md`.

## Per-project configuration

`/guyb:start` offers to create `.claude/CLAUDE.md` in each project, with its stack, run/test/build/deploy commands, and **AWS profile + region**. Agents read it, so each project can target a different AWS account.

## Customize

Fork the repo, edit `plugins/guyb/agents/*.md`, `skills/*/SKILL.md`, or `hooks/orchestrator.md`, then run `claude plugin validate ./plugins/guyb`. If you installed from a local clone, changes apply on the next session start or `/reload-plugins`.

## Security notes

Plugins run with your user permissions. Read the agents and the hook before installing. The hook only prints `hooks/orchestrator.md`. Nothing here sends data anywhere except through tools you already use (`git`, `gh`, `aws`).

## Roadmap

- **Claude Desktop (Code tab):** loads plugins installed on your machine, so guyb's agents, commands, and hook should work there. Sessions in its sidebar replace terminal tabs. Not yet tested or documented.
- **Cowork:** loads agents, hooks, and commands when you add the plugin via Customize -> Plugins from this repo. Whether local `git`/`gh`/`aws` credentials are available there is unverified, so ops agents may not work.
- More agents as needed (frontend specialist, test writer, security auditor).

## Credits

Adapted from MIT-licensed work by wshobson/agents, VoltAgent/awesome-claude-code-subagents, and ruvnet/claude-flow. See [CREDITS.md](CREDITS.md).
