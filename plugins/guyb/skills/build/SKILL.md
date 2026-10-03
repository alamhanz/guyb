---
name: build
description: Run the full build pipeline for a feature, app, microservice, webapp, or MCP server - plan, implement in parallel, review, and open a PR.
disable-model-invocation: true
argument-hint: "<what to build>"
---

Build: $ARGUMENTS

Follow the **Build** pipeline from the guyb playbook:

1. Create a todo list with the pipeline stages so the user can follow progress.
2. `guyb:architect` writes `.claude/pipeline/plan.md`. If the build involves new data, the architect may ask for `guyb:data-modeler` first.
3. Show the user a 5-10 line plan summary. Wait for approval if it is large, risky, or touches auth/data/public APIs; otherwise continue.
4. Split the plan's "Parallelizable work" into disjoint file groups and launch one `guyb:implementer` per group in parallel (worktree isolation when more than one edits code). Do the shared files yourself.
5. `guyb:code-reviewer` on the combined diff. Send 🟡 items back to an implementer automatically; bring 🔴 items to the user. Max 2 review rounds, then escalate.
6. `guyb:git-ops`: branch, commit, push, open PR. Report the PR URL and CI status.
7. `guyb:session-tracker` in **end** mode to record the change.

Keep talking with the user while agents run; update the todo list as stages finish.
