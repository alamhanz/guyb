---
name: pipeline
description: Run tracking rules for guyb - registry, progress files, question log, token accounting. Load before launching or tracking subagent runs.
---

Detailed mechanics for the orchestrator's subagent runs. The playbook has the core rules; this skill has the formats.

## Run IDs and registry
Every subagent run gets an ID `<project>-<n>`: `<project>` is the project folder name, `<n>` is the next integer in the registry (it keeps counting across sessions, never reused).
- **Registry** `.claude/pipeline/runs.md`, created on first use and edited only by you:
  ```
  | ID | Agent | Model | Task | Wave | After | Status | Started | Tokens |
  |---|---|---|---|---|---|---|---|---|
  | shuto-1 | architect | opus | plan rate limiting | 1 | - | done | 2026-10-03 14:02 | 41k |
  | shuto-2 | implementer | sonnet | middleware + tests | 2 | shuto-1 | running | 2026-10-03 14:10 | - |
  ```
  Status: `queued` -> `running` -> `done` / `blocked` / `failed` / `stopped`. Record the model you chose in the `Model` column. Update the row when you launch a run and when its result arrives.
- **Tokens:** when a run finishes, fill `Tokens` from the usage in its completion notice (`subagent_tokens`), e.g. `41k`; `-` while running or if not reported. If an existing `runs.md` lacks `Tokens`, append the column. Use it when the user asks what a run or a build cost.
- **`.gitignore`:** when you first create `.claude/pipeline/` in a git repo, make sure `.gitignore` ignores `.claude/pipeline/` (or `.claude/`); if not, append `.claude/pipeline/` (create the file if missing) without asking, and mention it in one line. Never add `.claude/STATE.md` (it is meant to be committed).

## Progress files
`.claude/pipeline/progress/<id>.md`, written by the subagent. Add this to every subagent prompt, with the absolute path of the main project folder (a worktree-isolated agent must still write there):
> Your run ID is `<id>`. Create `<abs path>/.claude/pipeline/progress/<id>.md` at the start and overwrite it at the end with: `status:` (working / blocked / done / failed), `done:` (bullets), `doing:`, `next:`, `blockers:`, `questions:`, `files touched:`. Update it in between only for long runs (many steps or more than ~10 minutes), after each major step. Keep it under 30 lines. This file is the only file you may write outside your normal scope.
> You can't ask the user directly. If you need a decision, put it under `questions:` in the progress file and in a `## Questions for the user` section of your final report, each with the question, 2-4 options (recommended first), and `blocking: yes/no`. Blocking (you can't continue safely: unclear requirement, destructive, security-relevant or costly choice, missing access): finish what you can, set `status: blocked`, and end your run with the questions. Non-blocking: state the assumption you're using (`assumed: ...`) and keep going.
> Keep your final report to about 15 lines (outcome, files touched, verification, questions); details go in the progress file or plan.

## Handing work to implementers
The architect's plan has a shared header plus one short `## Task <run-id or #>` section per task. Point each implementer at the plan path and its own section only ("read the header and `## Task 3`"), so it doesn't load the others. Give each the plan path, its run ID, and its progress file block above.

## Run status queries
When the user asks about a run ("how's shuto-2?", "what's running?"): read the registry and the progress files and summarize from them, stating how fresh each file is (its last-modified time). A running agent's result is not visible to you until it finishes, so never guess beyond what the file says; for the live transcript, point the user to the agent panel (`↑`/`↓`, `Enter`) or `/tasks`.
- Refer to runs by ID in your updates and summaries. At session end, `session-tracker` records finished run IDs in `.claude/STATE.md`; progress files are scratch and can be deleted after that.

## Questions from agents
Agents never talk to the user; you collect their questions and ask them.
- **Question log** `.claude/pipeline/questions.md`, created on first use and edited only by you (same `.gitignore` check as the registry). IDs `Q<n>` keep counting across sessions:
  ```
  | Q | Run | Agent | Question | Blocking | Assumed | Status | Answer |
  |---|---|---|---|---|---|---|---|
  | Q1 | shuto-1 | architect | Rate limit per user or per IP? | yes | - | answered | per user |
  | Q2 | shuto-2 | implementer | Return 429 or 503? | no | 429 | open | |
  ```
  Status: `open` -> `answered` (or `dropped` if no longer relevant).
- **Collect** from each finished or blocked run's report (and from progress files when the user asks for status). Add every question to the log; mark the registry row `blocked` if any of its questions is blocking.
- **Ask** open questions with the AskUserQuestion picker, up to 4 per call, blocking ones first. Use the Q ID as the header, start the question with `[<run-id> <agent>]`, and pass the agent's options (recommended first). Ask as soon as a blocking question arrives, adding any open non-blocking ones to the same call.
- **Record** each answer in the log, then act on it:
  - Blocking, agent still resumable: continue it with SendMessage (it keeps its context), giving the Q IDs and answers; set the run back to `running`.
  - Blocking, agent gone (new session): launch a new run with the answers and the old progress file, `after: <old id>`.
  - Non-blocking: if the answer matches the assumption, nothing to do; if it differs, queue a follow-up run (usually implementer) to change it.
- When the user asks "any questions?" / "what's pending?", show the open rows of the log, then ask them.
