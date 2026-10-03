---
name: ship
description: Review the current changes, then commit, push, and open (or update) a PR and report CI status.
disable-model-invocation: true
argument-hint: "[optional: PR title or notes]"
---

Ship the current changes. Notes from the user: $ARGUMENTS

1. Run `guyb:code-reviewer` on the working-tree diff (or branch diff vs the default branch).
2. If there are 🔴 findings, show them and stop for the user's decision. Fix 🟡 findings directly if they are quick, otherwise list them in the PR body.
3. Run `guyb:git-ops`: branch if on main/master, commit with a conventional message, push, and create a PR (or update the existing PR for this branch).
4. Report: PR URL, CI status (`gh pr checks`), and any follow-ups.
