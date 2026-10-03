---
name: end
description: Close the work session - record changes, decisions, open issues, and next steps in .claude/STATE.md and fix drifted docs.
disable-model-invocation: true
---

1. Tell `guyb:session-tracker` (end mode) what happened this session: tasks done, decisions with their reasons, PRs/commits, deploys, problems found, and what is next. Include the run IDs from `.claude/pipeline/runs.md` with their final status, and flag any still `running` or `queued`.
2. Once STATE.md is updated, delete progress files under `.claude/pipeline/progress/` for runs that are `done`; keep those of unfinished or failed runs.
3. If there is uncommitted work, ask the user whether to commit it (via `guyb:git-ops`) or leave it, and note it in STATE.md either way.
4. Report what the session tracker changed.
