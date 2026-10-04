---
name: build
description: Run the full build pipeline for a feature, app, microservice, webapp, or MCP server - plan, implement, review, and open a PR.
disable-model-invocation: true
argument-hint: "<what to build>"
---

Build: $ARGUMENTS

Follow the **Build** pipeline from the guyb playbook:

1. Create a todo list with the pipeline stages so the user can follow progress.
2. `guyb:architect` writes `.claude/guyb/pipeline/plans/<run-id>.md` (task table + open questions; ask the questions per the playbook). If the build involves new data, the architect may ask for `guyb:data-modeler` first.
3. Show the user a 5-10 line plan summary. Wait for approval if it is large, risky, or touches auth/data/public APIs; otherwise continue.
4. Load `guyb:pipeline` if you haven't. Launch implementers per the playbook wave rule: one per disjoint file group in parallel only when each group is heavy (roughly >100 changed lines or genuinely independent big areas) or the user wants speed (worktree isolation when more than one edits code); otherwise one implementer does all tasks in sequence. Point each at its own `## Task` section of the plan. Do the shared files yourself.
5. `guyb:code-reviewer` on the combined diff (docs-only changes: skip review; small changes: one round on `sonnet`). Send 🟡 items back to an implementer automatically; bring 🔴 items to the user. Max 2 review rounds, then escalate.
6. `guyb:git-ops`: branch, commit, push, open PR. Report the PR URL and CI status.
7. `guyb:session-tracker` in **end** mode to record the change.

Keep talking with the user while agents run; update the todo list as stages finish.
