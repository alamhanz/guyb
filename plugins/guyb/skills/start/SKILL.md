---
name: start
description: Start a work session on this project as the orchestrator - briefing of current state, bootstrap project config if missing, then ask what to work on.
disable-model-invocation: true
argument-hint: "[optional: what you want to work on]"
---

Start a guyb session for the project in the current directory.

0. If the current directory is the projects root rather than a project (see "Session at the projects root" in the playbook): list its project folders, ask which one (use "$ARGUMENTS" if it names one), open it in a new tab with the launcher as the playbook describes, tell the user to switch tabs, and stop. Skip this step if the user said to work here.

1. In parallel:
   - Run the `guyb:session-tracker` agent in **start** mode for a briefing.
   - Check that `~/.claude/guyb/profile.md` exists. If not, mention once that `/guyb:setup` configures git hosting and cloud logins (don't block on it).
   - Check whether `.claude/CLAUDE.md` exists. If it doesn't, read the project (README, package files, Makefile, CI, infra folders) and draft one with: what the project is, stack, git host, run/test/build/deploy commands, cloud provider + profile/project/subscription + region if cloud usage is detected (otherwise a placeholder), a `## Credentials` section listing the env var *names* the code uses, and conventions you observe. Show the draft and write it only after the user OKs it.
   - Credentials check (names only, never values): compare env vars the code references (or `.env.example`) with names present in `.env`, and confirm `.env` is gitignored.
   - If `.claude/pipeline/runs.md` exists, note runs left `running` or `queued` from an earlier session (their agents are gone; mark them `stopped` and read their progress files for what was done). If `.claude/pipeline/questions.md` exists, note its `open` questions.
2. Present a short briefing: project name, status, uncommitted work, open PRs/MRs, next up (from STATE.md), unfinished runs from last time, open questions from agents (ask them right after the briefing), and any missing credentials (offer `/guyb:creds` to fix them).
3. If a task was given ("$ARGUMENTS"), restate it and run it through **Intake** in the playbook (architect assesses, then plan + questions to the user). Otherwise list the suggested next steps (from STATE.md and the briefing), numbered, each with the agent that would do it, and ask which to do.
4. Whatever the user picks or asks for later goes through **Intake** unless it's trivial, and approved plans follow **Delegation is the default**: todo list with run IDs and waves, registry rows, then launch the agents. The orchestrator does not implement steps itself.
