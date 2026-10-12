---
name: end
description: Wrap up the work session - checkpoint and stop running agents, write a handoff, record the session in .claude/guyb/STATE.md, then commit and push every work branch (WIP included, no PR) so another machine can continue. Use when the user says they need to go, are done for today, want to wrap up or stop for now, runs /guyb:end, or the guyb usage guard says to wind down.
---

Goal: nothing lost when the user walks away. Same machine resumes from the handoff file; another machine resumes from STATE.md and the pushed branches.

1. **Stop agents.** From `.claude/guyb/pipeline/runs.md` and your running background tasks:
   - `queued`: don't launch; set `stopped`.
   - `running`: SendMessage each one: "Wrap-up: stop after the current command. Overwrite your progress file (status, done, doing, next, files touched), write your report file, then end your run without starting new steps." Wait for their results, about 3 minutes in total. TaskStop any still running and set `stopped`; for the others apply the pipeline rules (verify, then `done` / `failed` / `blocked`).
   - Collect questions from their reports into the question log, as usual.
2. **Handoff** (same-machine resume). Overwrite `.claude/guyb/pipeline/handoff.md` (gitignored), under 40 lines: date; per branch/worktree what was in flight and its next action; stopped runs with their progress file paths; open questions; the first thing to do on resume.
3. **STATE.md** (cross-machine resume). Tell `guyb:session-tracker` (end mode) what happened: tasks done, decisions with their reasons, PRs/commits, deploys, problems found, what is next, run IDs with final status (flag `stopped` ones and where their progress files are), and the branches about to be pushed as WIP.
4. Delete progress files under `.claude/guyb/pipeline/progress/` for runs that are `done`; keep the rest (the handoff points to them).
5. **Commit and push.** List every work branch with uncommitted changes or unpushed commits: the main checkout and each `git worktree list` entry. If the user already said to commit, or this list is empty apart from STATE.md, go ahead; otherwise ask once (AskUserQuestion): commit and push all as WIP (recommended) / leave uncommitted. Then `guyb:git-ops`, one call for all branches: per branch stage the changed files (never secrets), commit (`wip: <summary>` when the work is unfinished, a normal conventional commit when it is done), `git push -u origin <branch>`, no PR. STATE.md rides with the current branch's commit. Never commit to or push the default branch: changes sitting on it go to a new `wip/<topic>` branch first. A push that fails is reported, not retried with force. If the user leaves work uncommitted, note it in STATE.md and the handoff.
6. Report in a few lines: runs stopped, branches pushed (branch + short SHA), anything left uncommitted, the handoff path, and that it is safe to close.

## Usage limit mode
Trigger: a "guyb usage guard" notice. At `stop` little plan usage is left (default 98%), so do only this, inline: no new agents (a launch prompts the user), no session-tracker, no git-ops, no extra questions.
- **warn** notice: tell the user in one line (window, percent, reset time) and that no new waves start; keep running agents going. Nothing else.
- **stop** notice:
  1. Launch nothing. `queued` runs stay `queued`; the handoff lists them as "launch after reset".
  2. `running`: SendMessage the step 1 checkpoint text; wait about 1 minute in total; TaskStop the rest and set `stopped`.
  3. Handoff as step 2, plus `limit: <5-hour|weekly> resets <time>`.
  4. STATE.md: write the session entry yourself (what was done, decisions, run IDs with status, branches pushed, next).
  5. Commit and push WIP on every work branch yourself (main checkout and each `git worktree list` entry), no asking: stage the changed files (never secrets), `wip: <summary>`, `git push -u origin <branch>`. Never the default branch (changes on it go to a new `wip/<topic>` branch first), never force; a failed push is reported. STATE.md rides with the current branch.
  6. Summary: finished, stopped (progress file paths), queued, branches pushed (branch + short SHA), next actions, reset time. After the reset this session, or `/guyb:start`, resumes from `handoff.md`; another machine resumes from STATE.md and the pushed branches.
