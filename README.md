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
             │    cloud-ops · deployer · repo-steward · session-tracker
             └─ relays results, asks you only for real decisions
```

## How it works

- **One tab = one project = one orchestrator.** The `guyb` launcher opens a Windows Terminal tab (or tmux window) in the project folder and starts Claude with `/guyb:start`.
- **The orchestrator plans and delegates.** A `SessionStart` hook loads the orchestrator playbook into every session. It keeps a visible todo list and hands steps to subagents.
- **Subagents run in the background.** You keep talking to the orchestrator while they work; results come back to it and it summarizes them for you. Subagents never talk to you directly, and permission prompts still surface in your tab.
- **State survives sessions.** `session-tracker` keeps `.claude/STATE.md` per project: status, change log, decisions, open issues, next steps.
- **Accounts are set up once, credentials per project.** `/guyb:setup` connects your git host and cloud once for all projects; `/guyb:creds` adds what a single project needs. guyb never stores secret values.

## Install

Requirements: [Claude Code](https://code.claude.com/docs) v2.1.280+ and `git` (on Windows, Git for Windows, whose Git Bash runs guyb's hooks). Everything else (`gh`, `glab`, `aws`, `gcloud`, `az`, database clients) is optional; `/guyb:setup` offers to install what you choose.

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
2. merges [`settings/recommended-permissions.json`](settings/recommended-permissions.json) into `~/.claude/settings.json` (backup kept):
   - **allow**: read-only git, gh, and glab commands, explicit read-only cloud commands per service (e.g. `aws ec2 describe-*`, `gcloud run services list`, `az vm show`), plus normal commits and pushes. Commands that print secrets (`aws secretsmanager get-secret-value`, `gcloud secrets versions access`, …) always ask,
   - **ask**: destructive operations (force-push, hard reset, PR/MR merge, cloud delete/terminate, IAM and role changes),
   - **deny**: reading secret files (`.env`, `*.pem`, `*.key`, cloud credential files).

   Skip this step with `-SkipPermissions` / `--skip-permissions`.
3. adds the `guyb` command to your shell profile.

### Option B: plugin only

```
claude plugin marketplace add alamhanz/guyb
claude plugin install guyb@guyb
```

### Then: one-time global setup

Open any project (`guyb myapp`) and run:

```
/guyb:setup
```

The wizard:
1. **Detects** what's installed and logged in: git identity, gh / glab / Bitbucket, aws / gcloud / az, and database clients.
2. **Asks** which git host (GitHub, GitLab, Bitbucket), which cloud (AWS, GCP, Azure), which databases, and any other services you use.
3. **Installs** missing CLIs with winget / brew / apt, showing each command and asking first.
4. **Guides logins.** You run them yourself with the `!` prefix (e.g. `! gh auth login`, `! aws configure sso`, `! gcloud auth login`, `! az login`), because they open a browser or ask for a password.
5. **Verifies** each login with a read-only identity check.
6. **Records** a no-secrets profile in `~/.claude/guyb/profile.md`: which accounts, profiles, and regions you use.

Run `/guyb:setup git`, `/guyb:setup cloud`, or similar to redo one area later.

## Usage guide (terminal)

> **guyb is built and tested for the terminal** (Windows Terminal, or tmux on macOS/Linux). Claude Desktop (Code tab) and Cowork can load parts of the plugin, but they aren't documented or tested yet. See [Roadmap](#roadmap).

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
- on first use, **drafts `.claude/CLAUDE.md`** for the project (stack, git host, run/test/build/deploy commands, cloud account and region, credential names) and asks before saving it,
- checks that the env vars the code uses exist in `.env` (by name only) and offers `/guyb:creds` for anything missing,
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
| `/guyb:setup [area]` | one-time global setup: git host, cloud, DB clients, other services |
| `/guyb:creds [what]` | add credentials for this project only (see [Credentials](#credentials)) |

For anything with several steps, the orchestrator shows the plan as a **todo list** that updates as agents finish. For big or risky plans it shows a summary and waits for your OK before writing code.

### 4. Watch the subagents (optional)

Subagents run in the background. Keep chatting with the orchestrator; it relays their results when they finish.

**Run IDs and waves.** Every subagent run gets an ID like `myapp-3` (project folder name + a counter that keeps going across sessions). The todo list shows each run with its wave, e.g. `[myapp-3] implementer: API routes (wave 2, after myapp-1)`. Runs in the same wave go in parallel (at most 4 at once, the rest queue); a wave waits for the runs it depends on.

**Ask the orchestrator mid-run.** Each subagent keeps a short progress file (`.claude/pipeline/progress/<id>.md`: done / doing / next / blockers) and the orchestrator keeps a registry of all runs (`.claude/pipeline/runs.md`). So you can ask:

```
> how's myapp-3 doing?
> what's running right now?
```

and the orchestrator answers from those files, with how fresh they are. It can't see more than the agent has written, so for the live transcript use the panel under the prompt, which shows one row per running agent:

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
| `.claude/CLAUDE.md` | project facts: stack, commands, cloud account/region, credential *names* | yes |
| `.env` | this project's secret values | **never** (guyb makes sure it's gitignored) |
| `.env.example` | the same names with placeholder values | yes |
| `.claude/STATE.md` | status, change log, decisions, next steps | yes (it's useful history) |
| `.claude/pipeline/plan.md` | the architect's current plan | optional; add `.claude/pipeline/` to `.gitignore` if you prefer |
| `.claude/pipeline/runs.md` | registry of subagent runs: ID, agent, task, wave, status | optional, same as above |
| `.claude/pipeline/progress/<id>.md` | each run's live progress | no (scratch; `/guyb:end` cleans up finished ones) |

### Tips

- **Several projects at once:** one tab per project. To see all sessions on one screen, try Claude Code's built-in agent view: `claude agents`.
- **Small tasks** ("rename this function") skip the pipeline; the orchestrator just does them.
- **Usage:** subagents use extra tokens, and a full `/guyb:build` costs noticeably more than a single chat. `architect`, `code-reviewer`, and `data-modeler` run on Opus; switch them to `sonnet` (see [The team](#the-team)) to save usage.
- **Cloud:** `cloud-ops` always prints the provider, account/project/subscription, and region before doing anything, and passes the profile explicitly instead of relying on whichever account is active.

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
| `git-ops` | sonnet | branches, conventional commits, PRs/MRs, CI logs, issues, releases on GitHub (`gh`), GitLab (`glab`), Bitbucket (REST API) |
| `cloud-ops` | sonnet | identity-first AWS / GCP / Azure inspect, troubleshoot, cost, IaC-first changes |
| `deployer` | sonnet | test -> build -> deploy -> **verify live** -> record |
| `repo-steward` | sonnet | portfolio status and hygiene across all repos |
| `session-tracker` | haiku | `.claude/STATE.md` briefings, change log, docs drift |

To use cheaper models, change `model:` in `plugins/guyb/agents/*.md`.

## Credentials

guyb has one rule: **it manages where credentials live and checks that they work, but never stores or sees the values.**

| Level | What | Where the secret lives | What guyb records |
|---|---|---|---|
| Global (`/guyb:setup`) | git host, cloud accounts, other service logins | each CLI's own credential store (`gh`, `glab`, `aws`, `gcloud`, `az`); Bitbucket and global API keys in user-level env vars | `~/.claude/guyb/profile.md`: account names, profiles, regions |
| Project (`/guyb:creds`) | database URLs, API keys, a different cloud account | the project's gitignored `.env`; cloud accounts as named CLI profiles (`aws --profile myapp-staging`, a gcloud configuration, an Azure subscription) | `.claude/CLAUDE.md` `## Credentials`: names and locations, with the date last verified |

When a task needs a credential that isn't set up, the orchestrator pauses that step and runs `/guyb:creds`:
1. It finds the env vars the code uses and compares them, by name only, with `.env`.
2. It makes sure `.env` is gitignored and `.env.example` lists every name.
3. It tells you which lines to add. **You open `.env` in your editor and paste the values there**, never into the chat: the transcript is saved, and so are `!` commands.
4. It verifies each credential without printing it (e.g. `select 1` against the database, or a whoami API call).
5. It records the names in `.claude/CLAUDE.md`.

### Safety nets
- **Commit guard:** a hook blocks `git commit` when `.env`, `*.pem`, `*.key`, private SSH keys, `credentials*`, or service-account JSON files are staged. `.example`/`.sample`/`.template` files and `.pub` keys are allowed.
- **Deny rules** stop Claude from reading `.env`, key files, and cloud credential files with its file tools or `cat`. This is a guardrail, not a sandbox: a determined shell command could still read them. Keep real production secrets in a cloud secret manager.
- If a real `.env` is already tracked by git, `/guyb:creds` stops and tells you to remove it from git **and rotate the leaked values**.

## Customize

Fork the repo, edit `plugins/guyb/agents/*.md`, `skills/*/SKILL.md`, or `hooks/orchestrator.md`, then run `claude plugin validate ./plugins/guyb`. If you installed from a local clone, changes apply on the next session start or `/reload-plugins`.

## Security notes

Plugins run with your user permissions. Read the agents and the hooks before installing. The hooks do two things only: print `hooks/orchestrator.md` at session start, and check staged file *names* before a commit (`hooks/guard-secrets.sh`). Nothing here sends data anywhere except through tools you already use (`git`, `gh`, `glab`, `aws`, `gcloud`, `az`).

## Roadmap

- **Claude Desktop (Code tab):** loads plugins installed on your machine, so guyb's agents, commands, and hook should work there. Sessions in its sidebar replace terminal tabs. Not yet tested or documented.
- **Cowork:** loads agents, hooks, and commands when you add the plugin via Customize -> Plugins from this repo. Whether local `git`/`gh`/`aws` credentials are available there is unverified, so ops agents may not work.
- More agents as needed (frontend specialist, test writer, security auditor).

## Credits

Adapted from MIT-licensed work by wshobson/agents, VoltAgent/awesome-claude-code-subagents, and ruvnet/claude-flow. See [CREDITS.md](CREDITS.md).
