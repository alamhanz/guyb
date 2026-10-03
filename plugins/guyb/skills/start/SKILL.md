---
name: start
description: Start a work session on this project as the orchestrator - briefing of current state, bootstrap project config if missing, then ask what to work on.
disable-model-invocation: true
argument-hint: "[optional: what you want to work on]"
---

Start a guyb session for the project in the current directory.

0. If the session started in the projects root (even if the working directory has since moved into a project) rather than a project (see "Session at the projects root" in the playbook): follow the `guyb:launch` skill (setup check, project list and picker, or "$ARGUMENTS" if it names a project, then open it in a new tab and tell the user to switch tabs) and stop. Skip this step if the user said to work here.

1. In parallel:
   - Run the read-only briefing script (no agent): PowerShell `pwsh -NoProfile -File "<dir>/brief.ps1" -Dir "<project folder>"` (use `powershell` if `pwsh` is missing), bash `bash "<dir>/brief.sh" "<project folder>"`. `<dir>` is `${CLAUDE_PLUGIN_ROOT}/skills/start`, then `<repo>/plugins/guyb/skills/start` (repo from `~/.claude/plugins/known_marketplaces.json`, `guyb.source.path`). On Windows use `brief.ps1`; strip any trailing `\` or `/` from the folder. It prints ~30 lines of plain text: branch and ahead/behind, uncommitted files, last 5 commits, open PRs, STATE.md next up / open issues, unfinished runs, open questions, the `max parallel` agent cap (optional `max_parallel: N` override in `.claude/CLAUDE.md` or `~/.claude/guyb/profile.md`), and whether `.claude/pipeline/` is gitignored. Brief from that output. `guyb:session-tracker` is only for **end** mode and "what changed" deep dives.
   - Check that `~/.claude/guyb/profile.md` exists. If not, mention once that `/guyb:setup` configures git hosting and cloud logins (don't block on it).
   - Check whether `.claude/CLAUDE.md` exists. If it doesn't, read the project (README, package files, Makefile, CI, infra folders) and draft one with: what the project is, stack, git host, run/test/build/deploy commands, cloud provider + profile/project/subscription + region if cloud usage is detected (otherwise a placeholder), a `## Credentials` section listing the env var *names* the code uses, and conventions you observe. Show the draft and write it only after the user OKs it.
   - If the project is a git repo and `.gitignore` doesn't ignore `.claude/pipeline/` (or `.claude/`), append `.claude/pipeline/` (create `.gitignore` if missing) without asking, and mention it in one line of the briefing. Never add `.claude/STATE.md`: it is meant to be committed.
   - Credentials check (names only, never values): compare env vars the code references (or `.env.example`) with names present in `.env`, and confirm `.env` is gitignored.
   - Load `guyb:pipeline`. From the script output: runs left `running` or `queued` from an earlier session (their agents are gone; mark them `stopped` and read their progress files for what was done). Note its open questions too.
2. Present a short briefing: project name, status, uncommitted work, open PRs/MRs, next up (from STATE.md), unfinished runs from last time, open questions from agents (ask them right after the briefing), and any missing credentials (offer `/guyb:creds` to fix them).
3. If a task was given ("$ARGUMENTS"), restate it and run it through **Intake** in the playbook (architect assesses, then plan + questions to the user). Otherwise list the suggested next steps (from STATE.md and the briefing), numbered, each with the agent that would do it, and ask which to do.
4. Whatever the user picks or asks for later goes through **Intake** unless it's small, and approved plans follow **Delegation is the default**: todo list with run IDs and waves, registry rows, then launch the agents. The orchestrator does not implement steps itself.
